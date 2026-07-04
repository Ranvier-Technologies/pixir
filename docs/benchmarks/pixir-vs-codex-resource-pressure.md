# Pixir vs Codex Resource Pressure

Date: 2026-06-22
Status: profile and metric contract

## Goal Frame

Objective: compare local resource pressure for Pixir and Codex under comparable
operator scenarios without turning the benchmark into a model-quality contest.

This benchmark measures local machine pressure only. It can support claims about
observable RSS, CPU, process counts, thread counts when available, and system memory
context during a run. It cannot prove provider-side model memory, hidden Codex runtime
internals, or general model quality.

## Measurement Profiles

Profiles separate pure runtime pressure from daily-driver stack pressure.

| Profile | Purpose | Default process hints | Interpretation |
|---|---|---|---|
| `pixir-runtime-only` | Pixir runtime/escript pressure without a presenter-heavy client. | `pixir`, `beam.smp` | Best baseline for local BEAM runtime overhead, but `beam.smp` may match other Erlang VMs if they are running. |
| `codex-app-stack` | Codex desktop/app orchestration pressure visible on the local Mac. | `codex` | Best baseline for Codex-visible orchestration pressure. It does not expose hidden server/provider internals. |
| `t3-pixir-stack` | Pixir used through T3 Code as a daily-driver ACP presenter. | `T3 Code`, `Electron`, `pixir`, `beam.smp` | Measures presenter plus Pixir runtime pressure, not Pixir runtime alone. |
| `zed-pixir-stack` | Pixir used through Zed as an ACP presenter. | `Zed`, `pixir`, `beam.smp` | Measures Zed plus Pixir runtime pressure, not Pixir runtime alone. |
| `custom` | Explicit operator-selected process hints. | user supplied | Useful for local experiments; claims must disclose the selected patterns. |

The primary Pixir vs Codex baseline is `pixir-runtime-only` vs `codex-app-stack`.
T3 and Zed profiles are daily-driver stack measurements.

## Metric Matrix

| Metric | Pixir Method | Codex Method | Artifact | Interpretation | Caveat |
|---|---|---|---|---|---|
| Tracked RSS | Sum RSS for profile-matched Pixir process rows. | Sum RSS for profile-matched Codex process rows. | `samples.jsonl`, `summary.json` | Approximate local resident memory pressure for selected processes. | Pattern matching can over/under-count; RSS is not unique memory and is not provider memory. |
| Process-tree RSS | Group matching root processes with known descendants when available. | Same grouping for Codex-visible local processes when available. | `samples.jsonl`, `summary.json` | Better local stack attribution than flat process matching. | Requires reliable PID/PPID snapshots; short-lived children can be missed between samples. |
| CPU percent | Sum `ps` CPU percent for tracked rows. | Same. | `samples.jsonl`, `summary.json` | Local CPU pressure during the sampling window. | `ps` CPU is sampled and can be noisy for short runs. |
| Process count | Count profile-matched rows. | Same. | `samples.jsonl`, `summary.json` | Indicates fan-out shape and local runtime/process churn. | Count is not work completion; reconcile with run evidence. |
| Thread count | Record `ps` thread count if the platform exposes it. | Same. | `samples.jsonl`, `summary.json` | Useful signal for UI/runtime pressure. | Optional on first implementation; unsupported platforms must say so. |
| System used memory | Capture `vm_stat` used/free context. | Same sampling window. | `samples.jsonl`, `summary.json` | Shows whether the Mac was globally memory pressured. | System-wide context only; not attributable to Pixir or Codex alone. |
| Swap delta | Capture `vm_stat` swap counters across the run. | Same sampling window. | `summary.json`, `report.md` | Strong operator-pressure signal when it rises during a benchmark. | Global and cumulative; must not be assigned to one runtime without corroborating evidence. |
| BEAM memory | Query explicit Pixir/BEAM metrics only when Pixir can report them for the target VM. | Not applicable. | future `beam` section | Strong Pixir-specific runtime insight. | `:erlang.memory()` from the sampler VM is not evidence about a separate Pixir escript VM. |

## Scenario Matrix

| Scenario | Pixir Shape | Codex Shape | Success Evidence | Non-Comparable If |
|---|---|---|---|---|
| Simple one-turn | One short Pixir turn or ACP prompt. | One short Codex prompt/thread. | Assistant response, one benchmark packet, no tool fan-out. | The prompt or model path differs enough to change local work shape. |
| Tool-heavy read-only | Read several files and summarize without writes. | Same task contract in Codex. | Tool/read evidence plus benchmark packet. | One side refuses tools, mutates files, or uses different workspace scope. |
| Parallel/fan-out | Pixir subagents or workflow with bounded child count. | Codex visible threads/workers/subagents with the same target count where practical. | Lifecycle evidence, completion/reconciliation report, benchmark packet. | Child count or lifecycle visibility cannot be reconciled. |

## Execution Contract

The pressure sampler should remain a root-agent-friendly adapter:

```bash
mix pixir.bench.codex_pressure --help --json
mix pixir.bench.codex_pressure --dry-run --json
mix pixir.bench.codex_pressure --profile pixir-runtime-only --duration-seconds 60 --json
mix pixir.bench.codex_pressure --profile codex-app-stack --duration-seconds 60 --json
```

Expected artifacts:

```text
.pixir/benchmarks/resource-pressure/<run-id>/
  samples.jsonl
  summary.json
  report.md
  completion_audit.json
```

## No-Overclaim Rules

- Say "local process pressure", not "model memory".
- Say "system memory context", not "Pixir caused swap" or "Codex caused swap" unless
  the process evidence and timing make that attribution credible.
- Treat `pixir-runtime-only` vs `codex-app-stack` as a pragmatic baseline, not a pure
  BEAM vs Rust/runtime-internals comparison.
- Treat T3/Zed profiles as daily-driver stack evidence.
- Do not publish performance claims from one run. Use the matrix to choose follow-up
  repetitions and scenarios.
