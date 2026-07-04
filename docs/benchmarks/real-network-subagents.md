# Real-Network Subagents Benchmark Design

Date: 2026-06-02
Status: Capability matrix, provider probe, common-model gate, smoke N=2, real-network
schema validation, representative scored fixture, and N-scalable lifecycle fixture
adapters implemented; usage reconciliation pending

## Goal Frame

Objective: design a comparative head-to-head benchmark for T3 Code subagent fan-out
where both sides use real model-backed network requests, multiple tools, the same
fixture, and auditable evidence.

Success condition: a future implementation can run Pixir and Codex through T3 Code on
the same benchmark fixture, record exact accepted models, force observable subagent
fan-out, collect tool/lifecycle/output/cost evidence, score results against known
answers, and avoid large accidental spend.

Constraints:

- Use real provider calls for the head-to-head runs. Fake providers remain allowed only
  for Pixir-native stress baselines.
- Compare the same T3 surface wherever possible: T3 runtime -> provider -> model/tool
  loop -> subagents.
- Use the same fixture, prompt family, model selection policy, concurrency target,
  timeout policy, and scorer for both providers.
- Keep default runs cheap enough for interactive iteration.
- Do not mutate real project files. Every run uses a temporary fixture workspace.
- Do not treat a final assistant answer as proof. A run is valid only when lifecycle,
  tool, output, and scoring evidence reconcile.

Non-goals:

- Proving one model is smarter in general.
- Stressing 25 or 50 model-backed child agents by default.
- Benchmarking browser UI rendering. Chrome can be a later UX smoke, not the timing
  source.
- Upstreaming T3 Code changes.

Risk level: high. Real model calls can silently fail the comparison by choosing not to
spawn, using different models, hitting rate limits, or producing plausible unscored
answers.

## Skill Intent

Desired posture: evidence-first, cost-aware, and deliberately non-hype. The benchmark
should make it hard to overclaim.

Semantic locks:

- "Real-network" means at least one live model request in the parent and live model
  requests for spawned child workers. A fake provider, fixture-only script, or final
  answer without child lifecycle evidence is not real-network completion.
- "Head-to-head" means both providers run the same scenario against the same fixture
  under the same accepted model and both expose observable subagent lifecycle. If the
  accepted model or lifecycle capability differs, the run is useful diagnostic evidence
  but does not satisfy head-to-head completion.
- "Multiple tools" means the workflow must include subagent lifecycle tools plus at
  least one non-subagent tool category such as file read, shell command, or write.
- "Representative" means the fixture has seeded findings and a scorer, not merely a
  prompt asking the model to say that it spawned children.
- "Cheap" means the default suite is small and capped; larger N is opt-in.

Assumptions:

- Pixir can be driven through `pixir acp` from the local T3 Code runtime harness.
- Codex can be driven through T3 Code's Codex app-server runtime harness.
- Both paths can accept a model override, but exact model support may differ.
- Current Pixir advertises `gpt-5.3-codex-spark`, `gpt-5.3-codex`, and nearby Codex
  family models locally.
- Current public OpenAI model docs document `gpt-5.3-codex` as the most capable
  agentic coding model and document GPT-5.3-Codex pricing and reasoning effort values.
  Public docs also describe Codex-Spark as a focused UI-iteration product/use-case
  label, not as a public API model slug. Therefore Spark must be probed before use.

## Source Notes

Official model docs currently relevant to this design:

- `gpt-5.3-codex`: https://developers.openai.com/api/docs/models/gpt-5.3-codex
- OpenAI models index: https://platform.openai.com/docs/models
- Codex use cases mentioning Codex-Spark:
  https://developers.openai.com/codex/use-cases

Design implication:

> Use `gpt-5.3-codex-spark` only as a candidate that must pass preflight. The primary
> head-to-head should use the first model slug accepted by both providers. If Spark is
> accepted only by Pixir, record it as a Pixir-native variant, not the main comparison.

## Tool Policy And Adapter Level

The benchmark should become a Level 3 verifiable Tool Adapter before its numbers are
used in a PR, blog post, or architecture claim.

The shared agent-facing adapter contract lives in
`docs/benchmarks/agent-tool-adapter-contract.md`.

Implemented V0 adapter command:

```bash
mix pixir.bench.real_subagents
```

Recommended gate CLI:

```bash
mix pixir.bench.real_subagents \
  --scenario common_model_gate \
  --models gpt-5.5 \
  --reasoning-effort low
```

Recommended future representative CLI:

```bash
mix pixir.bench.real_subagents \
  --scenario representative_review_n3 \
  --providers pixir,codex \
  --models gpt-5.5 \
  --reasoning-effort low \
  --output .pixir/benchmarks/real-subagents/<run-id>
```

Recommended scaling lifecycle CLI:

```bash
mix pixir.bench.real_subagents \
  --scenario scaling_lifecycle \
  --providers pixir,codex \
  --models gpt-5.5 \
  --reasoning-effort low \
  --n 10 \
  --output .pixir/benchmarks/real-subagents/<run-id>
```

Adapter maturity requirements:

| Level | Requirement |
|---|---|
| Documented | This file defines purpose, scenarios, evidence, scoring, and cost policy. |
| Executable | A CLI creates fixtures, launches T3 harnesses, records JSONL, and emits Markdown. |
| Verifiable | Run records validate against a schema, scorer output reconciles with fixture truth, model probes are recorded, and completion audit is machine-readable. |

