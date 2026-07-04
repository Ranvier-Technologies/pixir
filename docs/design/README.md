# Design notes

Investigations and proposals that explore a problem and weigh options **without yet
recording a decision**. The dividing line:

- `docs/adr/` — **decisions** (locked, dated, Accepted). One decision per file.
- `docs/design/` — **investigations** (this dir). Options + caveats + provenance. A design
  note may later be promoted to an ADR once its chosen subset is decided.
- `docs/benchmarks/` — **measurements** (numbers, harnesses, capability matrices).

Each note is numbered, states its Status (`Investigation / proposal`), and lists which
source files it was verified against and on what date. `[VERIFY]` / `[CONTRADICTS]` tags
inside a note are honesty markers from an adversarial code-check — they flag claims that are
net-new or that an earlier draft got wrong. Keep them; they tell the next reader exactly
what is real today vs proposed.

## Index

- [Design — Pixir marketing site direction](Design.md)
  — web positioning, visual system, home-page IA, and content strategy for presenting
  Pixir as a local-first, auditable agent runtime rather than a Pi/TUI replacement.
- [0001 — A write-set scheduler for subagent orchestration](0001-subagent-scheduler-write-set-orchestration.md)
  — why prose/`.sh` queue orchestrators force a human to hand-map chained dependencies and
  read-vs-write permits, and how a `Pixir.Scheduler` could derive the read/write posture from
  `Permissions.mutating?/2` (ADR 0006) and route through `Subagents.Manager` (ADR 0011) so
  collisions are safe-by-construction. Partially promoted by ADR 0012 as v1
  `Pixir.Workflows`; the larger scheduler/typed-output/merge-back ideas remain proposed.
  Builds on ADR 0001/0003/0004/0005/0006/0011.
- [0002 — Context compaction vs summarization](0002-context-compaction-vs-summarization.md)
  — summary as lossy artifact vs `history_compaction` as canonical replay checkpoint;
  why a compaction boundary is a triple lifecycle event (continuation reset, intentional
  cache break, key family preserved); the versioned prompt-contract re-layering (px2) with
  AGENTS.md discovery rule, fork-root cache-key family, explicit skill-activation
  limitations, and an advisory + overflow-recovery trigger policy. Provider-native
  compaction parked pending the production WebSocket transport. Grilled 2026-06-09 against
  external sources (Manus, LangChain/Deep Agents, OpenAI compaction docs) and live code.
  Builds on ADR 0003/0007/0018/0019; resolved directions promoted as ADR 0020.
