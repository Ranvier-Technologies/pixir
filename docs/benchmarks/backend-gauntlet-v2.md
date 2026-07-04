# Backend Gauntlet V2

Status: executable no-network join gate

## Purpose

Backend gauntlet v2 is the proof gate for issue #93. It composes Pixir's
runtime-truth fixture checker with the fanout regression gauntlet so backend
runtime semantics can be evaluated without relying on T3, Zed, or screenshots.

It is a correctness and evidence gate, not a performance benchmark.

## Command

```bash
bin/pixir-backend-gauntlet-v2 --help
bin/pixir-backend-gauntlet-v2 --dry-run --json
bin/pixir-backend-gauntlet-v2 --mode runtime-truth --json
bin/pixir-backend-gauntlet-v2 --mode fanout --json
bin/pixir-backend-gauntlet-v2 --json
```

Child subprocess controls:

```bash
bin/pixir-backend-gauntlet-v2 --child-timeout-seconds 120
bin/pixir-backend-gauntlet-v2 --mode fanout --mix-bin mix --json
```

`--child-timeout-seconds` bounds each child gauntlet command. `--mix-bin`
selects the Mix executable used by the fanout component, which keeps missing
command diagnostics host-independent and testable.

Default output is local runtime state:

```text
.pixir/benchmarks/backend-gauntlet-v2/<timestamp>/
```

That directory is gitignored.

## Components

### Runtime Truth

The runtime-truth component generates a complete sanitized fixture set for
scenarios `T0` through `T11`, then runs:

```bash
bin/pixir-runtime-trust-gauntlet \
  --fixture-dir <output>/runtime-truth-fixtures \
  --json \
  --fail-on-blocker \
  --require-all-scenarios
```

This proves the Turn/Event/replay/presenter contract at fixture level:

- clean assistant completion,
- partial assistant plus provider error,
- provider error before text,
- tool-call pairing,
- Subagent timeout evidence,
- Workflow partial outcome,
- ACP partial replay guard,
- replay/cache failure exclusion,
- client parity fixture,
- turn timeout/interruption,
- Subagent completion,
- Workflow full completion.

### Fanout

The fanout component runs:

```bash
mix pixir.bench.fanout_gauntlet --json --output <output>/fanout
```

This proves direct CLI fanout and parent-led Subagent fanout using no-network
fixtures. The parent-led fixture intentionally includes a timeout. Success means
the timeout is classified as honest partial evidence with child id, reason,
duration, timeout, and next actions.

## Artifacts

```text
runtime-truth-fixtures/
runtime-truth-result.json
runtime-truth-stdout.txt
runtime-truth-stderr.txt
fanout/
fanout-result.json
fanout-stdout.txt
fanout-stderr.txt
summary.json
completion_audit.json
report.md
```

`completion_audit.json` is the proof-closure artifact. A run is completion-ready
only when every requirement for the selected mode is proved.

## Interpretation

Use this gauntlet as backend evidence for release or ACP Registry confidence
after runtime semantics changes. It answers:

- Are runtime-truth scenarios completely covered?
- Is the backend free of blockers?
- Do Subagent timeouts stay explicit and actionable?
- Do fanout runs produce artifact-backed completion evidence?
- Are functional outcomes separated from resource pressure?

Do not use this gauntlet to claim Pixir is faster, cheaper, or less resource
intensive than another runtime. Use `mix pixir.bench.codex_pressure` for local
RSS/CPU/swap sampling and treat those results as a separate evidence stream.
