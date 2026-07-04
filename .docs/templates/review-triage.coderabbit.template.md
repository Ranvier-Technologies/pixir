<!--
TEMPLATE: Review Triage (CodeRabbit)
INSTALLS TO: .docs/patches/<patch-id>/review-triage.md
PROFILE: review-proof
INPUT: patch:review:coderabbit  (wraps the EXTERNAL CodeRabbit CLI — never a package dependency)
PURPOSE: Turn external review output into in-scope decisions. Every finding gets a decision and
         a resolution note. "Recorded gaps" are accepted on purpose, with a reason.
DECISION VOCABULARY:
  fix_now                  address inside this patch
  defer_out_of_scope       valid, but not this patch (→ classification.json)
  infra_failed             review/CI infra problem, not a code issue
  accepted_with_recorded_gap  knowingly shipping with this; reason recorded
-->
# Review triage · {{patch_spec_id}}

> Source: **CodeRabbit** (external CLI, `{{coderabbit_version}}`). This is external review,
> not local proof. Findings here do not gate local acceptance; they gate **handoff**.

```json
{
  "patch_spec_id": "{{patch_spec_id}}",
  "source": "coderabbit",
  "external": true,
  "generated_at": "{{ISO8601}}",
  "counts": { "fix_now": {{n}}, "defer_out_of_scope": {{n}}, "infra_failed": {{n}}, "accepted_with_recorded_gap": {{n}} },
  "blocking_handoff": {{n}}
}
```

## Findings

| # | Severity | File | Finding | Decision | Resolution note |
|:--:|:--|:--|:--|:--|:--|
| 1 | `{{high\|med\|low}}` | `{{path:line}}` | {{summary}} | `fix_now` | {{commit / how fixed}} |
| 2 | `{{low}}` | `{{path:line}}` | {{nit}} | `defer_out_of_scope` | → `classification.json` `hold_for_later` |
| 3 | `{{—}}` | `{{ci/workflow}}` | {{infra error}} | `infra_failed` | {{not a code issue; link}} |
| 4 | `{{med}}` | `{{path:line}}` | {{perf note}} | `accepted_with_recorded_gap` | see ledger ↓ |

## Recorded-gap ledger

<!-- Anything `accepted_with_recorded_gap` MUST appear here with an explicit reason and owner.
     These flow verbatim into the handoff "accepted gaps" list. -->
| Finding | Why accepted now | Risk | Revisit when |
|:--|:--|:--|:--|
| {{#4 perf}} | {{out of stop condition; low traffic path}} | {{low}} | {{next perf patch}} |

## Blocking handoff?

- {{"No — all `fix_now` resolved; gaps recorded."  OR  "Yes — finding #N unresolved."}}
