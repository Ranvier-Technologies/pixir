unless Code.ensure_loaded?(PixirMonitor.FixtureWorkspace) do
  Code.require_file("support/fixture_workspace.ex", __DIR__)
end

unless Code.ensure_loaded?(PixirMonitor.SemanticZoomFixture) do
  Code.require_file("support/semantic_zoom_fixture.ex", __DIR__)
end

unless Code.ensure_loaded?(PixirMonitor.SemanticZoomReadModel) do
  Code.require_file("support/semantic_zoom_read_model.ex", __DIR__)
end

defmodule PixirMonitor.EscriptMalformedScaleTest do
  use ExUnit.Case, async: false

  alias PixirMonitor.Projection.Builder
  alias PixirMonitor.SemanticZoomFixture
  alias PixirMonitor.SemanticZoomReadModel

  @project_root Path.expand("..", __DIR__)
  @escript Path.join(@project_root, "pixir-monitor")
  @harness Path.join(__DIR__, "support/malformed_scale_browser_harness.mjs")
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
  @tag timeout: 300_000
  test "malformed fields remain bounded, inert, confessed, and outside semantic ordering" do
    workspace =
      Path.join(
        System.tmp_dir!(),
        "pixir-monitor-escript-malformed-scale-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf!(workspace) end)

    input = SemanticZoomFixture.malformed_input_500()
    run_id = PixirMonitor.FixtureWorkspace.materialize!(input, workspace)

    # The oracle must be derived from the SERVED round-trip (materialize ->
    # fetch_input), not the in-memory fixture: materialization only persists
    # the parent log, so in-memory-only inputs (runtime diagnostics, owner
    # state, the seeded envelope) never reach the escript and their
    # confessions cannot appear in the rendered copy the harness checks.
    assert {:ok, served_input} =
             PixirMonitor.Projection.Source.Filesystem.fetch_input(run_id, workspace: workspace)

    assert {:ok, projection} = Builder.build(served_input)
    oracle = ordering_oracle(projection)
    assert length(oracle["malformed_units"]) == 13
    oracle_path = Path.join(workspace, "malformed-scale-oracle.json")
    File.write!(oracle_path, Jason.encode!(oracle))

    {output, status} =
      System.cmd(
        @node,
        [
          @harness,
          "--monitor",
          @escript,
          "--workspace",
          workspace,
          "--browser",
          @browser,
          "--profile-base",
          System.tmp_dir!(),
          "--run-id",
          run_id,
          "--oracle-file",
          oracle_path,
          "--browser-timeout-ms",
          "60000",
          "--json"
        ],
        stderr_to_stdout: true
      )

    assert status == 0, "malformed scale browser harness failed: #{output}"
    result = output |> String.split("\n", trim: true) |> List.last() |> Jason.decode!()

    assert result["ok"] == true
    assert result["check"] == "pixir_monitor_malformed_scale"
    assert result["windows_checked"] == [0, 6, 12]
    assert result["malformed_units_checked"] == 13
    assert result["ordering_matches_read_model"] == true
    assert result["malformed_values_inert"] == true
    assert result["projection_limitations_present"] == true
    assert result["source_aggregate_limitation_visible"] == true
    max_window_entities = oracle["windows"] |> Enum.map(& &1["entity_count"]) |> Enum.max()
    assert result["maximum_cluster_cards"] == max_window_entities
    assert result["maximum_unit_cards"] < 500
    assert result["console_security_errors"] == 0
    assert result["launch_fragment_cleared"] == true
    assert result["handoff_cleaned"] == true

    assert result["cleanup"] == %{
             "browser_stopped" => true,
             "monitor_stopped" => true,
             "profile_removed" => true
           }
  end

  defp ordering_oracle(projection) do
    windows =
      Enum.map([0, 6, 12], fn start ->
        window = SemanticZoomReadModel.materialize_window(projection, start)

        %{
          "start" => start,
          # Every window entity (clusters plus boundary/overflow markers) renders
          # as one card, so the DOM bound is the full entity count.
          "entity_count" => length(window.entities),
          "clusters" =>
            window.entities
            |> Enum.filter(&(&1.kind == :cluster))
            |> Enum.map(fn entity ->
              %{"key" => entity.key, "members" => entity.members}
            end)
        }
      end)

    malformed_units =
      projection["units"]
      |> Enum.filter(fn unit ->
        Enum.any?(unit["limitations"] || [], &String.starts_with?(to_string(&1), "unknown_enum:"))
      end)
      |> Enum.map(fn unit ->
        limitations = Enum.map(unit["limitations"] || [], &to_string/1)

        assert unit["execution_kind"] == "unknown"
        assert unit["workspace_mode"] == "unknown"
        assert unit["posture"] == "unknown"
        assert "unknown_enum:execution_kind:future_execution_kind" in limitations
        assert "unknown_enum:workspace_mode:future_workspace_mode" in limitations
        assert "unknown_enum:posture:future_posture" in limitations

        %{
          "logical_id" => unit["logical_id"],
          "execution_kind" => unit["execution_kind"],
          "workspace_mode" => unit["workspace_mode"],
          "posture" => unit["posture"],
          "limitations" => limitations,
          "raw_unknown_values" =>
            limitations
            |> Enum.filter(&String.starts_with?(&1, "unknown_enum:"))
            |> Enum.map(&(&1 |> String.split(":") |> List.last())),
          "attempts" =>
            Enum.map(unit["attempts"] || [], fn attempt ->
              attempt_limitations = Enum.map(attempt["limitations"] || [], &to_string/1)
              assert is_nil(attempt["started_at"])
              assert is_nil(attempt["ended_at"])
              assert Enum.any?(attempt_limitations, &String.starts_with?(&1, "malformed_timestamp:started_at:malformed-timestamp-for-"))
              assert Enum.any?(attempt_limitations, &String.starts_with?(&1, "malformed_timestamp:ended_at:malformed-timestamp-for-"))

              %{
                "attempt_id" => attempt["attempt_id"],
                "started_at" => attempt["started_at"],
                "ended_at" => attempt["ended_at"],
                "limitations" => attempt_limitations
              }
            end)
        }
      end)

    source_limitations = Enum.map(projection["source"]["limitations"] || [], &to_string/1)
    assert "malformed_event_timestamps:39" in source_limitations

    %{
      "windows" => windows,
      "malformed_units" => malformed_units,
      "source_limitations" => source_limitations
    }
  end
end
