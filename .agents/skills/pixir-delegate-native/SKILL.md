---
name: pixir-delegate-native
description: Delegate work to subagents from INSIDE a Pixir session using the native Subagent tools (spawn_agent, wait_agent, close_agent, list_agents, send_input) instead of shelling out to the pixir CLI. Use when you are a Pixir session that needs to fan out parallel workers, steer a child, or run skill-backed workflow templates — in-VM, without spawning nested pixir processes.
---

# Pixir Delegate (native) — delegation from inside the runtime

You are already inside a Pixir session. The delegation judgment you follow is
the shared core — read `../pixir-delegate/references/delegation-core.md` on
first use. This variant covers only what changes when the orchestrator IS a
Pixir session.

First established by a blind run (session `20260705T001653-399094`): an
in-Pixir orchestrator correctly refused the CLI variant's own commands,
because shelling out to `pixir` from inside Pixir boots the extra runtime
layer the core doctrine forbids. Your actuation surface is the native tools.

## Surface mapping

| Core concept | Native form |
|---|---|
| Fan-out | `spawn_agent` × N (children share your VM) |
| Await + reconcile | `wait_agent`, then `list_agents` for statuses/summaries |
| Steer or retry one child | `send_input` to a live child; a finished child's session resumes like any session |
| Release | `close_agent` when no follow-up is needed — completed agents count against concurrency until closed |
| Structured invocation | skill-backed workflow templates (ADR 0013), when the delegation shape repeats |

Concurrency is governed by the runtime's `max_threads` limit — children
beyond it queue honestly. The parent wait horizon and per-child timeout are
distinct knobs; a timed-out child is a resumable session, not a loss.

## What this host changes about the practice

- **Rehearsal has no `--dry-run` analog on the native surface** (known gap).
  Rehearse by validating your task contracts and child prompts before
  spawning: self-contained, strict-JSON output schema, read-only role for
  analysis. Spawn nothing you have not fully specified.
- **No hydration prologue**: the `!`cmd`` line in the CLI variant renders
  inert here. Your runtime state is already yours — you know your version
  and session; verify workspace posture instead.
- **`allowed-tools` means nothing to this host**: your tool authority comes
  from the session's permission mode and write policy, decided at session
  start, not from skill frontmatter.
- **Evidence is native**: children are sessions with their own append-only
  logs; `subagent_event` references in your log plus the session tree
  (`pixir tree` from outside, or your own log fold) are the reconciliation
  record. Usage evidence lives in each child log's `provider_usage` events
  at `.data.usage_summary`.

## Closure, natively

`wait_agent` returning is not closure. Closure is: every child's terminal
status read via `list_agents`, every summary parsed against its declared
contract, every non-completed child dispositioned (steered with
`send_input`, resumed as a session, or reported), completed children
closed. Then — and only then — report the delegation's outcome.
