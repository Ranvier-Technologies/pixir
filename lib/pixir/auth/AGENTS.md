# AGENTS.md - Pixir Auth

This directory owns credentials, OAuth, refresh, and credential persistence.

- Prefer this file plus ADR 0002 before changing OAuth, refresh, store, or credential
  precedence.
- Secrets never enter the repo, Log, stdout, stderr diagnostics, or test fixtures.
- Subscription credentials live only in `~/.pixir/auth.json` with mode `0600`; API keys
  are fallback input and are never persisted.
- Keep real network calls behind the injectable OAuth seam so tests stay offline.
- Refresh must persist rotated access and refresh tokens together.

Fast checks:

```bash
mix test test/pixir/auth_test.exs
mix compile --warnings-as-errors
mix format --check-formatted
```
