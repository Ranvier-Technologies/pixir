# test — conventions

ExUnit. Tests never hit the network: they drive the **injectable seams** instead.

## Patterns to reuse (don't reinvent)

- **Provider seam:** pass `transport:` (a 3-arity fn or module) — see `provider_test.exs`'s
  `canned/2` + `sse/1` helpers that replay canned SSE blocks.
- **Auth seam:** pass `oauth:` a stub module (e.g. `StubOAuth`/`DeadTokenOAuth`/`FlakyOAuth`
  in `auth_test.exs`); run an isolated `Auth` instance with `name:` + `store_path:`.
- **Turn/Conversation:** pass `provider:` a stub module with `stream/2` that pops scripted
  results from an `Agent` (see `turn_test.exs` `StubProvider`, `conversation_test.exs`).
- **Workspace:** each test makes a temp dir and `on_exit` removes it; sessions persist under
  `<ws>/.pixir/sessions/`.

## Rules

- **Tool contract:** every tool is checked by `test/support/tool_contract.ex` for the ADR 0005
  contract (`__tool__/0` shape, dry-run effect-free). Add new tools to it.
- A cold read path (resume/fold) must be tested WITHOUT first building events via constructors
  — that's how the `to_existing_atom` resume bug slipped past (decode raw NDJSON instead).
- Assert structured errors by `kind`, not message text.
- `async: true` where there's no shared global; Session/Conversation tests use `async: false`.