The first implementation lives in `mix pixir.bench.real_subagents`. It shells into the
local T3 harnesses and records a provider/model capability matrix. It can run
`probe`, `smoke_real_n2`, and `common_model_gate`: the gate probes candidate models on
both providers, selects the first model accepted by both, then runs `smoke_real_n2`
only for that model. If model or lifecycle parity is missing, it records
`model_diverged` or `capability_diverged` as an explicit non-comparable abort. It can
also run `representative_review_n3`, which generates the seeded fixture, writes
`benchctl`, injects a scenario prompt, applies the same `--reasoning-effort` knob to
both provider paths, samples process-tree RSS for RAM comparison, and scores strict
final JSON. It can also run `scaling_lifecycle`, which generates one deterministic
shard assignment per requested child and scores lifecycle plus mechanical assignment
completion instead of seeded review recall. Usage reconciliation is still pending. The
T3 harnesses should remain local-only unless explicitly requested otherwise.

Canonical Pixir-owned copies of those local-only harness templates live in
`docs/benchmarks/t3-harnesses/`. Install or refresh them in the paired T3 checkout with:

```bash
mix pixir.bench.install_t3_harnesses --dry-run --json
mix pixir.bench.install_t3_harnesses
```

Installed T3 copies remain local-only. Do not upstream them unless explicitly requested.

## Executable V0: Capability Matrix And Gates

Use this before running any representative work-quality scenario:

```bash
mix pixir.bench.real_subagents --dry-run
mix pixir.bench.real_subagents --dry-run --json
mix pixir.bench.real_subagents
mix pixir.bench.real_subagents --scenario probe --models gpt-5.5 --reasoning-effort low
mix pixir.bench.real_subagents --scenario common_model_gate --dry-run --json
mix pixir.bench.real_subagents --scenario common_model_gate --models gpt-5.5 --reasoning-effort low
mix pixir.bench.real_subagents --models gpt-5.5 --reasoning-effort low
mix pixir.bench.real_subagents --scenario representative_review_n3 --providers pixir
```

The default run is deliberately small:

- Pixir with `gpt-5.3-codex-spark`.
- Codex with its default model.
- Codex with `gpt-5.3-codex-spark`.
- `N = 1` child agent per provider/model probe.

It writes:

```text
runs.jsonl
summary.json
report.md
provider-artifacts/<provider>/<model>/
provider-artifacts/<provider>/<model>/memory-samples.txt
```

The default V0 proves provider/model capability only. The `representative_review_n3`
scenario adds fixture scoring, but it is not a full head-to-head until it has been run
against both Pixir and Codex with the same accepted model, observable subagent lifecycle
on both paths, comparable fixture/scoring evidence, and usage evidence.

`common_model_gate` is the current cheap preflight for that future report. It writes
`runs.jsonl`, `summary.json`, `report.md`, and `completion_audit.json`. Its completion
states are:

| State | Meaning | Can proceed to representative? |
|---|---|---|
| `common_model_smoke_ready` | A common accepted model was selected and both providers exposed smoke N=2 lifecycle. | Yes. |
| `model_diverged` | No candidate was accepted by both providers under the same accepted model id. | No. |
| `capability_diverged` | A common model was accepted, but smoke lifecycle was not observed on both provider paths. | No. |

The gate writes `schema_validation` and `completion_audit` in `summary.json`, plus a
standalone `completion_audit.json`. For this gate, `model_diverged` and
`capability_diverged` are valid completion states because they prove the requested
head-to-head is not comparable yet. They are not valid completion states for the final
representative head-to-head report.

## Model Selection Policy

Model selection is part of the evidence, not a hidden config.

Preflight steps:

1. Record local Pixir model catalog from `Pixir.Provider.models/0`.
2. Record T3/Codex session-reported model capability if available.
3. Probe each candidate model with a tiny live request on both paths.
4. Run a tiny subagent-capability probe for each candidate that the provider accepts.
5. Pick the first candidate accepted by both providers that also exposes subagent
   lifecycle on both paths.
6. If no common model is accepted, run provider-native variants and mark the run
   `model_diverged`. This diagnoses non-comparability; it is not a completed
   head-to-head.
7. If a model is accepted by both providers but only one path exposes subagent lifecycle,
   run provider-native variants and mark the run `capability_diverged`. This diagnoses
   non-comparability; it is not a completed head-to-head.

Default candidates:

```text
gpt-5.5
gpt-5.3-codex-spark
gpt-5.3-codex
gpt-5.2-codex
gpt-5.1-codex
```

Default reasoning:

- `low` for smoke and contract runs.
- `medium` for the representative work-quality run.
- Never use `high` or `xhigh` by default.

Why this matters:

- `gpt-5.3-codex-spark` is locally configured in Pixir and may be the cheap/fast target
  the user wants.
- Public OpenAI docs establish `gpt-5.3-codex`, not Spark, as the official model slug
  for agentic coding.
- On 2026-06-02, Spark was accepted by both Pixir and Codex app-server, but only Pixir
  exposed subagent lifecycle under that model in the T3 path. Treat Spark as a fast
  Pixir capability target unless a refreshed Codex/T3 probe shows `collabAgentToolCall`
  spawn/wait lifecycle.
- A benchmark that silently compares Spark on Pixir to another Codex model on the Codex
  path is still interesting, but it is not a strict model-controlled head-to-head.
- A benchmark that only proves "the model slug was accepted" is too weak. Model
  preflight must also prove that the provider path exposes subagent lifecycle under that
  model. Otherwise the run must be labeled `capability_diverged`.

## Cost Controls

The benchmark should be cheap by default and explicit when it becomes expensive.

Default hard caps:

| Cap | Default |
|---|---:|
| Providers | `pixir,codex` |
| Real-network child count | `N = 2` |
| Repetitions | `1` |
| Reasoning effort | `low` |
| Scenario timeout | `180 s` |
| Child timeout | `90 s` |
| Max real-network scenarios per run | `2` |
| Budget warning threshold | `$2.00` estimated API cost |
| Require explicit opt-in above | `N > 5`, repetitions > 2, or reasoning > medium |

