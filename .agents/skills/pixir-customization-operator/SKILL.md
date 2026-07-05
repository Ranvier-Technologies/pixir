---
name: pixir-customization-operator
description: Maintain a customized Pixir repository against canonical upstream using PATCHMD, Pixir Skills, workflow templates, and the UV-backed Patch Operator Kit. Use when syncing from Pixir main, preserving local agent behavior, auditing custom Skills, or preparing a bounded customization patch with evidence.
---

# Pixir Customization Operator

> Maintainer practice: the UV-backed PATCH kit CLI (`scripts/patch_cli.py`)
> that this skill drives is not distributed with this repository.

Use this Skill when Pixir itself is the target repository and the task is to keep local
customizations aligned with canonical upstream without losing installed practices.

This Skill is Pixir-specific. For the generic PATCH loop, also use `patch-operator`.

## Model

- Canonical Pixir upstream is the donor.
- This customized repository or branch is the target.
- `AGENTS.md` is repo law.
- `patch.md` is the active customization or upstream-sync charter.
- `.agents/skills/` contains installed practices that may be preserved, adapted, or ported.
- `.docs/patches/<patch-id>/` is the evidence ledger.
- `scripts/patch_cli.py` is the deterministic validation and artifact surface.

## Command Surface

Pixir is a Mix project with no `package.json`, so run the PATCH commands directly:

```bash
uv run scripts/patch_cli.py --help
uv run scripts/patch_cli.py truth-check --help
uv run scripts/patch_cli.py status --help
uv run scripts/patch_cli.py classify --help
uv run scripts/patch_cli.py accept --help
```

Mutating PATCH commands must be dry-run first when the subcommand supports it.

## Workflow

1. Read `AGENTS.md`, then `CONTEXT.md`, then `docs/adr/0015-patchmd-customization-maintenance.md`.
2. Activate `patch-operator` for the generic evidence loop.
3. Fill or update `patch.md` with a bounded upstream-sync or customization charter.
4. Run `uv run scripts/patch_cli.py truth-check`.
5. Classify upstream changes as `Port`, `Preserve`, `Adapt`, `Reject`, or `Defer`.
6. Preserve local Pixir customization unless the charter explicitly says to replace it.
7. Implement only recorded `Port` and approved `Adapt` scope.
8. Run local Pixir gates and PATCH acceptance, then record the handoff.

## Workflow Templates

Inspect these supporting files with `skill_view` before use:

- `workflows/customization_audit.json` for a read-only audit of local customization
  surfaces.
- `workflows/upstream_sync.json` for a permission-gated upstream sync plan.

Example dry-run (Pixir↔Pixir audit):

```json
{
  "template_id": "pixir-customization-operator/customization_audit",
  "template_args": {
    "focus": "skills and patch workflow"
  }
}
```

## Guardrails

- Do not make PATCHMD a hidden autopatcher. The Skill supplies judgment; the CLI records
  and validates artifacts.
- Do not bypass Pixir's Log, Skill, Workflow, or Tool model when implementing native
  runtime features.
- Do not add CodeRabbit, Playwright, or Python packages as repo dependencies just because
  the PATCH profile knows how to use external tools.
- Keep customization changes visible in `patch.md`, `.agents/skills/`, ADRs, or committed
  source. Avoid untracked local behavior that cannot be replayed.
