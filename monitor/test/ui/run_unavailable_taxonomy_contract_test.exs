defmodule PixirMonitor.UI.RunUnavailableTaxonomyContractTest do
  @moduledoc """
  Contract pins for issue #543: structured `run_not_found` is not a snapshot
  outage. Three held-snapshot classes (id absent, child of a run_log_limit
  parent, parent-observed child) must not share the "Projection unavailable /
  relaunch or wait for convergence" page. Genuinely unfetchable projections
  keep today's copy.
  """

  use ExUnit.Case, async: true

  @js Path.expand("../../priv/static/app.js", __DIR__)
  @source Path.expand("../../lib/pixir_monitor/projection/source.ex", __DIR__)
  @workspace_set Path.expand("../../lib/pixir_monitor/workspace_set.ex", __DIR__)

  setup_all do
    {:ok, js: File.read!(@js), source: File.read!(@source), workspace_set: File.read!(@workspace_set)}
  end

  test "the client splits identity-loss from a genuine projection outage", %{js: js} do
    assert js =~ "function identityLossFailure(failure, route)"
    assert js =~ "function droppedParentEvidence(failure, route)"
    assert js =~ "function heldSnapshotReceipt(route)"
    assert js =~ "function snapshotIsHeld(route)"
    assert js =~ "function runsReturnLink(route)"
    refute js =~ "Return to Workspace Overview"
    assert js =~ ~s|link("Return to Runs", routeHash({workspace: route && route.workspace, view: "runs"}), "return-runs")|
    assert js =~ ~s|root.dataset.unavailableClass = "not_found"|
    assert js =~ ~s|root.dataset.unavailableClass = "dropped_parent"|
    assert js =~ ~s|root.dataset.unavailableClass = "resolved_child"|
    assert js =~ ~s|root.dataset.unavailableClass = "projection_unavailable"|
    assert js =~ ~s|heading(1, "Run not found")|
    assert js =~ ~s|heading(1, "Parent not projected")|

    assert js =~
             ~s|held ? "The requested id " + scalar(route.runId, "unknown") + " matched no projected run in the held snapshot." : "The requested id " + scalar(route.runId, "unknown") + " matched no projected run."|

    assert js =~ "The authoritative snapshot is held (as of "
    assert js =~ "This id is absent from it; nothing will converge."
    assert js =~ "exceeds the configured byte bound (run_log_limit)."
    assert js =~ "function appendDroppedParentCopy(root, route, dropped)"
    assert js =~ ~s|projectedLink(dropped.parentId, routeHash({workspace: route.workspace, runId: dropped.parentId}), "dropped-parent:" + dropped.parentId)|
    assert js =~ "waiting will not project the cap-dropped parent."
    assert js =~ "Held snapshot · requested id not found · as of "
    assert js =~ ~s|held ? "Held snapshot · parent unprojected · run_log_limit · as of " + asOf : "Parent unprojected · run_log_limit · list receipt is not yet held"|
    assert js =~ ~s|(held ? "Held snapshot · requested id is a parent-observed child · as of " + asOf : "Requested id is a parent-observed child · list receipt is not yet held")|
  end

  test "a direct detail 404 does not claim a held snapshot when the list receipt is absent", %{js: js} do
    unavailable =
      js
      |> String.split("function renderUnavailable(message, failure) {")
      |> Enum.at(1)
      |> String.split("function renderCurrent() {")
      |> hd()

    resolved =
      unavailable
      |> String.split(~s|root.dataset.unavailableClass = "resolved_child"|)
      |> Enum.at(1)
      |> String.split(~s|root.dataset.unavailableClass = "dropped_parent"|)
      |> hd()

    dropped =
      unavailable
      |> String.split(~s|root.dataset.unavailableClass = "dropped_parent"|)
      |> Enum.at(1)
      |> String.split(~s|root.dataset.unavailableClass = "not_found"|)
      |> hd()

    not_found =
      unavailable
      |> String.split(~s|root.dataset.unavailableClass = "not_found"|)
      |> Enum.at(1)
      |> String.split(~s|root.dataset.unavailableClass = "projection_unavailable"|)
      |> hd()

    assert resolved =~ ~s|held ? "Held snapshot · requested id is a parent-observed child · as of " + asOf : "Requested id is a parent-observed child · list receipt is not yet held"|
    refute resolved =~ "relaunch or wait for convergence"

    assert dropped =~
             ~s|held ? "The authoritative snapshot is held (as of " + asOf + "). This is not a fetch outage; waiting will not project the cap-dropped parent." : "The parent is not projected. This is not a fetch outage; the list receipt is not yet held. Waiting will not project the cap-dropped parent."|

    assert dropped =~ ~s|held ? "Held snapshot · parent unprojected · run_log_limit · as of " + asOf : "Parent unprojected · run_log_limit · list receipt is not yet held"|
    refute dropped =~ "relaunch or wait for convergence"

    assert not_found =~
             ~s|held ? "The requested id " + scalar(route.runId, "unknown") + " matched no projected run in the held snapshot." : "The requested id " + scalar(route.runId, "unknown") + " matched no projected run."|

    unheld_body =
      not_found
      |> String.split(
        ~s|held ? "The requested id " + scalar(route.runId, "unknown") + " matched no projected run in the held snapshot." : "|,
        parts: 2
      )
      |> Enum.at(1)
      |> String.split(~s|", "empty-state"|)
      |> hd()

    assert unheld_body == ~s|The requested id " + scalar(route.runId, "unknown") + " matched no projected run.|
    refute unheld_body =~ "held snapshot"
    refute unheld_body =~ "Held snapshot"

    assert not_found =~ ~s|held ? "The authoritative snapshot is held (as of " + asOf + "). This id is absent from it; nothing will converge." : "No projected run matched this id."|
    assert not_found =~ ~s|held ? "Held snapshot · requested id not found · as of " + asOf : "Requested id not found in the snapshot."|
    assert not_found =~ ~s|held ? "Run not found in the held snapshot." : "The requested id is not a projected run."|
    refute not_found =~ "relaunch or wait for convergence"
    refute unavailable =~ ~s|setStatus("Held snapshot ·|
  end

  test "a genuine unfetchable projection keeps today's outage copy", %{js: js} do
    assert js =~ ~s|heading(1, "Projection unavailable")|
    assert js =~ "The authoritative projection could not be fetched."
    assert js =~ "Snapshot unavailable; relaunch or wait for convergence."
    assert js =~ "Requested projection unavailable; return to Runs or relaunch."
  end

  test "structured run_not_found details survive fetch classification", %{js: js} do
    assert js =~ "failure.details = details && typeof details === \"object\" && !Array.isArray(details) ? details : null;"
    assert js =~ "details.parent_unprojected_reason"
    assert js =~ "details.parent_session_id"
    assert js =~ ~s|reason === "run_log_limit" && parentId|
  end

  test "the source confesses an already-known dropped parent without a new inventory policy", %{
    source: source
  } do
    assert source =~ "defp not_found_or_dropped_parent(id, history, workspace, opts)"
    assert source =~ ~s|parent_unprojected_reason: "run_log_limit"|
    assert source =~ "defp parent_session_id_from_history(history)"
    refute source =~ "child_to_parent"
  end

  test "workspace-set scoping preserves dropped-parent details", %{workspace_set: workspace_set} do
    assert workspace_set =~ "put_optional_session_id(details, :parent_session_id"
    assert workspace_set =~ "put_optional_reason(details, :parent_unprojected_reason"
  end

  test "held-snapshot receipt is scoped to the routed workspace in set mode", %{js: js} do
    receipt_fn =
      js
      |> String.split("function heldSnapshotReceipt(route) {")
      |> Enum.at(1)
      |> String.split("function snapshotIsHeld(route) {")
      |> hd()

    [set_branch, single_branch] = String.split(receipt_fn, "if (workspaceSetMode()) {", parts: 2)
    set_receipt = set_branch <> hd(String.split(single_branch, "if (state.lastAuthoritativeRefetchAt)"))

    assert receipt_fn =~ "if (workspaceSetMode()) {"
    assert set_receipt =~ "workspaceSnapshots[route.workspace]"
    assert set_receipt =~ "scoped.list && scoped.listObservedAt"
    refute set_receipt =~ "state.lastAuthoritativeRefetchAt"
    assert single_branch =~ "state.lastAuthoritativeRefetchAt"

    held_fn =
      js
      |> String.split("function snapshotIsHeld(route) {")
      |> Enum.at(1)
      |> String.split("function identityLossFailure(failure, route) {")
      |> hd()

    assert held_fn =~ ~s|if (workspaceSetMode()) {\n      const scoped = route && route.workspace ? workspaceSnapshots[route.workspace] : null;\n      return Boolean(scoped && scoped.list);\n    }|
    assert held_fn =~ "Boolean(state.lastAuthoritativeRefetchAt) || state.list !== null"
  end
end
