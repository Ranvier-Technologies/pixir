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