Recommended suite tiers:

| Tier | Purpose | Providers | N | Reps | Expected spend posture |
|---|---|---|---:|---:|---|
| `probe` | Validate auth/model/network. | pixir,codex | 0 | 1 | Tiny. |
| `smoke_real_n2` | Prove real subagent fan-out on both paths. | pixir,codex | 2 | 1 | Cheap. |
| `representative_review_n3` | Score useful multi-tool work. | pixir,codex | 3 | 1 | Still modest. |
| `stability_n2_r3` | Check variance. | pixir,codex | 2 | 3 | Opt-in. |
| `scale_real_n5` | Practical upper real-network fan-out smoke. | pixir,codex | 5 | 1 | Opt-in. |
| `scaling_lifecycle` | N-scalable lifecycle/RSS measurement with mechanical shard assignments. | pixir,codex | 10 | 1 | Explicit opt-in. |
| `pixir_native_stress` | BEAM lifecycle stress, no network. | pixir only | 10,25,50,100 | 1+ | Cheap, but not head-to-head. |

Cost workarounds that keep the run representative:

- Use tiny fixtures with real code, not large repos.
- Constrain child outputs to strict JSON with short evidence strings.
- Force each child to inspect only one assigned subsystem.
- Use `low` reasoning for lifecycle scenarios.
- Use `medium` only for the scored representative run.
- Forbid network inside tool commands.
- Prefer `benchctl` helper commands over expensive exploratory shell output.
- Cap final answer length and fail runs that exceed the cap.

The adapter should estimate cost before running. If exact token usage is unavailable on
one side, report estimated transcript tokens and mark cost proof as `estimated`, not
`measured`.

## Fixture Design

Create a small temporary repo fixture per run:

```text
fixture/
  AGENTS.md
  README.md
  benchctl
  truth/
    expected_findings.json
  src/
    auth/token_store.ex
    provider/retry_policy.ex
    tools/executor.ex
    ui/acp_translate.ex
  tests/
    smoke_test.exs
```

The fixture should be small enough that a child can inspect its assigned subsystem in
one or two tool calls, but realistic enough to require actual reading and command use.

Seeded findings:

| Id | Area | Kind | Expected evidence |
|---|---|---|---|
| `AUTH-001` | auth | secret handling | Token-like value is accidentally logged in one branch. |
| `PROV-001` | provider | retry policy | Rate-limit retry sleeps are uncapped in one path. |
| `TOOL-001` | tools | workspace confinement | One path joins an absolute child path without rechecking root. |
| `ACP-001` | ui | transport discipline | One diagnostic write goes to stdout in ACP mode. |
| `TEST-001` | tests | weak coverage | Existing test asserts only status, not output evidence. |
| `SYN-001` | synthesis | cross-cutting | A final answer should group stdout/secrets/tool confinement as safety risks. |

`benchctl` commands:

```bash
./benchctl manifest
./benchctl inspect auth
./benchctl inspect provider
./benchctl inspect tools
./benchctl inspect ui
./benchctl score final.json
```

The model should not know `truth/expected_findings.json` exists. The scorer uses it
after the run.

The `scaling_lifecycle` scenario uses a different fixture shape because it is not
trying to measure review quality:

```text
fixture/
  AGENTS.md
  README.md
  benchctl
  shards/
    shard-001.txt
    shard-002.txt
    ...
    shard-010.txt
```

For each requested child, the Mix task generates exactly one shard file and one prompt
assignment. Each child must read `AGENTS.md`, run `./benchctl inspect shard-###`, and
return that shard id plus its result key. The parent's final JSON must report
`requested_children`, `target_max_concurrency`, `completed_children`, and
`completed_shards`. The prompt keeps the task and assignments identical, but includes
provider-native tool hints because Pixir and Codex expose different subagent surfaces
through T3.

Concurrency semantics are explicit rather than inferred:

- `requested_children = N`.
- `target_max_concurrency = min(N, 6)` by default, matching Codex's documented default
  subagent thread cap while still allowing N > 6 as queued fan-out.
- A provider may queue internally, but it may not simulate child work in parent text.
- Completion is judged from lifecycle events, wait/completion evidence, parsed final
  JSON, and shard assignment recall/precision.

## Real-Network Scenarios

### 1. `probe`

Purpose: confirm auth, model, and network reachability before spending on subagents.

Per provider:

- Start runtime.
- Send one tiny prompt with no subagents.
- Record accepted model, stop reason, errors, and any usage event.

Valid when:

- Provider returns a final answer or a usage-limit/model-not-supported error with
  structured details.
- Model selection outcome is recorded.

### 2. `smoke_real_n2`

Purpose: prove both providers can perform real model-backed subagent fan-out through T3.

Prompt skeleton:

```text
You are running a real-network subagent benchmark.

Spawn exactly 2 read-only child agents. Assign child A to auth and child B to provider.
Each child must:
1. Read AGENTS.md and the assigned src file.
2. Run ./benchctl inspect <area>.
3. Return strict JSON: {area, finding_ids, evidence, tools_used}.

Wait for both children. Finish with strict JSON:
{requested_children, completed_children, child_ids, findings, lifecycle_visible}.

Do not modify files. Keep every evidence string under 160 characters.
```

Required observable tools:

- Subagent spawn.
- Subagent wait.
- File read or equivalent local inspection.
- Shell command for `benchctl inspect`.

Valid when:

- T3 observes at least two child spawn lifecycle events.
- T3 observes a wait/completion event.
- Final JSON parses.
- At least one expected finding id is recovered.
- Tool evidence shows non-subagent tool use.

### 3. `representative_review_n3`

Purpose: measure whether fan-out helps a bounded code-review task.

Assignments:

