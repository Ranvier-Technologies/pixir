# AGENTS.md - Pixir Benchmarks

> Source guidance for benchmark specs, benchmark adapters, and benchmark reports. This
> does not apply to generated `.pixir/benchmarks/` outputs except when reading them as
> evidence.

## Progressive Discovery

1. **Start here:** this file after the root `AGENTS.md` when the task touches benchmark
   design, benchmark reports, `mix pixir.bench.*` tasks, or paired local T3 harnesses.
2. **Adapter contract:** read `agent-tool-adapter-contract.md` before changing CLI
   surfaces. It defines the discover -> dry_run -> run -> validate_records ->
   reconcile_report -> completion_audit loop.
3. **Benchmark intent:** read only the relevant benchmark spec:
   - `subagents.md` for deterministic Pixir-native and T3-visible Subagents benchmark
     design.
   - `real-network-subagents.md` for real provider runs, RAM/process-tree RSS, model
     comparability, and representative review scenarios.
   - `codex-parallel-pressure.md` for local Mac pressure sampling during Codex
     thread/subagent fan-out.
4. **Evidence summaries:** read `subagents-report.md` only when updating historical
   evidence or explaining previous runs.
5. **Code surfaces:** inspect the matching executable source only after the docs above
   identify the benchmark layer:
   - `lib/mix/tasks/pixir.bench.subagents.ex` for deterministic no-network Pixir stress.
   - `lib/mix/tasks/pixir.bench.install_t3_harnesses.ex` for installing Pixir-owned
     local-only harness templates into the paired T3 checkout.
   - `lib/mix/tasks/pixir.bench.real_subagents.ex` for real-network orchestration
     through paired local T3 harnesses.
   - `docs/benchmarks/t3-harnesses/` for canonical Pixir-owned copies of the local-only
     T3 harness templates.
   - `$T3_CODE_PATH/scripts/pixir-subagents-benchmark.ts`
     for the installed local T3 -> Pixir ACP harness.
   - `$T3_CODE_PATH/scripts/codex-subagents-observability-probe.ts`
     for the installed local T3 -> Codex observability harness.

## Screaming Architecture

The benchmark source should reveal the layer being measured:

- `docs/benchmarks/*.md` - committed benchmark specs, contracts, and summarized evidence.
- `mix pixir.bench.subagents` - deterministic no-network Pixir stress adapter using
  fake provider seams.
- `mix pixir.bench.real_subagents` - real-network wrapper that plans and runs paired T3
  harnesses, samples peak process-tree RSS, validates raw records, and reconciles
  reports.
- `mix pixir.bench.codex_pressure` - local macOS sampler for process RSS, CPU,
  `vm_stat` memory pressure, and configured/target Codex parallelism metadata.
- `mix pixir.bench.install_t3_harnesses` - installs Pixir-owned T3 harness templates
  into the paired local T3 checkout with dry-run and conflict protection.
- T3 harness templates - committed under `docs/benchmarks/t3-harnesses/` as Pixir-owned
  local benchmark adapters. Installed copies in the paired T3 checkout should not be
  upstreamed unless the user explicitly asks.
- `.pixir/benchmarks/**` - ignored runtime evidence. Read it to validate claims; do not
  commit it or design instructions around its existence.

## Adapter Invariants

- Every benchmark command intended for agents has `--help`, `--dry-run`, and `--json`.
- Dry-runs report planned commands, writes, requirements, and estimated real-network run
  count without invoking providers.
- Deterministic Pixir-native runs write `runs.jsonl`, `summary.json`, `report.md`, and
  `completion_audit.json`; completion requires `schema_validation.status = "passed"` and
  `completion_audit.status = "completion_ready"`.
- Real-network runs also write `completion_audit.json`; `summary.json` must include
  `schema_validation` and `completion_audit`. For `common_model_gate`, completion is
  either `common_model_smoke_ready` or an explicit non-comparable abort with
  `completion_audit.status = "completion_ready"`.
- Recoverable failures emit structured JSON:
  `%{"ok" => false, "error" => %{"kind" => kind, "message" => message, "details" => details}}`.
- Do not silently coerce invalid inputs such as bad providers, bad N values, or zero
  repetitions. Return a structured error that a root agent can act on.
- Real-network benchmarks are cost-bearing. Prefer `--dry-run --json` first, keep default
  runs small, and make larger N/repetition suites explicit.
- When reporting memory, say `peak process-tree RSS`; do not call it model memory or
  provider memory.
- Benchmark claims should distinguish runtime observability, subagent capability, model
  acceptance, latency, RAM, and work-quality scoring. Do not collapse them into one
  winner claim.

## Verification

For Pixir benchmark source changes:

```bash
mix format --check-formatted
mix compile --warnings-as-errors
mix test
git diff --check
```

For targeted adapter checks:

```bash
mix pixir.bench.subagents --json --help
mix pixir.bench.subagents --dry-run --json
mix pixir.bench.install_t3_harnesses --json --help
mix pixir.bench.install_t3_harnesses --dry-run --json
mix pixir.bench.real_subagents --json --help
mix pixir.bench.real_subagents --dry-run --json
```

For paired local T3 harness changes, stay in `$T3_CODE_PATH` and use Node 24:

```bash
source ~/.nvm/nvm.sh && nvm use 24
bun run fmt --check scripts/pixir-subagents-benchmark.ts scripts/codex-subagents-observability-probe.ts
bun run typecheck --filter='t3' --force
git diff --check
```

Keep T3 changes local-only unless the user explicitly asks to push or open an upstream
T3 Code PR.
