# Context-pressure evidence and override granularity

Invalid entries in a `context_windows` object are ignored individually, preserving
valid siblings and their precedence over built-in values. Non-object configuration
still supplies no overrides. Existing warnings remain visible.

For a known input ceiling, missing usage now yields `usage_missing` and malformed,
negative or noninteger usage yields `usage_invalid`. Both assessments have
`available: false`, `tier: unavailable` and no fabricated input count or ratio.
An observed integer zero remains available with zero pressure. Atom-keyed input
takes precedence when present; the string-keyed canonical Log shape is also accepted.

Turn's existing unavailable-evidence path records these reasons without emitting
a healthy pressure snapshot or advisory. Unknown model capacity still reports
`context_window_unknown`; no numeric Astra ceiling is introduced. Native compaction
and explicit overflow recovery are not changed.

The original missing-usage-as-zero test contract is intentionally replaced. New
regressions cover mixed-validity configuration, missing/invalid usage, real zero,
and a Provider that returns raw usage without the required normalized summary.
Tests use isolated configuration or supplied raw maps, not operator configuration.

The OpenAI and Anthropic Providers now also preserve validity **before accounting normalization**.
The optional `usage_summary.input_tokens_unavailable_reason` is `usage_missing` or
`usage_invalid`; it survives Turn's string-keyed canonical `provider_usage` record
and NDJSON folding. Context-window assessments honor that marker before reading
normalized `input_tokens`, so re-assessing a durable summary cannot turn missing
usage into a healthy zero or a coerced string/float into observed pressure.
Existing accounting fields and coercions remain unchanged, and valid integer
observations (including zero) retain the established summary shape. Responses and
legacy `prompt_tokens` names, string and atom keys, retain the Provider's existing
lookup order and nil fallback; a present boolean is invalid, not missing.

Injected HTTP/SSE transport regressions exercise the actual Provider-to-Turn path
for omitted/empty/null usage, malformed tokens, numeric strings, floats, negatives,
boolean tokens, genuine zero, legacy zero, and observed warning pressure. They
check canonical availability/reasons, ephemeral snapshots/notices, and pressure
re-assessment after reading the durable NDJSON Log.

Anthropic Provider-to-Turn tests cover the same missing/invalid versus observed
distinction, including partial usage updates that only supply output tokens. Its
accounting and cache-token calculations remain unchanged.

Scope: custom Providers still own their normalized summaries. Raw missing or
invalid summaries remain unavailable, and foreign Providers using the shared
OpenAI normalizer inherit its provenance. A foreign normalizer that already
replaced unknown usage with an unmarked integer zero cannot be distinguished from
an observed zero at this seam. Likewise, this change does not rewrite historical
Logs whose summaries predate provenance; no retroactive validity is claimed.
