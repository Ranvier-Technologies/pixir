# 10. Agent Skills use progressive disclosure with durable activations

Date: 2026-06-01
Status: Accepted

## Context

Pixir has deferred `SKILL.md` support since v0.1, but its existing architecture already
sets two hard constraints. First, the **Log** is the source of truth (ADR 0003/0004), so
anything that changes what the model knew during a Turn must be replayable on resume and
fork. Second, file tools are confined to the **Workspace** (ADR 0006), while user skills
may live in user-level or agent-level directories outside the Workspace.

Codex, Pi, and Hermes all converge on the same shape: expose cheap skill metadata first,
then load full instructions only when a skill is selected. Pixir should follow that
progressive-disclosure pattern without weakening Workspace confinement.

## Decision

A **Skill** is a reusable instruction package, not an Agent and not a Tool. Pixir will
surface available Skills through a dedicated Skills layer that lists bounded metadata and
loads Skill content from registered skill roots. The existing `read` Tool remains
Workspace-confined; it does not gain permission to read arbitrary user skill paths.

The model-facing v1 surface is read-only Tools: `skills_list` for bounded metadata and
`skill_view` for a selected Skill's instructions or an explicit supporting file. These
Tools follow ADR 0005 like every other Tool (`__tool__/0`, dry-run, structured errors,
bounded model output), but they are not the Skills themselves; they are the controlled
way to inspect registered Skill packages.

Calling `skill_view` for the main `SKILL.md` counts as a Skill Activation and records the
canonical activation event. Calling `skill_view` for supporting files does not create a
new activation; it is an auxiliary read of an already discoverable resource. There is no
separate `activate_skill` action in v1.

Each Turn includes a compact, budgeted index of available Skills, shaped like
`name` / `description` / `location`, so the model can decide when a Skill is relevant.
Full instructions are loaded only through `skill_view` or explicit user invocation; the
index is discovery metadata, not the Skill body. Duplicate warnings and richer discovery
details remain available through `skills_list`; they do not need to occupy every Turn's
system prompt.

Explicit user invocation accepts both Codex-style `$skill-name` mentions and
terminal-style `/skill-name` commands where the presenter can support slash commands.
Both syntaxes resolve to the same Skill Activation semantics and canonical event.

Pixir discovers Skills from both the shared agent convention and Pixir's own global
state: repository `.agents/skills` roots, user `~/.agents/skills`, and `~/.pixir/skills`
(respecting `PIXIR_HOME` for the Pixir root). This keeps Pixir interoperable with
Codex/Pi/Hermes-style Skill bundles while preserving a Pixir-native home for local
state and future first-party Skills.

When multiple Skills declare the same name, Pixir resolves by scope precedence: repo
Skills win over user Skills, which win over Pixir-global Skills. The selected activation
still records the exact path and hash, and the loader reports duplicate-name warnings so
shadowing is visible.

A **Skill Activation** is canonical History. When a Skill is selected by the user or by
the model to guide a Turn, Pixir records a durable activation event. That event stores
the Skill identity, source, resolved path, content hash, and the loaded `SKILL.md`
instruction snapshot used for that Turn. Supporting files (`references/`, `templates/`,
`scripts/`, `assets/`) remain progressively disclosed: they are read and persisted only
if explicitly loaded later.

Skill Activations are per-Turn, not sticky Session state. A later Turn may activate the
same Skill again, but no Skill remains active merely because it was used earlier.

Skill scripts are never auto-run as part of loading or activating a Skill. `skill_view`
may reveal or list them, but executing one is an ordinary `bash` Tool call subject to the
current permission mode and all existing Tool ergonomics.

## Consequences

- Resume, fork, and replay preserve which Skill shaped a Turn, even if the on-disk Skill
  changes later.
- Skill reads outside the Workspace go through a narrow, auditable Skills surface instead
  of expanding the authority of `read`.
- Logs grow when a Skill is activated, but only by the instruction snapshot actually sent
  to the model; supporting resources remain on-demand.
- Adding `skill_activation` is a deliberate extension of the canonical Event vocabulary,
  so `Pixir.Event`, `Pixir.Log.fold/2`, Provider history folding, and presentation layers
  must all be updated together.
