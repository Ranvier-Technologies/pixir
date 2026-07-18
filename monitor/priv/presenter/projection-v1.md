# Pixir Presenter Projection v1

Status: frozen candidate for fixture validation  
Schema id: `pixir.presenter.run.v1`  
JSON Schema: `schema/pixir.presenter.run.v1.schema.json`

## Purpose

`pixir.presenter.run.v1` is a deterministic, lossy, presenter-neutral view of
one Pixir Delegate run. It lets a web console, TUI, ACP client, or diagnostic
surface answer the same operator questions without creating a second source of
truth:

1. What work is this run responsible for?
2. What is its canonical execution state?
3. Is anything live now, and how fresh is that observation?
4. Which Workflow dependencies may proceed?
5. Did a model-authored reviewer recommend something different from the
   runtime gate?
6. How many execution attempts and child Sessions belong to one logical unit?
7. What evidence, artifacts, usage, mutations, limitations, and safe next
   actions exist?

The projection is recomputable. It is not stored as conversation state and is
never authoritative over the Logs it cites.

## Core invariants

1. The parent and child Logs remain the canonical history.
2. Volatile runtime state never overwrites a canonical terminal fact or
   Workflow checkpoint.
3. Terminal envelopes, `diagnose`, and `tree` are derived inputs. They may add
   bounded convenience fields or expose contradictions, but cannot silently
   replace a Log fact.
4. Execution, liveness, gate, advisory verdict, and source authority are
   separate dimensions.
5. A logical unit is not a child Session. One unit may own several ordered
   attempts, and attempts may reference distinct or repeated
   `child_session_id` values.
6. Model-authored content is untrusted text or explicitly
   `model_declared` structured data. It never becomes a runtime gate.
7. Provider usage is a deterministic fold of durable `provider_usage` Events.
   v1 contains no monetary cost field.
8. `safe_actions` are projected from existing structured runtime guidance
   through the closed v1 registry below. Presenters do not invent commands,
   infer actions from prose, or silently drop unrecognized candidates.
9. Missing, stale, contradictory, or unreadable evidence becomes a limitation;
   it never defaults to success.
10. Every value that could change an operator decision has an evidence
    reference or an explicitly named deterministic basis.

## Source authority and precedence

| Rank | Source | Authority | Permitted use |
| --- | --- | --- | --- |
| 1 | Parent `workflow_event` and `subagent_event` Log entries | Canonical | Run graph, scheduling, lifecycle, checkpoints, terminal Workflow state, attempt lineage |
| 1 | Child Log entries | Canonical within the child Session | Tool activity, turn failure, provider usage, assistant output, child artifacts |
| 1a | Hash-validated evidence-mirror copies of those Logs | Canonical copy | Reconstruction when the workspace Log is absent; origin remains `evidence_mirror` |
| 2 | Deterministic folds such as `tree`, `diagnose`, and this projection | Derived | Summaries, gaps, counts, replay checks, convenience navigation |
| 2 | Delegate status/attach snapshot or terminal envelope | Derived snapshot | Identity, recovery commands, write-destination projection, final convenience fields, contradiction detection |
| 3 | Delegate Owner and Subagent Manager diagnostics | Volatile | Liveness, reachability, process health, active waiters, runtime gaps |
| 4 | Model-authored summaries or JSON | Advisory | Review verdicts, prose summaries, declared limitations; never gates execution |

When equal-rank canonical sources disagree, v1 does not choose silently. It
keeps the newest fact by Log `seq` for the same Session and adds a
`canonical_source_conflict` limitation for cross-Log or mirror mismatches.

## Source modes

- `reconstructed`: durable evidence is available, but no reachable current
  runtime observation is included.
- `mixed`: durable evidence forms the base and a reachable volatile runtime
  snapshot adds liveness or activity.
- `live`: only a volatile observation is available. This is an honest
  degradation state, must use `durable_origin: "none"`, and must carry the
  `durable_log_unavailable` limitation. It is never equivalent to durable
  completion evidence.

`source.as_of_seq` is the highest included parent Log sequence. Child evidence
references keep their own Session and sequence. `source.freshness` is:

- `terminal` when the canonical run state is terminal;
- `current` when mixed/live evidence is within the presenter's configured
  freshness window;
- `stale` when a nonterminal durable state lacks current reachable liveness;
- `unknown` when timestamps or liveness are insufficient.

The projection records timestamps but does not standardize a freshness window.
That policy belongs to each presenter and must be shown if it classifies
evidence as stale.

## Run identity

`run.id` is deterministic:

