# Delegate CLI Live Example

This example shows how another coding agent can call Pixir as a local
Subagents-as-a-Service runtime through `pixir delegate`.

The files here are deterministic examples, but running them without `--dry-run`
uses the configured Pixir Provider. Use `pixir` for an installed escript and
`./pixir` from a source checkout.

## Contract

### Streams

- stdout is one final JSON envelope.
- stderr is empty unless progress is explicitly requested.
- `--progress=stderr-jsonl` is currently for `delegate attach`; attached
  `pixir delegate --spec ... --json` rejects `--progress` until it can emit real
  progress frames.
- The Log under `.pixir/sessions/` is the durable source of truth; `diagnose` and
  `tree` are projections derived from that Log.

### Exit Codes Are Path-Scoped

Do not generalize one exit code across all `pixir` subcommands. Branch on the
command path first, then parse stdout JSON.

| Path | Exit | Meaning for that path | Caller action |
| --- | ---: | --- | --- |
| `pixir delegate --spec ... --dry-run --json` | `0` | Spec accepted; no Provider, Subagent, Workflow, host command, or artifact execution started. | Safe to run without `--dry-run` if the plan matches intent. |
| `pixir delegate --spec ... --dry-run --json` | `2` | Invalid args/spec, unreadable stdin/spec, unsupported mode, or unknown role. | Inspect `kind`, `details`, `field` / `json_pointer`, and `next_actions`; fix the spec before runtime. |
| `pixir delegate --spec ... --dry-run --json` | `3` | Bounded write policy rejected the planned write scope. | Narrow the child `write_set` or explicitly expand `write_policy.allow_writes`. |
| attached `pixir delegate --spec ... --json` | `0` | Delegate work reached a clean success state; expect `ok: true` and `status: "completed"`. | Consume `children`, diagnostics commands, artifacts, and summaries as evidence pointers. |
| attached `pixir delegate --spec ... --json` | `3` | Permission, workspace, read-confinement, or bounded-write policy denial. | Distinguish `kind: "outside_workspace"` from `kind: "write_policy_denied"` before retrying. |
| attached `pixir delegate --spec ... --json` | `4` | Provider/auth/network class failure. | Inspect `kind`, provider diagnostics, and retry or re-auth guidance. |
| attached `pixir delegate --spec ... --json` | `5` | Runner-level failure before delegated work reached a terminal state: backpressure, unavailable manager, or daemon requirement. | Inspect the error `kind` and details; retry with adjusted budgets or daemon setup. |
| attached `pixir delegate --spec ... --json` | `6` | Domain work reached an incomplete terminal state such as `partial`, `timed_out`, `failed`, or `cancelled` — attached child timeouts normalize to `status: "timed_out"` and exit here, not `5`. | Parse the envelope; inspect `children[*].status`, workflow buckets, `write_destination`, and diagnostics before deciding whether the result is usable. |
| one-shot `pixir "prompt"` / `pixir resume ...` | `6` | The turn completed without a final assistant message. | Use the emitted resume/diagnose guidance; do not infer Delegate partial semantics. |
| `delegate status` / `delegate attach` / `delegate cancel` | path-specific | Liveness commands reuse the same JSON envelope vocabulary, but status/snapshot acceptance is not proof that delegate work succeeded. | Inspect `ok`, `status`, owner/runtime fields, and child evidence. |

### Reading Delegate Results

Treat `ok`, `status`, and the shell exit code as the first branch only. A top-level
`status: "partial"` means "not cleanly completed"; it is an incomplete umbrella, not
proof that useful partial work exists. Before acting, inspect:

- `children[*].status`, `children[*].checkpoint_status`, and child
  `child_session_id`;
- workflow buckets such as `held_steps`, `failed_steps`, `partial_steps`,
  `needs_orchestrator_steps`, and `safe_next_actions`;
- bounded-write `write_destination`;
- `diagnostics.diagnose_command` and `diagnostics.tree_command`.

For direct child Subagents from a root delegate Session, use `max_depth: 1`.
`max_depth: 0` is a useful rejection fixture, not a working fanout setting.

### Bounded Write Results

Bounded-write envelopes report where Pixir believes writes landed. A partial
bounded-write result can still have applied a subset of writes before a later denial
or failure. `observed_applied_writes` is an at-least observation from child Logs when
available; if it is absent, that is not proof of zero writes unless
`write_destination.contract_status` explicitly says no workspace write was applied.

Illustrative non-golden partial bounded-write envelope:

```json
{
  "ok": false,
  "status": "partial",
  "exit_code": 6,
  "strategy": "workflow",
  "write_destination": {
    "writes_applied_to": "indeterminate",
    "contract_status": "unverified_partial_writes",
    "workspace_modes": ["shared"],
    "observed_applied_writes": ["notes/e1.md"],
    "observed_writes_source": "child_log",
    "observed_writes_semantics": "at_least"
  },
  "children": [
    {
      "step_id": "write",
      "status": "failed",
      "checkpoint_status": "failed",
      "writes_applied_to": "indeterminate",
      "observed_applied_writes": ["notes/e1.md"],
      "next_actions": ["retry_failed_step"]
    }
  ],
  "safe_next_actions": ["retry_failed_steps"]
}
```

### Denial Kinds

Do not collapse read/scope denials and write allowlist denials:

- `kind: "outside_workspace"` with `matched_rule: "outside_workspace"` means a
  read/scope escape, such as a shell-shaped path token resolving outside the
  workspace. This is a tripwire, not a full POSIX sandbox.
- `kind: "write_policy_denied"` means the requested write exceeded the bounded write
  policy.

Illustrative non-golden `outside_workspace` denial:

