# Artifact Contract

Patch artifacts are durable records under `.docs/patches/<patch-id>/`.

## Working Contract vs Evidence Ledger

- `patch.md` is the concise working contract.
- `.docs/patches/<patch-id>/` is the evidence ledger.

Write current scope and state into `patch.md`. Write supporting reasoning, path-level classification, proof output, review triage, and snapshots into the evidence ledger.

## Classification JSON v1

The canonical classification artifact is `.docs/patches/<patch-id>/classification.json`.

Required top-level fields:

- `schemaVersion`: `1`
- `artifactKind`: `"patch-classification"`
- `patchId`: must match `patch-spec.id`
- `generatedBy`: short producer label, usually `"patch-operator-skill"`
- `decisions`: array of path decisions

Optional top-level fields:

- `summary`
- `donor`
- `target`
- `conflictClusters`
- `scopeChanges`
- `operatorNotes`

Each decision requires:

- `path`
- `classification`: one of `Port`, `Preserve`, `Adapt`, `Reject`, `Defer`
- `summary`
- `reason`

The Patch CLI validates and writes this artifact. The Skill owns the judgment inside it.