- Child A: `auth`
- Child B: `provider`
- Child C: `tools` and `ui`

Prompt differences from smoke:

- Ask for ranked findings with file refs.
- Ask parent to deduplicate child outputs.
- Ask parent to produce `final.json` either as final text or a file in the fixture root.

Scoring:

| Metric | Meaning |
|---|---|
| `expected_recall` | Expected finding ids recovered / expected ids for assigned areas. |
| `precision` | Valid finding ids / all claimed finding ids. |
| `file_ref_accuracy` | Claimed file refs match expected area and plausible file. |
| `duplicate_rate` | Same issue repeated in final synthesis. |
| `hallucinated_count` | Claimed ids or risks not supported by fixture. |
| `synthesis_score` | Parent grouped findings into useful risk categories. |
| `tool_compliance` | Required read/shell/subagent lifecycle tools observed. |
| `peak_tree_rss_mb` | Peak sampled RSS of the T3 harness process tree, including provider children. |
| `peak_component_rss_kb` | Peak-snapshot RSS grouped approximately into BEAM/Erlang/Pixir, Codex, Node/Bun, and shell processes. |

Valid when:

- Both providers complete the scenario under the same accepted model.
- Divergent provider-native runs are valid diagnostics only; they do not satisfy this
  scenario as a head-to-head comparison.
- Scorer produces a machine-readable score for both providers.
- The report includes non-equivalence notes for missing lifecycle/log details.

`representative_review_n3` is intentionally fixed at exactly three children. Do not use
it for N=5/N=10 scaling claims; use `scaling_lifecycle` instead.

### 4. `scaling_lifecycle`

Purpose: measure N-scalable fan-out lifecycle, wait/completion evidence, latency, and
peak process-tree RSS without mixing the result with repository-review quality.

Generated prompt contract:

```text
Spawn exactly N child agents immediately.
requested_children: N
target_max_concurrency: min(N, 6)

Child 001: read AGENTS.md, run ./benchctl inspect shard-001, return shard-001.
Child 002: read AGENTS.md, run ./benchctl inspect shard-002, return shard-002.
...

Wait for every child result.
Finish with strict JSON:
{
  "scenario": "scaling_lifecycle",
  "requested_children": N,
  "target_max_concurrency": min(N, 6),
  "completed_children": number,
  "completed_shards": ["shard-001"],
  "failed_children": number,
  "tool_notes": []
}
```

Scoring:

| Metric | Meaning |
|---|---|
| `spawn_request_satisfied` | T3-visible spawn count is at least requested N. |
| `wait_completion_observed` | T3 observes at least one wait/completion lifecycle event. Pixir may wait all children with one call; Codex may show one wait per child. |
| `assignment_recall` | Valid reported shard ids / expected shard ids. |
| `assignment_precision` | Valid reported shard ids / all reported shard ids. |
| `json_requested_children_matches` | Final JSON echoes the requested N. |
| `json_target_concurrency_matches` | Final JSON echoes the explicit concurrency target. |
| `tool_compliance` | Raw/final evidence includes spawn, wait, `benchctl`, `inspect`, and shard references. |
| `peak_tree_rss_mb` | Peak sampled RSS of the T3 harness process tree, including provider children. |

Completion-ready threshold:

- At least one real-network N >= 10 run is included.
- Both providers run under the same requested and accepted model.
- Every non-baseline scaling record passes.
- Every score has `assignment_recall = 1.0`, `assignment_precision = 1.0`,
  `spawn_request_satisfied = true`, and `wait_completion_observed = true`.
- `summary.json`, `runs.jsonl`, `report.md`, and `completion_audit.json` validate.

### 5. `write_isolation_n2`

Purpose: test safe writes without mutating real project state.

Prompt:

```text
Spawn 2 implementation workers.
Each worker must inspect one assigned area and write a tiny JSON report to
bench-output/<area>.json, then run ./benchctl score bench-output/<area>.json.
Wait for both workers and summarize the written files.
```

Comparable write policy:

- Codex path writes to unique `bench-output/<area>.json` files in the shared temp
  fixture.
- Pixir path may write inside child isolated workspaces by default. The parent should
  report child workspace output paths from Pixir evidence rather than pretending they
  are in the same root.

Valid when:

- Filesystem effects are reconciled against the provider's workspace model.
- No writes happen outside the temp fixture or child workspace snapshots.

This scenario is opt-in because it is more likely to surface non-equivalent workspace
semantics.

## Execution Matrix

Default head-to-head:

| Scenario | Providers | N | Reps | Reasoning | Required for first real report |
|---|---|---:|---:|---|---|
| `probe` | pixir,codex | 0 | 1 | low | Yes |
| `smoke_real_n2` | pixir,codex | 2 | 1 | low | Yes |
| `representative_review_n3` | pixir,codex | 3 | 1 | medium | Yes |
| `scaling_lifecycle` | pixir,codex | 10 | 1 | low | Yes, for N=10+ scaling claims |
| `write_isolation_n2` | pixir,codex | 2 | 1 | low | No, opt-in |
| `stability_n2_r3` | pixir,codex | 2 | 3 | low | No, opt-in |

Do not run real-network `N = 25` or `50` by default. `N = 10` is allowed only through
the explicit `scaling_lifecycle` scenario after the common-model gate is current and
the operator accepts the cost. Larger values remain Pixir-native no-network stress
targets until N=10 proves stable.

## Evidence Schema

Each run writes:

```text
runs.jsonl
summary.json
report.md
fixtures/<scenario-id>/
provider-artifacts/<provider>/<scenario-id>/
```

Minimum record fields:

