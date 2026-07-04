# Patch Operator Versioning

Patch Operator uses separate versions for separate compatibility boundaries.

## Kit Version

`kitVersion` is the semver version of the installed Patch Operator Kit. It changes when installed files, command behavior, or bundled operator practices change.

Pre-release suffixes such as `-alpha.1` mark dogfood cuts. Treat alpha installs as valid for local proof and operator learning, not as a guarantee that every repo shape has been exercised.

## Patch Spec Schema

`patch-spec.schemaVersion` versions the `patch.md` working-contract schema. It changes only when the shape or meaning of `patch-spec` changes.

## Classification Artifact Schema

`classification.schemaVersion` versions `.docs/patches/<patch-id>/classification.json`. Version 1 records Skill-produced classification decisions using the canonical labels `Port`, `Preserve`, `Adapt`, `Reject`, and `Defer`.

## Compatibility Rule

Patch CLI commands must fail with structured errors for unsupported artifact schema versions. Skills may explain migrations, but deterministic commands must enforce compatibility.

Package-less repositories may install the kit without package scripts. In that case installers report package script entries as `skipped` and operators should invoke the CLI directly with `uv run scripts/patch_cli.py ...`.

Installers and validators may emit `git_ignored_path` warnings. These warnings mean the installed file works locally but may not be committed until the repo unignores it or chooses a different install path.
