# Agent Tool Adapter Contract For Subagents Benchmarks

Pixir's Subagents benchmark tooling is intended to be operated by root agents, not only
humans. The adapter contract is:

```text
discover -> dry_run -> run -> validate_records -> reconcile_report -> completion_audit
```

## Commands

```bash
mix pixir.bench.subagents --help
mix pixir.bench.subagents --dry-run --json
mix pixir.bench.subagents --json

mix pixir.bench.real_subagents --help
mix pixir.bench.real_subagents --dry-run --json
mix pixir.bench.real_subagents --models gpt-5.5 --reasoning-effort low --n-values 1,3,5 --repetitions 3 --include-baseline --json

mix pixir.bench.codex_pressure --help
mix pixir.bench.codex_pressure --dry-run --json
mix pixir.bench.codex_pressure --profile pixir-runtime-only --dry-run --json
mix pixir.bench.codex_pressure --profile codex-app-stack --dry-run --json
mix pixir.bench.codex_pressure --target-n 8 --configured-limit 20 --duration-seconds 120 --json

mix pixir.bench.fanout_gauntlet --help
mix pixir.bench.fanout_gauntlet --dry-run --json
mix pixir.bench.fanout_gauntlet --mode direct --pixir-bin ./pixir --json
mix pixir.bench.fanout_gauntlet --mode parent --parent-n 4 --timeout-ms 500 --json
mix pixir.bench.fanout_gauntlet --json

bin/pixir-runtime-trust-gauntlet --help
bin/pixir-runtime-trust-gauntlet --list-scenarios --json
bin/pixir-runtime-trust-gauntlet --fixture-dir <dir> --json --fail-on-blocker --require-all-scenarios

bin/pixir-projection-parity-gauntlet --help
bin/pixir-projection-parity-gauntlet --list-scenarios --json
bin/pixir-projection-parity-gauntlet --dry-run --json
bin/pixir-projection-parity-gauntlet --runtime-truth-result runtime-truth.json --json --fail-on-blocker
```

Paired local T3 harnesses remain local-only:

```bash
bun scripts/pixir-subagents-benchmark.ts --help
bun scripts/pixir-subagents-benchmark.ts --dry-run --json

bun scripts/codex-subagents-observability-probe.ts --help
bun scripts/codex-subagents-observability-probe.ts --dry-run --json
```

## Structured Result Shape

Successful machine-readable commands emit:

```json
{
  "ok": true,
  "mode": "dry_run|run",
  "would_run": [],
  "would_write": [],
  "summary": {}
}
```

Recoverable failures emit:

```json
{
  "ok": false,
  "error": {
    "kind": "missing_t3_checkout",
    "message": "Paired T3 Code checkout was not found.",
    "details": {},
    "root_agent_hint": "Verify --t3-code-path points to the local T3 checkout before rerunning."
  }
}
```

## Evidence Policy

Do not treat command exit alone as completion. Completion requires:

- `runs.jsonl` exists and contains one JSON object per planned run.
- Every `runs.jsonl` record validates against the benchmark record schema for the
  requested scenario.
- `summary.json` exists and has `requirements` with all required booleans true for the
  requested scenario, and validates against the summary schema.
- `report.md` exists and matches the same run id.
- `completion_audit.json` exists when the adapter claims `completion_ready`, and every
  audit requirement is `proved`.
- Real-network runs include accepted model, reasoning effort, lifecycle counts, duration,
  RSS samples, and raw provider artifacts.
- Dry-runs report planned commands, writes, requirements, and estimated real-network run
  count without invoking providers.
- Fanout gauntlet runs distinguish correctness and honest partial outcomes from resource
  pressure evidence; a parent-led timeout fixture must be reported as partial evidence,
  not as clean completion.
- Runtime-truth gauntlet runs distinguish clean completion from partial, failed,
  timed-out, interrupted, Subagent, and Workflow terminal evidence. A full join-gate
  run should use `--require-all-scenarios` so missing coverage is a blocker.
- Projection-parity gauntlet runs join runtime-truth output with optional Presenter
  packets. Missing refreshed T3/Zed packets are a warning in the first slice; invalid
  supplied packets or runtime-truth blockers are Registry blockers.

## Proof Closure States

```text
intent_declared
-> cli_contract_available
-> dry_run_passed
-> structured_errors_proved
-> benchmark_records_produced
-> records_validated
-> schema_validated
-> report_reconciled
-> skill_ready
-> completion_ready
```

This contract is deliberately small. It is enough for a future Skill to operate the
benchmarks safely without turning the benchmark scripts into a general-purpose CLI
framework.
