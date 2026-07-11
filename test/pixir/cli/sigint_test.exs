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
    assert Enum.map(history, & &1.type) == [:subagent_event, :tool_call, :tool_result]

    assert %{
             data: %{
               "call_id" => "call_active",
               "error" => %{"kind" => "orphan_tool_call", "details" => %{"reason" => "interrupt"}}
             }
           } = List.last(history)
  end

  test "install and remove trap SIGUSR1 without error", %{sid: sid} do
    previous = Application.get_env(:pixir, :cli_sigint_trap, false)
    Application.put_env(:pixir, :cli_sigint_trap, true)
    on_exit(fn -> Application.put_env(:pixir, :cli_sigint_trap, previous) end)

    assert {:ok, trap} = Sigint.install(sid)
    assert :ok = Sigint.remove(trap)
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
end
