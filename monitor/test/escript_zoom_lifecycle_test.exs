unless Code.ensure_loaded?(PixirMonitor.FixtureWorkspace) do
  Code.require_file("support/fixture_workspace.ex", __DIR__)
end

unless Code.ensure_loaded?(PixirMonitor.SemanticZoomFixture) do
  Code.require_file("support/semantic_zoom_fixture.ex", __DIR__)
end

unless Code.ensure_loaded?(PixirMonitor.SemanticZoomReadModel) do
  Code.require_file("support/semantic_zoom_read_model.ex", __DIR__)
end

defmodule PixirMonitor.EscriptZoomLifecycleTest do
  use ExUnit.Case, async: false

  alias PixirMonitor.Projection.Builder
  alias PixirMonitor.SemanticZoomFixture
  alias PixirMonitor.SemanticZoomReadModel

  @project_root Path.expand("..", __DIR__)
  @escript Path.join(@project_root, "pixir-monitor")
  @harness Path.join(__DIR__, "support/zoom_lifecycle_browser_harness.mjs")
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

  @checkpoints ~w(serve_boot expand_state sse_lands_on_expansion selection_clamp_honesty)

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

  @tag skip: @browser_skip
  @tag timeout: 240_000
  test "authoritative SSE refetch preserves then honestly clamps semantic zoom state" do
    root =
      Path.join(
        System.tmp_dir!(),
        "pixir-monitor-escript-zoom-lifecycle-#{System.unique_integer([:positive])}"
      )

    workspace = Path.join(root, "workspace")
    File.mkdir_p!(workspace)
    run_id = PixirMonitor.FixtureWorkspace.materialize!(SemanticZoomFixture.input(), workspace)
    log = Path.join([workspace, ".pixir", "sessions", run_id <> ".ndjson"])
    profiles_before = Path.wildcard(Path.join(root, "pixir-monitor-zoom-lifecycle-*")) |> MapSet.new()
    on_exit(fn -> File.rm_rf!(root) end)

    {result, status} = run_harness!(root, workspace, run_id, log)

    assert status == 0, "zoom lifecycle browser harness failed: #{inspect(result)}"
    assert result["ok"] == true
    assert result["check"] == "pixir_monitor_zoom_lifecycle"
    assert result["phases"] == @checkpoints
    assert result["navigation_entries"] == 1
    assert result["fresh_receipt"] == true
    assert result["selection_preserved"] == true
    assert result["zoom_window_preserved"] == true
    assert result["member_page_preserved"] == true
    assert result["disclosures_preserved"] == true
    assert result["selection_clamped"] == true
    assert result["stale_member_rows"] == 0
    assert result["launch_fragment_cleared"] == true
    assert result["handoff_cleaned"] == true

    assert result["cleanup"] == %{
             "browser_stopped" => true,
             "monitor_stopped" => true,
             "profile_removed" => true
           }

    profiles_after = Path.wildcard(Path.join(root, "pixir-monitor-zoom-lifecycle-*")) |> MapSet.new()
    assert MapSet.difference(profiles_after, profiles_before) == MapSet.new()
  end

  defp run_harness!(root, workspace, run_id, log) do
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
          "zoom-lifecycle-browser-e2e",
          stderr_path,
          @node,
          @harness,
          "--monitor",
          @escript,
          "--workspace",
          workspace,
          "--run-id",
          run_id,
          "--log",
          log,
          "--browser",
          @browser,
          "--profile-base",
          root,
          "--json"
        ]
      ])

    on_exit(fn -> close_port(port) end)
    deadline = System.monotonic_time(:millisecond) + 210_000

    try do
      {output, status, handled} = drive!(port, stderr_path, workspace, log, MapSet.new(), "", deadline, 0)

      assert handled == MapSet.new(@checkpoints),
             "missing zoom lifecycle checkpoints: #{inspect(MapSet.difference(MapSet.new(@checkpoints), handled))}"

      result = output |> String.split("\n", trim: true) |> List.last() |> Jason.decode!()
      {result, status}
    rescue
      error ->
        drain(port, System.monotonic_time(:millisecond) + 10_000)
        reraise error, __STACKTRACE__
    end
  end

  defp drive!(port, stderr_path, workspace, log, handled, output, deadline, consumed) do
    assert System.monotonic_time(:millisecond) < deadline,
           "zoom lifecycle harness exceeded its 210 second driver deadline"

    lines = complete_json_lines(stderr_path)

    handled =
      lines
      |> Enum.drop(consumed)
      |> Enum.reduce(handled, fn line, seen ->
        prompt = Jason.decode!(line)
        checkpoint = prompt["checkpoint"]
        phase = prompt["phase"]

        refute MapSet.member?(seen, phase),
               "harness re-emitted an already-handled zoom lifecycle checkpoint phase: #{phase}"

        assert phase in @checkpoints
        assert checkpoint == Enum.find_index(@checkpoints, &(&1 == phase)) + 1
        assert prompt["servedWorkspace"] == Path.expand(workspace)

        clamp_expectation = verify_and_apply!(workspace, log, prompt)
        acknowledge(port, prompt, clamp_expectation)
        MapSet.put(seen, phase)
      end)

    consumed = length(lines)

    receive do
      {^port, {:data, bytes}} ->
        drive!(port, stderr_path, workspace, log, handled, output <> bytes, deadline, consumed)

      {^port, {:exit_status, status}} ->
        {output, status, handled}
    after
      25 -> drive!(port, stderr_path, workspace, log, handled, output, deadline, consumed)
    end
  end

  defp verify_and_apply!(workspace, log, %{"phase" => "serve_boot", "runId" => run_id}) do
    assert File.regular?(log)
    assert Path.basename(log, ".ndjson") == run_id
    assert [log] == Path.wildcard(Path.join([workspace, ".pixir", "sessions", "*.ndjson"]))
  end

  defp verify_and_apply!(_workspace, log, %{
         "phase" => "expand_state",
         "logSize" => log_size,
         "selectedCluster" => "wave:0:bucket:0",
         "memberPage" => 2
       }) do
    assert File.stat!(log).size == log_size
  end

  defp verify_and_apply!(_workspace, log, %{
         "phase" => "sse_lands_on_expansion",
         "beforeSize" => before_size,
         "beforeSeq" => before_seq
       }) do
    assert File.stat!(log).size == before_size
    assert max_seq!(log) == before_seq
    next_seq = before_seq + 1

    event = %{
      "id" => "event-20260715T000000-a1b2c3-#{next_seq}",
      "session_id" => "20260715T000000-a1b2c3",
      "seq" => next_seq,
      "ts" => "2026-07-16T00:05:00Z",
      "type" => "workflow_event",
      "data" => %{
        "kind" => "checkpoint_decided",
        "workflow_id" => "semantic-zoom-100",
        "step_id" => "wave-3-unit-09",
        "checkpoint_status" => "checkpoint_ready",
        "dependent_safe" => true
      }
    }

    File.write!(log, Jason.encode!(event) <> "\n", [:append])
    assert max_seq!(log) == next_seq
    assert File.stat!(log).size > before_size
  end

  defp verify_and_apply!(_workspace, log, %{
         "phase" => "selection_clamp_honesty",
         "selectedCluster" => selected_cluster,
         "memberPage" => 2,
         "logSize" => log_size
       }) do
    # NO mutation: the Log is append-only truth and a rewrite would model a
    # transition production cannot produce. The clamp is exercised through a
    # REAL reachable path instead — an overshooting deep link (members=99) on
    # the unchanged store — and this driver only derives the read-model
    # expectation for it. The store must be byte-identical to what the SSE
    # phase left behind.
    assert File.stat!(log).size == log_size

    {:ok, projection} = Builder.build(SemanticZoomFixture.input())
    window = SemanticZoomReadModel.materialize_window(projection, 0)
    selected_entity = Enum.find(window.entities, &(&1.key == selected_cluster))
    assert selected_entity, "fixture no longer contains #{selected_cluster}"

    page_size = 12
    members = selected_entity.members
    max_page = div(length(members) + page_size - 1, page_size)

    assert max_page >= 2,
           "fixture cluster no longer paginates (#{length(members)} members); the clamp phase would be vacuous"

    # Member pages are CUMULATIVE (page P shows the first P x 12 members), so
    # the clamped last page shows every member in oracle order.
    %{
      "selected_cluster" => selected_entity.key,
      "member_page_max" => max_page,
      "visible_member_ids" => Enum.take(members, max_page * page_size)
    }
  end

  defp max_seq!(log) do
    log
    |> File.stream!(:line)
    |> Enum.map(fn line -> Jason.decode!(line)["seq"] end)
    |> Enum.max()
  end

  defp acknowledge(port, prompt, clamp_expectation) do
    acknowledgement = %{
      phase: prompt["phase"],
      checkpoint: prompt["checkpoint"],
      post_state: "verified"
    }

    acknowledgement =
      if is_map(clamp_expectation),
        do: Map.put(acknowledgement, :clamp_expectation, clamp_expectation),
        else: acknowledgement

    true = Port.command(port, Jason.encode!(acknowledgement) <> "\n")

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
