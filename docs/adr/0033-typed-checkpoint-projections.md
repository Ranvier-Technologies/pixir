# 33. Typed checkpoint outputs are harness-owned projections

Date: 2026-06-30
Status: Accepted
Implementation status: Minimal Checkpoint Bundle v2 runtime projection implemented;
schema registry and template-declared typed payloads remain follow-up work.

## Context

ADR 0012 introduced Workflows as deterministic structural orchestration over
Subagents. ADR 0014 added Step Outcomes, Checkpoint Bundles, and honest partial
Workflow outcomes, while explicitly deferring typed outputs. Since then, Pixir has
accepted virtual diff artifacts (ADR 0029), explicit apply semantics (ADR 0030),
lease-owned Git worktrees as a future strategy (ADR 0031), and a minimal durable
Workflow event spine (ADR 0032).

The remaining design question is not whether Pixir should expose machine-readable
Workflow evidence. It should. The question is where that structure belongs.

Pixir Subagents are not just model messages that happen to return text. They are child
Sessions inside a local-first Harness. They have Logs, Tool results, artifacts,
Subagent lifecycle evidence, Workflow decisions, and summaries. Turning every
Subagent answer into required strict JSON would overfit to model output formatting and
make routine human-readable summaries brittle. It would also duplicate deterministic
evidence that Pixir already owns through the Harness.

Typed output therefore needs to preserve the key distinction:

- prose remains prose unless a Workflow Template or step explicitly asks for a typed
  model declaration;
- deterministic runtime evidence should be projected by Pixir from Logs, Tool
  results, artifacts, and Workflow decisions;
- typed payloads should exist where downstream runtime decisions, dependency
  unlocking, replay repair, diagnostics, or presenter behavior need stable structure.

## Decision

Pixir accepts **Typed Checkpoint Outputs** as harness-owned checkpoint projections, not
as a global requirement that Subagents or models answer in JSON.

A Typed Checkpoint Output is an optional machine-readable payload or artifact
reference attached to a Workflow Checkpoint Bundle. The Workflow runtime may use it to
unlock dependents, hold dependents, repair replay, render diagnostics, or explain safe
next actions. It is not the primary final answer format for ordinary agent prose.

### Checkpoint Bundle V2 Direction

The first runtime slice should evolve Checkpoint Bundles toward a versioned envelope
that can carry typed payloads without replacing the existing summary and verification
fields:

```json
{
  "version": 2,
  "step_id": "analyze",
  "status": "checkpoint_ready",
  "dependent_safe": true,
  "summary": "Short human-readable summary.",
  "known_limitations": [],
  "verification": {
    "source": "harness_projection"
  },
  "typed_payloads": [
    {
      "schema_id": "test_evidence.v1",
      "provenance": "tool_result",
      "validation": {
        "status": "valid",
        "validated_at": "runtime"
      },
      "payload": {
        "command": "mix test test/pixir/workflows_test.exs",
        "status": "passed",
        "exit_code": 0
      }
    }
  ],
  "artifacts": [
    {
      "kind": "virtual_diff",
      "artifact_id": "sha256:...",
      "provenance": "artifact"
    }
  ]
}
```

The exact key names may be refined during implementation, but the semantic contract is
stable:

- Checkpoint Bundles remain the dependency-safety envelope from ADR 0014.
- Typed payloads are optional.
- A human-readable `summary` remains present and useful.
- Typed payloads may be embedded when small and bounded, or referenced when large.
- Artifact contracts such as `virtual_diff` remain their own contracts; typed
  checkpoints reference them instead of reshaping them.

### Provenance

Each typed payload or typed artifact reference must declare provenance. Initial
provenance values are:

| Provenance | Meaning |
| --- | --- |
| `harness_projection` | Pixir derived the payload by folding owned runtime state such as Step Outcomes, child lifecycle, limits, or summaries. |
| `tool_result` | Pixir derived the payload from a Tool result whose shape is owned by Pixir. |
| `artifact` | The typed item references a structured artifact such as `virtual_diff`, future `virtual_diff_apply`, or future `git_worktree_result` by kind, version, id, hash, or location. It does not inline the artifact body as a typed payload. |
| `workflow_event_fold` | Pixir derived the payload by folding canonical `workflow_event` evidence. |
| `model_declared` | A model or Subagent summary declared a typed value because a Workflow Template or step explicitly requested it. Pixir may validate shape, but not truth, from prose alone. |

Provenance is not decorative metadata. It tells downstream consumers how much trust the
payload deserves and what can be reconstructed during replay. Deterministic provenance
can support runtime decisions. `model_declared` payloads require stricter template
contracts before they can unlock dependents.

For typed payloads, `artifact` provenance is reference-oriented. A Checkpoint Bundle may
still carry a separate artifact entry, and today's runtime may embed small artifact
objects in existing bundle fields, but the typed payload contract should point at the
artifact contract rather than copy or rename it.

### First Useful Payload Kinds

The initial typed-output implementation should stay small. Useful early schema ids are:

| Schema id | Source | Purpose |
| --- | --- | --- |
| `test_evidence.v1` | `tool_result` or future `git_worktree_result` | Record command, status, exit code, elapsed time, and bounded failure summary for dependency decisions. |
| `artifact_ref.v1` | `artifact` | Reference large structured artifacts by kind, version, hash, and storage location without duplicating them inside checkpoints. |
| `workflow_checkpoint.v1` | `harness_projection` or `workflow_event_fold` | Summarize checkpoint status, dependent safety, limitations, and safe next actions for replay repair and diagnostics. |

