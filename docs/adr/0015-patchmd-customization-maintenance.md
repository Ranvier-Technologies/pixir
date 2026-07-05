# 15. PATCHMD maintains Pixir customization against canonical upstream

Date: 2026-06-04
Status: Accepted
Implementation status: Initial repo integration. PATCHMD is a maintainer
practice: the UV-backed PATCH kit CLI (`scripts/patch_cli.py`) referenced
below is not distributed with this repository.

## Context

Pixir is intentionally small compared with Codex, but it already has the primitives needed
for user customization: repo law through `AGENTS.md`, progressively disclosed Skills,
Skill-backed Workflow Templates, permissioned Tools, deterministic Workflows, and the Log
as the source of truth.

The product risk is not that users customize Pixir. Customization is the point. The risk is
that every customized Pixir checkout becomes an unmaintainable fork that cannot safely pull
canonical improvements from `main`.

PATCHMD gives Pixir a maintenance protocol around customization. It records the current
sync intent, classifies donor changes against target constraints, preserves local practice
where appropriate, and keeps acceptance evidence separate from CI and external review.

## Decision

Pixir will treat PATCHMD as the repo-local customization maintenance layer, not as a hidden
autopatcher and not as a dependency of the core runtime.

The split is:

- canonical Pixir upstream is the donor;
- a customized Pixir repo or branch is the target;
- `AGENTS.md` remains repo law;
- `patch.md` records one active upstream-sync or customization charter;
- `.docs/patches/<patch-id>/` records classification, acceptance, status, proof, and
  handoff evidence;
- `.agents/skills/patch-operator/SKILL.md` provides the generic PATCH operator loop;
- `.agents/skills/pixir-customization-operator/SKILL.md` provides Pixir-specific judgment
  for preserving Skills, workflow templates, ADRs, and runtime customization;
- Pixir Workflow Templates may orchestrate read-only audits and permission-gated sync
  steps, but deterministic validation remains in the UV-backed PATCH CLI.

The first command surface is direct because Pixir is a Mix project without `package.json`:

```bash
uv run scripts/patch_cli.py truth-check
uv run scripts/patch_cli.py classify --help
uv run scripts/patch_cli.py accept --help
uv run scripts/patch_cli.py status
```

Future Pixir-native wrappers such as `mix pixir.patch.status` are allowed, but they should
wrap the same deterministic artifacts instead of creating a second evidence model.

## Consequences

- Users can keep local Skills, workflow templates, ADRs, and behavior customizations while
  still pulling canonical Pixir changes.
- PATCH classification becomes the reviewable boundary between upstream code movement and
  user-owned customization.
- Pixir's Skill primitive carries operator intelligence; the PATCH CLI carries validation
  and evidence writes.
- Package-less repository support matters: docs and skills must show direct `uv run`
  commands, not package-script-only commands.
- CodeRabbit remains an external CLI surface in the extended PATCH profile, not a Pixir
  dependency.

## Non-goals

- Do not make PATCHMD execute automatically on Skill Activation.
- Do not bypass Pixir's permission model, Workspace confinement, or Log architecture.
- Do not require Node package scripts for Pixir's PATCH workflow.
- Do not make `patch.md` replace durable repo law in `AGENTS.md`.
- Do not use PATCHMD for unbounded refactors or vague wishlist work.

## Verification Direction

The initial integration is verified when:

```bash
uv run scripts/patch_cli.py --help
uv run scripts/patch_cli.py truth-check
uv run scripts/patch_cli.py status
mix test test/pixir/skills_test.exs test/pixir/workflows_test.exs
mix pixir.smoke.workflows --dry-run --json
```

If a future change adds Mix wrappers, the wrapper tests must prove that stdout, stderr,
dry-run behavior, and structured errors remain aligned with ADR 0005.

## References

- ADR 0005: agent ergonomics, dry-run, help, structured errors, I/O discipline.
- ADR 0010: Agent Skills use progressive disclosure with durable activations.
- ADR 0013: Skills can provide Workflow Templates as installed practices.
- ADR 0014: Workflow Checkpoint Bundles and honest partial outcomes.
