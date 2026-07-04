# 28. Workspace strategies separate physical isolation from virtual overlays

Date: 2026-06-29
Status: Accepted
Implementation status: Internal virtual overlay runner implemented; explicit Workflow
step opt-in is implemented; Subagent child Session virtual toolsets remain a follow-up
slice.

## Context

ADR 0011 made isolated Subagent workspaces safe by default. ADR 0012 made Workflow
steps choose between `shared` and `isolated` workspace modes. ADR 0027 then separated
cheap BEAM fanout from scarce host-boundary crossings.

Issue #100 and issue #107 showed that physical isolation is not the only workspace
shape Pixir needs. A bounded physical snapshot is now fast enough for the current repo,
but not every Subagent needs real files, real `git`, real `mix`, real `node`, or a
future branch-backed worktree. Some Subagents need shell-shaped file exploration or
scratch edits while staying inside BEAM.

The Elixir `just_bash` project, referred to here as Bashex to avoid confusion with the
Vercel TypeScript project of the same name, is a plausible engine for that shape. It
provides a BEAM-native bash-like interpreter, an in-memory filesystem, resource limits,
execution stats, network-off-by-default behavior, and common commands such as `find`,
`grep`, `sed`, `jq`, and `diff`. Bashex custom commands are trusted host-side
extensions, so they are not part of the safe default.

## Decision

Pixir treats workspace handling as an explicit **Workspace Strategy**, not merely as a
path copied into a child Session.

The strategy taxonomy is:

| Need | Strategy |
| --- | --- |
| No file access | `context_only` child Turn |
| Read-only source exploration | `shared` workspace with read-only permissions |
| Shell-shaped context retrieval or scratch edits | explicit Workflow-step `virtual_overlay` |
| Suggested changes without host deps | `virtual_diff`, file artifact, or patch artifact |
| Disposable real-file writes | `isolated` bounded physical snapshot |
| Intended repo changes and merge-back | future `git_worktree` / branch-backed workspace |
| Real build/test/toolchain execution | host command path through Tools and `CommandBoundary` |

Pixir keeps the existing `workspace_mode` field for compatibility. Subagents accept
`shared` and `isolated`. Workflow steps also accept explicit `virtual_overlay` when
the step provides a bounded `read_set` and explicit `virtual_commands`.

The current `virtual_overlay` strategy:

- import only selected parent files, normally from Workflow `read_set` or an equivalent
  explicit resource selection;
- run shell-shaped commands against a BEAM-native virtual filesystem;
- allow writes only inside the virtual filesystem;
- export the structured `virtual_diff` artifact specified by ADR 0029 instead of
  mutating the parent workspace silently;
- expose fidelity limits in Delegation Context;
- keep host process execution unavailable unless the task moves to a real Tool path
  governed by ADR 0027.

`spawn_agent` does not yet accept `virtual_overlay`. A full Subagent virtual overlay
surface needs a child Session with a model-visible virtual toolset and virtual
filesystem lifecycle, which is deliberately out of this slice.

Model-visible Delegation Context for virtual overlays should say, at minimum:

- `workspace_mode: "virtual_overlay"`;
- `workspace_fidelity: "virtual_shell_no_host_binaries"`;
- the existing host-boundary rule: "OTP fanout yes; OS-boundary fanout carefully
  bounded."

Useful observability fields include imported file count and bytes, virtual command
count, virtual diff file count and bytes, Bashex stats (`steps`, `output_bytes`,
`max_exec_depth`), limits profile, elapsed time, and fidelity caveats.

## Consequences

- Pixir can use a cheap BEAM-native middle strategy between read-only shared workspaces
  and physical isolated snapshots.
- The architecture does not promise that virtual shell execution is equivalent to a real
  host shell.
- `virtual_overlay` can support read/scratch tasks without increasing host-boundary
  crossings per useful work unit.
- Bashex may be a good implementation engine, but Pixir's public contract remains
  Workspace Strategy, permissions, audit, and fidelity limits.
- Real builds, tests, package managers, compilers, and host CLIs still belong behind
  Tools and `CommandBoundary`, not inside the virtual overlay.

## Non-goals

- Do not make `virtual_overlay` the default workspace mode.
- Do not replace bounded isolated snapshots.
- Do not enable `virtual_overlay` for `spawn_agent` until a child Session virtual
  toolset is designed.
- Do not claim virtual overlays can run real `mix`, `git`, `node`, shells, compilers,
  tests, or arbitrary host binaries.
- Do not enable Bashex custom commands by default; they are trusted host-side
  extensions.
- Do not use a Node bridge or spawn an external shell for virtual overlay commands.

## Verification Direction

The design slice should pass documentation checks:

```bash
git diff --check docs/adr CONTEXT.md AGENTS.md
mix format --check-formatted
mix compile --warnings-as-errors
```

The implementation slice should prove:

- `virtual_overlay` imports a bounded read set into a virtual filesystem.
- Virtual `find`, `grep`, `sed`, `jq`, and `diff` work without `System.cmd/3`,
  `Port.open/2`, `:os.cmd/1`, `git`, `node`, or a host shell in the virtual command
  path.
- Network is disabled by default.
- Custom host-side Bashex commands are not enabled by default.
- The result includes virtual diff/audit metadata and Bashex execution stats.
- Delegation Context clearly communicates virtual fidelity limits.
- Workflow-step `virtual_overlay` returns `virtual_diff` with `apply.status:
  "not_applied"` and no parent Workspace mutation.
- Future parent Workspace mutation uses the explicit apply/merge-back semantics in ADR
  0030 rather than extending `virtual_overlay` completion.
- Future branch-backed repository changes use the worktree avoidance and lease model in
  ADR 0031.

A local feasibility spike on 2026-06-29 imported four Pixir files into Bashex, ran
virtual `find`, `grep`, `sed`, `jq`, and `diff`, recorded execution stats, and confirmed
process substitution `<(...)` is not supported.

## References

- Issue #108: Design virtual workspace strategy for Subagents.
- Issue #100: Harden Subagent manager crash recovery, mailbox pressure, and delegation
  context.
- Issue #107: Bound isolated Subagent workspace snapshots.
- ADR 0011: BEAM-native Subagents.
- ADR 0012: Structural Workflows over Subagents.
- ADR 0027: External command execution as a bounded host boundary.
- ADR 0029: Virtual overlays export `virtual_diff` artifacts.
- ADR 0030: Explicit `virtual_diff` apply and merge-back.
- ADR 0031: Git worktrees as lease-owned strategy for intended repo changes.
- `elixir-ai-tools/just_bash`: https://github.com/elixir-ai-tools/just_bash
