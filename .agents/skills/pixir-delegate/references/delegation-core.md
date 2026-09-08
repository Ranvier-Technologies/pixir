# Delegation core — host-neutral judgment

This is the judgment layer shared by every pixir-delegate variant. Actuation
surfaces differ per host (external CLI, Codex-root daemon, Pixir-native
Subagent tools); this doctrine does not. A variant SKILL.md teaches its
surface's mechanics and defers here for the practice.

Proven to transfer: an orchestrator running inside Pixir used this core to
justify choosing native Subagent tools over the CLI commands the Claude
variant teaches — the judgment held even against the recipes.

## Routing

| Situation | Shape |
|---|---|
| One worker, one task | one-shot |
| N independent parallel workers | shared-runtime fan-out |
| Sequentially dependent steps | one steered chain (resume), never fan-out |
| Fan out, then steer or retry one child | fan-out + per-child resume |

Anti-pattern: N independent one-shot processes for fan-out. Every surface has
a shared-runtime form; use it.

## Refusal — when not to delegate

- A child starts blind. If writing the self-contained prompt costs more than
  doing the work, do it yourself.
- Sequential dependencies want one chain, not parallel children.
- A workspace whose state you cannot share with another writer means
  read-only children or no delegation.
- One trivial question is not a delegation.

## Rehearsal — before the first real act

Rehearse in whatever non-mutating form the surface offers (CLI: `--dry-run`;
other surfaces: validate the plan/spec/schema without spending provider
tokens). Treat structured errors and `next_actions` as the runtime teaching
you its current contract. Use the same effective caller timeout in rehearsal
and the real act; CLI automation must validate the rehearsal JSON and stop before
execution when `would_reject` is true. Do not memorize contracts; ask the runtime to
reveal them at the moment of use. Know exactly WHICH binary/runtime version
you are driving before delegating through it.

Acceptance is not validation of every knob: surfaces may ignore unknown
fields silently, so a typo or an invented setting can pass rehearsal while
doing nothing. Before trusting that rehearsal exercised an intent-bearing
knob, confirm the knob exists in the surface's revealed contract (help,
plan echo, or documented spec), not merely that no error mentioned it.

Readiness classification (doctor or equivalent): `ready` proceeds;
`ready_with_warnings` means read the non-passed checks and judge — a missing
local build is non-blocking, failed auth is not; an error status never
delegates. Record the classification in your closure report.

## Sizing

- Concurrency: set the surface's thread/child limit to your child count
  unless deliberately throttling — provider quota is shared across children
  and the limit is your backpressure lever.
