# 0.1.17 review hardening

This candidate fixes three bounded correctness issues without changing the
CLI/ACP-only Hex scope, the Log authority boundary, or Monitor's read-only posture.

## Config admission

Delegate validates the caller's Provider selection from one Config snapshot.
When resolution fails, it no longer consults ambient configuration to guess the
reasoning effort. Explicit invalid/unsupported effort keeps its existing refusal;
other resolution failures return invalid_spec / provider_configuration_unresolved
before a runner or child starts. This also rejects invalid configurations with
non-max or omitted effort earlier than 0.1.16, rather than deferring failure to
child startup. Valid configurations preserve model/effort precedence.

Regressions cover raw_config, config_path, a changing single-invocation loader,
unavailable loaders, ambient max/no-max, no dispatch, and valid explicit override.
The source errors remain sanitized, without loader exception contents.

## Manifest text

The shared renderer caps only the manifest block at 16,000 bytes, including its
truncation marker, using Tool.truncate/2. wait_agent, run_workflow and Delegate
callers keep preceding summaries and re-verification directives. Structured
manifests still retain their existing eight-child/twenty-path projections and
omission counts; integrability selection is unchanged.

Tests execute both tools with a scripted Provider writing twenty long UTF-8 paths.
They check actual files, intact structured paths, unchanged prefix/directive,
valid UTF-8, the byte ceiling and an explicit truncation marker. Existing tests
keep empty-manifest and small-manifest output byte-identical.

## Monitor completeness

Partial parent selection remains partial in its own dimension. Child completeness
depends only on readable child selections and actual child read failures, so
complete or partial children are not falsely labeled explicitly_missing merely
because the parent has a missing middle. Parent uncertainty still prevents claims
of complete lineage or usage. Real missing/unreadable children retain their
existing conservative behavior.

Raw NDJSON regressions cover a partial parent with two complete children and a
partial parent with a partial child; existing cases cover truly unreadable children.

## Contract references and release boundary

- [ADR 0005](../adr/0005-agent-ergonomics-dry-run-help-structured-errors-io-discipline.md):
  structured errors and bounded model-channel output.
- [ADR 0011](../adr/0011-beam-native-subagents.md): Subagent lifecycle and ownership.
- [ADR 0038](../adr/0038-pixir-monitor-sibling-spa-sse.md): independent read-only
  projection dimensions with canonical Logs as truth.

The source-tagged 0.1.16 candidate was not published to Hex; its tag is not moved.
0.1.17 incorporates these fixes and the preceding candidate's features. Local
acceptance, CI/review, curated mirror export and Hex publication remain separate
evidence and authorization steps.
