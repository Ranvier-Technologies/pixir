# 16. Open beta scope starts as source-install developer preview

Date: 2026-06-05
Status: Accepted
Implementation status: Scope locked; local ACP operator dogfood validated.
ADR 0025 separately defines the narrow CLI/ACP-only Hex package contract.

## Context

Pixir has crossed the architecture-risk threshold for a serious private dogfood run.
The core Harness exists: local Log as truth, OpenAI Responses Provider, ChatGPT
subscription OAuth, permissioned Tools, ACP over stdio, Agent Skills, supervised
Subagents, structural Workflows, Skill-backed Workflow Templates, checkpoint bundles,
and PATCHMD customization maintenance.

The remaining risk is release-quality risk, not conceptual architecture risk. A stranger
can still get stuck on installation, first-run auth, model/config setup, ACP wiring,
subagent lifecycle expectations, or unclear diagnostics. Calling that state "open beta"
without a narrower support contract would invite false confidence.

## Decision

Pixir's first open beta starts as a **source-install developer preview**, not a broad
packaged ecosystem release. ADR 0025 later permits a narrow Hex package as a CLI/ACP
distribution channel without changing this beta product scope into a stable Elixir
library contract.

The beta surface is:

- **Supported:** Pixir runtime from source, terminal CLI, ACP over stdio, OpenAI
  Responses Provider, ChatGPT subscription OAuth/API-key fallback, permission model,
  core file/bash/edit Tools, Skills, Subagents, Workflows, Workflow Templates, and local
  diagnostics.
- **Experimental:** client-specific integrations through local adapters, long-running
  non-blocking Subagent UX, Workflow Templates as user-facing product surface, PATCHMD
  customization operations, benchmark harnesses, and any client-specific projection
  behavior.
- **Not included:** stable public Elixir API, packaged T3Code upstream integration,
  multi-provider support, web UI, self-update channel, telemetry, or a production
  support/SLA promise. Hex publication, if used, is governed by ADR 0025 and remains a
  CLI/ACP distribution path.

The initial install channel is intentionally boring and reversible:

```bash
git clone <pixir-repo>
cd pixir
mix deps.get
mix escript.build
./pixir help
./pixir login
```

Publishing to Hex is explicitly **not** a prerequisite for open beta. Hex becomes
appropriate only after Pixir's package ownership model and public stability wording are
clear enough that publishing will not freeze the wrong contract. A GitHub Release
binary may still be useful if it improves beta ergonomics without hardening the public
API too early.

## Beta Gate

The project can call this open beta only when these gates are true:

1. **Source install path works from a clean checkout.**
   `mix deps.get`, `mix escript.build`, `./pixir help`, and the documented first-run
   flow succeed or fail with actionable messages.
2. **First-run diagnostics exist.**
   Users and agents have a command surface such as `pixir doctor` or equivalent smoke
   tasks for auth, config, model availability, workspace access, and ACP readiness.
3. **CI/CD is explicit.**
   The default gate runs formatting, warnings-as-errors compilation, ExUnit, no-network
   workflow smoke, and docs generation.
4. **Failure output is agent-usable.**
   Public scripts and smoke commands provide help, dry-run where relevant, structured
   errors, bounded output, and next actions in the style of ADR 0005.
5. **Docs are newcomer-complete.**
   README, AGENTS.md, CONTEXT.md, ADR index, and quickstart docs explain what Pixir is,
   how to install it, how to login, how to run a first Turn, and what beta limitations
   remain.
6. **Presenter/client stance is honest.**
   Client adapters remain local-only dogfood unless a separate decision changes that.
   Open beta docs may mention ACP compatibility and experimental client pairing, but
   must not imply upstream client PRs or packaged provider install paths.
7. **Subagent lifecycle limitations are explicit.**
   If non-blocking status/result retrieval is not complete, the beta docs must say so.
   Pixir should not present detached or timed-out children as successful completion.
8. **Security posture is clear.**
   No telemetry by default, secrets never enter logs/stdout/diagnostics, and diagnostic
   bundles are user-triggered.

## Consequences

- Pixir can open itself to external developer feedback earlier without pretending the
  distribution story is finished.
- The release work now has a concrete contract: diagnostics, docs, CI/CD, first-run UX,
  and honest client/Subagent limitations matter more than broad packaging claims.
- Local ACP client dogfood is useful validation, but it does not create a packaged
  client integration or public support surface.
- Hex was deferred by design, not forgotten. ADR 0025 records the later decision to use
  Hex only as a CLI/ACP distribution path.
- Any future "public package" decision should get its own ADR if it changes install,
  compatibility, or API stability promises beyond ADR 0025.

## Non-goals

- Do not publish to Hex merely to create a sense of launch readiness; publish only when
  the ADR 0025 package-scope checks are satisfied.
- Do not upstream or PR T3Code integration as part of this beta unless explicitly
  re-scoped.
- Do not add telemetry by default.
- Do not treat benchmark outputs or local-only T3 harnesses as a public support surface.
- Do not promise stable Elixir APIs beyond the documented CLI/ACP behavior.

## Verification Direction

The open beta preparation goal should produce current evidence for:

```bash
mix deps.get
mix check
mix escript.build
./pixir help
./pixir --version
./pixir doctor --json
mix pixir.smoke.skills
mix pixir.smoke.subagents
mix pixir.smoke.workflows --dry-run --json
```

`pixir doctor --json` is the first local diagnostic command in this gate. It must stay
no-network and machine-readable.

For local ACP client dogfood, optional operator verification should produce current
evidence for:

```bash
mix escript.build
./pixir doctor --json
```

Networked client/UI evidence remains manual and operator-owned. Passing that path does
not turn a local adapter into a public packaging surface.

## References

- CONTEXT.md: Pixir is a Harness; Provider and front-ends do not own agency.
- ADR 0005: agent ergonomics, dry-run, help, structured errors, I/O discipline.
- ADR 0009: ACP transport over stdio and dependent adapter efforts.
- ADR 0010: Agent Skills with progressive disclosure.
- ADR 0011: BEAM-native Subagents as supervised child Sessions.
- ADR 0012: structural Workflows over Subagents.
- ADR 0014: Workflow Checkpoint Bundles and honest partial outcomes.
- ADR 0015: PATCHMD customization maintenance is repo-local, not a runtime dependency.
