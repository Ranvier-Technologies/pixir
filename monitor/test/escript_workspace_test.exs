defmodule PixirMonitor.EscriptWorkspaceTest do
  use ExUnit.Case, async: false

  @moduledoc """
  Proves the BUILT escript resolves the workspace at invocation time: launched from
  a foreign cwd it must report that cwd (never the build-time directory), an explicit
  --workspace must win over the invocation cwd, and workspace failures must be
  structured JSON errors emitted before any launch. The real-browser case uses the
  bounded CDP harness to traverse Runs, Detail, and Unit without placing launch
  capability bytes in process argv or test output.
  """

  @project_root Path.expand("..", __DIR__)
  @escript Path.join(@project_root, "pixir-monitor")
  @browser_harness Path.join(__DIR__, "support/browser_harness.mjs")
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
    # The enclosing suite runs under MIX_ENV=test, whose Endpoint is deliberately
    # disabled. Build the operator artifact in its normal dev environment so this
    # E2E exercises a real loopback listener rather than the test application spec.
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

  defp foreign_dir! do
    path = Path.join(System.tmp_dir!(), "pixir-monitor-foreign-#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end

  defp realpath!(path) do
    {:ok, original} = File.cwd()
    File.cd!(path)
    resolved = File.cwd!()
    File.cd!(original)
    resolved
  end

  test "built escript launched from a foreign cwd defaults to that invocation cwd" do
    foreign = foreign_dir!()

    {output, 0} = System.cmd(@escript, ["serve", "--dry-run", "--json"], cd: foreign)
    plan = Jason.decode!(output)

    assert plan["workspace"]["origin"] == "invocation_cwd"
    assert plan["workspace"]["path"] == realpath!(foreign)
    refute plan["workspace"]["path"] == @project_root
  end

  test "built escript honors explicit --workspace over the invocation cwd" do
    invocation = foreign_dir!()
    explicit = foreign_dir!()

    {output, 0} = System.cmd(@escript, ["serve", "--dry-run", "--json", "--workspace", explicit], cd: invocation)
    plan = Jason.decode!(output)

    assert plan["workspace"]["origin"] == "cli"
    assert plan["workspace"]["path"] == Path.expand(explicit)
  end

  test "built escript fails structurally on a missing workspace before any launch" do
    invocation = foreign_dir!()
    missing = Path.join(invocation, "does-not-exist")

    {output, 1} = System.cmd(@escript, ["serve", "--json", "--workspace", missing], cd: invocation, stderr_to_stdout: true)
    error = Jason.decode!(output)["error"]

    assert error["kind"] == "workspace_missing"
    assert Enum.any?(error["next_actions"], &(&1 =~ "--workspace"))
  end

  test "built escript help documents --workspace" do
    {output, 0} = System.cmd(@escript, ["--help"], cd: foreign_dir!())
    assert output =~ "--workspace PATH"
  end

  test "readiness polling waits for a newline-terminated JSON record" do
    path = Path.join(foreign_dir!(), "pixir-monitor.stderr")
    File.write!(path, ~s({"status":))

    writer =
      Task.async(fn ->
        Process.sleep(50)
        File.write!(path, ~s("ready"}\n), [:append])
      end)

    assert %{"status" => "ready"} = await_json_file!(path)
    Task.await(writer)
  end

  test "built escript applies explicit workspace before application startup" do
    workspace = foreign_dir!()
    invocation = foreign_dir!()
    stderr_path = Path.join(invocation, "pixir-monitor.stderr")
    sessions = Path.join([workspace, ".pixir", "sessions"])
    File.mkdir_p!(sessions)
    run_id = "20260713T225900-deadbe"
    write_subagent_run!(sessions, run_id)
    shell = System.find_executable("sh")

    monitor =
      Port.open(
        {:spawn_executable, shell},
        [
          :binary,
          :exit_status,
          :use_stdio,
          {:line, 4_096},
          cd: invocation,
          args: [
            "-c",
            ~S|stderr="$1"; shift; exec "$@" 2>"$stderr"|,
            "pixir-monitor-e2e",
            stderr_path,
            @escript,
            "serve",
            "--workspace",
            workspace,
            "--launch-mode",
            "fifo",
            "--json"
          ]
        ]
      )

    try do
      readiness = await_json_file!(stderr_path)
      assert readiness["status"] == "ready"
      refute_receive {^monitor, {:data, _stdout_before_handoff}}, 100

      reader =
        Task.async(fn ->
          {url, 0} = System.cmd(System.find_executable("cat"), [readiness["fifo_path"]])
          String.trim(url)
        end)

      launch_url = Task.await(reader, 15_000)
      uri = URI.parse(launch_url)
      launch = String.replace_prefix(uri.fragment, "launch=", "")
      origin = "http://127.0.0.1:#{uri.port}"

      cookie = bootstrap!(origin, launch)
      runs = get_json!(origin <> "/api/runs", cookie)

      assert runs["inventory"]["total"] == 1
      assert runs["inventory"]["selected"] == 1
      assert [%{"id" => ^run_id}] = runs["runs"]

      detail = get_json!(origin <> "/api/runs/#{run_id}", cookie)
      assert detail["schema"] == "pixir.presenter.run"
      assert detail["schema_version"] == 1
      assert detail["run"]["id"] == run_id
      expected_unit_id = "delegate:#{run_id}:subagent:subagent-one"
      assert [%{"logical_id" => ^expected_unit_id}] = detail["units"]
      assert %{"ok" => true, "status" => "serving"} = await_stdout_json!(monitor)
    after
      close_port(monitor)
    end
  end

  @tag skip: @browser_skip
  test "built escript renders list, detail, and unit through a real browser" do
    workspace = foreign_dir!()
    sessions = Path.join([workspace, ".pixir", "sessions"])
    File.mkdir_p!(sessions)
    run_id = "20260713T225901-browser"
    unit_id = "delegate:#{run_id}:subagent:subagent-one"
    write_subagent_run!(sessions, run_id)
    profiles_before = Path.wildcard(Path.join(System.tmp_dir!(), "pixir-monitor-browser-*")) |> MapSet.new()
    browser_helpers_before = browser_profile_processes()

    {output, status} =
      System.cmd(
        @node,
        [
          @browser_harness,
          "--monitor",
          @escript,
          "--workspace",
          workspace,
          "--run-id",
          run_id,
          "--unit-id",
          unit_id,
          "--browser",
          @browser,
          "--json"
        ],
        stderr_to_stdout: true
      )

    assert status == 0, "real-browser Monitor regression failed: #{output}"
    result = Jason.decode!(output)
    assert result["ok"] == true
    assert result["check"] == "pixir_monitor_browser_story"
    assert result["launch_fragment_cleared"] == true
    assert result["runs_view"] == true
    assert result["detail_view"] == true
    assert result["unit_view"] == true
    assert result["follow_route_reload_history"] == true
    assert result["follow_refetch_restoration"] == true
    assert result["invalidation_only_refetch"] == true
    assert result["terminal_transition_visible"] == true
    assert result["unavailable_transition_visible"] == true
    assert result["missing_unit_honest"] == true
    assert result["identity_disappeared_visible"] == true
    assert result["identity_disappeared_recovered"] == true
    assert result["transient_failure_neutral"] == true
    assert result["same_run_missing_unit_honest"] == true
    assert result["same_run_navigation_from_neutral_cleared"] == true
    assert result["cross_run_navigation_after_identity_loss_cleared"] == true
    assert result["transient_failure_same_run_refetched"] == true
    assert result["cross_run_navigation_cleared"] == true
    assert result["cross_run_navigation_after_failure_cleared"] == true
    assert result["inflight_navigation_converged"] == true
    assert result["attempt_cards"] == 1
    assert result["render_failure_classified"] == true
    assert result["failure_renderer_fallback"] == true
    assert result["projection_unavailable"] == false
    assert result["handoff_cleaned"] == true

    assert_bounded_cleanup!(workspace, profiles_before, browser_helpers_before, result["cleanup"])
  end

  @tag skip: @browser_skip
  test "real-browser harness reaps children and removes its profile after failure" do
    workspace = foreign_dir!()
    sessions = Path.join([workspace, ".pixir", "sessions"])
    File.mkdir_p!(sessions)
    run_id = "20260713T225902-browser-failure"
    unit_id = "delegate:#{run_id}:subagent:subagent-one"
    write_subagent_run!(sessions, run_id)
    profiles_before = Path.wildcard(Path.join(System.tmp_dir!(), "pixir-monitor-browser-*")) |> MapSet.new()
    browser_helpers_before = browser_profile_processes()

    {output, status} =
      System.cmd(
        @node,
        [
          @browser_harness,
          "--monitor",
          @escript,
          "--workspace",
          workspace,
          "--run-id",
          run_id,
          "--unit-id",
          unit_id,
          "--browser",
          @browser,
          "--browser-timeout-ms",
          "2000",
          "--exercise-unit-timeout",
          "--json"
        ],
        stderr_to_stdout: true
      )

    assert status == 1
    result = Jason.decode!(output)
    assert result["ok"] == false
    assert get_in(result, ["error", "kind"]) == "browser_assertion_timeout"
    assert get_in(result, ["error", "details", "stage"]) == "unit_view"

    assert_bounded_cleanup!(
      workspace,
      profiles_before,
      browser_helpers_before,
      get_in(result, ["error", "details", "cleanup"])
    )
  end

  @tag skip: @browser_skip
  test "real-browser harness bounds a crashed CDP connection and still cleans up" do
    workspace = foreign_dir!()
    sessions = Path.join([workspace, ".pixir", "sessions"])
    File.mkdir_p!(sessions)
    run_id = "20260713T225903-browser-cdp-crash"
    unit_id = "delegate:#{run_id}:subagent:subagent-one"
    write_subagent_run!(sessions, run_id)
    profiles_before = Path.wildcard(Path.join(System.tmp_dir!(), "pixir-monitor-browser-*")) |> MapSet.new()
    browser_helpers_before = browser_profile_processes()

    {output, status} =
      System.cmd(
        @node,
        [
          @browser_harness,
          "--monitor",
          @escript,
          "--workspace",
          workspace,
          "--run-id",
          run_id,
          "--unit-id",
          unit_id,
          "--browser",
          @browser,
          "--exercise-cdp-crash",
          "--json"
        ],
        stderr_to_stdout: true
      )

    assert status == 1
    result = Jason.decode!(output)
    assert result["ok"] == false
    assert get_in(result, ["error", "kind"]) in ["devtools_connection_closed", "devtools_connection_failed"]

    assert_bounded_cleanup!(
      workspace,
      profiles_before,
      browser_helpers_before,
      get_in(result, ["error", "details", "cleanup"])
    )
  end

  defp assert_bounded_cleanup!(workspace, profiles_before, browser_helpers_before, cleanup) do
    assert cleanup == %{
             "browser_stopped" => true,
             "monitor_stopped" => true,
             "profile_removed" => true
           }

    assert Path.wildcard(Path.join(System.tmp_dir!(), "pixir-monitor-browser-*")) |> MapSet.new() == profiles_before
    {processes, 0} = System.cmd(System.find_executable("ps"), ["-axo", "command="])
    refute Enum.any?(String.split(processes, "\n"), &(&1 =~ @escript and &1 =~ workspace))
    assert MapSet.subset?(browser_profile_processes(), browser_helpers_before)
  end

  defp browser_profile_processes do
    {processes, 0} = System.cmd(System.find_executable("ps"), ["-axo", "command="])

    processes
    |> String.split("\n")
    |> Enum.filter(&String.contains?(&1, "pixir-monitor-browser-"))
    |> MapSet.new()
  end

  defp await_json_file!(path, attempts \\ 2_000)

  defp await_json_file!(path, attempts) when attempts > 0 do
    case File.read(path) do
      {:ok, bytes} ->
        case String.split(bytes, "\n", parts: 2) do
          [line, _rest] -> Jason.decode!(line)
          [_partial] -> retry_json_file!(path, attempts)
        end

      {:error, :enoent} ->
        retry_json_file!(path, attempts)

      {:error, reason} ->
        flunk("could not read pixir-monitor stderr: #{inspect(reason)}")
    end
  end

  defp await_json_file!(_path, 0), do: flunk("pixir-monitor did not emit readiness on stderr")

  defp retry_json_file!(path, attempts) do
    Process.sleep(10)
    await_json_file!(path, attempts - 1)
  end

  defp await_stdout_json!(port) do
    receive do
      {^port, {:data, {:eol, line}}} -> Jason.decode!(line)
      {^port, {:exit_status, status}} -> flunk("pixir-monitor exited before serving: #{status}")
    after
      5_000 -> flunk("pixir-monitor did not emit serving status on stdout")
    end
  end

  defp bootstrap!(origin, launch) do
    headers = [
      {~c"origin", String.to_charlist(origin)},
      {~c"sec-fetch-site", ~c"same-origin"}
    ]

    request = {
      String.to_charlist(origin <> "/bootstrap"),
      headers,
      ~c"application/json",
      Jason.encode!(%{launch: launch})
    }

    assert {:ok, {{_, 200, _}, response_headers, _body}} =
             :httpc.request(:post, request, [timeout: 5_000], body_format: :binary)

    response_headers
    |> Enum.find_value(fn {name, value} ->
      if String.downcase(to_string(name)) == "set-cookie", do: to_string(value)
    end)
    |> String.split(";", parts: 2)
    |> hd()
  end

  defp get_json!(url, cookie) do
    headers = [{~c"sec-fetch-site", ~c"same-origin"}, {~c"cookie", String.to_charlist(cookie)}]

    assert {:ok, {{_, 200, _}, _response_headers, body}} =
             :httpc.request(:get, {String.to_charlist(url), headers}, [timeout: 5_000], body_format: :binary)

    Jason.decode!(body)
  end

  defp write_subagent_run!(sessions, run_id) do
    events = [
      subagent_event(run_id, 0, "2026-07-13T22:59:00Z", "started", "running"),
      subagent_event(run_id, 1, "2026-07-13T22:59:01Z", "finished", "completed")
    ]

    body = Enum.map_join(events, "", &(Jason.encode!(&1) <> "\n"))
    File.write!(Path.join(sessions, "#{run_id}.ndjson"), body)
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

  defp close_port(port) do
    if Port.info(port) do
      case Port.info(port, :os_pid) do
        {:os_pid, os_pid} when is_integer(os_pid) and os_pid > 0 ->
          System.cmd(System.find_executable("kill"), ["-KILL", Integer.to_string(os_pid)])

        _ ->
          :ok
      end

      Port.close(port)
    end
  rescue
    ArgumentError -> :ok
  end
end
