defmodule PixirMonitor.EscriptManualRouteTest do
  use ExUnit.Case, async: false

  @moduledoc """
  Real-browser behavioural proof of the instrument-manual ROUTE FAMILY (#551).

  Two tiers already speak about this family and neither drives a browser.
  `test/ui/manual_pane_contract_test.exs` greps the bundle SOURCE, so it can
  pin that a branch is written but never that it is reached.
  `test/ui/manual_overlay_preservation_test.exs` executes the fast-path seam in
  node:vm against a minimal DOM, so it proves the seam's logic but never a real
  hashchange, a real history stack, a real render loop, or a real fetch. This
  suite closes that gap: real Chrome over CDP, real navigation, and the app's
  own recorded fetches as the evidence for the no-refetch claim.

  WHAT IT DELIBERATELY DOES NOT COVER. The Escape legs of the manual are
  already pinned per-frontier by `test/accessibility_gauntlet_test.exs`:
  `escape_dispatched_without_navigation`, `manual_pane_opens_for_escape_contract`,
  `escape_closes_open_manual_pane` and `escape_close_preserves_underlying_route`
  run on f1, f2 and f3 and are asserted there by NAME. Re-driving them here
  would duplicate a gate rather than add evidence. This suite drives the OTHER
  exit instead — the Close control the pane renders — which the gauntlet does
  not exercise, and asserts the same route-preservation property from it.

  THE DEEP-LINK SHAPE, and why it is a hash navigation rather than a page load.
  `#manual/<slug>` cannot be a document-load URL in this architecture: the
  launch capability is one-use, and the shell bootstrap replaceStates the whole
  fragment away before the app bundle loads (`lib/pixir_monitor/bootstrap.ex`).
  The reachable production shape is the identity pasted into an already-open
  Monitor, which is what the harness drives. It drives it from a NON-DEFAULT
  route on purpose: with a run detail painted, a deep link that merely "kept the
  current route and opened a pane" would land on the detail and still look
  correct. Only the parseRoute intercept produces the default view, so entering
  from the detail is what makes the leg bite.

  PROVEN TO BITE. A gate that has never been observed failing is a recorder, so
  each leg was driven against a REBUILT bundle carrying one surgical tamper, on
  this base, and required to go red on its own leg:

    * parseRoute's `segments[0] === "manual"` intercept disabled -> the deep
      link falls through and the pane never opens ->
      `deep_link_resolves_to_default_view` times out.
    * `renderManualPane` forced to `entry = null` -> the pane opens but always
      at the index -> `deep_link_not_resolved`.
    * `renderManualIndex`'s unknown-slug branch disabled -> the pane stops
      naming the slug it was asked for -> `unknown_slug_not_indexed`.
    * the `hashchange` listener made inert after the third event -> the deep
      links paint but back/forward do not -> `history_back_restores_manual`
      times out.
    * `renderManualPane` made to fall back on the last term it showed instead of
      reading the route — the "ambient state" defect the bundle's own comments
      warn about -> stepping back to the route beneath the manual entries comes
      back with the pane still open -> `history_back_reaches_underlying_route`
      times out.
    * the Close control's `manualRoute(route, null)` target replaced with a bare
      `#/runs` -> `close_control_preserves_underlying_route` times out.
    * the manual fast-path guard replaced with `if (false)` ->
      `no_refetch_over_unrederivable_view` reports a delta of 2 with
      `manual_toggle_refetched`, while every other leg stays green.

  The refetch row is the reason there are two refetch legs rather than one. Over
  a HEALTHY view the ordinary path's own `matchingDetail` branch re-renders from
  `state.detail` without refetching, so deleting the fast path changes no
  request count there and the healthy leg cannot carry the claim by itself.

  PROVEN NOT TO FLAKE, on the same base and by the same method — because the
  dead-end baseline is the one gate whose own machinery could invent a red:

    * `/api/runs` delayed 3s in the router, so the app's parent-resolution
      acquisition is arbitrarily SLOW -> the leg still passes with the same
      baseline of 8 and a delta of 0. The baseline is held open until the slow
      acquisition settles rather than taken over a moving snapshot.
    * the acquisition guard neutered to `if (false && identityLoss && ...)`, so
      the app issues NO acquisition at all -> the leg passes in seconds with
      `resolution_acquisitions_observed: 0` and a baseline of 7, instead of
      burning the 60s deadline on a request that was never owed. This is the
      case a hard-coded "one more `/api/runs` must arrive" demand turns into a
      60-second false red blaming the app for a correct decision.
    * both of the above at once with the fast-path guard ALSO disabled -> still
      red with `manual_toggle_refetched`, baseline 7 and delta 2. Observing the
      acquisition rather than demanding it does not blunt the gate.

  One half of one leg is STRUCTURAL rather than gated, and is named as such
  rather than left to look stronger than it is. The second back step asserts two
  things: that the pane comes back CLOSED over the underlying view (gated — the
  ambient-state tamper above turns it red) and that the two manual deep links
  occupied DISTINCT history entries. No in-app tamper can falsify that second
  half, because assigning `location.hash` always pushes an entry and a later
  `replaceState` cannot retract one. It is kept because it makes the step's
  premise explicit and because a future move to `replaceState`-based manual
  routing would land the first back step somewhere else and go red there.
  """

  @project_root Path.expand("..", __DIR__)
  @escript Path.join(@project_root, "pixir-monitor")
  @harness Path.join(__DIR__, "support/manual_route_browser_harness.mjs")
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

  # Pinning the leg NAMES — and their ORDER — is what makes this a gate rather
  # than a recorder: a harness that quietly drops a leg, or reorders the story so
  # a later leg's precondition is no longer established by the earlier one,
  # produces a different list and fails here.
  @legs [
    "boot_default_view",
    "deep_link_resolves_to_default_view",
    "unknown_slug_lands_on_index",
    "history_back_forward_restores_manual_state",
    "manual_only_toggle_issues_no_authoritative_refetch",
    "close_control_preserves_underlying_route",
    "no_refetch_over_unrederivable_view",
    "dotted_label_opens_its_term"
  ]

  # `liveness` is the first entry of the shipped corpus (app.js GLOSSARY). The
  # unknown slug is manualField-SHAPED so it reaches the pane verbatim: an
  # off-shape token would be normalized to the index sentinel before the pane
  # ever saw it, and the leg would be asserting against the normalizer instead
  # of against the unknown-slug branch.
  @known_slug "liveness"
  @unknown_slug "not-a-term"

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
  # One browser, one monitor, one page, seven legs. Shared hosts showed
  # identical-work browser runs spreading widely, so the budget absorbs that.
  @tag timeout: 300_000
  test "the manual route family behaves in a real browser" do
    root = PixirMonitor.TestRun.tmp("pixir-monitor-escript-manual-route")

    workspace = Path.join(root, "workspace")
    File.mkdir_p!(workspace)
    run_id = "20260819T000000-manualroute"
    materialize_workspace!(workspace, run_id)
    profiles_before = Path.wildcard(Path.join(root, "pixir-monitor-manual-route-*")) |> MapSet.new()

    on_exit(fn ->
      # A brutal ExUnit timeout cannot kill the System.cmd child tree, so reap
      # any harness/monitor still holding the unique fixture root.
      System.cmd("pkill", ["-f", root], stderr_to_stdout: true)
      File.rm_rf!(root)
    end)

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
          root,
          "--run-id",
          run_id,
          "--known-slug",
          @known_slug,
          "--unknown-slug",
          @unknown_slug,
          "--browser-timeout-ms",
          "60000",
          "--json"
        ],
        stderr_to_stdout: true
      )

    assert status == 0, "manual route browser harness failed: #{output}"
    result = output |> String.split("\n", trim: true) |> List.last() |> Jason.decode!()
    IO.puts(Jason.encode!(%{"manual_route_evidence" => result}))

    assert result["ok"] == true
    assert result["check"] == "pixir_monitor_manual_route"
    assert result["console_errors"] == 0
    assert result["launch_fragment_cleared"] == true
    assert result["handoff_cleaned"] == true

    assert result["cleanup"] == %{
             "browser_stopped" => true,
             "monitor_stopped" => true,
             "profile_removed" => true
           }

    assert result["leg_names"] == @legs
    legs = Map.new(result["legs"], fn entry -> {entry["name"], entry} end)

    # ── Boot ────────────────────────────────────────────────────────────────
    boot = legs["boot_default_view"]
    assert boot["hash"] == "#/runs"
    assert boot["view_class"] =~ "runs-view"
    assert boot["pane_open"] == false

    # ── The deep link resolves to the DEFAULT view ──────────────────────────
    #
    # `entered_from` is what proves the leg is not vacuous: the deep link was
    # taken while a RUN DETAIL was painted, so landing on the runs view is a
    # move OFF that route rather than the route it happened to be sitting on.
    deep = legs["deep_link_resolves_to_default_view"]
    assert deep["entered_from"] == "#/runs/#{run_id}"
    assert deep["hash"] == "#manual/#{@known_slug}"
    assert deep["view_class"] =~ "runs-view"
    refute deep["view_class"] =~ "detail-view"
    assert deep["pane_term"] == @known_slug
    assert deep["pane_label"] == "Instrument manual"
    assert deep["route_chip"] == "#manual/#{@known_slug}"
    # The slug RESOLVED to a real corpus entry rather than falling back to the
    # index — the term is rendered, so the pane opened ON that entry.
    assert deep["entry_term"] == "Liveness"
    # Close returns to the default route the deep link resolved onto.
    assert deep["close_href"] == "#/runs"

    # ── An unknown slug lands on the INDEX, never on an unavailable view ────
    unknown = legs["unknown_slug_lands_on_index"]
    assert unknown["hash"] == "#manual/#{@unknown_slug}"
    assert unknown["view_class"] =~ "runs-view"
    # Carried verbatim in the route field, so the pane can name what was asked
    # for, while the chip names the route that actually opens what is on screen.
    assert unknown["pane_term"] == @unknown_slug
    assert unknown["route_chip"] == "#manual/index"
    assert unknown["unknown_slug_named"] == true
    assert unknown["index_term_links"] > 0
    assert unknown["index_term_links"] == result["index_term_count"]

    # ── Back / forward restore the manual state ────────────────────────────
    #
    # Asserted on the pane's CONTENT, not merely on the hash: a restored hash
    # with a closed or empty pane is exactly the regression this leg exists for.
    history = legs["history_back_forward_restores_manual_state"]
    assert history["back_hash"] == "#manual/#{@known_slug}"
    assert history["back_pane_term"] == @known_slug
    assert history["back_entry_term"] == deep["entry_term"]

    # A SECOND step back reaches the route UNDER the manual entries. This is
    # what proves each deep link pushed a history entry of its own rather than
    # replacing its predecessor: with the manual entries collapsed, one step
    # back from the known deep link would already be the run detail and the
    # assertion above would have landed elsewhere. It also pins that stepping
    # out of the manual restores a CLOSED pane over the underlying view —
    # the Close control's property, reached through the browser control.
    assert history["beneath_hash"] == "#/runs/#{run_id}"
    assert history["beneath_pane_open"] == false
    assert history["beneath_detail_run_id"] == run_id

    assert history["forward_hash"] == "#manual/#{@unknown_slug}"
    assert history["forward_pane_term"] == @unknown_slug
    assert history["forward_index_term_links"] == unknown["index_term_links"]

    # ── The overlay rides beside an already-painted view ────────────────────
    #
    # A manual-only hash delta over a healthy run detail is a pure re-render:
    # the run stays painted BY IDENTITY beside the pane and nothing is refetched.
    # Measured from the app's own recorded fetches, over a detail that was
    # allowed to go quiescent first, across a full open/close toggle.
    #
    # This leg does NOT carry the no-refetch claim on its own, which is stated
    # here rather than left implied: deleting the manual fast path entirely
    # leaves it green, because the ordinary path's `matchingDetail` branch
    # re-renders a healthy detail from `state.detail` without refetching. Over a
    # healthy view the fast path buys view PRESERVATION, not request
    # suppression. The discriminating leg is `no_refetch_over_unrederivable_view`
    # below, and its red proof is recorded in this suite's task notes.
    toggle = legs["manual_only_toggle_issues_no_authoritative_refetch"]
    assert toggle["projection_refetch_delta"] == 0
    assert toggle["settled_projection_fetches"] == toggle["baseline_projection_fetches"]

    # A baseline of zero would mean nothing was ever loaded and the toggle rode
    # over an empty app, where the fast path is not even taken.
    assert toggle["baseline_projection_fetches"] > 0

    # The run the pane opened OVER is the run the route asked for: the overlay
    # pushed layout beside a still-painted view rather than replacing it.
    assert toggle["opened_over_run_id"] == run_id

    # Opening lands focus INSIDE the pane. The full focus round trip (including
    # the return on close) is pinned by the node:vm tier and by the gauntlet;
    # this is the real-browser corroboration that the handoff fires at all.
    assert toggle["opened_focus_key"] == "manual-heading"

    # ── Closing through the pane's own control preserves the route ─────────
    close = legs["close_control_preserves_underlying_route"]
    assert close["pane_open"] == false
    assert close["hash"] == "#/runs/#{run_id}"
    assert close["view_class"] =~ "detail-view"
    assert close["detail_run_id"] == run_id

    # ── The no-refetch property WHERE IT IS OBSERVABLE ─────────────────────
    #
    # The leg that bites. A run id this workspace does not contain paints the
    # not-found dead end with `state.detail` null underneath it, so the ordinary
    # path cannot re-render it from state and would refetch. The manual-only
    # delta must still be a pure re-render: the same unavailable class comes
    # back, the same view class comes back, and the request count does not move.
    #
    # Verified to bite on this base: rebuilding the bundle with the fast-path
    # guard replaced by `if (false)` makes this leg report a delta of 2 (one
    # authoritative request on open, another on close) while every other leg —
    # including the healthy-view toggle above — stays green.
    #
    # The baseline and the reference snapshot are both taken AFTER quiescence,
    # never at the 404 paint. `renderProjectionFailure` fires the
    # parent-resolution `/api/runs` acquisition on a structured `run_not_found`,
    # and on this base it does fire, because the route change nulled the held
    # list on the way in. The navigation's own wait condition — an error view
    # with no pane — is satisfied by the paint while that request may still be
    # open, so a baseline taken at arrival would race it: land it after the leg
    # and the delta measures nothing, land it between baseline and settle and
    # the manual toggle is blamed for the app's own acquisition.
    #
    # What removes the race is an ORDERING FACT rather than a prediction. That
    # acquisition is decided synchronously inside `renderProjectionFailure`,
    # before any of its branches paint, so by the time the error view exists in
    # the DOM the decision is final. The harness reads the acquisition count in
    # the SAME evaluation that first sees the view, then holds the baseline open
    # until what it saw has settled and nothing is in flight.
    #
    # Demanding one acquisition instead would be a prediction the app never
    # made: the same guard declines it outright when inventory is already held
    # (`!heldInventoryRows(route).length`), and `acquireInventoryForResolution`
    # short-circuits on a resolution already open or already spent for the id.
    # On any of those the demanded request never arrives and the gate would burn
    # its whole deadline and go red blaming the app for a request it was right
    # not to make — a false red on the arc's highest-regression-risk leg.
    #
    # So the count is REPORTED and pinned here rather than demanded inside the
    # harness. One acquisition is what this base does; a base that held its
    # inventory would honestly record zero and still be a correct dead end, and
    # a change in this number is then a visible evidence change instead of a
    # 60-second timeout with a misleading diagnosis.
    dead_end = legs["no_refetch_over_unrederivable_view"]
    assert dead_end["reference_taken_after_quiescence"] == true
    assert dead_end["resolution_acquisitions_observed"] == 1
    assert dead_end["projection_refetch_delta"] == 0
    assert dead_end["settled_projection_fetches"] == dead_end["baseline_projection_fetches"]
    assert dead_end["baseline_projection_fetches"] > 0

    # The dead end came back UNCHANGED rather than merely being an error view
    # again: re-deriving one unavailable class as another is a silent
    # relabelling of what the operator is being told.
    assert dead_end["unavailable_class"] == "not_found"
    assert dead_end["view_class"] =~ "error-view"
    assert dead_end["hash"] == "#/runs/#{run_id}-absent"

    # ── The dotted-label leg, decided by the DOM ───────────────────────────
    #
    # T5's labels are integrated, so this leg MUST report `exercised` with the
    # pane open on the clicked label's own slug: a `not_present` now means the
    # dotted labels regressed. The decision stays a DOM existence check inside
    # the harness, not a flag this driver can set, so the leg cannot be
    # silently disabled from here.
    dotted = legs["dotted_label_opens_its_term"]
    # T5's labels are integrated: the leg's existence guard was for the wave
    # where the affordance lived in a parallel branch. A not_present here now
    # means the labels REGRESSED, so the leg must have exercised.
    assert dotted["status"] == "exercised"
    assert dotted["labels_present"] > 0
    assert dotted["pane_term"] == dotted["slug"]

    profiles_after = Path.wildcard(Path.join(root, "pixir-monitor-manual-route-*")) |> MapSet.new()
    assert MapSet.difference(profiles_after, profiles_before) == MapSet.new()
  end

  # A minimal, deterministic single-run workspace: one subagent that starts and
  # finishes. The manual is orthogonal to what the run contains, so the fixture
  # is kept at the smallest shape that paints a runs list and a run detail —
  # anything richer would add variance without adding evidence.
  defp materialize_workspace!(workspace, run_id) do
    sessions = Path.join([workspace, ".pixir", "sessions"])
    File.mkdir_p!(sessions)

    events = [
      %{
        "id" => "event-#{run_id}-0",
        "session_id" => run_id,
        "seq" => 0,
        "ts" => "2026-08-19T00:00:00Z",
        "type" => "subagent_event",
        "data" => %{
          "event" => "started",
          "status" => "running",
          "child_session_id" => "child-session",
          "subagent_id" => "subagent-one",
          "agent" => "manual-route-agent"
        }
      },
      %{
        "id" => "event-#{run_id}-1",
        "session_id" => run_id,
        "seq" => 1,
        "ts" => "2026-08-19T00:00:01Z",
        "type" => "subagent_event",
        "data" => %{
          "event" => "finished",
          "status" => "completed",
          "child_session_id" => "child-session",
          "subagent_id" => "subagent-one"
        }
      }
    ]

    File.write!(
      Path.join(sessions, run_id <> ".ndjson"),
      Enum.map_join(events, "", &(Jason.encode!(&1) <> "\n"))
    )

    :ok
  end
end
