#!/usr/bin/env python3
"""Reconcile Tier 3 per-provider-call usage from durable evidence (house rule:
logs, not estimates). pixir: child session-log provider_usage events. codex:
per-task events.jsonl turn.completed usage. Emits pressure-normalized-per-call
figures so pixir's deeper reads are not misread as worse orchestration."""
import json
import os
import statistics
from collections import Counter
from pathlib import Path

# Path-parameterized for publication: set BENCH_REPO to the repo root
# (defaults to the current working directory).
REPO = Path(os.environ.get("BENCH_REPO", os.getcwd()))
# BENCH_OUTDIR points at a condition's data dir (e.g. outputs/proc-pressure/tier2-quiet);
# the output file gains the dir's suffix so conditions never overwrite each other.
_dirname = os.environ.get("BENCH_OUTDIR", "outputs/proc-pressure/tier2").split("/")[-1]
T2 = REPO / "outputs/proc-pressure" / _dirname
SESS = REPO / ".pixir/sessions"
RUNS = T2 / "tier3-runs.jsonl"
_suffix = "" if _dirname == "tier2" else f"-{_dirname}"
OUT = REPO / f"outputs/proc-pressure/tier3-usage-reconciled{_suffix}.json"


def pixir_unit_usage(unit_dir):
    env_path = unit_dir / "delegate.stdout"
    if not env_path.exists():
        return None
    try:
        env = json.loads(env_path.read_text())
    except Exception:
        return None
    calls = 0
    tok = Counter()
    children = env.get("children", [])
    for c in children:
        sid = c.get("child_session_id")
        log = SESS / f"{sid}.ndjson"
        if not log.exists():
            continue
        for line in log.read_text().splitlines():
            if '"provider_usage"' not in line:
                continue
            data = json.loads(line).get("data", {})
            s = data.get("usage_summary") or {}
            if not s:
                continue
            calls += 1
            for k in ("input_tokens", "cached_tokens", "output_tokens"):
                tok[k] += s.get(k) or 0
    return {"children": len(children), "provider_calls": calls,
            "input_tokens": tok["input_tokens"],
            "cached_tokens": tok["cached_tokens"],
            "uncached_input_tokens": tok["input_tokens"] - tok["cached_tokens"],
            "output_tokens": tok["output_tokens"]}


def codex_unit_usage(unit_dir, n):
    calls = 0
    tok = Counter()
    for k in range(1, n + 1):
        f = unit_dir / f"child_{k}.events.jsonl"
        if not f.exists():
            continue
        for line in f.read_text().splitlines():
            evt = json.loads(line)
            if evt.get("type") == "turn.completed":
                calls += 1
                u = evt.get("usage") or {}
                tok["input_tokens"] += u.get("input_tokens") or 0
                tok["cached_tokens"] += u.get("cached_input_tokens") or 0
                tok["output_tokens"] += u.get("output_tokens") or 0
    return {"children": n, "provider_calls": calls,
            "input_tokens": tok["input_tokens"],
            "cached_tokens": tok["cached_tokens"],
            "uncached_input_tokens": tok["input_tokens"] - tok["cached_tokens"],
            "output_tokens": tok["output_tokens"]}


rows = [json.loads(l) for l in RUNS.read_text().splitlines()]
per_unit = []
by_arm_n = {}
for r in rows:
    arm, n, rep = r["arm"], r["n"], r["rep"]
    prefix = "t3-"
    unit = T2 / f"{prefix}{arm}-n{n}-rep{rep}"
    usage = (pixir_unit_usage(unit) if arm == "pixir-delegate"
             else codex_unit_usage(unit, n))
    if not usage or usage["provider_calls"] == 0:
        continue
    icsw = r["icsw_sum"]
    syscpu = r["sys_s_sum"]
    calls = usage["provider_calls"]
    entry = {
        "arm": arm, "n": n, "rep": rep,
        "provider_calls": calls,
        "calls_per_child": round(calls / n, 1),
        "uncached_input_tokens": usage["uncached_input_tokens"],
        "output_tokens": usage["output_tokens"],
        "icsw_per_call": round(icsw / calls) if icsw is not None else None,
        "sys_cpu_ms_per_call": (round(syscpu * 1000 / calls, 1)
                                if syscpu is not None else None),
    }
    per_unit.append(entry)
    by_arm_n.setdefault((arm, n), []).append(entry)

summary = {"note": ("Per-call normalization from durable evidence: pixir child "
                    "session-log provider_usage, codex per-task turn.completed. "
                    "Purpose: pixir children make many provider calls per child "
                    "while codex makes ~1, so normalizing per call shows the "
                    "per-worker pressure gap is NOT an artifact of pixir doing "
                    "deeper multi-call work: codex pays MORE kernel pressure per "
                    "individual provider call. Medians via statistics.median "
                    "(even rep counts average the middle pair; corrected "
                    "2026-07-07, previous revision took the upper value)."),
           "per_n": {}}
for (arm, n), entries in sorted(by_arm_n.items()):
    def med(key):
        vals = [e[key] for e in entries if e[key] is not None]
        return round(statistics.median(vals), 1) if vals else None
    summary["per_n"].setdefault(str(n), {})[arm] = {
        "reps": len(entries),
        "median_calls_per_child": med("calls_per_child"),
        "median_icsw_per_call": med("icsw_per_call"),
        "median_sys_cpu_ms_per_call": med("sys_cpu_ms_per_call"),
    }

OUT.write_text(json.dumps({"summary": summary, "per_unit": per_unit}, indent=2) + "\n")
print(f"reconciled {len(per_unit)} units -> {OUT.name}")
for n in ("8", "16", "32", "64"):
    d = summary["per_n"].get(n, {})
    p = d.get("pixir-delegate", {})
    c = d.get("codex-exec", {})
    print(f"N={n:>2}: pixir {p.get('median_calls_per_child')} calls/child, "
          f"{p.get('median_icsw_per_call')} icsw/call, "
          f"{p.get('median_sys_cpu_ms_per_call')} sysCPUms/call  |  "
          f"codex {c.get('median_calls_per_child')} calls/child, "
          f"{c.get('median_icsw_per_call')} icsw/call, "
          f"{c.get('median_sys_cpu_ms_per_call')} sysCPUms/call")
