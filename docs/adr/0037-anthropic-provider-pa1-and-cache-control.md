# 37. Anthropic provider: registry routing, pa1 prompt contract, explicit cache_control, and seam-parity transport

Date: 2026-07-08
Status: Accepted (2026-07-08, design review by the maintainer on PR #247)
Implementation status: Not implemented. This ADR is P0 of epic #243 and gates all
code phases (P2-P8). It is written over two verified artifacts: the P1 seam audit
impl-map (`outputs/cloud-fable-p1/impl-map-244.json`, 233 items adjudicated, issue
#244) and the ordered output_items fix (issue #245, PR #246), which this design
assumes merged.

## Context

Pixir today has one Provider, `Pixir.Provider`, speaking the OpenAI Responses
dialect behind the `Session -> Turn -> Provider -> Tools` seam. Epic #243 adds the
Anthropic Messages API (`claude-fable-5`) as a second Provider with the same
doctrine that governs the OpenAI path: a versioned byte-stable prompt prefix built
for maximum cache reuse (ADR 0020), cache evidence over cache hope (ADR 0019),
reasoning captured verbatim and replayed model-guarded (ADR 0007), and transport
behind the seam.

The P1 impl-map adjudicated every implicit OpenAI-ism in the current contract:
119 seam / 57 neutral / 57 internal. The seams converge on six abstractions
(neutral request struct, provider registry/router, ordered output-blocks contract,
per-provider usage normalizer, cache-intent, transport taxonomy). The ordered
output-blocks substrate already landed Turn-side (PR #246): Turn consumes the
provider's `output_items` in arrival order, with a fallback for providers that
omit it.

Load-bearing facts about the target API, verified against current Anthropic
documentation (2026-07), that constrain the design:

- **Prompt caching is explicit and prefix-exact.** `cache_control: {type:
  "ephemeral"}` breakpoints (max 4 per request), render order `tools -> system ->
  messages`, minimum cacheable prefix 2048 tokens on `claude-fable-5` (erratum,
  P3 review 2026-07-08: current live documentation states **512 tokens** for
  `claude-fable-5`; a prompt below the minimum caches nothing silently, both
  cache counters read 0 and no error is returned — P4 classifies that state as
  "below cacheable minimum", not an anomaly), cache reads
  ~0.1x input price, writes 1.25x (5m TTL) or 2x (1h TTL). Each breakpoint looks
  back at most 20 content blocks for a prior cache entry. Hits are reported in
  `usage.cache_read_input_tokens` / `usage.cache_creation_input_tokens`, with a
  nested per-TTL `usage.cache_creation` breakdown; `usage.input_tokens` is the
  uncached tail only (total prompt-side input = input + creation + reads).
- **Thinking is always on for `claude-fable-5` and `budget_tokens` is removed.**
  The epic's working assumption of an effort-to-thinking-budget-tokens mapping is
  obsolete: `thinking: {type: "enabled", budget_tokens: N}` returns 400, as does
  an explicit `{type: "disabled"}`. Depth is controlled by `output_config.effort`,
  whose API-side vocabulary is `low|medium|high|xhigh|max`; Decision 4 maps Pixir's
  `reasoning_effort` onto the first four and deliberately does not expose `max`
  (see Out of scope). The raw chain of thought is never returned;
  responses carry `thinking` blocks whose text is empty by default (`display:
  "omitted"`) or a readable summary (`display: "summarized"`). Blocks must be
  replayed exactly as received on the same model; a different model drops them.
- **Sampling and verbosity knobs are rejected.** `temperature`, `top_p`, `top_k`
  return 400 on `claude-fable-5`. There is no `text.verbosity`.
- **No developer role, no mid-conversation system on Fable 5.** Mid-conversation
  `role: "system"` messages are Opus 4.8 only. Volatile late context cannot ride a
  developer-role item (OpenAI) or a late system message (Opus 4.8) on this model.
- **Tool results are grouped.** All `tool_result` blocks answering one assistant
  turn's `tool_use` blocks must arrive in a single user message. The OpenAI path
  renders one `function_call_output` item per call; the Anthropic projection must
  group.
- **SSE is the public transport.** Event vocabulary: `message_start`,
  `content_block_start/delta/stop` (with `text_delta`, `thinking_delta`,
  `input_json_delta`), `message_delta` (carries `stop_reason` and usage),
  `message_stop`. There is no public WebSocket transport.
- **Auth is header-based API key.** `x-api-key: $ANTHROPIC_API_KEY` plus
  `anthropic-version: 2023-06-01`. Errors use a stable `error.type` vocabulary
  (`rate_limit_error` with `retry-after`, `overloaded_error` on 529, `api_error`
  on 500, `invalid_request_error`, ...). `claude-fable-5` additionally requires
  30-day org data retention (erratum, P7 review 2026-07-09: the original "ZDR
  orgs get 400 on every request" was too broad — current live documentation
  states the `400 invalid_request_error` is returned for requests from an
  organization whose data-retention configuration does not meet the 30-day
  requirement, and ZDR organizations can enable 30-day retention per workspace
  in Console > Settings > Workspaces, making the model available in that
  workspace) and can return `stop_reason: "refusal"` with `stop_details`.

## Decision

**1. A provider registry routes model ids; explicit selection still wins.**

A registry resolves a model id or an explicit provider id to: provider module,
default model, model catalog, auth adapter, and capability flags (transports,
structured output, thinking dialect, cache dialect). `claude-*` resolves to the
new Anthropic provider module (namespace `Pixir.Providers.Anthropic`; the
existing `Pixir.Provider` remains the OpenAI implementation and its internal
items from the impl-map stay provider-private). `opts[:provider]` keeps working
and takes precedence, preserving today's injection seam for tests and callers.
Turn stops calling `Pixir.Provider.default_model/0` and asks the resolved
provider, so `state.model`, usage stamps, context-window assessment, and replay
guards all carry the true model. ACP model validation and doctor consult the
registry, not the OpenAI catalog. Subagents/Workflows inherit the resolved
provider through the existing context threading; `subagents.model` with a
`claude-*` id routes children to Anthropic without an explicit module.

**2. The pa1 prompt contract mirrors px3 in spirit, not in bytes.**

Layering, with its own version label `pa1` so a fleet-wide cache break is
attributable in `provider_usage`:

- `tools`: canonical local tool definitions projected to Anthropic tool schema,
  deterministically ordered (registry order, stable).
- `system`: Layer 0 (Pixir identity and runtime invariants, byte-identical
  everywhere, mode variant selected the same way px3 does) followed by Layer 1
  (the deterministic Skills index), as an array of text blocks.
- `messages`: folded history, then the current request.
- **Volatile late context** (workspace root, posture, presenter context,
  Delegation Context) rides as the leading content block of the latest user
  message, after the last cache breakpoint, byte-fenced the way the late
  developer item is on px3. This is the one structural divergence from px3 and
  it is forced by the API: no developer role exists and mid-conversation system
  messages are not available on `claude-fable-5`. Authority is carried by the
  fence wording, cacheability by position, same doctrine as ADR 0020.

Byte-stability rules are identical in spirit to px3: Layer 0 frozen, Layer 1
project-stable, any layout change bumps `pa1 -> pa2` and ships as one labeled
break.

**3. cache_control placement: three planned breakpoints, one reserve.**

- **B1** on the last `system` block. Because a breakpoint caches everything
  before it in render order, B1 covers tools + system in one entry (the pa1
  stable prefix).
- **B2** on the last content block of the folded history as of the previous
  turn. Multi-turn requests then read the whole prior conversation
  incrementally, the standard multi-turn pattern.
- **B3** intermediate, placed by the request builder only when the current turn
  has appended more than ~15 content blocks since the previous breakpoint
  (tool-heavy agentic turns; the 20-block lookback otherwise silently misses).
- The fourth breakpoint stays in reserve; adding a planned use for it is a pa1
  revision, not an ad hoc edit.

TTL strategy: default 5-minute TTL everywhere initially. The 1-hour TTL doubles
the write premium and needs at least three reads to break even; it is not
adopted until P4 hit-rate reconciliation from Logs shows a workload where it
pays (delegation loops on a 4-minute cadence keep the 5m cache warm by design).
Breakpoint placement and TTL are recorded decisions; effectiveness is measured
from `cache_read_input_tokens` in durable usage events, never assumed.

**4. Effort maps to `output_config.effort`; foreign knobs are filtered.**

`reasoning_effort` (`low|medium|high|xhigh`, already provider-neutral since
#223) maps 1:1 to `output_config.effort`. Anthropic's additional `max` tier is
reachable only if the spec vocabulary grows later; this ADR does not grow it.
The `thinking` parameter is omitted entirely on `claude-fable-5` (always-on).
`thinking.display` defaults to `"omitted"`; a provider option can request
`"summarized"` when human-readable reasoning summaries are wanted as evidence.
The provider request builder filters options by capability: `text_verbosity`,
sampling parameters, `prompt_cache_key`, and `prompt_cache_retention` are never
sent to Anthropic (the API rejects some and ignores none silently that matter).
Effective model and effort are evidenced per call in `provider_usage`, never
echoed (the #223 doctrine unchanged).

**5. Thinking blocks are captured verbatim and replayed in exact order.**

ADR 0007 parity over the ordered walker from PR #246: `thinking` and
`redacted_thinking` content blocks are captured as ordered output items
alongside `tool_use`, recorded as canonical `reasoning` events with the raw
block stored opaquely plus a model stamp and a provider dialect label
(additive field in the event data; old events without it fold unchanged and
are treated as the OpenAI dialect). Replay re-injects the blocks verbatim, in
the exact assistant-content order next to their `tool_use` blocks, signatures
untouched, guarded by model equality exactly as `rs_` items are today. Blocks
from a different model are dropped (deterministic client-side, matching the
server's own cross-model behavior). Iteration-capped turns keep the existing
rule: no trailing reasoning persisted without a following executed item.

**6. Tool use projects from canonical definitions; results group.**

`__tool__/0` schemas project to Anthropic `{name, description, input_schema}`
tools. `tool_use.id` becomes the canonical `call_id` (Turn and the Executor are
already id-agnostic). On replay, each assistant turn renders its `tool_use`
blocks inside the assistant message content in captured order, and all
corresponding `tool_result` blocks render into one single following user
message, `is_error` mapped from the tool error contract. Parallel tool use
stays enabled (API default). Provider-hosted tools (web search) are not mapped
in this epic: the capability flag reports them unsupported and the spec-level
strict validation rejects them for Anthropic runs, honestly.

**7. Usage evidence is provider-owned; the cache accounting is explicit.**

The provider returns `usage_summary` itself; Turn's fallback to
`Pixir.Provider.usage_summary/1` for foreign providers is removed (a provider
without a summary is a contract violation surfaced as structured error, not
silently misparsed). The normalized summary keeps the neutral fields
(`input_tokens`, `output_tokens`, `total_tokens`, `model`) and adds an explicit
cache map: `cache: %{"creation_tokens" => n, "read_tokens" => n}`.
`cached_tokens` is populated from read tokens only, so existing consumers keep
meaning; `cache_hit_rate` is computed from reads only (creation is a write,
never a hit). `prompt_contract_version: "pa1"` and the neutral family hashes
(mode, toolset, skill index, fork-root family) ride the same evidence fields
px3 uses; the cache-intent split is: neutral evidence stays in
`cache_metadata`, provider request hints (`prompt_cache_key` for OpenAI, the
cache_control plan for Anthropic) are produced by a provider cache-planning
callback and never leak into the neutral contract. Context-window table gains
the `claude-fable-5` entry (1M input, 128K output).

**8. Transport: SSE now, the seam keeps the WS slot open.**

The Anthropic provider declares transport capabilities: `auto -> http_sse`,
`http_sse -> http_sse`, `websocket -> structured error` (kind
`unsupported_transport`, fail-closed and honest; no silent fallback that would
misreport `active_transport`). The generic SSE framing parser is reused; event
decoding is provider-owned (the vocabulary in Context). Errors map into the
existing stable kinds: 429 -> `rate_limited` (honoring `retry-after`), 500 ->
retryable `provider_http_error`, 529 (`overloaded_error`) -> retryable
`provider_http_error`, 400/401/403/404 -> terminal kinds as today, and
`stop_reason: "refusal"` -> a new curated kind `provider_refusal` (terminal,
non-retryable, `stop_details` recorded as evidence; no fallback-model retry in
this epic). Stream-idle timeout, retry policy shape, and `active_transport`
evidence keep the existing contract. A future Anthropic WebSocket or successor
transport drops in behind `TransportPolicy` without touching Turn; nothing is
fabricated today.

**9. Auth is provider-scoped; doctor tells the truth per provider.**

Credentials gain a provider dimension: an Anthropic API key from
`ANTHROPIC_API_KEY`, sent as `x-api-key` plus `anthropic-version` by an
Anthropic header builder. Bearer headers, `chatgpt-account-id`, and the Codex
OAuth adapter remain OpenAI-private and are never sent to Anthropic. OAuth or
subscription auth for Anthropic is out of scope. Doctor reports the resolved
provider and effective model per the registry, and remediation names the right
variable for the failing provider; the `claude-fable-5` retention requirement
is documented in doctor guidance (a 400 on every valid-looking request points
at org data-retention configuration, not the payload). No network probing by
default, as today.

**10. Request shape details.**

`max_tokens` is required by the Messages API: default from provider config
(generous, streaming is always used), never inferred from the OpenAI path.
`output_schema` maps to `output_config: {format: {type: "json_schema",
schema: ...}}`. Assistant prefill is never emitted (rejected by the API; the
fold has no prefill path today). Stop reason mapping: `end_turn -> :stop`,
`tool_use -> :tool_calls`, `refusal` -> `provider_refusal` per Decision 8.
`max_tokens` (erratum, P2 review: the originally referenced "existing
truncation error path" does not exist on the OpenAI side, which never errors
on output caps) finalizes successfully with truncation recorded as evidence:
`:stop` for plain text, `:tool_calls` when completed `tool_use` blocks exist
so they are not discarded, and `provider_metadata` carries
`stop_reason: "max_tokens"` plus `truncated: true` in both cases. A shared
cross-provider truncation-honesty contract is defined by ADR 0039; its neutral
value is authoritative while these private keys remain compatibility evidence. `pause_turn` is
out of scope (no server-side tools are mapped).

## Out of scope (deliberate)

- OAuth / subscription authentication for Anthropic.
- WebSocket transport (none exists publicly; the seam slot stays open).
- Server-side fallbacks beta, fast mode, Batches, Files, server-side
  compaction, provider-hosted web search/fetch, and Managed Agents surfaces.
- 1-hour cache TTL (revisit with P4 evidence).
- Growing the effort vocabulary to `max`.
- Cache pre-warming (`max_tokens: 0`) and cache diagnostics beta.

## Consequences

- The six impl-map abstractions land as the epic's phases: registry/router and
  option namespacing (P7 pulled partially into P2 groundwork), neutral request
  struct and tool projection (P2/P6), pa1 + cache planning (P3), usage
  normalizer and cache evidence (P4), thinking capture/replay (P5), transport
  taxonomy (P2). Each phase implements against this ADR plus the impl-map, by
  Pixir workers, audited pre-merge, evidence-gated.
- The OpenAI path's behavior does not change in this epic. Impl-map `internal`
  items stay provider-private; `neutral` items are reused as-is. Where a seam
  forces a shared contract change (usage_summary ownership, cache-intent
  split), the OpenAI provider is adapted mechanically with its existing tests
  as the regression net.
- Test doctrine: no test hits the network. Canned Anthropic SSE fixtures drive
  the transport seam (fixture files checked in, replayed through the generic
  SSE parser); live smokes are manual and opt-in; P8 runs the delegate fan-out
  gauntlet with Claude children and the cache-evidence bench in the
  proc-pressure honesty style.
- Evidence rules extend, not fork: `provider_usage` carries
  `prompt_contract_version: "pa1"`, the explicit cache map, and the true model;
  cache hit claims must cite `cache_read_input_tokens` from durable events.
- The 4-minute delegation loop cadence happens to sit inside the 5-minute cache
  TTL; the cache bench in P8 should measure this coupling rather than assume it.

## Verification direction

```bash
mix test test/pixir/provider_test.exs
mix test test/pixir/turn_test.exs
mix test test/pixir/providers/anthropic_test.exs   # new, per phase
mix test
mix check
```

Regression coverage across the phases should prove, minimum:

- `claude-*` model ids route to the Anthropic provider via the registry;
  explicit `opts[:provider]` still wins; non-`claude-*` behavior unchanged.
- pa1 Layer 0 bytes are identical across workspaces; volatile context rides
  the latest user message after the last breakpoint; breakpoint plan matches
  Decision 3 including the ~15-block intermediate rule.
- OpenAI-only knobs never appear in an Anthropic request body (property test
  over the option bag).
- Thinking blocks round-trip verbatim in exact order through Log fold and
  replay; cross-model events drop; signatures byte-identical.
- One assistant turn's tool_results render as a single user message.
- `usage_summary.cache` populates from Anthropic usage fields; `cached_tokens`
  equals read tokens; the prompt-cache smoke reports hits from the normalized
  field, not `cached_tokens > 0` hard-coded against OpenAI shape.
- `websocket` transport request against Anthropic returns the structured
  `unsupported_transport` error; SSE fixtures cover text, thinking, tool_use,
  usage, refusal, 429-with-retry-after, and 529.

## References

- Epic #243 (doctrine and phases), sub-issue #244 (impl-map, verified
  2026-07-08), issue #245 / PR #246 (ordered output_items substrate).
- `outputs/cloud-fable-p1/impl-map-244.json` (233 adjudicated items; the seam
  inventory this ADR resolves).
- ADR 0007 (reasoning capture/replay), ADR 0019 (provider usage and prompt
  cache evidence), ADR 0020 (versioned prompt contract and cache-key family).
- Anthropic Messages API documentation: prompt caching (breakpoints, TTLs,
  20-block lookback, minimums), extended thinking on `claude-fable-5`
  (always-on, `output_config.effort`, display modes, replay rules), streaming
  SSE event vocabulary, error codes, model catalog
  (https://platform.claude.com/docs/en).
