defmodule PixirMonitor.UI.PRReviewRepairsContractTest do
  use ExUnit.Case, async: true

  @app_js Path.expand("../../priv/static/app.js", __DIR__) |> File.read!()
  @app_css Path.expand("../../priv/static/app.css", __DIR__) |> File.read!()

  test "screen-reader-only content keeps the legacy clip and pins clip-path" do
    assert @app_css =~ "clip: rect(0, 0, 0, 0) !important; clip-path: inset(50%) !important;"
  end

  test "projected text visibly normalizes every separator and bidi control from U+2028 through U+202E" do
    assert @app_js =~ "(cp >= 0x2028 && cp <= 0x202e)"
    refute @app_js =~ "(cp >= 0x202a && cp <= 0x202e)"

    assert @app_js =~
             "(cp >= 0x2028 && cp <= 0x202e) || (cp >= 0x2066 && cp <= 0x2069)"
  end

  test "detail and unit renderers reject a stale run before constructing replacement content" do
    assert @app_js =~ """
           function renderDetail() {
               const run = state.detail; const route = parseRoute(location.hash);
               if (!run || !run.run || typeof run.run.id !== "string" || !run.run.id) return route.follow === true ? renderFollowSnapshotUnavailable(route, "Run projection is unavailable.") : renderUnavailable("Run projection is unavailable.");
               if (route.runId !== run.run.id) return route.follow === true ? renderFollowIdentityConflict(route, "The authoritative snapshot returned a different run identity than the one being followed.") : renderUnavailable("The requested run no longer matches this projection.");
               const root = el("div", "view detail-view");
           """

    assert @app_js =~ """
           function renderUnit() {
               const run = state.detail; const route = parseRoute(location.hash);
               if (!run || !run.run || typeof run.run.id !== "string" || !run.run.id) return route.follow === true ? renderFollowSnapshotUnavailable(route, "Run projection is unavailable.") : renderUnavailable("Run projection is unavailable.");
               if (route.runId !== run.run.id) return route.follow === true ? renderFollowIdentityConflict(route, "The authoritative snapshot returned a different run identity than the one being followed.") : renderUnavailable("The requested run no longer matches this projection.");
               const unit = array(run.units).find(function (candidate) { return candidate.logical_id === route.unitId; });
           """

    refute @app_js =~
             "setText(status, \"Read-only · \" + titleCase(run.source && run.source.mode) + \" projection · as of seq \" + scalar(run.source && run.source.as_of_seq, \"unknown\"));\n    if (route.runId !== run.run.id)"
  end

  test "stale fetch failures are suppressed before unavailable rendering while current failures propagate" do
    assert @app_js =~ "async function fetchJSON(path, expectedGeneration)"
    assert @app_js =~ ~s|projectionFailure("fetch", "projection_request_failed")|
    assert @app_js =~ ~s|projectionFailure("decode", "projection_response_invalid", response.status)|

    assert @app_js =~ """
                 if (expectedGeneration !== null && expectedGeneration !== state.generation) return SUPERSEDED;
                 return value;
               } catch (error) {
                 if (expectedGeneration !== null && expectedGeneration !== state.generation) return SUPERSEDED;
                 throw error;
               }
           """

    assert length(String.split(@app_js, "fetchJSON(")) == 6
    assert length(String.split(@app_js, "fetchJSON(\"/api/workspaces/\" + encodeURIComponent(workspace) + \"/runs\", null)")) == 2
    assert @app_js =~ "return refetchWorkspaceList(workspace, null)"
    assert @app_js =~ "await refetchWorkspaceList(workspace, null)"
    assert @app_js =~ "fetchJSON(\"/api/workspaces/\" + encodeURIComponent(workspace) + \"/runs\" + suffix, current)"
    assert @app_js =~ "fetchJSON(\"/api/runs\", current)"
    assert @app_js =~ "fetchJSON(\"/api/runs/\" + encodeURIComponent(route.runId), current)"
  end

  test "limited or truncated Runs inventory is confessed with structured text-only limitations" do
    assert @app_js =~
             "if (!inventory || (inventory.truncated !== true && !limitations.length)) return null;"

    assert @app_js =~
             "inventory.truncated === true ? \"Run inventory truncated\" : \"Run inventory limited\""

    assert @app_js =~
             "section.append(text(\"p\", \"Newest \" + scalar(inventory.selected, \"?\") + \" of \" + scalar(inventory.total, \"?\") + \" Session Logs selected.\"));"

    assert @app_js =~
             "item.append(untrustedText(\"strong\", limitation && limitation.kind));\n        item.append(untrustedText(\"p\", limitation && limitation.message));"

    assert @app_js =~
             "[[\"Maximum Logs\", details.max_logs], [\"Total Logs\", details.total], [\"Selected Logs\", details.selected], [\"Projected Runs\", details.projected_runs], [\"Non-run Session Logs\", details.non_parent_logs], [\"Unprojected Selected Logs\", details.dropped_logs]]"

    assert @app_js =~
             "projected runs: \" + scalar(inventoryFacts && inventoryFacts.projected_runs, all.length)"

    assert @app_js =~
             "root.append(text(\"p\", scanned, \"inventory-summary provenance\"));"

    assert @app_js =~
             "facts.append(field(\"Error kinds\", labels.join(\" · \")))"

    assert @app_js =~
             "const inventory = inventoryNotice(state.list); if (inventory) root.append(inventory);"

    refute @app_js =~ ".innerHTML"
    assert @app_css =~ ".inventory-notice { margin: 1rem 0; border: 2px solid var(--attention);"
  end

  test "pagination keys are scoped to run and logical-unit resources with bounded first pages" do
    # Workflow unit paging (state.pages unitPageKey) was replaced by the frozen
    # semantic-zoom contract (#336/#348): cluster member and exact-edge paging is
    # route-encoded per selected cluster/arc with contract-pinned bounds.
    assert @app_js =~ "const SEMANTIC_ZOOM_MAX_CLUSTERS = 6;"
    assert @app_js =~ "const SEMANTIC_ZOOM_MEMBER_PAGE_SIZE = 12;"
    assert @app_js =~ "const SEMANTIC_ZOOM_EDGE_PAGE_SIZE = 100;"
    refute @app_js =~ "unitPageKey"

    assert @app_js =~
             "const pageKey = \"evidence:\" + encodeURIComponent(run.run.id) + \":\" + encodeURIComponent(disclosureKey || \"all\"); const page = state.pages[pageKey] || 1;"

    assert @app_js =~
             "const attemptPageKey = \"attempts:\" + encodeURIComponent(run.run.id) + \":\" + encodeURIComponent(unit.logical_id);"

    assert @app_js =~
             "const selectedAttemptPage = selectedAttemptIndex < 0 ? 1 : Math.floor(selectedAttemptIndex / LIMITS.attempts) + 1;"

    assert @app_js =~
             "const page = Math.max(state.pages[attemptPageKey] || 1, selectedAttemptPage);"

    assert @app_js =~
             "const activityPageKey = \"activity:\" + encodeURIComponent(run.run.id) + \":\" + encodeURIComponent(unit.logical_id) + \":\" + encodeURIComponent(attempt.attempt_id); const activityPage = state.pages[activityPageKey] || 1;"

    assert @app_js =~
             "Object.freeze({runs: 50, units: 100, attempts: 20, evidence: 100, field: 32768, query: 256})"

    refute @app_js =~ "state.pages.units"
    refute @app_js =~ "state.pages.attempts"
  end

  # End-to-end absence coverage (real projection, missing unit, count copy +
  # unit_evidence_absent) lives in semantic_zoom_contract_test.exs; rendered
  # browser assertions belong to the #334/#337 surface.
  test "unprojected cluster members are disclosed as absent evidence, not paged navigation" do
    # The paged-out-vs-missing distinction moved into the semantic-zoom contract:
    # a wave member with no projected unit is disclosed as unit_evidence_absent
    # (never rendered as complete), summaries count observed members only, and
    # arcs touching unprojected units are marked affected.
    assert @app_js =~
             "entity.members.forEach(function (id) { if (!lookup[id]) values.push(\"unit_evidence_absent\"); });"

    assert @app_js =~
             "const observed = entity.members.filter(function (id) { return Boolean(lookup[id]); }).length;"

    assert @app_js =~ ~s|observed + " observed member" + (observed === 1 ? "" : "s")|
    # LIMITS.units no longer bounds Workflow DOM (semantic zoom owns those
    # bounds); the frozen LIMITS literal stays pinned in the pagination test.
  end

  test "fan-out bounds DOM per group over the full observed inventory instead of hiding unit 101" do
    # Contract change sanctioned by #338/#364: fan-out no longer renders a flat
    # unit list bounded by LIMITS.units; it derives grouped views from the FULL
    # observed inventory (honest counts) and bounds DOM per group at the frozen
    # member page size, with explicit +N continuation.
    assert @app_js =~ "const FANOUT_GROUP_MEMBER_PAGE_SIZE = 12;"
    assert @app_js =~ "const shown = group.members.slice(0, page * FANOUT_GROUP_MEMBER_PAGE_SIZE);"
    assert @app_js =~ "root.append(fanoutTree(run, route));"
    refute @app_js =~ "fanoutTree(boundedRun"
    refute @app_js =~ "array(run.units).slice(0, LIMITS.units).forEach"
  end

  test "bootstrap and later refresh signals share one request plus a trailing authoritative refresh" do
    assert @app_js =~ "refreshInFlight: null"
    assert @app_js =~ "refreshPendingReason: null"
    assert @app_js =~ "if (state.refreshInFlight) return state.refreshInFlight;"
    assert @app_js =~ "if (state.refreshPendingReason !== null) refreshSingleFlight(state.refreshPendingReason);"
    assert @app_js =~ "refreshSingleFlight(reason);"
    assert @app_js =~ "refreshSingleFlight(\"stream reconnect\")"
    assert @app_js =~ "refreshSingleFlight(\"stream error\")"
    assert @app_js =~ "const alreadyDown = state.streamState === \"down\";"
    assert @app_js =~ "if (!alreadyDown) refreshSingleFlight(\"stream error\")"
    assert @app_js =~ "refreshSingleFlight(\"initial load\");\n    connect();"
    refute @app_js =~ "refresh(\"initial load\")"
    assert @app_js =~ "state.generation += 1;"

    assert @app_js =~
             "if (state.refreshInFlight) state.refreshPendingReason = \"navigation\";"

    assert @app_js =~ "else refreshSingleFlight(\"navigation\");"
  end
end
