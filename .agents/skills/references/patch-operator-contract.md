# Patch Operator Contract

Read order:

1. root repo law file (`AGENTS.md` or `CLAUDE.md`)
2. root `patch.md`
3. relevant docs under `.docs/`

Decision vocabulary has two scopes.

Classification labels are used in `classification.json` `decisions[]` entries:

- `Port`
- `Preserve`
- `Adapt`
- `Reject`
- `Defer`

Patch status labels are used when triaging review/proof status, not as
`classification` values:

- `fix_now`
- `defer_out_of_scope`
- `infra_failed`
- `accepted_with_recorded_gap`

Patch artifacts should keep the charter, classification, status, review, proof, and CI language aligned.
