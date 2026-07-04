# AGENTS.md - Pixir Provider

This directory is the OpenAI Responses API dialect, transport policy, prompt-cache
metadata, and Provider-hosted tool seam.

- Prefer this file plus ADR 0019/0020/0022 before touching request shape, SSE/WebSocket
  handling, retries, model resolution, hosted tools, or reasoning replay.
- Provider calls are stateless: `store: false`, full History folded into input each Turn.
- Keep network access behind the injectable transport seam; ordinary tests must not hit
  the network.
- `prompt_cache_key` is only routing metadata. Cache-hit claims require observed
  `cached_tokens`. Preserve the same safe cache-key family across WebSocket ->
  HTTP/SSE fallback when the dialect supports it.
- WebSocket continuation is the target default transport via an `auto` policy:
  WebSocket first, HTTP/SSE fallback, then retry WebSocket after backoff instead of
  downgrading forever. Preserve the local Log as source of truth:
  `previous_response_id` is transport optimization state, not Session persistence and
  need not survive fallback.
- Provider-hosted tools (currently OpenAI `web_search`) are Provider request/evidence
  features, not Pixir local Tools. Shape them here, return bounded evidence, and let
  `Pixir.Turn` decide what becomes durable `provider_usage`.
- Provider image/file inputs are projections of `Pixir.SessionResources`; do not treat a
  Provider `input_image`/`input_file` payload as Pixir's canonical resource record.
- Preserve encrypted reasoning replay rules from ADR 0007, including model-id guarding.
- Provider modules should not depend on Session, Log, or Events; the Turn loop turns
  stream chunks into Pixir Events.

Fast checks:

```bash
mix test test/pixir/provider_test.exs test/pixir/provider_model_test.exs test/pixir/provider_models_test.exs
mix compile --warnings-as-errors
mix format --check-formatted
```
