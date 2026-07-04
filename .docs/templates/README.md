<!--
TEMPLATE README — installs to .docs/templates/README.md
Explains the placeholder convention and which template feeds which patch:* command.
-->
# Patch templates

These templates are copied here by the Patch Operator Kit. They are the document and JSON
shapes the `patch:*` commands read and write. One active patch at a time.

## Placeholders

- `{{field}}` required · `{{field?}}` optional · `{{a | b}}` pick one · `<!-- … -->` delete before commit.
- Each template has a YAML/JSON machine block (the contract) and a human body below it.

## Which template, which command

| Template | Command | Output location |
|:--|:--|:--|
| `patch.template.md` | (operator-authored) `patch:truth:check` validates it | `patch.md` (repo root) |
| `status.template.md` | `patch:status` | `.docs/patches/<id>/status.md` |
| `classification.template.md` | `patch:classify` | `.docs/patches/<id>/classification.json` |
| `acceptance-run.template.md` | `patch:accept` | `.docs/patches/<id>/runs/accept-latest.json` |
| `handoff-pr-summary.template.md` | (operator-authored at handoff) | `.docs/patches/<id>/handoff-pr-summary.md` |
| `upgrade-plan.template.md` | `plan_patch_operator_upgrade.py` | `.docs/patch-kit/upgrade-plan.md` |
| `review-triage.coderabbit.template.md` | `patch:review:coderabbit` *(review-proof)* | `.docs/patches/<id>/review-triage.md` |
| `proof-bundle.template.md` | `patch:proof:*`, `patch:diff:snapshot`, `patch:drift:analyze` *(review-proof)* | `.docs/patches/<id>/proof-bundle.md` |

## Golden rule

Local proof and external review are separate columns everywhere. A patch may be
`local-accepted` while CI and CodeRabbit are still `pending`. Never collapse them.
