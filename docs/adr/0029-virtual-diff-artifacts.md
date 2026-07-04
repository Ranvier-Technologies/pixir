# 29. Virtual overlays export virtual_diff artifacts

Date: 2026-06-29
Status: Accepted
Implementation status: Internal virtual overlay runner and explicit Workflow-step
`virtual_overlay` can produce artifacts; public apply/merge-back remains a follow-up
slice.

## Context

ADR 0028 accepts `virtual_overlay` as a future Workspace Strategy for shell-shaped
exploration and scratch edits inside a BEAM-native virtual filesystem. That strategy
must let a child Subagent produce useful write-shaped work without silently mutating the
parent Workspace.

Pixir already has Workflow Checkpoint Bundles (ADR 0014), canonical Log discipline (ADR
0004), and the host-boundary rule from ADR 0027. The missing contract is the artifact
shape that carries virtual file changes from a virtual overlay back to the parent,
Presenter, or future apply step.

## Decision

Pixir names that artifact `virtual_diff`.

A `virtual_diff` is a structured result artifact that represents changes made inside a
virtual overlay. It is not an applied parent Workspace mutation, not a host command, and
not a new canonical Event type by itself. Workflow-step `virtual_overlay` carries the
artifact in the Workflow result and checkpoint data. When Pixir needs other durable
evidence, the artifact can be carried by existing durable surfaces such as a Tool
result, Subagent result, Workflow Checkpoint Bundle, Session Resource, or a later
explicitly accepted event family.

The artifact uses JSON-safe string keys and starts with this minimum contract:

```json
{
  "kind": "virtual_diff",
  "version": 1,
  "workspace_strategy": "virtual_overlay",
  "workspace_fidelity": "virtual_shell_no_host_binaries",
  "parent_workspace": {
    "mutation": "none",
    "evidence": "virtual writes only; no parent apply was attempted"
  },
  "import": {
    "read_set": ["lib/example.ex"],
    "file_count": 1,
    "byte_count": 1200,
    "truncated": false
  },
  "commands": [
    {
      "id": "cmd_1",
      "display": "sed -i s/foo/bar/ lib/example.ex",
      "status": "ok",
      "elapsed_ms": 12,
      "stats": {
        "steps": 30,
        "output_bytes": 0,
        "max_exec_depth": 1
      }
    }
  ],
  "summary": {
    "files_added": 0,
    "files_modified": 1,
    "files_deleted": 0,
    "files_unsupported": 0,
    "diff_bytes": 240,
    "truncated": false
  },
  "changes": [
    {
      "path": "lib/example.ex",
      "operation": "modify",
      "before": {
        "sha256": "previous-content-sha",
        "byte_count": 1200
      },
      "after": {
        "sha256": "new-content-sha",
        "byte_count": 1198
      },
      "diff": {
        "format": "unified",
        "text": "--- a/lib/example.ex\n+++ b/lib/example.ex\n",
        "truncated": false
      }
    }
  ],
  "limits": {
    "profile": "default",
    "max_import_bytes": 200000,
    "max_diff_bytes": 50000,
    "max_virtual_commands": 20
  },
  "caveats": [],
  "apply": {
    "status": "not_applied",
    "requires_explicit_apply": true
  }
}
```

Required top-level fields are:

- `kind`, always `"virtual_diff"`;
- `version`, starting at `1`;
- `workspace_strategy`, initially `"virtual_overlay"`;
- `workspace_fidelity`, initially `"virtual_shell_no_host_binaries"`;
- `parent_workspace`, with `mutation` initially `"none"` and `evidence` explaining
  that only virtual writes occurred;
- `import`;
- `commands`;
- `summary`;
- `changes`;
- `limits`;
- `caveats`;
- `apply`.

`changes[].operation` starts with these values:

| Operation | Meaning |
| --- | --- |
| `add` | A virtual file did not exist in the imported read set and now exists. |
| `modify` | A virtual file existed before and after with different content. |
| `delete` | A virtual file existed in the imported read set and was removed virtually. |
| `unsupported` | Pixir detected a change but cannot safely represent it as a text diff. |

For text files, `changes[].diff.format` should be `"unified"` unless a later ADR accepts
another format. Binary files and files Pixir cannot safely treat as text use
`operation: "unsupported"` and should not include misleading patch text. Text files that
are over a configured output limit or have encoding caveats should keep their real
operation (`add`, `modify`, or `delete`) and set `diff.truncated: true` and/or add a
caveat entry. Consumers can then count binary/non-text changes as unsupported while
still rendering partial text diffs for bounded or caveated text changes.

The `commands` list describes virtual commands, not host processes. It may contain
display strings and virtual execution stats, but it must not imply `System.cmd/3`,
`Port.open/2`, `:os.cmd/1`, `git`, `node`, `/bin/bash`, or a host shell ran. If a future
implementation uses Bashex, Bashex stats are implementation evidence under `stats`; the
public contract remains `virtual_diff`.

`apply.status` starts as `"not_applied"`. Applying a `virtual_diff` to a real Workspace
requires the explicit permissioned apply/merge-back operation accepted in ADR 0030.

## Consequences

- Virtual overlays can produce useful file-change evidence before Pixir supports
  merge-back.
- Presenters can render a reviewable summary and diff without pretending parent files
  changed.
- Workflow Checkpoint Bundles can include virtual write evidence as an artifact while
  still requiring the Workflow to decide whether the checkpoint is dependency-safe.
- ADR 0033 lets typed checkpoints reference `virtual_diff` as a structured artifact
  without flattening or renaming the artifact contract.
- A future apply command has a stable input shape, but no automatic apply behavior is
  implied. ADR 0030 defines that apply as a separate permissioned, dry-runnable,
  hash-checked operation.
- The artifact makes host-boundary discipline inspectable: virtual command stats are
  separate from real host command execution.

## Non-goals

- Do not implement the `virtual_overlay` runner in this ADR.
- Do not add Bashex as a runtime dependency.
- Do not add automatic apply or merge-back.
- Do not define `git_worktree` behavior.
- Do not add a canonical `workflow_event`.
- Do not replace Workflow Checkpoint Bundles or typed checkpoint output decisions.
- Do not claim a virtual diff is equivalent to a patch produced by a real Git worktree.

## Verification Direction

The design slice should pass:

```bash
git diff --check docs/adr CONTEXT.md AGENTS.md
mix format --check-formatted
mix compile --warnings-as-errors
```

Future implementation checks should prove:

- additions, modifications, deletions, and unsupported/binary caveats are represented;
- parent Workspace files are not mutated while producing a `virtual_diff`;
- virtual command stats are present without host command execution;
- output truncation is explicit and bounded;
- `virtual_diff` can appear inside a Workflow Checkpoint Bundle without being treated as
  an applied change.

## References

- ADR 0004: unified Event envelope and canonical vs ephemeral events.
- ADR 0014: Workflow Checkpoint Bundles and honest partial outcomes.
- ADR 0027: External command execution as a bounded host boundary.
- ADR 0028: Workspace Strategies and future virtual overlays.
- ADR 0030: Explicit `virtual_diff` apply and merge-back.
- ADR 0033: Typed Checkpoint Outputs as harness-owned projections.
- Issue #112: Define `virtual_diff` artifact contract for virtual overlays.
