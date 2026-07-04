# 32. Minimal workflow events record durable run decisions

Date: 2026-06-30
Status: Accepted
Implementation status: Minimal runtime emission implemented; automated whole-workflow
resume remains a follow-up slice.

## Context

ADR 0012 introduced Workflows as deterministic structural orchestration over
Subagents, but deliberately avoided a canonical `workflow_event` in v1. ADR 0014 then
added Step Outcomes, Checkpoint Bundles, and Partial Workflow Outcomes so a completed
or partial `run_workflow` Tool result could explain what happened honestly.

That is enough when the parent Turn reaches a persisted `tool_result`. It is weaker
when the Workflow is interrupted mid-run, when Pixir needs to repair replay after an
orphaned `run_workflow` call, or when a fork needs to preserve enough workflow graph
and checkpoint decisions to diagnose or resume safely. ADR 0018 already names this
failure mode: an interrupted `run_workflow` can spawn Subagents but never persist the
parent `tool_result`.

The design question is not whether every Workflow status update should be durable. ADR
0004 makes canonical Events a curated Log vocabulary. The question is which Workflow
decisions must survive restart, fork, replay repair, and diagnostics.

## Decision

Pixir accepts a minimal canonical `workflow_event` type for durable Workflow run
decisions.

`workflow_event` is a single canonical Event type whose `data` payload carries a
string-keyed `kind`. This keeps the Event vocabulary small while allowing a focused
Workflow event family.

The initial `kind` vocabulary is:

| Kind | Durable meaning |
| --- | --- |
| `workflow_started` | A normalized Workflow run began. Records run identity, source Tool call when available, normalized spec hash, graph summary, limits, and workspace posture. |
| `step_scheduled` | A Workflow step became runnable and was scheduled. Records step id, wave, dependencies, workspace mode, execution kind, and child/runner identity when known. |
| `checkpoint_decided` | The Workflow runtime classified a step outcome as dependency-safe or not. Records `checkpoint_status`, checkpoint/artifact references or hashes, source child Session when available, and dependent-safe flag. |
| `step_held` | A step was held because dependencies did not become `checkpoint_ready`, capacity/backpressure prevented safe scheduling, or the Workflow stopped before the step could run. |
| `workflow_finished` | The Workflow reached a terminal projection: `completed`, `partial`, `failed`, `timed_out`, or `cancelled`, with summary counts and safe next actions. |

This vocabulary records decisions, not progress noise. Poll ticks, spinners, live queue
lengths, repeated wait updates, renderer status, and model-facing prose remain
ephemeral or ordinary Tool output.

## Relationship To Existing Evidence

`workflow_event` does not replace:

- `tool_call` / `tool_result` for the model-facing Tool contract;
- `subagent_event` for child Session lifecycle;
- Checkpoint Bundles for step evidence and dependency-safety data;
- `history_compaction` for bounded Provider replay;
- typed checkpoint outputs from ADR 0033.

Instead, `workflow_event` links those facts into a replayable Workflow run spine. A
clean completed Workflow still returns its structured `tool_result`. If the parent Turn
is interrupted before that `tool_result` exists, workflow events plus subagent events
give repair and diagnostics enough durable evidence to avoid pretending the Workflow
cleanly completed or erasing useful child work.

Provider replay should not blindly fold every `workflow_event` into model context. By
default, workflow events are audit and repair evidence. Provider-visible Workflow text
continues to come from clean `tool_result` payloads, repaired fallback `tool_result`
payloads, or a future Prompt Contract that deliberately summarizes terminal Workflow
events.

## Required Durable State

Workflow events should preserve enough state to answer:

- which Workflow run was started;
- which normalized graph/spec it used;
- which steps were scheduled, held, or terminally classified;
- which checkpoints were accepted or rejected for dependency unlocking;
- which child Sessions or virtual runners produced evidence;
- whether the Workflow terminal projection was completed, partial, failed, timed out, or
  cancelled;
- which safe next actions are available after restart or fork.

The payload should prefer stable identifiers, hashes, counts, references, and bounded
summaries over full duplicated data. The original `run_workflow` Tool call already
contains the model-supplied spec when the Workflow came from a Tool. The final
`tool_result`, when present, already contains the full result projection. Workflow
events should not duplicate large prompts, child transcripts, or unbounded artifacts.
When a checkpoint decision depends on a typed payload, the event should prefer payload
schema ids, hashes, checkpoint ids, or artifact references over embedding the full
payload.

## Fork, Resume, Replay Repair, And Diagnostics

### Resume

Whole-workflow resume requires a durable run spine. An implementation can reconstruct
which steps were pending, active, checkpoint-ready, failed, or held by folding
`workflow_event` together with `subagent_event` and available child Logs.

