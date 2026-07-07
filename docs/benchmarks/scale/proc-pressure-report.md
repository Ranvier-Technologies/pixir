# proc-pressure: the macOS kernel tax of process-per-worker fan-out

**Status: measured (Tier 1; Tier 2 both conditions; Tier 3 loaded + quiet
spot-check); report gate passed (4-lens adversarial fan-out, 23/23 findings
applied). This copy is the public evidence bundle.**


## Bundle map (how in-text references map to public files)

This report ships inside the public evidence bundle at
`docs/benchmarks/scale/`. Private working paths referenced in the body map
to bundle files as follows:

| In-text reference | Bundle file |
|---|---|
| `tier1-runs.jsonl` | `proc-pressure-tier1-runs.jsonl` |
| `tier2/runs.jsonl` | `proc-pressure-tier2-loaded-runs.jsonl` |
| `tier2/tier2-summary.json` | `proc-pressure-tier2-loaded-summary.json` |
| `tier2/smoke-runs.jsonl` | `proc-pressure-tier2-loaded-smoke-runs.jsonl` |
| `tier2-quiet/` (runs + summary) | `proc-pressure-tier2-quiet-runs.jsonl`, `proc-pressure-tier2-quiet-summary.json` |
| `tier2/tier3-runs.jsonl` | `proc-pressure-tier3-loaded-runs.jsonl` |
| `tier2-quiet/tier3-runs.jsonl` | `proc-pressure-tier3-quiet-spotcheck-runs.jsonl` |
| `tier3-acceptance-runs.jsonl` | `proc-pressure-tier3-acceptance-runs.jsonl` |
| `tier3-usage-reconciled.json` | `proc-pressure-tier3-usage-reconciled-loaded.json` |
| `tier3-usage-reconciled-tier2-quiet.json` | `proc-pressure-tier3-usage-reconciled-quiet-spotcheck.json` |
| per-unit `delegate.stdout` | `proc-pressure-tier3-pixir-envelopes.redacted.jsonl` (derived: paths normalized to `<workspace>`, children task/summary dropped, local session ids retained; tasks are public in `audit64-spec.json`) |
| per-child codex `.events.jsonl` | `proc-pressure-tier3-codex-usage-summary.json` (derived: `turn.completed` usage + item counts only; provider correlation ids never shipped) |
| child session-log failure events (the 6 lost children) | `proc-pressure-tier3-transport-evidence.json` (the durable `turn_failed` events per child: 3x `websocket_read_failed`, 1x `websocket_closed`, 2x `provider_http_error`; request-id UUIDs redacted; provider_usage events never ship) |
| acceptance per-unit `delegate.stdout` (17 units) | `proc-pressure-tier3-acceptance-envelopes.redacted.jsonl` (same derivation diet as the benchmark envelopes) |
| acceptance failed child's `turn_failed` | `proc-pressure-tier3-acceptance-failure-evidence.json` (backs the `provider_http_error` and zero-websocket-family claims) |
| per-unit `time_k.txt` wrappers | not shipped (wrapper overhead is disclosed and arithmetically checkable from the runs rows; honesty note 1) |
| harness scripts under `outputs/proc-pressure/` | `proc-pressure-harness-tier2.py`, `proc-pressure-analyze.py`, `proc-pressure-reconcile.py`, `proc-pressure-tier1-spawntax.py`, `proc-pressure-tier1-beam.exs` (path-parameterized: `BENCH_REPO` env, cwd fallback; bench-home/workspace defaults renamed for publication and overridable via `BENCH_PIXIR_HOME`/`BENCH_CODEX_HOME`/`BENCH_WORKSPACE`) |

The design doc ships as `proc-pressure-design.md`.

