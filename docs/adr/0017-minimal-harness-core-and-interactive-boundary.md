# 17. Keep the Harness core minimal; put interactivity at Presenter boundaries

Date: 2026-06-06
Status: Accepted
Implementation status: Direction locked; first tree/compaction/replay-repair slices implemented

## Context

Pixir intentionally borrows from the Pi harness philosophy: keep the agent loop small,
then invest in context engineering, skills, tools, and user workflow around that loop.
Comparable terminal-first harnesses show the same product pressure: a small core loop
can quickly attract slash commands, UI state, session trees, and compaction behavior.

Pixir already has a stronger runtime spine for some of this: **Session -> Turn ->
Provider -> Tools**, canonical Events, append-only Logs, ACP, Skills, Subagents,
Workflows, and OTP supervision. The risk now is product gravity. It would be easy to
start adding slash commands, package catalogs, prompt-template expansion,
client-specific projection logic, compaction policy, and workflow UX directly into the
core Turn loop.
That would make Pixir feel more capable quickly, but it would blur the ownership lines
that make the Harness understandable and testable.

## Decision

Pixir keeps the Harness core minimal. The core owns durable agency:

- Session lifecycle and supervision;
- Turn/tool-loop execution;
- Provider dialect and replay input;
- Tool validation, permissioning, and workspace confinement;
- canonical Events, Logs, and History folding;
- Skills, Subagents, and Workflows when they affect runtime behavior or durable History.

Interactive behavior belongs at Presenter or adapter boundaries unless it changes those
durable semantics. A Presenter may parse `/skill`, expand a prompt template, render a
session tree, choose a model, attach files, or display Workflows. It must translate
those choices into explicit Pixir inputs and Events instead of becoming a second agent
runtime.

For ACP clients and other Presenters, the boundary is:

```text
Presenters own product presentation.
Pixir owns agent runtime truth.
OpenAI owns model execution.
```

Presenters may own chat bubbles, editor chrome, diff panels, approval UX, model
pickers, and local projection databases. They may also provide late UX context to Pixir:
open files, selected ranges, branch/mode, diagnostics, attachments, and permission
choices. Presenters must not assemble the Provider prompt, choose replay shape, own
`previous_response_id`, run Pixir Tools directly, or treat projection databases as
Pixir's canonical replay source. The normal command flow is Presenter/ACP action ->
Pixir `Conversation`/`Session` command -> Pixir Turn/tool loop -> Pixir Events ->
Presenter projection.

The concrete boundary is:

- **Allowed outside core:** slash command parsing, local UI state, visual tree views,
  prompt-template selection, catalog browsing, model picker UX, adapter-specific
  projection reconciliation, and installer/patcher flows.
- **Belongs in core:** anything that changes future Provider input, permissions, Tool
  availability, durable Skill Activation, Subagent lifecycle, Workflow scheduling,
  checkpoint/partial outcome semantics, or Log replay.

Compaction follows the same rule. A Presenter can request or display compaction, but a
summary that affects future model input must be represented as durable Log-backed state
or as a deterministic projection from the Log. It is not a hidden UI cache.
ADR 0018 defines the first concrete mechanism: canonical `history_compaction` Events,
Provider replay through latest checkpoint plus recent tail, and Session-level repair for
orphan `tool_call` Events.

Session trees also remain projections. Pixir may expose branch/fork/tree views, but the
canonical representation remains Logs, parent-child relationships, and durable Events.

Package-style growth should happen through explicit practices: Skills, Workflow
Templates, PATCHMD/patcher repositories, and future installable bundles. Pixir should not
bundle arbitrary third-party dependencies merely to feel like an app store.

## Consequences

- Pixir can grow Pi-like ergonomics without making the Turn loop a kitchen sink.
- ACP, CLI, and future UIs can differ in interaction style while sharing one
  runtime contract.
- Client integrations can become polished product shells without becoming competing
  Harnesses. Adapter bugs should first be diagnosed as projection or protocol-boundary
  issues before changing Pixir Log or Turn semantics.
- Skills stay "installed practices", not hidden commands that bypass Tools or
  permissions.
- Compaction and branching get a durable design path instead of becoming transient UI
  behavior.
- Adapter-specific problems remain adapter/patcher concerns unless they reveal a
  missing Pixir protocol contract.
- Some UX work takes longer because Presenter affordances must be translated into
  explicit Harness inputs rather than reaching into core internals.

## Non-goals

- Do not build a terminal TUI clone of Pi as the default Pixir product surface.
- Do not move ACP/client projection state into Pixir core.
- Do not auto-run Skill scripts during Skill discovery or activation.
- Do not add a package catalog before the Skill/Workflow/PATCHMD boundaries are stable.
- Do not treat compaction summaries as disposable Presenter cache if they affect future
  model input.

## Verification Direction

Future implementation slices should be verified by checking ownership boundaries:

```bash
mix test
mix pixir.smoke.skills --json
mix pixir.smoke.workflows --dry-run --json
./pixir doctor --json
```

New Presenter or adapter tooling should also provide ADR 0005-style `--help`,
`--dry-run` where relevant, structured JSON errors, and actionable `next_actions`.

## References

- CONTEXT.md: Harness, Presenter, Interactive Layer, Skill, Workflow, Session Tree,
  Compaction, Presenter Projection.
- ADR 0003: stateless Turns; local Log is source of truth.
- ADR 0004: unified Event envelope and canonical vs ephemeral events.
- ADR 0005: agent ergonomics, dry-run, help, structured errors, I/O discipline.
- ADR 0008: UI-agnostic Conversation driver.
- ADR 0010: Agent Skills with progressive disclosure.
- ADR 0011: BEAM-native Subagents.
- ADR 0012: structural Workflows over Subagents.
- ADR 0016: open beta source-install developer preview.
- ADR 0018: durable History compaction and replay repair.
