# 4. Unified event log; tagged-map Event envelope

Date: 2026-05-29
Status: Accepted

## Context

The event bus (the D-06 "spine") is the seam between the core and every front-end, and
the per-Session **Log** is the single source of truth (ADR 0003). We need one Event
shape that works for both live display and durable replay. The Kimojo reference keeps
two things — durable `messages` and a separate `ui_event` stream — which is the source
of its documented partial-vs-final `call_id` duplication.

## Decision

There is **one** Event type, a plain tagged map built via a constructor module, with a
common envelope: `{id, session_id, seq, ts, type, data}`.

- **Canonical** events (`user_message`, `assistant_message`, `reasoning`,
  `skill_activation`, `subagent_event`, `session_fork`, `branch_summary`,
  `history_compaction`, `provider_usage`, `turn_failed`, `tool_call`, `tool_result`,
  `permission_decision`) are assigned a per-Session monotonic `seq`, appended to the
  Log, and define **History** (a fold over them).
- **Ephemeral** events (`text_delta`, `reasoning_delta`, `status`) are broadcast on
  the bus for live display and **never persisted**.

The Log is a per-Session append-only NDJSON file; the envelope serializes 1:1 to a
line. Streaming deltas are never written as canonical events. The normal
`assistant_message` remains the final assistant answer, while provider-error paths may
preserve useful partial assistant text as an `assistant_message` with
`metadata.partial == true`; Provider replay treats those partial messages as
audit-only. If a Turn fails without useful assistant text, `turn_failed` records durable
failure evidence without pretending there was a final answer.

## Consequences

- **One contract** for live UI, persistence, replay, and fork — no two-store sync.
- **Deterministic replay/fold** via `seq` (and file append order as backstop).
- **Avoids Kimojo's dedupe bug** by construction (streaming deltas are ephemeral; any
  preserved partial is explicitly marked and audit-only).
- **Front-ends stay thin** — a renderer is just a subscriber that pattern-matches on
  `type`; new front-ends need no core changes.
- **Cost:** the canonical type set is a small shared vocabulary that must be curated
  deliberately; adding a canonical type is a schema change to the Log.
