# 11. Subagents are supervised child Sessions

Date: 2026-06-02
Status: Accepted

## Context

Codex subagents use explicit fan-out: a parent agent spawns specialized workers, those
workers run in parallel with their own context, and the parent collects concise results
instead of absorbing every intermediate log line. The pattern is valuable because it
reduces context pollution and makes independent exploration, review, and test work
parallel.

The 2026-06-02 OpenAI Codex docs describe the same useful shape: subagents are spawned
explicitly, run specialized workers in parallel, inherit the current sandbox policy,
and are commonly bounded with `[agents] max_threads = 6` and `max_depth = 1`. Codex also
documents custom-agent TOML files with `name`, `description`, optional model fields,
optional `sandbox_mode`, and `developer_instructions`.

Pixir already models a conversation as a supervised **Session** whose **Turn** runs in a
Task. On BEAM, spawning many supervised processes is cheap and observable, so Subagents
should be a runtime primitive rather than prompt-only convention.

## Decision

A **Subagent** is a delegated child Session created for a bounded task. It is distinct
from a Skill and from a Tool: Skills add instructions, Tools expose capabilities, and
Subagents are concurrent workers with their own Session, Turn, workspace, and lifecycle.

Subagents are spawned only through explicit controlled surfaces such as `spawn_agent`.
Pixir does not silently auto-fan-out because hidden concurrency makes cost, permissions,
and file ownership difficult to reason about.

Pixir runs Subagents under the Subagents manager, a GenServer in the application
supervision tree. The Manager starts child Sessions through `Pixir.SessionSupervisor`,
subscribes to filtered child lifecycle Events, monitors lifecycle, enforces
`max_threads`, `max_depth`, and per-worker timeouts, and starts queued workers when
capacity frees. Timeout supervision records durable `timeout_ms` and `deadline_at`
metadata in the parent Log so a restarted Manager can rearm the child timeout instead of
depending on in-memory timers.

Each child receives an isolated workspace snapshot under the parent workspace's ignored
`.pixir/subagents/<id>/workspace` directory by default. This keeps file writes from
colliding across Subagents while preserving normal Workspace confinement inside each
child. A shared workspace mode may exist for trusted workflows, but isolation is the
default.

Each child Turn receives explicit Delegation Context as late dynamic developer context.
This context records the bounded delegation being executed: Subagent id, parent and
child Session ids, agent role, task, depth and max depth, timeout and deadline,
effective permission and workspace posture, and compact host-boundary guidance. The
task remains user-facing input and agent instructions remain role configuration; the
Delegation Context is operational runtime context, not a broad stable Prefix change.

Subagent lifecycle is canonical parent History. The parent Log records
`subagent_event` entries for queued/started/input/finished/failed/cancelled/timed_out
and closed states. These events carry the parent id, Subagent id, child Session id,
agent role, task, depth, status, workspace, Log pointers, timeout budget, deadline, and
final summary where available. If a later Pixir runtime reconstructs a non-terminal
Subagent from the parent Log, it first attempts to reattach when the child Session is
still live and its Turn is still running. If no live runtime handle is available, it
reports the Subagent as `detached` rather than `not_found`; `detached` is an honest
query-time projection, not evidence of completion.

Provider replay folds only compact terminal Subagent summaries into parent input.
Detailed child logs stay in the child Session Log, so the parent can resume with the
outcome without context pollution.

Pixir ships built-in agents analogous to Codex:

- `default`: general-purpose child worker.
- `worker`: execution-focused implementation/fix worker.
- `explorer`: read-heavy evidence-gathering worker.

Custom agents are loaded from project and user roots with deterministic precedence:
project `.pixir/agents`, project `.codex/agents`, user `~/.pixir/agents`, user
`~/.codex/agents`, then built-ins. Duplicate names produce visible warnings; selected
custom agents override lower-precedence entries and built-ins. Agent files use a small
TOML-compatible subset: `name`, `description`, `developer_instructions`, and optional
`model`, `model_reasoning_effort`, and `sandbox_mode`.

Unlike the current tool-backed Codex limitation reported in openai/codex#15250, Pixir's
tool surface resolves named custom agents directly through `spawn_agent`.

The model-facing v1 surface is ADR 0005-compliant Tools: `spawn_agent`, `wait_agent`,
`send_input`, `close_agent`, and `list_agents`. Listing and waiting are read-only.
Spawning, sending input, and closing are lifecycle mutations and therefore go through
the existing permission policy. Child agents inherit the parent's permission posture
unless their agent config narrows it to read-only.

## Consequences

- Pixir can run tens or hundreds of lightweight child workers while keeping lifecycle
  state supervised and observable.
- Parent context remains smaller because child logs are summarized instead of replayed
  wholesale.
- Resume/fork can reconstruct Subagent relationships and terminal outcomes from the
  parent Log.
- Child Turns receive their own delegation identity and limits without changing the
  stable Prompt Contract prefix for every Session.
- Manager restart can reattach still-running child Sessions and rearm their timeout from
  durable deadline evidence; children without a live handle remain explicit `detached`
  projections.
- Parallel write-heavy workflows remain safer by default because isolated child
  workspaces prevent accidental cross-agent file interference.

## References

- OpenAI Codex docs, "Subagents": https://developers.openai.com/codex/subagents
- openai/codex#15250, custom subagents in tool-backed sessions:
  https://github.com/openai/codex/issues/15250
