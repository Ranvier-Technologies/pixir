# 18. Durable History compaction and replay repair

Date: 2026-06-08
Status: Accepted
Implementation status: Initial deterministic slice implemented

## Context

Pixir folds the local Log into Provider input on every Turn. That keeps Turns stateless
and audit-friendly, but long Sessions eventually create two practical risks:

- replaying every old Event can waste context or exceed model limits;
- a prior interrupted or crashed Turn can leave a `tool_call` without a matching
  `tool_result`, which makes Responses API replay invalid.

One observed failure mode was a large shell output truncated across a UTF-8 boundary:
the `tool_call` had already been appended, but the `tool_result` crashed during JSON
encoding. Another observed failure mode was an interrupted `run_workflow` that spawned
Subagents but never persisted the parent `tool_result`. In both cases the next Turn can
send a function call without output and receive a provider error such as "No tool output
found for function call".

These are not Presenter concerns. They affect future Provider input, so the Harness core
must own the repair path.

## Decision

Pixir adds a canonical `history_compaction` Event. The full NDJSON Log remains the source
of truth; compaction does not delete or rewrite old Events. Instead, `pixir compact`
records a durable checkpoint that summarizes an older History prefix and leaves a recent
tail uncompressed.

Provider replay uses:

1. the latest `history_compaction` checkpoint, if present;
2. all non-compaction Events after that checkpoint's compacted `to_seq`;
3. synthetic fallback tool outputs only when a historical orphan still exists.

The first compaction strategy is deterministic:

- count compacted event types;
- preserve recent conversational excerpts;
- preserve obvious tool call names and path-like arguments;
- record limitations that tell the model the full Log is still authoritative.

Pixir also defines the contract for a future model-assisted compaction pass in code:

- `Pixir.Compaction.developer_instruction/0` is a short goal/constraints/output
  instruction for reasoning models.
- `Pixir.Compaction.output_schema/0` owns the checkpoint JSON shape as a strict schema.
- `Pixir.Compaction.model_contract/3` packages the instruction, schema, and delimited
  Session Event payload without calling the network or mutating the Log.

The prompt deliberately avoids chain-of-thought requests and long process scripts. The
developer instruction states the task boundary; the schema enforces shape; the Events
are the arguments.

Pixir also repairs orphan tool calls before starting a new Turn and during `interrupt/1`.
If a Log contains `tool_call` Events without matching `tool_result` Events, Session
records fallback `tool_result` Events with `ok: false` and error kind
`orphan_tool_call`. Provider-level synthetic outputs remain as a final replay guard, but
Session reconciliation is the canonical repair path.

ADR 0032 extends this direction for Workflows: a future `workflow_event` spine can give
orphaned `run_workflow` repair enough durable graph/checkpoint evidence to report
interrupted or partial Workflow work honestly instead of relying only on volatile
runtime state.

`pixir compact` follows ADR 0005:

```bash
./pixir compact <session-id> --dry-run --json
./pixir compact <session-id> --tail-events 80
./pixir compact --help
```

## Consequences

- Long Sessions can get bounded Provider input without hiding the full audit trail.
- Future model input is shaped by durable Events, not hidden UI cache.
- Crash/interruption repair becomes visible in the Log instead of being silently patched
  only at Provider fold time.
- Deterministic summaries are safe to test but intentionally limited; they are not a
  semantic replacement for the full Log.
- A future model-assisted compaction mode can be added, but it must still write a
  canonical checkpoint with limitations and verification evidence.
- Prompt/schema drift is testable before networked model-assisted compaction exists.

## Non-goals

- Do not delete, rewrite, or garbage-collect old Log Events in this slice.
- Do not make compaction automatic on every Turn yet.
- Do not call a model for compaction in this slice.
- Do not make the Presenter own context reduction policy.
- Do not claim deterministic compaction preserves every semantic nuance.
- Do not put the output schema in prose inside the prompt.

## Verification Direction

The minimal contract is:

```bash
mix test test/pixir/compaction_test.exs
mix test test/pixir/session_test.exs
mix test test/pixir/provider_test.exs
mix test test/pixir/cli_test.exs
mix test
mix check
```

Regression coverage should prove:

- `history_compaction` is canonical.
- Provider input becomes latest checkpoint plus uncompressed tail.
- `pixir compact --dry-run --json` is structured and does not mutate the Log.
- The model-assisted compaction contract keeps developer instructions small and schema
  separate.
- `Session.start_turn/2` records fallback `tool_result` Events before a new Turn if
  pending calls exist.
- `Session.interrupt/1` reconciles pending calls even when no active Turn remains.

## References

- ADR 0003: stateless Turns; local Log is source of truth.
- ADR 0004: unified Event envelope and canonical vs ephemeral events.
- ADR 0005: agent ergonomics, dry-run, help, structured errors.
- ADR 0017: minimal Harness core and Presenter boundary.
- ADR 0032: Minimal Workflow Events for durable run decisions.
- CONTEXT.md: Compaction, History, Log, Provider, Session.
