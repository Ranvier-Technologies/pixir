defmodule PixirMonitor.EscriptWorkspaceSetTest do
  use ExUnit.Case, async: false

  import Bitwise, only: [band: 2]

  @moduledoc """
  Drives the built workspace-set escript and a real Chrome instance while this
  ExUnit process alone mutates the two deterministic fixture workspaces.
  """

  @project_root Path.expand("..", __DIR__)
  @escript Path.join(@project_root, "pixir-monitor")
  @harness Path.join(__DIR__, "support/workspace_set_browser_harness.mjs")
  @node System.find_executable("node")
  @node_websocket if(is_binary(@node), do: elem(System.cmd(@node, ["-p", "typeof WebSocket"]), 0) == "function\n", else: false)
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

  for mode <- ~w(removal permission_denial corrupt_log empty_restoration runs_unheld) do
    @tag skip: @browser_skip
    test "real browser isolates and recovers #{mode} degradation" do
      mode = unquote(mode)
      fixture = fixture_workspaces!(mode)
      profiles_before = Path.wildcard(Path.join(fixture.root, "pixir-monitor-workspace-set-browser-*")) |> MapSet.new()
      browser_helpers_before = browser_profile_processes(fixture.root)

      on_exit(fn -> File.rm_rf!(fixture.root) end)

      try do
        {result, status} = run_harness!(fixture, mode)
        assert status == 0, "workspace-set browser mode #{mode} failed: #{inspect(result)}"
        assert result["ok"] == true
        assert result["check"] == "pixir_monitor_workspace_set_browser_degradation"
        assert result["mode"] == mode
        assert result["launch_fragment_cleared"] == true
        assert result["handoff_cleaned"] == true

        if mode != "runs_unheld" do
          assert "healthy_both_overview_list_detail_unit" in result["phases"]
        end

        assert "healthy_source_fully_navigable" in result["phases"]
        assert "recovery_fresh_authoritative_fetch" in result["phases"]

        case mode do
          "permission_denial" ->
            assert "degrade_stale_unit_navigation_preserved" in result["phases"]
            assert "exact_limitation_and_no_duplicate_sections" in result["phases"]
            assert "per_source_retry_network_scoped" in result["phases"]
            assert "rapid_flapping_newest_receipt_monotonic" in result["phases"]

          "removal" ->
            assert "degrade_navigation_state_preserved" in result["phases"]
            assert "removed_sessions_directory_absent_not_zero_inferred" in result["phases"]

          "corrupt_log" ->
            assert "degrade_navigation_state_preserved" in result["phases"]
            assert "exact_run_projection_incomplete_limitation" in result["phases"]

          "empty_restoration" ->
            assert "degrade_navigation_state_preserved" in result["phases"]
            assert "empty_source_observed_zero" in result["phases"]
            assert "per_source_retry_network_scoped" in result["phases"]

          "runs_unheld" ->
            assert "runs_unheld_unavailable_not_blank" in result["phases"]
            assert "per_source_retry_network_scoped" in result["phases"]
        end

        assert_bounded_cleanup!(fixture.root, profiles_before, browser_helpers_before, result["cleanup"])
      after
        File.chmod(fixture.sessions, 0o700)
        File.rm_rf!(fixture.root)
      end
    end
  end

  defp run_harness!(fixture, mode) do
    stderr_path = Path.join(fixture.root, "harness.stderr")
    shell = System.find_executable("sh")

    args = [
      "-c",
      ~S|stderr="$1"; shift; exec "$@" 2>"$stderr"|,
      "workspace-set-browser-e2e",
      stderr_path,
      @node,
      @harness,
      "--monitor",
      @escript,
      "--left-workspace",
      fixture.served_left,
      "--right-workspace",
      fixture.served_right,
      "--left-run-id",
      fixture.left_run,
      "--right-run-id",
      fixture.right_run,
      "--left-unit-id",
      fixture.left_unit,
      "--right-unit-id",
      fixture.right_unit,
      "--browser",
      @browser,
      "--profile-base",
      fixture.root,
      "--mode",
      mode,
      "--json"
    ]

    port =
      Port.open({:spawn_executable, shell}, [
        :binary,
        :exit_status,
        :use_stdio,
        args: args
      ])

    on_exit(fn -> close_harness_port(port) end)
    deadline = System.monotonic_time(:millisecond) + 120_000

    try do
      {output, status} = drive_port!(port, stderr_path, fixture, mode, MapSet.new(), "", deadline)
      result = Jason.decode!(String.trim(output))
      if is_binary(result["profile_path"]), do: on_exit(fn -> File.rm_rf!(result["profile_path"]) end)
      {result, status}
    rescue
      error ->
        drain_harness_after_driver_failure(port, System.monotonic_time(:millisecond) + 10_000)
        reraise error, __STACKTRACE__
    end
  end

  defp drive_port!(port, stderr_path, fixture, mode, handled, output, deadline) do
    assert System.monotonic_time(:millisecond) < deadline, "workspace-set browser harness exceeded 120 seconds"

    {handled, output} =
      stderr_path
      |> complete_json_lines()
      |> Enum.reduce({handled, output}, fn line, {seen, bytes} ->
        prompt = Jason.decode!(line)
        token = prompt["checkpoint"]

        if MapSet.member?(seen, token) do
          {seen, bytes}
        else
          try do
            synchronize_watcher_baseline!()
            assert_served_pre_state!(fixture, mode, prompt)
            mutate_fixture!(fixture, mode, prompt)
            assert_served_post_state!(fixture, mode, prompt)
            acknowledge_checkpoint(port, fixture, prompt, "verified")
            {MapSet.put(seen, token), bytes}
          rescue
            error ->
              acknowledge_checkpoint(port, fixture, prompt, "driver_failed")
              reraise error, __STACKTRACE__
          end
        end
      end)

    receive do
      {^port, {:data, bytes}} ->
        drive_port!(port, stderr_path, fixture, mode, handled, output <> bytes, deadline)

      {^port, {:exit_status, status}} ->
        {output, status}
    after
      20 -> drive_port!(port, stderr_path, fixture, mode, handled, output, deadline)
    end
  end

  defp acknowledge_checkpoint(port, fixture, prompt, post_state) do
    acknowledgement = %{
      phase: prompt["command"],
      checkpoint: prompt["checkpoint"],
      served_workspace: fixture.served_left,
      post_state: post_state
    }

    true = Port.command(port, Jason.encode!(acknowledgement) <> "\n")
    :ok
  end

  defp drain_harness_after_driver_failure(port, deadline) do
    cond do
      Port.info(port) == nil ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        close_harness_port(port)

      true ->
        receive do
          {^port, {:data, _bytes}} -> drain_harness_after_driver_failure(port, deadline)
          {^port, {:exit_status, _status}} -> :ok
        after
          25 -> drain_harness_after_driver_failure(port, deadline)
        end
    end
  end

  defp close_harness_port(port) do
    if Port.info(port), do: Port.close(port)
    :ok
  rescue
    ArgumentError -> :ok
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

  # Every filesystem transition starts from a bounded quiet interval. This gives
  # the monitor watcher one complete polling window to commit the prior durable
  # state before the driver changes the exact served path again.
  defp synchronize_watcher_baseline!, do: Process.sleep(1_000)

  defp assert_served_pre_state!(fixture, mode, prompt) do
    assert prompt["servedWorkspace"] == fixture.served_left
    assert fixture.served_left == Path.expand(fixture.left)
    assert %File.Stat{type: :directory} = File.stat!(fixture.served_left)
    assert fixture.sessions == Path.join([fixture.served_left, ".pixir", "sessions"])

    case {mode, prompt["command"]} do
      {"removal", "degrade"} ->
        assert File.read!(fixture.log) == fixture.original_log

      {"removal", "restore"} ->
        assert {:error, :enoent} = File.stat(fixture.sessions)

      {"permission_denial", command} when command in ["degrade", "flap_degrade"] ->
        assert band(File.stat!(fixture.sessions).mode, 0o777) == 0o700

      {"permission_denial", command} when command in ["restore", "flap_restore"] ->
        assert band(File.stat!(fixture.sessions).mode, 0o777) == 0

      {"corrupt_log", "degrade"} ->
        assert File.read!(fixture.log) == fixture.original_log

      {"corrupt_log", "restore"} ->
        assert File.read!(fixture.log) == "{corrupt\n"

      {"empty_restoration", "prepare_empty"} ->
        assert File.read!(fixture.log) == fixture.original_log

      {"empty_restoration", "degrade"} ->
        assert {:error, :enoent} = File.stat(fixture.log)
        assert band(File.stat!(fixture.sessions).mode, 0o777) == 0o700

      {"empty_restoration", "restore_empty"} ->
        assert band(File.stat!(fixture.sessions).mode, 0o777) == 0

      {"empty_restoration", "restore"} ->
        assert {:error, :enoent} = File.stat(fixture.log)
        assert band(File.stat!(fixture.sessions).mode, 0o777) == 0o700

      {"runs_unheld", "restore"} ->
        assert band(File.stat!(fixture.sessions).mode, 0o777) == 0
    end
  end

  defp assert_served_post_state!(fixture, mode, prompt) do
    case {mode, prompt["command"]} do
      {"removal", "degrade"} ->
        assert {:error, :enoent} = File.stat(fixture.sessions)

      {"removal", "restore"} ->
        assert %File.Stat{type: :regular} = File.stat!(fixture.log)

      {"permission_denial", command} when command in ["degrade", "flap_degrade"] ->
        assert band(File.stat!(fixture.sessions).mode, 0o777) == 0

      {"permission_denial", command} when command in ["restore", "flap_restore"] ->
        assert band(File.stat!(fixture.sessions).mode, 0o777) == 0o700

      {"corrupt_log", "degrade"} ->
        assert File.read!(fixture.log) == "{corrupt\n"

      {"corrupt_log", "restore"} ->
        assert File.read!(fixture.log) == fixture.original_log

      {"empty_restoration", "prepare_empty"} ->
        assert {:error, :enoent} = File.stat(fixture.log)
        assert band(File.stat!(fixture.sessions).mode, 0o777) == 0o700

      # The exact enoent claim was already proved while the directory was
      # traversable, immediately before chmod. Once denied, only its mode is
      # observable without conflating absence with eacces.
      {"empty_restoration", "degrade"} ->
        assert band(File.stat!(fixture.sessions).mode, 0o777) == 0

      {"empty_restoration", "restore_empty"} ->
        assert {:error, :enoent} = File.stat(fixture.log)
        assert band(File.stat!(fixture.sessions).mode, 0o777) == 0o700

      {"empty_restoration", "restore"} ->
        assert File.read!(fixture.log) == fixture.original_log

      {"runs_unheld", "restore"} ->
        assert band(File.stat!(fixture.sessions).mode, 0o777) == 0o700
        assert File.read!(fixture.log) == fixture.original_log
    end
  end

  defp mutate_fixture!(fixture, "permission_denial", %{"command" => command})
       when command in ["degrade", "flap_degrade"] do
    assert :ok = File.chmod(fixture.sessions, 0o000)
  end

  defp mutate_fixture!(fixture, "permission_denial", %{"command" => command})
       when command in ["restore", "flap_restore"] do
    File.chmod!(fixture.sessions, 0o700)
  end

  defp mutate_fixture!(fixture, "removal", %{"command" => "degrade"}) do
    assert {:ok, _removed} = File.rm_rf(fixture.sessions)
  end

  defp mutate_fixture!(fixture, "removal", %{"command" => "restore"}) do
    File.mkdir_p!(fixture.sessions)
    File.chmod!(fixture.sessions, 0o700)
    File.write!(fixture.log, fixture.original_log)
  end

  defp mutate_fixture!(fixture, "corrupt_log", %{"command" => "degrade"}) do
    File.write!(fixture.log, "{corrupt\n")
  end

  defp mutate_fixture!(fixture, "corrupt_log", %{"command" => "restore"}) do
    File.chmod!(fixture.sessions, 0o700)
    File.write!(fixture.log, fixture.original_log)
  end

  defp mutate_fixture!(fixture, "empty_restoration", %{"command" => "prepare_empty"}) do
    File.rm!(fixture.log)
  end

  defp mutate_fixture!(fixture, "empty_restoration", %{"command" => "degrade"}) do
    assert :ok = File.chmod(fixture.sessions, 0o000)
  end

  defp mutate_fixture!(fixture, "empty_restoration", %{"command" => "restore_empty"}) do
    File.chmod!(fixture.sessions, 0o700)
  end

  defp mutate_fixture!(fixture, "empty_restoration", %{"command" => "restore"}) do
    File.chmod!(fixture.sessions, 0o700)
    File.write!(fixture.log, fixture.original_log)
  end

  defp mutate_fixture!(fixture, "runs_unheld", %{"command" => "restore"}) do
    File.chmod!(fixture.sessions, 0o700)
  end

  defp fixture_workspaces!(mode) do
    root = Path.join(System.tmp_dir!(), "pixir-monitor-set-browser-#{System.unique_integer([:positive])}")
    left = Path.join(root, "left")
    right = Path.join(root, "right")
    left_sessions = Path.join([left, ".pixir", "sessions"])
    right_sessions = Path.join([right, ".pixir", "sessions"])
    File.mkdir_p!(left_sessions)
    File.mkdir_p!(right_sessions)
    File.chmod!(left_sessions, 0o700)
    File.chmod!(right_sessions, 0o700)
    left_run = "20260716T000000-left"
    right_run = "20260716T000001-right"
    write_subagent_run!(left_sessions, left_run)
    write_subagent_run!(right_sessions, right_run)
    left_log = Path.join(left_sessions, left_run <> ".ndjson")
    original_log = File.read!(left_log)
    if mode == "runs_unheld", do: File.chmod!(left_sessions, 0o000)

    %{
      root: root,
      left: left,
      right: right,
      served_left: Path.expand(left),
      served_right: Path.expand(right),
      sessions: left_sessions,
      log: left_log,
      original_log: original_log,
      left_run: left_run,
      right_run: right_run,
      left_unit: "delegate:#{left_run}:subagent:subagent-one",
      right_unit: "delegate:#{right_run}:subagent:subagent-one"
    }
  end

  defp write_subagent_run!(sessions, run_id) do
    events = [
      subagent_event(run_id, 0, "2026-07-16T00:00:00Z", "started", "running"),
      subagent_event(run_id, 1, "2026-07-16T00:00:01Z", "finished", "completed")
    ]

    File.write!(Path.join(sessions, "#{run_id}.ndjson"), Enum.map_join(events, "", &(Jason.encode!(&1) <> "\n")))
  end

  defp subagent_event(run_id, seq, timestamp, lifecycle, status) do
    %{
      "id" => "event-#{run_id}-#{seq}",
      "session_id" => run_id,
      "seq" => seq,
      "ts" => timestamp,
      "type" => "subagent_event",
      "data" => %{
        "event" => lifecycle,
        "status" => status,
        "child_session_id" => "child-session",
        "subagent_id" => "subagent-one"
      }
    }
  end

  defp assert_bounded_cleanup!(root, profiles_before, browser_helpers_before, cleanup) do
    assert cleanup == %{
             "browser_stopped" => true,
             "monitor_stopped" => true,
             "profile_removed" => true
           }

    profiles_after =
      Path.wildcard(Path.join(root, "pixir-monitor-workspace-set-browser-*"))
      |> MapSet.new()

    assert MapSet.difference(profiles_after, profiles_before) == MapSet.new()
    {processes, 0} = System.cmd(System.find_executable("ps"), ["-axo", "command="])
    refute Enum.any?(String.split(processes, "\n"), &(&1 =~ @escript and &1 =~ root))
    assert MapSet.subset?(browser_profile_processes(root), browser_helpers_before)
  end

  defp browser_profile_processes(root) do
    {processes, 0} = System.cmd(System.find_executable("ps"), ["-axo", "command="])

    processes
    |> String.split("\n")
    |> Enum.filter(&String.contains?(&1, root))
    |> MapSet.new()
  end
end
