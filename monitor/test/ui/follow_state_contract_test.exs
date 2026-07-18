defmodule PixirMonitor.FollowStateContractTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Contract pins for issue #334: an explicit, route-represented Follow state.

  Follow is a refetch policy, not a stream state machine: it never patches truth
  from SSE hints and it never silently switches runs. These tests pin the SPA
  source contract the same way the existing UI contract tests do.
  """

  @js Path.expand("../../priv/static/app.js", __DIR__)
  @css Path.expand("../../priv/static/app.css", __DIR__)
  @router Path.expand("../../lib/pixir_monitor/router.ex", __DIR__)

  setup_all do
    {:ok, js: File.read!(@js), css: File.read!(@css), router: File.read!(@router)}
  end

  describe "follow state is explicit and represented in the route" do
    test "follow is parsed from and serialized to the hash route so it survives reload and back-forward", %{js: js} do
      assert js =~ ~s|const follow = params.get("follow") === "1";|
      assert js =~ ~s|if (route.runId && route.follow === true) params.set("follow", "1");|
      # Detail and unit routes carry follow; the runs list never does.
      # Detail routes gained the source-scoped workspace discriminator (#349);
      # follow still rides in the same position.
      assert js =~ ~s|{view: "detail", workspace: workspace, runId: routeSegments[1], filters: filters, sort: sort, q: q, follow: follow}|
      assert js =~ ~s|attemptId: params.get("attempt"), filters: filters, sort: sort, q: q, follow: follow}|
      assert js =~ ~s|{view: "runs", workspace: workspace, filters: filters, sort: sort, q: q, follow: false}|
      assert js =~ ~s|if (segments.some(function (segment) { return segment === null; })) return Object.assign({view: "invalid", filters: filters, sort: sort, q: q, follow: false}, zoom);|
    end

    test "follow is enterable and leavable from run selection via labeled links", %{js: js} do
      assert js =~ "function followToggle(run, route)"
      assert js =~ ~s|wrap.dataset.followState = route.follow === true ? "following" : "not_following";|
      assert js =~ ~s|link("Follow this run"|
      assert js =~ ~s|link("Unfollow"|
      assert js =~ ~s|"follow-on"|
      assert js =~ ~s|"follow-off"|
      # Rendered in both the run detail view and the unit inspector.
      assert js =~ "root.append(followToggle(run, route));"
    end

    test "unit and attempt navigation preserve the follow state", %{js: js} do
      # semanticZoomRoute merges the FULL route (follow + all zoom state) into
      # every context-preserving link: routeHash(Object.assign({}, route, changes)).
      assert js =~ "function semanticZoomRoute(route, changes)"
      assert js =~ "return routeHash(Object.assign({}, route, changes));"

      assert js =~
               ~s|projectedLink(unit.label, semanticZoomRoute(route, {runId: run.run.id, unitId: unit.logical_id})|

      assert js =~
               ~s|link("Select", semanticZoomRoute(activeRoute, {attemptId: attempt.attempt_id})|

      assert js =~
               ~s|semanticZoomRoute(activeRoute, {attemptId: predecessor.attempt_id})|
    end
  end

  describe "deterministic degradation" do
    test "identity disappearance while following renders the explicit Follow degraded view", %{js: js, router: router} do
      assert js =~ "function renderFollowErrorView(route, options, failure)"
      assert js =~ "function renderFollowDegraded(route, message, failure)"
      assert js =~ "function renderFollowIdentityConflict(route, message, failure)"
      assert js =~ "function renderFollowRenderFailure(route, message, failure)"
      assert js =~ ~s|followState: "identity_conflict",|
      assert js =~ ~s|followState: "degraded",|
      assert js =~ ~s|title: "Follow degraded",|
      assert js =~ "The followed run is not projected in the authoritative snapshot. Follow never silently switches to another run; it degrades here deterministically."

      assert js =~
               ~s|route.follow === true ? renderFollowIdentityConflict(route, "The authoritative snapshot returned a different run identity than the one being followed.") : renderUnavailable("The requested run no longer matches this projection.")|

      assert js =~
               ~s|provenance: "The authoritative snapshot contradicted the followed run identity. Follow did not switch runs or infer that the followed identity disappeared.",|

      assert router =~ ~s|{:error, %{kind: "run_not_found"} = error} -> send_json(conn, 404, %{error: error})|

      assert js =~ ~s|route.follow === true ? renderFollowSnapshotUnavailable(route, "Run projection is unavailable.") : renderUnavailable("Run projection is unavailable.")|
      assert js =~ "function renderFollowUnitUnavailable(route, message, failure)"
      assert js =~ ~s|renderFollowUnitUnavailable(route, "This logical unit is absent within the followed run's last authoritative snapshot or its provisional deep link was invalidated.")|
      assert js =~ ~s|retryLabel: "Retry followed unit",|
      assert js =~ "The followed run identity is still projected. Only this logical unit is absent within the followed run; Follow did not switch or lose the run."
      refute js =~ ~s|renderFollowDegraded(route, "This logical unit is absent within the followed run or its provisional deep link was invalidated.")|
    end

    test "degraded view offers explicit recovery, never an automatic switch", %{js: js} do
      # Follow-retry canonicalization preserves the full zoom context (Grok F4).
      assert js =~ ~s|const canonical = semanticZoomRoute(route, {follow: true});|
      assert js =~ ~s|retryLabel: "Retry followed run",|
      assert js =~ ~s|retryReason: "follow retry",|
      refute js =~ ~r/link\([^)]*Retry followed run/
      assert js =~ ~s|button("Refetch authoritative snapshot", function () { refreshSingleFlight(options.retryReason); }|
      # The return link stays scoped to the routed workspace in set mode
      # (semanticZoomRoute inherits it); single mode still yields #/runs.
      assert js =~
               ~s|link("Unfollow and return to Runs", semanticZoomRoute(route, {runId: null, unitId: null, attemptId: null, follow: false}), "return-runs")|

      assert js =~ ~s|status: "Follow degraded · followed identity unavailable · authoritative snapshots remain available"|
    end

    test "refetch failure while following preserves neutral snapshot diagnosis unless identity loss is evidenced", %{js: js} do
      assert js =~ "const failure = normalizeProjectionFailure(error);"
      assert js =~ "const message = projectionFailureMessage(failure);"
      assert js =~ "function renderFollowSnapshotUnavailable(route, message, failure)"
      assert js =~ ~s|failure.phase === "fetch" && failure.status === 404|

      assert js =~
               ~s/const authorityUnavailable = route.runId && (failure.phase === "fetch" || failure.phase === "decode");/

      assert js =~
               ~s/const identityLoss = route.runId && failure.phase === "fetch" && failure.status === 404 && failure.structured === true && failure.kind === "run_not_found";/

      assert js =~ "if (authorityUnavailable) {"
      assert js =~ "state.detail = null;"
      assert js =~ "state.detailConflict = false;"
      assert js =~ "failure.structured === true && failure.kind !== \"run_not_found\""
      assert js =~ "if (identityLoss) state.detailId = null;"
      assert js =~ "this response did not confirm identity and Follow did not infer loss."

      assert js =~
               ~s|if (identityLoss && route.follow === true) renderFollowDegraded(route, "The followed run is not projected in the authoritative snapshot.", failure);|

      assert js =~ ~s|else if (route.follow === true && route.runId) renderFollowSnapshotUnavailable(route, message, failure);|
      refute js =~ ~s|if (route.follow === true && route.runId) renderFollowDegraded(route, message, failure);|
      assert js =~ ~s|else renderUnavailable(message, failure);|
    end

    test "terminal and unavailable transitions of a followed run are made visible", %{js: js} do
      assert js =~ "if (run.execution && run.execution.terminal === true) wrap.append(labeledMarker(\"Followed run reached a terminal state: \""
      assert js =~ "if (liveness === \"owner_unavailable\" || liveness === \"stale_handle\") wrap.append(labeledMarker(\"Followed run is \""
    end

    test "follow surfaces are styled and announced", %{js: js, css: css} do
      assert css =~ ".follow-panel"
      assert css =~ ~s|.follow-panel[data-follow-state="following"]|
      assert css =~ ".follow-degraded"
      assert css =~ ".follow-unit-unavailable"
      assert css =~ ".follow-snapshot-unavailable"
      assert css =~ ".follow-identity-conflict"
      assert css =~ ".follow-render-failure"
      assert js =~ ~s|announcement: "Follow degraded. " + message,|
    end
  end

  describe "regression pins: existing restoration and hint discipline" do
    test "authoritative refetch captures and restores focus, disclosures, and scroll", %{js: js} do
      assert js =~ "function captureView()"
      assert js =~ "function restoreView(saved)"
      assert js =~ "const route = arguments.length ? {runId: arguments[0], workspace: arguments[1]} : parseRoute(location.hash);"

      assert js =~
               "{scrollX: window.scrollX, scrollY: window.scrollY, focus: active && active.dataset ? active.dataset.focusKey || null : null, open: open, runId: route.runId || null, workspace: route.workspace || null}"

      assert js =~ "state.restore = captureView();"
      assert js =~ "const saved = state.restore || captureView();"
      assert js =~ "window.scrollTo(saved.scrollX || 0, saved.scrollY || 0)"
      assert js =~ ~s|focusNode.focus({preventScroll: true})|
      assert js =~ ~s|document.querySelectorAll("details[data-disclosure-key]")|
    end

    test "route changes and page hide persist the view snapshot for back-forward restoration", %{js: js} do
      assert js =~ ~s|history.replaceState({pixirView: captureView()}, "", location.href)|
      assert js =~ "const savedRestore = history.state && history.state.pixirView ? history.state.pixirView : captureView(state.routeRunId, state.routeWorkspace);"
      assert js =~ "state.restore = savedRestore && savedRestore.runId === nextRouteRunId && (savedRestore.workspace || null) === nextRouteWorkspace ? savedRestore : null;"
      assert js =~ ~s|window.addEventListener("pagehide"|
    end

    test "SSE hints never patch projected truth: every anomaly converges through a bounded single-flight refetch", %{js: js} do
      # The handler never writes event payload data into list/detail state.
      assert js =~ "function handleInvalidation(event)"
      assert js =~ "refreshSingleFlight(reason);"
      refute js =~ "state.detail = JSON.parse(event.data)"
      refute js =~ "state.list = JSON.parse(event.data)"
      # Broader guard: no state property is ever assigned from a parsed event payload.
      refute js =~ ~r/state\.\w+\s*=\s*JSON\.parse/

      for reason <- ["malformed invalidation", "duplicate invalidation", "reordered invalidation", "invalidation gap", "stream reconnect", "stream error"] do
        assert js =~ reason
      end

      assert js =~ "if (parsed.valid && parsed.sequence !== null) state.lastEventId ="

      # Single-flight boundedness: one request in flight, one pending reason.
      assert js =~ "if (state.refreshInFlight) return state.refreshInFlight;"
      assert js =~ "if (state.refreshPendingReason !== null) refreshSingleFlight(state.refreshPendingReason);"
    end

    test "stale generations from in-flight navigation are discarded", %{js: js} do
      assert js =~ "if (expectedGeneration !== null && expectedGeneration !== state.generation) return SUPERSEDED;"
      assert length(String.split(js, "fetchJSON(")) == 6
      assert length(String.split(js, "fetchJSON(\"/api/workspaces/\" + encodeURIComponent(workspace) + \"/runs\", null)")) == 2
      assert js =~ "return refetchWorkspaceList(workspace, null)"
      assert js =~ "await refetchWorkspaceList(workspace, null)"
      assert js =~ "fetchJSON(\"/api/workspaces/\" + encodeURIComponent(workspace) + \"/runs\" + suffix, current)"
      assert js =~ "fetchJSON(\"/api/runs\", current)"
      assert js =~ "fetchJSON(\"/api/runs/\" + encodeURIComponent(route.runId), current)"
      assert js =~ "state.generation += 1;"
      assert js =~ ~s|if (state.refreshInFlight) state.refreshPendingReason = "navigation";|

      assert js =~
               "const matchingDetail = route.runId && state.detail && state.detailId === route.runId && (!workspaceSetMode() || state.detailWorkspace === route.workspace) && state.detail.run && state.detail.run.id === route.runId;"

      assert js =~ "const staleRoute = route.runId && (state.detailId && route.runId !== state.detailId || workspaceSetMode() && state.detailWorkspace && route.workspace !== state.detailWorkspace);"
      assert js =~ "const staleDetail = staleRoute || (route.runId && state.detail && !matchingDetail);"
      assert js =~ "const staleFollowView = route.runId && app.querySelector(\".error-view[data-follow-state]\") && (!matchingDetail || runChanged);"
      assert js =~ "const preserveSameRunFollowIdentity = route.follow === true && !runChanged && !state.detail && state.detailId === route.runId;"
      assert js =~ "state.detailId = preserveSameRunFollowIdentity ? route.runId : null;"
      assert js =~ "if (staleDetail || staleFollowView) {"
      assert js =~ "state.detail = null;"
      assert js =~ "state.detailId = null;"
      assert js =~ "const nextRouteRunId = route.runId || null;"
      assert js =~ "const runChanged = state.routeRunId !== nextRouteRunId || state.routeWorkspace !== nextRouteWorkspace;"
      assert js =~ "state.routeRunId = nextRouteRunId;"
      assert js =~ "if (runChanged) {"
      assert js =~ "state.pendingAttemptScroll = null;"
      assert js =~ "if (reconnecting) state.lastEventId = null;"
      assert js =~ "app.replaceChildren();"
      assert js =~ "delete app.dataset.errorPhase;"
      assert js =~ "if (forceRefetch) refreshSingleFlight(\"follow retry\");"
    end
  end
end
