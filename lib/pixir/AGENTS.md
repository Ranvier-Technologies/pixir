# AGENTS.md - Pixir Core

This directory is the runtime spine: Events, Log, Session, Turn, Conversation, Provider
handoff, Session Resources, Skills, Subagents, Workflows, and Compaction.

- Prefer this file, root `AGENTS.md`, `CONTEXT.md`, and the relevant ADR over legacy
  `CLAUDE.md` notes.
- Keep `CONTEXT.md` terms precise: Session is the unit of agency; the Log is truth;
  Workflows coordinate Subagents; Skills are installed practices, not executors;
  Session Resources are local durable evidence, not ambient prompt.
- Preserve ADR 0003/0004 invariants: canonical Events are durable, ephemeral deltas are
  bus-only, and Event `data` uses string keys.
- Adding a canonical Event type, changing History folding, or changing replay semantics
  needs an ADR-level check before code.
- Keep Provider usage, Session Resource descriptors, and future Skill Context Hydration
  as explicit evidence/context; do not smuggle them into user/assistant History.
- Keep front-ends entering through `Pixir.Conversation`; do not create a second Turn loop.

Fast checks:

```bash
mix test test/pixir
mix compile --warnings-as-errors
mix format --check-formatted
```
