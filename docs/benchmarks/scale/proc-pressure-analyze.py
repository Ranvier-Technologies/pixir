#!/usr/bin/env python3
"""Aggregate Tier 2 proc-pressure runs: per-N medians, marginal slopes,
seeded bootstrap CI95 (house method, seed 20260706).

Usage:
  python proc-pressure-analyze.py [--runs <runs.jsonl>] [--out <summary.json>]
Without flags, reads <script dir>/<BENCH_OUTDIR basename>/runs.jsonl
(condition dirs; never blend conditions across files)."""
import argparse
import json
import os
import random
import statistics
from pathlib import Path

ap = argparse.ArgumentParser()
ap.add_argument("--runs", help="explicit runs.jsonl path (e.g. a published "
                "proc-pressure-tier2-*-runs.jsonl bundle file)")
ap.add_argument("--out", help="explicit summary output path")
args = ap.parse_args()

# Point at a specific condition's data (e.g. BENCH_OUTDIR=tier2-quiet);
# defaults to the original loaded-condition directory. Never blend conditions.
# Resolved against BENCH_REPO (cwd fallback) so the zero-flag default matches
# where the harness actually writes, wherever this script lives.
REPO = Path(os.environ.get("BENCH_REPO", os.getcwd()))
_dirname = os.environ.get("BENCH_OUTDIR", "tier2").split("/")[-1]
DIR = REPO / "outputs/proc-pressure" / _dirname
RUNS = Path(args.runs) if args.runs else DIR / "runs.jsonl"
OUT = Path(args.out) if args.out else DIR / "tier2-summary.json"
rows = [json.loads(l) for l in RUNS.read_text().splitlines()]

random.seed(20260706)

METRICS = {
    "threads_peak": lambda r: r["threads"]["peak"],
    "procs_peak": lambda r: r["procs"]["peak"],
    "rss_peak_mb": lambda r: r["rss_mb"]["peak"],
    "sys_cpu_s": lambda r: r["sys_s_sum"],
    "user_cpu_s": lambda r: r["user_s_sum"],
    "icsw": lambda r: r["icsw_sum"],
    "vcsw": lambda r: r["vcsw_sum"],
    "wall_ms": lambda r: r["wall_ms"],
}

incomplete = [r for r in rows if not r["complete"]]
print(f"rows={len(rows)}  incomplete={len(incomplete)}")
for r in incomplete:
    print("  INCOMPLETE:", r["arm"], "n", r["n"], "rep", r["rep"],
          "completed", r["completed"], "exits", r["exit_codes"][:5])

by = {}
for r in rows:
    if r["complete"]:
        by.setdefault((r["arm"], r["n"]), []).append(r)


def slope(points):
    xs = [p[0] for p in points]
    ys = [p[1] for p in points]
    mx, my = sum(xs) / len(xs), sum(ys) / len(ys)
    den = sum((x - mx) ** 2 for x in xs)
    return sum((x - mx) * (y - my) for x, y in points) / den


summary = {"seed": 20260706, "resamples": 10000, "per_n_medians": {},
           "marginal_slopes": {}}

arms = sorted({a for a, _ in by})
ns = sorted({n for _, n in by})

for metric, get in METRICS.items():
    table = {}
    for arm in arms:
        table[arm] = {}
        for n in ns:
            cell = by.get((arm, n), [])
            vals = [get(r) for r in cell if get(r) is not None]
            if vals:
                table[arm][n] = round(statistics.median(vals), 1)
    summary["per_n_medians"][metric] = table

for metric in ["threads_peak", "procs_peak", "rss_peak_mb", "sys_cpu_s", "icsw"]:
    get = METRICS[metric]
    summary["marginal_slopes"][metric] = {}
    for arm in arms:
        cells = {n: [get(r) for r in by.get((arm, n), []) if get(r) is not None]
                 for n in ns if by.get((arm, n))}
        pts = [(n, v) for n, vals in cells.items() for v in vals]
        point = slope(pts)
        boots = []
        for _ in range(10000):
            sample = [(n, random.choice(vals)) for n, vals in cells.items()]
            boots.append(slope(sample))
        boots.sort()
        summary["marginal_slopes"][metric][arm] = {
            "per_extra_child_point": round(point, 2),
            "ci95": [round(boots[249], 2), round(boots[9749], 2)],
        }

OUT.write_text(json.dumps(summary, indent=2) + "\n")

print("\n=== per-N medians (pixir | codex) ===")
for metric in METRICS:
    t = summary["per_n_medians"][metric]
    line = f"{metric:12s}"
    for n in ns:
        p = t.get("pixir-delegate", {}).get(n, "-")
        c = t.get("codex-exec", {}).get(n, "-")
        line += f"  N{n}: {p}|{c}"
    print(line)

print("\n=== marginal per extra child, point [CI95] ===")
for metric, arms_d in summary["marginal_slopes"].items():
    for arm, d in arms_d.items():
        print(f"{metric:12s} {arm:15s} {d['per_extra_child_point']:>10} "
              f"[{d['ci95'][0]}, {d['ci95'][1]}]")
