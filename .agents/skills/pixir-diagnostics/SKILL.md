---
name: pixir-diagnostics
description: Diagnose Pixir and T3 Code Pixir incidents from local canonical evidence. Use when a Pixir run, ACP/T3 thread, subagent/workflow, provider replay, or daily-driver dogfood session appears stuck, inconsistent, missing tool output, or hard to classify.
argument-hint: "session id, T3 thread id, or symptom"
---

# Pixir Diagnostics

Use this Skill when Pixir, a Pixir-backed T3 Code thread, or a Pixir Session needs an
evidence-backed diagnosis. The goal is to separate canonical Pixir facts from UI,
adapter, provider, or assistant-summary symptoms.

This Skill is procedural. Prefer existing Pixir commands first; do not build a new
script unless the same manual bundle is repeated enough to justify automation.

## Evidence Model

Rank evidence in this order:

1. Pixir canonical NDJSON Logs under `.pixir/sessions/` and child `.pixir/subagents/`.
2. Pixir diagnostic commands: `doctor`, `diagnose session`, `inspect-replay`, `tree`.
3. T3 Code durable storage or logs.
4. Screenshots or visible UI state.
5. Assistant summaries inside the conversation.

Assistant summaries are never proof when they contradict Logs.

## Default Workflow

1. Identify the workspace that owns the Session Log.
2. Identify the Pixir binary actually used:
   - source checkout: `./pixir`
   - Hex install: `pixir` on `PATH`
   - T3 provider config: `binaryPath`
3. Run local readiness:

```bash
pixir doctor --json
```

4. If a Pixir Session id is known, run:

```bash
pixir diagnose session <session-id> --json
pixir inspect-replay <session-id> --json
pixir tree <session-id> --json
```

5. If a T3 thread id is known, locate T3 durable state before guessing:

```bash
find "$HOME/Library/Application Support" -maxdepth 3 -iname '*t3*' -print
```

Then search bounded patterns such as the thread id, Pixir session id, or exact UI error
text. Avoid dumping whole LevelDB records into chat.

6. Produce a short verdict with:
   - classification,
   - evidence paths,
   - pass/fail/warning checks,
   - next action,
   - what not to infer.

## Command Surface

Use the repo binary when testing source changes:

```bash
mix escript.build
./pixir --version
./pixir doctor --json
./pixir diagnose session <session-id> --json
./pixir inspect-replay <session-id> --after-seq <n> --json
./pixir tree <session-id> --json
```

Use the Hex binary when diagnosing the installed daily-driver path:

```bash
command -v pixir
pixir --version
pixir doctor --json
pixir diagnose session <session-id> --json
```

## Classification

Classify incidents with one primary label:

| Label | Meaning |
|---|---|
| `pixir_core_log` | Canonical NDJSON Log is corrupt, missing, or internally inconsistent |
| `pixir_provider_replay` | Replay input differs from Log truth, has false or missing function outputs, or bad continuation metadata |
| `pixir_subagent_lifecycle` | Parent/child Session lifecycle facts disagree or child Logs are missing |
| `t3_projection_or_adapter` | T3 UI/storage disagrees with Pixir canonical facts |
| `provider_backend_or_stream` | Provider stream failed or emitted transient ids not persisted locally |
| `operator_workspace_or_binary` | Wrong workspace, stale source binary, or Hex/source binary confusion |
| `assistant_narrative_error` | Assistant described tool outcomes incorrectly despite healthy Logs |
| `unknown` | Evidence is insufficient or not durable |

Always state whether Pixir canonical Log integrity is `PASS`, `WARNING`, or `FAIL`.

## Common Pitfalls

- Do not confuse thread workspace with binary provenance. A T3 thread can run in one
  workspace while using a Hex-installed Pixir binary.
- Do not accept "No tool output found" from UI as proof of missing Pixir Log results.
  Check `tool_call`/`tool_result` pairing.
- Do not treat synthetic orphan closures as live missing results. They may be replay
  repair evidence.
- Do not treat a subagent summary as factual when the child Log says reads succeeded or
  failures were `permission_denied`.
- Do not patch the T3 adapter until Pixir replay and Log integrity have been checked.

## Artifact Bundle

For non-trivial incidents, write a local bundle:

```text
/tmp/pixir-diagnostics-<timestamp>/
├── INDEX.md
├── doctor.json
├── session-diagnosis.json
├── inspect-replay.json
├── tree.json
└── verdict.md
```

Keep raw storage dumps out of the bundle unless bounded and necessary.

## Completion Criteria

- `doctor --json` was run or explicitly skipped with a reason.
- For a known Session id, `diagnose session --json` and `inspect-replay --json` were run.
- For a known T3 thread id, durable T3 storage/logs were searched before assigning blame.
- The final answer separates Log truth, replay/provider behavior, T3 UI/projection, and
  assistant narrative.
- The next action is one of: patch Pixir, patch T3 adapter/UI, collect ephemeral stream
  evidence, clean misleading teaching/docs artifacts, or stop because no issue remains.
