#!/usr/bin/env python3
"""proc-pressure Tier 2: synthetic pressure ladder, pixir delegate vs codex exec.

Parity mirrors the prior internal duel-benchmark harness verbatim: same isolated homes, same
model/effort flags, same trivial strict-JSON child tasks. Adds: 500ms tree
sampler (procs, RSS, threads), /usr/bin/time -l wrappers (user/sys CPU,
voluntary/involuntary context switches at exit), completion audit per run.

Usage:
  uv run python proc-pressure-harness-tier2.py --smoke          # N=1,4 x1 rep, validate
  uv run python proc-pressure-harness-tier2.py                  # N=1,2,4,8,16,32 x5 reps
"""
import argparse
import json
import os
import re
import shutil
import statistics
import subprocess
import threading
import time
from pathlib import Path

# Path-parameterized for publication: set BENCH_REPO to the repo root
# (defaults to the current working directory).
REPO = Path(os.environ.get("BENCH_REPO", os.getcwd()))
# Quiet rerun MUST use the preserved 0.1.5-era binary for comparability with
# the loaded-condition runs: PIXIR_BENCH_BIN=outputs/proc-pressure/bin/pixir-0.1.5-bench
PIXIR_BIN = Path(os.environ.get("PIXIR_BENCH_BIN", REPO / "pixir"))
# Isolated bench homes (own auth/config per arm) and the synthetic-task
# workspace. Overridable for reruns outside this working copy; the defaults
# are the homes used by every published run.
BENCH_HOME = Path(os.environ.get("BENCH_PIXIR_HOME",
                                 REPO / "outputs/proc-pressure/bench-home"))
CODEX_HOME = Path(os.environ.get("BENCH_CODEX_HOME",
                                 REPO / "outputs/proc-pressure/bench-home-codex"))
WORKSPACE = Path(os.environ.get("BENCH_WORKSPACE",
                                REPO / "outputs/proc-pressure/bench-workspace"))
# Quiet rerun writes to its OWN directory (BENCH_OUTDIR=outputs/proc-pressure/tier2-quiet):
# rows append per file, the loaded artifacts stay untouched, and the analyzer
# never blends conditions.
OUTDIR = REPO / os.environ.get("BENCH_OUTDIR", "outputs/proc-pressure/tier2")
MODEL = "gpt-5.5"
EFFORT = "low"
SAMPLE_S = 0.5
COOLDOWN_S = 8
TIME = "/usr/bin/time"

# Condition label per row. Labeling only (no measurement change; added
# 2026-07-06 before the quiet rerun and disclosed in the report): the original
# loaded runs carried the then-hardcoded "loaded-evening".
MACHINE_CONDITION = os.environ.get("BENCH_CONDITION", "loaded-evening")


def _bin_version(cmd):
    try:
        out = subprocess.run(cmd, capture_output=True, text=True, timeout=10)
        return out.stdout.strip().splitlines()[0] if out.stdout.strip() else None
    except Exception:
        return None


# Version stamps per row (absent in the original loaded rows; comparability
# there rests on the frozen bench binary and same-day codex).
PIXIR_VERSION_STAMP = f"{PIXIR_BIN.name} {_bin_version([str(PIXIR_BIN), '--version']) or '?'}"
CODEX_VERSION_STAMP = _bin_version(["codex", "--version"]) or "?"


AUDIT_SPEC = REPO / "docs/benchmarks/scale/audit64-spec.json"
_audit_tasks = None


def audit_task(k):
    global _audit_tasks
    if _audit_tasks is None:
        _audit_tasks = json.loads(AUDIT_SPEC.read_text())["tasks"]
    return _audit_tasks[(k - 1) % len(_audit_tasks)]


def task(k, tier3=False):
    if tier3:
        return audit_task(k)
    return (f'Reply with strict JSON only, no prose: '
            f'{{"child":{k},"ok":true}}')


def descendants(roots):
    out = subprocess.run(["ps", "-axo", "pid=,ppid="], capture_output=True,
                         text=True).stdout
    children = {}
    for line in out.splitlines():
        parts = line.split()
        if len(parts) == 2:
            children.setdefault(int(parts[1]), []).append(int(parts[0]))
    tree, stack = set(roots), list(roots)
    while stack:
        for child in children.get(stack.pop(), []):
            if child not in tree:
                tree.add(child)
                stack.append(child)
    return tree


