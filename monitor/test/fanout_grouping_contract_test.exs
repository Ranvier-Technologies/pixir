Code.require_file("support/fanout_fixture.ex", __DIR__)

# These tests verify deterministic fixture math and app.js source contracts via
# string pins. They do not execute JavaScript; executable behavior coverage belongs
# to the monitor bench/browser surface.

defmodule PixirMonitor.FanoutGroupingContractTest do
  use ExUnit.Case, async: true

  alias PixirMonitor.Test.FanoutFixture

  @app Path.expand("../priv/static/app.js", __DIR__)
  @family_order ~w(execution advisory liveness mutation virtual_diff evidence)
  @execution_order ~w(failed timed_out cancelled detached partial held unknown running queued planned completed closed)
  @reason_family %{
    "execution_failed" => "execution",
    "execution_timed_out" => "execution",
    "execution_cancelled" => "execution",
    "execution_detached" => "execution",
    "execution_partial" => "execution",
    "execution_held" => "execution",
    "execution_unknown" => "execution",
    "advisory_stop" => "advisory",
    "advisory_needs_review" => "advisory",
    "advisory_gate_disagreement" => "advisory",
    "advisory_unparseable" => "advisory",
    "nonterminal_stale_handle" => "liveness",
    "nonterminal_owner_unavailable" => "liveness",
    "nonterminal_liveness_unknown" => "liveness",
    "terminal_ambiguous_close" => "liveness",
    "mutation_partial" => "mutation",
    "mutation_indeterminate" => "mutation",
    "mutation_unknown" => "mutation",
    "virtual_diff_unapplied" => "virtual_diff",
    "virtual_diff_apply_failed" => "virtual_diff",
    "virtual_diff_correlation_unknown" => "virtual_diff",
    "canonical_source_conflict" => "evidence",
    "durable_log_unavailable" => "evidence",
    "child_log_missing" => "evidence",
    "attempt_index_conflict" => "evidence"
  }

  test "pins the complete frozen reason map and leaves gate reasons unmapped" do
    source = File.read!(@app)
    [_, map_source] = Regex.run(~r/const FANOUT_ATTENTION_REASON_FAMILY = Object\.freeze\(\{(.*?)\n  \}\);/s, source)

    assert map_size(@reason_family) == 25

    Enum.each(@reason_family, fn {reason, family} ->
      assert map_source =~ ~s(#{reason}: "#{family}")
    end)

    mapped_keys = Regex.scan(~r/^    ([a-z0-9_]+):/m, map_source) |> Enum.map(&List.last/1)
    assert Enum.sort(mapped_keys) == Enum.sort(Map.keys(@reason_family))
    refute Enum.any?(mapped_keys, &String.starts_with?(&1, "gate_"))

    [_, fallback_source] =
      Regex.run(~r/function fanoutReasonFamily\(reason\) \{(.*?)\n  \}/s, source)

    assert Map.get(@reason_family, "evidence_like_thing") == nil
    assert fallback_source =~ "Evidence reasons are exact-map-only"
    refute fallback_source =~ "gate_"
    refute fallback_source =~ ~s{startsWith("evidence_")}
    refute source =~ ~s("gate" => "attention")
  end

  test "pins both region orders and the independent twelve-member group bound" do
    source = File.read!(@app)

    assert source =~
             ~s(const FANOUT_GROUP_MEMBER_PAGE_SIZE = 12;)

    assert source =~
             ~s{const FANOUT_ATTENTION_FAMILY_ORDER = Object.freeze(["execution", "advisory", "liveness", "mutation", "virtual_diff", "evidence"]);}

    assert source =~
             ~s{const FANOUT_EXECUTION_STATE_ORDER = Object.freeze(["failed", "timed_out", "cancelled", "detached", "partial", "held", "unknown", "running", "queued", "planned", "completed", "closed"]);}

    assert @family_order == ~w(execution advisory liveness mutation virtual_diff evidence)
    assert @execution_order == ~w(failed timed_out cancelled detached partial held unknown running queued planned completed closed)
    assert source =~ "section.append(attention);"
    assert source =~ "section.append(executionRegion);"
    assert source =~ ~s{if (unmappedGroup.members.length > 0) attention.push(unmappedGroup);}

    assert source =~
             ~r/const attention = FANOUT_ATTENTION_FAMILY_ORDER.*?if \(unmappedGroup\.members\.length > 0\) attention\.push\(unmappedGroup\);/s

    assert source =~ ~s{key: "attention:unmapped"}
    assert source =~ ~s{button("+" + remaining + " more · show next "}
    refute source =~ "healthyGroups"
    refute source =~ "grouping.healthy"
    refute source =~ "fanout-healthy-region"
  end

  test "500-sibling fixture preserves non-exclusive membership, occurrence math, seq order, retries, and pagination" do
    events = FanoutFixture.parent_events()
    units = FanoutFixture.units(events)
    groups = derive_attention_groups(units)
    attention_units = Enum.filter(units, &(&1.reasons != []))
    occurrences = Enum.sum(Enum.map(attention_units, &length(&1.reasons)))

    assert length(units) == 500
    assert length(attention_units) == 80
    assert length(units) - length(attention_units) == 420
    assert occurrences == 84
    assert Enum.map(groups, &elem(&1, 0)) == @family_order ++ ["unmapped"]

    multi = hd(units)
    assert multi.id in group_members(groups, "execution")
    assert multi.id in group_members(groups, "advisory")
    assert multi.id in group_members(groups, "mutation")
    assert multi.id in group_members(groups, "evidence")
    assert "fanout-80" in group_members(groups, "unmapped")
    refute "fanout-80" in group_members(groups, "evidence")
    assert "fanout-79" in group_members(groups, "execution")
    refute "fanout-79" in group_members(groups, "unmapped")

    residual = group_data(groups, "unmapped")
    assert residual.occurrences == 1
    assert residual.reasons == [{"evidence_like_thing", 1}]

    global_unmapped =
      units
      |> Enum.flat_map(& &1.reasons)
      |> Enum.filter(&(Map.get(@reason_family, &1) == nil))
      |> Enum.frequencies()

    assert global_unmapped == %{"evidence_like_thing" => 1, "mixed_future_reason" => 1}
    assert Enum.sum(Enum.map(groups, fn {_family, data} -> data.occurrences end)) == occurrences - 1
    assert Enum.sum(Enum.map(groups, fn {_family, data} -> length(data.members) end)) > length(attention_units)

    Enum.each(groups, fn {_family, data} ->
      assert data.members == Enum.sort_by(data.members, & &1.seq)
      assert data.reasons == Enum.sort(data.reasons)
    end)

    execution_units = Enum.filter(units, &(&1.reasons == []))
    assert div(length(execution_units) + 11, 12) == 35
    assert length(execution_units) - 12 == 408
    assert Enum.any?(units, &(length(&1.attempts) > 1))
    assert Enum.any?(units, &("child_log_missing" in &1.reasons))
    assert Enum.find(units, &(&1.id == "fanout-3")).agent =~ "<img"
  end

  test "pins observed-count honesty, inert projected text, and unchanged deep links" do
    source = File.read!(@app)

    assert source =~
             ~s{" siblings need attention (" + grouping.attentionOccurrences + " reason occurrences)"}

    assert source =~
             ~s{"Observed count limited: " + limitations.map(titleCase).join(" · "), "limitation group-count-limitation"}

    assert source =~
             "Unmapped observed attention reasons (never dropped; mixed-family siblings stay in their mapped groups): "

    assert source =~ "const unitUnmappedReasons = [];"
    assert source =~ "unitUnmappedReasons.push(reason);"
    assert source =~ "if (families.size === 0) {"
    assert source =~ "unitUnmappedReasons.forEach(function (reason) {"
    assert source =~ "unmappedGroup.occurrences += 1;"

    [before_zero_family_commit, after_zero_family_commit] =
      String.split(source, "if (families.size === 0) {", parts: 2)

    zero_family_commit = hd(String.split(after_zero_family_commit, "\n      }", parts: 2))
    refute before_zero_family_commit =~ "unmappedGroup.occurrences += 1;"
    assert zero_family_commit =~ "unitUnmappedReasons.forEach(function (reason) {"
    assert zero_family_commit =~ "unmappedGroup.occurrences += 1;"

    assert source =~ "grouping.unmapped.forEach(function (item) {"
    assert source =~ "unmappedReasonCounts[item.reason] = (unmappedReasonCounts[item.reason] || 0) + 1;"

    assert source =~
             "return reason + \" · \" + unmappedReasonCounts[reason] + \" occurrences\";"

    assert source =~
             "shownReasons.forEach(function (reason) { reasonList.append(untrustedText(\"li\", reason + \" · \" + group.reasons[reason] + \" occurrences\")); });"

    assert source =~
             ~s{const shownReasons = reasonEntries.slice(0, reasonPage * FANOUT_GROUP_MEMBER_PAGE_SIZE);}

    assert source =~
             ~s{"+" + remainingReasons + " more distinct reasons · show next "}

    assert source =~
             ~s{state.pages[reasonPageKey] = reasonPage + 1;}

    assert source =~
             ~s{attention.append(untrustedText("span", array(unit.attention.reasons).map(titleCase).join(" · ")))}

    assert source =~
             ~s{item.append(unitSummary(run, unit, route, "unit-" + unit.logical_id + ":" + group.key));}

    assert source =~ ~s{summaryFocusKey || "unit-" + unit.logical_id}
    assert source =~ ~s{"attempt-summary-" + unit.logical_id + "-" + index + ":" + groupKey}
    assert source =~ "attemptId: attempt.attempt_id"
    assert source =~ "unitId: unit.logical_id"
    refute source =~ "innerHTML"
  end

  defp derive_attention_groups(units) do
    mapped =
      Enum.map(@family_order, fn family ->
        members =
          Enum.filter(units, fn unit ->
            Enum.any?(unit.reasons, &(Map.get(@reason_family, &1) == family))
          end)

        reason_counts =
          members
          |> Enum.flat_map(& &1.reasons)
          |> Enum.filter(&(Map.get(@reason_family, &1) == family))
          |> Enum.frequencies()
          |> Enum.sort()

        {family, %{members: members, occurrences: Enum.sum(Enum.map(reason_counts, &elem(&1, 1))), reasons: reason_counts}}
      end)

    unmapped_members =
      Enum.filter(units, fn unit ->
        unit.reasons != [] and Enum.all?(unit.reasons, &(Map.get(@reason_family, &1) == nil))
      end)

    unmapped_reasons =
      unmapped_members
      |> Enum.flat_map(& &1.reasons)
      |> Enum.frequencies()
      |> Enum.sort()

    mapped ++
      [
        {"unmapped",
         %{
           members: unmapped_members,
           occurrences: Enum.sum(Enum.map(unmapped_reasons, &elem(&1, 1))),
           reasons: unmapped_reasons
         }}
      ]
  end

  defp group_members(groups, family) do
    groups |> group_data(family) |> Map.fetch!(:members) |> Enum.map(& &1.id)
  end

  defp group_data(groups, family) do
    {_family, data} = List.keyfind(groups, family, 0)
    data
  end
end
