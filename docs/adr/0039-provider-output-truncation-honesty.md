# 39. Provider-output truncation is neutral, durable success evidence

Date: 2026-07-12
Status: Accepted

## Context

OpenAI Responses and Anthropic Messages can successfully terminate after a Provider
output limit, context-window output limit, or content filter. Pixir historically kept
Anthropic's `max_tokens` as private metadata and did not represent the equivalent
Responses lifecycle at all. A successful but cut answer could therefore look complete
to the Turn, CLI, ACP clients, parent Subagents, Delegate consumers, and diagnostics.

Operational `finish_reason` cannot carry this truth. A positively truncated response
may contain finalized valid tool calls that remain safe to execute. Conversely, token
counts, requested caps, text length, and transport closure cannot prove truncation.

## Decision

`Pixir.Provider.OutputTruncation` is the provider-neutral, opaque tri-state value:
`not_truncated`, `truncated`, or `unknown`. Positive evidence requires an explicit,
bounded Provider terminal token. Missing, malformed, unsafe, or historical evidence is
confessed as a reasoned `unknown`; Pixir never infers a positive value.

Every successful built-in Provider result carries the value. `Pixir.Turn` records it
inside every canonical `provider_usage`, correlated to that Event id and call role.
Only a positively truncated final call is copied to assistant metadata, with the stamped
usage seq. Provider text, lifecycle status, replay text, retry, compaction, and
`metadata.partial` remain unchanged.

Responses maps completed/incomplete lifecycle events explicitly and treats conflicting
terminal frames as invalid, including an incompatible pair already buffered on one
WebSocket read. Buffered terminal inspection reconstructs fragmented text messages
across continuation and interleaved control frames without performing another receive.
Anthropic maps its enumerated `stop_reason` values while retaining its
legacy private positive keys for compatibility; unsafe or oversized unmapped tokens are
not copied into Provider metadata or the Log. Both Providers execute
only finalized calls whose bounded identity is valid and whose arguments are a JSON
object. Anthropic error-partial assistant evidence is excluded from replay.

Presenters and orchestration surfaces use bounded, correlation-aware projections:

- CLI and ACP retain at most 256 per-call warnings per presentation epoch;
- diagnostics and replay inspection retain the most recent 64 positive references;
- each Subagent retains at most 64 warning objects while preserving its authoritative
  pre-bound total and reason set; restore retains the first 64 canonical warnings and
  validates correlation, including the outer child Session identity, before any suffix
  or Delegate projection;
- Delegate envelopes retain at most 256 children and warnings, and advance the additive
  `pixir.delegate.envelope.v1` revision from 4 to 5; top-level totals sum validated
  pre-bound authority once per distinct child Session even when only 64 references were
  retained;
- parent model context receives only a bounded enum/count suffix after the unchanged
child summary.

Assistant metadata is only a usage-absent presentation fallback. A partial assistant,
unsafe correlation id, missing call role, or contradictory count-only aggregate cannot
be promoted into a warning or final completeness claim.
The terminal Renderer owns the same bounded presentation epoch: it keeps at most 256
Session/Event identities, deduplicates canonical warnings and assistant fallback, and
still advances its latest order marker for suppressed warnings.

ACP warnings use the pinned protocol-v1 `session_info_update` extension under
`_meta.pixir`; they never mutate transcript chunks or claim that a particular client
renders a visible banner.

## Consequences

Successful output can now be honestly qualified without becoming an error. Historical
Logs remain readable and immutable, but their completeness is explicitly unknown.
Provider-private metadata cannot overwrite the neutral object. The additional bounded
state and Delegate schema revision are additive compatibility costs.

The one-shot CLI empty-output guard remains authoritative: empty, whitespace-only, or
reasoning-only final output still exits 6 even when the Provider Turn itself completed.
Extension-profile conformance remains separate work and cannot redefine this core
vocabulary.

## Non-goals

- Input context overflow, recovery, retry, or compaction policy.
- Local tool/file/stdout truncation and non-2xx error-body bounds.
- Generic Open Responses extension capability gates.
- UI changes in T3 Code, Zed, or another ACP client.

## Verification direction

Deterministic, no-network fixtures cover both Provider terminal vocabularies, terminal
conflicts, missing evidence, safe-token boundaries, complete/partial tool calls, Turn
correlation, historical replay, bounded CLI/ACP/Subagent/Delegate projections, and the
Delegate revision. The durable issue-268 oracle must report `fixed_contract_observed`
without repository mutation.

## References

- ADR 0003 and ADR 0004: local Log and canonical Event truth.
- ADR 0009: ACP presenter boundary.
- ADR 0026: terminal-state and partial replay contract.
- ADR 0037 Decision 10: Anthropic stop-reason compatibility predecessor.
- Issue #268 item 2; issue #320 remains downstream.
