defmodule PixirMonitor.TriageHonestyMobileTest do
  use ExUnit.Case, async: true

  @js Path.expand("../../priv/static/app.js", __DIR__)
  @css Path.expand("../../priv/static/app.css", __DIR__)

  # Mirror of the frozen JS pagination contract in app.js (attentionRowBudget):
  # at or below the declared cap every attention row is rendered; above the cap
  # the DOM stays bounded by page * LIMITS.runs with exact shown/total counts.
  @attention_render_all_cap 200
  @runs_page_limit 50

  setup_all do
    {:ok, js: File.read!(@js), css: File.read!(@css)}
  end

  defp attention_row_budget(total, page) do
    if total <= @attention_render_all_cap do
      total
    else
      min(total, page * @runs_page_limit)
    end
  end

  test "attention labels state the parent-observed basis and never claim global health", %{js: js} do
    assert js =~ ~s|"Needs attention · " + total + " parent-observed"|
    assert js =~ "No parent-observed attention. Absence of attention rows is a parent-Log observation, not a global health claim."
    assert js =~ ~s|label: "Attention (parent-observed)"|
    assert js =~ ~s|yes: "Parent-observed attention", no: "No parent-observed attention"|
    assert js =~ "Attention observed: "
    assert js =~ "parent Log only"
    refute js =~ "Healthy"
    refute js =~ "healthy\""
  end

  test "attention filter vocabulary stays binary with no synthetic unknown bucket", %{js: js} do
    assert js =~ ~s|attention: ["yes", "no"]|
    refute js =~ ~s|attention: ["yes", "no", "unknown"]|
    refute js =~ "unknown-attention"
    refute js =~ "const values = name === \"attention\""
  end

  test "units without registered safe actions expose an explicit limitation and projected identifier", %{js: js} do
    assert js =~ ~s|"No registered safe actions for " + kind + " " + scalar(contextId, "unknown")|
    assert js =~ "Registered copy_only actions are the only executable affordance the monitor ever offers."
    assert js =~ ~s|actionsPanel(run.safe_actions, "run", run.run.id)|
    assert js =~ ~s|actionsPanel(unit.safe_actions, "logical unit", unit.logical_id|
    assert js =~ ~s|const projectedAttemptId = selectedAttemptIndex >= 0 ? route.attemptId : null;|
    assert js =~ ~s|projectedAttemptId ? " · attempt " + projectedAttemptId : ""|
    refute js =~ ~s|route.attemptId ? " · attempt " + route.attemptId : ""|
    refute js =~ "No structured safe actions are projected."
  end

  test "clipboard is escaped-only through a single sink with no raw-byte path", %{js: js} do
    assert js =~ ~s|navigator.clipboard.writeText(escapedEvidence(scalar(value, "")))|
    # Exactly one clipboard write invocation exists in the bundle, and it escapes.
    assert length(String.split(js, ".writeText(")) == 2
    assert js =~ "Escaped-only clipboard is frozen for v1.x. No raw-byte copy exists."
    refute js =~ "Review raw copy"
    refute js =~ "Confirm raw bytes copy"
    refute js =~ "Raw command bytes"
    refute js =~ "raw bytes copied"
    assert js =~ "function escapedEvidence(raw)"
    # Hostile text stays literal on screen: display sinks remain textContent-only.
    assert js =~ "node.textContent ="
    refute js =~ "inner" <> "HTML"
  end

  test "attention pagination cap is declared, deterministic at, below, and above the cap", %{js: js} do
    assert js =~ "const ATTENTION_RENDER_ALL_CAP = 200;"
    assert js =~ "function attentionRowBudget(total, page, cap)"

    assert js =~
             ~s|const budget = group === "Needs attention" ? attentionRowBudget(grouped[group].length, page, ATTENTION_RENDER_ALL_CAP) : page * LIMITS.runs;|

    assert js =~ "const rows = grouped[group].slice(0, budget)"
    assert js =~ ~s|rows.length + " of " + grouped[group].length + " shown, "|
    assert js =~ ~s|(grouped[group].length - rows.length) + " remaining)"|
    assert js =~ "Attention is never hidden behind healthy-row pagination."
    assert js =~ "attentionRenderAllCap: ATTENTION_RENDER_ALL_CAP"
    assert js =~ "attentionRowBudget: attentionRowBudget"

    # Below the cap: all attention rows render on page 1.
    assert attention_row_budget(150, 1) == 150
    # At the cap: still render-all.
    assert attention_row_budget(200, 1) == 200
    # Above the cap: bounded DOM with explicit show-next paging.
    assert attention_row_budget(201, 1) == 50
    assert attention_row_budget(201, 4) == 200
    assert attention_row_budget(201, 5) == 201
    assert attention_row_budget(1000, 2) == 100
  end

  test "attention final page restores focus to its stable group heading", %{js: js} do
    assert js =~ ~s|const groupFocusKey = "run-group:" + pageKey;|
    assert js =~ ~s|key(groupHeading, focusKey); groupHeading.tabIndex = -1; section.append(groupHeading);|

    assert js =~
             ~s|if (nextBudget >= grouped[group].length) { state.restore = captureView(); state.restore.focus = groupFocusKey; }|
  end

  test "390x844 renders stacked triage cards with labeled facts and no document scroll", %{js: js, css: css} do
    for label <- ["Run", "Execution", "Gate", "Advisory", "Source", "Latest"] do
      assert js =~ ~s|"#{label}")|
    end

    assert js =~ "function cellLabel(node, name) { node.dataset.cellLabel = name; return node; }"
    assert css =~ "@media (max-width: 480px)"
    assert css =~ ".runs-table, .runs-table tbody, .runs-table tr, .runs-table td { display: block; }"
    assert css =~ "content: attr(data-cell-label)"
    assert css =~ ".table-scroll { overflow-x: visible; }"
    assert css =~ ".source-degradation { align-items: stretch; flex-direction: column; }"
    assert css =~ ".remaining-runs-list"
    assert css =~ "@media (max-width: 640px)"
    assert css =~ ".cluster-overview { grid-template-columns: minmax(0, 1fr); }"

    assert css =~
             ".cluster-card, .aggregate-arcs, .cluster-inspector { min-width: 0; }"

    assert css =~
             ".cluster-inspector .unit-meta, .cluster-inspector .attempt-facts, .cluster-inspector .artifact-facts { grid-template-columns: 1fr; }"

    # Wider widths keep native tabular semantics via the pre-existing table rules.
    assert css =~ ".runs-table { min-width: 72rem; }"
    assert css =~ "overflow-x: auto"
  end

  test "minimum Tab and focus model is pinned", %{js: js, css: css} do
    assert js =~ "Tab/focus model (pinned minimum)"
    assert js =~ ~s|"continuation:" + pageKey|
    # Workflow unit paging was replaced by the semantic-zoom contract (#336/#348):
    # continuation focus keys now live on cluster member and exact-edge pagination.
    assert js =~ ~s|"members-next:" + selectedEntity.key|
    assert js =~ ~s|"edges-next:" + selectedArc.key|
    assert js =~ ~s|"continuation:" + attemptPageKey|
    assert js =~ ~s|"continuation:" + activityPageKey|
    assert js =~ ~s|"remaining-runs:" + workspace|
    assert js =~ ~s|return current.workspace + ":" + (current.runId ? current.runId + ":" : "");|
    assert js =~ "function clientStateKey(value, route) { return clientIdentity(route) + value; }"
    assert js =~ "data-focus-key"

    assert css =~
             ~s|a[data-focus-key="zoom-back"], a[data-focus-key$=":zoom-back"] { display: inline-block; margin: .35rem 0 .8rem; }|

    assert css =~ ":focus-visible"
  end
end
