# 34. Delegate service mode requires explicit runtime residency

Date: 2026-07-01
Status: Accepted
Implementation status: Decision documented; reversible Delegate handles, service-state
vocabulary, current-BEAM-runtime `pixir delegate start` owner, and manual foreground
daemon/IPC residency v0 are implemented. Streaming attach, Workflow runtime, auto-start,
and production daemon management remain future work.

## Context

ADR 0011 defines Subagents as supervised child Sessions owned by the Subagents manager.
ADR 0012 defines Workflows as structural orchestration over those Subagents. ADR 0027
then makes the command-boundary doctrine explicit: Pixir should scale coordination
inside BEAM, while external process spawns remain scarce, observable, and bounded.

`pixir delegate` is the Codex/GPT-first service facade over that runtime. Its first
implementation is intentionally attached: a caller enters Pixir once, Pixir creates a
parent Session, spawns Subagents through the existing manager, waits for terminal
evidence, and returns one result envelope. The current `status`, `attach`, and `cancel`
subcommands are bounded service-shape probes:

- `status` folds durable Log evidence;
- `attach` returns a one-shot durable snapshot;
- `cancel` can close live Subagents only when the current BEAM runtime has Manager
  handles.

The open design question in issue #139 is what must be true before Pixir can support
`pixir delegate start` as a real service-mode command. Returning from a CLI process is
not enough by itself. Once that process exits, any in-memory pids, monitors, waiters,
timers, progress subscribers, and cancellation handles also disappear unless another
BEAM runtime remains alive to own them.

Without that owner, a later `pixir delegate cancel <id>` can still read durable truth
from the Log, but it cannot honestly claim that it actively cancelled running work.
Likewise, a later `attach` can return a durable snapshot, but it cannot stream live
progress from a process that no longer exists.

## Decision

Pixir separates Delegate **durable identity** from Delegate **live capability**.

A Delegate handle must carry enough stable identity to find durable evidence and enough
live identity to attempt active operations when a resident owner exists. The stable
handle shape is:

- `delegate_id`: the service-level operation id returned by `pixir delegate start`;
- `parent_session_id`: the Pixir parent Session id whose Log records durable Delegate,
  Subagent, Workflow, and diagnostic evidence.

One identifier is not enough. `delegate_id` is the user-facing service handle and may
eventually span a Subagents fanout or Workflow run. `parent_session_id` is the durable
Log root that survives restart, powers `pixir diagnose session`, and lets old callers
fall back to existing Session-oriented commands. Future implementations may include
`workflow_id`, child Session ids, or a typed handle version, but they must not hide the
parent Session id.

Pixir also separates **durable truth** from **live handle evidence**:

| Operation | Works from durable Log after restart | Requires live Delegate owner |
| --- | --- | --- |
| `delegate status` | Yes. It folds parent and child Logs, SessionTree, diagnostics, and Workflow events when present. | No, though live snapshots may enrich it. |
| `delegate attach` snapshot | Yes. It may return the latest bounded durable snapshot and say whether it is stale. | No. |
| `delegate attach` streaming | No. Streaming observes in-memory progress, waiters, subscriptions, and owner state. | Yes. |
| `delegate cancel` active cancellation | No. The Log can prove intent and prior state, but cannot by itself interrupt a live child. | Yes. |

When the live owner is missing, stale, or belongs to another runtime that cannot be
reached, Pixir must report an honest service-state result such as
`owner_unavailable`, `stale_handle`, or `snapshot_only`. It must not claim that live
work was cancelled, streamed, or waited on merely because durable evidence was readable.

The first real `delegate start` implementation must therefore choose an explicit
runtime residency model before it promises fire-and-forget behavior. The preferred
target is a resident Pixir-owned BEAM process for the workspace or user environment.
That owner should supervise Delegate runs, keep live handles in OTP, expose bounded
status/attach/cancel operations, and write all durable truth to the normal Session Logs.

A bounded per-run OS process may be used later only if the implementation documents the
tradeoff and keeps host-boundary concurrency explicit. It must not become
process-per-child fanout, shell polling, or a hidden second scheduler.

