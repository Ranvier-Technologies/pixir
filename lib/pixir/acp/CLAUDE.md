# lib/pixir/acp — the ACP agent (stdio transport)

`pixir acp` speaks **Agent Client Protocol** (Zed's ACP): JSON-RPC 2.0, ndjson, over stdio.
Pixir is the *agent/server*; T3 Code (or any ACP client) is the client. Design: ADR 0009.
Another presenter over `Conversation` + the Events bus (ADR 0008) — the core is untouched.

## Map

- `protocol.ex` — pure JSON-RPC ndjson framing over Jason. `decode/1` →
  `{:request|:notification|:error|:ignore, ...}`; `result/2`, `error/3,4`, `notification/2`
  encoders (no trailing newline; the writer adds it). Error-code constants.
- `translate.ex` — pure mapping: Pixir `Event` → `session/update` params; `await` outcome →
  `stopReason`; `kind/1` tool-kind map. Presentation only — never touches the Log.
- `server.ex` — the GenServer owning stdio: linked stdin reader, single stdout writer, method
  dispatch onto `Conversation`, a per-prompt Task that subscribes + translates + emits, the
  no-deltas fallback, and the cancel-vs-terminal race resolution. `run/0` is the entrypoint
  (`route(["acp"], …)` in `cli.ex`).

## Load-bearing rules (break these and ACP clients break)

- **stdout is ONLY JSON-RPC** (ADR 0005/0009). The sole writer is `write/1`. Logs/diagnostics
  go to **stderr** — `redirect_logger_to_stderr/0` removes + re-adds the `:default` handler
  bound to `:standard_error` (OTP 28's `:logger_std_h` rejects an in-place `:type` change — a
  no-op redirect once leaked logs to stdout and corrupted the stream; there's a real-escript
  regression test in `server_test.exs` guarding it).
- **Streaming with fallback:** stream `text_delta` → `agent_message_chunk`; the canonical
  `assistant_message` maps to `nil` (not re-sent); emit it as one chunk only if a Turn produced
  no deltas. See [[pixir-canonical-vs-presentation]].
- **Turn error → content, not protocol error:** a failed turn resolves `stopReason:"end_turn"`
  with the error text as a chunk; JSON-RPC errors are only for protocol faults (-32601 unknown
  method, -32602 bad params/unknown session, -32700 parse, -32600 invalid request).
- **Current ACP v1 surface:** `initialize`, `authenticate`, `logout`, `session/new`,
  `session/prompt`, `session/cancel`, `session/load`, `session/resume`,
  `session/set_mode`, `session/set_config_option`, and outbound
  `session/request_permission`. `session/list`, `session/close`, and `session/delete`
  stay unadvertised until Pixir implements them deliberately.
- **Model selection:** prefer ACP `session/set_config_option {configId:"model", value}`.
  `session/set_model` is a Pixir/T3 compatibility extension, not a canonical ACP v1
  method.

Pixir executes all tools internally (Executor) and only *reports* via `session/update` — T3 Code
has `fs`/`terminal` capabilities off, so don't call client `fs/*`/`terminal/*`.
