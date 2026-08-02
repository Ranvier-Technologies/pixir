# Pixir Monitor

`monitor/` is the standalone, experimental, loopback-only, read-only Pixir web
Presenter. It is run from a source checkout and depends on Pixir by sibling path while
keeping Phoenix and Bandit outside Pixir core and the Pixir Hex package.

```sh
cd monitor
mix deps.get
mix compile --warnings-as-errors
mix test
mix format --check-formatted
mix escript.build
./pixir-monitor --help
./pixir-monitor self-check --json
./pixir-monitor serve --dry-run --json
./pixir-monitor serve --launch-mode fifo --dry-run --json
```

`serve` defaults to the existing Darwin-only automatic browser launch. For a Codex
sidecar or another external reader, opt in with `--launch-mode fifo`. The Monitor
creates its own private `0700` temporary directory and `0600` named pipe, then emits
a readiness frame on stderr containing only the non-secret FIFO path (`--json`
selects a bounded JSON frame). Open that path for reading; only after the reader is
connected (within the bounded 60-second reader window) does Monitor issue the
30-second, one-use launch capability and write its URL through the pipe. Do not pass
a FIFO path to Monitor; caller-owned paths are not accepted.

## The launch handoff never ends serving

A launch handoff is auxiliary. Once the listener and the workspace projection are
healthy, `serve` reaches its serving state and stays there whatever the handoff does.
Only failures that make serving itself impossible — application load, workspace
resolution, port acquisition — still exit nonzero.

**Attach the reader before or promptly after the readiness frame.** The reader is
expected to open the announced path within the bounded 60-second reader window. It no
longer has to win a race: if the reader arrives after the writer is gone, closes the
pipe early, or never arrives at all, Monitor emits one `launch_degraded` frame naming
the failing `kind` and **re-arms** a fresh private directory, FIFO, and bounded writer,
announcing the new path in a new readiness frame. The previous attempt's private
directory is removed, so at most one is live at a time.

An automated supervisor keys on these stderr frames:

| frame | meaning |
| --- | --- |
| `status: "ready"`, `event: "launch_ready"`, `fifo_path` | this path is the currently valid FIFO; a later readiness frame supersedes an earlier one |
| `status: "launch_degraded"`, `kind` | that attempt failed; a readiness frame follows unless the bound is exhausted |
| `status: "launch_surface_exhausted"`, `rearm_limit` | terminal: no further FIFO will be armed, and serving continues without one. Carries `kind` when the surface stopped on an unclassified handoff error rather than on the re-arm bound |

**The re-arm bound is 16 re-arms** after the initial arm. It is reported in the
dry-run plan as `launch_surface.rearm_limit`. On exhaustion Monitor keeps serving.

A **successful** handoff also re-arms, so a second browser session needs no restart.
The capability itself stays strictly one-use: every handoff issues its own fresh,
TTL-bounded capability from the vault, none is reused or retained, and no capability
byte appears in any frame, error, log, or on stdout. When the vault refuses issuance
(`launch_limit`), Monitor reports the refusal and keeps serving.

In darwin mode the serving stdout frame carries a bounded `launch` object whose
`status` is `succeeded`, `failed` (with the `browser_open_failed` kind), or
`not_attempted` (for example `unsupported_platform` off macOS). A launcher failure is
reported there, never as exit 1. Send **`SIGUSR2`** to re-enter: Monitor mints a fresh
one-use capability and hands it to the launcher again without a restart. SIGUSR1 is
deliberately not used — ERTS reserves it for its crash-dump handler.

Dry-runs report the selected launch mode, the re-arm bound, and the re-entry signal,
but create neither a FIFO nor a launch capability. FIFO mode is portable where named
pipes are supported and never invokes macOS browser automation. Its bounded writer
requires `sh`, `kill`, and `perl` on the local host; setup fails structurally before
readiness when any is unavailable.

`self-check` exercises the built escript over real HTTP on its ephemeral
`127.0.0.1` listener. It performs the one-use bootstrap internally, fetches the
BEAM-embedded `app.js` and `app.css`, and validates `/api/runs` without printing or
persisting the launch capability.

The reusable real-browser acceptance harness lives at
`test/support/browser_harness.mjs`. After `mix escript.build`, invoke
`node test/support/browser_harness.mjs --help` for its bounded CLI contract, or use
`--dry-run --json` with the required `--monitor`, `--workspace`, `--run-id`,
`--unit-id`, and `--browser` arguments to validate inputs without starting a child.
The normal run uses the real built escript and Chrome DevTools Protocol to cover
Runs/Detail/Unit plus Follow route entry/exit, reload and history, authoritative
refetch restoration, terminal/unavailable/identity-disappeared degradation, missing
Unit honesty, malformed/duplicate/gapped invalidations, stream error/reconnect, and
navigation during an in-flight fetch. Response variants are injected only in the
browser's local HTTP boundary; no provider or network call is used. Every success and
failure path reaps Monitor/Chrome and removes the private browser profile and FIFO.

## Large-Workflow rendering

The initial overview DOM is bounded by clusters, not units, and is measured as scale-independent between the 100-unit and 500-unit fixtures. Member pages are sized at 12, edge ledger pages are sized at 100, and expansion bounds are enforced by a committed bench gate. Performance evidence is measured on a single local host; no cross-machine performance claim is made.

The application uses the filesystem projection source by code default, independent of
runtime `config.exs`. The Runs inventory reads a bounded newest-N selection and exposes
its total, selected, and truncated counts, so an inventory larger than the selection
limit remains inspectable. Inventory rows deliberately fold only each parent Log: their
attention count is a labeled lower bound and their reason list contains only
parent-observed reasons. Run Detail may reveal additional child-Log-derived attention.
The inventory never scans every child Log merely to claim completeness. Pixir Logs
remain authoritative; the Monitor has no Presenter store.

A bounded watcher observes only Log directory entries and regular-file metadata. It
publishes non-normative `projection_changed` hints, and the SSE hub coalesces pending
hints per subscriber. SSE connections rotate after 300 seconds. Initial load, hints,
rotation, reconnect, and stream errors require an authoritative HTTP refetch rather
than reconstruction from event order.

Listener-port discovery follows Endpoint restarts, clears stale port state, and exposes
bounded discovery exhaustion without retry-log flooding. Automatic browser launch is
supported only on Darwin. It transfers the in-memory launch URL to a short-lived,
bounded `osascript` launcher through that process's private environment; capability
bytes are never placed in process arguments or files, and launcher output — which an
AppleScript error can taint with the resolved URL — is discarded unread, so capability
bytes never reach diagnostics. A launcher that outlives its absolute deadline is
killed, not abandoned. Process environments are readable only by the same UID (and
root), matching the Monitor's adjudicated local threat model.

The HTTP surface binds only literal IPv4 loopback on an ephemeral port and has no
runtime, Workflow, workspace, evidence, or projection-input mutation controls. Pixir
Monitor remains source-only and experimental: it has no Hex or packaged install path
and makes no production-support promise.
