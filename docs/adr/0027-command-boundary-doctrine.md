# 27. External command execution is a bounded host boundary

Date: 2026-06-29
Status: Accepted

## Context

Pixir's concurrency advantage comes from BEAM-native coordination. A large number of
Sessions, Subagents, Tasks, timers, and mailboxes can live inside one `beam.smp`
runtime, where the operating system mostly sees scheduler threads, CPU/RSS, file I/O,
network I/O, and a small number of OS processes.

That advantage disappears when each agent freely crosses into host process execution.
Calls such as `System.cmd/3`, `Port.open/2`, `:os.cmd/1`, shells, `git`, `mix`, `node`,
and similar runtimes are visible to the operating system as process creation and
external program execution. On macOS that can also involve `posix_spawn` pressure,
path lookup, code-signing checks, Gatekeeper, `syspolicyd`, `trustd`, and certificate
or notarization checks.

ADR 0011 and ADR 0012 let Pixir fan out Subagents and Workflows. ADR 0005 and ADR
0006 already make Tools explicit, permissioned, dry-runnable, and structured. The
remaining architectural risk is confusing cheap BEAM fanout with cheap host process
fanout.

## Decision

Pixir should scale coordination inside BEAM, and treat every external process spawn as
a scarce, observable, rate-limited host boundary crossing.

The rule is:

> OTP fanout yes; OS-boundary fanout carefully bounded.

Subagents, Workflows, Session diagnostics, timers, waiters, queues, and lifecycle
state should prefer BEAM-native coordination. Runtime inspection should use internal
snapshots such as Manager state, queue lengths, waiters, child indexes, deadlines,
Session state, SessionTree, and the Log before it considers host commands.

External process execution must pass through an explicit Pixir boundary. The first
concrete boundary is the existing `Pixir.Tools.Executor` path and its tool-specific
implementations. A future `CommandBroker` may become a module or policy layer if the
Executor path needs a clearer single place for host command accounting, queueing, or
backpressure. The doctrine does not require that module today.

Pixir keeps two classes of limits separate:

- **BEAM coordination limits**: Subagent `max_threads`, Workflow `max_concurrency`,
  mailbox pressure, timers, and process supervision.
- **Host command limits**: concurrent external process spawns, command queue depth,
  command family budgets, timeout budgets, and backpressure.

Host boundary crossings should be instrumented in a way that helps agents and humans
answer "who crossed the boundary, how often, how long, and why?" without logging
secrets or raw unbounded arguments. Useful fields include command family, Tool name,
Session id, Workspace, start/end/duration, exit status, timeout status, queue delay,
active concurrency bucket, and backpressure state.

When Pixir detects host command pressure, it should report structured backpressure or
timeout evidence before multiplying OS processes. Diagnostics must not poll by
shelling out per Subagent.

## Consequences

- Pixir can preserve the practical benefit of BEAM-native fanout while avoiding
  accidental process storms on macOS and other hosts.
- Subagents may be numerous, but OS-visible process creation remains explicit,
  bounded, and measurable.
- Tool and Workflow implementation reviews get a concrete question: does this change
  increase host boundary crossings per useful work unit?
- Some work that could run in parallel inside BEAM may wait at the host command
  boundary. That latency is intentional backpressure, not a hidden failure.
- Future performance claims must distinguish BEAM coordination work from external
  process execution and must measure host boundary crossings directly.

## Non-goals

- This ADR does not ban `System.cmd/3`, `Port.open/2`, shells, `git`, `mix`, or `node`.
- This ADR does not implement a new `CommandBroker` module.
- This ADR does not change the public Tool API by itself.
- This ADR does not define a stable telemetry product surface.
- This ADR does not make public claims that Pixir uses fewer resources than another
  harness.

## Verification Direction

Immediate documentation checks:

```bash
git diff --check docs/adr CONTEXT.md AGENTS.md
mix format --check-formatted
```

Future implementation checks should prove:

- Tool execution through `Pixir.Tools.Executor` can account for host command
  crossings without leaking secrets.
- Host command concurrency can be bounded independently from Subagent/Workflow
  concurrency.
- Runtime diagnostics can report Manager/mailbox/backpressure state without shelling
  out per Subagent.
- Structured backpressure is visible to agents as ADR 0005-compatible data.

## References

- ADR 0005: Agent ergonomics, dry-run, structured errors, and I/O discipline.
- ADR 0006: Permission model.
- ADR 0011: BEAM-native Subagents.
- ADR 0012: Structural Workflows over Subagents.
- ADR 0026: Runtime terminal-state and replay contract.
- Issue #100: Harden Subagent manager crash recovery, mailbox pressure, and delegation
  context.