`analysis_findings.v1` may be accepted later, but it should be treated carefully:
findings are useful for presenter and orchestrator decisions, yet many findings are
model-authored judgments rather than deterministic facts. They should not become a
generic JSON wrapper for every Subagent answer.

### Validation And Failure Semantics

Validation rules follow the same split between Workflow specification errors and
agentic outcomes used by ADR 0014.

Invalid Workflow specs, schema declarations, impossible schema references, or malformed
typed-output requirements are Tool errors with `:invalid_args`.

Invalid produced payloads are Workflow evidence, not automatically Tool errors:

- if the step produced useful evidence but the optional typed payload is invalid, the
  step can become `partial` with a validation limitation;
- if a required typed-output payload is invalid and dependents need it, the step becomes
  `needs_orchestrator` or its dependents are held;
- if deterministic validation proves a payload unsafe, dependents must not unlock from
  it;
- if only a `model_declared` payload is available, Pixir may validate shape but should
  not treat the payload as truth without template-specific acceptance rules.

Validation should be deterministic wherever the source is deterministic:
`harness_projection`, `tool_result`, `artifact`, and `workflow_event_fold`. A later
implementation may add schema modules, but v0 can start with local validators for a
small set of schema ids instead of introducing a broad schema registry.

### Relationship To Workflow Events

`workflow_event` records durable decisions. It may reference typed payload schema ids,
payload hashes, artifact ids, checkpoint ids, and validation status when those facts
are part of a scheduling or checkpoint decision.

`workflow_event` should not carry large typed payloads by default. Large or detailed
payloads belong in the final `tool_result`, Checkpoint Bundle, Session Resource, or
artifact storage. Events should keep the durable run spine compact and replayable.

### Relationship To Subagent Results

Subagent terminal summaries remain human-readable. Pixir may still ask a child to
include markers such as `checkpoint_status: checkpoint_ready`, but the typed-output
contract does not require every child to emit strict JSON.

When a Subagent completes, the Workflow runtime should build typed checkpoint evidence
from Harness-owned sources first:

- child Session id and lifecycle status;
- Tool results in the child Log, when available and selected by the Workflow runtime;
- structured artifacts such as `virtual_diff`;
- final summary and checkpoint marker;
- durable `workflow_event` decisions, once implemented.

Model-authored JSON is allowed only when a Workflow Template or step explicitly
declares that output contract. Even then, it is `model_declared` until Pixir can
validate it against deterministic evidence.

### Relationship To Artifacts

Typed checkpoints should reference structured artifacts instead of flattening or
renaming them.

`virtual_diff` remains the artifact contract from ADR 0029. A Checkpoint Bundle may
embed it while it is small, or reference it through `artifact_ref.v1` when storage
becomes durable. A future `git_worktree_result` should likewise remain a worktree
strategy result and be referenced by typed checkpoints rather than becoming the
checkpoint envelope itself.

## Consequences

- Pixir gets machine-readable Workflow evidence without making every Subagent response
  brittle JSON.
- Checkpoint Bundles become the stable handoff between agentic work and deterministic
  Workflow scheduling.
- Presenters can keep readable summaries while advanced consumers inspect structured
  payloads when present.
- Replay repair and diagnostics gain deterministic attachment points for future
  `workflow_event` folds.
- `virtual_diff`, future apply results, and future worktree results can participate in
  typed checkpoints without losing their own artifact semantics.
- The runtime must eventually distinguish validation failure from step failure and
  preserve useful evidence as `partial` instead of collapsing it into a Tool error.

## Non-goals

- Do not require every model or Subagent answer to be strict JSON.
- Do not remove or devalue human-readable summaries.
- Do not replace Checkpoint Bundles, Workflow Events, Tool results, or artifacts.
- Do not add a broad public schema registry in the first slice.
- Do not define full typed outputs for every Workflow Template.
- Do not add automatic merge-back, apply, PR publication, or Git worktree allocation.

## Verification Direction

The design slice should pass:

```bash
git diff --check docs/adr CONTEXT.md AGENTS.md
mix format --check-formatted
mix compile --warnings-as-errors
```

Future implementation checks should prove:

- Checkpoint Bundles can carry versioned optional typed payloads while preserving
  summaries and verification fields;
- invalid typed-output requirements return structured `:invalid_args` Tool errors;
- invalid optional payloads produce `partial` Workflow evidence instead of losing
  useful work;
- invalid required payloads hold dependents or produce `needs_orchestrator`;
- deterministic payloads are validated without parsing arbitrary prose;
- `model_declared` payloads are shape-validated and clearly marked as lower trust;
- `virtual_diff` appears as an artifact or artifact reference, not a reshaped payload;
- future `workflow_event` payloads reference hashes or ids rather than large typed
  payloads.

The initial runtime slice implements versioned Checkpoint Bundles with
`workflow_checkpoint.v1` typed payloads and `artifact_ref.v1` references for
`virtual_diff`, while preserving existing summary, verification, and compatibility
fields. It does not add a public schema registry, parse arbitrary model JSON, or add
template-declared typed payload contracts.

## References

- ADR 0004: unified Event envelope and canonical vs ephemeral events.
- ADR 0005: Tool ergonomics and structured errors.
- ADR 0011: BEAM-native Subagents as supervised child Sessions.
- ADR 0012: Workflows are structural orchestration over Subagents.
- ADR 0014: Workflow Checkpoint Bundles and honest partial outcomes.
- ADR 0029: Virtual overlays export `virtual_diff` artifacts.
- ADR 0031: Git worktrees are lease-owned strategy for intended repo changes.
- ADR 0032: Minimal Workflow Events for durable run decisions.
- Issue #118: Design typed outputs for Workflow checkpoints and Subagent results.