- Timeouts cover waves: with tasks > concurrency, children run in
  `ceil(N / concurrency)` waves. The Delegate admission floor is that wave count
  times the resolved uniform child budget. The caller horizon is the resolved
  wait horizon (`wait_horizon_ms` cascading through delegate/request defaults).
  A caller timeout changes that horizon, not an omitted child budget: omitted child
  budgets use `Subagents.default_limits().timeout_ms` (currently 120s). Explicit
  `limits.child_timeout_ms` or `subagents.timeout_ms` pins the child budget, while
  legacy spec-level `limits.timeout_ms` / top-level `timeout_ms` remains a compatible
  child default. Workflow floors sum the maximum effective step budget in each
  dependency wave; omitted steps use the runtime default. The current estimate and
  wave budgets cap all step budgets by the normalized workflow timeout. The workflow
  suggestion is the least sufficient fixed point after that cap moves: it sums each
  wave's maximum uncapped declared/default budget, can exceed the current estimate
  only when the cap binds, and makes a one-shot relaunch sufficient. A real CLI
  launch whose effective horizon is shorter is rejected before creating a parent or
  child Session with structured kind
  `horizon_shorter_than_critical_path`; dry-run reports the same arithmetic and
  `would_reject` non-fatally, replacing run actions with the real rejection's
  recovery `next_actions` when true. Workflow details retain the separately resolved
  `caller_horizon_ms`, `wait_horizon_explicit`, normalized
  `declared_workflow_timeout_ms`, and `declared_workflow_timeout_explicit`, while
  `effective_timeout_ms` and runtime behavior remain their minimum.
  `wait_horizon_explicit` is true only when request `wait_horizon_ms` or spec
  `limits.wait_horizon_ms` supplied that horizon; it is false when the horizon defaulted
  from the delegate timeout. The workflow boolean records whether the normalized
  workflow spec contained `timeout_ms` before default injection. Recovery chooses the
  wait-horizon knob when it is explicit and the delegate-timeout knob when it is
  derived, and compares both the caller horizon and declared workflow ceiling with
  `suggested_timeout_ms`. When the workflow timeout is explicit, raise only the chosen
  caller knob when only the caller is short, only the workflow timeout when only it is
  short, and both when both are short. When the workflow timeout is omitted, its
  normalized value remains the delegate-derived ceiling rather than a workflow field to
  widen. With an explicit wait horizon, raise only the wait when only the caller is
  short, only the delegate timeout when only that ceiling is short, and the wait plus
  delegate timeout when both are short. With a derived wait horizon, raise only the
  delegate timeout because it moves both derived values. Thus recovery does not emit a
  wait-only action when the wait is already sufficient but the delegate-derived ceiling
  binds. Do not infer which knob binds from the relationship between the capped estimate
  and suggestion. Omitted subagent
  budgets stay stable, and the workflow suggestion accounts for cap movement, so the
  suggested value is a fixed point. When a spec intentionally couples the legacy spec
  timeout to child budget, pin `limits.child_timeout_ms` explicitly before widening the
  caller horizon. The `--allow-short-horizon` flag is an explicit break-glass escape
  hatch and records the same four stable override values in `horizon_override`; the
  four binding-evidence fields are admission details and do not change that override
  schema.
  Workflow dry-runs also emit `plan_warnings[]` when the spec explicitly declares its own
  `timeout_ms` and a step explicitly declares a longer one. That entry
  (`kind: "step_budget_capped_by_workflow_timeout"`) names each offending step's
  `step_index`, `step_id`, `json_pointer`, `path`, `declared_step_timeout_ms`, the
  capping `declared_workflow_timeout_ms`, and the `effective_step_timeout_ms` it will
  actually receive, predicting the runtime `closed_by_workflow_timeout` cancellation. The
  `json_pointer`/`path` address the step list *as submitted*: `/steps/<i>/timeout_ms` for
  a flat spec and `/workflow/steps/<i>/timeout_ms` for the nested shell form. Its
  `next_actions` are `increase_workflow_timeout_to_cover_declared_step_timeouts`,
  `reduce_workflow_step_timeouts`, and `retry_workflow_with_larger_timeout`. It is
  advisory only and independent of `would_reject`: a plan carrying only this warning is
  still runnable and keeps its accepted exit code, and when a rejection also fires the
  warning sits alongside that `summary`/`next_actions` rather than replacing them. It
  stays silent for a defaulted workflow timeout, for steps that omitted `timeout_ms`, and
  when every declared step budget fits; `subagents` plans never carry it. `plan_warnings`
  is distinct from the runtime `warnings` list of Provider output-truncation evidence.
  Workflow dependency-wave maxima are a conservative batch admission estimate: a
  work-conserving scheduler may realize less wall time by starting newly unblocked work before the rest of a batch
  finishes. Admission deliberately still fails closed on the conservative sum. These
  estimates exclude retries, jitter, and orchestration overhead, so they are floors,
  not promises.

## Contracts

Every child prompt is self-contained and demands strict JSON output against
an explicit schema. The child's final message is your data; make it
parseable on arrival.

- Evidence citations in child contracts should allow line RANGES
  (`file:start-end`); single-line citations are fragile for multi-line
  sections and push children toward `uncertain` verdicts.
- For large files, instruct sectioned reads in the task prompt — a child
  that truncates its source produces confident-looking partial evidence.
- Read-only children run only bare safe-listed shell commands (no pipes,
  chaining, or redirection — by design). Shape tasks around their read
  tools; do not fight the posture.

## Closure — evidence-gated, never exit-code-gated

For virtual-overlay children, scratch lifetime is one `run_virtual_commands`
invocation, not the whole Session. Batch dependent edits/reads within that call.
Use `deliverable: true` to keep that invocation's artifact selected through later
unmarked reads; a newer explicit mark replaces it. Selection is not application:
inspect the returned durable reference and use the separate permissioned apply
operation explicitly. Logs/artifacts still use disk; avoiding per-child workspace
copies is the storage benefit, not a promise of zero I/O or faster inference.

For bounded-write verification, `bash.verify` lists exact commands, including flags.
`verify_prefixes` controls which commands may be declared, not arbitrary runtime
suffixes. Include the literal approved commands in the child brief. A denied optional
variant does not authorize broadening policy; an already-approved exact alternative
can still be used.

A delegation closes when its outcome is reconciled: every child's terminal
status read, every summary parsed against its declared contract, every
non-completed child dispositioned — resumed, retried, or reported. Partial
failure recovers per child; never re-run the whole batch. If the surface's
output fails to parse, the run failed — read the error channel, do not
scrape fragments.

Runtimes absorb recovery over time: eligible children may already have been
auto-retried before you see the result. Reconcile whatever retry confession
the surface offers as part of the record, never re-retry what the runtime
already retried, and distrust a successful retry when the task was not
idempotent (verify its effects, not its status).

## Evidence

Every child is a durable session with an append-only log. Reconcile costs
and behavior from logged per-call usage evidence, not estimates. Timed-out
or failed children remain resumable sessions — recovery is a first-class
move, not an apology.
