defmodule PixirMonitor.UI.ProvenanceAbsentContractTest do
  @moduledoc """
  Contract pins for issue #544: `provenance: absent` is a source condition,
  not an authoritative empty observation. Session 03 showed absent at top
  level; session 05 distinguished `.pixir` present but empty. The data still
  has that three-way split; the overview must show it without expanding
  Evidence details.
  """

  use ExUnit.Case, async: true

  @js Path.expand("../../priv/static/app.js", __DIR__)
  @css Path.expand("../../priv/static/app.css", __DIR__)

  setup_all do
    {:ok, js: File.read!(@js), css: File.read!(@css)}
  end

  test "absent provenance is the top-line source condition, not an authoritative count", %{js: js} do
    assert js =~ ~s|const absent = provenance === "absent";|
    assert js =~ ~s|condition.classList.add("source-absent")|
    assert js =~ ~s|text("p", "No sessions directory observed (provenance: absent)", "source-absent-note")|
    refute js =~ "No sessions directory observed (provenance: absent)\", \"provenance\")"
  end

  test "the authoritative counts row is not rendered for an absent store", %{js: js} do
    assert js =~ ~s|if (absent) {|
    assert js =~ ~s|const stats = el("p", "source-stats");|
    # Counts stay on the observed path only. The absent branch must not append them.
    assert js =~ ~s|Observed Session Logs: |
    absent_branch = js |> String.split(~s|if (absent) {|) |> Enum.at(1) |> String.split(~s|} else {|) |> hd()
    refute absent_branch =~ "source-stats"
    refute absent_branch =~ "Observed Session Logs"
  end

  test "an observed empty store still reports a real 0 and Evidence still names provenance", %{js: js} do
    assert js =~ ~s|Authoritative scoped snapshot · |
    assert js =~ "Sessions directory provenance: "
    assert js =~ ~s|text("summary", "Evidence details")|
    assert js =~ ~s|untrustedText("p", "Authoritative scoped snapshot · " + receiptBoundary, "provenance")|
  end

  test "absent treatment is visually demoted from the authoritative accent", %{css: css} do
    assert css =~ ".source-condition.source-absent { border-left-color: var(--muted); }"
    assert css =~ ".source-absent-note { color: var(--muted); }"
  end
end
