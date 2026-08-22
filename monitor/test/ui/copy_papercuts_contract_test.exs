defmodule PixirMonitor.UI.CopyPapercutsContractTest do
  @moduledoc """
  Contract pins for issue #545: trailing presentation honesty. Truncation is
  one amber summary, remaining runs carry already-projected fields, empty
  delegate id is omitted, unclassified verdicts pluralize, and the normal
  empty safe-actions state is not amber.
  """

  use ExUnit.Case, async: true

  @js Path.expand("../../priv/static/app.js", __DIR__)
  @css Path.expand("../../priv/static/app.css", __DIR__)

  setup_all do
    {:ok, js: File.read!(@js), css: File.read!(@css)}
  end

  test "inventory truncation is one amber summary plus expandable details", %{js: js, css: css} do
    assert js =~ ~s|el("details", "inventory-limitation-disclosure")|
    assert js =~ ~s|text("summary", "Limitation details")|
    assert js =~ ~s|facts.append(field("Error kinds", labels.join(" · ")))|
    assert js =~ ~s|if (limitations.length === 1)|
    assert js =~ ~s|"Observed count limited: " + scalar(limitations[0].kind, "unknown_limitation")|
    assert js =~ "limitations.length > 1"
    assert css =~ ".inventory-limitation-disclosure"
  end

  test "limitation evidence keeps the run_log_limit confession without extra amber lines", %{js: js} do
    assert js =~ "Error kinds: "
    assert js =~ ~s|name !== "error_kinds" && name !== "dropped"|
    refute js =~ ~s|Limitation details: " + detailKeys.map(function (name) { return name + " " + scalar(details[name], "unknown"); }).join(" · ") + " · " + receiptBoundary, "limitation"|
    refute js =~ ~s|Error kinds: " + errorKindKeys.map(function (kind) { return kind + " " + scalar(errorKinds[kind], "unknown"); }).join(" · ") + " · " + receiptBoundary, "limitation"|
  end

  test "remaining runs render title, execution state, and started-at from the list row", %{js: js} do
    assert js =~ "function remainingRunLabel(row)"
    assert js =~ "row.title"
    assert js =~ "row.execution.state"
    assert js =~ ~s|temporalField(row, "started_at")|
    assert js =~ "projectedLink(remainingRunLabel(row)"
    refute js =~ "row.run.title || id"
  end

  test "an empty delegate id is omitted from the run overview", %{js: js} do
    assert js =~ "Delegate id"
    assert js =~ "entry[1] == null"
    assert js =~ ~s|entry[1] === ""|
    assert js =~ ~s|["Delegate id", run.run && run.run.delegate_id]|
  end

  test "unclassified verdict pluralizes at the distribution marker", %{js: js} do
    assert js =~ ~s|const ADVISORY_DISPLAY_ALIASES = Object.freeze({unknown: "unclassified verdict"});|
    assert js =~ "function pluralizeDistributionLabel(label, count)"
    assert js =~ ~s|if (label === "unclassified verdict") return "unclassified verdicts";|
    assert js =~ "pluralizeDistributionLabel(distributionValueLabel(name, aliases), count)"
  end

  test "empty safe actions are neutral and timestamps drop fractional seconds", %{js: js} do
    assert js =~ ~s|"No registered safe actions for " + kind + " " + scalar(contextId, "unknown") + ".", "empty-state"|
    assert js =~ "function displayInstant(value)"
    assert js =~ "Fractional seconds are evidence, not UI copy."
    assert js =~ "displayInstant(held.listObservedAt)"
    assert js =~ "displayInstant(heldObservedAt)"
    assert js =~ "displayInstant(latest.value)"
    assert js =~ "displayInstant(run.projected_at)"
  end
end
