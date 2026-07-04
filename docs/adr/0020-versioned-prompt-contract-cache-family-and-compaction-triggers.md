# 20. Versioned prompt contract, cache-key family, and compaction triggers

Date: 2026-06-09
Status: Accepted
Implementation status: Implemented. Triggers/limitations landed via fleet waves 1–2;
the px2 migration landed in wave 3 (byte-stable Layer 0 with discovery rule and
checkpoint contract, late developer-context input item, px2 key with fork-root family,
prompt_contract_version on provider_usage). The developer-role input item is
live-verified against the ChatGPT/Codex backend. Subsequent prompt-contract bump:
`px3` renders the Skill index as routing-only metadata with `when_to_use` fields and an
explicit "do not list Skills unless asked" instruction, after dogfood showed the model
could answer a system-prompt question by listing Skills first.

## Context

Pixir folds the local Log into OpenAI Responses input on every Turn (ADR 0003) and now
has durable compaction checkpoints (ADR 0018) and provider usage/cache evidence
(ADR 0019). Design note 0002 grilled the remaining context-engineering questions against
those decisions, the live code, and re-verified external sources (Manus, LangChain/Deep
Agents, OpenAI compaction docs). This ADR promotes the resolved subset.

Three facts drove the decisions:

- **Prefix edits are never free.** Prompt cache is an exact-prefix match: any byte change
  at position N invalidates everything after N, and a first-sentence change (where the
  workspace path lives today, `turn.ex`) invalidates the entire cached prompt for every
  live Session. Each "small" instructions edit is a fleet-wide cold restart.
- **Routing discrimination moves from bytes to the key.** The Provider routes on a hash
  of the initial prompt prefix (~256 tokens) combined with `prompt_cache_key`, with a
  ~15 requests/min overflow ceiling per (prefix, key) bucket. Today different workspaces
  separate by bytes because the workspace path sits in the routing window. Once the
  prefix is re-layered to be globally byte-identical, the key becomes the only traffic
  separator — making key design more load-bearing, not less.
- **The shipped key has a fork gap.** ADR 0019's key component `s_` is named "session
  family" but hashes the raw `session_id`, so a Fork (CONTEXT.md) gets a cold bucket
  despite byte-sharing almost its entire prefix with its parent — the exact case the
  component was named for.

A compaction checkpoint is a **triple lifecycle event**: it resets WebSocket
continuation (the new input is no longer a prefix extension), intentionally breaks the
transcript portion of the cache prefix, and is invisible to the Cache-Key Family, which
names the request family rather than the prefix bytes. Compaction triggering is
therefore a deliberate lifecycle policy, not a background optimization.

## Decision

**1. The Prompt Contract is versioned, and changes ride one batched break.**

Pixir adopts the Prompt Contract term (CONTEXT.md): the layered agreement over Provider
input. Authority and cacheability are separate axes — authority is carried by role, not
position. All pending prefix-layout changes ship as one explicit migration, not as
incremental refactors:

- Layer 0 (instructions, byte-identical for every Session everywhere): Pixir identity
  and runtime invariants; the AGENTS.md discovery rule instead of injected project
  documents; a short checkpoint-interpretation contract (a history checkpoint in input
  is lossy prior context; recent tail and current request win).
- Layer 1 (instructions, project-stable): the deterministic Skills index and tool
  schemas, ordered deterministically, after Layer 0 so the routing window stays global.
- Late developer context (input): workspace path, branch, permission mode. Workspace
  confinement does not move — it is enforced by the tool layer, not the prompt sentence.