- use `delegate_id` when available;
- otherwise use `parent_session_id`;
- a Workflow additionally carries `workflow_id`, but `workflow_id` does not
  replace the Delegate run identity.

`run.title` is optional display text. It may come from a Workflow name or
operator-authored spec label. v1 does not infer a trigger such as timer,
webhook, or user request from source authority. Trigger and source are distinct
concepts; trigger is outside v1 until Pixir emits it durably.

## Canonical execution versus liveness

`execution.state` is a durable or deterministic-fold state. Volatile runtime
diagnostics do not upgrade or demote it. Typical examples:

- durable `running` plus a reachable child PID: execution `running`, liveness
  `live`;
- durable `running` plus no owner handle: execution `running`, liveness
  `stale_handle`, source freshness `stale`;
- volatile `completed` before a durable terminal Event: execution remains
  `running`, liveness is `live`, and `runtime_ahead_of_log` is a limitation;
- durable terminal execution: liveness is `not_applicable`, regardless of a
  retained Owner snapshot. A contradictory volatile `running` observation adds
  `runtime_conflicts_with_terminal_log` but does not change terminal liveness;
- the sole terminal exception is canonical ambiguous-close evidence containing
  `subagent_may_still_be_running`. That unit retains
  `stale_handle`/`owner_unavailable` until an operator resolves it;
- durable nonterminal execution plus a reachable current Owner/Manager:
  liveness `live`;
- durable nonterminal execution plus `snapshot_only`/stale Owner state:
  liveness `stale_handle` and source freshness `stale`;
- explicit runtime lookup failure: liveness `owner_unavailable`;
- insufficient evidence: liveness `unknown`.

Run execution vocabulary:

`planned | queued | running | completed | partial | failed | timed_out |
cancelled | detached | closed | held | unknown`

Liveness vocabulary:

`live | stale_handle | owner_unavailable | not_applicable | unknown`

`snapshot_only` is an Owner-service state, not presenter liveness. It means a
durable snapshot exists without a resident Owner and is normalized using the
rules above.

## Logical units

### Workflow

One unit exists per `workflow_started.graph.steps[].id`:

`workflow:<workflow_id>:step:<step_id>`

Its `execution_kind` is `subagent`, `virtual_overlay`, or
`virtual_diff_apply`. Engine-only steps have no attempts and no child Session.
Their evidence comes from Workflow checkpoint artifacts and engine
verification.

### Subagent fan-out

One unit exists per stable `subagent_id`:

`delegate:<run-id>:subagent:<subagent_id>`

The final envelope's child list is not sufficient to reconstruct the unit. The
parent Log is folded so earlier failed Sessions remain visible.

Every unit declares `materialization: durable | volatile_only`. Durable units
come from canonical Logs. When no durable Log exists, a `live` projection may
create one provisional `volatile_only` unit per Manager `subagent_id`; it may
carry observed agent/child identity and liveness, but execution, gate,
advisory, artifacts, usage completeness, mutation, and prior history remain
unknown.

## Attempt lineage

An attempt is one contiguous execution epoch of a logical Subagent unit. Its
identity is the unit id plus an ordinal, never the child Session id:

`<logical-unit-id>:attempt:<ordinal>`

Fold rules:

1. The first `started` event creates ordinal `0` with relation `fresh`.
2. A `retrying` event closes or annotates the active attempt. Its
   `failed_child_session_id`, `error_kind`, retry counters, and event evidence
   remain on that attempt.
3. A later `started` event creates a new attempt when the prior attempt is
   terminal/failed, the child Session changes, or an explicit retry/resume
   boundary exists.
4. Relation is `retry` for runtime retry evidence and `resume` for guided or
   operator resume evidence. Otherwise it is `unknown`, not guessed.
5. A resumed execution may reuse a `child_session_id`; attempt identity still
   changes because the execution epoch changed.
6. Explicit `current_attempt_index` wins only when it is monotonic and
   consistent with observed boundaries. A conflict adds
   `attempt_index_conflict` and preserves both raw evidence refs.
7. A terminal envelope that includes only the latest child Session may enrich
   that attempt, but cannot delete earlier attempts reconstructed from the Log.
8. A parent `input` event for an already-known child Session starts a new
   durable attempt with relation `resume`, even when `child_session_id` is
   reused.

The v1 fixture fold recognizes only `started`, `input`, `retrying`, `finished`,
`failed`, `timed_out`, `cancelled`, `detached`, and `closed` as attempt
lifecycle events. Retry and terminal evidence must target the active
nonterminal attempt by exact child Session identity. An unknown event kind, an
invalid terminal status, a retry/terminal target mismatch, a late terminal for
an already closed attempt, or an `input` boundary while another attempt is
active is a raw-evidence error. The checker reports it independently of the
golden; coordinated corruption of input and projection cannot normalize the
contradiction. Unit execution and advisory content consume only transitions
accepted by this lifecycle fold.

