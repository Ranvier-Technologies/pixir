# proc-pressure: benchmark design (integrative proposal)

Synthesized 2026-07-06 from a 5-lens Pixir delegate fan-out (sids
`20260706T001912-{2a9fe6,2f1d39,c34df6,e9d774,395d9d}`: measurement,
harness integration, spawn-tax, adversarial, stats/publication).
Question: how hard does each runtime hit the macOS process subsystem,
pixir delegate (N workers, one BEAM VM) vs codex exec (N OS processes)?

## The load-bearing design decision: three claim tiers

The adversarial lens rated network contamination FATAL for any "process
pressure" claim (TLS/transport dominates system CPU and context switches),
and backpressure differences FATAL (a runtime that queues avoids pressure
by doing less concurrently). So claims are stratified; no metric crosses
tiers.

**Tier 1: spawn tax (no network, no quota, cleanest claim).**
Four OS arms + two BEAM arms, all warm-cache only (`purge` needs sudo, so
cold-start claims are out of scope by design):

- `/usr/bin/true` sequential and parallel (floor: pure posix_spawn+reap)
- `codex --version` sequential and parallel (floor + large-binary startup;
  the delta over `true` is NOT pure loader cost: CLI init is included, say so)
- BEAM `spawn_monitor` no-op sequential and parallel inside a running VM,
  timed with `:timer.tc`, schedulers pinned `+S 1:1` (report unpinned
  separately)

Ladders: OS arms N=1..500 seq / N=1..250 (`true`) and N=1..50 (`codex`)
parallel, REP=10, one discarded warm-up batch per arm; BEAM N=100..100k.
Parent-side `perf_counter_ns` timing only; children to /dev/null (PTY and
stdout rendering would dominate otherwise). Supported claim shape: "warm
creation tax per child on this Mac". Explicitly unsupported: cold start,
steady-state scheduling, anything end-to-end.

**Tier 2: synthetic pressure ladder (cheap, no quota beyond trivial calls).**
Extends the prior internal benchmark's 500ms tree sampler with:
- thread counts per tree (`ps -o thcount=` over refreshed descendant PIDs;
  upgrade path: `proc_pidinfo(PROC_PIDTASKINFO).pti_threadnum`)
- live context-switch deltas via `pti_csw` (total only; the vol/invol split
  does NOT exist live without sudo/dtrace: measurement lens verdict)
- `/usr/bin/time -lp` wrapper per spawned process (codex: N files; pixir: 1)
  for exit-lifecycle totals: user/sys CPU + voluntary/involuntary CSW
- startup latency measured with ONE clock: the harness parent's monotonic
  timer, spawn -> first observable output/event per worker. Cross-log
  timestamp comparison was rated FATAL (different clock bases); do not do it.

N=1,2,4,8,16,32 x5 reps (+N=64 x3 only if no swap spiral).
Dropped as unmeasurable without sudo (measurement lens): system-wide CSW
rate (no Linux-vmstat equivalent), full Mach port inventory (lsmp not
guaranteed); Mach ports demoted to an optional one-shot diagnostic snapshot.

**Tier 3: real work (quota-consuming, contextual evidence only).**
Same audit-style workload as the published bundle. N=1..8 x3, 16/32 x2,
64 x1 directional (~673 provider calls per pixir run). All pressure metrics
here are reported normalized per provider call AND per second, so pixir's
deeper work (~10.5 calls/child) is not misread as worse pressure. Labeled:
"includes transport/API overhead; not pure local pressure evidence".

## Fairness rules the adversarial lens made mandatory

1. **Baseline subtraction with both views**: BEAM scheduler threads are
   always-on (~2x cores at N=0). Publish raw AND idle-baseline-subtracted;
   wording: "an always-on VM cost amortized across workers".
2. **Count the helpers**: pixir's tree includes erl_child_setup and
   inet_gethost; "one BEAM VM" is not literally one OS process. The tree
   sampler counts everything on both sides, as it already does for RSS.
3. **max_threads = N recorded per run**, plus actual peak concurrency from
   samples: no side may quietly queue its way out of pressure.
4. **Completion audit per run**: silent failures/retries invalidate a rep.
5. **Pre-registered expectation**: low N may favor codex (fast Rust startup);
   we publish crossover points, not a winner. Wall at N=64 real work already
   publicly favors codex; new metrics must not be spun to bury that.
6. **Environment record**: chip, power state, thermal, macOS/codex/OTP
   versions, run-order interleaving, cooldowns.

## Guardrails against the three predictable misreadings

- "pixir scales better overall" -> only local footprint is claimed, never
  end-to-end speed or quota.
- "codex is unscalable" -> process isolation has costs AND benefits; CSW
  count is a pressure proxy, not a performance verdict.
- "this proves BEAM > Rust" -> one machine, one macOS, specific versions;
  no general law.

## Stats and publication (house method)

Seeded bootstrap, seed 20260706, 10k resamples, resample reps within each
(arm, N) cell; OLS marginal slope vs N for linear count-like metrics
(threads, procs, RSS cross-check), per-N median + CI95 for the rest; CSW as
rate/s and per completed child (and per provider call in Tier 3). 1-rep
cells are directional everywhere, never CI'd.

Bundle files (house naming, ship next to the existing ones):
`proc-pressure-spec.json`, `-runs.jsonl`, `-summary.json`, `-report.md`,
`-ci95.json`, `-samples-{pixir,codex}.txt`, `-honesty-notes.md`,
`-completion-audit.json`.

Acceptance gate for a /scale section: >=3 N levels x >=3 reps per CI claim,
usage evidence reconciled, profile matching explicit, honesty notes present,
completion audit green. **Null-result policy (house rule): if the gate
passes and the results are null or favor codex, publish anyway** in a
neutral or negative-evidence subsection; suppression is not an option.

## Harness touch points (integration lens, verified against the script)

`usage()/parse_args()` (new workload), `sampler_loop()` (thread columns),
`run_fanout_pixir_delegate()` / `run_fanout_codex_exec()` (time -l wrappers),
`analyze_unit()` / `summarize()` / `render_report()` (new aggregates).
New runs.jsonl fields follow existing naming: `peak_tracked_thread_count`,
`median_tracked_thread_count`, rusage fields, `startup_latency_ms_*`.
Everything already published stays byte-compatible for comparability with
`docs/benchmarks/scale/`.

## Effort estimate

Tier 1 harness: ~1h (standalone script, no quota). Tier 2: ~1-2h extending
that sampler harness + ~1h of runs. Tier 3: reuses everything; quota cost is the
real budget (~673 calls per pixir N=64 rep). Recommended order: Tier 1
first (free, and its result decides whether the spawn-tax story is even
interesting), then Tier 2, then decide Tier 3 by what the first two show.
