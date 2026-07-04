# Patch Operator Workflow

1. Read the repo law file (`AGENTS.md` or `CLAUDE.md`).
2. Read root `patch.md`.
3. Confirm the patch scope and stop condition before editing.
4. Keep evidence under `.docs/patches/<patch-id>/`.
5. Classify donor and target surfaces with the Patch Operator Skill, then record the result with `patch:classify`.
6. Run `patch:truth:check` before implementation work and after changing the charter.
7. Run `patch:accept` only for the acceptance commands declared by the patch or kit config.
8. Record review, proof, and CI gaps explicitly rather than implying closure.

Acceptance commands run non-interactively. Do not declare commands that require stdin, such as `--input-json -`, unless the command itself supplies stdin.

Local acceptance does not replace CI.
