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
    #
    # The totals carry one hand case per mode for the manual-only DELTA KEY: the
    # router skips the refetch when only the manual field moved, so the key it
    # compares must change on a view change. It cannot be the canonical hash
    # alone — distinct views share paths (an unavailable route and a runs route
    # both canonicalize to the runs path), and collapsing them would repaint a
    # Runs page from the unavailable view's empty state, claiming zero runs were
    # found without ever issuing a fetch.
    #
    # They also carry nine hand cases per mode for PARTIAL route literals. Every
    # other manual assertion in the checker spreads the whole canonical route,
    # which is what only semanticZoomRoute does in the app; the great majority of
    # in-view controls build a fresh partial literal naming only the fields their
    # navigation changes. Those literals must INHERIT the pane state of the route
    # they navigate from (three cases), must still obey an EXPLICIT manual value
    # in either direction (three), and must not INVENT a pane over a route that
    # had none (three) — inheritance is symmetric or it is a fabrication.
    #
    # And one hand case per mode for the UNAVAILABLE route under the overlay.
    # That family names no workspace, no run and no unit, so a serializer with no
    # branch for it falls through to the runs-path construction and INVENTS a
    # destination: standing on `#/%zz` and pressing `?` used to write
    # `#/runs?manual=index` (single) or `#/workspaces/<first>/runs?manual=index`
    # (set), navigating the reader onto a real view and discarding the
    # unavailable state permanently. It is the overview short-circuit's defect
    # class on the one view whose entire message is that the request does not
    # exist, so it is pinned the same way — driven through manualRoute (the call
    # both key bindings make), in both directions, plus the hand-built literal
    # that claims the view while carrying no path.
    assert result["roundtrip"]["single"]["cases"] == 534
    assert result["roundtrip"]["workspace_set"]["cases"] == 532

    # The manual families (#551) are the overlay-dimension contract: a term slug,
    # the bare index sentinel, an off-shape slug normalized to the index, and the
    # pane closed. They are route-grammar families rather than views on purpose —
    # the manual rides EVERY family above rather than adding a fifth `view`.
    for mode <- ["single", "workspace_set"],
        family <-
          ~w(view_runs view_detail view_unit with_attempt with_zoom with_arc with_member_page with_edge_page bogus_filter_dropped with_manual_term with_manual_index manual_off_shape_normalized without_manual) do
      assert result["roundtrip"][mode]["coverage"][family] > 0,
             "route family #{family} was never exercised in #{mode} mode"
    end

    # The workspace OVERVIEW is a set-mode-only route family, and the one view
    # that names no workspace. It is pinned separately because a serializer that
    # only knows how to build "#/workspaces/<ws>/runs" would invent a workspace
    # and navigate the reader off the overview — including when the manual
    # overlay is opened over it, which must preserve the underlying view.
    assert result["roundtrip"]["workspace_set"]["coverage"]["view_workspaces"] > 0,
           "route family view_workspaces was never exercised in workspace_set mode"

    assert result["visible_cases"] == 22

    assert result["comparator"] == %{
             "rows" => 16,
             "order_checks" => 4,
             "pairs" => 1024,
             "triples" => 16384
           }

    # Issue #438: parent-observed child resolution is executed, not pinned as
    # source text. The case count is exact so a family cannot be quietly
    # dropped from the checker.
    assert result["child_resolution_cases"] == 11

    # Issue #551: the glossary accessor seam is EXECUTED here, not grepped as
    # source text. The counts are pinned so the checker cannot silently narrow
    # to a corpus fragment; the null contract, the corpus concern order, and
    # the deep freeze are asserted inside the checker against the loaded seam.
    assert result["glossary"] == %{"entries" => 56, "concerns" => 8}

    # Issue #551, T4 -> T7: the ON THIS RUN slug inventories. The manual's
    # fourth doctrine part is bound PER TERM, so the set of terms with no
    # run-scoped value is a real contract — it is exactly the set the pane is
    # allowed to stay silent about, and T7's anti-rot predicate consumes it as
    # DATA rather than re-deriving it. Two derivations of one set is two sources
    # of truth for which silences are honest, and they drift the first time a
    # term is added.
    #
    # The counts are pinned, and the checker additionally proves the two
    # inventories PARTITION the corpus (every slug on exactly one side, none off
    # corpus), are frozen, and are stable across reads. The partition is what
    # makes the count meaningful: 19 + 37 == 56 with no slug on both sides and
    # none missing.
    assert result["manual_run_inventory"] == %{
             "bound" => 19,
             "no_run_value" => 37,
             "corpus" => 56
           }

    # The dotted labelled-term affordance's own seam, likewise EXECUTED. The
    # source-pin contract test asserts the resolver contains a `throw`; only
    # this proves it throws.
    #
    # Sixteen shipped labels resolve to twelve distinct slugs. The gap of four
    # is the deliberate many-to-one the orchestrator's spelling decision forces:
    # the rail's "Dependency gate", "Model advisory", "Source (run-scoped)"
    # and "Child activity after end" share their entries with the list's
    # shorter "Gate", "Advisory", "Source" and "Child after end" (attention
    # ships NO list column, so no short form exists). Every one of those eight
    # strings is what actually ships; none was reworded for lookup convenience.
    #
    # "Runtime gate" is NOT part of that fold. It labels the same dimension as
    # "Dependency gate" but has its own corpus entry, because the corpus
    # documents the two-labels-one-dimension confusion as a term in its own
    # right.
    #
    # `defects_observed` counts the refusals the check drove that arrived as a
    # MonitorDefect AND that the shipped normalizer declined to absorb. It is
    # the only evidence in this suite about what the operator would actually
    # see: calling labelledTermSlug directly can never observe the shipped
    # behavior, because every render is wrapped in renderCurrentGuarded.
    assert result["labelled_terms"] == %{
             "labels" => 16,
             "slugs" => 12,
             "defects_observed" => 10
           }

    # The checks themselves are proven to bite: each family must have gone RED
    # against a deliberately broken seam before the green run counts (the #362
    # red-proof idiom). Eighteen families at wave-3 integration: four route/base,
    # four glossary (undefined-for-null, re-sorted concern order, thawed corpus,
    # un-interned concerns), four the manual overlay's own regressions (a manual
    # parsed as a fifth `view` that discards the underlying route, a manual that
    # parses but never serializes, a routeHash that reads an ABSENT manual field
    # as a request to CLOSE the pane, and a routeHash with no branch for the
    # unavailable route — the last two being the ones the whole-route assertions
    # structurally cannot see), two on the ON THIS RUN inventories (a slug on
    # NEITHER side of the partition, and a mutable inventory a consumer could
    # rewrite in place), and four from the dotted-label affordance, all
    # invisible-on-screen failures: a label mapped to a slug the corpus does not
    # carry; a resolver that answers a falsy slug instead of refusing; a refusal
    # thrown as a PLAIN Error, which the shipped render guard launders into "The
    # fetched projection could not be displayed."; and the mirror-image lie, a
    # classifier that claims genuine upstream failures as Monitor defects.
    assert result["red_proof_families"] == 19
  end
end