Durable attempts declare `materialization: "durable"`, a non-null ordinal, and
`status_basis: "parent_log"`. A live-only unit may expose one provisional
current attempt with:

```text
attempt_id: <logical-unit-id>:attempt:provisional:current
ordinal: null
materialization: volatile_only
status_basis: volatile_runtime
```

The provisional attempt is recomputed, never persisted or renumbered. When a
durable Log appears it disappears and durable attempts replace it. A presenter
must invalidate provisional deep links. Ambiguous identity reconciliation adds
`volatile_attempt_reconciliation_ambiguous` rather than merging by guess.

Each durable attempt also declares a child-Log event window. A single-attempt
Session uses `whole_child_log_single_attempt`. When a Session is reused,
ordered canonical child `user_message` Events define
`child_user_message_epoch` windows. Missing or mismatched anchors use `unknown`;
timestamps are never used to guess epoch boundaries.

The F4 fixture proves the need for this model: one `subagent_id` started in
`child-a`, retried after `websocket_closed`, restarted in `child-b`, and
finished there. The terminal envelope exposed only `child-b`.

## Workflow graph and gate

`graph.waves` preserves planned/runtime waves when available. `graph.edges`
is deterministically derived from `depends_on` and names logical unit ids.
When a runtime never schedules a held step, its planned topological wave still
remains present; runtime scheduling evidence may enrich a wave but cannot erase
a planned node.

Each Workflow unit carries a gate independent of execution:

`checkpoint_ready | partial | failed | held | needs_orchestrator |
not_applicable | unknown`

Only `checkpoint_ready` has `dependent_safe: true`. A completed Subagent can
still carry a non-ready model-declared advisory, and that disagreement must be
shown without changing the runtime gate.

Fan-out units use `gate.state: "not_applicable"`.

## Attention

Every unit carries:

```json
{"required": true, "reasons": ["execution_failed"], "evidence_refs": ["e-parent-1"]}
```

`attention.required` is exactly `attention.reasons != []` and
`counts.attention_units` is exactly the number of unique units whose attention
is required. Reasons are emitted in this normative order:

1. Execution: `execution_failed`, `execution_timed_out`,
   `execution_cancelled`, `execution_detached`, `execution_partial`,
   `execution_held`, `execution_unknown`.
2. Gate: `gate_partial`, `gate_failed`, `gate_held`,
   `gate_needs_orchestrator`; `gate_unknown` only for terminal execution.
3. Advisory: `advisory_stop`, `advisory_needs_review`,
   `advisory_gate_disagreement`, `advisory_unparseable`.
4. Liveness: `nonterminal_stale_handle`,
   `nonterminal_owner_unavailable`, `nonterminal_liveness_unknown`,
   `terminal_ambiguous_close`.
5. Mutation/artifacts: `mutation_partial`, `mutation_indeterminate`,
   `mutation_unknown`, `virtual_diff_unapplied`,
   `virtual_diff_apply_failed`, `virtual_diff_correlation_unknown`.
6. Integrity: `canonical_source_conflict`, `durable_log_unavailable`,
   `child_log_missing`, `attempt_index_conflict`.

Incomplete usage, unavailable monetary cost, fixture minimization, the mere
presence of safe actions, or a historical limitation resolved by later
canonical evidence do not require attention by themselves.

## Advisory projection

Advisory content is optional and always lower authority than runtime evidence.

v1 parses advisory fields only when the terminal summary is a complete JSON
object and the values have expected primitive types. Recognized fields are:

- `mergeable` boolean;
- `checkpoint_status` string as `declared_gate`;
- `verdict` string;
- `majors` and `minors` arrays;
- `summary` string.

Free prose is never classified into pass/stop. Invalid or truncated JSON yields
`parse_status: "invalid"`, preserves a bounded escaped excerpt, and adds
`model_advisory_unparseable`.

Normalized advisory verdict:

- `stop` when `mergeable` is explicitly false;
- `pass` when `mergeable` is explicitly true and no recognized blocking value
  contradicts it;
- `needs_review` for recognized nonterminal/partial declarations without an
  explicit mergeable decision;
- `unknown` otherwise.

If `advisory.declared_gate` differs from `gate.state`, v1 adds
`advisory_gate_disagreement`. Both values remain visible. The F4 fixture is the
canonical pin: runtime gate `checkpoint_ready`, model-declared gate `partial`,
and advisory verdict `stop`.

## Provider usage

