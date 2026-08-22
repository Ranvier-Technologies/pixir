defmodule PixirMonitor.UI.ManualPaneContractTest do
  @moduledoc """
  Contract pins for the instrument-manual overlay (#551): the CONTENT of the
  pane, not only its routing.

  The routing leg is already pinned by `manual_overlay_preservation_test`. What
  it does not pin is what the pane SAYS, and the pane's honesty lives entirely
  in its copy: ON THIS RUN reads the run actually on screen through an explicit
  slug -> reader table and degrades honestly when there is no run (or no
  run-scoped value at all), the absent-corpus pane confesses instead of
  blanking, and the citation provenance disclaims its own stale line pins.
  Silently dropping any of those is a truthfulness regression, so each one is
  pinned here in the same source-pin idiom as the sibling contract tests.

  The wave-2 placeholder ("Not yet wired…") is gone; the pins that guarded it
  now guard the real binding's honesty instead. That copy must not come back:
  the pane DOES read the value on screen now, so a not-yet-wired statement would
  be a false confession.

  The index grouping is pinned for the same reason: without it the whole
  concern structure (section titles, blurbs, term links) can be deleted with a
  green suite.
  """

  use ExUnit.Case, async: true

  @js Path.expand("../../priv/static/app.js", __DIR__)
  @css Path.expand("../../priv/static/app.css", __DIR__)

  setup_all do
    {:ok, js: File.read!(@js), css: File.read!(@css)}
  end

  # Splits AFTER a source anchor, flunking with the anchor's name when it has
  # moved — `String.split |> Enum.at(1)` dies as an ArgumentError on nil, which
  # sends the reader hunting a crash instead of a moved anchor.
  defp after_anchor(js, anchor) do
    case String.split(js, anchor, parts: 2) do
      [_, rest] -> rest
      _ -> flunk("anchor not found in app.js: #{inspect(anchor)}")
    end
  end

  defp entry_body(js) do
    js
    |> after_anchor("function renderManualEntry(root, route, entry, painted) {")
    |> String.split("function renderManualPane(route, painted) {")
    |> hd()
  end

  defp index_body(js) do
    js
    |> after_anchor("function renderManualIndex(root, route, requested) {")
    |> String.split("function renderManualEntry(root, route, entry, painted) {")
    |> hd()
  end

  test "an open entry carries the four doctrine parts, in the doctrine order", %{js: js} do
    body = entry_body(js)

    # The fourth part's HEADING moved into renderManualOnThisRun -- that is what
    # makes omission possible for an unbound term -- so its position in the
    # doctrine order is the position of the CALL that emits it.
    labels = [
      {"Plain definition", ~s|"Plain definition"|},
      {"HOW IT IS DERIVED", ~s|"HOW IT IS DERIVED"|},
      {"DO NOT READ IT AS", ~s|"DO NOT READ IT AS"|},
      {"ON THIS RUN", "renderManualOnThisRun(parts, route, entry, painted)"}
    ]

    positions =
      Enum.map(labels, fn {label, needle} ->
        case :binary.match(body, needle) do
          {at, _len} -> at
          :nomatch -> flunk("renderManualEntry no longer emits the #{label} part")
        end
      end)

    assert positions == Enum.sort(positions),
           "the four manual parts must render in doctrine order: #{labels |> Enum.map(&elem(&1, 0)) |> Enum.join(" -> ")}"

    assert body =~ ~s|part("Plain definition", scalar(entry.plain_definition,|
    assert body =~ ~s|part("HOW IT IS DERIVED", scalar(entry.code_citation,|
    assert body =~ ~s|part("DO NOT READ IT AS", scalar(entry.confused_with,|
  end

  defp on_this_run_body(js) do
    js
    |> String.split("function renderManualOnThisRun(parts, route, entry, painted) {")
    |> Enum.at(1)
    |> String.split("function manualNoRunCopy(route, painted) {")
    |> hd()
  end

  defp reader_table(js) do
    js
    |> String.split("const MANUAL_RUN_READERS = Object.freeze({")
    |> Enum.at(1)
    |> String.split("function manualExecutionReading(scope) {")
    |> hd()
  end

  test "the wave-2 not-yet-wired placeholder is gone from every surface", %{js: js, css: css} do
    # The pane now READS the value on screen. A surviving not-yet-wired sentence
    # would be a false confession -- the pane understating what it can source is
    # the same class of defect as overstating it.
    refute js =~ "Not yet wired."
    refute js =~ "manual-not-wired"
    refute css =~ "manual-not-wired"
  end

  test "ON THIS RUN is emitted by the reader binding, not by a fixed sentence", %{js: js} do
    body = entry_body(js)

    assert body =~ "const bound = renderManualOnThisRun(parts, route, entry, painted);"

    # The part heading now lives in the binding, which is what makes OMISSION
    # possible: a fixed append in the entry renderer could only ever print
    # something.
    on_this_run = on_this_run_body(js)
    assert on_this_run =~ ~s|parts.append(text("dt", "ON THIS RUN"));|

    # Unbound terms omit the part rather than printing a hedge under a heading
    # that promises a live value, and the omission is confessed once.
    assert on_this_run =~
             ~s|if (!Object.prototype.hasOwnProperty.call(MANUAL_RUN_READERS, slug)) return false;|

    assert body =~
             ~s|if (!bound) root.append(text("p", "This pane does not read a run-scoped value for this term|

    # The confession states THIS PANE's silence and characterises the term not
    # at all. The unbound set is corpus-minus-table, so it mixes genuinely
    # instrument-scoped terms (error kinds, clipboard rules) with terms the
    # views beside the pane DO read off the same run and the table has simply
    # not bound: `limitations`, `mutation`, `evidence-basis`, `declared-gate`.
    # The old copy asserted every unbound term "names a property of the
    # instrument rather than a reading off a run", which is FALSE for those and
    # is fabricating a claim about the term — the same defect class as
    # fabricating a value, with the truth rail printing the contradiction
    # inches away. No wording that characterises the term can be true of the
    # whole bucket, so none may reappear.
    refute body =~ "names a property of the instrument rather than a reading off a run"
    refute body =~ "This term has no run-scoped value"

    assert body =~
             ~s|not a claim that the term has no per-run value elsewhere in the Monitor.|
  end

  test "the reader table binds each slug to a SHIPPED accessor, explicitly", %{js: js} do
    table = reader_table(js)

    # The table is explicit: every bound term names its accessor. Nothing here
    # may derive a value from the term's shape.
    assert table =~ ~s|"execution": function (scope) { return manualExecutionReading(scope); }|
    assert table =~ ~s|"liveness": function (scope) { return manualLivenessReading(scope); }|
    assert table =~ ~s|"dependency-gate": function (scope) { return manualGateReading(scope); }|
    assert table =~ ~s|"runtime-gate": function (scope) { return manualGateReading(scope); }|
    assert table =~ ~s|"attention": function (scope) { return manualAttentionReading(scope); }|

    assert table =~
             ~s|"parent-observed": function (scope) { return manualAttentionReading(scope); }|

    assert table =~
             ~s|"child-after-end": function (scope) { return manualPostTerminalReading(scope); }|

    assert table =~
             ~s|"source-run-scoped": function (scope) { return {value: titleCase(scope.run.source && scope.run.source.mode), basis: scope.run.source && scope.run.source.durable_origin, scope: MANUAL_SCOPE_RUN}; }|

    assert table =~ ~s|const seq = scope.run.source && scope.run.source.as_of_seq;|

    # The post-terminal reader reads the SHIPPED field name, off the RUN: no
    # unit carries a post-terminal record, and the boundary it is measured from
    # is the parent run's.
    assert js =~ "const activity = scope.run.post_terminal_child_activity;"
  end

  test "every reader is dispatched with the scope, and every reading names it", %{js: js} do
    on_this_run = on_this_run_body(js)

    # Readers receive `{run, unit}` rather than a bare run. Passing only the run
    # is what made a run-wide fold the ONLY answer a reader could give, so the
    # pane printed the run's numbers under ON THIS RUN while the Unit Inspector
    # painted that unit's value for the same dimension inches away.
    assert on_this_run =~
             ~s|try { reading = MANUAL_RUN_READERS[slug]({run: run, unit: manualUnitInScope(run, route)}); } catch (_error) { reading = null; }|

    # The scope is PRINTED on every reading, unconditionally. A count with no
    # population named is a number the reader can only guess the meaning of.
    assert on_this_run =~
             ~s|dd.append(untrustedText("span", " · on " + scalar(reading.scope, MANUAL_SCOPE_RUN), "manual-run-scope"));|

    assert on_this_run =~ ~s|dd.dataset.manualScope = scalar(reading.scope, MANUAL_SCOPE_RUN);|

    # The opened unit is resolved with the SAME lookup renderUnit uses, off the
    # same projection, so "the pane found a unit" and "the Inspector painted
    # that unit" cannot come apart.
    unit_scope =
      js
      |> String.split("function manualUnitInScope(run, route) {")
      |> Enum.at(1)
      |> String.split("\n  }\n")
      |> hd()

    assert unit_scope =~
             ~S<if (!route || route.view !== "unit" || !route.unitId) return null;>

    assert unit_scope =~
             ~S<return array(run && run.units).find(function (candidate) { return candidate.logical_id === route.unitId; }) || null;>

    assert js =~
             ~s|const unit = array(run.units).find(function (candidate) { return candidate.logical_id === route.unitId; });|

    # The two scope words are defined ONCE, like every other vocabulary this
    # pane shares with the rail.
    assert js =~ ~s|const MANUAL_SCOPE_RUN = "this run";|

    assert js =~
             ~s|function manualUnitScopeLabel(unit) { return "this unit (" + scalar(unit && unit.logical_id, "unknown") + ")"; }|
  end

  test "the per-unit dimensions read the OPENED unit, and the run-scoped ones do not",
       %{js: js} do
    # The corpus defines `runtime-gate` as "the Unit Inspector's label for the
    # runtime's own gate decision on one unit", and the Inspector paints
    # unit.gate.state with unit.gate.basis. The reader must produce that same
    # pair -- value AND basis -- or the pane states a different provenance for
    # the one dimension the card beside it is painting.
    #
    # And the VALUE must be the card's own WORD, not a re-derivation of it. The
    # pin therefore requires the SHARED label path: the pane calls the same
    # unitGateLabel() the "Runtime gate" card calls, so the two cannot print
    # different words for one gate value again. Aliasing the token here (as the
    # shipped reader did) renamed `checkpoint_ready` to "ready" while the card
    # inches away rendered "checkpoint ready" -- two words, one value, on the
    # one route where this term's surface string appears.
    assert js =~
             ~s|if (scope.unit) return {value: unitGateLabel(scope.unit), basis: scope.unit.gate && scope.unit.gate.basis, scope: manualUnitScopeLabel(scope.unit)};|

    # ONE definition, TWO call sites -- the pane's and the card's -- which is
    # what makes divergence structurally impossible rather than merely fixed.
    assert js =~
             ~s|function unitGateLabel(unit) { return titleCase(unit && unit.gate && unit.gate.state); }|

    assert js =~
             ~s|labeledTruthCard(route, "Runtime gate", "gate", unitGateLabel(unit), unit.gate && unit.gate.state, unit.gate && unit.gate.basis)|

    # The denial half quotes the card too: the TERM keeps its own surface string
    # ("Ready"), but the state the unit is reported to be in is the card's word.
    assert js =~ ~s|"Not " + label + " — this unit reads " + unitGateLabel(scope.unit)|

    # Attention distinguishes ABSENT from NO, and it does so through ONE reader
    # at BOTH scopes. A unit whose projection carries no attention object must
    # not be reported "not required" -- a negative the projection never asserts
    # -- nor stamped with the parent-log basis, which would attribute a
    # provenance to a fact that was never read; and it must not be counted into
    # the negative bucket of the run fold either, where the same fabricated
    # negative would reach the more-travelled run-detail route inside a number.
    assert js =~ ~s|const bucket = unitAttentionBucket(scope.unit);|

    assert js =~
             ~s|if (bucket === null) return {value: MANUAL_ATTENTION_ABSENT, basis: null, scope: manualUnitScopeLabel(scope.unit)};|

    assert js =~ ~s|function unitHasAttentionRecord(unit) {|

    assert js =~
             ~s|const MANUAL_ATTENTION_ABSENT = "No attention record on this unit|

    # The bucket reader itself: absence returns null, which stateCounts and
    # semanticZoomDistribution both skip, so it is EXCLUDED from every count
    # rather than bucketed -- the same shape runAdvisoryCounts's
    # `present === true` guard has, which is the precedent this dimension was
    # missing.
    assert js =~ ~s|function unitAttentionBucket(unit) {|
    assert js =~ ~s|if (!unitHasAttentionRecord(unit)) return null;|

    assert js =~
             ~s|return unit.attention.required === true ? "yes" : "no";|

    # And every attention distribution folds through it -- the rail's card and
    # the manual's run branch via runAttentionCounts, the semantic-zoom cluster
    # row directly. Counted, so a NEW inline `required === true ? "yes" : "no"`
    # at any call site is as visible as a surviving one: the expression appears
    # exactly once in the bundle, in unitAttentionBucket.
    assert js =~
             ~s|function runAttentionCounts(run) { return stateCounts(run.units, unitAttentionBucket); }|

    assert length(String.split(js, ~s|attention.required === true ? "yes" : "no"|)) == 2

    # Execution and Liveness take the same shape: the entity the view is
    # painting, never the run folded around it.
    assert js =~ ~S<const entity = scope.unit || scope.run;>

    # Source is RUN-scoped by contract ("Source is run-scoped, never per unit"),
    # so its readers name the run even while a unit is open. Narrowing them
    # would invent a per-unit value no projection carries.
    assert js =~ ~s|const mode = scope.run.source && scope.run.source.mode;|
    assert js =~ ~s|basis: scope.run.source && scope.run.source.durable_origin, scope: MANUAL_SCOPE_RUN};|

    # One unit's advisory bucket is decided by ONE function, shared with the run
    # fold's own rules -- absence excluded by `present === true`, an unparseable
    # advisory counted `invalid` -- so the two scopes cannot classify one unit
    # differently.
    # Absence is NAMED, not resolved to the card's titleCase of a missing field
    # -- which is "unknown", the exact word the alias map exists to rename,
    # because an unclassifiable verdict and no verdict at all are different
    # facts. The corpus says so under `unclassified verdict`: "Absence never
    # reaches a bucket; the present===true guard keeps it out of every count."
    assert js =~
             ~S<return bucket === null ? "no advisory" : distributionValueLabel(bucket, ADVISORY_DISPLAY_ALIASES);>

    assert js =~ ~s|function unitAdvisoryBucket(unit) {|
    assert js =~ ~S<if (!unit.advisory || unit.advisory.present !== true) return null;>
    assert js =~ ~s|if (unit.advisory.parse_status === "invalid") return "invalid";|
  end

  test "`unobserved` is answered as the list-scope value it is, never denied", %{js: js} do
    table = reader_table(js)

    # `unobserved` is folded by list_liveness alone (source.ex); the detail
    # builder's liveness/4 emits no such token, and the contract says so
    # outright. Bound like its two siblings it rendered a STRUCTURALLY INVARIANT
    # denial -- "Not unobserved" on every run forever, affirmative branch
    # unreachable -- while the runs-list cell the reader clicked through from
    # printed `unobserved` for that very run.
    assert table =~
             ~s|"unobserved": function (scope) { return manualListOnlyLivenessReading(scope, "unobserved"); }|

    refute table =~ ~s|"unobserved": function (scope) { return manualLivenessValueReading(scope, "unobserved"); }|

    # The two siblings ARE detail-scope values and keep the denial shape.
    assert table =~
             ~s|"stale-handle": function (scope) { return manualLivenessValueReading(scope, "stale_handle"); }|

    assert table =~
             ~s|"externally-owned": function (scope) { return manualLivenessValueReading(scope, "externally_owned"); }|

    # The reading states the SCOPE fact and then what the entity actually reads.
    # Both halves are true at once, which the denial never was.
    assert js =~
             ~s|value: "A list-scope value only — no detail projection reads " + titleCase(token) + ", so " + subject + " reads " + titleCase(state) + " here while its row in the Runs list may still read " + titleCase(token) + ".",|
  end

  test "the run is read from the painted VIEW, never from route shape alone", %{js: js} do
    scope =
      js
      |> String.split("function manualRunInScope(route, painted) {")
      |> Enum.at(1)
      |> String.split("\n  }\n")
      |> hd()

    # The same identity guard renderCurrent uses to decide whether a cached
    # detail may be painted at all. Anything looser lets the pane read a detail
    # the view beside it is no longer painting.
    assert scope =~
             ~S{if (!route || (route.view !== "detail" && route.view !== "unit")) return null;}

    assert scope =~ "const run = state.detail;"
    assert scope =~ "if (!run || !run.run || run.run.id !== route.runId) return null;"
    assert scope =~ "if (state.detailId !== route.runId) return null;"

    assert scope =~
             ~s|if (workspaceSetMode() && state.detailWorkspace !== route.workspace) return null;|

    # The route checks are NECESSARY and NOT SUFFICIENT: they establish that the
    # cached detail is the one this route names, never that a renderer painted
    # it. renderUnit bails to renderUnavailable WITHOUT clearing state.detail,
    # so on an absent logical unit every identity check above still passed and
    # the pane rendered a live, basis-attributed, seq-stamped reading beside a
    # view declaring the projection unavailable.
    assert scope =~ "if (!paintedRunScopeView(painted)) return null;"

    # Nothing is memoized: a cached run would survive the route change that must
    # invalidate it.
    refute scope =~ "state.manualRun"
  end

  test "scope is decided by the painted view, with the follow-unit case admitted by name",
       %{js: js} do
    painted =
      js
      |> String.split("function paintedRunScopeView(painted) {")
      |> Enum.at(1)
      |> String.split("\n  }\n")
      |> hd()

    # The renderer's own answer about which view it produced.
    assert painted =~
             ~S[if (classes.indexOf("detail-view") >= 0 || classes.indexOf("unit-view") >= 0) return true;]

    # The ONE error view that is genuinely run-scoped, admitted by the
    # followState its renderer stamps rather than by class, so no other error
    # view inherits the exemption. Its own copy states that "the followed run
    # identity is still projected. Only this logical unit is absent within the
    # followed run", so denying run scope there would make the pane refuse a
    # value the view beside it is affirming.
    assert painted =~
             ~s|return !!(painted && painted.dataset && painted.dataset.followState === "unit_unavailable");|

    assert js =~ ~s|followState: "unit_unavailable",|

    assert js =~
             ~s|"The followed run identity is still projected. Only this logical unit is absent within the followed run; Follow did not switch or lose the run."|

    # The pane mounts at the single seam every renderer funnels through, and it
    # is handed the node being painted -- which is what makes the receipt
    # available at all.
    assert js =~ "const pane = renderManualPane(route, node);"

    # The no-run copy for a bailed-out run route points at the view rather than
    # diagnosing on its own: the view beside the pane already says what went
    # wrong, and a pane repeating a diagnosis it did not make is speaking beyond
    # its evidence.
    assert js =~
             ~s|if (!paintedRunScopeView(painted)) return "No run is in scope. This route names a run, but the view beside this pane is not painting one; read that view for why. Nothing is read from a remembered projection here.";|
  end

  test "list and overview scopes say no run is in scope, in Monitor voice", %{js: js} do
    copy =
      js
      |> String.split("function manualNoRunCopy(route, painted) {")
      |> Enum.at(1)
      |> String.split("\n  }\n")
      |> hd()

    # The runs list and the Workspace Overview are ordinary destinations, not
    # outages, so the sentence names the scope and where the value CAN be seen
    # rather than implying something broke.
    assert copy =~
             ~s|if (view === "runs") return "No run is in scope. The Runs list shows many runs at once, so there is no single run to read this from; open one run to see its value here.";|

    assert copy =~
             ~s|if (view === "workspaces") return "No run is in scope. The Workspace Overview is above run scope, so there is no run to read this from; open a workspace's Runs list and then one run to see its value here.";|

    assert copy =~ ~s|if (view === "invalid") return "No run is in scope.|
  end

  test "the no-run-value slug inventory is exported as frozen data", %{js: js} do
    # T7's anti-rot predicate reads this inventory rather than re-deriving it:
    # two derivations of the same set is two sources of truth for which terms
    # this pane may stay silent about.
    assert js =~ "const MANUAL_NO_RUN_VALUE_SLUGS = (function () {"
    assert js =~ "return Object.freeze(unbound.sort());"

    assert js =~
             "manualRunValueSlugs: Object.freeze(Object.keys(MANUAL_RUN_READERS).sort()), manualNoRunValueSlugs: MANUAL_NO_RUN_VALUE_SLUGS"

    # Derived from the corpus, so a term added to the glossary lands in the
    # inventory automatically instead of silently acquiring a fabricated value.
    assert js =~ "const entries = manualEntries();"
    assert js =~ "!Object.prototype.hasOwnProperty.call(MANUAL_RUN_READERS, slug)"
  end

  test "ON THIS RUN reuses the SHIPPED display vocabulary, with no parallel table",
       %{js: js} do
    # Words are contract (DESIGN.md binding constraint 1). The manual renders the
    # advisory, gate and attention dimensions, so it must reach the SAME alias
    # maps the truth rail reaches. A second copy of these strings here would let
    # the rail and the pane drift into saying different things about one value.
    assert js =~ ~s|const ADVISORY_DISPLAY_ALIASES = Object.freeze({unknown: "unclassified verdict"});|
    assert js =~ ~s|const GATE_DISPLAY_ALIASES = Object.freeze({checkpoint_ready: "ready"});|

    assert js =~
             ~s|const ATTENTION_DISPLAY_ALIASES = Object.freeze({yes: "required", no: "not required"});|

    # The advisory readers pass the SHIPPED constant, never a literal.
    assert js =~ "ADVISORY_BUCKET_ORDER, ADVISORY_DISPLAY_ALIASES"
    assert js =~ ~s|manualBucketPhrase(runAdvisoryCounts(scope.run), token, ADVISORY_DISPLAY_ALIASES)|

    # "unclassified verdicts" -- the PLURAL alias -- comes from the shipped
    # pluralizer, not from a second string in the manual.
    assert js =~ ~s|if (label === "unclassified verdict") return "unclassified verdicts";|
    assert js =~ "pluralizeDistributionLabel(distributionValueLabel(name, aliases), count)"
    assert js =~ "pluralizeDistributionLabel(distributionValueLabel(bucket, aliases), count)"

    # The post-terminal dimension has no alias MAP -- its display vocabulary is
    # a function, postTerminalLabel -- so the same constraint takes the same
    # shape: every surface that renders it CALLS that function. Three do (the
    # runs-list cell, the truth card, and this pane, both its whole-dimension
    # reader and its value term), and none of them titleCases the raw state
    # token. A titleCase here is a parallel copy table by another name: it had
    # the pane read "None" beside a rail reading "No child events after the run
    # ended", explaining a word no other surface uses.
    assert js =~
             ~s|return {value: postTerminalLabel(activity), basis: activity.basis, scope: MANUAL_SCOPE_RUN};|

    assert js =~ ~s|const node = text("span", postTerminalLabel(activity),|
    refute js =~ "titleCase(activity.state)"

    # The phrases themselves are defined ONCE, in postTerminalLabel. Counted
    # rather than asserted absent, so a new literal is as visible as a surviving
    # one. The `undetermined` phrase appears TWICE by design: once as the label
    # and once as the corpus `surface_string`, which is how the glossary quotes
    # the words a term names -- the same shape as "Attention (parent-observed)"
    # above.
    assert length(String.split(js, ~s|"No child events after the run ended"|)) == 2
    assert length(String.split(js, ~s|"Undetermined (child evidence unavailable)"|)) == 3
    assert js =~ ~s|"surface_string": "Undetermined (child evidence unavailable)"|
    assert length(String.split(js, ~s| child events after the run ended"|)) == 3

    # The rail's own label stays the shipped one, and the manual's attention
    # entry surfaces it verbatim through the corpus.
    assert js =~ ~s|distributionCard(route, "Attention (parent-observed)", "attention", attentionCounts, ATTENTION_BUCKET_ORDER, ATTENTION_DISPLAY_ALIASES, ATTENTION_FOLD_BASIS)|

    assert js =~ ~s|"surface_string": "Attention (parent-observed)"|

    # The BASIS strings and the empty-distribution phrase get the same treatment
    # as the alias maps, for the same reason and with the same idiom. A basis is
    # a claim about where a number came from, so a rail and a pane holding
    # separate literals is a parallel copy table for PROVENANCE: renaming the
    # rail's basis and updating only the rail's own pin left the pane
    # attributing a stale provenance to a live reading, inches away, with
    # nothing failing -- because the two sides were pinned independently, here
    # and in the executed tier, and neither pin ever compared them.
    #
    # Counted, not merely asserted present, so a NEW literal at any call site is
    # as visible as a surviving one. Each appears exactly TWICE in the bundle:
    # once in its frozen definition, once in the doctrine comment above it.
    assert js =~ ~s|const GATE_FOLD_BASIS = "unit checkpoint fold";|
    assert js =~ ~s|const ADVISORY_FOLD_BASIS = "model declared";|
    assert js =~ ~s|const ATTENTION_FOLD_BASIS = "parent log";|
    assert js =~ ~s|const EMPTY_DISTRIBUTION_PHRASE = "0 observed";|

    assert length(String.split(js, ~s|"unit checkpoint fold"|)) == 2
    assert length(String.split(js, ~s|"model declared"|)) == 2
    assert length(String.split(js, ~s|"parent log"|)) == 2
    assert length(String.split(js, ~s|"0 observed"|)) == 2

    # And every call site takes the constant: the rail's three cards, the Unit
    # Inspector's advisory card, the pane's folds, and the cluster row's empty
    # phrase.
    assert js =~
             ~s|distributionCard(route, "Dependency gate", "gate", gateCounts, GATE_BUCKET_ORDER, GATE_DISPLAY_ALIASES, GATE_FOLD_BASIS)|

    assert js =~
             ~s|distributionCard(route, "Model advisory", "advisory", advisoryCounts, ADVISORY_BUCKET_ORDER, ADVISORY_DISPLAY_ALIASES, ADVISORY_FOLD_BASIS,|

    assert js =~
             ~s|labeledTruthCard(route, "Model advisory", "advisory", unitAdvisoryLabel(unit), unit.advisory && unit.advisory.verdict, ADVISORY_FOLD_BASIS,|

    # And the card's word comes from the SAME bucket classification the pane
    # and every fold use — invalid FIRST, then the aliased verdict. Aliasing
    # the raw verdict was the round-2 adversarial catch on #553: an invalid
    # advisory carrying verdict "unknown" painted "unclassified verdict" on
    # the card while the pane correctly said "invalid".
    advisory_label_body =
      js
      |> after_anchor("function unitAdvisoryLabel(unit) {")
      |> String.split("\n  }")
      |> hd()

    assert advisory_label_body =~ "const bucket = unitAdvisoryBucket(unit);",
           "unitAdvisoryLabel no longer classifies through unitAdvisoryBucket; invalid advisories will alias their raw verdict again"

    assert advisory_label_body =~ "distributionValueLabel(bucket, ADVISORY_DISPLAY_ALIASES)",
           "unitAdvisoryLabel no longer paints the classified bucket through the shipped alias map"

    assert js =~ ~S<return {value: phrase || EMPTY_DISTRIBUTION_PHRASE, basis: GATE_FOLD_BASIS, scope: MANUAL_SCOPE_RUN};>

    assert js =~
             ~S<return {value: phrase || EMPTY_DISTRIBUTION_PHRASE, basis: ATTENTION_FOLD_BASIS, scope: MANUAL_SCOPE_RUN};>

    assert js =~
             ~S<return {value: phrase || EMPTY_DISTRIBUTION_PHRASE, basis: ADVISORY_FOLD_BASIS, scope: MANUAL_SCOPE_RUN};>

    assert js =~
             ~s|wrap.append(labeledMarker(EMPTY_DISTRIBUTION_PHRASE, "unknown", dimension + " distribution", basis));|

    # ONE definition each, referenced everywhere a DISTRIBUTION is rendered.
    # These maps and orders are words on screen, and four surfaces now fold each
    # dimension into counts: the runs list cell, the detail truth rail, this
    # pane at run scope, and the semantic-zoom cluster row. (Naming one unit's
    # gate state is a different job with its own single definition,
    # unitGateLabel, pinned above -- the block's own text says so and is pinned
    # for saying so below.) A literal at any call site is a parallel copy table
    # by another name -- it lets one surface be renamed while the manual goes on
    # explaining a vocabulary no other surface uses. An OMITTED alias slot is
    # the same divergence wearing a different coat: the cluster row printed
    # `checkpoint_ready 3` and `yes 1` for the counts every other surface read
    # aloud as `3 ready` and `1 required`, so the slot is pinned below too.
    # Counted rather than asserted absent, so a NEW literal is as visible as a
    # surviving one.
    #
    # The gate order and its alias appear exactly once: in the frozen
    # definition. Every renderer takes the constant.
    assert length(String.split(js, ~s|["needs_orchestrator", "failed", "held", "partial", "unknown", "checkpoint_ready", "not_applicable"]|)) ==
             2

    assert length(String.split(js, ~s|{checkpoint_ready: "ready"}|)) == 2
    assert length(String.split(js, ~s|{yes: "required", no: "not required"}|)) == 2

    # THE BLOCK THAT DECLARES THIS CONTRACT MUST DECLARE THE TRUE ONE. It is the
    # load-bearing canon for the one value the gate alias map exists to rename,
    # so a reader who trusts it and finds it overbroad re-introduces the exact
    # defect it was written after. It once said the maps are the words on screen
    # for every surface rendering each dimension, "the instrument manual's ON
    # THIS RUN part" enumerated among them -- which stopped being true the
    # moment that part's UNIT branch was routed through unitGateLabel instead,
    # deliberately, to stop printing "ready" beside a card reading "checkpoint
    # ready". Nothing failed when it went false, because nothing read it.
    #
    # It is read here now. The block must name what the maps actually govern
    # (buckets in a count), and must name the other job and its own single
    # definition (one entity's state, through unitGateLabel), because a contract
    # that omits the exception is what the omission cost.
    assert js =~ "WHAT THESE MAPS GOVERN IS DISTRIBUTIONS"
    assert js =~ "An alias\n  // renames a BUCKET IN A COUNT"
    assert js =~ "Naming ONE ENTITY'S STATE is a different job and deliberately does NOT come"
    assert js =~ "// through here."

    assert js =~
             "not \"every gate rendering passes through this map\"; it is that each of the"

    # And the attention half of the same block names ITS rule, which is absence
    # rather than a second label path.
    assert js =~ "an absent record is\n  // excluded from the counts by unitAttentionBucket, never bucketed as \"no\""

    # The rail's Dependency-gate card is pinned with its basis constant above,
    # beside the other three call sites, so it is not restated here.
    assert js =~
             ~s|distributionMarkers(row.gate_counts, GATE_BUCKET_ORDER, GATE_DISPLAY_ALIASES, "gate distribution", "parent_log_only")|

    # The fourth surface: the semantic-zoom cluster row takes the same three
    # alias maps in its `dimensions` table rather than a null alias slot. Its
    # attention READER is the shared unitAttentionBucket too, not a fourth
    # inline collapse of absence into the negative bucket.
    assert js =~ ~s|return unit.gate && unit.gate.state; }, GATE_DISPLAY_ALIASES]|
    assert js =~ ~s|["Attention", "attention", unitAttentionBucket, ATTENTION_DISPLAY_ALIASES]|

    # The per-run unit folds are named once and shared with truthRail. The
    # advisory fold carries a real decision -- absence excluded by the
    # `present === true` guard, an unparseable advisory counted `invalid` rather
    # than given an invented verdict -- and a second copy of it would be a
    # second place for that decision to be got wrong.
    assert js =~ "const gateCounts = runGateCounts(run);"
    assert js =~ "const advisoryCounts = runAdvisoryCounts(run);"
    assert js =~ "const attentionCounts = runAttentionCounts(run);"

    # The liveness vocabulary has no "terminal" value anywhere in the bundle: a
    # terminal run reads not_applicable, which is what the corpus itself says.
    # Synthesizing one would put a state on screen no projection can produce and
    # no filter can select.
    refute js =~ ~s|"terminal"|
    refute js =~ "liveness: [\"unobserved\", \"not_applicable\", \"terminal\"]"
    assert js =~ ~s|liveness: ["unobserved", "not_applicable"]|
  end

  test "citation provenance disclaims its own stale line pins", %{js: js} do
    assert entry_body(js) =~
             ~s|"Citations are authored grounding. Their line numbers are historical and are not maintained against the current tree; the module and function names are the durable anchors."|
  end

  test "an absent corpus produces an honest degraded pane, never a fabricated one", %{js: js} do
    assert js =~ "function manualDegraded(root)"

    assert js =~
             ~s|"Manual data is not available in this build. The pane is routed and reachable; the term corpus is not loaded, so no definition can be shown. Nothing is being withheld and nothing is being guessed."|

    assert js =~ "if (entries === null || concerns === null) return manualDegraded(root);"
    # Every corpus read stays typeof-guarded: the pane links against the data
    # side when it is there and degrades when it is not.
    assert js =~ ~s|if (typeof glossaryEntries !== "function") return null;|
    assert js =~ ~s|if (typeof glossaryConcerns !== "function") return null;|
    assert js =~ ~s|if (typeof glossaryBySlug !== "function") return null;|
  end

  test "the index groups by concern and emits each section's title and blurb", %{js: js} do
    body = index_body(js)

    assert body =~ "const concerns = manualConcerns();"
    assert body =~ "concerns.forEach(function (concern) {"
    assert body =~ ~s|entry.concern.key === conceptKey|
    assert body =~ ~s|untrustedText("h3", scalar(concern.title, conceptKey))|
    assert body =~ ~s|untrustedText("p", scalar(concern.blurb, ""), "manual-group-blurb")|
    assert body =~ ~s|el("ul", "manual-term-list")|

    assert body =~
             ~s|projectedLink(scalar(entry.term, entry.slug), manualRoute(route, entry.slug), "manual-term:" + scalar(entry.slug, ""))|

    assert body =~
             ~s|entries.length + " terms, grouped by the concern each one answers. Every entry is a hash route you can paste into an issue."|
  end

  test "an unresolved slug lands on the index and says so, rather than blanking", %{js: js} do
    body = index_body(js)

    assert body =~ ~s|el("p", "manual-unknown-slug")|
    assert body =~ ~s|unknown.append(text("span", "No manual entry is named "));|
    assert body =~ ~s|unknown.append(untrustedText("span", requested));|
    assert body =~ ~s|unknown.append(text("span", ". The full index is below."));|
  end

  test "a corpus that renders no group confesses instead of leaving a bare lede", %{js: js} do
    body = index_body(js)

    # manualDegraded fires only when an accessor returns NULL. When the
    # accessors ANSWER but every group is skipped -- an empty corpus, or entries
    # whose concern.key matches no concern object (a shape drift at the data
    # seam) -- the pane used to render its lede ("N terms, grouped by...") and
    # then nothing at all: a count asserted and never displayed, which is the
    # same blanking the unknown-slug path exists to prevent.
    assert body =~ "let shown = 0;"
    assert body =~ "shown += grouped.length;"
    assert body =~ "if (!shown) root.append("

    # Both zero-render shapes are NAMED, and each states what the data side
    # actually returned rather than implying a display failure.
    assert body =~
             ~s|"The term corpus loaded and is empty: it contains no entries, so there is nothing to group. This is what the data side returned, not a display failure and not a filter."|

    assert body =~ ~s|"The term corpus loaded with " + entries.length + " entries and " + concerns.length + " concerns, but no entry's concern matches a known concern|

    # The PARTIAL case is confessed too: a lede claiming N terms over a list
    # showing fewer is the same defect in miniature, so the shortfall is stated
    # with both numbers rather than left for the reader to notice.
    assert body =~ ~s|else if (shown < entries.length) root.append(|
    assert body =~ ~s|"Showing " + shown + " of " + entries.length + " terms.|
  end

  test "the pane renders the #manual route identity its own copy tells readers to paste",
       %{js: js, css: css} do
    pane =
      js
      |> String.split("function renderManualPane(route, painted) {")
      |> Enum.at(1)
      |> String.split("// Tab/focus model")
      |> hd()

    # Hash-routing is load-bearing for this pane (DESIGN.md: "definitions must
    # be linkable in issues and PRs"), and the index lede tells the reader that
    # "Every entry is a hash route you can paste into an issue." Rendering no
    # route made that an instruction the pane never instantiated.
    assert pane =~ ~s|header.append(untrustedText("code", "#manual/" + shownSlug, "manual-route-id"));|

    # The chip names what the pane is SHOWING, not what was requested: an
    # unresolved slug lands the reader on the index, so pinning the requested
    # slug there would print a route that does not open this content.
    assert pane =~ "const entry = requested === MANUAL_INDEX ? null : manualEntry(requested);"
    assert pane =~ "const shownSlug = entry ? requested : MANUAL_INDEX;"

    # The chip is resolved BEFORE the header is built, or `shownSlug` could not
    # know which body the pane is about to render.
    {slug_at, _} = :binary.match(pane, "const shownSlug")
    {header_at, _} = :binary.match(pane, ~s|el("header", "manual-pane-header")|)
    assert slug_at < header_at

    assert css =~ ".manual-route-id"
  end

  test "the shell gives the pane its own column and collapses at the 900px breakpoint", %{
    css: css
  } do
    assert css =~
             ".manual-shell { display: grid; grid-template-columns: minmax(0, 1fr) 452px;"

    assert css =~ ".manual-shell > * { min-width: 0; }"
    assert css =~ ".manual-pane { position: sticky;"
    assert css =~ ".manual-pane-header"
    assert css =~ ".manual-pane-body"
    assert css =~ ".manual-parts"
    assert css =~ ".manual-on-this-run"
    assert css =~ ".manual-no-run"

    collapse =
      css
      |> String.split("@media (max-width: 900px) {")
      |> Enum.at(1)
      |> String.split("@media (max-width: 640px) {")
      |> hd()

    assert collapse =~ ".manual-shell { grid-template-columns: minmax(0, 1fr); }"
    assert collapse =~ ".manual-pane { position: static;"
  end
end
