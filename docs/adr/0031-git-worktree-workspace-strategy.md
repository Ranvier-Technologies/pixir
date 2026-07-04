# 31. Git worktrees are lease-owned strategy for intended repo changes

Date: 2026-06-30
Status: Accepted
Implementation status: Design accepted; runtime implementation remains a follow-up
slice.

## Context

ADR 0028 defines Workspace Strategies and keeps branch-backed worktrees as a future
direction. ADR 0030 defines explicit apply semantics for `virtual_diff` artifacts.
Issue #117 closes the next design gap: when should Pixir allocate a real Git worktree
instead of returning a cheaper artifact or using an existing workspace strategy?

The risk is overfitting to agent habits from systems where every task starts by
creating a checkout. Pixir's advantage is not that it can create many real worktrees;
it is that many Subagents, Workflow steps, and scratch operations can stay BEAM-native
or artifact-shaped until real host toolchain behavior is materially needed.

## Decision

Pixir accepts `git_worktree` as a future explicit Workspace Strategy for intentional
repository mutation, but treats it as expensive evidence, not a default workspace
convenience.

### Worktree Avoidance Rule

Before allocating a `git_worktree`, Pixir should ask whether the task can be satisfied
by a bounded reviewable artifact:

- file artifact;
- `virtual_diff`;
- git patch artifact;
- summary plus explicit next action.

If the task does not need real host dependencies, real build/test/toolchain execution,
Git merge behavior, commits, branches, or PR lifecycle, Pixir should prefer the cheaper
artifact path. Most proposed code changes can start as `virtual_diff` or patch evidence
and only graduate to `git_worktree` when validation, branch ownership, or publication is
actually required.

The selection ladder is:

| Need | Preferred strategy |
| --- | --- |
| No file access | `context_only` child Turn |
| Read-only source exploration | `shared` read-only |
| Shell-shaped text exploration or scratch edits without host binaries | `virtual_overlay` |
| Suggested change without host deps | `virtual_diff`, file artifact, or patch artifact |
| Disposable real-file writes or real host-tool validation | `isolated` |
| Intended persistent repo change with branch/commit/PR lifecycle | `git_worktree` |

`git_worktree` is opt-in. It is never the default for explorer Subagents, read-only
Workflow steps, or text-only patch proposals.

### When To Use `git_worktree`

Use `git_worktree` when one or more of these are true:

- the work is intended to become a persistent repository change;
- the task needs a branch, commit, PR, or review lifecycle;
- real dependency/toolchain behavior matters, such as `mix`, `git`, `node`, package
  managers, compilers, tests, formatters, or code generators;
- Git conflict or merge behavior is part of the evidence;
- the expected output is not merely a suggested patch but a publishable branch state.

Do not use `git_worktree` for simple exploration, summaries, read-only inspection,
scratch transforms, or text-only change proposals that can be represented as
`virtual_diff` or a patch artifact.

## Lease Model

Every `git_worktree` allocation should create a **worktree lease**. The lease ties a
branch-backed physical workspace to its owner and cleanup policy.

Minimum lease fields:

- `lease_id`;
- `owner_session_id`;
- `owner_subagent_id` and/or `workflow_id` / `workflow_step_id`, when applicable;
- `workspace_strategy: "git_worktree"`;
- `parent_workspace`;
- `base_ref` and `base_sha`;
- `branch`;
- `worktree_path`;
- `created_at`;
- `status`: `active`, `completed`, `abandoned`, `cleanup_ready`, or `cleanup_blocked`;
- `cleanup_policy`;
- `host_boundary_summary`.

The lease should be durable or recoverable enough for later diagnostics and cleanup.
An implementation may persist the lease directly, derive it from Log/tool evidence, or
combine both, but it must not require volatile process memory to know whether a
worktree is safe to inspect or clean up after restart.

Branch names should be collision-safe and owner-shaped, for example:

```text
pixir/<issue-or-session-short>/<purpose-slug>-<short-nonce>
```

The exact naming algorithm is implementation detail, but the result must avoid
colliding with user branches and must be visible enough for a human to identify why it
exists.

Worktree paths should live under an explicit Pixir-controlled worktree root, not inside
arbitrary user directories. Paths must be canonicalized before use, including
resolution of `.`/`..` segments and symlinks. After canonicalization, allocation and
cleanup must verify that the resolved worktree path is still contained by the
configured Pixir worktree root. Any path that escapes that root is refused before it is
created, inspected, used, or cleaned up.

## Dirty State And User Edits

Pixir must protect worktrees as user-editable real repositories.

Rules:

- do not reuse an existing dirty or unknown worktree for a new lease;
- do not delete a worktree with uncommitted changes, untracked files, or unknown Git
  state;
- do not silently reset, clean, checkout, rebase, or force-push worktree state;
- cleanup must be explicit and dry-runnable;
- cleanup output must distinguish `clean`, `dirty`, `unknown`, `committed`, and
  `cleanup_blocked` states;
