# 40. Native OpenAI compaction is an opt-in replay window on history_compaction

Date: 2026-08-16
Status: Accepted
Implementation status: Implemented for store/validate/inspect (B), standalone
capture (C), and threshold capture (D), with the 2026-08-17 host split:
`chatgpt_codex` overlay-on Turns send `compact_threshold`; standalone C stays
local on that Codex `/compact` 404 host. Official `POST /responses/compact`
is only `https://api.openai.com/v1/responses/compact` after overlay-on.
Amended 2026-08-16 (overlay): native compact is one default-on overlay after
OpenAI Responses resolve — see "Amendment (2026-08-16, overlay)" below.
Amended 2026-08-17 (host split): C and D are not one boolean — see
"Amendment (2026-08-17, host split)" below.
Amended 2026-08-17 (product threshold): overlay-on ordinary Turns send
product N 200000; 1000 is the OpenAI API floor only — see
"Amendment (2026-08-17, product threshold)" below.

## Context

Pixir already compact History locally. ADR 0018 records a canonical
`history_compaction` Event: a scoped, inspectable checkpoint plus a recent raw tail.
ADR 0020 made compaction a deliberate lifecycle policy (manual first; advisory
pressure; visible preflight and overflow recovery) and parked provider-native
compaction as a non-goal. `Pixir.Compaction` still writes
`deterministic_operational_summary_v1` or optional `model_assisted` text. Provider
replay folds that checkpoint as a single user-role text item. The runtime does not
call `POST /responses/compact` and does not send `context_management.compact_threshold`.

