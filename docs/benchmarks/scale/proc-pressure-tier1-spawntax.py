#!/usr/bin/env python3
"""proc-pressure Tier 1: warm-cache spawn tax, no network, no quota.

Arms (per proc-pressure-design.md):
  os_true_seq / os_true_par       - /usr/bin/true: posix_spawn+reap floor
  os_codex_seq / os_codex_par     - codex --version: floor + large binary startup
  (BEAM arms run separately via elixir -e; see proc-pressure-tier1-beam.exs)

Warm-only: one discarded warm-up batch per (arm, N). Parent-side
perf_counter_ns timing. Children to /dev/null. Output: JSONL rows.
"""
import json
import os
import shutil
import statistics
import subprocess
import sys
import time
from pathlib import Path

OUT = Path(__file__).parent / "tier1-runs.jsonl"
REP = int(os.environ.get("REP", "10"))
CODEX = shutil.which("codex")

SEQ_NS = [1, 5, 10, 25, 50, 100]
PAR_TRUE_NS = [1, 5, 10, 25, 50, 100]
PAR_CODEX_NS = [1, 2, 5, 10, 25, 50]


def run_seq(binary, args, n):
    t0 = time.perf_counter_ns()
    failures = 0
    for _ in range(n):
        rc = subprocess.run([binary] + args, stdout=subprocess.DEVNULL,
                            stderr=subprocess.DEVNULL, check=False).returncode
        failures += rc != 0
    return time.perf_counter_ns() - t0, failures


def run_par(binary, args, n):
    t0 = time.perf_counter_ns()
    procs = [subprocess.Popen([binary] + args, stdout=subprocess.DEVNULL,
                              stderr=subprocess.DEVNULL) for _ in range(n)]
    failures = sum(p.wait() != 0 for p in procs)
    return time.perf_counter_ns() - t0, failures


def bench(arm, mode, binary, args, ns, out):
    runner = run_seq if mode == "seq" else run_par
    for n in ns:
        runner(binary, args, n)  # warm-up batch, discarded
        per_child_us = []
        total_failures = 0
        for rep in range(REP):
            dt_ns, failures = runner(binary, args, n)
            total_failures += failures
            per_child_us.append(dt_ns / n / 1000)
        row = {
            "arm": arm, "mode": mode, "n": n, "reps": REP,
            "binary": os.path.basename(binary),
            "per_child_us_median": round(statistics.median(per_child_us), 1),
            "per_child_us_min": round(min(per_child_us), 1),
            "per_child_us_max": round(max(per_child_us), 1),
            "per_child_us_all": [round(v, 1) for v in per_child_us],
            "failures": total_failures,
            "cache_state": "warm",
        }
        out.write(json.dumps(row) + "\n")
        out.flush()
        print(f"{arm} {mode} N={n}: median {row['per_child_us_median']}us/child"
              f" (min {row['per_child_us_min']}, max {row['per_child_us_max']},"
              f" failures {total_failures})")


def main():
    if not CODEX:
        sys.exit("codex binary not found on PATH")
    def probe(cmd):
        # provenance fails fast: a broken probe must not emit a benchmark
        # header with blank provenance
        r = subprocess.run(cmd, capture_output=True, text=True)
        out = r.stdout.strip()
        if r.returncode != 0 or not out:
            sys.exit(f"provenance probe failed: {cmd} "
                     f"(rc={r.returncode}, stderr={r.stderr.strip()!r})")
        return out

    meta = {
        "meta": True, "date": os.environ.get("BENCH_DATE", "unset"),
        "codex_path": CODEX,
        "codex_version": probe([CODEX, "--version"]),
        "os": probe(["sw_vers", "-productVersion"]),
        "arch": probe(["uname", "-m"]),
        "rep": REP,
        "timing": "parent perf_counter_ns, spawn->exit(reaped), warm-cache only",
    }
    with OUT.open("w") as out:
        out.write(json.dumps(meta) + "\n")
        bench("os_true", "seq", "/usr/bin/true", [], SEQ_NS, out)
        bench("os_true", "par", "/usr/bin/true", [], PAR_TRUE_NS, out)
        bench("os_codex", "seq", CODEX, ["--version"], SEQ_NS, out)
        bench("os_codex", "par", CODEX, ["--version"], PAR_CODEX_NS, out)
    print(f"\nwritten: {OUT}")


if __name__ == "__main__":
    main()
