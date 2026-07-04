# 30. Virtual diffs require explicit apply and merge-back

Date: 2026-06-29
Status: Accepted
Implementation status: Design accepted; runtime apply remains a follow-up slice.

## Context

ADR 0028 defines `virtual_overlay` as a Workspace Strategy for BEAM-native
shell-shaped exploration and scratch edits. ADR 0029 defines the `virtual_diff`
artifact exported by that strategy. The artifact deliberately records
`apply.status: "not_applied"` so a virtual write cannot silently become a parent
Workspace mutation.

Issue #116 closes the remaining design gap: when Pixir eventually lets a user,
Workflow, or agent apply a `virtual_diff`, the operation needs one shared semantic
contract. Without that, CLI, Tool, and Workflow surfaces could grow incompatible rules
for permissions, dry-runs, conflicts, partial application, and Log evidence.

## Decision

Applying a `virtual_diff` is an explicit **Virtual Diff Apply** operation.

It is not part of `virtual_overlay` execution. A virtual overlay may produce a
reviewable artifact, but it never mutates the parent Workspace by itself. Parent
Workspace mutation requires a separate apply operation that is permissioned,
dry-runnable, workspace-confined, and auditable.

Pixir should implement one underlying apply engine and allow multiple front doors to
call it:

| Surface | Role |
| --- | --- |
| Tool | Model-visible, permissioned apply path during a Turn. |
| Workflow step | Structural orchestration wrapper around the same Tool/engine. |
| CLI command | Human/operator path for dry-run, review, and explicit apply. |

The surfaces may arrive in different implementation slices, but they must share the
same planning, permission, conflict, and result semantics. `virtual_overlay` itself
must continue to return `virtual_diff` with `apply.status: "not_applied"` until one of
those explicit surfaces is invoked.

The first implementation should prefer a small reusable apply module plus a
permissioned Tool surface. A CLI command can wrap the same module for human review.
A Workflow apply step should be a thin explicit step, not an implicit continuation of
the producing `virtual_overlay` step.

## Apply Input

The apply operation takes:

- a `virtual_diff` artifact or durable artifact reference;
- the target Workspace root;
- an optional file selection, if later supported;
- `dry_run`, defaulting to `true` for CLI and unspecified model-facing calls;
- an explicit mutation request such as CLI `--apply` or Tool `dry_run: false`;
- the active permission mode and Workspace confinement policy.

The artifact must include enough preimage evidence to protect the parent Workspace.
For v0, applicable file changes require:

- path confined to the target Workspace after resolving `.`/`..` segments and
  symlinks to a canonical path;
- `operation` of `add`, `modify`, or `delete`;
- `before.sha256` for `modify` and `delete`;
- `after.sha256` and bounded text content or a reconstructable text patch for `add`
  and `modify`;
- `diff.truncated: false`;
- no caveat that marks the file unsafe to apply.

`unsupported`, binary, truncated, or caveated changes are reviewable evidence but not
automatically applicable in v0.

## Permission Gates

Virtual Diff Apply follows ADR 0006:

| Permission mode | Dry-run behavior | Mutating behavior |
| --- | --- | --- |
| `:read_only` | Allowed; reports the plan. | Denied with structured `:permission_denied` or the current canonical equivalent. |
| `:ask` | Allowed without prompting. | Prompts through the normal permission asker and records `permission_decision`. |
| `:auto` | Allowed. | Allowed after the explicit apply operation is invoked. |

Workspace confinement remains the floor in every mode. Apply must check confinement
against canonical, resolved paths rather than raw input strings. `.`/`..` segments and
symlinks are resolved before comparing with the target Workspace root, so an in-tree
symlink cannot escape the Workspace. Paths outside the Workspace are refused, not
prompted.

Even in `:auto`, apply is never automatic. The user, model, CLI command, or Workflow
spec must explicitly request the apply operation after reviewing or choosing to trust
the `virtual_diff`.

## Conflict Semantics

Apply is optimistic and hash-checked.

For each change:

| Operation | Precondition |
| --- | --- |
| `add` | Target path does not exist. |
| `modify` | Target path exists and its SHA-256 matches `before.sha256`. |
| `delete` | Target path exists and its SHA-256 matches `before.sha256`. |

If a precondition fails, the file is a conflict. Conflict output must identify the
path, expected state, observed state, and safe next action. The operation should not
attempt a three-way merge in v0; richer merge behavior belongs to future work or the
`git_worktree` strategy.

## Partial Apply Semantics

v0 apply is all-or-nothing.