def sample_tree(roots):
    tree = descendants(roots)
    ps = subprocess.run(["ps", "-axo", "pid=,rss="], capture_output=True,
                        text=True).stdout
    rss_kb, procs = 0, 0
    for line in ps.splitlines():
        parts = line.split()
        if len(parts) == 2 and int(parts[0]) in tree:
            procs += 1
            rss_kb += int(parts[1])
    threads = 0
    psm = subprocess.run(["ps", "-axM"], capture_output=True, text=True).stdout
    for line in psm.splitlines()[1:]:
        m = re.search(r"^\s*(?:\S+\s+)?(\d+)\s", line)
        if m and int(m.group(1)) in tree:
            threads += 1
    return {"procs": procs, "rss_kb": rss_kb, "threads": threads}


class Sampler(threading.Thread):
    def __init__(self, roots):
        super().__init__(daemon=True)
        self.roots, self.samples, self.stop_flag = roots, [], False

    def run(self):
        while not self.stop_flag:
            try:
                self.samples.append(sample_tree(self.roots))
            except Exception:
                pass
            time.sleep(SAMPLE_S)


def parse_time_file(path):
    text = Path(path).read_text() if Path(path).exists() else ""
    def grab(pattern, cast=float):
        m = re.search(pattern, text)
        return cast(m.group(1)) if m else None
    return {
        "real_s": grab(r"([\d.]+) real"),
        "user_s": grab(r"([\d.]+) user"),
        "sys_s": grab(r"([\d.]+) sys"),
        "max_rss_bytes": grab(r"(\d+)\s+maximum resident set size", int),
        "vcsw": grab(r"(\d+)\s+voluntary context switches", int),
        "icsw": grab(r"(\d+)\s+involuntary context switches", int),
    }


def wrapped(cmd, time_file):
    return [TIME, "-l", "-o", str(time_file), "sh", "-c", cmd]


def run_pixir(unit, n, tier3=False):
    ws = REPO if tier3 else WORKSPACE
    spec = {"contract_version": 1, "strategy": "subagents",
            "tasks": [task(k, tier3) for k in range(1, n + 1)],
            "subagents": {"role": "explorer", "max_threads": n}}
    (unit / "spec.json").write_text(json.dumps(spec))
    cmd = (f'cd "{ws}" && PIXIR_HOME="{BENCH_HOME}" "{PIXIR_BIN}" '
           f'delegate --spec "{unit}/spec.json" --json --timeout-ms 900000 '
           f'> "{unit}/delegate.stdout" 2> "{unit}/delegate.stderr"')
    proc = subprocess.Popen(wrapped(cmd, unit / "time_delegate.txt"))
    sampler = Sampler([proc.pid])
    t0 = time.perf_counter()
    sampler.start()
    rc = proc.wait()
    wall_ms = (time.perf_counter() - t0) * 1000
    sampler.stop_flag = True
    sampler.join(2)
    completed = 0
    try:
        env = json.loads((unit / "delegate.stdout").read_text())
        completed = sum(1 for c in env.get("children", [])
                        if c.get("status") == "completed")
    except Exception:
        pass
    return sampler.samples, [parse_time_file(unit / "time_delegate.txt")], \
        wall_ms, [rc], completed


def run_codex(unit, n, tier3=False):
    ws = REPO if tier3 else WORKSPACE
    procs = []
    t0 = time.perf_counter()
    for k in range(1, n + 1):
        prompt = unit / f"prompt_{k}.md"
        prompt.write_text(task(k, tier3))
        cmd = (f'CODEX_HOME="{CODEX_HOME}" codex -a never exec --ephemeral '
               f'--skip-git-repo-check --sandbox read-only -C "{ws}" '
               f'-m {MODEL} -c model_reasoning_effort={EFFORT} --json '
               f'--output-last-message "{unit}/child_{k}.last.md" - '
               f'< "{prompt}" > "{unit}/child_{k}.events.jsonl" '
               f'2> "{unit}/child_{k}.stderr"')
        procs.append(subprocess.Popen(wrapped(cmd, unit / f"time_{k}.txt")))
    sampler = Sampler([p.pid for p in procs])
    sampler.start()
    rcs = [p.wait() for p in procs]
    wall_ms = (time.perf_counter() - t0) * 1000
    sampler.stop_flag = True
    sampler.join(2)
    rusages = [parse_time_file(unit / f"time_{k}.txt")
               for k in range(1, n + 1)]
    completed = sum(1 for k in range(1, n + 1)
                    if (unit / f"child_{k}.last.md").exists()
                    and (unit / f"child_{k}.last.md").stat().st_size > 0)
    return sampler.samples, rusages, wall_ms, rcs, completed


