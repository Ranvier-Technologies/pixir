# AGENTS.md - Pixir ACP

This directory is the ACP stdio presenter over Conversation and Events.

- Prefer this file, ADR 0009, and live `Pixir.ACP.Server` moduledocs for protocol
  shape.
- ACP is JSON-RPC over stdio. Call protocol operations "methods", not HTTP endpoints,
  and compare new/changed methods against the official ACP v1 schema before adding
  Pixir/T3 compatibility extensions.
- stdout is JSON-RPC only. Diagnostics and logs go to stderr.
- ACP is presentation, not a second runtime: do not bypass Conversation, Session, or the
  Executor.
- Pixir executes tools internally and reports tool calls/results to ACP clients.
- Presenter context, attachments, and T3-specific projection details must remain
  Presenter input/projection until Pixir records canonical Events or Session Resources.
- `session/load` replays History; `session/resume` reattaches without replay.
- Sticky model selection should use `session/set_config_option` with `configId:"model"`.
  `session/set_model` is a compatibility extension only.

Fast checks:

```bash
mix test test/pixir/acp
mix compile --warnings-as-errors
mix format --check-formatted
```
