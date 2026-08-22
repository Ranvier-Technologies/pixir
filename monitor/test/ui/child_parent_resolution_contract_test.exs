defmodule PixirMonitor.UI.ChildParentResolutionContractTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Contract pins for issue #438: a `run_not_found` dead end whose requested id is
  an exact parent-observed child in the held authoritative inventory must NAME
  the owning parent run and offer a directed link to it, without ever redirecting
  by itself and without widening list scope.

  The behavioral core (exact-equality resolution, ambiguity, non-resolution) is
  EXECUTED in `PixirMonitor.PresenterUiSeamTest` via the frozen
  `resolveParentObservedChild` seam. These pins cover what source text alone can
  hold: the wiring into the two dead-end renderers, the honest provenance copy,
  the byte-identical unresolved degrade, workspace scoping, and the absence of
  any new endpoint, index, or automatic navigation.
  """

  @js Path.expand("../../priv/static/app.js", __DIR__)
  @css Path.expand("../../priv/static/app.css", __DIR__)
  @router Path.expand("../../lib/pixir_monitor/router.ex", __DIR__)
  @source Path.expand("../../lib/pixir_monitor/projection/source.ex", __DIR__)

  setup_all do
    {:ok, js: File.read!(@js), css: File.read!(@css), router: File.read!(@router), source: File.read!(@source)}
  end

  describe "resolution primitive" do
    test "resolution is a pure exact-equality scan over held inventory rows, exported on the frozen seam", %{js: js} do
      assert js =~ "function resolveParentObservedChild(sessionId, rows)"
      # Exact equality between two strings: no includes/startsWith/toLowerCase,
      # and a non-string session_id is rejected before comparison rather than
      # coerced into a value that could collide with a real requested id.
      assert js =~ ~S{if (typeof child.session_id !== "string" || child.session_id !== sessionId) return;}
      assert js =~ "resolveParentObservedChild: resolveParentObservedChild"
    end

    test "the resolver reads the held list snapshot only and never enumerates child Logs", %{js: js} do
      assert js =~ "function heldInventoryRows(route)"
      assert js =~ "listRows(state.list)"
      # No new endpoint: the only fetched paths remain the run list and run detail.
      refute js =~ "/api/children"
      refute js =~ "/api/resolve"
      refute js =~ ~s|"/api/runs/" + encodeURIComponent(route.runId) + "/children"|
      # No persisted index on the client either.
      refute js =~ "localStorage"
      refute js =~ "sessionStorage"
      refute js =~ "indexedDB"
    end

    test "an unheld inventory is acquired through the ordinary authoritative list path, never fabricated", %{js: js} do
      assert js =~ "function acquireInventoryForResolution(route)"
      # The workspace-set branch reuses the ordinary list refetch verbatim
      # rather than opening a second network surface.
      assert js =~ ~s|? refetchWorkspaceList(route.workspace, null)|
      # Single mode commits under the navigation generation captured BEFORE the
      # request, so a late acquisition cannot overwrite a newer state.list after
      # the operator has navigated away. Passing null here would disable the
      # SUPERSEDED gate entirely.
      refute js =~ ~s|fetchJSON("/api/runs", null)|
      assert js =~ "const acquisitionGeneration = state.generation;"
      assert js =~ ~s|fetchJSON("/api/runs", acquisitionGeneration)|

      assert js =~
               "if (payload === SUPERSEDED || acquisitionGeneration !== state.generation) return;"

      # Bounded TERMINALLY, per resolved-for id. An in-flight-only guard is not
      # enough: the acquisition's own repaint re-enters this call site, so a
      # guard released before the repaint runs loops forever whenever the
      # acquired inventory is empty or failed. The per-id attempt marker is
      # recorded BEFORE the request and is not cleared by the acquisition.
      assert js =~
               "if (state.resolutionInFlight || state.resolutionAttemptedFor === route.runId) return;"

      assert js =~ "state.resolutionAttemptedFor = route.runId;"
      # The in-flight handle is released only AFTER the repaint has run.
      assert js =~ "} finally { state.resolutionInFlight = null; }"
      # Only a change of resolved-for id returns the acquisition budget.
      assert js =~
               "if (state.resolutionAttemptedFor !== null && state.resolutionAttemptedFor !== nextResolutionFor) state.resolutionAttemptedFor = null;"
    end

    test "the acquisition boundedness is EXECUTED, not merely pinned here", %{js: _js} do
      # The pins above cannot observe a loop. The executing tier that can lives
      # in PixirMonitor.UI.ChildResolutionAcquisitionTest, which drives the real
      # acquisition/repaint cycle in node:vm and asserts an exact authoritative
      # request count. This assertion keeps the two files tied together so the
      # executing tier cannot be deleted while these pins keep passing.
      checker = Path.expand("../support/child_resolution_acquisition_check.mjs", __DIR__)
      test_file = Path.expand("child_resolution_acquisition_test.exs", __DIR__)
      assert File.exists?(checker)
      assert File.exists?(test_file)
      assert File.read!(test_file) =~ "child_resolution_acquisition_check.mjs"
    end
  end

  describe "the dead end names the owning parent and offers a directed exit" do
    test "the Follow degraded view renders the resolved-parent affordance alongside Retry, Refetch, and Unfollow", %{js: js} do
      assert js =~ "function parentResolutionPanel(route, options)"
      assert js =~ "const resolution = parentResolutionPanel(route);"
      assert js =~ "if (resolution) root.append(resolution);"
      # The three existing exits are untouched and still present.
      assert js =~ ~s|button(options.retryLabel,|
      assert js =~ ~s|button("Refetch authoritative snapshot", function () { refreshSingleFlight(options.retryReason); }, "continuation")|

      assert js =~
               ~s|link("Unfollow and return to Runs", semanticZoomRoute(route, {runId: null, unitId: null, attemptId: null, follow: false}), "return-runs")|
    end

    test "the non-follow resolved-child page headlines the resolution, not Projection unavailable", %{js: js} do
      assert js =~ "function renderUnavailable(message, failure)"
      assert js =~ ~s|parentResolutionPanel(route, {headline: true})|
      assert js =~ ~s|root.dataset.unavailableClass = "resolved_child"|
      assert js =~ "root.append(resolution);"
      refute js =~ ~s|const unavailableResolution = parentResolutionPanel(route);|
    end

    test "the panel only appears for a run-scoped run_not_found route", %{js: js} do
      assert js =~ ~S{if (!route.runId || state.resolutionFor !== route.runId) return null;}
      assert js =~ "const candidates = resolveParentObservedChild(route.runId, heldInventoryRows(route));"
      assert js =~ "if (!candidates.length) return null;"
    end

    test "the offered target deep-links to the owning logical unit when one was identified, and to the parent run otherwise", %{js: js} do
      assert js =~
               ~s|const target = candidate.unitId ? routeHash({workspace: route.workspace, runId: candidate.runId, unitId: candidate.unitId, filters: route.filters, sort: route.sort, q: route.q}) : routeHash({workspace: route.workspace, runId: candidate.runId, filters: route.filters, sort: route.sort, q: route.q});|

      assert js =~
               ~s|const label = "Open parent run " + candidate.runId + (candidate.unitId ? " → logical unit " + candidate.unitId : " (owning logical unit not identified in parent evidence)");|

      assert js =~ ~s|"parent-resolution-" + candidate.runId|
    end

    test "ambiguity offers every in-scope candidate parent explicitly and selects none", %{js: js} do
      assert js =~
               ~s|candidates.length > 1 ? "This Session id is observed as a child by " + candidates.length + " parent runs in the held inventory. No parent was selected for you; choose one." : "This Session id is a parent-observed child of the run below."|

      assert js =~ "candidates.forEach(function (candidate) {"
      # Every candidate becomes its own labeled link; none is auto-followed.
      refute js =~ "location.hash = target;"
      refute js =~ "location.replace(target)"
    end

    test "the affordance carries parent-Log provenance and claims nothing about the child Session", %{js: js} do
      assert js =~
               ~s|"Basis: parent-observed child evidence from parent Session Logs only. The child Session itself was not projected, fetched, or observed for liveness; no freshness is claimed for it."|

      assert js =~ ~s|heading(options && options.headline ? 1 : 2, "Parent-observed child Session")|
    end

    test "the panel is announced and reachable on the same accessibility path as the other dead-end actions", %{js: js, css: css} do
      assert js =~ ~s|section.setAttribute("role", "status")|
      assert js =~ ~s|el("section", "parent-resolution")|
      assert js =~ ~s|setStatus(options.status + resolutionStatusSuffix(route));|
      assert js =~ "function resolutionStatusSuffix(route)"
      assert js =~ ~s| · owning parent run resolved from parent-observed child evidence|
      assert css =~ ".parent-resolution"
    end
  end

  describe "non-resolution degrades exactly as before" do
    test "the unresolved degraded state keeps its title, provenance, status line, and action set byte-identical", %{js: js} do
      assert js =~ ~s|title: "Follow degraded",|

      assert js =~
               ~s|provenance: "The followed run is not projected in the authoritative snapshot. Follow never silently switches to another run; it degrades here deterministically.",|

      assert js =~
               ~s|status: "Follow degraded · followed identity unavailable · authoritative snapshots remain available"|

      assert js =~ ~s|retryLabel: "Retry followed run",|
      assert js =~ ~s|announcement: "Follow degraded. " + message,|
      # With no candidates the suffix contributes nothing at all.
      assert js =~ ~s|return candidates.length ? " · owning parent run resolved from parent-observed child evidence" : "";|
    end

    test "resolution is scoped to the routed workspace in workspace-set mode", %{js: js} do
      assert js =~
               ~s|if (workspaceSetMode()) { const scoped = workspaceSnapshots[route.workspace]; return scoped && scoped.list ? listRows(scoped.list.snapshot) : []; }|

      # The resolved target inherits the routed workspace, never another one.
      assert js =~ ~s|routeHash({workspace: route.workspace, runId: candidate.runId|
    end

    test "no partial, fuzzy, or speculative match is offered", %{js: js} do
      refute js =~ "resolveParentObservedChild(route.runId.slice"
      refute js =~ "session_id.startsWith"
      refute js =~ "session_id.includes"
    end
  end

  describe "list scope and server surfaces are unchanged" do
    test "the run source still admits parents only and still returns the structured run_not_found error", %{router: router, source: source} do
      assert router =~ ~s|{:error, %{kind: "run_not_found"} = error} -> send_json(conn, 404, %{error: error})|
      assert source =~ ~s|"children" => list_children(subs, workflow_index)|
      assert source =~ "defp list_children(subs, workflow_index) do"
      # Children are still a per-parent projected field, not inventory rows.
      refute source =~ ~s|"runs" => parent_rows ++ child_rows|
    end

    test "no server-side child-to-parent index is written for this purpose", %{source: source} do
      refute source =~ "child_to_parent"
      refute source =~ "child_index"
    end
  end
end
