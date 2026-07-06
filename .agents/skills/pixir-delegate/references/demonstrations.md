# Demonstrations of the practice

Real annotated traces — not invented examples. Demos 1-3: three agent classes
followed this skill blind (no prior context, the skill as their only manual)
on 2026-07-04/05, each exercising surfaces the others could not. Demo 4 is a
later, deliberately non-blind trace: a practiced orchestrator staking a real
merge decision on the practice (2026-07-06). Session ids reference
append-only logs under `.pixir/sessions/` on the machines where the runs
happened — Pixir evidence is machine-local by design, so those logs are not
in this repository. Read these as annotated accounts by the people holding
the logs, then generate your own primary evidence by following the skill.

The vicarious modes these demonstrate: watching someone **build** a
delegation, **exercise it under pressure**, **tune it after failures**,
**decide not to use it**, and **use it in production as a gate**.

## Demo 1 — Claude (Opus 4.8): building a fan-out, first try

Mission: produce groundwork for a Codex variant of this skill by fanning out
three read-only analysis workers.

- Parent session `20260704T234926-a51abe`; children `…-a8cd7f`, `…-49d6c0`,
  `…-b4b894` — 3/3 completed, one wave (`max_threads: 3`), all strict-JSON
  contracts parsed on arrival.
- What it proves: the routing table plus the validated starter spec carried a
  first-time orchestrator from zero to a reconciled three-worker envelope
  with no exploratory failures.
- Decision moment worth studying: it obeyed "discover, don't memorize" and
  ran `pixir delegate --help`, which revealed the daemon lifecycle the skill
  body does not document — the discovery instruction did work the prose
  could not.
- Tuning that came back into the skill: hydration was binary-blind (PATH held
  a stale v0.1.4 while the workspace had v0.1.5); the hydration line is
  binary-explicit because of this run.

## Demo 2 — Claude (Fable 5): pressure, refusal, and a real failure

Mission: three parts engineered to exercise judgment — sequentially dependent
analysis, a trivia question, and a deliberately tight-timeout fan-out.

- Refusal worked verbatim: for "which version are you working with" it did
  the work itself, citing "if writing the self-contained prompt costs more
  than doing the work, do it yourself". A delegation avoided is part of the
  practice.
- Sequential analysis ran as one resume chain (sid `20260705T000602-047492`),
  each step's prompt referencing the previous answer — routing row three,
  chosen from the skill text without hesitation.
- The failure, end to end: fan-out parent `20260705T001024-9f871b` with
  `--timeout-ms 20000` → exit 6, `work_complete: false`, 2 completed +
  1 timed_out. Recovery followed the prose exactly: read the timed-out
  child's `child_log_path` tail, `diagnose session`, then
  `resume 20260705T001024-4d919b` → completed, contract-conformant. The
  whole spec was never re-run. `pixir tree` on the parent confirms the
  reconciled family.
- Tuning that came back: the stderr resume-command promise was over-scoped
  (true for one-shot/resume, false for delegate partials) and envelope
  first-read orientation was missing — both fixed because this run hit them.

## Demo 3 — Pixir (gpt-5.5): the judgment transfers, the recipes don't have to

Mission: from INSIDE a Pixir session, produce groundwork for a Pixir-native
variant — with the actuation choice (CLI vs native Subagent tools) left
consciously open.

- Session `20260705T001653-399094`; children `20260705T001738-82acc2`,
  `20260705T001744-aa0bec` — both completed via native `spawn_agent`/
  `wait_agent`, reconciled through `list_agents`.
- The decision that matters: it declined the skill's own CLI commands,
  grounding the choice in the skill's anti-pattern line ("each boots its own
  VM") — shelling out to `pixir` from inside Pixir would add the exact layer
  the doctrine forbids. Practice over recipe, argued from the text.
- Honest gap it exposed: native Subagents have no `--dry-run` analog, so
  rehearsal degraded to schema validation; and `skill_view` hit an
  `orphan_tool_call` replay error on first call. Both filed as runtime
  findings, not skill patches — the skill cannot paper over its host.

## Demo 4 — Claude (Fable 5): the practice in production, as a pre-merge gate

Mission (2026-07-06, not a blind run: a practiced orchestrator using the
skill in anger): adversarially review a real PR before merge, four
independent lenses (correctness, security, contract honesty, test adequacy),
each a read-only child with a strict JSON verdict contract.

- Parent envelope reconciled 4/4 completed, zero retries; sids
  `20260706T171044-{d745a1,d137ea,66e8b7,ace82a}`. All four `summary` fields
  parsed against the declared verdict schema on arrival.
- The judgment moment: 17 findings came back and the orchestrator's job
  became adjudication. Two lenses independently converged on the same real
  bug (accepted, fixed), while a "major" severity was rejected as overclaimed
  after checking the claim against the actual threat model. The fan-out
  produces claims; the practice is deciding which survive.
- Rehearsal caught nothing it should have: the spec carried invented
  `model`/`reasoning_effort` knobs and dry-run accepted them silently. The
  honest workaround (isolated `PIXIR_HOME` with its own `config.json`,
  doctor-verified before spending quota) became skill text, and the
  validation gap became a runtime finding, the same split as Demo 3:
  runtime defects get filed, not papered over.
- What it proves: the closure discipline scales from "did my workers finish"
  to "can I stake a merge decision on this envelope".

## How to read these as a learner

Do not extract commands from the demos; extract decision shapes. Each demo
is one answer to "this situation asks for this form of attention, this
discipline of action, this standard of proof" — the same core
(references/delegation-core.md) actuated three different ways.
