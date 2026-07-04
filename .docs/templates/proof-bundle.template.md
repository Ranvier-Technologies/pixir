<!--
TEMPLATE: Proof Bundle
INSTALLS TO: .docs/patches/<patch-id>/proof-bundle.md
PROFILE: review-proof
INPUTS: patch:proof:playwright · patch:proof:runtime · patch:diff:snapshot · patch:drift:analyze
PURPOSE: One bundle that keeps evidence streams SEPARATE — visual, runtime, diff, drift — plus
         a residual-risk statement. Each stream carries an explicit proof state so "no UI to
         test" reads as `not_applicable`, not as a silent pass.
PROOF STATE: not_applicable | pending | partial | captured | accepted | failed
-->
# Proof bundle · {{patch_spec_id}}

```json
{
  "patch_spec_id": "{{patch_spec_id}}",
  "generated_at": "{{ISO8601}}",
  "streams": {
    "visual":  "{{not_applicable | pending | partial | captured | accepted | failed}}",
    "runtime": "{{captured}}",
    "diff":    "{{captured}}",
    "drift":   "{{captured}}"
  },
  "scope": "local",
  "residual_risk": "{{none | low | medium | high}}"
}
```

> All four streams are **local** evidence. They strengthen the handoff; they do not replace CI
> or external review.

## Visual / browser  — `{{state}}`

<!-- If there is no UI surface, set state=not_applicable and say why. Do not fake a pass. -->
- Command: `{{package_runner}} run patch:proof:playwright`
- {{"N/A — library change, no rendered surface." OR screenshot refs below}}
- Desktop: `{{path.png?}}` · Mobile: `{{path.png?}}`

## Runtime  — `{{state}}`

- Command: `{{package_runner}} run patch:proof:runtime`
- Repro / scenario: {{what was exercised}}
```text
{{key runtime output — before/after, or the assertion that now holds}}
```

## Diff snapshot  — `{{state}}`

- Command: `{{package_runner}} run patch:diff:snapshot`
- Files: {{n}} changed, +{{adds}}/−{{dels}}
```text
{{path}} | +{{a}} −{{d}}
{{path}} | +{{a}} −{{d}}
```

## Drift / branch health  — `{{state}}`

- Command: `{{package_runner}} run patch:drift:analyze`
- Target `{{target_head}}` is {{n}} commits behind `{{donor_head}}`.
- Conflict surface: {{"clean" | "N files at risk: …"}}

## Residual risk  — `{{none | low | medium | high}}`

<!-- The honest paragraph. What could this patch break later, given what was deferred? -->
> {{e.g. "Codec refactor was held (classification.json). If upstream lands it, the next sync
> may conflict in src/stream/codec.ts. Low risk this cycle; flagged for the prerequisite patch."}}