```json
{
  "run_id": "string",
  "scenario": "smoke_real_n2",
  "provider": "pixir",
  "provider_path": "t3code-pixir-acp",
  "status": "passed",
  "model_requested": "gpt-5.3-codex-spark",
  "model_accepted": "gpt-5.3-codex",
  "model_selection_status": "common_model|model_diverged|capability_diverged",
  "reasoning_effort": "low",
  "n": 2,
  "repetition": 1,
  "started_at": "iso8601",
  "duration_ms": 12345,
  "workspace": "path",
  "t3": {
    "event_count": 0,
    "event_count_by_kind": {},
    "stop_reason": "end_turn"
  },
  "lifecycle": {
    "spawn_visible_count": 0,
    "wait_visible_count": 0,
    "completed_count": 0,
    "failed_count": 0,
    "cancelled_count": 0
  },
  "tools": {
    "subagent_tools_observed": [],
    "non_subagent_tools_observed": [],
    "benchctl_invocations": []
  },
  "usage": {
    "kind": "measured|estimated|missing",
    "input_tokens": null,
    "cached_input_tokens": null,
    "output_tokens": null,
    "reasoning_output_tokens": null,
    "estimated_cost_usd": null
  },
  "score": {
    "expected_recall": null,
    "precision": null,
    "file_ref_accuracy": null,
    "duplicate_rate": null,
    "hallucinated_count": null,
    "synthesis_score": null
  },
  "evidence_paths": {
    "fixture": "path",
    "t3_events": "path",
    "parent_log": "path-or-null",
    "child_logs": [],
    "final_output": "path",
    "score": "path"
  },
  "non_equivalence_notes": []
}
```

A provider may pass the scenario while still having `usage.kind = "estimated"` if token
usage is not exposed equivalently. It may not pass with missing lifecycle evidence.
Records labeled `model_diverged` or `capability_diverged` may pass as diagnostics, but
the unified head-to-head report must remain incomplete until a `common_model` record set
exists for both providers.

## Proof Closure Semantics

Use these proof states:

```text
benchmark_declared
-> official_model_sources_checked
-> fixture_created
-> model_candidates_probed
-> subagent_capability_probed
-> common_model_selected
-> t3_pixir_runtime_configured
-> t3_codex_runtime_configured
-> real_network_parent_turn_started
-> child_lifecycle_observed
-> non_subagent_tool_use_observed
-> wait_completion_observed
-> final_output_parsed
-> mechanical_assignments_scored
-> outputs_scored
-> usage_measured_or_estimated
-> logs_and_workspaces_reconciled
-> schema_validated
-> report_written
-> completion_ready
```

States that are not enough:

- `model_candidates_probed` is not enough because no subagents ran.
- `subagent_capability_probed` is not enough because it can prove tool availability
  without producing useful work.
- `model_diverged` or `capability_diverged` is enough to close `common_model_gate` as a
  non-comparable abort, but it is not enough for the final representative head-to-head.
- `child_lifecycle_observed` is not enough because children may not have used tools or
  produced scorable work.
- `final_output_parsed` is not enough because the model can produce valid JSON with no
  evidence.
- `usage_measured_or_estimated` is not enough because cost evidence is not quality
  evidence.

## Common Gate Completion Threshold

The current cheap gate is completion-ready when:

- `probe` records are written for both Pixir and Codex.
- The probe records select a common accepted model, or record `model_diverged` with a
  structured `abort_reason`.
- If a common accepted model exists, `smoke_real_n2` runs only for that selected model.
- The smoke records either prove lifecycle on both provider paths or record
  `capability_diverged` with a structured `abort_reason`.
- `representative_review_n3` is not run by this gate.
- `summary.json` includes `common_model_gate` and `completion_audit`.

This threshold is intentionally narrower than the full report. It answers whether we
are allowed to spend on `representative_review_n3`.

## Scaling Lifecycle Completion Threshold

The `scaling_lifecycle` scenario is completion-ready when:

- The run includes at least one non-baseline record with `N >= 10`.
- The run uses a model that has already passed a current common-model lifecycle gate.
- Both Pixir and Codex records are present for the same requested model and reasoning
  effort.
- T3 observes at least N spawn lifecycle events for every provider record.
- T3 observes wait/completion lifecycle evidence for every provider record.
- The final parent JSON parses and reports the requested child count and concurrency
  target.
- The final parent JSON reports every generated shard exactly once, with no hallucinated
  shard ids.
- `summary.json`, `runs.jsonl`, `report.md`, and `completion_audit.json` validate.

If any of these fail, the run may still be useful diagnostic evidence, but it is not a
head-to-head N=10 scaling result.

## Common Model Gate: 2026-06-02

Command:

```bash
mix pixir.bench.real_subagents \
  --scenario common_model_gate \
  --models gpt-5.5 \
  --reasoning-effort low \
  --json
```

Artifact:
`.pixir/benchmarks/real-subagents/20260602T190310477149/`

Result: `common_model_smoke_ready`.

The gate selected `gpt-5.5` as both the requested and accepted model on Pixir and
Codex. It then ran `smoke_real_n2` only for that selected model. Both provider paths
showed observable lifecycle:

| Provider | Probe status | Smoke status | Spawn visible | Wait visible | Duration | Peak tree RSS |
|---|---|---|---:|---:|---:|---:|
| Pixir | `passed` | `passed` | 2 | 1 | 20.5s | 246.45 MB |
| Codex | `passed` | `passed` | 2 | 2 | 93.0s | 1152.23 MB |

`summary.json` recorded:

```json
{
  "status": "common_model_smoke_ready",
  "selected_model_requested": "gpt-5.5",
  "selected_model_accepted": "gpt-5.5",
  "head_to_head_ready": true,
  "next_allowed_scenario": "representative_review_n3",
  "schema_validation": {
    "status": "passed",
    "record_issues": [],
    "summary_issues": [],
    "completion_audit_issues": [],
    "report_issues": []
  },
  "completion_audit": {
    "status": "completion_ready"
  }
}
```

