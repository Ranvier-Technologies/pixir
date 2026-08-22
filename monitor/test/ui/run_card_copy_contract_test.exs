defmodule PixirMonitor.UIRunCardCopyContractTest do
  @moduledoc """
  Presenter copy contract for the three run-card label defects of #441.

  1. The usage disclosure summary must scope its completeness claim to the
     evidence, so that beside a `running` run it can never be read as the run
     having finished. Both polarities stay distinguishable while collapsed.
  2. The run detail subtitle must carry no unlabeled `unknown` enum slot, no
     dangling separator, and exactly one `projection` token.
  3. The advisory `unknown` bucket must be labeled "unclassified verdict"
     at all three surfaces that render advisory distributions — the Runs
     list Advisory column, the run truth rail card, and the semantic-zoom
     cluster summary row — via one shared display-alias map.

  Nothing here touches the projection schema, the builder, marker tones, or the
  `advisory.present == true` guard. Every assertion is about naming an
  already-correct fact.
  """
  use ExUnit.Case, async: true

  @js Path.expand("../../priv/static/app.js", __DIR__)
  @package Path.expand("../../priv/presenter", __DIR__)
  @fixture_root Path.expand("../../priv/presenter/fixtures", __DIR__)

  setup_all do
    {:ok, js: File.read!(@js)}
  end

  describe "usage disclosure completeness is scoped to the evidence" do
    test "the collapsed summary never emits a standalone Complete/Incomplete word", %{js: js} do
      # The old summary read "... · Complete" beside a running run.
      refute js =~ ~s|(usage && usage.complete ? "Complete" : "Incomplete")|

      assert js =~ "function usageCompletenessLabel(usage)"
      assert js =~ ~s|return usage && usage.complete === true ? "Evidence complete" : "Evidence incomplete";|
    end

    test "the summary keeps the pinned disclosure name and renders the scoped label", %{js: js} do
      assert js =~
               ~s|text("summary", "Evidence-derived usage · " + scalar(usage && usage.calls, 0) + " calls · " + usageCompletenessLabel(usage))|
    end

    test "both polarities stay distinguishable while collapsed", %{js: js} do
      # One helper, two distinct strings; neither is a prefix-free variant of
      # the other that could collapse under truncation.
      assert js =~ ~s|"Evidence complete"|
      assert js =~ ~s|"Evidence incomplete"|
    end

    test "the single helper serves the run, unit, and attempt scopes alike", %{js: js} do
      # usagePanel is the only builder of the disclosure; the three scopes differ
      # only by disclosure key, so one summary expression covers all three.
      assert js =~ ~s|usagePanel(run.usage, "usage:run:"|
      assert js =~ ~s|usagePanel(unit.usage, "usage:unit:"|
      assert js =~ ~s|"usage:attempt:" + attempt.attempt_id|
      assert length(String.split(js, "usageCompletenessLabel(usage)")) == 3
      assert length(String.split(js, "function usagePanel(")) == 2
    end

    test "the expanded provenance line still confesses the observed boundary", %{js: js} do
      assert js =~ "complete at observed boundary"
    end
  end

  describe "run detail subtitle has no bare unknown slot and one projection token" do
    test "the subtitle is composed from a separator-safe segment join", %{js: js} do
      assert js =~ "function runSubtitleSegments(run)"
      assert js =~ ~s|runSubtitleSegments(run).join(" · ")|
      # The old hard-coded concatenation with its duplicated literal is gone.
      refute js =~ ~s|" · projection " + scalar(run.projection_id, "unknown")|
      refute js =~ ~s|titleCase(run.run.strategy) + " · " + titleCase(run.run.mode)|
    end

    test "an unknown workspace mode is omitted rather than rendered bare", %{js: js} do
      assert js =~ ~s|if (mode && mode !== "unknown") segments.push("Workspace mode " + titleCase(mode));|
    end

    test "an unknown strategy is omitted rather than rendered bare", %{js: js} do
      assert js =~ ~s|if (strategy && strategy !== "unknown") segments.push(titleCase(strategy));|
    end

    test "the projection id is emitted once, unprefixed by a second literal", %{js: js} do
      assert js =~ ~s|if (run.projection_id) segments.push(String(run.projection_id));|
      refute js =~ ~s|"projection " + scalar(run.projection_id|
      refute js =~ "projection projection:"
    end

    test "an absent projection id is omitted rather than rendered as a bare unknown", %{js: js} do
      # Rule 3 of the subtitle spec: the id slot obeys the same no-bare-token
      # rule as the strategy and mode slots, so the fallback literal is gone.
      refute js =~ ~s|segments.push(scalar(run.projection_id, "unknown"));|
    end

    test "the subtitle is rendered through the untrusted text sink", %{js: js} do
      assert js =~ ~s|untrustedText("p", runSubtitleSegments(run).join(" · "), "lede")|
    end

    test "the projection id stays selectable in the run detail view", %{js: js} do
      assert js =~ ~s|copyValueButton(run.projection_id, "projection id")|
    end

    test "every golden projection id carries exactly one projection segment" do
      for id <- scenario_ids() do
        projection = golden(id)
        assert String.starts_with?(projection["projection_id"], "projection:")

        # The rendered subtitle shows the id verbatim, so the whole subtitle
        # must contain the word "projection" only as that single prefix.
        segments =
          [
            projection["run"]["strategy"],
            projection["run"]["mode"],
            projection["projection_id"]
          ]
          |> Enum.reject(&(is_nil(&1) or &1 == "unknown"))

        subtitle = Enum.join(segments, " · ")
        refute subtitle =~ "projection projection:"
        assert length(String.split(subtitle, "projection")) == 2
        refute subtitle =~ " ·  · "
        refute String.starts_with?(subtitle, " · ")
        refute String.ends_with?(subtitle, " · ")
      end
    end
  end

  describe "advisory unknown bucket is labeled at all three surfaces" do
    test "one shared alias map names the bucket", %{js: js} do
      assert js =~
               ~s|const ADVISORY_DISPLAY_ALIASES = Object.freeze({unknown: "unclassified verdict"});|
    end

    test "the Runs list Advisory column passes the shared alias map", %{js: js} do
      assert js =~
               ~s|distributionMarkers(row.advisory_counts, ADVISORY_BUCKET_ORDER, ADVISORY_DISPLAY_ALIASES, "advisory distribution", "parent_log_only")|

      refute js =~
               ~s|distributionMarkers(row.advisory_counts, ["stop", "needs_review", "pass", "unknown", "invalid"], null|
    end

    test "the run truth rail card passes the shared alias map", %{js: js} do
      # The BASIS is a shared constant too, for the same reason the alias map
      # is: the manual's ON THIS RUN part attributes its advisory fold to the
      # same provenance word this card prints, and two literals is a parallel
      # copy table that lets one surface be renamed while the other goes on
      # attributing the old word to a live reading.
      assert js =~
               ~s|distributionCard(route, "Model advisory", "advisory", advisoryCounts, ADVISORY_BUCKET_ORDER, ADVISORY_DISPLAY_ALIASES, ADVISORY_FOLD_BASIS|

      assert js =~ ~s|const ADVISORY_FOLD_BASIS = "model declared";|

      refute js =~
               ~s|distributionCard(route, "Model advisory", "advisory", advisoryCounts, ["stop", "needs_review", "pass", "unknown", "invalid"], null|
    end

    test "the semantic-zoom cluster summary row uses the same alias map", %{js: js} do
      assert js =~ "function distributionValueLabel(value, aliases)"
      assert js =~ ~s|["Model advisory", "advisory", function (unit)|
      assert js =~ ~s|distributionValueLabel(value, dimension[3])|
      # The cluster row previously title-cased the raw token with no alias hook.
      refute js =~ ~s|return titleCase(value) + " " + counts[value];|
    end

    test "the frozen bucket order is preserved as one constant", %{js: js} do
      assert js =~
               ~s|const ADVISORY_BUCKET_ORDER = Object.freeze(["stop", "needs_review", "pass", "unknown", "invalid"]);|
    end

    test "buckets whose token already reads correctly keep their labels", %{js: js} do
      # Only `unknown` is aliased; pass/stop/invalid fall through to titleCase.
      assert js =~
               ~S<function distributionValueLabel(value, aliases) { return (aliases && aliases[value]) || titleCase(value); }>

      [alias_literal] =
        Regex.run(~r/const ADVISORY_DISPLAY_ALIASES = Object\.freeze\(\{[^}]*\}\);/, js)

      refute alias_literal =~ "pass:"
      refute alias_literal =~ "stop:"
      refute alias_literal =~ "needs_review:"
      refute alias_literal =~ "invalid:"
      assert alias_literal =~ "unknown:"
    end

    test "the advisory.present guard is preserved at every counting surface", %{js: js} do
      assert js =~
               ~s|function (unit) { return unit.advisory && unit.advisory.present === true ? unit.advisory.verdict : null; }|

      assert js =~
               ~s|unit.advisory && unit.advisory.present === true ? (unit.advisory.parse_status === "invalid" ? "invalid" : unit.advisory.verdict) : null|
    end

    test "marker tone is still driven by the raw token, never by the label", %{js: js} do
      # distributionBuckets carries the raw token beside the aliased phrase, and
      # distributionMarkers passes that token as the tone argument while the
      # aliased string is only ever the visible label. Pinned on the shared fold
      # because the manual pane reads the SAME fold: a bucket whose tone came
      # from its label would now be wrong in two surfaces at once.
      assert js =~
               ~s|buckets.push({token: name, phrase: count + " " + pluralizeDistributionLabel(distributionValueLabel(name, aliases), count)})|

      assert js =~ ~s|wrap.append(labeledMarker(bucket.phrase, bucket.token, dimension, basis))|
      assert js =~ ~s|function labeledMarker(label, tone, dimension, basis)|
      assert js =~ ~s|"marker marker-" + markerTone(tone)|
    end

    test "the invalid-advisory golden keeps its unit out of the unknown bucket" do
      projection = golden("invalid-model-advisory")

      unit =
        Enum.find(projection["units"], fn unit ->
          get_in(unit, ["advisory", "parse_status"]) == "invalid"
        end)

      # Present, verdict unknown, but parse_status invalid: the invalid reader
      # claims it, so the relabeled `unknown` bucket must not absorb it.
      assert get_in(unit, ["advisory", "present"]) == true
      assert get_in(unit, ["advisory", "verdict"]) == "unknown"
    end

    test "advisory-absent units contribute to no bucket in any surface" do
      absent =
        for id <- scenario_ids(),
            unit <- golden(id)["units"],
            get_in(unit, ["advisory", "present"]) != true,
            do: get_in(unit, ["advisory", "verdict"])

      # The classifier's empty map verdict is `unknown` with present: false.
      # Only the present guard keeps these out of the counted bucket, so the
      # relabel must not become a claim about them.
      assert absent != []
      assert Enum.all?(absent, &(&1 in [nil, "unknown"]))
    end
  end

  describe "the frozen screen specification is amended in the same change" do
    test "the usage disclosure prose no longer mandates the bare words" do
      spec = screen_specs()

      refute spec =~ "Show **Complete** or **Incomplete** with limitations."
      assert spec =~ "Evidence complete"
      assert spec =~ "Evidence incomplete"
      assert spec =~ "never as a claim about run execution state"
    end

    test "the specification describes the subtitle composition rule" do
      spec = screen_specs()

      assert spec =~ "Run detail subtitle"
      assert spec =~ "omitted entirely when `unknown`"
      assert spec =~ "`projection_id` renders verbatim"
    end

    test "the specification describes the advisory unknown display label" do
      spec = screen_specs()

      assert spec =~ "unclassified verdict"
      assert spec =~ "display label for an existing bucket"
    end

    test "the frozen severity ordering and never-invent-a-verdict clause survive" do
      spec = screen_specs()

      assert spec =~ "`stop > needs_review > pass > unknown`"
      assert spec =~ "never receive an invented verdict"
    end
  end

  defp screen_specs, do: File.read!(Path.join(@package, "ux/screen-specs.md"))

  defp scenario_ids do
    Path.join(@fixture_root, "manifest.json")
    |> File.read!()
    |> Jason.decode!()
    |> Map.fetch!("scenarios")
    |> Enum.map(& &1["id"])
  end

  defp golden(id) do
    [@fixture_root, "golden", id <> ".json"]
    |> Path.join()
    |> File.read!()
    |> Jason.decode!()
  end
end
