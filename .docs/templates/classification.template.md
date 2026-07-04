<!--
TEMPLATE: Classification JSON v1
INSTALLS TO: .docs/patches/<patch-id>/classification.json
PROFILE: minimal
GENERATED/UPDATED BY: patch:classify
PURPOSE: Record Skill-led classification decisions using deterministic CLI validation.
LABELS: Port, Preserve, Adapt, Reject, Defer
-->
```json
{
  "schemaVersion": 1,
  "artifactKind": "patch-classification",
  "patchId": "{{patch_spec_id}}",
  "generatedBy": "patch-operator-skill",
  "summary": "{{one_sentence_summary}}",
  "donor": {
    "repo": "{{donor_repo}}",
    "base": "{{donor_base}}",
    "head": "{{donor_head}}"
  },
  "target": {
    "repo": "{{target_repo}}",
    "head": "{{target_head}}"
  },
  "decisions": [
    {
      "path": "{{path}}",
      "classification": "Port",
      "summary": "{{what changes}}",
      "reason": "{{why it belongs to this patch}}"
    },
    {
      "path": "{{path}}",
      "classification": "Preserve",
      "summary": "{{target surface to protect}}",
      "reason": "{{target invariant or fork behavior}}"
    },
    {
      "path": "{{path}}",
      "classification": "Adapt",
      "summary": "{{donor intent to carry forward}}",
      "reason": "{{why direct implementation does not fit target}}"
    },
    {
      "path": "{{path}}",
      "classification": "Reject",
      "summary": "{{what is rejected}}",
      "reason": "{{why it should not land in this target}}"
    },
    {
      "path": "{{path}}",
      "classification": "Defer",
      "summary": "{{what is deferred}}",
      "reason": "{{why it is outside this stop condition}}"
    }
  ],
  "conflictClusters": [
    {
      "id": "{{cluster_id}}",
      "title": "{{cluster_title}}",
      "paths": [
        "{{path}}"
      ],
      "reason": "{{Port or Adapt collides with Preserve here}}"
    }
  ],
  "scopeChanges": [],
  "operatorNotes": []
}
```