Question: what does each additional coding-agent worker cost the macOS
process subsystem? Two runtimes, same model (gpt-5.5, reasoning effort low),
same ChatGPT quota, isolated config homes: `pixir delegate` (N supervised
Subagent Sessions inside one BEAM VM) versus `codex exec` (one OS process
per worker). Design doc: `proc-pressure-design.md` (shipped) (three claim
tiers; provider-side latency is never used for pure spawn-tax claims, and
Tier 2/3 pressure metrics are local-tree measurements that include each
client's transport overhead by definition).

Machine: macOS arm64, 32 GB. Conditions are labeled per run:
`loaded-evening` (machine in normal interactive use; Chrome, messaging) and
`quiet` — which is honestly a CONTROLLED low-ambient baseline, not a
representative idle Mac: fresh reboot, Spotlight volume indexing disabled
via `mdutil -a -i off`, `corespotlightd` SIGSTOPped for the window, no
interactive use, verified with `top` before launch. It answers "what does
each architecture cost with ambient preemption engineered out", not "what
would a typical user's idle machine show". Contention-sensitive metrics
(involuntary context switches, wall) must be read per condition; tree-scoped
metrics (threads, processes, RSS of the tracked process tree) are robust to
ambient load — a claim the quiet rerun then tested directly (it held).
Quiet rows carry `machine_condition`, `pixir_bin`, and `codex_bin` stamps.
Loaded Tier 2 synthetic rows predate all three fields; loaded Tier 3 rows
carry `machine_condition` but no binary stamps (the harness gained the
stamps, labeling-only, before the quiet rerun). Consequence, stated as a
limit: loaded-vs-quiet CODEX deltas are version-unverified (the codex CLI
auto-updates; the frozen `pixir-0.1.5-bench` binary is version-pinned by
construction), so the stamped quiet Tier 2 ladder is the primary
cross-arm table and loaded/quiet deltas are secondary evidence.

## Tier 1: spawn tax (no network, no quota, warm-cache only)

Creation cost per worker, parent-clock timed, spawn to reaped exit, REP=10,
one discarded warm-up batch per cell. Data: `tier1-runs.jsonl`. Correction
note (2026-07-07): the shipped tier1 scripts now compute a true median
(even rep counts average the middle pair). The OS-arm rows were never
affected: the spawn-tax script always used `statistics.median`, and
recomputing from the raw samples shipped in every OS-arm row
(`per_child_us_all`) reproduces the published figures exactly at their
stated precision (2,097.6 -> ~2,100; 1,030.2 -> ~1,030 at N=100;
42,447.8 -> ~42,500; 4,706.6 -> ~4,700 at N=50). Only the BEAM rows were
generated with the upper-middle median; they ship median/min/max, which
bounds the worst-case upward bias at (max - min) / 2, at most 0.39 us
across all BEAM rows: below the ~ precision published, so no figure
changes and the rows stand as measured.

| Arm | Sequential (median/child) | Parallel amortized (best N) |
|---|---|---|
| BEAM no-op worker, in-VM, unpinned | ~1.0 us | ~1.6-2.4 us |
| `/usr/bin/true` (posix_spawn+reap floor) | ~2,100 us | ~1,030 us (N=100) |
| `codex --version` (floor + binary startup) | ~42,500 us | ~4,700 us (N=50) |

Readings, in the order honesty requires:

1. An in-VM BEAM worker costs ~1 microsecond and stays flat to N=100,000.
   A trivial OS process costs ~1,000x that; a codex process (large Rust
   binary load + CLI init) costs ~20x the OS floor: roughly 20,000-40,000x
   the BEAM worker sequentially, ~2,500x amortized in bursts.
2. **The concession the data forces**: at N<=64 the codex spawn tax
   amortizes to ~0.3 s total, negligible against the ~96 s real-work wall.
   The creation tax is enormous in relative terms and NOT the wall at these
   scales. Publishing the ratio without this sentence would be an overclaim.
3. The reverse concession: the no-op BEAM worker is the creation floor, not
   a full Pixir Subagent Session (GenServer, session log on disk,
   supervision). The citable Pixir-side per-session number comes from Tier
   2/3 trees, not from this floor.
4. Curiosity, published as measured: pinning the BEAM to one scheduler
   (`+S 1:1`) made sequential spawn ~2x SLOWER than unpinned (2.2 vs 1.0 us).

Claims this tier cannot support: cold-start latency (warm-only by design;
`purge` needs sudo), steady-state scheduling, anything end-to-end.

## Tier 2: synthetic pressure ladder (N=1..32 x5 reps, 60/60 complete)

Trivial one-answer strict-JSON tasks, `max_threads=N`, arms interleaved per
rep, 500ms tree sampler + `/usr/bin/time -l` wrappers. Condition:
`loaded-evening`. Data: `tier2/runs.jsonl`, aggregates (seeded bootstrap,
seed 20260706, 10k resamples): `tier2/tier2-summary.json`.

**Marginal cost per additional worker, point [CI95], zero overlap on every
differentiating metric:**

| Metric | codex exec | pixir delegate |
|---|---|---|
| Threads (peak) | +99.4 [95.9, 101.7] | +0.0 [0.0, 0.0] |
| OS processes (peak) | +8.8 [8.2, 9.5] | 0 (flat 6) |
| Peak process-tree RSS | +131.5 MB [122.7, 139.4] | +4.4 MB [3.7, 4.8] |
| System CPU | +1.42 s [1.31, 1.58] | +0.05 s [0.04, 0.07] |
| Involuntary ctx switches | +54,800 [50.7k, 63.1k] | +3,000 [1.5k, 5.5k] |

Absolutes at N=32: codex 3,141 threads / 276 processes / 4.2 GB / 43.9 s
system CPU; pixir 45 threads / 6 processes / 270 MB / 2.0 s. Pixir's thread
count is flat from N=1 to N=32: the per-worker marginal is literally zero
because BEAM processes are not OS threads.

**What did NOT differentiate (published with equal prominence):**

- Voluntary context switches: comparable across arms; pixir slightly HIGHER
  at low N (its WebSocket transport at work). Marginal vcsw is not a Pixir
  advantage and is not claimed as one.
- Wall clock: mixed. codex won N=8 (6.7 vs 7.4 s); pixir won elsewhere
  (10.0 vs 24.8 s at N=32). Consistent with the published /scale nuance:
  raw speed is not the claim.

### Quiet-condition rerun (2026-07-06 night, 60/60 complete, `tier2-quiet/`)

Same ladder, same frozen binary (`pixir-0.1.5-bench`, stamped per row along
with `codex-cli 0.142.5`), machine prepared as described under Conditions.
Marginal cost per additional worker, point [CI95]:

| Metric | codex exec (quiet) | pixir delegate (quiet) |
|---|---|---|
| Threads (peak) | +100.5 [94.9, 104.4] | +0.0 [0.0, 0.0] |
| OS processes (peak) | +8.0 [7.1, 8.7] | 0 (flat 6) |
| Peak process-tree RSS | +130.7 MB [128.6, 132.6] | +3.7 MB [3.2, 4.1] |
| System CPU | +1.30 s [1.25, 1.37] | +0.04 s [0.03, 0.06] |
| Involuntary ctx switches | +45,018 [42.8k, 47.9k] | +2,445 [1.4k, 4.1k] |

What the loaded/quiet comparison establishes (the pre-registered questions):

1. **Tree-scoped metrics are condition-invariant, as designed**: threads
   (+99.4 loaded vs +100.5 quiet), processes (+8.8 vs +8.0), and RSS
   (+131.5 vs +130.7 MB) moved within noise. These claims never depended on
   the machine being quiet.
2. **The ambient contribution to codex's icsw is real**: the loaded point
   estimate exceeded quiet by 9.8k icsw/worker (~17.8% of loaded), and the
   two separately bootstrapped CIs do not overlap. (Point-estimate
   arithmetic; the difference itself was not bootstrapped.) **The
   pixir/codex point-estimate ratio was similar in both conditions: 18.5x
   loaded, 18.4x quiet** — no ratio CIs are computed (the pixir slope CIs
   are wide), so this is stated as point arithmetic, not as a
   condition-invariance theorem. Read together with the unchanged
   tree-scoped metrics, the kernel tax tracks the process-per-worker
   architecture rather than the busy machine. The sysCPU point ratio moved
   from 28x to 32x.
3. **Wall under quiet: pixir won every N except a near-tie at N=1**
   (codex 3.50 vs 3.60 s medians there; pixir won N=2 through N=32, e.g.
   5.2 vs 22.1 s at N=32, and 4.6 vs 5.6 s at N=8, which codex had won
   loaded). Honest counterpart: pixir's own N=32 wall halved from loaded to
   quiet (10.0 -> 5.2 s) while codex barely moved (24.8 -> 22.1 s), so
   ambient load degrades the single-VM's wall more even as its kernel
   footprint stays flat. Different-day caveat applies; vcsw stayed
   comparable (pixir higher at low N), as loaded.

## Tier 3: real work (audit-style tasks, quota-consuming)

Ladder N=1,2,4,8 x3, 16/32 x2, 64 x1 (directional), both arms running the
published `docs/benchmarks/scale/audit64-spec.json` tasks against this
repository. Condition `loaded-evening` in progress; results land in
`tier2/tier3-runs.jsonl`.

Pressure metrics here are reported per provider call AND per second (pixir
made 1,830 provider calls over 205 target children on audit tasks, ~8.9
per target child; deeper work must not be misread as worse pressure). This
tier's numbers include transport/API overhead by definition and are labeled
contextual evidence, never pure local-pressure claims. External-validity
limit, stated plainly: the audit tasks run AGAINST THIS REPOSITORY — Tier 3
is Pixir-repo dogfood evidence, and neutral task authorship, other repos,
and other OS versions are not covered.

**Run complete: 34/34 units, condition `loaded-evening`, 2026-07-06.**

Headline cell, N=64 real work (1 rep, directional):

| N=64 | codex exec | pixir delegate |
|---|---|---|
| Threads (peak) | 6,111 | 45 |
| OS processes (peak) | 474 | 6 |
| Peak process-tree RSS | 8,236 MB | 482 MB |
| System CPU | 187.1 s | 16.9 s (11x) |
| Involuntary ctx switches | 4.93 M | 0.69 M (7x) |
| Wall | 112 s | 113 s (dead even) |
| Children completed | 64/64 | 64/64 |

Wall note: dead even at N=64 tonight, versus the 2026-07-05 audit64 run
where codex won wall (96 vs 202 s). Same tasks, 1 rep each, different days
and cache states: treated as directional variance, not a reversal claim.

**Completion audit (the negative result, published as headline):**

| Arm | Units complete | Children completed |
|---|---|---|
| codex exec | 17/17 | 205/205 (100%) |
| pixir delegate | 13/17 | 199/205 (97.1%) |

The 6 lost pixir children, from their durable `turn_failed` events
(shipped as `proc-pressure-tier3-transport-evidence.json`): 3x
`websocket_read_failed` ("Could not read WebSocket frame"; 2 of them
mid-stream with partial output preserved, 107 and 243 chars; 1 with no
output captured), 1x `websocket_closed` ("WebSocket closed before
response.completed", 9 chars partial), and 2x `provider_http_error`
(OpenAI server errors whose message says "You can retry your request",
no output; the same family the acceptance rerun later hit once, addressed
by PR #219). All 6 carry `terminal_status: provider_error` and every one
left a resumable session id in the envelope (surgical recovery exists and
is the skill's documented flow). For the 4 websocket-family deaths the
documented design applies: SSE fallback is pre-output-safe only; a socket
that dies after output starts fails the child honestly instead of risking
duplication. Under the loaded-evening condition codex's HTTP transport had
no equivalent failure mode: 100% completion. This is fresh evidence for
issue #205 (orchestrator ergonomics: candidate retry/resume policy for
mid-stream WS drops). CORRECTION (2026-07-07, caught by the bundle build's
asserts against the durable logs): an earlier draft attributed all 6
deaths to mid-stream `websocket_read_failed` with partials preserved;
the per-child breakdown above is what the evidence supports.

**Per-provider-call normalization (reconciled from durable evidence:
pixir child session-log `provider_usage`, codex per-task `turn.completed`;
34/34 units; `tier3-usage-reconciled.json`):**

| N | pixir icsw/call | codex icsw/call | pixir sysCPU/call | codex sysCPU/call |
|---|---|---|---|---|
| 8 | 1,550 | 53,403 | 45.3 ms | 1,417.5 ms |
| 16 | 1,531.5 | 57,647.5 | 44.5 ms | 1,507.2 ms |
| 32 | 1,105.5 | 60,869.5 | 34.6 ms | 1,934.2 ms |
| 64 | 1,457 | 77,020 | 35.7 ms | 2,923.3 ms |

CORRECTION (2026-07-07, caught by the bundle gate): an earlier revision of
this table took the upper value instead of the statistical median on
even-rep cells (N=16, N=32 have 2 reps each), overstating some cells; the
reconcile script now uses `statistics.median` and the reconciled JSONs
confess the correction in their `note`.

This addresses the obvious counter-argument ("pixir children just do more
calls, ~9 vs 1") for the observed provider calls: even per individual
provider call, the process-per-worker pattern pays ~34-55x the involuntary
context switches and ~31-82x the kernel CPU (exact ratios by N above), and
its per-call tax GROWS with N (scheduler contention) while pixir's stays
flat. Caveat attached to the strong claim: pixir completed 199/205 children
in this loaded pass, so per-call figures cover completed work.

**#205 acceptance rerun (2026-07-06, pixir arm only, NEW binary with the
Manager auto-retry, loaded condition, `tier3-acceptance-runs.jsonl`):**
17/17 units ran, 204/205 children completed, ZERO websocket-family deaths
(the retry never even needed to fire: PASS, no regression). The single
failure was a `provider_http_error`/`server_error` whose provider message
says "You can retry your request": scope extension implemented same night
(PR #219). Disclosure (2026-07-07, caught by the bundle gate): the
acceptance ladder spans TWO binary commits, visible per row in
`binary_commit`: N=1,2,4,8 and N=16 rep1 (13 units) ran on `69fdccb`, then
N=16 rep2 and N=32,64 (4 units, including the one failure) on `bba09dd`
after a same-evening rebuild; both builds carry the Manager auto-retry, and
the "acceptance" verdict is directional across the pair, not a single-build
certification. These acceptance numbers use different binaries from the
benchmark and are NEVER merged with the benchmark rows above.

### Quiet spot-check, N=32 x1 (directional, `tier2-quiet/tier3-runs.jsonl`)

| N=32 real work | codex exec (quiet) | pixir delegate (quiet) |
|---|---|---|
| Threads / procs (peak) | 2,645 / 229 | 45 / 6 |
| Peak process-tree RSS | 4,478.5 MB | 316 MB |
| System CPU | 228.1 s | 8.9 s |
| Involuntary ctx switches | 2.74 M | 0.28 M |
| Wall | 512.5 s | 76.5 s |
| Children completed | 32/32 | 32/32 |

- **pixir completed 32/32 under quiet with the OLD binary** (no auto-retry):
  both loaded N=32 reps had lost children to mid-stream WS drops. Consistent
  with ambient load stressing the WebSocket path.
- **Per-call reconciliation (quiet, from durable evidence,
  `tier3-usage-reconciled-tier2-quiet.json`): pixir 984 icsw/call and
  30.7 ms sysCPU/call**, directionally similar in this one-rep spot-check
  to its loaded medians (1,105.5 / 34.6 ms; no statistical comparison is
  possible from a single rep). Arithmetic stress check, not a
  condition-matched estimate: pairing QUIET pixir per-call against LOADED
  codex per-call yields 62x, the same magnitude class as the loaded ratios
  (34-55x icsw / 31-82x sysCPU) though above the icsw span's top. No
  condition-matched quiet ratio is computed: the quiet codex cell failed
  QC and is excluded from all comparisons (below), so there is nothing
  valid to pair against.
- **The quiet codex cell is treated as failed QC for comparison, not
  evidence**: it ran 5-8x slower in wall (512 vs 62-90 s loaded) with 3-4x
  the local sysCPU (228 vs 49-75 s). With no codex version stamp on the
  loaded rows and provider-side state unknown (heavy quota use earlier that
  day), the cause is unattributable, so this cell is EXCLUDED from all
  comparative claims. What the quiet spot-check establishes is limited to
  the pixir side: 32/32 completion, flat footprint, and per-call figures
  consistent with loaded.

- [x] Quiet-condition rerun done: full Tier 2 ladder + Tier 3 N=32
  spot-check (gate requirement met)

## Honesty notes (cumulative, pre-registered where marked)

1. **Wrapper overhead is counted, disclosed, and checkable**: each codex
   child carries a `time + sh` wrapper (~2 processes, ~2 threads of its
   marginal); the pixir arm carries one wrapper total. Auditable correction
   at quiet N=32: raw codex peaks 3,144 threads / 265 processes; subtracting
   32 wrappers x (2 threads, 2 processes) leaves ~3,080 / ~201, i.e. a
   corrected marginal of ~+97 threads and ~+6 processes per child. The
   per-child wrapper cost is visible in each unit dir's `time_k.txt`
   wrappers; the conclusion is unchanged.
2. **Condition labeling**: Tier 2 and the first Tier 3 pass ran on a machine
   in normal evening use (`loaded-evening`). Involuntary CSW and wall are
   contention-sensitive: with ~70x more preemption targets (threads), codex
   plausibly absorbs disproportionate ambient preemption. (Pre-registered
   before quiet runs.) **Resolved by the quiet rerun**: ~18% of codex's
   loaded icsw marginal was ambient (54.8k -> 45.0k, non-overlapping CIs),
   and the pixir/codex point-estimate ratio was similar (18.5x -> 18.4x). The
   attributable floor is the quiet table above.
3. **vcsw and wall results that favor codex or nobody are in the headline
   tables, not a footnote.** (House null-result policy.)
4. The smoke run's codex N=1 anomaly (27.8 s wall for a trivial call) did
   not recur across reps (median 4.1 s at N=1); treated as first-run cold
   state, kept in `tier2/smoke-runs.jsonl`.
5. Sampling is 500ms tree-scoped peaks, not OS-exact accounting: sampled
   process/thread/RSS peaks are LOWER BOUNDS (a helper living entirely
   between samples is missed by them). `/usr/bin/time -l` exit totals bound
   only CPU and context-switch accounting over each wrapper's lifetime; they
   do not recover missed peak history.
6. Context-switch voluntary/involuntary split exists only as exit-lifecycle
   totals on macOS without sudo (`/usr/bin/time -l`); live splits are not
   measurable without dtrace/SIP exceptions, so none are claimed.
7. One machine, one macOS version, specific pixir/codex versions: no general
   BEAM-vs-Rust law is claimed. Ratios are configuration-specific.
8. Spawn-tax microbench (Tier 1) cannot predict end-to-end behavior and is
   never cited as if it did.

## Reproduce

The scripts below ship in this bundle, path-parameterized:
`BENCH_REPO` points at the repo root (default: current working directory).

```bash
uv run python proc-pressure-tier1-spawntax.py                  # no quota
elixir proc-pressure-tier1-beam.exs unpinned                   # no quota
uv run python proc-pressure-harness-tier2.py --smoke           # ~10 trivial calls
uv run python proc-pressure-harness-tier2.py                   # ~630 trivial calls
uv run python proc-pressure-harness-tier2.py --tier3           # ~2,300 calls, real work
uv run python proc-pressure-analyze.py --runs proc-pressure-tier2-quiet-runs.jsonl --out /tmp/check.json
```

Requires: `./pixir` built at repo root (pin a specific build via
`PIXIR_BENCH_BIN`, absolute path), `codex` on PATH, isolated bench homes you
create yourself (`BENCH_PIXIR_HOME` / `BENCH_CODEX_HOME`, each with its own
auth), a `BENCH_WORKSPACE` directory for the synthetic tasks, and auth on
both sides for Tier 2/3. Label conditions with `BENCH_CONDITION` and keep
each condition's output in its own `BENCH_OUTDIR`. Verification without
quota: `proc-pressure-analyze.py --runs <shipped runs file>` reproduces the
shipped Tier 2 summaries (seeded bootstrap) byte-for-byte;
`proc-pressure-reconcile.py` reruns only against raw session logs, which do
not ship - the reconciled JSONs here are the derived record of that step.

## Publication gate (must pass before any of this reaches /scale)

- [x] Quiet-condition reruns done; loaded vs quiet published side by side.
- [x] Tier 3 usage reconciled against session-log evidence (house rule:
  logs, not estimates).
- [x] 4-lens adversarial fan-out over this report + data files (2026-07-06
  night, gpt-5.5 high): 23 findings, 23 accepted, all wording/method fixes
  applied above; the 3 publication-safety FATALs became the bundle
  requirements below.
- [x] Bundle construction requirements (from the gate, same diet as the
  audit64 bundle), implemented by this bundle - see the Bundle map above:
  (1) no codex raw `.events.jsonl`; derived usage summaries only, provider
  correlation ids stripped; (2) pixir `delegate.stdout` shipped as redacted
  derived envelopes, `child_log_path` normalized to `<workspace>/...`,
  local session ids retained by explicit decision; (3) harness scripts
  shipped path-parameterized.
- [x] Bundle files in house naming ship to `docs/benchmarks/scale/` in the
  same PR that adds the /scale section (this bundle is that shipment; it
  passed its own 4-lens adversarial gate on 2026-07-07).
- [x] Null-result policy honored: vcsw and wall published as measured
  (including the N=1 quiet wall near-tie codex won, and the excluded
  quiet codex Tier 3 cell).
- [x] Design acceptance-gate reconciliation, stated plainly: the design doc
  gates a /scale section on ">=3 N levels x >=3 reps per CI claim, usage
  evidence reconciled, profile matching explicit, honesty notes present,
  completion audit green". The CI claims satisfy the first criterion via
  Tier 2 (6 N levels x 5 reps, both conditions); usage is reconciled; but
  the loaded Tier 3 pixir completion audit is NOT green (199/205). Per the
  design's own null-result policy (same paragraph), that result is
  published as the headline negative result instead of gating publication;
  any /scale section must carry it as negative evidence, never bury it.