This proves the cheap gate, not the full benchmark. It allows the next real-network
step: a bounded `representative_review_n3` head-to-head under `gpt-5.5` with reasoning
`low` or `medium`, depending on the cost posture we choose.

## Representative Review N=3: 2026-06-02

Command:

```bash
mix pixir.bench.real_subagents \
  --scenario representative_review_n3 \
  --models gpt-5.5 \
  --reasoning-effort low \
  --json
```

Artifact:
`.pixir/benchmarks/real-subagents/20260602T194733505400/`

Result: `representative_scored`.

Both provider paths used the same requested and accepted model, exposed subagent
lifecycle, produced parseable final JSON, passed schema validation, and passed the
completion audit:

| Provider | Status | Spawn visible | Wait visible | Duration | Peak tree RSS | Precision | Expected recall |
|---|---|---:|---:|---:|---:|---:|---:|
| Pixir | `passed` | 3 | 1 | 29.4s | 246.36 MB | 1.0000 | 0.6667 |
| Codex | `passed` | 3 | 3 | 101.5s | 1369.34 MB | 1.0000 | 0.6667 |

`summary.json` recorded:

```json
{
  "status": "representative_scored",
  "common_capable_models": ["gpt-5.5"],
  "records_count": 2,
  "observed_count": 2,
  "schema_validation": {
    "status": "passed",
    "record_issues": [],
    "summary_issues": [],
    "completion_audit_issues": [],
    "report_issues": []
  },
  "completion_audit": {
    "status": "completion_ready"
  }
}
```

Two harness details matter for interpreting this run:

- Codex app-server under T3's `approval-required` runtime can request command approval
  for child `benchctl` calls. The local Codex harness auto-accepts command approvals
  during this benchmark fixture so `wait` can complete. It does not auto-accept file
  changes.
- Codex child agent messages are observable as `item/agentMessage/delta` events. The
  harness records lifecycle evidence separately but scores only parent-thread final
  text so child JSON snippets do not contaminate final-answer parsing.

## Representative Escalation N=5 And N=10: 2026-06-02

After the N=3 head-to-head completed, the same scenario was run at N=5 and N=10 with
`gpt-5.5` and reasoning `low`.

N=5 command:

```bash
mix pixir.bench.real_subagents \
  --scenario representative_review_n3 \
  --models gpt-5.5 \
  --reasoning-effort low \
  --n-values 5 \
  --json
```

Artifact:
`.pixir/benchmarks/real-subagents/20260602T195114290047/`

Result: `representative_scored`.

| Provider | Status | Spawn visible | Wait visible | Duration | Peak tree RSS | Precision | Expected recall |
|---|---|---:|---:|---:|---:|---:|---:|
| Pixir | `passed` | 5 | 1 | 35.9s | 245.69 MB | 1.0000 | 0.6667 |
| Codex | `passed` | 5 | 5 | 161.8s | 1541.77 MB | 1.0000 | 0.6667 |

N=10 command:

```bash
mix pixir.bench.real_subagents \
  --scenario representative_review_n3 \
  --models gpt-5.5 \
  --reasoning-effort low \
  --n-values 10 \
  --json
```

Artifact:
`.pixir/benchmarks/real-subagents/20260602T195444154110/`

Result: `representative_weak`.

| Provider | Status | Spawn visible | Wait visible | Duration | Peak tree RSS | Precision | Expected recall |
|---|---|---:|---:|---:|---:|---:|---:|
| Pixir | `weak` | 0 | 0 | 123.2s | 242.98 MB | 0.0000 | 0.0000 |
| Codex | `not_observed` | 0 | 0 | 184.6s | 491.44 MB | 0.0000 | 0.0000 |

The N=10 run validates the harness schema path but not the head-to-head capability. The
prompt generator for this scenario asks for exactly 10 child agents while still defining
only Child A, Child B, and Child C assignments and budgets. N=5 happened to complete
despite that mismatch; N=10 did not produce observable subagent lifecycle on either
provider. Treat this as a benchmark-design failure, not as evidence that either provider
cannot run 10 subagents.

This finding was folded into the adapter contract:

- `representative_review_n3` is now fixed at exactly three children and rejects larger
  `--n`/`--n-values`.
- `scaling_lifecycle` is the N-variable scenario. Its prompt is mechanically generated
  for every requested child and its scoring focuses on lifecycle, latency, RSS, final
  JSON, and shard assignment completion rather than repository-review recall.

## Scaling Lifecycle N=10: 2026-06-02

The corrected `scaling_lifecycle` path exposed two important benchmark bugs before it
produced evidence worth reporting.

First, Pixir appeared to return empty turns with no T3-visible lifecycle. The root cause
was not Subagents capacity: Pixir's Provider was ignoring streamed
`response.failed`/`error` events and recording an empty `assistant_message`, while
`wait_agent.ids` had an incomplete strict JSON schema (`array` without `items`) that
could trigger backend failure when tools were advertised. The fix:

- `Pixir.Provider` now turns streamed `response.failed`/`error` events into structured
  provider errors instead of empty assistant messages.
- `wait_agent.ids` now declares string `items`.
- Tool contract tests now reject array schemas without `items`.
- `mix pixir.smoke.e2e --probe-model --model gpt-5.5` verified live text output after
  the fix.
- `mix escript.build` refreshed the `./pixir` binary used by the T3 Pixir harness.

Second, an early Pixir N=10 run looked superficially successful while children used the
`explorer` agent. That agent is read-only, so `./benchctl inspect ...` was denied even
though the final parent JSON listed all shards. The scorer now requires every
deterministic `shard-###-ok` result key to appear in the raw/final evidence, and the
Pixir prompt now asks for `agent="worker"` for implementation-style shard inspection.

