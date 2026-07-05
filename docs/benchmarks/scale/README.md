# Scale-evidence bundle

Redacted, reproducible evidence behind the numbers on [pixir.dev/scale](https://pixir.dev/scale).
Tracks public issue [#1](https://github.com/Ranvier-Technologies/pixir/issues/1).

All evidence originates from append-only session logs (`provider_usage` events,
see ADR 0019) and OS-level process sampling on the machine that ran the
benchmarks (macOS arm64, 32 GB RAM). Evidence is machine-local by design; this
bundle is a redacted export of aggregates and envelopes, not a hosted dataset,
and not the raw logs themselves. "subagent-duel" in file contents is the
internal name of the benchmark harness that produced these runs.

## Contents

| File | What it is |
|---|---|
| `audit64-spec.json` | The 64-task audit spec both arms ran; also the reproduction input (see below). |
| `audit64-envelope.redacted.json` | The full delegate envelope for the N=64 real-work run (64-task module doc-audit, read-only, 2026-07-05). One envelope per run; 64 `children[]` with status and session ids. |
| `audit64-children-usage.json` | Per-child provider usage rebuilt from each child's session log: calls, input/cached/output tokens, transport per call. Totals: 64/64 completed, 673 calls, 1,470,112 uncached input tokens, 120,645 output tokens. |
| `audit64-codex-summary.json` | The codex-exec x64 arm: per-task usage aggregated from each process's `turn.completed` events. Totals: 64/64 tasks, 1,812,137 uncached input tokens, 73,432 output tokens, 16 transport errors retried. Raw event streams are not published (they carry provider correlation ids). |
| `audit64-findings.md` | The cross-validated deliverable both arms produced: consensus and single-side doc-drift findings for the audited modules. |
| `synthetic-ladder-runs.jsonl` | Raw per-run aggregates for the synthetic ladder (N=1,2,4,8 x3 reps) across three arms: pixir-delegate, pixir-oneshot, codex-exec. Includes peak RSS, wall, tokens, transports. |
| `synthetic-ladder-summary.json` | Marginal RSS per extra child, per arm, with the aggregation table. |
| `synthetic-ladder-report.md` | The analyzer's human-readable report for the ladder runs. |
| `marginal-rss-ci95.json` | Bootstrap CI95 for marginal RSS per extra child, per arm, recomputable from `synthetic-ladder-runs.jsonl` (seeded, method stated in-file). Zero overlap between arms. |
| `scale16-32-runs.jsonl` | Per-run aggregates for the N=16 and N=32 scale runs (1 rep each). |
| `transport-evidence.json` | WebSocket pressure evidence: N=16 (32/32 calls) and N=32 (68/68 calls) all-websocket; one transient fallback in a single N=8 ladder rep (the other two N=8 reps were all-websocket); at N=64 real work, 31 of 673 calls fell back WS->SSE (17 handshake_failed, 13 degraded, 1 closed), zero losses. |
| `audit64-rss-samples-pixir.txt` | Process-tree RSS samples (KB, process count; ~1s cadence, 187 samples over the ~202s run) for the Pixir arm of the N=64 run. |
| `audit64-rss-samples-codex.txt` | Same sampling for the codex-exec x64 arm. |

## Honesty notes

- Memory numbers are **sampled process-tree peaks**, not exact accounting. The
  N=64 sample files included here poll at ~1s; the N=1..8 ladder peaks were
  sampled by the benchmark harness at a finer cadence and are published as
  aggregates.
- The CI95 intervals in `marginal-rss-ci95.json` are recomputed with a seeded,
  documented bootstrap so anyone can reproduce them from the published
  `synthetic-ladder-runs.jsonl`. Earlier public mentions of these intervals
  used a different resampling scheme; the zero-overlap conclusion is unchanged.
- N=16, N=32 and the N=64 real-work run are **1 rep each: directional**, not a
  distribution.
- At N=64 real work, **raw wall-clock favored codex exec**; memory (27x) is
  where the scaling wall lives. The N=32 synthetic wall crossover did not
  generalize to 64 real tasks. The two arms also did different depths of work
  (Pixir children averaged ~10.5 provider calls each; see usage files).
- Same-quota concession: Pixir does not create extra model capacity. Same
  ChatGPT quota, fewer uncached tokens per unit of work.
- Transport counts come from per-call `provider_usage` events; "zero losses"
  means every fallback call completed over http_sse and 64/64 children
  produced valid contracts. Fallback reasons are recorded per call in the
  session logs; this bundle publishes their tally.

## Reproduce

The 64-task audit spec ships in-repo at `docs/benchmarks/scale/audit64-spec.json`.
From a fresh clone:

```bash
mix deps.get && mix escript.build          # build ./pixir
./pixir delegate --spec docs/benchmarks/scale/audit64-spec.json --dry-run --json  # rehearse: no network, no auth
./pixir login    # or export OPENAI_API_KEY; the real run needs credentials
./pixir delegate --spec docs/benchmarks/scale/audit64-spec.json --json --timeout-ms 1200000
```

The real run consumes provider quota (~673 calls in our run) and writes session
logs under `.pixir/`. Your numbers will differ with hardware, provider routing,
and cache state; the shape (one BEAM VM, flat marginal memory per child,
per-call usage evidence in session logs) is the reproducible part.

## Redaction rules applied

- Absolute home paths replaced with `~`; the benchmark workspace path replaced
  with `<workspace>`.
- References to the private work tracker replaced with `private-tracker#<n>`
  (see the private-refs note in `docs/adr/README.md`).
- Prompt-cache routing keys (`cache_keys`, `prompt_cache_key`) stripped from
  published aggregates; codex raw event streams replaced by a derived summary
  because they carry provider correlation ids.
- No tokens, account ids, or response ids ever enter session logs (runtime
  policy); the export was additionally scanned for them.
- Child task prompts and summaries are retained verbatim: the workload audited
  Pixir's own public source, so summaries reference in-repo modules only.
