# Fanout Regression Gauntlet

Date: 2026-06-23
Status: executable no-network correctness gate

## Purpose

This gauntlet checks Pixir fanout reliability and outcome honesty. It is not a
public performance benchmark.

The goal is to make these failure modes visible before they become product claims:

- direct CLI fanout that exits `0` but produces no useful output,
- hidden stderr or failed exit codes,
- parent-led Subagent fanout that presents partial work as clean completion,
- Subagent timeouts without child ids, reasons, durations, or next actions,
- reports that mix functional completion evidence with resource pressure evidence.

For local RSS/CPU/swap sampling, use `mix pixir.bench.codex_pressure`. For broader
Subagent stress history, see `docs/benchmarks/subagents.md`.

## Command

```bash
mix pixir.bench.fanout_gauntlet --help
mix pixir.bench.fanout_gauntlet --dry-run --json
mix pixir.bench.fanout_gauntlet --json
mix pixir.bench.fanout_gauntlet --mode direct --pixir-bin ./pixir --direct-n 3 --json
mix pixir.bench.fanout_gauntlet --mode parent --parent-n 4 --timeout-ms 500 --json
```

Default output is local runtime state:

```text
.pixir/benchmarks/fanout-gauntlet/<run-id>/
```

That directory is gitignored.

## Modes

### Direct CLI Fanout

Direct mode launches safe no-network Pixir CLI commands concurrently:

- `pixir --version`
- `pixir doctor --json`
- `pixir help`

Each run records:

- command descriptor,
- stdout and stderr,
- exit code,
- session id when discoverable,
- terminal outcome,
- diagnostic issues.

A command that exits `0` with empty stdout is treated as false success and fails the
gauntlet.

### Parent-Led Subagent Fanout

Parent mode uses Pixir's in-process Subagent seam with fake providers. The default
fixture intentionally creates a mixed outcome: some children complete, and one child
times out.

The success bar is not "everything green". The success bar is honest partial evidence:

- parent outcome is `partial_honest`,
- child ids are recorded,
- timed-out children include `reason`, `timeout_ms`, `elapsed_ms`, and `next_actions`,
- `Pixir.SessionDiagnostics` reports timeout warnings instead of failed or missing
  evidence,
- the report keeps resource pressure out of the functional completion section.

## Artifacts

```text
direct_runs.jsonl
parent_runs.jsonl
summary.json
report.md
completion_audit.json
```

`completion_audit.json` is the proof-closure artifact. A run is completion-ready only
when every requirement relevant to the requested mode is `proved`.

## Interpretation

Use this gauntlet as a regression guard before claiming fanout reliability or before
expanding ACP Registry / client-facing dogfood. It should answer:

- Did every run produce bounded, inspectable evidence?
- Did any false success become visible?
- Did Subagent timeouts remain actionable instead of looking like normal completion?
- Are functional outcomes separated from local resource pressure?

Do not use this gauntlet to claim Pixir is faster than Codex, Claude Code, or another
runtime. It does not sample process pressure, compare model quality, or run live
network tasks.
