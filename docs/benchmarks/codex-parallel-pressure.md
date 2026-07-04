# Codex Parallel Pressure Benchmark

Date: 2026-06-21
Status: executable local sampler; superseded by profile contract for Pixir vs Codex work

## Goal Frame

Objective: measure how much local Mac pressure Codex parallel work adds as the
operator increases visible threads or subagents.

For the newer Pixir vs Codex profile contract, including `pixir-runtime-only`,
`codex-app-stack`, `t3-pixir-stack`, and `zed-pixir-stack`, see
`docs/benchmarks/pixir-vs-codex-resource-pressure.md`.

The benchmark is deliberately narrower than a work-quality benchmark. It
measures local process and system pressure: RSS, CPU, `vm_stat` memory pressure,
and swap counters. It does not measure provider-side model memory, model
quality, token spend, or BEAM-vs-Codex correctness.

## Why This Exists

Codex parallelism may be useful for visible work lanes, but it can become heavy
when many agents run at once. Pixir also needs a sober comparison point for the
kind of local orchestration BEAM should handle cheaply: many supervised local
processes, bounded fan-out, and explicit lifecycle evidence.

## Executable Adapter

```bash
mix pixir.bench.codex_pressure --help
mix pixir.bench.codex_pressure --dry-run --json
mix pixir.bench.codex_pressure --target-n 8 --configured-limit 20 --duration-seconds 120
```

The command does not spawn Codex agents. Codex thread and subagent creation is a
runtime tool surface, not a shell API. Instead, start the sampler before a
parallel Codex run and reconcile the output with the actual spawned/completed
agent evidence.

## Evidence Artifacts

The adapter writes under `.pixir/benchmarks/codex-pressure/<run-id>/` by
default:

```text
samples.jsonl
summary.json
report.md
completion_audit.json
```

## Suggested Scaling Matrix

Run the same tiny, read-only Codex task at each target N:

| Target N | Purpose |
|---:|---|
| 1 | Baseline single-agent pressure |
| 2 | Two-lane dogfood shape |
| 4 | Comfortable parallel work |
| 8 | Above older observed defaults |
| 12 | Stress with higher configured limit |
| 20 | Only if the Mac remains responsive |

Record the configured Codex limit separately from target N. A higher
`config.toml` limit removes one bottleneck, but it does not prove memory or UI
scaling is acceptable.

## Completion Bar

A pressure claim is usable only when:

- the sampler records at least one sample,
- the target N and configured limit are recorded or explicitly unknown,
- the run has actual spawned/completed Codex evidence from the orchestrator,
- the report distinguishes local process pressure from provider/model memory,
- swap or UI slowdown is reported as pressure evidence, not as model failure.

## Recommended Interpretation

Use the benchmark to find the local knee of the curve: the N where peak RSS,
swapout delta, CPU, or operator-visible responsiveness degrades sharply. Treat
that as an operator safety limit for Codex parallel work on this Mac, not as a
universal Codex or model limit.
