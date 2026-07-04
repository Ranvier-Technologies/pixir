# Subagents Benchmark Design

Date: 2026-06-02
Status: Implemented for first runtime/observability suite

## Purpose

This benchmark measures how well T3 Code can orchestrate parallel delegated work when
Subagents are provided by two different runtimes:

- T3 Code -> Codex provider -> Codex-native subagent behavior.
- T3 Code -> Pixir ACP -> Pixir BEAM-native Subagents.

The benchmark is not a model-quality contest. It is a runtime, observability, and UX
benchmark for agent fan-out from the T3 Code surface.

For the planned head-to-head suite that uses real model-backed network requests, model
preflight, cost caps, fixture scoring, and comparable Pixir/Codex runs, see
`docs/benchmarks/real-network-subagents.md`.

For the agent-facing CLI contract that governs `--help`, `--dry-run`, `--json`,
structured errors, and completion evidence, see
`docs/benchmarks/agent-tool-adapter-contract.md`.

## Goal Frame

Objective: build a repeatable benchmark suite that compares Codex-spawned and
Pixir-spawned Subagent workflows from T3 Code.

Target success condition: the full suite produces machine-readable evidence for
lifecycle latency, parallelism, failures, cancellation, resume/load, T3 presentation,
and output quality on the same fixtures.

Current completion scope: the first suite covers runtime and observability. It proves
Pixir-native fan-out stress, T3-visible Pixir fan-out, and T3-visible Codex fan-out
where practical. Work-quality scoring remains a later benchmark layer.

Constraints:

- Use the same T3 Code checkout, project fixture, prompts, and model class when possible.
- Separate browser/UI smoke evidence from runtime benchmark evidence.
- Treat Codex-vs-Pixir as non-equivalent when one side does not expose the same lifecycle
  surface through T3.
- Avoid mutating real project files. Use temporary fixture workspaces unless a scenario
  explicitly exercises writes in isolated workspaces.
- Do not compare hidden internal reasoning. Compare observable events, logs, outputs,
  filesystem effects, and recovery behavior.

Non-goals:

- Deciding which model is smarter.
- Measuring total dollar cost unless usage accounting is available in both paths.
- Replacing unit tests for `Pixir.Subagents`.
- Proving T3 Code upstream support for Pixir-specific UI affordances.

Expected artifacts:

- A benchmark harness under T3 Code or Pixir test support.
- A deterministic repo fixture.
- JSONL or JSON benchmark runs with timestamps and scenario metadata.
- A summarized Markdown report.
- Optional Chrome screenshots for UX smoke only.

Risk level: medium. The workflow involves real providers, local runtime state, and
browser pairing; weak evidence can look convincing if the benchmark only checks a final
assistant answer.

## Current Adapter

Pixir ships a deterministic no-network stress adapter:

```bash
mix pixir.bench.subagents
mix pixir.bench.subagents --n 1,5,10 --repetitions 3
mix pixir.bench.subagents --dry-run --json
mix pixir.bench.subagents --output .pixir/benchmarks/subagents/custom-run
```

It writes:

- `runs.jsonl`: one machine-readable record per scenario.
- `summary.json`: aggregate requirements, schema validation, and completion audit.
- `report.md`: human-readable benchmark table, schema validation, audit, and
  comparability notes.
- `completion_audit.json`: machine-readable proof closure audit for root agents.

Default output is `.pixir/benchmarks/subagents/<run-id>/`, which is ignored local
runtime state.

The adapter proves Pixir's BEAM-native stress layer and records Codex comparability as
`not_observed` because this adapter intentionally does not drive T3 Code's Codex
provider. Codex visibility is measured by the separate local T3/Codex probe below.

In the paired local T3 Code checkout, the corresponding T3 runtime harness lives at
`scripts/pixir-subagents-benchmark.ts`. It drives `makePixirAcpRuntime` directly and is
intentionally local-only unless the user explicitly asks to upstream T3 Code changes.

The paired Codex observability probe lives at
`scripts/codex-subagents-observability-probe.ts`. It drives T3 Code's
`makeCodexSessionRuntime` and records Codex app-server `collabAgentToolCall` lifecycle
items visible to T3.

Current summarized evidence lives in `docs/benchmarks/subagents-report.md`.

## Benchmark Layers

### 1. Contract Benchmark

Runs without Chrome. The harness drives T3 Code's runtime surfaces directly, similar to
the existing `pixir-*-e2e.ts` scripts.

Primary questions:

- Does T3 initialize the provider and discover models/modes?
- Does a prompt create observable child lifecycle updates?
- Does the runtime translate tool and Subagent updates into T3 events?
- Are parent and child logs persisted?
- Do `cancel`, `resume`, and `load` preserve enough state to continue or inspect results?

