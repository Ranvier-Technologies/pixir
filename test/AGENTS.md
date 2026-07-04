# AGENTS.md - Pixir Tests

This directory is the ExUnit verification surface for Pixir.

- Prefer this file plus the relevant ADR before adding broad test patterns.
- Tests do not hit the network; use Provider transport, Auth OAuth, Turn provider, and
  temp Workspace seams.
- Prefer raw NDJSON tests for cold resume/fold bugs; constructors can hide replay issues.
- Assert structured error `kind`, not prose.
- Cover request-shape boundaries with deterministic tests: Provider-hosted Web Search is
  not a local Tool, Session Resources project to Provider inputs, and `provider_usage`
  never replays as model context.
- Add every new Tool to `test/support/tool_contract.ex`.

Fast checks:

```bash
mix test
mix test --stale
mix compile --warnings-as-errors
mix format --check-formatted
```