The apply engine first builds an apply plan. If any selected change is conflicted,
unsupported, outside the Workspace, truncated, unsafe, or unreconstructable, a mutating
apply makes no file changes and returns a structured non-applied result.

Partial apply may be accepted later only with explicit file selection, per-file audit
evidence, and result data that clearly distinguishes `applied`, `skipped`,
`conflicted`, and `unsupported` files. Until then, avoiding partial mutation is more
important than applying a convenient subset.

## Result And Audit Evidence

Virtual Diff Apply returns a structured result, whether dry-run or mutating. It should
include at least:

- `kind: "virtual_diff_apply"`;
- `version`;
- `dry_run`;
- `status`: `planned`, `applied`, `not_applied`, `conflicted`, `denied`, or `failed`;
- artifact identity or hash;
- target Workspace identity;
- counts for selected, applicable, applied, conflicted, unsupported, and skipped files;
- per-file outcomes and precondition evidence;
- elapsed time and bounded output metadata.

When apply runs during a Session Turn, the durable audit surface is the existing
canonical `tool_call` and `tool_result` Event pair. If `:ask` mode prompts, the
existing canonical `permission_decision` Event records the gate. This ADR does not add
a new canonical Event type.

If a future CLI apply runs outside a Session, it should still emit the same structured
result to the machine-readable channel. A later ADR may define standalone local audit
records for out-of-Session CLI mutations, but that is not required for the first
Session-bound apply implementation.

## Workspace Strategy Interactions

| Strategy | Apply relationship |
| --- | --- |
| `shared` | Apply mutates the same real Workspace and must be permissioned like any write. |
| `isolated` | Apply from an isolated snapshot remains out of scope; use explicit artifacts or future merge-back design. |
| `virtual_overlay` | Produces `virtual_diff`; never applies it automatically. |
| future `git_worktree` | Intended repo-change strategy with branch/worktree lifecycle; ADR 0031 defines its selection and lease model. |

Virtual Diff Apply should use Pixir Workspace/file primitives and BEAM file I/O.
Those primitives must resolve canonical paths before enforcing confinement, including
symlink resolution. The default path must not shell out to `git apply`, `/bin/bash`,
`patch`, or other host commands. If a future implementation offers a host-backed apply
mode, that is a Host Boundary Crossing under ADR 0027 and must be explicitly named,
bounded, and observable.

## Consequences

- `virtual_overlay` remains safe for read/scratch work because it cannot mutate the
  parent Workspace by completion alone.
- Humans and agents can review `virtual_diff` artifacts before applying them.
- Future implementation can add apply without inventing permission, conflict, and audit
  semantics in code review.
- Hash-checked all-or-nothing v0 behavior avoids silent overwrites and confusing
  partial states.
- Git-aware merge-back remains a separate design problem instead of being smuggled into
  virtual overlays.

## Non-goals

- Do not implement Virtual Diff Apply in this ADR.
- Do not define full `git_worktree` merge-back behavior.
- Do not add typed Workflow outputs.
- Do not add a canonical `workflow_event` or `virtual_diff_apply` Event type.
- Do not make `virtual_overlay` the default workspace strategy.
- Do not support automatic three-way merge in v0.

## Verification Direction

The design slice should pass:

```bash
git diff --check docs/adr CONTEXT.md AGENTS.md
mix format --check-formatted
mix compile --warnings-as-errors
```

Future implementation checks should prove:

- dry-run returns a complete apply plan and mutates no files;
- `:read_only` denies mutating apply;
- `:ask` records a `permission_decision` when a mutating apply is approved or denied;
- `:auto` applies only after an explicit apply call;
- modify/delete conflicts are detected by `before.sha256`;
- add conflicts when the target path already exists;
- unsupported, binary, truncated, caveated, and outside-Workspace changes do not mutate
  files;
- v0 apply is all-or-nothing;
- successful apply records durable `tool_call` and `tool_result` evidence;
- default apply does not use host commands.

## References

- ADR 0004: unified Event envelope and canonical vs ephemeral events.
- ADR 0005: Agent ergonomics, dry-run, structured errors, and I/O discipline.
- ADR 0006: Permission model.
- ADR 0014: Workflow Checkpoint Bundles and honest partial outcomes.
- ADR 0027: External command execution as a bounded host boundary.
- ADR 0028: Workspace Strategies and future virtual overlays.
- ADR 0029: Virtual overlays export `virtual_diff` artifacts.
- ADR 0031: Git worktrees as lease-owned strategy for intended repo changes.
- Issue #116: Decide explicit apply and merge-back semantics for virtual diffs.