Usage is a fold of durable `provider_usage` Events associated with projected
attempt child Logs.

- `calls` counts included Events.
- Exact additive counters are summed per provider/model group.
- `cached_tokens` is reported separately and is not added to `input_tokens`.
- Cache creation/read counters are preserved from `usage_summary.cache`.
- A cross-call or cross-provider cache-hit rate is omitted in v1 because
  provider-normalized denominator semantics differ. Individual raw rates remain
  available through evidence refs.
- Unknown provider identity remains `unknown`; it is not guessed from model
  marketing names.
- Missing child Logs yield no zero-valued usage. They add
  `usage_incomplete_missing_child_log`.
- v1 has no monetary cost property. A presenter must not synthesize one.
- `usage.complete` means all relevant durable usage Events through the
  projection's observed evidence boundary are included and attributable. It
  does not claim a live run will emit no future usage.

Portable fixture completeness maps normatively as follows: `complete`,
`complete_through_observed_at`, and `present_empty` may yield complete usage at
that boundary; `provider_usage_sampled`, `not_retained`, and `minimized` yield
`source: incomplete` plus `usage_fixture_minimized`; `explicitly_missing` and
`unavailable` yield `source: incomplete` plus
`usage_incomplete_missing_child_log`; `not_applicable` is valid only when no
projected Subagent attempt requires a child Log. This fixture vocabulary
describes evidence retention, not a runtime failure.

For a child Session used by one attempt, the entire child Log belongs to that
attempt. For a reused Session, attempts align with ordered child
`user_message` epochs. A `provider_usage` Event belongs only to the epoch window
that contains its `(session_id, seq)`. Unit/root totals are the union of unique
Event identities, never a sum of attempt subtotals. If windows cannot be
aligned, attempt usage is omitted, unit/root usage remains a deduplicated
incomplete fold, and `usage_attribution_ambiguous` is recorded.

## Mutation projection

Mutation status is one of:

`read_only | none | workspace_applied | isolated_only | partial |
indeterminate | not_applied | unknown`

`observed_paths` are lower-bound evidence when derived from child tool Logs;
`observed_semantics` is then `at_least`. A successful apply-engine artifact may
provide `exact` selected/applied file evidence. An absent observed path list
does not prove that no write occurred.

Shared writer failure with incomplete evidence is `indeterminate` or `partial`,
never `none`. A virtual diff with no apply evidence is `not_applied`.

A `virtual_overlay` unit itself mutates only its isolated overlay, so its unit
mutation is `isolated_only`. Application state belongs to its `virtual_diff`
artifact. A correlated apply requires all of:

1. structured `apply_from` naming the producer step;
2. the apply result's input artifact hash matching the producer diff hash;
3. a structured apply status.

The producer artifact carries `application_state` and
`applied_by_unit_id`; the apply artifact carries `producer_unit_id`,
`source_artifact_hash`, and `correlation`. Correlation is
`matched | missing | mismatch | not_applicable | unknown`. Never correlate by
dependency order, paths, or checkpoint readiness. Log-only reconstruction that
lacks structured `apply_from`/input hash yields `unknown` and
`virtual_diff_correlation_unknown`.

## Safe actions

Actions are normalized from structured `safe_next_actions`, `next_actions`,
recovery commands, and diagnose commands. v1 may deduplicate by
`(scope, id, command)`, but does not parse prose or compose a command from
parts. Every projected action records `source_field`.

When the same normalized action is present in more than one structured field,
the retained `source_field` uses this deterministic precedence:
`diagnose_command`, `resume_command`, `virtual_diff_apply_hint`,
`safe_next_actions`, then `next_actions`. The precedence records provenance;
it does not change effect or presentation.

Each action declares:

- `kind`: `inspect | diagnose | resume | retry | cancel | apply | other`;
- `effect`: `read_only | mutating`;
- `presentation`: `informational | copy_only`.

Closed v1 registry:

| Structured source | Candidate/id | Normalized id | Kind | Effect | Presentation |
| --- | --- | --- | --- | --- | --- |
| `next_actions` / `safe_next_actions` | `inspect_child_session_log` | same | inspect | read_only | informational |
| same | `inspect_partial_writes_before_retry` | same | inspect | read_only | informational |
| same | `inspect_timed_out_step` | same | inspect | read_only | informational |
| same | `rerun_subagent_after_fixing_provider_error` | same | retry | mutating | informational |
| same | `rerun_after_dependencies_checkpoint_ready` | same | retry | mutating | informational |
| same | `ask_user_or_orchestrator` | same | other | read_only | informational |
| virtual diff apply hint | `apply_virtual_diff` | same | apply | mutating | informational |
| `diagnose_command` | structured command | `diagnose_session` | diagnose | read_only | copy_only |
| `resume_command` | structured command | `resume_session` | resume | mutating | copy_only |