The current attached runner remains the synchronous compatibility path. It is not
service mode. It may continue to run Subagent fanout in one Pixir invocation and return
final evidence, but it must not grow caller-side loops that pretend an exited CLI
process is still an owner.

## Consequences

- `pixir delegate start` may start current-runtime owner-backed work, but it must report
  that live owner capability does not survive one-shot escript process exit. This avoids
  shipping fake cross-invocation async semantics.
- `status` stays durable-first. It should continue working after restart because the Log
  and SessionTree are the source of truth.
- `attach` can safely ship snapshot behavior before streaming. Streaming is a separate
  capability that depends on live owner reachability.
- `cancel` must distinguish "I read a running/stale durable record" from "I interrupted
  a live owner." Missing live handles are service-state facts, not internal corruption.
- The current implementation defines the current-runtime owner boundary, registration
  and lookup path, stale-owner vocabulary, and a manual foreground daemon/IPC path for
  cross-invocation `start`, `status`, and active `cancel`. This is still not production
  daemon management or auto-start.
- A resident owner introduces later design work: IPC or in-process entrypoint, lifecycle
  startup/shutdown, auth/permission boundary, workspace scoping, heartbeat/progress
  snapshots, backpressure, and diagnostics.
- The decision preserves ADR 0027: many Subagents or Workflow steps may fan out inside
  BEAM, while host-visible processes remain bounded and measured.

## Non-goals

- This ADR does not require auto-start or production service management for
  daemon-backed `pixir delegate start`.
- This ADR does not implement launchd service management, an HTTP server, or a
  network-visible daemon.
- This ADR does not choose the final packaging model for a resident Pixir runtime.
- This ADR does not add a new canonical Event type.
- This ADR does not change ACP, T3, or Zed presenter behavior.
- This ADR does not replace `Pixir.Subagents.Manager`, `Pixir.Workflows`, or
  `Pixir.WorkflowRun`.

## Verification Direction

Immediate documentation checks:

```bash
git diff --check docs/adr/0034-delegate-runtime-residency.md
mix format --check-formatted
```

Implementation slices after this ADR should prove:

- `delegate start --json` returns both `delegate_id` and `parent_session_id`;
- durable `delegate status <id> --json` can resolve through the parent Log after a
  runtime restart;
- `delegate attach <id> --json` has a snapshot fallback when no live owner is reachable;
- streaming attach succeeds only when a live owner is reachable;
- `delegate cancel <id> --json` actively cancels only through a live owner and reports
  `owner_unavailable` or `stale_handle` otherwise;
- tests cover stale owner, owner restart, terminal durable children, and running durable
  children with no live handle;
- diagnostics remain Log-backed and do not poll by shelling out per Subagent.
- manual daemon/IPC `start`, `status`, and `cancel` work across short-lived CLI client
  invocations without process-per-child fanout.

## References

- ADR 0003: stateless Turns; local Log is source of truth.
- ADR 0008: UI-agnostic conversational driver; do not duplicate Session ownership.
- ADR 0011: BEAM-native Subagents as supervised child Sessions.
- ADR 0012: Structural Workflows over Subagents.
- ADR 0013: Skill-backed Workflow Templates keep runtime ownership unchanged.
- ADR 0027: External command execution is a bounded host boundary.
- ADR 0032: Minimal Workflow Events for durable run decisions.
- ADR 0033: Typed checkpoint outputs are harness-owned projections.
- Issue #133: Subagents as a Service v1.
- Issue #139: Delegate service mode: owner-backed start/status/attach/cancel.
- Elixir `DynamicSupervisor`: https://hexdocs.pm/elixir/DynamicSupervisor.html
- Elixir `Registry`: https://hexdocs.pm/elixir/Registry.html
- Elixir `Supervisor`: https://hexdocs.pm/elixir/Supervisor.html
- Elixir `Task.Supervisor`: https://hexdocs.pm/elixir/Task.Supervisor.html
