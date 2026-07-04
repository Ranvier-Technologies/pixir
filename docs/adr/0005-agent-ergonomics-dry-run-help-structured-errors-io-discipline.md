# 5. Agent ergonomics: dry-run, self-describing help, structured errors, I/O discipline

Date: 2026-05-29
Status: Accepted

## Context

Pixir is built *by* agents as much as it is *for* them. The model drives tools, and
agents (including a fresh one with no prior context) drive the CLI and the dev
scripts. When a command's behaviour, arguments, or failure mode is opaque, the agent
guesses — it runs destructive actions to "see what happens", invents flags, or pastes
raw, unbounded output back into the model where it burns tokens and derails the Turn.

Two recurring failure modes motivate this decision:

1. **No safe preview.** A tool/command with side effects can only be understood by
   running it. There is no way to ask "what *would* you do?" first.
2. **Ambiguous I/O.** It is unclear what text is meant for the model, what is meant
   for the human at the terminal, and what is pure diagnostics. Everything collapses
   onto stdout, so the model ingests prompts/spinners/log noise and the human sees
   raw JSON.

This is a cross-cutting contract over the Tool behaviour (ADR 0001's Executor), the
Event/Log envelope (ADR 0004), and the CLI (build step 8). It costs us nothing to
adopt now and is expensive to retrofit.

## Decision

Every Pixir tool, CLI command, and dev script obeys four rules.

### 1. Dry-runnable

Anything with side effects (writes, shell, network, file mutation) supports a
**dry-run** that reports the *planned* action and the resources it would touch,
performs no mutation, and returns success.

- **CLI / scripts:** accept `--dry-run`.
- **LLM-facing tools:** the Executor honours a `dry_run` flag (per-call arg and/or a
  Turn-level mode). In dry-run a tool returns a structured *plan* (e.g.
  `%{would: :write, path: ..., bytes: ...}`) instead of acting.
- Read-only tools are trivially dry-run (they have no effect to suppress).

### 2. Self-describing for a fresh agent

A caller with zero context can discover capabilities without reading source.

- **CLI:** `pixir help` and `pixir <cmd> --help` print usage, every flag, and at
  least one example. Subcommands are individually discoverable.
- **Tools:** `__tool__/0` *is* the help — a complete name, description, and JSON
  schema (required/optional args, types). Descriptions are written for a fresh agent.
- Help text is plain and example-led; no hidden flags.

### 3. Structured errors

Failures are data, not just prose. Internally functions return `{:error, reason}`;
at every boundary that an agent or the model reads, the error serialises to a stable
envelope:

```
%{ok: false, error: %{kind: atom_or_string, message: human_string, details: map}}
```

`kind` is a small, stable, documented vocabulary (e.g. `:outside_workspace`,
`:not_found`, `:invalid_args`, `:timeout`) so callers can branch on it. The **canonical
enumeration is `t:Pixir.Tool.kind/0`** — the single source of truth; adding a kind is a
deliberate change there. CLI commands exit non-zero on error and emit the same envelope
on the diagnostic channel; successful machine output stays clean.

**Deliberate divergence — a nonzero shell exit is not an error.** A `bash` command that
runs and exits nonzero (e.g. `grep` finding nothing → exit 1) returns a *successful* tool
result `%{"output", "exit_code", "ok" => false}`, not an error envelope — the tool did its
job, and the model needs the output and code to reason (treating a no-match as a failure
would derail Turns). So there is no `:nonzero_exit` kind; branch on `exit_code`/`ok` within
the result instead.

### 4. I/O channel discipline — be deliberate about what reaches the LLM

Three distinct channels, never conflated:

- **Model channel** — the `tool_result` payload folded into History and sent to the
  model (ADR 0004). It is curated and **token-bounded**: large output is truncated
  with an explicit marker (e.g. `…[truncated N of M lines]`), never raw-dumped. No
  ANSI, spinners, or prompts.
- **Human channel (stdout)** — rendered, human-facing output produced by the
  Renderer (build step 9) from bus events. Formatting lives here.
- **Diagnostic channel (stderr / Logger)** — debug and operational noise. **Never
  seen by the model** and not part of any tool result.

Input is equally explicit: a one-shot prompt comes from `argv` or, when piped, from
**stdin**; a tool never silently reads stdin. Each tool documents which streams it
consumes and produces.

## Consequences

- **Safer autonomy.** Agents can preview destructive actions; dry-run is the natural
  first probe and pairs with the deferred `:ask` permission gate when it lands.
- **Faster cold starts.** A fresh agent orients via `--help` / `__tool__/0` instead
  of reading the codebase or trial-and-error.
- **Branchable failures + cheaper Turns.** Stable `kind`s let the loop react
  programmatically; bounded model-channel output keeps Turns from blowing the context
  window on log spew.
- **Cost / obligations.**
  - Every new tool and command must implement dry-run, help, the error envelope, and
    declare its streams — enforced in review (and ideally a shared test helper).
  - The `kind` vocabulary is a curated, documented set; adding one is a deliberate
    change.
  - Truncation policy (limits, marker format) is a tunable knob, decided in code
    alongside the Executor.
- The `Pixir.Tool` behaviour and Executor (build step 6) and the CLI (step 8) are the
  enforcement points; this ADR is their acceptance criteria.
