# 0002 - Context compaction vs summarization

Status: Investigation / grilled — resolved directions promoted to ADR 0020 (2026-06-09);
provider-native compaction remains parked here
Date: 2026-06-09

## Source Check

Verified against local Pixir language and code on 2026-06-09:

- `CONTEXT.md`: Log, History, Event, Provider, Skill Activation, Subagent, Workflow,
  Compaction, Cache-Key Family, Fork, WebSocket Continuation, Provider Usage.
- `docs/adr/0003`: stateless Turns, Log as source of truth.
- `docs/adr/0007`: encrypted reasoning items canonical, replayed verbatim, model-guarded.
- `docs/adr/0018`: `history_compaction` as durable checkpoint; deterministic first slice;
  model-assisted contract in code; orphan tool-call repair.
- `docs/adr/0019`: `provider_usage` Events; shipped `prompt_cache_key`; WebSocket-first
  transport direction.
- Code: `lib/pixir/turn.ex`, `lib/pixir/provider.ex`, `lib/pixir/compaction.ex`,
  `lib/pixir/provider/cache.ex`, `lib/pixir/skills.ex`, `lib/pixir/cli.ex`.

External sources independently re-read 2026-06-09 (corrections folded in below):

- [Manus: Context Engineering for AI Agents](https://manus.im/blog/Context-Engineering-for-AI-Agents-Lessons-from-Building-Manus)
- [LangChain: Context engineering](https://docs.langchain.com/oss/python/langchain/context-engineering)
- [LangChain: Deep Agents context engineering](https://docs.langchain.com/oss/python/deepagents/context-engineering)
- [OpenAI: Compaction](https://developers.openai.com/api/docs/guides/compaction)
- [OpenAI API reference: compact endpoint](https://developers.openai.com/api/reference/resources/responses/methods/compact/)
- [OpenAI: Reasoning summaries](https://developers.openai.com/api/docs/guides/reasoning)
- [OpenAI: Prompt caching](https://developers.openai.com/api/docs/guides/prompt-caching)

## Question

How should Pixir distinguish context compaction from context summarization, given that
Pixir already has a local append-only Log and folds that Log into OpenAI Responses input
on every Turn?

The practical question is not just naming. It affects:

- what gets persisted;
- what the model sees;
- what remains inspectable later;
- when prompt-cache prefixes are intentionally broken;
- whether a future Session can replay honestly from local state.

## Working Distinction

Summarization is a technique.

It produces a shorter representation of previous context. A summary can be written by a
human, a model, or deterministic code. It may be useful, but by itself it is not a new
source of truth in Pixir.

Compaction is a runtime operation.

It changes the representation of past context that will be sent to future Provider calls.
In Pixir, a compaction should be durable, auditable, explicitly scoped to a range of Log
Events, and clear about what was lost or retained.

Canonical vocabulary (now also in `CONTEXT.md` as **Summary** and **Prompt Contract**):

```text
summary
- a lossy human/model-readable artifact
- useful as context
- not the Log
- not automatically replay-authoritative
- in Pixir: at most a bounded field inside a history_compaction checkpoint

history_compaction
- a canonical Event in Pixir History (ADR 0018, shipped)
- covers a known Log range
- may contain a summary
- may contain retained excerpts, limitations, and pointers
- used by Provider replay as "checkpoint + recent tail"
- never deletes or replaces the full Log
```

A compaction checkpoint is a **triple lifecycle event**. By construction it:

1. forces a WebSocket-continuation reset (the new input is no longer a prefix extension,
   so `previous_response_id` reuse is off the table);
2. invalidates the transcript portion of the prompt-cache prefix (first post-compaction
   call pays a partial miss; only the static instructions/tools prefix survives);
3. is invisible to the **Cache-Key Family**, which names the request family, not the
   prefix bytes, and therefore survives the boundary.

Live connection state must never enter a checkpoint. A checkpoint that captured a
`response_id`, a Subagent PID, or an in-flight status would be poison after any presenter
or process restart (observed: the false `modelChanged` bug, where a presenter restarting
the provider session destroyed the live process holding `previous_response_id`).

## How Other Systems Frame It

### Manus

Corrected reading: Manus never uses summarization as a strategy at all. Its compression
is **restorable drop-with-pointer**: "the content of a web page can be dropped from the
context as long as the URL is preserved"; document contents can be omitted "if its path
remains available." The agent restores full content lazily by re-reading on demand. The
post explicitly warns that "any irreversible compression carries risk" because you cannot
"reliably predict which observation might become critical ten steps later."

So Manus supports the recoverability/path leg of this doc, not the inline-summary leg.
Other verified Manus mechanics relevant here: append-only context, stable prefixes
("even a single-token difference can invalidate the cache"), deterministic serialization,
mask-don't-remove for tools, recitation via rewritten `todo.md`, keep failures in
context.

Implication for Pixir:

- do not inject full `AGENTS.md` or large project documents by default;
- inject a stable rule telling the agent how to discover scoped instructions;
- keep durable pointers to the full Log, compacted checkpoint, or workspace files;
- prefer on-demand `read`/`bash` inspection for dynamic project context.

### LangChain / Deep Agents

Corrected reading: LangChain's `SummarizationMiddleware` is stronger (worse) than a
replay shape — it "Replaces them with a summary message in State (**permanently**)";
"future turns will see the summary instead of the original messages." No restore path is
documented. The word "compaction" never appears in their vocabulary.

Deep Agents adds calibration numbers and one important convergence:

- summarization triggers at **85% of the model window** (or immediately on a context
  overflow error), keeps **~10% of tokens** as recent context, with a 170k-trigger /
  6-messages-kept fallback;
- large tool results offload to the filesystem past a **20k-token threshold**, replaced
  by a path reference plus a first-10-lines preview;
- subagents return "a single final report"; the parent "receives only the final result,
  not the dozens of tool calls that produced it" (prompt guidance, not an enforced
  mechanism);
- crucially: "A text rendering of the original conversation messages is written to the
  filesystem as a canonical record" — the summarize-and-replace camp independently
  converged on keeping a recoverable original. That is the Log argument arrived at from
  the other direction.

Implication for Pixir:

- the "summary + tail" shape is useful;
- subagent terminal summaries are good replay units;
- live subagent status, PIDs, and partial progress stay out of compaction;
- Pixir preserves the full Log separately instead of overwriting state with the summary.

### OpenAI Responses

Verified endpoint facts (compaction guide + OpenAPI spec):

```text
POST /responses/compact
- request: model (required), input (the full prior item window)
- response: object "response.compaction" whose output contains retained items
  plus one compaction item:
  { "type": "compaction", "id": "cmp_...", "encrypted_content": "<ciphertext>" }
- "It is opaque and not intended to be human-interpretable."
- pass-forward is mandatory, not advisory: "do not prune /responses/compact output...
  pass it into your next /responses call as-is" — the whole returned window,
  which may include retained verbatim items
- billed: compaction consumes reasoning tokens
- ZDR/store:false friendly: state travels in-band as encrypted_content

Server-side alternative (per-request opt-in):
- context_management: [{"type": "compaction", "compact_threshold": N}], min 1000
- compacts mid-stream automatically; emits the compaction item in the same stream
- nothing auto-compacts without explicit opt-in, in either mode

reasoning summary (distinct thing)
- human-readable, opt-in (reasoning: {summary: ...}), explicitly not raw CoT
- no documented replay role; replay is carried by the reasoning item itself
  (encrypted_content), exactly as ADR 0007 models it
```

No documented interaction between compaction and prompt caching exists; the cache
consequence (transcript-prefix invalidation on the first post-compaction call) follows
from exact-prefix mechanics, not from quoted guidance.

The structural observation that matters for Pixir: the `cmp_` compaction item is a
sibling of the `rs_` encrypted reasoning item — opaque, model-bound, replay-critical,
store:false-friendly. Pixir already has a locked, live-verified pattern for exactly that
shape (ADR 0007: store verbatim, replay opaque, model-guarded drop).

## Current State (code-verified, 2026-06-09)

What ships today, against which every proposal below is measured:

- `instructions` = base prompt with the **workspace path in the first sentence**
  (`turn.ex`), then the Skills index (deterministic, 8k-char budget), then agent/role
  instructions. Tools sorted alphabetically. No AGENTS.md injection — and **no discovery
  rule either**: the model is never told repo instructions exist.
- `history_compaction` is shipped (ADR 0018): deterministic checkpoint with range,
  event counts, tool-call evidence, files touched, open-task excerpts, summary,
  limitations; folded into Provider input as a single `role: "user"` text item; replay =
  latest checkpoint + non-compaction Events after `to_seq`. `pixir compact` has
  `--dry-run`, `--json`, `--tail-events`. The model-assisted contract
  (`developer_instruction/0`, `output_schema/0`, `model_contract/3`) exists in code,
  un-networked.
- `prompt_cache_key` is shipped: originally `px1:m_<model>:r_<mode>:s_<hash>:t_<toolset>:
  k_<skill-index>` (ADR 0019), ≤96 bytes, no volatile facts. Real `cached_tokens` hits
  observed intra-session. An earlier draft of this note flagged `[CONTRADICTS]`: `s_`
  hashed the raw `session_id`, so a fork would get a cold bucket despite CONTEXT.md's
  Fork entry. **Resolved by the px2 migration (ADR 0020, implemented):** the key now
  leads with the prompt-contract version (`px2:`), `s_` hashes the fork-tree root
  (`fork_root_session_id`, default self), and `provider_usage` carries
  `prompt_contract_version`. A pinned-hash test couples the version constant to the
  stable prompt bytes.
- `skill_activation` Events replay **full SKILL.md bodies** into every subsequent
  Provider call, forever (token bleed). Inside a compacted range they vanish without
  even their names being recorded.
- Compaction is invisible to the cache key (correct per the triple-lifecycle framing).

## Prefix And Dynamic Payload Organization

Authority and cacheability are separate axes:

```text
developer message
- higher authority than user
- can still be dynamic and arrive late; authority is carried by role, not position

cacheable prefix
- identical early request bytes/tokens across turns
- can still be low-authority operational guidance
```

Target layering, byte-stability strictly decreasing with position:

```text
Layer 0: Global stable prefix (instructions)
- Pixir identity and runtime invariants
- AGENTS.md discovery rule, not AGENTS.md contents
- checkpoint-interpretation contract (one short rule: a history checkpoint in input is
  lossy prior context; recent tail and current request win)
- byte-identical for every Session in every Workspace

Layer 1: Project-stable surface (instructions, after Layer 0)
- Skills index (already deterministic, 8k budget)
- stable tool schemas, deterministic ordering

Layer 2: Late developer context (input, early)
- workspace path, branch, permission mode — moved OUT of the first sentence
- workspace confinement does not move: it is enforced by the tool layer, not the prompt

Layer 3: Compacted History
- latest history_compaction checkpoint
- recent raw tail after checkpoint.to_seq

Layer 4: Task context
- current request, one-off Skill body, current errors and tool outputs
```

(An earlier draft listed "session-pinned Skills" in Layer 2. Removed: **Pinned Skill is
deliberately undefined** — no such concept exists in code or glossary; see Skills section
below.)

The discovery rule replacing AGENTS.md injection:

```text
Projects may contain one or more AGENTS.md files. Before making or reviewing code
changes, inspect relevant instructions with read or bash. Start at the workspace root,
then read the nearest AGENTS.md files for directories you touch. In monorepos, local
instructions override broader ones for their subtree. Do not rely on stale remembered
instructions when the file can be read.
```

### Resolved: one batched, versioned prompt-contract migration

Every individual edit to `instructions` costs one full fleet-wide cache break (exact-
prefix matching: a change at position N invalidates everything after N; a first-sentence
change invalidates everything). Three separate "safe" changes = three unlabeled cold
restarts. Therefore:

```text
Batch the prefix re-layering into one explicit prompt-contract change and bump the key
to px2. The point is not to preserve warmth across this migration; the point is to make
the cache break intentional, measurable, and attributable.

The slice includes:
- stable discovery rule instead of injected AGENTS.md/project instructions;
- stable checkpoint/compaction interpretation contract;
- workspace path and branch moved late, outside the global cacheable prefix;
- deterministic skill-index/tool ordering;
- provider_usage labels showing prompt_contract_version = px2.

Expected signature: worse cache immediately after migration, better/stabler cache
behavior after the new prefix warms. The live smoke must also measure prompt-position
sensitivity (the model has anchored on a first-sentence workspace path since v0.1).
```

Sequencing constraint: do not mix with WebSocket continuation work in one PR.

```text
PR A: instrument/understand previous_response_id (transport)
PR B: prefix re-layering px2 (prompt contract)
then: comparative smoke via provider_usage
```

So if cache behavior moves, causality is attributable to transport continuation or
prompt contract — never ambiguously both.

## Cache Key (rewritten after grilling)

Routing mechanics that decide this design:

- A hit needs two independent conditions: **byte condition** (exact prefix match on
  request bytes; the key plays no role) and **placement condition** (the request lands on
  a machine with warm KV; routing hashes the initial ~256-token prefix **combined with**
  `prompt_cache_key`; past ~15 requests/min per (prefix, key) pair, traffic overflows to
  cold machines).
- Today the workspace path sits inside the routing window, so workspaces separate by
  bytes alone. **After re-layering, the first 256 tokens become byte-identical for every
  Pixir session everywhere** — byte discrimination drops to zero and the key becomes the
  only traffic separator. The re-layering makes the key MORE load-bearing, exactly when
  an earlier draft proposed making it broader.

`[CONTRADICTS]` An earlier draft proposed `pixir:runtime-v1:tools-base-v1` as the
"conservative first key." Rejected: post-re-layering, that key funnels every session of
every user into one (prefix, key) bucket with a ~15 rpm overflow ceiling; a single
subagent fleet saturates it alone, scattering the *large* per-session conversation
prefixes to cold machines in order to co-locate the *small* shared static prefix.
Broad families fit workloads of many short near-identical requests; Pixir's workload is
long sessions with sequential tool loops plus subagent bursts — the opposite.

Resolved contract: **the cache key discriminates by stable surfaces, not volatile
bytes.**

```text
keep   m_<model> r_<mode> t_<toolset> k_<skill-index>   (shipped px1 surfaces)
add    prefix-contract version segment (px1 -> px2 at the re-layering;
       bumped on every future prompt-contract change)
fix    s_ becomes a true fork family: hash of the fork-tree ROOT session,
       inherited across forks, so forks that share a stable prefix
       intentionally share warmth (delivers what CONTEXT.md's Fork entry
       and the component's own name already promised)
defer  project-hash segment until pinned Layer-1 project summaries exist;
       until then project instructions are discovered through tools,
       not injected
```

Branch name, live subagent statuses, current errors, and current tool results never
belong to the key. They can appear in the request, but late.

## Pixir Model

Pixir already has the right anchor: the Log is truth, Provider input is a projection.

Compaction is modeled as a canonical Event that changes future replay projection, not as
a hidden UI cache and not as a replacement for old Events.

Request shape after compaction:

```text
instructions
- stable Pixir runtime rules
- short rule for interpreting history_compaction checkpoints

tools
- stable or mode-aware tool profile

input
- latest history_compaction checkpoint
- uncompressed recent tail after checkpoint.to_seq
- current one-off skill/task context
- current user message
```

The checkpoint is older, lossy context. Recent raw tail and current user instructions
override stale checkpoint intent. The contract about checkpoints lives in instructions;
the concrete checkpoint lives as History — an old summary is never elevated to global
policy.

## Path, Summary, Or Both?

Three possible representations:

```text
path-only
- cheapest, cache-friendly
- weak continuity unless the model decides to read it
- (Manus-supported for archived context: drop content, keep the pointer)

inline summary
- strong continuity, costs tokens
- can become stale or over-authoritative if not labeled as lossy

inline checkpoint + path
- best default for long Sessions
- continuity and recoverability; model inspects full artifacts when needed
- (Deep Agents converged here independently: replace in-context, but write
  the original to the filesystem as a canonical record)
```

Resolved Pixir default (matches shipped ADR 0018 shape):

```text
history_compaction Event contains:
- compacted range
- bounded inline summary / structured checkpoint
- limitations
- pointer to full Log and checkpoint artifact
- recent tail remains raw
```

Path-only is for archived context, not normal session continuity.

## Resolved: Skill Activations Across Compaction

Skill Activation remains **per-Turn** (the glossary already takes this side: a Skill
Activation guides "a specific Turn"). Compaction may compact away old `skill_activation`
bodies, and Pixir does not pretend those practices remain active session-wide. This is
the explicit version of the current behavior, not the silent one:

```text
The checkpoint records it as a limitation: skills activated only inside the
compacted range are not replayed unless they remain in the recent raw tail or are
explicitly re-activated later.
```

This avoids the token bleed of replaying full SKILL.md bodies forever, avoids a
premature Pinned Skill concept, and preserves the glossary constraint. If long-lived
governing practices become a real user need, that is a separate design — Pinned Skills
or session-scoped practices, with explicit events and UX — not a rider on compaction.

## Resolved: Trigger Policy

Manual compaction remains the primary lifecycle operation, but Pixir uses
`provider_usage` as an advisory pressure gauge — the telemetry already exists per call
(ADR 0019), so context pressure is read from durable local evidence, with no token-
counting endpoint and no estimation.

```text
0-70% of model window   nothing
70-80%                  light status/advisory
80-90%                  visible warning + suggest `pixir compact --dry-run --json`,
                        with structured next actions
>90% or provider        recovery mode may compact, recorded as a canonical
overflow rejection      history_compaction Event with trigger: "overflow_recovery",
                        visible to the user
```

Advisory before failure, recovery after failure. Not silent rewriting.

- Auto-compaction does not fire silently at the threshold. At the overflow boundary the
  cache/continuation state is already lost, so the triple lifecycle cost of recovering
  is zero and refusing to act just strands the session.
- Full-auto (Deep Agents / Claude Code style, ~85% trigger) may be right someday for
  fleets and unattended runs, but only behind an explicit policy such as
  `compaction: auto` — it changes the contract from "compaction is a deliberate
  lifecycle event" to "the harness silently rewrites replay shape."
- The warning must not spam every turn: hysteresis/cooldown, or record "warning already
  shown for this checkpoint range."

## Parked: Provider-Native Compaction

Deferred pending the production WebSocket transport (ADR 0019, in progress). Nothing is
locked. What is recorded:

- The leading seam candidate is the ADR 0007 analogy: a future provider-native profile
  would store the `cmp_` item verbatim inside `history_compaction` Event data with the
  capturing model id, replay it opaque and model-guarded exactly like `rs_` reasoning
  items, and fall back to the local checkpoint text on model mismatch. One opaque-item
  rule, not two.
- Three IDs stay distinct and must never be conflated in this design: the presenter
  thread id (UI projection, e.g. a T3 thread), the Pixir `session_id` (canonical, owns
  the Log), and the OpenAI `response_id` (ephemeral continuation hint, connection-local,
  never durable truth).
- `prompt_cache_key` and `previous_response_id` interaffect but are different things:
  observed evidence shows a real `cached_tokens` hit while `used_previous_response_id`
  stayed false. The key survives transport fallback; the response id does not have to.
- The unpruned-window rule ("pass /responses/compact output as-is") collides with
  Pixir's fold unless provenance is pinned first — one more reason this waits for the
  transport to stabilize, since the seam will be shaped by how continuation resets are
  handled.

## Chemical / Cellular Cycle Analogy

The useful metaphor is not "delete old context." It is metabolism.

A coding agent continuously transforms raw events into usable energy for the next Turn:

```text
Raw Events
  -> folding
  -> working context
  -> tool/subagent work
  -> new Events
  -> compaction checkpoint
  -> bounded replay context
  -> next Turn
```

Like the Krebs cycle, compaction is not merely compression. It converts accumulated
material into a reusable intermediate form while preserving the system's ability to keep
running.

Like the cell cycle, compaction should have phases and checkpoints:

```text
Growth
- normal Turns append Events
- History grows as raw material

Checkpoint
- detect context pressure (provider_usage gauge), orphan tool calls, long tails,
  or user-requested compact

Synthesis
- produce deterministic or model-assisted compaction
- preserve decisions, evidence, limitations, and pointers

Division
- future Provider input splits into compacted older History + raw recent tail

Repair
- reconcile orphan tool calls before replay
- record visible fallback tool_result Events when needed (shipped, ADR 0018)
```

This metaphor avoids two bad designs:

- garbage-collection framing, where old context simply disappears;
- memory-magic framing, where an opaque summary becomes unquestioned truth.

The better framing is context metabolism:

```text
The full Log is the organism's record.
The current prompt is working memory.
Compaction is a metabolic checkpoint.
Summaries are nutrients, not organs.
```

## Design Principles For Pixir

1. Keep the Log authoritative.
2. Make compaction canonical, scoped, and inspectable.
3. Treat summaries as lossy fields inside compaction, not as truth.
4. Preserve recent raw tail after every checkpoint.
5. Include limitations directly in the checkpoint — including which skill activations
   were compacted away.
6. Keep dynamic project instructions discoverable by tools, not injected by default.
7. Use paths and hashes for recoverability and invalidation.
8. Keep provider-native opaque compaction separate from human-readable summaries.
9. Compact terminal subagent/workflow outcomes, not live process state.
10. A compaction boundary is a triple lifecycle event — continuation reset, intentional
    cache-prefix break, key family preserved. Treat all three as deliberate.
11. The prompt contract is versioned. All prefix-layout changes ride one batched,
    labeled break; `provider_usage` carries the contract version so breaks are
    attributable in evidence, never inferred.

## Open Questions

Resolved 2026-06-09 (recorded above, promoted as ADR 0020):

- ~~Cache key shape~~ → stable-surface key: px2 version segment, fork-root family,
  minimal/global key rejected, project-hash deferred.
- ~~Pinned Skills vs skill_activation replay~~ → per-Turn stands; compacted activations
  recorded as an explicit checkpoint limitation; Pinned Skills is a separate future
  design.
- ~~Prefix re-layering scope~~ → one batched px2 migration, sequenced after
  `previous_response_id` instrumentation, comparative smoke between.
- ~~Cache evidence at boundaries~~ → `provider_usage` labels carry
  `prompt_contract_version`; overflow-recovery compactions carry
  `trigger: "overflow_recovery"`.
- ~~Trigger policy~~ → advisory gauge + overflow recovery; full-auto only behind a
  future explicit `compaction: auto` policy.

Still open:

- Provider-native compaction adoption (parked; revisit when the production WebSocket
  transport lands; seam candidate = ADR 0007 analogy).
- Should model-assisted compaction use a small tool/schema-only request with no normal
  coding tools exposed? (Leaning yes — ADR 0018's `model_contract/3` already shapes
  this — but unexercised until the networked pass exists.)
- Should a future `pixir compact inspect <checkpoint-id> --json` expose both the inline
  checkpoint and pointers to the compacted Log range? (No inspect subcommand exists
  today.)
- Exact advisory thresholds and hysteresis tuning (the 70/80/90 tiers are a starting
  shape, not measured numbers).
- Whether subagent Sessions should share the parent's fork-family key segment (their
  role prompts diverge inside the routing window, so co-location likely buys nothing —
  needs measurement, not assumption).
