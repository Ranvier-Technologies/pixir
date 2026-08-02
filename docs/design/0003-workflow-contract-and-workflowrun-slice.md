# Workflow contract and first WorkflowRun slice

Date: 2026-06-24

Status: Design note

Related: ADR 0012, ADR 0014, ADR 0026, issues #83 and #92

## Context

Pixir Workflows are already useful as structural orchestration over Subagents:
they validate dependencies, serialize write-set conflicts, run steps through the
Subagent manager, and return checkpoint-aware outcomes. The remaining backend
question is whether the next hardening step should introduce a durable
`WorkflowRun` process now, or first make the current contract explicit enough to
diagnose and test.

ADR 0012 deliberately avoided a new canonical `workflow_event`. ADR 0014 added
Step Outcomes, Checkpoint Bundles, and Partial Workflow Outcomes. ADR 0026 then
made the terminal-state vocabulary explicit across Turns, Subagents, Workflows,
replay, and presenter projection.

## Current contract

The current implementation keeps Workflow truth in two layers:

| Layer | Values | Meaning |
| --- | --- | --- |
| Workflow result `status` | `completed`, `partial` | `completed` means every step is checkpoint-ready; `partial` means at least one step needs retry, inspection, synthesis, or orchestrator input. |
| Step `checkpoint_status` | `checkpoint_ready`, `partial`, `failed`, `held`, `needs_orchestrator` | Step-level truth used to unlock dependents and explain why the Workflow did not complete. |

Workflow `ok == true` is reserved for full completion. A partial Workflow can be
valuable, but it is not a successful completion.

## Outcome semantics

| Situation | Workflow status | Step evidence | Parent-facing meaning |
| --- | --- | --- | --- |
| Every required step returns a dependent-safe checkpoint | `completed` | All steps have `checkpoint_status == "checkpoint_ready"` | Parent can consume the Workflow as complete. |
| A step returns useful but incomplete evidence | `partial` | `partial_steps` includes the step; dependents are held unless another dependency path is ready | Parent can synthesize from partial evidence or retry. |
| A child Subagent fails | `partial` | `failed_steps` includes the step with reason/details when available | Parent must not treat the Workflow as complete. |
| A step or Workflow timeout occurs | `partial` | `timeout_steps` and `failed_steps` include timeout metadata and safe next actions | Parent can inspect/retry with larger timeout. |
| A dependency never becomes checkpoint-ready | `partial` | `held_steps` records scheduler hold reason | Parent can rerun after dependencies become ready or ask the orchestrator. |
| A step asks for human/orchestrator decision | `partial` | `needs_orchestrator_steps` records the blocking decision | Parent should ask, not continue blindly. |

Downstream steps unlock only from `checkpoint_ready`, never from raw Subagent
`completed` alone.

## Which workflow shape to reach for

**For implementation lanes the canonical shape is a single-step workflow whose
verification is performed by the parent.** Multi-step in-workflow gating remains
fully supported and is not deprecated — it is the right tool for read-only
pipelines and for lanes whose steps can run their own checks.

The discriminator is not the number of steps or the kind of work; it is
**whether a step can verify its own work**. A step that can run the build, the
tests, or the linter produces a `checkpoint_ready` checkpoint that honestly
unblocks its dependents. A step that cannot — a bounded writer with no shell
being the clearest case — has no way to reach `checkpoint_ready` on its own
merits, so a graph that gates a dependent on it is fail-by-default: the
dependent is held with `dependency_not_checkpoint_ready` and the whole run
terminates `partial`. Splitting such a lane across steps buys ordering the
parent already has, at the cost of a run that cannot complete.

| Lane | Blessed shape | Why |
| --- | --- | --- |
| Implementation (a writer that cannot run checks) | Single-step workflow; the parent verifies and sequences | The writer cannot self-verify, so nothing downstream can honestly gate on it |
| Read-only pipeline (survey → synthesize, propose → review) | Multi-step gating | Read-only steps reach `checkpoint_ready` on completion; gating is real |
| Checks-capable lane (a step that runs build/tests itself) | Multi-step gating | The step's own checks are the evidence that unblocks dependents |
| Writer whose audit *is* the verification | Multi-step with `allow_unverified_depends_on` | See below; the gate relaxation is an operator assertion, not runtime proof |

### The unverified-dependency opt-in

`allow_unverified_depends_on` is a per-step, per-dependency escape hatch that
makes in-workflow audit viable for shell-less writer lanes. A step lists a
subset of its own `depends_on` ids; each named dependency then unblocks the step
under a narrow admission rule:

> The named dependency's child reached a **successful terminal completion** and
> its derived `checkpoint_status` is **`partial`**.