ACP `/compact` (#521, #529) made that parked seam more visible. It is a Presenter
request into the existing local compact path, not a reason to close epic #512 or to
treat native compact as an editor feature. The Presenter asks; the runtime is truth;
the local Log remains the audit trail.

OpenAI Responses now documents two different native contracts
([compaction guide](https://developers.openai.com/api/docs/guides/compaction),
[compact endpoint](https://developers.openai.com/api/reference/resources/responses/methods/compact/)):

```text
compact_threshold (server-side, per-request opt-in)
- context_management: [{type: "compaction", compact_threshold: N}], minimum 1000
- the create stream may emit an opaque compaction item (id cmp_, type compaction,
  encrypted_content)
- for stateless input-array chaining, append output items as usual
- after append, items before the most recent compaction item may be dropped;
  the latest compaction item carries the context needed to continue
- previous_response_id chaining must not be hand-pruned

POST /responses/compact (standalone, explicit)
- request: model plus the full prior item window (must still fit the model window)
- response object is response.compaction
- output is a compacted window: retained items plus one compaction item
- "do not prune /responses/compact output... pass it into your next /responses
  call as-is"
- billed; compaction consumes reasoning tokens
- store: false / ZDR friendly: state travels in-band as encrypted_content
```

Those are not the same replay contract. "Save only `cmp_`" is a legal latency tip
for the threshold path and is incorrect for the standalone path, whose returned
window is the canonical next prefix and may include retained verbatim items besides
`cmp_`. Design note 0002 recorded the ADR 0007 analogy (store `cmp_` verbatim,
model-guarded, fall back to local text) as a leading seam candidate and left the
unpruned-window collision with Pixir's Log fold unlocked.

Three further facts constrain the decision:

- Overflow recovery cannot depend on `/responses/compact`. The standalone endpoint
  requires the window you send to still fit the model. A Session that already
  overflowed cannot honestly use that call as its only recovery.
- `open_responses` already treats a `compaction` output item as a non-portable
  OpenAI-shaped item. Native compact is a dialect feature, not a portable
  Responses subset.
- ADR 0024 fork copy currently excludes `history_compaction` because parent
  checkpoint ranges do not survive child renumbering. A native blob is even less
  seq-portable than a local text checkpoint.

## Decision

Pixir adopts native OpenAI compaction as an **opt-in replay aid** on the existing
`history_compaction` Event. Local compact remains the default lifecycle operation.
Native compact must not silently replace it.

**1. Same canonical Event, not a new type.**

Do not add `provider_compaction` or any sibling canonical type. Compaction is one
lifecycle fact: a scoped prefix of the Log will be projected differently on future
Provider calls. Strategy (deterministic text, model-assisted text, native window)
is payload, not a second kind of Event.

A new type would create two "latest checkpoint" sources, split
`Pixir.Compaction.provider_history/1`, and force fork/resume/ACP/`pixir compact`
to learn a second schema. ADR 0004 already treats a new canonical type as a Log
schema change; this change does not need one. Model-assisted compact already
shares `history_compaction` with a different `strategy`. Native compact follows
that pattern.

ADR 0018's Event, range, tail, limitations, and "full Log remains truth" rules
stand. This ADR only grows `data` with an optional native replay object.

**2. Persist the exact replay window the next request must send, plus local text
as fallback.**

Do not assume one stored shape for both OpenAI modes. The common representation is
the **native replay window**: the verbatim Provider item list that a later OpenAI
Responses call must send as the compacted prefix.

```text
history_compaction.data.native_replay (optional, string keys)
- mode: "standalone_window" | "threshold_item"
- provider: "openai_responses"
- backend: resolved backend id (for example chatgpt_codex)
- dialect: the request dialect that produced the blob
- model: capturing model id
- items: verbatim output items that must be replayed as-is
- compaction_item_ids: ["cmp_..."] (ids only; ciphertext stays inside items)
- recorded_usable: true | false
```

Mode contracts:

- `threshold_item`: `items` is the latest compaction item from that stream
  (`type` `compaction`, `id` `cmp_…`, `encrypted_content` present). OpenAI's
  latency tip allows dropping earlier conversation items once that item exists.
  Same-turn output that arrives after the item is ordinary tail History, not part
  of the window.
- `standalone_window`: `items` is the **entire** `/responses/compact` `output`
  array, unpruned. Retained messages or tool items stay in the window even when a
  `cmp_` is also present. Pixir must not reduce this array to the compaction item
  alone.

The Event always also carries the existing local checkpoint fields (`range`,
`strategy`, `summary`, `limitations`, skill-activation limitation, pointers).
Those fields are the human-readable audit and the fallback projection. They are
not sent to the Provider while `native_replay` is usable.

Replay, after the usual `provider_history/1` split (latest checkpoint + Events
after `to_seq`):

```text
if native_replay is present
   and recorded_usable
   and current Provider, backend, dialect, and model all match the capturing
       values
   and the window still validates (compaction item present; standalone window
       unpruned; no unpaired function_call left open inside the window):
  send native_replay.items as the compacted prefix
  then fold the raw tail Events
else:
  send the local text checkpoint as today
  then fold the raw tail Events
```

Never send both the native window and the local text checkpoint in the same
prefix. The text is fallback and diagnostics, not a second summary stacked on
`cmp_`.

Standalone compact sends only the compactable prefix (the same split
`pixir compact --tail-events` already uses). The returned window replaces that
prefix. The withheld tail stays raw Events after `to_seq`. Appending the tail
after an unpruned window is not pruning the compact output; it is continuing the
conversation with turns that were never sent to `/responses/compact`.

A window is unusable, and must fall back, when any of these hold: missing or
empty `encrypted_content`; missing `cmp_` item; standalone `items` was pruned or
is not a list; model, Provider, backend, or dialect mismatch; the blob is
malformed; the backend rejects it; or the window contains a `function_call`
without a matching output item in the same window. Conservative rejection is
correct: a 400 from a stale opaque item is worse than a lossy local summary.

**3. Guards are late-bound: Provider, backend, dialect, then model.**

Native compact is an OpenAI Responses dialect feature. It is off unless every
guard passes.

| Surface | Native compact |
| --- | --- |
| OpenAI Responses, `chatgpt_codex` or OpenAI API-key | allowed only when that backend/dialect has accepted the field or endpoint, and the capturing model matches |
| OpenAI Responses, `open_responses` | refused; `compaction` items are already non-portable |
| Anthropic | refused; local compact only |
| Model change, including fork-to-other-model | drop the native window; use local text |

Treat `compact_threshold` and `/responses/compact` as independently gated dialect
features. Support for one does not imply support for the other. A 400 or
unsupported-field rejection records structured evidence and does not retry every
Turn (hysteresis on the same checkpoint range). Absence of an operator preference
is not "on for every backend." Do not bake a global native-compact default into
configuration before Provider and backend are resolved.

`store: false` stays. Native compact does not move Session truth onto the
Provider.

**4. Fallback to the local checkpoint is mandatory, never optional.**

Every native attempt writes or keeps a local text checkpoint in the same Event.
If the native call fails, times out, returns an unusable blob, or later becomes
unreplayable, Pixir uses that local checkpoint. This matches today's
model-assisted fallback: a failed richer strategy still leaves a deterministic
checkpoint.

Recovery paths must not wait on a native blob. If native capture fails during an
opt-in threshold Turn, the Turn still records a local `history_compaction` with
`native_replay.recorded_usable` false and a reason, then continues with local
replay.

Do not persist `previous_response_id`, socket identity, or other live connection
state inside the checkpoint. Those remain connection-local (ADR 0019).

**5. Native compact is the same triple lifecycle event as local compact.**

A recorded `history_compaction` still:

- resets WebSocket continuation for the **next** Turn (`previous_response_id`
  from a pre-checkpoint response is not reused);
- breaks the transcript portion of the prompt-cache prefix;
- leaves the Cache-Key Family unchanged.

A mid-Turn `compact_threshold` item may continue inference on the current
Response. That does not license storing that Response id, and it does not license
continuing from it after the Turn ends or the socket drops. Resume always folds
the Log.

Fork (ADR 0024) keeps excluding `history_compaction`. Native windows therefore
do not copy into a child Log. The child receives the raw copied prefix and, if it
needs a bound, runs its own compact. A future fork-rewrite slice must not
transplant a parent `cmp_` window across remapped seqs; the window is
Provider-shaped, not seq-shaped. Model-guarded drop still applies if a later
slice ever copies one.

Compacted Skill Activations stay as ADR 0020 decided: bodies inside the compacted
range are not replayed unless they remain in the raw tail or are re-activated.
Pixir does not claim that `cmp_` retained those Skill bodies. The checkpoint
still records the compacted-skill limitation. When the native window is usable,
`skill_activation` Events at or before `to_seq` stay out of the fold.

Orphan tool-call repair stays Log-first (ADR 0018). Session reconciliation runs
on Events, not on opaque window items. Before recording a native checkpoint,
pending Log orphans are repaired as they are today. The native window is never a
reason to skip that repair. If a standalone window itself contains an unpaired
`function_call`, the window is unusable and local text wins.

**6. What may trigger each mode.**

| Trigger | Local compact | Native standalone `/responses/compact` | Native `compact_threshold` |
| --- | --- | --- | --- |
| Explicit `pixir compact` / ACP `/compact` | default | opt-in only (explicit flag or resolved preference) | not this command |
| `overflow_recovery` | required default | forbidden as the recovery mechanism (the overflowing window cannot be sent) | not a recovery switch |
| `critical_pressure_preflight` | required default | not in this ADR | not in this ADR |
| `websocket_critical_recovery` | required default | not in this ADR | not in this ADR |
| Per-request `compact_threshold` | still recorded if a native item arrives and local fallback is written | n/a | opt-in only; never an absence-of-override default |

Silent threshold auto-compaction remains rejected (ADR 0020). Enabling
`compact_threshold` is an explicit operator/runtime preference, and when it
fires it still appends a visible `history_compaction` with a clear `trigger`
(for example `native_threshold`) plus a `context_pressure` notice. The harness
does not rewrite replay shape without a canonical Event.

ACP `/compact` stays a Presenter parse of a runtime command. It does not become
a Skill, a free model Tool, or a silent native call. A later slice may expose an
opt-in native preference through ordinary config/CLI surfaces; this ADR does not
invent a second compact product.

**7. Cost and evidence live in `provider_usage`, not in replay.**

Standalone `/responses/compact` is a Provider call. It records its own
`provider_usage` Event with a distinct call role such as `compaction`. The Event
carries ordinary token/cache fields (input, output, reasoning, cached tokens,
prompt-contract version, cache-key family) plus bounded compact evidence: mode,
whether a usable window was recorded, compaction item ids, and fallback reason
when the blob was rejected. Ciphertext and raw item bodies do not belong in
usage.

A `compact_threshold` item arrives on an ordinary Turn stream. That Turn's
`provider_usage` records bounded evidence that a threshold compact fired (mode,
threshold, item ids, usable/fallback). It does not invent a second usage Event
unless a later implementation has a truly separate compact call.

`provider_usage` remains audit evidence and is never folded into model input
(ADR 0019). Prompt-cache claims still require observed `cached_tokens`. Native
compact is expected to miss the transcript prefix on the first post-checkpoint
call; that miss is the triple-lifecycle cost, not a regression by itself.

**8. The full local Log remains the auditable truth.**

Compaction never deletes, rewrites, or garbage-collects old Events. Native
windows are additional `data` on an append-only checkpoint. Resume, fork, doctor,
tree, and Monitor projections can still read the original Events. A `cmp_` blob
is a replay aid for one model and dialect, not a replacement Log, not Provider
memory, and not a Presenter cache.

Diagnostics and CLI output may show compaction item ids, mode, usability, and
the local summary. They must not print `encrypted_content`.

## Consequences

- Local compact stays the product default. Native compact is a guarded overlay
  with an honest fallback, not a new source of truth.
- The two OpenAI contracts keep distinct persisted windows, so a future
  implementer cannot "just save `cmp_`" for `/responses/compact`.
- Overflow and transport recovery remain possible when the Provider window no
  longer fits or the native blob is stale.
- `open_responses` and Anthropic Sessions keep today's local checkpoint behavior.
- Fork children do not inherit parent native windows; they compact themselves if
  needed.
- First post-native-compact calls pay a prompt-cache transcript miss, same as
  local compact. The cache-key family is unchanged.
- Later #522 slices can implement capture, fold, guards, and usage without
  reopening the Event-type or "Log is truth" questions.

## Non-goals

- Do not implement native compact in this slice (#522-B/C/D stay closed here).
- Do not add a new canonical Event type.
- Do not make native compact the default for `pixir compact`, ACP `/compact`,
  preflight, or overflow recovery.
- Do not enable `compact_threshold` by absence of override.
- Do not close issue #512 or issue #522.
- Do not mix #515, #516, #517, #520, or #523.
- Do not adopt Anthropic-native compaction, Pinned Skills, or silent
  `compaction: auto`.
- Do not persist `previous_response_id` in checkpoints.
- Do not prune `/responses/compact` output down to `cmp_` alone.
- Do not print or log compaction ciphertext.

## Verification Direction

This slice is documentation. Later implementation slices should prove the
contract with ExUnit seams (no live network in ordinary CI):

```bash
mix test test/pixir/compaction_test.exs
mix test test/pixir/provider_test.exs
mix test test/pixir/turn_test.exs
mix test test/pixir/event_test.exs
mix test
mix check
```

Regression coverage should prove:

- `history_compaction` remains the only compaction Event type; `native_replay`
  is optional string-keyed data.
- Standalone mode persists the full compact `output` list; threshold mode
  persists the compaction item; "save only `cmp_`" is rejected for standalone.
- Model, Provider, backend, or dialect mismatch drops the native window and
  folds local text.
- Unusable blobs (missing ciphertext, pruned standalone window, unpaired
  function call in the window) fold local text and record a fallback reason.
- Overflow, `critical_pressure_preflight`, and `websocket_critical_recovery`
  still write local checkpoints and do not call `/responses/compact` or use
  threshold as recovery.
- After OpenAI Responses resolve to `chatgpt_codex` or official
  `api.openai.com`, the overlay is default-on (absence of override is on;
  explicit `false` wins). Overlay-on ordinary Turns send `compact_threshold`.
  Overlay-on explicit compact POSTs `/responses/compact` only on the official
  host; on `chatgpt_codex` it stays local. Other `open_responses` vendors and
  Anthropic refuse the overlay.
- A recorded native or local checkpoint resets `previous_response_id` for the
  next Turn and does not store that id.
- Compacted `skill_activation` Events stay out of replay; the limitation is
  still recorded.
- Orphan `tool_call` repair still runs on the Log before the next Turn.
- Standalone compact records `provider_usage` with role `compaction`; threshold
  evidence rides the Turn usage Event; neither is replayed as model context.
- The compacted prefix Events remain in the Log.

File-level PR sequence, mid-turn timing, and ExUnit case list for slices
B/C/D: design note 0004 (2026-08-16, overlay amendment). That note implements
this Decision plus the overlay amendment; it does not rewrite the historical
Decision text.

## Amendment (2026-08-16, overlay)

The Decision above still stands for: one canonical `history_compaction` Event;
distinct `threshold_item` vs `standalone_window` persist shapes; mandatory
local-text fallback; late-bound Provider/backend/dialect/model guards;
`store: false`; Log as truth; fork exclusion; unrestored Skill Activations;
Log-first orphan repair; triple lifecycle; `provider_usage` evidence; no
ciphertext in usage or diagnostics; ACP `/compact` as a Presenter parse.

This amendment changes the **product default** after Provider/backend resolve.
It lifts two earlier rules:

- default `pixir compact` / ACP `/compact` stay local
- `compact_threshold` is never an absence-of-override default

Native OpenAI compaction is **one overlay**, not two features.

After Provider/backend resolve to OpenAI Responses on `chatgpt_codex` or
API-key OpenAI, the overlay is **default-on**. Absence of an override is on.
Explicit `false` always wins. The default is decided after resolve, the same
late-bound pattern as hosted `web_search` (ADR 0022 / #523). Do not bake the
default on before the request has a Provider and backend.

| Resolved Provider / backend | Absence of override |
| --- | --- |
| OpenAI Responses, `chatgpt_codex` or API-key OpenAI | overlay on |
| OpenAI Responses, `open_responses` | refused (compaction items are non-portable) |
| Anthropic | local-only |

When the overlay is on:

- explicit `pixir compact` / ACP `/compact` use `POST /responses/compact`
- ordinary Turns send `compact_threshold`
- every fire still writes a visible `history_compaction` (plus
  `context_pressure` for threshold)

Overflow recovery, `critical_pressure_preflight`, and
`websocket_critical_recovery` stay **local** even when the overlay is on. The
overflowing window cannot be sent to `/responses/compact`, and recovery is not
threshold.

One off switch. Do not invent two flags or a second compact product. Persist
shapes stay distinct: `threshold_item` is the latest `cmp_` only;
`standalone_window` is the full unpruned `/responses/compact` `output`. Do not
"just save `cmp_`" for standalone.

B still locks store/validate/inspect without changing live Provider input.
After B, C and D remain serial capture-mode PRs that share the one overlay
preference. Product is unified; persist contracts and mid-turn timing stay
split.

This amendment does not implement native compact and leaves #512 and #522
open.

## Amendment (2026-08-17, host split)

The overlay remains one preference. Capture modes are independently gated
by host:

- `chatgpt_codex` (ChatGPT Codex Responses at
  `https://chatgpt.com/backend-api/codex/responses`): overlay-on ordinary
  Turns send `compact_threshold` (D). Standalone C stays local — the same
  local checkpoint as overlay-off compact. That host's `/compact` 404s.
  Do not invent another Codex compact URL. Do not route C through
  `api.openai.com` with a ChatGPT subscription cookie.
- Official Responses (`https://api.openai.com/v1/responses`): overlay-on
  may POST `/responses/compact` (C) and send `compact_threshold` (D).
  This is the documented compact route, not a third backend mode.
- Other `open_responses` vendors and Anthropic: overlay off; local only.

A 404 or transport failure on an attempted standalone call records
`fallback_reason` `http_404` or `transport`, not `malformed_native_replay`.
Do not persist a usable `standalone_window` for those failures. Local text
stays mandatory.

## Amendment (2026-08-17, product threshold)

The overlay, host split, and one-switch rules above still stand. This
amendment only names the `compact_threshold` integer sent on overlay-on
ordinary Turns.

OpenAI documents `compact_threshold` with a **minimum of 1000**. That is
the API validation floor (the field is rejected below 1000). It is not
Pixir's product threshold. Sending 1000 on every overlay-on Turn makes
native D fire on almost every non-trivial Turn and fights local compact.

Product rules (2026-08-17):

- Overlay-on ordinary Turns send **product N = 200000**.
- 1000 remains the API floor only. A future override may pass 1000; it
  must not send below 1000. The default sent N is 200000.
- ChatGPT-sub theoretical input ceiling is 272000 (built-in table for
  gpt-5.5 / 5.4 / 5.3-codex). The 1M API window is not exposed on sub;
  do not add a second N for it.
- Do not special-case `gpt-5.3-codex-spark` (128k). No per-SKU threshold
  table. One number.
- Native D should fire first (around advisory, ~70–74% of 272k). Local
  90% critical preflight / overflow / websocket recovery stay the
  backstop (~245k).
- Local `Compaction.compact/2` is not triggered by D. D is Codex
  mid-stream `cmp_`; Pixir still writes local text on the same
  `history_compaction`.
- One switch `compaction.native`; explicit false still wins.
- Standalone C is unchanged (official-host only; `chatgpt_codex` C stays
  local). Recovery triggers are unchanged. No config key for N.

`Pixir.Compaction.compact_threshold/0` returns the product N because
Provider already uses it as the value put on the request.
`Pixir.Compaction.compact_threshold_minimum/0` is the API floor used
only to validate the field.

This amendment does not close issue #512 or issue #522.

## References

- Issue #522 (Part of / Addresses #522-A). Parent epic #512 is presenter
  surface; this is parked Provider work that `/compact` made visible.
- Design note 0004 (2026-08-16): #522-B/C/D implementation plan, including
  the overlay amendment. Does not rewrite the historical Decision text.
- ADR 0022: hosted `web_search` late-bound default-on after resolve; the
  overlay copies that pattern.
- Design note 0002: context compaction vs summarization (parked native question).
- ADR 0003: stateless Turns; local Log is source of truth.
- ADR 0004: canonical vs ephemeral Events; new types are schema changes.
- ADR 0007: encrypted reasoning items stored verbatim, replayed opaque,
  model-guarded — the pattern native compact extends, not a "save only `cmp_`"
  shortcut for both OpenAI modes.
- ADR 0018: durable `history_compaction` and orphan tool-call repair.
- ADR 0019: `provider_usage`, prompt cache, WebSocket continuation.
- ADR 0020: prompt contract, cache-key family, local compaction triggers;
  historical non-goal that parked native compact.
- ADR 0024: fork copy excludes `history_compaction`.
- ADR 0037: Anthropic is a second Provider; native OpenAI items do not leak.
- CONTEXT.md: Compaction, Summary, Log, History, Provider Usage, Prompt Cache,
  Cache-Key Family, WebSocket Continuation, Skill Activation, Fork.
- OpenAI compaction: https://developers.openai.com/api/docs/guides/compaction
- OpenAI compact endpoint:
  https://developers.openai.com/api/reference/resources/responses/methods/compact/
