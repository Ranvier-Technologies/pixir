defmodule PixirMonitor.PresenterUiSeamTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Executes the frozen `window.PixirMonitorUI` seam of app.js in node:vm — the
  first test tier that RUNS Presenter JavaScript instead of pinning its source
  text, and the only one that needs neither Chrome nor the escript. The checker
  loads app.js inside a fail-closed stub (any unstubbed load-time touch throws)
  with a never-resolving bootstrap promise, so no fetch, SSE, or render fires.
  """

  @app Path.expand("../priv/static/app.js", __DIR__)
  @checker Path.join(__DIR__, "support/presenter_ui_seam_check.mjs")
  @node System.find_executable("node")
  # A missing node skips LOCALLY but must fail LOUDLY in CI: this tier is the
  # only CI-executed Presenter JavaScript, and losing it to a silent skip
  # would demote the evidence class without anyone noticing.
  @node_skip (cond do
                is_binary(@node) -> false
                System.get_env("CI") in ["true", "1"] -> false
                true -> "requires Node.js"
              end)

  @tag skip: @node_skip
  @tag timeout: 60_000
  test "the exported UI seam holds its route, sanitizer, and ordering contracts under execution" do
    assert is_binary(@node),
           "the CI runner lost node: the UI seam tier must not silently skip in CI"

    {output, status} =
      System.cmd(@node, [@checker, "--app", @app, "--json"], stderr_to_stdout: true)

    assert status == 0, "UI seam check failed: #{output}"
    result = output |> String.split("\n", trim: true) |> List.last() |> Jason.decode!()

    assert result["ok"] == true
    assert result["check"] == "pixir_monitor_ui_seam"
    assert result["executed_in"] == "node_vm_fail_closed_stub"

    # Structured counts, pinned so the checker cannot silently skip a family:
    # totals AND per-route-grammar-family coverage (each must be non-zero at
    # the checker layer; the totals are pinned exactly here), the 22
    # hand-computed visible() oracles, and the comparator's 16
    # equivalence-class rows, 4 pinned total orders, and full pair/triple
    # antisymmetry + transitivity sweeps.
    assert result["roundtrip"]["single"]["cases"] == 510
    assert result["roundtrip"]["workspace_set"]["cases"] == 511

    for mode <- ["single", "workspace_set"],
        family <-
          ~w(view_runs view_detail view_unit with_attempt with_zoom with_arc with_member_page with_edge_page bogus_filter_dropped) do
      assert result["roundtrip"][mode]["coverage"][family] > 0,
             "route family #{family} was never exercised in #{mode} mode"
    end

    assert result["visible_cases"] == 22

    assert result["comparator"] == %{
             "rows" => 16,
             "order_checks" => 4,
             "pairs" => 1024,
             "triples" => 16384
           }

    # The checks themselves are proven to bite: each family must have gone RED
    # against a deliberately broken seam before the green run counts (the #362
    # red-proof idiom).
    assert result["red_proof_families"] == 3
  end
end
