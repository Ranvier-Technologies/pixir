<!--
TEMPLATE: Patch Handoff / PR Summary
INSTALLS TO: .docs/patches/<patch-id>/handoff-pr-summary.md
PROFILE: minimal
PURPOSE: The paste-ready summary for a PR description, Codex final answer, or handoff note.
         It is honest about what is proven LOCALLY vs what still depends on CI/external review.
-->
# Handoff · {{short_title}}

> **TL;DR.** {{One sentence: what landed and the single most important caveat.}}
> **Proof state.** local-acceptance `{{passed}}` · CI `{{pending \| green}}` · external review `{{pending \| clear}}`

## What changed

- {{change 1 — file/behavior}}
- {{change 2}}

## Evidence

| Claim | Scope | State | Reference |
|:--|:--|:--|:--|
| Acceptance commands pass | local | `{{passed}}` | `runs/accept-latest.json` |
| Regression covered | local | `{{passed}}` | `{{test path}}` |
| Review | external | `{{clear \| changes_requested \| pending \| n/a}}` | `review-triage.md` |
| CI | external | `{{pending \| green \| red}}` | `{{provider link}}` |
<!-- review-proof: add runtime/visual/diff/drift rows from proof-bundle.md -->

## Intentionally deferred

<!-- Pulled from classification.json. State it plainly so reviewers don't re-litigate scope. -->
- `hold_for_later`: {{item}} — {{why / when}}
- `needs_prerequisite_patch`: {{item}} — needs `{{prereq}}`
- `reject_for_this_fork`: {{item}} — {{why}}

## Remaining CI / review state

- {{e.g. "CI not yet run on target; push to trigger."}}
- {{accepted gaps, each with a reason}}

## Commands run

```bash
{{package_runner}} run patch:truth:check
{{project_test_command}}
{{package_runner}} run patch:accept
{{package_runner}} run patch:review:coderabbit
{{package_runner}} run patch:proof:runtime
```

## Canonical files

| File | Role |
|:--|:--|
| `patch.md` | charter (scope + stop condition) |
| `.docs/patches/{{patch_spec_id}}/classification.json` | scope decisions |
| `.docs/patches/{{patch_spec_id}}/runs/accept-latest.json` | local acceptance |
| `.docs/patches/{{patch_spec_id}}/handoff-pr-summary.md` | this file |
<!-- review-proof: review-triage.md, proof-bundle.md -->

---
<!-- Everything above this line is safe to paste into a PR description. -->