Suggested scenarios:

- `contract_spawn_wait_n`: spawn `N` read-only workers and wait for completion.
- `contract_partial_timeout`: one worker times out, others complete.
- `contract_cancel_mid_fanout`: cancel while workers are running.
- `contract_resume_after_completion`: close runtime, load/resume parent session, verify
  terminal Subagent summaries are replayed.
- `contract_plan_mode_explorer`: in plan/read-only mode, verify whether read-only
  explorer fan-out is allowed or explicitly denied.

Metrics:

- `prompt_to_first_child_event_ms`
- `prompt_to_all_spawned_ms`
- `wait_all_completed_ms`
- `total_turn_ms`
- `spawned_count`
- `completed_count`
- `failed_count`
- `timed_out_count`
- `cancelled_count`
- `parent_log_events`
- `child_log_count`
- `t3_event_count_by_kind`

### 2. Work Benchmark

Runs on a deterministic repo fixture with realistic modules and seeded findings.

Primary question:

Can the runtime use parallel workers to produce a better repo review than a single
worker while keeping results observable and recoverable?

Fixture shape:

- `auth/`: credentials, permissions, and token refresh code.
- `provider/`: streaming, retry, and model selection code.
- `tools/`: read/write/bash/edit tool contracts.
- `ui/`: presenter and update translation code.
- `persistence/`: event log and resume/fold code.
- `tests/`: fixture tests with both passing and intentionally weak coverage.

Each subsystem should contain known facts and planted issues. A scoring script should
know the expected file refs and findings without requiring model internals.

Suggested scenarios:

- `review_single_agent`: one worker reviews the whole fixture.
- `review_fanout_5`: five workers review one subsystem each.
- `review_fanout_10`: ten workers split files more finely.
- `review_fanout_25`: stress moderate fan-out and synthesis.
- `review_failure_recovery`: one assigned subsystem is intentionally ambiguous or slow.

Metrics:

- `expected_findings_found`
- `false_positive_count`
- `file_ref_precision`
- `file_ref_recall`
- `duplicate_finding_count`
- `synthesis_coverage`
- `root_summary_token_estimate` when measurable
- `wall_clock_ms`
- `subagent_output_bytes`
- `parent_log_bytes`
- `child_log_bytes_total`

### 3. UX Benchmark

Runs through Chrome with a local T3 Code pairing URL. This validates the human-facing
experience after the contract benchmark is already green.

Primary questions:

- Does the user see child lifecycle progress clearly?
- Does T3 remain responsive at `N = 10`, `25`, and `50`?
- Are tool rows readable, or do many workers collapse into noise?
- Does cancel work from the UI while Subagents are active?
- Does a resumed thread show a coherent story?

Evidence:

- Screenshot after spawn burst.
- Screenshot after partial failure.
- Screenshot after completion.
- DOM snapshot excerpts proving visible tool rows and final answer.
- Parent session log path and child session log paths.

Chrome is UX evidence only. It should not be the primary timing source.

## Comparison Matrix

| Capability | Codex path | Pixir path |
|---|---|---|
| T3-visible child lifecycle | Observed as `collabAgentToolCall` with `spawnAgent`/`wait` | Tool updates plus canonical `subagent_event`s |
| Parent/child logs | Measure if available through T3/Codex surface | Parent Log plus child Session Logs |
| `N = 25/50/100` fan-out | Measure practical limit | Expected BEAM strength; verify with stress runs |
| Cancel mid-fanout | Measure observable behavior | ACP cancel plus supervised child lifecycle |
| Resume/load after fan-out | Measure observable behavior | Parent replay with compact terminal summaries |
| Plan/read-only explorer fan-out | Depends on Codex/T3 behavior | Proposed Pixir policy: allow read-only explorer only |
| UI presentation | T3 generic provider surface | T3 generic ACP tool rows; richer UI would need T3 work |

If Codex does not expose Subagent lifecycle through T3, the strict benchmark should record
that as a capability gap instead of forcing an unfair emulation.

## Scale Plan

Run each scenario with:

```text
N = 1, 2, 5, 10, 25, 50
```

For Pixir stress-only runs, add:

```text
N = 100
```

Use at least five repetitions for benchmark tables. Report median, p95, min, max, and
failure count. Keep raw run records so later regressions can be compared.

## Evidence Policy

Do not accept a final assistant answer as sufficient proof. A run is only valid when the
evidence contains:

- Provider/runtime metadata: provider path, binary path or version, model id, mode,
  permission posture, workspace path, benchmark scenario id, and timestamp.