- parent Workspace mutation remains separate from worktree completion.

If a user edits inside a Pixir-created worktree, Pixir should report that fact as
dirty/unknown evidence and stop short of destructive cleanup. A later explicit cleanup
or reconciliation operation may be accepted, but v0 must bias toward preserving user
work.

## Merge-Back And Publication

`git_worktree` does not imply automatic merge-back to the parent Workspace.

The v0 output should be a structured result that makes the branch state reviewable:

- `kind: "git_worktree_result"`;
- `version`;
- `lease_id`;
- `branch`;
- `worktree_path`;
- `base_ref`;
- `base_sha`;
- `head_sha`;
- `dirty_state`;
- `diff_stats`;
- `commits`;
- `test_evidence`;
- `host_boundary_summary`;
- `recommended_next_action`: `review_diff`, `commit_changes`, `open_pr`, `ask_user`,
  `cleanup`, or `abandon`.

If the workflow opens a PR in a future slice, that is a publication step layered on top
of the worktree result. PR creation, reviewer assignment, CI waiting, and merge remain
separate explicit operations. Automatic merge to parent or default branch is out of
scope for v0.

## Host Boundary Accounting

`git_worktree` necessarily crosses the host boundary. Commands such as `git worktree`,
`git status`, `git diff`, `git commit`, `mix`, `node`, and test runners are host-visible
work under ADR 0027.

The worktree strategy must therefore report host-boundary evidence separately from BEAM
coordination evidence. Useful fields include:

- command family counts, especially `git`, language toolchain, package manager, and
  test runner;
- elapsed time;
- timeouts;
- backpressure or queue delay;
- bytes read/written when available;
- whether commands ran through the normal Pixir Tool/Executor boundary.

Worktree fanout should be separately bounded from Subagent fanout. A Workflow may have
many BEAM steps, but should not casually allocate many active Git worktrees or spawn
many host toolchains in parallel.

## Delegation Context

Child agents using `git_worktree` should see explicit workspace fidelity and ownership
language.

Minimum wording:

```text
workspace_mode: "git_worktree"
workspace_fidelity: "real_git_worktree"
worktree_lease_id: "<lease-id>"
branch: "<branch>"
base_sha: "<sha>"
host_boundary_rule: "OTP fanout yes; OS-boundary fanout carefully bounded."
merge_back: "No automatic parent merge. Produce branch/diff/test evidence and wait for an explicit publish/apply/merge decision."
cleanup_rule: "Do not reset, clean, delete, or force-push without explicit instruction."
```

The child should understand that writes happen in the worktree, not directly in the
parent Workspace. Completion means producing reviewable branch evidence, not silently
changing the parent.

## Consequences

- Pixir preserves cheaper strategies for the common case where a patch artifact or
  `virtual_diff` is enough.
- Worktree sprawl becomes a first-class lifecycle concern instead of incidental local
  filesystem debris.
- Host command pressure becomes visible and bounded.
- Branch-backed Subagents can eventually support real build/test/PR workflows without
  changing the semantics of `virtual_overlay` or `isolated`.
- ADR 0033 gives future typed checkpoint outputs a natural way to reference branch,
  diff, dirty-state, and test evidence from `git_worktree_result` without making the
  worktree result itself the checkpoint envelope.

## Non-goals

- Do not implement `git_worktree` runtime allocation in this ADR.
- Do not make `git_worktree` the default for explorer Subagents.
- Do not define automatic parent merge-back.
- Do not define GitHub PR automation.
- Do not decide `workflow_event` durability.
- Do not replace `virtual_diff` apply semantics from ADR 0030.
- Do not require every code proposal to become a real branch.

## Verification Direction

The design slice should pass:

```bash
git diff --check docs/adr CONTEXT.md AGENTS.md
mix format --check-formatted
mix compile --warnings-as-errors
```

Future implementation checks should prove:

- worktree allocation is explicit and never used for read-only explorer tasks;
- tasks that can return artifacts avoid worktree allocation;
- leases include owner, branch, worktree path, base SHA, and cleanup policy;
- branch and path collisions are handled without overwriting user state;
- resolved worktree paths are rejected when they escape the configured Pixir worktree
  root;
- dirty worktrees block cleanup;
- cleanup has a dry-run mode;
- host-boundary summary is recorded;
- child Delegation Context clearly states branch, base SHA, lease id, no auto-merge,
  and cleanup rules.

## References

- ADR 0011: BEAM-native Subagents.
- ADR 0012: Structural Workflows over Subagents.
- ADR 0014: Workflow Checkpoint Bundles and honest partial outcomes.
- ADR 0027: External command execution as a bounded host boundary.
- ADR 0028: Workspace Strategies and future virtual overlays.
- ADR 0030: Explicit `virtual_diff` apply and merge-back.
- ADR 0033: Typed Checkpoint Outputs as harness-owned projections.
- Issue #117: Design `git_worktree` workspace strategy.
