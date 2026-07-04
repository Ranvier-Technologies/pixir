# 35. Write-capable Sessions require an external evidence mirror

Date: 2026-07-02
Status: Accepted
Implementation status: Decision documented; the Executor has defense-in-depth guards,
but runtime mirror implementation remains a follow-up slice.

## Context

ADR 0003 makes the workspace-local Session Log the source of truth. Today that Log lives
under `<workspace>/.pixir/sessions/`, and existing `resume`, `tree`, `diagnose`, ACP
load/resume, Subagents, Workflows, and local dogfood evidence all assume that location.

That design is appropriate for read-only and developer-preview work, but Fable's
write-capable dogfood exposed a sharper audit risk: if the same executor that mutates a
repository can also mutate or remove `.pixir`, it can destroy the evidence needed to
audit what happened. PR #162 added a hard Executor guard that refuses direct tool
mutation of `.pixir`, but storage policy still needs a decision before Pixir claims
write-capable executor safety.

The main alternatives were:

- keep only workspace-local `.pixir/sessions`;
- move all Logs to user-global `~/.pixir`;
- keep workspace-local Logs and mirror write-capable evidence to user-global state;
- export an evidence bundle only after a run completes.

## Decision

Pixir keeps the workspace-local `.pixir/sessions` Log as the canonical runtime Log and
compatibility path, but any future write-capable Session, Turn, Delegate run, Subagent,
or Workflow step must also write an external evidence mirror outside the active
Workspace.

The decision is keyed by effective capability, not by Presenter:

- read-only execution may rely on the workspace-local Log;
- write-capable execution requires a mirror;
- Subagents inherit the requirement when their effective permission posture can write;
- Workflows require a mirror when any step can write;
- CLI, ACP, T3/Zed adapters, and resident BEAM/daemon entrypoints all follow the same
  Harness policy.

The external mirror is audit/retention evidence, not a second semantic source of truth.
It should live under user-global Pixir state, for example
`~/.pixir/projects/<workspace-hash>/...`, and copy or append the same durable evidence
needed to reconstruct the run if the workspace-local `.pixir` tree is later damaged.

For write-capable execution, mirror initialization is a preflight requirement. If Pixir
cannot initialize the mirror, it must reject the write-capable posture with a structured
error before provider work or mutation. If the mirror fails after write-capable work has
started, Pixir should mark the run audit-degraded and refuse further mutations until the
operator chooses how to proceed.

## Consequences

- Existing read-only and developer-preview flows keep working through
  `.pixir/sessions`, `resume`, `tree`, and `diagnose`.
- Write-capable executor work gains evidence outside the directory being edited, without
  migrating all runtime state at once.
- The mirror must be implemented at the Harness/Log or Session boundary, not as a CLI
  shell wrapper, because Pixir has multiple entrypoints and may run as a resident BEAM
  runtime.
- The mirror does not remove the need for the `.pixir` protected-path guard. The guard
  prevents direct self-evidence destruction; the mirror provides an external audit copy.
- Future diagnostics should report evidence locality and mirror health so operators know
  whether a run is fully auditable or audit-degraded.

The current Executor guard is intentionally a floor, not the final safety model. It
denies direct `write`/`edit` targets under the canonicalized project `.pixir` root,
literal destructive or redirecting shell references to `.pixir`, and `git clean`
ignored-file modes that can remove the gitignored state tree. The Bash tool separately
rejects parent-directory shell path tokens before host execution. Protected-path
denials are recorded as durable `permission_decision` and `tool_result` evidence. This
still does not cover every way a host program could compute or corrupt a Log path after
crossing the shell boundary, nor any tool path that bypasses `Pixir.Tools.Executor`.
Those gaps are exactly why write-capable execution still requires the external mirror
described by this ADR.

## Non-goals

- This ADR does not implement evidence mirroring.
- This ADR does not move read-only Logs out of the Workspace.
- This ADR does not make the mirror a replacement for the canonical Log or History fold.
- This ADR does not add cloud storage, remote attestation, signing, or immutable object
  storage.
- This ADR does not define write-capable Delegate policy; issue #156 owns bounded write
  authorization.

## Verification Direction

Implementation slices after this ADR should prove:

- write-capable preflight fails before provider work when the mirror cannot initialize;
- read-only Sessions remain compatible with workspace-local `.pixir/sessions`;
- mirrored evidence can reconstruct or diagnose a write-capable run after local
  `.pixir` is unavailable;
- mirror failures after startup are visible as structured audit-degraded evidence;
- Subagents and Workflows apply the requirement based on effective write capability,
  not on which Presenter started them.

## References

- ADR 0003: stateless Turns; local Log is source of truth.
- ADR 0005: agent ergonomics, structured errors, and I/O discipline.
- ADR 0006: permission model and workspace confinement.
- ADR 0027: external command execution as a bounded host boundary.
- ADR 0034: Delegate service mode requires explicit runtime residency.
- Issue #133: Subagents as a Service v1.
- Issue #155: Delegate evidence placement policy before write-capable execution.
- Issue #156: Headless bounded write policy for Pixir executor mode.
- Issue #158: Protect Pixir runtime evidence and tighten executor workspace scope.
