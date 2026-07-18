# AGENTS.md — Pixir Monitor

## Purpose

This tree is the standalone `:pixir_monitor` application: a loopback-only, read-only Phoenix/Bandit presenter for recomputable Pixir run projections.

## Truth boundary

Pixir Logs remain truth. `PixirMonitor.RunSource` rereads authoritative projections; browser state is disposable. The invalidation hub carries only bounded `projection_changed` identifiers and never stores snapshots, execution, gates, advisories, usage, or mutation facts.

## Security invariants

- Bind literal `127.0.0.1` on port `0`; validate the exact active-port Host and ignore forwarded Host headers.
- Launch capabilities are one-use, in-memory, 30-second fragment values. Browser sessions are opaque, HttpOnly, SameSite=Strict, session-only cookies.
- `/bootstrap` is the sole security-state transition. No runtime, Workflow, Session, workspace, evidence, apply, retry, resume, cancel, shell, policy, or file-open route exists.
- Every response is `no-store`; all projected strings are text only. No remote assets, telemetry, service worker, Markdown, auto-links, `innerHTML`, or executable clipboard/path affordance.
- Never log, print, persist, return as JSON, or expose launch/session capability bytes.
- Preserve `priv/presenter/**` byte-exact.

## Owned paths

Monitor application code, config, tests, and self-hosted assets live below this directory. Do not change Pixir root files from this subtree.

## Verification

```sh
cd monitor
mix deps.get
mix compile --warnings-as-errors
mix test
mix format --check-formatted
mix escript.build
./pixir-monitor --help
./pixir-monitor serve --dry-run --json
```
