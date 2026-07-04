# 24. Session fork and branch summaries (Log-backed, inter-session)

Date: 2026-06-19
Status: Accepted
Implementation status: Fork write path, `SessionTree` projection, and deterministic `--summarize` shipped; model-assisted summarize deferred (#28)

## Context

Pixir needs a Pi-inspired fork surface without adopting Pi's intra-file message tree or
TUI `/tree` navigator (ADR 0017). CONTEXT.md already defines **Fork** as an inter-Session
branch and **Branch Summary** as an optional lossy synthesis at fork creation — distinct
from Pi's `/tree` trigger and from **Compaction**.

ADR 0020 fixed prompt-cache routing so `fork_root_session_id` can keep a fork tree on one
`s_` family, but no producer sets that field yet. Issue #29 tracks the CLI-first slice.

## Decision

**1. Inter-session fork only.** `./pixir fork <parent-session-id>` creates a new child
Session Log by replaying a prefix of the parent's canonical Events. Pixir does not add
`parent_event_id` pointers inside a single Log.

**2. Canonical `session_fork` at seq 0 in the child Log.** The first durable Event records
lineage: `parent_session_id`, `fork_root_session_id`, `forked_to_seq`, workspaces,
`replay_event_count`, and `strategy: "replay_v1"`. Sequence numbering stays 0-based like
today's Sessions.

**3. Replay copy rules.** Copy conversational canonical types through `forked_to_seq`.
Exclude `provider_usage` (audit evidence, never model context), `history_compaction`
(parent checkpoint ranges do not survive child renumbering until a rewrite slice),
existing `session_fork`, and `branch_summary`. Copied Events get new `id`, child
`session_id`, and child `seq` starting at 1; content `data` is preserved. Referenced
Session Resource payloads are copied into the child store when present.

**4. `fork_root_session_id`.** Child inherits the parent's fork root when the parent Log
contains `session_fork`; otherwise the root is `parent_session_id`. Child Turns must
forward this into Provider cache metadata (Session `start_turn` follow-up).

**5. `branch_summary`.** Separate canonical type, optional via `--summarize`. When present
it is recorded after the replayed prefix in the child Log and is interpretive Provider
context with explicit limitations; it does not delete or replace replayed prefix Events.
The first slice uses `deterministic_operational_summary_v1`; model-assisted summarize
remains deferred (#28). Dry-run reports `would_record_branch_summary`.

**6. CLI contract (ADR 0005).** `pixir fork <parent> [--to-seq N] [--summarize]
[--dry-run] [--json]`. Default `to_seq` is the highest seq among replayable parent
Events (full conversational prefix). Same workspace as parent. Parent Log is read-only.

**7. Session Tree.** Fork children are discovered by scanning workspace Logs for
`session_fork.parent_session_id` — a read-only projection, not a replay index.

## Consequences

- Forks share warm prompt-cache families when prefixes match (ADR 0020).
- Child Logs are self-describing for resume/fork/debug without a sidecar header file.
- Log duplication is accepted for audit clarity; compaction remains the path to bound
  Provider input on long child Sessions.
- Branch summary at fork time is intentionally different from Pi `/tree` navigation.

## Non-goals

- No intra-Log sibling branches or TUI `/tree` navigator.
- No ACP `session/fork` in this slice.
- No parent Log mutation, merge-back, or deletion.
- No model-assisted `--summarize` until #28.
- `branch_summary` Provider fold is minimal in the deterministic slice; richer shaping
  may follow model-assisted summarize (#28).

## Verification Direction

```bash
mix test test/pixir/fork_test.exs
mix test test/pixir/event_test.exs
mix test test/pixir/cli_test.exs
mix test
```

Regression coverage should prove:

- `session_fork` and `branch_summary` are canonical types.
- `pixir fork --dry-run --json` returns structured plan without mutating Logs.
- Write path creates child Log with `session_fork` at seq 0 and replayed prefix.
- `provider_usage` and `history_compaction` are excluded from replay.
- `fork_root_session_id` inherits from parent fork lineage.
- forked child Sessions keep referenced resource payloads addressable.
- `pixir tree --json` discovers fork children from `session_fork` lineage metadata.

## References

- ADR 0004: unified Event envelope.
- ADR 0017: Presenter boundary, no TUI tree.
- ADR 0018: compaction is a separate lifecycle.
- ADR 0020: fork-root cache family.
- CONTEXT.md: Fork, Branch Summary, Session Tree.