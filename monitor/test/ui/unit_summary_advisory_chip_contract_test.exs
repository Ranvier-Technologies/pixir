defmodule PixirMonitor.UI.UnitSummaryAdvisoryChipContractTest do
  @moduledoc """
  Compact unit-summary advisory chips must speak the same verdict WORD as the
  Unit Inspector card and the ON THIS RUN pane (#554).

  The chip used to paint `marker(unit.advisory.verdict)` — titleCase of the raw
  token — so the golden invalid fixture read "unknown" on the pill while the
  card and pane already said "invalid". Only the visible word changes: marker
  tone stays keyed on the raw projection token, the same split the run-scope
  distributions and `labeledTruthCard` already implement.

  Source-string pins catch a drifted call site. The executed node:vm tier paints
  the real renderers against the golden fixtures and requires the three surfaces
  to be byte-equal.
  """

  use ExUnit.Case, async: true

  @js Path.expand("../../priv/static/app.js", __DIR__)
  @checker Path.expand("../support/unit_summary_advisory_chip_check.mjs", __DIR__)
  @golden_dir Path.expand("../../priv/presenter/fixtures/golden", __DIR__)
  @node System.find_executable("node")
  @node_skip (cond do
                is_binary(@node) -> false
                System.get_env("CI") in ["true", "1"] -> false
                true -> "requires Node.js"
              end)

  setup_all do
    {:ok, js: File.read!(@js)}
  end

  test "the compact chip routes its word through the shared #553 classifier", %{js: js} do
    assert js =~
             ~s|if (unit.advisory && unit.advisory.present) header.append(labeledMarker(unitAdvisoryLabel(unit), unit.advisory.verdict, "advisory", "model_declared"));|

    refute js =~
             ~s|if (unit.advisory && unit.advisory.present) header.append(marker(unit.advisory.verdict, "advisory", "model_declared"));|
  end

  test "tone stays the raw verdict while the word comes from unitAdvisoryLabel", %{js: js} do
    chip =
      js
      |> after_anchor("function unitSummary(run, unit, route, summaryFocusKey) {")
      |> String.split("\n    return article;")
      |> hd()

    assert chip =~ "labeledMarker(unitAdvisoryLabel(unit), unit.advisory.verdict",
           "the chip no longer splits word (classifier) from tone (raw verdict)"

    refute chip =~ "marker(unit.advisory.verdict",
           "the chip fell back to titleCase of the raw verdict token"
  end

  test "unitAdvisoryLabel still classifies invalid-first then the shipped alias map", %{js: js} do
    body =
      js
      |> after_anchor("function unitAdvisoryLabel(unit) {")
      |> String.split("\n  }")
      |> hd()

    assert body =~ "const bucket = unitAdvisoryBucket(unit);"
    assert body =~ "distributionValueLabel(bucket, ADVISORY_DISPLAY_ALIASES)"
  end

  test "every compact-chip surface still goes through unitSummary", %{js: js} do
    assert js =~
             ~s|if (lookup[id]) inspector.append(unitSummary(run, lookup[id], route, "member:" + selectedEntity.key + ":" + id));|

    assert js =~
             ~s|item.append(unitSummary(run, unit, route, "unit-" + unit.logical_id + ":" + group.key));|

    assert length(String.split(js, "function unitSummary(")) == 2
  end

  @tag skip: @node_skip
  @tag timeout: 120_000
  test "executed chips match the Inspector card and pane over the golden fixtures" do
    assert is_binary(@node),
           "the CI runner lost node: the compact-chip executed tier must not silently skip in CI"

    {output, status} =
      System.cmd(
        @node,
        [@checker, "--app", @js, "--golden-dir", @golden_dir, "--json"],
        stderr_to_stdout: true
      )

    assert status == 0, "unit-summary advisory chip check failed: #{output}"
    result = output |> String.split("\n", trim: true) |> List.last() |> Jason.decode!()

    assert result["ok"] == true
    assert result["check"] == "pixir_monitor_unit_summary_advisory_chip"
    assert result["executed_in"] == "node_vm_minimal_dom"
    assert result["red_proof"]["family"] == "unit_summary_advisory_chip"
    assert result["red_proof"]["detected"] == "chip_still_raw_token"
    assert result["red_proof"]["rendered"] == "unknown"

    scenarios = Map.new(result["scenarios"], fn entry -> {entry["name"], entry} end)

    assert Map.keys(scenarios) |> Enum.sort() == [
             "golden_f4_stop",
             "golden_invalid",
             "overlay_stop_invalid",
             "present_needs_review",
             "present_pass",
             "present_stop",
             "present_unclassified"
           ]

    assert scenarios["golden_invalid"]["word"] == "invalid"
    assert scenarios["golden_invalid"]["card"] == "invalid"
    assert scenarios["golden_invalid"]["pane"] == "invalid"
    assert scenarios["golden_invalid"]["tone"] == "marker-unknown"

    assert scenarios["overlay_stop_invalid"]["word"] == "invalid"
    assert scenarios["overlay_stop_invalid"]["tone"] == "marker-stop"

    assert scenarios["present_unclassified"]["word"] == "unclassified verdict"
    assert scenarios["present_unclassified"]["tone"] == "marker-unknown"

    assert scenarios["present_stop"]["word"] == "stop"
    assert scenarios["present_stop"]["tone"] == "marker-stop"

    assert scenarios["present_needs_review"]["word"] == "needs review"
    assert scenarios["present_needs_review"]["tone"] == "marker-needs_review"

    assert scenarios["present_pass"]["word"] == "pass"
    assert scenarios["present_pass"]["tone"] == "marker-pass"

    assert scenarios["golden_f4_stop"]["word"] == "stop"
    assert scenarios["golden_f4_stop"]["tone"] == "marker-stop"
  end

  defp after_anchor(text, anchor) do
    case String.split(text, anchor, parts: 2) do
      [_before, after_text] -> after_text
      _ -> flunk("missing anchor: #{anchor}")
    end
  end
end