Corrected Pixir-only N=10 command:

```bash
mix pixir.bench.real_subagents \
  --scenario scaling_lifecycle \
  --providers pixir \
  --models gpt-5.5 \
  --reasoning-effort low \
  --n 10 \
  --json
```

Artifact:
`.pixir/benchmarks/real-subagents/20260602T203512453752/`

Result: `completion_ready`, status `scaling_lifecycle_scored`.

| Provider | Status | Spawn visible | Wait visible | Duration | Peak tree RSS | Assignment precision | Assignment recall | Benchctl results observed |
|---|---|---:|---:|---:|---:|---:|---:|---|
| Pixir | `passed` | 10 | 1 | 36.8s | 247.08 MB | 1.0000 | 1.0000 | Yes |

The completion audit proved `scaling_lifecycle_scored`,
`scaling_lifecycle_n10_plus_included`, `mechanical_assignments_completed`,
`benchctl_results_observed`, and `spawn_and_wait_lifecycle_observed`.

Corrected head-to-head N=10 command:

```bash
mix pixir.bench.real_subagents \
  --scenario scaling_lifecycle \
  --providers pixir,codex \
  --models gpt-5.5 \
  --reasoning-effort low \
  --n 10 \
  --json
```

Artifact:
`.pixir/benchmarks/real-subagents/20260602T203601195614/`

Result: `completion_blocked`, status `scaling_lifecycle_weak`. This is a useful result,
not a failed adapter or a victory claim: schema validation passed, both providers
exposed lifecycle, and the completion audit blocked the run because Codex did not
complete all mechanical assignments or observe every deterministic result key.

| Provider | Status | Spawn visible | Wait visible | Duration | Peak tree RSS | Assignment precision | Assignment recall | Benchctl results observed |
|---|---|---:|---:|---:|---:|---:|---:|---|
| Pixir | `passed` | 10 | 1 | 51.6s | 243.86 MB | 1.0000 | 1.0000 | Yes |
| Codex | `weak` | 10 | 3 | 110.0s | 2065.64 MB | 1.0000 | 0.6000 | No |

Codex's final parent JSON reported `completed_children = 6`, completed shards
`shard-001` through `shard-006`, `failed_children = 4`, and noted that four spawns
failed due to an agent thread limit. The scorer identified missing deterministic result
keys for `shard-007-ok` through `shard-010-ok`. The benchmark therefore proves lifecycle
visibility on both paths, and it now records a concrete N=10 scaling weakness in Codex's
T3 provider path without reporting the paired run as fully completion-ready.

## Spark Capability Divergence: 2026-06-02

Command:

```bash
mix pixir.bench.real_subagents \
  --scenario common_model_gate \
  --models gpt-5.3-codex-spark \
  --reasoning-effort low \
  --json
```

Artifact:
`.pixir/benchmarks/real-subagents/20260602T191413561177/`

Result: `capability_diverged`.

Spark was reachable on both provider paths, but the lifecycle capability was not
symmetric:

| Provider | Probe status | Smoke status | Spawn visible | Wait visible | Duration | Peak tree RSS |
|---|---|---|---:|---:|---:|---:|
| Pixir | `passed` | `passed` | 2 | 1 | 24.0s | 244.08 MB |
| Codex | `passed` | `not_observed` | 0 | 0 | 36.2s | 588.41 MB |

An explicit prompt that named Codex's internal `spawnAgent` and `wait` tools also did
not make Spark emit `collabAgentToolCall` items through T3's Codex runtime. The model
reported that the interface did not expose those tools.

A separate local-only app-server probe tested the programmatic workaround of creating a
thread with `threadSource: "subagent"`. Codex accepted and returned the metadata
(`threadSource: "subagent"`), and the child thread completed a normal turn, but it
emitted no `collabAgentToolCall` lifecycle and no `spawnAgent`/`wait` tools. This is a
manual child-thread pattern, not Codex model-emitted subagent lifecycle. It should not
be mixed into the strict head-to-head benchmark.

## Full Head-To-Head Completion Threshold

The first real-network head-to-head report is completion-ready only when:

- `probe` runs for both Pixir and Codex.
- A common accepted model with subagent lifecycle enabled on both paths is selected.
- `smoke_real_n2` runs for both Pixir and Codex with real network calls.
- `representative_review_n3` runs for both Pixir and Codex with real network calls.
- Both providers show child lifecycle and wait/completion evidence.
- Both providers show at least one non-subagent tool category.
- The scorer produces machine-readable output for both providers.
- Usage is measured where available and otherwise estimated with an explicit marker.
- Pixir parent/child logs are reconciled.
- Codex observable lifecycle details are recorded without claiming Pixir-like local Logs
  unless that evidence exists.
- Run records, summary, and scorer outputs validate against their schemas.
- A Markdown report states what is comparable and explicitly separates any divergent
  provider-native diagnostics from the head-to-head result.

## RAM Scaling Gate

The complete benchmark package also requires a separate RAM scaling gate. This gate is
mandatory for BEAM/OTP memory-scaling claims, but it does not share the same pass/fail
state as the representative scorer.

`ram_scaling_ready` is true only when:

- The post-wrapper-fix RAM scaling suite runs cleanly.
- The run uses the same accepted model and reasoning effort on both provider paths.
- `N = 1, 3, 5` run with at least three repetitions each.
- Baseline no-network harness rows are included for both provider harnesses.
- Every raw record has a clean harness exit code, RSS samples, and lifecycle evidence.
- The report states `peak process-tree RSS`, baseline-adjusted RSS, median, p95, and
  failure counts.