```json
{
  "ok": false,
  "status": "rejected",
  "exit_code": 3,
  "kind": "outside_workspace",
  "message": "bash command references a path outside the workspace",
  "details": {
    "tool": "bash",
    "token": "$HOME/notes.txt",
    "requested_command": "cat $HOME/notes.txt",
    "matched_rule": "outside_workspace",
    "next_actions": [
      "use_workspace_relative_paths",
      "use_pixir_read_tool_for_file_access",
      "run_pixir_from_the_intended_workspace_root"
    ]
  }
}
```

Canonical `permission_decision` events may omit `next_actions` even when the
underlying tool error details contain them. Prefer the terminal tool error/details
and top-level `next_actions` / `safe_next_actions` when present.

`host_boundary.external_process_spawns` is scoped to the delegate entrypoint, not to
host tools that child Sessions may call. Inspect child diagnostics for child
host-command evidence.

## Preflight

```bash
mix escript.build
./pixir doctor --json
```

For installed Pixir:

```bash
pixir doctor --json
```

## Attached Call

Use this when the caller wants Pixir to return only after the child Subagents
finish or reach a terminal partial state.

```bash
./pixir delegate --spec docs/examples/delegate-cli-live/attached-subagents.json --dry-run --json
./pixir delegate --spec docs/examples/delegate-cli-live/attached-subagents.json --json
```

For shell callers, treat a non-zero exit as actionable even though stdout remains
parseable JSON:

```bash
if ! result="$(./pixir delegate --spec docs/examples/delegate-cli-live/attached-subagents.json --json)"; then
  printf '%s\n' "$result" | jq '{ok,status,kind,summary,next_actions}'
  exit 1
fi
printf '%s\n' "$result" | jq '{ok,status,delegate_id,parent_session_id,children}'
```

Optional transport preference: `subagents.transport` (or top-level
`transport`) accepts `auto`, `websocket`, or `http_sse`; invalid values fail
the dry-run with a structured error, and the effective value is surfaced as
`limits.transport` in plan and envelope.

Useful fields for callers:

- `ok`
- `status`
- `delegate_id`
- `parent_session_id`
- `children[].status`
- `children[].child_session_id`
- `children[].retry_attempts` / `children[].retry_max_attempts` /
  `children[].current_attempt_index` / `children[].retry_history` - present
  only when the runtime auto-retried that child (bounded retry for
  websocket-family and provider-declared-retryable server errors on
  read-only children); `retry_history` preserves each failed attempt's
  session id and error kind
- `diagnostics.diagnose_command`
- `diagnostics.tree_command`
- `host_boundary.external_process_spawns_scope`

## Async Service Call

Use this when the caller wants separate `start`, `status`, `attach`, and `cancel`
invocations. Start the manual workspace-local daemon in one terminal:

```bash
./pixir delegate daemon --foreground --json
```

`delegate start` requires that resident daemon. Without it, Pixir rejects `start`
instead of returning a `running` handle whose owner would die with the short-lived CLI
process.

From another managed shell/process:

```bash
delegate_json="$(./pixir delegate start --spec docs/examples/delegate-cli-live/async-subagents.json --json)"
delegate_id="$(printf '%s\n' "$delegate_json" | jq -r '.delegate_id')"

./pixir delegate status "$delegate_id" --json
./pixir delegate attach "$delegate_id" --json --progress=stderr-jsonl --wait-horizon-ms 5000
./pixir delegate cancel "$delegate_id" --json
./pixir delegate attach "$delegate_id" --json
./pixir delegate daemon --stop --json
```

After the daemon stops, `attach` falls back to a durable snapshot from the local
Session Log. That fallback is expected and should be treated as inspectable
state, not as live owner capability.

## Claude Code Pattern

Claude Code can call Pixir the same way Codex does: use the shell, write a bounded
spec, run `--dry-run --json`, then choose attached or async execution.

### Suggested Agent Instruction Block

Use this block for Claude Code, Codex, or another shell-driven agent:

```text
Use Pixir delegate as a local audited executor. Do not edit files.
First run ./pixir doctor --json. Create a temporary delegate spec with
strategy "subagents", mode "read_only", max_depth 1, and bounded tasks. Run
./pixir delegate --spec <spec> --dry-run --json and inspect the JSON. If accepted,
run attached with ./pixir delegate --spec <spec> --json and treat a non-zero exit
as incomplete or failed work while still parsing stdout JSON for next_actions. Use
async service mode only when a managed resident daemon is already running or can be
started and later stopped explicitly: ./pixir delegate daemon --foreground --json.
Then call start/status/attach/cancel from another managed shell. Parse stdout as
the final JSON envelope. Parse stderr as JSONL only when --progress=stderr-jsonl is
used. Use diagnose/tree commands from the result for evidence. Do not treat prose
summaries as proof.
```

Minimal Claude shell flow:

```bash
cat > /tmp/pixir-delegate.json <<'JSON'
{
  "contract_version": 1,
  "strategy": "subagents",
  "mode": "read_only",
  "workspace_mode": "shared",
  "subagents": {
    "role": "explorer",
    "max_threads": 2,
    "max_depth": 1
  },
  "tasks": [
    "Read README.md only. Return 2 bullets about Pixir. Do not edit files.",
    "Read CONTEXT.md only. Return 2 bullets about the Log. Do not edit files."
  ],
  "limits": {
    "timeout_ms": 120000
  }
}
JSON

./pixir delegate --spec /tmp/pixir-delegate.json --dry-run --json
./pixir delegate --spec /tmp/pixir-delegate.json --json | jq '{ok,status,delegate_id,parent_session_id,children}'
```

For Claude, the practical rule is simple: let Pixir own fanout and evidence;
Claude owns the outer decision loop and reads Pixir's JSON, diagnostics, and
Session ids.