def agg(samples, key):
    vals = [s[key] for s in samples]
    if not vals:
        return {"peak": None, "median": None}
    return {"peak": max(vals), "median": statistics.median(vals)}


def run_unit(arm, n, rep, out, tier3=False):
    prefix = "t3-" if tier3 else ""
    unit = OUTDIR / f"{prefix}{arm}-n{n}-rep{rep}"
    unit.mkdir(parents=True, exist_ok=True)
    runner = run_pixir if arm == "pixir-delegate" else run_codex
    samples, rusages, wall_ms, rcs, completed = runner(unit, n, tier3)
    def rsum(key):
        vals = [r[key] for r in rusages if r.get(key) is not None]
        return round(sum(vals), 3) if vals else None
    row = {
        "arm": arm,
        "workload": "proc-pressure-realwork" if tier3
                    else "proc-pressure-synthetic",
        "machine_condition": MACHINE_CONDITION,
        "pixir_bin": PIXIR_VERSION_STAMP,
        "codex_bin": CODEX_VERSION_STAMP,
        "n": n, "rep": rep,
        "model": MODEL, "effort": EFFORT, "wall_ms": round(wall_ms),
        "samples": len(samples),
        "procs": agg(samples, "procs"), "threads": agg(samples, "threads"),
        "rss_mb": {k: (round(v / 1024, 1) if v is not None else None)
                   for k, v in agg(samples, "rss_kb").items()},
        "user_s_sum": rsum("user_s"), "sys_s_sum": rsum("sys_s"),
        "vcsw_sum": rsum("vcsw"), "icsw_sum": rsum("icsw"),
        "exit_codes": rcs, "completed": completed, "target": n,
        "complete": completed == n and all(rc == 0 for rc in rcs),
    }
    out.write(json.dumps(row) + "\n")
    out.flush()
    print(f"{arm} n={n} rep={rep}: wall {row['wall_ms']}ms, "
          f"procs peak {row['procs']['peak']}, threads peak "
          f"{row['threads']['peak']}, rss peak {row['rss_mb']['peak']}MB, "
          f"sys {row['sys_s_sum']}s, vcsw {row['vcsw_sum']}, "
          f"icsw {row['icsw_sum']}, complete {row['complete']}")
    return row


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--smoke", action="store_true")
    ap.add_argument("--tier3", action="store_true")
    ap.add_argument("--reps", type=int, default=5)
    args = ap.parse_args()
    if not shutil.which("codex"):
        raise SystemExit("codex not on PATH")
    OUTDIR.mkdir(parents=True, exist_ok=True)
    if args.tier3:
        # design ladder: N=1,2,4,8 x3; 16,32 x2; 64 x1 (directional)
        cells = [(n, r) for n in (1, 2, 4, 8) for r in (1, 2, 3)]
        cells += [(n, r) for n in (16, 32) for r in (1, 2)]
        cells += [(64, 1)]
        # Spot-checks (cell selection only; measurement unchanged):
        # BENCH_T3_CELLS="32:1" or "32:1,32:2" runs just those (n, rep) cells.
        if os.environ.get("BENCH_T3_CELLS"):
            cells = [tuple(map(int, c.split(":")))
                     for c in os.environ["BENCH_T3_CELLS"].split(",")]
        results = OUTDIR / "tier3-runs.jsonl"
        with results.open("a") as out:
            for n, rep in cells:
                arms = ["pixir-delegate", "codex-exec"]
                if rep % 2 == 0:
                    arms.reverse()
                for arm in arms:
                    run_unit(arm, n, rep, out, tier3=True)
                    time.sleep(COOLDOWN_S)
        print(f"\nwritten: {results}")
        return
    ns = [1, 4] if args.smoke else [1, 2, 4, 8, 16, 32]
    reps = 1 if args.smoke else args.reps
    results = OUTDIR / ("smoke-runs.jsonl" if args.smoke else "runs.jsonl")
    with results.open("a") as out:
        for rep in range(1, reps + 1):
            arms = ["pixir-delegate", "codex-exec"]
            if rep % 2 == 0:
                arms.reverse()  # interleave order across reps (fairness)
            for n in ns:
                for arm in arms:
                    run_unit(arm, n, rep, out)
                    time.sleep(COOLDOWN_S if not args.smoke else 2)
    print(f"\nwritten: {results}")


if __name__ == "__main__":
    main()
