# 14. Workflows report Checkpoint Bundles and honest partial outcomes

Date: 2026-06-04
Status: Accepted
Implementation status: Implemented

## Context

ADR 0012 deliberately shipped a small Workflow v1: structural dependency edges,
read/write posture, conservative write-set serialization, execution through
the Subagents manager, and compact terminal summaries. It explicitly deferred typed
outputs, merge-back, workflow-level Events, and whole-workflow resume.

The T3 Code UI smoke after ADR 0012 exposed the next reliability gap. A tiny read-only
Workflow completed cleanly, but a broader Workflow produced useful Subagent outputs while
other steps timed out and the root retried. The UI could show `run_workflow` and Subagent
lifecycle updates, but the runtime did not yet give the parent a first-class answer to:

- which steps completed;
- which steps timed out or failed;
- which results are safe for downstream steps;
- which dependents were held;
- whether retry is safe;
- what partial evidence can still be used.

The hybrid Claude Code orchestrator used "checkpoint bundles" to decide whether a
dependent task could proceed. Pixir should borrow that semantic contract without
borrowing Claude Code's script/runtime mechanics.

## Decision

Pixir will extend Workflow results with **Step Outcomes**, **Checkpoint Bundles**, and
**Partial Workflow Outcomes**.

A **Step Outcome** records both the raw Subagent lifecycle status and the Workflow's
derived usability decision. It includes at least:

- `step_id`;
- `agent_id`;
- `child_session_id` when available;
- `wave`;
- raw `subagent_status`;
- derived `checkpoint_status`;
- concise summary;
- elapsed time when available;
- error kind/details when terminal failure occurred;
- any Checkpoint Bundle produced.

`checkpoint_status` is a Workflow-level projection, not a replacement for Subagent
lifecycle status:

| Status | Meaning |
| --- | --- |
| `checkpoint_ready` | The step produced a result safe for dependents to consume. |
| `partial` | The step produced useful evidence but not enough to unblock dependents. |
| `failed` | The step reached a terminal non-usable state, including failed, timed out, cancelled, closed, or detached with no usable checkpoint. |
| `held` | The step was not started because a dependency did not become checkpoint-ready. |
| `needs_orchestrator` | The step found a material ambiguity, seam conflict, or unreconciled decision the Workflow cannot safely resolve. |

A **Checkpoint Bundle** is the structured evidence that makes a step safe to consume:

- produced contract or artifact;
- verification evidence when the template/practice requires it;
- known limitations;
- dependent-safe flag;
- source Subagent id and Session id;
- optional structured payload once typed outputs exist.

Checkpoint requirements are also passed to each child Turn through Subagent Delegation
Context. That makes the expected evidence and dependency-unblocking contract visible as
operational context for the child, instead of relying only on prose in the task prompt.

A **Partial Workflow Outcome** is returned when a Workflow started and produced some
operational truth but did not reach completed status. It records:

- all Step Outcomes;
- usable Checkpoint Bundles;
- failed/partial/held/needs-orchestrator steps;
- held dependents;
- unresolved Seam Obligations;
- safe next actions such as retry, rerun failed steps only, ask user, or abort.

Invalid Workflow specifications remain Tool errors (`:invalid_args`) per ADR 0005.
Provider/runtime crashes that prevent Pixir from knowing what happened may still be Tool
errors. But expected agentic outcomes such as one step timing out while another completed
are Workflow outcomes, not protocol failures. They should be returned as structured
Workflow data so parent agents and presenters cannot mistake partial work for success or
lose useful evidence.

## Consequences

- Downstream steps should unlock only from `checkpoint_ready`, not merely from raw
  Subagent `completed`.
- A Workflow can fail honestly without erasing completed child work.
- ACP/T3 and terminal presenters can show partial outcomes without misleading success
  prose.
- Parent agents can decide whether to retry only failed steps, ask for approval, or
  synthesize from partial evidence.
- This creates a natural bridge to Skill-backed Workflow Templates: each template can
  define what a valid Checkpoint Bundle means for its practice.
- Delegated child Turns can be guided toward checkpoint-safe outputs while the Workflow
  runtime remains the authority that decides whether a checkpoint actually unblocks
  dependents.
- ADR 0033 later defines typed checkpoint outputs as optional harness-owned projections
  that fit inside or are referenced by this result envelope without requiring every
  Subagent answer to become strict JSON.

## Non-goals

- Do not add automatic merge-back from isolated writer snapshots in this ADR.
- Do not add whole-workflow resume or canonical `workflow_event` yet.
- Do not replace Subagent lifecycle statuses; preserve them and add a Workflow projection
  over them.
- Do not make partial outcomes count as completed Workflows.

ADR 0032 later accepts a minimal canonical `workflow_event` type for durable Workflow
run decisions. Checkpoint Bundles remain the dependency-safety payload; Workflow Events
record when the runtime accepts, rejects, holds, or finishes around those bundles.
ADR 0033 later defines optional typed payloads and artifact references inside those
bundles.

## Verification Direction

The first implementation should add no-network tests before real-network smoke:

```bash
mix test test/pixir/workflows_test.exs test/pixir/tools_test.exs
mix pixir.smoke.workflows --dry-run --json
```

Required scenarios:

- all steps checkpoint-ready;
- one step times out while another step has a usable partial or ready checkpoint;
- dependent steps become `held`;
- invalid graphs still return `:invalid_args`;
- `run_workflow` renders partial status without claiming completion;
- ACP presentation distinguishes completed, partial, held, and failed outcomes.

## References

- ADR 0003: stateless Turns; local Log is source of truth.
- ADR 0004: unified Event envelope and canonical vs ephemeral events.
- ADR 0005: tool ergonomics and structured errors.
- ADR 0011: BEAM-native Subagents as supervised child Sessions.
- ADR 0012: structural Workflows over Subagents.
- ADR 0013: Skills can provide Workflow Templates as installed practices.
- ADR 0032: Minimal Workflow Events for durable run decisions.
- ADR 0033: Typed Checkpoint Outputs as harness-owned projections.
