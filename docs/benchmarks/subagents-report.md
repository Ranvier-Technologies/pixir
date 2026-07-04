# Subagents Benchmark Report

Date: 2026-06-02
Status: Completed for first runtime/observability suite

## Summary

The first verifiable runtime/observability Subagents benchmark suite now has three
evidence layers:

1. Pixir-native no-network stress adapter.
2. T3 Code -> Pixir ACP visible fan-out harness.
3. T3 Code -> Codex app-server visible fan-out probe.

The Codex side is observable from T3 Code through `collabAgentToolCall` provider events.
That makes the comparison more interesting than a simple capability gap: both runtimes
can show T3-visible child lifecycle, but they do not expose identical semantics.

## Evidence Artifacts

Local raw evidence is intentionally under ignored `.pixir/benchmarks/` state.

| Layer | Artifact | Status |
|---|---|---|
| Pixir native stress | `.pixir/benchmarks/subagents/latest/summary.json` | passed |
| Pixir native stress report | `.pixir/benchmarks/subagents/latest/report.md` | passed |
| T3 -> Pixir, `N=2` | `.pixir/benchmarks/subagents/t3-pixir-n2/t3-pixir-subagents-result.json` | passed |
| T3 -> Codex, `N=2` | `.pixir/benchmarks/subagents/t3-codex-n2/codex-subagents-observability.json` | observed |

The paired local T3 Code harnesses are installed into:

- `$T3_CODE_PATH/scripts/pixir-subagents-benchmark.ts`
- `$T3_CODE_PATH/scripts/codex-subagents-observability-probe.ts`

They are local-only T3 Code changes unless the user explicitly asks to upstream them.

## Pixir Native Stress

Command:

```bash
mix pixir.bench.subagents --output .pixir/benchmarks/subagents/latest
```

Result:

```json
{
  "status": "passed",
  "scales": [1, 5, 10, 25, 50],
  "failed_count": 0,
  "requirements": {
    "pixir_required_scales_present": true,
    "no_failed_records": true,
    "close_mid_fanout_checked": true,
    "replay_summary_checked": true,
    "codex_comparability_noted": true
  }
}
```

Stress timings:

| N | Status | First child ms | All spawned ms | Wait completed ms | Total ms | Completed | Active after wait |
|---:|---|---:|---:|---:|---:|---:|---:|
| 1 | passed | 9 | 9 | 35 | 44 | 1 | 0 |
| 5 | passed | 23 | 23 | 12 | 35 | 5 | 0 |
| 10 | passed | 59 | 59 | 9 | 68 | 10 | 0 |
| 25 | passed | 155 | 155 | 9 | 164 | 25 | 0 |
| 50 | passed | 373 | 373 | 12 | 385 | 50 | 0 |

This run is no-network and measures Pixir's BEAM-native lifecycle mechanics with fake
providers: supervision, isolated workspaces, parent/child logs, wait collection, close
mid-fanout, and replay summaries.

## T3 Code -> Pixir ACP

Command:

```bash
bun scripts/pixir-subagents-benchmark.ts --n 2 \
  --output "$PIXIR_ROOT/.pixir/benchmarks/subagents/t3-pixir-n2"
```

Result:

```json
{
  "status": "passed",
  "n": 2,
  "metrics": {
    "prompt_to_first_child_event_ms": 3455,
    "prompt_to_all_spawned_ms": 6497,
    "total_turn_ms": 26161,
    "spawned_visible_count": 2,
    "wait_visible_count": 1,
    "t3_event_count": 7,
    "tool_event_count": 3
  }
}
```

T3-visible evidence:

- Two `ToolCallUpdated` rows reported `Spawned sub_... (explorer) with status running`.
- One `wait_agent` result summarized both completed child agents.
- Pixir also produced a parent session log path and child session ids in raw evidence.

## T3 Code -> Codex App Server

Command:

```bash
bun scripts/codex-subagents-observability-probe.ts --n 2 \
  --output "$PIXIR_ROOT/.pixir/benchmarks/subagents/t3-codex-n2"
```

Result:

```json
{
  "status": "observed",
  "n": 2,
  "metrics": {
    "total_ms": 97511,
    "provider_event_count": 627,
    "collab_lifecycle_event_count": 8,
    "collab_spawn_completed_count": 2,
    "collab_wait_completed_count": 2,
    "unique_item_types": [
      "userMessage",
      "reasoning",
      "agentMessage",
      "collabAgentToolCall",
      "commandExecution"
    ]
  }
}
```

T3-visible evidence:

- Codex emitted `collabAgentToolCall` lifecycle events.
- The observed tool sequence included two completed `spawnAgent` calls.
- The observed tool sequence included two completed `wait` calls.
- Wait events carried `receiverThreadIds` and child result messages.

## Non-Equivalence Notes

This is an observability comparison, not an assertion that Codex and Pixir Subagents are
semantically identical. It also is not yet the future work-quality/scoring benchmark
described in `docs/benchmarks/subagents.md`.

Pixir exposes:

- explicit `subagent_id`s such as `sub_...`;
- parent `subagent_event` history;
- child Session ids;
- child Session Logs;
- isolated child workspaces;
- deterministic no-network stress up to at least `N=50`;
- compact terminal summaries replayed into parent history.

Codex exposes through T3:

- `collabAgentToolCall` lifecycle items;
- `spawnAgent` and `wait` tool names;
- `receiverThreadIds`;
- child status/message maps inside wait completion payloads.

Current Codex evidence does not prove:

- child Session Log paths comparable to Pixir's local NDJSON logs;
- deterministic no-network stress behavior;
- `N=25/50` local fan-out under T3 without model/network cost;
- identical cancellation/resume semantics.

So the fair conclusion is:

> T3 Code can observe fan-out in both runtimes. Pixir has stronger local runtime
> auditability and cheap BEAM stress evidence; Codex has visible app-server
> collaboration lifecycle, but not the same local child log/workspace semantics from
> this T3 surface.

## Checks

Pixir:

```bash
mix format --check-formatted
mix compile --warnings-as-errors
mix test
git diff --check
```

T3 Code:

```bash
bun fmt scripts/pixir-subagents-benchmark.ts scripts/codex-subagents-observability-probe.ts
bun run typecheck --filter='t3' --force
bun lint
```

`bun lint` currently reports warnings in existing T3 files and older Pixir harnesses,
but 0 errors.
