defmodule PixirMonitor.UIPostTerminalChildActivityContractTest do
  @moduledoc """
  Presenter surface contract for #447 Phase 1.

  The signal must be visible at BOTH scopes — the Runs list row and the run
  detail truth rail — labeled with its basis and its child-Log provenance, in
  the same read-only, evidence-cited idiom as the existing truth cards. Nothing
  it renders may become actionable or mutating, and no copy may let it read as
  a reachability claim.
  """
  use ExUnit.Case, async: true

  @js Path.expand("../../priv/static/app.js", __DIR__)
  @css Path.expand("../../priv/static/app.css", __DIR__)
  @fixture_root Path.expand("../../priv/presenter/fixtures", __DIR__)

  setup_all do
    {:ok, js: File.read!(@js), css: File.read!(@css)}
  end

  test "the client accepts the enriched detail document instead of rejecting it as undecodable",
       %{js: js} do
    # The decode guard is an exact key allowlist. A required root field missing
    # from it turns every run detail into "projection response could not be
    # decoded", so the allowlist and the schema must move together.
    assert js =~
             ~s|const detailKeys = ["counts", "evidence", "execution", "graph", "limitations", "liveness", "mutation", "post_terminal_child_activity", "projected_at", "projection_id", "run", "safe_actions", "schema", "schema_version", "source", "units", "usage"];|
  end

  test "the run detail rail renders the dimension with basis and child-Log provenance", %{js: js} do
    assert js =~ ~s|rail.append(postTerminalCard(run.post_terminal_child_activity, route));|
    assert js =~ ~s|card.dataset.truthDimension = "post_terminal_child_activity";|
    # The heading is still an <h3> and still says exactly "Child activity after
    # end"; it is now the dotted labelled-term affordance rather than a plain
    # heading, so the reader can open the definition of the dimension. The
    # shipped string is unchanged — the labelled-term table absorbs the fact
    # that the list column calls the same dimension "Child after end".
    assert js =~ ~s|card.append(labelledTerm("h3", "Child activity after end", route));|

    # Basis, parent-derived boundary, and the child Sessions that supplied the
    # evidence are all visible, not inferred by the reader.
    assert js =~ ~s|marker(scalar(activity && activity.state, "unknown"), "post-terminal", activity && activity.basis)|
    assert js =~ ~s|"Parent terminal boundary: "|
    assert js =~ ~s|"Child Logs that supplied the evidence:"|
    assert js =~ ~s|"Reported, not reclassified: canonical execution and liveness are unchanged by this observation."|
  end

  test "the Runs list row renders the signal without opening the run", %{js: js} do
    assert js =~ ~s|"Duration", "Latest", "Child after end"|
    assert js =~ ~s|tr.append(cellLabel(postTerminalCell(row.post_terminal_child_activity), "Child after end"));|
    assert js =~ ~s|node.dataset.provenance = scalar(activity && activity.basis, "unknown");|
  end

  test "the copy never reads as a reachability or liveness claim", %{js: js} do
    assert js =~ ~s|" child events after the run ended"|
    assert js =~ ~s|"No child events after the run ended"|
    assert js =~ ~s|"Undetermined (child evidence unavailable)"|
    assert js =~ ~s|"Not applicable (run is not terminal)"|

    assert js =~
             ~s|"Child Log unavailable; absence of post-terminal activity is not asserted."|

    assert js =~
             ~s|"Boundary derived from parent Log evidence only; counted from child Log writes, not from any reachability observation."|

    # No copy in this surface claims the child is running, live, or reachable.
    refute js =~ "Child is still running"
    refute js =~ "child still live"
  end

  test "child-authored strings ride the existing untrusted-text sink", %{js: js} do
    # Timestamps and session ids come from a child Log. Every one of them goes
    # through untrustedText / projected, never a raw text sink.
    assert js =~
             ~s|if (activity && activity.latest_event_at) cell.append(untrustedText("span", scalar(activity.latest_event_at, "Unknown"), "absolute-ts"));|

    assert js =~ ~s|sessions.slice(0, LIMITS.evidence).forEach(function (sessionId) { const item = el("li"); projected(item, "code", sessionId); list.append(item); });|
  end

  test "the surface stays read-only: it adds no action, button, or handler", %{js: js} do
    card = between(js, "function postTerminalCard(activity, route) {", "\n  }\n")
    cell = between(js, "function postTerminalCell(activity) {", "\n  }\n")

    for source <- [card, cell] do
      refute source =~ "button("
      refute source =~ "addEventListener"
      refute source =~ "fetch("
      refute source =~ "clipboard"
      refute source =~ "safe_action"
    end
  end

  test "the observed and undetermined tones read as attention, the zero as muted", %{
    js: js,
    css: css
  } do
    assert js =~ ~s|"observed", "none", "undetermined"|
    assert css =~ ".marker-observed::before"
    assert css =~ ".marker-undetermined::before"
    assert css =~ ".marker-none::before { background: var(--muted); }"
    assert css =~ ".post-terminal-basis"
  end

  test "the golden nonzero scenario is the one the surface was built for" do
    golden =
      [@fixture_root, "golden", "post-terminal-child-resume.json"]
      |> Path.join()
      |> File.read!()
      |> Jason.decode!()

    activity = golden["post_terminal_child_activity"]

    assert activity["state"] == "observed"
    assert activity["event_count"] == 3
    assert activity["latest_event_at"] == "2026-07-30T10:41:00Z"
    assert activity["boundary_basis"] == "workflow_finished_event_ts"
    assert activity["child_session_ids"] == ["child-post-terminal"]

    # And it changed nothing else.
    assert golden["execution"]["state"] == "partial"
    assert golden["execution"]["terminal"] == true
    assert golden["execution"]["basis"] == "workflow_event_fold"
    assert golden["liveness"]["state"] == "not_applicable"
    assert golden["liveness"]["reachable"] == false
    assert "post_terminal_child_activity_observed" in golden["limitations"]
  end

  test "the projection contract documents the dimension and the Phase 2 decision" do
    doc =
      Path.expand("../../priv/presenter/projection-v1.md", __DIR__) |> File.read!()

    assert doc =~ "## Post-terminal child activity"
    assert doc =~ "It reports; it does not reclassify"
    assert doc =~ "child_events_after_parent_terminal_boundary"
    assert doc =~ "terminal_boundary_unavailable"
    assert doc =~ "post_terminal_child_activity_observed"
    assert doc =~ "Missing evidence never defaults to \"nothing"

    # Phase 2 decision, its sole linkage evidence, and its open dependency.
    assert doc =~ "### Phase 2 (decided, not shipped)"
    assert doc =~ "data.child_session_id"
    assert doc =~ "data.delegation_context.step_id"
    assert doc =~ "no durable child-Log record of the owning"
    assert doc =~ "DelegationContext"
    assert doc =~ "Phase 1 therefore deliberately **reports** rather than reclassifies."
  end

  defp between(source, from, to) do
    [_before, rest] = String.split(source, from, parts: 2)
    [body, _after] = String.split(rest, to, parts: 2)
    body
  end
end