- T3 runtime evidence: request ids, event counts by kind, stop reason, and errors.
- Pixir evidence when testing Pixir: parent session log path, parent session id, child
  ids, child session ids, and terminal `subagent_event`s.
- Filesystem evidence for write scenarios: fixture path, expected file changes, and
  isolated workspace paths.
- Output evidence: final answer, scored findings, and machine-readable scoring result.
- UX evidence for Chrome scenarios: screenshot references and DOM excerpts.

## Proof Closure Semantics

Use named proof states instead of one pass/fail flag:

```text
benchmark_declared
-> fixture_created
-> runtime_configured
-> contract_run_started
-> lifecycle_observed
-> logs_reconciled
-> outputs_scored
-> resilience_checked
-> ux_smoked
-> report_written
-> completion_ready
```

`lifecycle_observed` is not completion: it proves that children appeared. Completion
requires reconciled logs, scored output, and scenario-specific recovery checks.

## Deterministic Suite Completion

The deterministic Pixir-native suite is complete when:

- `mix pixir.bench.subagents --dry-run --json` writes nothing and reports zero
  estimated real-network runs.
- `mix pixir.bench.subagents` produces `runs.jsonl`, `summary.json`, `report.md`, and
  `completion_audit.json`.
- Every run record declares `schema_version`, `network: false`, scenario metadata,
  metrics, and evidence.
- `summary.json` has `schema_validation.status = "passed"` and all deterministic
  requirements true.
- `completion_audit.json` has `status = "completion_ready"` and every requirement is
  `proved`.
- Spawn/wait records show zero active children after wait and no parent workspace writes.
- Close mid-fanout and replay summary scenarios pass.
- ExUnit covers CLI discovery, dry-run, structured errors, schema validation, artifact
  reconciliation, and scenario evidence.

## Tool Adapter Maturity

The first deterministic version is now a documented and verifiable Pixir-native adapter:

- Level 1: this document defines the contract and evidence policy.
- Level 2: `mix pixir.bench.subagents` provides `--n`, `--repetitions`, and `--output`
  with JSONL/JSON/Markdown evidence artifacts.
- Level 3: `mix pixir.bench.subagents` validates run records and summary shape, writes a
  completion audit, and reconciles `report.md` against the same run id and artifacts.

Real-network and T3/Codex head-to-head layers still need their own gates before being
used for architecture claims in a PR, blog post, or product decision.

## First Runtime Goal Closure

The first verifiable runtime/observability goal is ready to close when:

- At least one strict T3 runtime scenario runs for Pixir ACP.
- At least one T3 Codex probe records observable child lifecycle, or explicitly records
  the Codex path as not observable.
- Pixir runs `N = 1, 5, 10, 25, 50` for spawn/wait without orphaned active children.
- A close/cancel-like scenario demonstrates terminal lifecycle events for affected
  Pixir children.
- A resume/load-style scenario demonstrates compact terminal summaries in parent
  replay.
- A Markdown report summarizes raw evidence paths, metrics, and non-equivalence notes.
- Existing Pixir tests still pass.

## Full Benchmark Threshold

A full work-quality benchmark is ready to claim architecture/product conclusions only
when:

- The benchmark fixture is created and committed.
- At least one strict contract scenario runs for both comparable provider paths. A
  non-comparable path may be recorded as diagnostic evidence, but it does not satisfy
  the full benchmark threshold.
- Pixir runs `N = 1, 5, 10, 25, 50` for spawn/wait without orphaned active children.
- T3-visible cancellation demonstrates terminal lifecycle events for affected children.
- T3-visible resume/load demonstrates a coherent replay story after fan-out.
- A scoring script validates a work benchmark output against expected fixture findings.
- Run records, summary, and scoring outputs validate against machine-readable schemas.
- A separate RAM scaling gate runs cleanly for `N = 1, 3, 5` with at least three
  repetitions, baselines, and peak process-tree RSS reporting.
- A Markdown report summarizes raw evidence paths and metrics.
- Existing Pixir tests still pass.

## Suggested Goal Objective

Build a verifiable Subagents benchmark suite for T3 Code that compares Codex-visible
and Pixir-visible fan-out where possible, stress-tests Pixir BEAM-native Subagents at
`N = 1, 5, 10, 25, 50`, records lifecycle/log/output evidence, and emits a report with
clear non-equivalence notes for any Codex capability that T3 cannot observe.

## Open Questions

- Should Pixir implement read-only `spawn_agent` for explorer before the plan-mode
  benchmark, or should plan-mode denial be the current expected result?
- Should local T3 harnesses stay ad hoc scripts, or become a separate ignored/internal
  benchmark package?
- What fixture and scoring rubric should define the future work-quality benchmark?
