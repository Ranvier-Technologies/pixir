defmodule PixirMonitor.UI.ChildResolutionAcquisitionTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Executes the STATEFUL inventory-acquisition/repaint cycle of issue #438 in
  node:vm against a counting fetch stub and a minimal DOM.

  This tier exists because neither of the other two can reach the defect class it
  guards. `ChildParentResolutionContractTest` pins source text, and
  `PresenterUiSeamTest` executes only the PURE `resolveParentObservedChild`
  resolver through the frozen seam. The acquisition is the one loop-capable part
  of the change: the dead end repaints, the repaint re-enters the acquisition
  call site, and the acquisition completing repaints again. When the acquired
  inventory comes back EMPTY or FAILED — the brief's own "evidence unavailable"
  case — a guard released before the repaint runs turns that cycle into an
  unbounded request storm against the authoritative list endpoint.

  The checker therefore asserts an EXACT authoritative-request count per
  scenario, in both single and workspace-set mode, on both dead ends, and proves
  the check bites by first running the empty-inventory scenario against a
  deliberately unbounded guard and requiring it to go red.
  """

  @app Path.expand("../../priv/static/app.js", __DIR__)
  @checker Path.expand("../support/child_resolution_acquisition_check.mjs", __DIR__)
  @node System.find_executable("node")
  # Same policy as the seam tier: a missing node skips LOCALLY but must fail
  # LOUDLY in CI, so this executed-JavaScript evidence class cannot be lost to a
  # silent skip.
  @node_skip (cond do
                is_binary(@node) -> false
                System.get_env("CI") in ["true", "1"] -> false
                true -> "requires Node.js"
              end)

  @tag skip: @node_skip
  @tag timeout: 120_000
  test "an unresolvable child dead end acquires its inventory exactly once and converges" do
    assert is_binary(@node),
           "the CI runner lost node: the acquisition tier must not silently skip in CI"

    {output, status} =
      System.cmd(@node, [@checker, "--app", @app, "--json"], stderr_to_stdout: true)

    assert status == 0, "child resolution acquisition check failed: #{output}"
    result = output |> String.split("\n", trim: true) |> List.last() |> Jason.decode!()

    assert result["ok"] == true
    assert result["check"] == "pixir_monitor_child_resolution_acquisition"
    assert result["executed_in"] == "node_vm_minimal_dom"

    # The check is proven to bite before its green counts: the pre-fix guard
    # discipline (single-flight handle released BEFORE the repaint, no per-id
    # attempt marker) must run away past the cap.
    assert result["red_proof"]["family"] == "acquisition_boundedness"
    assert result["red_proof"]["detected"] in ["acquisition_unbounded", "acquisition_count_mismatch"]

    scenarios = Map.new(result["scenarios"], fn entry -> {entry["name"], entry} end)

    # Every named scenario must be present: a checker that quietly drops one
    # cannot pass by reporting fewer.
    assert Map.keys(scenarios) |> Enum.sort() == [
             "single_empty_inventory_bounded",
             "single_failing_inventory_bounded",
             "single_non_follow_empty_inventory_bounded",
             "single_resolving_inventory_renders_parent",
             "workspace_set_empty_inventory_bounded",
             "workspace_set_failing_inventory_bounded"
           ]

    # ONE authoritative detail request and ONE inventory acquisition, in every
    # scenario — including the two where the inventory can never resolve the id.
    for {name, entry} <- scenarios do
      assert entry["list_requests"] == 1,
             "#{name} did not acquire the scoped inventory exactly once"

      assert entry["detail_requests"] == 1,
             "#{name} issued an unexpected number of authoritative detail requests"
    end
  end
end
