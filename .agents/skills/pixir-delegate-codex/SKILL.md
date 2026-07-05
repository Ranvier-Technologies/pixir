---
name: pixir-delegate-codex
description: "Use when a Codex CLI/Desktop root should fan out subagents, delegate to Pixir workers, run parallel workers, or manage a resident delegation daemon via Pixir Delegate; covers Codex preflight, AGENTS.md, approvals/sandbox, dry-run, daemon start/status/attach/cancel, and closure evidence."
---

# Pixir Delegate Codex — Pixir workers from a Codex root

You are the Codex CLI/Desktop root orchestrator. Pixir is the worker runtime.
On first use in a session, read the shared practice core at
`../pixir-delegate/references/delegation-core.md`. Do not re-invent its
routing, refusal, sizing, contracts, closure, or evidence doctrine here; this
file only maps that doctrine onto Codex mechanics.

## PREFLIGHT — explicit, no hydration

Codex has no `!` command preprocessing. Before any delegation, explicitly choose
and report the Pixir binary you will drive:

1. Resolve the binary as an absolute path. Prefer an intentional repo-local
   source binary (`./pixir` in the target checkout) over a PATH hit; stale PATH
   binaries are a known failure mode.
2. Run `<PIXIR_BIN> --version` and `<PIXIR_BIN> doctor --json`.
3. In the doctor JSON, find the check with `"id": "source_install_binary"` and
   report its status plus details path; do not treat a PATH version string as
   proof that the source checkout binary is current.
4. Classify readiness exactly as the core says:
   - `ready`: may delegate.
   - `ready_with_warnings`: inspect every non-passed check and judge. A missing
     local source build may be non-blocking for a PATH-driven run; failed auth or
     unwritable workspace is not.
   - blocked/error/non-JSON/no binary: do not delegate.
5. Record: absolute binary path, version, doctor status, source_install_binary
   check, and readiness classification for the closure report.

Doctor status and the `source_install_binary` check are part of the runtime
contract (`lib/pixir/doctor.ex:22-31`, `lib/pixir/doctor.ex:81-105`,
`lib/pixir/doctor.ex:251-257`).

## Codex command posture

There is no Claude-style `allowed-tools` field here. Codex approval mode and
sandboxing decide whether the root may execute shell commands; Pixir specs decide
what children may do. If the Codex host is read-only, stay with read-only Pixir
workers or ask before changing posture. If approval is required for a command,
obtain it before running the Pixir CLI; do not smuggle side effects through a
child.

Prefer machine-readable commands:

- `<PIXIR_BIN> help`
- `<PIXIR_BIN> delegate --spec spec.json --dry-run --json`
- `<PIXIR_BIN> delegate --spec spec.json --json --timeout-ms N`
- `<PIXIR_BIN> delegate start --spec spec.json --json --timeout-ms N`
- `<PIXIR_BIN> delegate status|attach|cancel HANDLE --json`
- `<PIXIR_BIN> tree PARENT_SESSION_ID --json`

Parse JSON yourself or with an approved JSON tool. If stdout is not one valid
JSON envelope when one was requested, the run failed; inspect stderr and logs.

## Spec discovery and rehearsal

Use the runtime as the source of truth. Generate the intended spec, then run the
dry-run form before the first real delegation and after any schema or permission
change. Treat structured errors and `next_actions` as the current contract.

For fan-out, enter Pixir once and let BEAM coordinate workers; do not launch N
independent shell processes. The CLI contract explicitly rejects caller-side
process-per-child fanout (`lib/pixir/delegate/cli_contract.ex:11-13`,
`lib/pixir/delegate/cli_contract.ex:33-37`).

Every child task prompt must be self-contained because children do not inherit
the Codex conversation. Include the output schema, relevant repo instructions,
line-range citation requirements (`file:start-end`), and sectioned-read guidance
for large files.

## AGENTS.md is repo law

Before delegating, Codex must read the root `AGENTS.md` and the nearest
`AGENTS.md` files for the directories the work will touch. Pixir children also
read the workspace's AGENTS.md, but the root must not assume they inherit the
root's conversation, decisions, or private scratch context. Put any
child-relevant obligations directly in each task prompt, especially directory
scope, validation commands, and forbidden actions.

## Permissions, approvals, and write boundaries

Map the work to both layers:

- Read-only exploration: use an explorer/read-only role and `mode: read_only`
  (or the current dry-run-discovered equivalent). This fits Codex read-only
  sandboxing and Pixir's safe read posture.
- Bounded writes: only use `mode: bounded_write` with an explicit
  `write_policy` discovered and accepted by dry-run. The Codex root must also be
  in a posture that permits those writes, with user approval if required.
- Multiple writers: only if the write policies are disjoint and dry-run accepts
  them. Otherwise serialize or keep children read-only.
- A dry-run write-policy rejection is binding. Do not weaken the spec, widen the
  sandbox, or reroute through shell without explicit approval and a new dry-run.

## Attached delegation mode

