# lib/pixir/provider — the Responses dialect

The OpenAI **Responses API** dialect (ADR 0002/0003): each call is **stateless**
(`store: false`, no `previous_response_id`); the full conversation is sent every Turn by
folding History into `input` items. The local Log stays the source of truth.

## Map

- `../provider.ex` — `stream/2` (one streamed call, retry/backoff on transient errors),
  `build_body` + `fold_input`/`to_input_item` (History → Responses input), the SSE reducer
  (`apply_event/2`), `default_model/0`, error classification (`classify_http_error`).
- `transport.ex` / `finch_transport.ex` — the network seam.
- `cache.ex` — the px2 Prompt Contract cache key (ADR 0020): version segment leads the
  key; `s_` hashes the fork-tree root (`fork_root_session_id`, default self). Volatile
  facts (workspace, mode) ride as a late developer-role `input` item
  (`developer_context`), never in the cacheable `instructions` prefix.

## Rules

- **Transport is the injectable seam:** `Provider.Transport` (a module or a 3-arity fn) via
  `:transport`. All Provider tests run without the network through this (see provider_test.exs).
- **Error kinds are stable** (ADR 0005): `:usage_limit_reached`, `:model_not_supported`,
  `:rate_limited`, `:network`, `:context_overflow` (ADR 0020 — the Turn loop's overflow-
  recovery hook), `:provider_http_error`. Terminal ones aren't retried;
  network/`:rate_limited`/5xx are (capped exponential backoff, `max_retries`, default 2).
- **Reasoning items** (ADR 0007): `apply_event/2` captures the opaque `rs_` item in arrival
  order; `to_input_item/1` replays it verbatim, **dropping any whose stored model ≠ the
  request model**. `include: ["reasoning.encrypted_content"]` must be sent on every request.
- Stay free of Session/bus deps — the Turn loop turns deltas into Events; this module just
  streams and assembles a result.

Model id is an open knob: `config :pixir, :model` → `PIXIR_MODEL` → `~/.pixir/config.json` → default.
