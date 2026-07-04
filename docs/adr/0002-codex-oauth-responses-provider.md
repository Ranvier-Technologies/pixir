# 2. Codex (ChatGPT subscription) OAuth + OpenAI Responses API as the primary provider

Date: 2026-05-29
Status: Accepted

## Context

A core goal is letting users run Pixir on their existing **ChatGPT Plus/Pro
subscription** rather than pay-per-token API keys — the "Sign in with ChatGPT
(Codex)" experience Pi ships. Pi implements this as an OAuth (PKCE) flow against
`auth.openai.com`, then calls the **OpenAI Responses API** with the resulting access
token plus a `chatgpt-account-id` header.

Two facts shaped the decision:
1. `req_llm` (the Elixir multi-provider library Kimojo uses) is API-key +
   chat-completions oriented and does not support this OAuth/subscription path. Even
   Pi keeps OAuth providers as hand-built built-ins.
2. The **Responses API dialect serves both** a subscription OAuth token *and* a plain
   `OPENAI_API_KEY` — same item format, different endpoint/auth/headers.

## Decision

v0.1's single Provider is the **OpenAI Responses API**, reached via two
**Credentials**: a Codex **Subscription** OAuth token (primary) or an `OPENAI_API_KEY`
(fallback). The OAuth flow is implemented natively (PKCE), starting with the
**device-code** method (no local callback server; headless-friendly); the browser +
`127.0.0.1:1455` callback flow is a fast-follow. `req_llm` and all other providers
(Anthropic, local models) are deferred.

## Consequences

- **Subscription-first UX** — users leverage ChatGPT Plus/Pro; no API key required.
- **Responses is the canonical dialect.** Tool calling uses Responses
  `function_call` / `function_call_output` items and reasoning items — *not*
  chat-completions function-calling (a divergence from the Kimojo reference).
- **Auth is the largest single component of v0.1** (PKCE, token storage + refresh,
  the Responses client). Consciously accepted as the differentiator.
- **Device-code first** avoids the localhost-callback failures documented for remote/
  headless Codex sign-in, at the cost of a copy-code step.
- **Tokens** are stored locally and auto-refreshed; `chatgpt_account_id` is extracted
  from the JWT and sent as a header.
- **Deferring `req_llm`** means multi-provider breadth comes later; re-adding it is
  additive (a second dialect behind the same Provider seam).