Use attached mode when the root can wait for completion in one Pixir invocation:
dry-run, then `<PIXIR_BIN> delegate --spec spec.json --json --timeout-ms N`.
This returns one envelope and durable child sessions. Reconcile `command_ok`,
`work_complete`, child statuses, and logs; never collapse shell exit code into
work success. Budget timeout for waves when child count exceeds concurrency.

## Resident daemon mode — lifecycle for a long-lived Codex root

Use service mode when the Codex root is resident and wants handles it can inspect
later. Be honest about today's limits:

- The daemon is manual, foreground, workspace-local, and loopback-only. It is not
  auto-started, not launchd/systemd, not HTTP, and not production service
  management (`lib/pixir/delegate/daemon_server.ex:2-13`,
  `lib/pixir/delegate/daemon_server.ex:21-22`,
  `lib/pixir/delegate/daemon_command.ex:5-24`).
- Start one daemon per workspace in a dedicated terminal:
  `<PIXIR_BIN> delegate daemon --foreground --json`. Keep it alive.
- From the same workspace, check:
  `<PIXIR_BIN> delegate daemon --status --json`. Status may return structured
  states such as absent, stale_endpoint, unavailable, invalid_endpoint,
  workspace_mismatch, or auth_failed when the daemon is unreachable
  (`lib/pixir/delegate/daemon_client.ex:95-124`,
  `lib/pixir/delegate/daemon_client.ex:350-386`).
- Rehearse the spec with attached dry-run; `delegate start` itself is the service
  start command, not the dry-run surface.
- Start work:
  `<PIXIR_BIN> delegate start --spec spec.json --json --timeout-ms N`. Save both
  `delegate_id` and `parent_session_id`.
- Observe:
  `<PIXIR_BIN> delegate status HANDLE --json` for durable/log-folded status.
- Attach:
  `<PIXIR_BIN> delegate attach HANDLE --json` is ordinary snapshot attach:
  `mode: one_shot_snapshot`, `streaming: false`
  (`lib/pixir/delegate/async.ex:107-118`,
  `lib/pixir/delegate/async.ex:315-343`).
- Optional progress:
  `<PIXIR_BIN> delegate attach HANDLE --json --progress=stderr-jsonl --wait-horizon-ms N`
  requests daemon follow frames, with bounded JSONL on stderr and one final JSON
  envelope on stdout. Treat it as best-effort owner-backed follow, not a general
  interactive streaming UI (`lib/pixir/delegate/cli_contract.ex:17-28`,
  `lib/pixir/delegate/daemon_server.ex:286-317`).
- Cancel:
  `<PIXIR_BIN> delegate cancel HANDLE --json`. Active cancellation requires a
  live owner. If the envelope says `owner_unavailable`, `snapshot_only`, or
  `stale_handle`, you have durable evidence only; do not claim live work was
  interrupted (`docs/adr/0034-delegate-runtime-residency.md:58-70`,
  `lib/pixir/delegate/owner.ex:10-22`,
  `lib/pixir/delegate/owner.ex:144-175`).
- Stop:
  `<PIXIR_BIN> delegate daemon --stop --json`, then confirm with
  `daemon --status`.

`status`, ordinary `attach`, and some `cancel` results can fall back to durable
Log snapshots when the daemon is unreachable; active streaming/cancel cannot.
ADR 0034 is the source of truth for the split between durable identity and live
capability (`docs/adr/0034-delegate-runtime-residency.md:23-37`,
`docs/adr/0034-delegate-runtime-residency.md:89-101`,
`docs/adr/0034-delegate-runtime-residency.md:129-142`).

## Evidence and tree inspection

Pixir child sessions are durable logs. Use the returned `parent_session_id` for
diagnostics and tree inspection. In JSON tree output, subagents are under
`.tree.subagents`, not `.children`; the SessionTree node field is `subagents`
(`lib/pixir/session_tree.ex:86-95`, `lib/pixir/session_tree.ex:237-249`).

For service mode, reconcile from status/attach snapshots when streaming is not
available. If the daemon is gone, durable snapshots are still evidence; they are
not proof of live ownership.

## Closure pointer

Closure discipline is the core's discipline: reconcile every child, parse every
declared JSON result, disposition every non-completed child, and recover per
child rather than rerunning the whole batch. Daemon-specific addition: if attach
streaming is unavailable, close from `status`/snapshot envelopes and state that
the evidence was durable-only.

## Closure report checklist

Include, briefly:

- Pixir binary: absolute path, version, doctor status, source_install_binary
  check, readiness classification.
- Delegation gate: why delegation was appropriate per the core, or why it was
  refused.
- Dry-run: command/spec used and whether accepted; note structured next_actions.
- Runtime envelope: command, delegate_id, parent_session_id, command_ok,
  work_complete/status, timeout/concurrency.
- Per-child disposition: completed, retried/resumed, cancelled, timed out, or
  reported partial, with evidence citations.
- Side effects: files changed or confirmed none; approvals/sandbox posture used.
- Daemon, if used: foreground daemon status, attach mode observed, fallback or
  owner_unavailable states, and stop/status result if stopped.