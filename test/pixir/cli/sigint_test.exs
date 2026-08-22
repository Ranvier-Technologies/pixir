defmodule Pixir.CLI.SigintTest do
  use ExUnit.Case, async: false

  alias Pixir.{Conversation, Event, Log, Session}
  alias Pixir.CLI.Sigint

  setup do
    ws =
      Path.join(
        System.tmp_dir!(),
        "pixir-cli-sigint-" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
      )

    File.mkdir_p!(ws)
    on_exit(fn -> File.rm_rf!(ws) end)

    {:ok, sid} = Conversation.start(workspace: ws)
    %{ws: ws, sid: sid}
  end

  test "on_interrupt during an active Turn calls Conversation.interrupt/1", %{sid: sid} do
    test_pid = self()

    {:ok, _ref} =
      Session.start_turn(sid, fn _ctx ->
        send(test_pid, :turn_started)
        Process.sleep(5_000)
      end)

    assert_receive :turn_started, 500
    assert Session.turn_running?(sid)

    assert :interrupt_turn = Sigint.on_interrupt(sid)
    refute Session.turn_running?(sid)
  end

  test "on_interrupt when idle exits without spurious Log events", %{sid: sid, ws: ws} do
    refute Session.turn_running?(sid)
    assert :exit_idle = Sigint.on_interrupt(sid)

    # The root posture is creation-time evidence, not an interrupt artifact:
    # the Log must hold exactly that and nothing else.
    assert {:ok, [%{data: %{"event" => "permission_posture"}}]} = Log.fold(sid, workspace: ws)
  end

  test "interrupt during Turn records status interrupted and reconciles tool_calls", %{
    ws: ws,
    sid: sid
  } do
    test_pid = self()

    {:ok, _ref} =
      Session.start_turn(sid, fn ctx ->
        Session.record(
          ctx.session_id,
          Event.tool_call(ctx.session_id, "call_active", "bash", %{})
        )

        send(test_pid, :tool_call_recorded)
        Process.sleep(300)
      end)

    assert_receive :tool_call_recorded, 500
    assert :interrupt_turn = Sigint.on_interrupt(sid)

    assert {:ok, history} = Log.fold(sid, workspace: ws)

    assert Enum.map(history, & &1.type) == [
             :subagent_event,
             :tool_call,
             :tool_result,
             :turn_failed
           ]

    assert %{
             data: %{
               "call_id" => "call_active",
               "error" => %{"kind" => "orphan_tool_call", "details" => %{"reason" => "interrupt"}}
             }
           } = Enum.at(history, 2)

    assert %{
             data: %{
               "terminal_status" => "interrupted",
               "error_kind" => "interrupted",
               "details" => %{"scope" => "turn"}
             }
           } = List.last(history)
  end

  test "install and remove trap SIGUSR1 without error", %{sid: sid} do
    enable_real_helper!()

    assert {:ok, trap} = Sigint.install(sid)
    assert :ok = Sigint.remove(trap)
  end

  test "helper dies when the port closes and leaves no sleep children", %{sid: sid} do
    enable_real_helper!()

    assert {:ok, {_trap_id, port} = trap} = Sigint.install(sid)
    {:os_pid, os_pid} = Port.info(port, :os_pid)
    on_exit(fn -> reap_os_pid(os_pid) end)

    assert os_process_alive?(os_pid)
    assert helper_command(os_pid) =~ "read -r"
    refute helper_command(os_pid) =~ "sleep 3600"
    assert child_commands(os_pid) == []

    assert :ok = Sigint.remove(trap)
    assert await_os_exit(os_pid, 1_000)
    refute os_process_alive?(os_pid)
    assert child_commands(os_pid) == []
  end

  test "helper dies when its owning process exits without remove/1", %{sid: sid} do
    enable_real_helper!()
    parent = self()

    owner =
      spawn(fn ->
        {:ok, {_trap_id, port}} = Sigint.install(sid)
        {:os_pid, os_pid} = Port.info(port, :os_pid)
        send(parent, {:helper, os_pid})
        Process.sleep(:infinity)
      end)

    assert_receive {:helper, os_pid}, 1_000

    on_exit(fn ->
      _ = System.untrap_signal(:sigusr1, :pixir_cli_turn)
      reap_os_pid(os_pid)
    end)

    assert os_process_alive?(os_pid)
    Process.exit(owner, :kill)
    assert await_os_exit(os_pid, 1_000)
    assert child_commands(os_pid) == []
  end

  test "INT on the helper forwards USR1 and the helper stays up until port close", %{ws: ws} do
    # Mix's test VM treats SIGUSR1 as a crash dump, so the helper targets a
    # dummy OS process instead of the test BEAM.
    count_path = Path.join(ws, "usr1.count")
    File.write!(count_path, "0")

    dummy_script =
      "interrupted=0; trap 'n=$(cat #{count_path}); echo $((n+1)) > #{count_path}; interrupted=1' USR1; " <>
        "while :; do interrupted=0; IFS= read -r _ && continue; " <>
        "if [ \"$interrupted\" -eq 1 ]; then continue; fi; break; done"

    dummy_port =
      Port.open({:spawn_executable, System.find_executable("sh")}, [
        :binary,
        {:args, ["-c", dummy_script]}
      ])

    {:os_pid, dummy_pid} = Port.info(dummy_port, :os_pid)
    assert {:ok, port} = Sigint.start_sigint_forwarder(dummy_pid)
    {:os_pid, os_pid} = Port.info(port, :os_pid)

    on_exit(fn ->
      if Port.info(port), do: Port.close(port)
      if Port.info(dummy_port), do: Port.close(dummy_port)
      reap_os_pid(os_pid)
      reap_os_pid(dummy_pid)
    end)

    assert os_process_alive?(os_pid)
    assert os_process_alive?(dummy_pid)
    assert child_commands(os_pid) == []

    {_, 0} = System.cmd("kill", ["-INT", Integer.to_string(os_pid)])
    assert await_truth(fn -> usr1_count(count_path) == 1 end, 1_000)
    assert os_process_alive?(os_pid)

    {_, 0} = System.cmd("kill", ["-INT", Integer.to_string(os_pid)])
    assert await_truth(fn -> usr1_count(count_path) == 2 end, 1_000)
    assert os_process_alive?(os_pid)

    Port.close(port)
    assert await_os_exit(os_pid, 1_000)
    assert child_commands(os_pid) == []
  end

  test "Conversation.await treats emitted interrupted status as terminal", %{sid: sid, ws: ws} do
    :ok = Conversation.subscribe(sid)

    {:ok, _ref} =
      Session.start_turn(sid, fn ctx ->
        Session.emit(ctx.session_id, Event.status(ctx.session_id, "interrupted"))
      end)

    assert :interrupted = Conversation.await(sid, idle_timeout: 2_000)

    # Only the creation-time root posture: the interrupted status was ephemeral.
    assert {:ok, [%{data: %{"event" => "permission_posture"}}]} = Log.fold(sid, workspace: ws)
  end

  defp enable_real_helper! do
    previous = Application.get_env(:pixir, :cli_sigint_trap, false)
    Application.put_env(:pixir, :cli_sigint_trap, true)
    on_exit(fn -> Application.put_env(:pixir, :cli_sigint_trap, previous) end)
  end

  defp usr1_count(path) do
    case File.read(path) do
      {:ok, contents} ->
        case Integer.parse(String.trim(contents)) do
          {n, _rest} -> n
          :error -> -1
        end

      {:error, _} ->
        -1
    end
  end

  defp os_process_alive?(os_pid) when is_integer(os_pid) do
    case System.cmd("kill", ["-0", Integer.to_string(os_pid)], stderr_to_stdout: true) do
      {_out, 0} -> true
      _ -> false
    end
  end

  defp await_os_exit(os_pid, timeout_ms) do
    await_truth(fn -> not os_process_alive?(os_pid) end, timeout_ms)
  end

  defp await_truth(fun, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    await_truth_loop(fun, deadline)
  end

  defp await_truth_loop(fun, deadline) do
    if fun.() do
      true
    else
      if System.monotonic_time(:millisecond) >= deadline do
        false
      else
        Process.sleep(20)
        await_truth_loop(fun, deadline)
      end
    end
  end

  defp helper_command(os_pid) do
    ps_rows()
    |> Enum.find_value("", fn {pid, _ppid, command} ->
      if pid == Integer.to_string(os_pid), do: command
    end)
  end

  defp child_commands(os_pid) do
    parent = Integer.to_string(os_pid)

    for {_, ppid, command} <- ps_rows(), ppid == parent, do: command
  end

  defp ps_rows do
    {out, _} = System.cmd("ps", ["-eo", "pid=,ppid=,command="], stderr_to_stdout: true)

    out
    |> String.split("\n", trim: true)
    |> Enum.flat_map(fn line ->
      case String.split(String.trim(line), ~r/[[:space:]]+/, parts: 3) do
        [pid, ppid, command] -> [{pid, ppid, command}]
        _ -> []
      end
    end)
  end

  defp reap_os_pid(os_pid) when is_integer(os_pid) do
    if os_process_alive?(os_pid) do
      _ = System.cmd("kill", ["-9", Integer.to_string(os_pid)], stderr_to_stdout: true)
    end

    :ok
  end
end