Everything else stays inadmissible: a completed child self-declaring `failed` or
`needs_orchestrator`, a child that timed out or was cancelled, and a dependency
that was itself `held`. The opt-in is never a default and never global — absent
the flag the strict `checkpoint_ready` gate is unchanged for every step and
posture, and a dependency the flag does not name still gates strictly even when
a sibling dependency is named. Naming an id that is not in the step's own
`depends_on` is a normalization error; the workflow never launches.

**The evidence caveat is the point.** The runtime cannot distinguish "finished
the work but could not self-verify" from "genuinely did not finish": both are a
completed child that marked itself `partial`. There is no new terminal state and
none is planned. So using the flag is an *operator assertion about the lane*,
not a runtime-proven property, and the runtime records that honestly instead of
pretending otherwise:

- The opted-in step's checkpoint bundle carries
  `verification.unverified_dependencies` naming the dependency ids that supplied
  the unverified basis, and adds `ran_against_unverified_dependencies` to its
  `known_limitations`.
- The same information appears in the step's `workflow_checkpoint.v1` typed
  payload as `unverified_dependencies`, alongside `verification_source` and
  `known_limitations`, so a consumer reading only the checkpoint bundle can tell
  that these conclusions rest on unverified upstream work.
- The opt-in **never launders the upstream dependency**. The writer keeps its
  derived `checkpoint_status`, its `dependent_safe: false`, and its own
  `known_limitations`, and it still counts as `partial` in workflow-level
  rollups. A run whose writer stayed `partial` still terminates `partial`.

The flag is visible in `dry_run` step plans, so an operator can confirm the gate
relaxation before launching.

## WorkflowRun decision

Do not introduce a durable `WorkflowRun` GenServer in this slice.

Reasoning:

- The current issue needs contract hardening more than a second runtime owner.
- ADR 0012 still says Subagents are the execution authority and Workflows v1 do
  not add a canonical `workflow_event`.
- The existing `run_workflow` tool already returns structured partial outcomes
  for parent agents.
- A durable `WorkflowRun` process should be introduced only with event and replay
  semantics, not as an internal refactor hidden from diagnostics.

## Implemented first slice

The first backend slice is a pure `Pixir.WorkflowRun` state boundary, not an OTP
process. It owns the in-memory execution state for one normalized Workflow:
pending steps, active child references, completed step records, wave history, and
the start time used for Workflow-level timeout decisions.

This improves code ownership without changing runtime truth:

- Subagents remain the execution authority.
- `Pixir.Workflows` remains the tool-facing projection.
- No durable `workflow_event` is emitted yet.
- Replay/cache behavior is unchanged because WorkflowRun state is not provider
  replay context.
- Partial, failed, timed-out, and held outcomes still flow through the existing
  Workflow result contract.

## First safe WorkflowRun slice

When Pixir does add `WorkflowRun`, the smallest safe slice should be:

1. A `WorkflowRun` process owns one Workflow execution graph.
2. It emits durable `workflow_event` records for:
   - `workflow_started`
   - `step_started`
   - `step_checkpoint_ready`
   - `step_partial`
   - `step_failed`
   - `step_timed_out`
   - `step_held`
   - `needs_orchestrator`
   - `partial_outcome_ready`
   - `completion_ready`
3. Every event includes enough identity to reconcile with Subagent truth:
   - `workflow_id`
   - `parent_session_id`
   - `step_id`
   - `agent_id`
   - `child_session_id`
   - `checkpoint_status`
   - `reason`
   - `timeout_ms`
   - `elapsed_ms`
   - `next_actions`
4. `run_workflow` remains a tool projection over the same truth, not a competing
   state store.
5. Diagnostics can reconstruct the graph after crash/restart from the Log.

## Test strategy

The current contract should stay locked by no-network tests:

- `Workflows.workflow_statuses/0` returns the top-level status vocabulary.
- `Workflows.checkpoint_statuses/0` returns the step checkpoint vocabulary.
- Full completion returns `ok == true`, `status == "completed"`, and
  `completion_ready` proof states.
- Failed, partial, timeout, held, and needs-orchestrator outcomes return
  `ok == false`, `status == "partial"`, structured step lists, and safe next
  actions.
- The backend gauntlet should later verify that no presenter or diagnostic layer
  collapses partial Workflow outcomes into success.

## File ownership

Current contract surface:

- `lib/pixir/workflows.ex`
- `lib/pixir/workflow_run.ex`
- `test/pixir/workflows_test.exs`
- `test/pixir/workflow_run_test.exs`
- `docs/adr/0012-structural-workflows-over-subagents.md`
- `docs/adr/0014-workflow-checkpoint-bundles-and-partial-outcomes.md`
- `docs/adr/0026-runtime-terminal-state-and-replay-contract.md`

Future durable WorkflowRun surface:

- `lib/pixir/workflow_run_supervisor.ex`
- `lib/pixir/event.ex`
- `lib/pixir/log.ex`
- `lib/pixir/session_diagnostics.ex`
- `test/pixir/workflow_run_test.exs`
- `test/pixir/session_diagnostics_test.exs`
