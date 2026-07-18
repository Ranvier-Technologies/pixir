unless Code.ensure_loaded?(PixirMonitor.InventoryFixture) do
  Code.require_file("support/inventory_fixture.ex", __DIR__)
end

defmodule PixirMonitor.EscriptLifecycleTest do
  use ExUnit.Case, async: false

  @moduledoc """
  Drives one fail-closed real-browser lifecycle from serve boot through a real
  five-minute SSE rotation, process restart, and an honestly stale old tab.
  """

  @project_root Path.expand("..", __DIR__)
  @escript Path.join(@project_root, "pixir-monitor")
  @harness Path.join(__DIR__, "support/lifecycle_browser_harness.mjs")
  @node System.find_executable("node")
  @node_websocket if(is_binary(@node),
                    do: elem(System.cmd(@node, ["-p", "typeof WebSocket"]), 0) == "function\n",
                    else: false
                  )
  @browser Enum.find(
             [
               System.get_env("PIXIR_MONITOR_BROWSER_BIN"),
               System.find_executable("google-chrome"),
               System.find_executable("chromium"),
               System.find_executable("chromium-browser"),
               "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
               "/Applications/Chromium.app/Contents/MacOS/Chromium",
               "/Applications/Helium.app/Contents/MacOS/Helium"
             ],
             &(is_binary(&1) and File.exists?(&1))
           )
  # A missing browser toolchain soft-skips LOCALLY but must fail LOUDLY in CI:
  # since #401 the browser suites are CI-mandatory, and a lost setup step must
  # never demote them back to silent skip-green (the #397 bar; same idiom as
  # the presenter UI seam tier). The CI toolchain assert lives in setup.
  @browser_skip (cond do
                   is_binary(@node) and @node_websocket and is_binary(@browser) -> false
                   System.get_env("CI") in ["true", "1"] -> false
                   true -> "requires Node.js WebSocket support and a Chrome-compatible browser"
                 end)

  setup do
    if System.get_env("CI") in ["true", "1"] do
      toolchain = [node: is_binary(@node), websocket: @node_websocket, browser: is_binary(@browser)]

      assert Enum.all?(Keyword.values(toolchain)),
             "the CI runner lost part of its browser toolchain #{inspect(toolchain)}: " <>
               "browser suites must not silently skip in CI"
    end

    :ok
  end

  @lifecycle_skip @browser_skip ||
                    if(System.get_env("PIXIR_MONITOR_LIFECYCLE") == "1",
                      do: false,
                      else: "requires PIXIR_MONITOR_LIFECYCLE=1 because it holds a REAL 300s SSE rotation and must not inflate the default local suite"
                    )

  @checkpoints ~w(serve_boot browse_baseline live_log_growth sse_rotation_300s escript_restart stale_display_and_new_session)

  setup_all do
    {output, status} =
      System.cmd("mix", ["escript.build"],
        cd: @project_root,
        env: [{"MIX_ENV", "dev"}],
        stderr_to_stdout: true
      )

    assert status == 0, "mix escript.build failed: #{output}"
    assert File.exists?(@escript)
    :ok
  end

  @tag skip: @lifecycle_skip
  # 60s of headroom above the 590s driver deadline + 10s rescue drain, so an
  # ExUnit timeout can never interrupt teardown.
  @tag timeout: 660_000
  test "one real browser fails closed across the complete lifecycle" do
    root =
      Path.join(
        System.tmp_dir!(),
        "pixir-monitor-escript-lifecycle-#{System.unique_integer([:positive])}"
      )

    workspace = Path.join(root, "workspace")
    File.mkdir_p!(workspace)
    run_ids = PixirMonitor.InventoryFixture.materialize_many!(workspace, 0..7)
    existing_log = Path.join([workspace, ".pixir", "sessions", hd(run_ids) <> ".ndjson"])
    profiles_before = Path.wildcard(Path.join(root, "pixir-monitor-lifecycle-*")) |> MapSet.new()
    on_exit(fn -> File.rm_rf!(root) end)

    {result, status} = run_harness!(root, workspace, existing_log)

    assert status == 0, "lifecycle browser harness failed: #{inspect(result)}"
    assert result["ok"] == true
    assert result["check"] == "pixir_monitor_lifecycle"
    assert result["phases"] == @checkpoints
    assert result["event_requests"] >= 2
    assert is_number(result["rotated_stream_lifetime_seconds"])
    assert result["rotated_stream_lifetime_seconds"] >= 290
    assert result["rotated_stream_lifetime_seconds"] <= 330
    assert result["navigation_entries"] == 1
    assert result["baseline_count"] == 8
    assert result["grown_count"] == 9
    assert result["launch_fragment_cleared"] == true
    assert result["handoffs_cleaned"] == true

    assert result["cleanup"] == %{
             "browser_stopped" => true,
             "monitor_stopped" => true,
             "profile_removed" => true
           }

    profiles_after = Path.wildcard(Path.join(root, "pixir-monitor-lifecycle-*")) |> MapSet.new()
    assert MapSet.difference(profiles_after, profiles_before) == MapSet.new()
  end

  defp run_harness!(root, workspace, existing_log) do
    stderr_path = Path.join(root, "harness.stderr")
    shell = System.find_executable("sh")

    port =
      Port.open({:spawn_executable, shell}, [
        :binary,
        :exit_status,
        :use_stdio,
        args: [
          "-c",
          ~S|stderr="$1"; shift; exec "$@" 2>"$stderr"|,
          "lifecycle-browser-e2e",
          stderr_path,
          @node,
          @harness,
          "--monitor",
          @escript,
          "--workspace",
          workspace,
          "--existing-log",
          existing_log,
          "--browser",
          @browser,
          "--profile-base",
          root,
          "--json"
        ]
      ])

    on_exit(fn -> close_port(port) end)
    deadline = System.monotonic_time(:millisecond) + 590_000

    try do
      {output, status, handled} = drive!(port, stderr_path, workspace, handled(), "", deadline, 0)
      assert handled == MapSet.new(@checkpoints), "missing lifecycle checkpoints: #{inspect(MapSet.difference(MapSet.new(@checkpoints), handled))}"
      result = output |> String.split("\n", trim: true) |> List.last() |> Jason.decode!()
      {result, status}
    rescue
      error ->
        drain(port, System.monotonic_time(:millisecond) + 10_000)
        reraise error, __STACKTRACE__
    end
  end

  defp handled, do: MapSet.new()

  defp drive!(port, stderr_path, workspace, handled, output, deadline, consumed) do
    assert System.monotonic_time(:millisecond) < deadline,
           "lifecycle harness exceeded its 590 second driver deadline"

    lines = complete_json_lines(stderr_path)

    handled =
      lines
      |> Enum.drop(consumed)
      |> Enum.reduce(handled, fn line, seen ->
        prompt = Jason.decode!(line)
        checkpoint = prompt["checkpoint"]
        phase = prompt["phase"]

        refute MapSet.member?(seen, phase),
               "harness re-emitted an already-handled lifecycle checkpoint phase: #{phase}"

        assert phase in @checkpoints
        assert checkpoint == Enum.find_index(@checkpoints, &(&1 == phase)) + 1
        assert prompt["servedWorkspace"] == Path.expand(workspace)

        verify_and_apply!(workspace, prompt)
        acknowledge(port, prompt)
        MapSet.put(seen, phase)
      end)

    consumed = length(lines)

    receive do
      {^port, {:data, bytes}} ->
        drive!(port, stderr_path, workspace, handled, output <> bytes, deadline, consumed)

      {^port, {:exit_status, status}} ->
        {output, status, handled}
    after
      25 -> drive!(port, stderr_path, workspace, handled, output, deadline, consumed)
    end
  end

  defp verify_and_apply!(workspace, %{"phase" => "serve_boot", "expectedCount" => 8}) do
    assert length(session_logs(workspace)) == 8
  end

  defp verify_and_apply!(workspace, %{"phase" => "browse_baseline", "expectedCount" => 8}) do
    assert length(session_logs(workspace)) == 8
  end

  defp verify_and_apply!(workspace, %{
         "phase" => "live_log_growth",
         "existingLog" => existing_log,
         "beforeSize" => before_size
       }) do
    assert existing_log in session_logs(workspace)
    before = File.stat!(existing_log)
    assert before.size == before_size

    File.write!(
      existing_log,
      Jason.encode!(growth_event(Path.basename(existing_log, ".ndjson"))) <> "\n",
      [:append]
    )

    [new_id] = PixirMonitor.InventoryFixture.materialize_many!(workspace, [8])
    new_log = Path.join([workspace, ".pixir", "sessions", new_id <> ".ndjson"])
    after_growth = File.stat!(existing_log)

    assert {after_growth.mtime, after_growth.size} != {before.mtime, before.size}
    assert after_growth.size > before_size
    assert File.regular?(new_log)
    assert length(session_logs(workspace)) == 9
  end

  defp verify_and_apply!(workspace, %{"phase" => "sse_rotation_300s", "expectedCount" => 9}) do
    # No fixture writes occur from this acknowledgement until the timer closes the
    # stream. This distinguishes the 300s timer from the 100-event cap path.
    assert length(session_logs(workspace)) == 9
    Process.put({__MODULE__, :quiet_fingerprint}, workspace_fingerprint(workspace))
  end

  defp verify_and_apply!(workspace, %{"phase" => "escript_restart", "monitorPid" => pid})
       when is_integer(pid) do
    assert length(session_logs(workspace)) == 9
    assert Process.get({__MODULE__, :quiet_fingerprint}) == workspace_fingerprint(workspace)
    # SIGTERM starts a graceful BEAM stop, but the tab's live SSE connection can
    # hold it open far longer than this driver's bound (measured: >5s); escalate
    # to SIGKILL the way an operator restart would.
    {_, 0} = System.cmd("kill", ["-TERM", Integer.to_string(pid)])

    unless process_exited?(pid, 100) do
      _ = System.cmd("kill", ["-KILL", Integer.to_string(pid)], stderr_to_stdout: true)
    end

    assert process_exited?(pid, 200), "Monitor did not stop after SIGTERM then SIGKILL"
  end

  defp verify_and_apply!(workspace, %{
         "phase" => "stale_display_and_new_session",
         "expectedCount" => 9
       }) do
    assert length(session_logs(workspace)) == 9
  end

  # The appended line mirrors FixtureWorkspace.wrapped_event/2 exactly: a real
  # Log line carries id and session_id, and the projection must fold it (the
  # harness pins the run's "as of seq" moving), not merely notice a bigger file.
  defp growth_event(session_id) do
    %{
      "id" => "event-#{session_id}-1",
      "session_id" => session_id,
      "seq" => 1,
      "ts" => "2026-07-16T00:05:00Z",
      "type" => "workflow_event",
      "data" => %{
        "kind" => "workflow_step_started",
        "workflow_id" => "inventory-scope",
        "step_id" => "growth-observation"
      }
    }
  end

  defp session_logs(workspace) do
    Path.wildcard(Path.join([workspace, ".pixir", "sessions", "*.ndjson"]))
  end

  defp workspace_fingerprint(workspace) do
    Map.new(session_logs(workspace), fn path ->
      stat = File.stat!(path)
      {path, {stat.mtime, stat.size}}
    end)
  end

  defp process_exited?(_pid, 0), do: false

  defp process_exited?(pid, attempts) do
    case System.cmd("kill", ["-0", Integer.to_string(pid)], stderr_to_stdout: true) do
      {_, 0} ->
        Process.sleep(25)
        process_exited?(pid, attempts - 1)

      {_, _} ->
        true
    end
  end

  defp acknowledge(port, prompt) do
    true =
      Port.command(
        port,
        Jason.encode!(%{
          phase: prompt["phase"],
          checkpoint: prompt["checkpoint"],
          post_state: "verified"
        }) <> "\n"
      )

    :ok
  end

  defp complete_json_lines(path) do
    case File.read(path) do
      {:ok, bytes} ->
        bytes
        |> String.split("\n")
        |> Enum.drop(-1)
        |> Enum.reject(&(&1 == ""))

      {:error, :enoent} ->
        []
    end
  end

  defp drain(port, deadline) do
    cond do
      Port.info(port) == nil ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        close_port(port)

      true ->
        receive do
          {^port, {:data, _bytes}} -> drain(port, deadline)
          {^port, {:exit_status, _status}} -> :ok
        after
          25 -> drain(port, deadline)
        end
    end
  end

  defp close_port(port) do
    if Port.info(port), do: Port.close(port)
    :ok
  rescue
    ArgumentError -> :ok
  end
end
