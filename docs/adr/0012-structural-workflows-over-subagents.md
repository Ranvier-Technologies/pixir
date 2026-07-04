# 12. Workflows are structural orchestration over Subagents

Date: 2026-06-03
Status: Accepted

## Context

The surveyed Claude Code Workflows-style patterns expose a useful product shape:
describe a set of delegated agent tasks, run what can be parallel, wait for dependencies,
and synthesize the result. The weakness is that many implementations leave the actual
scheduler in prose. `Dependencies:` are labels the model reads, not edges the runtime
enforces. Read-vs-write safety is also left to human judgement or prompt convention.

Pixir already has the lower-level primitive needed for a stronger version: ADR 0011
Subagents are supervised child Sessions with explicit lifecycle tools, isolated
workspace snapshots by default, compact terminal summaries, and canonical
`subagent_event` evidence in the parent Log.

The open question is how much engine to add now. The earlier design note proposed a
larger `Pixir.Scheduler` with path-level write-set derivation, typed returns, and
possible future worktree merge-back. That is directionally right, but too large for a
first accepted surface.

## Decision

Pixir adds **Workflows** as a deterministic runtime plan over existing Subagents.

A Workflow contains ordered step definitions with:

- a safe unique step id;
- a task prompt;
- an Agent role;
- structural `depends_on` edges;
- a derived posture: `read_only` or `writer`;
- `read_set` and `write_set` path metadata;
- `workspace_mode`, defaulting to `shared` for read-only steps and `isolated` for
  writers.

`Pixir.Workflows` validates the graph before execution. Unknown dependencies and
dependency cycles fail early with ADR 0005 structured `:invalid_args` errors.

The scheduler is greedy and deterministic. A step becomes runnable only after all of its
dependencies have completed. Pixir starts as many runnable steps as fit under
`max_concurrency`, excluding any step that conflicts with already-running or same-wave
steps.

Conflict semantics are intentionally conservative:

- read-only steps have an empty write-set and may fan out together;
- writer/writer steps with overlapping write-sets serialize;
- shared-workspace writers conflict with readers whose read-set overlaps;
- isolated writers do not block readers because they mutate a child snapshot;
- a writer without an explicit write-set claims the whole workspace (`**/*`).

Execution routes through the Subagents manager; Workflows do not start Sessions or
Tasks directly. This preserves the single concurrency/lifecycle authority from ADR 0011:
the Manager still owns child Sessions, max thread enforcement, timeouts, lifecycle
events, timeout rearming after Manager restart, and terminal summaries.

Workflow execution passes step-specific Delegation Context into each child Turn through
the Subagents manager. The context may include workflow id and name, step id, wave,
dependencies, dependency summaries, read/write posture, workspace mode, and checkpoint
requirements. This makes structural workflow state visible to the child without relying
only on prose embedded in the task prompt.

After ADR 0028 and ADR 0029, Workflows also support an explicit `virtual_overlay`
step mode for bounded virtual shell work. A `virtual_overlay` step is the narrow
exception to the "over Subagents" execution rule: it runs Pixir's internal
BEAM-native virtual workspace runner directly, returns a `virtual_diff` checkpoint, and
does not open a child Session or mutate the parent Workspace. Full Subagent child
Sessions with model-visible virtual tools remain future work.

The model-facing surface is `run_workflow`, an ADR 0005-compliant Tool with `dry_run/2`.
It is permissioned as a mutation because it creates Subagent lifecycle state. In
`:read_only` mode it is denied; in `:ask` mode it asks; in `:auto` it runs.

Workflows v1 does **not** add a new canonical `workflow_event`. Durable evidence remains
the existing canonical `subagent_event` lifecycle entries recorded by ADR 0011, plus the
structured result returned to the caller. A future ADR may add durable workflow-level
events if Pixir needs mid-workflow resume, forkable workflow graphs, or audited workflow
decisions.

ADR 0032 later accepts that future direction as a minimal canonical `workflow_event`
type for durable Workflow run decisions. The v1 decision in this ADR remains the
implemented baseline until that follow-up runtime slice ships.

## Consequences

- Pixir gets a practical version of "Workflows" without importing prose queues or a
  second orchestration runtime.
- The user/model can express dependencies as edges instead of hoping a dispatcher obeys
  textual labels.
- Read-only fan-out is cheap and explicit, while overlapping writers are serialized
  before they can collide.
- Writers remain safe by default because they use isolated child snapshots.
- Results are still compact prose summaries, not schema-validated typed values. Typed
  outputs remain future work.
- Child workers can see their workflow role and dependency evidence as operational
  context while Workflows still avoid a new canonical `workflow_event` in v1.
- Merge-back from isolated writer snapshots remains future work. Workflows v1 can run
  writer subagents safely, but does not claim to automatically merge file changes back
  into the parent workspace.
- Whole-workflow resume is not guaranteed in v1. Parent Logs preserve child lifecycle
  facts, but an interrupted Workflow call itself is not yet a replayable canonical graph.
  ADR 0032 defines the minimal event spine needed for that future capability.

## Verification

The no-network verification surface is:

```bash
mix test test/pixir/workflows_test.exs test/pixir/tools_test.exs test/pixir/permissions_test.exs
mix pixir.smoke.workflows --dry-run --json
mix pixir.smoke.workflows --json
```

The smoke task proves the accepted contract: structural validation, parallel read-only
steps, serialized overlapping write-sets, dependency summary collection, and canonical
Subagent lifecycle evidence.

The real-network smoke surface is intentionally separate and should be run manually:

```bash
mix pixir.smoke.workflows_real --dry-run --json
mix pixir.smoke.workflows_real --scenario micro_parallel --json
mix pixir.smoke.workflows_real --scenario dependency --json
mix pixir.smoke.workflows_real --scenario writer_controlled --json
```

It writes durable local evidence under `.pixir/smoke/workflows-real/`, keeps dry-run
offline and no-write, and reports actionable JSON errors for known failure modes such
as subagent step timeouts and Provider transport failures.

## References

- ADR 0003: stateless Turns; local Log is source of truth.
- ADR 0004: unified Event envelope and canonical vs ephemeral events.
- ADR 0005: tool ergonomics, dry-run, structured errors, I/O discipline.
- ADR 0006: permissions and read-only posture.
- ADR 0011: BEAM-native Subagents as supervised child Sessions.
- ADR 0032: Minimal Workflow Events for durable run decisions.
- `docs/design/0001-subagent-scheduler-write-set-orchestration.md`.
