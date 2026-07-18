defmodule PixirMonitor.AccessibilityGauntletTest do
  use ExUnit.Case, async: false

  @moduledoc """
  Collects the issue #341 AC2 accessibility evidence matrix from a real browser
  for F1 detail/unit, F2 semantic zoom, and F3 Workspace Overview.
  """

  @project_root Path.expand("..", __DIR__)
  @escript Path.join(@project_root, "pixir-monitor")
  @harness Path.join(__DIR__, "support/accessibility_harness.mjs")
  @emitter Path.join(@project_root, "bench/emit_fixture_workspace.exs")
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

  @hostile_agent "<script data-pixir-a11y-hostile>window.__pixirA11yInjected=true</script>" <>
                   "&lt;hostile&gt;&amp;&#x202E;" <>
                   "right-to-left-override:\u202Epayload" <>
                   "cap:" <> String.duplicate("Z", 32_700)

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

  # The complete keyboard path per frontier. Pinning the check NAMES (not just
  # ok/hard_failures) is what makes this a gate instead of a recorder: an
  # early-returned "audited" path produces different check names and fails here,
  # so a keyboard regression cannot ride out as a recorded limitation.
  @keyboard_checks %{
    "f1" => [
      "runs_link_reachable_by_tab",
      "enter_changes_route_to_detail",
      "unit_group_summary_reachable_by_tab",
      "fanout_group_expanded_by_enter",
      "unit_link_reachable_by_tab",
      "enter_changes_route_to_unit",
      "escape_dispatched_without_navigation"
    ],
    "f2" => [
      "cluster_link_reachable_by_tab",
      "enter_changes_route_to_cluster",
      "deep_link_unmaterialized_member_renders",
      "back_run_returns_to_first_member_page_with_target_absent",
      "members_next_advances_to_second_member_page",
      "member_link_returns_to_deep_link_with_second_page_state",
      "escape_dispatched_without_navigation"
    ],
    "f3" => [
      "left_source_degradation_rendered_before_tab",
      "source_retry_reachable_by_tab",
      "retry_activated_by_enter",
      "remaining_runs_expansion_reachable_by_tab",
      "remaining_runs_expanded_by_enter",
      "overview_source_card_link_reachable_by_tab",
      "enter_changes_route_from_overview",
      "escape_dispatched_without_navigation"
    ]
  }

  @hostile_checks %{
    "f1" => [
      "hostile_script_rendered_as_text",
      "entities_rendered_as_literal_text",
      "rtl_override_made_visible",
      "near_cap_field_rendered",
      "no_injected_element"
    ],
    "f2" => [
      "hostile_script_rendered_as_text",
      "entities_rendered_as_literal_text",
      "rtl_override_made_visible",
      "near_cap_field_rendered",
      "no_injected_element"
    ],
    "f3" => [
      "hostile_script_rendered_as_text",
      "entities_rendered_as_literal_text",
      "rtl_override_made_visible",
      "near_cap_field_rendered",
      "no_injected_element",
      "right_hostile_script_rendered_as_text",
      "right_entities_rendered_as_literal_text",
      "right_rtl_override_made_visible",
      "right_near_cap_field_rendered",
      "right_no_injected_element"
    ]
  }

  # Any limitation kind outside this set fails the suite loudly instead of
  # riding out as a recorded observation: keyboard limitations, unreachable
  # controls, residual motion, and real contrast shortfalls are regressions.
  @allowed_limitation_kinds MapSet.new([
                              "visual_clipping_observed",
                              "contrast_not_computable"
                            ])

  @tag skip: @browser_skip
  # Three browser-real frontiers plus fixture emission; shared hosts showed
  # identical-work runs spreading 27s..303s, so the budget absorbs that variance.
  @tag timeout: 480_000
  test "records the complete accessibility matrix for F1, F2, and F3" do
    root = fixture_root!()
    profiles_before = Path.wildcard(Path.join(System.tmp_dir!(), "pixir-monitor-a11y-*")) |> MapSet.new()

    on_exit(fn ->
      # A brutal ExUnit timeout cannot kill the System.cmd child tree, so reap
      # any harness/monitor still holding the unique fixture root. A Chrome
      # orphan is still possible on that path (its profile dir is not under the
      # root); the leak assertion below is what surfaces it.
      System.cmd("pkill", ["-f", root], stderr_to_stdout: true)
      File.rm_rf!(root)
    end)

    f1 = small_workspace!(Path.join(root, "f1"), "20260720T000000-a11yf1")
    f2 = semantic_zoom_workspace!(Path.join(root, "f2"))
    left = small_workspace!(Path.join(root, "left"), "20260720T000001-a11yleft")
    right = small_workspace!(Path.join(root, "right"), "20260720T000002-a11yright")

    evidence = [
      run_harness!("f1", workspace: f1.workspace, run_id: f1.run_id, unit_id: f1.unit_id),
      run_harness!("f2", workspace: f2.workspace, run_id: f2.run_id, unit_id: f2.unit_id),
      run_harness!("f3",
        left_workspace: left.workspace,
        right_workspace: right.workspace,
        run_id: left.run_id,
        unit_id: left.unit_id,
        right_run_id: right.run_id,
        right_unit_id: right.unit_id
      )
    ]

    Enum.each(evidence, fn result ->
      IO.puts(Jason.encode!(%{"accessibility_evidence" => result}))
      assert result["ok"] == true
      assert result["check"] == "pixir_monitor_accessibility_gauntlet"
      assert result["hard_failures"] == []
      assert result["launch_fragment_cleared"] == true
      assert result["handoff_cleaned"] == true

      assert result["cleanup"] == %{
               "browser_stopped" => true,
               "monitor_stopped" => true,
               "profile_removed" => true
             }

      assert Enum.map(result["phases"], & &1["phase"]) == [
               "keyboard_traversal",
               "ax_tree",
               "zoom_200",
               "narrow_viewport",
               "reduced_motion",
               "contrast",
               "hostile_text"
             ]

      assert Enum.all?(result["phases"], fn phase ->
               is_list(phase["checks"]) and is_map(phase["observations"]) and
                 is_list(phase["limitations"])
             end)

      ax_tree = Enum.find(result["phases"], &(&1["phase"] == "ax_tree"))
      landmarks = get_in(ax_tree, ["observations", "landmarks"])

      assert is_list(landmarks) and
               Enum.any?(landmarks, fn landmark ->
                 landmark["role"] == "main" and landmark["name"] == "Pixir Monitor"
               end),
             "accessibility frontier #{result["frontier"]} did not observe the named Pixir Monitor main landmark"

      keyboard = Enum.find(result["phases"], &(&1["phase"] == "keyboard_traversal"))
      assert Enum.map(keyboard["checks"], & &1["name"]) == @keyboard_checks[result["frontier"]]

      hostile = Enum.find(result["phases"], &(&1["phase"] == "hostile_text"))
      assert Enum.map(hostile["checks"], & &1["name"]) == @hostile_checks[result["frontier"]]

      contrast = Enum.find(result["phases"], &(&1["phase"] == "contrast"))
      measured = Enum.filter(contrast["observations"]["samples"], &is_number(&1["ratio"]))
      assert Enum.all?(measured, &(&1["ratio"] >= &1["threshold"]))

      # F1 requires truth_marker_text and truth_marker_tone. F2 requires those
      # two kinds plus cluster_card_heading, cluster_key_tile,
      # cluster_summary_row, cluster_distribution_row, aggregate_arcs_heading,
      # aggregate_arcs_link, and cluster_inspector_heading. F3 requires the
      # Overview kinds listed in its branch below.
      measured_kinds = measured |> Enum.map(& &1["kind"]) |> MapSet.new()

      case result["frontier"] do
        "f1" ->
          assert MapSet.subset?(
                   MapSet.new(["truth_marker_text", "truth_marker_tone"]),
                   measured_kinds
                 )

        "f2" ->
          # The 100-unit semantic-zoom fixture guarantees clusters with inspect
          # links, aggregate arcs, and an inspector after the guarded cluster click.
          # A fixture change that removes one of those structures must fail this set.
          assert MapSet.subset?(
                   MapSet.new([
                     "truth_marker_text",
                     "truth_marker_tone",
                     "cluster_card_heading",
                     "cluster_key_tile",
                     "cluster_summary_row",
                     "cluster_distribution_row",
                     "aggregate_arcs_heading",
                     "aggregate_arcs_link",
                     "cluster_inspector_heading"
                   ]),
                   measured_kinds
                 )

        "f3" ->
          assert MapSet.subset?(
                   MapSet.new([
                     "workspace_source_card",
                     "source_error_banner",
                     "stale_disclosure_banner",
                     "source_retry_control",
                     "source_stats_row",
                     "source_stat_value",
                     "source_stats_receipt",
                     "source_evidence_disclosure",
                     "source_attention_region",
                     "source_runs_region",
                     "remaining_runs_disclosure"
                   ]),
                   measured_kinds
                 )
      end

      assert is_list(result["recorded_limitations"])

      observed_kinds = result["recorded_limitations"] |> Enum.map(& &1["kind"]) |> MapSet.new()
      assert MapSet.subset?(observed_kinds, @allowed_limitation_kinds)

      for limitation <- result["recorded_limitations"] do
        case limitation["kind"] do
          # Only the app's radial-gradient background is accepted as
          # not-computable, and ONLY for the primary-text surface; a marker
          # gaining a background image (or an unparsable oklch/color()/
          # transparent foreground, or no opaque ancestor) must fail, or the
          # allowlist could zero out marker contrast measurement while green.
          "contrast_not_computable" ->
            assert limitation["reason"] == "background_image"
            assert limitation["surface"] == "primary_text"

          _ ->
            :ok
        end
      end

      assert is_map(result["host"])
      refute Map.has_key?(result["host"], "username")
      refute Map.has_key?(result["host"], "path")
    end)

    assert Enum.map(evidence, & &1["frontier"]) == ["f1", "f2", "f3"]
    assert Path.wildcard(Path.join(System.tmp_dir!(), "pixir-monitor-a11y-*")) |> MapSet.new() == profiles_before
  end

  defp run_harness!(frontier, options) do
    common = [
      @harness,
      "--monitor",
      @escript,
      "--browser",
      @browser,
      "--frontier",
      frontier,
      "--run-id",
      Keyword.fetch!(options, :run_id),
      "--unit-id",
      Keyword.fetch!(options, :unit_id),
      "--json"
    ]

    workspace_args =
      if frontier == "f3" do
        [
          "--left-workspace",
          Keyword.fetch!(options, :left_workspace),
          "--right-workspace",
          Keyword.fetch!(options, :right_workspace),
          "--right-run-id",
          Keyword.fetch!(options, :right_run_id),
          "--right-unit-id",
          Keyword.fetch!(options, :right_unit_id)
        ]
      else
        ["--workspace", Keyword.fetch!(options, :workspace)]
      end

    {output, status} = System.cmd(@node, common ++ workspace_args, stderr_to_stdout: true)
    assert status == 0, "accessibility harness #{frontier} failed: #{output}"
    # stderr is merged into stdout; the evidence record is the last JSON line.
    output |> String.split("\n", trim: true) |> List.last() |> Jason.decode!()
  end

  defp fixture_root! do
    path =
      Path.join(
        System.tmp_dir!(),
        "pixir-monitor-accessibility-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(path)
    path
  end

  defp small_workspace!(workspace, run_id) do
    sessions = Path.join([workspace, ".pixir", "sessions"])
    File.mkdir_p!(sessions)

    events = [
      subagent_event(run_id, 0, "2026-07-20T00:00:00Z", "started", "running", @hostile_agent),
      subagent_event(run_id, 1, "2026-07-20T00:00:01Z", "finished", "completed", nil)
    ]

    File.write!(
      Path.join(sessions, run_id <> ".ndjson"),
      Enum.map_join(events, "", &(Jason.encode!(&1) <> "\n"))
    )

    %{
      workspace: workspace,
      run_id: run_id,
      unit_id: "delegate:#{run_id}:subagent:subagent-one"
    }
  end

  defp subagent_event(run_id, seq, timestamp, lifecycle, status, agent) do
    data = %{
      "event" => lifecycle,
      "status" => status,
      "child_session_id" => "child-session",
      "subagent_id" => "subagent-one"
    }

    data = if is_binary(agent), do: Map.put(data, "agent", agent), else: data

    %{
      "id" => "event-#{run_id}-#{seq}",
      "session_id" => run_id,
      "seq" => seq,
      "ts" => timestamp,
      "type" => "subagent_event",
      "data" => data
    }
  end

  defp semantic_zoom_workspace!(workspace) do
    {output, status} =
      System.cmd(
        "mix",
        ["run", "--no-start", @emitter, "--", "--fixture", "100", "--out", workspace],
        cd: @project_root,
        stderr_to_stdout: true
      )

    assert status == 0, "semantic zoom fixture emitter failed: #{output}"
    emitted = output |> String.split("\n", trim: true) |> List.last() |> Jason.decode!()
    run_id = emitted["run_id"]
    log = Path.join([workspace, ".pixir", "sessions", run_id <> ".ndjson"])

    rewritten =
      log
      |> File.stream!([], :line)
      |> Enum.map_join("", fn line ->
        line
        |> Jason.decode!()
        |> inject_semantic_hostile_label()
        |> Jason.encode!()
        |> Kernel.<>("\n")
      end)

    File.write!(log, rewritten)
    %{workspace: workspace, run_id: run_id, unit_id: "resolved-from-current-cluster-markup"}
  end

  defp inject_semantic_hostile_label(event) do
    event =
      case get_in(event, ["data", "graph", "steps"]) do
        [first | rest] ->
          put_in(
            event,
            ["data", "graph", "steps"],
            [Map.put(first, "agent", @hostile_agent) | rest]
          )

        _ ->
          event
      end

    step_id =
      get_in(event, ["data", "delegation_context", "step_id"]) ||
        get_in(event, ["data", "step_id"])

    if get_in(event, ["data", "event"]) == "started" and step_id == "wave-0-unit-00" do
      put_in(event, ["data", "agent"], @hostile_agent)
    else
      event
    end
  end
end
