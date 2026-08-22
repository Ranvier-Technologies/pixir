defmodule PixirMonitor.UI.DroppedLogsConfessionContractTest do
  @moduledoc """
  Contract pins for issue #542 slice A: every unprojected selected Log is named
  in the limitations payload, expand details carry per-id rows, and the #548
  orphan-child page links the already-named parent with size and kind from
  that same payload. One amber summary stays; details do not grow extra amber
  lines.
  """

  use ExUnit.Case, async: true

  @js Path.expand("../../priv/static/app.js", __DIR__)
  @css Path.expand("../../priv/static/app.css", __DIR__)

  setup_all do
    {:ok, js: File.read!(@js), css: File.read!(@css)}
  end

  test "expand details name every dropped Log instead of only counting kinds", %{js: js, css: css} do
    assert js =~ "function droppedLogsSummary(dropped)"
    assert js =~ "function droppedLogRowLabel(row)"
    assert js =~ "function appendDroppedLogRows(dropped)"
    assert js =~ "not projected (per-log cap) · the "
    assert js =~ " cap is one reason a Log lands here"
    assert js =~ ~s|Number(rank) === 1 ? "newest selected" : "selected rank " + scalar(rank, "unknown")|
    assert js =~ " · raise max_log_bytes"
    assert js =~ "const droppedRows = appendDroppedLogRows(details.dropped)"
    assert js =~ ~s|name !== "error_kinds" && name !== "dropped"|
    assert css =~ ".inventory-dropped-logs"
    assert css =~ ".inventory-dropped-log-rows"
  end

  test "the one-amber inventory summary stays; per-id rows are expand-only", %{js: js} do
    assert js =~ ~s|el("details", "inventory-limitation-disclosure")|
    assert js =~ ~s|text("summary", "Limitation details")|
    assert js =~ ~s|"Observed count limited: " + scalar(limitations[0].kind, "unknown_limitation")|
    refute js =~ ~s|untrustedText("p", droppedLogsSummary(rows), "limitation")|
    refute js =~ ~s|untrustedText("li", droppedLogRowLabel(row), "limitation")|
    assert js =~ "wrap.append(untrustedText(\"p\", droppedLogsSummary(rows)));"
    assert js =~ "list.append(untrustedText(\"li\", droppedLogRowLabel(row)));"
  end

  test "orphan-child page links the named parent with size and kind from the A payload", %{js: js} do
    assert js =~ "function droppedLogById(route, id)"
    assert js =~ "function appendDroppedParentCopy(root, route, dropped)"
    assert js =~ "droppedLogById(route, dropped.parentId)"
    assert js =~ ~s|projectedLink(dropped.parentId, routeHash({workspace: route.workspace, runId: dropped.parentId}), "dropped-parent:" + dropped.parentId)|
    assert js =~ "function droppedLogFactSuffix(fact)"
    assert js =~ ~s|bits.push(scalar(fact.bytes, "unknown") + " bytes")|
    assert js =~ "bits.push(scalar(fact.kind, \"unknown\"))"
    assert js =~ ~s|bits.push("raise max_log_bytes (" + scalar(fact.max_log_bytes, "unknown") + ")")|
    refute js =~ "child_to_parent"
  end

  test "mixed-kind summary does not hang every drop on the byte cap", %{js: js} do
    summary =
      js
      |> String.split("function droppedLogsSummary(dropped) {")
      |> Enum.at(1)
      |> String.split("function droppedLogRowLabel(row) {")
      |> hd()

    assert summary =~ ~s|row && row.kind === "run_log_limit"|
    assert summary =~ "capRows.length === count && capLabel"
    assert summary =~ "not projected (per-log cap)"
    assert summary =~ "capRows.length && capLabel"
    assert summary =~ ~s|return count + " not projected"|
  end
end