Unregistered candidates are omitted and add `safe_action_unrecognized`. Root
actions are the stable union of unit actions and retain unit scope; they are
never re-scoped to `run:*`. Same scope/id with differing commands adds
`safe_action_command_conflict` and suppresses the copyable command.

The read-only monitor follow-up may render mutating guidance as informational
text but cannot execute it. Command text is opaque untrusted display content.

## Evidence references

All decision-bearing projection fields cite ids from the root `evidence`
array. Evidence authority is one of:

`canonical | derived | volatile | model_declared | artifact`

Canonical Log references carry Session id and sequence when known. File paths
inside portable fixtures are sanitized relative labels, not host paths.

## Deterministic projection algorithm

1. Validate input shapes and inventory available sources.
2. Fold the parent Log by sequence to build the run, Workflow graph, units,
   canonical execution, gates, and Subagent attempt lineage.
3. Fold referenced child Logs for terminal evidence, activity references,
   usage, and observed writes.
4. Read hash-validated mirror copies only when workspace Logs are absent;
   preserve the mirror origin.
5. Compare terminal envelopes, `tree`, and `diagnose` with the durable fold.
   Add bounded derived fields and limitations; never replace contradictory
   canonical facts silently.
6. Overlay Owner/Manager diagnostics into liveness only. The sole no-Log
   exception is creation of explicitly `volatile_only` provisional units and
   attempts under `source.mode: "live"` as defined above.
7. Parse recognized model-declared advisory JSON without changing the gate.
8. Derive graph edges, attention, counts, mutation/artifact correlation,
   registered actions, and run aggregates.
9. Assign source mode, freshness, `as_of_seq`, and evidence refs.
10. Validate the result against `pixir.presenter.run.v1.schema.json`.

Ordering is stable: units follow Workflow graph order or first parent-Log
appearance; attempts follow ordinal; evidence follows first use; actions and
limitations preserve first occurrence while removing exact duplicates. For
limitations, first occurrence means the deterministic scope fold: raw
Workflow facts attributable to the unit, source/integrity and materialization
facts, advisory facts, usage-boundary facts, then mutation facts. Root order is
the first occurrence across units in unit order, followed by any source-only
fact. Reordering an otherwise identical limitation list is a contract error.

## Contradictions and limitations

The v1 limitation registry is closed to:

- `canonical_source_conflict`
- `runtime_ahead_of_log`
- `runtime_conflicts_with_terminal_log`
- `attempt_index_conflict`
- `advisory_gate_disagreement`
- `model_advisory_unparseable`
- `durable_log_unavailable`
- `child_log_missing`
- `usage_incomplete_missing_child_log`
- `workflow_graph_incomplete`
- `mutation_evidence_incomplete`
- `source_stale`
- `volatile_attempt_not_durable`
- `volatile_attempt_reconciliation_ambiguous`
- `usage_attribution_ambiguous`
- `virtual_diff_correlation_unknown`
- `safe_action_unrecognized`
- `safe_action_command_conflict`
- `dependency_not_checkpoint_ready`
- `partial_repo_mutation`
- `subagent_close_failed`
- `subagent_may_still_be_running`
- `usage_fixture_minimized` (fixture-retention evidence only; never a runtime
  failure)
- `virtual_diff_not_applied`

Limitations are machine-readable ids. Presenters may supply localized copy,
but must not soften their meaning. A new id requires a reviewed contract and
registry change; unknown values fail fixture validation rather than silently
becoming UI prose.

## Presenter requirements

- Label execution, gate, advisory, and source separately.
- Label live activity as volatile and canonical events as durable.
- Show attempt boundaries under one logical unit.
- Group Runs solely from `counts.attention_units`, then terminality/liveness;
  do not reimplement a second attention predicate in the presenter.
- Never label a trigger as evidence source.
- Never render model text, diff text, paths, or commands as trusted HTML.
- Do not hide limitations behind a successful aggregate state.
- Do not expose an action as executable unless a future control-plane contract
  authorizes and revalidates it at invocation time.

## Versioning

The root pair `schema: "pixir.presenter.run"` and `schema_version: 1` defines
this contract. Additive optional fields may be introduced only if v1 readers
can ignore them safely. Renames, changed authority, changed enum meaning,
changed attempt identity, or changed omission/default semantics require v2.

Golden fixture changes require adjudication: a runtime source-shape change may
update fixture inputs, but the frozen golden output changes only when the
presenter contract intentionally changes.
