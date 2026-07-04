# 19. Provider usage, prompt-cache observability, and WebSocket continuation

Date: 2026-06-09
Status: Accepted
Implementation status: Provider usage/cache deterministic slice implemented; WebSocket
probe surface implemented; production WebSocket transport in progress

## Context

Pixir sends stateless OpenAI Responses calls with `store: false` and folds the local Log
into Provider input on every Turn. That keeps the Log authoritative, but it also means
cost, latency, and prompt-cache behavior are easy to misunderstand unless the Harness
records the Provider's accounting.

Prompt cache is not a Session store. It is an optimization on stable prompt prefixes.
The only trustworthy evidence that cache was used is Provider usage metadata such as
`cached_tokens` in the final `response.completed` usage payload. Latency or subjective
"it felt faster" observations are not enough.

The public OpenAI API supports automatic prompt caching for long prompts, `prompt_cache_key`
as a routing hint for requests that share a stable prefix, and `prompt_cache_retention`
for retention policy. Pixir's primary path is the ChatGPT/Codex subscription backend,
so new request parameters must be treated as dialect features: send only fields that are
known to be accepted or have a safe fallback.

OpenAI's Responses WebSocket mode is a separate optimization. It can keep a live
connection and continue from a prior Response with `previous_response_id` while sending
only the new input. The important distinction is:

- Prompt cache is Provider-side prefix reuse and is proven by `cached_tokens`.
- WebSocket continuation is transport/session-on-the-socket reuse and is proven by
  successful same-socket continuation semantics.
- Neither mechanism is Pixir's durable source of truth. The local Log remains
  authoritative.

The older Pixir repo already carried a bounded WebSocket smoke that empirically probed
the ChatGPT/Codex subscription path. That implementation is useful donor material for
Pixir Harness. It should be ported as an opt-in smoke first so the product can safely
move toward a WebSocket-first default transport without confusing validation probes with
ordinary CI or local unit tests.

## Decision

Pixir records Provider usage as a canonical `provider_usage` Event for every Provider
call in a Turn, including repeated calls inside a tool loop. The event is durable
Harness evidence and is excluded from Provider replay.

`Pixir.Provider.stream/2` captures usage from the streamed `response.completed` event and
returns both:

- the raw usage object;
- a normalized summary with input tokens, cached tokens, output tokens, reasoning
  tokens, total tokens, and cache-hit rate.

Normal Turn calls populate a deterministic `prompt_cache_key` when the Provider dialect
accepts it. The key is a cache family, not an individual request id. It is short,
bounded, and non-PII; it may include stable hashes for model, mode, Session/fork family,
Tool set, and Skill index. It must not include raw workspace paths, user text, timestamps,
request ids, emails, or secrets.

Pixir improves cache friendliness by keeping Tool specs and Skill index rendering
deterministic. The current workspace path remains in early instructions for now because
it is part of Pixir's existing agent contract; this is a known cache-rate drag across
different workspaces and should be revisited only with a separate prompt-contract change.

Pixir keeps `store: false`. Extended prompt-cache retention (`prompt_cache_retention:
"24h"`) is not sent by default on the ChatGPT/Codex subscription path until a probe proves
that backend accepts it. If enabled on a supported API path, it remains a request-level
optimization and still does not make the Provider the source of truth.

Pixir adds an opt-in WebSocket smoke surface:

```bash
mix pixir.smoke.websocket --dry-run --json
mix pixir.smoke.websocket --json
```

The smoke is agent-useful: it has `--help`, `--dry-run`, JSON output, structured errors,
bounded evidence, and no token/account-id printing. The real-network path probes:

- WebSocket upgrade/handshake;
- a minimal `response.create`;
- same-socket `previous_response_id` continuation;
- a tool-call loop continued with `function_call_output`;
- reconnect behavior showing that `store: false` response ids are not durable
  cross-socket Session storage.

Pixir's Provider transport decision is WebSocket-first by default once support is proven
for the active credential/dialect path. HTTP/SSE remains the fallback and debug path.
The production transport should be configured as `auto | websocket | http_sse`:

- `auto` is the default and prefers WebSocket when the dialect and credential path
  support it, then falls back to HTTP/SSE with a visible reason;
- `websocket` requires WebSocket support and fails honestly when unavailable;
- `http_sse` keeps the current stateless behavior.

The `auto` fallback must be a recovery policy, not a one-way downgrade. If WebSocket
fails because the socket cannot be opened, closes unexpectedly, or emits malformed
frames, Pixir may complete the Turn through HTTP/SSE so the user is not blocked. It then
marks WebSocket as temporarily degraded and retries WebSocket on a later Turn or after
backoff. If WebSocket recovers, `auto` returns to WebSocket. Provider/model failures
such as `response.failed` are not transport failures and must not be hidden by fallback.

`prompt_cache_key` survives transport fallback. It is a routing hint for a stable prompt
prefix family, so a full HTTP/SSE replay after WebSocket failure should carry the same
safe cache-key family when the active dialect supports it. `previous_response_id` does
not have the same portability: it is connection/Provider continuation state and may be
discarded on fallback or reconnect without corrupting Pixir, because the local Log can
always rebuild the Provider input.

