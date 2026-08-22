defmodule PixirMonitor.UI.DottedLabelAffordanceContractTest do
  @moduledoc """
  Contract pins for the dotted labelled-term affordance (#551).

  The affordance's whole claim is a NEGATIVE one, and negatives rot silently.
  The mock's orientation line promises a reader that "Dotted labels are axes
  with a manual entry. Values are never marked." A build where the underline
  quietly appeared on a marker, on a monospace basis line, or on a projected
  string would still look fine, still be green, and would have broken the
  promise. So the refutations here carry as much weight as the assertions.

  Same source-pin idiom as the sibling UI contract tests: `app.js` and
  `app.css` are read as text and the shipped call sites are asserted against.
  These tests do not execute the bundle; what they defend is that the call
  sites, the mapping table, and the prohibited selectors are what they say.
  """

  use ExUnit.Case, async: true

  @js Path.expand("../../priv/static/app.js", __DIR__)
  @css Path.expand("../../priv/static/app.css", __DIR__)
  @terms Path.expand("../fixtures/glossary_terms.json", __DIR__)

  @orientation "Dotted labels are axes with a manual entry. Values are never marked."

  # Every SHIPPED label string this wave marks, paired with the slug it must
  # resolve to. This list is the acceptance criterion written down: the seven
  # truth-rail card headings, the Runs list column headers carrying a doctrine
  # term, the Unit Inspector's own label for the gate dimension, and the SSE
  # health pill vocabulary that DESIGN.md constraint 4 requires be reachable
  # from the first screen.
  #
  # The mismatches are DELIBERATE and are pinned as mismatches: the rail ships
  # "Child activity after end" where the list <th> ships "Child after end";
  # the rail ships "Dependency gate" where the Unit Inspector ships "Runtime
  # gate". No shipped string was reworded to make a lookup convenient. (The
  # list ships NO "Attention" column — attention rides the row's inline copy —
  # so no Attention pair exists; naming one here was the round-1 inventory
  # fiction, #553.)
  @labelled_terms [
    # Truth-rail card headings (seven).
    {"Execution", "execution"},
    {"Liveness", "liveness"},
    {"Dependency gate", "dependency-gate"},
    {"Model advisory", "model-advisory"},
    {"Source (run-scoped)", "source-run-scoped"},
    {"Attention (parent-observed)", "attention"},
    {"Child activity after end", "child-after-end"},
    # Runs list column headers with a doctrine term.
    {"Gate", "dependency-gate"},
    {"Advisory", "model-advisory"},
    {"Source", "source-run-scoped"},
    {"Mutation", "mutation"},
    # No "Attention" short form: the list ships no Attention column (attention
    # rides the row's inline copy); the phantom mapping was dropped on #553.
    {"Child after end", "child-after-end"},
    # Unit Inspector.
    {"Runtime gate", "runtime-gate"},
    # Live-activity front door.
    {"hints only", "hints-only"},
    {"coalesced", "coalesced"},
    {"last successful authoritative refetch", "last-successful-authoritative-refetch"}
  ]

  # Runs list headers that name no doctrine term. They must stay PLAIN: a
  # dotted label whose target cannot define it is a dead link dressed as an
  # explanation, which is worse than no affordance at all.
  @unlabelled_headers ["Run", "Strategy", "Units", "Duration", "Latest"]

  setup_all do
    {:ok, js: File.read!(@js), css: File.read!(@css), terms: Jason.decode!(File.read!(@terms))}
  end

  defp body_between(js, from, to) do
    js
    |> String.split(from)
    |> Enum.at(1)
    |> case do
      nil -> flunk("app.js no longer contains #{inspect(from)}")
      rest -> rest |> String.split(to) |> hd()
    end
  end

  defp labelled_terms_table(js), do: body_between(js, "const LABELLED_TERMS = Object.freeze({", "});")

  # The shipped Runs column names, in order. Named once here so the parallel-copy
  # scan and its own mutation proof cannot drift apart.
  @runs_columns ["Run", "Strategy", "Execution", "Liveness", "Gate", "Advisory", "Source", "Units", "Mutation", "Duration", "Latest", "Child after end"]

  # Matches a bracketed array literal holding two or more Runs column names, in
  # ANY whitespace layout. The layout-insensitivity is the whole point: the
  # earlier version of this scan demanded a literal `", "` between names on one
  # line, so a parallel copy formatted one-name-per-line was invisible to it
  # while the failure message went on claiming "exactly one is allowed".
  defp column_array_regex do
    names = Enum.map_join(@runs_columns, "|", &Regex.escape/1)
    Regex.compile!("\\[\\s*(?:\"(?:#{names})\"\\s*,\\s*){1,}\"[^\"]+\"\\s*,?\\s*\\]", "s")
  end

  # The ordered string literals stamped by cellLabel(...) calls, extracted with
  # a paren-balanced scan so nested call arguments (text("td", ...),
  # postTerminalCell(...)) cannot hide the label argument from the pin. The
  # array scan above is structurally blind to a copy DISTRIBUTED across call
  # sites, and below 480px those per-call literals — not RUNS_COLUMNS — are the
  # column vocabulary the reader actually sees (content: attr(data-cell-label)).
  defp cell_label_literals(js) do
    js
    |> String.split("cellLabel(")
    |> Enum.drop(1)
    |> Enum.map(&balanced_call_body/1)
    |> Enum.map(fn body -> Regex.run(~r/"([^"]*)"\s*\z/, body, capture: :all_but_first) end)
    |> Enum.flat_map(fn
      [label] -> [label]
      nil -> []
    end)
  end

  # Walks from just inside an opening paren to its matching close, tracking
  # string literals so a paren inside a quoted argument cannot end the call.
  # ESCAPE-AWARE (adversarial CodeRabbit, #553): a bare quote toggle would let
  # an escaped quote inside a label flip the string state and miscount a paren.
  # Scope note: the walker tracks double-quoted strings only — this bundle's
  # style is double-quote-only (string_literals/1 documents the same bound), so
  # a single-quoted or template-literal label would be a style break first; if
  # one ever ships, the correspondence assertion goes red on the shortfall
  # rather than passing silently.
  defp balanced_call_body(rest), do: balanced_call_body(rest, 1, false, false, [])

  defp balanced_call_body(_rest, 0, _in_string, _escaped, [_closing_paren | acc]),
    do: acc |> Enum.reverse() |> List.to_string()

  defp balanced_call_body(<<>>, _depth, _in_string, _escaped, acc),
    do: acc |> Enum.reverse() |> List.to_string()

  defp balanced_call_body(<<ch::utf8, rest::binary>>, depth, in_string, escaped, acc) do
    {depth, in_string, escaped} =
      cond do
        escaped -> {depth, in_string, false}
        in_string and ch == ?\\ -> {depth, in_string, true}
        ch == ?" -> {depth, not in_string, false}
        in_string -> {depth, in_string, false}
        ch == ?( -> {depth + 1, in_string, false}
        ch == ?) -> {depth - 1, in_string, false}
        true -> {depth, in_string, false}
      end

    balanced_call_body(rest, depth, in_string, escaped, [ch | acc])
  end

  describe "the shared helper" do
    test "maps every shipped label to its slug in one enumerable table", %{js: js} do
      table = labelled_terms_table(js)

      for {label, slug} <- @labelled_terms do
        assert table =~ ~s|#{inspect(label)}: #{inspect(slug)}|,
               "LABELLED_TERMS no longer maps the shipped label #{inspect(label)} to #{inspect(slug)}"
      end
    end

    test "the table is exhaustive: it maps nothing beyond the pinned inventory", %{js: js} do
      mapped =
        ~r/"([^"]+)":\s*"([^"]+)"/
        |> Regex.scan(labelled_terms_table(js))
        |> Enum.map(fn [_all, label, slug] -> {label, slug} end)

      assert Enum.sort(mapped) == Enum.sort(@labelled_terms),
             """
             LABELLED_TERMS drifted from the pinned call-site inventory.

             Downstream anti-rot depends on this table being the exhaustive,
             enumerable list of every label the UI marks. Adding a mapping here
             without adding it to @labelled_terms hides a new dotted label from
             the inventory.
             """
    end

    test "every mapped slug exists in the glossary corpus", %{terms: terms} do
      known = MapSet.new(terms, & &1["slug"])

      for {label, slug} <- @labelled_terms do
        assert MapSet.member?(known, slug),
               "the label #{inspect(label)} maps to slug #{inspect(slug)}, which the corpus does not carry"
      end
    end

    test "an unknown label REFUSES build-visibly instead of degrading", %{js: js} do
      body = body_between(js, "function labelledTermSlug(label) {", "\n  }")

      assert body =~ "throw monitorDefect(",
             """
             labelledTermSlug must THROW on an unmapped label, and it must throw a
             MonitorDefect rather than a plain Error.

             A silent fallback to a plain heading is the exact rot the glossary's
             anti-rot constraint exists to prevent: the label drifts, its dotted
             underline vanishes, and nothing is red.

             The DEFECT CLASS is the second half, and it is what makes the refusal
             survive the shipped render path. Every render goes through
             renderCurrentGuarded, which catches. A plain Error is absorbed by
             normalizeProjectionFailure into projection_render_failed, which
             DISCARDS the label name and the whole diagnostic and paints "The
             fetched projection could not be displayed." — the Monitor's own
             authoring typo reported to the operator as a fault in their Log.
             """

      refute body =~ "throw new Error(",
             "a plain Error here is laundered by the render guard into an accusation against upstream evidence"

      assert body =~ "no glossary term is mapped for the shipped label"

      # It also refuses a mapped slug the corpus does not carry, so a typo in
      # the hand-written table cannot ship a dotted label that lands on the
      # manual's unknown-slug page.
      assert body =~ "glossaryBySlug(slug) === null"
      assert body =~ "which the glossary corpus does not carry"
    end

    test "the anchor is native, routed through manualRoute, and stamped for both consumers", %{js: js} do
      body = body_between(js, "function labelledTerm(tag, label, route, scope) {", "\n  }")

      assert body =~ ~s|text("a", label, "labelled-term")|,
             "a labelled term must be a NATIVE <a>: that is what makes it a tab stop and an Enter target with no key handling"

      assert body =~ "anchor.href = manualRoute(route, slug);",
             """
             the href must be built through manualRoute.

             A hand-built "#manual/<slug>" literal drops the current run,
             workspace, filters, sort, query, follow and zoom state, so opening
             a definition would silently move the operator.
             """

      refute body =~ "\"#manual/",
             "labelledTerm must never hand-build a manual hash literal"

      assert body =~ "anchor.dataset.manualTerm = slug;",
             "data-manual-term is the browser harness's stable click target"

      assert body =~ ~s|key(anchor, "manual-term-label:|,
             "data-focus-key is what lets restoreView refocus the label after a re-render"

      # The label is an authored literal, so it must NOT be laundered through
      # the projection sanitizer: doing so would imply it were untrusted.
      refute body =~ "untrustedText(",
             "a labelled term's text is an authored literal and must not pretend to be projected"
    end
  end

  describe "the marked call sites" do
    test "all seven truth-rail card headings are labelled", %{js: js} do
      rail = body_between(js, "function truthRail(run, route) {", "\n  }")

      for label <- [
            "Execution",
            "Liveness",
            "Dependency gate",
            "Model advisory",
            "Source (run-scoped)",
            "Attention (parent-observed)"
          ] do
        assert rail =~ ~s|#{inspect(label)}|,
               "the rail no longer emits the #{label} card"
      end

      # The heading of every card built by truthCard/distributionCard is a
      # labelled term, and the card's own value marker is not. truthCard
      # delegates to labeledTruthCard (the shared word path the unit-scope gate
      # rides), so the labelled heading lives there and serves both.
      assert body_between(js, "function truthCard(route, label, dimension, value, basis, extra) {", "\n  }") =~
               ~s|return labeledTruthCard(route, label, dimension, titleCase(value), value, basis, extra);|

      assert body_between(js, "function labeledTruthCard(route, label, dimension, valueLabel, tone, basis, extra) {", "\n  }") =~
               ~s|card.append(labelledTerm("h3", label, route));|

      assert body_between(js, "function distributionCard(route, label, dimension, counts, order, aliases, basis, extra) {", "\n  }") =~
               ~s|card.append(labelledTerm("h3", label, route));|

      # The seventh card is built by its own function.
      assert body_between(js, "function postTerminalCard(activity, route) {", "\n  }") =~
               ~s|card.append(labelledTerm("h3", "Child activity after end", route));|
    end

    test "the Unit Inspector's 'Runtime gate' is labelled and keeps its shipped spelling", %{js: js} do
      assert js =~ ~s|labeledTruthCard(route, "Runtime gate", "gate", unitGateLabel(unit), unit.gate && unit.gate.state|,
             """
             the Unit Inspector must still say "Runtime gate".

             The rail says "Dependency gate" for the same dimension. The mismatch
             is shipped vocabulary; the mapping table absorbs it. Rewording
             either surface to make one lookup serve both is forbidden.
             """
    end

    test "Runs list column headers with a doctrine term are labelled, and the rest are not", %{js: js} do
      body = body_between(js, "function runTable(rows, total, group, matches, focusKey, route) {", "\n  }")

      assert body =~
               ~s|hr.append(Object.prototype.hasOwnProperty.call(LABELLED_TERMS, name) ? labelledTerm("th", name, route, "runs-header:" + group) : text("th", name));|,
             "the header row must label exactly the names present in LABELLED_TERMS and leave the rest plain"

      table = labelled_terms_table(js)

      for header <- @unlabelled_headers do
        refute table =~ ~s|#{inspect(header)}: |,
               "#{inspect(header)} is an ordinary table noun with no glossary entry and must stay unmarked"
      end
    end

    test "the header row's focus keys are scoped per group so both tables can coexist", %{js: js} do
      helper = body_between(js, "function labelledTerm(tag, label, route, scope) {", "\n  }")

      assert helper =~ ~s|(scope ? scope + ":" : "")|,
             """
             the Runs view paints the header row once per group table, so the
             two copies of "Gate" would share a focus key and restoreView would
             land the operator on whichever came first in the DOM.
             """
    end
  end

  describe "the typographic honesty rule" do
    test "the dotted treatment has its own class and rides no forbidden selector", %{css: css} do
      assert css =~ ".labelled-term { border-bottom: 1px dotted currentcolor;",
             "the dotted underline must be painted by the dedicated .labelled-term class"

      # Comments are stripped first: the block comment above the rule explains
      # what the dotted treatment must never touch, and scanning prose for CSS
      # declarations would flag the explanation as a violation of itself.
      dotted_rules =
        css
        |> String.replace(~r|/\*.*?\*/|s, "")
        |> String.split("\n")
        |> Enum.filter(&(String.contains?(&1, "dotted") and String.contains?(&1, "border-bottom")))

      # Every selector that paints a dotted border-bottom must be a
      # .labelled-term selector. The three prohibited families are values
      # (.marker), basis lines (.provenance) and quoted evidence (code /
      # .projected-text): if any of them ever grew the treatment, the
      # orientation line's promise would be false and this would be the only
      # thing that noticed.
      for rule <- dotted_rules do
        selector = rule |> String.split("{") |> hd() |> String.trim()

        assert String.contains?(selector, ".labelled-term"),
               """
               a dotted border-bottom is painted by #{inspect(selector)}, which is not a .labelled-term selector.

               The affordance must never reach values, provenance lines, or
               quoted evidence.
               """

        for forbidden <- [".marker", ".provenance", ".truth-extra", ".projected-text", "code"] do
          refute String.contains?(selector, forbidden),
                 "the dotted treatment must not be coupled to #{forbidden} (selector: #{selector})"
        end
      end
    end

    test "the affordance never appears on a value, on evidence, or on a projected string", %{js: js} do
      # Values. `marker` and `labeledMarker` build every distribution bucket and
      # every state token on screen; neither may carry the class or the anchor.
      marker_body = body_between(js, "function labeledMarker(label, tone, dimension, basis) {", "\n  }")
      refute marker_body =~ "labelled-term"
      refute marker_body =~ "manualTerm"
      refute marker_body =~ "labelledTerm("

      # Quoted monospace evidence and any projected string. `projected`,
      # `untrustedText` and `projectedLink` are the three sinks every
      # non-authored string passes through.
      for fun <- [
            "function projected(parent, tag, value, className) {",
            "function untrustedText(tag, value, className) {",
            "function projectedLink(value, hash, focusKey) {"
          ] do
        body = body_between(js, fun, "\n  }")
        refute body =~ "labelled-term", "#{fun} must never emit the dotted affordance"
        refute body =~ "labelledTerm(", "#{fun} must never emit the dotted affordance"
        refute body =~ "manualTerm", "#{fun} must never stamp a manual term on a projected string"
      end

      # And the helper is never called with a runtime-derived string. Every call
      # site passes a double-quoted literal or a loop variable whose source is an
      # AUTHORED literal list — `label`, `name` (RUNS_COLUMNS, via
      # doctrineRunsColumns) and `term` (streamVocabularyTerms). The allowlist is
      # closed on purpose: each entry below is pinned to its literal source in
      # the assertion that follows, so adding a projected string to a call site
      # cannot pass by naming its variable conveniently.
      assert js =~ "const RUNS_COLUMNS = Object.freeze([" <> Enum.map_join(@runs_columns, ", ", &inspect/1) <> "]);",
             "`name` is only allowlisted because doctrineRunsColumns filters this authored constant"

      assert body_between(js, "function streamVocabularyTerms(streamState) {", "\n  }") =~
               ~s|["hints only", "coalesced"] : ["hints only"]|,
             "`term` is only allowlisted because streamVocabularyTerms returns authored literals"

      call_arguments =
        ~r/labelledTerm\(\s*"[a-z0-9]+"\s*,\s*([^,]+),/
        |> Regex.scan(js)
        |> Enum.map(fn [_all, argument] -> String.trim(argument) end)
        |> Enum.uniq()

      assert call_arguments != []

      for argument <- call_arguments do
        assert String.starts_with?(argument, "\"") or argument in ["label", "name", "term"],
               """
               labelledTerm was called with #{inspect(argument)}.

               Only authored literals may be labelled. A slug derived from a
               projected string is a routing primitive handed to an upstream
               Log.
               """
      end
    end

    test "the orientation and front-door copy is Monitor voice, not monospace", %{js: js, css: css} do
      refute js =~ ~s|"rail-orientation provenance"|
      refute js =~ ~s|"stream-vocabulary provenance"|
      refute js =~ ~s|"dimension-vocabulary provenance"|

      declarations = String.replace(css, ~r|/\*.*?\*/|s, "")

      for rule <- [".rail-orientation", ".stream-vocabulary", ".dimension-vocabulary", ".monitor-defect-diagnostic"] do
        line =
          declarations
          |> String.split("\n")
          |> Enum.find(&String.starts_with?(String.trim(&1), rule <> " {"))

        assert line, "#{rule} has no rule in app.css"

        refute String.contains?(line, "monospace"),
               """
               #{rule} must not be monospace.

               Monospace is the agent speaking and is never annotated. This copy
               is the Monitor explaining its own notation, so dressing it as
               transported agent output would invert the very rule it teaches.
               """
      end
    end
  end

  describe "the orientation line and the live-activity front door" do
    test "the orientation line ships verbatim beside both dimension grids", %{js: js} do
      assert body_between(js, "function truthRail(run, route) {", "\n  }") =~
               ~s|text("p", #{inspect(@orientation)}, "rail-orientation")|

      assert js =~ ~s|dimensions.append(text("p", #{inspect(@orientation)}, "rail-orientation"))|,
             "the Unit Inspector's dimension grid carries the same orientation line as the rail"
    end

    test "the SSE health pill vocabulary is reachable from the first screen", %{js: js} do
      body = body_between(js, "function repaintStreamVocabularyLine(line, route) {", "\n  }")

      assert body =~ ~s|labelledTerm("span", term, route, "front-door")|,
             "the state-dependent pill terms must each be a real anchor into the manual"

      assert body =~
               ~s|labelledTerm("span", "last successful authoritative refetch", route, "front-door")|,
             "the refetch phrase is emitted in every stream state, so it is named unconditionally"

      assert body =~ @orientation,
             "the front-door line carries the orientation sentence too: the first screen must teach the notation before the run detail does"

      # And it is actually painted on the Runs view, which is the first screen.
      runs = body_between(js, "function renderRuns() {", "\n  }")
      assert runs =~ "root.append(streamVocabularyLine(route));"
    end

    # The line QUOTES the pill. "coalesced" is emitted on the connected state
    # alone (setStatus builds a per-state string), so a line that asserted it
    # unconditionally had the Monitor claiming text that was not on screen on a
    # down or connecting stream — the exact dishonesty this affordance exists to
    # prevent.
    test "the stream orientation line quotes only the terms the current state shows", %{js: js} do
      body = body_between(js, "function repaintStreamVocabularyLine(line, route) {", "\n  }")

      assert body =~ "const terms = streamVocabularyTerms(state.streamState);",
             "the quoted vocabulary must be derived from observed stream state, not asserted"

      refute body =~ ~s|"coalesced"|,
             """
             "coalesced" must not be a literal in the orientation line: the pill
             only emits it while connected. It belongs to the per-state source.
             """

      source = body_between(js, "function streamVocabularyTerms(streamState) {", "\n  }")

      assert source =~
               ~s|streamState === "connected" ? ["hints only", "coalesced"] : ["hints only"]|,
             "the per-state vocabulary is the single source both the pill and its orientation line read"

      # And the pill itself is assembled from the same split, so the two cannot
      # drift apart silently.
      pill = body_between(js, "function setStatus(message) {", "\n  }")

      assert pill =~ "streamHealthText(state.streamState)",
             "the pill text is assembled by the same per-state helper family"

      health = body_between(js, "function streamHealthText(streamState) {", "\n  }")

      assert health =~ "SSE connected · hints only · coalesced"

      for state_name <- ["down", "connecting"] do
        assert health =~ "SSE #{state_name} · hints only · authoritative snapshots remain available",
               "the #{state_name} pill string shows no coalescing claim, and the orientation line must not invent one"
      end
    end

    # A stream transition repaints the pill through setStatus WITHOUT re-rendering
    # the view. Deriving the quote only at render time would leave a stale quote
    # on screen: the same absent-text claim, in slower motion.
    test "a stream transition repaints the orientation line, not just the pill", %{js: js} do
      pill = body_between(js, "function setStatus(message) {", "\n  }")

      assert pill =~ "document.querySelector(\".stream-vocabulary\")"
      assert pill =~ "repaintStreamVocabularyLine(vocabulary, vocabulary.__pixirRoute)"
    end

    # setStatus runs on the TAIL of every render, so an unconditional repaint
    # would rebuild this line's whole subtree on renders that have nothing to
    # say. The guard makes a same-state render a genuine no-op.
    #
    # It is a CHURN guard, and nothing more. It is deliberately NOT described as
    # the focus protection, because it is not one: a same-state render is exactly
    # the case where the repaint is unnecessary, while every REAL transition is a
    # case where the repaint must happen AND focus must survive it. Naming the
    # guard as the fix is what let the transition dead end ship. The protection is
    # pinned by the test below, and driven for real by the stream-transition
    # family in the manual-overlay preservation tier.
    test "a same-state render does not repaint the orientation line at all", %{js: js} do
      # Matched against the whole bundle, not a body_between slice: the guard is
      # the LAST statement of setStatus, and the slice's "\n  }" terminator cuts
      # at the guard's own closing brace.
      assert js =~
               ~s|vocabulary.__pixirTerms !== streamVocabularyTerms(state.streamState).join(" ")|,
             "the repaint fires only when the quoted vocabulary actually changed"

      paint = body_between(js, "function repaintStreamVocabularyLine(line, route) {", "\n  }")

      assert paint =~ ~s|line.__pixirTerms = terms.join(" ");|,
             "the painted line records what it is showing, so the guard has something to compare"
    end

    # THE TRANSITION PATH, which is the one that matters and the one a same-state
    # guard can never reach.
    #
    # Every term in this line is a native <a href> built by labelledTerm: a real
    # tab stop on the first screen. `replaceChildren()` detaches them, and the
    # browser collapses document.activeElement to document.body — the keyboard
    # dead end where the next Tab restarts at the top of the document.
    #
    # source.onopen and source.onerror call setStatus DIRECTLY, with no view
    # re-render, so replaceContent never runs and restoreView is nowhere near
    # them. `connecting -> connected` therefore fires seconds after page load with
    # no operator action at all, exactly while a keyboard user is tabbing into the
    # first screen. The preservation cannot live at a call site that does not
    # exist; it lives with the destruction, inside the repaint, where it holds for
    # every caller present and future.
    test "the repaint preserves focus across a real transition", %{js: js} do
      paint = body_between(js, "function repaintStreamVocabularyLine(line, route) {", "\n  }")

      assert paint =~ "const active = document.activeElement;",
             "the held focus must be read BEFORE the clear; afterwards it is document.body"

      assert paint =~ ~s|Array.from(line.querySelectorAll("[data-focus-key]")).indexOf(active) !== -1|,
             """
             the capture is SCOPED TO THIS LINE: focus parked elsewhere in the
             document is none of this repaint's business, and stealing it would
             be a worse defect than the one being fixed
             """

      assert paint =~ ~s|const same = anchors.find(function (candidate) { return candidate.dataset.focusKey === held; });|,
             "a term that survives the transition returns the operator to the very same anchor"

      assert paint =~ "const landing = same || anchors[0];",
             """
             and a term the new vocabulary legitimately drops ("coalesced" exists
             only while connected) lands the operator on the first anchor of the
             SAME sentence, rather than on document.body
             """

      assert paint =~ "if (landing) landing.focus({preventScroll: true});",
             "restored without scrolling the operator's view out from under them"

      # The two callers with no re-render around them, which is why the
      # preservation is inside the repaint rather than at a call site.
      connect = body_between(js, "function connect() {", "\n  }")

      assert connect =~ "source.onopen = function () {"
      assert connect =~ "source.onerror = function () {"

      assert connect =~ "setStatus(status.textContent)",
             "both stream handlers repaint the pill through setStatus with no view re-render"
    end

    test "the SSE health pill itself stays unmarked", %{js: js} do
      body = body_between(js, "function setStatus(message) {", "\n  }")

      refute body =~ "labelledTerm(",
             """
             the pill is one assembled status string whose parts change with
             observed stream state. Marking fragments of it would put dotted
             underlines on something that reads as a live value, contradicting
             the orientation line the same build ships.
             """

      refute body =~ "labelled-term"
    end
  end

  # ── The refusal must not become an accusation ──────────────────────────────
  #
  # The affordance's refusal is only worth having if it survives the SHIPPED
  # path. Every render funnels through renderCurrentGuarded, which catches. A
  # plain Error is absorbed by normalizeProjectionFailure into
  # projection_render_failed, whose copy is "The fetched projection could not be
  # displayed." and whose status line is "Snapshot loaded but could not be
  # displayed." In an instrument whose doctrine is honest provenance, that turns
  # a Monitor authoring typo into an accusation against the operator's Log —
  # and on a followed run the same path could route into the follow-degradation
  # views, so the typo could additionally masquerade as a run-identity problem.
  describe "a Monitor defect is attributed to the Monitor" do
    test "the defect class exists, carries its own name, and keeps the diagnostic", %{js: js} do
      body = body_between(js, "function monitorDefect(kind, message) {", "\n  }")

      assert body =~ ~s|defect.name = "MonitorDefect";|,
             "the name is what stops normalizeProjectionFailure from absorbing it"

      assert body =~ "defect.detail = String(message);",
             "the authored diagnostic names the exact label and slug at fault; discarding it discards the whole value of the throw"
    end

    test "the normalizer cannot absorb a defect, because the guard classifies first", %{js: js} do
      guard = body_between(js, "function renderRenderErrorSafely(error) {", "\n  }")

      assert guard =~ "if (isMonitorDefect(error)) return renderMonitorDefectSafely(error);",
             "the classification must precede the projection-failure path, not follow it"

      # And every render catch site goes through the classifier, not straight to
      # the projection-failure path. These are the seams that decide what the
      # operator sees.
      assert js =~ ~s|try { renderCurrent(); }\n    catch (error) { renderRenderErrorSafely(error); }|,
             "renderCurrentGuarded is the primary render seam"

      assert js =~ "refresh(currentReason).catch(renderRenderErrorSafely)",
             "a defect thrown inside an async refresh must not be laundered either"

      replay = body_between(js, "function replayLastPaint() {", "\n  }")

      assert replay =~ "catch (error) { renderRenderErrorSafely(error); }",
             "an overlay move that replays a paint must classify the same way"
    end

    test "the defect view names the Monitor and never accuses the projection", %{js: js} do
      body = body_between(js, "function renderMonitorDefect(defect) {", "\n  }")

      assert body =~ ~s|heading(1, "Monitor defect")|
      assert body =~ "a defect in the Monitor itself"

      assert body =~ "This is not a fact about the Log, the snapshot, or the run",
             "the view must refute the accusation the old path made, not merely omit it"

      assert body =~ ~s|text("p", defect.detail, "monitor-defect-diagnostic")|,
             "the diagnostic is shown verbatim; the old path discarded it entirely"

      assert body =~ ~s|root.dataset.errorPhase = "monitor";|,
             "the diagnostic phase must not be one of the projection phases"

      # The copy is AUTHORED by this file, so it must not be dressed as
      # transported agent output.
      refute body =~ "untrustedText(",
             "an authoring bug is not evidence and must not wear the projection sanitizer"

      refute body =~ ~s|"provenance")|,
             """
             .provenance is monospace and is reserved for basis lines about
             transported evidence. The Monitor talking about its own build is
             not evidence, and dressing it as such inverts the very rule this
             wave teaches.
             """
    end

    test "the defect path touches no projection state", %{js: js} do
      body = body_between(js, "function renderMonitorDefect(defect) {", "\n  }")

      for mutation <- ["state.detail =", "state.detailId =", "state.detailConflict =", "state.resolutionFor =", "state.resolutionFailure ="] do
        refute body =~ mutation,
               """
               #{mutation} in the defect view would let an authoring typo change
               what the Monitor believes it holds. renderProjectionFailure does
               exactly this, which is how the same throw could masquerade as a
               run-identity or follow-degradation problem.
               """
      end

      for renderer <- ["renderFollowDegraded", "renderFollowSnapshotUnavailable", "renderFollowRenderFailure", "renderFollowIdentityConflict"] do
        refute body =~ renderer,
               "a Monitor defect must never be painted as a Follow-state assertion"
      end
    end

    test "a defect in a workspace-set refetch is not recorded as a source failure", %{js: js} do
      assert js =~ "if (isMonitorDefect(error)) return renderMonitorDefectSafely(error);\n        const failure = normalizeProjectionFailure(error);",
             """
             The workspace-set detail catch writes {detailError: {kind}} into the
             held snapshot. Recording a Monitor defect there stamps a stale-source
             disclosure ("refresh failure <kind>") onto a snapshot that arrived
             intact, so the operator reads an accusation over evidence nothing is
             wrong with.
             """
    end
  end

  # ── The narrow viewport is promised nothing it does not have ───────────────
  #
  # Below 480px the shipped triage contract CLIPS the runs table's <thead> with
  # the sr-only pattern and re-renders the column names from
  # `content: attr(data-cell-label)` on each td. CSS generated content cannot be
  # a link, cannot carry data-manual-term, and is in neither the accessibility
  # nor the hit-testing tree — so at the 390x844 reference viewport every
  # doctrine column header stopped being a manual entry, while the same screen
  # kept shipping "Dotted labels are axes with a manual entry."
  describe "the affordance survives the narrow-viewport card stack" do
    test "the runs list carries an always-painted front door to its dimensions", %{js: js} do
      body = body_between(js, "function dimensionVocabularyLine(route) {", "\n  }")

      assert body =~ "const columns = doctrineRunsColumns();",
             "the front door names the shipped columns by reading them, not by restating them"

      assert body =~ ~s|labelledTerm("span", name, route, "list-front-door")|,
             "each named dimension must be a real anchor, not prose"

      runs = body_between(js, "function renderRuns() {", "\n  }")

      assert runs =~ "root.append(dimensionVocabularyLine(route));",
             "the front door must be painted on the Runs view itself"

      # NOT width-conditional. A narrow-only surface has to be kept in sync with
      # a media query, which is the exact coupling that let the promise rot.
      refute body =~ "matchMedia",
             "the front door is painted at every width; a width test here would reintroduce the coupling that broke the promise"
    end

    # The seam obligation for this arc is "no parallel copy tables". The front
    # door once restated the seven doctrine column names as its own literal
    # array beside the header row's own literal array: two lists, one truth, and
    # nothing to break when they drift.
    test "the shipped column names exist as exactly one constant", %{js: js} do
      # Built from @runs_columns rather than spelled out, so this test file
      # cannot itself become the parallel copy it forbids: the names the scan
      # searches for and the names the constant must hold are the same list.
      assert js =~
               "const RUNS_COLUMNS = Object.freeze([" <>
                 Enum.map_join(@runs_columns, ", ", &inspect/1) <> "]);",
             "the Runs list column order lives in one frozen constant"

      # RUNS_COLUMNS is the ONLY array LITERAL of column names in app.js. The old
      # parallel copy was the doctrine subset spelled out again inside
      # dimensionVocabularyLine; a bracketed run of two or more of these names is
      # that shape, and it must occur exactly once.
      #
      # WHITESPACE-INSENSITIVE on purpose, and that is a repair rather than a
      # nicety. This scan used to require a literal `", "` between names on a
      # single line, so any array formatted one-name-per-line — the shape a
      # formatter produces the moment the list grows, and the shape a second copy
      # would most naturally take — slid past it untouched. A pin whose failure
      # message says "exactly one is allowed" while the code enforces "exactly
      # one, if you write it on one line" is this arc's own defect class
      # (asserting what is not so) reappearing inside the guard against it.
      column_arrays = Regex.scan(column_array_regex(), js)

      assert length(column_arrays) == 1,
             """
             app.js holds #{length(column_arrays)} array literals of Runs column names:
             #{inspect(column_arrays)}
             Exactly one array literal is allowed — RUNS_COLUMNS. A second is the
             parallel copy table this arc forbids. (This scan sees only bracketed
             arrays; the cellLabel correspondence below covers the per-call form.)
             """

      # The row builder keeps its per-call form for readability, so its twelve
      # cellLabel literals ARE a second spelling of the column names — the one
      # the narrow viewport renders from. Pin the correspondence: the ordered
      # cellLabel literals must equal RUNS_COLUMNS exactly. Proven to bite by
      # mutation (renaming one cellLabel literal left every other guard green
      # before this pin existed; it goes red here now).
      assert cell_label_literals(js) == @runs_columns,
             """
             The row builder's ordered cellLabel literals diverged from RUNS_COLUMNS:
             #{inspect(cell_label_literals(js))}
             Below 480px the reader's column vocabulary is rendered from these
             per-call literals (content: attr(data-cell-label)), so they must be
             the same twelve names in the same order as the constant.
             """

      # And the doctrine subset is nowhere restated in prose either: the
      # docstring used to enumerate the seven names above the function.
      front_door_doc =
        js
        |> String.split("function dimensionVocabularyLine(route) {")
        |> hd()
        |> String.split("/**")
        |> List.last()

      refute front_door_doc =~ "Execution, Liveness, Gate",
             "the docstring must not re-enumerate the column names it stopped restating in code"

      header = body_between(js, "function runTable(rows, total, group, matches, focusKey, route) {", "\n  }")

      assert header =~ "RUNS_COLUMNS.forEach(function (name) {",
             "the header row reads the constant"

      subset = body_between(js, "function doctrineRunsColumns() {", "\n  }")

      assert subset =~ "RUNS_COLUMNS.filter(",
             "the doctrine subset is derived from the same constant"

      assert subset =~ "hasOwnProperty.call(LABELLED_TERMS, name)",
             "and by the SAME predicate the header row uses to decide which <th> is labelled"
    end

    # The pin above is a SOURCE-TEXT SCAN, and a scan that does not bite is worse
    # than no scan: it reports "single source" over a codebase that has two. The
    # earlier version of it did exactly that — it required a literal `", "` on one
    # line, so a complete, byte-identical parallel copy of all twelve names
    # formatted one-per-line left the whole suite green while the failure message
    # said "Exactly one is allowed". That is this arc's own defect class,
    # asserting what is not so, reappearing inside the guard meant to prevent it.
    #
    # So the scan is proven against MUTATIONS of the real shipped source, in the
    # formats a second copy would actually take. Each must be seen as a second
    # array; a mutation that slips through means the pin has rotted back into a
    # claim it cannot keep, and this test is what makes that visible rather than
    # silent.
    test "the parallel-copy scan bites on a copy in any layout", %{js: js} do
      assert length(Regex.scan(column_array_regex(), js)) == 1,
             "the shipped source must be the single-array baseline these mutations are measured against"

      mutations = [
        {"one name per line, the shape a formatter produces",
         "\n  const RUNS_COLUMNS_EXPORT = Object.freeze([\n" <>
           Enum.map_join(@runs_columns, ",\n", fn name -> "    #{inspect(name)}" end) <> "\n  ]);\n"},
        {"a two-name doctrine subset split across lines", "\n  const DOCTRINE = [\"Execution\",\n    \"Liveness\"];\n"},
        {"no space after the comma", "\n  const DOCTRINE = [\"Execution\",\"Liveness\"];\n"},
        {"a trailing comma", "\n  const DOCTRINE = [\"Execution\", \"Liveness\",];\n"}
      ]

      for {shape, copy} <- mutations do
        found = length(Regex.scan(column_array_regex(), js <> copy))

        assert found == 2,
               """
               A parallel copy written as #{shape} was NOT seen by the scan
               (it found #{found} arrays, not 2). The single-source pin would
               report success over a codebase holding two column tables.
               """
      end
    end

    test "every dimension the front door names is in the shipped mapping table", %{js: js} do
      table = labelled_terms_table(js)

      for term <- ["Execution", "Liveness", "Gate", "Advisory", "Source", "Mutation", "Child after end"] do
        assert table =~ ~s|#{inspect(term)}:|,
               "the front door resolves through LABELLED_TERMS, so a drift that breaks the header must break it too"
      end
    end

    # "Each run below is reported on independent axes: ..." is a claim ABOUT
    # ROWS. It shipped above the empty-state branches, so an empty, filtered-
    # empty or searched-empty list still promised axes for runs that were not
    # there — the exact class of false claim this feature exists to prevent.
    test "the dimension front door does not claim axes for runs that are not rendered", %{js: js} do
      runs = body_between(js, "function renderRuns() {", "\n  }")

      assert runs =~ "if (searched.length) root.append(dimensionVocabularyLine(route));",
             """
             the front door renders only when rows render below it. `searched` is
             the exact set the group tables are built from, and it is empty in all
             three empty states (nothing projected, nothing filter-selected,
             nothing matched).
             """

      # The stream line has no such dependency: it describes the always-painted
      # pill, so it stays unconditional.
      assert runs =~ "root.append(streamVocabularyLine(route));"

      # And the three empty branches are still keyed off the same chain, so the
      # single `searched.length` test above genuinely covers all of them.
      assert runs =~ "if (!all.length) root.append(empty("
      assert runs =~ "else if (!filtered.length) root.append(empty("
      assert runs =~ "else if (!searched.length) {"
    end

    test "the clipped header row is revealed the moment focus enters it", %{css: css} do
      assert css =~ ".runs-table thead { position: absolute;",
             "the shipped clip is still in place; this test guards its companion rule, it does not remove it"

      assert css =~ ".runs-table thead:focus-within { position: static;",
             """
             The doctrine headers are ANCHORS, so clipping them alone leaves six
             invisible tab stops per group table: a mobile keyboard operator hits
             six focus stops with no visible focus target. The sr-only pattern's
             mandatory companion rule is a focus reveal, and none was shipped.
             """

      assert css =~ "clip-path: none;",
             "the reveal must undo clip-path, not only the legacy clip property"

      assert css =~ ".runs-table thead:focus-within .labelled-term:focus-visible { outline:",
             "the revealed band must show WHICH stop the operator landed on"
    end

    test "the front-door copy is Monitor voice and tells the truth about the stack", %{js: js, css: css} do
      body = body_between(js, "function dimensionVocabularyLine(route) {", "\n  }")

      assert body =~ "On narrow screens the column headings stack into each card as plain labels",
             "the copy must name the degradation rather than let the orientation sentence overpromise"

      assert css =~ ".dimension-vocabulary {",
             "the front door has its own class (its typographic honesty is pinned with the other Monitor-voice rules above)"
    end
  end
end
