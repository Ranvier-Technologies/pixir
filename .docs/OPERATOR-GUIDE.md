# Operator Guide

The Patch Operator Kit makes patch work reviewable inside the target repository.

Canonical truth:

- repo law file: `AGENTS.md` or `CLAUDE.md`
- active charter: root `patch.md`
- patch artifacts: `.docs/patches/<patch-id>/`
- kit config: `.docs/patch-kit/config.json`
- install manifest: `.docs/patch-kit/manifest.json`

Use `patch:status` to inspect the current kit state and `patch:accept` to run configured acceptance commands.