The migration is the prompt-contract change ADR 0019 explicitly deferred ("revisited
only with a separate prompt-contract change"). The point is not preserving warmth across
the migration; the point is making the break intentional, measurable, and attributable.
Expected signature: worse cache immediately after migration, better and stabler behavior
once the new prefix warms. The live smoke must measure prompt-position sensitivity,
since the model has anchored on a first-sentence workspace path since v0.1.

Sequencing: the migration must not share a PR or an observability window with WebSocket
continuation work. PR A instruments `previous_response_id`; PR B ships the px2
re-layering; a comparative smoke via `provider_usage` runs between, so cache movement is
attributable to transport or prompt contract — never ambiguously both.

Implementation disposition: the accepted release branch carried PR A-style continuation
evidence and PR B-style px2 re-layering in one GitHub PR, but not as one undifferentiated
behavioral window. The `previous_response_id` work was instrumentation/evidence over the
existing WebSocket transport semantics; the px2 prompt-contract change remained a later
wave with pre/post live probes and a `prompt_contract_version` label in `provider_usage`.
Future production transport behavior changes still need their own observability window.

**2. The cache key discriminates by stable surfaces, not volatile bytes.**

- Keep the shipped surfaces: model, mode, toolset, skill-index hashes.
- Add a prefix-contract version segment (`px1` → `px2` at this migration; bumped on
  every future prompt-contract change).
- Fix `s_` to be a true fork family: a hash of the fork-tree root Session, inherited
  across forks, so forks sharing a stable prefix intentionally share warmth.
- The broad/global key (`pixir:runtime-v1:tools-base-v1`, proposed in an earlier draft
  of design note 0002) is rejected: post-re-layering it would funnel every Session into
  one overflow-limited bucket — a single Subagent fleet saturates ~15 rpm alone,
  scattering large per-session conversation prefixes to cold machines to co-locate a
  small shared static prefix. Broad families fit many short near-identical requests;
  Pixir's workload is long Sessions with sequential tool loops plus Subagent bursts.
- A project-hash segment is deferred until pinned Layer-1 project summaries exist; until
  then project instructions are discovered through tools, not injected.
- `provider_usage` Events carry the prompt-contract version, so intentional breaks are
  distinguishable from regressions in cached-token evidence.

**3. Skill Activation stays per-Turn; compaction states what it dropped.**

Compaction may compact away old `skill_activation` bodies (ending the unbounded replay
of full SKILL.md content), and Pixir does not pretend those practices remain active
session-wide. The checkpoint records it explicitly as a limitation: skills activated
only inside the compacted range are not replayed unless they remain in the recent raw
tail or are explicitly re-activated. No Pinned Skill concept is introduced; if
long-lived governing practices become a real need, that is a separate design with its
own events and UX.

**4. Compaction triggers: advisory before failure, recovery after failure.**

Manual `pixir compact` remains the primary lifecycle operation. Pixir uses
`provider_usage` as the pressure gauge — the telemetry already exists per call, so
context pressure is read from durable local evidence:

- 0–70% of the model window: nothing.
- 70–80%: light status/advisory.
- 80–90%: visible warning suggesting `pixir compact --dry-run --json`, with structured
  next actions. Warnings carry hysteresis/cooldown ("already warned for this checkpoint
  range") — no per-turn spam.
- >90% ("critical"): the session is now eligible for two pragmatic, gauge-driven
  actions in addition to the classic post-overflow path:
  - *Preflight*: before the next user Turn's Provider call, if the most recent
    `provider_usage` was critical and no newer compaction has relieved the pressure,
    Pixir records a `history_compaction` (trigger `"critical_pressure_preflight"`) and
    proceeds with the compacted checkpoint + tail. A recovery-style ephemeral notice is
    emitted.
  - *Transport-triggered recovery*: if a low-level transport failure occurs (e.g.
    WebSocket "Could not read frame") while the last usage gauge was critical, Pixir
    treats it as near-overflow, compacts (trigger `"websocket_critical_recovery"`, same
    tail-shrinking), and retries. This is the case that previously stranded sessions
    when the backend died at the frame level instead of returning a clean
    `context_length_exceeded`.

All automatic actions remain *deliberate and visible*: they append a canonical
`history_compaction` Event (with clear `trigger`) and surface a `context_pressure`
notice with `tier: "recovery"`. The full Log is never rewritten silently.

Silent threshold auto-compaction (outside the explicit preflight/WS-critical and
overflow paths) is not adopted. It may become right for fleets and unattended runs, but
only behind an explicit future policy (e.g. `compaction: auto`), because it would change
the contract from "compaction is a deliberate lifecycle event" to "the harness silently
rewrites replay shape."

The key evolution from the original 0020 decision: `critical` is no longer purely
advisory when the gauge shows we are one Turn (or one socket frame) from breaking a long
session. The local evidence in `provider_usage` is now actionable for preemptive and
transport-resilient recovery while still requiring an explicit checkpoint Event.

## Consequences

- One labeled fleet-wide cache restart replaces three unlabeled ones; the px2 segment
  and `provider_usage` labels make the break visible in evidence rather than inferred.
- After re-layering, Sessions in different workspaces share the global Layer 0 bytes;
  the key carries all traffic discrimination, which the fork-family fix and version
  segment are sized for.
- Forks finally get the warm shared prefix CONTEXT.md's Fork entry promised.
- The model starts reading AGENTS.md on demand (it is currently never told repo
  instructions exist) — a visible behavior change, intended, but it will spend tool
  calls on instruction discovery.
- The token bleed from replaying every historical SKILL.md body ends at the first
  compaction; the cost is that long-governing practices must be re-activated after a
  checkpoint.
- Threshold numbers (70/80/90) are a starting shape, not measured values; tuning happens
  against `provider_usage` evidence.

## Non-goals

- Do not adopt provider-native compaction (`/responses/compact`, `compact_threshold`) in
  this slice. Parked in design note 0002 pending the production WebSocket transport; the
  leading seam candidate is the ADR 0007 analogy (store the `cmp_` item verbatim,
  model-guarded, fall back to the local checkpoint text).
- Do not introduce Pinned Skills.
- Do not auto-compact silently at a pressure threshold (outside the deliberate preflight and websocket-critical-transport recovery paths documented above).
- Do not implement fork UX in this slice; the fork-family key fix only removes the
  routing obstacle.
- Do not mix the px2 migration with WebSocket continuation changes in one PR or one
  observability window.

## Verification Direction

The minimal contract is:

```bash
mix test test/pixir/provider_test.exs
mix test test/pixir/turn_test.exs
mix test test/pixir/compaction_test.exs
mix test
mix pixir.smoke.prompt_cache --dry-run --json
mix check
```

Regression coverage should prove:

- Layer 0 instructions are byte-identical across workspaces; workspace path and mode
  arrive as late developer context.
- The discovery rule and checkpoint-interpretation contract are present and stable.
- The cache key carries the current prompt-contract version segment; fork children produce the same `s_`
  segment as their fork-tree root; all components remain bounded and non-PII.
- `provider_usage` records the prompt-contract version.
- Checkpoint limitations include the compacted-skill-activation statement when
  `skill_activation` Events fall inside the compacted range.
- Advisory warnings respect hysteresis; overflow-recovery compactions record
  `trigger: "overflow_recovery"`.
- The comparative smoke can attribute cache movement to PR A vs PR B.

## References

- Design note 0002: context compaction vs summarization (provenance, rejected
  alternatives, external-source verification, parked provider-native question).
- ADR 0003: stateless Turns; local Log is source of truth.
- ADR 0007: encrypted reasoning items — the opaque-item replay pattern.
- ADR 0018: durable History compaction and replay repair.
- ADR 0019: provider usage, prompt-cache observability, WebSocket continuation.
- CONTEXT.md: Prompt Contract, Summary, Compaction, Cache-Key Family, Fork, Skill
  Activation, Provider Usage, WebSocket Continuation.
- OpenAI prompt caching: https://developers.openai.com/api/docs/guides/prompt-caching
- OpenAI compaction: https://developers.openai.com/api/docs/guides/compaction