This gate answers a different question from `representative_review_n3`: how provider
process-tree RAM scales with child count under the same T3 surface.

## T3 Resilience Gate

The complete benchmark package also requires a minimal T3 resilience gate. Pixir-native
close/replay checks are useful, but they do not prove that the default T3 surface can
recover or inspect a fan-out workflow.

`t3_resilience_ready` is true only when:

- A T3 runtime scenario cancels a prompt while child agents are active.
- The run records terminal lifecycle evidence for the parent and affected children.
- A T3 runtime scenario resumes or loads a completed parent session after fan-out.
- Resume/load evidence shows a coherent final story without duplicating completed
  assistant content.
- The report separates provider runtime behavior from T3 presentation behavior.

Plan-mode explorer fan-out and Chrome UX are useful later gates, but they are not part
of this minimal resilience threshold.

## Expected Answer To The Head-To-Head Question

## RAM Scaling Suite: 2026-06-02

Command:

```bash
mix pixir.bench.real_subagents \
  --models gpt-5.5 \
  --reasoning-effort low \
  --n-values 1,3,5 \
  --repetitions 3 \
  --include-baseline
```

Artifact:
`.pixir/benchmarks/real-subagents/20260602T165110388168/`

This run compared the same T3 provider surface, same requested and accepted model
(`gpt-5.5`), same reasoning effort (`low`), and the same child counts. RAM is sampled
as peak RSS of the T3 harness process tree and descendants. Baseline rows are
no-network harness imports/runs for each provider-specific harness.

| Provider | N | Passed | Median duration | p95 duration | Median peak RSS | Baseline-adjusted median RSS |
|---|---:|---:|---:|---:|---:|---:|
| Pixir | 1 | 3/3 | 17.1s | 18.1s | 245.25 MB | 106.44 MB |
| Codex | 1 | 3/3 | 89.7s | 90.0s | 795.91 MB | 609.03 MB |
| Pixir | 3 | 3/3 | 20.9s | 21.3s | 248.94 MB | 110.13 MB |
| Codex | 3 | 3/3 | 98.2s | 99.6s | 1512.20 MB | 1325.32 MB |
| Pixir | 5 | 3/3 | 28.1s | 29.7s | 245.48 MB | 106.67 MB |
| Codex | 5 | 3/3 | 108.6s | 111.8s | 1928.39 MB | 1741.51 MB |

Interpretation: for this smoke fan-out workload, Pixir's process-tree RSS stayed
near-flat from N=1 to N=5, while Codex's process-tree RSS increased with child count.
This supports an end-to-end T3 provider-path claim, not a universal runtime claim.

Method note: this run was produced before a wrapper variable name fix. The structured
raw provider statuses, RSS samples, and effective benchmark status are valid, but
`runs.jsonl` contains `harness_exit_code: 1` because `status` is read-only in zsh. The
wrapper was fixed afterward and validated with a Pixir baseline + N=1 check at
`.pixir/benchmarks/real-subagents/20260602T171058080709/`, where
`harness_exit_code` is `0`.

This benchmark is designed to answer:

> How does Pixir compare to Codex when T3 Code spawns multiple real model-backed
> subagents?

The expected output should not be one winner. It should produce a structured answer:

| Question | Output |
|---|---|
| Did both providers spawn and wait on multiple child agents? | Pass/weak/fail with event evidence. |
| Did both providers use multiple tools beyond subagent lifecycle? | Tool category counts and examples. |
| Did the children find seeded issues? | Recall, precision, and hallucination metrics. |
| Did parent synthesis improve or degrade the result? | Synthesis score and duplicate rate. |
| Did one path expose better lifecycle auditability? | Logs, child ids, workspace evidence, and non-equivalence notes. |
| Was the model controlled? | Common model only; `model_diverged` is diagnostic, not head-to-head completion. |
| Was cost controlled? | Measured or estimated usage plus cap status. |

The likely first fair conclusion is:

> Codex is the more mature T3-integrated subagent path. Pixir is the more explicit local
> runtime path. The real-network benchmark should show whether Pixir's supervision,
> Logs, and isolated workspaces produce better observability or recovery without losing
> too much on product integration, latency, or work quality.

## Remaining Implementation Work

Implemented:

- `mix pixir.bench.real_subagents` coordinates local T3 harnesses and writes one
  unified run directory.
- `probe`, `smoke_real_n2`, `common_model_gate`, and `representative_review_n3` are
  adapter scenarios.
- `scaling_lifecycle` is the N-variable, mechanically generated scenario for N=10+
  lifecycle/RSS comparison.
- The representative fixture generator writes `benchctl`, source files, truth data,
  and a scoring prompt.
- The scaling fixture generator writes deterministic shard files, a bounded `benchctl`,
  and one child assignment per requested child.
- Reports are generated from `summary.json` and `runs.jsonl`.
- Real-network outputs include schema validation and a completion audit for run
  records, summaries, reports, and gate status.
- The local Codex harness auto-accepts benchmark command approvals and filters final
  text to parent-thread deltas so scoring does not mix child agent messages with the
  parent final answer.

Remaining before a serious public report:

1. Extend the local T3 Pixir harness to record usage events if available and exact
   non-subagent tool categories.
2. Extend the local T3 Codex harness to record `thread.token-usage.updated` events and
   exact non-subagent tool categories.
3. Proceed to `representative_review_n3` only while the current or refreshed
   `common_model_gate` evidence returns `common_model_smoke_ready`.
4. Run `scaling_lifecycle --n 10` under the same refreshed common model before making
   N=10+ head-to-head claims.
5. Re-run the RAM scaling suite after the wrapper fix so no raw record carries a stale
   harness exit-code artifact.

Do not start with Chrome. A browser demo is useful after the runtime report exists, but
it should not be the proof source for this benchmark.
