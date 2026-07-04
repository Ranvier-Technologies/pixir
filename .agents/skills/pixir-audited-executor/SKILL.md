---
name: pixir-audited-executor
description: Use Pixir as an audited local executor for Codex-led work. Use when Codex should delegate a bounded task to Pixir while retaining meta-orchestration, evidence review, and commit decisions.
argument-hint: "bounded task, expected artifact, or run bundle path"
---

# Pixir Audited Executor

Use this Skill when Codex should ask Pixir to execute a bounded task and then audit
the result from durable evidence. Pixir is the executor/orchestrator. Codex remains
the meta-orchestrator and auditor.

Do not use this Skill to replace Codex judgment. Use it to create an independent
Pixir Log and artifact bundle that Codex can inspect.

## Operating Model

```text
Codex
  defines objective, scope, gates, and evidence requirements

Pixir
  executes the bounded task, optionally with subagents or workflows
  writes canonical local Logs
  produces artifacts in a run bundle

Codex
  audits Logs, diagnostics, replay, tree, artifacts, and diffs
  accepts, rejects, or warns on the run
```

Assistant summaries are not primary evidence. If a summary contradicts Pixir Logs
or diagnostic output, trust the Logs and classify the summary as narrative error.

## When To Use

Use this Skill for:

- dogfooding Pixir on real bounded tasks,
- evidence-led research or repo audits,
- subagent/workflow demonstrations,
- tasks where an auditable independent Log matters,
- Pixir-as-runtime experiments governed by Codex.

Do not use it for:

- trivial shell commands,
- unbounded coding tasks without a clear artifact,
- T3 adapter debugging before Pixir Log/replay health is checked,
- commits or pushes without a separate Codex review.

## Run Bundle

Create one local bundle per delegated run:

```text
/tmp/pixir-run-<timestamp>-<slug>/
├── INDEX.md
├── prompt.md
├── command.txt
├── session-id.txt
├── doctor.json
├── session-diagnosis.json
├── inspect-replay.json
├── tree.json
├── artifacts/
└── codex-verdict.md
```

The bundle is execution evidence, not product documentation.

## Preflight

Before launching Pixir:

1. Choose binary provenance:
   - source dogfood: `./pixir`
   - installed daily-driver path: `pixir`
2. Run:

```bash
pixir doctor --json
```

3. Write `prompt.md` with:
   - objective,
   - scope,
   - output path under `artifacts/`,
   - constraints,
   - what not to change,
   - expected completion signal.
4. Write `command.txt` with the exact command Codex will run.

## Launch Pattern

Prefer a prompt that forces durable output into the bundle:

```bash
pixir "$(cat /tmp/pixir-run-<timestamp>-<slug>/prompt.md)"
```

If continuing an existing Pixir Session:

```bash
pixir resume <session-id> "$(cat /tmp/pixir-run-<timestamp>-<slug>/prompt.md)"
```

Capture the Session id into `session-id.txt`. If the Session id is not obvious from
stdout, locate it from `.pixir/sessions/` by timestamp and confirm with the Log.

## Audit Commands

After the run:

```bash
pixir diagnose session <session-id> --json > /tmp/pixir-run-<timestamp>-<slug>/session-diagnosis.json
pixir inspect-replay <session-id> --json > /tmp/pixir-run-<timestamp>-<slug>/inspect-replay.json
pixir tree <session-id> --json > /tmp/pixir-run-<timestamp>-<slug>/tree.json
```

Use `pixir-diagnostics` if the run shows missing tool output, replay drift,
subagent lifecycle confusion, T3 projection issues, or provider stream exits.
Routine audit collection stays in this Skill; if any audit command reveals missing
tool output, replay drift, inconsistent lifecycle state, or UI/projection
disagreement, switch to `pixir-diagnostics` and classify the incident before
accepting the run.

## Codex Verdict

Write `codex-verdict.md` with:

```text
# Codex Verdict

Status: ACCEPT | ACCEPT_WITH_WARNINGS | REJECT | INCONCLUSIVE

## Evidence

- Session id:
- Bundle:
- Doctor:
- Diagnose session:
- Inspect replay:
- Tree:
- Artifacts:

## Claims Checked

| Claim | Evidence | Status |
|---|---|---|

## Classification

Primary label:

## Next Action
```

Allowed claim statuses:

- `proved`
- `weak`
- `missing`
- `contradicted`

Do not mark the run accepted unless the task artifact exists and the diagnostic
evidence is adequate for the requested work.

## Boundaries

- Codex decides commits.
- Pixir can create or modify files only within the requested scope.
- Pixir summaries can guide the audit but cannot complete it.
- Do not push to upstream remotes as part of an audited executor run.
- Prefer small runs. Large objectives should be split into waves.

## Completion Criteria

The delegated run is complete only when:

- the run bundle exists,
- `prompt.md` and `command.txt` preserve the instruction and command,
- `session-id.txt` names the Pixir Session,
- diagnostics are captured or a reason is documented,
- `codex-verdict.md` maps claims to evidence,
- Codex has decided the next action.