Real-network runtime evidence on the ChatGPT/Codex subscription path showed the nuance:
two cache-eligible WebSocket requests with the same `prompt_cache_key` but separate
connections may still return `cached_tokens: 0`, while the same pair on one live
WebSocket connection observed a cache hit. Therefore Pixir treats `prompt_cache_key` as
worth preserving across transports, but not as a guarantee. WebSocket-first remains the
better default because it preserves engine/socket affinity when the Session is linear.

Production WebSocket support should be implemented as a supervised Provider connection
owned by a Session or Subagent. It may keep connection-local continuation state such as
the latest Response id, but it must not replace canonical Events, local Log replay,
compaction, or orphan tool-call repair.

## Consequences

- Pixir can answer "did this run hit prompt cache?" from durable evidence rather than
  guesses.
- Subagent and Workflow cost/cache behavior becomes inspectable because every model call
  gets its own usage event.
- Provider usage increases Log volume slightly, but the event is compact and string-keyed.
- Replay remains clean because `provider_usage` is never converted into model input.
- Cache keys can improve routing for fork-like workloads without exposing private paths
  or prompt content.
- Sending `prompt_cache_retention` too aggressively could break the ChatGPT/Codex backend;
  keeping it gated avoids turning an optimization into a product reliability risk.
- WebSocket continuation can reduce repeated payload transfer and improve latency for
  long, tool-heavy sessions, and is the right default for a Codex-first harness when the
  backend supports it. It still introduces connection lifecycle, reconnect, and fallback
  state that must be supervised explicitly.
- HTTP/SSE fallback preserves reliability and should preserve the same safe
  `prompt_cache_key`, but fallback may lose WebSocket-only continuation state. This is
  acceptable because replay comes from Pixir's Log.
- Parallel Subagents should use separate WebSocket connections. Responses WebSocket mode
  is not a general multiplexing layer for many in-flight responses on one socket.
- Fork-like workloads can benefit from both cache-key routing and shared-prefix
  WebSocket continuation, but forks are different from handoffs: forks preserve a shared
  prefix and diverge late; handoffs summarize or transfer context.

## Non-goals

- Do not treat the WebSocket smoke task as the production transport. Runtime WebSocket
  support must live behind Provider transport policy and supervised connection modules.
- Do not implement full Session fork UX in this slice.
- Do not use Provider cache as Session persistence.
- Do not use WebSocket `previous_response_id` as Session persistence.
- Do not claim cache hits from latency alone.
- Do not claim WebSocket performance wins without measuring bytes sent and latency.
- Do not expose raw prompts, raw paths, or identities in cache keys.
- Do not make network prompt-cache or WebSocket smokes part of ordinary tests or CI.

## Verification Direction

The minimal contract is:

```bash
mix test test/pixir/provider_test.exs
mix test test/pixir/turn_test.exs
mix test test/pixir/event_test.exs
mix test test/pixir/skills_test.exs
mix pixir.smoke.prompt_cache --dry-run --json
mix pixir.smoke.websocket --dry-run --json
mix check
```

Regression coverage should prove:

- `provider_usage` is canonical and string-keyed.
- Provider replay excludes `provider_usage`.
- `response.completed` usage is captured and normalized for current and legacy shapes.
- Turn records one `provider_usage` Event per Provider call.
- Default cache keys are stable, bounded, and do not include raw workspace paths or user
  text.
- Tool specs and Skill index output are deterministic.
- The prompt-cache smoke task exposes `--help`, `--dry-run`, `--json`, and structured
  errors.
- The WebSocket smoke task exposes `--help`, `--dry-run`, `--json`, structured errors,
  and a no-auth/no-network/no-write dry-run contract.
- The WebSocket real-network path remains opt-in and records enough evidence to
  distinguish handshake failure, provider error, same-socket continuation failure, tool
  loop failure, and reconnect/durable-state mismatch.

Representative real-network probes should use the configured default OpenAI model with
low reasoning effort when supported, unless the user explicitly asks otherwise. Public
cache and continuation claims must be based on observed `provider_usage` and transport
outcomes for the active dialect.

## References

- ADR 0002: ChatGPT subscription OAuth and OpenAI Responses Provider.
- ADR 0003: stateless Turns and local Log as source of truth.
- ADR 0004: unified Event envelope and canonical vs ephemeral events.
- ADR 0017: minimal Harness core and Presenter boundary.
- ADR 0018: durable History compaction and replay repair.
- CONTEXT.md: Provider Usage, Prompt Cache, Cache-Key Family, Prompt Cache Retention,
  WebSocket Continuation, Fork, Handoff.
- OpenAI Prompt Caching guide: https://developers.openai.com/api/docs/guides/prompt-caching
- OpenAI WebSocket Mode guide: https://developers.openai.com/api/docs/guides/websocket-mode
- OpenAI Conversation State guide:
  https://developers.openai.com/api/docs/guides/conversation-state#previous_response_id-in-websocket-mode
- OpenAI Responses API reference:
  https://developers.openai.com/api/docs/api-reference/responses/create
