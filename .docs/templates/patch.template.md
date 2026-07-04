<!--
TEMPLATE: Patch Charter
INSTALLS TO: <repo root>/patch.md
PROFILE: minimal
PURPOSE: Canonical Portable PATCH v1 charter. One active patch at the repo root.
PLACEHOLDERS: {{required}} {{optional?}} {{a | b}} ; delete this guidance before commit.
-->
# Patch: {{title}}

> State: `{{planned | active | validating | hardening | blocked | completed | superseded}}` | Mode: `{{port | hardening}}` | Donor: `{{live | snapshot | missing}}` | Target: `{{missing | partial | substantially_landed}}`

```patch-meta
state: {{planned | active | validating | hardening | blocked | completed | superseded}}
mode: {{port | hardening}}
donorStatus: {{live | snapshot | missing}}
targetStatus: {{missing | partial | substantially_landed}}
# branch: {{codex/patch-branch?}}
```

```patch-spec
{
  "schemaVersion": 1,
  "id": "{{patch_spec_id}}",
  "title": "{{title}}",
  "donor": {
    "repo": "{{../donor-repo}}",
    "base": "{{base-ref-or-sha}}",
    "head": "{{head-ref-or-sha}}"
  },
  "target": {
    "repo": ".",
    "head": "{{target-head-ref}}"
  },
  "includePaths": [
    "{{path/in/scope}}"
  ],
  "preservePaths": [
    "{{path/to/preserve?}}"
  ],
  "publicSeams": [
    "{{public/seam/path?}}"
  ],
  "autoPortCandidates": [
    "{{safe/new/path?}}"
  ],
  "conflictClusters": [
    {
      "id": "{{cluster-id}}",
      "title": "{{Cluster title}}",
      "paths": [
        "{{path/requiring/review}}"
      ]
    }
  ],
  "acceptanceChecks": [
    "{{project acceptance command}}"
  ],
  "runtimeProofCommands": [
    "{{runtime proof command?}}"
  ]
}
```

## Stop Condition

{{One sentence. The patch is done when this is true and nothing more is needed for local handoff.}}

## Summary

{{2-4 sentences: what this patch reconciles and why now.}}

## Scope

### In Scope

- `{{path/one}}` - {{why it belongs to this patch}}

### Out Of Scope

- `{{path/two}}` - {{why it is deferred or rejected}} -> see classification (`{{hold_for_later | needs_prerequisite_patch | reject_for_this_fork}}`)

## Evidence

| Artifact | Path | State |
|:--|:--|:--|
| Classification | `.docs/patches/{{patch_spec_id}}/classification.json` | `{{pending \| captured}}` |
| Acceptance run | `.docs/patches/{{patch_spec_id}}/runs/accept-latest.json` | `{{pending \| accepted \| failed}}` |
| Status | `.docs/patches/{{patch_spec_id}}/status.md` | `{{pending \| captured}}` |
| Handoff | `.docs/patches/{{patch_spec_id}}/handoff-pr-summary.md` | `{{pending \| captured}}` |

## Open Questions

- [ ] {{unresolved decision that could change scope}}

<!--
INVARIANTS
- `patch-spec.id` is the canonical patch id.
- `patch-meta` and the visible status header must agree.
- Local acceptance does not imply CI is green.
- Every out-of-scope item should have a matching classification decision.
-->
