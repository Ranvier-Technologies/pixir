# 6. Permission model: auto-run by default, smart opt-in gating

Date: 2026-05-29
Status: Accepted

## Context

v0.1 ships with tools auto-running and the interactive permission gate deferred
(ADR 0005, CONTEXT). Before building the gate we have to decide its *default stance*.

How people actually use coding agents informs this: the maintainer — and most users —
run Claude/Codex in "YOLO" / `--dangerously-skip-permissions` mode ~99% of the time. A
gate that prompts on every write or command is friction users immediately disable,
which means a prompt-by-default design optimizes for a mode almost nobody runs. Modern
models also rarely take harmful actions unprompted, and Pixir already bounds the blast
radius two ways: **Workspace confinement** (a hard floor) and **dry-run** (ADR 0005).

So the question is not "how do we ask about everything safely" but "how do we make the
*frictionless* path the blessed default, and make the optional gate smart enough that
turning it on isn't painful either."

## Decision

Permission handling is a **mode**, scoped to a Turn (sourced from the Session / CLI),
with **`:auto` as the default**:

- **`:auto` (default)** — every tool runs, no prompts. This is a first-class, blessed
  mode (not "dangerous mode"); it is how Pixir is expected to run most of the time.
- **`:ask` (opt-in)** — gate only *genuinely risky* operations, and be smart about it:
  - `read` and other read-only tools **never ask**.
  - `bash` commands on a conservative **safe-list** (read-only commands like `ls`,
    `cat`, `grep`, `git status|diff|log`, with no chaining/redirection/substitution)
    **auto-run**.
  - Only `write` and non-safe-listed `bash` actually prompt.
- **`:read_only` (opt-in)** — mutating tools are *denied* (not asked); reads and safe
  commands run. Pairs with a future read-only/plan role.

**Always-on floor, every mode:** Workspace confinement. Paths outside the Workspace are
*refused*, never "asked about" — confinement is the real safety boundary; the gate is a
convenience layer on top, not the floor.

Decisions in `:ask`/`:read_only` are recorded as canonical **`permission_decision`**
Events (already reserved in ADR 0004), so they are auditable in the Log and can be
answered by any front-end (the CLI today; the REPL/web later). The front-end supplies an
*asker*; the core never blocks on a hard-coded prompt.

**Deferred refinements (not v1):** session-scoped "remember / always allow this command"
allow-lists, per-role default modes, and pattern-based rules. v1 keeps the policy
stateless per call — the safe-list already removes most friction, and `:auto` remains
the default.

## Consequences

- **The default matches reality** — no friction for the way Pixir is actually used; you
  opt *into* gating, not out of it.
- **Confinement stays the floor** — safety doesn't depend on the user keeping prompts on.
- **`:ask` is tolerable when chosen** — reads and safe commands never interrupt; only
  real mutations prompt. It shines with the REPL (an interactive answerer).
- **Auditable** — `permission_decision` Events make gated runs replayable.
- **Cost** — the bash safe-list is a heuristic (first token + no shell metacharacters);
  it errs toward *asking*, never toward silently running something risky. Maintaining it
  is a small, deliberate vocabulary.
- The enforcement points are `Pixir.Permissions` (pure policy) and the Executor (which
  consults it and invokes the asker); `:auto` short-circuits to allow with zero overhead.
