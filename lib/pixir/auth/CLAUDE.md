# lib/pixir/auth — credentials + OAuth

Owns the Session's Credential and serializes token refresh (ADR 0002). A singleton GenServer
so refresh is naturally race-free across concurrent Turns.

## Map

- `../auth.ex` — the GenServer + public API (`access_token`, `request_headers`,
  `login_device_code`, `set_credential`, `logout`). Resolves the refresh + the failure mapping.
- `codex_oauth.ex` — the device-code flow + token endpoint (`refresh/1`, `exchange_for_credential/2`,
  `account_id_from_token/1`). The real network calls live here.
- `store.ex` — persists subscription credentials to `~/.pixir/auth.json` (atomic, **mode 0600**).

## Rules

- **Secrets discipline:** tokens live ONLY in `~/.pixir/auth.json` (0600) — never in the repo,
  the Log, logs, or any printed output. Don't echo token contents in diagnostics.
- **The OAuth module is the injectable seam:** `Auth` takes `:oauth` (default `CodexOAuth`) so
  everything is unit-tested without the network (see `test/pixir/auth_test.exs` stubs). Keep
  new network-calling code behind this seam.
- **Refresh rotates BOTH tokens** — OpenAI returns a new refresh_token each time; persist the
  new credential before returning, or the next start strands a dead token (ADR/ROADMAP C4).
- Failure mapping (C4): a rejected refresh (4xx) → actionable `:not_authenticated`
  ("run `pixir login`"); a transient failure keeps `:network` so the Provider can retry.

Precedence: stored subscription > `OPENAI_API_KEY` (never persisted) > unauthenticated.
