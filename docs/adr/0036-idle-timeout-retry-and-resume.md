# 36. Idle-timeout recovery does not auto-resume ambiguous work

Date: 2026-07-03
Status: Accepted
Implementation status: Decision documented; PR #174 implements deterministic manual
recovery guidance, but no automatic retry or resume behavior is implemented.

## Context

Pixir executor dogfood exposed a provider stream stall during a write-capable one-shot
run. The CLI exited with a provider idle-timeout failure and the operator had to inspect
partial filesystem changes, recover context manually, and relaunch work with explicit
instructions.

PR #174 improved the deterministic recovery path:

- `turn_failed.details.recovery` now records diagnose and resume commands;
- one-shot JSON and stderr output expose copyable recovery guidance;
- diagnostics distinguish provider stream idle timeout from permission, workspace, and
  tool failures.

The remaining question is whether Pixir should automatically retry or resume after an
idle timeout.

ADR 0003 and ADR 0019 are the hard boundary. Pixir sends Responses requests with
`store: false`, and the local Log is the source of truth. A WebSocket
`previous_response_id` is connection-local optimization state, not durable Session
state. If a provider stream dies, Pixir cannot reattach to the remote stream as if the
backend owned the conversation. Any cross-turn "resume" is a fresh Provider invocation
rebuilt from Pixir's Log.

That distinction matters most for write-capable executor sessions. A timed-out request
may have already emitted text, requested tools, run host commands, edited files, or
left effects outside the model transcript. Arbitrary bash idempotency cannot be proven
by Pixir, and the current permission safe-list is an ergonomics heuristic, not a
proof-grade read-only classifier. Silent replay can duplicate writes, race a parent
orchestrator that already retried the task, or produce two active writers in the same
Workspace.

## Decision

Pixir v1 does not automatically cross-turn resume ambiguous work after provider idle
timeout.

Idle-timeout recovery is manual by default:

- record durable timeout evidence in the Log;
- report a structured terminal failure;
- print or return exact diagnose/resume commands;
- let the operator or outer orchestrator decide whether to resume.

Pixir separates four recovery concepts that must not be collapsed:

| Concept | Meaning | v1 stance |
| --- | --- | --- |
| Transport fallback | Switch from WebSocket to HTTP/SSE, or reconnect later, while preserving Log truth. | Allowed by ADR 0019 when it does not hide provider/model failure. |
| Provider request retry | Retry the same live Turn request after a transport/provider interruption. | Future opt-in only, and only before any durable output or tool-side-effect evidence exists for that request segment. |
| Manual resume | Start a new Turn or CLI invocation from Log evidence and explicit operator intent. | Supported through recovery guidance and `pixir resume`. |
| Automatic Turn resume | Pixir silently starts new semantic work after a timed-out Turn. | Not allowed in v1. |

Write-capable executor sessions must not auto-resume after idle timeout. A future ADR is
required before enabling any automatic recovery that can re-enter write-capable work.

Read-only auto-resume is also deferred. A future implementation may classify some
sessions or request segments as safe to retry, but that decision must use durable,
Log-observable predicates instead of claims such as "the command is idempotent." At
minimum, a future automatic provider request retry must prove:

- the retry happens inside the same live Turn, not as hidden cross-turn resume;
- the interrupted request segment emitted no durable assistant output, tool call,
  tool result, provider usage, or permission/workspace decision that could affect
  future behavior;
- no local Tool or host command crossed the boundary in that segment;
- the retry is bounded by attempt count, backoff, and a circuit breaker;
- retry attempts and final outcome are visible in structured evidence;
- a single-writer or owner guard prevents concurrent manual and automatic recovery;
- CLI exit codes and JSON shapes remain versioned and do not hide recovered timeouts.

Safe-resume prompts are helpful operator guidance, but they are not a safety mechanism.
Safety comes from Log predicates, permission/workspace posture, bounded retries,
single-writer ownership, and explicit evidence.

`previous_response_id` must never be promoted to durable resume truth. It may speed up a
healthy live connection, but if the socket, model, prompt shape, or Session branch
changes, Pixir resumes from the Log, not from Provider continuation state.

## Consequences

- Pixir remains safe for Claude, Codex, Fable, T3, Zed, and other orchestrators that may
  have their own timeout and retry policies. Pixir will not secretly create a second
  writer while an outer orchestrator is also recovering.
- Operators get deterministic recovery instructions instead of hidden semantic replay.
- Some provider stalls that could eventually be recoverable still require manual action
  in v1. That friction is intentional until Pixir can prove the replay is safe.
- Future retry work can still happen, but it must be named as retry, not stream
  reattachment or durable Provider resume.
- The permission safe-list should not be used as the sole basis for read-only
  auto-resume. It may need hardening before any automatic read-only retry policy.

## Non-goals

- This ADR does not implement automatic retry, automatic resume, or new CLI flags.
- This ADR does not prove idempotency for arbitrary bash, `git`, `node`, `mix`, or
  other host commands.
- This ADR does not enable `store: true` or Provider-hosted Session persistence.
- This ADR does not change WebSocket fallback semantics from ADR 0019.
- This ADR does not implement Workflow resume.
- This ADR does not change `pixir resume` behavior by itself.

## Verification Direction

Immediate documentation checks:

```bash
git diff --check docs/adr AGENTS.md
mix format --check-formatted
```

Future implementation checks should prove:

- provider idle timeout before any provider output records manual recovery guidance and
  does not silently start a new Turn;
- provider idle timeout after a write-capable `tool_call` never auto-resumes;
- a concurrent manual resume and any future automatic recovery path cannot both own the
  same write-capable Workspace;
- SIGTERM or outer-orchestrator timeout still leaves enough durable evidence or stderr
  guidance for manual recovery;
- read-only retry gates reject shell commands whose apparent command family can still
  mutate through flags, redirection, path traversal, or nested tools.

## References

- ADR 0003: stateless Turns and local Log source of truth.
- ADR 0004: unified Event envelope and canonical versus ephemeral evidence.
- ADR 0006: permission model and safe-list ergonomics.
- ADR 0017: minimal Harness core and Presenter boundary.
- ADR 0019: Provider usage, prompt-cache observability, and WebSocket continuation.
- ADR 0026: runtime terminal-state and replay contract.
- ADR 0027: external command execution as a bounded host boundary.
- ADR 0035: write-capable Sessions require an external evidence mirror.
- Issue #159: Provider idle-timeout recovery and resume guidance for executor sessions.
- PR #174: deterministic idle-timeout recovery guidance.
