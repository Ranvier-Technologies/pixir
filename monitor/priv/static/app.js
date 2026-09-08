"use strict";

(function () {
  const LIMITS = Object.freeze({runs: 50, units: 100, attempts: 20, evidence: 100, field: 32768, query: 256});
  const FILTER_VOCABULARIES = Object.freeze({
    strategy: ["workflow", "subagents", "unknown"],
    execution: ["planned", "queued", "running", "completed", "partial", "failed", "timed_out", "cancelled", "detached", "closed", "held", "unknown"],
    liveness: ["unobserved", "not_applicable"],
    source: ["live", "reconstructed", "mixed"],
    attention: ["yes", "no"]
  });
  // Attention honesty contract: labels state the parent-observed evidence basis.
  // No label ever claims global health, and no synthetic unknown bucket exists
  // for the attention dimension anywhere in this bundle.
  const FILTER_LABELS = Object.freeze({
    attention: Object.freeze({
      label: "Attention (parent-observed)",
      options: Object.freeze({yes: "Parent-observed attention", no: "No parent-observed attention"})
    })
  });
  // Attention pagination contract: while the bounded inventory keeps the attention
  // group at or below this declared cap, every attention row is rendered. Above the
  // cap the DOM stays bounded with exact shown/total counts and an explicit
  // show-next control. Attention is never hidden behind healthy-row pagination.
  const ATTENTION_RENDER_ALL_CAP = 200;
  function attentionRowBudget(total, page, cap) {
    const bound = Number.isSafeInteger(cap) && cap > 0 ? cap : ATTENTION_RENDER_ALL_CAP;
    const safeTotal = Number.isSafeInteger(total) && total > 0 ? total : 0;
    const safePage = Number.isSafeInteger(page) && page > 0 ? page : 1;
    if (safeTotal <= bound) return safeTotal;
    return Math.min(safeTotal, safePage * LIMITS.runs);
  }
  const SORT_VOCABULARY = Object.freeze(["recency_desc", "recency_asc", "duration_desc", "duration_asc"]);
  const DEFAULT_SORT = "recency_desc";
  const SORT_LABELS = Object.freeze({
    recency_desc: "Newest activity first (default)",
    recency_asc: "Oldest activity first",
    duration_desc: "Longest duration first",
    duration_asc: "Shortest duration first"
  });
  const COMPLETENESS_RANK = Object.freeze({complete: 0, incomplete: 1, unknown: 2, malformed: 3});
  const MARKER_TONES = new Set([
    "planned", "queued", "running", "completed", "partial", "failed", "timed_out", "cancelled", "detached", "closed", "held", "unknown",
    "live", "externally_owned", "stale_handle", "owner_unavailable", "unobserved", "not_applicable", "reconstructed", "mixed", "workflow", "subagents",
    "needs_orchestrator", "checkpoint_ready", "ready", "stop", "needs_review", "pass", "invalid", "workspace_applied", "indeterminate", "not_applied", "current",
    // #447 post-terminal child activity. "observed" reads as attention (the run
    // is narratively incomplete), "undetermined" as attention (evidence is
    // missing, and missing evidence is never a clean bill), "none" as muted.
    "observed", "none", "undetermined"
  ]);
  // Advisory display contract (#441). The bucket order is the frozen display
  // severity ordering stop > needs_review > pass > unknown, with invalid counted
  // separately and never given an invented verdict. The alias map renames only
  // the human-readable label of the `unknown` bucket: a model advisory was
  // present but its verdict was not classifiable, which is a different fact from
  // "no advisory". Absence never reaches a bucket at all — the
  // `advisory.present === true` guard in each count reader excludes it. Tone and
  // severity keep reading the raw token, so this alias changes no classification.
  const ADVISORY_BUCKET_ORDER = Object.freeze(["stop", "needs_review", "pass", "unknown", "invalid"]);
  const ADVISORY_DISPLAY_ALIASES = Object.freeze({unknown: "unclassified verdict"});
  // The GATE and ATTENTION display contracts, hoisted beside the advisory one
  // for the same reason it exists: these bucket orders and alias maps are WORDS
  // ON SCREEN, and more than one surface renders each dimension. They were bare
  // literals repeated at each call site (and, at the cluster row, an omitted
  // alias slot), which is a parallel copy table by another name: renaming
  // "ready" or reordering the buckets in one place and not the others would
  // have one surface explaining a vocabulary another no longer uses. One frozen
  // definition each, passed by reference, so a change is a change everywhere or
  // it is a compile-visible divergence.
  //
  // WHAT THESE MAPS GOVERN IS DISTRIBUTIONS, and the scope of that claim is
  // load-bearing enough to state rather than leave to inference. An alias
  // renames a BUCKET IN A COUNT: "3 ready" on the runs-list gate cell, the
  // detail rail's Dependency-gate card, the semantic-zoom cluster row, and the
  // instrument manual's ON THIS RUN part wherever it folds a run. Every one of
  // those call sites takes the constant, and the manual_pane_contract pins them
  // by occurrence count so a new literal is as visible as a surviving one.
  //
  // Naming ONE ENTITY'S STATE is a different job and deliberately does NOT come
  // through here. The Unit Inspector's "Runtime gate" card renders
  // `checkpoint_ready` as "checkpoint ready" via unitGateLabel, and the manual's
  // ON THIS RUN part at UNIT scope calls that same unitGateLabel — the card's
  // own path, shared by reference — precisely so the pane prints the word the
  // card inches away prints. Routing the pane through GATE_DISPLAY_ALIASES
  // there instead is what put two words on one gate value, on the one route
  // where the runtime-gate term's surface string appears. So the invariant is
  // not "every gate rendering passes through this map"; it is that each of the
  // two jobs has exactly ONE definition (this map for counts, unitGateLabel for
  // a unit's state) and every surface doing that job calls it.
  //
  // ATTENTION has no such split — no surface labels one unit's attention state
  // through a card — but it has the absence rule instead: an absent record is
  // excluded from the counts by unitAttentionBucket, never bucketed as "no", so
  // these two aliases only ever name units the projection actually spoke about.
  const GATE_BUCKET_ORDER = Object.freeze(["needs_orchestrator", "failed", "held", "partial", "unknown", "checkpoint_ready", "not_applicable"]);
  const GATE_DISPLAY_ALIASES = Object.freeze({checkpoint_ready: "ready"});
  const ATTENTION_BUCKET_ORDER = Object.freeze(["yes", "no"]);
  const ATTENTION_DISPLAY_ALIASES = Object.freeze({yes: "required", no: "not required"});
  // The BASIS strings the run-scoped distribution cards attribute their counts
  // to, and the phrase a distribution with no populated bucket shows. They are
  // hoisted for exactly the reason the orders and alias maps above are: they are
  // words on screen, and two surfaces now print each of them — the truth rail's
  // own card and the instrument manual's ON THIS RUN part explaining that card.
  // Held as literals at both, they were a parallel copy table for PROVENANCE
  // words: renaming the rail's basis and updating only the rail's own pin left
  // the pane attributing a stale provenance to a live reading, inches away, with
  // nothing failing. A basis is a claim about where a number came from, so a
  // divergence here is a false attribution rather than a cosmetic drift.
  const GATE_FOLD_BASIS = "unit checkpoint fold";
  const ADVISORY_FOLD_BASIS = "model declared";
  const ATTENTION_FOLD_BASIS = "parent log";
  // What the pane says about a unit whose projection carries no attention
  // record at all. It is NOT one of the two alias values: absence is a third
  // case, and reporting it as `not required` asserts a negative the projection
  // never made. Frozen beside the basis it deliberately does NOT claim.
  // The copy deliberately does NOT quote the two alias words back at the
  // reader, even to deny them: the executed guard forbids the phrase "not
  // required" anywhere in an absent reading, and a mention inside the sentence
  // is indistinguishable from a claim to anything reading the rendered string —
  // an operator skimming included.
  const MANUAL_ATTENTION_ABSENT = "No attention record on this unit — the projection carries none here, so this pane reads no attention value for it either way.";
  const EMPTY_DISTRIBUTION_PHRASE = "0 observed";
  // Onboarding glossary delivery (#551). The 56-term corpus ships INLINE, as the
  // generated frozen literal below, rather than as a served /assets/glossary.json.
  // Inline needs no new route, no CSP or bootstrap change, and no await: the
  // Instrument Manual pane can render its index at first paint. The block is
  // emitted by gen_terms.py from the same build() that writes
  // .docs/design-handoffs/pixir-monitor-onboarding/research/terms.json and
  // monitor/test/fixtures/glossary_terms.json. glossary_delivery_contract_test
  // compares this block against the monitor fixture, and the fixture against
  // terms.json, so no one of the three copies can rot alone.
  // NEVER hand-edit between the markers: regenerate with
  // `uv run python gen_terms.py .` from that research/ directory.
  // GENERATED BEGIN pixir-monitor-glossary -- gen_terms.py; do not hand-edit.
  // Delivered INLINE rather than as a served asset: see gen_terms.py's
  // delivery-decision note. Regenerate with `uv run python gen_terms.py .`
  // from .docs/design-handoffs/pixir-monitor-onboarding/research/.
  const GLOSSARY = Object.freeze([
    {
      "term": "Liveness",
      "surface_string": "Liveness",
      "code_citation": "monitor/priv/static/app.js:1185 (truthRail), :968 (list column); vocabulary in monitor/priv/presenter/projection-v1.md:181-184",
      "plain_definition": "Whether anything is running right now, and how that was observed. A separate dimension from what the durable Log says happened.",
      "confused_with": "Execution. Execution is the durable record of the run's state; Liveness is a volatile observation about this instant. A terminal run has no Liveness.",
      "slug": "liveness",
      "concern": {
        "key": "dimensions",
        "title": "The truth dimensions",
        "blurb": "The monitor never folds these into one status. Each answers a different question from a different evidence class, and a good-looking value in one says nothing about the others."
      }
    },
    {
      "term": "Execution",
      "surface_string": "Execution",
      "code_citation": "monitor/priv/static/app.js:1184 (truthRail), :968 (list column); vocabulary in monitor/priv/presenter/projection-v1.md:176-179",
      "plain_definition": "The run's canonical state folded from the durable Log: planned, queued, running, completed, partial, failed, timed_out, and so on.",
      "confused_with": "Liveness. A live process never upgrades Execution, and a volatile 'completed' before a durable terminal Event leaves Execution at running.",
      "slug": "execution",
      "concern": {
        "key": "dimensions",
        "title": "The truth dimensions",
        "blurb": "The monitor never folds these into one status. Each answers a different question from a different evidence class, and a good-looking value in one says nothing about the others."
      }
    },
    {
      "term": "Dependency gate",
      "surface_string": "Dependency gate",
      "code_citation": "monitor/priv/static/app.js:1188 (truthRail card), :1409 (cluster row), :997 (list Gate column); vocabulary in monitor/priv/presenter/projection-v1.md:447-456",
      "plain_definition": "The runtime's own answer to whether dependent Workflow steps may proceed. Only checkpoint_ready is dependent-safe.",
      "confused_with": "Model advisory. The gate is the runtime's decision; the advisory is a model's opinion and cannot change it. The Unit Inspector labels this same dimension 'Runtime gate' (app.js:2078).",
      "slug": "dependency-gate",
      "concern": {
        "key": "dimensions",
        "title": "The truth dimensions",
        "blurb": "The monitor never folds these into one status. Each answers a different question from a different evidence class, and a good-looking value in one says nothing about the others."
      }
    },
    {
      "term": "Runtime gate",
      "surface_string": "Runtime gate",
      "code_citation": "monitor/priv/static/app.js:2078 (Unit Inspector truthCard over unit.gate); rail label for the same dimension at :1188; vocabulary in monitor/priv/presenter/projection-v1.md:447-456",
      "plain_definition": "The Unit Inspector's label for the runtime's own gate decision on one unit. Same dimension the Runs rail labels Dependency gate.",
      "confused_with": "Dependency gate. One dimension, two labels: the rail says 'Dependency gate', the Unit Inspector says 'Runtime gate'. Also Declared gate, which is the model's advisory claim and never moves this value.",
      "slug": "runtime-gate",
      "concern": {
        "key": "dimensions",
        "title": "The truth dimensions",
        "blurb": "The monitor never folds these into one status. Each answers a different question from a different evidence class, and a good-looking value in one says nothing about the others."
      }
    },
    {
      "term": "Declared gate",
      "surface_string": "Declared gate: <state>",
      "code_citation": "monitor/priv/static/app.js:2078 (Model advisory truthCard note over advisory.declared_gate); contract monitor/priv/presenter/projection-v1.md:501 and :519-522",
      "plain_definition": "The checkpoint status the model declared about its own work. Advisory only: it never moves the runtime gate.",
      "confused_with": "Runtime gate and Dependency gate, which are the runtime's own decision. When declared_gate differs from gate.state, v1 adds the advisory_gate_disagreement limitation and shows both values rather than resolving them.",
      "slug": "declared-gate",
      "concern": {
        "key": "dimensions",
        "title": "The truth dimensions",
        "blurb": "The monitor never folds these into one status. Each answers a different question from a different evidence class, and a good-looking value in one says nothing about the others."
      }
    },
    {
      "term": "Model advisory",
      "surface_string": "Model advisory",
      "code_citation": "monitor/priv/static/app.js:1189 (truthRail card, 'Advisory does not control the runtime gate.'), :1275, :2079; contract monitor/priv/presenter/projection-v1.md:493-522",
      "plain_definition": "A verdict a model wrote about its own work: stop, needs_review, pass, or unclassified. Advisory only, never a runtime control.",
      "confused_with": "Dependency gate. A run can be gate checkpoint_ready while its advisory says stop; that disagreement is shown, not resolved. The advisory's own checkpoint claim is the Declared gate.",
      "slug": "model-advisory",
      "concern": {
        "key": "dimensions",
        "title": "The truth dimensions",
        "blurb": "The monitor never folds these into one status. Each answers a different question from a different evidence class, and a good-looking value in one says nothing about the others."
      }
    },
    {
      "term": "Source (run-scoped)",
      "surface_string": "Source (run-scoped)",
      "code_citation": "monitor/priv/static/app.js:1190 (truthRail card), :1443 (semantic zoom line); modes in monitor/priv/presenter/projection-v1.md:68-77",
      "plain_definition": "Which evidence class this projection rests on: reconstructed, mixed, or live, plus its durable origin and freshness.",
      "confused_with": "Liveness. Source describes the evidence the view was built from; Liveness describes the process. Source is run-scoped, never per unit.",
      "slug": "source-run-scoped",
      "concern": {
        "key": "dimensions",
        "title": "The truth dimensions",
        "blurb": "The monitor never folds these into one status. Each answers a different question from a different evidence class, and a good-looking value in one says nothing about the others."
      }
    },
    {
      "term": "Attention",
      "surface_string": "Attention (parent-observed)",
      "code_citation": "monitor/priv/static/app.js:1192 (truthRail card), :17 (filter label), :1676 (fan-out region); reason registry monitor/priv/presenter/projection-v1.md:458-491",
      "plain_definition": "Units whose parent Log evidence gives a named reason to look: failed execution, an advisory stop, a stale handle, missing evidence.",
      "confused_with": "A health score. Attention is a count of parent-observed reasons, not a severity grade, and its absence is not a clean bill of health.",
      "slug": "attention",
      "concern": {
        "key": "dimensions",
        "title": "The truth dimensions",
        "blurb": "The monitor never folds these into one status. Each answers a different question from a different evidence class, and a good-looking value in one says nothing about the others."
      }
    },
    {
      "term": "Child after end",
      "surface_string": "Child after end",
      "code_citation": "monitor/priv/static/app.js:968 (list column), :1208 ('Child activity after end' card); contract monitor/priv/presenter/projection-v1.md:199-262",
      "plain_definition": "Child Log writes recorded strictly after the parent run hit its terminal boundary. It reports; it never reclassifies the run.",
      "confused_with": "Liveness. A child Log proves past writes, never a reachable process, so this can never make a run read as live or reopen it.",
      "slug": "child-after-end",
      "concern": {
        "key": "dimensions",
        "title": "The truth dimensions",
        "blurb": "The monitor never folds these into one status. Each answers a different question from a different evidence class, and a good-looking value in one says nothing about the others."
      }
    },
    {
      "term": "Mutation",
      "surface_string": "Mutation",
      "code_citation": "monitor/priv/static/app.js:968 (list column), :1226 ('Mutation observation' panel); status vocabulary monitor/priv/presenter/projection-v1.md:563-575",
      "plain_definition": "What the run did to files: read_only, workspace_applied, isolated_only, partial, indeterminate, not_applied, or unknown.",
      "confused_with": "Success. A denied write is not a mutation, and an empty observed-path list never proves that nothing was written.",
      "slug": "mutation",
      "concern": {
        "key": "dimensions",
        "title": "The truth dimensions",
        "blurb": "The monitor never folds these into one status. Each answers a different question from a different evidence class, and a good-looking value in one says nothing about the others."
      }
    },
    {
      "term": "provenance",
      "surface_string": "Basis: <basis> / Evidence basis: <basis>",
      "code_citation": "monitor/priv/static/app.js:1160 (truthCard Basis line), :1229 (mutation Evidence basis), :248 (data-provenance attribute)",
      "plain_definition": "The named evidence a shown fact rests on. Every decision-bearing value in the monitor carries one instead of appearing unattributed.",
      "confused_with": "A timestamp. Provenance names the evidence class, not when the page was drawn or when the fact was received.",
      "slug": "provenance",
      "concern": {
        "key": "provenance",
        "title": "Provenance vocabulary",
        "blurb": "Every decision-bearing value names the evidence it rests on. These are the words that name it."
      }
    },
    {
      "term": "Evidence basis",
      "surface_string": "Evidence basis: <basis>",
      "code_citation": "monitor/priv/static/app.js:1229 (mutationPanel); mutation basis vocabulary monitor/priv/presenter/projection-v1.md:614-627",
      "plain_definition": "For Mutation specifically, which evidence class the write record rests on: envelope, child-log-derived, apply checkpoint, or none available.",
      "confused_with": "Observed semantics. Basis names where evidence came from; observed_semantics says whether the path list is exact or a lower bound.",
      "slug": "evidence-basis",
      "concern": {
        "key": "provenance",
        "title": "Provenance vocabulary",
        "blurb": "Every decision-bearing value names the evidence it rests on. These are the words that name it."
      }
    },
    {
      "term": "reconstructed",
      "surface_string": "Reconstructed",
      "code_citation": "monitor/priv/static/app.js:9 (source filter vocabulary), :44 (marker tone); definition monitor/priv/presenter/projection-v1.md:70-71",
      "plain_definition": "Source mode meaning durable evidence was read but no current runtime observation was included. The normal mode for a finished run.",
      "confused_with": "Stale or wrong. Reconstructed is the strongest evidence class the monitor has; live is the degraded one.",
      "slug": "reconstructed",
      "concern": {
        "key": "provenance",
        "title": "Provenance vocabulary",
        "blurb": "Every decision-bearing value names the evidence it rests on. These are the words that name it."
      }
    },
    {
      "term": "live (source mode)",
      "surface_string": "Live",
      "code_citation": "monitor/priv/static/app.js:9 (source filter vocabulary), :44; definition monitor/priv/presenter/projection-v1.md:74-77",
      "plain_definition": "Source mode meaning only a volatile observation exists and no durable Log backs it. An honest degradation, never proof of completion.",
      "confused_with": "Liveness live. Source live means the evidence is weak; Liveness live means a process was reached.",
      "slug": "live-source-mode",
      "concern": {
        "key": "provenance",
        "title": "Provenance vocabulary",
        "blurb": "Every decision-bearing value names the evidence it rests on. These are the words that name it."
      }
    },
    {
      "term": "authoritative",
      "surface_string": "Read-only · authoritative snapshots · N runs",
      "code_citation": "monitor/priv/static/app.js:1131 (setStatus), :414 (SSE health), :1089 ('Authoritative, recomputable projections.')",
      "plain_definition": "A snapshot fetched over HTTP from the server. Only an authoritative refetch may change what the view shows.",
      "confused_with": "The Log itself. The snapshot is a recomputable projection over the Log; the append-only Log stays the source of truth.",
      "slug": "authoritative",
      "concern": {
        "key": "provenance",
        "title": "Provenance vocabulary",
        "blurb": "Every decision-bearing value names the evidence it rests on. These are the words that name it."
      }
    },
    {
      "term": "as-of seq",
      "surface_string": "as of seq <n>",
      "code_citation": "monitor/priv/static/app.js:1864 (detail status line), :1175 ('As of parent seq' field); definition monitor/priv/presenter/projection-v1.md:79-80",
      "plain_definition": "The highest parent Log sequence number this projection folded. It is the cut of history the whole view was computed from.",
      "confused_with": "A clock. Seq is a Log position, not a time; two projections at different wall-clock times with the same seq are identical.",
      "slug": "as-of-seq",
      "concern": {
        "key": "provenance",
        "title": "Provenance vocabulary",
        "blurb": "Every decision-bearing value names the evidence it rests on. These are the words that name it."
      }
    },
    {
      "term": "parent-observed",
      "surface_string": "Attention observed: N · parent Log only",
      "code_citation": "monitor/priv/static/app.js:976 (row basis), :959 ('Needs attention · N parent-observed'), :12-14 (attention honesty contract)",
      "plain_definition": "The fact came from reading the parent Session Log alone. It is a claim about observed evidence, never a claim about global health.",
      "confused_with": "Complete. Parent-observed absence means nothing was seen in that Log, not that nothing happened anywhere.",
      "slug": "parent-observed",
      "concern": {
        "key": "provenance",
        "title": "Provenance vocabulary",
        "blurb": "Every decision-bearing value names the evidence it rests on. These are the words that name it."
      }
    },
    {
      "term": "non-run Logs",
      "surface_string": "non-run Logs: N",
      "code_citation": "monitor/priv/static/app.js:1094 (scanned inventory line), :1044 ('Non-run Session Logs' detail row)",
      "plain_definition": "Session Logs in the scanned inventory that are not Delegate runs, so they project no row. Counted so the numbers reconcile.",
      "confused_with": "Dropped logs. Non-run Logs are correctly excluded; dropped_logs are selected Logs that failed to project.",
      "slug": "non-run-logs",
      "concern": {
        "key": "inventory",
        "title": "Inventory accounting",
        "blurb": "The Runs list confesses exactly what it scanned and what it could not turn into a row, so the visible count reconciles."
      }
    },
    {
      "term": "unprojected selected Logs",
      "surface_string": "unprojected selected Logs: N",
      "code_citation": "monitor/priv/static/app.js:1094 (scanned inventory line), :1044 ('Unprojected Selected Logs' detail row)",
      "plain_definition": "Logs the monitor selected but could not turn into a run row. A confessed gap between the inventory and the visible list.",
      "confused_with": "Non-run Logs. These were expected to project and did not; non-run Logs were never runs at all.",
      "slug": "unprojected-selected-logs",
      "concern": {
        "key": "inventory",
        "title": "Inventory accounting",
        "blurb": "The Runs list confesses exactly what it scanned and what it could not turn into a row, so the visible count reconciles."
      }
    },
    {
      "term": "stale handle",
      "surface_string": "Owner handle is stale; last observed evidence no longer confirms activity.",
      "code_citation": "monitor/priv/static/app.js:579 (livenessCellNote), :44 (marker tone), :1505 (attention reason family); rules monitor/priv/presenter/projection-v1.md:115-132",
      "plain_definition": "Liveness state where a nonterminal run has no current owner observation and nothing asserts the durable Log advanced.",
      "confused_with": "externally_owned. Both mean the owner is not this process, but externally_owned adds evidence the run is still advancing.",
      "slug": "stale-handle",
      "concern": {
        "key": "states",
        "title": "States you will meet first",
        "blurb": "Specific values whose plain reading is usually wrong on first encounter."
      }
    },
    {
      "term": "externally owned",
      "surface_string": "Owner is another process; activity confirmed from durable Log evidence.",
      "code_citation": "monitor/priv/static/app.js:1151 (livenessCardNote); doctrine monitor/priv/presenter/projection-v1.md:136-174",
      "plain_definition": "Liveness state where another process owns the Delegate and the durable Log confirms progress. Ordinary for read-only observation.",
      "confused_with": "A fault. Owner non-residency is the normal condition here, raises no attention reason, and never forces stale freshness.",
      "slug": "externally-owned",
      "concern": {
        "key": "states",
        "title": "States you will meet first",
        "blurb": "Specific values whose plain reading is usually wrong on first encounter."
      }
    },
    {
      "term": "unobserved",
      "surface_string": "Activity evidence unavailable at list scope (parent Log only). Detail may load owner diagnostics.",
      "code_citation": "monitor/priv/static/app.js:578 (livenessCellNote), :8 (liveness filter vocabulary); rule monitor/priv/presenter/projection-v1.md:195-197",
      "plain_definition": "The list-scope Liveness value: no activity evidence was consulted at all. An admission of not looking, not a finding.",
      "confused_with": "Not running. The list never consults owner diagnostics, so opening the run can legitimately show a different Liveness.",
      "slug": "unobserved",
      "concern": {
        "key": "states",
        "title": "States you will meet first",
        "blurb": "Specific values whose plain reading is usually wrong on first encounter."
      }
    },
    {
      "term": "checkpoint-ready",
      "surface_string": "Ready",
      "code_citation": "monitor/priv/static/app.js:1188 and :996 (alias {checkpoint_ready: \"ready\"}); rule monitor/priv/presenter/projection-v1.md:449-454",
      "plain_definition": "The only gate state that is dependent-safe: downstream Workflow steps depending on this unit may proceed.",
      "confused_with": "Completed. A unit can be execution-completed and still not checkpoint_ready, and its advisory may separately say stop.",
      "slug": "checkpoint-ready",
      "concern": {
        "key": "states",
        "title": "States you will meet first",
        "blurb": "Specific values whose plain reading is usually wrong on first encounter."
      }
    },
    {
      "term": "unclassified verdict",
      "surface_string": "unclassified verdict",
      "code_citation": "monitor/priv/static/app.js:60 (ADVISORY_DISPLAY_ALIASES), :51-58 (advisory display contract)",
      "plain_definition": "An advisory was present but its verdict could not be classified. A distinct fact from no advisory at all.",
      "confused_with": "No advisory. Absence never reaches a bucket; the present===true guard keeps it out of every count.",
      "slug": "unclassified-verdict",
      "concern": {
        "key": "states",
        "title": "States you will meet first",
        "blurb": "Specific values whose plain reading is usually wrong on first encounter."
      }
    },
    {
      "term": "invalid (advisory)",
      "surface_string": "Invalid",
      "code_citation": "monitor/priv/static/app.js:59 (ADVISORY_BUCKET_ORDER), :1187 (invalidReader on parse_status); rule monitor/priv/presenter/projection-v1.md:506-508",
      "plain_definition": "The advisory JSON could not be parsed. Counted in its own bucket and never given an invented verdict.",
      "confused_with": "unclassified verdict. Invalid means the document was unparseable; unclassified means it parsed but said nothing decisive.",
      "slug": "invalid-advisory",
      "concern": {
        "key": "states",
        "title": "States you will meet first",
        "blurb": "Specific values whose plain reading is usually wrong on first encounter."
      }
    },
    {
      "term": "undetermined",
      "surface_string": "Undetermined (child evidence unavailable)",
      "code_citation": "monitor/priv/static/app.js:595 (postTerminalLabel), :607 (postTerminalNote), :46-49 (tone comment); table monitor/priv/presenter/projection-v1.md:252-262",
      "plain_definition": "Child evidence for post-terminal activity was missing, so nothing is asserted. Missing evidence is never a clean bill.",
      "confused_with": "None. 'None' is an observed zero with event_count 0; undetermined carries null and reads as attention.",
      "slug": "undetermined",
      "concern": {
        "key": "states",
        "title": "States you will meet first",
        "blurb": "Specific values whose plain reading is usually wrong on first encounter."
      }
    },
    {
      "term": "hints only",
      "surface_string": "SSE connected · hints only · coalesced",
      "code_citation": "monitor/priv/static/app.js:414 (setStatus health pill), :2511-2518 (invalidation contract comment)",
      "plain_definition": "The event stream carries only invalidation notices. It never ships data and never mutates the view; a refetch does that.",
      "confused_with": "A live data feed. Nothing on screen ever comes from SSE; losing the stream costs freshness prompts, not correctness.",
      "slug": "hints-only",
      "concern": {
        "key": "stream",
        "title": "Stream and refresh",
        "blurb": "The event stream is a doorbell, not a delivery. These terms describe how the page stays current."
      }
    },
    {
      "term": "coalesced",
      "surface_string": "SSE connected · hints only · coalesced",
      "code_citation": "monitor/priv/static/app.js:414 (setStatus), :2499-2510 (refreshSingleFlight)",
      "plain_definition": "Bursts of invalidations collapse into one in-flight authoritative refetch; the last cause is replayed rather than dropped.",
      "confused_with": "Debounced or dropped. No cause is lost, and the refetch is always a full authoritative fetch, not a partial patch.",
      "slug": "coalesced",
      "concern": {
        "key": "stream",
        "title": "Stream and refresh",
        "blurb": "The event stream is a doorbell, not a delivery. These terms describe how the page stays current."
      }
    },
    {
      "term": "last successful authoritative refetch",
      "surface_string": "last successful authoritative refetch <ts>",
      "code_citation": "monitor/priv/static/app.js:413-415 (setStatus), :2480 / :2543 (lastAuthoritativeRefetchAt)",
      "plain_definition": "When the browser last received a snapshot it could use. Client-held receipt state, not a server field.",
      "confused_with": "projected_at. That is when the server built the projection; this is when this tab last successfully received one.",
      "slug": "last-successful-authoritative-refetch",
      "concern": {
        "key": "stream",
        "title": "Stream and refresh",
        "blurb": "The event stream is a doorbell, not a delivery. These terms describe how the page stays current."
      }
    },
    {
      "term": "stale handle vs stale source snapshot",
      "surface_string": "Stale source snapshot · received <ts> · refresh failure <kind>",
      "code_citation": "monitor/priv/static/app.js:384-385 (replaceContent disclosure), :2110 (workspace overview); rule monitor/priv/presenter/workspace-set-v1.md:244-266",
      "plain_definition": "A workspace source whose refresh is failing while an older snapshot is still held. Observational, never threshold-based.",
      "confused_with": "Unavailable. Stale means data is held but not current; unavailable means nothing is held at all.",
      "slug": "stale-handle-vs-stale-source-snapshot",
      "concern": {
        "key": "stream",
        "title": "Stream and refresh",
        "blurb": "The event stream is a doorbell, not a delivery. These terms describe how the page stays current."
      }
    },
    {
      "term": "logical unit",
      "surface_string": "Logical unit · <id>",
      "code_citation": "monitor/priv/static/app.js:2076 (unit view lede), :840 (resolution label); definition monitor/priv/presenter/projection-v1.md:344-371",
      "plain_definition": "One planned piece of work: a Workflow step or a fan-out subagent. It owns attempts and is not a child Session.",
      "confused_with": "A child Session. One unit may span several attempts across distinct or repeated child Session ids.",
      "slug": "logical-unit",
      "concern": {
        "key": "structure",
        "title": "Structure and navigation",
        "blurb": "How work is decomposed, and how a large graph stays legible without hiding anything."
      }
    },
    {
      "term": "Attempt lineage",
      "surface_string": "Attempt lineage",
      "code_citation": "monitor/priv/static/app.js:2080 (unit view section), :1606 (fan-out attempt nav); fold rules monitor/priv/presenter/projection-v1.md:373-400",
      "plain_definition": "The ordered attempts of one logical unit, including earlier failed ones. Identity is the unit id plus an ordinal.",
      "confused_with": "A retry count. Lineage keeps every epoch visible, including resumes that reuse the same child Session id.",
      "slug": "attempt-lineage",
      "concern": {
        "key": "structure",
        "title": "Structure and navigation",
        "blurb": "How work is decomposed, and how a large graph stays legible without hiding anything."
      }
    },
    {
      "term": "Provisional (attempt)",
      "surface_string": "Provisional",
      "code_citation": "monitor/priv/static/app.js:1610 and :1927 (ordinal null label); contract monitor/priv/presenter/projection-v1.md:413-427",
      "plain_definition": "A volatile_only attempt with a null ordinal, seen only under source mode live. It vanishes when a durable Log appears.",
      "confused_with": "Attempt 1. A provisional attempt is never persisted or renumbered, and its deep link must be treated as invalidatable.",
      "slug": "provisional-attempt",
      "concern": {
        "key": "structure",
        "title": "Structure and navigation",
        "blurb": "How work is decomposed, and how a large graph stays legible without hiding anything."
      }
    },
    {
      "term": "semantic zoom",
      "surface_string": "Dependency DAG · semantic zoom",
      "code_citation": "monitor/priv/static/app.js:1424 (workflowGraph heading), :1281-1284 (bounds); contract monitor/priv/presenter/semantic-zoom-v1.md:7-19",
      "plain_definition": "A bounded overview of a large dependency graph: at most six clusters plus one overflow at each zoom level.",
      "confused_with": "A filter. Nothing is removed; every edge stays reachable through a finite sequence of activations.",
      "slug": "semantic-zoom",
      "concern": {
        "key": "structure",
        "title": "Structure and navigation",
        "blurb": "How work is decomposed, and how a large graph stays legible without hiding anything."
      }
    },
    {
      "term": "Aggregate arc",
      "surface_string": "Aggregate arc <from> → <to> · N observed edges",
      "code_citation": "monitor/priv/static/app.js:1457 ('Aggregate dependency arcs'), :1462 (label); contract monitor/priv/presenter/semantic-zoom-v1.md:155-178",
      "plain_definition": "A bundle of exact dependency edges between two clusters, carrying ready, blocked, and unknown counts.",
      "confused_with": "A dependency. An arc is presentation structure; the real dependencies appear only in the exact-edge ledger.",
      "slug": "aggregate-arc",
      "concern": {
        "key": "structure",
        "title": "Structure and navigation",
        "blurb": "How work is decomposed, and how a large graph stays legible without hiding anything."
      }
    },
    {
      "term": "Exact-edge ledger",
      "surface_string": "Exact-edge ledger for selected aggregate arc",
      "code_citation": "monitor/priv/static/app.js:1481-1482 ('These rows are exact projected dependencies; the selected overview arc is only an aggregate.')",
      "plain_definition": "The complete list of real from/to dependency pairs behind one aggregate arc, paged 100 at a time.",
      "confused_with": "The arc summary. The arc is the aggregate; only this ledger shows the actual projected dependency set.",
      "slug": "exact-edge-ledger",
      "concern": {
        "key": "structure",
        "title": "Structure and navigation",
        "blurb": "How work is decomposed, and how a large graph stays legible without hiding anything."
      }
    },
    {
      "term": "Upstream boundary",
      "surface_string": "Upstream boundary · Waves 1–N",
      "code_citation": "monitor/priv/static/app.js:1335 (deriveSemanticZoom), :1453 ('Crosses the current zoom boundary.'); contract monitor/priv/presenter/semantic-zoom-v1.md:170-178",
      "plain_definition": "At deeper zoom levels, the one entity holding every wave before the current window so no edge is silently dropped.",
      "confused_with": "An overflow. Overflow holds waves after the window; the boundary holds the waves before it.",
      "slug": "upstream-boundary",
      "concern": {
        "key": "structure",
        "title": "Structure and navigation",
        "blurb": "How work is decomposed, and how a large graph stays legible without hiding anything."
      }
    },
    {
      "term": "Follow",
      "surface_string": "Follow this run / Following this run",
      "code_citation": "monitor/priv/static/app.js:1728-1742 (followToggle), :1734 ('It never silently switches runs.')",
      "plain_definition": "Explicit route state that keeps the same logical run selected across authoritative refetches, degrading rather than switching.",
      "confused_with": "Auto-refresh. Follow is about identity stability; refetch happens either way, and follow never picks a different run for you.",
      "slug": "follow",
      "concern": {
        "key": "structure",
        "title": "Structure and navigation",
        "blurb": "How work is decomposed, and how a large graph stays legible without hiding anything."
      }
    },
    {
      "term": "Parent-observed child Session",
      "surface_string": "Parent-observed child Session",
      "code_citation": "monitor/priv/static/app.js:833 (heading), :845 (basis line), :638-655 (resolveParentObservedChild)",
      "plain_definition": "A child Session id that a parent run's Log already names, letting a dead-end id offer its owning parent run.",
      "confused_with": "A projectable run. The child itself was never fetched or observed; only the parent's roster was scanned.",
      "slug": "parent-observed-child-session",
      "concern": {
        "key": "structure",
        "title": "Structure and navigation",
        "blurb": "How work is decomposed, and how a large graph stays legible without hiding anything."
      }
    },
    {
      "term": "run_not_found",
      "surface_string": "run_not_found (404)",
      "code_citation": "monitor/lib/pixir_monitor/router.ex:75 and :128; client handling monitor/priv/static/app.js:2299 (identityLoss)",
      "plain_definition": "The structured 404 saying this id is not a projectable run in this scope. The only failure that licenses the resolved-parent offer.",
      "confused_with": "A transient fetch error. Only a structured run_not_found is treated as identity loss; every other 404 clears that licence.",
      "slug": "run-not-found",
      "concern": {
        "key": "errors",
        "title": "Error kinds an operator meets",
        "blurb": "Server-side kinds that surface verbatim in the UI. Each is a specific confession, not a generic failure."
      }
    },
    {
      "term": "unscoped_route_unavailable",
      "surface_string": "Use a workspace-scoped Runs route (404)",
      "code_citation": "monitor/lib/pixir_monitor/router.ex:54 and :69; contract monitor/priv/presenter/workspace-set-v1.md:119-122",
      "plain_definition": "In workspace-set mode the unscoped /api/runs routes refuse rather than guess a workspace. An explicit confession of scope.",
      "confused_with": "A missing route. The route exists but is scope-inappropriate; it points at /api/workspaces/:key/… instead of inferring one.",
      "slug": "unscoped-route-unavailable",
      "concern": {
        "key": "errors",
        "title": "Error kinds an operator meets",
        "blurb": "Server-side kinds that surface verbatim in the UI. Each is a specific confession, not a generic failure."
      }
    },
    {
      "term": "workspace_unavailable",
      "surface_string": "Workspace projection is unavailable (503)",
      "code_citation": "monitor/lib/pixir_monitor/router.ex:137-147 (unavailable_error); isolation rule monitor/priv/presenter/workspace-set-v1.md:206-233",
      "plain_definition": "One declared source failed on its own scoped routes. There is no set-level 503; every other source is unaffected.",
      "confused_with": "The monitor being down. Failure is isolated per source, and the failing source shows an error card, never a zero.",
      "slug": "workspace-unavailable",
      "concern": {
        "key": "errors",
        "title": "Error kinds an operator meets",
        "blurb": "Server-side kinds that surface verbatim in the UI. Each is a specific confession, not a generic failure."
      }
    },
    {
      "term": "workspace_not_found",
      "surface_string": "workspace_not_found (404)",
      "code_citation": "monitor/lib/pixir_monitor/router.ex:127; contract monitor/priv/presenter/workspace-set-v1.md:123-126",
      "plain_definition": "The workspace key is charset-valid but was never declared at serve time. Distinct from a malformed key.",
      "confused_with": "invalid_workspace_key. That is a 400 for a key failing the safe-component rule, and it never echoes the key back.",
      "slug": "workspace-not-found",
      "concern": {
        "key": "errors",
        "title": "Error kinds an operator meets",
        "blurb": "Server-side kinds that surface verbatim in the UI. Each is a specific confession, not a generic failure."
      }
    },
    {
      "term": "authentication_required",
      "surface_string": "Same-origin monitor authentication is required (403)",
      "code_citation": "monitor/lib/pixir_monitor/router.ex:186-192 (with_auth); host check monitor/lib/pixir_monitor/security.ex:22-26",
      "plain_definition": "The request lacked the same-origin monitor session. The monitor answers only on its own loopback origin.",
      "confused_with": "A login. There is no account; the session cookie is minted once from a single-use launch capability.",
      "slug": "authentication-required",
      "concern": {
        "key": "errors",
        "title": "Error kinds an operator meets",
        "blurb": "Server-side kinds that surface verbatim in the UI. Each is a specific confession, not a generic failure."
      }
    },
    {
      "term": "invalid_launch",
      "surface_string": "Launch capability is invalid, expired, or already used (401)",
      "code_citation": "monitor/lib/pixir_monitor/router.ex:170 (consume_bootstrap); expiry copy monitor/lib/pixir_monitor/launch_surface.ex:287",
      "plain_definition": "The one-shot launch token did not consume. Relaunching pixir-monitor serve arms a fresh launch surface.",
      "confused_with": "A permissions problem. The token is single-use by design; a second tab using the same link legitimately fails.",
      "slug": "invalid-launch",
      "concern": {
        "key": "errors",
        "title": "Error kinds an operator meets",
        "blurb": "Server-side kinds that surface verbatim in the UI. Each is a specific confession, not a generic failure."
      }
    },
    {
      "term": "shutting_down",
      "surface_string": "Monitor is stopping (503)",
      "code_citation": "monitor/lib/pixir_monitor/router.ex:178-184 (with_api drain carve-out)",
      "plain_definition": "During the shutdown drain window API calls fail closed, so an open tab cannot keep painting a stale display as current.",
      "confused_with": "A crash. This is the deliberate drain window; failing closed here is what keeps the display honest.",
      "slug": "shutting-down",
      "concern": {
        "key": "errors",
        "title": "Error kinds an operator meets",
        "blurb": "Server-side kinds that surface verbatim in the UI. Each is a specific confession, not a generic failure."
      }
    },
    {
      "term": "next_actions",
      "surface_string": "next: <command>",
      "code_citation": "monitor/lib/pixir_monitor/cli.ex:526 (printer), :542 (normalize_error); registry monitor/priv/presenter/projection-v1.md:651-690",
      "plain_definition": "The bounded operator steps attached to a structured error or projected safe action. Never composed from prose.",
      "confused_with": "Automation. The monitor is read-only; it prints or offers a command to copy but never executes one.",
      "slug": "next-actions",
      "concern": {
        "key": "errors",
        "title": "Error kinds an operator meets",
        "blurb": "Server-side kinds that surface verbatim in the UI. Each is a specific confession, not a generic failure."
      }
    },
    {
      "term": "read-only",
      "surface_string": "Authoritative, recomputable projections. The monitor is read-only.",
      "code_citation": "monitor/priv/static/app.js:1089 (Runs lede), :1131 / :1864 / :2093 (status lines)",
      "plain_definition": "The monitor observes and never acts. Nothing it shows can be commanded from the page.",
      "confused_with": "Static. The view updates constantly from authoritative refetches; it simply issues no writes.",
      "slug": "read-only",
      "concern": {
        "key": "doctrine",
        "title": "Read-only doctrine",
        "blurb": "The monitor observes. These terms mark the boundary it never crosses."
      }
    },
    {
      "term": "Structured safe actions",
      "surface_string": "Structured safe actions",
      "code_citation": "monitor/priv/static/app.js:2050 (actionsPanel), :2055 ('Registered copy_only actions are the only executable affordance the monitor ever offers.'); registry monitor/priv/presenter/projection-v1.md:670-683",
      "plain_definition": "Commands projected from a closed registry of structured runtime guidance, offered to copy and never run by the monitor.",
      "confused_with": "Buttons that do the thing. Copying is the entire affordance; a mutating action is still only text to review and paste.",
      "slug": "structured-safe-actions",
      "concern": {
        "key": "doctrine",
        "title": "Read-only doctrine",
        "blurb": "The monitor observes. These terms mark the boundary it never crosses."
      }
    },
    {
      "term": "Review to copy",
      "surface_string": "Review command before copying",
      "code_citation": "monitor/priv/static/app.js:2017 (reviewModal), :1972-1979 (classifyCommand)",
      "plain_definition": "Copy gate for commands that mutate, carry shell syntax, or hide control or whitespace codepoints: bytes are shown first.",
      "confused_with": "A confirmation dialog for running it. Nothing executes; the choice is only whether the text reaches your clipboard.",
      "slug": "review-to-copy",
      "concern": {
        "key": "doctrine",
        "title": "Read-only doctrine",
        "blurb": "The monitor observes. These terms mark the boundary it never crosses."
      }
    },
    {
      "term": "escaped-only clipboard",
      "surface_string": "Escaped-only clipboard is frozen for v1.x. No raw-byte copy exists.",
      "code_citation": "monitor/priv/static/app.js:2023 and :2034 (dialog note), :1998-2004 (writeClipboard sink)",
      "plain_definition": "Every copy passes one sink that escapes control and bidirectional codepoints. There is no raw-byte copy path.",
      "confused_with": "Lossy copying. The escapes are reversible and visible; hostile bytes simply never arrive unannounced in your terminal.",
      "slug": "escaped-only-clipboard",
      "concern": {
        "key": "doctrine",
        "title": "Read-only doctrine",
        "blurb": "The monitor observes. These terms mark the boundary it never crosses."
      }
    },
    {
      "term": "Limitations",
      "surface_string": "Limitations",
      "code_citation": "monitor/priv/static/app.js:1713 (limitationsPanel), :1233 / :1917 (inline limitation lines); closed registry monitor/priv/presenter/projection-v1.md:734-766",
      "plain_definition": "Named, machine-readable admissions of missing or contradictory evidence. They are never hidden behind a successful aggregate.",
      "confused_with": "Errors. A limitation is a confessed gap in evidence, not a failure of the run or of the monitor.",
      "slug": "limitations",
      "concern": {
        "key": "doctrine",
        "title": "Read-only doctrine",
        "blurb": "The monitor observes. These terms mark the boundary it never crosses."
      }
    },
    {
      "term": "Evidence",
      "surface_string": "Evidence (N)",
      "code_citation": "monitor/priv/static/app.js:1698 (evidenceDrawer summary), :1703 (authority marker); authority vocabulary monitor/priv/presenter/projection-v1.md:692-700",
      "plain_definition": "The cited rows behind a projection, each with an authority: canonical, derived, volatile, model_declared, or artifact.",
      "confused_with": "Logs. Evidence rows are references into the Logs, carrying Session id and seq so a claim can be traced back.",
      "slug": "evidence",
      "concern": {
        "key": "doctrine",
        "title": "Read-only doctrine",
        "blurb": "The monitor observes. These terms mark the boundary it never crosses."
      }
    },
    {
      "term": "Evidence-derived usage",
      "surface_string": "Evidence-derived usage · N calls · Evidence complete",
      "code_citation": "monitor/priv/static/app.js:1908 (usagePanel summary), :1903-1905 (usageCompletenessLabel); fold rules monitor/priv/presenter/projection-v1.md:524-560",
      "plain_definition": "Token and call totals folded from durable provider_usage Events. 'Evidence complete' scopes the claim to that evidence.",
      "confused_with": "The run being finished. Usage completeness is about evidence at the observed boundary, unrelated to execution state.",
      "slug": "evidence-derived-usage",
      "concern": {
        "key": "doctrine",
        "title": "Read-only doctrine",
        "blurb": "The monitor observes. These terms mark the boundary it never crosses."
      }
    },
    {
      "term": "Write denials",
      "surface_string": "Write denials (N)",
      "code_citation": "monitor/priv/static/app.js:1242 (writeDenials heading), :1236-1237 (comment); rule monitor/priv/presenter/projection-v1.md:596-611",
      "plain_definition": "Writes a policy refused, shown with the matched rule and deciding policy so the refusal is readable without opening the child Log.",
      "confused_with": "A mutation. A denial is the opposite of a write and never moves mutation status toward partial or applied.",
      "slug": "write-denials",
      "concern": {
        "key": "doctrine",
        "title": "Read-only doctrine",
        "blurb": "The monitor observes. These terms mark the boundary it never crosses."
      }
    },
    {
      "term": "Workspace Overview",
      "surface_string": "Workspace Overview",
      "code_citation": "monitor/priv/static/app.js:2097 (heading), :2098 ('no set-level total is calculated'); contract monitor/priv/presenter/workspace-set-v1.md:14-24",
      "plain_definition": "The root view of a 2-to-8 workspace set: one section per declared source, in declaration order, with no cross-source sums.",
      "confused_with": "Fleet. Fleet is reserved for a future multi-machine product; this is bounded, local, and explicitly declared.",
      "slug": "workspace-overview",
      "concern": {
        "key": "doctrine",
        "title": "Read-only doctrine",
        "blurb": "The monitor observes. These terms mark the boundary it never crosses."
      }
    }
  ]);
  // GENERATED END pixir-monitor-glossary
  // Object.freeze is shallow, and the generated literal above is plain JSON so it
  // stays decodable by the drift test. Depth is added here, OUTSIDE the generated
  // region, so an accessor can hand a caller an entry it cannot mutate.
  //
  // The projection is SHAPE-AGNOSTIC on purpose: it walks the entry's own keys
  // rather than re-typing the corpus key names. Re-typing them here would make a
  // third hand-maintained copy of the shape (gen_terms.py's KEYS and the drift
  // test's @keys are the other two) and the only one nothing checks: the drift
  // test compares the extracted BLOCK to terms.json and never reads these
  // projected entries. The corpus has already taken one additive amendment
  // (5 keys -> 7, see DESIGN.md 'Amendment: routable glossary shape'); with a
  // typed list the next one would ship a seam that silently drops the new field
  // to every caller. Deriving instead means the generator stays the single place
  // the shape is declared, which is the whole reason this block is generated.
  function deepFreezeEntry(value) {
    if (value === null || typeof value !== "object") return value;
    const frozen = Array.isArray(value) ? value.map(deepFreezeEntry) : Object.keys(value).reduce(function (acc, name) {
      acc[name] = deepFreezeEntry(value[name]);
      return acc;
    }, {});
    return Object.freeze(frozen);
  }
  // Concerns are INTERNED across entries. gen_terms.py emits a byte-identical
  // concern record on every entry of a group, but the projection above rebuilds
  // each object literal, so without interning the 56 entries would carry 56
  // distinct concern objects that merely compare equal. That difference is not
  // cosmetic: it is what makes the deep freeze actually protect the corpus (one
  // shared object per group, so a refused write cannot be routed around by
  // reaching a group through another entry) and what lets the index group by
  // `concern` identity — grouping by object would otherwise yield one member per
  // group instead of 10/7/9, and a Map keyed by the concern object would hold 56
  // keys instead of 8. Interning by `key` is the only re-typed field name here;
  // the record's own shape stays derived, so an additive amendment to the concern
  // shape still reaches callers untouched.
  const CONCERN_BY_KEY = new Map();
  function internConcern(concern) {
    const interned = CONCERN_BY_KEY.get(concern.key);
    if (interned !== undefined) return interned;
    CONCERN_BY_KEY.set(concern.key, concern);
    return concern;
  }
  const GLOSSARY_ENTRIES = Object.freeze(GLOSSARY.map(function (entry) {
    const frozen = deepFreezeEntry(entry);
    const concern = internConcern(frozen.concern);
    if (concern === frozen.concern) return frozen;
    // Rebuild only to swap in the interned concern, still walking the entry's
    // own keys so an added field is carried rather than dropped.
    return Object.freeze(Object.keys(frozen).reduce(function (acc, name) {
      acc[name] = name === "concern" ? concern : frozen[name];
      return acc;
    }, {}));
  }));
  const GLOSSARY_BY_SLUG = new Map(GLOSSARY_ENTRIES.map(function (entry) { return [entry.slug, entry]; }));
  // Corpus order, deduplicated by key: the index's section order is the order the
  // concerns first appear in TERMS, never an alphabetical or re-sorted one. These
  // are the same interned objects the entries carry, so identity grouping holds.
  const GLOSSARY_CONCERNS = Object.freeze(GLOSSARY_ENTRIES.reduce(function (acc, entry) {
    if (!acc.some(function (concern) { return concern.key === entry.concern.key; })) acc.push(entry.concern);
    return acc;
  }, []));
  // Accessor seam (frozen for the onboarding wave). All three are SYNCHRONOUS
  // reads of the frozen literal: no fetch, no promise, no load-order question.
  function glossaryEntries() { return GLOSSARY_ENTRIES; }
  // Returns the entry for a slug, or null. Never undefined and never a throw:
  // an unknown `#manual/<slug>` is a routing miss the caller renders, not a crash.
  function glossaryBySlug(slug) {
    if (typeof slug !== "string" || slug === "") return null;
    const entry = GLOSSARY_BY_SLUG.get(slug);
    return entry === undefined ? null : entry;
  }
  function glossaryConcerns() { return GLOSSARY_CONCERNS; }
  const app = document.getElementById("app");
  const status = document.getElementById("status");
  const shell = document.querySelector("body > main");
  function readShellConfig() {
    if (!shell.hasAttribute("data-workspace-set")) return null;
    let value;
    try { value = JSON.parse(shell.getAttribute("data-workspace-set")); } catch (_error) { throw new Error("workspace set shell config is malformed"); }
    const exact = value && !Array.isArray(value) && Object.keys(value).sort().join(",") === "mode,workspaces";
    const keys = exact && Array.isArray(value.workspaces) ? value.workspaces : [];
    const validKeys = keys.length >= 2 && keys.length <= 8 && new Set(keys).size === keys.length && keys.every(function (key) { return typeof key === "string" && key.length <= 256 && /^[A-Za-z0-9][A-Za-z0-9_-]*$/.test(key); });
    if (!exact || value.mode !== "workspace_set" || !validKeys) throw new Error("workspace set shell config has an invalid shape");
    return Object.freeze({mode: value.mode, workspaces: Object.freeze(keys.slice())});
  }
  let shellConfig = null;
  let shellConfigError = null;
  try { shellConfig = readShellConfig(); } catch (error) { shellConfigError = error; }
  function workspaceSetMode() { return shellConfig !== null; }
  function clientIdentity(route) {
    const current = route || parseRoute(location.hash);
    if (!workspaceSetMode() || !current.workspace) return "";
    return current.workspace + ":" + (current.runId ? current.runId + ":" : "");
  }
  function clientStateKey(value, route) { return clientIdentity(route) + value; }
  function scopedStore() {
    const target = Object.create(null);
    return new Proxy(target, {
      get: function (store, property) { return typeof property === "string" ? store[clientStateKey(property)] : store[property]; },
      set: function (store, property, value) { store[typeof property === "string" ? clientStateKey(property) : property] = value; return true; },
      deleteProperty: function (store, property) { return delete store[typeof property === "string" ? clientStateKey(property) : property]; }
    });
  }
  const workspaceSnapshots = Object.create(null);
  const state = {
    generation: 0,
    list: null,
    detail: null,
    detailId: null,
    detailWorkspace: null,
    routeRunId: null,
    routeWorkspace: null,
    lastEventId: null,
    streamState: "connecting",
    refreshInFlight: null,
    refreshPendingReason: null,
    sourceRequestGeneration: Object.create(null),
    lastAuthoritativeRefetchAt: null,
    activityOrder: scopedStore(),
    pages: scopedStore(),
    restore: null,
    pendingAttemptScroll: null,
    detailConflict: false,
    forceRefetch: false,
    // Parent-observed child resolution (#438). resolutionFor names the run id
    // whose LAST authoritative response was a structured run_not_found; only
    // that id may be offered a resolved parent. resolutionFailure is the failure
    // to repaint after a one-shot inventory acquisition; resolutionInFlight
    // bounds that acquisition to a single request. resolutionAttemptedFor names
    // the id whose acquisition has ALREADY been attempted, which is what makes
    // the bound terminal: a repaint over an inventory that came back empty or
    // failed cannot re-enter acquisition for the same id.
    resolutionFor: null,
    resolutionFailure: null,
    resolutionInFlight: null,
    resolutionAttemptedFor: null,
    // Instrument manual overlay. `manual` is the last observed overlay field and
    // `manualUnderlyingHash` the underlyingKey of the route WITHOUT it (its view
    // identity plus its canonical hash): equal underlying keys with a moved
    // manual field is precisely the manual-only delta that must never fire an
    // authoritative refetch. Null means "no route has been observed yet", which
    // deliberately makes the first hashchange take the ordinary path.
    manual: null,
    manualUnderlyingHash: null,
    // The focus key the operator held when the pane OPENED, so closing it
    // returns them there. Generic capture/restore cannot do this: the hashchange
    // precedes the capture, so a close initiated from the pane's own Close link
    // records a key the same re-render destroys.
    manualReturnFocus: null,
    // A thunk that repaints the CURRENTLY PAINTED failure view with the exact
    // arguments that painted it, or null when the paint came from a projection
    // rather than from a failure. A manual-only delta is a pure overlay move, so
    // its re-render must reproduce the same view it opened over — and the
    // failure views cannot be re-derived from state: both renderProjectionFailure
    // and refresh's finally blocks clear state.detail while leaving the view
    // painted, so re-running renderCurrent() over that state repaints a
    // DIFFERENT view — a "Follow degraded" pane becomes "Follow snapshot
    // unavailable", and a "Follow identity conflict" pane (a contradiction)
    // becomes "Follow snapshot unavailable" (an outage). The record is a thunk
    // rather than a failure object because the identity-conflict and
    // unit-absent views are painted STRAIGHT from renderDetail/renderUnit with
    // no failure at all, so there is nothing to re-classify — only the call to
    // reproduce. It is captured at the two seams where every failure view is
    // actually mounted, which is what makes "lastPaint describes what is on
    // screen" true for every one of them.
    lastPaint: null
  };
  const SUPERSEDED = Symbol("superseded");

  function array(value) { return Array.isArray(value) ? value : []; }
  function scalar(value, fallback) { return value === null || value === undefined ? fallback : String(value); }
  function diagnosticToken(value, fallback) {
    const token = scalar(value, "");
    return /^[a-z0-9_]{1,64}$/.test(token) ? token : fallback;
  }
  function projectionFailure(phase, kind, status) {
    const failure = new Error("projection client failure");
    failure.name = "ProjectionFailure";
    failure.phase = diagnosticToken(phase, "render");
    failure.kind = diagnosticToken(kind, "projection_failure");
    failure.status = Number.isSafeInteger(status) && status >= 100 && status <= 599 ? status : null;
    failure.structured = false;
    return failure;
  }
  /**
   * A MONITOR AUTHORING DEFECT: a bug in this file, not a fact about the Log.
   *
   * The distinction is the whole point. Every render path funnels through
   * `renderCurrentGuarded`, which catches whatever a renderer throws. Before
   * this class existed, a plain `Error` raised by Monitor code was swallowed by
   * `normalizeProjectionFailure` and repainted as `projection_render_failed`
   * with the copy "The fetched projection could not be displayed." — an
   * ACCUSATION AGAINST UPSTREAM EVIDENCE for a typo the Monitor committed. In
   * an instrument whose entire doctrine is honest provenance, laundering our
   * own bug into a claim about the operator's Log is the worst failure mode
   * available to it: it sends the operator to inspect a Log that is fine.
   *
   * A defect therefore carries its own name, so `normalizeProjectionFailure`
   * cannot absorb it, and its own render path, so the screen says who is at
   * fault and preserves the diagnostic message verbatim.
   * @param {string} kind Diagnostic token naming the defect class.
   * @param {string} message The authored diagnostic, shown verbatim.
   * @returns {Error}
   */
  function monitorDefect(kind, message) {
    const defect = new Error(message);
    defect.name = "MonitorDefect";
    defect.kind = diagnosticToken(kind, "monitor_defect");
    defect.detail = String(message);
    return defect;
  }
  function isMonitorDefect(error) { return Boolean(error) && error.name === "MonitorDefect"; }
  function normalizeProjectionFailure(error) {
    if (error && error.name === "ProjectionFailure") return error;
    return projectionFailure("render", "projection_render_failed");
  }
  function projectionFailureMessage(failure) {
    if (failure.phase === "decode") return "The projection response could not be decoded.";
    if (failure.phase === "render") return "The fetched projection could not be displayed.";
    return "The authoritative projection could not be fetched.";
  }
  function projectionFailureStatus(failure) {
    if (failure.phase === "decode") return "Snapshot response invalid; relaunch or wait for convergence.";
    if (failure.phase === "render") return "Snapshot loaded but could not be displayed.";
    return "Snapshot unavailable; relaunch or wait for convergence.";
  }
  function applyFailureDiagnostic(root, failure) {
    root.dataset.errorPhase = failure.phase;
    root.dataset.errorKind = failure.kind;
    if (failure.status !== null) root.dataset.httpStatus = String(failure.status);
    return root;
  }
  function el(tag, className) {
    const node = document.createElement(tag);
    if (className) node.className = className;
    return node;
  }
  function text(tag, value, className) {
    const node = el(tag, className);
    node.textContent = scalar(value, "—");
    return node;
  }
  function untrustedText(tag, value, className) {
    const shown = visible(value);
    const node = text(tag, shown.text, className);
    node.classList.add("projected-text");
    node.setAttribute("dir", "auto");
    return node;
  }
  function projectedLink(value, hash, focusKey) {
    const node = untrustedText("a", value);
    node.href = hash;
    if (focusKey) key(node, focusKey);
    return node;
  }
  function projectedHeading(level, value) { return untrustedText("h" + level, value); }
  function setText(node, value) { node.textContent = scalar(value, "—"); }
  function key(node, value) { node.dataset.focusKey = clientStateKey(value); return node; }
  function scopedDisclosureValue(value, route) {
    const prefix = clientIdentity(route);
    return prefix && !value.startsWith(prefix) ? prefix + value : value;
  }
  function setDisclosureKey(node, value) { node.dataset.disclosureKey = scopedDisclosureValue(value); return node; }
  /**
   * Projects untrusted text for display: control, escape, and bidirectional
   * codepoints become visible tokens, and output is bounded to 32 KiB of the
   * source. Every projected string passes through here; hostile bytes never
   * reach a live sink.
   * @param {*} value Projected string (any type; coerced via scalar).
   * @returns {{text: string, truncated: boolean, rawLength: number}}
   */
  function visible(value) {
    const raw = scalar(value, "");
    let out = "";
    let truncated = false;
    let consumed = 0;
    for (const character of raw) {
      const cp = character.codePointAt(0);
      let token = character;
      if (cp === 0x1b) token = "⟦ESC⟧";
      else if (cp === 0x7f) token = "⟦DEL⟧";
      else if (cp < 0x20) token = "⟦C0 U+" + cp.toString(16).toUpperCase().padStart(4, "0") + "⟧";
      else if ((cp >= 0x80 && cp <= 0x9f) || (cp >= 0x2028 && cp <= 0x202e) || (cp >= 0x2066 && cp <= 0x2069) || cp === 0x061c || cp === 0x200e || cp === 0x200f) token = "⟦U+" + cp.toString(16).toUpperCase().padStart(4, "0") + "⟧";
      if (consumed + token.length > LIMITS.field) { truncated = true; break; }
      out += token;
      consumed += token.length;
    }
    return {text: out, truncated: truncated, rawLength: raw.length};
  }
  function projected(parent, tag, value, className) {
    const shown = visible(value);
    const node = untrustedText(tag, value, className);
    parent.append(node);
    if (shown.truncated) parent.append(text("span", "Visible preview limited to 32 KiB (" + shown.rawLength + " source characters).", "truncation"));
    return node;
  }
  function titleCase(value) { return scalar(value, "unknown").replaceAll("_", " "); }
  /**
   * Display label for one bucket of a distribution. Aliases rename the visible
   * token only; the raw value still drives tone, severity, and ordering.
   * @param {*} value Raw bucket token from the projection.
   * @param {?Object} aliases Optional display-alias map keyed by raw token.
   * @returns {string} Human-readable bucket label.
   */
  function distributionValueLabel(value, aliases) { return (aliases && aliases[value]) || titleCase(value); }
  function pluralizeDistributionLabel(label, count) {
    if (count === 1) return label;
    if (label === "unclassified verdict") return "unclassified verdicts";
    return label;
  }
  function markerTone(value) { const tone = scalar(value, "unknown"); return MARKER_TONES.has(tone) ? tone : "unknown"; }
  function marker(value, dimension, basis) {
    return labeledMarker(titleCase(value), value, dimension, basis);
  }
  function labeledMarker(label, tone, dimension, basis) {
    const node = text("span", label, "marker marker-" + markerTone(tone));
    node.dataset.dimension = dimension;
    if (basis) node.dataset.provenance = basis;
    return node;
  }
  function field(label, value) {
    const wrap = el("div", "field");
    wrap.append(text("dt", label));
    projected(wrap, "dd", value);
    return wrap;
  }
  function heading(level, value) { return text("h" + level, value); }
  function button(label, handler, className) {
    const node = text("button", label, className);
    node.type = "button";
    node.addEventListener("click", handler);
    return node;
  }
  function link(label, hash, focusKey) {
    const node = text("a", label);
    node.href = hash;
    if (focusKey) key(node, focusKey);
    return node;
  }
  function empty(message) { return text("p", message, "empty-state"); }

  // ── Dotted labelled terms: the AXIS names, and only the axis names ──────────
  //
  // The typographic honesty rule (DESIGN.md constraint 3) is what this whole
  // block enforces: the Monitor annotates its OWN labels and never the text it
  // merely transports. So the affordance is admissible on an axis NAME — a
  // string this bundle authored, shipped as a literal, and can therefore
  // define — and inadmissible on:
  //
  //   * VALUES (marker tokens, counts, distribution buckets). A value is what
  //     the projection observed; underlining it would claim the Monitor can
  //     define this run's answer rather than the question.
  //   * QUOTED MONOSPACE EVIDENCE (`code`, projected ids, raw excerpts). That
  //     is the agent speaking; annotating it is exactly the rule's prohibition.
  //   * PROJECTED / UNTRUSTED STRINGS (anything through untrustedText or
  //     projected). A slug looked up from a projected string is a slug an
  //     upstream Log can choose, which is a dead link at best and a routing
  //     primitive handed to untrusted data at worst.
  //
  // Every label below is therefore a compile-time literal from a call site in
  // this file, never a runtime-derived string.
  //
  // SHIPPED STRINGS WIN. The rail says "Attention (parent-observed)" and
  // "Child activity after end"; the list column header says "Child after end";
  // the Unit Inspector says "Runtime gate" where the rail says "Dependency
  // gate". The corpus has its own spellings again. None of those surfaces is
  // reworded to make a lookup convenient — the map absorbs the mismatch
  // instead, many shipped labels to one slug. (The list has NO "Attention"
  // column: attention rides the row's inline copy, so no short form ships.)
  //
  // The map is also the CALL-SITE INVENTORY: it is exhaustive and enumerable by
  // construction, which is what a downstream anti-rot predicate needs in order
  // to assert that the labels marked on screen are exactly these and no others.
  const LABELLED_TERMS = Object.freeze({
    // Truth-rail card headings (seven), in rail order.
    "Execution": "execution",
    "Liveness": "liveness",
    "Dependency gate": "dependency-gate",
    "Model advisory": "model-advisory",
    "Source (run-scoped)": "source-run-scoped",
    "Attention (parent-observed)": "attention",
    "Child activity after end": "child-after-end",
    // Runs list column headers carrying a doctrine term. "Run", "Strategy",
    // "Units", "Duration" and "Latest" are ordinary table nouns with no
    // glossary entry and are deliberately absent: an unmarked header is honest,
    // a header pointing at a term that does not define it is not.
    "Gate": "dependency-gate",
    "Advisory": "model-advisory",
    "Source": "source-run-scoped",
    "Mutation": "mutation",
    "Child after end": "child-after-end",
    // Unit Inspector.
    "Runtime gate": "runtime-gate",
    // The live-activity front door (DESIGN.md constraint 4). The SSE health pill
    // itself is left UNMARKED: it is a single status string the Monitor
    // assembles around observed stream state, and threading anchors through it
    // would put the affordance on a line that reads as a value. Instead the
    // first screen carries a Monitor-voice sentence that NAMES the pill's three
    // vocabulary terms and links each into the manual, so the newcomer who reads
    // the pill and does not understand it has somewhere to go without leaving
    // the first screen.
    "hints only": "hints-only",
    "coalesced": "coalesced",
    "last successful authoritative refetch": "last-successful-authoritative-refetch"
  });
  /**
   * The glossary slug for a SHIPPED label string.
   *
   * REFUSES BUILD-VISIBLY on an unknown label rather than degrading to a plain
   * heading. A silent fallback is the exact rot DESIGN.md constraint 2 exists to
   * prevent: a label would drift, its dotted underline would quietly vanish, and
   * nothing would be red. The throw is the red build — it is raised at the call
   * site during render, so any test that paints the surface catches it.
   *
   * It also refuses a slug the corpus does not carry. The map is hand-written
   * and the corpus is generated; a typo in either would otherwise ship a dotted
   * label whose target renders the manual's unknown-slug page.
   *
   * IT THROWS A `MonitorDefect`, NOT A PLAIN `Error`, and that is load-bearing.
   * A plain Error thrown during render is caught by `renderCurrentGuarded` and
   * normalized to `projection_render_failed`, which paints "The fetched
   * projection could not be displayed." and the status "Snapshot loaded but
   * could not be displayed." — the whole view blanked and OUR authoring typo
   * reported to the operator as a fault in their Log. On a followed run the
   * same path could route into the follow-degradation views, so the typo could
   * additionally masquerade as a run-identity or follow problem. The defect
   * class keeps the refusal loud on screen while naming the Monitor as the
   * culprit and preserving this message verbatim.
   * @param {string} label A literal label string from a call site in this file.
   * @returns {string} The glossary slug.
   * @throws {Error} A MonitorDefect when the label is unmapped or its slug is absent from the corpus.
   */
  function labelledTermSlug(label) {
    const slug = Object.prototype.hasOwnProperty.call(LABELLED_TERMS, label) ? LABELLED_TERMS[label] : null;
    if (!slug) throw monitorDefect("labelled_term_unmapped", "labelledTermSlug: no glossary term is mapped for the shipped label " + JSON.stringify(label) + ". Add the mapping in LABELLED_TERMS or drop the dotted affordance from that label; a dotted label with no entry is a dead link.");
    if (typeof glossaryBySlug === "function" && glossaryBySlug(slug) === null) throw monitorDefect("labelled_term_dead_link", "labelledTermSlug: the label " + JSON.stringify(label) + " maps to slug " + JSON.stringify(slug) + ", which the glossary corpus does not carry.");
    return slug;
  }
  /**
   * A labelled axis name: the dotted underline plus the route into the manual
   * opened at this term.
   *
   * The node is a NATIVE <a> with a real href, in DOM order, so it is a tab stop
   * and an Enter target without a single line of key handling (the manual's own
   * `?`/Escape bindings are wave 2's and are untouched here). `data-focus-key`
   * lets restoreView land the operator back on it after a re-render;
   * `data-manual-term` is the stable click target the browser harness uses.
   *
   * The href is always built through manualRoute so the current run, workspace,
   * filters, sort, query, follow and zoom state ride along — a hand-built
   * "#manual/..." literal would silently drop the operator's place.
   * @param {string} tag Element tag to wrap the anchor in ("h3", "th", ...).
   * @param {string} label A literal shipped label string.
   * @param {Object} route Parsed route the overlay opens over.
   * @param {string=} scope Disambiguator for surfaces that paint the same label
   *   more than once in one document (the runs list renders its header row once
   *   per group table). Focus keys must be unique or restoreView lands the
   *   operator on whichever copy happens to be first in the DOM.
   * @returns {Element} The wrapper element carrying the anchor.
   */
  function labelledTerm(tag, label, route, scope) {
    const slug = labelledTermSlug(label);
    const wrapper = el(tag);
    // `text`, not `untrustedText`: the label is an authored literal, so passing
    // it through the projection sanitizer would be theatre. The sanitizer is for
    // strings the Monitor did not write, and none of these are.
    const anchor = text("a", label, "labelled-term");
    anchor.href = manualRoute(route, slug);
    anchor.dataset.manualTerm = slug;
    key(anchor, "manual-term-label:" + (scope ? scope + ":" : "") + slug + ":" + label);
    wrapper.append(anchor);
    return wrapper;
  }

  // ── Instrument manual: an OVERLAY DIMENSION, never a fifth view ─────────────
  //
  // The manual is orthogonal to `view`. It rides every route family as its own
  // field so that opening it over a run detail keeps that run painted (the pane
  // PUSHES layout beside the view, it does not replace it) and so a manual-only
  // hash delta can be served as a pure re-render with no authoritative refetch.
  //
  // Two shapes reach the same field:
  //   1. `#manual/<slug>` / `#manual` — the DEEP LINK, the identity pasted into
  //      issues and PRs. It is intercepted before every other branch (before the
  //      workspace-set branch and before the runs fallthrough) and resolves to
  //      the DEFAULT view with the pane open, never to an unavailable view.
  //   2. `?manual=<slug>` — the canonical serialization on an existing route,
  //      which is what routeHash always emits. A deep link therefore
  //      canonicalizes to `#/runs?manual=<slug>` on its first pass and is a
  //      fixed point from then on.
  //
  // MANUAL_INDEX is the sentinel for "the pane is open at its index": a distinct
  // value from absence, so `#manual` round-trips as an open pane rather than
  // silently closing. An UNKNOWN slug is not an error and never demotes the
  // route: it is carried verbatim so the pane can say which slug was requested
  // while landing the reader on the index.
  const MANUAL_INDEX = "index";
  const MANUAL_SLUG_PATTERN = /^[a-z0-9]+(?:-[a-z0-9]+)*$/;
  // The path routeHash emits for an unavailable route that carries no raw path
  // of its own — a hand-built `{view: "invalid"}` literal rather than parseRoute
  // output. `%zz` is not a valid percent-escape, so decodeURIComponent throws on
  // it and parseRoute classifies the result as unavailable: the round trip
  // preserves the CLASS even when the original bytes are unknown. It is never
  // preferred over a real invalidPath — a path that merely lacks a leading "/"
  // is normalized, not replaced — so it is reached only when there are no bytes
  // to keep at all, which parseRoute output never is.
  const INVALID_PATH_SENTINEL = "/%zz";
  /**
   * Normalizes a requested manual term into the route field.
   * @param {*} value Raw slug from a hash segment or query param.
   * @returns {?string} MANUAL_INDEX, a slug-shaped token, or null when the pane is closed.
   */
  function manualField(value) {
    const token = scalar(value, "");
    if (!token) return null;
    if (token === MANUAL_INDEX) return MANUAL_INDEX;
    // Bounded and shape-checked so a hostile hash cannot smuggle an unbounded
    // string into the route; anything off-shape still OPENS the pane (at its
    // index) rather than producing an unavailable view.
    return MANUAL_SLUG_PATTERN.test(token) && token.length <= 128 ? token : MANUAL_INDEX;
  }
  /**
   * Parses the hash route. All view state lives in the hash — filters (validated
   * against FILTER_VOCABULARIES), sort (validated against SORT_VOCABULARY, else
   * the default), a length-bounded search query, the explicit follow flag, and
   * the orthogonal manual overlay field — so it survives refresh, back/forward,
   * and relaunch.
   * @param {string} hash location.hash, with or without the leading "#".
   * @returns {{view: string, runId: (string|undefined), unitId: (string|undefined), attemptId: (string|null|undefined), filters: Object, sort: string, q: string, follow: boolean, manual: ?string, invalidPath: (string|undefined)}}
   */
  function parseRoute(hash) {
    const raw = scalar(hash, "").replace(/^#/, "");
    const parts = raw.split("?");
    const path = parts[0] || (workspaceSetMode() ? "/workspaces" : "/runs");
    const params = new URLSearchParams(parts[1] || "");
    const segments = path.split("/").filter(Boolean).map(function (part) {
      try { return decodeURIComponent(part); } catch (_error) { return null; }
    });
    const filters = Object.create(null);
    ["strategy", "execution", "liveness", "source", "attention"].forEach(function (name) {
      const value = params.get(name);
      if (value && FILTER_VOCABULARIES[name].includes(value)) filters[name] = value;
    });
    const requestedSort = params.get("sort");
    const sort = SORT_VOCABULARY.includes(requestedSort) ? requestedSort : DEFAULT_SORT;
    const rawQuery = params.get("q");
    const q = rawQuery ? Array.from(String(rawQuery)).slice(0, LIMITS.query).join("") : "";
    const follow = params.get("follow") === "1";
    const zoomStart = /^\d+$/.test(params.get("zoom") || "") ? Number(params.get("zoom")) : 0;
    const selectedCluster = params.get("cluster") || null;
    const selectedArc = params.get("arc") || null;
    const memberPage = /^\d+$/.test(params.get("members") || "") ? Math.max(1, Number(params.get("members"))) : 1;
    const edgePage = /^\d+$/.test(params.get("edges") || "") ? Math.max(1, Number(params.get("edges"))) : 1;
    const zoom = {zoomStart: zoomStart, selectedCluster: selectedCluster, selectedArc: selectedArc, memberPage: memberPage, edgePage: edgePage};
    let manual = manualField(params.get("manual"));
    // The manual DEEP LINK is intercepted here, ahead of the workspace-set
    // branch and ahead of the runs fallthrough, so `#manual/<slug>` is a
    // standalone entry point: it yields the DEFAULT view with the pane open.
    // A path that merely FAILS to decode still wins invalid, below; only a
    // well-formed manual path short-circuits.
    if (segments.length >= 1 && segments[0] === "manual") {
      manual = manualField(segments.length >= 2 ? segments[1] : MANUAL_INDEX) || MANUAL_INDEX;
      const defaultView = workspaceSetMode() ? "workspaces" : "runs";
      return Object.assign({view: defaultView, filters: filters, sort: sort, q: q, follow: false, manual: manual}, zoom);
    }
    // THE UNAVAILABLE ROUTE KEEPS ITS PATH. `view: "invalid"` is the one view
    // whose path cannot be rebuilt from the parsed fields — its segments are
    // exactly the ones that FAILED to decode, so nothing structured survives
    // them. Carrying the raw path here is what lets routeHash re-emit it, and
    // that is what makes opening the manual over an unavailable route an
    // overlay move like every other: without it the serializer fell through to
    // the runs-path construction and silently DEMOTED the route, so pressing
    // `?` on `#/%zz` navigated the reader to `#/runs?manual=index` and the
    // unavailable state was gone for good. The path is stored verbatim and
    // never decoded or re-encoded — it is round-tripped as the opaque byte
    // sequence the operator's address bar actually holds.
    if (segments.some(function (segment) { return segment === null; })) return Object.assign({view: "invalid", invalidPath: parts[0] || "", filters: filters, sort: sort, q: q, follow: false, manual: manual}, zoom);
    let workspace;
    let routeSegments = segments;
    if (workspaceSetMode()) {
      if (segments.length === 1 && segments[0] === "workspaces") return Object.assign({view: "workspaces", filters: filters, sort: sort, q: q, follow: false, manual: manual}, zoom);
      if (segments[0] !== "workspaces" || !shellConfig.workspaces.includes(segments[1]) || segments[2] !== "runs") return Object.assign({view: "workspaces", filters: filters, sort: sort, q: q, follow: false, manual: manual}, zoom);
      workspace = segments[1];
      routeSegments = segments.slice(2);
    }
    if (routeSegments[0] !== "runs") return Object.assign({view: "runs", workspace: workspace, filters: filters, sort: sort, q: q, follow: false, manual: manual}, zoom);
    if (routeSegments.length >= 4 && routeSegments[2] === "units") return Object.assign({view: "unit", workspace: workspace, runId: routeSegments[1], unitId: routeSegments[3], attemptId: params.get("attempt"), filters: filters, sort: sort, q: q, follow: follow, manual: manual}, zoom);
    if (routeSegments.length >= 2) return Object.assign({view: "detail", workspace: workspace, runId: routeSegments[1], filters: filters, sort: sort, q: q, follow: follow, manual: manual}, zoom);
    return Object.assign({view: "runs", workspace: workspace, filters: filters, sort: sort, q: q, follow: false, manual: manual}, zoom);
  }
  /**
   * The manual field a route SERIALIZES with. Present-but-empty closes the pane;
   * absent inherits it from the hash the operator is currently on, so a partial
   * route literal navigates without disturbing the overlay. Reading the hash is
   * confined to this one helper, and it is only reached when the caller named no
   * manual at all — a route that carries the field never consults ambient state.
   * @param {Object} route Route literal, partial or whole.
   * @returns {?string} Slug, MANUAL_INDEX, or null when the pane is closed.
   */
  function routeManualField(route) {
    if (route && Object.prototype.hasOwnProperty.call(route, "manual")) return manualField(route.manual);
    // parseRoute, not a raw param read: it also resolves the `#manual/<slug>`
    // deep-link path shape, so a link rendered before the deep link has
    // canonicalized inherits the open pane rather than reading it as closed.
    // It cannot recur — parseRoute never calls routeHash.
    return manualField(parseRoute(location.hash).manual);
  }
  /**
   * Canonicalizes already-parsed route state into a hash. Inputs are trusted to
   * be pre-validated (parseRoute output or a route built from it): filters must
   * already match the vocabularies, and no validation happens here. Only
   * non-default state is serialized — the default sort, empty query, and
   * follow=false stay out of the hash; attemptId serializes as the attempt
   * param, and follow is only meaningful on run routes.
   *
   * The manual overlay serializes as the `manual` param on EVERY route family —
   * it is orthogonal to the path, so the underlying view and all its params
   * survive opening and closing the pane. The `#manual/<slug>` deep link is an
   * INPUT shape only: it canonicalizes here to `…?manual=<slug>` on the route it
   * landed on, which is what makes the round-trip a fixed point after one pass.
   *
   * ABSENCE OF THE FIELD IS NOT A REQUEST TO CLOSE THE PANE. Most callers build a
   * PARTIAL route literal — a filter change, a sort change, a run-row link, a
   * search submit, a Return to Runs — naming only the fields that navigation
   * changes. They are describing a delta against the route the operator is on,
   * and the manual is not part of that delta. Reading a missing field as "no
   * pane" made those exits silently close the manual while the semantic-zoom
   * exits (which spread the whole route) kept it, so one screen behaved two
   * contradictory ways and the orthogonality claim above was false for the great
   * majority of controls. An OMITTED field therefore inherits the pane state of
   * the current hash; only an EXPLICIT `manual: null`/`undefined` value closes
   * it, which is exactly what manualRoute's Close link and underlyingKey pass.
   * @param {Object} route Pre-validated route state in canonical order: filters, sort, q, follow, manual (plus runId/unitId/attemptId for detail routes). Omit `manual` to inherit the current pane state; pass it explicitly (including null) to set it.
   * @returns {string} Hash beginning with "#/runs".
   */
  function routeHash(route) {
    // The UNAVAILABLE route is its own path too, and for the same reason the
    // overview below is: it names no workspace, no run and no unit, so the
    // runs-path construction further down would invent an entire destination
    // for it. That is not a cosmetic difference — it silently DEMOTES the
    // route. Opening the manual over `#/%zz` used to serialize
    // `#/runs?manual=index` (or `#/workspaces/<first>/runs?manual=index` in set
    // mode), which navigates the reader onto a real view, discards the
    // unavailable state permanently, and makes the pane a destination rather
    // than an overlay on the one view where "you asked for something that does
    // not exist" is the entire message.
    //
    // The path is the RAW one parseRoute preserved, re-emitted verbatim: its
    // segments are undecodable by construction, so re-encoding them would
    // produce a different (and possibly decodable) hash. The manual field is
    // appended exactly as the overview does, which is what makes open/close a
    // fixed point over an unavailable route.
    if (route && route.view === "invalid") {
      const invalidManual = routeManualField(route);
      // The preserved path is NORMALIZED to root-relative, never discarded.
      // parseRoute stores `parts[0]` verbatim, which is the hash fragment
      // BEFORE any "/" normalization: `#%e0%a4%a` reaches here with
      // invalidPath `"%e0%a4%a"`, no leading slash at all. Dropping such a
      // path for a sentinel would rewrite the operator's address bar to a
      // hash they never typed and collapse every slash-less undecodable hash
      // onto one fabricated path — the same silent-rewrite class this branch
      // exists to eliminate, one step smaller. So a missing leading "/" is
      // ADDED rather than treated as grounds for replacement.
      //
      // Collapsing any run of leading slashes to exactly one is what preserves
      // routeHash's standing promise that everything it returns is a
      // ROOT-RELATIVE fragment, and it neutralizes both hostile literal shapes
      // in one move: "javascript:alert(1)" becomes "/javascript:alert(1)" and
      // the protocol-relative "//evil.example" becomes "/evil.example".
      // Nothing here can execute anyway — the value only ever reaches
      // `location.hash` or an href that starts with "#", where a leading
      // "javascript:" is a fragment and not a scheme, and no view interpolates
      // it as markup — but "the serializer emits a root-relative fragment,
      // always" is worth more as an invariant than as a case analysis.
      //
      // INVALID_PATH_SENTINEL is reserved for the one case with no bytes to
      // keep: a hand-built `{view: "invalid"}` literal carrying no path. It is
      // undecodable, so it re-parses to `view: "invalid"` and the CLASS
      // invariant holds even when the original bytes are unknown — strictly
      // better than falling through and demoting the route to runs.
      const preserved = typeof route.invalidPath === "string" ? route.invalidPath : "";
      const invalidPath = preserved ? "/" + preserved.replace(/^\/+/, "") : INVALID_PATH_SENTINEL;
      return "#" + invalidPath + (invalidManual ? "?manual=" + encodeURIComponent(invalidManual) : "");
    }
    // The workspace OVERVIEW is its own path, and it is the one view that names
    // no workspace. It must be serialized before the runs-path construction
    // below, which would otherwise invent a workspace (the route's, the current
    // hash's, or the first configured one) and silently navigate the reader OFF
    // the overview into a workspace's runs list — exactly what opening the
    // manual over the overview must not do.
    if (route && route.view === "workspaces" && workspaceSetMode()) {
      const overviewManual = routeManualField(route);
      return "#/workspaces" + (overviewManual ? "?manual=" + encodeURIComponent(overviewManual) : "");
    }
    let path = workspaceSetMode() ? "#/workspaces/" + encodeURIComponent(route.workspace || parseRoute(location.hash).workspace || shellConfig.workspaces[0]) + "/runs" : "#/runs";
    // Run and unit are one detail address. Encoding them independently can emit
    // `#/runs/units/<unit>` when the run id is unlinkable, which parseRoute
    // reads as `runId === "units"`. If either present component is unencodable,
    // omit both extra segments and stay on the list/workspace path. Never throw.
    const encodedRun = route.runId ? encodableComponent(route.runId) : null;
    const encodedUnit = route.unitId ? encodableComponent(route.unitId) : null;
    if ((!route.runId || encodedRun !== null) && (!route.unitId || encodedUnit !== null)) {
      if (encodedRun !== null) path += "/" + encodedRun;
      if (encodedUnit !== null) path += "/units/" + encodedUnit;
    }
    const params = new URLSearchParams();
    const filters = route.filters || Object.create(null);
    Object.keys(filters).sort().forEach(function (name) { if (filters[name]) params.set(name, filters[name]); });
    if (route.sort && route.sort !== DEFAULT_SORT && SORT_VOCABULARY.includes(route.sort)) params.set("sort", route.sort);
    if (route.q) params.set("q", Array.from(String(route.q)).slice(0, LIMITS.query).join(""));
    if (route.attemptId) params.set("attempt", route.attemptId);
    if (route.runId && Number.isSafeInteger(route.zoomStart) && route.zoomStart > 0) params.set("zoom", String(route.zoomStart));
    if (route.runId && route.selectedCluster) params.set("cluster", route.selectedCluster);
    if (route.runId && route.selectedArc) params.set("arc", route.selectedArc);
    if (route.runId && Number.isSafeInteger(route.memberPage) && route.memberPage > 1) params.set("members", String(route.memberPage));
    if (route.runId && Number.isSafeInteger(route.edgePage) && route.edgePage > 1) params.set("edges", String(route.edgePage));
    if (route.runId && route.follow === true) params.set("follow", "1");
    // Appended LAST on purpose: every pre-existing canonical hash keeps its
    // exact byte order, so the pinned bookmark corpus is unchanged for routes
    // that carry no manual field.
    const manual = routeManualField(route);
    if (manual) params.set("manual", manual);
    const query = params.toString();
    return path + (query ? "?" + query : "");
  }
  /**
   * The canonical hash for the same route with the manual overlay set or
   * cleared. Everything else on the route — view path, filters, sort, query,
   * follow, zoom state — is preserved verbatim, which is what makes the pane an
   * overlay rather than a destination.
   * @param {Object} route Parsed route to overlay.
   * @param {?string} slug Term slug, MANUAL_INDEX, or null to close the pane.
   * @returns {string} Canonical hash.
   */
  function manualRoute(route, slug) { return routeHash(Object.assign({}, route, {manual: slug === null || slug === undefined ? null : manualField(slug)})); }
  /**
   * The identity of the route UNDER the manual overlay: everything the pane is
   * allowed to sit beside without the view behind it changing. Two routes share
   * a key only when opening or closing the pane is the entire delta between
   * them.
   *
   * The view is part of the key because routeHash serializes a PATH, and a path
   * alone has never been a reliable view discriminator here. It is kept even now
   * that the unavailable route serializes its own path rather than falling
   * through to the runs path: the discrimination must not depend on a
   * serialization detail one refactor away from collapsing again, and the cost
   * of the extra component is nothing.
   * @param {Object} route Parsed route.
   * @returns {string} Key that changes whenever anything but the manual field changes.
   */
  function underlyingKey(route) {
    return route.view + "|" + routeHash(Object.assign({}, route, {manual: null}));
  }

  // ── Instrument manual pane ───────────────────────────────────────────────────
  //
  // The glossary CORPUS is not owned here. This branch defines no accessor and
  // embeds no term data: every read goes through a typeof-guarded call to the
  // accessors the data side exports (glossaryEntries / glossaryBySlug /
  // glossaryConcerns). When they are absent the pane still opens and says so in
  // the Monitor's own voice — a degraded pane is honest; a fabricated entry is
  // not.
  // The typeof guard is the whole seam: an UNDECLARED identifier is safe under
  // `typeof`, so this bundle links against the accessors when the data side is
  // present and degrades honestly when it is not, without either side importing
  // the other.
  function manualEntries() {
    if (typeof glossaryEntries !== "function") return null;
    try { const value = glossaryEntries(); return Array.isArray(value) ? value : null; } catch (_error) { return null; }
  }
  function manualConcerns() {
    if (typeof glossaryConcerns !== "function") return null;
    try { const value = glossaryConcerns(); return Array.isArray(value) ? value : null; } catch (_error) { return null; }
  }
  function manualEntry(slug) {
    if (typeof glossaryBySlug !== "function") return null;
    try { const value = glossaryBySlug(slug); return value && typeof value === "object" && !Array.isArray(value) ? value : null; } catch (_error) { return null; }
  }
  function manualDegraded(root) {
    root.append(text("p", "Manual data is not available in this build. The pane is routed and reachable; the term corpus is not loaded, so no definition can be shown. Nothing is being withheld and nothing is being guessed.", "empty-state"));
    return root;
  }
  /**
   * The manual INDEX: every term grouped by its concern, each group carrying the
   * authored section title and blurb. This is where an unknown slug lands — an
   * unrecognized term is a reason to show the reader the whole index, never a
   * reason to blank the screen or claim the route is unavailable.
   * @param {Element} root Pane body to append into.
   * @param {Object} route Current route, so entry links preserve it.
   * @param {?string} requested The slug that was asked for, when it did not resolve.
   */
  function renderManualIndex(root, route, requested) {
    const entries = manualEntries();
    const concerns = manualConcerns();
    if (entries === null || concerns === null) return manualDegraded(root);
    if (requested) {
      // The slug is already shape-validated by manualField, but it still reaches
      // the reader through the same untrusted-text projection as every other
      // variable string in this bundle: no string gets an exemption for being
      // "known safe".
      const unknown = el("p", "manual-unknown-slug");
      unknown.append(text("span", "No manual entry is named "));
      unknown.append(untrustedText("span", requested));
      unknown.append(text("span", ". The full index is below."));
      root.append(unknown);
    }
    root.append(text("p", entries.length + " terms, grouped by the concern each one answers. Every entry is a hash route you can paste into an issue.", "manual-lede"));
    // What the pane actually PUT ON SCREEN, counted rather than assumed. The
    // lede above asserts a corpus size; the groups below are what the reader can
    // see. When the two disagree the pane must say so instead of leaving the
    // assertion standing over nothing.
    let shown = 0;
    concerns.forEach(function (concern) {
      const conceptKey = scalar(concern && concern.key, "");
      const grouped = entries.filter(function (entry) { return entry && entry.concern && entry.concern.key === conceptKey; });
      if (!grouped.length) return;
      const section = el("section", "manual-group");
      section.append(untrustedText("h3", scalar(concern.title, conceptKey)));
      section.append(untrustedText("p", scalar(concern.blurb, ""), "manual-group-blurb"));
      const list = el("ul", "manual-term-list");
      grouped.forEach(function (entry) {
        const item = el("li");
        item.append(projectedLink(scalar(entry.term, entry.slug), manualRoute(route, entry.slug), "manual-term:" + scalar(entry.slug, "")));
        list.append(item);
      });
      shown += grouped.length;
      section.append(list);
      root.append(section);
    });
    // The ZERO-RENDER states, which manualDegraded cannot reach: the accessors
    // ANSWERED, so nothing is null and the pane is not degraded, yet every group
    // was skipped. Two shapes get here — an empty corpus, and a corpus whose
    // entries carry concern keys that match no concern object (a shape drift at
    // the data seam). Without this the pane rendered its lede and then nothing
    // at all: a count asserted and never displayed, which is the same blanking
    // the unknown-slug path exists to prevent. Naming the two numbers is what
    // makes it a confession rather than an empty screen.
    if (!shown) root.append(text("p", entries.length === 0 ? "The term corpus loaded and is empty: it contains no entries, so there is nothing to group. This is what the data side returned, not a display failure and not a filter." : "The term corpus loaded with " + entries.length + " entries and " + concerns.length + " concerns, but no entry's concern matches a known concern, so no group could be built. The corpus and its concern index disagree; nothing here is being withheld and nothing is being guessed.", "empty-state manual-empty"));
    else if (shown < entries.length) root.append(text("p", "Showing " + shown + " of " + entries.length + " terms. The remaining " + (entries.length - shown) + " name a concern that is not in the concern index, so they could not be grouped and are not listed above.", "provenance manual-partial"));
    return root;
  }
  // ── ON THIS RUN: the per-term reader table ───────────────────────────────────
  //
  // The manual's fourth doctrine part states the value the term has ON THE RUN
  // CURRENTLY ON SCREEN, with its basis and the parent Log sequence it was read
  // at. That is a claim about live projection state, so it is sourced through an
  // EXPLICIT slug -> reader table rather than derived from the term's shape.
  // Three properties follow from the table being explicit and total-by-omission:
  //
  //   1. Every bound term names the accessor it reads. No term acquires a value
  //      because a heuristic guessed one for it.
  //   2. A term ABSENT from the table is one this pane does not read a value
  //      for, and the part is OMITTED rather than filled with a hedge: printing
  //      "not applicable" under a heading that promises a live value would teach
  //      the reader that the part is noise. Absence is NOT evidence that the
  //      term has no per-run value — error kinds, doctrine terms and clipboard
  //      rules genuinely are instrument properties, but the same bucket also
  //      holds terms the views beside the pane DO read off this run and the
  //      table has not bound yet. The confession therefore states the pane's
  //      silence and never characterises the term; see renderManualEntry.
  //   3. The absent set is EXPORTED as frozen data (manualNoRunValueSlugs), so
  //      the anti-rot tier reads the inventory instead of re-deriving it and
  //      disagreeing with this bundle about what is bound.
  //
  // Every reader is passed the SAME projected run detail the view beside the
  // pane is painted from, so the pane can never disagree with the rail it is
  // explaining. The display vocabulary is the SHIPPED vocabulary, by reference
  // and never by transcription: ADVISORY_DISPLAY_ALIASES, GATE_DISPLAY_ALIASES,
  // ATTENTION_DISPLAY_ALIASES and their frozen bucket orders, plus the same
  // basis strings truthRail passes to its own cards. A parallel copy table here
  // would be a second source of truth for words that are contract, and the pane
  // would go on explaining a vocabulary the rail had already renamed.
  //
  // "The shipped vocabulary" means THE ONE THE SURFACE THIS READING EXPLAINS
  // USES, which is not always the alias map. At run scope the pane folds a
  // distribution, so it takes the alias maps the rail's distribution cards
  // take. At UNIT scope the surface beside it is the Unit Inspector's card, so
  // the gate reading takes unitGateLabel — that card's own label path, shared
  // by reference for exactly the reason the maps are. Passing the reader
  // through whichever of the two the neighbouring surface uses is the rule;
  // the alias map is one instance of it, not the rule itself.
  /**
   * THE distribution fold, folded ONCE for both readers of it. The truth rail
   * paints these buckets as markers and the manual pane joins them into prose;
   * before this was one function each side kept its own loop, and the pane's
   * copy silently dropped the residual bucket — so a run whose counts carried
   * only out-of-vocabulary tokens read "5 unrecognized" on the rail and fell
   * through to EMPTY_DISTRIBUTION_PHRASE in the pane explaining that rail,
   * inches apart. A distribution has exactly two kinds of bucket and both are
   * stated here:
   *
   *   1. The IN-VOCABULARY buckets, in the frozen display order, at their
   *      shipped alias. Buckets at zero are omitted — the rail omits them, so
   *      a reader never has to wonder whether an absent bucket means zero or
   *      means unsupported.
   *   2. The RESIDUAL: every count key the order does not name, summed into one
   *      "N unrecognized" bucket. Dropping it would let the instrument assert a
   *      total smaller than the run's own, which is the instrument fabricating
   *      a claim about the run rather than confessing what it cannot name.
   *
   * @param {Object} counts Bucket counts keyed by raw token.
   * @param {Array<string>} order Frozen display order.
   * @param {?Object} aliases Shipped display-alias map.
   * @returns {Array<{token: string, phrase: string}>} Populated buckets in display order, residual last.
   */
  function distributionBuckets(counts, order, aliases) {
    const buckets = [];
    const recognized = new Set(order);
    order.forEach(function (name) {
      const count = Number(counts && counts[name]) || 0;
      if (count > 0) buckets.push({token: name, phrase: count + " " + pluralizeDistributionLabel(distributionValueLabel(name, aliases), count)});
    });
    const residual = Object.keys(counts && typeof counts === "object" ? counts : {}).reduce(function (total, name) {
      if (recognized.has(name)) return total;
      const count = Number(counts[name]);
      return Number.isFinite(count) && count > 0 ? total + Math.floor(count) : total;
    }, 0);
    if (residual > 0) buckets.push({token: "unknown", phrase: residual + " unrecognized"});
    return buckets;
  }
  /**
   * Renders one distribution as the same "N label" phrases the truth rail emits,
   * joined for prose. It is the SAME fold the rail paints, residual bucket
   * included, so the pane and the rail never disagree about which buckets the
   * run has nor about the totals they add up to. Those totals are over the units
   * the projection SPOKE ABOUT for that dimension, which for advisory and
   * attention is fewer than the run's units when a record is absent — both folds
   * exclude absence rather than invent a bucket for it.
   * @param {Object} counts Bucket counts keyed by raw token.
   * @param {Array<string>} order Frozen display order.
   * @param {?Object} aliases Shipped display-alias map.
   * @returns {string} Joined phrase, or "" when no bucket is populated.
   */
  function manualDistributionPhrase(counts, order, aliases) {
    return distributionBuckets(counts, order, aliases).map(function (bucket) { return bucket.phrase; }).join(" · ");
  }
  /**
   * The count of ONE bucket, in the shipped label for that bucket. Used by the
   * terms that ARE a bucket ("checkpoint-ready", "unclassified verdict") rather
   * than the whole dimension.
   * @param {Object} counts Bucket counts keyed by raw token.
   * @param {string} bucket Raw token.
   * @param {?Object} aliases Shipped display-alias map.
   * @returns {string} "N label" in shipped vocabulary.
   */
  function manualBucketPhrase(counts, bucket, aliases) {
    const count = Number(counts && counts[bucket]) || 0;
    return count + " " + pluralizeDistributionLabel(distributionValueLabel(bucket, aliases), count);
  }
  /**
   * Whether one unit carries an attention record at all — the distinction that
   * separates "not required" (a fact the projection asserts) from "no record"
   * (a fact it is silent about). Named ONCE, above every reader of the
   * dimension, so no surface can disagree with another about which of the three
   * cases a unit is in.
   *
   * projection-v1.md says "Every unit carries" an attention object, so a unit
   * without one is a malformed or partial projection rather than a state the
   * builder emits. That is exactly why the predicate exists: the presenter's
   * job at a projection it cannot fully read is to say less, not to guess a
   * value and print it in the vocabulary of one it read.
   * @param {Object} unit Unit projection.
   * @returns {boolean} True when an attention object with a boolean `required`
   *   is present.
   */
  function unitHasAttentionRecord(unit) {
    return !!unit && !!unit.attention && typeof unit.attention === "object" && typeof unit.attention.required === "boolean";
  }
  /**
   * The raw attention bucket ONE unit falls in, or null when the projection
   * carries no attention record for it. The single reader every attention
   * distribution folds through: the rail's card, the manual's run fold and the
   * semantic-zoom cluster row.
   *
   * ABSENCE IS NOT "no". `required === true ? "yes" : "no"` collapsed three
   * cases into two, so a unit the projection says NOTHING about was counted in
   * the negative bucket and printed as "not required" under the `parent log`
   * basis — a fabricated negative carrying a fabricated provenance, multiplied
   * by every surface that renders the fold. Returning null instead excludes it
   * from the count exactly as `runAdvisoryCounts`'s `present === true` guard
   * excludes an absent advisory, which is the precedent this dimension had been
   * missing.
   *
   * Excluded, NOT bucketed. There is no third bucket to put it in: the filter
   * vocabulary is `["yes", "no"]` and the attention honesty contract at the top
   * of this bundle forbids a synthetic unknown bucket for this dimension
   * anywhere in it. A count is a claim about units the projection spoke about,
   * and a unit it did not speak about belongs in no bucket at all. The
   * fan-out grouping already reaches the same conclusion by another route: an
   * absent record lands in `attention_requirement_unavailable`, never in the
   * healthy `required === false` group.
   * @param {Object} unit Unit projection.
   * @returns {?string} "yes", "no", or null when no record is present.
   */
  function unitAttentionBucket(unit) {
    if (!unitHasAttentionRecord(unit)) return null;
    return unit.attention.required === true ? "yes" : "no";
  }
  // The three per-run unit folds, named ONCE and shared with truthRail rather
  // than re-expressed here. The advisory and attention folds in particular
  // carry a real decision — absence is excluded, by the `present === true`
  // guard and by unitHasAttentionRecord respectively, and an unparseable
  // advisory is counted `invalid` instead of being given an invented verdict —
  // and a second copy of either in the manual would be a second place for that
  // decision to be got wrong.
  function runGateCounts(run) { return stateCounts(run.units, function (unit) { return unit.gate && unit.gate.state; }); }
  function runAdvisoryCounts(run) {
    return stateCounts(run.units, function (unit) { return unit.advisory && unit.advisory.present === true ? unit.advisory.verdict : null; }, function (unit) { return unit.advisory && unit.advisory.present === true && unit.advisory.parse_status === "invalid"; });
  }
  function runAttentionCounts(run) { return stateCounts(run.units, unitAttentionBucket); }
  // ── The SCOPE a reading is a fold over ───────────────────────────────────────
  //
  // The pane rides two run-scoped views, and they are painted from DIFFERENT
  // entities. The detail view's truth rail folds every dimension across the
  // whole run; the Unit Inspector paints ONE unit's own execution, liveness,
  // gate and advisory. A reader that always folded the run therefore printed a
  // run-wide number under a heading reading ON THIS RUN while the card inches
  // away painted that unit's value for the same dimension — two different
  // answers to one question on one screen, with nothing on either naming which
  // entity its number was about. It was sharpest for `runtime-gate`, whose own
  // corpus definition is "the Unit Inspector's label for the runtime's own gate
  // decision ON ONE UNIT": the single route where that term's surface string
  // appears was the route where the pane answered about something else.
  //
  // So a reading is scoped, always, and both halves of that are load-bearing:
  //
  //   1. The reader is handed the entity the view beside it is PAINTED FROM.
  //      On the Unit Inspector the unit-scoped dimensions read the opened unit,
  //      so the pane and the card agree by construction rather than by luck.
  //   2. The reading NAMES its scope, and the part prints that name. A count is
  //      meaningless without the population it counts, and "1 held · 3 ready"
  //      says nothing about whether those four are this unit's siblings or the
  //      whole run until the phrase says so.
  //
  // The two scope kinds are frozen here so the words are defined once, like
  // every other vocabulary this pane shares with the rail.
  const MANUAL_SCOPE_RUN = "this run";
  function manualUnitScopeLabel(unit) { return "this unit (" + scalar(unit && unit.logical_id, "unknown") + ")"; }
  /**
   * The unit the Unit Inspector is painting, or null.
   *
   * Resolved with the SAME lookup renderUnit uses, off the same projection, so
   * "the pane found a unit" and "the Inspector painted that unit" cannot come
   * apart. A route that names no unit, or names one this projection does not
   * carry, yields null and every reader falls back to run scope — which is what
   * the surrounding view is showing in that case too.
   * @param {Object} run Run projection in detail form.
   * @param {Object} route Parsed route.
   * @returns {?Object} The opened unit, or null.
   */
  function manualUnitInScope(run, route) {
    if (!route || route.view !== "unit" || !route.unitId) return null;
    return array(run && run.units).find(function (candidate) { return candidate.logical_id === route.unitId; }) || null;
  }
  /**
   * The slug -> reader table. A reader is called with ONE scope object
   * `{run, unit}` — `unit` is the logical unit the Unit Inspector is painting,
   * or null everywhere else — and returns {value, basis, scope}. `basis` may be
   * null when the projection carries none for that dimension, and the part then
   * shows the value alone rather than inventing a provenance for it. `scope`
   * names the entity the value was folded over and is always printed. A reader
   * returning null means the dimension is present in the schema but carries
   * nothing on THIS run, which is stated as such rather than shown blank.
   *
   * Readers split into two families, and the split is the corpus's, not a
   * convenience:
   *
   *   - PER-UNIT dimensions (execution, liveness, gate, advisory, attention)
   *     are painted per unit by the Unit Inspector and folded across units by
   *     the rail. They read the opened unit when there is one and fold the run
   *     when there is not, so each answers about whatever the view beside the
   *     pane is showing.
   *   - RUN-SCOPED dimensions (source and its modes, post-terminal child
   *     activity, as-of seq) exist only at run scope — the corpus says so
   *     outright for source ("Source is run-scoped, never per unit") — so they
   *     read the run on EVERY route and label themselves run-scoped even while
   *     a unit is open. Narrowing them to a unit would invent a per-unit value
   *     no projection carries.
   *
   * Liveness reads the entity's own `liveness` object and NOTHING else — the
   * same field livenessState/livenessBasis read off a run and the Unit
   * Inspector's own Liveness card reads off a unit. The shipped detail
   * vocabulary is not_applicable / stale_handle / externally_owned /
   * owner_unavailable / live / unknown; it carries no terminal token, because a
   * run past its terminal boundary reads not_applicable — which is what the
   * corpus itself says. Synthesizing a terminal state here would put a value on
   * screen that no projection can produce and no filter can select.
   */
  const MANUAL_RUN_READERS = Object.freeze({
    "execution": function (scope) { return manualExecutionReading(scope); },
    "liveness": function (scope) { return manualLivenessReading(scope); },
    // The liveness VALUES that detail scope can actually produce. Each answers
    // "is the entity on screen in this state right now", which is the question a
    // reader who just met the word in a cell actually has. The answer names the
    // state the entity IS in, so a "no" is still informative rather than a bare
    // denial.
    "stale-handle": function (scope) { return manualLivenessValueReading(scope, "stale_handle"); },
    "externally-owned": function (scope) { return manualLivenessValueReading(scope, "externally_owned"); },
    // `unobserved` is NOT one of them. It is produced by list_liveness alone
    // (source.ex) and the contract states it outright: "List scope ... folds
    // liveness independently into `unobserved` ... for nonterminal rows"
    // (projection-v1.md, Liveness vocabulary). The detail builder's liveness/4
    // can emit none of it. Answered like its two siblings it was therefore a
    // STRUCTURALLY INVARIANT denial — "Not unobserved" on 100% of runs, forever,
    // with the affirmative branch unreachable — and worse, a denial the operator
    // arrives at by clicking the dotted label on a runs-list cell that literally
    // reads `unobserved`. The pane would answer "this run is not unobserved"
    // about a run whose row says it is. So this reader states the SCOPE fact
    // instead, which is both true and the thing the reader came to learn.
    "unobserved": function (scope) { return manualListOnlyLivenessReading(scope, "unobserved"); },
    // Both labels for the runtime's own gate decision. The rail says "Dependency
    // gate", the Unit Inspector says "Runtime gate"; one dimension, so one
    // reader, which is exactly the confusable the entry warns about. The reader
    // is scoped, so opening the Inspector answers each label about the unit the
    // Inspector is painting rather than about its siblings.
    "dependency-gate": function (scope) { return manualGateReading(scope); },
    "runtime-gate": function (scope) { return manualGateReading(scope); },
    "checkpoint-ready": function (scope) { return manualGateValueReading(scope, "checkpoint_ready"); },
    "model-advisory": function (scope) { return manualAdvisoryReading(scope); },
    "unclassified-verdict": function (scope) { return manualAdvisoryValueReading(scope, "unknown"); },
    "invalid-advisory": function (scope) { return manualAdvisoryValueReading(scope, "invalid"); },
    "source-run-scoped": function (scope) { return {value: titleCase(scope.run.source && scope.run.source.mode), basis: scope.run.source && scope.run.source.durable_origin, scope: MANUAL_SCOPE_RUN}; },
    "live-source-mode": function (scope) { return manualSourceModeReading(scope, "live"); },
    "reconstructed": function (scope) { return manualSourceModeReading(scope, "reconstructed"); },
    "attention": function (scope) { return manualAttentionReading(scope); },
    "parent-observed": function (scope) { return manualAttentionReading(scope); },
    "child-after-end": function (scope) { return manualPostTerminalReading(scope); },
    // The post-terminal VALUE, not the dimension. Structurally it is the same
    // question the liveness values answer — "is the run on screen in this
    // state" — so it takes the same shape, and it must NOT reuse the whole
    // dimension's reader: that answers "what IS post-terminal activity on this
    // run" under a heading promising what `undetermined` reads, so a run whose
    // state is `none` had this entry print the word "none".
    "undetermined": function (scope) { return manualPostTerminalValueReading(scope, "undetermined"); },
    // as_of_seq is "the highest included parent Log sequence" — a position in
    // the parent Log fold, not a value read off the source evidence class. So
    // it carries NO basis: the source mode ("live", "reconstructed") names what
    // kind of evidence the projection rests on, and stapling it here would tell
    // the reader that a parent-Log sequence rests on, say, a live observation
    // that by definition has no durable Log behind it. The renderer already
    // shows the value alone when basis is null, which is the honest reading.
    "as-of-seq": function (scope) {
      const seq = scope.run.source && scope.run.source.as_of_seq;
      if (seq === null || seq === undefined) return null;
      return {value: "seq " + scalar(seq, "unknown"), basis: null, scope: MANUAL_SCOPE_RUN, suppressAsOf: true};
    }
  });
  /**
   * Execution, off whichever entity the view beside the pane is painting. The
   * Unit Inspector's Execution card reads `unit.execution`; the rail's reads
   * `run.execution`. Same accessor shape, different entity, so one reader
   * carries both and names which it used.
   * @param {{run: Object, unit: ?Object}} scope Painted scope.
   * @returns {{value: string, basis: ?string, scope: string}} Reading.
   */
  function manualExecutionReading(scope) {
    const entity = scope.unit || scope.run;
    return {value: titleCase(entity.execution && entity.execution.state), basis: entity.execution && entity.execution.basis, scope: manualScopeLabel(scope)};
  }
  /**
   * Liveness, off whichever entity the view is painting. livenessState /
   * livenessBasis are the run-shaped accessors the rail uses; a unit carries the
   * same `liveness` object, which is what the Inspector's own card reads.
   * @param {{run: Object, unit: ?Object}} scope Painted scope.
   * @returns {{value: string, basis: ?string, scope: string}} Reading.
   */
  function manualLivenessReading(scope) {
    const entity = scope.unit || scope.run;
    return {value: titleCase(entity.liveness && entity.liveness.state), basis: entity.liveness && entity.liveness.basis, scope: manualScopeLabel(scope)};
  }
  function manualScopeLabel(scope) { return scope.unit ? manualUnitScopeLabel(scope.unit) : MANUAL_SCOPE_RUN; }
  /**
   * The gate dimension. On the Unit Inspector this is the unit's own gate state
   * with the unit's own basis, LABELLED THROUGH THE CARD'S OWN PATH
   * (unitGateLabel) so the pane prints the exact word the "Runtime gate"
   * truthCard inches away prints; everywhere else it is the run-wide checkpoint
   * fold the rail's "Dependency gate" card paints, in that fold's own
   * distribution vocabulary.
   *
   * The two labellings differ for exactly one token: the card renders
   * `checkpoint_ready` as "checkpoint ready" and the distribution renames it to
   * "ready" for its counts. The pane quotes the surface it explains, so at unit
   * scope it says what the card says.
   * @param {{run: Object, unit: ?Object}} scope Painted scope.
   * @returns {{value: string, basis: ?string, scope: string}} Reading.
   */
  function manualGateReading(scope) {
    if (scope.unit) return {value: unitGateLabel(scope.unit), basis: scope.unit.gate && scope.unit.gate.basis, scope: manualUnitScopeLabel(scope.unit)};
    const phrase = manualDistributionPhrase(runGateCounts(scope.run), GATE_BUCKET_ORDER, GATE_DISPLAY_ALIASES);
    return {value: phrase || EMPTY_DISTRIBUTION_PHRASE, basis: GATE_FOLD_BASIS, scope: MANUAL_SCOPE_RUN};
  }
  /**
   * ONE gate value ("checkpoint-ready", whose corpus surface_string is the
   * single word "Ready"). At unit scope the honest answer is whether THIS unit
   * is in that state, phrased like every other value term; at run scope it is
   * the bucket's count.
   *
   * The TERM keeps its own surface string on both sides of the denial — that is
   * the word the reader clicked — but the STATE the unit is reported to be in
   * goes through unitGateLabel, the card's path, so "this unit reads ..." names
   * the value in the same word the card beside it paints.
   * @param {{run: Object, unit: ?Object}} scope Painted scope.
   * @param {string} token Raw gate token this term names.
   * @returns {{value: string, basis: ?string, scope: string}} Reading.
   */
  function manualGateValueReading(scope, token) {
    if (scope.unit) {
      const state = scalar(scope.unit.gate && scope.unit.gate.state, "unknown");
      const label = distributionValueLabel(token, GATE_DISPLAY_ALIASES);
      return {value: state === token ? label : "Not " + label + " — this unit reads " + unitGateLabel(scope.unit), basis: scope.unit.gate && scope.unit.gate.basis, scope: manualUnitScopeLabel(scope.unit)};
    }
    return {value: manualBucketPhrase(runGateCounts(scope.run), token, GATE_DISPLAY_ALIASES), basis: GATE_FOLD_BASIS, scope: MANUAL_SCOPE_RUN};
  }
  /**
   * The advisory dimension, scoped the same way. The Unit Inspector's "Model
   * advisory" card paints unitAdvisoryLabel(unit) — the shared bucket-then-
   * alias path — with the shipped `model declared` basis; the rail paints the
   * run-wide verdict fold.
   * @param {{run: Object, unit: ?Object}} scope Painted scope.
   * @returns {{value: string, basis: ?string, scope: string}} Reading.
   */
  function manualAdvisoryReading(scope) {
    if (scope.unit) return {value: manualUnitAdvisoryLabel(scope.unit), basis: ADVISORY_FOLD_BASIS, scope: manualUnitScopeLabel(scope.unit)};
    const phrase = manualDistributionPhrase(runAdvisoryCounts(scope.run), ADVISORY_BUCKET_ORDER, ADVISORY_DISPLAY_ALIASES);
    return {value: phrase || EMPTY_DISTRIBUTION_PHRASE, basis: ADVISORY_FOLD_BASIS, scope: MANUAL_SCOPE_RUN};
  }
  /**
   * ONE advisory bucket. The unit-scope answer applies the SAME bucketing
   * decision the run fold applies — absence excluded by the `present === true`
   * guard, an unparseable advisory counted `invalid` rather than given an
   * invented verdict — so the two scopes can never classify one unit
   * differently.
   * @param {{run: Object, unit: ?Object}} scope Painted scope.
   * @param {string} token Raw advisory bucket this term names.
   * @returns {{value: string, basis: ?string, scope: string}} Reading.
   */
  function manualAdvisoryValueReading(scope, token) {
    if (scope.unit) {
      const bucket = unitAdvisoryBucket(scope.unit);
      const label = distributionValueLabel(token, ADVISORY_DISPLAY_ALIASES);
      const value = bucket === token ? label : "Not " + label + " — this unit reads " + manualUnitAdvisoryLabel(scope.unit);
      return {value: value, basis: ADVISORY_FOLD_BASIS, scope: manualUnitScopeLabel(scope.unit)};
    }
    return {value: manualBucketPhrase(runAdvisoryCounts(scope.run), token, ADVISORY_DISPLAY_ALIASES), basis: ADVISORY_FOLD_BASIS, scope: MANUAL_SCOPE_RUN};
  }
  /**
   * The bucket ONE unit's advisory falls in, by the same rules runAdvisoryCounts
   * folds by, or null when no advisory is present at all. Named once so unit
   * scope and run scope cannot disagree about one unit.
   * @param {Object} unit Unit projection.
   * @returns {?string} Raw bucket token, or null when no advisory is present.
   */
  function unitAdvisoryBucket(unit) {
    if (!unit.advisory || unit.advisory.present !== true) return null;
    if (unit.advisory.parse_status === "invalid") return "invalid";
    return scalar(unit.advisory.verdict, "unknown");
  }
  /**
   * The shipped label for one unit's advisory, ABSENCE INCLUDED.
   *
   * The bucket vocabulary has no token for "no advisory" because absence never
   * reaches a bucket — the `present === true` guard excludes it, which is what
   * the corpus entry for `unclassified verdict` warns about in as many words:
   * "No advisory. Absence never reaches a bucket; the present===true guard
   * keeps it out of every count." So the pane needs a word the fold does not
   * supply, and there are only two honest candidates.
   *
   * For a PRESENT verdict the card and this pane now share the alias path
   * (unitAdvisoryLabel), so there is one word per value. ABSENCE is the one
   * deliberate divergence left: the card renders a missing field through
   * titleCase as "unknown" — a rendering artefact, not a verdict the
   * projection asserts — and renaming it there would claim a verdict that
   * never existed. So the pane names absence as absence, and says so.
   * @param {Object} unit Unit projection.
   * @returns {string} Shipped bucket label, or the absence phrase.
   */
  function manualUnitAdvisoryLabel(unit) {
    const bucket = unitAdvisoryBucket(unit);
    return bucket === null ? "no advisory" : distributionValueLabel(bucket, ADVISORY_DISPLAY_ALIASES);
  }
  /**
   * Attention, scoped. `unit.attention.required` is the per-unit fact the run
   * fold counts; at unit scope the pane states that fact in the SHIPPED
   * attention alias ("required" / "not required") rather than a raw boolean.
   *
   * ABSENCE IS NOT "no", AND NOT AT EITHER SCOPE. `required === true ? "yes" :
   * "no"` collapses three cases into two: required, not required, and NO
   * ATTENTION RECORD AT ALL. A unit whose projection carries no attention
   * object was therefore read as "not required · basis parent log" — a negative
   * the projection never asserts, stamped with a provenance that observed
   * nothing. The parent Log is the basis for a fact READ off the record; there
   * is no record here, so there is nothing for it to be the basis of.
   *
   * BOTH branches answer to that, through ONE reader. The unit branch states
   * absence as absence and carries NO basis, exactly like `as-of-seq` carries
   * none: a reading with no evidence behind it must not borrow evidence from a
   * sibling. The run branch folds through runAttentionCounts, whose
   * unitAttentionBucket EXCLUDES an absent record from the count rather than
   * bucketing it in the negative — so the "N not required" the pane prints is a
   * count of units the projection actually said "no" about, and the fabricated
   * negative cannot survive by hiding inside a fold. Narrowing only the unit
   * branch would have left the same defect at the more-travelled run-detail
   * route, one branch away, in this same function.
   *
   * This differs from manualUnitAdvisoryLabel only in that the advisory fold
   * has a documented `present` flag; here the record's own existence is the
   * flag.
   * @param {{run: Object, unit: ?Object}} scope Painted scope.
   * @returns {{value: string, basis: ?string, scope: string}} Reading.
   */
  function manualAttentionReading(scope) {
    if (scope.unit) {
      const bucket = unitAttentionBucket(scope.unit);
      if (bucket === null) return {value: MANUAL_ATTENTION_ABSENT, basis: null, scope: manualUnitScopeLabel(scope.unit)};
      return {value: distributionValueLabel(bucket, ATTENTION_DISPLAY_ALIASES), basis: ATTENTION_FOLD_BASIS, scope: manualUnitScopeLabel(scope.unit)};
    }
    const phrase = manualDistributionPhrase(runAttentionCounts(scope.run), ATTENTION_BUCKET_ORDER, ATTENTION_DISPLAY_ALIASES);
    return {value: phrase || EMPTY_DISTRIBUTION_PHRASE, basis: ATTENTION_FOLD_BASIS, scope: MANUAL_SCOPE_RUN};
  }
  /**
   * The whole post-terminal dimension, answered about the run on screen. The
   * value is postTerminalLabel — the SHIPPED vocabulary the runs-list cell
   * (postTerminalCell) and the truth card (postTerminalCard) already print — so
   * the pane quotes the words the rail beside it uses rather than titleCasing
   * the raw state token. Words are contract (DESIGN.md binding constraint 1),
   * and a bare titleCase here had the manual read "None" under a heading every
   * other surface answers with the full shipped sentence.
   * It is RUN-SCOPED on every route, the Unit Inspector included: the record is
   * `run.post_terminal_child_activity`, measured from the parent run's own
   * terminal boundary, and no unit carries one. Reading it beside an open unit
   * therefore keeps saying "this run", which is what it is a fact about.
   * @param {{run: Object, unit: ?Object}} scope Painted scope.
   * @returns {?{value: string, basis: ?string, scope: string}} Reading, or null
   *   when the run carries no post-terminal record at all.
   */
  function manualPostTerminalReading(scope) {
    const activity = scope.run.post_terminal_child_activity;
    if (!activity || typeof activity !== "object") return null;
    return {value: postTerminalLabel(activity), basis: activity.basis, scope: MANUAL_SCOPE_RUN};
  }
  /**
   * One post-terminal VALUE, answered about the run on screen. The phrasing
   * mirrors manualLivenessValueReading so the two families of value-terms read
   * alike, and BOTH the affirmative and the negative name the state through
   * postTerminalLabel — the shipped vocabulary the list cell and the truth card
   * already print. Quoting it here is what keeps the pane and the rail saying
   * the same words about one value; raw titleCase would have this entry read
   * "Undetermined" where the rail reads "Undetermined (child evidence
   * unavailable)".
   * Run-scoped for the same reason the dimension is.
   * @param {{run: Object, unit: ?Object}} scope Painted scope.
   * @param {string} token The post-terminal state this term names.
   * @returns {?{value: string, basis: ?string, scope: string}} Reading, or null
   *   when the run carries no post-terminal record at all.
   */
  function manualPostTerminalValueReading(scope, token) {
    const activity = scope.run.post_terminal_child_activity;
    if (!activity || typeof activity !== "object" || !activity.state) return null;
    const affirmative = activity.state === token;
    const value = affirmative
      ? postTerminalLabel(activity)
      : "Not " + titleCase(token) + " — this run reads " + postTerminalLabel(activity);
    return {value: value, basis: activity.basis, scope: MANUAL_SCOPE_RUN};
  }
  /**
   * One liveness VALUE, answered about whatever entity the view is painting. A
   * unit carries its own liveness and the Inspector paints it, so on that route
   * the denial names the unit rather than the run folded around it.
   * @param {{run: Object, unit: ?Object}} scope Painted scope.
   * @param {string} token Detail-scope liveness state this term names.
   * @returns {?{value: string, basis: ?string, scope: string}} Reading, or null
   *   when the entity carries no liveness state.
   */
  function manualLivenessValueReading(scope, token) {
    const entity = scope.unit || scope.run;
    const state = entity.liveness && entity.liveness.state;
    if (!state) return null;
    const subject = scope.unit ? "this unit" : "this run";
    return {value: state === token ? titleCase(token) : "Not " + titleCase(token) + " — " + subject + " reads " + titleCase(state), basis: entity.liveness && entity.liveness.basis, scope: manualScopeLabel(scope)};
  }
  /**
   * A liveness value the DETAIL projection cannot produce, answered honestly.
   *
   * `unobserved` is folded by list_liveness alone; builder.ex's liveness/4 emits
   * no such token, so asking "is this run unobserved" of a detail projection is
   * asking a question whose answer is fixed before the run is consulted. The
   * denial the sibling value readers produce would therefore be a structural
   * artefact wearing the clothes of a live reading — and it would contradict the
   * runs-list cell the reader most likely clicked to get here, which does print
   * `unobserved` for this very run. So the pane states the scope fact, then
   * states what the entity in front of the reader actually reads. Both halves
   * are true at once, which the denial never was.
   * @param {{run: Object, unit: ?Object}} scope Painted scope.
   * @param {string} token The list-scope liveness state this term names.
   * @returns {?{value: string, basis: ?string, scope: string}} Reading, or null
   *   when the entity carries no liveness state.
   */
  function manualListOnlyLivenessReading(scope, token) {
    const entity = scope.unit || scope.run;
    const state = entity.liveness && entity.liveness.state;
    if (!state) return null;
    const subject = scope.unit ? "this unit" : "this run";
    return {
      value: "A list-scope value only — no detail projection reads " + titleCase(token) + ", so " + subject + " reads " + titleCase(state) + " here while its row in the Runs list may still read " + titleCase(token) + ".",
      basis: entity.liveness && entity.liveness.basis,
      scope: manualScopeLabel(scope)
    };
  }
  /**
   * One source MODE. Source is run-scoped by contract ("Source describes the
   * evidence the view was built from ... Source is run-scoped, never per unit"),
   * so this answers about the run even while a unit is open.
   * @param {{run: Object, unit: ?Object}} scope Painted scope.
   * @param {string} token Source mode this term names.
   * @returns {?{value: string, basis: ?string, scope: string}} Reading, or null
   *   when the run carries no source mode.
   */
  function manualSourceModeReading(scope, token) {
    const mode = scope.run.source && scope.run.source.mode;
    if (!mode) return null;
    return {value: mode === token ? titleCase(token) : "Not " + titleCase(token) + " — this run reads " + titleCase(mode), basis: scope.run.source && scope.run.source.durable_origin, scope: MANUAL_SCOPE_RUN};
  }
  /**
   * The inventory of glossary slugs this pane reads NO run-scoped value for,
   * computed ONCE from the corpus minus the reader table and frozen. It is
   * exported rather than re-derived by the anti-rot tier: two derivations of the
   * same set is two sources of truth for which terms this pane is allowed to
   * stay silent about.
   *
   * It is the set of pane SILENCES, not a claim that its members lack a per-run
   * value: a term the table has not bound yet lands here beside a genuinely
   * instrument-scoped one, and nothing downstream may read membership as the
   * latter.
   *
   * Derived rather than hand-listed so that a term added to the corpus lands in
   * the inventory automatically. Adding a term is therefore never a silent
   * fabrication; it is a visible entry the anti-rot tier can adjudicate.
   * @returns {Array<string>} Frozen, sorted slugs the reader table does not bind.
   */
  const MANUAL_NO_RUN_VALUE_SLUGS = (function () {
    const entries = manualEntries();
    if (entries === null) return Object.freeze([]);
    const unbound = entries
      .map(function (entry) { return entry && typeof entry.slug === "string" ? entry.slug : null; })
      .filter(function (slug) { return slug !== null && !Object.prototype.hasOwnProperty.call(MANUAL_RUN_READERS, slug); });
    return Object.freeze(unbound.sort());
  })();
  /**
   * Whether the view the pane is mounting BESIDE is actually showing a run.
   *
   * The route is a REQUEST, not a receipt. Every run-scoped renderer can bail
   * out to a view that shows no run while the hash still says `#/runs/<id>` —
   * `renderUnit` on an absent logical unit paints "Projection unavailable · this
   * logical unit is absent or its provisional deep link was invalidated", and it
   * does so WITHOUT clearing state.detail, so a route-shape guard passed every
   * identity check and the pane read live values beside a view declaring the
   * projection unavailable. That is the false-claim class this whole part exists
   * to prevent, so scope is decided by what was PAINTED, not by what was asked
   * for: the node handed to replaceContent is the view itself, and its class is
   * the renderer's own answer about which view it produced.
   *
   * The one error view that IS run-scoped is admitted by name rather than by
   * class. "Unit unavailable while following" states in its own copy that "the
   * followed run identity is still projected. Only this logical unit is absent
   * within the followed run" — the run really is on screen and really is the
   * followed one, so denying run scope there would make the pane refuse a value
   * the view beside it is affirming. Admission is keyed on the followState the
   * renderer stamps, so no other error view inherits it.
   * @param {?Element} painted The view node being mounted.
   * @returns {boolean} Whether a run is genuinely on screen.
   */
  function paintedRunScopeView(painted) {
    const classes = String((painted && painted.className) || "").split(/\s+/);
    if (classes.indexOf("detail-view") >= 0 || classes.indexOf("unit-view") >= 0) return true;
    return !!(painted && painted.dataset && painted.dataset.followState === "unit_unavailable");
  }
  /**
   * The run the pane may read, or null.
   *
   * The pane rides EVERY route family, and only the detail-scoped families have
   * a run on screen. The guard is the same identity check `renderCurrent` uses
   * to decide whether a cached detail may be painted at all — route view, route
   * run id, the workspace under workspace-set mode, and the snapshot's own
   * `run.id` — because anything looser would let the pane read a detail the view
   * beside it is no longer painting. Reading `state.detail` on a runs-list route
   * is exactly that defect: the list carries no run, so the last-visited detail
   * would be presented as "this run" while the operator looks at fifty others.
   *
   * The route checks are necessary and NOT sufficient: they establish that the
   * cached detail is the one this route names, never that a renderer painted it.
   * paintedRunScopeView supplies the missing half, so the pane reads a run only
   * when the view beside it is showing that run.
   *
   * Nothing is cached here; the run is resolved fresh on every render.
   * @param {Object} route Parsed route.
   * @param {?Element} painted The view node being mounted beside the pane.
   * @returns {?Object} Projected run detail in scope, or null.
   */
  function manualRunInScope(route, painted) {
    if (!route || (route.view !== "detail" && route.view !== "unit")) return null;
    if (!route.runId) return null;
    if (!paintedRunScopeView(painted)) return null;
    const run = state.detail;
    if (!run || !run.run || run.run.id !== route.runId) return null;
    if (state.detailId !== route.runId) return null;
    if (workspaceSetMode() && state.detailWorkspace !== route.workspace) return null;
    return run;
  }
  /**
   * ON THIS RUN, rendered into the open entry's part list.
   *
   * Three outcomes, and each is a DIFFERENT honest statement:
   *
   *   - Term is unbound: the part is OMITTED entirely. There is no run-scoped
   *     value to state, and a heading promising one over a hedge is worse than
   *     no heading.
   *   - Term is bound but no run is in scope: the part says SO, naming the scope
   *     the reader is actually in. It never falls back to a remembered detail,
   *     and "in scope" means the view beside the pane is PAINTING that run.
   *   - Term is bound and a run is in scope: value · scope · basis · as of seq,
   *     in the shipped vocabulary, read from the same snapshot AND the same
   *     entity the view is painted from.
   *
   * @param {Element} parts The <dl> being built.
   * @param {Object} route Parsed route.
   * @param {Object} entry Resolved glossary entry.
   * @param {?Element} painted The view node being mounted beside the pane.
   * @returns {boolean} Whether the part was emitted.
   */
  function renderManualOnThisRun(parts, route, entry, painted) {
    const slug = scalar(entry && entry.slug, "");
    if (!Object.prototype.hasOwnProperty.call(MANUAL_RUN_READERS, slug)) return false;
    parts.append(text("dt", "ON THIS RUN"));
    const run = manualRunInScope(route, painted);
    if (!run) {
      parts.append(text("dd", manualNoRunCopy(route, painted), "manual-no-run"));
      return true;
    }
    let reading = null;
    // A reader touches projected fields, and a projection that drifted shape is
    // not a reason to take the pane down with it. A throwing reader degrades to
    // the same statement as a missing value: the pane says it could not read
    // one, which is true, rather than blanking the whole entry.
    try { reading = MANUAL_RUN_READERS[slug]({run: run, unit: manualUnitInScope(run, route)}); } catch (_error) { reading = null; }
    if (!reading) {
      parts.append(text("dd", "This run's projection carries no value for this term. The dimension exists in the schema; this snapshot did not populate it, so nothing is stated here.", "manual-no-run"));
      return true;
    }
    const dd = el("dd", "manual-on-this-run");
    dd.dataset.manualSlug = slug;
    dd.append(untrustedText("span", scalar(reading.value, "unknown"), "manual-run-value"));
    // The SCOPE the value was folded over, printed on every reading without
    // exception. A count carries no meaning without its population, and the two
    // run-scoped views fold different ones: the rail folds the whole run, the
    // Unit Inspector paints one unit. Naming it is what lets a reader tell "1
    // held · 3 ready across this run" from "Held on this unit" instead of
    // reading whichever number the pane happened to have and assuming it was
    // about the thing they were looking at.
    dd.dataset.manualScope = scalar(reading.scope, MANUAL_SCOPE_RUN);
    dd.append(untrustedText("span", " · on " + scalar(reading.scope, MANUAL_SCOPE_RUN), "manual-run-scope"));
    if (reading.basis) dd.append(untrustedText("span", " · basis " + titleCase(reading.basis), "manual-run-basis"));
    // The as-of seq is the SAME parent Log sequence the status line and the run
    // overview print, so a reader can line the three up. It is suppressed for
    // the as-of-seq entry itself, whose value already IS that sequence.
    const seq = run.source && run.source.as_of_seq;
    if (!reading.suppressAsOf && seq !== null && seq !== undefined) dd.append(untrustedText("span", " · as of seq " + scalar(seq, "unknown"), "manual-run-seq"));
    parts.append(dd);
    return true;
  }
  /**
   * What the part says when the term IS bound but the route has no run.
   *
   * Stated in the Monitor's own vocabulary and naming the actual scope, because
   * "no run in scope" alone reads as a failure. The runs list and the Workspace
   * Overview are ordinary destinations, not outages; the honest sentence tells
   * the reader where the value CAN be seen rather than implying something broke.
   * The route-names-a-run case splits in two, because the two are different
   * facts and only one of them is an outage. A route whose renderer BAILED —
   * the run absent from the snapshot, the logical unit gone, the projection
   * failed — has a view beside the pane already saying what went wrong, and the
   * honest part points at it rather than repeating a diagnosis it did not make.
   * @param {Object} route Parsed route.
   * @param {?Element} painted The view node being mounted beside the pane.
   * @returns {string} Copy for the no-run-in-scope part.
   */
  function manualNoRunCopy(route, painted) {
    const view = route && route.view;
    if (view === "runs") return "No run is in scope. The Runs list shows many runs at once, so there is no single run to read this from; open one run to see its value here.";
    if (view === "workspaces") return "No run is in scope. The Workspace Overview is above run scope, so there is no run to read this from; open a workspace's Runs list and then one run to see its value here.";
    if (view === "invalid") return "No run is in scope. This route could not be resolved to a run, so nothing is read from a projection here.";
    if (!paintedRunScopeView(painted)) return "No run is in scope. This route names a run, but the view beside this pane is not painting one; read that view for why. Nothing is read from a remembered projection here.";
    return "No run is in scope. This route names a run, but no matching authoritative snapshot is painted right now, so nothing is read from it here.";
  }
  /**
   * One open entry, in the four-part doctrine shape.
   *
   * HOW IT IS DERIVED renders the authored `code_citation` VERBATIM. Its line
   * pins are known-stale against the current tree (they were anchored at the
   * corpus authorship base) and are deliberately neither updated nor asserted
   * on: the function-name anchors are the durable part, and rewriting a pin here
   * would launder an authored citation into a claim this pane cannot back.
   *
   * ON THIS RUN is emitted by renderManualOnThisRun, which OMITS it for terms
   * the reader table does not bind rather than printing a hedge under a heading
   * that promises a live value.
   */
  function renderManualEntry(root, route, entry, painted) {
    root.append(untrustedText("h3", scalar(entry.term, entry.slug), "manual-entry-term"));
    // The surface string is how the term APPEARS on screen, which for many
    // entries is the term itself; showing it twice teaches nothing. It is also a
    // SLOT TEMPLATE for some entries ("Declared gate: <state>", "Evidence (N)"):
    // it is rendered verbatim as the authored pattern and is never filled in
    // here, because filling a slot would state a value this pane cannot source.
    const surface = scalar(entry.surface_string, "");
    if (surface && surface !== scalar(entry.term, "")) root.append(untrustedText("p", surface, "manual-entry-surface"));
    const parts = el("dl", "manual-parts");
    function part(label, value, className) {
      parts.append(text("dt", label));
      parts.append(untrustedText("dd", value, className));
    }
    part("Plain definition", scalar(entry.plain_definition, "No plain definition is authored for this term."));
    part("HOW IT IS DERIVED", scalar(entry.code_citation, "No citation is authored for this term."), "manual-citation");
    part("DO NOT READ IT AS", scalar(entry.confused_with, "No confusable is authored for this term."));
    const bound = renderManualOnThisRun(parts, route, entry, painted);
    root.append(parts);
    // The OMISSION is confessed rather than left as a silent gap. A reader who
    // sees the part on Liveness and not on run_not_found would otherwise be left
    // to guess whether the pane failed to read a value or the part is simply
    // absent; saying which it is costs one sentence and closes the question.
    //
    // The sentence claims something about THIS PANE and nothing about the term.
    // It used to assert that an unbound term "names a property of the instrument
    // rather than a reading off a run" — a categorical claim about the term's
    // NATURE, and false for a good part of the unbound set: `limitations`,
    // `mutation`, `evidence-basis` and `declared-gate` are every bit a reading
    // off a run, and this same projection carries them (run.limitations at
    // limitationsPanel, run.mutation and run.mutation.basis at mutationPanel,
    // unit.advisory.declared_gate in the Unit Inspector), painted by the rail
    // inches from the pane. Asserting they are instrument properties is the same
    // defect class as fabricating a value: the pane would teach a falsehood
    // about the term while the view beside it contradicts the lesson. The
    // unbound set is corpus-minus-table, so it mixes genuinely instrument-scoped
    // terms with terms this table has simply not bound yet; no wording that
    // characterises the TERM can be true of all of it. Stating the pane's own
    // silence is true of every member and stays true as the table grows.
    if (!bound) root.append(text("p", "This pane does not read a run-scoped value for this term, so there is no ON THIS RUN part for it. That is a statement about this pane only, not a claim that the term has no per-run value elsewhere in the Monitor.", "provenance manual-unbound"));
    root.append(text("p", "Citations are authored grounding. Their line numbers are historical and are not maintained against the current tree; the module and function names are the durable anchors.", "provenance"));
    root.append(link("All terms", manualRoute(route, MANUAL_INDEX), "manual-index"));
    return root;
  }
  /**
   * The pane itself. Returns null when the manual field is absent, which is what
   * keeps every existing view byte-identical when the overlay is closed.
   * @param {Object} route Parsed route.
   * @returns {?Element}
   */
  function renderManualPane(route, painted) {
    const requested = manualField(route && route.manual);
    if (!requested) return null;
    const pane = el("aside", "manual-pane");
    // <aside> is a COMPLEMENTARY landmark, so it is announced in the landmark
    // rota whether or not it has a name — and an unnamed one is announced as a
    // bare "complementary", which tells a screen-reader operator nothing about
    // which of the page's regions they just landed in. Every other landmark-level
    // region in this bundle carries a name (the truth-dimension rail, the cluster
    // overview, the attempt-lineage nav, the filter and search forms); this was
    // the only one without. Named with the same direct aria-label idiom they use.
    pane.setAttribute("aria-label", "Instrument manual");
    pane.dataset.manual = requested;
    // The entry is resolved BEFORE the header so the route chip can name what
    // the pane is actually showing. An unresolved slug lands the reader on the
    // index, so the chip must read "#manual/index" — pinning the requested slug
    // there would print a route that does not open this content.
    const entry = requested === MANUAL_INDEX ? null : manualEntry(requested);
    const shownSlug = entry ? requested : MANUAL_INDEX;
    const header = el("header", "manual-pane-header");
    // The heading is a programmatic focus target (tabIndex -1, never in the tab
    // order) so opening the pane can land focus INSIDE it. Without it the only
    // deliberate entry point would be the Close link, which reads as "you are
    // about to leave" rather than "you have arrived".
    const heading = text("h2", "Instrument manual");
    heading.tabIndex = -1;
    header.append(key(heading, "manual-heading"));
    // THE ROUTE IDENTITY, rendered. Hash-routing is load-bearing for this pane
    // (DESIGN.md: "definitions must be linkable in issues and PRs") and both the
    // index lede and the mock tell the reader to paste a hash route into an
    // issue. Showing none made that an instruction the pane never instantiated —
    // the reader was told to paste a route and never shown one. It is emitted as
    // untrusted text like every other variable string here, even though
    // manualField already shape-checked the slug.
    header.append(untrustedText("code", "#manual/" + shownSlug, "manual-route-id"));
    header.append(key(link("Close", manualRoute(route, null), "manual-close"), "manual-close"));
    pane.append(header);
    const body = el("div", "manual-pane-body");
    if (entry) renderManualEntry(body, route, entry, painted);
    else renderManualIndex(body, route, requested === MANUAL_INDEX ? null : requested);
    pane.append(body);
    pane.append(text("p", "Press ? anywhere to open this pane · esc closes it.", "manual-keys"));
    return pane;
  }

  // Tab/focus model (pinned minimum): every interactive element is a native
  // control (a, button, select, summary) in DOM order — filters first, then the
  // attention group, then remaining groups; continuation buttons carry
  // data-focus-key ("continuation:" + pageKey) so focus survives re-render, and
  // :focus-visible outlines stay enabled at every viewport width.
  function captureView() {
    const active = document.activeElement;
    const open = [];
    const route = arguments.length ? {runId: arguments[0], workspace: arguments[1]} : parseRoute(location.hash);
    document.querySelectorAll("details[data-disclosure-key]").forEach(function (node) { if (node.open) open.push(scopedDisclosureValue(node.dataset.disclosureKey, route)); });
    return {scrollX: window.scrollX, scrollY: window.scrollY, focus: active && active.dataset ? active.dataset.focusKey || null : null, open: open, runId: route.runId || null, workspace: route.workspace || null};
  }
  function restoreView(saved) {
    if (!saved) return;
    array(saved.open).forEach(function (id) {
      const node = Array.from(document.querySelectorAll("details[data-disclosure-key]")).find(function (candidate) { return scopedDisclosureValue(candidate.dataset.disclosureKey) === id; });
      if (node) node.open = true;
    });
    // `focusFallback` is the caller's declaration that focus is CURRENTLY on a
    // node this re-render is about to destroy, so landing somewhere in the
    // repainted view is mandatory even when no key was saved. Without it a null
    // key meant "nothing to restore" and the whole block — fallback included —
    // was skipped: focus stayed on the detached node, document.activeElement
    // collapsed to body, and the next Tab restarted at the top of the document.
    // That is the same keyboard dead-end the fallback below exists to close, so
    // the two must not be reachable independently. An ordinary re-render passes
    // no flag and keeps its old behaviour of never stealing focus.
    if (saved.focus || saved.focusFallback) {
      const focusNode = saved.focus ? Array.from(document.querySelectorAll("[data-focus-key]")).find(function (candidate) { return candidate.dataset.focusKey === saved.focus || candidate.dataset.focusKey === clientStateKey(saved.focus); }) : null;
      // A saved key whose element this re-render destroyed used to drop focus
      // silently onto document.body, so the next Tab restarted at the top of the
      // document — a keyboard dead-end. The first focusable control of the
      // repainted view is a bounded, in-place fallback: the operator lands where
      // the view begins rather than where the document does.
      if (focusNode) focusNode.focus({preventScroll: true});
      else {
        const fallback = app.querySelectorAll("[data-focus-key]")[0];
        if (fallback) fallback.focus({preventScroll: true});
      }
    }
    window.scrollTo(saved.scrollX || 0, saved.scrollY || 0);
  }
  function replaceContent(node, announcement) {
    const saved = state.restore || captureView();
    state.restore = null;
    delete app.dataset.errorPhase;
    delete app.dataset.errorKind;
    const route = parseRoute(location.hash);
    const held = route.workspace && workspaceSnapshots[route.workspace];
    const heldError = held && (route.view === "runs" ? held.listError : held.detailError);
    const heldPayload = held && (route.view === "runs" ? held.list : held.detailId === route.runId ? held.detail : null);
    if (heldPayload && heldError && route.view !== "workspaces") {
      const disclosure = el("div", "stale-disclosure");
      const heldObservedAt = route.view === "runs" ? held.listObservedAt : held.detailObservedAt;
      disclosure.append(untrustedText("strong", "Stale source snapshot · received " + (displayInstant(heldObservedAt) || scalar(heldObservedAt, "unknown")) + " · refresh failure " + heldError.kind));
      disclosure.append(text("p", route.view === "runs" ? "Held data is not current. Retry refetches only this authoritative source." : "Held data is not current. Return to the runs list to retry this source.", "provenance"));
      if (route.view === "runs") disclosure.append(key(button("Retry this source", function () {
        refetchWorkspaceList(route.workspace, "source retry");
      }, "source-retry"), "runs-source-retry:" + route.workspace));
      node.prepend(disclosure);
    }
    // The manual mounts HERE, at the single seam every renderer already funnels
    // through, so the pane rides beside whatever view is painted without any
    // renderer knowing it exists. Layout is PUSHED, not replaced: the view keeps
    // its own node and its own subtree, and the pane is a sibling. With the
    // overlay closed the DOM is exactly what it was before this change.
    const pane = renderManualPane(route, node);
    if (pane) {
      const shell = el("div", "manual-shell");
      shell.append(node);
      shell.append(pane);
      app.replaceChildren(shell);
    } else app.replaceChildren(node);
    restoreView(saved);
    announce(announcement);
  }
  function announce(message) {
    let region = document.getElementById("pixir-live-region");
    if (!region) {
      region = text("div", "", "sr-only");
      region.id = "pixir-live-region";
      region.setAttribute("role", "status");
      region.setAttribute("aria-live", "polite");
      region.setAttribute("aria-atomic", "true");
      document.body.append(region);
    }
    setText(region, message || "Projection updated.");
  }

  /**
   * The SSE health pill's vocabulary FOR ONE OBSERVED STREAM STATE, as an
   * ordered list of the manual terms the pill is currently showing.
   *
   * This is the single source both the pill (setStatus) and its orientation
   * line (streamVocabularyLine) read. It exists because the two drifted: the
   * line asserted unconditionally that the pill "says hints only and
   * coalesced", while "coalesced" is only ever emitted on the connected state.
   * On a down or connecting stream the first screen quoted pill text that was
   * not on screen — the Monitor asserting absent text, which is the exact
   * dishonesty this affordance exists to prevent.
   *
   * Every term returned here is a key of LABELLED_TERMS, so the orientation
   * line can link each one without a second table.
   * @param {string} streamState Observed stream state.
   * @returns {string[]} Manual terms present in this state's pill text.
   */
  function streamVocabularyTerms(streamState) {
    return streamState === "connected" ? ["hints only", "coalesced"] : ["hints only"];
  }
  function streamHealthText(streamState) {
    return streamState === "connected"
      ? "SSE connected · hints only · coalesced"
      : streamState === "down"
        ? "SSE down · hints only · authoritative snapshots remain available"
        : "SSE connecting · hints only · authoritative snapshots remain available";
  }
  function setStatus(message) {
    setText(status, message);
    let pill = document.getElementById("sse-health");
    if (!pill) { pill = el("span", "sse-health"); pill.id = "sse-health"; status.insertAdjacentElement("afterend", pill); }
    pill.className = "sse-health sse-" + state.streamState;
    const refetch = state.lastAuthoritativeRefetchAt ? state.lastAuthoritativeRefetchAt.toISOString().replace(/\.\d{3}Z$/, "Z") : "not yet";
    setText(pill, streamHealthText(state.streamState) + " · last successful authoritative refetch " + refetch);
    // The orientation line QUOTES the pill, so a stream transition that repaints
    // the pill without re-rendering the view would leave the quote stale — the
    // same absent-text claim in slower motion. Repaint it from the same source.
    //
    // Only when the quoted vocabulary ACTUALLY CHANGED. setStatus runs on the
    // tail of every render, so an unconditional repaint would rebuild this line's
    // whole subtree on renders that have nothing to say — throwing away the
    // operator's text selection and any in-progress interaction for no change in
    // what is on screen. `__pixirTerms` records what the line is showing, so the
    // repaint fires on a real state transition and never on a same-state render.
    //
    // This guard is NOT the focus protection, and must never be mistaken for it.
    // A REAL transition still destroys the line's anchors, and the transitions
    // that matter most (source.onopen, source.onerror) reach setStatus with no
    // view re-render and therefore no restoreView anywhere near them. Focus
    // preservation lives inside repaintStreamVocabularyLine, with the
    // destruction it protects against, so it holds on the transition path this
    // guard deliberately lets through.
    const vocabulary = document.querySelector(".stream-vocabulary");
    if (vocabulary && vocabulary.__pixirRoute && vocabulary.__pixirTerms !== streamVocabularyTerms(state.streamState).join(" ")) {
      repaintStreamVocabularyLine(vocabulary, vocabulary.__pixirRoute);
    }
  }

  function parseInstant(value) {
    if (typeof value !== "string" || !value) return null;
    const ms = Date.parse(value);
    return Number.isFinite(ms) ? ms : null;
  }
  /**
   * Second-precision display of a projected or receipt instant. Fractional seconds are evidence, not UI copy.
   * @param {*} value ISO-8601-like string, or empty.
   * @returns {string}
   */
  function displayInstant(value) {
    if (typeof value !== "string" || !value) return "";
    return value.replace(/\.\d+(?=Z|[+-]\d{2}:\d{2}$)/, "");
  }
  /**
   * One remaining-run line from fields already on the list row. Never invents
   * a title, execution state, or started-at the snapshot did not project.
   * @param {Object} row List row from the held scoped snapshot.
   * @returns {string}
   */
  function remainingRunLabel(row) {
    const id = row && (row.id || row.run && row.run.id);
    const title = row && typeof row.title === "string" && row.title ? row.title : "";
    const parts = [title || scalar(id, "Unnamed run")];
    const state = row && row.execution && typeof row.execution.state === "string" ? row.execution.state : "";
    if (state) parts.push(state);
    const started = displayInstant(temporalField(row, "started_at").value);
    if (started) parts.push(started);
    return parts.join(" · ");
  }
  function normalizedInstant(value, ms) {
    const match = typeof value === "string" ? value.match(/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.(\d+))?(?:Z|[+-]\d{2}:\d{2})$/) : null;
    if (!match || ms === null) return "";
    const utcSecond = new Date(Math.floor(ms / 1000) * 1000).toISOString().slice(0, 19);
    return utcSecond + "." + (match[1] || "").padEnd(9, "0").slice(0, 9) + "Z";
  }
  /**
   * Reads one field of the frozen temporal schema from a list row. Each boundary
   * is {value, basis, completeness} with completeness one of complete,
   * incomplete, unknown, or malformed; a missing boundary is honestly "unknown"
   * and is never manufactured from the browser clock or stream receipt. Rows
   * predating the schema fall back to the legacy latest_at string.
   * @param {Object} row Projected list row.
   * @param {string} name "started_at" | "ended_at" | "latest_at" | "duration".
   * @returns {Object} Boundary or duration map, never null.
   */
  function temporalField(row, name) {
    const temporal = row && row.temporal;
    const value = temporal && typeof temporal === "object" ? temporal[name] : null;
    if (value && typeof value === "object") return value;
    if (name === "latest_at") {
      const legacy = row && typeof row.latest_at === "string" && row.latest_at ? row.latest_at : null;
      if (legacy === null) return {value: null, basis: null, completeness: "unknown"};
      return {value: legacy, basis: "max_parent_event_ts", completeness: parseInstant(legacy) === null ? "malformed" : "complete"};
    }
    if (name === "duration") return {ms: null, basis: "boundary_difference", completeness: "unknown"};
    return {value: null, basis: null, completeness: "unknown"};
  }
  function completenessRank(completeness) {
    return COMPLETENESS_RANK[completeness] === undefined ? COMPLETENESS_RANK.unknown : COMPLETENESS_RANK[completeness];
  }
  // Pinned total order per sort: complete values first in the sort direction, then
  // incomplete, then unknown, then malformed; exact ties break by ascending run id.
  function sortRank(row, sort) {
    if (sort === "duration_desc" || sort === "duration_asc") {
      const duration = temporalField(row, "duration");
      const ms = duration.completeness === "complete" && typeof duration.ms === "number" && Number.isFinite(duration.ms) ? duration.ms : null;
      if (ms === null) return {rank: Math.max(completenessRank(duration.completeness), 1), value: 0};
      return {rank: 0, value: sort === "duration_asc" ? ms : -ms};
    }
    const latest = temporalField(row, "latest_at");
    const instant = latest.completeness === "complete" ? parseInstant(latest.value) : null;
    if (instant === null) return {rank: Math.max(completenessRank(latest.completeness), 1), value: 0};
    return {rank: 0, value: sort === "recency_asc" ? instant : -instant, normalized: normalizedInstant(latest.value, instant)};
  }
  /**
   * Comparator factory for the pinned total order of a sort vocabulary entry:
   * complete values first in the sort direction, then incomplete, then unknown,
   * then malformed; sub-millisecond recency ties use the normalized instant and
   * exact ties break by ascending run id.
   * @param {string} sort Entry of SORT_VOCABULARY.
   * @returns {function(Object, Object): number}
   */
  function runsComparator(sort) {
    return function (a, b) {
      const left = sortRank(a, sort);
      const right = sortRank(b, sort);
      if (left.rank !== right.rank) return left.rank - right.rank;
      if (left.value !== right.value) return left.value < right.value ? -1 : 1;
      if (left.normalized !== right.normalized) {
        if (sort === "recency_desc") return left.normalized > right.normalized ? -1 : 1;
        return left.normalized < right.normalized ? -1 : 1;
      }
      const leftId = scalar(a && a.id, "");
      const rightId = scalar(b && b.id, "");
      return leftId < rightId ? -1 : leftId > rightId ? 1 : 0;
    };
  }
  function formatDurationMs(ms) {
    const total = Math.max(Math.floor(ms / 1000), 0);
    const hours = Math.floor(total / 3600);
    const minutes = Math.floor((total % 3600) / 60);
    const seconds = total % 60;
    if (hours > 0) return hours + " h " + minutes + " m";
    if (minutes > 0) return minutes + " m " + seconds + " s";
    return seconds + " s";
  }
  /**
   * Human label for a duration map. Only a complete duration renders a value;
   * incomplete and malformed durations confess themselves instead of guessing.
   * @param {Object} duration Duration map from temporalField.
   * @returns {string}
   */
  function durationLabel(duration) {
    if (duration.completeness === "complete" && typeof duration.ms === "number" && Number.isFinite(duration.ms)) return formatDurationMs(duration.ms);
    if (duration.completeness === "incomplete") return "Incomplete · no end boundary";
    if (duration.completeness === "malformed") return "Malformed timestamp";
    return "Unknown";
  }
  // Display convenience only: the projected absolute timestamp always stays visible
  // and no missing boundary is ever backfilled from the browser clock.
  function relativeLabel(boundary) {
    if (boundary.completeness !== "complete") return null;
    const instant = parseInstant(boundary.value);
    if (instant === null) return null;
    const deltaSeconds = Math.round((Date.now() - instant) / 1000);
    if (deltaSeconds < 0) return "≈ in the future by local clock";
    if (deltaSeconds < 60) return "≈ " + deltaSeconds + " s ago";
    if (deltaSeconds < 3600) return "≈ " + Math.floor(deltaSeconds / 60) + " m ago";
    if (deltaSeconds < 86400) return "≈ " + Math.floor(deltaSeconds / 3600) + " h ago";
    return "≈ " + Math.floor(deltaSeconds / 86400) + " d ago";
  }
  function rowValue(row, keyName) {
    if (keyName === "strategy") return row.strategy;
    if (keyName === "execution") return row.execution && row.execution.state;
    if (keyName === "liveness") return row.liveness && row.liveness.state;
    if (keyName === "source") return row.source && row.source.mode;
    if (keyName === "attention") return row.counts && row.counts.attention_units > 0 ? "yes" : "no";
    return null;
  }
  /**
   * Assigns a list row to a rendered group. Grouping is parent-observed
   * attention or nothing: list scope carries no activity evidence, so no group
   * may claim liveness.
   * @param {Object} row Projected list row.
   * @returns {string} Group heading.
   */
  function groupFor(row) {
    if (row && row.counts && row.counts.attention_units > 0) return "Needs attention";
    return "Recent";
  }
  /**
   * Visible basis note for a liveness state at list scope. List rows reread the
   * parent Log only, so a nonterminal row is "unobserved" (evidence unavailable,
   * not a health claim) and a terminal row needs no activity state; detail scope
   * may load owner diagnostics and legitimately differ.
   * @param {string} livenessState Projected liveness state.
   * @returns {?string} Note text, or null when the state carries none.
   */
  function livenessCellNote(livenessState) {
    if (livenessState === "unobserved") return "Activity evidence unavailable at list scope (parent Log only). Detail may load owner diagnostics.";
    if (livenessState === "stale_handle") return "Owner handle is stale; last observed evidence no longer confirms activity.";
    if (livenessState === "not_applicable") return "Terminal per parent Log; liveness does not apply.";
    return null;
  }
  /**
   * Short label for the post-terminal child-activity dimension. A child Log is
   * durable evidence of PAST writes, so this never reads as a liveness or
   * reachability claim: it says work was recorded after the parent ended, and
   * nothing about whether anything is running now.
   * @param {Object} activity post_terminal_child_activity, list or detail form.
   * @returns {string} Label text.
   */
  function postTerminalLabel(activity) {
    const state = activity && activity.state;
    if (state === "observed") return scalar(activity.event_count, "?") + " child events after the run ended";
    if (state === "none") return "No child events after the run ended";
    if (state === "undetermined") return "Undetermined (child evidence unavailable)";
    if (state === "not_applicable") return "Not applicable (run is not terminal)";
    return "Unknown";
  }
  /**
   * Names the parent-only evidence the boundary and the count came from, so the
   * reader can see this is not a wall-clock or SSE-derived claim.
   * @param {Object} activity post_terminal_child_activity, list or detail form.
   * @returns {string} Provenance note.
   */
  function postTerminalNote(activity) {
    const state = activity && activity.state;
    if (state === "undetermined") return "Child Log unavailable; absence of post-terminal activity is not asserted.";
    if (state === "not_applicable") return "No terminal boundary exists yet, so no event can be after it.";
    return "Boundary derived from parent Log evidence only; counted from child Log writes, not from any reachability observation.";
  }
  function postTerminalCell(activity) {
    const cell = el("td", "post-terminal-cell");
    const state = activity && activity.state;
    const tone = scalar(state, "unknown");
    const node = text("span", postTerminalLabel(activity), "post-terminal post-terminal-" + tone + " marker marker-" + tone);
    node.dataset.postTerminalState = scalar(state, "unknown");
    node.dataset.provenance = scalar(activity && activity.basis, "unknown");
    cell.append(node);
    if (activity && activity.latest_event_at) cell.append(untrustedText("span", scalar(activity.latest_event_at, "Unknown"), "absolute-ts"));
    cell.append(text("span", postTerminalNote(activity), "post-terminal-basis"));
    return cell;
  }
  function listRows(payload) {
    const raw = payload && Array.isArray(payload.runs) ? payload.runs : (Array.isArray(payload) ? payload : []);
    return raw.filter(validListRow);
  }
  /**
   * Resolves a Session id against the parent-observed `children` already carried
   * by held authoritative list rows (issue #438). This is the ONLY resolution
   * primitive: a pure, side-effect-free, EXACT-equality scan. It never reads a
   * child Log, never builds or persists an index, and never touches the network.
   * Every in-scope observer is returned in held-inventory order — ambiguity is
   * surfaced, never resolved by silently picking one.
   * @param {*} sessionId Requested Session id (only a non-empty string can match).
   * @param {*} rows Held authoritative list rows for the routed scope.
   * @returns {Array<{runId: string, unitId: (string|null), childSessionId: string}>}
   */
  function resolveParentObservedChild(sessionId, rows) {
    if (typeof sessionId !== "string" || !sessionId) return [];
    const candidates = [];
    array(rows).forEach(function (row) {
      const runId = scalar(row && row.id, "");
      if (!runId) return;
      array(row && row.children).forEach(function (child) {
        if (!child || typeof child !== "object") return;
        // Exact equality between two strings: no prefix, substring, or case
        // folding, and a non-string session_id is rejected before comparison
        // rather than coerced into something that could collide with a real id.
        if (typeof child.session_id !== "string" || child.session_id !== sessionId) return;
        const unitId = typeof child.unit_id === "string" && child.unit_id ? child.unit_id : null;
        candidates.push({runId: runId, unitId: unitId, childSessionId: sessionId});
      });
    });
    return candidates;
  }
  /**
   * The authoritative list rows held for the ROUTED scope. In workspace-set mode
   * only the routed workspace's snapshot is consulted, so a child observed in a
   * sibling workspace can never resolve here.
   * @param {Object} route Parsed route.
   * @returns {Array<Object>}
   */
  function heldInventoryRows(route) {
    if (workspaceSetMode()) { const scoped = workspaceSnapshots[route.workspace]; return scoped && scoped.list ? listRows(scoped.list.snapshot) : []; }
    return listRows(state.list);
  }
  /**
   * Held inventory metadata for the routed scope. The A payload lives here —
   * named unprojected Logs — so a dropped-parent page can show size and kind
   * without inventing an id the snapshot did not name.
   * @param {Object} route Parsed route.
   * @returns {Object|null}
   */
  function heldInventory(route) {
    if (workspaceSetMode()) {
      const scoped = route && route.workspace ? workspaceSnapshots[route.workspace] : null;
      return scoped && scoped.list && scoped.list.snapshot ? scoped.list.snapshot.inventory : null;
    }
    return state.list && state.list.inventory;
  }
  function droppedLogsFromInventory(inventory) {
    return array(inventory && inventory.limitations).flatMap(function (limitation) {
      const details = limitation && limitation.details && typeof limitation.details === "object" && !Array.isArray(limitation.details) ? limitation.details : {};
      return array(details.dropped).filter(function (row) { return row && typeof row === "object" && !Array.isArray(row) && typeof row.id === "string" && row.id; });
    });
  }
  function droppedLogById(route, id) {
    if (typeof id !== "string" || !id) return null;
    return droppedLogsFromInventory(heldInventory(route)).find(function (row) { return row.id === id; }) || null;
  }
  function boundedLogNote(projection) {
    const limits = array(projection && projection.source && projection.source.limitations);
    const record = limits.find(function (value) { return typeof value === "string" && value.startsWith("parent_log_prefix_tail:"); });
    if (!record) return null;
    const metrics = /^parent_log_prefix_tail:bytes_omitted=(\d+);events_omitted=unknown;events_retained=(\d+);bytes_read=(\d+)$/.exec(record);
    const amount = metrics ? metrics[1] + " bytes omitted; omitted events unknown; " + metrics[2] + " events retained; " + metrics[3] + " bytes read. " : "Omitted bytes and events unknown. ";
    return text("p", "Partial parent Log — prefix + tail only. " + amount + "Event, child, unit and usage counts describe selected evidence and are lower bounds, not complete totals. Missing middle work is not known complete.", "bounded-log-note provenance");
  }

  function byteBoundLabel(bytes) {
    if (!Number.isSafeInteger(bytes) || bytes < 0) return "";
    if (bytes % (1024 * 1024) === 0) return (bytes / (1024 * 1024)) + " MB";
    if (bytes % 1024 === 0) return (bytes / 1024) + " KB";
    return bytes + " bytes";
  }
  function posixInstant(mtime) {
    if (!Number.isSafeInteger(mtime) || mtime < 0) return "";
    return displayInstant(new Date(mtime * 1000).toISOString());
  }
  /**
   * Expand-only honesty for unprojected selected Logs. The 8 MB cap is one
   * reason a Log lands here; mixed kinds are not hung on that cap.
   * @param {Array<Object>} dropped Named drop rows from the A payload.
   * @returns {string}
   */
  function droppedLogsSummary(dropped) {
    const rows = array(dropped);
    const count = rows.length;
    const capRows = rows.filter(function (row) { return row && row.kind === "run_log_limit"; });
    const cap = capRows[0] && Number.isSafeInteger(capRows[0].max_log_bytes) ? capRows[0].max_log_bytes : null;
    const capLabel = cap === null ? "" : byteBoundLabel(cap);
    if (!count) return "";
    if (capRows.length === count && capLabel) return count + " not projected (per-log cap) · the " + capLabel + " cap is one reason a Log lands here";
    if (capRows.length && capLabel) return count + " not projected · the " + capLabel + " cap is one reason a Log lands here";
    return count + " not projected";
  }
  function droppedLogRowLabel(row) {
    const id = scalar(row && row.id, "unknown");
    const bytes = scalar(row && row.bytes, "unknown");
    const rank = row && row.newest_rank;
    const recency = Number(rank) === 1 ? "newest selected" : "selected rank " + scalar(rank, "unknown");
    const mtime = posixInstant(row && row.mtime);
    const kind = scalar(row && row.kind, "unknown");
    let label = id + " · " + bytes + " bytes · " + recency;
    if (mtime) label += " · mtime " + mtime;
    label += " · " + kind;
    if (row && row.kind === "run_log_limit") {
      label += " · raise max_log_bytes";
      if (row.max_log_bytes !== null && row.max_log_bytes !== undefined) label += " (" + scalar(row.max_log_bytes, "unknown") + ")";
    }
    return label;
  }
  function appendDroppedLogRows(dropped) {
    const rows = array(dropped).filter(function (row) { return row && typeof row === "object" && !Array.isArray(row) && typeof row.id === "string" && row.id; });
    if (!rows.length) return null;
    const wrap = el("div", "inventory-dropped-logs");
    wrap.append(untrustedText("p", droppedLogsSummary(rows)));
    const list = el("ul", "inventory-dropped-log-rows");
    rows.forEach(function (row) { list.append(untrustedText("li", droppedLogRowLabel(row))); });
    wrap.append(list);
    return wrap;
  }
  function droppedLogFactSuffix(fact) {
    if (!fact || typeof fact !== "object") return "";
    const bits = [];
    if (fact.bytes !== null && fact.bytes !== undefined) bits.push(scalar(fact.bytes, "unknown") + " bytes");
    if (fact.kind) bits.push(scalar(fact.kind, "unknown"));
    if (fact.kind === "run_log_limit" && fact.max_log_bytes !== null && fact.max_log_bytes !== undefined) bits.push("raise max_log_bytes (" + scalar(fact.max_log_bytes, "unknown") + ")");
    return bits.length ? " · " + bits.join(" · ") : "";
  }
  function appendDroppedParentCopy(root, route, dropped) {
    const fact = droppedLogById(route, dropped.parentId);
    const line = el("p", "empty-state");
    if (dropped.parentId === route.runId) {
      line.append(text("span", "The requested id "));
      line.append(untrustedText("span", scalar(route.runId, "unknown")));
      const suffix = droppedLogFactSuffix(fact);
      if (suffix) line.append(untrustedText("span", suffix));
      line.append(text("span", " was not projected because its Session Log exceeds the configured byte bound (run_log_limit)."));
    } else {
      line.append(text("span", "The requested id "));
      line.append(untrustedText("span", scalar(route.runId, "unknown")));
      line.append(text("span", " is a child of parent "));
      line.append(projectedLink(dropped.parentId, routeHash({workspace: route.workspace, runId: dropped.parentId}), "dropped-parent:" + dropped.parentId));
      const suffix = droppedLogFactSuffix(fact);
      if (suffix) line.append(untrustedText("span", suffix));
      line.append(text("span", ", which was not projected because its Session Log exceeds the configured byte bound (run_log_limit)."));
    }
    root.append(line);
  }
  /**
   * Acquires the scoped inventory through the ordinary authoritative list path
   * when it is not currently held, then repaints the same dead end so resolution
   * is attempted against real evidence. No mapping is ever fabricated: a failed
   * or empty acquisition leaves the dead end exactly as it was, and the operator
   * is never moved.
   * @param {Object} route Parsed route whose runId hit run_not_found.
   * @returns {void}
   */
  function acquireInventoryForResolution(route) {
    // ONE acquisition per resolved-for id, terminally. The marker is recorded
    // BEFORE the request is issued and is never cleared by the acquisition
    // itself, so the repaint this acquisition triggers cannot re-enter here —
    // not even when the acquired inventory came back empty or failed, which is
    // exactly the "evidence unavailable" case. Only renderProjectionFailure
    // moving resolutionFor to a DIFFERENT id clears it.
    if (state.resolutionInFlight || state.resolutionAttemptedFor === route.runId) return;
    state.resolutionAttemptedFor = route.runId;
    // The ordinary authoritative list paths, reused verbatim: the workspace-set
    // branch goes through refetchWorkspaceList (same per-source arbitration and
    // snapshot bookkeeping as every other list acquisition), and single mode
    // through the same /api/runs request the Runs view issues.
    // Single mode commits under the navigation generation captured BEFORE the
    // request, so a late acquisition can never overwrite a newer state.list —
    // the workspace-set branch already arbitrates per source through
    // sourceRequestGeneration, which is why it passes null there.
    const acquisitionGeneration = state.generation;
    const request = workspaceSetMode()
      ? refetchWorkspaceList(route.workspace, null)
      : fetchJSON("/api/runs", acquisitionGeneration).then(function (payload) {
          if (payload === SUPERSEDED || acquisitionGeneration !== state.generation) return;
          state.list = confessUnlinkableListRows(payload);
        });
    state.resolutionInFlight = request.catch(function () {}).finally(function () {
      const current = parseRoute(location.hash);
      const failure = state.resolutionFailure;
      // Repaint only the dead end that asked for this inventory, and only while
      // it is still the rendered view. Acquisition never navigates. The
      // in-flight handle is released only AFTER the repaint has run, so the
      // repaint observes an acquisition still in progress even if the attempt
      // marker were ever weakened.
      try {
        if (failure && current.runId === route.runId && state.resolutionFor === route.runId && app.querySelector(".error-view")) renderProjectionFailureSafely(failure);
      } finally { state.resolutionInFlight = null; }
    });
  }
  /**
   * Builds the resolved-parent affordance for a run_not_found dead end whose
   * requested id is an exact parent-observed child in the held scoped inventory.
   * Returns null whenever nothing resolves, so the unresolved dead end keeps its
   * copy and action set byte-identical. It renders LINKS only: activating one is
   * an explicit operator action, and nothing here navigates on its own.
   * @param {Object} route Parsed route.
   * @returns {HTMLElement|null}
   */
  function parentResolutionPanel(route, options) {
    if (!route.runId || state.resolutionFor !== route.runId) return null;
    const candidates = resolveParentObservedChild(route.runId, heldInventoryRows(route));
    if (!candidates.length) return null;
    const section = el("section", "parent-resolution");
    section.setAttribute("role", "status");
    section.append(heading(options && options.headline ? 1 : 2, "Parent-observed child Session"));
    const summary = candidates.length > 1 ? "This Session id is observed as a child by " + candidates.length + " parent runs in the held inventory. No parent was selected for you; choose one." : "This Session id is a parent-observed child of the run below.";
    section.append(untrustedText("p", "The requested id " + route.runId + " is not a projectable run. " + summary, "empty-state"));
    const list = el("ul", "parent-resolution-candidates");
    candidates.forEach(function (candidate) {
      const item = el("li");
      const target = candidate.unitId ? routeHash({workspace: route.workspace, runId: candidate.runId, unitId: candidate.unitId, filters: route.filters, sort: route.sort, q: route.q}) : routeHash({workspace: route.workspace, runId: candidate.runId, filters: route.filters, sort: route.sort, q: route.q});
      const label = "Open parent run " + candidate.runId + (candidate.unitId ? " → logical unit " + candidate.unitId : " (owning logical unit not identified in parent evidence)");
      item.append(projectedLink(label, target, "parent-resolution-" + candidate.runId));
      list.append(item);
    });
    section.append(list);
    section.append(text("p", "Basis: parent-observed child evidence from parent Session Logs only. The child Session itself was not projected, fetched, or observed for liveness; no freshness is claimed for it.", "provenance"));
    return section;
  }
  /**
   * Appends the resolution outcome to a dead end's status line — and contributes
   * nothing at all when nothing resolved, so the unresolved status line stays
   * byte-identical to what it has always been.
   * @param {Object} route Parsed route.
   * @returns {string}
   */
  function resolutionStatusSuffix(route) {
    if (!route.runId || state.resolutionFor !== route.runId) return "";
    const candidates = resolveParentObservedChild(route.runId, heldInventoryRows(route));
    return candidates.length ? " · owning parent run resolved from parent-observed child evidence" : "";
  }
  function filtersPanel(route) {
    const form = el("form", "filters");
    form.setAttribute("aria-label", "Run filters");
    ["strategy", "execution", "liveness", "source", "attention"].forEach(function (name) {
      const naming = FILTER_LABELS[name];
      const label = text("label", naming ? naming.label : titleCase(name));
      const select = el("select");
      select.name = name;
      key(select, "filter-" + name);
      const allOption = text("option", "All"); allOption.value = ""; select.append(allOption);
      const values = FILTER_VOCABULARIES[name];
      values.forEach(function (value) { const option = text("option", naming && naming.options[value] ? naming.options[value] : titleCase(value)); option.value = value; if (route.filters[name] === value) option.selected = true; select.append(option); });
      select.addEventListener("change", function () {
        const next = Object.create(null);
        Object.keys(route.filters).forEach(function (keyName) { next[keyName] = route.filters[keyName]; });
        if (select.value) next[name] = select.value; else delete next[name];
        location.hash = routeHash({view: "runs", filters: next, sort: route.sort, q: route.q});
      });
      label.append(select);
      form.append(label);
    });
    const sortLabel = text("label", "Sort");
    const sortSelect = el("select");
    sortSelect.name = "sort";
    key(sortSelect, "sort-order");
    SORT_VOCABULARY.forEach(function (value) { const option = text("option", SORT_LABELS[value]); option.value = value; if ((route.sort || DEFAULT_SORT) === value) option.selected = true; sortSelect.append(option); });
    sortSelect.addEventListener("change", function () { location.hash = routeHash({view: "runs", filters: route.filters, sort: sortSelect.value, q: route.q}); });
    sortLabel.append(sortSelect);
    form.append(sortLabel);
    form.append(button("Clear filters", function () { location.hash = routeHash({view: "runs", filters: Object.create(null), sort: route.sort, q: route.q}); }, "secondary"));
    return form;
  }
  /**
   * Matches one row against the search query. An exact parent-observed child
   * Session id wins before run id/title substrings so the provenance of the
   * match is honest; child Logs are never scanned and no index is persisted.
   * @param {Object} row Projected list row.
   * @param {*} rawQuery Route query (bounded upstream by LIMITS.query).
   * @returns {{matched: boolean, via: (string|null), child: (Object|undefined)}}
   */
  function searchMatch(row, rawQuery) {
    const query = scalar(rawQuery, "").trim();
    if (!query) return {matched: true, via: null};
    const needle = query.toLowerCase();
    const child = array(row.children).find(function (candidate) { return scalar(candidate.session_id, "") === query; });
    if (child) return {matched: true, via: "child_session", child: child};
    if (scalar(row.id, "").toLowerCase().includes(needle) || scalar(row.title, "").toLowerCase().includes(needle)) return {matched: true, via: "run"};
    return {matched: false, via: null};
  }
  function searchPanel(route) {
    const form = el("form", "filters search-panel");
    form.setAttribute("aria-label", "Run search");
    const label = text("label", "Search runs");
    const input = el("input");
    input.type = "search";
    input.name = "q";
    input.maxLength = LIMITS.query;
    input.value = scalar(route.q, "");
    input.placeholder = "Run id, projected title, or exact child Session id";
    key(input, "search-q");
    label.append(input);
    form.append(label);
    form.append(button("Search", function () { location.hash = routeHash({view: "runs", filters: route.filters, sort: route.sort, q: input.value}); }, "primary"));
    if (route.q) form.append(button("Clear search", function () { location.hash = routeHash({view: "runs", filters: route.filters, sort: route.sort, q: ""}); }, "secondary"));
    form.addEventListener("submit", function (event) { event.preventDefault(); location.hash = routeHash({view: "runs", filters: route.filters, sort: route.sort, q: input.value}); });
    form.append(text("p", "Search scans only the selected inventory of parent Session Logs already projected above. Child Session ids match exactly when parent-observed; child Logs are never scanned and no index is persisted.", "provenance"));
    return form;
  }
  function distributionMarkers(counts, order, aliases, dimension, basis) {
    const wrap = el("div", "marker-distribution");
    distributionBuckets(counts, order, aliases).forEach(function (bucket) {
      wrap.append(labeledMarker(bucket.phrase, bucket.token, dimension, basis));
    });
    return wrap;
  }
  function cellLabel(node, name) { node.dataset.cellLabel = name; return node; }
  /**
   * Renders one group of run rows as a table. Cells carry data-cell-label so
   * narrow viewports can stack them with their column names; search matches via
   * a child Session annotate the run cell with their provenance; temporal cells
   * render the projected absolute value with its completeness confessed.
   * @param {Array<Object>} rows Rows already filtered, sorted, searched, and budgeted.
   * @param {number} total Total rows in the group before pagination.
   * @param {string} group Group heading.
   * @param {Object} matches Search matches keyed by run id.
   * @param {string} focusKey Focus key for the group heading (survives re-render).
   * @param {Object} route Parsed route, so column-header manual links preserve place.
   * @returns {HTMLElement}
   */
  /**
   * The Runs list column headers, in shipped order — the ONE place the column
   * names exist. `runTable` paints them and the narrow-viewport front door
   * (dimensionVocabularyLine) names the doctrine subset, and both read this
   * array: a parallel copy table is exactly the drift the affordance's seam
   * obligation forbids.
   *
   * "Run", "Strategy", "Units", "Duration" and "Latest" are ordinary table
   * nouns with no glossary entry, so membership in LABELLED_TERMS — not a
   * second hand-maintained list — is what decides which headers are labelled
   * and which the front door names.
   */
  const RUNS_COLUMNS = Object.freeze(["Run", "Strategy", "Execution", "Liveness", "Gate", "Advisory", "Source", "Units", "Mutation", "Duration", "Latest", "Child after end"]);
  function doctrineRunsColumns() {
    return RUNS_COLUMNS.filter(function (name) { return Object.prototype.hasOwnProperty.call(LABELLED_TERMS, name); });
  }
  function runTable(rows, total, group, matches, focusKey, route) {
    const section = el("section", "run-group");
    const attentionGroup = group === "Needs attention";
    const groupHeading = heading(2, attentionGroup ? "Needs attention · " + total + " parent-observed" : group + " · " + total);
    key(groupHeading, focusKey); groupHeading.tabIndex = -1; section.append(groupHeading);
    if (!rows.length) {
      section.append(empty(attentionGroup ? "No parent-observed attention. Absence of attention rows is a parent-Log observation, not a global health claim." : "No runs in this group."));
      return section;
    }
    const table = el("table", "runs-table");
    const caption = text("caption", group + " runs"); caption.className = "sr-only"; table.append(caption);
    const head = el("thead"); const hr = el("tr");
    // Only the headers naming a DOCTRINE term are labelled. "Run", "Strategy",
    // "Units", "Duration" and "Latest" are ordinary table nouns with no glossary
    // entry, so they stay plain: an unmarked header is honest, and a dotted one
    // whose target cannot define it is not.
    RUNS_COLUMNS.forEach(function (name) {
      hr.append(Object.prototype.hasOwnProperty.call(LABELLED_TERMS, name) ? labelledTerm("th", name, route, "runs-header:" + group) : text("th", name));
    });
    head.append(hr); table.append(head);
    const body = el("tbody");
    rows.forEach(function (row) {
      const tr = el("tr");
      if (row.counts && row.counts.attention_units > 0) tr.className = "attention-row";
      const name = scalar(row.title, row.id || "Unnamed run");
      const nameCell = el("td"); nameCell.append(projectedLink(name, routeHash({runId: row.id, filters: parseRoute(location.hash).filters, sort: parseRoute(location.hash).sort, q: parseRoute(location.hash).q}), "run-" + row.id));
      nameCell.append(text("span", "Attention observed: " + scalar(row.counts && row.counts.attention_units, 0) + " · parent Log only", "attention-basis"));
      if (array(row.attention && row.attention.reasons).length) nameCell.append(untrustedText("span", "△ " + row.attention.reasons.map(titleCase).join(" · "), "attention-reasons"));
      const match = matches && matches[row.id];
      if (match && match.via === "child_session") {
        const matchedUnit = match.child && match.child.unit_id;
        const currentRoute = parseRoute(location.hash);
        const matchTarget = matchedUnit ? routeHash({runId: row.id, unitId: matchedUnit, filters: currentRoute.filters, sort: currentRoute.sort, q: currentRoute.q}) : routeHash({runId: row.id, filters: currentRoute.filters, sort: currentRoute.sort, q: currentRoute.q});
        const matchLabel = "Matched via parent-observed child Session " + scalar(match.child && match.child.session_id, "unknown") + (matchedUnit ? " → logical unit " + matchedUnit : " (owning logical unit not identified in parent evidence)");
        const matchNote = el("span", "child-match provenance");
        matchNote.append(projectedLink(matchLabel, matchTarget, "child-match-" + row.id));
        nameCell.append(matchNote);
      }
      tr.append(cellLabel(nameCell, "Run"));
      const strategy = el("td"); strategy.append(marker(row.strategy, "strategy")); tr.append(cellLabel(strategy, "Strategy"));
      const execution = el("td"); execution.append(marker(row.execution && row.execution.state, "execution")); tr.append(cellLabel(execution, "Execution"));
      const liveness = el("td"); liveness.append(marker(row.liveness && row.liveness.state, "liveness", row.liveness && row.liveness.basis));
      const livenessNote = livenessCellNote(row.liveness && row.liveness.state);
      if (livenessNote) liveness.append(text("span", livenessNote, "liveness-basis"));
      tr.append(cellLabel(liveness, "Liveness"));
      const gateCell = el("td");
      const gateMarkers = distributionMarkers(row.gate_counts, GATE_BUCKET_ORDER, GATE_DISPLAY_ALIASES, "gate distribution", "parent_log_only");
      if (!gateMarkers.childNodes.length) gateCell.append(text("span", "—")); else gateCell.append(gateMarkers); tr.append(cellLabel(gateCell, "Gate"));
      const advisoryCell = el("td");
      const advisoryMarkers = distributionMarkers(row.advisory_counts, ADVISORY_BUCKET_ORDER, ADVISORY_DISPLAY_ALIASES, "advisory distribution", "parent_log_only");
      if (!advisoryMarkers.childNodes.length) advisoryCell.append(text("span", "—")); else advisoryCell.append(advisoryMarkers); tr.append(cellLabel(advisoryCell, "Advisory"));
      const source = el("td"); source.append(marker(row.source && row.source.mode, "source"));
      const boundedNote = boundedLogNote(row);
      if (boundedNote) source.append(boundedNote);
      tr.append(cellLabel(source, "Source"));
      tr.append(cellLabel(text("td", scalar(row.counts && row.counts.completed_units, "0") + "/" + scalar(row.counts && row.counts.planned_units, "?")), "Units"));
      tr.append(cellLabel(text("td", titleCase(row.mutation && row.mutation.status)), "Mutation"));
      const duration = temporalField(row, "duration");
      const durationCell = el("td");
      const durationNode = text("span", durationLabel(duration), "duration duration-completeness-" + scalar(duration.completeness, "unknown"));
      durationNode.dataset.provenance = scalar(duration.basis, "boundary_difference");
      durationNode.dataset.completeness = scalar(duration.completeness, "unknown");
      durationCell.append(durationNode);
      tr.append(cellLabel(durationCell, "Duration"));
      const latest = temporalField(row, "latest_at");
      const latestCell = el("td");
      latestCell.append(untrustedText("span", displayInstant(latest.value) || scalar(latest.value, "Unknown"), "absolute-ts"));
      const relative = relativeLabel(latest);
      if (relative) latestCell.append(text("span", relative, "relative-label"));
      if (latest.completeness === "malformed") latestCell.append(text("span", "Malformed timestamp", "relative-label duration-completeness-malformed"));
      tr.append(cellLabel(latestCell, "Latest"));
      tr.append(cellLabel(postTerminalCell(row.post_terminal_child_activity), "Child after end"));
      body.append(tr);
    });
    table.append(body);
    const scroll = el("div", "table-scroll"); scroll.append(table); section.append(scroll);
    return section;
  }
  function inventoryNotice(payload) {
    const inventory = payload && payload.inventory;
    const limitations = array(inventory && inventory.limitations);
    if (!inventory || (inventory.truncated !== true && !limitations.length)) return null;
    const section = el("section", "inventory-notice");
    section.setAttribute("role", "status");
    section.append(heading(2, inventory.truncated === true ? "Run inventory truncated" : "Run inventory limited"));
    section.append(text("p", "Newest " + scalar(inventory.selected, "?") + " of " + scalar(inventory.total, "?") + " Session Logs selected."));
    if (limitations.length) {
      const disclosure = el("details", "inventory-limitation-disclosure");
      disclosure.append(text("summary", "Limitation details"));
      const list = el("ul", "inventory-limitations");
      limitations.forEach(function (limitation) {
        const item = el("li");
        item.append(untrustedText("strong", limitation && limitation.kind));
        item.append(untrustedText("p", limitation && limitation.message));
        const details = limitation && limitation.details;
        if (details && typeof details === "object" && !Array.isArray(details)) {
          const facts = el("dl", "inventory-limitation-details");
          [["Maximum Logs", details.max_logs], ["Total Logs", details.total], ["Selected Logs", details.selected], ["Projected Runs", details.projected_runs], ["Non-run Session Logs", details.non_parent_logs], ["Unprojected Selected Logs", details.dropped_logs]].forEach(function (entry) {
            if (entry[1] !== null && entry[1] !== undefined) facts.append(field(entry[0], entry[1]));
          });
          const errorKinds = details.error_kinds;
          if (errorKinds && typeof errorKinds === "object" && !Array.isArray(errorKinds)) {
            const labels = Object.keys(errorKinds).sort().map(function (kind) { return kind + ": " + scalar(errorKinds[kind], 0); });
            if (labels.length) facts.append(field("Error kinds", labels.join(" · ")));
          }
          item.append(facts);
          const droppedRows = appendDroppedLogRows(details.dropped);
          if (droppedRows) item.append(droppedRows);
        }
        list.append(item);
      });
      disclosure.append(list);
      section.append(disclosure);
    }
    return section;
  }
  /**
   * Renders the Runs view from route state alone. The pipeline is pinned:
   * filter, then sort (pinned total order), then search, then group, then
   * per-group pagination — with the attention group budgeted by
   * attentionRowBudget so parent-observed attention is never hidden behind
   * healthy-row pagination. Every scanned-domain fact is confessed inline.
   * @returns {void}
   */
  /**
   * The LIVE-ACTIVITY FRONT DOOR (DESIGN.md constraint 4): the first screen a
   * newcomer sees reaches the SSE health pill's vocabulary.
   *
   * The pill sits in the page chrome above every view and says things like
   * "SSE connected · hints only · coalesced · last successful authoritative
   * refetch 08:11:02Z". Those phrases are the whole reason a newcomer mistrusts
   * or over-trusts the stream, and the pill has no room to explain them. This
   * line does: it names the phrases in the Monitor's own voice and links each
   * into the manual at its term.
   *
   * It quotes only what the pill is CURRENTLY showing. The vocabulary is
   * state-dependent — "coalesced" is emitted on the connected state alone — so
   * the quoted terms come from streamVocabularyTerms, the same source setStatus
   * assembles the pill from, and setStatus repaints this line on every stream
   * transition. An orientation line that asserted absent pill text would be the
   * Monitor claiming something not on screen.
   *
   * The affordance is on this SENTENCE, not on the pill. The pill is one
   * assembled status string whose parts change with observed stream state;
   * marking fragments of it would put dotted underlines on something that reads
   * as a live value, which is exactly what the orientation line promises never
   * happens.
   * @param {Object} route Parsed route.
   * @returns {Element}
   */
  function streamVocabularyLine(route) {
    return repaintStreamVocabularyLine(el("p", "stream-vocabulary"), route);
  }
  /**
   * Fills (or refills) the stream orientation line from the observed stream
   * state. Split out of streamVocabularyLine so setStatus can re-derive the
   * quote without a view re-render.
   *
   * REFILLING IS DESTRUCTIVE, and the nodes it destroys are TAB STOPS. Every
   * term in this line is a native `<a href>` built by labelledTerm, so
   * `replaceChildren()` detaches whatever the operator's focus is sitting on and
   * the browser collapses `document.activeElement` to `document.body` — the
   * keyboard dead end where the next Tab restarts at the top of the document,
   * the same one restoreView exists to close. The call setStatus makes has no
   * captureView/restoreView around it (source.onopen and source.onerror repaint
   * the pill with no view re-render at all), so the preservation cannot live at
   * the call site: it lives HERE, with the destruction, and therefore holds for
   * every caller present and future.
   *
   * The restore is by focus key rather than by position, because the vocabulary
   * itself changes across a transition: "coalesced" exists only on the connected
   * state, so a term the operator was standing on can legitimately vanish. When
   * the same key comes back the operator does not move at all; when it does not,
   * the first anchor of THIS line is the bounded fallback — they stay in the
   * sentence they were reading rather than at the top of the document.
   * @param {Element} line The `.stream-vocabulary` element.
   * @param {Object} route Parsed route.
   * @returns {Element} The same element.
   */
  function repaintStreamVocabularyLine(line, route) {
    line.__pixirRoute = route;
    // Read BEFORE the clear: afterwards the active element is document.body and
    // the key is gone. Scoped to this line on purpose — focus parked anywhere
    // else in the document is none of this repaint's business, and stealing it
    // would be a worse defect than the one being fixed.
    const active = document.activeElement;
    const held = active && active.dataset && Array.from(line.querySelectorAll("[data-focus-key]")).indexOf(active) !== -1
      ? active.dataset.focusKey
      : null;
    // Not setText: scalar() renders "" as the em-dash placeholder. This clears.
    line.replaceChildren();
    const terms = streamVocabularyTerms(state.streamState);
    line.__pixirTerms = terms.join(" ");
    line.append(text("span", "The stream indicator above says "));
    terms.forEach(function (term, index) {
      if (index > 0) line.append(text("span", index === terms.length - 1 ? " and " : ", "));
      line.append(labelledTerm("span", term, route, "front-door"));
    });
    line.append(text("span", ", and names the "));
    line.append(labelledTerm("span", "last successful authoritative refetch", route, "front-door"));
    line.append(text("span", ". Those terms are what the stream does and does not promise; each opens its manual entry here. The pill's wording follows the observed stream state, so this sentence names only what it is showing now. Dotted labels are axes with a manual entry. Values are never marked."));
    if (held !== null) {
      const anchors = Array.from(line.querySelectorAll("[data-focus-key]"));
      const same = anchors.find(function (candidate) { return candidate.dataset.focusKey === held; });
      const landing = same || anchors[0];
      if (landing) landing.focus({preventScroll: true});
    }
    return line;
  }
  /**
   * The RUNS-LIST DIMENSION FRONT DOOR, and the reason it exists is a defect
   * this line repairs.
   *
   * The Runs list columns naming a doctrine term carry the dotted affordance on
   * the `<th>` elements of each group table. Below 480px the shipped triage
   * contract
   * CLIPS the entire `<thead>` (app.css) and re-renders the column names as
   * `td::before` pseudo-content, so that on the 390x844 reference viewport the
   * dotted labels VANISH: CSS generated content cannot be a link, cannot carry
   * `data-manual-term`, and is in neither the accessibility nor the hit-testing
   * tree. The same screen kept shipping the sentence "Dotted labels are axes
   * with a manual entry", so the narrow viewport was promised an affordance it
   * did not have.
   *
   * This line is the repair, and it is deliberately NOT narrow-only. A
   * width-conditional front door would be a second surface that only some
   * readers ever see, and it would have to be kept in sync with a media query
   * — the exact coupling that let the promise rot in the first place. One
   * sentence, always painted, always in the accessibility tree, reaching every
   * doctrine dimension the list shows. At wide widths it is redundant with the
   * headers, which is the cheap half of the trade.
   *
   * The terms are not restated here. They are `RUNS_COLUMNS` filtered by
   * membership in `LABELLED_TERMS` — the same array `runTable` paints its
   * `<th>` row from, filtered by the same predicate that decides which of those
   * headers is labelled. Adding, renaming or unlabelling a column moves this
   * sentence with it; there is no second list to forget.
   * @param {Object} route Parsed route.
   * @returns {Element}
   */
  function dimensionVocabularyLine(route) {
    const line = el("p", "dimension-vocabulary");
    line.append(text("span", "Each run below is reported on independent axes: "));
    const columns = doctrineRunsColumns();
    columns.forEach(function (name, index) {
      if (index > 0) line.append(text("span", index === columns.length - 1 ? " and " : ", "));
      line.append(labelledTerm("span", name, route, "list-front-door"));
    });
    line.append(text("span", ". Each opens its manual entry here. On narrow screens the column headings stack into each card as plain labels, so this sentence is where those axes stay reachable."));
    return line;
  }
  function renderRuns() {
    const route = parseRoute(location.hash);
    const all = listRows(state.list);
    const filtered = all.filter(function (row) {
      return Object.keys(route.filters).every(function (name) { return String(rowValue(row, name)) === route.filters[name]; });
    });
    const sorted = filtered.slice().sort(runsComparator(route.sort || DEFAULT_SORT));
    const activeQuery = scalar(route.q, "").trim();
    const matches = Object.create(null);
    const searched = sorted.filter(function (row) {
      const match = searchMatch(row, route.q);
      if (match.matched) matches[row.id] = match;
      return match.matched;
    });
    const grouped = Object.create(null);
    ["Needs attention", "Recent"].forEach(function (group) { grouped[group] = searched.filter(function (row) { return groupFor(row) === group; }); });
    const root = el("div", "view runs-view");
    root.append(heading(1, "Runs"));
    root.append(text("p", "Authoritative, recomputable projections. The monitor is read-only.", "lede"));
    root.append(text("p", "List rows are reconstructed from the parent Log only and carry no liveness observation; the sole exception is \"Child after end\", which counts child Log (or verified-mirror) writes after the parent's terminal boundary and still never asserts reachability. Opening a run may load additional evidence (owner diagnostics), so row and detail liveness can legitimately differ.", "lede provenance"));
    root.append(streamVocabularyLine(route));
    // "Each run below is reported on independent axes" is a claim ABOUT ROWS, so
    // it is painted only when rows are painted. `searched` is the exact set the
    // group tables are built from, and the three empty branches below are the
    // three ways it can be empty (nothing projected, nothing filter-selected,
    // nothing matched), so this single test covers all of them. An orientation
    // line promising axes for runs that are not there would be the same class of
    // false claim the affordance exists to prevent. The stream line above is
    // unconditional on purpose: it describes the pill, which is always painted.
    if (searched.length) root.append(dimensionVocabularyLine(route));
    root.append(filtersPanel(route));
    root.append(searchPanel(route));
    const inventoryFacts = state.list && state.list.inventory;
    const scanned = "Scanned inventory: " + scalar(inventoryFacts && inventoryFacts.selected, 0) + " selected of " + scalar(inventoryFacts && inventoryFacts.total, 0) + " Session Logs · projected runs: " + scalar(inventoryFacts && inventoryFacts.projected_runs, all.length) + " · non-run Logs: " + scalar(inventoryFacts && inventoryFacts.non_parent_logs, 0) + " · unprojected selected Logs: " + scalar(inventoryFacts && inventoryFacts.dropped_logs, 0) + " · truncated: " + (inventoryFacts && inventoryFacts.truncated === true ? "yes" : "no") + ".";
    root.append(text("p", scanned, "inventory-summary provenance"));
    if (activeQuery) {
      const summary = el("p", "search-summary provenance");
      summary.append(untrustedText("span", "Search “" + activeQuery + "”"));
      summary.append(text("span", " matched " + searched.length + " of " + filtered.length + " filter-selected rows. " + scanned));
      root.append(summary);
    }
    const inventory = inventoryNotice(state.list); if (inventory) root.append(inventory);
    if (!all.length) root.append(empty("No authoritative run projections are currently available. " + scanned));
    else if (!filtered.length) root.append(empty("No runs match the selected filters. " + scanned));
    else if (!searched.length) {
      const emptySearch = el("p", "empty-state");
      emptySearch.append(text("span", "No runs match this search in the selected inventory. Query "));
      emptySearch.append(untrustedText("span", "“" + activeQuery + "”"));
      emptySearch.append(text("span", " was compared against " + filtered.length + " filter-selected of " + all.length + " projected run rows. " + scanned + " Runs outside the selected inventory were not searched; no match here is not evidence of absence."));
      root.append(emptySearch);
    } else ["Needs attention", "Recent"].forEach(function (group) {
      // A pagination STATE key, not a navigation target, so the manual is pinned
      // closed rather than inherited: opening the pane is a pure re-render, and
      // an overlay-sensitive key would silently reset every group back to page 1.
      const pageKey = "runs:" + group.toLowerCase().replace(" ", "-") + ":" + routeHash({view: "runs", filters: route.filters, sort: route.sort, q: route.q, manual: null});
      const page = state.pages[pageKey] || 1;
      const budget = group === "Needs attention" ? attentionRowBudget(grouped[group].length, page, ATTENTION_RENDER_ALL_CAP) : page * LIMITS.runs;
      const rows = grouped[group].slice(0, budget);
      const groupFocusKey = "run-group:" + pageKey;
      const section = runTable(rows, grouped[group].length, group, matches, groupFocusKey, route);
      if (rows.length < grouped[group].length) {
        const nextPage = page + 1;
        const nextBudget = group === "Needs attention" ? attentionRowBudget(grouped[group].length, nextPage, ATTENTION_RENDER_ALL_CAP) : nextPage * LIMITS.runs;
        const nextReveal = Math.min(nextBudget, grouped[group].length) - rows.length;
        section.append(key(button("Show next " + nextReveal + " " + group + " runs (" + rows.length + " of " + grouped[group].length + " shown, " + (grouped[group].length - rows.length) + " remaining)", function () {
          state.pages[pageKey] = nextPage;
          if (nextBudget >= grouped[group].length) { state.restore = captureView(); state.restore.focus = groupFocusKey; }
          renderCurrentGuarded();
        }, "continuation"), "continuation:" + pageKey));
      }
      root.append(section);
    });
    replaceContent(root, "Runs updated. " + searched.length + " visible.");
    setStatus("Read-only · authoritative snapshots · " + all.length + " runs");
  }

  function livenessState(run) { return run.liveness && run.liveness.state; }
  function livenessBasis(run) { return run.liveness && run.liveness.basis; }
  /**
   * Detail-scope Liveness truth-card copy.
   *
   * Owner residency and owner brokenness are different claims. "externally_owned"
   * means the Delegate owner is simply another process — the ordinary condition
   * for read-only external observation — while the durable parent Log confirms
   * the run is advancing. That is an epistemic position, not a fault, so the copy
   * must not say the run is unreachable as if something were wrong. Reachability
   * itself stays honestly false in the projection.
   *
   * @param {Object} run Projected run detail.
   * @returns {string} Card copy for the projected liveness state.
   */
  function livenessCardNote(run) {
    const state = livenessState(run);
    if (state === "externally_owned") return "Owner is another process; activity confirmed from durable Log evidence.";
    if (run.liveness && run.liveness.reachable === true) return "Reachable now";
    return "Not currently reachable";
  }
  /**
   * The WORD the Unit Inspector's "Runtime gate" card paints for one unit's
   * gate state, named once so the ON THIS RUN pane inches away can quote it
   * instead of re-deriving it.
   *
   * The card renders `marker(unit.gate.state, ...)`, and marker() labels
   * through titleCase — no display alias — so `checkpoint_ready` reads
   * "checkpoint ready" there. The pane's unit branch used to run the same token
   * through GATE_DISPLAY_ALIASES, which renames it to "ready" for the run-wide
   * DISTRIBUTION. Two words for one value, on the one route where the runtime
   * gate term's surface string appears. The pane QUOTES the surface it
   * explains, so the shipped card wording stands and this function is the one
   * path both call: they can no longer diverge without moving together.
   *
   * The aliases still govern the RUN fold, where "3 ready" is the phrasing the
   * rail's distribution card and the runs-list cell both print. Renaming a
   * bucket in a count and naming one unit's state are different jobs.
   * @param {?Object} unit Unit projection.
   * @returns {string} The card's exact label for this unit's gate state.
   */
  function unitGateLabel(unit) { return titleCase(unit && unit.gate && unit.gate.state); }
  /**
   * The WORD the Unit Inspector's "Model advisory" card paints for one unit's
   * advisory, named once so the card, the ON THIS RUN pane, and the compact
   * unit chips cannot diverge.
   *
   * A PRESENT advisory renders through the SAME bucket classification the
   * pane and every fold use (unitAdvisoryBucket): invalid FIRST, then the
   * verdict through the shipped alias map. Aliasing the raw verdict instead
   * was round two's catch — an invalid advisory carrying `verdict: "unknown"`
   * painted "unclassified verdict" on the card while the pane correctly said
   * "invalid", and those are different facts (unparseable vs parsed-but-
   * decisive-nothing; the corpus keeps them apart on purpose). `unknown`
   * itself stays aliased because painting it bare is the misreading
   * ADVISORY_DISPLAY_ALIASES exists to prevent (#441).
   * ABSENCE keeps the raw rendering: the pane names absence as absence
   * ("no advisory") and documents the card's artefact; renaming a missing
   * field would claim a verdict the projection never asserted.
   * @param {?Object} unit Unit projection.
   * @returns {string} The card's label for this unit's advisory.
   */
  function unitAdvisoryLabel(unit) {
    const bucket = unitAdvisoryBucket(unit);
    if (bucket === null) return titleCase(unit && unit.advisory && unit.advisory.verdict);
    return distributionValueLabel(bucket, ADVISORY_DISPLAY_ALIASES);
  }
  /**
   * One truth card. The HEADING is a labelled axis name; the marker under it is
   * the VALUE and is never marked, which is the visible half of the typographic
   * honesty rule.
   * @param {Object} route Parsed route, so the heading's manual link preserves place.
   */
  function truthCard(route, label, dimension, value, basis, extra) {
    return labeledTruthCard(route, label, dimension, titleCase(value), value, basis, extra);
  }
  /**
   * A truth card whose visible label is supplied rather than derived, so a
   * caller that shares its label path with another surface can pass the shared
   * word. `tone` stays the raw token: aliasing and labeling are display only,
   * and severity still reads the projection's own value. The heading is a
   * labelled axis name (dotted manual affordance); the marker is the VALUE and
   * is never marked.
   * @param {Object} route Parsed route, so the heading's manual link preserves place.
   * @param {string} label Card heading.
   * @param {string} dimension Truth dimension slug.
   * @param {string} valueLabel The word to paint.
   * @param {*} tone Raw token driving marker tone.
   * @param {?string} basis Provenance string.
   * @param {?string} extra Optional trailing note.
   * @returns {HTMLElement} The card.
   */
  function labeledTruthCard(route, label, dimension, valueLabel, tone, basis, extra) {
    const card = el("section", "truth-card");
    card.dataset.truthDimension = dimension;
    card.append(labelledTerm("h3", label, route));
    card.append(labeledMarker(valueLabel, tone, dimension, basis));
    if (basis) card.append(text("p", "Basis: " + titleCase(basis), "provenance"));
    if (extra) card.append(text("p", extra, "truth-extra"));
    return card;
  }
  function distributionCard(route, label, dimension, counts, order, aliases, basis, extra) {
    const card = el("section", "truth-card"); card.dataset.truthDimension = dimension; card.append(labelledTerm("h3", label, route));
    const wrap = distributionMarkers(counts, order, aliases, dimension + " distribution", basis);
    if (!wrap.childNodes.length) wrap.append(labeledMarker(EMPTY_DISTRIBUTION_PHRASE, "unknown", dimension + " distribution", basis));
    card.append(wrap); if (basis) card.append(text("p", "Basis: " + titleCase(basis), "provenance")); if (extra) card.append(text("p", extra, "truth-extra")); return card;
  }
  function stateCounts(units, reader, invalidReader) {
    const counts = Object.create(null); array(units).forEach(function (unit) { const invalid = invalidReader && invalidReader(unit); const value = invalid ? "invalid" : reader(unit); if (value) counts[value] = (counts[value] || 0) + 1; }); return counts;
  }
  function runOverview(run) {
    const panel = el("dl", "run-overview");
    [["Run id", run.run && run.run.id], ["Delegate id", run.run && run.run.delegate_id], ["Parent Session", run.run && run.run.parent_session_id], ["Workflow id", run.run && run.run.workflow_id], ["Projected at", displayInstant(run.projected_at) || run.projected_at], ["As of parent seq", run.source && run.source.as_of_seq], ["Planned units", run.counts && run.counts.planned_units], ["Observed units", run.counts && run.counts.observed_units], ["Running units", run.counts && run.counts.running_units], ["Completed units", run.counts && run.counts.completed_units], ["Attention units", run.counts && run.counts.attention_units]].forEach(function (entry) {
      if (entry[0] === "Delegate id" && (entry[1] == null || entry[1] === "")) return;
      panel.append(field(entry[0], entry[1]));
    });
    return panel;
  }
  function truthRail(run, route) {
    const rail = el("div", "truth-rail");
    rail.setAttribute("aria-label", "Seven independent truth dimensions");
    // The orientation line, in Monitor voice. It ships beside the rail rather
    // than in the manual because it teaches WITHOUT any act: a newcomer who
    // never clicks still learns what the dotted underline means and, more
    // importantly, what its ABSENCE means.
    rail.append(text("p", "Dotted labels are axes with a manual entry. Values are never marked.", "rail-orientation"));
    rail.append(truthCard(route, "Execution", "execution", run.execution && run.execution.state, run.execution && run.execution.basis));
    rail.append(truthCard(route, "Liveness", "liveness", livenessState(run), livenessBasis(run), livenessCardNote(run)));
    const gateCounts = runGateCounts(run);
    const advisoryCounts = runAdvisoryCounts(run);
    rail.append(distributionCard(route, "Dependency gate", "gate", gateCounts, GATE_BUCKET_ORDER, GATE_DISPLAY_ALIASES, GATE_FOLD_BASIS));
    rail.append(distributionCard(route, "Model advisory", "advisory", advisoryCounts, ADVISORY_BUCKET_ORDER, ADVISORY_DISPLAY_ALIASES, ADVISORY_FOLD_BASIS, "Advisory does not control the runtime gate."));
    rail.append(truthCard(route, "Source (run-scoped)", "source", run.source && run.source.mode, run.source && run.source.durable_origin, "Freshness: " + titleCase(run.source && run.source.freshness) + "; limitations: " + (array(run.source && run.source.limitations).map(titleCase).join(", ") || "none observed")));
    const attentionCounts = runAttentionCounts(run);
    rail.append(distributionCard(route, "Attention (parent-observed)", "attention", attentionCounts, ATTENTION_BUCKET_ORDER, ATTENTION_DISPLAY_ALIASES, ATTENTION_FOLD_BASIS));
    rail.append(postTerminalCard(run.post_terminal_child_activity, route));
    const boundedNote = boundedLogNote(run);
    if (boundedNote) rail.append(boundedNote);
    return rail;
  }
  /**
   * Detail truth card for post-terminal child activity. It REPORTS: nothing
   * here reclassifies execution, and it can never claim reachability. The card
   * names its basis, the parent-derived boundary it was measured from, and the
   * child Sessions whose Logs supplied the evidence.
   * @param {Object} activity run.post_terminal_child_activity.
   * @returns {Element} Truth card section.
   */
  function postTerminalCard(activity, route) {
    const card = el("section", "truth-card");
    card.dataset.truthDimension = "post_terminal_child_activity";
    card.dataset.postTerminalState = scalar(activity && activity.state, "unknown");
    card.append(labelledTerm("h3", "Child activity after end", route));
    card.append(marker(scalar(activity && activity.state, "unknown"), "post-terminal", activity && activity.basis));
    card.append(text("p", postTerminalLabel(activity), "truth-extra"));
    if (activity && activity.latest_event_at) card.append(untrustedText("p", "Latest child event: " + activity.latest_event_at, "provenance"));
    if (activity && activity.boundary_at) card.append(untrustedText("p", "Parent terminal boundary: " + activity.boundary_at + " (" + titleCase(activity.boundary_basis) + ")", "provenance"));
    const sessions = array(activity && activity.child_session_ids);
    if (sessions.length) {
      const list = el("ul", "post-terminal-sessions");
      sessions.slice(0, LIMITS.evidence).forEach(function (sessionId) { const item = el("li"); projected(item, "code", sessionId); list.append(item); });
      card.append(text("p", "Child Logs that supplied the evidence:", "provenance"));
      card.append(list);
    }
    card.append(text("p", postTerminalNote(activity), "provenance"));
    card.append(text("p", "Reported, not reclassified: canonical execution and liveness are unchanged by this observation.", "provenance"));
    return card;
  }
  function mutationPanel(mutation) {
    const section = el("section", "mutation-panel");
    section.append(heading(2, "Mutation observation"));
    section.append(marker(mutation && mutation.status, "mutation", mutation && mutation.basis));
    section.append(text("p", "Observed semantics: " + titleCase(mutation && mutation.observed_semantics), "provenance"));
    section.append(text("p", "Evidence basis: " + titleCase(mutation && mutation.basis), "provenance"));
    const paths = array(mutation && mutation.observed_paths);
    if (paths.length) { const list = el("ul"); paths.slice(0, LIMITS.evidence).forEach(function (path) { const item = el("li"); projected(item, "code", path); list.append(item); }); section.append(list); }
    section.append(writeDenials(mutation));
    array(mutation && mutation.limitations).forEach(function (item) { section.append(untrustedText("p", titleCase(item), "limitation")); });
    return section;
  }
  // Denials are read-only observation: the operator sees which write was refused,
  // by which rule, and under which policy, without opening the child Log.
  function writeDenials(mutation) {
    const denials = array(mutation && mutation.write_denials);
    const region = el("div", "write-denials");
    if (!denials.length) return region;
    region.append(heading(3, "Write denials (" + denials.length + ")"));
    const list = el("ul");
    denials.slice(0, LIMITS.evidence).forEach(function (denial) {
      const item = el("li", "write-denial");
      projected(item, "code", denial.normalized_path || denial.requested_path);
      item.append(untrustedText("span", " · " + titleCase(denial.matched_rule), "denial-rule"));
      const policy = denial.policy_id ? denial.policy_id + (denial.policy_hash ? " · " + denial.policy_hash : "") : "unknown policy";
      item.append(untrustedText("span", " · " + policy, "provenance"));
      list.append(item);
    });
    region.append(list);
    if (denials.length > LIMITS.evidence) region.append(text("p", "Showing " + LIMITS.evidence + " of " + denials.length + " observed denials.", "truncation"));
    return region;
  }
  function incompleteAttemptLineage(unit) {
    return array(unit.limitations).includes("attempt_lineage_unavailable");
  }
  function unitSummary(run, unit, route, summaryFocusKey) {
    const article = el("article", "unit-card");
    article.dataset.unitId = unit.logical_id;
    const header = el("header");
    header.append(projectedLink(unit.label, semanticZoomRoute(route, {runId: run.run.id, unitId: unit.logical_id}), summaryFocusKey || "unit-" + unit.logical_id));
    header.append(marker(unit.execution && unit.execution.state, "execution", unit.execution && unit.execution.basis));
    header.append(marker(unit.liveness && unit.liveness.state, "liveness", unit.liveness && unit.liveness.basis));
    header.append(marker(unit.gate && unit.gate.state, "gate", unit.gate && unit.gate.basis));
    // WORD through the shared classifier (invalid-first, then the shipped
    // alias); TONE stays the raw verdict. Same split labeledTruthCard uses.
    if (unit.advisory && unit.advisory.present) header.append(labeledMarker(unitAdvisoryLabel(unit), unit.advisory.verdict, "advisory", "model_declared"));
    article.append(header);
    const meta = el("dl", "unit-meta");
    const attemptCount = array(unit.attempts).length;
    meta.append(field("Agent", unit.agent)); meta.append(field("Workspace", unit.workspace_mode)); meta.append(field("Attempts", incompleteAttemptLineage(unit) ? attemptCount + " retained · total unknown" : attemptCount));
    article.append(meta);
    if (unit.attention && unit.attention.required) {
      const attention = el("div", "attention"); attention.append(text("strong", "Needs attention · parent-observed"));
      attention.append(untrustedText("span", array(unit.attention.reasons).map(titleCase).join(" · ")));
      article.append(attention);
    }
    if (unit.advisory && unit.advisory.present) {
      const advisory = el("div", "advisory-panel"); advisory.append(text("strong", "Model advisory (not a runtime gate)"));
      projected(advisory, "p", unit.advisory.summary || unit.advisory.raw_excerpt || "No summary");
      article.append(advisory);
    }
    return article;
  }
  const SEMANTIC_ZOOM_MAX_CLUSTERS = 6;
  const SEMANTIC_ZOOM_MEMBER_PAGE_SIZE = 12;
  const SEMANTIC_ZOOM_EDGE_PAGE_SIZE = 100;
  const SEMANTIC_ZOOM_CLUSTER_KEY = /^wave:\d+:bucket:\d+$/;

  function semanticZoomRoute(route, changes) {
    return routeHash(Object.assign({}, route, changes));
  }

  function semanticZoomBuckets(waves, start) {
    const count = waves.length - start;
    const buckets = Object.create(null);
    if (count > SEMANTIC_ZOOM_MAX_CLUSTERS) {
      for (let index = start; index < start + SEMANTIC_ZOOM_MAX_CLUSTERS; index += 1) if (array(waves[index]).length > 0) buckets[index] = 1;
      return buckets;
    }
    for (let index = start; index < waves.length; index += 1) if (array(waves[index]).length > 0) buckets[index] = 1;
    for (let slot = 0; slot < SEMANTIC_ZOOM_MAX_CLUSTERS - count; slot += 1) {
      let candidate = null;
      for (let index = start; index < waves.length; index += 1) {
        const units = array(waves[index]).length;
        if (units === 0) continue;
        if (buckets[index] >= units) continue;
        if (candidate === null || units * buckets[candidate] > array(waves[candidate]).length * buckets[index]) candidate = index;
      }
      if (candidate === null) break;
      buckets[candidate] += 1;
    }
    return buckets;
  }

  function semanticZoomChunks(ids, bucketCount) {
    const chunks = [];
    const quotient = Math.floor(ids.length / bucketCount);
    const remainder = ids.length % bucketCount;
    let offset = 0;
    for (let ordinal = 0; ordinal < bucketCount; ordinal += 1) {
      const size = quotient + (ordinal < remainder ? 1 : 0);
      chunks.push(ids.slice(offset, offset + size));
      offset += size;
    }
    return chunks;
  }

  function deriveSemanticZoom(graph, start) {
    const waves = array(graph && graph.waves).map(array);
    const safeStart = Number.isSafeInteger(start) && start >= 0 && start < waves.length ? start : 0;
    const buckets = semanticZoomBuckets(waves, safeStart);
    const entities = [];
    const assignment = Object.create(null);
    const unitOrder = Object.create(null);
    if (safeStart > 0) {
      const keyName = "boundary:upstream:waves:0-" + (safeStart - 1);
      const members = waves.slice(0, safeStart).flat();
      entities.push({key: keyName, kind: "boundary", members: members, label: "Upstream boundary · Waves 1–" + safeStart});
      members.forEach(function (id) { assignment[id] = keyName; });
    }
    const visibleEnd = waves.length - safeStart > SEMANTIC_ZOOM_MAX_CLUSTERS ? safeStart + SEMANTIC_ZOOM_MAX_CLUSTERS : waves.length;
    for (let waveIndex = safeStart; waveIndex < visibleEnd; waveIndex += 1) {
      if (waves[waveIndex].length === 0 || !buckets[waveIndex]) continue;
      semanticZoomChunks(waves[waveIndex], buckets[waveIndex]).forEach(function (members, ordinal) {
        const keyName = "wave:" + waveIndex + ":bucket:" + ordinal;
        const entity = {key: keyName, kind: "cluster", waveIndex: waveIndex, ordinal: ordinal, members: members, label: "Wave " + (waveIndex + 1) + " · bucket " + (ordinal + 1)};
        entities.push(entity);
        members.forEach(function (id) { assignment[id] = keyName; });
      });
    }
    if (visibleEnd < waves.length) {
      const keyName = "overflow:waves:" + visibleEnd + "-" + (waves.length - 1);
      const members = waves.slice(visibleEnd).flat();
      if (members.length > 0) {
        entities.push({key: keyName, kind: "overflow", start: visibleEnd, end: waves.length - 1, members: members, label: "More waves " + (visibleEnd + 1) + "–" + waves.length});
        members.forEach(function (id) { assignment[id] = keyName; });
      }
    }
    waves.forEach(function (wave, waveIndex) {
      const visible = entities.filter(function (entity) { return entity.kind === "cluster" && entity.waveIndex === waveIndex; });
      wave.forEach(function (id) {
        const entity = visible.find(function (item) { return item.members.includes(id); });
        unitOrder[id] = [waveIndex, entity ? entity.ordinal : 0, scalar(id, "")];
      });
    });
    const entityOrder = Object.create(null); entities.forEach(function (entity, index) { entityOrder[entity.key] = index; });
    const arcMap = Object.create(null);
    const droppedEdges = [];
    array(graph && graph.edges).forEach(function (edge) {
      const fromKey = assignment[edge.from]; const toKey = assignment[edge.to];
      if (!fromKey || !toKey) { droppedEdges.push({edge: edge, reason: "edge_endpoint_outside_entities"}); return; }
      if (!["ready", "blocked", "unknown"].includes(edge.state)) { droppedEdges.push({edge: edge, reason: "edge_state_invalid"}); return; }
      const keyName = fromKey + "=>" + toKey;
      if (!arcMap[keyName]) arcMap[keyName] = {key: keyName, from: fromKey, to: toKey, counts: {ready: 0, blocked: 0, unknown: 0}, edges: []};
      const arc = arcMap[keyName];
      arc.counts[edge.state] += 1; arc.edges.push(edge);
    });
    function compareUnit(left, right) {
      const a = unitOrder[left] || [Number.MAX_SAFE_INTEGER, 0, scalar(left, "")];
      const b = unitOrder[right] || [Number.MAX_SAFE_INTEGER, 0, scalar(right, "")];
      return a[0] - b[0] || a[1] - b[1] || a[2].localeCompare(b[2]);
    }
    const arcs = Object.keys(arcMap).map(function (keyName) { return arcMap[keyName]; });
    arcs.forEach(function (arc) { arc.edges.sort(function (a, b) { return compareUnit(a.from, b.from) || compareUnit(a.to, b.to); }); });
    arcs.sort(function (a, b) { return entityOrder[a.from] - entityOrder[b.from] || entityOrder[a.to] - entityOrder[b.to]; });
    return {start: safeStart, waves: waves, entities: entities, arcs: arcs, droppedEdges: droppedEdges, compareUnit: compareUnit};
  }

  function semanticZoomLimitations(run, entity, lookup) {
    const values = array(run.limitations).map(function (value) { return scalar(value, "unknown_limitation"); });
    entity.members.forEach(function (id) { if (!lookup[id]) values.push("unit_evidence_absent"); });
    return Array.from(new Set(values));
  }

  function semanticZoomDistribution(members, lookup, reader) {
    const counts = Object.create(null);
    members.forEach(function (id) { if (lookup[id]) { const value = reader(lookup[id]); if (value) counts[value] = (counts[value] || 0) + 1; } });
    return counts;
  }

  function semanticZoomSummary(run, entity, lookup) {
    const summary = el("div", "cluster-summary");
    const observed = entity.members.filter(function (id) { return Boolean(lookup[id]); }).length;
    const limitations = semanticZoomLimitations(run, entity, lookup);
    summary.append(text("p", observed + " observed member" + (observed === 1 ? "" : "s") + (limitations.length ? " · limited: " + limitations.map(titleCase).join(", ") : ""), limitations.length ? "limitation" : "provenance"));
    // Fourth slot is the optional display-alias map, and it is the SHIPPED
    // constant at every dimension that has one: the cluster row must call the
    // advisory `unknown` bucket, the gate `checkpoint_ready` bucket and the
    // attention `yes`/`no` buckets exactly what the truth rail, the Runs list
    // cell and the instrument manual call them, so no surface disagrees with
    // another about one bucket. Execution and Liveness have no alias map --
    // their tokens are already the words on screen -- so those rows pass null.
    // Aliasing is display only: the counts are keyed and sorted on the raw
    // token, so this renames nothing a filter or a tone reads.
    //
    // The attention READER is the shared unitAttentionBucket rather than a
    // fourth inline `required === true ? "yes" : "no"`, for the same reason the
    // alias slot is the shared map: that expression folds an absent record into
    // the negative bucket, so a cluster whose members the projection is silent
    // about would print "not required N" here while the fan-out region beside
    // it files those same units under `attention_requirement_unavailable`.
    // Absence is excluded from the count at every surface or it is fabricated
    // at some of them.
    const dimensions = [
      ["Execution", "execution", function (unit) { return unit.execution && unit.execution.state; }, null],
      ["Liveness", "liveness", function (unit) { return unit.liveness && unit.liveness.state; }, null],
      ["Dependency gate", "gate", function (unit) { return unit.gate && unit.gate.state; }, GATE_DISPLAY_ALIASES],
      ["Model advisory", "advisory", function (unit) { return unit.advisory && unit.advisory.present === true ? (unit.advisory.parse_status === "invalid" ? "invalid" : unit.advisory.verdict) : null; }, ADVISORY_DISPLAY_ALIASES],
      ["Attention", "attention", unitAttentionBucket, ATTENTION_DISPLAY_ALIASES]
    ];
    dimensions.forEach(function (dimension) {
      const row = el("p", "cluster-distribution"); row.dataset.truthDimension = dimension[1]; row.append(text("strong", dimension[0] + ": "));
      const counts = semanticZoomDistribution(entity.members, lookup, dimension[2]);
      const values = Object.keys(counts).sort();
      row.append(text("span", values.length ? values.map(function (value) { return distributionValueLabel(value, dimension[3]) + " " + counts[value]; }).join(" · ") : EMPTY_DISTRIBUTION_PHRASE));
      summary.append(row);
    });
    return summary;
  }

  function workflowGraph(run, route) {
    const section = el("section", "graph-panel semantic-zoom"); section.append(heading(2, "Dependency DAG · semantic zoom"));
    const graph = run.graph;
    if (!graph || !array(graph.waves).length) { section.append(empty("No Workflow dependency graph is projected.")); return section; }
    const lookup = Object.create(null); array(run.units).forEach(function (unit) { lookup[unit.logical_id] = unit; });
    const zoom = deriveSemanticZoom(graph, route.zoomStart);
    const selectedEntityCandidate = zoom.entities.find(function (entity) { return entity.kind === "cluster" && entity.key === route.selectedCluster && SEMANTIC_ZOOM_CLUSTER_KEY.test(entity.key); }) || null;
    const selectedArcCandidate = zoom.arcs.find(function (arc) { return arc.key === route.selectedArc; }) || null;
    const maximumMemberPage = selectedEntityCandidate ? Math.max(1, Math.ceil(selectedEntityCandidate.members.length / SEMANTIC_ZOOM_MEMBER_PAGE_SIZE)) : 1;
    const maximumEdgePage = selectedArcCandidate ? Math.max(1, Math.ceil(selectedArcCandidate.edges.length / SEMANTIC_ZOOM_EDGE_PAGE_SIZE)) : 1;
    const normalizedZoomRoute = Object.assign({}, route, {
      selectedCluster: selectedEntityCandidate ? selectedEntityCandidate.key : null,
      selectedArc: selectedArcCandidate ? selectedArcCandidate.key : null,
      memberPage: Math.min(Math.max(1, route.memberPage), maximumMemberPage),
      edgePage: Math.min(Math.max(1, route.edgePage), maximumEdgePage)
    });
    const canonicalZoomHash = semanticZoomRoute(normalizedZoomRoute, {});
    if (location.hash !== canonicalZoomHash) history.replaceState(null, "", canonicalZoomHash);
    route = normalizedZoomRoute;
    section.dataset.zoomStart = String(zoom.start);
    section.append(text("p", "Source (run-scoped) · " + titleCase(run.source && run.source.mode) + " · origin " + titleCase(run.source && run.source.durable_origin) + " · freshness " + titleCase(run.source && run.source.freshness) + " · limitations " + (array(run.source && run.source.limitations).map(titleCase).join(", ") || "none observed"), "provenance"));
    if (zoom.start > 0) section.append(link("← Previous zoom window", semanticZoomRoute(route, {zoomStart: Math.max(0, zoom.start - SEMANTIC_ZOOM_MAX_CLUSTERS), selectedCluster: null, selectedArc: null, memberPage: 1, edgePage: 1}), "zoom-back"));
    const overview = el("div", "cluster-overview"); overview.setAttribute("aria-label", "Workflow cluster overview");
    zoom.entities.forEach(function (entity) {
      const card = el("article", "cluster-card cluster-" + entity.kind); card.dataset.clusterKey = entity.key;
      card.append(heading(3, entity.label)); card.append(text("code", entity.key, "cluster-key")); card.append(semanticZoomSummary(run, entity, lookup));
      if (entity.kind === "overflow") {
        card.append(key(link("Open next zoom level", semanticZoomRoute(route, {zoomStart: entity.start, selectedCluster: null, selectedArc: null, memberPage: 1, edgePage: 1}), "overflow:" + entity.key), "overflow:" + entity.key));
      } else if (entity.kind === "cluster") {
        card.append(key(link("Inspect observed members", semanticZoomRoute(route, {selectedCluster: entity.key, selectedArc: null, memberPage: 1, edgePage: 1}), "cluster:" + entity.key), "cluster:" + entity.key));
      } else card.append(text("p", "Crosses the current zoom boundary.", "provenance"));
      overview.append(card);
    });
    section.append(overview);
    const arcs = el("section", "aggregate-arcs"); arcs.append(heading(3, "Aggregate dependency arcs"));
    if (!zoom.arcs.length) arcs.append(empty("No aggregate arcs are observed in this window."));
    zoom.arcs.forEach(function (arc) {
      const total = arc.counts.ready + arc.counts.blocked + arc.counts.unknown;
      const affected = array(run.limitations).length > 0 || arc.edges.some(function (edge) { return !lookup[edge.from] || !lookup[edge.to]; });
      const label = "Aggregate arc " + arc.from + " → " + arc.to + " · " + total + " observed edges · ready " + arc.counts.ready + " · blocked " + arc.counts.blocked + " · unknown " + arc.counts.unknown + (affected ? " · limited: projected graph or unit completeness" : "");
      arcs.append(key(link(label, semanticZoomRoute(route, {selectedArc: arc.key, selectedCluster: null, edgePage: 1, memberPage: 1}), "arc:" + arc.key), "arc:" + arc.key));
    });
    if (zoom.droppedEdges.length) arcs.append(text("p", zoom.droppedEdges.length + " projected edge" + (zoom.droppedEdges.length === 1 ? " was" : "s were") + " excluded from aggregate counts · limited: " + Array.from(new Set(zoom.droppedEdges.map(function (item) { return titleCase(item.reason); }))).join(", "), "limitation"));
    section.append(arcs);
    const selectedEntity = selectedEntityCandidate;
    if (selectedEntity) {
      const inspector = el("section", "cluster-inspector"); inspector.append(heading(3, "Selected cluster · " + selectedEntity.label));
      const members = selectedEntity.members.slice().sort(zoom.compareUnit);
      const visibleMembers = members.slice(0, route.memberPage * SEMANTIC_ZOOM_MEMBER_PAGE_SIZE);
      visibleMembers.forEach(function (id) {
        if (lookup[id]) inspector.append(unitSummary(run, lookup[id], route, "member:" + selectedEntity.key + ":" + id));
        else inspector.append(untrustedText("p", id + " · unit evidence absent", "limitation"));
      });
      if (visibleMembers.length < members.length) inspector.append(key(link("Show next " + Math.min(SEMANTIC_ZOOM_MEMBER_PAGE_SIZE, members.length - visibleMembers.length) + " members (" + visibleMembers.length + " of " + members.length + " shown)", semanticZoomRoute(route, {memberPage: route.memberPage + 1}), "members-next:" + selectedEntity.key), "members-next:" + selectedEntity.key));
      section.append(inspector);
    }
    const selectedArc = selectedArcCandidate;
    if (selectedArc) {
      const ledger = el("section", "exact-edge-ledger"); ledger.append(heading(3, "Exact-edge ledger for selected aggregate arc"));
      ledger.append(text("p", "These rows are exact projected dependencies; the selected overview arc is only an aggregate.", "provenance"));
      const visibleEdges = selectedArc.edges.slice(0, route.edgePage * SEMANTIC_ZOOM_EDGE_PAGE_SIZE);
      const list = el("ol"); visibleEdges.forEach(function (edge) { list.append(untrustedText("li", scalar(edge.from, "Unknown") + " → " + scalar(edge.to, "Unknown") + " — " + titleCase(edge.state))); }); ledger.append(list);
      if (visibleEdges.length < selectedArc.edges.length) ledger.append(key(link("Show next " + Math.min(SEMANTIC_ZOOM_EDGE_PAGE_SIZE, selectedArc.edges.length - visibleEdges.length) + " exact edges (" + visibleEdges.length + " of " + selectedArc.edges.length + " shown)", semanticZoomRoute(route, {edgePage: route.edgePage + 1}), "edges-next:" + selectedArc.key), "edges-next:" + selectedArc.key));
      section.append(ledger);
    }
    return section;
  }
  const FANOUT_GROUP_MEMBER_PAGE_SIZE = 12;
  const FANOUT_ATTENTION_FAMILY_ORDER = Object.freeze(["execution", "advisory", "liveness", "mutation", "virtual_diff", "evidence"]);
  const FANOUT_EXECUTION_STATE_ORDER = Object.freeze(["failed", "timed_out", "cancelled", "detached", "partial", "held", "unknown", "running", "queued", "planned", "completed", "closed"]);
  const FANOUT_ATTENTION_REASON_FAMILY = Object.freeze({
    execution_failed: "execution",
    execution_timed_out: "execution",
    execution_cancelled: "execution",
    execution_detached: "execution",
    execution_partial: "execution",
    execution_held: "execution",
    execution_unknown: "execution",
    advisory_stop: "advisory",
    advisory_needs_review: "advisory",
    advisory_gate_disagreement: "advisory",
    advisory_unparseable: "advisory",
    nonterminal_stale_handle: "liveness",
    nonterminal_owner_unavailable: "liveness",
    nonterminal_liveness_unknown: "liveness",
    terminal_ambiguous_close: "liveness",
    mutation_partial: "mutation",
    mutation_indeterminate: "mutation",
    mutation_unknown: "mutation",
    virtual_diff_unapplied: "virtual_diff",
    virtual_diff_apply_failed: "virtual_diff",
    virtual_diff_correlation_unknown: "virtual_diff",
    canonical_source_conflict: "evidence",
    durable_log_unavailable: "evidence",
    child_log_missing: "evidence",
    attempt_index_conflict: "evidence"
  });

  function fanoutReasonFamily(reason) {
    if (Object.prototype.hasOwnProperty.call(FANOUT_ATTENTION_REASON_FAMILY, reason)) return FANOUT_ATTENTION_REASON_FAMILY[reason];
    if (reason.startsWith("execution_")) return "execution";
    if (reason.startsWith("advisory_")) return "advisory";
    if (reason.startsWith("nonterminal_") || reason.startsWith("terminal_")) return "liveness";
    if (reason.startsWith("mutation_")) return "mutation";
    if (reason.startsWith("virtual_diff_")) return "virtual_diff";
    // Evidence reasons are exact-map-only: their four frozen tokens intentionally
    // share no trustworthy prefix. Future evidence-like tokens stay unmapped and
    // visible rather than being guessed into the evidence family.
    return null;
  }

  function fanoutGrouping(run) {
    const attentionGroups = Object.create(null);
    const executionGroups = Object.create(null);
    const unmappedGroup = {key: "attention:unmapped", family: "unmapped", members: [], occurrences: 0, reasons: Object.create(null)};
    FANOUT_ATTENTION_FAMILY_ORDER.forEach(function (family) { attentionGroups[family] = {key: "attention:" + family, family: family, members: [], occurrences: 0, reasons: Object.create(null)}; });
    FANOUT_EXECUTION_STATE_ORDER.forEach(function (execution) { executionGroups[execution] = {key: "execution:" + execution, execution: execution, members: []}; });
    const attentionUnits = [];
    const unmapped = [];
    let attentionOccurrences = 0;
    array(run.units).forEach(function (unit) {
      const attentionRequired = unit.attention && unit.attention.required;
      if (attentionRequired === false) {
        const execution = scalar(unit.execution && unit.execution.state, "unknown");
        const target = executionGroups[execution] || executionGroups.unknown;
        target.members.push(unit);
        return;
      }
      attentionUnits.push(unit);
      if (attentionRequired !== true) {
        unmapped.push({unit: unit, reason: "attention_requirement_unavailable"});
        unmappedGroup.members.push(unit);
        return;
      }
      const families = new Set();
      const unitUnmappedReasons = [];
      const reasons = Array.from(new Set(array(unit.attention && unit.attention.reasons).map(function (reason) { return scalar(reason, "unknown"); })));
      attentionOccurrences += reasons.length;
      reasons.forEach(function (reason) {
        const family = fanoutReasonFamily(reason);
        if (!family) {
          unmapped.push({unit: unit, reason: reason});
          unitUnmappedReasons.push(reason);
          return;
        }
        const group = attentionGroups[family];
        group.occurrences += 1;
        group.reasons[reason] = (group.reasons[reason] || 0) + 1;
        families.add(family);
      });
      FANOUT_ATTENTION_FAMILY_ORDER.forEach(function (family) { if (families.has(family)) attentionGroups[family].members.push(unit); });
      if (families.size === 0) {
        unmappedGroup.members.push(unit);
        unitUnmappedReasons.forEach(function (reason) {
          unmappedGroup.occurrences += 1;
          unmappedGroup.reasons[reason] = (unmappedGroup.reasons[reason] || 0) + 1;
        });
      }
    });
    const attention = FANOUT_ATTENTION_FAMILY_ORDER.map(function (family) { return attentionGroups[family]; }).filter(function (group) { return group.members.length > 0; });
    if (unmappedGroup.members.length > 0) attention.push(unmappedGroup);
    return {
      attentionSiblingCount: attentionUnits.length,
      attentionOccurrences: attentionOccurrences,
      attention: attention,
      execution: FANOUT_EXECUTION_STATE_ORDER.map(function (execution) { return executionGroups[execution]; }).filter(function (group) { return group.members.length > 0; }),
      unmapped: unmapped
    };
  }

  function fanoutGroupLimitations(run, members, group) {
    const values = [];
    array(run.limitations).concat(array(run.source && run.source.limitations)).forEach(function (value) { values.push(scalar(value, "unknown_source_limitation")); });
    array(members).forEach(function (unit) {
      array(unit.limitations).forEach(function (value) { values.push(scalar(value, "unknown_unit_limitation")); });
      if (group && group.family === "evidence" && array(unit.attention && unit.attention.reasons).includes("child_log_missing")) values.push("child_log_missing");
    });
    return Array.from(new Set(values));
  }

  function fanoutAttemptLinks(run, unit, route, groupKey) {
    const attempts = array(unit.attempts);
    if (!attempts.length) return null;
    const nav = el("nav", "attempt-lineage-links");
    nav.setAttribute("aria-label", "Attempt lineage for " + visible(unit.label).text);
    nav.append(text("span", "Attempts: ", "provenance"));
    attempts.forEach(function (attempt, index) {
      const label = attempt.ordinal === null || attempt.ordinal === undefined ? "Provisional" : "Attempt " + (attempt.ordinal + 1);
      nav.append(link(label, routeHash({runId: run.run.id, unitId: unit.logical_id, attemptId: attempt.attempt_id, filters: route.filters, sort: route.sort, q: route.q, follow: route.follow}), "attempt-summary-" + unit.logical_id + "-" + index + ":" + groupKey));
    });
    return nav;
  }

  function fanoutGroup(run, route, group, region) {
    const details = el("details", "fanout-group fanout-group-" + region);
    const pageKey = "fanout:" + encodeURIComponent(run.run.id) + ":" + group.key;
    setDisclosureKey(details, "fanout-group:" + run.run.id + ":" + group.key);
    const summary = key(el("summary"), "fanout-group-summary:" + pageKey);
    const countText = region === "attention" ? titleCase(group.family) + " · " + group.members.length + " siblings · " + group.occurrences + " reason occurrences" : titleCase(group.execution) + " · " + group.members.length + " siblings";
    summary.append(text("span", countText));
    const limitations = fanoutGroupLimitations(run, group.members, group);
    if (limitations.length) summary.append(untrustedText("span", "Observed count limited: " + limitations.map(titleCase).join(" · "), "limitation group-count-limitation"));
    details.append(summary);
    if (region === "attention") {
      const reasonEntries = Object.keys(group.reasons).sort();
      const reasonPageKey = pageKey + ":reasons";
      const reasonPage = state.pages[reasonPageKey] || 1;
      const shownReasons = reasonEntries.slice(0, reasonPage * FANOUT_GROUP_MEMBER_PAGE_SIZE);
      const reasonList = el("ul", "fanout-reason-counts");
      shownReasons.forEach(function (reason) { reasonList.append(untrustedText("li", reason + " · " + group.reasons[reason] + " occurrences")); });
      details.append(reasonList);
      if (shownReasons.length < reasonEntries.length) {
        const remainingReasons = reasonEntries.length - shownReasons.length;
        const revealReasons = Math.min(FANOUT_GROUP_MEMBER_PAGE_SIZE, remainingReasons);
        details.append(key(button("+" + remainingReasons + " more distinct reasons · show next " + revealReasons + " (" + shownReasons.length + " of " + reasonEntries.length + " distinct reasons shown; " + group.occurrences + " observed occurrences total)", function () {
          state.pages[reasonPageKey] = reasonPage + 1;
          details.open = true;
          state.restore = captureView();
          if (shownReasons.length + revealReasons >= reasonEntries.length) state.restore.focus = "fanout-group-summary:" + pageKey;
          renderCurrentGuarded();
        }, "continuation"), "continuation:" + reasonPageKey));
      }
    }
    const page = state.pages[pageKey] || 1;
    const shown = group.members.slice(0, page * FANOUT_GROUP_MEMBER_PAGE_SIZE);
    const list = el("ul", "fanout-tree");
    shown.forEach(function (unit) {
      const item = el("li");
      item.append(unitSummary(run, unit, route, "unit-" + unit.logical_id + ":" + group.key));
      const attempts = fanoutAttemptLinks(run, unit, route, group.key); if (attempts) item.append(attempts);
      list.append(item);
    });
    details.append(list);
    if (shown.length < group.members.length) {
      const remaining = group.members.length - shown.length;
      const reveal = Math.min(FANOUT_GROUP_MEMBER_PAGE_SIZE, remaining);
      details.append(key(button("+" + remaining + " more · show next " + reveal + " (" + shown.length + " of " + group.members.length + " observed siblings shown)", function () {
        state.pages[pageKey] = page + 1;
        details.open = true;
        state.restore = captureView();
        if (shown.length + reveal >= group.members.length) state.restore.focus = "fanout-group-summary:" + pageKey;
        renderCurrentGuarded();
      }, "continuation"), "continuation:" + pageKey));
    }
    return details;
  }

  function fanoutTree(run, route) {
    const section = el("section", "fanout-panel"); section.append(heading(2, "Parent and sibling fan-out"));
    section.append(untrustedText("p", "Parent Session: " + scalar(run.run.parent_session_id, "Unknown"), "tree-parent"));
    section.append(text("p", "Sibling membership only. No dependency edges are inferred for fan-out runs.", "provenance"));
    const grouping = fanoutGrouping(run);
    const attention = el("section", "fanout-region fanout-attention-region");
    attention.append(heading(3, "Attention · " + grouping.attentionSiblingCount + " siblings need attention (" + grouping.attentionOccurrences + " reason occurrences)"));
    const attentionCountLimitations = fanoutGroupLimitations(run, [], null);
    if (attentionCountLimitations.length) attention.append(untrustedText("span", "Observed count limited: " + attentionCountLimitations.map(titleCase).join(" · "), "limitation group-count-limitation"));
    if (grouping.unmapped.length) {
      const unmappedReasonCounts = Object.create(null);
      grouping.unmapped.forEach(function (item) { unmappedReasonCounts[item.reason] = (unmappedReasonCounts[item.reason] || 0) + 1; });
      const unmappedReasonSummary = Object.keys(unmappedReasonCounts).sort().map(function (reason) { return reason + " · " + unmappedReasonCounts[reason] + " occurrences"; });
      attention.append(untrustedText("p", "Unmapped observed attention reasons (never dropped; mixed-family siblings stay in their mapped groups): " + unmappedReasonSummary.join(" · "), "limitation group-count-limitation"));
    }
    if (!grouping.attention.length) attention.append(empty("No parent-observed attention groups."));
    grouping.attention.forEach(function (group) { attention.append(fanoutGroup(run, route, group, "attention")); });
    section.append(attention);
    const executionRegion = el("section", "fanout-region fanout-execution-region");
    executionRegion.append(heading(3, "No parent-observed attention required"));
    if (!grouping.execution.length) executionRegion.append(empty("No siblings without parent-observed attention."));
    grouping.execution.forEach(function (group) { executionRegion.append(fanoutGroup(run, route, group, "execution")); });
    section.append(executionRegion);
    return section;
  }
  function evidenceDrawer(run, refs, disclosureKey) {
    const selected = refs ? array(run.evidence).filter(function (evidence) { return refs.includes(evidence.id); }) : array(run.evidence);
    const details = setDisclosureKey(el("details", "evidence-drawer"), disclosureKey || "evidence");
    details.append(text("summary", "Evidence (" + selected.length + ")"));
    const pageKey = "evidence:" + encodeURIComponent(run.run.id) + ":" + encodeURIComponent(disclosureKey || "all"); const page = state.pages[pageKey] || 1; const shown = selected.slice(0, page * LIMITS.evidence);
    const list = el("ol");
    shown.forEach(function (evidence) {
      const item = el("li", "evidence-row"); item.dataset.authority = evidence.authority;
      item.append(untrustedText("strong", evidence.id)); item.append(marker(evidence.authority, "authority", evidence.source_kind));
      projected(item, "p", evidence.description);
      item.append(untrustedText("small", scalar(evidence.session_id, "No Session") + " · seq " + scalar(evidence.seq, "—") + " · " + titleCase(evidence.source_kind), "provenance"));
      list.append(item);
    });
    details.append(list);
    if (shown.length < selected.length) details.append(key(button("Show next 100 evidence rows", function () { state.pages[pageKey] = page + 1; details.open = true; renderCurrentGuarded(); }, "continuation"), "continuation:" + pageKey));
    return details;
  }
  function limitationsPanel(values) {
    const section = el("section", "limitations-panel"); section.append(heading(2, "Limitations"));
    const items = array(values); if (!items.length) section.append(empty("No projected limitations."));
    else { const list = el("ul"); items.forEach(function (item) { list.append(untrustedText("li", titleCase(item), "limitation")); }); section.append(list); }
    return section;
  }
  /**
   * Renders the follow panel for a run detail. Follow is explicit route state —
   * a selection-stability policy that keeps the same logical run selected across
   * authoritative refetches. It never silently switches runs; terminal and
   * degraded conditions are surfaced as labeled markers, and identity loss
   * degrades deterministically via renderFollowDegraded.
   * @param {Object} run Projected run detail.
   * @param {Object} route Parsed route carrying the follow flag.
   * @returns {HTMLElement}
   */
  function followToggle(run, route) {
    const wrap = el("section", "follow-panel");
    wrap.dataset.followState = route.follow === true ? "following" : "not_following";
    wrap.setAttribute("role", "status");
    if (route.follow === true) {
      wrap.append(text("strong", "Following this run"));
      wrap.append(text("p", "Follow keeps this logical run selected across authoritative refetches. It never silently switches runs.", "provenance"));
      if (run.execution && run.execution.terminal === true) wrap.append(labeledMarker("Followed run reached a terminal state: " + titleCase(run.execution.state), run.execution.state, "follow execution", run.execution.basis));
      const liveness = run.liveness && run.liveness.state;
      if (liveness === "owner_unavailable" || liveness === "stale_handle") wrap.append(labeledMarker("Followed run is " + titleCase(liveness), liveness, "follow liveness", run.liveness && run.liveness.basis));
      wrap.append(link("Unfollow", semanticZoomRoute(route, {follow: false}), "follow-off"));
    } else {
      wrap.append(link("Follow this run", semanticZoomRoute(route, {follow: true}), "follow-on"));
    }
    return wrap;
  }
  function renderFollowErrorView(route, options, failure) {
    // Every follow failure view is mounted HERE, so this is where the replayable
    // paint is recorded — not at the callers, and not only inside
    // renderProjectionFailure. renderDetail and renderUnit bail out to
    // renderFollowIdentityConflict / renderFollowSnapshotUnavailable directly,
    // never through renderProjectionFailure, so a record kept only there is null
    // for exactly the conflict views whose assertion the replay exists to hold.
    // The OVERLAY dimension is DELETED from the recorded route, not pinned to
    // null. `route` is captured by value here, so a repaint that happens while
    // the manual pane is open (the view's own Refetch/Retry controls, an
    // SSE-driven refresh) would otherwise freeze `manual` into the record. The
    // manual-only fast path replays that record after the pane CLOSES, and every
    // link built via semanticZoomRoute re-serializes the frozen field — so
    // "Unfollow and return to Runs" would reopen the pane the reader just
    // dismissed.
    //
    // Deleting rather than nulling is what keeps the OTHER direction right too.
    // An explicit null is a standing order to close the pane, which would make
    // this view the one screen whose exits drop an OPEN manual — the exact
    // two-behaviours-on-one-screen split the orthogonality contract forbids. An
    // ABSENT field inherits the live hash instead, so the replayed exits carry
    // whatever pane state actually holds at replay time: closed after a close,
    // open while the pane is open. Nothing in this view may legitimately read
    // the overlay dimension (it reads route only for
    // runId/unitId/workspace/follow/filters/sort/q), and replaceContent re-reads
    // location.hash to mount the pane, so pane presence is unchanged either way.
    const paintRoute = Object.assign({}, route);
    delete paintRoute.manual;
    state.lastPaint = function () { renderFollowErrorView(paintRoute, options, failure); };
    const root = el("div", "view error-view " + options.className);
    if (failure) applyFailureDiagnostic(root, failure);
    root.dataset.followState = options.followState;
    root.append(heading(1, options.title));
    root.append(untrustedText("p", options.message, "empty-state"));
    root.append(text("p", options.provenance, "provenance"));
    if (route.runId) {
      const canonical = semanticZoomRoute(route, {follow: true});
      root.append(button(options.retryLabel, function () {
        const currentRoute = parseRoute(location.hash);
        const currentCanonical = currentRoute.runId ? semanticZoomRoute(currentRoute, {follow: true}) : canonical;
        if (currentRoute.runId && location.hash !== currentCanonical) { state.forceRefetch = true; location.hash = currentCanonical; } else refreshSingleFlight(options.retryReason);
      }, "follow-retry"));
    }
    root.append(button("Refetch authoritative snapshot", function () { refreshSingleFlight(options.retryReason); }, "continuation"));
    root.append(link("Unfollow and return to Runs", semanticZoomRoute(route, {runId: null, unitId: null, attemptId: null, follow: false}), "return-runs"));
    // The resolved-parent affordance is ADDITIVE: it is appended after the
    // existing exits, and when nothing resolves it contributes no element and
    // no status text, leaving this dead end byte-identical to before (#438).
    const resolution = parentResolutionPanel(route);
    if (resolution) root.append(resolution);
    replaceContent(root, options.announcement);
    setStatus(options.status + resolutionStatusSuffix(route));
  }
  function renderFollowDegraded(route, message, failure) {
    renderFollowErrorView(route, {
      className: "follow-degraded",
      followState: "degraded",
      title: "Follow degraded",
      message: message,
      provenance: "The followed run is not projected in the authoritative snapshot. Follow never silently switches to another run; it degrades here deterministically.",
      retryLabel: "Retry followed run",
      retryReason: "follow retry",
      announcement: "Follow degraded. " + message,
      status: "Follow degraded · followed identity unavailable · authoritative snapshots remain available"
    }, failure);
  }
  function renderFollowUnitUnavailable(route, message, failure) {
    renderFollowErrorView(route, {
      className: "follow-unit-unavailable",
      followState: "unit_unavailable",
      title: "Unit unavailable while following",
      message: message,
      provenance: "The followed run identity is still projected. Only this logical unit is absent within the followed run; Follow did not switch or lose the run.",
      retryLabel: "Retry followed unit",
      retryReason: "follow unit retry",
      announcement: "Followed run remains selected; the logical Unit is unavailable. " + message,
      status: "Followed run present · logical unit unavailable · authoritative snapshots remain available"
    }, failure);
  }
  function renderFollowSnapshotUnavailable(route, message, failure) {
    const cachedIdentity = state.detailId === route.runId && (!workspaceSetMode() || state.detailWorkspace === route.workspace);
    const unstructured404 = failure && failure.phase === "fetch" && failure.status === 404 && failure.structured !== true;
    const structuredNonLoss404 = failure && failure.phase === "fetch" && failure.status === 404 && failure.structured === true && failure.kind !== "run_not_found";
    const transientFetch = failure && failure.phase === "fetch" && failure.status !== 404;
    const decodeFailure = failure && failure.phase === "decode";
    const preservedIdentityFailure = cachedIdentity && (transientFetch || decodeFailure);
    const unavailableProvenance = unstructured404 ? "The authoritative response was not a structured run-not-found signal. Any cached Follow snapshot for this followed run was discarded; this response did not confirm identity and Follow did not infer loss." : structuredNonLoss404 ? "The authoritative response was structured but did not confirm run-not-found. Any cached Follow snapshot for this followed run was discarded; this response did not confirm identity and Follow did not infer identity loss." : preservedIdentityFailure ? "The latest authoritative response could not be used. The followed identity was last confirmed for this run; Follow did not infer identity loss." : route.unitId ? "The authoritative snapshot could not confirm either the followed run or this logical Unit. Follow did not switch or infer identity loss." : "The authoritative snapshot could not confirm the followed run. Follow did not switch or infer identity loss.";
    const unavailableStatus = preservedIdentityFailure ? "Follow refetch failed · identity last confirmed · authoritative snapshots remain available" : "Follow snapshot unavailable · identity not confirmed · authoritative snapshots remain available";
    renderFollowErrorView(route, {
      className: "follow-snapshot-unavailable",
      followState: "snapshot_unavailable",
      title: "Follow snapshot unavailable",
      message: message,
      provenance: unavailableProvenance,
      retryLabel: route.unitId ? "Retry followed unit" : "Retry followed run",
      retryReason: "follow snapshot retry",
      announcement: "Follow snapshot unavailable. " + message,
      status: unavailableStatus
    }, failure);
  }
  function renderFollowIdentityConflict(route, message, failure) {
    renderFollowErrorView(route, {
      className: "follow-identity-conflict",
      followState: "identity_conflict",
      title: "Follow identity conflict",
      message: message,
      provenance: "The authoritative snapshot contradicted the followed run identity. Follow did not switch runs or infer that the followed identity disappeared.",
      retryLabel: route.unitId ? "Retry followed unit" : "Retry followed run",
      retryReason: "follow identity conflict retry",
      announcement: "Follow identity conflict. " + message,
      status: "Follow identity conflict · followed identity not confirmed · authoritative snapshots remain available"
    }, failure);
  }
  function renderFollowRenderFailure(route, message, failure) {
    renderFollowErrorView(route, {
      className: "follow-render-failure",
      followState: "render_failure",
      title: "Follow display failed",
      message: message,
      provenance: "The followed identity was last confirmed by an authoritative snapshot, but this view could not display it. Follow did not switch or infer identity loss.",
      retryLabel: route.unitId ? "Retry followed unit" : "Retry followed run",
      retryReason: "follow display retry",
      announcement: "Follow display failed. " + message,
      status: "Follow display failed · followed identity last confirmed · authoritative snapshots remain available"
    }, failure);
  }
  function renderDetail() {
    const run = state.detail; const route = parseRoute(location.hash);
    if (!run || !run.run || typeof run.run.id !== "string" || !run.run.id) return route.follow === true ? renderFollowSnapshotUnavailable(route, "Run projection is unavailable.") : renderUnavailable("Run projection is unavailable.");
    if (route.runId !== run.run.id) return route.follow === true ? renderFollowIdentityConflict(route, "The authoritative snapshot returned a different run identity than the one being followed.") : renderUnavailable("The requested run no longer matches this projection.");
    const root = el("div", "view detail-view");
    root.append(link("← Runs", semanticZoomRoute(route, {runId: null, unitId: null, attemptId: null, follow: false}), "back-runs"));
    const titleRow = el("div", "title-with-copy"); titleRow.append(projectedHeading(1, scalar(run.run.title, run.run.id))); titleRow.append(copyValueButton(run.run.id, "run id")); root.append(titleRow);
    root.append(followToggle(run, route));
    const lede = el("div", "lede-with-copy");
    lede.append(untrustedText("p", runSubtitleSegments(run).join(" · "), "lede"));
    lede.append(copyValueButton(run.projection_id, "projection id"));
    root.append(lede);
    root.append(truthRail(run, route)); root.append(mutationPanel(run.mutation));
    const overview = setDisclosureKey(el("details", "overview-disclosure"), "run-overview:" + run.run.id); overview.append(text("summary", "Run identifiers and counts")); overview.append(runOverview(run)); root.append(overview);
    if (run.run.strategy === "workflow") {
      root.append(workflowGraph(run, route));
    } else {
      root.append(fanoutTree(run, route));
    }
    root.append(usagePanel(run.usage, "usage:run:" + run.run.id)); root.append(actionsPanel(run.safe_actions, "run", run.run.id));
    root.append(limitationsPanel(run.limitations)); root.append(evidenceDrawer(run, null, "run-evidence"));
    replaceContent(root, (run.run.strategy === "workflow" ? "Workflow" : "Subagent fan-out") + " run updated.");
    setStatus("Read-only · " + titleCase(run.source && run.source.mode) + " projection · as of seq " + scalar(run.source && run.source.as_of_seq, "unknown"));
  }

  /**
   * Segments of the run detail subtitle (#441). Every segment names the fact it
   * reports, and an unknown enum is dropped rather than rendered as the bare word
   * `unknown` — the projected mode is frequently absent, and a bare token tells an
   * operator nothing about which dimension is unknown. Filling `run.mode` upstream
   * is a separate concern; this only refuses to render an empty slot. The
   * `projection_id` is minted already carrying its `projection:` prefix, so it is
   * pushed verbatim with no second human-facing `projection` word: the id an
   * operator cites when reporting a projection bug must match the snapshot field
   * exactly. An absent id is dropped for the same reason an unknown enum is: a
   * literal `unknown` in the id slot is the bare token this subtitle exists to
   * eliminate, and the copy control already announces the value as unavailable.
   * Joining a filtered array is what keeps dropped slots from leaving a
   * doubled, leading, or trailing separator.
   * @param {Object} run Run projection snapshot.
   * @returns {Array<string>} Ordered, non-empty subtitle segments.
   */
  function runSubtitleSegments(run) {
    const segments = [];
    const strategy = run.run && run.run.strategy;
    const mode = run.run && run.run.mode;
    if (strategy && strategy !== "unknown") segments.push(titleCase(strategy));
    if (mode && mode !== "unknown") segments.push("Workspace mode " + titleCase(mode));
    if (run.projection_id) segments.push(String(run.projection_id));
    return segments;
  }
  /**
   * Collapsed-summary label for `usage.complete` (#441). The claim is scoped to
   * the usage evidence: beside a running run the bare word "Complete" read as a
   * statement that the run had finished. `usage.complete` is a builder fact about
   * evidence completeness with no relation to `execution.state`, so the label
   * names its subject. Both polarities stay visible while the panel is collapsed
   * because partial usage evidence is load-bearing provenance.
   * @param {?Object} usage Projection usage object.
   * @returns {string} Scoped completeness label.
   */
  function usageCompletenessLabel(usage) {
    return usage && usage.complete === true ? "Evidence complete" : "Evidence incomplete";
  }
  function usagePanel(usage, disclosureKey) {
    const section = setDisclosureKey(el("details", "usage-panel"), disclosureKey);
    section.append(text("summary", "Evidence-derived usage · " + scalar(usage && usage.calls, 0) + " calls · " + usageCompletenessLabel(usage)));
    section.append(text("p", scalar(usage && usage.calls, 0) + " durable provider call(s) · " + (usage && usage.complete ? "complete at observed boundary" : "incomplete") + " · source " + titleCase(usage && usage.source), "provenance"));
    const groups = array(usage && usage.groups);
    if (!groups.length) section.append(empty("No attributable provider usage groups."));
    else {
      const table = el("table"); const head = el("thead"); const tr = el("tr");
      ["Provider / model", "Calls", "Input", "Output", "Reasoning", "Total", "Cached", "Cache create", "Cache read"].forEach(function (name) { tr.append(text("th", name)); }); head.append(tr); table.append(head);
      const body = el("tbody"); groups.forEach(function (group) { const row = el("tr"); row.append(untrustedText("td", scalar(group.provider, "unknown") + " / " + scalar(group.model, "unknown"))); ["calls", "input_tokens", "output_tokens", "reasoning_tokens", "total_tokens", "cached_tokens", "cache_creation_tokens", "cache_read_tokens"].forEach(function (name) { row.append(text("td", scalar(group[name], 0))); }); body.append(row); }); table.append(body); section.append(table);
    }
    array(usage && usage.limitations).forEach(function (item) { section.append(untrustedText("p", titleCase(item), "limitation")); });
    return section;
  }
  function activityFor(run, attempt) {
    const refs = array(attempt.evidence_refs);
    return array(run.evidence).filter(function (evidence) { return refs.includes(evidence.id); });
  }
  function attemptCard(run, unit, attempt, selected) {
    const card = el("article", "attempt-card"); card.dataset.attemptId = attempt.attempt_id;
    if (selected) card.classList.add("selected");
    const ordinal = attempt.ordinal === null || attempt.ordinal === undefined ? "Provisional" : "Attempt " + (attempt.ordinal + 1);
    const header = el("header"); header.append(heading(3, ordinal)); header.append(marker(attempt.status, "attempt execution", attempt.status_basis)); header.append(text("span", titleCase(attempt.relation), "relation"));
    const activeRoute = parseRoute(location.hash);
    header.append(link("Select", semanticZoomRoute(activeRoute, {attemptId: attempt.attempt_id}), "attempt-" + attempt.attempt_id));
    card.append(header);
    const facts = el("dl", "attempt-facts");
    const childField = field("Child Session", attempt.child_session_id); childField.querySelector("dd").append(copyValueButton(attempt.child_session_id, "child Session id")); facts.append(childField);
    if (attempt.predecessor_attempt_id) {
      const predecessor = array(unit.attempts).find(function (candidate) { return candidate.attempt_id === attempt.predecessor_attempt_id; });
      if (predecessor) {
        const predecessorFact = el("div", "field"); predecessorFact.append(text("dt", "Predecessor"));
        const predecessorLabel = predecessor.ordinal === null || predecessor.ordinal === undefined ? "Provisional" : "Attempt " + (predecessor.ordinal + 1);
        const predecessorLink = projectedLink("↩ " + predecessorLabel + " · " + scalar(predecessor.child_session_id, "Unknown child"), semanticZoomRoute(activeRoute, {attemptId: predecessor.attempt_id}), "predecessor-" + predecessor.attempt_id);
        predecessorLink.addEventListener("click", function () { state.pendingAttemptScroll = predecessor.attempt_id; });
        predecessorFact.append(predecessorLink); facts.append(predecessorFact);
      }
    }
    facts.append(field("Started", attempt.started_at)); facts.append(field("Ended", attempt.ended_at)); facts.append(field("Error", attempt.error_kind)); facts.append(field("Materialization", attempt.materialization)); facts.append(field("Window basis", attempt.child_event_window && attempt.child_event_window.basis)); facts.append(field("From seq", attempt.child_event_window && attempt.child_event_window.from_seq)); facts.append(field("To seq exclusive", attempt.child_event_window && attempt.child_event_window.to_seq_exclusive)); card.append(facts);
    if (attempt.summary) projected(card, "p", attempt.summary, "attempt-summary");
    if (attempt.usage) card.append(usagePanel(attempt.usage, "usage:attempt:" + attempt.attempt_id));
    else {
      const unavailable = setDisclosureKey(el("details", "usage-panel"), "usage:attempt:" + attempt.attempt_id);
      unavailable.append(text("summary", "Evidence-derived usage · unavailable"));
      unavailable.append(text("p", "No attributable attempt usage is available; call and token totals are unknown.", "provenance"));
      card.append(unavailable);
    }
    const activity = setDisclosureKey(el("details", "activity-drawer"), "activity:" + attempt.attempt_id); activity.append(text("summary", "Attempt activity via evidence references (" + activityFor(run, attempt).length + ")"));
    const allActivity = activityFor(run, attempt); const activityPageKey = "activity:" + encodeURIComponent(run.run.id) + ":" + encodeURIComponent(unit.logical_id) + ":" + encodeURIComponent(attempt.attempt_id); const activityPage = state.pages[activityPageKey] || 1;
    const newestFirst = state.activityOrder[activityPageKey] === "newest";
    activity.append(button(newestFirst ? "Order: newest first" : "Order: chronological (oldest first)", function () { state.activityOrder[activityPageKey] = newestFirst ? "chronological" : "newest"; state.pages[activityPageKey] = 1; renderCurrentGuarded(); }, "activity-order"));
    const orderedActivity = newestFirst ? allActivity.slice().reverse() : allActivity;
    const visibleActivity = orderedActivity.slice(0, activityPage * LIMITS.evidence);
    const activityTable = el("table", "activity-table"); const activityHead = el("thead"); const activityHeader = el("tr"); ["Authority", "Source kind", "Session", "Seq", "Description"].forEach(function (name) { activityHeader.append(text("th", name)); }); activityHead.append(activityHeader); activityTable.append(activityHead);
    const activityBody = el("tbody"); visibleActivity.forEach(function (evidence) { const row = el("tr"); row.append(text("td", titleCase(evidence.authority))); row.append(text("td", titleCase(evidence.source_kind))); row.append(untrustedText("td", evidence.session_id)); row.append(text("td", scalar(evidence.seq, "—"))); row.append(untrustedText("td", evidence.description)); activityBody.append(row); }); activityTable.append(activityBody); activity.append(activityTable);
    if (visibleActivity.length < allActivity.length) activity.append(key(button("Show next 100 activity rows", function () { state.pages[activityPageKey] = activityPage + 1; activity.open = true; renderCurrentGuarded(); }, "continuation"), "continuation:" + activityPageKey));
    card.append(activity);
    array(attempt.limitations).forEach(function (item) { card.append(untrustedText("p", titleCase(item), "limitation")); });
    return card;
  }
  function hasDangerousShell(command) { return /(?:[|;&`<>]|\$\(|\$\{|\n|\r)/u.test(command); }
  function hasReviewCodepoint(command) {
    return /^[\s]|[\s]$/u.test(command) || /[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f-\u009f\u061c\u200e\u200f\u2028-\u202e\u2066-\u2069]/u.test(command);
  }
  /**
   * Classifies a projected safe action's command for the copy affordance. The
   * monitor never executes commands; classification only decides whether a copy
   * needs explicit byte review first (mutating effect, control or whitespace
   * codepoints, or shell syntax).
   * @param {Object} action Projected safe action.
   * @returns {{copyable: boolean, review: boolean, reason: string}}
   */
  function classifyCommand(action) {
    const command = action && typeof action.command === "string" ? action.command : "";
    if (!command || !action || action.presentation !== "copy_only") return {copyable: false, review: false, reason: "not_copyable"};
    if (action.effect === "mutating") return {copyable: true, review: true, reason: "mutating"};
    if (hasReviewCodepoint(command)) return {copyable: true, review: true, reason: "controls_or_whitespace"};
    if (hasDangerousShell(command)) return {copyable: true, review: true, reason: "shell_syntax"};
    return {copyable: true, review: false, reason: "simple"};
  }
  /**
   * Escapes evidence text for the clipboard: newlines, carriage returns, and
   * tabs become their two-character escapes, and every other control or
   * bidirectional codepoint becomes a visible Unicode escape. This is the only
   * transform between projected text and the single clipboard sink.
   * @param {string} raw Projected evidence text.
   * @returns {string} Escaped text safe to paste anywhere.
   */
  function escapedEvidence(raw) {
    let result = "";
    for (const character of raw) {
      const cp = character.codePointAt(0);
      if (cp === 0x0a) result += "\\n"; else if (cp === 0x0d) result += "\\r"; else if (cp === 0x09) result += "\\t";
      else if (cp < 0x20 || (cp >= 0x7f && cp <= 0x9f) || (cp >= 0x2028 && cp <= 0x202e) || (cp >= 0x2066 && cp <= 0x2069) || cp === 0x061c || cp === 0x200e || cp === 0x200f) result += "\\u{" + cp.toString(16).toUpperCase() + "}";
      else result += character;
    }
    return result;
  }
  // Clipboard contract (FROZEN for v1.x): escaped-only. Every copy affordance routes
  // through writeClipboard, which applies escapedEvidence at the single sink. No raw-byte
  // copy path exists anywhere in this bundle; hostile text stays literal on screen.
  function writeClipboard(value, onDone, successMessage) {
    if (!navigator.clipboard || typeof navigator.clipboard.writeText !== "function") { announce("Clipboard unavailable. Nothing was copied."); return; }
    navigator.clipboard.writeText(escapedEvidence(scalar(value, ""))).then(function () { announce(successMessage || "Safely escaped command evidence copied without an added newline."); if (onDone) onDone(); }).catch(function () { announce("Clipboard permission denied. Nothing was copied."); });
  }
  function copyProjectedValue(value, label) {
    const raw = scalar(value, "");
    if (!raw) { announce(label + " is unavailable. Nothing was copied."); return; }
    if (hasReviewCodepoint(raw)) reviewProjectedValueModal(raw, label);
    else writeClipboard(raw, null, label + " safely escaped evidence copied without an added newline.");
  }
  function copyValueButton(value, label) {
    const node = button("⧉", function () { copyProjectedValue(value, label); }, "copy-id-button");
    node.setAttribute("aria-label", "Copy " + label); return node;
  }
  function reviewModal(action) {
    const dialog = el("dialog", "review-dialog"); dialog.setAttribute("aria-labelledby", "review-title");
    dialog.append(heading(2, "Review command before copying")); dialog.lastChild.id = "review-title";
    dialog.append(text("p", "Reason: " + titleCase(classifyCommand(action).reason) + ". This monitor never executes commands."));
    projected(dialog, "pre", action.command, "command-review");
    const actions = el("div", "dialog-actions");
    actions.append(button("Cancel", function () { dialog.close(); dialog.remove(); }, "secondary"));
    actions.append(button("Copy safely escaped evidence", function () { writeClipboard(action.command, function () { dialog.close(); dialog.remove(); }, "Safely escaped command evidence copied without an added newline."); }, "primary"));
    dialog.append(text("p", "Escaped-only clipboard is frozen for v1.x. No raw-byte copy exists.", "provenance"));
    dialog.append(actions); document.body.append(dialog); dialog.showModal();
  }
  function reviewProjectedValueModal(value, label) {
    const dialog = el("dialog", "review-dialog"); dialog.setAttribute("aria-labelledby", "projected-review-title");
    dialog.append(heading(2, "Review " + label + " before copying")); dialog.lastChild.id = "projected-review-title";
    dialog.append(text("p", "Projected identifiers with controls or surrounding whitespace require explicit byte review."));
    projected(dialog, "pre", value, "command-review");
    const actions = el("div", "dialog-actions");
    actions.append(button("Cancel", function () { dialog.close(); dialog.remove(); }, "secondary"));
    actions.append(button("Copy safely escaped evidence", function () { writeClipboard(value, function () { dialog.close(); dialog.remove(); }, label + " safely escaped evidence copied without an added newline."); }, "primary"));
    dialog.append(text("p", "Escaped-only clipboard is frozen for v1.x. No raw-byte copy exists.", "provenance"));
    dialog.append(actions); document.body.append(dialog); dialog.showModal();
  }
  function artifactPanel(artifacts) {
    const section = el("section", "artifacts-panel"); section.append(heading(2, "Artifacts"));
    const values = array(artifacts); if (!values.length) { section.append(empty("No projected artifacts.")); return section; }
    const list = el("ul"); values.slice(0, LIMITS.evidence).forEach(function (artifact) {
      const item = el("li", "artifact-row"); item.append(untrustedText("strong", titleCase(artifact.kind))); item.append(marker(artifact.status, "artifact", artifact.correlation));
      const facts = el("dl", "artifact-facts"); [
        ["Version", artifact.version], ["Hash", artifact.hash], ["Workspace strategy", artifact.workspace_strategy],
        ["Producer unit", artifact.producer_unit_id], ["Source artifact hash", artifact.source_artifact_hash],
        ["Application state", artifact.application_state], ["Applied by unit", artifact.applied_by_unit_id], ["Correlation", artifact.correlation]
      ].forEach(function (entry) { facts.append(field(entry[0], entry[1])); }); item.append(facts); list.append(item);
    }); section.append(list); return section;
  }
  function actionsPanel(actions, contextKind, contextId) {
    const section = el("section", "actions-panel"); section.append(heading(2, "Structured safe actions"));
    const values = array(actions);
    if (!values.length) {
      const kind = scalar(contextKind, "surface");
      section.append(untrustedText("p", "No registered safe actions for " + kind + " " + scalar(contextId, "unknown") + ".", "empty-state"));
      section.append(text("p", "This " + kind + " exposes no executable affordance. Registered copy_only actions are the only executable affordance the monitor ever offers.", "provenance"));
      return section;
    }
    const list = el("ul"); values.forEach(function (action) {
      const item = el("li", "action-row"); item.append(untrustedText("strong", titleCase(action.id))); item.append(text("span", titleCase(action.effect) + " · " + titleCase(action.kind) + " · from " + titleCase(action.source_field), "provenance"));
      const classification = classifyCommand(action);
      if (classification.copyable) {
        projected(item, "code", action.command);
        item.append(button(classification.review ? "Review to copy" : "Copy command", function () { if (classification.review) reviewModal(action); else writeClipboard(action.command); }, "copy-button"));
      } else item.append(text("p", "Informational guidance only. No executable control is exposed."));
      list.append(item);
    }); section.append(list); return section;
  }
  function renderUnit() {
    const run = state.detail; const route = parseRoute(location.hash);
    if (!run || !run.run || typeof run.run.id !== "string" || !run.run.id) return route.follow === true ? renderFollowSnapshotUnavailable(route, "Run projection is unavailable.") : renderUnavailable("Run projection is unavailable.");
    if (route.runId !== run.run.id) return route.follow === true ? renderFollowIdentityConflict(route, "The authoritative snapshot returned a different run identity than the one being followed.") : renderUnavailable("The requested run no longer matches this projection.");
    const unit = array(run.units).find(function (candidate) { return candidate.logical_id === route.unitId; });
    if (!unit) return route.follow === true ? renderFollowUnitUnavailable(route, "This logical unit is absent within the followed run's last authoritative snapshot or its provisional deep link was invalidated.") : renderUnavailable("This logical unit is absent or its provisional deep link was invalidated.");
    const root = el("div", "view unit-view"); root.append(projectedLink("← " + scalar(run.run.title, run.run.id), semanticZoomRoute(route, {unitId: null, attemptId: null}), "back-run"));
    root.append(followToggle(run, route));
    const unitTitle = el("div", "title-with-copy"); unitTitle.append(projectedHeading(1, unit.label)); unitTitle.append(copyValueButton(unit.logical_id, "logical id")); root.append(unitTitle); root.append(untrustedText("p", "Logical unit · " + unit.logical_id, "lede"));
    const unitOverview = el("dl", "run-overview"); [["Agent", unit.agent], ["Kind", unit.unit_kind], ["Execution kind", unit.execution_kind], ["Workspace", unit.workspace_mode], ["Posture", unit.posture], ["Materialization", unit.materialization], ["Depends on", array(unit.depends_on).join(", ") || "None"]].forEach(function (entry) { unitOverview.append(field(entry[0], entry[1])); }); root.append(unitOverview);
    const dimensions = el("div", "unit-dimensions");
    dimensions.append(text("p", "Dotted labels are axes with a manual entry. Values are never marked.", "rail-orientation"));
    dimensions.append(truthCard(route, "Execution", "execution", unit.execution && unit.execution.state, unit.execution && unit.execution.basis)); dimensions.append(truthCard(route, "Liveness", "liveness", unit.liveness && unit.liveness.state, unit.liveness && unit.liveness.basis)); dimensions.append(labeledTruthCard(route, "Runtime gate", "gate", unitGateLabel(unit), unit.gate && unit.gate.state, unit.gate && unit.gate.basis)); dimensions.append(labeledTruthCard(route, "Model advisory", "advisory", unitAdvisoryLabel(unit), unit.advisory && unit.advisory.verdict, ADVISORY_FOLD_BASIS, "Declared gate: " + scalar(unit.advisory && unit.advisory.declared_gate, "none"))); root.append(dimensions);
    if (unit.advisory && unit.advisory.present) { const advisory = el("section", "advisory-panel"); advisory.append(heading(2, "Model-authored advisory")); advisory.append(text("p", "This content is advisory and cannot alter the runtime gate.", "provenance")); projected(advisory, "p", unit.advisory.summary || unit.advisory.raw_excerpt || "No summary"); root.append(advisory); }
    const lineage = el("section", "lineage"); lineage.append(heading(2, "Attempt lineage")); const attempts = array(unit.attempts); const attemptPageKey = "attempts:" + encodeURIComponent(run.run.id) + ":" + encodeURIComponent(unit.logical_id); const selectedAttemptIndex = attempts.findIndex(function (attempt) { return attempt.attempt_id === route.attemptId; }); const projectedAttemptId = selectedAttemptIndex >= 0 ? route.attemptId : null; const selectedAttemptPage = selectedAttemptIndex < 0 ? 1 : Math.floor(selectedAttemptIndex / LIMITS.attempts) + 1; const page = Math.max(state.pages[attemptPageKey] || 1, selectedAttemptPage); const shown = attempts.slice(0, page * LIMITS.attempts);
    if (incompleteAttemptLineage(unit)) lineage.append(text("p", "Earlier attempt lineage is unavailable. Only provable retained attempts are shown; the total is unknown.", "limitation"));
    if (!shown.length && !incompleteAttemptLineage(unit)) lineage.append(empty("This engine-only unit has no Subagent attempts."));
    shown.forEach(function (attempt) { lineage.append(attemptCard(run, unit, attempt, route.attemptId === attempt.attempt_id)); });
    if (shown.length < attempts.length) lineage.append(key(button("Show next 20 attempts", function () { state.pages[attemptPageKey] = page + 1; renderCurrentGuarded(); }, "continuation"), "continuation:" + attemptPageKey)); root.append(lineage);
    root.append(usagePanel(unit.usage, "usage:unit:" + unit.logical_id)); root.append(artifactPanel(unit.artifacts)); root.append(mutationPanel(unit.mutation)); root.append(actionsPanel(unit.safe_actions, "logical unit", unit.logical_id + (projectedAttemptId ? " · attempt " + projectedAttemptId : ""))); root.append(limitationsPanel(unit.limitations)); root.append(evidenceDrawer(run, unit.evidence_refs, "unit-evidence:" + unit.logical_id));
    replaceContent(root, "Unit inspector updated. " + attempts.length + (incompleteAttemptLineage(unit) ? " retained attempts; total unknown." : " attempts."));
    if (state.pendingAttemptScroll && state.pendingAttemptScroll === route.attemptId) {
      const pending = state.pendingAttemptScroll; state.pendingAttemptScroll = null;
      requestAnimationFrame(function () {
        const target = Array.from(document.querySelectorAll("[data-attempt-id]")).find(function (candidate) { return candidate.dataset.attemptId === pending; });
        if (target) target.scrollIntoView({behavior: "smooth", block: "nearest"});
      });
    }
    setStatus("Read-only · unit inspector · ordinal attempts are displayed one-based");
  }
  function renderWorkspaceOverview() {
    // A SUCCESSFUL overview paint owns the replayable record, and it must own it
    // regardless of who called. renderCurrent clears the record before
    // dispatching, but it is NOT the only caller: refresh's workspace-set
    // overview leg and refetchWorkspaceList's finally both call this renderer
    // DIRECTLY, and both are on the hot path for an SSE invalidation and for the
    // per-source Retry control. When an earlier paint of this same route had
    // failed — renderWorkspaceOverview throwing under a hostile row, caught by
    // renderCurrentGuarded/refreshSingleFlight into renderUnavailable, which
    // records — the record stayed armed underneath the healthy overview those
    // direct callers then painted. The next manual-only delta took the replay
    // leg and put the stale failure view back over a Workspace Overview that had
    // just succeeded: the operator pressed `?` and the working page they were
    // reading became "Snapshot loaded but could not be displayed."
    //
    // Cleared at the MOUNT SEAM rather than in each caller, for the same reason
    // the record is WRITTEN at the mount seams: a rule enforced where the view is
    // actually mounted cannot be missed by a caller that did not know it existed.
    // It is cleared FIRST so a throw below leaves the failure renderer's OWN
    // record standing, exactly as renderCurrent's clear does.
    state.lastPaint = null;
    const root = el("div", "view workspace-overview");
    root.append(heading(1, "Workspace Overview"));
    root.append(text("p", "Explicitly configured local sources, in declaration order. Counts are observed per source; no set-level total is calculated.", "lede"));
    shellConfig.workspaces.forEach(function (workspace) {
      const held = workspaceSnapshots[workspace] || {};
      const section = el("section", "workspace-source");
      section.dataset.workspace = workspace;
      section.append(untrustedText("h2", workspace));
      const condition = el("div", "source-condition");
      condition.append(text("h3", "Source condition"));
      if (held.listError) {
        const degradation = el("div", "source-degradation");
        const notices = el("div", "source-degradation-notices");
        notices.append(untrustedText("p", "Source unreachable · " + held.listError.kind, "source-error"));
        if (held.list) notices.append(untrustedText("p", "Stale snapshot held · received " + (displayInstant(held.listObservedAt) || scalar(held.listObservedAt, "unknown")) + " · refresh failure " + held.listError.kind, "stale-disclosure"));
        else notices.append(text("p", "Unavailable. No observed count is held; retry the authoritative source.", "source-error"));
        degradation.append(notices);
        degradation.append(key(button("Retry this source", function () { refetchWorkspaceList(workspace, "source retry"); }, "source-retry"), "source-retry:" + workspace));
        condition.append(degradation);
      }
      if (held.list) {
        const envelope = held.list;
        const inventory = envelope.snapshot && envelope.snapshot.inventory || {};
        const provenance = envelope.source && envelope.source.sessions_directory;
        const receiptLabel = held.listError ? "last-observed " : "observed-at ";
        const receiptBoundary = receiptLabel + (displayInstant(held.listObservedAt) || scalar(held.listObservedAt, "unknown"));
        const absent = provenance === "absent";
        if (absent) {
          condition.classList.add("source-absent");
          condition.append(text("p", "No sessions directory observed (provenance: absent)", "source-absent-note"));
        } else {
          condition.append(untrustedText("p", "Authoritative scoped snapshot · " + receiptBoundary, "provenance"));
          const stats = el("p", "source-stats");
          const observedStat = el("span", "source-stat");
          observedStat.append(text("span", "Observed Session Logs: "));
          observedStat.append(untrustedText("strong", scalar(inventory.total, "unknown"), "source-stat-value"));
          stats.append(observedStat);
          stats.append(text("span", " · ", "source-stat-separator"));
          const selectedStat = el("span", "source-stat");
          selectedStat.append(text("span", "selected "));
          selectedStat.append(untrustedText("strong", scalar(inventory.selected, "unknown"), "source-stat-value"));
          stats.append(selectedStat);
          stats.append(text("span", " · ", "source-stat-separator"));
          const truncatedStat = el("span", "source-stat");
          truncatedStat.append(text("span", "truncated "));
          truncatedStat.append(untrustedText("strong", scalar(inventory.truncated, "unknown"), "source-stat-value"));
          stats.append(truncatedStat);
          stats.append(untrustedText("span", " · " + receiptBoundary, "source-stat-receipt"));
          condition.append(stats);
        }
        const evidence = setDisclosureKey(el("details", "source-evidence"), "source-evidence:" + workspace);
        evidence.append(key(text("summary", "Evidence details"), "source-evidence:" + workspace));
        evidence.append(untrustedText("p", "Sessions directory provenance: " + provenance + " · " + receiptBoundary));
        evidence.append(untrustedText("p", "Inventory bases: projected_runs " + scalar(inventory.projected_runs, "unknown") + " · non_parent_logs " + scalar(inventory.non_parent_logs, "unknown") + " · dropped_logs " + scalar(inventory.dropped_logs, "unknown") + " · " + receiptBoundary));
        const limitations = array(inventory.limitations);
        if (limitations.length === 1) {
          condition.append(untrustedText("p", "Observed count limited: " + scalar(limitations[0].kind, "unknown_limitation") + " · " + receiptBoundary, "limitation"));
        } else if (limitations.length > 1) {
          condition.append(untrustedText("p", "Observed count limited: " + limitations.map(function (limitation) { return scalar(limitation.kind, "unknown_limitation"); }).join(" · ") + " · " + receiptBoundary, "limitation"));
        }
        limitations.forEach(function (limitation) {
          const details = limitation && limitation.details && typeof limitation.details === "object" && !Array.isArray(limitation.details) ? limitation.details : {};
          const detailKeys = Object.keys(details).filter(function (name) { return name !== "error_kinds" && name !== "dropped"; }).sort();
          if (detailKeys.length) evidence.append(untrustedText("p", "Limitation details: " + detailKeys.map(function (name) { return name + " " + scalar(details[name], "unknown"); }).join(" · ") + " · " + receiptBoundary));
          const errorKinds = details.error_kinds && typeof details.error_kinds === "object" && !Array.isArray(details.error_kinds) ? details.error_kinds : {};
          const errorKindKeys = Object.keys(errorKinds).sort();
          if (errorKindKeys.length) evidence.append(untrustedText("p", "Error kinds: " + errorKindKeys.map(function (kind) { return kind + " " + scalar(errorKinds[kind], "unknown"); }).join(" · ") + " · " + receiptBoundary));
          const droppedRows = appendDroppedLogRows(details.dropped);
          if (droppedRows) evidence.append(droppedRows);
        });
        condition.append(evidence);
      }
      section.append(condition);
      const attention = el("div", "source-attention");
      attention.append(text("h3", "Parent-observed attention"));
      const rows = held.list && held.list.snapshot ? listRows(held.list.snapshot) : [];
      const attentionRows = rows.filter(function (row) { return row.attention && row.attention.required === true; });
      if (held.list) {
        if (!attentionRows.length) attention.append(empty("No parent-observed attention in the held snapshot."));
        attentionRows.forEach(function (row) { const id = row.id || row.run && row.run.id; attention.append(projectedLink(remainingRunLabel(row), routeHash({workspace: workspace, runId: id, filters: {}, sort: DEFAULT_SORT}), "workspace-attention:" + workspace + ":" + id)); });
      } else attention.append(text("p", "Attention and remaining runs are unavailable because no source snapshot is held.", "empty-state source-regions-unavailable"));
      section.append(attention);
      const rest = el("div", "source-runs");
      rest.append(text("h3", "Remaining observed runs"));
      if (held.list) {
        const remainingRows = rows.filter(function (row) { return !(row.attention && row.attention.required === true); });
        if (!remainingRows.length) rest.append(empty("No remaining observed runs in the held snapshot."));
        else {
          const remaining = setDisclosureKey(el("details", "remaining-runs-disclosure"), "remaining-runs:" + workspace);
          remaining.append(key(text("summary", "View all remaining runs"), "remaining-runs:" + workspace));
          const remainingList = el("div", "remaining-runs-list");
          remainingRows.forEach(function (row) { const id = row.id || row.run && row.run.id; remainingList.append(projectedLink(remainingRunLabel(row), routeHash({workspace: workspace, runId: id, filters: {}, sort: DEFAULT_SORT}), "workspace-run:" + workspace + ":" + id)); });
          remaining.append(remainingList);
          rest.append(remaining);
        }
      }
      section.append(rest);
      root.append(section);
    });
    replaceContent(root, "Workspace Overview updated. " + shellConfig.workspaces.length + " source sections remain in declaration order.");
    setStatus("Read-only Workspace Overview · per-source authority and freshness");
  }

  /**
   * Receipt time of the currently held authoritative snapshot, or null when
   * nothing has been confirmed yet. Used so a structured run_not_found can
   * confess that the snapshot IS held instead of claiming it is unavailable.
   * @param {Object} route Parsed route.
   * @returns {string|null}
   */
  function heldSnapshotReceipt(route) {
    if (workspaceSetMode()) {
      const scoped = route && route.workspace ? workspaceSnapshots[route.workspace] : null;
      if (scoped && scoped.list && scoped.listObservedAt) return displayInstant(scoped.listObservedAt) || scalar(scoped.listObservedAt, "unknown");
      return null;
    }
    if (state.lastAuthoritativeRefetchAt) return state.lastAuthoritativeRefetchAt.toISOString().replace(/\.\d{3}Z$/, "Z");
    return null;
  }
  function snapshotIsHeld(route) {
    if (workspaceSetMode()) {
      const scoped = route && route.workspace ? workspaceSnapshots[route.workspace] : null;
      return Boolean(scoped && scoped.list);
    }
    return Boolean(state.lastAuthoritativeRefetchAt) || state.list !== null;
  }
  function identityLossFailure(failure, route) {
    return Boolean(route.runId && failure && failure.phase === "fetch" && failure.status === 404 && failure.structured === true && failure.kind === "run_not_found");
  }
  /**
   * Already-known dropped-parent evidence from a structured run_not_found, or
   * from fetching the oversized parent itself (kind run_log_limit). Never
   * invents a parent id the response did not name.
   * @param {Object|undefined} failure Classified projection failure.
   * @param {Object} route Parsed route.
   * @returns {{parentId: string, reason: string}|null}
   */
  function droppedParentEvidence(failure, route) {
    if (failure && failure.kind === "run_log_limit" && route.runId) return {parentId: route.runId, reason: "run_log_limit"};
    const details = failure && failure.details && typeof failure.details === "object" && !Array.isArray(failure.details) ? failure.details : null;
    if (!details) return null;
    const reason = diagnosticToken(details.parent_unprojected_reason, "");
    const parentId = typeof details.parent_session_id === "string" ? details.parent_session_id : "";
    if (reason === "run_log_limit" && parentId) return {parentId: parentId, reason: reason};
    return null;
  }
  function runsReturnLink(route) {
    return link("Return to Runs", routeHash({workspace: route && route.workspace, view: "runs"}), "return-runs");
  }
  function renderUnavailable(message, failure) {
    // The other mount seam for a failure view. Recorded before the branches
    // because several of them return early, and the replay must reproduce
    // whichever one this call actually paints — including the identity-mismatch
    // bail-outs renderDetail and renderUnit reach without any failure object.
    state.lastPaint = function () { renderUnavailable(message, failure); };
    const route = parseRoute(location.hash);
    const root = el("div", "view error-view");
    if (failure) applyFailureDiagnostic(root, failure);
    const identityLoss = identityLossFailure(failure, route);
    const resolution = identityLoss ? parentResolutionPanel(route, {headline: true}) : parentResolutionPanel(route);
    const dropped = droppedParentEvidence(failure, route);
    const held = snapshotIsHeld(route);
    const asOf = heldSnapshotReceipt(route) || "receipt time not yet recorded";
    if (identityLoss && resolution) {
      root.className = "view error-view resolved-child-view";
      root.dataset.unavailableClass = "resolved_child";
      root.append(resolution);
      root.append(runsReturnLink(route));
      replaceContent(root, "Parent-observed child Session. The requested id is not a projectable run.");
      setStatus((held ? "Held snapshot · requested id is a parent-observed child · as of " + asOf : "Requested id is a parent-observed child · list receipt is not yet held") + resolutionStatusSuffix(route));
      return;
    }
    if ((identityLoss || (failure && failure.kind === "run_log_limit")) && dropped) {
      root.className = "view error-view dropped-parent-view";
      root.dataset.unavailableClass = "dropped_parent";
      root.append(heading(1, "Parent not projected"));
      appendDroppedParentCopy(root, route, dropped);
      root.append(text("p", held ? "The authoritative snapshot is held (as of " + asOf + "). This is not a fetch outage; waiting will not project the cap-dropped parent." : "The parent is not projected. This is not a fetch outage; the list receipt is not yet held. Waiting will not project the cap-dropped parent.", "provenance"));
      root.append(runsReturnLink(route));
      replaceContent(root, "Parent Session was not projected because of run_log_limit.");
      setStatus(held ? "Held snapshot · parent unprojected · run_log_limit · as of " + asOf : "Parent unprojected · run_log_limit · list receipt is not yet held");
      return;
    }
    if (identityLoss) {
      root.className = "view error-view not-found-view";
      root.dataset.unavailableClass = "not_found";
      root.append(heading(1, "Run not found"));
      root.append(untrustedText("p", held ? "The requested id " + scalar(route.runId, "unknown") + " matched no projected run in the held snapshot." : "The requested id " + scalar(route.runId, "unknown") + " matched no projected run.", "empty-state"));
      root.append(text("p", held ? "The authoritative snapshot is held (as of " + asOf + "). This id is absent from it; nothing will converge." : "No projected run matched this id.", "provenance"));
      root.append(runsReturnLink(route));
      replaceContent(root, held ? "Run not found in the held snapshot." : "The requested id is not a projected run.");
      setStatus((held ? "Held snapshot · requested id not found · as of " + asOf : "Requested id not found in the snapshot.") + resolutionStatusSuffix(route));
      return;
    }
    root.dataset.unavailableClass = "projection_unavailable";
    root.append(heading(1, "Projection unavailable"));
    root.append(text("p", message, "empty-state"));
    root.append(runsReturnLink(route));
    if (resolution) root.append(resolution);
    replaceContent(root, message);
    setStatus((failure ? projectionFailureStatus(failure) : "Requested projection unavailable; return to Runs or relaunch.") + resolutionStatusSuffix(route));
  }
  function renderCurrent() {
    const route = parseRoute(location.hash);
    // A projection-derived paint supersedes any recorded failure paint. Cleared
    // BEFORE the render so that a renderer which itself paints a failure view
    // (renderDetail bailing to renderFollowIdentityConflict, renderUnavailable
    // for an invalid route) leaves its OWN paint recorded, not a stale one.
    state.lastPaint = null;
    if (route.view === "workspaces") renderWorkspaceOverview();
    else if (route.view === "runs") renderRuns();
    else if (route.view === "unit") renderUnit();
    else if (route.view === "invalid") renderUnavailable("The requested route is invalid or could not be decoded.");
    else renderDetail();
  }
  function renderProjectionFailure(error) {
    const route = parseRoute(location.hash);
    const failure = normalizeProjectionFailure(error);
    // The replayable paint is NOT recorded here. Every branch below terminates
    // in renderFollowErrorView or renderUnavailable, and both record it
    // themselves — which is also what covers the conflict views that reach those
    // renderers straight from renderDetail/renderUnit and never pass through
    // here at all.
    const message = projectionFailureMessage(failure);
    const authorityUnavailable = route.runId && (failure.phase === "fetch" || failure.phase === "decode");
    const identityLoss = route.runId && failure.phase === "fetch" && failure.status === 404 && failure.structured === true && failure.kind === "run_not_found";
    const identityConflict = route.follow === true && route.runId && state.detailConflict === true && state.detail && state.detail.run && state.detail.run.id !== route.runId;
    if (authorityUnavailable) {
      state.detail = null;
      state.detailConflict = false;
    }
    if (identityLoss) state.detailId = null;
    // Only a structured run_not_found for the ROUTED id licenses offering a
    // resolved parent; every other failure clears the licence so no other state
    // can inherit the affordance (#438).
    const nextResolutionFor = identityLoss ? route.runId : null;
    // The one-shot acquisition budget belongs to the resolved-for id. Moving to
    // a different id (or off the affordance entirely) returns the budget; a
    // repaint of the SAME dead end does not, which is what bounds the cycle.
    if (state.resolutionAttemptedFor !== null && state.resolutionAttemptedFor !== nextResolutionFor) state.resolutionAttemptedFor = null;
    state.resolutionFor = nextResolutionFor;
    state.resolutionFailure = identityLoss ? failure : null;
    if (identityLoss && !heldInventoryRows(route).length) acquireInventoryForResolution(route);
    if (identityLoss && route.follow === true) renderFollowDegraded(route, "The followed run is not projected in the authoritative snapshot.", failure);
    else if (identityConflict && failure.phase === "render") {
      try { renderFollowIdentityConflict(route, "The authoritative snapshot returned a different run identity than the one being followed.", failure); }
      finally { state.detail = null; state.detailConflict = false; }
    }
    else if (route.follow === true && route.runId && failure.phase === "render" && state.detailId === route.runId && (!workspaceSetMode() || state.detailWorkspace === route.workspace)) {
      try { renderFollowRenderFailure(route, message, failure); }
      finally { state.detail = null; state.detailConflict = false; }
    }
    else if (route.follow === true && route.runId) renderFollowSnapshotUnavailable(route, message, failure);
    else if (failure.phase === "render") {
      try { renderUnavailable(message, failure); }
      finally { state.detail = null; state.detailConflict = false; }
    }
    else renderUnavailable(message, failure);
  }
  /**
   * Paints a MONITOR AUTHORING DEFECT as what it is.
   *
   * This view exists so the refusal in `labelledTermSlug` (and any future
   * Monitor-side invariant that refuses at render time) stays LOUD without
   * being LAUNDERED. Three properties are load-bearing and each is pinned:
   *
   *   1. It NAMES THE MONITOR. "The Monitor could not render this view because
   *      of a defect in the Monitor itself." No sentence here says or implies
   *      that anything is wrong with the Log, the snapshot, or the run.
   *   2. It SHOWS THE DIAGNOSTIC VERBATIM. The authored message identifies the
   *      exact label and slug at fault, which is the whole value of the throw;
   *      the previous path discarded it entirely.
   *   3. It TOUCHES NO PROJECTION STATE. `renderProjectionFailure` clears
   *      `state.detail`, drops `state.detailId`, moves the child-resolution
   *      licence, and can route into the follow-degradation views — all of
   *      which would let an authoring typo masquerade as a run-identity or
   *      follow problem. A defect is not evidence about a run, so it changes
   *      nothing about what the Monitor believes it holds.
   *
   * The diagnostic is authored by this file, so it goes through `text`, not
   * `untrustedText`: it is not transported agent output and must not be dressed
   * as any.
   * @param {Error} defect A MonitorDefect.
   * @returns {void}
   */
  function renderMonitorDefect(defect) {
    state.lastPaint = function () { renderMonitorDefect(defect); };
    const route = parseRoute(location.hash);
    const root = el("div", "view error-view monitor-defect-view");
    root.dataset.errorPhase = "monitor";
    root.dataset.errorKind = defect.kind;
    root.dataset.unavailableClass = "monitor_defect";
    root.append(heading(1, "Monitor defect"));
    root.append(text("p", "The Monitor could not render this view because of a defect in the Monitor itself. This is not a fact about the Log, the snapshot, or the run: the projection was not accused and nothing about it was discarded.", "empty-state"));
    root.append(text("p", defect.detail, "monitor-defect-diagnostic"));
    // `empty-state`, not `.provenance`: that class is monospace and is reserved
    // for basis lines about transported evidence. The Monitor talking about its
    // own build is not evidence and must not be dressed as any.
    root.append(text("p", "Report this with the line above. Reloading will not clear it; the defect is in the shipped build.", "empty-state"));
    root.append(runsReturnLink(route));
    replaceContent(root, "Monitor defect. The Monitor could not render this view because of a defect in the Monitor itself.");
    setStatus("Monitor defect · " + defect.kind + " · the projection was not accused.");
  }
  function renderMonitorDefectSafely(defect) {
    try { renderMonitorDefect(defect); }
    catch (_renderError) {
      try {
        app.dataset.errorPhase = "monitor";
        app.dataset.errorKind = "monitor_defect_renderer_failed";
        app.textContent = "Monitor defect. The Monitor could not render this view because of a defect in the Monitor itself. " + String(defect && defect.detail || "");
        status.textContent = "Monitor defect · the projection was not accused.";
      } catch (_fallbackError) {}
    }
  }
  /**
   * The single classification seam every render catch site shares: a Monitor
   * defect is never allowed to enter the projection-failure path, because that
   * path both rewrites the message into an accusation against upstream evidence
   * and mutates projection state on the way.
   * @param {*} error Whatever a renderer threw.
   * @returns {void}
   */
  function renderRenderErrorSafely(error) {
    if (isMonitorDefect(error)) return renderMonitorDefectSafely(error);
    renderProjectionFailureSafely(error);
  }
  function renderProjectionFailureSafely(error) {
    try { renderProjectionFailure(error); }
    catch (_renderError) {
      try {
        const primaryFailure = normalizeProjectionFailure(error);
        app.dataset.errorPhase = primaryFailure.phase;
        app.dataset.errorKind = "projection_failure_renderer_failed";
        app.textContent = "Projection unavailable. " + projectionFailureMessage(primaryFailure);
        status.textContent = projectionFailureStatus(primaryFailure);
      } catch (_fallbackError) {}
    }
  }
  function renderCurrentGuarded() {
    try { renderCurrent(); }
    catch (error) { renderRenderErrorSafely(error); }
  }
  /**
   * Repaints the recorded failure view. The thunk re-enters the same renderer,
   * which re-records itself, so a further overlay move replays the same view
   * again. A throw is routed through the ordinary failure path rather than
   * left to blank the app, and the stale record is dropped first so the
   * recovery paint owns the record.
   */
  function replayLastPaint() {
    const paint = state.lastPaint;
    state.lastPaint = null;
    try { paint(); }
    catch (error) { renderRenderErrorSafely(error); }
  }

  /**
   * encodeURIComponent throws URIError on a lone UTF-16 surrogate. A run id
   * that cannot be encoded cannot become a row or an href: the Monitor
   * confesses and declines rather than rewriting the id or crashing refresh.
   * @param {*} value Candidate path or query component.
   * @returns {string|null} Encoded component, or null when the encoder rejects it.
   */
  function encodableComponent(value) {
    try { return encodeURIComponent(value); }
    catch (_error) { return null; }
  }
  /**
   * A list row the Presenter can turn into a row: object shape, non-empty
   * string id, and an id the URL encoder accepts. An unlinkable id is an
   * invalid row — the same confession class as unprojected selected Logs.
   * @param {*} row Candidate list row.
   * @returns {boolean}
   */
  function validListRow(row) {
    return row && typeof row === "object" && !Array.isArray(row) && typeof row.id === "string" && row.id.length > 0 && encodableComponent(row.id) !== null;
  }
  /**
   * Rejects unlinkable rows at the list envelope and counts them as
   * unprojected selected Logs so scanned/projected/excluded still reconciles.
   * Never sanitizes the id; the count is the honesty.
   * @param {*} snapshot List snapshot or single-workspace /api/runs payload.
   * @returns {*} Snapshot with only linkable rows, or the original value.
   */
  function confessUnlinkableListRows(snapshot) {
    if (!snapshot || typeof snapshot !== "object" || Array.isArray(snapshot) || !Array.isArray(snapshot.runs)) return snapshot;
    const valid = [];
    let invalid = 0;
    snapshot.runs.forEach(function (row) {
      if (validListRow(row)) valid.push(row);
      else if (row && typeof row === "object" && !Array.isArray(row) && typeof row.id === "string" && row.id.length > 0) invalid += 1;
    });
    if (invalid === 0) return snapshot;
    const inventory = snapshot.inventory && typeof snapshot.inventory === "object" && !Array.isArray(snapshot.inventory) ? Object.assign({}, snapshot.inventory) : Object.create(null);
    if (Number.isSafeInteger(inventory.projected_runs)) inventory.projected_runs = Math.max(0, inventory.projected_runs - invalid);
    inventory.dropped_logs = (Number.isSafeInteger(inventory.dropped_logs) ? inventory.dropped_logs : 0) + invalid;
    return Object.assign({}, snapshot, {runs: valid, inventory: inventory});
  }
  /**
   * Workspace-set list envelopes carry the snapshot one level down. Classify
   * there so overview, per-source list, and inventory bases share one count.
   * @param {*} envelope Validated scoped list envelope.
   * @returns {*} Envelope whose snapshot has confessed unlinkable rows.
   */
  function confessUnlinkableListEnvelope(envelope) {
    if (!envelope || !envelope.snapshot) return envelope;
    const snapshot = confessUnlinkableListRows(envelope.snapshot);
    if (snapshot === envelope.snapshot) return envelope;
    return Object.assign({}, envelope, {snapshot: snapshot});
  }
  function exactObjectKeys(value, required, allowed) {
    if (!value || typeof value !== "object" || Array.isArray(value)) return false;
    const keys = Object.keys(value);
    return required.every(function (name) { return Object.prototype.hasOwnProperty.call(value, name); }) && keys.every(function (name) { return allowed.includes(name); });
  }
  function validScopedEnvelope(envelope, workspace, scope) {
    const envelopeKeys = ["snapshot", "source", "workspace"];
    if (!exactObjectKeys(envelope, envelopeKeys, envelopeKeys) || envelope.workspace !== workspace) return false;
    if (!exactObjectKeys(envelope.source, ["sessions_directory"], ["sessions_directory"]) || !["observed", "absent"].includes(envelope.source.sessions_directory)) return false;
    const snapshot = envelope.snapshot;
    if (scope === "list") {
      const snapshotKeys = ["inventory", "runs", "schema", "schema_version"];
      // Shape only: a non-empty string id still admits the envelope. An id the
      // URL encoder rejects is classified afterwards as an invalid row (see
      // confessUnlinkableListEnvelope) so the rest of the list can paint.
      if (!exactObjectKeys(snapshot, snapshotKeys, snapshotKeys) || snapshot.schema !== "pixir.monitor.runs" || snapshot.schema_version !== 1 || !Array.isArray(snapshot.runs) || !snapshot.runs.every(function (row) { return row && typeof row === "object" && !Array.isArray(row) && typeof row.id === "string" && row.id.length > 0; })) return false;
      const inventoryRequired = ["limitations", "selected", "total", "truncated"];
      const inventoryAllowed = inventoryRequired.concat(["dropped_logs", "non_parent_logs", "projected_runs"]);
      const inventory = snapshot.inventory;
      if (!exactObjectKeys(inventory, inventoryRequired, inventoryAllowed) || !Number.isSafeInteger(inventory.total) || inventory.total < 0 || !Number.isSafeInteger(inventory.selected) || inventory.selected < 0 || typeof inventory.truncated !== "boolean" || !Array.isArray(inventory.limitations) || !inventory.limitations.every(function (item) { return item && typeof item === "object" && !Array.isArray(item); })) return false;
      return ["dropped_logs", "non_parent_logs", "projected_runs"].every(function (name) { return inventory[name] === undefined || Number.isSafeInteger(inventory[name]) && inventory[name] >= 0; });
    }
    const detailKeys = ["counts", "evidence", "execution", "graph", "limitations", "liveness", "mutation", "post_terminal_child_activity", "projected_at", "projection_id", "run", "safe_actions", "schema", "schema_version", "source", "units", "usage"];
    if (!exactObjectKeys(snapshot, detailKeys, detailKeys) || snapshot.schema !== "pixir.presenter.run" || snapshot.schema_version !== 1) return false;
    return typeof snapshot.projection_id === "string" && snapshot.projection_id.length > 0 && typeof snapshot.projected_at === "string" && snapshot.run && typeof snapshot.run === "object" && !Array.isArray(snapshot.run) && typeof snapshot.run.id === "string" && snapshot.run.id.length > 0 && Array.isArray(snapshot.units) && Array.isArray(snapshot.safe_actions) && Array.isArray(snapshot.evidence) && Array.isArray(snapshot.limitations);
  }
  function validateScopedEnvelope(envelope, workspace, scope) {
    if (!validScopedEnvelope(envelope, workspace, scope)) throw projectionFailure("decode", "scoped_envelope_invalid", 200);
    return envelope;
  }

  async function fetchJSON(path, expectedGeneration) {
    try {
      let response;
      try {
        response = await fetch(path, {method: "GET", credentials: "same-origin", cache: "no-store", headers: {accept: "application/json"}});
      } catch (_error) {
        throw projectionFailure("fetch", "projection_request_failed");
      }
      if (!response.ok) {
        let value = null;
        try { value = await response.json(); } catch (_error) {}
        const serverKind = diagnosticToken(value && value.error && value.error.kind, "projection_http_failed");
        const failure = projectionFailure("fetch", serverKind, response.status);
        failure.structured = Boolean(value && value.error && typeof value.error === "object" && !Array.isArray(value.error));
        const details = value && value.error && value.error.details;
        failure.details = details && typeof details === "object" && !Array.isArray(details) ? details : null;
        throw failure;
      }
      let value;
      try {
        value = await response.json();
      } catch (_error) {
        throw projectionFailure("decode", "projection_response_invalid", response.status);
      }
      if (value === null) throw projectionFailure("decode", "projection_response_invalid", response.status);
      if (expectedGeneration !== null && expectedGeneration !== state.generation) return SUPERSEDED;
      return value;
    } catch (error) {
      if (expectedGeneration !== null && expectedGeneration !== state.generation) return SUPERSEDED;
      throw error;
    }
  }
  async function refresh(reason) {
    state.restore = captureView();
    const current = ++state.generation;
    const route = parseRoute(location.hash);
    state.routeRunId = route.runId || null;
    state.routeWorkspace = route.workspace || null;

    if (workspaceSetMode()) {
      if (route.view === "invalid") {
        renderCurrent();
        return;
      }
      if (route.view === "workspaces") {
        await Promise.all(shellConfig.workspaces.map(function (workspace) { return refetchWorkspaceList(workspace, null); }));
        if (current === state.generation) renderWorkspaceOverview();
        return;
      }

      const workspace = route.workspace;
      if (route.view === "runs") {
        await refetchWorkspaceList(workspace, null);
        return;
      }
      try {
        const suffix = "/" + encodeURIComponent(route.runId);
        const fetchedEnvelope = await fetchJSON("/api/workspaces/" + encodeURIComponent(workspace) + "/runs" + suffix, current);
        if (fetchedEnvelope === SUPERSEDED || current !== state.generation) return;
        const envelope = validateScopedEnvelope(fetchedEnvelope, workspace, "detail");
        const receivedAt = new Date().toISOString();
        const snapshot = envelope && envelope.snapshot;
        const detailIdentityConfirmed = Boolean(envelope && envelope.workspace === workspace && snapshot && snapshot.run && snapshot.run.id === route.runId);
        state.detailConflict = !detailIdentityConfirmed;
        state.detail = snapshot || null;
        state.detailId = detailIdentityConfirmed ? route.runId : null;
        state.detailWorkspace = detailIdentityConfirmed ? workspace : null;
        if (detailIdentityConfirmed) {
          workspaceSnapshots[workspace] = Object.assign({}, workspaceSnapshots[workspace] || {}, {detail: snapshot, detailId: route.runId, detailObservedAt: receivedAt, detailError: null});
          state.lastAuthoritativeRefetchAt = new Date();
        }
        let rendered = false;
        try {
          renderCurrent();
          rendered = true;
        } finally {
          if (rendered && route.view !== "runs" && state.detailConflict) { state.detail = null; state.detailWorkspace = null; state.detailConflict = false; }
        }
      } catch (error) {
        if (current !== state.generation) return;
        // A Monitor authoring defect is NOT a fetch or decode fact about this
        // workspace. Recording it as a `detailError` would stamp a stale-source
        // disclosure onto a snapshot that arrived intact, so the operator would
        // read "refresh failure <kind>" over evidence nothing is wrong with.
        // It leaves the held snapshot untouched and paints as itself.
        if (isMonitorDefect(error)) return renderMonitorDefectSafely(error);
        const failure = normalizeProjectionFailure(error);
        const failureState = {detailError: {kind: failure.kind}};
        workspaceSnapshots[workspace] = Object.assign({}, workspaceSnapshots[workspace] || {}, failureState);
        const currentSnapshot = workspaceSnapshots[workspace] || {};
        if (currentSnapshot.detail && currentSnapshot.detailId === route.runId) { state.detail = currentSnapshot.detail; state.detailId = currentSnapshot.detailId; state.detailWorkspace = workspace; state.detailConflict = false; renderCurrent(); }
        else renderProjectionFailureSafely(failure);
      }
      return;
    }

    let payload = null;
    let detailIdentityConfirmed = true;
    if (route.view === "invalid") {
      renderCurrent();
      return;
    } else if (route.view === "runs") {
      state.detail = null; state.detailId = null; state.detailConflict = false;
      payload = await fetchJSON("/api/runs", current); if (payload === SUPERSEDED || current !== state.generation) return; state.list = confessUnlinkableListRows(payload); state.detail = null; state.detailId = null; state.detailConflict = false;
    } else {
      payload = await fetchJSON("/api/runs/" + encodeURIComponent(route.runId), current); if (payload === SUPERSEDED || current !== state.generation) return; detailIdentityConfirmed = Boolean(payload && payload.run && payload.run.id === route.runId); state.detailConflict = !detailIdentityConfirmed; state.detail = payload; state.detailId = detailIdentityConfirmed ? route.runId : null;
    }
    const identityConfirmed = route.view === "runs" || (payload && payload.run && payload.run.id === route.runId);
    if (identityConfirmed) state.lastAuthoritativeRefetchAt = new Date();
    let rendered = false;
    try {
      renderCurrent();
      rendered = true;
    } finally {
      if (rendered && route.view !== "runs" && !detailIdentityConfirmed) { state.detail = null; state.detailConflict = false; }
    }
    setStatus(status.textContent);
    if (reason && !app.querySelector(".error-view[data-follow-state]")) announce("Projection refetched after " + reason + ".");
  }
  /**
   * Coalesces authoritative refetches into a single in-flight request. A reason
   * arriving mid-flight is remembered and replayed once, so bursts of
   * invalidations, navigations, and retries collapse without dropping the last
   * cause. Browser state is disposable; the refetch is always authoritative.
   * @param {string} reason Cause announced to assistive tech after the refetch.
   * @returns {Promise} The shared in-flight request.
   */
  function refreshSingleFlight(reason) {
    state.refreshPendingReason = reason;
    if (state.refreshInFlight) return state.refreshInFlight;
    const currentReason = state.refreshPendingReason;
    state.refreshPendingReason = null;
    const request = refresh(currentReason).catch(renderRenderErrorSafely).finally(function () {
      if (state.refreshInFlight === request) state.refreshInFlight = null;
      if (state.refreshPendingReason !== null) refreshSingleFlight(state.refreshPendingReason);
    });
    state.refreshInFlight = request;
    return request;
  }
  /**
   * Validates one stream event against the bounded invalidation contract: a
   * non-negative integer sequence id and a body of exactly
   * {type: "projection_changed", projection_id}. Invalidations are metadata
   * hints only — they never carry snapshots and never mutate view state; any
   * anomaly still resolves to an authoritative refetch.
   * @param {MessageEvent} event Server-sent invalidation event.
   * @returns {{valid: boolean, sequence: (number|null)}}
   */
  function validInvalidation(event) {
    if (!/^[0-9]+$/.test(event.lastEventId || "")) return {valid: false, sequence: null};
    const sequence = Number(event.lastEventId); if (!Number.isSafeInteger(sequence) || sequence < 0) return {valid: false, sequence: null};
    try {
      const body = JSON.parse(event.data);
      const expectedKeys = workspaceSetMode() ? "projection_id,type,workspace" : "projection_id,type";
      const workspaceValid = !workspaceSetMode() || (body && typeof body.workspace === "string" && shellConfig.workspaces.includes(body.workspace));
      if (!body || Array.isArray(body) || body.type !== "projection_changed" || typeof body.projection_id !== "string" || !body.projection_id || !workspaceValid || Object.keys(body).sort().join(",") !== expectedKeys) return {valid: false, sequence: sequence, workspace: null};
      return {valid: true, sequence: sequence, workspace: workspaceSetMode() ? body.workspace : null};
    } catch (_error) { return {valid: false, sequence: sequence}; }
  }
  function refetchWorkspaceList(workspace, reason) {
    const requestGeneration = (state.sourceRequestGeneration[workspace] || 0) + 1;
    let latestFailure = null;
    state.sourceRequestGeneration[workspace] = requestGeneration;
    // Workspace snapshot authority is source-scoped, not route-scoped. Passing
    // null keeps global navigation generations from superseding this request;
    // requestGeneration remains the sole commit arbiter for this workspace.
    return fetchJSON("/api/workspaces/" + encodeURIComponent(workspace) + "/runs", null).then(function (fetchedEnvelope) {
      // Per-source latest-result-wins arbitration: stale completions are discarded silently.
      if (fetchedEnvelope === SUPERSEDED || state.sourceRequestGeneration[workspace] !== requestGeneration) return;
      const envelope = confessUnlinkableListEnvelope(validateScopedEnvelope(fetchedEnvelope, workspace, "list"));
      workspaceSnapshots[workspace] = Object.assign({}, workspaceSnapshots[workspace] || {}, {list: envelope, listObservedAt: new Date().toISOString(), listError: null});
      state.lastAuthoritativeRefetchAt = new Date();
    }).catch(function (error) {
      if (state.sourceRequestGeneration[workspace] !== requestGeneration) return;
      const failure = normalizeProjectionFailure(error);
      latestFailure = failure;
      workspaceSnapshots[workspace] = Object.assign({}, workspaceSnapshots[workspace] || {}, {listError: {kind: failure.kind}});
    }).finally(function () {
      if (state.sourceRequestGeneration[workspace] !== requestGeneration) return;
      const route = parseRoute(location.hash);
      if (route.view === "workspaces") renderWorkspaceOverview();
      else if (route.view === "runs" && route.workspace === workspace) {
        const currentSnapshot = workspaceSnapshots[workspace] || {};
        if (currentSnapshot.list) {
          state.list = currentSnapshot.list.snapshot;
          renderCurrentGuarded();
        } else if (currentSnapshot.listError && latestFailure) renderProjectionFailureSafely(latestFailure);
      }
      if (reason) announce("Workspace source refetched after " + reason + ".");
    });
  }
  function handleInvalidation(event) {
    const parsed = validInvalidation(event); let reason = "valid invalidation";
    if (!parsed.valid) reason = "malformed invalidation";
    else if (state.lastEventId !== null && parsed.sequence === state.lastEventId) reason = "duplicate invalidation";
    else if (state.lastEventId !== null && parsed.sequence < state.lastEventId) reason = "reordered invalidation";
    else if (state.lastEventId !== null && parsed.sequence !== state.lastEventId + 1) reason = "invalidation gap";
    const anomaly = reason !== "valid invalidation";
    // Invalid payloads are still refetch triggers, but their numeric ids are
    // not trusted as the cursor for later valid invalidations.
    if (parsed.valid && parsed.sequence !== null) state.lastEventId = state.lastEventId === null ? parsed.sequence : Math.max(state.lastEventId, parsed.sequence);
    if (!workspaceSetMode()) refreshSingleFlight(reason);
    else if (anomaly) {
      const route = parseRoute(location.hash);
      Promise.all(shellConfig.workspaces.map(function (workspace) { return refetchWorkspaceList(workspace, reason); })).then(function () {
        if (route.workspace && route.view !== "workspaces" && route.view !== "runs") refreshSingleFlight(reason + " deep-view revalidation");
      });
    }
    else {
      const route = parseRoute(location.hash);
      const listRefresh = refetchWorkspaceList(parsed.workspace, reason);
      if (route.workspace === parsed.workspace && route.view !== "workspaces" && route.view !== "runs") {
        listRefresh.then(function () { refreshSingleFlight(reason + " detail revalidation"); });
      }
    }
  }
  function connect() {
    const source = new EventSource("/api/events", {withCredentials: true});
    source.addEventListener("projection_changed", handleInvalidation);
    source.onopen = function () { const reconnecting = state.streamState === "down"; if (reconnecting) state.lastEventId = null; state.streamState = "connected"; setStatus(status.textContent); if (reconnecting) refreshSingleFlight("stream reconnect"); };
    source.onerror = function () { const alreadyDown = state.streamState === "down"; state.streamState = "down"; setStatus(status.textContent); if (!alreadyDown) refreshSingleFlight("stream error"); };
  }
  function routeChanged() {
    const route = parseRoute(location.hash);
    // MANUAL-ONLY DELTA: opening, changing, or closing the manual overlay is a
    // pure re-render. Nothing about the underlying view changed, so bumping the
    // generation (which would supersede an in-flight authoritative request),
    // tearing down state.detail, or issuing a refetch would all be wrong — the
    // run whose values the pane sits beside must stay painted. This is the whole
    // reason the manual is an overlay field rather than a fifth view value.
    // The key is VIEW-DISCRIMINATING on purpose, and it stays that way even now
    // that the unavailable route serializes its own path rather than falling
    // through to the runs path. routeHash serializes a PATH, and the fast path
    // must not come to REST on a serialization detail one refactor from
    // collapsing two views onto one path again: were the hash alone the key, a
    // genuine view change carrying a manual delta — `#/%zz` ->
    // `#/runs?manual=index` — would be called "manual-only" and repaint the new
    // view against the PREVIOUS view's state, painting a Runs page from the
    // unavailable view's `state.list === null` that claims zero runs were found,
    // a fabricated negative claim, with no fetch ever issued.
    //
    // The run and workspace identities are checked against the STATE the paint
    // actually rests on, not just against the key: routeHash fills a missing
    // workspace from the current hash or the first configured one, so a route
    // that names no workspace can serialize onto another's path. The fast path
    // may only skip the refetch when the run and workspace already loaded are
    // the ones this route asks for.
    const underlying = underlyingKey(route);
    const sameSubject = state.routeRunId === (route.runId || null) && state.routeWorkspace === (route.workspace || null);
    const manualOnlyDelta = state.manualUnderlyingHash !== null && state.manualUnderlyingHash === underlying && sameSubject && state.manual !== (route.manual || null);
    // Only re-render when there is something painted to re-render AROUND. With
    // an empty app (first load, or an authoritative request still in flight over
    // the honest "awaiting" state) the fast path would repaint an unavailable
    // view, so the ordinary path runs instead — which is exactly what it would
    // have done had the manual field not moved.
    if (manualOnlyDelta && app.firstChild) {
      const wasOpen = state.manual !== null;
      const nowOpen = (route.manual || null) !== null;
      state.manual = route.manual || null;
      state.restore = captureView();
      // FOCUS ACROSS THE OVERLAY MOVE. Generic restore cannot carry it: the
      // hashchange lands BEFORE this capture, so closing the pane from its own
      // Close link records `focus: "manual-close"` — a key whose element the
      // very same re-render destroys, leaving focus on document.body and the
      // next Tab restarting at the top of the document. Both directions
      // therefore get a DELIBERATE target instead.
      if (!wasOpen && nowOpen) {
        // Opening: remember where the operator was so closing can return them,
        // and move focus into the pane heading rather than leaving it parked on
        // a control the pane now covers.
        state.manualReturnFocus = state.restore.focus;
        state.restore.focus = "manual-heading";
      } else if (wasOpen && !nowOpen) {
        // Closing: return to the pre-open control. The stash is legitimately
        // NULL on several reachable orders — a `#manual/<slug>` deep-link boot
        // (the pane was already open at bootstrap, so the open leg never ran),
        // pressing `?` while focus sat on unkeyed ground, and cross-view
        // navigation with the pane open (the ordinary path clears the stash
        // below, because a key stashed against the previous view no longer
        // names anything). In every one of those the focus about to be
        // destroyed is a manual key, so clearing the key is not enough:
        // `focusFallback` is what makes restoreView land the operator on the
        // repainted view's first control instead of leaving them on a detached
        // node and collapsing to document.body.
        state.restore.focus = state.manualReturnFocus;
        state.restore.focusFallback = true;
        state.manualReturnFocus = null;
      }
      // Term-to-term inside the pane keeps generic restore: both `manual-close`
      // and `manual-index` survive that re-render, and a term link that does not
      // is covered by the restoreView fallback.
      // The painted view is REPRODUCED, never re-derived. When a failure put it
      // there, the state its renderers read is already cleared (state.detail is
      // null by design while the failure view stays painted — set so by
      // renderProjectionFailure, and by refresh's own finally block on an
      // identity conflict), so calling renderCurrent() would repaint a DIFFERENT
      // view: a "Follow degraded" or "Follow identity conflict" pane would
      // silently become "Follow snapshot unavailable", changing the asserted
      // Follow state, its provenance and its status line, and replaceContent
      // would drop the failure diagnostic. Replaying the recorded paint keeps
      // the assertion byte-identical.
      if (state.lastPaint !== null) replayLastPaint();
      else renderCurrentGuarded();
      return;
    }
    state.manual = route.manual || null;
    state.manualUnderlyingHash = underlying;
    // The ordinary path repaints a DIFFERENT underlying view, so a focus key
    // stashed against the view the pane opened over no longer names anything.
    // Dropping it keeps the stash meaning "where to return within this view".
    state.manualReturnFocus = null;
    state.generation += 1;
    if (state.refreshInFlight) state.refreshPendingReason = "navigation";
    const savedRestore = history.state && history.state.pixirView ? history.state.pixirView : captureView(state.routeRunId, state.routeWorkspace);
    const nextRouteRunId = route.runId || null;
    const nextRouteWorkspace = route.workspace || null;
    const runChanged = state.routeRunId !== nextRouteRunId || state.routeWorkspace !== nextRouteWorkspace;
    state.routeRunId = nextRouteRunId;
    state.routeWorkspace = nextRouteWorkspace;
    state.restore = savedRestore && savedRestore.runId === nextRouteRunId && (savedRestore.workspace || null) === nextRouteWorkspace ? savedRestore : null;
    const forceRefetch = state.forceRefetch;
    state.forceRefetch = false;
    if (runChanged) {
      state.list = null;
      state.detail = null;
      state.detailId = null;
      state.detailWorkspace = null;
      state.detailConflict = false;
      state.pendingAttemptScroll = null;
      delete app.dataset.errorPhase;
      delete app.dataset.errorKind;
      // The recorded paint dies with the view it described. The emptied app
      // already blocks the manual fast path, but tying the record's lifetime to
      // the paint keeps "lastPaint describes what is on screen" an invariant
      // rather than something the firstChild guard happens to cover.
      state.lastPaint = null;
      app.replaceChildren();
      setStatus("Awaiting authoritative projection…");
    }
    if (route.view === "invalid") renderCurrentGuarded();
    else if (route.view === "workspaces") {
      state.detail = null; state.detailId = null; state.detailConflict = false;
      if (shellConfig.workspaces.every(function (workspace) { return workspaceSnapshots[workspace] && (workspaceSnapshots[workspace].list || workspaceSnapshots[workspace].listError); })) {
        renderCurrentGuarded();
        if (runChanged) refreshSingleFlight("navigation");
      }
      else refreshSingleFlight("navigation");
    }
    else if (route.view === "runs") {
      state.detail = null; state.detailId = null; state.detailConflict = false;
      const routedList = workspaceSetMode() && workspaceSnapshots[route.workspace] && workspaceSnapshots[route.workspace].list;
      if (workspaceSetMode()) state.list = routedList ? routedList.snapshot : null;
      if (forceRefetch) refreshSingleFlight("follow retry");
      else if (state.list) renderCurrentGuarded();
      else refreshSingleFlight("navigation");
    }
    else {
      const matchingDetail = route.runId && state.detail && state.detailId === route.runId && (!workspaceSetMode() || state.detailWorkspace === route.workspace) && state.detail.run && state.detail.run.id === route.runId;
      const staleRoute = route.runId && (state.detailId && route.runId !== state.detailId || workspaceSetMode() && state.detailWorkspace && route.workspace !== state.detailWorkspace);
      const staleDetail = staleRoute || (route.runId && state.detail && !matchingDetail);
      const staleFollowView = route.runId && app.querySelector(".error-view[data-follow-state]") && (!matchingDetail || runChanged);
      const preserveSameRunFollowIdentity = route.follow === true && !runChanged && !state.detail && state.detailId === route.runId;
      if (staleDetail || staleFollowView) {
        // A route change must not leave the prior run painted while the new
        // authoritative request is in flight. The empty render is neutral;
        // only a matching authoritative payload can restore the detail view.
        state.detail = null;
        state.detailWorkspace = null;
        state.detailConflict = false;
        state.detailId = preserveSameRunFollowIdentity ? route.runId : null;
        delete app.dataset.errorPhase;
        delete app.dataset.errorKind;
        // The recorded paint dies with the view it described. The emptied app
        // already blocks the manual fast path, but tying the record's lifetime to
        // the paint keeps "lastPaint describes what is on screen" an invariant
        // rather than something the firstChild guard happens to cover.
        state.lastPaint = null;
        app.replaceChildren();
        setStatus("Awaiting authoritative projection…");
      }
      if (forceRefetch) refreshSingleFlight("follow retry");
      else if (matchingDetail) renderCurrentGuarded();
      else refreshSingleFlight("navigation");
    }
  }
  window.addEventListener("hashchange", routeChanged);
  document.addEventListener("click", function (event) {
    const anchor = event.target && event.target.closest ? event.target.closest("a") : null;
    if (anchor && anchor.getAttribute("href") && anchor.getAttribute("href").startsWith("#")) history.replaceState({pixirView: captureView()}, "", location.href);
  });
  window.addEventListener("pagehide", function () { history.replaceState({pixirView: captureView()}, "", location.href); });
  /**
   * True when a key event originated inside a text-entry surface. Typing "?"
   * into the search box must reach the search box, never the manual.
   * @param {EventTarget} target
   * @returns {boolean}
   */
  function typingSurface(target) {
    if (!target || typeof target !== "object") return false;
    const tag = typeof target.tagName === "string" ? target.tagName.toUpperCase() : "";
    if (tag === "INPUT" || tag === "TEXTAREA" || tag === "SELECT") return true;
    return target.isContentEditable === true;
  }
  // Global manual keys. Deliberately minimal: exactly two bindings, no modifier
  // combinations, no key capture inside form fields, and no preventDefault on
  // anything this handler does not itself act on. Escape with the pane already
  // CLOSED is a strict no-op — it writes no hash and starts no navigation, which
  // keeps the existing accessibility contract (Escape never navigates) intact.
  //
  // An open review dialog outranks both bindings. Those dialogs are opened with
  // showModal() and register no cancel/keydown handler of their own, so NATIVE
  // Escape is their only keyboard exit; a preventDefault here would suppress it
  // and close the manual pane behind the modal instead, trapping the operator in
  // a dialog that no longer answers Escape. typingSurface() cannot cover this —
  // focus parked on the dialog's Cancel/Copy <button> is not a text-entry
  // surface — so the modal is checked separately, and the pane stays the pure
  // overlay it claims to be rather than reaching into a shipped modal contract.
  document.addEventListener("keydown", function (event) {
    // Inert on the boot-error screen: that paint deliberately starts no fetch and
    // no stream, and state.manual was never seeded, so a manual toggle here would
    // take the ordinary routeChanged path and replace the honest failure message
    // with a fetched view the boot refused to start.
    if (shellConfigError) return;
    if (event.defaultPrevented || event.altKey || event.ctrlKey || event.metaKey) return;
    if (typingSurface(event.target)) return;
    if (document.querySelector("dialog[open]")) return;
    const route = parseRoute(location.hash);
    if (event.key === "Escape") {
      if (!manualField(route.manual)) return;
      event.preventDefault();
      location.hash = manualRoute(route, null);
      return;
    }
    if (event.key !== "?") return;
    event.preventDefault();
    location.hash = manualRoute(route, MANUAL_INDEX);
  });

  window.PixirMonitorUI = Object.freeze({boundedLogNote: boundedLogNote, parseRoute: parseRoute, routeHash: routeHash, clientStateKey: clientStateKey, visible: visible, classifyCommand: classifyCommand, escapedEvidence: escapedEvidence, validInvalidation: validInvalidation, limits: LIMITS, sortVocabulary: SORT_VOCABULARY, defaultSort: DEFAULT_SORT, runsComparator: runsComparator, temporalField: temporalField, durationLabel: durationLabel, attentionRenderAllCap: ATTENTION_RENDER_ALL_CAP, attentionRowBudget: attentionRowBudget, resolveParentObservedChild: resolveParentObservedChild, glossaryEntries: glossaryEntries, glossaryBySlug: glossaryBySlug, glossaryConcerns: glossaryConcerns, manualField: manualField, manualRoute: manualRoute, manualUnderlyingKey: underlyingKey, manualIndexSlug: MANUAL_INDEX, manualRunValueSlugs: Object.freeze(Object.keys(MANUAL_RUN_READERS).sort()), manualNoRunValueSlugs: MANUAL_NO_RUN_VALUE_SLUGS, labelledTerms: LABELLED_TERMS, labelledTermSlug: labelledTermSlug, isMonitorDefect: isMonitorDefect, normalizeProjectionFailure: normalizeProjectionFailure});
  // Pre-load failure UX belongs solely to the shell bootstrap (PixirMonitor.Bootstrap):
  // this script loads only after the bootstrap promise fulfills, so rejection is unreachable here.
  window.__pixirBootstrap.then(function () {
    if (shellConfigError) {
      state.streamState = "down";
      app.textContent = "Workspace Overview could not start: malformed shell configuration.";
      setStatus("Workspace Overview boot error · relaunch required");
      return;
    }
    if (!location.hash || location.hash === "#") history.replaceState(null, "", workspaceSetMode() ? "#/workspaces" : "#/runs");
    // Seed the manual-delta baseline from the route we actually boot on, so the
    // FIRST manual toggle after load is already recognized as manual-only. A
    // `#manual/<slug>` deep link boots with the pane open and its underlying
    // route is the default view, which is what makes closing it a no-refetch
    // re-render rather than a navigation.
    const bootRoute = parseRoute(location.hash);
    state.manual = bootRoute.manual || null;
    state.manualUnderlyingHash = underlyingKey(bootRoute);
    refreshSingleFlight("initial load");
    connect();
  }).catch(function () {
    // Only a synchronous throw in the continuation above can land here; bootstrap
    // rejection cannot (see the ownership comment on the attachment). Report the
    // failure honestly instead of attributing it to launch expiry.
    state.streamState = "down";
    setStatus("Monitor initialization failed. Reload the page, or run pixir-monitor serve again for a fresh session.");
  });
}());
