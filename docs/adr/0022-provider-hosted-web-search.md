# 22. Provider-hosted Web Search

Date: 2026-06-12
Status: Accepted
Implementation status: deterministic slice implemented; live smoke is opt-in

## Context

Pixir is Codex-first and speaks the OpenAI Responses dialect directly. OpenAI Responses
supports hosted tools such as `web_search`: the Provider can run the search and emit
stream events, annotations, citations, and source evidence.

This creates a boundary risk. Pixir already has local **Tools** (`read`, `bash`,
`resource_view`, etc.) that are executed by Pixir, permissioned by Pixir, confined to the
Workspace, and recorded as `tool_call` / `tool_result` Events. OpenAI hosted web search
looks syntactically similar because it is also declared in the Responses `tools` array,
but it is operationally different: the Provider executes it.

Presenters can make web search visible or configurable, but Pixir owns Provider request
assembly. If a Presenter assembled the prompt or declared Provider tools itself, Pixir
would lose the Harness boundary locked in ADR 0017.

## Decision

Pixir treats OpenAI hosted `web_search` as a **Provider-hosted Tool**, not as a local
Pixir Tool.

Request shaping lives in the Provider layer:

- local Pixir Tools continue to be serialized as Responses `"function"` tools;
- hosted Web Search is serialized as `%{"type" => "web_search"}` only when explicitly
  requested by Pixir's Provider request config;
- `search_context_size` defaults to `"low"` for beta cost discipline;
- supported OpenAI search policy fields such as `filters`, `user_location`,
  `external_web_access`, and `return_token_budget` are preserved or rejected
  explicitly; Pixir must not silently widen or narrow the user's search policy;
- `web_search_call.action.sources` is included by default when Web Search is enabled so
  Pixir can capture source evidence when the backend emits it.

Pixir records bounded Provider-hosted Web Search evidence inside canonical
`provider_usage` Events. The evidence may include lifecycle event types, hosted call ids,
redacted query metadata, sources, and URL-citation annotations. It is durable Harness
evidence and excluded from Provider replay. Pixir does not persist raw Web Search queries
or Web Search as local `tool_call` / `tool_result`.

The first user-facing verification surface is an opt-in smoke:

```bash
mix pixir.smoke.web_search --dry-run --json
mix pixir.smoke.web_search --json
```

The smoke is agent-useful under ADR 0005: `--help`, `--dry-run`, JSON output, bounded
evidence, and structured errors with next actions. The dry-run path does not require
auth, does not call the Provider, and does not write files.

## Consequences

- Pixir can use current web evidence through the same OpenAI Responses backend without
  adding MCP or local browser automation.
- The local Log remains the source of truth; Provider-hosted Web Search output is audit
  evidence, not Session state.
- Presenters remain Presenters. They can expose settings later, but Pixir owns the Provider
  request shape.
- Hosted Web Search queries cross the Leakage Boundary. The product should keep usage
  opt-in until there is an explicit policy for ambient search.
- Provider-hosted tool evidence increases `provider_usage` size slightly, so the parser
  keeps the evidence bounded and normalized.
- Citations depend on backend stream shape and include support. Pixir preserves
  annotations and sources when emitted instead of flattening them into assistant text.

## Non-goals

- Do not implement MCP.
- Do not add local browser automation as part of Web Search.
- Do not make Web Search ambient for every Turn.
- Do not make OpenAI search output Pixir's source of truth.
- Do not treat hosted Web Search as a local `Tool`.
- Do not change client adapter behavior in this slice.

## Verification Direction

Deterministic checks:

```bash
mix test test/pixir/provider_test.exs
mix test test/pixir/turn_test.exs
mix test test/mix/tasks/pixir_smoke_web_search_test.exs
mix pixir.smoke.web_search --dry-run --json
mix check
```

Regression coverage should prove:

- request previews include `%{"type" => "web_search"}` only when requested;
- supported OpenAI Web Search policy fields are preserved and unsupported fields fail
  with structured `:invalid_args`;
- source include fields are present when Web Search is enabled;
- invalid Web Search config returns structured `:invalid_args`;
- Provider stream parsing captures `response.web_search_call.*`, `web_search_call`
  output items, sources, and URL-citation annotations;
- `provider_usage` records Provider-hosted evidence without raw search queries;
- Provider replay still excludes `provider_usage`.

Representative live probes should use the configured default OpenAI model with low
reasoning effort when supported, unless the user explicitly asks otherwise.

## References

- ADR 0004: unified Event envelope and canonical vs ephemeral events.
- ADR 0005: agent ergonomics and structured script errors.
- ADR 0017: minimal Harness core and Presenter boundary.
- ADR 0019: Provider usage, prompt-cache observability, and WebSocket continuation.
- ADR 0021: Session Resources and Image Attachments, which use the same "Provider
  projection, local truth" principle.
- OpenAI Web Search guide:
  https://developers.openai.com/api/docs/guides/tools-web-search
