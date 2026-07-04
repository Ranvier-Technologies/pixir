# 7. Reasoning items are canonical and replayed; summary text stays ephemeral

Date: 2026-05-29
Status: Accepted

## Context

ADR 0004 classified reasoning as **ephemeral** (`reasoning_delta`, never persisted)
and froze the canonical set to `user_message, assistant_message, tool_call,
tool_result, permission_decision`. That conflated two different things that share the
word "reasoning":

- the **reasoning summary text** — human-facing, streamed for live display; and
- the **encrypted reasoning item** (`rs_…`, type `"reasoning"`, carrying
  `encrypted_content`) that the OpenAI Responses API emits on a tool turn and
  **requires re-injected as `input`** on subsequent turns, ahead of its paired
  `function_call` (`fc_…`).

Because Pixir is stateless (`store: false`, ADR 0003) and folds the Log into `input`
every Turn, an `rs_` that is never persisted is never threaded back. Today
`Pixir.Provider` requests `include: ["reasoning.encrypted_content"]` but discards the
item, keeping only ephemeral deltas. On long multi-tool turns this is the **biggest
correctness risk** (ROADMAP §C item 1): the model loses the reasoning chain it paid to
produce. The official docs are explicit that, with `store: false`, reasoning is carried
across turns *only* by re-sending these encrypted items (with `include` on every
request) and keeping them in order between the last user message and the tool outputs.

## Decision

The **encrypted reasoning item is canonical**; the **summary text stays ephemeral**.
This refines ADR 0004 rather than overturning it.

1. **New canonical event `reasoning`** — a sibling of `tool_call`, not a field on
   `assistant_message`/`tool_call` (a pure-tool turn has no final `assistant_message`
   to hang it on, and it maps 1:1 to the wire item per ADR 0004's thesis).
   `data: %{"item" => <raw SSE reasoning object, opaque>, "model" => <capturing model id>}`.
   The item — including `encrypted_content` and its `rs_` id — is stored verbatim and
   never interpreted (mirrors Pi's `JSON.stringify(item)`), so server-side schema drift
   round-trips. `reasoning_delta` remains ephemeral for live display.

2. **Ordering is owned by the Turn loop, via `seq`.** The Provider captures output
   items in **arrival order** (a single ordered stream of reasoning items + function
   calls, alongside the existing flat `reasoning_items`/`function_calls` lists). The
   Turn loop records `reasoning` and `tool_call` events in that order, so monotonic
   `seq` guarantees every `rs_` precedes its `fc_` *and* preserves any intra-turn
   interleaving — no extra plumbing, and the deferred "exact interleaving" question
   becomes a non-issue.

3. **Replay (`to_input_item/1`) re-injects the item verbatim, guarded by model.** A
   `reasoning` event whose stored `"model"` differs from the current request model is
   **dropped** — an encrypted item is only valid for the model that produced it
   (mirrors Pi's `isDifferentModel`). Dropping an `rs_` is always safe; replaying a
   stale one risks a 400. Pixir already sends **no** `fc_` ids on tool calls (only
   `call_id`), so the companion "null the `fc_` id when its `rs_` is dropped" step Pi
   needs is satisfied for free. `include: ["reasoning.encrypted_content"]` is re-sent on
   every request (already the case).

## Consequences

- **Log schema change** — exactly the deliberate curation ADR 0004 named ("adding a
  canonical type is a schema change to the Log"). Old logs (no `reasoning` events) fold
  unchanged; new logs carry them.
- **Drop, don't replay, on these conditions:** model mismatch (above); reasoning from
  errored / iteration-capped turns (a reasoning item with no following item is rejected
  — "reasoning without following item").
- **Not guarded:** `encrypted_content` staleness across `resume`/time. The docs state no
  expiry and treat encrypted content as *the* cross-turn mechanism; we add no
  speculative time-based drop. If the backend ever rejects a stale item, that is an
  empirical finding to handle in `classify_http_error` then.
- **Open follow-ups:** whether the API's `rs_`/`fc_` pairing check is positional or
  strictly id-based is unconfirmed (Pi relies on order + omitted ids); resolve via the
  live-verify harness if a batched replay is ever rejected. Strict per-pair `fc_` ids
  remain a deferred refinement.
