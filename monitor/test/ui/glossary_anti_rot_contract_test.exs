defmodule PixirMonitor.UI.GlossaryAntiRotContractTest do
  use ExUnit.Case, async: true

  @moduledoc """
  DESIGN.md constraint 2, made falsifiable: a user-facing doctrine string in
  app.js with no glossary entry must fail this suite.

  ## Why this file needs a justified denominator before it needs an assertion

  The constraint as written is not directly testable. `app.js` holds well over a
  thousand double-quoted string literals; the corpus holds 56 entries. A literal
  reading of "every user-facing string needs an entry" is red on the first run
  and stays red forever, so it would be deleted within a day and the constraint
  would be worse off than with no test at all. A test that cannot be green on
  the tree it guards is not a constraint, it is a nuisance.

  The denominator this file adopts instead is the AFFORDANCE SURFACE: the set of
  strings the shipped UI has already committed to being doctrine, by marking
  them with the dotted labelled-term affordance or by listing them as a Runs
  column. That set is small, enumerable from the source, and — this is the part
  that makes it defensible rather than merely convenient — it is the set the UI
  makes a PROMISE about. "Dotted labels are axes with a manual entry" ships on
  three screens. Every string inside the affordance surface is one the Monitor
  has told the reader it can define; every string outside it is one the Monitor
  has promised nothing about. Constraint 2 is a claim about promises kept, so
  the promise boundary is the honest denominator, and the strings outside it are
  outside by a rule this file can state rather than by an exception list.

  ## The three clauses, and where each one already lives

  (a) FORWARD, label -> entry. Every slug reachable from a dotted label resolves
      to a glossary entry.

      ALREADY EXECUTED, and not duplicated here. `checkLabelledTerms` in
      test/support/presenter_ui_seam_check.mjs drives `labelledTermSlug` inside
      node:vm over the real frozen seam, proves each of the 16 shipped labels
      resolves to one of 12 corpus slugs, proves the resolver REFUSES an
      unmapped label with a MonitorDefect the shipped render guard will not
      launder, and carries its own dead-link red proof. Source-text pins for the
      same table live in dotted_label_affordance_contract_test.exs.

      This file's only contribution to (a) is a REACHABILITY pin (see
      `the executed clause (a) seam is still wired`): it asserts the seam that
      executes clause (a) is still exported and still asserted on with its
      result-key contract intact, so clause (a) cannot be silently unplugged
      while this file goes on claiming the bidirectional predicate is whole.
      Nothing here re-derives what that seam already proves.

  (b) BACKWARD, entry -> app.js. Every glossary entry whose surface string is a
      LITERAL still appears in app.js, so a shipped rename that orphans an entry
      goes red. This is new, and it is the clause the wave did not have.

  (c) FORWARD GUARD over call sites. A new doctrine-labelled surface added
      without a corpus entry goes red. Also new. See its own section below.

  Plus the DRIFT assertion (generated block == checked-in fixture == handoff
  copy), which is fully owned by glossary_delivery_contract_test.exs and is
  likewise pinned-for-reachability here rather than re-implemented.

  ## Clause (b)'s hard part: what "the surface string appears in app.js" means

  `surface_string` is an AUTHORED description of how a term appears on screen.
  It is not a promise that the bytes occur in the bundle, and for 28 of the 56
  entries they do not. Sorting that out is the whole substance of clause (b),
  because the two obvious predicates are both worthless:

    * `String.contains?(js, surface)` is VACUOUS for short strings. "Live"
      occurs inside "Liveness", "Invalid" inside "Invalidations", and "Ready"
      occurs only inside a code comment. All three would pass while nothing on
      screen said any of them. A predicate that is green for the wrong reason is
      indistinguishable from no predicate.

      The third of those is not a hypothetical the parse alone dispatches, and
      this file learned it the hard way: `"Ready"` inside a JSDoc IS a complete
      double-quoted literal, so parsing without stripping comments admitted it
      and clause (b) passed `checkpoint-ready` on a sentence written ABOUT the
      UI. `string_literals/1` therefore strips comments before it parses, and
      the entry now sits in the class it belongs to. Both halves of that fix are
      load-bearing; either alone leaves the false green standing.

    * Skipping every entry whose surface string is not found leaves the
      denominator defined by whatever happens to fail, which is not a
      denominator at all.

  So the classification is by PROVENANCE, decided per entry, and stated here in
  full. Each entry lands in exactly one of five classes; `classify/2` is the
  executable form of this prose and `every entry classifies, exactly once`
  proves the classes partition the corpus.

    1. :literal (27 entries). The surface string occurs in app.js as a complete
       double-quoted string literal, IN SHIPPED CODE — comments are stripped
       before the parse. This is the class clause (b) asserts on, and the
       assertion is literal-equality against the SET OF PARSED STRING LITERALS,
       never a substring scan over the source text. That is what makes it immune
       to the "Live" inside "Liveness" trap, and the strip is what makes it
       immune to the "Ready" inside a JSDoc one.

    2. :slot_template (15 entries). The surface string carries a placeholder —
       `<state>`, `<basis>`, `<ts>`, `<id>`, `<n>`, `<from>`/`<to>`, `<kind>`,
       `<command>`, a bare `N`, or `1–N` — because the shipped string is built by
       runtime concatenation ("Aggregate arc " + arc.from + " → " + arc.to). No
       literal equality can hold. Clause (b) asserts the template's SEGMENTS
       instead: split on the placeholders, and every remaining literal run must
       occur inside some parsed string literal. `"Declared gate: <state>"` and
       `"Evidence (N)"` are in this class even though their full text does
       appear, because the text that appears is the template's own prefix inside
       a concatenation.

       EVERY segment, not the longest or any: the permissive form was written
       first and rejected, because renaming `" observed edges"` out of the
       aggregate-arc line left the entry green on the strength of its
       `"Aggregate arc"` segment. Exactly two segments across the whole corpus
       cannot be required — a branch-dependent helper result
       (`usageCompletenessLabel`) and a four-character trailing word that occurs
       in 75 route-path literals — and both are named in
       `@unassertable_segments` with their reasons rather than being swallowed by
       a looser rule.

    3. :derived_value_token (4 entries: reconstructed, live-source-mode,
       invalid-advisory, checkpoint-ready). The surface string is a DISPLAY form
       the bundle never spells: `titleCase` renders the projection's raw token,
       and the raw token is what app.js authors. `"Reconstructed"` is nowhere in
       the bundle; `"reconstructed"` is, in the source filter vocabulary.
       `"Ready"` likewise is nowhere in shipped code; `"ready"` is, as the
       GATE_DISPLAY_ALIASES value at app.js:96. Clause (b) asserts the RAW TOKEN,
       derived from the surface string by the same downcase-and-underscore rule
       `titleCase` inverts.

       The token is asserted against the SHIPPED VOCABULARY CONSTANTS each slug
       is pinned to — never against the global literal set — and that scoping is
       load-bearing rather than tidy. Over the global set this class was a
       TAUTOLOGY of the same family the generated-block cut exists to defeat,
       reappearing one layer in: cutting the block removes the corpus's DATA but
       leaves its DELIVERY CODE, and `MANUAL_RUN_READERS` (app.js:1948-1990)
       dispatches each of these four entries by writing that entry's own raw
       token as a call argument — `manualSourceModeReading(scope, "live")`,
       `manualAdvisoryValueReading(scope, "invalid")`. So the corpus's plumbing
       answered for the corpus's entries: renaming `live` and `reconstructed` out
       of the shipped source vocabulary ENTIRELY left clause (b) fully green.
       `invalid-advisory` was worse still, because `"invalid"` is ALSO the
       unrelated route-view sentinel (app.js:1444, :1520), so that entry stayed
       green with the whole advisory vocabulary gone — which is why the pin is
       per-slug rather than one shared cut of the dispatcher. Both holes are now
       held shut by UI-HALF-ONLY red proofs, the one mutation shape the
       `global: true` renames structurally cannot make: rewriting every
       occurrence rewrites the dispatcher too, and goes red for a reason that
       does not distinguish the scoped predicate from the broken one.

       The scoping then had to survive its own second draft. Each slug was
       briefly pinned to a PAIR of constants, UNIONED, and MARKER_TONES was the
       second element of all four — which put the false green straight back, one
       layer over again. MARKER_TONES is a CSS-CLASS ALLOWLIST, not a surface
       vocabulary: `markerTone` (app.js:1178) feeds it into a class name, while
       the visible word is `titleCase` of the raw token, painted whether or not
       the token is in the set. So MARKER_TONES kept all four entries green
       through a total rename of the only site that paints. The pins now name
       painting sites only, and `every pinned vocabulary is a load-bearing
       painting site` proves it entry by entry: cut the token from one pinned
       constant and clause (b) must go red, so a constant that cannot orphan its
       entry cannot be listed as one that vouches for it.

    4. :composite (2 entries: follow, provenance). The surface string is an
       authored SLASH DISJUNCTION — the corpus saying "this term appears as
       either of these" — and the ` / ` is not a character the UI paints. A slash
       is the one separator the shape-based classifier cannot read (punctuation
       in some strings, an operator in these two), so the pair is pinned with the
       fragments each disjunct contributes and clause (b) asserts BOTH.

    5. :server_authored (8 entries). The string is authored in Elixir and
       reaches the browser as projected data — router.ex error copy, cli.ex next
       actions. `"Monitor is stopping (503)"` is a corpus-authored composition of
       router.ex's message and its HTTP status; neither app.js nor any single
       Elixir literal holds those bytes. Clause (b) asserts nothing about these
       entries against app.js, because there is nothing honest to assert: the
       Presenter is not where they are written. They are NOT skipped silently —
       the class is a pinned, exhaustive membership list, so moving an entry into
       it is a visible edit to this file rather than a quiet exemption, AND
       `the exempt class is exactly the pinned list` proves each one's copy really
       is in monitor/lib, so the exemption is earned by the code rather than
       declared here.

  The classes are decided by a PREDICATE over the entry, not by a per-slug
  lookup table, with one exception: :server_authored membership is pinned as an
  explicit list. That asymmetry is deliberate. A predicate for "is this string
  authored in Elixir rather than JavaScript" would have to read the corpus's
  `code_citation` field, whose line pins are known-stale (anchored at 9fcd54c)
  and whose file names are authored prose. Deciding a test's denominator from
  prose that no test validates is how a denominator rots. Eight pinned slugs are
  auditable in one glance; a citation-parsing heuristic is not.

  ## The duplicate surface string

  `"SSE connected · hints only · coalesced"` is the surface string of TWO entries
  (`hints-only` and `coalesced`) — the corpus documents the two vocabulary terms
  of one pill separately. Everything here is keyed by SLUG. A map keyed by
  surface string would silently hold 55 of 56 entries and clause (b) would stop
  covering one of them without any assertion changing.

  ## Clause (c): the forward guard, and its exact boundary

  Clause (a) proves every label in `LABELLED_TERMS` resolves. It cannot see a
  doctrine surface that was never ADDED to `LABELLED_TERMS`, and that is the
  live hole: `runTable` labels a column header with
  `hasOwnProperty.call(LABELLED_TERMS, name)`, so a thirteenth Runs column named
  "Backpressure" ships as a PLAIN header, joins no list, and every existing
  assertion stays green. The reader sees a doctrine axis with no way to look it
  up, on the screen that promises otherwise.

  So clause (c) asserts a TOTALITY over the two enumerable call-site inventories
  the wave already derives:

    * Every name in `RUNS_COLUMNS` is either in `LABELLED_TERMS` (and therefore
      carries the affordance, and therefore has a corpus entry by clause (a)) or
      is in this file's pinned `@ordinary_table_nouns`. A new column is in
      neither and goes red, with a message that names the two ways to fix it.
      This is the guard `@unlabelled_headers` in the sibling file cannot be: that
      list asserts five specific names STAY plain, which is a different claim and
      is silent about a sixth.

    * Every label that reaches an unconditional `labelledTerm(…)` is in
      `LABELLED_TERMS`. Rail cards, Unit-Inspector cards and the two front-door
      sentences label UNCONDITIONALLY, so an unmapped label throws a
      MonitorDefect at render — loud, but only if that surface is rendered by a
      test that drives it. Pinning the inventory statically makes the addition
      red at `mix test` rather than red at whichever browser proof happens to
      paint it.

      Two call shapes ship, and the scan reaches both by union. A generic
      constructor takes the heading as an argument (`truthCard(route,
      "Liveness", …)`, `distributionCard`, `labeledTruthCard`). A DEDICATED
      constructor hard-codes its own heading instead (`postTerminalCard` writes
      `labelledTerm("h3", "Child activity after end", route)`), so it is reached
      by scanning `labelledTerm` call sites directly. Scanning only the first
      shape was a live hole: it left `Child activity after end` — a shipped,
      rail-appended card — outside the inventory, and any new card written in
      that shape unguarded.

      BOTH halves are total over their own call sites, and that is a stronger
      claim than a union of two partial scans. The constructor half once matched
      only `truthCard(route, …)` — the literal token `route` as first argument —
      while the affordance half deliberately contributed NOTHING for a parameter,
      on the grounds that "its values are read at the route-first call sites".
      Each half assumed the other covered an aliased call site, and neither did:
      `truthCard(r, "Backpressure", …)` was seen by neither and shipped an
      unmapped h3 with clause (c) green. So the constructor half now matches the
      constructor NAME and resolves whatever sits in the heading position.

      The affordance half covers EVERY TAG, not only `"h3"`. Anchoring it to h3
      was the same accident one seam over: the bundle paints the same dotted
      affordance from `labelledTerm("span", …)` on the live-activity and
      Runs-list front doors (app.js:3452, :3455, :3502) — unconditionally, into
      the same manual, throwing the same `labelled_term_unmapped` defect. An
      h3-only regex put those three sites, and any new front-door term written
      beside them, outside the very denominator this file declares. The one
      CONDITIONAL site — the Runs `<th>`, painted through a
      `hasOwnProperty.call(LABELLED_TERMS, name) ?` ternary — is excluded because
      it cannot paint an unmapped label at all, and the RUNS_COLUMNS totality
      above covers that surface better anyway.

      Every argument is classified, and one that resolves to none of the known
      shapes FLUNKS: a literal; a call expression, captured whole so it reaches
      the flunk instead of slipping past the scan; a local bound to a literal in
      the same function body; the iteration variable of a `forEach` over a
      producer this file can read (authored literals, or a `LABELLED_TERMS`
      membership filter that cannot yield an unmapped label); or a parameter of
      a PINNED generic card constructor, whose call sites the constructor half
      reads totally — a parameter of any other function flunks. An unreadable
      label is red, never skipped. Non-enumeration is red by arithmetic for
      any call the strip still sees as a `labelledTerm(` or pinned-constructor
      `(` token: the reconciliation test counts those occurrences against the
      enumerated sites, so an ARGUMENT shape the scan cannot capture fails by
      counting rather than passing by invisibility. A call the token count
      itself cannot see — `labelledTerm .call/.apply`, an identifier alias
      (`const paint = labelledTerm`), a space before the paren — is OUTSIDE
      that guarantee and is listed under what this test does not catch.

  ### What clause (c) does NOT catch, stated plainly

  Clause (c) is a totality over ENUMERABLE inventories. It is red for a new Runs
  column and for a new rail card, because both are added by editing a frozen
  array or by calling a card constructor whose call sites this file scans. It is
  NOT red for a doctrine string introduced somewhere the inventories do not
  reach — a new `text("h2", "Backpressure")` in a panel that is neither a Runs
  column nor a rail card. Nothing short of a human judgment about which of the
  bundle's thousand-plus literals is "doctrine" could catch that, and encoding
  that judgment as a regex is how the permanently-red test gets written.

  What this file guarantees is narrower and true: a doctrine string cannot enter
  the AFFORDANCE SURFACE — the surface that carries the dotted-underline promise
  — without a corpus entry, PROVIDED it enters through the shapes this file
  scans. Two entry paths are admitted as uncovered: (a) forging the affordance
  without the helper — `text("a", "Backpressure", "labelled-term")` plus a
  hand-built href wears the dotted underline with no `labelledTerm(` call for
  any scan or count to see; and (b) invoking the helper in a form the token
  count cannot recognize — `.call`/`.apply`, an identifier alias, a space
  before the paren. Both are deliberate-evasion shapes rather than the drift
  this test exists to catch; a reviewer, not a regex, is the guard for
  deliberate evasion. A doctrine string that never claims the affordance at
  all is outside the promise, and outside this test.

  Within the affordance surface, the residue is bounded and NAMED rather than
  silent. The affordance scan resolves a label that is a literal, a local bound
  to a literal, an iteration variable over a readable producer, or a generic
  constructor's parameter; any other shape — a label computed at runtime, read
  from projected data, or assembled by concatenation — cannot be resolved to a
  string this file can check against `LABELLED_TERMS`, so the scan FLUNKS on it.
  That is the deliberate trade: such a surface is red until someone either writes
  its label in a readable shape or teaches `card_headings/1` the new one. It is
  never green-because-invisible.

  ## What this test does NOT catch, in full

  Beyond clause (c)'s boundary above:

    * SEMANTIC rot. Clause (b) proves the bytes of a surface string still occur
      in app.js. It cannot prove they still occur on the SCREEN the corpus entry
      describes, nor that the `plain_definition` is still true of what the code
      does. A string moved from a rail card into a dead branch stays green here.

    * DEFINITION QUALITY. Nothing here reads `plain_definition`,
      `confused_with`, or `concern`. An entry whose definition is wrong is
      indistinguishable from one whose definition is right.

    * `code_citation` line pins. Known-stale by design (anchored at 9fcd54c) and
      deliberately unasserted; only function-name anchors are durable. This file
      never parses them, which is also why :server_authored is a pinned list.

    * ORPHANED ENTRIES OUTSIDE THE LITERAL CLASSES. An entry that is
      :server_authored is asserted against nothing. If router.ex drops its
      "Monitor is stopping" copy tomorrow, the corpus entry rots and this file is
      green. That is the price of not asserting a Presenter test against Elixir
      copy, and it is named here rather than hidden.

    * RUNTIME REACHABILITY. This is a source-text tier. It does not execute the
      bundle; it reads app.js as text and parses its string literals. A literal
      present in dead code satisfies clause (b).

  ## Every clause is proven to bite

  A green anti-rot test is worth exactly as much as its red proofs. Each clause
  below has a test that mutates a COPY of the real bundle (never the tree) in
  the shape the clause exists to catch, and asserts the predicate goes red on the
  mutant while staying green on the real source. The mutations are the realistic
  rot: a shipped rename that orphans an entry, a new unglossed column, a new
  unglossed rail card, a LABELLED_TERMS entry pointing at a slug the corpus does
  not carry.
  """

  @app_js Path.expand("../../priv/static/app.js", __DIR__)
  @terms_json Path.expand("../fixtures/glossary_terms.json", __DIR__)
  @seam_check Path.expand("../support/presenter_ui_seam_check.mjs", __DIR__)
  @seam_test Path.expand("../presenter_ui_seam_test.exs", __DIR__)
  @delivery_test Path.expand("glossary_delivery_contract_test.exs", __DIR__)

  @begin_marker "  // GENERATED BEGIN pixir-monitor-glossary -- gen_terms.py; do not hand-edit."
  @end_marker "  // GENERATED END pixir-monitor-glossary"

  # The eight entries whose surface string is authored in Elixir and reaches the
  # browser as projected data. Pinned rather than predicated: see the moduledoc's
  # note on why a citation-parsing heuristic would be the rot, not the guard.
  #
  # Exhaustive by construction — `every entry classifies, exactly once` fails if
  # a slug here is not in the corpus, and clause (b) fails if an entry that
  # belongs here is left out. `the exempt class is exactly the pinned list` goes
  # further and proves each one's copy really is in monitor/lib, so membership is
  # earned by the code rather than declared here.
  #
  # `run-not-found` is in this class even though its citation also names app.js.
  # The citation's app.js half points at `identityLossFailure`, which BRANCHES on
  # `failure.kind === "run_not_found"` — the Presenter reads the kind, it does not
  # author the copy. The surface string `"run_not_found (404)"` is the corpus's
  # own composition of router.ex's error kind with the HTTP status it is sent
  # under, and those bytes are contiguous in neither tree. Classifying it by where
  # the STRING is authored rather than by where it is mentioned is the same rule
  # the other six follow.
  #
  # `next-actions` (`next: <command>`) is cli.ex:526's printer. It reached this
  # list the hard way: it was first left in :slot_template with its only segment
  # exempted, and `the unassertable-segment list is earned` refused that — an
  # entry covered by nothing must not sit in a class that claims coverage. The
  # refusal was correct and the entry moved here, where the earned-exemption test
  # confirms cli.ex really does author it.
  @server_authored ~w(
    unscoped-route-unavailable
    workspace-unavailable
    workspace-not-found
    authentication-required
    invalid-launch
    shutting-down
    run-not-found
    next-actions
  )

  # Entries whose on-screen form is produced by `titleCase` from the
  # projection's raw token, so the bundle authors the TOKEN and never the
  # display form. The expected token is derived, not listed: downcase and
  # underscore, the inverse of `titleCase`'s `replaceAll("_", " ")`.
  #
  # `checkpoint-ready` reached this list by correction rather than by design, and
  # the correction is worth recording because it is the exact defect this file
  # guards against, committed inside the guard. It sat in :literal and clause (b)
  # passed it — on the strength of the word `"Ready"` inside the JSDoc above
  # `manualGateValue`, the ONLY occurrence outside the generated block. The UI
  # never authors that display form: it is `titleCase` of the
  # GATE_DISPLAY_ALIASES value `"ready"` (app.js:96), which is a real shipped
  # literal. So the entry was green for a reason unrelated to the UI, and
  # renaming the alias to anything else would have orphaned it in total silence —
  # precisely the shipped-rename rot clause (b) exists to catch, undetected by
  # clause (b). Stripping comments in string_literals/1 turned that false green
  # red, and the class here is where the entry always belonged.
  #
  # Each slug is pinned to the SHIPPED VOCABULARY CONSTANTS that may satisfy it,
  # rather than to the global literal set, and that scoping is the whole strength
  # of this class. Against the global set the clause was a TAUTOLOGY of exactly
  # the kind `outside_generated_block/1` exists to defeat, reappearing one layer
  # in: the corpus's own DISPATCH TABLE (`MANUAL_RUN_READERS`, app.js:1948-1990)
  # authors these very tokens as its own call arguments —
  # `manualSourceModeReading(scope, "live")`, `manualAdvisoryValueReading(scope,
  # "invalid")`. Cutting the generated block removes the corpus's DATA but leaves
  # its DELIVERY CODE, so every one of these four entries proved its own token
  # shipped by quoting itself. Renaming `"live"` and `"reconstructed"` out of
  # FILTER_VOCABULARIES.source — the vocabulary the filter dropdown paints its
  # options from, leaving the dispatcher alone — left clause (b) fully green.
  #
  # `invalid-advisory` was the worst case and is why the fix is per-slug rather
  # than one shared cut. `"invalid"` is ALSO the unrelated route-view token
  # (app.js:1444, :1520), so scoping it to the advisory vocabularies is what
  # separates "the advisory bucket still ships" from "some other subsystem
  # happens to use the same five bytes". A dispatcher-only cut would leave that
  # entry green with the entire advisory vocabulary deleted.
  #
  # Each slug is pinned to the constants that PUT THE WORD ON SCREEN, and only
  # those. That distinction is the last shape of this defect, and it took three
  # attempts to get right.
  #
  # The first spelling matched the global literal set and the corpus's own
  # dispatcher answered for the corpus. The second scoped each slug to a PAIR of
  # constants, unioned, on the stated grounds that "the token genuinely ships in
  # two independent places, so a one-site rename must NOT go red". The second
  # element of all four pairs was MARKER_TONES — and that reasoning was FALSE for
  # every one of them, so the same false green came back one layer over.
  #
  # MARKER_TONES is not a surface vocabulary. It is a CSS-CLASS ALLOWLIST with
  # exactly one consumer in the bundle: `markerTone(value)` (app.js:1178), whose
  # result is concatenated into a class name — `text("span", label, "marker
  # marker-" + markerTone(tone))` (app.js:1183). The word the reader sees is the
  # separate `label` argument, `titleCase` of the raw token (app.js:1180),
  # painted identically whether or not the token is in the set; a token missing
  # from MARKER_TONES loses its TINT and keeps its TEXT. So membership is not
  # evidence the word ships and removal is not evidence it stopped, and because
  # the pins were UNIONED, MARKER_TONES alone kept all four entries green through
  # a total rename of the genuinely-painting site: renaming
  # FILTER_VOCABULARIES.source, or GATE_DISPLAY_ALIASES's `"ready"`, or
  # ADVISORY_BUCKET_ORDER's `"invalid"`, each left `clause_b_orphans/3` == [].
  # That is exactly "some other subsystem happens to use the same five bytes"
  # keeping an entry green, which this class exists to refuse.
  #
  # So each slug now names the site the UI paints FROM, one apiece:
  #
  #   * `live`/`reconstructed` — `FILTER_VOCABULARIES.source`, rendered as the
  #     filter dropdown's options through `titleCase(value)` (app.js:3164);
  #   * `invalid` — `ADVISORY_BUCKET_ORDER`, rendered as a distribution bucket
  #     phrase through `distributionValueLabel` (app.js:1172, :1769);
  #   * `ready` — the `GATE_DISPLAY_ALIASES` value, the alias the same bucket
  #     renderer prefers over `titleCase` (app.js:96, :1172).
  #
  # One constant per slug is not a weakening. A pin is only worth listing if
  # deleting the token from it can orphan the entry, and `every pinned
  # vocabulary is a load-bearing painting site` asserts precisely that for every
  # pin here: cut the token from ONE pinned constant and clause (b) must go red.
  # A second constant that cannot fail that test is not a second painting site;
  # it is a silencer, which is what MARKER_TONES was.
  @derived_value_tokens %{
    "reconstructed" => ["FILTER_VOCABULARIES.source"],
    "live-source-mode" => ["FILTER_VOCABULARIES.source"],
    "invalid-advisory" => ~w(ADVISORY_BUCKET_ORDER),
    "checkpoint-ready" => ~w(GATE_DISPLAY_ALIASES)
  }

  # The two authored SLASH DISJUNCTIONS. In both, the ` / ` is the corpus author
  # writing "this term appears as either of these", not a character the UI paints.
  # A slash is the one separator the shape-based classifier cannot read, because
  # it is punctuation in some strings and an operator in these two, so the pair is
  # pinned with the fragments each disjunct contributes.
  #
  # `follow` names two whole literals, one per follow state (followToggle
  # branches on `route.follow`). `provenance` names two TEMPLATE prefixes — the
  # generic basis line and the mutation panel's more specific one — so its
  # fragments are the literal runs, not whole strings. Both must be found: a
  # disjunction is a claim about both disjuncts, and asserting only the first
  # would let half of it rot.
  @composite %{
    "follow" => ["Follow this run", "Following this run"],
    "provenance" => ["Basis: ", "Evidence basis: "]
  }

  # Runs columns that name no doctrine term. Clause (c) requires every
  # RUNS_COLUMNS name to be in LABELLED_TERMS or in this list, so a NEW column
  # must be classified by a human edit here or given a corpus entry. This is a
  # totality guard, unlike the sibling file's @unlabelled_headers, which asserts
  # these five specific names stay plain and says nothing about a sixth.
  @ordinary_table_nouns ~w(Run Strategy Units Duration Latest)

  # Placeholder shapes that mark a surface string as a runtime-built template.
  # `N` is matched only as a standalone token so it cannot fire inside a word.
  @slot_pattern ~r/<[a-z]+>|(?<![A-Za-z0-9])N(?![A-Za-z0-9])|1–N/u

  setup_all do
    js = File.read!(@app_js)
    terms = Jason.decode!(File.read!(@terms_json))
    {:ok, js: js, terms: terms, outside: outside_generated_block(js), literals: string_literals(js)}
  end

  # ── Source parsing ─────────────────────────────────────────────────────────

  @doc false
  # app.js MINUS the generated glossary block.
  #
  # Non-negotiable for clause (b): the corpus ships INLINE inside app.js, so
  # every surface string trivially occurs in the file as part of its own entry.
  # Scanning the whole bundle would make clause (b) a tautology — 56 of 56 green,
  # forever, including for an entry whose UI string was deleted this morning.
  # Cutting the block is what turns the scan into evidence about the SHIPPED UI
  # rather than about the corpus quoting itself.
  def outside_generated_block(js) do
    lines = String.split(js, "\n")

    with begin_index when is_integer(begin_index) <- Enum.find_index(lines, &(&1 == @begin_marker)),
         end_index when is_integer(end_index) <- Enum.find_index(lines, &(&1 == @end_marker)),
         true <- begin_index < end_index do
      {:ok, Enum.join(Enum.slice(lines, 0, begin_index) ++ Enum.slice(lines, (end_index + 1)..-1//1), "\n")}
    else
      _ -> {:error, :no_generated_glossary}
    end
  end

  @doc false
  # The generated glossary block of app.js, markers included.
  #
  # Sliced directly by marker index, never by subtracting `outside` from the
  # bundle: `outside_generated_block/1` joins two DISJOINT line slices, so the
  # string it returns never occurs as a contiguous substring of app.js and
  # `String.replace(js, outside, "")` is a silent no-op that hands back the whole
  # file. That failure is invisible while no `"surface_string": ...` byte pattern
  # exists in the UI half — and stops being invisible the day one does, which is
  # exactly the swapped-corpus case the caller claims to defend against.
  def generated_block(js) do
    lines = String.split(js, "\n")

    with begin_index when is_integer(begin_index) <- Enum.find_index(lines, &(&1 == @begin_marker)),
         end_index when is_integer(end_index) <- Enum.find_index(lines, &(&1 == @end_marker)),
         true <- begin_index < end_index do
      {:ok, lines |> Enum.slice(begin_index..end_index//1) |> Enum.join("\n")}
    else
      _ -> {:error, :no_generated_glossary}
    end
  end

  @doc false
  # Every complete double-quoted string literal in app.js, outside the generated
  # block, as a MapSet of their decoded contents.
  #
  # A SET of parsed literals, not the source text, is what clause (b) matches
  # against. The difference is the whole defensibility of the clause: over raw
  # source, `String.contains?(js, "Live")` is true because "Liveness" exists,
  # `"Invalid"` is true because "Invalidations" exists, and `"Ready"` is true
  # because a comment mentions it. Every one of those would report a shipped
  # doctrine string that is not on screen anywhere.
  #
  # Escapes are consumed as a unit so a `\"` inside a literal cannot terminate
  # it, and the literal's own escape sequences are decoded so the comparison is
  # against the string the browser builds, not against its source spelling.
  #
  # COMMENTS ARE STRIPPED FIRST, and that is not a refinement — it is the third
  # trap in the same family as the two above, and the only one the parse alone
  # does not close. A quoted run inside `//` or JSDoc is a complete double-quoted
  # literal by the regex's reckoning while being a string the bundle never
  # builds: it is prose ABOUT the UI, not the UI. `"Ready"` is the live case the
  # moduledoc names — it occurs outside the generated block exactly once, in the
  # JSDoc above `manualGateValue`, and nowhere as shipped code. 58 of the 1186
  # runs the unstripped parse collects exist only inside comments. Admitting them
  # makes clause (b) satisfiable by a sentence someone wrote about a rename
  # instead of by the rename, which is the failure mode the whole file is built
  # against.
  def string_literals(js) do
    case outside_generated_block(js) do
      {:ok, outside} ->
        ~r/"((?:[^"\\\n]|\\.)*)"/
        |> Regex.scan(strip_comments(outside), capture: :all_but_first)
        |> Enum.map(fn [literal] -> decode_escapes(literal) end)
        |> MapSet.new()

      {:error, _} = error ->
        error
    end
  end

  @doc false
  # app.js with whole-line comments removed: `//` lines and the interior of
  # JSDoc/block comments, which this bundle writes one-per-line (` * ...`).
  #
  # Line-oriented on purpose. A real JS tokenizer is the only thing that could
  # strip a trailing `// note` after code, or a `/* */` opened mid-line, and this
  # tier has no business carrying one — it would be a second parser to keep in
  # step with the first. What the line-oriented form gives up is a literal that
  # shares a line with code, which stays IN the set: that direction is safe,
  # because it can only leave clause (b) as strict as it was before the strip.
  # What it removes is the entire class the traps live in — the standalone
  # comment paragraph, which is how every prose block in this bundle is written.
  #
  # Run AFTER the generated block is cut, never before: the two markers are
  # themselves `//` lines, so stripping first would delete the boundaries
  # `outside_generated_block/1` slices on.
  def strip_comments(source) do
    source
    |> String.split("\n")
    |> strip_comments_lines()
    |> Enum.join("\n")
  end

  # The ONE comment-line predicate, shared by the whole-source and the
  # line-list paths so the rule cannot fork: two copies of "what counts as a
  # comment" is two chances for one of them to rot.
  defp strip_comments_lines(lines) do
    Enum.reject(lines, fn line ->
      trimmed = String.trim(line)

      String.starts_with?(trimmed, "//") or String.starts_with?(trimmed, "*") or
        String.starts_with?(trimmed, "/*")
    end)
  end

  defp decode_escapes(literal) do
    literal
    |> String.replace("\\\"", "\"")
    |> String.replace("\\n", "\n")
    |> String.replace("\\t", "\t")
    |> String.replace("\\\\", "\\")
  end

  # ── The classification, executable ─────────────────────────────────────────

  @doc false
  # The class of one corpus entry, per the moduledoc's five-way split.
  #
  # Order matters and encodes the moduledoc's precedence: the pinned
  # :server_authored list first (it is the one class decided by membership
  # rather than by shape), then the other two pinned classes, then shape.
  def classify(entry, _literals) do
    slug = entry["slug"]
    surface = entry["surface_string"]

    cond do
      slug in @server_authored -> :server_authored
      Map.has_key?(@derived_value_tokens, slug) -> :derived_value_token
      Map.has_key?(@composite, slug) -> :composite
      Regex.match?(@slot_pattern, surface) -> :slot_template
      true -> :literal
    end
  end

  # Template segments that are NOT asserted, each with the reason the bundle
  # cannot hold them contiguously. Keyed by slug so one weak segment cannot
  # silence another entry's.
  #
  # This is the file's only per-entry exception list, and it is three lines long
  # by design. The alternative — accepting a template as shipped when ANY of its
  # segments is found — was tried and rejected: with it, renaming
  # `" observed edges"` out of the aggregate-arc line left the entry green
  # because the `"Aggregate arc"` segment still matched. A clause that survives
  # the rename it exists to catch is not a clause. Requiring EVERY segment and
  # naming the three that cannot be required is the honest shape.
  @unassertable_segments %{
    # `"Evidence-derived usage · " + calls + " calls · " + usageCompletenessLabel(usage)`.
    # `Evidence complete` is the true branch of a helper, so the corpus's
    # connected-and-complete rendering is never contiguous in the source.
    "evidence-derived-usage" => ["calls · Evidence complete"],
    # `"Read-only · authoritative snapshots · " + all.length + " runs"`. The
    # trailing `runs` is a four-character run that occurs in 75 shipped literals,
    # nearly all of them route paths. Asserting it would be vacuous, not strict.
    "authoritative" => ["runs"]
    # `authoritative`'s trailing `runs` above is the last entry here. `next:` was
    # briefly a third: the only app.js literals containing it are the focus keys
    # `members-next:` and `edges-next:`, which are unrelated to the CLI's
    # next-action copy, so matching it would have been a FALSE GREEN. But
    # exempting it left `next-actions` with NO assertable segment at all, and
    # `the unassertable-segment list is earned` refused that — an entry clause (b)
    # covers with nothing must not sit in a class that claims coverage. So
    # `next-actions` moved to @server_authored, where cli.ex authors it, and the
    # exemption disappeared rather than being kept as a silencer. That refusal
    # firing during authorship is the guard doing its job.
  }

  @doc false
  # The literal segments of a slot template: the anchors clause (b) asserts on.
  #
  # Splitting on the placeholder pattern yields the template's literal runs, and
  # EVERY one of them must occur inside some shipped literal. Requiring all of
  # them rather than the longest is what keeps the clause a real rename detector:
  # a template's segments are exactly the parts of it the bundle authors, so any
  # rename drops one.
  #
  # Segments shorter than four characters are dropped as inherently vacuous (a
  # bare "·" or ":" occurs in hundreds of literals), and the three segments the
  # bundle provably cannot hold contiguously are named in
  # @unassertable_segments with their reasons rather than being swallowed by a
  # permissive rule.
  def template_segments(surface, slug) do
    exempt = Map.get(@unassertable_segments, slug, [])

    @slot_pattern
    |> Regex.split(surface)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(String.length(&1) < 4 or &1 in exempt))
    |> Enum.sort_by(&(-String.length(&1)))
  end

  @doc false
  # The raw projection token a :derived_value_token entry's display form comes
  # from: the inverse of `titleCase`, which is `replaceAll("_", " ")`.
  def raw_token(surface), do: surface |> String.downcase() |> String.replace(" ", "_")

  @doc false
  # The string literals inside ONE named shipped vocabulary constant's
  # declaration — `const NAME = ...;` up to the line that closes it — as a
  # MapSet, or `{:error, {:no_such_vocabulary, name}}` when the constant is gone.
  #
  # This is the scoped denominator the :derived_value_token class asserts
  # against, and the scope is the point. The global literal set contains the
  # corpus's own DELIVERY CODE: `MANUAL_RUN_READERS` dispatches each of these
  # four entries by writing its raw token as a call argument, so over the global
  # set every one of them proved itself. Reading the vocabulary the UI actually
  # paints FROM makes the assertion about shipped UI vocabulary rather than about
  # the glossary machinery that describes it.
  #
  # Line-oriented and comment-stripping like `string_literals/1`, and for the
  # same reason: this bundle writes prose INSIDE declarations (MARKER_TONES
  # carries a paragraph mid-declaration at app.js:46-48; ADVISORY_BUCKET_ORDER's
  # contract note runs right up to its `const`), and a quoted token inside such a
  # paragraph is a sentence about the vocabulary rather than a member of it.
  # Admitting one would let a comment vouch for a shipped word, which is the same
  # trap `string_literals/1` closes for the bundle at large.
  #
  # A MISSING constant is an error rather than an empty set. Empty would make
  # every entry scoped to it go red with a message about a rename, when the real
  # event is that this file's pin has gone stale against a refactor — a different
  # fix, and one the reader must not be sent looking for in the wrong place.
  def vocabulary_literals(js, name) do
    # A pin may name a SUB-KEY (`FILTER_VOCABULARIES.source`), and the sub-key
    # is load-bearing: FILTER_VOCABULARIES is a five-key object, so a pin scoped
    # to the whole declaration would let all 21 literals across all five
    # dimensions vouch for the two tokens the moduledoc scopes to `source` —
    # deleting the `source:` key and relocating its bytes to a sibling key kept
    # clause (b) green while the filter dropdown could no longer paint the word.
    # Slicing the named key makes the assertion mean what the pin says.
    {constant, key} =
      case String.split(name, ".", parts: 2) do
        [constant] -> {constant, nil}
        [constant, key] -> {constant, key}
      end

    lines = js |> strip_comments() |> String.split("\n")

    case Enum.find_index(lines, &String.starts_with?(String.trim(&1), "const #{constant} =")) do
      nil ->
        {:error, {:no_such_vocabulary, name}}

      start ->
        rest = Enum.drop(lines, start)
        # The declaration ends at the first line closing it. Single-line
        # constants close on their own line, so the scan starts where it begins.
        length = Enum.find_index(rest, &Regex.match?(~r/\)\s*;\s*$/, &1))

        body =
          case length do
            nil -> hd(rest)
            n -> rest |> Enum.take(n + 1) |> Enum.join("\n")
          end

        scoped =
          case key do
            nil ->
              {:ok, body}

            key ->
              # The bundle writes each key's array on its own line; the scan is
              # that one bracket run. A missing key is its own error, distinct
              # from a missing constant: the pin has gone stale against a
              # restructure, and the reader must be sent to the right fix.
              case Regex.run(~r/#{Regex.escape(key)}:\s*\[[^\]]*\]/, body, capture: :first) do
                nil -> {:error, {:no_such_vocabulary_key, name}}
                [run] -> {:ok, run}
                run when is_binary(run) -> {:ok, run}
              end
          end

        with {:ok, scoped_body} <- scoped do
          literals =
            ~r/"((?:[^"\\\n]|\\.)*)"/
            |> Regex.scan(scoped_body, capture: :all_but_first)
            |> Enum.map(fn [literal] -> decode_escapes(literal) end)
            |> MapSet.new()

          {:ok, literals}
        end
    end
  end

  @doc false
  # Every token painted by the vocabularies one :derived_value_token slug is
  # pinned to, unioned.
  #
  # The union still exists because a term genuinely CAN ship from two places, but
  # every member of it must be a place that paints: see @derived_value_tokens on
  # why MARKER_TONES was removed from all four pins, and `every pinned vocabulary
  # is a load-bearing painting site` for the assertion that keeps a non-painting
  # constant from being added back.
  def derived_token_vocabulary(js, slug) do
    @derived_value_tokens
    |> Map.fetch!(slug)
    |> Enum.reduce({:ok, MapSet.new()}, fn
      _name, {:error, _} = error ->
        error

      name, {:ok, acc} ->
        case vocabulary_literals(js, name) do
          {:ok, literals} -> {:ok, MapSet.union(acc, literals)}
          {:error, _} = error -> error
        end
    end)
  end

  @doc false
  # Clause (b), as a function over (corpus, parsed literals), so the red proofs
  # can run the very same predicate over a mutated copy of the bundle. A clause
  # that is only ever spelled inline in a passing test is a clause that has never
  # been watched to fail.
  #
  # Returns the list of entries that FAIL the clause, each with its class and the
  # exact fragment that was not found, so a failure message can name the fix.
  #
  # Takes the parsed literal set AND the source it came from, because the classes
  # do not share one denominator. Three of them match against the whole shipped
  # literal set; :derived_value_token matches against the specific vocabulary
  # constants its slug is pinned to, read back out of `js`. That narrowing is
  # what stops the corpus's own dispatch table from satisfying the clause on the
  # corpus's behalf — see @derived_value_tokens for the false green it closes.
  def clause_b_orphans(terms, literals, js) do
    Enum.flat_map(terms, fn entry ->
      slug = entry["slug"]
      surface = entry["surface_string"]

      missing =
        case classify(entry, literals) do
          :server_authored ->
            []

          :literal ->
            if MapSet.member?(literals, surface), do: [], else: [surface]

          :slot_template ->
            # EVERY segment, not any: see template_segments/2 on why the
            # permissive form survived the very rename it existed to catch.
            surface
            |> template_segments(slug)
            |> Enum.reject(fn segment -> Enum.any?(literals, &String.contains?(&1, segment)) end)

          :derived_value_token ->
            # Scoped to the pinned SHIPPED VOCABULARY, never the global literal
            # set: `MANUAL_RUN_READERS` authors every one of these tokens as its
            # own dispatch argument, so the global set lets the corpus's delivery
            # code vouch for the corpus's data.
            token = raw_token(surface)

            case derived_token_vocabulary(js, slug) do
              {:ok, vocabulary} ->
                if MapSet.member?(vocabulary, token), do: [], else: [token]

              {:error, {:no_such_vocabulary, name}} ->
                ["#{token} (vocabulary constant #{name} is gone from app.js; re-pin @derived_value_tokens)"]
            end

          :composite ->
            # Containment, not equality: `follow`'s disjuncts are whole literals
            # while `provenance`'s are template prefixes inside longer ones
            # (`"Basis: " + titleCase(basis)`). Containment covers both, and every
            # pinned fragment is long enough that a collision is not plausible.
            Enum.reject(@composite[slug], fn fragment ->
              Enum.any?(literals, &String.contains?(&1, fragment))
            end)
        end

      case missing do
        [] -> []
        fragments -> [{slug, classify(entry, literals), fragments}]
      end
    end)
  end

  # ── The classification is total and honest ─────────────────────────────────

  test "every entry classifies, exactly once, and the pinned classes are all real slugs", %{
    terms: terms,
    literals: literals
  } do
    slugs = MapSet.new(terms, & &1["slug"])

    # A pinned class naming a slug the corpus does not carry is a stale
    # exemption: it would keep exempting nothing while its entry rotted in some
    # other class.
    for pinned <- @server_authored ++ Map.keys(@derived_value_tokens) ++ Map.keys(@composite) do
      assert MapSet.member?(slugs, pinned),
             "#{inspect(pinned)} is pinned into a classification class but the corpus does not carry that slug"
    end

    counts = terms |> Enum.map(&classify(&1, literals)) |> Enum.frequencies()

    # The shape of the corpus at this wave, pinned so a class cannot silently
    # absorb entries. These are not magic numbers: they are the moduledoc's
    # table, and a corpus change must update BOTH or go red.
    assert counts == %{
             literal: 27,
             slot_template: 15,
             derived_value_token: 4,
             composite: 2,
             server_authored: 8
           }

    assert Enum.sum(Map.values(counts)) == length(terms)
    assert length(terms) == 56
  end

  test "the exempt class is exactly the pinned list, and it is the only unasserted class", %{
    terms: terms,
    literals: literals
  } do
    exempt = for entry <- terms, classify(entry, literals) == :server_authored, do: entry["slug"]

    assert Enum.sort(exempt) == Enum.sort(@server_authored),
           """
           The set of entries clause (b) asserts NOTHING about must stay exactly
           the pinned list. Growing it silently is how a denominator rots into
           "whatever currently fails".
           """

    # And every one of them really is authored outside the Presenter. Asserted
    # against the Elixir tree so the exemption is EARNED rather than declared: an
    # entry moved into this class to silence a failure, whose copy is not in
    # lib/, goes red here.
    lib = Path.expand("../../lib", __DIR__)

    elixir_source =
      lib
      |> Path.join("**/*.ex")
      |> Path.wildcard()
      |> Enum.map_join("\n", &File.read!/1)

    for entry <- terms, entry["slug"] in @server_authored do
      # The corpus composes the message with its HTTP status ("... (503)"); the
      # Elixir side authors the message alone, so the status suffix is stripped.
      # `next-actions` is additionally a template (`next: <command>`), so it is
      # reduced to its literal segments the same way clause (b) reduces a
      # template on the app.js side — the exemption is checked against the same
      # notion of "the part the code actually authors".
      fragments =
        entry["surface_string"]
        |> String.replace(~r/\s*\(\d{3}\)\z/, "")
        |> then(fn message ->
          if Regex.match?(@slot_pattern, message) do
            @slot_pattern
            |> Regex.split(message)
            |> Enum.map(&String.trim/1)
            |> Enum.reject(&(&1 == ""))
          else
            [message]
          end
        end)

      for fragment <- fragments do
        assert String.contains?(elixir_source, fragment),
               """
               #{inspect(entry["slug"])} is exempted from clause (b) on the grounds
               that its copy is authored in Elixir, but #{inspect(fragment)} is not
               in monitor/lib. The exemption must be earned by the code, not
               declared by this list.
               """
      end
    end
  end

  test "the unassertable-segment list is earned, not a silencer", %{terms: terms, literals: literals} do
    # @unassertable_segments is the one place clause (b) is told to look away, so
    # it is the one place a future failure could be silenced instead of fixed.
    # Three properties keep it honest.
    by_slug = Map.new(terms, &{&1["slug"], &1})

    for {slug, segments} <- @unassertable_segments do
      entry = Map.get(by_slug, slug)

      # 1. It names a real entry, and one that is actually a template. Exempting
      #    a segment of an entry in another class would exempt nothing while
      #    reading as though it did.
      assert entry, "#{inspect(slug)} is exempted but the corpus does not carry that slug"

      assert classify(entry, literals) == :slot_template,
             "#{inspect(slug)} is exempted from segment assertion but is not a :slot_template"

      # 2. Each exempted segment is really a segment of that entry's surface
      #    string. A typo here would silently exempt nothing and the entry would
      #    keep asserting a segment nobody meant to require — or, worse, the
      #    reader would believe a segment was excused when it was not.
      raw_segments =
        @slot_pattern
        |> Regex.split(entry["surface_string"])
        |> Enum.map(&String.trim/1)

      for segment <- segments do
        assert segment in raw_segments,
               """
               #{inspect(segment)} is exempted for #{inspect(slug)} but is not one of
               that entry's template segments: #{inspect(raw_segments)}
               """
      end
    end

    # 3. Exempting a segment must never exempt the WHOLE entry. An entry with no
    #    assertable segment left is an entry clause (b) has stopped covering,
    #    and it must move to :server_authored (a visible, argued edit) rather
    #    than sit in :slot_template looking covered.
    for {slug, _segments} <- @unassertable_segments do
      remaining = template_segments(by_slug[slug]["surface_string"], slug)

      assert remaining != [],
             """
             Every segment of #{inspect(slug)} is exempted, so clause (b) asserts
             nothing about it while its class still claims coverage. Either
             restore a segment or move the entry to @server_authored with the
             argument written down.
             """
    end
  end

  # ── Clause (b) ─────────────────────────────────────────────────────────────

  test "clause (b): every non-exempt entry's surface string still ships in app.js", %{
    js: js,
    terms: terms,
    literals: literals
  } do
    orphans = clause_b_orphans(terms, literals, js)

    assert orphans == [],
           """
           These glossary entries describe strings the shipped bundle no longer
           carries. Either the UI was renamed and the corpus was not regenerated,
           or the entry is now describing a surface that does not exist:

           #{Enum.map_join(orphans, "\n", fn {slug, class, fragments} -> "  #{slug} (#{class}): #{inspect(fragments)}" end)}

           Fix by regenerating the corpus from
           .docs/design-handoffs/pixir-monitor-onboarding/research/ after
           updating terms.csv, not by editing this test's classification.
           """
  end

  test "clause (b) is not vacuous: the literal class is matched against PARSED literals, not source text",
       %{js: js, terms: terms, literals: literals} do
    {:ok, outside} = outside_generated_block(js)

    # The trap this clause exists to avoid, demonstrated on the real tree. Each
    # of these surface strings occurs as a SUBSTRING of app.js outside the
    # generated block while occurring nowhere as a complete string literal, so a
    # `String.contains?` predicate would report them shipped when nothing on
    # screen says them.
    #
    # If any of these ever becomes a real literal the assertion below flips and
    # this test goes red, which is correct: the example would have stopped being
    # an example and this comment would be lying.
    for {surface, colliding_with} <- [{"Live", "Liveness"}, {"Invalid", "Invalidations"}] do
      assert String.contains?(outside, surface),
             "#{inspect(surface)} no longer collides with #{inspect(colliding_with)}; pick a live example"

      refute MapSet.member?(literals, surface),
             """
             #{inspect(surface)} is now a complete string literal in app.js, so it
             no longer demonstrates the substring trap. Replace the example.
             """
    end

    # The THIRD example the moduledoc names, asserted rather than only prosed.
    # It was omitted from the loop above, and the omission was not cosmetic: it
    # is the one example the parse alone does not dispatch, so the loop that
    # skipped it was silent about the only trap still live. `"Ready"` is a
    # complete double-quoted literal by any regex's reckoning — it just happens
    # to sit inside a JSDoc — so it is caught by the COMMENT STRIP, not by
    # parsing, and it needs its own shape of assertion.
    #
    # Kept as its own block rather than folded into the loop because the two
    # traps differ in what they assert: a substring collision requires the word
    # to still be a substring of shipped code, while this one requires it to
    # occur ONLY in a comment, which is the opposite condition.
    assert String.contains?(outside, "Ready"),
           ~s|"Ready" is gone from app.js entirely; the comment-strip example is stale|

    refute String.contains?(strip_comments(outside), "Ready"),
           """
           "Ready" now occurs in app.js OUTSIDE a comment, so it no longer
           demonstrates the comment trap. If shipped code started authoring it,
           `checkpoint-ready` may belong back in :literal — check which, and
           replace this example either way.
           """

    refute MapSet.member?(literals, "Ready"),
           """
           "Ready" is back in the parsed literal set, which means string_literals/1
           has stopped stripping comments. Clause (b) can now be satisfied by a
           sentence written about the UI instead of by the UI, and
           `checkpoint-ready` is the entry that would go green for that reason.
           """

    # And the token the bundle DOES author is present, so reclassifying
    # `checkpoint-ready` to :derived_value_token asserts something real rather
    # than trading one vacuous predicate for another.
    assert MapSet.member?(literals, "ready"),
           ~s|the GATE_DISPLAY_ALIASES value "ready" is gone; `checkpoint-ready` now asserts nothing|

    # And the corpus really does carry entries whose surface strings are those
    # colliding short words, which is why the trap is not hypothetical.
    surfaces = MapSet.new(terms, & &1["surface_string"])
    assert MapSet.member?(surfaces, "Live")
    assert MapSet.member?(surfaces, "Invalid")

    # The literal class is non-trivially large: a classification that collapsed
    # everything into the exempt or template classes would make clause (b) green
    # by asserting nothing.
    literal_entries = for entry <- terms, classify(entry, literals) == :literal, do: entry["slug"]
    assert length(literal_entries) >= 25

    # And the COVERAGE is pinned as a number: 48 of 56 entries have at least one
    # fragment clause (b) requires to be in app.js. This is the denominator made
    # countable, so erosion is arithmetic rather than a judgment call — moving an
    # entry into @server_authored, or exempting a segment, changes this number
    # and the change has to be argued in the same commit.
    asserted =
      for entry <- terms,
          class = classify(entry, literals),
          class != :server_authored,
          do: entry["slug"]

    assert length(asserted) == 48
    assert length(asserted) + length(@server_authored) == length(terms)
  end

  test "clause (b) bites: a shipped rename that orphans an entry goes red", %{js: js, terms: terms} do
    # Red proof, on a MUTATED COPY of the real bundle. The tree is never touched.
    #
    # The mutation is the realistic rot: someone renames a heading in the UI and
    # does not regenerate the corpus. Before this clause existed, every other
    # test in the wave stayed green — LABELLED_TERMS still mapped a label to a
    # live slug, the drift check still saw a corpus matching the fixture — while
    # the corpus described a heading no build shipped.
    renames = [
      {"a section heading", ~s|"Attempt lineage"|, ~s|"Attempt history"|, "attempt-lineage"},
      {"a status line", ~s|"Workspace Overview"|, ~s|"Workspace Summary"|, "workspace-overview"},
      {"a panel heading", ~s|heading(2, "Limitations")|, ~s|heading(2, "Caveats")|, "limitations"}
    ]

    for {shape, from, to, orphaned} <- renames do
      mutated = String.replace(js, from, to, global: true)

      assert mutated != js, "the #{shape} mutation did not apply (#{from} is gone from app.js)"

      orphans = clause_b_orphans(terms, string_literals(mutated), mutated)

      assert Enum.any?(orphans, fn {slug, _class, _fragments} -> slug == orphaned end),
             """
             Renaming #{shape} orphaned the corpus entry #{inspect(orphaned)} and
             clause (b) did NOT go red. The clause is not defending the property
             it claims to defend.

             Orphans observed: #{inspect(orphans)}
             """
    end

    # And the SLOT TEMPLATE half bites too, which is the half a
    # literal-equality-only clause would leave uncovered. A template's anchor is
    # matched inside a literal, so renaming the concatenation fragment must be
    # just as red as renaming a whole heading.
    template_mutant = String.replace(js, ~s|" observed edges|, ~s|" counted edges|, global: true)

    assert template_mutant != js, "the aggregate-arc concatenation fragment is gone from app.js"

    template_orphans = clause_b_orphans(terms, string_literals(template_mutant), template_mutant)

    assert Enum.any?(template_orphans, fn {slug, _, _} -> slug == "aggregate-arc" end),
           """
           Renaming the aggregate-arc concatenation fragment did not go red, so
           the slot-template half of clause (b) asserts nothing.

           Orphans observed: #{inspect(template_orphans)}
           """

    # As does the derived-value-token half: the bundle authors the RAW token, so
    # dropping it from the source-filter vocabulary must orphan the entry whose
    # display form titleCase would have built. Scoped to the vocabulary line
    # rather than renamed globally, because a global rename also rewrites
    # MARKER_TONES and the dispatcher, and then the proof cannot say WHICH of
    # them the clause was depending on — which is precisely how a non-painting
    # constant sat in the pin for a round without any red proof noticing.
    token_mutant =
      String.replace(
        js,
        ~s|source: ["live", "reconstructed", "mixed"]|,
        ~s|source: ["live", "rebuilt", "mixed"]|,
        global: false
      )

    assert token_mutant != js

    assert String.contains?(token_mutant, ~s|"live", "externally_owned", "stale_handle"|),
           "this mutation must leave MARKER_TONES intact, or it cannot isolate the painting site"

    token_orphans = clause_b_orphans(terms, string_literals(token_mutant), token_mutant)

    assert Enum.any?(token_orphans, fn {slug, _, _} -> slug == "reconstructed" end),
           """
           Dropping the raw `reconstructed` token did not go red, so the
           derived-value-token half of clause (b) asserts nothing.

           Orphans observed: #{inspect(token_orphans)}
           """

    # The FAILURE SCENARIO that exposed the comment hole, kept as a permanent
    # red proof. `checkpoint-ready`'s rot is a rename of the `ready` TOKEN: the
    # UI stops painting "Ready" and the corpus entry is orphaned.
    #
    # Authoring this proof corrected the fix's own first draft TWICE, and both
    # corrections are worth recording because the second one reversed the first.
    #
    # The first mutation renamed only the GATE_DISPLAY_ALIASES value at
    # app.js:96 and expected red; it stayed green. That green was read as CORRECT
    # at the time, on the theory that the token ships in two independent places —
    # the alias and MARKER_TONES — so a one-site rename left the word on screen.
    # The mutation was widened to a global rename to accommodate it.
    #
    # That theory was wrong, and widening the mutation to fit it is what hid the
    # error for a round. MARKER_TONES never puts this word on screen: `markerTone`
    # (app.js:1178) uses it to pick a CSS class, and the visible text is
    # `titleCase` of the raw token regardless of membership. The alias at
    # app.js:96 is the ONLY site that paints `ready`, so the first mutation was
    # right and its green was the bug — the very false green this class exists to
    # refuse, sitting inside the class's own red proof.
    #
    # So the mutation is back to ONE LINE: rename the alias value and nothing
    # else. What it must NOT touch is the JSDoc that mentions "Ready" — leaving
    # those bytes in place is the whole point. Before the comment strip, that
    # JSDoc alone kept the entry green through a rename, so this assertion is the
    # one that distinguishes the fixed predicate from the broken one. And it must
    # not touch MARKER_TONES either, which is what makes it a proof that the pin
    # names a painting site rather than any constant that happens to hold the
    # bytes.
    ready_mutant =
      String.replace(
        js,
        ~s|const GATE_DISPLAY_ALIASES = Object.freeze({checkpoint_ready: "ready"});|,
        ~s|const GATE_DISPLAY_ALIASES = Object.freeze({checkpoint_ready: "green"});|,
        global: false
      )

    assert ready_mutant != js, ~s|the GATE_DISPLAY_ALIASES declaration has moved; re-derive this mutation|

    assert String.contains?(ready_mutant, ~s|"needs_orchestrator", "checkpoint_ready", "ready"|),
           """
           This mutation rewrote the MARKER_TONES line. It must not: the tone list
           is a CSS-class allowlist, and a proof that cuts it alongside the alias
           cannot show that the alias is the site the pin depends on.
           """

    assert String.contains?(ready_mutant, ~s|single word "Ready"|),
           """
           The JSDoc that mentions "Ready" is gone from app.js, so this mutation no
           longer demonstrates that a comment cannot keep the entry green. That
           comment is the reason the strip exists; if it moved, re-anchor this
           proof on wherever the prose now lives.
           """

    assert Enum.any?(clause_b_orphans(terms, string_literals(ready_mutant), ready_mutant), fn {slug, _, _} ->
             slug == "checkpoint-ready"
           end),
           """
           Renaming the `ready` token out of shipped code orphaned
           `checkpoint-ready` and clause (b) did NOT go red, even though the only
           remaining occurrence is a JSDoc. Either string_literals/1 has stopped
           stripping comments, or the entry has drifted back into :literal where
           the comment's "Ready" satisfies it. Both are the same false green.
           """

    # And the composite half.
    composite_mutant = String.replace(js, ~s|"Following this run"|, ~s|"Now following"|, global: true)

    assert composite_mutant != js

    assert Enum.any?(clause_b_orphans(terms, string_literals(composite_mutant), composite_mutant), fn {slug, _, _} ->
             slug == "follow"
           end),
           "renaming one half of the follow disjunction did not go red"

    # The real tree stays green: the clause is red on mutants and green here, so
    # it is a predicate rather than a constant.
    assert clause_b_orphans(terms, string_literals(js), js) == []
  end

  test "clause (b) cannot be satisfied by the corpus's own DISPATCH TABLE", %{js: js, terms: terms} do
    # The sibling test above proves the corpus's DATA cannot vouch for itself.
    # This one proves its DELIVERY CODE cannot either, and that is a separate
    # hole one layer in: cutting the generated block removes the entries, not
    # `MANUAL_RUN_READERS`, which dispatches each :derived_value_token entry by
    # writing that entry's raw token as its own call argument —
    # `manualSourceModeReading(scope, "live")`,
    # `manualAdvisoryValueReading(scope, "invalid")`. Against the global literal
    # set every one of those four entries proved its own token shipped.
    #
    # The mutation is therefore UI-HALF-ONLY BY CONSTRUCTION: rename the tokens
    # out of the ONE shipped vocabulary the UI paints them from
    # (FILTER_VOCABULARIES.source, rendered as the filter dropdown's options at
    # app.js:3164) and leave everything else untouched. That is the realistic rot
    # — someone renames the vocabulary the UI paints from and does not think to
    # look at the glossary plumbing — and it is precisely the mutation the
    # `global: true` proofs above CANNOT make, because rewriting every occurrence
    # rewrites the dispatcher too and goes red for a reason that does not
    # distinguish the scoped predicate from the global one.
    #
    # ONE LINE, and the narrowness is now the whole point. This proof used to
    # rewrite the FILTER_VOCABULARIES line AND the MARKER_TONES line together,
    # which meant it never isolated the single genuinely-painting site — and
    # while it was written that way, MARKER_TONES sat in the pin for all four
    # slugs and kept every one of them green through exactly this rename. A proof
    # that mutates both pinned constants at once cannot tell a load-bearing pin
    # from a silencer. This one mutates the painting site only and asserts the
    # tone list survives, so it fails the moment a non-painting constant is
    # unioned back into the pin.
    #
    # Ran against the pre-fix predicate this was fully green: orphans == [].
    lines = String.split(js, "\n")

    vocabulary_index =
      Enum.find_index(lines, &String.contains?(&1, ~s|source: ["live", "reconstructed", "mixed"]|))

    assert vocabulary_index,
           """
           The shipped source vocabulary (FILTER_VOCABULARIES.source) no longer
           has the shape this proof rewrites. Re-anchor the mutation on wherever
           the UI now authors `live`/`reconstructed`; do NOT relax it to a global
           rename, which is what this proof exists to be stronger than.
           """

    ui_half_mutant =
      lines
      |> Enum.with_index()
      |> Enum.map_join("\n", fn {line, index} ->
        if index == vocabulary_index do
          line
          |> String.replace(~s|"live"|, ~s|"streaming"|)
          |> String.replace(~s|"reconstructed"|, ~s|"rebuilt"|)
        else
          line
        end
      end)

    assert ui_half_mutant != js

    # The dispatcher must survive the mutation intact — that is what makes this a
    # test of the SCOPE rather than just another rename proof.
    for untouched <- [
          ~s|manualSourceModeReading(scope, "live")|,
          ~s|manualSourceModeReading(scope, "reconstructed")|
        ] do
      assert String.contains?(ui_half_mutant, untouched),
             """
             #{untouched} was rewritten by this mutation, so the proof no longer
             demonstrates that the dispatcher alone cannot keep an entry green.
             """
    end

    # And so must MARKER_TONES, which is the assertion that makes this proof
    # about the PAINTING SITE rather than about "some constant somewhere".
    # `markerTone` only ever turns these tokens into a CSS class (app.js:1178,
    # :1183); the visible word is `titleCase` of the raw token. If the tone list
    # is ever pinned as a vocabulary again, this mutation stays red and the pin
    # stays honest only because the assertion below refuses to let the tone list
    # answer for the vocabulary.
    assert String.contains?(ui_half_mutant, ~s|"live", "externally_owned", "stale_handle"|),
           """
           This mutation rewrote the MARKER_TONES line. It must not: the tone list
           is a CSS-class allowlist, not a painting site, and rewriting it
           alongside the vocabulary is exactly what hid the false green this proof
           now exists to catch.
           """

    orphans = clause_b_orphans(terms, string_literals(ui_half_mutant), ui_half_mutant)

    for orphaned <- ~w(live-source-mode reconstructed) do
      assert Enum.any?(orphans, fn {slug, _, _} -> slug == orphaned end),
             """
             The shipped UI vocabulary stopped painting this term and clause (b)
             stayed GREEN on #{inspect(orphaned)}, kept alive by MANUAL_RUN_READERS
             quoting the token as its own dispatch argument. The
             :derived_value_token class has drifted back to matching the global
             literal set instead of the vocabulary constants pinned in
             @derived_value_tokens.

             Orphans observed: #{inspect(orphans)}
             """
    end
  end

  test "the invalid-advisory token is scoped to the advisory vocabulary", %{js: js, terms: terms} do
    # `invalid-advisory` is the worst case of the dispatch-table hole and needs
    # its own proof, because `"invalid"` ships in a SECOND, UNRELATED subsystem:
    # it is the route-view sentinel (`{view: "invalid"}`, app.js:1444, :1520).
    # Against the global literal set the entry stayed green with the entire
    # advisory vocabulary deleted — the route parser alone answered for it.
    #
    # So this rewrites only the advisory bucket order — the one constant the
    # advisory distribution paints its bucket phrases from — and asserts both the
    # route-view occurrences AND the marker tone list survive. It used to rewrite
    # the tone line too, and that is why it never caught MARKER_TONES sitting in
    # the pin: with both pinned constants mutated at once, a pin that paints and
    # a pin that only tints are indistinguishable. Cutting one leaves the other
    # to answer, and the assertion below is what refuses to let it.
    lines = String.split(js, "\n")

    advisory_index =
      Enum.find_index(lines, &String.contains?(&1, "const ADVISORY_BUCKET_ORDER ="))

    assert advisory_index,
           "ADVISORY_BUCKET_ORDER has moved; re-anchor this proof"

    advisory_mutant =
      lines
      |> Enum.with_index()
      |> Enum.map_join("\n", fn {line, index} ->
        if index == advisory_index,
          do: String.replace(line, ~s|"invalid"|, ~s|"malformed_advisory"|),
          else: line
      end)

    assert advisory_mutant != js

    assert String.contains?(advisory_mutant, ~s|"needs_orchestrator", "checkpoint_ready", "ready"|),
           """
           This mutation rewrote the MARKER_TONES line. It must not: the tone list
           only ever picks a CSS class (markerTone, app.js:1178), so letting it
           carry `invalid` for this proof would restore the very false green the
           per-slug scoping exists to close.
           """

    assert String.contains?(advisory_mutant, ~s|{view: "invalid"|),
           """
           The route-view `invalid` sentinel is gone from app.js, so this proof no
           longer demonstrates that an unrelated subsystem's identical token
           cannot keep the advisory entry green. That collision is the reason
           `invalid-advisory` is scoped per-slug rather than by one shared cut.
           """

    orphans = clause_b_orphans(terms, string_literals(advisory_mutant), advisory_mutant)

    assert Enum.any?(orphans, fn {slug, _, _} -> slug == "invalid-advisory" end),
           """
           The advisory vocabulary stopped carrying `invalid` and clause (b) stayed
           GREEN, satisfied by the unrelated route-view sentinel. The entry is
           matching the global literal set again instead of the advisory
           constants pinned in @derived_value_tokens.

           Orphans observed: #{inspect(orphans)}
           """
  end

  test "every pinned vocabulary is a load-bearing painting site, not a silencer", %{
    js: js,
    terms: terms
  } do
    # The GENERAL form of the defect the two proofs above catch in their specific
    # shapes, and the reason this file now has it: those proofs are anchored on
    # named lines, so each one can only refuse the ONE non-painting constant it
    # was written against. This refuses every future one.
    #
    # @derived_value_tokens is a claim about where a term is on screen. A
    # constant listed there is being trusted to answer "this word still ships",
    # so the minimum it must satisfy is that CUTTING THE TOKEN FROM IT CAN ORPHAN
    # THE ENTRY. A constant that cannot is not a second painting site; it is a
    # place the same bytes happen to occur, and unioning it into the pin turns
    # the clause back into the tautology it was rescued from.
    #
    # That is not hypothetical: all four slugs carried MARKER_TONES as their
    # second pin, and MARKER_TONES is a CSS-class allowlist whose only consumer
    # (`markerTone`, app.js:1178) concatenates its result into a class name while
    # the visible word comes from `titleCase` of the raw token. So all four
    # entries stayed green through a total rename of the site that actually
    # paints, and every red proof in this file missed it because each one mutated
    # BOTH pinned constants at once.
    #
    # The assertion is per (slug, constant) so it cannot be satisfied in
    # aggregate: cut the token out of exactly one pinned constant's declaration
    # and clause (b) must name that slug.
    for {slug, constants} <- @derived_value_tokens, constant <- constants do
      entry = Enum.find(terms, &(&1["slug"] == slug))
      assert entry, "#{inspect(slug)} is pinned but the corpus does not carry it"

      token = raw_token(entry["surface_string"])

      {:ok, before} = vocabulary_literals(js, constant)

      assert MapSet.member?(before, token),
             """
             #{inspect(slug)} is pinned to #{constant}, but #{inspect(token)} is not
             in that constant's declaration. The pin is stale.
             """

      mutant = cut_token_from_vocabulary(js, constant, token)

      assert mutant != js,
             "cutting #{inspect(token)} out of #{constant} did not change the bundle"

      {:ok, after_cut} = vocabulary_literals(mutant, constant)

      refute MapSet.member?(after_cut, token),
             "the cut left #{inspect(token)} in #{constant}; the mutation is not doing what it says"

      orphans = clause_b_orphans(terms, string_literals(mutant), mutant)

      assert Enum.any?(orphans, fn {orphaned, _, _} -> orphaned == slug end),
             """
             #{constant} is pinned as a vocabulary that vouches for
             #{inspect(slug)}, but removing #{inspect(token)} from it left clause
             (b) GREEN. So that constant is not what keeps the entry honest —
             something else in the pin is answering for it, and #{constant} is a
             silencer sitting in a list that reads as evidence.

             Either drop #{constant} from @derived_value_tokens (if it does not
             paint the word — MARKER_TONES is the case that taught this test:
             `markerTone` only picks a CSS class), or, if it genuinely does paint
             and the entry survives because a co-pinned constant paints too, say
             so by splitting the entry rather than by unioning two constants and
             calling the union evidence.

             Orphans observed: #{inspect(orphans)}
             """
    end
  end

  # A copy of the bundle with one token removed from ONE named constant's
  # declaration and nothing else touched. Line-scoped to the declaration, so the
  # same bytes elsewhere in the bundle survive — which is the entire point:
  # the question this answers is whether THIS constant is what the clause depends
  # on, and a global rename cannot ask it.
  defp cut_token_from_vocabulary(js, name, token) do
    # Sub-key aware, and it MUST be: the guard and the predicate read the same
    # scope through vocabulary_literals/2, so a cut wider than the read would
    # let the two share an over-broad denominator again — the guard would cut a
    # sibling key's bytes and claim the pinned scope was load-bearing.
    {constant, key} =
      case String.split(name, ".", parts: 2) do
        [constant] -> {constant, nil}
        [constant, key] -> {constant, key}
      end

    lines = String.split(js, "\n")

    start = Enum.find_index(lines, &String.starts_with?(String.trim(&1), "const #{constant} ="))
    assert start, "#{constant} is no longer declared in app.js"

    stop =
      lines
      |> Enum.drop(start)
      |> Enum.find_index(&Regex.match?(~r/\)\s*;\s*$/, &1))
      |> then(&if(&1, do: start + &1, else: start))

    in_scope? = fn line, index ->
      index >= start and index <= stop and
        (key == nil or Regex.match?(~r/^\s*#{Regex.escape(key)}:\s*\[/, line))
    end

    lines
    |> Enum.with_index()
    |> Enum.map_join("\n", fn {line, index} ->
      if in_scope?.(line, index),
        do: String.replace(line, ~s|"#{token}"|, ~s|"pixir_cut_#{token}"|),
        else: line
    end)
  end

  test "clause (b) cannot be satisfied by the corpus quoting itself", %{js: js, terms: terms} do
    # The generated block ships INSIDE app.js, so every surface string occurs in
    # the file as part of its own entry. If the block were not cut, clause (b)
    # would be a tautology: 56 of 56 green forever, including for an entry whose
    # UI string was deleted this morning.
    #
    # Proven by running the clause over the WHOLE bundle, block included, on a
    # mutant that orphans an entry. Over the full text it is green (the corpus
    # quotes itself); over the cut text it is red.
    #
    # The mutation is applied to the UI HALF ONLY, which is both the realistic
    # rot and what makes this a valid demonstration. A rename applied globally
    # would edit the generated block too — the corpus would stop quoting the old
    # spelling and the whole-file scan would go red for the wrong reason,
    # "proving" the tautology does not exist by removing the very bytes that
    # cause it. Renaming the UI and leaving the corpus stale is exactly what
    # happens when someone forgets to regenerate.
    # Rebuilt IN PLACE, line by line, so the generated block stays exactly where
    # it was: `outside_generated_block/1` slices on marker position, and a
    # reassembly that moved the block would be testing a file shape that never
    # ships.
    lines = String.split(js, "\n")
    begin_index = Enum.find_index(lines, &(&1 == @begin_marker))
    end_index = Enum.find_index(lines, &(&1 == @end_marker))

    mutated =
      lines
      |> Enum.with_index()
      |> Enum.map_join("\n", fn {line, index} ->
        if index > begin_index and index < end_index,
          do: line,
          else: String.replace(line, ~s|"Attempt lineage"|, ~s|"Attempt history"|, global: true)
      end)

    assert mutated != js, ~s|"Attempt lineage" is no longer a UI-side literal; pick another rename|

    assert String.contains?(mutated, ~s|"surface_string": "Attempt lineage"|),
           "the generated block must still carry the stale corpus spelling for this demonstration to mean anything"

    whole_file_literals =
      ~r/"((?:[^"\\\n]|\\.)*)"/
      |> Regex.scan(mutated, capture: :all_but_first)
      |> Enum.map(fn [literal] -> decode_escapes(literal) end)
      |> MapSet.new()

    refute Enum.any?(clause_b_orphans(terms, whole_file_literals, mutated), fn {slug, _, _} -> slug == "attempt-lineage" end),
           """
           Scanning the whole bundle was expected to MISS the orphan (that is the
           tautology this cut exists to avoid). It did not, which means the
           generated block no longer carries surface strings and the rationale in
           this file's moduledoc has gone stale.
           """

    assert Enum.any?(clause_b_orphans(terms, string_literals(mutated), mutated), fn {slug, _, _} ->
             slug == "attempt-lineage"
           end),
           "cutting the generated block must be what makes the orphan visible"
  end

  # ── Clause (c): the forward guard ──────────────────────────────────────────

  defp body_between(js, from, to) do
    js
    |> String.split(from)
    |> Enum.at(1)
    |> case do
      nil -> flunk("app.js no longer contains #{inspect(from)}")
      rest -> rest |> String.split(to) |> hd()
    end
  end

  @doc false
  # The shipped Runs column names, READ from the frozen constant rather than
  # restated here. Restating them would make this file the parallel copy table
  # the wave's seam obligation forbids, and would make clause (c) blind to
  # exactly the addition it exists to catch: a new column appended to
  # RUNS_COLUMNS would not appear in a hand-copied list, so the totality check
  # would pass over a column it never saw.
  def runs_columns(js) do
    js
    |> strip_comments()
    |> body_between("const RUNS_COLUMNS = Object.freeze([", "]);")
    |> then(&Regex.scan(~r/"([^"]*)"/, &1, capture: :all_but_first))
    |> Enum.map(fn [name] -> name end)
  end

  @doc false
  # The labels LABELLED_TERMS maps, read from the shipped table.
  def labelled_labels(js) do
    js
    |> strip_comments()
    |> body_between("const LABELLED_TERMS = Object.freeze({", "});")
    |> then(&Regex.scan(~r/"([^"]+)":\s*"([^"]+)"/, &1, capture: :all_but_first))
    |> Enum.map(fn [label, slug] -> {label, slug} end)
  end

  # The generic card constructors: the ones that take their heading as an
  # ARGUMENT rather than hard-coding it, and label it unconditionally.
  #
  # Read as a set of NAMES here and as call sites below. The names are pinned
  # because a constructor is only generic if its own body labels the parameter,
  # and `every pinned generic constructor really does label its heading
  # parameter` asserts exactly that against the bundle — so the pin is earned by
  # the code rather than declared here.
  @generic_card_constructors ~w(truthCard distributionCard labeledTruthCard)

  # One argument at a call site, as source text. A COMPLETE double-quoted literal
  # first — a heading may carry parentheses ("Source (run-scoped)"), and a
  # paren-free run would truncate it mid-string and then flunk on a heading the
  # bundle spells perfectly well — then a CALL EXPRESSION (an identifier path
  # followed by one balanced paren group: `unitGateLabel(unit)`,
  # `headingFor(x)`), which the resolver FLUNKS as unresolvable — otherwise any
  # run containing neither a comma nor a paren, which is what an identifier is.
  #
  # The call-expression alternative exists because its ABSENCE was a hole: the
  # paren-free branch produced zero matches for `labelledTerm("h3",
  # headingFor(x), route)`, so the site was never ENUMERATED and never reached
  # the flunk — the safety net was downstream of the gap, and a mutant shipping
  # an unmapped doctrine card through that shape left the whole suite green.
  # Capturing the shape whole hands it to the resolver, whose unresolvable
  # branch is the loud failure the moduledoc promises. Nested calls beyond one
  # paren level are not captured here; `the argument scan enumerates every
  # labelledTerm call site` makes THAT miss red by arithmetic instead of
  # invisible.
  #
  # Deliberately NOT permissive beyond that. Widening to "anything up to the
  # next comma" would trade a loud flunk for a silent miss, which is the failure
  # this file keeps having to fix.
  # GROUPED, and the group is load-bearing: an ungrouped alternation
  # interpolated into a larger pattern splits that pattern at its TOP level
  # rather than at the argument position, silently matching something else
  # entirely. That is not a hypothetical — it happened while writing this, and
  # the symptom was a flunk naming `"units: 100"` from an unrelated constant.
  @argument ~S{(?:"(?:[^"\\]|\\.)*"|[A-Za-z0-9_$.]+\((?:[^()"]|"(?:[^"\\]|\\.)*")*\)|[^,()]+)}

  @doc false
  # Every heading literal that reaches an UNCONDITIONAL `labelledTerm(…)` call,
  # by every shape the bundle ships. These are the doctrine-labelled surfaces
  # that are NOT Runs columns.
  #
  # Scanned from the call sites rather than listed, for the same reason
  # runs_columns/1 is read rather than restated: a new
  # `rail.append(truthCard(route, "Backpressure", ...))` must be SEEN by the
  # guard, and a hand list cannot see what was not added to it.
  #
  # TWO shapes, because the bundle ships two and scanning only one is a hole that
  # was live here. The generic constructors take the heading as an argument
  # (`truthCard(route, "Liveness", …)`); a DEDICATED constructor instead
  # hard-codes its own heading in the `labelledTerm` call (`postTerminalCard` at
  # app.js:3708 writes `labelledTerm("h3", "Child activity after end", route)`
  # and is rail-appended at app.js:3693). The constructor regex cannot see the
  # second shape at all: a new `backpressureCard(...)` written in exactly
  # postTerminalCard's shape would rail-append an unmapped heading and leave this
  # guard green.
  #
  # So the inventory is the AFFORDANCE — a labelled term painted unconditionally
  # — rather than three constructor names, and the two scans are unioned.
  #
  # BOTH halves are total over their own call sites, and that totality is what a
  # union of two partial scans cannot buy. The earlier spelling matched
  # `truthCard\(\s*route\s*,` — the literal token `route` as first argument — on
  # the grounds that the affordance half would catch anything it missed. It does
  # not: inside `labeledTruthCard` the heading is `label`, a PARAMETER, and the
  # affordance half deliberately contributes nothing for a parameter precisely
  # because "its values are read at the route-first call sites". So
  # `truthCard(r, "Backpressure", …)` — the shape a destructuring or a local
  # alias naturally produces — was seen by NEITHER half and shipped an unmapped
  # doctrine h3 with clause (c) green. The two halves each assumed the other
  # covered it. The constructor scan therefore matches the constructor NAME and
  # resolves its heading ARGUMENT through the same resolver the affordance half
  # uses, so the first argument's spelling is no longer load-bearing.
  #
  # And the affordance scan covers EVERY TAG, not only `"h3"`. Anchoring it to h3
  # was the same accident one seam over: the bundle paints the dotted affordance
  # from `labelledTerm("span", …)` on the live-activity and Runs-list front doors
  # (app.js:3452, :3455, :3502), unconditionally and into the same manual. An h3-
  # only regex left those three sites — and any new front-door term written
  # beside them — outside the denominator this file's moduledoc declares as "the
  # surface that carries the dotted-underline promise". A new unmapped front-door
  # label throws `labelled_term_unmapped` on first render exactly as an unmapped
  # card heading does, so the guard must be red for it too.
  #
  # Every call site is therefore classified, and an argument that cannot be
  # classified FLUNKS rather than being skipped:
  #
  #   * a double-quoted literal is the heading;
  #   * an identifier bound to a string literal inside the enclosing function
  #     body resolves to that literal;
  #   * an identifier that is the ITERATION VARIABLE of a `forEach` over a local
  #     bound to a call of a named producer resolves through that producer:
  #     either to the authored literals the producer returns, or — when the
  #     producer is a `LABELLED_TERMS`-membership filter, which cannot by
  #     construction yield an unmapped label — to nothing, with the filter itself
  #     asserted (see `every iterated front-door vocabulary is authored or
  #     membership-filtered`);
  #   * an identifier that is a PARAMETER of the enclosing function contributes
  #     nothing here ONLY when that function is one of the pinned generic
  #     constructors, whose call sites the constructor scan reads TOTALLY; a
  #     parameter of any OTHER function is unresolvable and flunks, because an
  #     unpinned constructor's call sites are read by nobody;
  #   * anything else is unresolvable, and unresolvable is RED. A label this file
  #     cannot read is a label it cannot guard, and the honest failure is to say
  #     so rather than to return a shorter list.
  #
  # And non-enumeration is red by ARITHMETIC for any call the strip still sees
  # as a `labelledTerm(` or pinned-constructor `(` token: `the argument scan
  # enumerates every labelledTerm and constructor call site` reconciles
  # occurrence counts against enumerated sites, so an ARGUMENT shape the scan
  # cannot capture is red by counting instead of invisible. A call the token
  # count itself cannot see (`.call`/`.apply`, an identifier alias, a space
  # before the paren) is outside that guarantee — the moduledoc lists it under
  # what this test does not catch.
  def card_headings(js) do
    # Comment-stripped FIRST, and every offset below indexes the STRIPPED text:
    # body_between/2 takes the first occurrence of its opening delimiter, so a
    # commented-out declaration or call site above the real one would otherwise
    # REPLACE the inventory rather than add to it — a false green over exactly
    # the rot this clause exists to catch. Clause (b) already treats stripping
    # as load-bearing; clause (c) reads the same bundle with the same rule.
    js = strip_comments(js)
    functions = js_functions(js)

    by_constructor =
      ~r/(?:#{Enum.join(@generic_card_constructors, "|")})\(\s*#{@argument}\s*,\s*(#{@argument})\s*[,)]/
      |> Regex.scan(js, capture: :all_but_first, return: :index)
      |> Enum.flat_map(fn [{start, len}] ->
        arg = js |> binary_part(start, len) |> String.trim()
        resolve_label_argument(arg, enclosing_function(functions, start), js, :constructor)
      end)

    by_affordance = labelled_headings(js, functions)

    Enum.uniq(by_constructor ++ by_affordance)
  end

  # Every UNCONDITIONAL `labelledTerm(<tag>, <arg>, …)` call site in the bundle,
  # resolved to the label(s) it can paint.
  #
  # Conditional sites are excluded and that exclusion is narrow, argued and
  # COUNTED: the Runs `<th>` is painted through a
  # `hasOwnProperty.call(LABELLED_TERMS, name) ? labelledTerm(…) : text(…)`
  # ternary, so it CANNOT paint an unmapped label — the guard is the same
  # predicate this clause would assert. Clause (c)'s RUNS_COLUMNS totality is
  # what covers that surface instead, and covers it better: it refuses a new
  # column that silently falls to the plain branch.
  #
  # An exclusion is a place a future author can hide, so `the membership-guarded
  # exclusion is exactly one shipped site` pins the count. A second one appearing
  # is a visible, argued edit rather than a quiet way to make a label invisible
  # to this guard by wrapping it in the right ternary.
  defp labelled_headings(js, functions) do
    js
    |> labelled_term_sites()
    |> Enum.reject(fn {start, _len} -> membership_guarded?(js, start) end)
    |> Enum.flat_map(fn {start, len} ->
      arg = js |> binary_part(start, len) |> String.trim()
      resolve_label_argument(arg, enclosing_function(functions, start), js, :affordance)
    end)
  end

  @doc false
  # Every `labelledTerm(<tag>, <arg>, …)` call site's ARGUMENT span, guarded and
  # unguarded alike.
  def labelled_term_sites(js) do
    js = strip_comments(js)

    ~r/labelledTerm\(\s*"[a-z0-9]+"\s*,\s*(#{@argument})\s*[,)]/
    |> Regex.scan(js, capture: :all_but_first, return: :index)
    |> Enum.map(fn [span] -> span end)
  end

  @doc false
  # The `labelledTerm` call sites this file declines to inventory because a
  # LABELLED_TERMS membership ternary makes an unmapped label impossible there.
  def membership_guarded_sites(js) do
    js = strip_comments(js)
    js |> labelled_term_sites() |> Enum.filter(fn {start, _} -> membership_guarded?(js, start) end)
  end

  # True when the `labelledTerm` call at this offset sits on the true branch of a
  # `hasOwnProperty.call(LABELLED_TERMS, …) ?` ternary on the same line, which is
  # the one conditional shape the bundle ships and the one shape that cannot
  # paint an unmapped label.
  defp membership_guarded?(js, offset) do
    line_start =
      case :binary.matches(binary_part(js, 0, offset), "\n") do
        [] -> 0
        matches -> matches |> List.last() |> elem(0)
      end

    js
    |> binary_part(line_start, offset - line_start)
    |> String.contains?("hasOwnProperty.call(LABELLED_TERMS,")
  end

  # The bundle is a single IIFE whose functions are all declared at two-space
  # indent, so the declarations partition it: each function's text runs from its
  # own `function` keyword to the next one's. Each entry carries :name, :params,
  # its byte :start, and that :body slice.
  defp js_functions(js) do
    matches = Regex.scan(~r/^  function ([A-Za-z0-9_$]+)\(([^)]*)\)/m, js, return: :index)

    assert matches != [], "app.js no longer declares functions at two-space indent"

    starts = Enum.map(matches, fn [{start, _} | _] -> start end)
    bounds = Enum.zip(starts, tl(starts) ++ [byte_size(js)])

    matches
    |> Enum.zip(bounds)
    |> Enum.map(fn {[_whole, name_idx, params_idx], {start, stop}} ->
      %{
        name: slice(js, name_idx),
        params: js |> slice(params_idx) |> String.split(",") |> Enum.map(&String.trim/1),
        start: start,
        body: binary_part(js, start, stop - start)
      }
    end)
  end

  defp slice(js, {start, len}), do: binary_part(js, start, len)

  defp enclosing_function(functions, offset) do
    functions
    |> Enum.filter(&(&1.start <= offset))
    |> List.last()
  end

  # Resolve one labelled-surface argument to the label(s) it can paint, or FLUNK.
  #
  # `origin` only shapes the failure message: :constructor for a generic card
  # constructor's heading argument, :affordance for a `labelledTerm` call site.
  # The classification is identical, deliberately — the whole point of the fix
  # that introduced it is that the two scans must not disagree about what a shape
  # means, because it was exactly that disagreement (each half assuming the other
  # read the parameter) that let an aliased-`route` call site through both.
  defp resolve_label_argument(arg, fun, js, origin) do
    cond do
      # A quoted literal: the dedicated-constructor shape postTerminalCard ships,
      # and the shape every `truthCard(route, "Liveness", …)` call site uses.
      Regex.match?(~r/^"([^"]*)"$/, arg) ->
        [Regex.run(~r/^"([^"]*)"$/, arg, capture: :all_but_first) |> hd()]

      fun == nil ->
        flunk("""
        A #{origin_phrase(origin)} sits outside any function declared at
        two-space indent, so its label cannot be resolved: #{inspect(arg)}

        card_headings/1 must be able to read every label it ships, or the forward
        guard is silently narrower than it claims.
        """)

      # A local bound to a string literal in the same function body.
      literals = local_literal_bindings(arg, fun) ->
        literals

      # An ITERATION VARIABLE over an authored vocabulary: the front-door shape.
      # `terms.forEach(function (term, …) { … labelledTerm("span", term, …) })`
      # is how both front doors paint, so the resolution follows the array back
      # to the producer that built it rather than giving up.
      literals = iterated_vocabulary(arg, fun, js) ->
        literals

      # The generic-constructor shape: the label is a parameter of a constructor
      # whose own call sites the constructor scan reads TOTALLY. It contributes
      # nothing here, and — unlike the version of this file that shipped before
      # the aliased-`route` hole was found — that is now a fact rather than an
      # assumption, because the constructor scan no longer requires the first
      # argument to be spelled `route`.
      #
      # RESTRICTED to the pinned constructor names, because the justification
      # only holds for them: the constructor scan is built from exactly
      # @generic_card_constructors, so a NEW dedicated constructor taking its
      # heading as a parameter is in neither half — its call sites are unread
      # and its parameter would contribute nothing. That was a live false green
      # (a parameter-heading `backpressureCard` shipped unmapped with clause (c)
      # green), so a parameter of any OTHER function falls through to the flunk
      # below until its constructor is pinned, and `every pinned generic
      # constructor really does label its heading parameter` earns the pin.
      arg in fun.params and fun.name in @generic_card_constructors ->
        []

      true ->
        flunk("""
        A #{origin_phrase(origin)} label cannot be resolved to a literal:
        #{inspect(arg)} in function #{inspect(fun.name)}.

        This label paints with the dotted affordance, so it MUST be in
        LABELLED_TERMS — but this file cannot read it, so clause (c) cannot
        check it. Either bind it to a string literal in the same function
        body, iterate it from a producer this file can read, pass it as a
        parameter of a generic card constructor, or teach card_headings/1 the
        new shape. Leaving it unreadable would make the guard green over a
        surface it never saw.
        """)
    end
  end

  defp origin_phrase(:constructor), do: "generic card constructor call site"
  defp origin_phrase(:affordance), do: ~s|labelledTerm(…) call site|

  # `const <arg> = "<literal>"` in the enclosing function body, or nil.
  defp local_literal_bindings(arg, fun) do
    case Regex.scan(
           ~r/(?:const|let|var)\s+#{Regex.escape(arg)}\s*=\s*"([^"]*)"/,
           fun.body,
           capture: :all_but_first
         ) do
      [] -> nil
      found -> Enum.map(found, fn [literal] -> literal end)
    end
  end

  # `<array>.forEach(function (<arg>, …)` where `<array>` is a local bound to a
  # call of a NAMED producer in the same function body. Resolves through the
  # producer, or nil when the shape does not apply (so the caller flunks).
  #
  # Two producer shapes are readable, and they are readable for opposite reasons:
  #
  #   * a producer that returns AUTHORED STRING LITERALS contributes those
  #     literals, and they are then checked against LABELLED_TERMS exactly as a
  #     card heading is (`streamVocabularyTerms` returns `["hints only",
  #     "coalesced"] : ["hints only"]`);
  #   * a producer that is a LABELLED_TERMS MEMBERSHIP FILTER contributes
  #     nothing, because it cannot yield an unmapped label — its filter IS the
  #     predicate clause (c) would assert (`doctrineRunsColumns` filters
  #     RUNS_COLUMNS by `hasOwnProperty.call(LABELLED_TERMS, name)`), and the
  #     names it drops are covered by clause (c)'s RUNS_COLUMNS totality
  #     instead. That reading is not taken on trust: `every iterated front-door
  #     vocabulary is authored or membership-filtered` re-derives both shapes
  #     from the bundle and fails if either producer stops having them.
  #
  # A producer with neither shape resolves to nil and the call site flunks, which
  # is the same trade the rest of the resolver makes: an unreadable vocabulary is
  # red, never skipped.
  defp iterated_vocabulary(arg, fun, js) do
    with true <- Regex.match?(~r/\.forEach\(\s*function\s*\(\s*#{Regex.escape(arg)}\s*[,)]/, fun.body),
         [[array]] <-
           Regex.scan(
             ~r/([A-Za-z0-9_$]+)\.forEach\(\s*function\s*\(\s*#{Regex.escape(arg)}\s*[,)]/,
             fun.body,
             capture: :all_but_first
           ),
         [[producer]] <-
           Regex.scan(
             ~r/(?:const|let|var)\s+#{Regex.escape(array)}\s*=\s*([A-Za-z0-9_$]+)\(/,
             fun.body,
             capture: :all_but_first
           ) do
      producer_vocabulary(js, producer)
    else
      _ -> nil
    end
  end

  @doc false
  # The labels a named producer function can yield: `{:literals, [...]}` for an
  # authored vocabulary, `:membership_filtered` when it filters by
  # LABELLED_TERMS membership, `nil` when neither shape is readable.
  def producer_shape(js, producer) do
    case Enum.find(js_functions(js), &(&1.name == producer)) do
      nil ->
        nil

      fun ->
        body = producer_body(fun.body)

        cond do
          membership_filter_exactly?(body) ->
            :membership_filtered

          true ->
            # The literals inside ARRAY LITERALS only. A producer's body also
            # holds literals that are not vocabulary — `streamVocabularyTerms`
            # compares `streamState === "connected"` before choosing which array
            # to return — and admitting those would put a state token into the
            # inventory and demand a LABELLED_TERMS mapping for a word the line
            # never paints. The array brackets are what say "these are the
            # elements".
            literals =
              ~r/\[([^\[\]]*)\]/
              |> Regex.scan(body, capture: :all_but_first)
              |> Enum.flat_map(fn [inner] ->
                ~r/"([^"]*)"/
                |> Regex.scan(inner, capture: :all_but_first)
                |> Enum.map(fn [literal] -> literal end)
              end)
              |> Enum.uniq()

            if literals == [], do: nil, else: {:literals, literals}
        end
    end
  end

  defp producer_vocabulary(js, producer) do
    case producer_shape(js, producer) do
      {:literals, literals} -> literals
      :membership_filtered -> []
      nil -> nil
    end
  end

  # A producer's own body: `js_functions/1` slices from one `function` keyword to
  # the NEXT one, so a producer's slice trails the following function's JSDoc.
  # Cut at the two-space-indent `}` that closes the declaration, then drop
  # comment lines — a quoted word in prose about a vocabulary is not a member of
  # it, the same rule `string_literals/1` follows for the bundle at large.
  # `:membership_filtered` used to be a SUBSTRING test — any body MENTIONING
  # `hasOwnProperty.call(LABELLED_TERMS,` classified as the safe shape, so a
  # producer widened to `["Backpressure"].concat(RUNS_COLUMNS.filter(...))`, or
  # loosened with `|| name === "Duration"`, kept contributing [] while the
  # front door painted an unmapped label at first render — the exact hole
  # clause (c) claims to make static-red (found by adversarial review, #553).
  # The classification is now STRUCTURAL: the producer's executable body must
  # be exactly the one safe statement, whitespace-tolerant, and nothing else.
  # Any widening stops matching, the resolver falls through to the literal
  # reading, and the smuggled term surfaces as unmapped (red proof 2i).
  defp membership_filter_exactly?(body) do
    statements =
      body
      |> String.split("\n")
      |> Enum.drop(1)
      |> Enum.reject(&(String.trim(&1) in ["", "}"]))
      |> Enum.map_join(" ", &String.trim/1)
      |> String.replace(~r/\s+/, " ")

    Regex.match?(
      ~r/\Areturn RUNS_COLUMNS\.filter\(function \(name\) \{ return Object\.prototype\.hasOwnProperty\.call\(LABELLED_TERMS, name\); \}\);\z/,
      statements
    )
  end

  defp producer_body(body) do
    lines = String.split(body, "\n")

    closing =
      lines
      |> Enum.drop(1)
      |> Enum.find_index(&(String.trim_trailing(&1) == "  }"))

    lines
    |> then(fn all -> if closing, do: Enum.take(all, closing + 2), else: all end)
    |> strip_comments_lines()
    |> Enum.join("\n")
  end

  test "clause (c): every Runs column is either a doctrine term or a pinned ordinary noun", %{js: js} do
    columns = runs_columns(js)
    labelled = labelled_labels(js) |> Enum.map(&elem(&1, 0)) |> MapSet.new()

    assert columns != [], "RUNS_COLUMNS could not be read from app.js"

    unclassified =
      Enum.reject(columns, &(MapSet.member?(labelled, &1) or &1 in @ordinary_table_nouns))

    assert unclassified == [],
           """
           These Runs list columns are neither in LABELLED_TERMS nor pinned as
           ordinary table nouns: #{inspect(unclassified)}

           A new column has to be classified, and the classification is a
           statement about the reader:

             * If it names a DOCTRINE axis, add a corpus entry for it,
               regenerate the glossary, and map the header in LABELLED_TERMS. It
               then carries the dotted affordance and the manual can define it.

             * If it is an ordinary table noun ("Run", "Duration"), add it to
               @ordinary_table_nouns in this file. It stays plain, which is
               honest.

           Shipping it as neither is the failure this clause exists to catch: the
           header renders plain, no assertion notices, and the reader sees an axis
           the Monitor promised to define and did not.
           """

    # The ordinary nouns really are ordinary: none of them may acquire a corpus
    # entry-backed label without leaving this list, or the pin would be exempting
    # a term that IS doctrine.
    for noun <- @ordinary_table_nouns do
      refute MapSet.member?(labelled, noun),
             "#{inspect(noun)} is pinned as an ordinary table noun but is now labelled; move it out of @ordinary_table_nouns"
    end

    # And the pin is not stale: every ordinary noun is still a shipped column.
    for noun <- @ordinary_table_nouns do
      assert noun in columns,
             "#{inspect(noun)} is pinned as an ordinary Runs column but is no longer in RUNS_COLUMNS"
    end
  end

  test "clause (c): every LABELLED_TERMS mapping lands on a slug the corpus carries", %{js: js, terms: terms} do
    # The mirror of the two totality checks above: they catch a doctrine surface
    # added with no mapping; this catches a MAPPING added with no corpus entry.
    # Both are ways to ship a dotted underline the manual cannot honour.
    #
    # Clause (a)'s executed seam (checkLabelledTerms) already refuses this at
    # runtime and carries its own red proof (labelled_term_dead_link). It is a
    # first-class assertion here as well, at the SOURCE tier, for two reasons.
    # It is one of the two directions the acceptance criteria name, so leaving it
    # only inside this file's red-proof test would mean the property is
    # demonstrated but never asserted on the real tree. And the two tiers fail
    # DIFFERENTLY: the seam needs node and skips locally without it, while this
    # runs everywhere `mix test` does.
    corpus_slugs = MapSet.new(terms, & &1["slug"])

    dangling =
      js
      |> labelled_labels()
      |> Enum.reject(fn {_label, slug} -> MapSet.member?(corpus_slugs, slug) end)

    assert dangling == [],
           """
           These LABELLED_TERMS mappings point at slugs the glossary corpus does
           not carry: #{inspect(dangling)}

           The label still paints with its dotted underline and the anchor still
           navigates — onto the manual's unknown-slug page. A dead link dressed as
           an explanation is worse than no affordance, which is the whole reason
           labelledTermSlug refuses rather than degrading.

           Add the corpus entry and regenerate, or drop the mapping.
           """

    # And the table is non-empty, so the check cannot pass by having nothing to
    # check. Sixteen: seven rail headings, five list short forms (no "Attention"
    # — the list has no such column; the phantom mapping was dropped on #553),
    # the Unit Inspector's "Runtime gate", and three front-door terms.
    assert length(labelled_labels(js)) >= 16
  end

  test "clause (c): every labelled card heading and front-door term is a mapped doctrine term", %{js: js} do
    headings = card_headings(js)
    labelled = labelled_labels(js) |> Enum.map(&elem(&1, 0)) |> MapSet.new()

    # Eleven, not eight: the seven reached by the card constructors, plus
    # `Child activity after end` which postTerminalCard hard-codes into its own
    # labelledTerm call, plus the THREE front-door terms the `labelledTerm("span",
    # …)` sites paint (`hints only`, `coalesced`, `last successful authoritative
    # refetch`). The floor was 7 while the scan missed the eighth and the number
    # still matched, because the Inspector's `Runtime gate` filled the gap; it
    # was 8 while the scan was anchored to `"h3"` and missed all three front-door
    # terms. A floor a hole can satisfy by coincidence is not a floor, so it moves
    # with every widening.
    assert length(headings) >= 11,
           "expected the card headings and both front doors to be found; scan returned #{inspect(headings)}"

    assert "Child activity after end" in headings,
           """
           The dedicated-constructor shape is no longer reached by card_headings/1.

           postTerminalCard labels its own heading rather than taking it as an
           argument, so it is only visible to the `labelledTerm(…)` half of the
           scan. If that call moved, the union has gone back to seeing one shape
           and a card constructor written like this one is unguarded again.

           (Making the heading non-literal no longer hides it: the resolver reads
           a local bound to a literal and FLUNKS on anything it cannot resolve.
           But that half must still be scanning labelledTerm call sites at all.)
           """

    # The front-door half, pinned by its own terms. These are painted by
    # `labelledTerm("span", …)`, not by any card constructor, and an h3-anchored
    # scan saw none of them — which left the surface the moduledoc calls "the
    # surface that carries the dotted-underline promise" only partly enumerated.
    for term <- ["hints only", "coalesced", "last successful authoritative refetch"] do
      assert term in headings,
             """
             The front-door term #{inspect(term)} is no longer reached by
             card_headings/1, so the `labelledTerm("span", …)` half of the
             affordance surface has fallen out of the inventory. A new unmapped
             term added beside it would throw labelled_term_unmapped on first
             render with clause (c) green — the exact hole the h3-only scan had.

             Scan returned: #{inspect(headings)}
             """
    end

    unmapped = Enum.reject(headings, &MapSet.member?(labelled, &1))

    assert unmapped == [],
           """
           These labelled surfaces are not in LABELLED_TERMS: #{inspect(unmapped)}

           Every truth-rail card, Unit Inspector card and front-door term labels
           unconditionally (labelledTerm(tag, label, route)), so an unmapped label
           throws a MonitorDefect the moment that surface renders. Pinning it here
           makes the addition red at `mix test` rather than red at whichever
           browser proof happens to paint it.

           Add a corpus entry for the new dimension and map its label.
           """
  end

  test "every pinned generic constructor really does label its heading parameter", %{js: js} do
    # @generic_card_constructors is the list card_headings/1 reads heading
    # arguments FROM, and the resolver contributes nothing for a parameter of one
    # of them on the grounds that its values arrive at those call sites. Both
    # halves of that reasoning have to stay true of the bundle.
    functions = js_functions(js)

    for name <- @generic_card_constructors do
      fun = Enum.find(functions, &(&1.name == name))

      assert fun, "#{name} is pinned as a generic card constructor but app.js no longer declares it"

      assert "label" in fun.params,
             """
             #{name} no longer takes a `label` parameter, so the heading is not
             where card_headings/1 reads it. Either the constructor changed shape
             or it stopped being generic; re-derive @generic_card_constructors.
             """

      # And it labels that parameter itself, unconditionally. A "generic
      # constructor" that does not is not one, and pinning it here would make the
      # resolver skip a parameter for a reason that had stopped being true.
      assert Regex.match?(~r/labelledTerm\(\s*"[a-z0-9]+"\s*,\s*label\s*,/, fun.body) or
               Regex.match?(~r/#{Enum.join(@generic_card_constructors, "|")}\([^)]*label/, fun.body),
             """
             #{name} does not pass `label` to labelledTerm, nor delegate it to
             another pinned constructor. It is pinned as a generic card
             constructor, which is what lets the resolver contribute nothing for
             its `label` parameter — so if it stopped labelling, that skip is a
             hole rather than a deferral.
             """
    end
  end

  test "the membership-guarded exclusion is exactly one shipped site", %{js: js} do
    # The affordance scan skips a `labelledTerm` call that sits on the true
    # branch of a `hasOwnProperty.call(LABELLED_TERMS, …)` ternary, because such a
    # call CANNOT paint an unmapped label. That reasoning is sound and the
    # exclusion is one site — but an exclusion is also the cheapest place to hide
    # a label from this guard, so the count is pinned rather than trusted.
    guarded = membership_guarded_sites(js)
    # The spans index the comment-stripped text the scanner walked.
    stripped = strip_comments(js)

    assert length(guarded) == 1,
           """
           #{length(guarded)} labelledTerm call sites are skipped as
           membership-guarded; exactly one ships (the Runs `<th>` at app.js:3276).

           A second one is either a real second guarded surface — in which case
           say so here and check that clause (c) covers it the way RUNS_COLUMNS
           covers the header row — or it is a label made invisible to this guard
           by wrapping it in a ternary, which is the failure the exclusion must
           not become.

           Guarded argument spans: #{inspect(Enum.map(guarded, fn {start, len} -> binary_part(stripped, start, len) end))}
           """

    [{start, len}] = guarded

    assert binary_part(stripped, start, len) == "name",
           "the one membership-guarded site no longer labels `name`; re-derive this pin"

    # And it really is the Runs header row, whose surface clause (c) covers by
    # the RUNS_COLUMNS totality instead.
    line =
      js
      |> String.split("\n")
      |> Enum.find(&String.contains?(&1, "hasOwnProperty.call(LABELLED_TERMS, name) ? labelledTerm("))

    assert line && String.contains?(line, "runs-header:"),
           """
           The membership-guarded site is no longer the Runs header row. That row
           is the only surface whose exclusion is paid for by another clause
           (the RUNS_COLUMNS totality); any other guarded site is unaccounted for.
           """
  end

  test "the argument scan enumerates every labelledTerm and constructor call site", %{js: js} do
    # The arithmetic backstop behind clause (c)'s totality claim. The argument
    # regex captures the shapes it knows; this makes an UNKNOWN shape red by
    # counting instead of invisible by omission. A call-expression heading once
    # produced zero regex matches, so the site was never enumerated and never
    # reached the flunk — the safety net was downstream of the gap. Counting
    # occurrences closes the class, not just that shape: any future argument
    # form the scan cannot capture disagrees with the count and is named here.
    stripped = strip_comments(js)

    occurrences = length(String.split(stripped, "labelledTerm(")) - 1
    definitions = length(String.split(stripped, "function labelledTerm(")) - 1
    enumerated = length(labelled_term_sites(js))

    assert occurrences - definitions == enumerated,
           """
           #{occurrences - definitions} labelledTerm( call sites ship, but the
           argument scan enumerated #{enumerated}. A site the scan cannot
           capture is a label clause (c) never saw — teach @argument the new
           shape (the resolver will then flunk it loudly) rather than leaving
           the site invisible.
           """

    for name <- @generic_card_constructors do
      occurrences = length(String.split(stripped, name <> "(")) - 1

      # The constructor scan matches the function DEFINITION header too — a
      # parameter list is shaped exactly like a call — and that match is benign
      # (its second "argument" is the constructor's own pinned parameter, which
      # resolves to nothing). So the reconciliation counts it on BOTH sides:
      # every occurrence, definition included, must be a span the scan captured.
      scanned =
        ~r/#{name}\(\s*#{@argument}\s*,\s*(#{@argument})\s*[,)]/
        |> Regex.scan(stripped)
        |> length()

      assert occurrences == scanned,
             """
             #{occurrences} #{name}( occurrences ship (definition included), but
             the constructor scan captured #{scanned}. A call whose arguments the
             scan cannot read is a heading clause (c) never resolved.
             """
    end
  end

  test "every iterated front-door vocabulary is authored or membership-filtered", %{js: js} do
    # The resolver reads a `forEach` iteration variable through the producer that
    # built the array, and the two readings it can make are opposites: an
    # AUTHORED literal list contributes its literals (and they are then checked
    # against LABELLED_TERMS), while a LABELLED_TERMS MEMBERSHIP FILTER
    # contributes nothing because it cannot yield an unmapped label.
    #
    # The second reading is the one that could rot into a silencer: if
    # doctrineRunsColumns stopped filtering by membership, the resolver would go
    # on contributing nothing for `name` and the Runs-list front door would paint
    # whatever RUNS_COLUMNS held, unguarded. So both shapes are re-derived from
    # the bundle here rather than assumed.
    assert producer_shape(js, "streamVocabularyTerms") ==
             {:literals, ["hints only", "coalesced"]},
           """
           streamVocabularyTerms no longer returns an authored literal vocabulary,
           so the live-activity front door's `term` cannot be resolved to the words
           it paints. Either it now computes its terms (in which case the resolver
           will FLUNK, which is correct and this pin should be re-derived), or the
           vocabulary changed and this pin is stale.
           """

    assert producer_shape(js, "doctrineRunsColumns") == :membership_filtered,
           """
           doctrineRunsColumns is no longer a LABELLED_TERMS membership filter.

           The resolver contributes NOTHING for the Runs-list front door's `name`
           purely because that filter makes an unmapped label impossible. Without
           it, the front door paints whatever RUNS_COLUMNS holds and clause (c) is
           silent about it — a hole exactly like the h3-only scan's.
           """

    # And the filter really is over RUNS_COLUMNS, which is the array clause (c)'s
    # own totality check reads. If it filtered some other list, the two halves
    # would be guarding different surfaces while reading as one.
    fun = Enum.find(js_functions(js), &(&1.name == "doctrineRunsColumns"))

    assert fun && String.contains?(fun.body, "RUNS_COLUMNS.filter("),
           "doctrineRunsColumns no longer filters RUNS_COLUMNS; clause (c)'s two halves have drifted apart"
  end

  test "clause (c) bites: a new unglossed column and a new unglossed card both go red", %{js: js} do
    # Red proof for the forward guard, on mutated COPIES. This is the clause with
    # no prior coverage anywhere in the wave, so its red proof is the only
    # evidence it is real.

    # 1. A thirteenth Runs column with no glossary entry. Today it would ship as
    #    a plain <th> (runTable branches on hasOwnProperty), joining no list, with
    #    every existing assertion green.
    new_column =
      String.replace(
        js,
        ~s|"Duration", "Latest", "Child after end"]);|,
        ~s|"Duration", "Latest", "Child after end", "Backpressure"]);|,
        global: false
      )

    assert new_column != js, "the RUNS_COLUMNS tail is no longer what the mutation targets"

    columns = runs_columns(new_column)
    assert "Backpressure" in columns, "the mutated constant must actually carry the new column"

    labelled = labelled_labels(new_column) |> Enum.map(&elem(&1, 0)) |> MapSet.new()

    unclassified =
      Enum.reject(columns, &(MapSet.member?(labelled, &1) or &1 in @ordinary_table_nouns))

    assert unclassified == ["Backpressure"],
           """
           A new Runs column with no corpus entry was NOT caught by clause (c).
           The forward guard is not guarding anything.

           Unclassified: #{inspect(unclassified)}
           """

    # 2. A new truth-rail card whose heading is in no mapping table. The card
    #    constructor would throw a MonitorDefect at render; the guard makes it
    #    red statically.
    new_card =
      String.replace(
        js,
        ~s|rail.append(postTerminalCard(run.post_terminal_child_activity, route));|,
        ~s|rail.append(truthCard(route, "Backpressure", "backpressure", null, null));\n    | <>
          ~s|rail.append(postTerminalCard(run.post_terminal_child_activity, route));|,
        global: false
      )

    assert new_card != js, "the rail's last append is no longer what the mutation targets"

    card_labelled = labelled_labels(new_card) |> Enum.map(&elem(&1, 0)) |> MapSet.new()
    unmapped = Enum.reject(card_headings(new_card), &MapSet.member?(card_labelled, &1))

    assert unmapped == ["Backpressure"],
           """
           A new rail card with no corpus entry was NOT caught by clause (c).

           Unmapped headings: #{inspect(unmapped)}
           """

    # 2b. The SECOND card shape, which the `route`-first regex alone could not
    #     see. postTerminalCard does not take its heading as an argument; it
    #     hard-codes it in its own `labelledTerm("h3", …, route)` call. A new
    #     dedicated constructor written in that shape is just as much a rail card
    #     and just as capable of throwing a MonitorDefect at render, so the guard
    #     must be red for it too.
    #
    #     This mutation is what the union exists for: run it against the old
    #     `truthCard|distributionCard|labeledTruthCard` regex and `unmapped` comes
    #     back [], a false green over a card that ships.
    dedicated_card =
      String.replace(
        js,
        ~s|  function postTerminalCard(activity, route) {|,
        ~s|  function backpressureCard(backpressure, route) {\n| <>
          ~s|    const card = el("section", "truth-card");\n| <>
          ~s|    card.append(labelledTerm("h3", "Backpressure", route));\n| <>
          ~s|    return card;\n| <>
          ~s|  }\n\n| <>
          ~s|  function postTerminalCard(activity, route) {|,
        global: false
      )

    assert dedicated_card != js, "postTerminalCard's definition is no longer what this mutation targets"

    dedicated_card =
      String.replace(
        dedicated_card,
        ~s|rail.append(postTerminalCard(run.post_terminal_child_activity, route));|,
        ~s|rail.append(backpressureCard(run.backpressure, route));\n    | <>
          ~s|rail.append(postTerminalCard(run.post_terminal_child_activity, route));|,
        global: false
      )

    assert String.contains?(dedicated_card, "rail.append(backpressureCard("),
           "the dedicated-constructor card must actually be rail-appended for this proof to describe a shipped card"

    dedicated_labelled = labelled_labels(dedicated_card) |> Enum.map(&elem(&1, 0)) |> MapSet.new()

    dedicated_unmapped =
      Enum.reject(card_headings(dedicated_card), &MapSet.member?(dedicated_labelled, &1))

    assert dedicated_unmapped == ["Backpressure"],
           """
           A new rail card in postTerminalCard's shape — a dedicated constructor
           that labels its OWN heading — was NOT caught by clause (c).

           This is the shape the constructor-name regex is blind to. If this
           assertion is empty, card_headings/1 has stopped scanning
           `labelledTerm("h3", "<literal>"` call sites and the guard once again
           only sees cards whose heading arrives as an argument after `route`.

           Unmapped headings: #{inspect(dedicated_unmapped)}
           """

    # 2c. The same dedicated constructor, one step less literal: it binds its
    #     heading to a local before labelling it. This is the shape a literal-only
    #     scan cannot see AT ALL — neither regex matches — so the card shipped and
    #     the inventory came back short with no assertion noticing. `label` is the
    #     name chosen deliberately: it is what both shipped generic constructors
    #     call their heading parameter and what the sibling dotted-label contract
    #     allows, so it is the name a new card author copies.
    variable_card =
      String.replace(
        js,
        ~s|  function postTerminalCard(activity, route) {|,
        ~s|  function backpressureCard(backpressure, route) {\n| <>
          ~s|    const card = el("section", "truth-card");\n| <>
          ~s|    const label = "Backpressure";\n| <>
          ~s|    card.append(labelledTerm("h3", label, route));\n| <>
          ~s|    return card;\n| <>
          ~s|  }\n\n| <>
          ~s|  function postTerminalCard(activity, route) {|,
        global: false
      )

    assert variable_card != js,
           "postTerminalCard's definition is no longer what this mutation targets"

    variable_card =
      String.replace(
        variable_card,
        ~s|rail.append(postTerminalCard(run.post_terminal_child_activity, route));|,
        ~s|rail.append(backpressureCard(run.backpressure, route));\n    | <>
          ~s|rail.append(postTerminalCard(run.post_terminal_child_activity, route));|,
        global: false
      )

    assert String.contains?(variable_card, "rail.append(backpressureCard("),
           "the variable-heading card must actually be rail-appended for this proof to describe a shipped card"

    variable_labelled = labelled_labels(variable_card) |> Enum.map(&elem(&1, 0)) |> MapSet.new()

    variable_unmapped =
      Enum.reject(card_headings(variable_card), &MapSet.member?(variable_labelled, &1))

    assert variable_unmapped == ["Backpressure"],
           """
           A new rail card whose heading is a LOCAL rather than a literal argument
           was NOT caught by clause (c).

           If this assertion comes back empty, card_headings/1 has gone back to
           matching only `labelledTerm("h3", "<literal>"`, and a card written as
           `const label = "…"; card.append(labelledTerm("h3", label, route))`
           renders an unmapped doctrine heading with every source-tier assertion
           green. That is not a declared blind spot — the moduledoc claims clause
           (c) is red for a new rail card — so the claim and the code must not
           drift apart here.

           Unmapped headings: #{inspect(variable_unmapped)}
           """

    # 2d. The same rail card through a GENERIC constructor whose first argument
    #     is not spelled `route`. This is the shape that defeated BOTH halves of
    #     the union at once, and it defeated them by a mechanism worth naming:
    #     the constructor regex required the literal token `route`, so it did not
    #     match; the affordance half then reached `labelledTerm("h3", label,
    #     route)` inside labeledTruthCard, where `label` is a PARAMETER, and
    #     contributed nothing on the documented grounds that "its actual values
    #     are read at the route-first call sites" — which is exactly what this
    #     call site is not. Each half deferred to the other and the card shipped
    #     unmapped with clause (c) green.
    #
    #     Aliasing a route is not exotic. `const r = route` is what a local
    #     helper or a destructuring naturally produces, and the card would throw
    #     a MonitorDefect at first render, which is the failure clause (c) exists
    #     to make static.
    aliased_card =
      String.replace(
        js,
        ~s|rail.append(postTerminalCard(run.post_terminal_child_activity, route));|,
        ~s|const r = route;\n    rail.append(truthCard(r, "Backpressure", "backpressure", null, null));\n    | <>
          ~s|rail.append(postTerminalCard(run.post_terminal_child_activity, route));|,
        global: false
      )

    assert aliased_card != js, "the rail's last append is no longer what this mutation targets"

    aliased_labelled = labelled_labels(aliased_card) |> Enum.map(&elem(&1, 0)) |> MapSet.new()

    aliased_unmapped =
      Enum.reject(card_headings(aliased_card), &MapSet.member?(aliased_labelled, &1))

    assert aliased_unmapped == ["Backpressure"],
           """
           A new rail card added through a generic constructor whose first
           argument is not spelled `route` was NOT caught by clause (c).

           If this comes back empty, the constructor scan has gone back to
           requiring the literal token `route` as its first argument, and the
           affordance half is once again skipping the constructor's `label`
           parameter on the assumption that the constructor half read it. Neither
           half sees this card, and the moduledoc's totality claim is false.

           Unmapped headings: #{inspect(aliased_unmapped)}
           """

    # 2e. The FRONT-DOOR shape: an unmapped doctrine term added to the
    #     live-activity sentence, which paints through `labelledTerm("span", …)`
    #     rather than through any card constructor. The scan was anchored to
    #     `"h3"`, so all three shipped front-door sites — and anything added
    #     beside them — sat outside the inventory while the moduledoc declared
    #     the affordance surface as the denominator. The label throws
    #     labelled_term_unmapped at labelledTermSlug on the first screen render.
    front_door_card =
      String.replace(
        js,
        ~s|line.append(labelledTerm("span", "last successful authoritative refetch", route, "front-door"));|,
        ~s|line.append(labelledTerm("span", "last successful authoritative refetch", route, "front-door"));\n    | <>
          ~s|line.append(labelledTerm("span", "Backpressure", route, "front-door"));|,
        global: false
      )

    assert front_door_card != js, "the live-activity front-door line has moved; re-anchor this mutation"

    front_door_labelled = labelled_labels(front_door_card) |> Enum.map(&elem(&1, 0)) |> MapSet.new()

    front_door_unmapped =
      Enum.reject(card_headings(front_door_card), &MapSet.member?(front_door_labelled, &1))

    assert front_door_unmapped == ["Backpressure"],
           """
           A new unmapped doctrine term on the live-activity front door was NOT
           caught by clause (c).

           If this comes back empty, the affordance scan has been re-anchored to
           `labelledTerm("h3", …)` and the `"span"` half of the dotted-underline
           promise is outside the inventory again — while this file's moduledoc
           goes on defining its denominator as the whole affordance surface.

           Unmapped headings: #{inspect(front_door_unmapped)}
           """

    # 2f. The CALL-EXPRESSION heading: `labelledTerm("h3", headingFor(x), route)`.
    #     The argument regex's paren-free branch produced ZERO matches for this
    #     shape, so the site was never ENUMERATED and never reached the flunk —
    #     the safety net was downstream of the gap, and this exact mutant left
    #     the whole suite green while an unmapped doctrine card shipped. The
    #     shape is now captured whole and the resolver REFUSES it loudly; the
    #     arithmetic reconciliation makes any future uncaptured shape red by
    #     counting.
    call_expression_card =
      String.replace(
        js,
        ~s|  function postTerminalCard(activity, route) {|,
        ~s|  function backpressureCard(backpressure, route) {\n| <>
          ~s|    const card = el("section", "truth-card");\n| <>
          ~s|    card.append(labelledTerm("h3", headingFor(backpressure), route));\n| <>
          ~s|    return card;\n| <>
          ~s|  }\n\n| <>
          ~s|  function postTerminalCard(activity, route) {|,
        global: false
      )

    assert call_expression_card != js,
           "postTerminalCard's definition is no longer what this mutation targets"

    assert_raise ExUnit.AssertionError, ~r/cannot be resolved/, fn ->
      card_headings(call_expression_card)
    end

    # 2g. The PARAMETER-HEADING constructor that is NOT pinned. Its call sites
    #     are unread (its name is not in @generic_card_constructors), and its
    #     parameter used to contribute nothing — the general form of 2d's
    #     each-half-defers-to-the-other defect. The parameter branch is now
    #     restricted to the pinned names, so an unpinned constructor's heading
    #     parameter flunks until the constructor is pinned and earns its pin.
    parameter_card =
      String.replace(
        js,
        ~s|  function postTerminalCard(activity, route) {|,
        ~s|  function backpressureCard(label, route) {\n| <>
          ~s|    const card = el("section", "truth-card");\n| <>
          ~s|    card.append(labelledTerm("h3", label, route));\n| <>
          ~s|    return card;\n| <>
          ~s|  }\n\n| <>
          ~s|  function postTerminalCard(activity, route) {|,
        global: false
      )

    assert parameter_card != js,
           "postTerminalCard's definition is no longer what this mutation targets"

    parameter_card =
      String.replace(
        parameter_card,
        ~s|rail.append(postTerminalCard(run.post_terminal_child_activity, route));|,
        ~s|rail.append(backpressureCard("Backpressure", route));\n    | <>
          ~s|rail.append(postTerminalCard(run.post_terminal_child_activity, route));|,
        global: false
      )

    assert String.contains?(parameter_card, "rail.append(backpressureCard("),
           "the parameter-heading card must actually be rail-appended for this proof to describe a shipped card"

    assert_raise ExUnit.AssertionError, ~r/cannot be resolved/, fn ->
      card_headings(parameter_card)
    end

    # 2h. The COMMENTED DECOY: dead prose must neither replace an inventory nor
    #     enter it. body_between/2 takes the FIRST occurrence of its opening
    #     delimiter, so before the clause (c) readers stripped comments, a
    #     commented-out declaration above the real one REPLACED the whole
    #     inventory — a phantom one-column list passed totality while a
    #     genuinely unglossed column shipped beneath it.
    column_decoy =
      String.replace(
        js,
        ~s|  const RUNS_COLUMNS = Object.freeze([|,
        ~s|  // const RUNS_COLUMNS = Object.freeze(["Run"]);\n  const RUNS_COLUMNS = Object.freeze([|,
        global: false
      )

    assert column_decoy != js, "RUNS_COLUMNS declaration moved; re-anchor this mutation"

    assert runs_columns(column_decoy) == runs_columns(js),
           "a commented-out RUNS_COLUMNS decoy changed the inventory: clause (c) is reading dead prose"

    labelled_decoy =
      String.replace(
        js,
        ~s|  const LABELLED_TERMS = Object.freeze({|,
        ~s|  // const LABELLED_TERMS = Object.freeze({"Ghost": "ghost"});\n  const LABELLED_TERMS = Object.freeze({|,
        global: false
      )

    assert labelled_decoy != js, "LABELLED_TERMS declaration moved; re-anchor this mutation"

    assert labelled_labels(labelled_decoy) == labelled_labels(js),
           "a commented-out LABELLED_TERMS decoy changed the mapping table: clause (c) is reading dead prose"

    # 2i. The WIDENED membership filter (adversarial review, #553): the producer
    #     still MENTIONS the membership predicate, so the old substring
    #     classification read it as the safe shape while it prepended an
    #     unmapped doctrine term — which the Runs-list front door then painted,
    #     throwing labelled_term_unmapped at first render with every pin green.
    #     Structural classification refuses the widened body; the resolver falls
    #     through to the literal reading and the smuggled term surfaces.
    widened_filter =
      String.replace(
        js,
        ~s|    return RUNS_COLUMNS.filter(function (name) { return Object.prototype.hasOwnProperty.call(LABELLED_TERMS, name); });|,
        ~s|    return ["Backpressure"].concat(RUNS_COLUMNS.filter(function (name) { return Object.prototype.hasOwnProperty.call(LABELLED_TERMS, name); }));|,
        global: false
      )

    assert widened_filter != js,
           "doctrineRunsColumns' body is no longer what this mutation targets; re-anchor 2i"

    refute producer_shape(widened_filter, "doctrineRunsColumns") == :membership_filtered,
           """
           A doctrineRunsColumns widened with ["Backpressure"].concat(...) still
           classifies as :membership_filtered. The classification has regressed
           to a substring test, and the resolver will contribute nothing for a
           front door that paints an unmapped label at first render.
           """

    widened_labelled = labelled_labels(widened_filter) |> Enum.map(&elem(&1, 0)) |> MapSet.new()

    widened_unmapped =
      Enum.reject(card_headings(widened_filter), &MapSet.member?(widened_labelled, &1))

    assert "Backpressure" in widened_unmapped,
           """
           The widened filter's smuggled term did not surface as unmapped.
           card_headings/1 must read a non-membership-filtered producer's array
           literals so the term the front door would paint is checked.

           Unmapped headings: #{inspect(widened_unmapped)}
           """

    # 3. The mirror case the acceptance criteria name: a LABELLED_TERMS entry
    #    added WITHOUT a corpus slug. This is a dead link — the label paints with
    #    its dotted underline and the anchor lands on the manual's unknown-slug
    #    page.
    #
    #    Clause (a)'s executed seam (checkLabelledTerms) already refuses this and
    #    carries its own red proof (labelled_term_dead_link). It is re-proven here
    #    at the SOURCE tier so this file's bidirectional claim is self-contained
    #    evidence: the source-text side must be red too, or a reader of this file
    #    is taking clause (a) on trust.
    dead_link =
      String.replace(
        js,
        ~s|"Runtime gate": "runtime-gate",|,
        ~s|"Runtime gate": "runtime-gate",\n    "Backpressure": "backpressure",|,
        global: false
      )

    assert dead_link != js

    terms = Jason.decode!(File.read!(@terms_json))
    corpus_slugs = MapSet.new(terms, & &1["slug"])

    dangling =
      dead_link
      |> labelled_labels()
      |> Enum.reject(fn {_label, slug} -> MapSet.member?(corpus_slugs, slug) end)

    assert dangling == [{"Backpressure", "backpressure"}],
           """
           A LABELLED_TERMS mapping to a slug the corpus does not carry was not
           detected at the source tier.

           Dangling: #{inspect(dangling)}
           """

    # And the real tree has no dangling mapping, so the check is a predicate.
    assert js |> labelled_labels() |> Enum.reject(fn {_l, s} -> MapSet.member?(corpus_slugs, s) end) == []
  end

  # ── Clauses consumed, not duplicated ───────────────────────────────────────

  test "the executed clause (a) seam is still wired, with its result-key contract intact" do
    # Clause (a) is EXECUTED by checkLabelledTerms in node:vm and is not
    # re-implemented here. What this file must guarantee is that it is still
    # PLUGGED IN: a bidirectional predicate whose forward half was silently
    # unplugged is a predicate this moduledoc lies about.
    #
    # Pinned by NAME, not by line number, and by the result keys the seam test
    # asserts on, so the two files cannot drift into both assuming the other
    # covers clause (a).
    checker = File.read!(@seam_check)
    seam_test = File.read!(@seam_test)

    assert checker =~ "function checkLabelledTerms(seam)",
           "clause (a)'s executed check is gone; this file's moduledoc claims it covers the forward direction"

    assert checker =~ "labelled_term_dead_link",
           "the dead-link refusal is clause (a)'s core property"

    assert checker =~ "labelled_terms: labelledTerms",
           "the checker must still publish the labelled_terms result key this file defers to"

    assert seam_test =~ ~s|result["labelled_terms"]|,
           "the seam test must still assert on the labelled_terms result key"

    # The counts are the seam test's business, not this file's; what is pinned
    # here is that a non-trivial count is asserted at all, so clause (a) cannot
    # be reduced to a shape check while this file defers to it.
    assert seam_test =~ ~s|"labels" => 16|
    assert seam_test =~ ~s|"slugs" => 12|

    # And the honest-degradation inventory this arc consumes as DATA is still
    # published and still proven to partition the corpus.
    assert checker =~ "function checkManualRunInventory(seam)"
    assert checker =~ "manual_inventory_not_a_partition"
    assert seam_test =~ ~s|result["manual_run_inventory"]|
  end

  test "the drift assertion is still owned by the delivery contract, and still compares three copies" do
    # The generated-artifact-matches-checked-in-artifact clause the task names is
    # fully owned by glossary_delivery_contract_test.exs. It is referenced rather
    # than re-implemented: two extractors over one generated region is two things
    # to keep in step, and the sibling's is total (it accounts for every byte of
    # the region, both sides of the payload).
    #
    # What is pinned here is that the ownership is real, so this file's claim to
    # cover "no hand-edit rot" is not resting on a test that stopped comparing.
    delivery = File.read!(@delivery_test)

    assert delivery =~ "def extract_glossary(js)",
           "the drift extractor is gone from the delivery contract"

    assert delivery =~ "the generated block does not drift from the checked-in terms.json",
           "the app.js-vs-fixture drift assertion is gone"

    assert delivery =~ "the handoff's terms.json has not rotted away from the monitor fixture",
           "the third copy (research/terms.json) is no longer compared, so a hand-edit there is invisible"

    assert delivery =~ "the drift check bites: a mutated copy of the bundle goes red",
           "the drift assertion's own red proof is gone"

    # And this file reads the SAME fixture the drift test compares against, so a
    # corpus that drifted would be caught there and clause (b) here is asserting
    # over the same bytes the bundle ships.
    assert File.exists?(@terms_json)
  end

  test "the generated artifact this file reads is byte-identical to the one the bundle ships", %{js: js} do
    # A minimal, non-duplicating extension of the drift clause: the sibling test
    # proves the app.js block decodes equal to the fixture. This asserts the
    # narrower property THIS file depends on — that the slugs and surface strings
    # clause (b) iterates are the ones actually inside the bundle — so a corpus
    # swapped under this test cannot make clause (b) green by describing a
    # different UI.
    #
    # Deliberately a SUBSET comparison on (slug, surface_string) pairs rather
    # than a second full extractor: the total byte-level ownership stays with
    # glossary_delivery_contract_test.exs.
    {:ok, generated_region} = generated_block(js)

    # The point of the region is that it is NARROWER than the bundle. Pinned
    # because the obvious spelling of this cut (subtracting `outside` from js)
    # is a no-op that yields the whole file and scans the UI half too, which
    # would let a stray `"surface_string": ...` byte pattern anywhere in app.js
    # satisfy an entry the shipped block no longer carries.
    assert byte_size(generated_region) < byte_size(js),
           "the generated region is not a strict slice of the bundle — the cut degraded into a no-op"

    terms = Jason.decode!(File.read!(@terms_json))

    for entry <- terms do
      assert String.contains?(generated_region, ~s|"slug": #{Jason.encode!(entry["slug"])}|),
             "the bundle's generated block does not carry the slug #{inspect(entry["slug"])} the fixture claims"

      assert String.contains?(
               generated_region,
               ~s|"surface_string": #{Jason.encode!(entry["surface_string"])}|
             ),
             """
             the bundle's generated block does not carry the surface string
             #{inspect(entry["surface_string"])} that clause (b) is asserting on for
             #{inspect(entry["slug"])}
             """
    end
  end

  # ── The duplicate surface string, pinned ───────────────────────────────────

  test "keying by slug is load-bearing: one surface string belongs to two entries", %{terms: terms} do
    by_surface = Enum.group_by(terms, & &1["surface_string"])
    duplicated = for {surface, entries} <- by_surface, length(entries) > 1, do: {surface, Enum.map(entries, & &1["slug"])}

    assert duplicated == [{"SSE connected · hints only · coalesced", ["hints-only", "coalesced"]}],
           """
           The known duplicate surface string changed shape: #{inspect(duplicated)}

           Everything in this file is keyed by SLUG for this reason. A map keyed
           by surface string would hold 55 of 56 entries and clause (b) would stop
           covering one of them without any assertion changing.
           """

    # And the corpus really is slug-unique, so slug is a safe key.
    slugs = Enum.map(terms, & &1["slug"])
    assert length(Enum.uniq(slugs)) == length(slugs)
  end

  # ── The non-coverage statement, asserted rather than only prosed ───────────

  test "the moduledoc's non-coverage statement is present and specific" do
    doc = @moduledoc

    for claim <- [
          "What this test does NOT catch",
          "SEMANTIC rot",
          "DEFINITION QUALITY",
          "code_citation` line pins",
          "RUNTIME REACHABILITY",
          "What clause (c) does NOT catch"
        ] do
      assert String.contains?(doc, claim),
             """
             The moduledoc's explicit non-coverage statement lost #{inspect(claim)}.

             A test that states a denominator without stating its blind spots
             invites the reader to believe it covers more than it does, which is
             this arc's own defect class (asserting what is not so) reappearing in
             the guard against it.
             """
    end

    # The justified denominator itself must stay stated.
    assert String.contains?(doc, "AFFORDANCE SURFACE")
    assert String.contains?(doc, ":slot_template")
    assert String.contains?(doc, ":server_authored")
  end
end
