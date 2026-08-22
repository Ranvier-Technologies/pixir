defmodule PixirMonitor.UI.ManualOverlayPreservationTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Executes the manual-overlay FAST PATH of #551 in node:vm against a minimal DOM,
  over views that a FAILURE painted.

  This tier exists because the source-text pins cannot reach the defect class it
  guards. Opening the instrument manual is a pure overlay move, so the view the
  pane opens over must come back byte-identical. The failure views are precisely
  the ones that are NOT re-derivable from state: both `renderProjectionFailure`
  and `refresh`'s own finally block deliberately set `state.detail = null` while
  leaving the view painted, so a fast path that re-renders from state repaints a
  DIFFERENT view. A run that 404s under follow paints "Follow degraded" with
  `data-follow-state="degraded"`, the identity-loss provenance and the
  resolved-parent affordance; re-deriving it yields "Follow snapshot unavailable"
  with a different asserted Follow state, a different provenance sentence and a
  different status line, and `replaceContent` drops `data-error-kind` on the way
  through. A snapshot that CONTRADICTS the followed identity paints "Follow
  identity conflict" straight out of `renderDetail`, never through
  `renderProjectionFailure` at all; re-deriving relabels that contradiction as an
  outage. Both are silent changes to assertions the operator is trusting, which
  is why the replayable paint is recorded at the two seams where every failure
  view is mounted rather than at the failure classifier.

  The checker therefore snapshots the painted view before the manual-only
  hashchange and requires an EXACT match after it — across `data-follow-state`,
  `data-unavailable-class`, the app-level error diagnostic, the status line and
  the full text of the view — and proves the check bites by first running the
  follow-degraded scenario against a fast path that re-derives from state and
  requiring it to go red.

  The HEALTHY views are covered by the same assertions on the other leg of that
  fast path. Failure views record a replayable paint, so every failure scenario
  exercises `replayLastPaint()`; a successfully painted run detail, followed run
  detail or runs list records none, so the overlay move goes through
  `renderCurrentGuarded()` instead. That is the leg the headline criterion lives
  on — the manual-only delta is a no-refetch re-render, `state.detail` is not
  torn down, and the run detail stays painted beside the pane — and it has its
  own red proof, which deletes the call so the pane never mounts over a healthy
  view at all.

  A final family runs in WORKSPACE-SET mode, where the fast path can find a
  record no scenario above can leave behind. Both legs above are reached through
  `renderCurrent`, the one site that cleared the record on a successful paint;
  `refresh`'s overview leg and `refetchWorkspaceList`'s `finally` call
  `renderWorkspaceOverview()` directly, so a superseded failure record stayed
  armed under a healthy overview and the next `?` replayed it. The record is now
  cleared at that renderer's own mount seam.

  A last family runs the ON THIS RUN binding for real. Every family above is
  about what the pane must NOT disturb; that one is about what it must SAY. The
  source-text pins in `manual_pane_contract_test` prove the slug -> reader table
  exists and names its accessors, but not that it produces anything: readers
  that all return null, a scope guard that never resolves the run, or an alias
  map applied to the wrong dimension survive every source pin and put either
  nothing or the wrong words on screen. The checker renders the binding over a
  projection fixture with every bound dimension populated, asserts each reading
  verbatim in the shipped display vocabulary, and drives the list-scope
  degradation through the order that actually produces it -- detail first, so a
  binding without the scope guard would have a real snapshot to misread.

  Two of its legs drive the UNIT route, which nothing here ever did before. The
  scope guard has always admitted `route.view === "unit"` and no leg exercised
  it, which hid two defects at once. On a PAINTED Unit Inspector the readers
  folded the whole run, so the pane printed a run-wide number under a heading
  reading ON THIS RUN while the card inches away painted that unit's value for
  the same dimension. And on an ABSENT unit `renderUnit` bails to
  renderUnavailable without clearing `state.detail`, so a guard keyed on route
  shape alone passed every identity check and the pane made a live,
  basis-attributed, seq-stamped claim about a run beside a view declaring the
  projection unavailable. Both legs carry red proofs that reinstate the shipped
  defect exactly.

  A last family enters through the SSE STREAM rather than through `hashchange`,
  and it is the path where nothing generic protects focus. The runs list paints
  an orientation sentence that quotes the SSE health pill, and each quoted term
  is a native `<a href>` — a tab stop on the first screen. Because the pill's
  wording is state-dependent, `setStatus` refills that sentence when the observed
  vocabulary changes, and refilling calls `replaceChildren()` on the subtree
  holding those anchors. `source.onopen` and `source.onerror` call `setStatus`
  with no view re-render at all, so `restoreView` is nowhere near them:
  `connecting -> connected` collapsed focus to `document.body` seconds after page
  load, with no operator action, exactly while a keyboard user was tabbing in.
  The preservation therefore lives inside `repaintStreamVocabularyLine`, with the
  destruction it protects against, and this family drives real transitions
  against it — including the one where the held term legitimately vanishes.
  """

  @app Path.expand("../../priv/static/app.js", __DIR__)
  @checker Path.expand("../support/manual_overlay_preservation_check.mjs", __DIR__)
  @node System.find_executable("node")
  # Same policy as the acquisition tier: a missing node skips LOCALLY but must
  # fail LOUDLY in CI, so this executed-JavaScript evidence class cannot be lost
  # to a silent skip.
  @node_skip (cond do
                is_binary(@node) -> false
                System.get_env("CI") in ["true", "1"] -> false
                true -> "requires Node.js"
              end)

  @tag skip: @node_skip
  @tag timeout: 120_000
  test "opening the manual over a failure view reproduces it instead of re-deriving it" do
    assert is_binary(@node),
           "the CI runner lost node: the manual overlay preservation tier must not silently skip in CI"

    {output, status} =
      System.cmd(@node, [@checker, "--app", @app, "--json"], stderr_to_stdout: true)

    assert status == 0, "manual overlay preservation check failed: #{output}"
    result = output |> String.split("\n", trim: true) |> List.last() |> Jason.decode!()

    assert result["ok"] == true
    assert result["check"] == "pixir_monitor_manual_overlay_preservation"
    assert result["executed_in"] == "node_vm_minimal_dom"

    # The check is proven to bite before its green scenarios: a fast path that
    # calls renderCurrentGuarded() unconditionally must downgrade the painted
    # Follow state.
    assert result["red_proof"]["family"] == "manual_overlay_preservation"
    assert result["red_proof"]["detected"] == "view_not_preserved"

    # The focus family is proven to bite by its OWN red proof, which strips both
    # halves of the fix — the deliberate open/close handoff and the restoreView
    # fallback — back to plain capture/restore. Stripping only one would leave the
    # other masking the dead end.
    assert result["focus_red_proof"]["family"] == "manual_overlay_focus"

    assert result["focus_red_proof"]["detected"] in [
             "focus_lost_on_close",
             "focus_not_returned",
             "focus_lost_on_open"
           ]

    scenarios = Map.new(result["scenarios"], fn entry -> {entry["name"], entry} end)

    # Every named scenario must be present: a checker that quietly drops one
    # cannot pass by reporting fewer.
    assert scenarios |> Map.keys() |> Enum.sort() == [
             "detail_fetch_outage_survives_manual_open",
             "follow_degraded_repainted_while_manual_open_survives_close",
             "follow_degraded_survives_manual_open",
             "follow_identity_conflict_survives_manual_open",
             "healthy_followed_detail_survives_manual_open",
             "healthy_run_detail_survives_manual_open",
             "healthy_runs_list_survives_manual_open",
             "identity_conflict_survives_manual_open",
             "run_not_found_survives_manual_open",
             "runs_list_failure_survives_manual_open",
             "unanchored_open_close_lands_focus_in_view_detail",
             "unanchored_open_close_lands_focus_in_view_runs"
           ]

    # The finding's own case: the degraded Follow assertion must still be the one
    # painted after the pane opens, not a snapshot-unavailable downgrade.
    assert scenarios["follow_degraded_survives_manual_open"]["follow_state"] == "degraded"

    # The dead ends keep their unavailable taxonomy across the overlay move.
    assert scenarios["run_not_found_survives_manual_open"]["unavailable_class"] == "not_found"

    assert scenarios["runs_list_failure_survives_manual_open"]["unavailable_class"] ==
             "projection_unavailable"

    # The IDENTITY CONFLICT views. These are the family that never passes through
    # `renderProjectionFailure` at all: `renderDetail` and `renderUnit` bail out
    # to them directly when the authoritative snapshot names a different run than
    # the route, and `refresh`'s own finally block then nulls `state.detail`
    # underneath the painted view. A record kept only at the failure classifier
    # is therefore null here, and re-deriving relabels a CONTRADICTION as an
    # OUTAGE — `identity_conflict` decaying to `snapshot_unavailable`, and "The
    # requested run no longer matches this projection." decaying to "Run
    # projection is unavailable." Recording the replayable paint at the two
    # seams where every failure view is actually mounted is what holds them.
    assert scenarios["follow_identity_conflict_survives_manual_open"]["follow_state"] ==
             "identity_conflict"

    assert scenarios["identity_conflict_survives_manual_open"]["unavailable_class"] ==
             "projection_unavailable"

    # Keyboard focus survives the round trip. Opening lands INSIDE the pane, and
    # closing it from the pane's own Close control returns the operator to the
    # control they held when they opened it — rather than dropping focus onto
    # document.body, where the next Tab restarts at the top of the document.
    round_trip = scenarios["follow_degraded_survives_manual_open"]
    assert round_trip["focus_after_open"] == "manual-heading"
    assert is_binary(round_trip["focus_before_open"])
    assert round_trip["focus_after_close"] == round_trip["focus_before_open"]

    # ── The HAPPY PATH ──────────────────────────────────────────────────────
    #
    # Every scenario above is a FAILURE view, and every failure view records a
    # replayable paint, so all of them take the `replayLastPaint()` leg. The
    # headline criterion of #551 — a manual-only delta is a no-refetch
    # re-render that does not tear `state.detail` down, leaving the run detail
    # painted beside the pane — lives on the OTHER leg,
    # `else renderCurrentGuarded()`, and nothing above reaches it. A regression
    # in which the pane never mounts over a healthy view at all was invisible
    # to this whole tier.
    #
    # Each healthy scenario therefore pins the view class it actually painted:
    # `detail-view` and `runs-view` are the successful renderers, so a fixture
    # the renderers reject would surface as an error view here rather than pass
    # by testing the failure leg a seventh time.
    assert scenarios["healthy_run_detail_survives_manual_open"]["view_class"] =~ "detail-view"
    assert scenarios["healthy_followed_detail_survives_manual_open"]["view_class"] =~ "detail-view"
    assert scenarios["healthy_runs_list_survives_manual_open"]["view_class"] =~ "runs-view"

    for name <- [
          "healthy_run_detail_survives_manual_open",
          "healthy_followed_detail_survives_manual_open",
          "healthy_runs_list_survives_manual_open"
        ] do
      healthy = scenarios[name]

      # A healthy view carries no failure taxonomy: if any of these were set the
      # scenario silently degraded and is not exercising the re-derive leg.
      assert healthy["unavailable_class"] == nil
      assert healthy["follow_state"] == nil
      assert healthy["error_kind"] == nil

      # The pure-overlay contract on the healthy leg: the byte-identical view
      # comparison inside the checker already ran, and the pane mounted without
      # a single authoritative request. The checker throws `manual_refetched`
      # otherwise, so reaching here means the request count did not move.
      assert healthy["focus_after_open"] == "manual-heading"
      assert is_binary(healthy["focus_before_open"])
      assert healthy["focus_after_close"] == healthy["focus_before_open"]
    end

    # The healthy family has its OWN red proof, because neither proof above can
    # speak for this leg: both tamper with the replay leg. This one deletes the
    # `else renderCurrentGuarded()` call, so the fast path returns having done
    # nothing — the pane never mounts over a healthy view — and requires the
    # healthy scenario to go red on the missing pane.
    assert result["healthy_red_proof"]["family"] == "manual_overlay_healthy_leg"
    assert result["healthy_red_proof"]["detected"] == "manual_not_mounted"

    # ── CLOSING is an overlay move too ──────────────────────────────────────
    #
    # The three proofs above all tamper with the fast PATH, so none of them can
    # speak for what the replayed record CONTAINS. `renderFollowErrorView`
    # captures its route by value, so a repaint that happens while the pane is
    # open — the view's own Refetch control, an SSE-driven refresh — used to
    # freeze `manual=index` into the record. Replaying it after the close then
    # rebuilt every exit through `semanticZoomRoute`, which re-serializes the
    # whole route: "Unfollow and return to Runs", the dead end's primary exit,
    # pointed back into the pane the operator had just dismissed.
    #
    # Two gaps kept that invisible, and this scenario closes both: link targets
    # are `node.href`, a plain property that never entered the compared surface,
    # and the close leg asserted only focus and pane absence, never a snapshot
    # diff against the view the pane opened over.
    repainted = scenarios["follow_degraded_repainted_while_manual_open_survives_close"]
    assert repainted["follow_state"] == "degraded"
    assert repainted["focus_after_open"] == "manual-heading"
    assert repainted["focus_after_close"] == repainted["focus_before_open"]

    assert result["restore_red_proof"]["family"] == "manual_overlay_restoration"
    assert result["restore_red_proof"]["detected"] == "view_not_restored"

    # ── The NULL-STASH close ────────────────────────────────────────────────
    #
    # Every scenario above anchors focus on a keyed control before pressing `?`,
    # so the close leg always has a stash to return to and its null branch was
    # never executed. These two do not anchor, which is the order that actually
    # happens: `?` pressed with focus on unkeyed ground — page whitespace, or a
    # page that just loaded and was never clicked — and, equivalently, a
    # `#manual/<slug>` deep-link boot where the pane is open at bootstrap so
    # nothing was ever stashed.
    #
    # With no stash, "return to where you were" has no subject, and the control
    # focus IS on (`manual-close`) is destroyed by the very re-render that
    # closes the pane. Clearing the key is not enough: a null key used to skip
    # restoreView's entire focus block, the first-focusable fallback included,
    # leaving focus on the detached node and collapsing to document.body.
    #
    # The checker asserts ATTACHMENT, not just a key: it now models a browser's
    # own behaviour of resetting document.activeElement when the focused subtree
    # is detached, and asks whether focus landed anywhere inside the repainted
    # view. `focus_before_open` being nil is what proves the null branch ran.
    for name <- [
          "unanchored_open_close_lands_focus_in_view_runs",
          "unanchored_open_close_lands_focus_in_view_detail"
        ] do
      unanchored = scenarios[name]

      assert unanchored["focus_before_open"] == nil,
             "#{name} must open with NOTHING stashed, or it is not exercising the null-stash branch"

      assert unanchored["focus_after_open"] == "manual-heading"

      # Landed on a real control of the repainted view, not on document.body and
      # not on the destroyed manual-close anchor.
      assert is_binary(unanchored["focus_after_close"])
      refute unanchored["focus_after_close"] in ["manual-close", "manual-heading"]
    end

    # And its OWN red proof, because the focus proof above only ever runs against
    # an ANCHORED scenario, where a stash exists and the fallback is a backstop
    # rather than the whole mechanism. This one cuts exactly the `focusFallback`
    # guard, restoring the pre-fix `if (saved.focus)`, and requires the
    # unanchored scenario to go red on focus leaving the view.
    assert result["null_stash_red_proof"]["family"] == "manual_overlay_null_stash"
    assert result["null_stash_red_proof"]["detected"] == "focus_lost_on_close"

    # ── The STALE REPLAY over a healthy Workspace Overview ───────────────────
    #
    # Every scenario above runs in SINGLE mode, where both legs of the fast path
    # are reached through `renderCurrent` — the one site that cleared
    # `state.lastPaint` on a successful paint. Workspace-set mode has callers
    # that bypass `renderCurrent` entirely: `refresh`'s overview leg and
    # `refetchWorkspaceList`'s `finally` both call `renderWorkspaceOverview()`
    # DIRECTLY, and both are the hot path for an SSE invalidation and for the
    # per-source Retry control.
    #
    # So a failed paint of the overview route left the replayable record ARMED
    # underneath a healthy overview those direct callers then painted, and the
    # next manual-only delta took the replay leg: the operator pressed `?` on a
    # working Workspace Overview and got "Snapshot loaded but could not be
    # displayed." back. That is the exact inverse of the preservation property
    # every scenario above pins, and no scenario above can reach it.
    #
    # The order the checker drives is entirely honest — no tampering of the
    # fast path, no synthetic lastPaint. A list row that still passes the
    # envelope (encodable id) but throws when the overview reads `attention`
    # makes the renderer fail; the guarded caller records. A clean SSE
    # invalidation then repaints the healthy overview through
    # `refetchWorkspaceList`'s finally. Then `?`.
    # The lone-surrogate id used to arm this family; #556 classifies that id
    # as an invalid row, so the surrogate has its own executed proof below.
    #
    # Fixed at the MOUNT SEAM: `renderWorkspaceOverview` clears the record as its
    # first statement, so a successful overview paint owns it regardless of
    # caller — the same reasoning that puts the record's WRITES at the mount
    # seams rather than at the failure classifier.
    stale = result["stale_replay"]
    assert stale["family"] == "workspace_overview_stale_replay"

    # The three steps of the order, each observed rather than assumed: the
    # failure really was painted (so a record really was armed), the healthy
    # overview really did come back, and the overlay move left it there.
    assert stale["failure_view_class"] =~ "error-view"
    assert stale["healthy_view_class"] =~ "workspace-overview"
    assert stale["after_manual_view_class"] =~ "workspace-overview"
    refute stale["after_manual_view_class"] =~ "error-view"

    # And its OWN red proof, because none of the five above can speak for it:
    # they all tamper with the fast PATH, while this defect is about which record
    # the fast path finds when it gets there. This one cuts exactly the clear at
    # the overview's mount seam.
    assert result["stale_replay_red_proof"]["family"] == "workspace_overview_stale_replay"

    assert result["stale_replay_red_proof"]["detected"] ==
             "stale_failure_replayed_over_healthy_view"

    # ── UNLINKABLE RUN ID (#556), executed ──────────────────────────────────
    #
    # A lone UTF-16 surrogate passes the list envelope's shape contract and
    # then `encodeURIComponent` throws URIError inside `routeHash`. On the
    # workspace-set path that throw escaped uncaught from
    # `refetchWorkspaceList`'s finally. The honest home is the existing
    # invalid-row confession: count it as an unprojected selected Log, paint
    # the healthy rows, never build the href.
    unlinkable = result["unlinkable_run_id"]
    assert unlinkable["family"] == "unlinkable_run_id"
    assert unlinkable["single_view_class"] =~ "runs-view"
    assert unlinkable["overview_view_class"] =~ "workspace-overview"
    assert unlinkable["list_view_class"] =~ "runs-view"
    assert unlinkable["sse_view_class"] =~ "workspace-overview"
    assert unlinkable["atomic_pair"] == "list_path"
    assert unlinkable["console_errors"] == 0
    assert unlinkable["unhandled_rejections"] == 0

    assert result["unlinkable_run_id_red_proof"]["family"] == "unlinkable_run_id"

    assert result["unlinkable_run_id_red_proof"]["detected"] ==
             "unhandled_rejection_uri_error"

    # ── ON THIS RUN, executed ───────────────────────────────────────────────
    #
    # Everything above is about PRESERVATION: what the pane must not disturb.
    # This family is about what the pane must SAY. The source-text pins in
    # `manual_pane_contract_test` can prove the slug -> reader table exists and
    # names its accessors; they cannot prove it produces anything. A table whose
    # readers all return null, a scope guard that never finds the run, an alias
    # map applied to the wrong dimension, or a distribution built from the wrong
    # counts all survive every source pin unchanged and put either nothing or
    # the wrong words on screen.
    #
    # The checker therefore runs the real binding over a projection fixture with
    # every bound dimension populated and reads what the pane rendered.
    detail = result["on_this_run_detail"]
    assert detail["family"] == "on_this_run_detail_scope"
    assert detail["as_of_seq"] == 34

    readings = Map.new(detail["readings"], fn entry -> {entry["slug"], entry["reading"]} end)

    # Every bound term must be exercised. A checker that quietly dropped one
    # cannot pass by reporting fewer.
    # The checker asserts this list against the bundle's OWN exported bound
    # inventory (`manualRunValueSlugs`) before running a single scenario, so a
    # term added to the reader table without an expectation goes red on
    # `on_this_run_coverage_gap` rather than shipping with its rendering
    # unproven. This assertion is the second half of that: it names which
    # nineteen, so a coordinated change to both the table and the checker still
    # has to be stated here.
    assert readings |> Map.keys() |> Enum.sort() == [
             "as-of-seq",
             "attention",
             "checkpoint-ready",
             "child-after-end",
             "dependency-gate",
             "execution",
             "externally-owned",
             "invalid-advisory",
             "live-source-mode",
             "liveness",
             "model-advisory",
             "parent-observed",
             "reconstructed",
             "runtime-gate",
             "source-run-scoped",
             "stale-handle",
             "unclassified-verdict",
             "undetermined",
             "unobserved"
           ]

    # value · basis · as-of seq, in the SHIPPED display vocabulary. The exact
    # strings are the assertion: they are what the shipped alias maps and the
    # shipped pluralizer produce, so a reader that switched dimension or grew a
    # parallel copy table cannot render them by accident.
    assert readings["execution"] == "running · on this run · basis parent log fold · as of seq 34"
    assert readings["liveness"] == "not applicable · on this run · basis parent log only · as of seq 34"

    # The gate distribution carries the shipped {checkpoint_ready: "ready"}
    # alias, and BOTH labels for that one dimension read identically -- which is
    # exactly the confusable the two entries warn about.
    assert readings["dependency-gate"] == "1 held · 3 ready · on this run · basis unit checkpoint fold · as of seq 34"
    assert readings["runtime-gate"] == readings["dependency-gate"]
    assert readings["checkpoint-ready"] == "3 ready · on this run · basis unit checkpoint fold · as of seq 34"

    # ADVISORY_DISPLAY_ALIASES plus the shipped pluralizer: two unknown-verdict
    # units read "2 unclassified verdicts", never "2 unknown".
    assert readings["model-advisory"] ==
             "1 pass · 2 unclassified verdicts · 1 invalid · on this run · basis model declared · as of seq 34"

    assert readings["unclassified-verdict"] ==
             "2 unclassified verdicts · on this run · basis model declared · as of seq 34"

    assert readings["invalid-advisory"] == "1 invalid · on this run · basis model declared · as of seq 34"
    assert readings["source-run-scoped"] == "live · on this run · basis parent log · as of seq 34"

    # The attention aliases {yes: "required", no: "not required"} -- "3 not
    # required" is the phrase the design handoff names as contract.
    assert readings["attention"] == "1 required · 3 not required · on this run · basis parent log · as of seq 34"
    assert readings["parent-observed"] == readings["attention"]
    # The post-terminal dimension speaks postTerminalLabel -- the same shipped
    # phrase the runs-list cell and the truth card print -- not a titleCased
    # state token. Words are contract, so the pane may not be the one surface
    # explaining this dimension in a vocabulary no other surface uses.
    assert readings["child-after-end"] ==
             "No child events after the run ended · on this run · basis child log scan · as of seq 34"

    # The as-of-seq entry's VALUE is the sequence, so it is not restated as a
    # suffix on itself. It also carries no basis: the sequence is a position in
    # the parent Log fold, not a value read off the source evidence class, so
    # naming the source mode ("live") here would misattribute it.
    assert readings["as-of-seq"] == "seq 34 · on this run"

    # The terms that ARE a state VALUE rather than a dimension. The question a
    # reader who just met the word in a cell has is "is the run on screen in
    # this state right now", so the answer names the state the run IS in -- a
    # bare "no" would leave them exactly where they started. This fixture's run
    # is not_applicable, so both DETAIL-scope liveness values answer negatively
    # and each names not_applicable as what the run actually reads.
    #
    # `unobserved` is NOT one of them, and this is where that is proven. It is
    # folded by list_liveness alone (projection/source.ex), and the contract
    # says so outright: "List scope ... folds liveness independently into
    # `unobserved` ... for nonterminal rows" (projection-v1.md, Liveness
    # vocabulary). The detail builder's liveness/4 can emit no such token.
    # Answered in the denial shape its two siblings use it was a STRUCTURALLY
    # INVARIANT reading -- "Not unobserved" on 100% of runs, forever, with the
    # affirmative branch unreachable -- and the operator reaches this entry by
    # clicking the dotted label on a runs-list Liveness cell that LITERALLY
    # READS `unobserved` for that run. The pane answered a question about the
    # run with a denial the cell they came from contradicts.
    #
    # The reading states the scope fact and then what the run actually reads at
    # this scope. Both halves are true at once, which the denial never was.
    assert readings["unobserved"] ==
             "A list-scope value only — no detail projection reads unobserved, so this run reads not applicable here while its row in the Runs list may still read unobserved. · on this run · basis parent log only · as of seq 34"

    refute readings["unobserved"] =~ "Not unobserved",
           "`unobserved` is unreachable at detail scope, so denying it about the run is a structural artefact dressed as a live reading"

    assert readings["stale-handle"] ==
             "Not stale handle — this run reads not applicable · on this run · basis parent log only · as of seq 34"

    assert readings["externally-owned"] ==
             "Not externally owned — this run reads not applicable · on this run · basis parent log only · as of seq 34"

    # The source-mode values: one affirmative, one negative naming what the run
    # actually reads.
    assert readings["live-source-mode"] == "live · on this run · basis parent log · as of seq 34"

    assert readings["reconstructed"] ==
             "Not reconstructed — this run reads live · on this run · basis parent log · as of seq 34"

    # The post-terminal VALUE term, same shape as the liveness values and NOT
    # the whole dimension's reading. This fixture's run is `none`, so the entry
    # denies the term and names what the run actually reads -- through
    # postTerminalLabel, the shipped vocabulary the list cell and the truth card
    # print, so the pane and the rail quote the same words about one value.
    assert readings["undetermined"] ==
             "Not undetermined — this run reads No child events after the run ended · on this run · basis child log scan · as of seq 34"

    refute readings["undetermined"] == readings["child-after-end"],
           "the post-terminal value term rendered the whole dimension's value"

    # The DIVERGENCE leg. Both slugs now speak postTerminalLabel, so the two
    # slugs are driven over a run that IS undetermined and one that is not, and
    # every reading is pinned verbatim. Over the affirmative run the two
    # legitimately coincide -- one state, one shipped phrase -- so it is the
    # `observed` case that separates a correct value term from one wrongly bound
    # to the whole dimension, and the checker requires divergence there.
    post_terminal = result["on_this_run_post_terminal"]
    assert post_terminal["family"] == "on_this_run_post_terminal"

    post_terminal_readings =
      Map.new(post_terminal["readings"], fn entry ->
        {entry["case"], {entry["value"], entry["dimension"]}}
      end)

    assert post_terminal_readings |> Map.keys() |> Enum.sort() == ["observed", "undetermined"]

    # A run whose post-terminal state IS undetermined: the entry affirms it, in
    # the rail's own words, parenthetical included -- and the dimension prints
    # that same shipped phrase, because there is exactly one wording for this
    # state and every surface quotes it.
    assert post_terminal_readings["undetermined"] ==
             {"Undetermined (child evidence unavailable) · on this run · basis child log scan · as of seq 34",
              "Undetermined (child evidence unavailable) · on this run · basis child log scan · as of seq 34"}

    # A run that is not: the entry denies the term and names the observed count
    # through the same shipped label, while the dimension reports that count on
    # its own. This is the case that separates the two bindings.
    assert post_terminal_readings["observed"] ==
             {"Not undetermined — this run reads 7 child events after the run ended · on this run · basis child log scan · as of seq 34",
              "7 child events after the run ended · on this run · basis child log scan · as of seq 34"}

    # And the red proof: rebinding the value slug to the whole-dimension reader
    # -- the shipped defect, verbatim -- must take the leg red.
    assert result["post_terminal_red_proof"]["detected"] == "post_terminal_value_reads_dimension"

    # No reading may introduce a liveness value the projection cannot produce.
    for {slug, reading} <- readings do
      refute reading =~ "terminal", "#{slug} rendered a liveness value that does not exist"
    end

    # The UNBOUND leg: a term the reader table does not bind omits the part even
    # with a run fully in scope, and confesses the omission rather than leaving a
    # silent gap. The checker reads the heading as a NODE, so the confession
    # naming the part cannot be mistaken for the part itself.
    unbound = result["on_this_run_unbound"]
    assert unbound["family"] == "on_this_run_unbound"
    assert unbound["confession"] =~ "This pane does not read a run-scoped value for this term"

    # BOTH classes of unbound term are driven, because only one of them can
    # falsify the confession. `read-only` is genuinely instrument-scoped, so any
    # wording survives it -- that is precisely why exercising it alone let a
    # false explanation ship. `mutation` sits in the `dimensions` concern and
    # this same projection carries `run.mutation` for the rail to paint inches
    # away, so a confession that denies the TERM a run-scoped value is refuted
    # by the panel on the same screen.
    classes = unbound["classes"]
    assert length(classes) == 2

    assert Enum.map(classes, & &1["slug"]) == ["read-only", "mutation"]
    assert Enum.map(classes, & &1["class"]) == ["instrument", "rail_read"]

    # The rail-read case is driven with the dimension POPULATED, so the pane's
    # silence sits beside a value that actually exists rather than beside a gap.
    rail_read = Enum.find(classes, &(&1["class"] == "rail_read"))
    assert rail_read["rail_value"] == "workspace_applied"

    # The confession is about the PANE. It may not characterise the term, and it
    # must be the SAME sentence for both classes -- wording that varies by slug
    # is a curated split list that rots when a term changes buckets.
    for entry <- classes do
      # Matched in the ASSERTING form: the confession's own disclaimer denies
      # this inference in nearly these words, so a bare substring would refute
      # the sentence that protects the reader.
      refute entry["confession"] =~ "names a property of the instrument"
      refute entry["confession"] =~ "This term has no run-scoped value"
      assert entry["confession"] == unbound["confession"]
    end

    # The LIST-SCOPE degradation, driven through the order that actually
    # produces it: the run detail is visited FIRST, so a binding without the
    # scope guard would have a real snapshot to misread, then the runs list,
    # then `?`. The checker fails on any run-scoped reading here.
    list_scope = result["on_this_run_list_scope"]
    assert list_scope["family"] == "on_this_run_list_scope"
    assert list_scope["statement"] =~ "No run is in scope"
    assert list_scope["statement"] =~ "Runs list"

    # Both legs have their own red proofs. The detail leg's cuts the reader
    # dispatch, so every reader returns null and the family must go red on a
    # term that must have a value -- otherwise nineteen exact readings could be
    # asserting nothing about the accessors at all. The list leg's cuts the
    # no-run STATEMENT rather than the scope guard: `routeChanged` already nulls
    # `state.detail` on the runs route, so a removed guard would find nothing to
    # read and the degradation would look correct for the wrong reason. The
    # defect this leg must see is the silent one -- the part vanishing with no
    # word about scope.
    assert result["on_this_run_red_proof"]["family"] == "on_this_run_detail_scope"
    assert result["on_this_run_red_proof"]["detected"] == "on_this_run_not_rendered"
    assert result["list_scope_red_proof"]["family"] == "on_this_run_list_scope"
    assert result["list_scope_red_proof"]["detected"] == "list_scope_silent"

    # ── UNIT scope, executed ────────────────────────────────────────────────
    #
    # `manualRunInScope` admits `route.view === "unit"`, and until this family
    # existed nothing in the executed tier ever drove a unit route: every leg
    # above declares `expectView: "detail-view"`, so the unit branch of the
    # guard shipped entirely unexercised. What it shipped WITH was a reader
    # table that folded the run on every route, which put a run-wide number
    # under a heading reading ON THIS RUN while the Unit Inspector painted THAT
    # UNIT's value for the same dimension inches away -- two answers to one
    # question on one screen, with no wording naming which population either
    # number was a fold over.
    #
    # The checker opens the DISAGREEING unit: its gate is `held` where three
    # siblings are ready, its attention is required where three are not, and its
    # execution and liveness differ from the run's. Every reading below is
    # therefore a string the run fold could not produce, and the checker
    # additionally requires each one to differ from that slug's own run-scope
    # reading, so no expectation here can pass by coincidence.
    unit_scope = result["on_this_run_unit_scope"]
    assert unit_scope["family"] == "on_this_run_unit_scope"
    assert unit_scope["unit"] == "u3"
    assert unit_scope["as_of_seq"] == 34

    # Keyed by slug WITHIN a scope, never by slug alone. The leg drives several
    # units now -- the disagreeing one, a checkpoint-ready one, one with no
    # advisory, one with no attention record -- and each carries its own entry
    # for the same slugs. Folding them into one flat map let a later unit's
    # reading silently displace the one an assertion below names, which is the
    # same class of collapse the readings themselves are being checked for.
    unit_readings =
      unit_scope["readings"]
      |> Enum.filter(fn entry -> entry["scope"] in ["unit", "run"] end)
      |> Map.new(fn entry -> {entry["slug"], entry["reading"]} end)

    # The dimension the corpus DEFINES as per-unit ("the Unit Inspector's label
    # for the runtime's own gate decision on one unit"), answered about that
    # unit -- value AND basis -- which is the pair the "Runtime gate" truthCard
    # paints. Before this, the pane answered "1 held · 3 ready · basis unit
    # checkpoint fold" beside a card reading "held · Basis: workflow event":
    # both the value and the provenance were wrong for the term as its own
    # corpus entry defines it.
    assert unit_readings["runtime-gate"] ==
             "held · on this unit (u3) · basis workflow event · as of seq 34"

    # One dimension, two labels, so the rail's label cannot change the answer.
    assert unit_readings["dependency-gate"] == unit_readings["runtime-gate"]

    assert unit_readings["execution"] ==
             "queued · on this unit (u3) · basis subagent events · as of seq 34"

    assert unit_readings["liveness"] ==
             "stale handle · on this unit (u3) · basis delegate owner · as of seq 34"

    # A gate VALUE term, whose corpus surface_string is the single word "Ready".
    # At unit scope the honest answer is whether THIS unit is ready, not how
    # many of its siblings are.
    assert unit_readings["checkpoint-ready"] ==
             "Not ready — this unit reads held · on this unit (u3) · basis workflow event · as of seq 34"

    assert unit_readings["attention"] ==
             "required · on this unit (u3) · basis parent log · as of seq 34"

    assert unit_readings["parent-observed"] == unit_readings["attention"]

    # The RUN-scoped dimensions, driven on the SAME unit route. Source is
    # run-scoped by contract ("Source describes the evidence the view was built
    # from ... Source is run-scoped, never per unit"), no unit carries a
    # post-terminal record, and as-of seq is a position in the parent Log fold.
    # A reader that "helpfully" narrowed any of them to the opened unit would be
    # inventing a per-unit value no projection produces, so they keep saying
    # `on this run` while a unit is open.
    assert unit_readings["source-run-scoped"] ==
             "live · on this run · basis parent log · as of seq 34"

    assert unit_readings["child-after-end"] ==
             "No child events after the run ended · on this run · basis child log scan · as of seq 34"

    assert unit_readings["as-of-seq"] == "seq 34 · on this run"

    # ABSENCE, which the bucket vocabulary has no token for: the
    # `present === true` guard keeps it out of every count, and the corpus says
    # so outright under `unclassified verdict` -- "No advisory. Absence never
    # reaches a bucket." The Inspector card renders unit.advisory.verdict
    # through marker(), whose titleCase resolves the missing field to "unknown"
    # -- the very word the alias map exists to rename, because an unclassifiable
    # verdict and no verdict at all are different facts. This is the ONE place
    # the pane deliberately says something the card beside it does not, and it
    # says the true thing: the card's "Unknown" is a rendering artefact of a
    # missing field, not a verdict the projection asserts.
    absent_advisory =
      Enum.find(unit_scope["readings"], fn entry ->
        entry["scope"] == "unit_absent_advisory"
      end)

    assert absent_advisory["reading"] ==
             "no advisory · on this unit (u-no-advisory) · basis model declared · as of seq 34"

    refute absent_advisory["reading"] =~ "unclassified verdict"
    refute absent_advisory["reading"] =~ "unknown"

    # ── THE ONE TOKEN THE ALIAS RENAMES ─────────────────────────────────────
    #
    # Every gate expectation above opens u3, whose gate is `held` -- a token
    # GATE_DISPLAY_ALIASES leaves alone. So the family passed at full strength
    # while the pane and the Unit Inspector card printed DIFFERENT WORDS for
    # `checkpoint_ready`, the single value that map exists to rename: the pane
    # aliased it to "ready", the card rendered marker(unit.gate.state) ->
    # titleCase -> "checkpoint ready". Two words for one value, inches apart, on
    # the one route where the runtime-gate term's surface string appears. The
    # blind spot was structural -- no fixture unit in scope carried the token --
    # so the fixture now opens one.
    #
    # The pane QUOTES the surface it explains, so the shipped card wording
    # stands and the pane moves to it, through a SHARED label path
    # (unitGateLabel, one function, two call sites) rather than a second
    # transcription that can drift again.
    ready_by_slug =
      unit_scope["readings"]
      |> Enum.filter(fn entry -> entry["scope"] == "unit_checkpoint_ready" end)
      |> Map.new(fn entry -> {entry["slug"], entry["reading"]} end)

    assert ready_by_slug["runtime-gate"] ==
             "checkpoint ready · on this unit (u1) · basis workflow event · as of seq 34"

    # One dimension, two labels, one reader: the rail's label cannot change the
    # word either.
    assert ready_by_slug["dependency-gate"] == ready_by_slug["runtime-gate"]

    # The distribution's word for a COUNT must not leak into a statement about
    # ONE unit's state.
    refute ready_by_slug["runtime-gate"] =~ ~r/(^|[^ ])ready · on this unit/

    # The VALUE term keeps its OWN corpus surface string ("Ready") -- that is
    # the word the reader clicked -- while the dimension quotes the card. The
    # two are different questions, so they are allowed different words.
    assert ready_by_slug["checkpoint-ready"] ==
             "ready · on this unit (u1) · basis workflow event · as of seq 34"

    # ── ABSENT IS NOT NO ────────────────────────────────────────────────────
    #
    # `required === true ? "yes" : "no"` collapsed THREE cases into two:
    # required, not required, and no attention record at all. A unit whose
    # projection carries no attention object therefore read "not required ·
    # basis parent log" -- a negative the projection never asserts, stamped with
    # a provenance that observed nothing. The parent Log is where a fact READ
    # off the record came from; with no record there is nothing for it to be the
    # basis of, so the honest reading claims no basis at all, exactly as
    # `as-of-seq` does.
    absent_attention =
      Enum.filter(unit_scope["readings"], fn entry ->
        entry["scope"] == "unit_absent_attention"
      end)

    assert length(absent_attention) == 2

    Enum.each(absent_attention, fn entry ->
      assert entry["reading"] =~ "No attention record on this unit"
      assert entry["reading"] =~ "on this unit (u-no-attention)"
      refute entry["reading"] =~ "not required"
      refute entry["reading"] =~ "basis parent log"
    end)

    # ── AND ONE BRANCH AWAY, THE RUN FOLD ───────────────────────────────────
    #
    # Stating absence honestly at unit scope while `runAttentionCounts` still
    # bucketed it as "no" left the identical defect at the more-travelled
    # run-detail route, wearing a number instead of a sentence: the SAME unit,
    # read at run scope, was counted into "N not required" under `basis parent
    # log`. A fabricated negative carrying a fabricated basis is not made
    # honest by being summed with true ones.
    #
    # The fold now excludes what the projection did not assert, exactly as
    # `runAdvisoryCounts`'s `present === true` guard does -- the precedent the
    # unit-scope fix reasoned FROM, and the one place it had not followed
    # through. Five units in scope, one required, three asserting `required:
    # false`, one silent: the honest fold counts four and names three of them
    # "not required".
    run_absent_attention =
      Enum.filter(unit_scope["readings"], fn entry ->
        entry["scope"] == "run_absent_attention"
      end)

    assert length(run_absent_attention) == 2

    Enum.each(run_absent_attention, fn entry ->
      assert entry["reading"] ==
               "1 required · 3 not required · on this run · basis parent log · as of seq 34"

      # The shipped defect, pinned by the exact string it produced: the silent
      # unit swelling the negative bucket to four.
      refute entry["reading"] =~ "4 not required"
    end)

    # ── The UNIT-ABSENT leg ─────────────────────────────────────────────────
    #
    # `renderUnit` bails to renderUnavailable("This logical unit is absent or
    # its provisional deep link was invalidated.") WITHOUT clearing state.detail
    # -- unlike renderProjectionFailure, which nulls it -- so a scope guard
    # keyed on ROUTE SHAPE alone passed every identity check and the pane
    # rendered a live, basis-attributed, seq-stamped ON THIS RUN reading beside
    # a view declaring the projection unavailable. A positive claim about a run
    # the screen says it cannot show is the exact class the reader table exists
    # to prevent.
    #
    # The route is a REQUEST; the painted view is the RECEIPT. Scope is now
    # decided by what a renderer actually produced.
    unit_absent = result["on_this_run_unit_absent"]
    assert unit_absent["family"] == "on_this_run_unit_absent"
    assert unit_absent["statement"] =~ "No run is in scope"

    # The copy points at the view rather than diagnosing on its own: the view
    # beside the pane already says what went wrong, and a pane repeating a
    # diagnosis it did not make is speaking beyond its evidence.
    assert unit_absent["statement"] =~ "the view beside this pane is not painting one"

    # Driven across a per-unit slug and two run-scoped ones, because the defect
    # passed for BOTH: a fix narrowing only the per-unit family would leave
    # `execution` reading "running · basis parent log fold" beside "Projection
    # unavailable".
    assert Enum.sort(unit_absent["slugs"]) == ["as-of-seq", "execution", "runtime-gate"]

    # And the case that must stay GREEN, which is what keeps the fix from being
    # a blanket denial of unit scope. The SAME absent unit under follow paints
    # "Unit unavailable while following", whose own provenance states that "the
    # followed run identity is still projected. Only this logical unit is absent
    # within the followed run". The run really is on screen and really is the
    # followed one, so the pane reads it -- refusing there would make the pane
    # withhold a value the view beside it is affirming.
    assert unit_absent["follow_unit_unavailable_reading"] ==
             "running · on this run · basis parent log fold · as of seq 34"

    # Both new legs carry their own red proofs, and each reinstates the shipped
    # defect exactly rather than breaking something adjacent: the unit-scope
    # proof deletes the gate reader's unit branch so it folds the run on every
    # route, and the unit-absent proof deletes the painted-view check so the
    # guard keys on route shape alone again.
    assert result["unit_scope_red_proof"]["family"] == "on_this_run_unit_scope"
    assert result["unit_scope_red_proof"]["detected"] == "unit_scope_wrong_reading"
    assert result["unit_absent_red_proof"]["family"] == "on_this_run_unit_absent"
    assert result["unit_absent_red_proof"]["detected"] == "unit_absent_read_a_run"

    # And the two remediations carry their own, each reinstating the SHIPPED
    # defect exactly: the gate-word proof sends unitGateLabel back through the
    # distribution aliases (the pane's old transcription), and the attention
    # proof deletes the absence branch so `required === true ? "yes" : "no"`
    # collapses absence into the negative again. Both were invisible to the
    # fixture before this commit widened it.
    assert result["unit_gate_word_red_proof"]["family"] == "on_this_run_unit_scope"

    assert result["unit_gate_word_red_proof"]["detected"] ==
             "unit_gate_word_diverged_from_card"

    assert result["unit_absent_attention_red_proof"]["family"] == "on_this_run_unit_scope"

    assert result["unit_absent_attention_red_proof"]["detected"] ==
             "unit_absent_attention_read_as_no"

    # The run fold gets its OWN red proof rather than riding the unit one,
    # because that is precisely how the surviving branch stayed invisible: the
    # unit assertions fire first and would have absorbed a shared tamper,
    # leaving a fold that still counts absence as "no" unexercised behind a
    # green proof. This one restores the collapse to runAttentionCounts ALONE,
    # so the run-scope assertion is the only thing that can catch it.
    assert result["run_absent_attention_red_proof"]["family"] == "on_this_run_unit_scope"

    assert result["run_absent_attention_red_proof"]["detected"] ==
             "run_absent_attention_counted_as_no"

    # ── The STREAM TRANSITION ────────────────────────────────────────────────
    #
    # Every family above enters through `hashchange`. This one enters through
    # the SSE stream, and it is the path where nothing generic protects focus at
    # all.
    #
    # The runs list paints `.stream-vocabulary`, a sentence that QUOTES the SSE
    # health pill, and each quoted term is a native `<a href>` built by
    # `labelledTerm` — a real tab stop on the first screen. The pill's wording
    # is state-dependent ("coalesced" is emitted on the connected state alone),
    # so `setStatus` refills that sentence when the observed vocabulary changes,
    # and refilling calls `replaceChildren()` on the subtree holding those
    # anchors.
    #
    # `source.onopen` and `source.onerror` call `setStatus` DIRECTLY: no view
    # re-render, so `replaceContent` never runs and `restoreView` never runs.
    # An operator tabbing into the first screen during the `connecting` window —
    # where every page load starts, and the authoritative fetch routinely paints
    # the runs list before the stream opens — had focus collapsed to
    # `document.body` seconds later by `connecting -> connected`, with no action
    # of their own, and the next Tab restarted at the top of the document.
    #
    # A same-state guard in `setStatus` cannot reach that: a same-state render is
    # exactly the case where the repaint is unnecessary, while every REAL
    # transition is a case where it must happen AND focus must survive it. The
    # preservation therefore lives inside `repaintStreamVocabularyLine`, with the
    # destruction it protects against, so it holds for every caller — including
    # the two that have no re-render anywhere near them.
    stream = Map.new(result["stream_scenarios"], fn entry -> {entry["name"], entry} end)

    assert stream |> Map.keys() |> Enum.sort() == [
             "a_transition_does_not_steal_focus_from_another_line",
             "initial_open_keeps_focus_on_hints_only",
             "initial_open_keeps_focus_on_last_refetch",
             "stream_down_keeps_focus_on_surviving_term",
             "stream_down_lands_in_line_when_the_held_term_vanishes"
           ]

    # A term that survives the transition keeps the operator exactly where they
    # were: they do not move at all.
    for name <- [
          "initial_open_keeps_focus_on_hints_only",
          "initial_open_keeps_focus_on_last_refetch",
          "stream_down_keeps_focus_on_surviving_term"
        ] do
      moved = stream[name]
      assert moved["focus_after"] == moved["focus_before"]
    end

    # And the case the same-key restore CANNOT serve: focus is standing on
    # "coalesced", which the down-state vocabulary legitimately drops. Landing
    # must stay inside the sentence rather than on document.body.
    vanished = stream["stream_down_lands_in_line_when_the_held_term_vanishes"]
    assert vanished["focus_before"] == "manual-term-label:front-door:coalesced:coalesced"
    assert vanished["focus_after"] == "manual-term-label:front-door:hints-only:hints only"

    # The repaint's OWN reason for existing, held across the same transitions:
    # the sentence quotes the pill it sits under. A focus fix that simply froze
    # the line would satisfy every assertion above while reintroducing the
    # absent-text claim this arc was opened to remove.
    assert result["stream_quote_honesty"]["family"] == "stream_vocabulary_quote"
    assert result["stream_quote_honesty"]["connected_quotes_coalesced"] == true
    assert result["stream_quote_honesty"]["down_drops_coalesced"] == true

    connected = stream["initial_open_keeps_focus_on_hints_only"]
    refute connected["quoted_before"] =~ "coalesced"
    assert connected["quoted_after"] =~ "hints only and coalesced"
    assert connected["pill"] =~ "SSE connected · hints only · coalesced"

    down = stream["stream_down_keeps_focus_on_surviving_term"]
    assert down["quoted_before"] =~ "coalesced"
    refute down["quoted_after"] =~ "coalesced"
    assert down["pill"] =~ "SSE down · hints only"

    # THREE red proofs, because the family has three independent halves and no
    # one of them can speak for the others. The first cuts the focus capture and
    # restore inside the repaint — leaving the same-state guard in `setStatus`
    # entirely intact — and requires `connecting -> connected` to go red, which
    # is the precise claim that the guard was never the protection.
    assert result["stream_red_proof"]["family"] == "stream_vocabulary_focus"
    assert result["stream_red_proof"]["detected"] == "stream_focus_lost"

    # The second cuts ONLY the in-line fallback, leaving the same-key restore in
    # place. The proof above always drives a term that survives, where the
    # fallback is never reached; without this one the fallback would be untested
    # code shipping on the operator's behalf.
    assert result["stream_fallback_red_proof"]["family"] == "stream_vocabulary_focus_fallback"
    assert result["stream_fallback_red_proof"]["detected"] == "stream_focus_lost"

    # ── And the OTHER direction ──────────────────────────────────────────────
    #
    # A repaint that restored focus unconditionally would satisfy every
    # assertion above while introducing a worse defect: focus parked on an
    # anchor the repaint does not touch — the runs list also paints a dimension
    # front door of exactly the same kind of anchor — would be YANKED into the
    # orientation line every time the stream flickered. The capture is therefore
    # scoped to the repainted line, and this scenario stands deliberately
    # outside it.
    no_steal = stream["a_transition_does_not_steal_focus_from_another_line"]

    assert no_steal["focus_before"] == "manual-term-label:list-front-door:execution:Execution"
    assert no_steal["focus_after"] == no_steal["focus_before"]

    # Its own red proof, which is the only one of the three that watches focus be
    # TAKEN rather than lost. It widens the capture past the line — the natural
    # careless simplification, "just remember whatever was focused" — and
    # requires the scenario to go red on the theft.
    assert result["stream_scope_red_proof"]["family"] == "stream_vocabulary_focus_scope"
    assert result["stream_scope_red_proof"]["detected"] == "stream_focus_stolen"
  end
end
