# 3. Stateless Turns; local Log is the source of truth; prompt-cache deferred

Date: 2026-05-29
Status: Accepted

## Context

We chose the OpenAI Responses API (ADR 0002). The Responses API can run stateful
(server retains the thread via `previous_response_id` + `store: true`) or stateless
(client resends the conversation as input items each Turn). We separately decided the
per-Session **Log** is the single source of truth and History is a fold over it.

Investigation of Pi's `openai-codex-responses.ts` settled it: the ChatGPT Codex
subscription backend **rejects `store: true`** ("Store must be set to false"). Server
-side stored threads are therefore unavailable on the subscription path. Pi recovers
prompt-cache only via a persistent WebSocket whose connection-scoped `continuation`
sends a delta + `previous_response_id` when the new request is a prefix-extension of
the previous one, and falls back to a full resend on any divergence (fork/edit).

## Decision

Turns are **stateless**: each Turn folds the Session's Log into Responses input items
and sends them with `store: false`. The local Log remains the single source of truth;
no server state is relied upon. v0.1 uses plain **HTTP/SSE**. The **WebSocket-cached**
transport (a per-Session connection process holding continuation state, sending
prefix-deltas with `previous_response_id`) is a deferred optimization.

## Consequences

- **No conflict with "Log is source of truth"** — the backend cannot own state anyway.
- **Fork/replay stay clean** — divergence simply means a full resend.
- **Cost/latency:** without the WS cache, long sessions resend full history each Turn.
  Accepted for v0.1; the WS connection process recovers caching later.
- **The WS optimization is OTP-natural:** a supervised GenServer per Session owns the
  socket + continuation state; process lifetime = cache lifetime; token refresh and
  reconnect become supervision concerns (less code than Pi's manual pool).
- **Heeded gotcha:** only the final `assistant_message` is canonical/logged; streaming
  partials are ephemeral (avoids Kimojo's partial-vs-final `call_id` duplication).