Resume is not required to be automatic in the first implementation. The minimum slice
should produce enough evidence to say whether resume is safe, blocked, or requires user
input.

### Fork

Forks should preserve `workflow_event` evidence through the fork boundary when the
forked prefix includes Workflow activity. A forked Session can then explain the
Workflow state it inherited without relying on volatile parent process memory.

Provider replay may still treat the copied workflow events as audit-only unless a later
Prompt Contract explicitly chooses a concise terminal summary.

### Replay Repair

When a `run_workflow` Tool call has no matching `tool_result`, Session repair can use
workflow events to synthesize a bounded fallback result that says the Workflow was
interrupted, partial, or unknown, and points to child evidence. This extends ADR 0018's
orphan tool repair without inventing a second source of truth.

### Diagnostics

Diagnostics can report workflow graph state, held steps, checkpoint decisions, and
safe next actions from Log evidence instead of inferring them from transient runtime
state or re-running child Sessions.

## Canonical Versus Ephemeral

Canonical:

- Workflow run start;
- step scheduling decisions;
- checkpoint acceptance/rejection decisions;
- held/blocked decisions;
- terminal Workflow projection.

Ephemeral:

- progress ticks;
- live wait/poll updates;
- UI rendering status;
- transient queue depth snapshots unless explicitly captured as backpressure evidence;
- repeated child wait state that is already represented by `subagent_event`.

## Minimum Implementation Slice

The first implementation should:

1. Add `:workflow_event` to `Pixir.Event.canonical_types/0`.
2. Add `Pixir.Event.workflow_event/3`.
3. Emit `workflow_started` after Workflow normalization succeeds and before scheduling
   steps.
4. Emit `step_scheduled` whenever the runtime schedules a Subagent or direct
   `virtual_overlay` step.
5. Emit `checkpoint_decided` when a step outcome becomes `checkpoint_ready`, `partial`,
   `failed`, or `needs_orchestrator`.
6. Emit `step_held` when a pending step is held because dependencies are not
   checkpoint-ready or the Workflow stops before it can run.
7. Emit `workflow_finished` before returning completed or partial Workflow results.
8. Update replay/fork/diagnostic tests to prove events round-trip through the Log and
   can support orphan `run_workflow` repair.

This is deliberately smaller than durable Workflow process supervision. It records
truth first; automated resume can follow once the Log has enough evidence.

The initial runtime slice implements canonical `workflow_event` construction, emits
the five accepted decision kinds from `Pixir.Workflows`, preserves workflow events
through forks, and keeps Provider replay from folding raw Workflow events into model
context. Full replay repair and automated resume remain later work.

## Consequences

- Pixir gains a durable Workflow run spine without turning live progress into Log spam.
- Interrupted `run_workflow` calls can be repaired and diagnosed more honestly.
- Forked Sessions can carry Workflow evidence across the branch boundary.
- Checkpoint Bundles remain the dependency-safety payload; workflow events record when
  the runtime accepted or rejected those checkpoints.
- Typed checkpoint outputs (ADR 0033) get a clearer attachment point, but are not
  required for this decision.
- Adding `workflow_event` is a real Log schema change and must be implemented with
  round-trip tests.

## Non-goals

- Do not implement `workflow_event` runtime emission in this ADR.
- Do not persist every live Workflow status update.
- Do not replace `tool_result`, `subagent_event`, or Checkpoint Bundles.
- Do not design the typed checkpoint output system.
- Do not add automatic whole-workflow resume in the first event slice.
- Do not make Provider replay ingest raw Workflow events by default.

## Verification Direction

The design slice should pass:

```bash
git diff --check docs/adr CONTEXT.md AGENTS.md
mix format --check-formatted
mix compile --warnings-as-errors
```

Future implementation checks should prove:

- `workflow_event` is canonical and round-trips through raw NDJSON Log fold;
- event `data` uses string keys;
- normal completed Workflows emit `workflow_started`, scheduling/checkpoint events, and
  `workflow_finished`;
- partial Workflows emit held/checkpoint evidence without claiming completion;
- interrupted or orphaned `run_workflow` calls can be repaired into honest fallback
  `tool_result` evidence;
- forks preserve workflow events in the copied prefix;
- Provider replay does not flood model input with raw Workflow events by default.

## References

- ADR 0004: unified Event envelope and canonical vs ephemeral events.
- ADR 0012: Workflows are structural orchestration over Subagents.
- ADR 0014: Workflow Checkpoint Bundles and honest partial outcomes.
- ADR 0018: Durable History compaction and replay repair.
- ADR 0024: Session fork and branch summaries.
- ADR 0033: Typed Checkpoint Outputs as harness-owned projections.
- Issue #114: Decide `workflow_event` durability for whole-workflow resume.
