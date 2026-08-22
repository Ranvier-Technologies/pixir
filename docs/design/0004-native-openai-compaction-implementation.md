# 0004 - Native OpenAI compaction implementation plan (#522-B/C/D)

Date: 2026-08-16

Status: Implementation plan (implements ADR 0040 including the 2026-08-16
overlay amendment and the 2026-08-17 product-threshold amendment; does
not rewrite the historical Decision text)

Related: ADR 0040, ADR 0018, ADR 0019, ADR 0020, ADR 0022, ADR 0024,
issue #522 (slices B/C/D). Parent epic #512 is presenter surface and stays
open.

## Source Check

Verified against local Pixir language and code on 2026-08-16:

- ADR 0040 (Accepted, `fde8adb` / #531) plus overlay amendment (this branch):
  product contract this plan implements.
- ADR 0018 amendment (2026-08-16): optional `native_replay` payload; Event type
  unchanged.
- ADR 0020 amendments (2026-08-16): native-compact park lifted; overlay
  default recorded by pointer to ADR 0040.
- ADR 0022: hosted `web_search` late-bound default after Provider/backend
  resolve; explicit `false` always wins. Overlay follows that pattern.
- Design note 0002: parked native question; historical "store only `cmp_`" text
  is not the accepted standalone contract.
- Code: `lib/pixir/compaction.ex`, `lib/pixir/event.ex`, `lib/pixir/provider.ex`,
  `lib/pixir/providers/anthropic.ex`, `lib/pixir/turn.ex`, `lib/pixir/cli.ex`,
  `lib/pixir/acp/server.ex`, `lib/pixir/fork.ex`.
- Tests (seams only; this note does not add them): `test/pixir/compaction_test.exs`,
  `test/pixir/provider_test.exs`, `test/pixir/turn_test.exs`,
  `test/pixir/event_test.exs`, `test/pixir/acp/server_test.exs`,
  `test/pixir/fork_test.exs`.

This note is documentation. It does not implement native compact, does not add
Elixir or tests, and leaves #512 and #522 open.

## Product: one overlay

Native OpenAI compaction is **one overlay**, not two features. Product
decision 2026-08-16 (Bastian). Lock this; do not reopen it.

After Provider/backend resolve to OpenAI Responses on `chatgpt_codex` or
the official `api.openai.com` Responses host, the overlay is **default-on**.
Absence of an override is on. Explicit `false` always wins. Other
`open_responses` vendors refuse the overlay (compaction items are
non-portable). Anthropic stays local-only. "API-key OpenAI" here is that
official host, not a third backend mode.

When the overlay is on:

- explicit `pixir compact` / ACP `/compact` use `POST /responses/compact`
  only on the official `api.openai.com` host (slice C). On `chatgpt_codex`
  they stay local — Codex `/compact` 404s.
- ordinary Turns send `compact_threshold` (slice D capture mode), including
  on `chatgpt_codex`
- every fire still writes a visible `history_compaction` (plus
  `context_pressure` for threshold)

Overflow recovery, `critical_pressure_preflight`, and
`websocket_critical_recovery` stay **local** even when the overlay is on.

One off switch. Do not invent two flags or a second compact product.

### Product N (2026-08-17)

Overlay-on ordinary Turns send `compact_threshold: 200000`. That is the
product N, not OpenAI's documented minimum.

- **200000** is the value `Pixir.Compaction.compact_threshold/0` returns
  and Provider puts on overlay-on ordinary Turn requests.
- **1000** is the OpenAI API floor only
  (`Pixir.Compaction.compact_threshold_minimum/0`). Values below 1000
  are invalid; 1000 remains legal if passed explicitly.
- **272000** is the ChatGPT-sub theoretical input ceiling used to choose
  N (built-in table for gpt-5.5 / 5.4 / 5.3-codex). Native D should fire
  first around advisory (~70–74% of 272k). Local 90% critical preflight /
  overflow / websocket recovery stay the backstop (~245k). The 1M API
  window is not exposed on sub; do not add a second N for it.
- Do not special-case `gpt-5.3-codex-spark` (128k). No per-SKU threshold
  table. One number.
- Local `Compaction.compact/2` is not triggered by D. D is Codex
  mid-stream `cmp_`; Pixir still writes local text on the same
  `history_compaction`.
- One switch `compaction.native`; explicit false still wins. No config
  key for N.

Standalone C is unchanged (official-host only; `chatgpt_codex` C stays
local). Recovery triggers are unchanged.

Persist shapes stay distinct:

| Mode | Persist shape | Legal "save only `cmp_`" |
| --- | --- | --- |
| `threshold_item` | latest `cmp_` compaction item only | legal |
| `standalone_window` | entire unpruned `/responses/compact` `output` array | illegal |
| `compact_threshold` (request field) | not a persist shape; D's trigger that *produces* a `threshold_item` | n/a |

Do not unify those persist shapes. A helper that "just saves `cmp_`" is correct
for threshold ingest and a contract bug for standalone.

B is unchanged in spirit: first implementation PR still locks
store/validate/inspect and does **not** change live Provider input. After B,
C and D remain serial capture-mode PRs that share the one overlay preference.
Do not collapse C and D into one runtime PR unless the seam map stays honest.
Product is unified; persist contracts and mid-turn timing stay split.

Shared implementation pieces (not one persist shape, not one PR):

- `history_compaction.data.native_replay` schema (ADR 0040 Decision 2)
- one overlay check after Provider/backend resolve
- late-bound dialect/model guards
- mandatory local-text fallback in the same Event
- `provider_usage` evidence rules (standalone call role `compaction`;
  threshold evidence on the Turn usage Event; no ciphertext)
- ExUnit seams with no live network
- the file-level touch list and the PR sequence below

## Slice definitions (do not collapse)

### B — ingest without activating

If a `cmp_` item is supplied to the persist helper (tests inject it; live Turn
does not start emitting one), persist it on `history_compaction.native_replay`
with `mode: "threshold_item"`. Fold/replay still sends the local text
checkpoint. Do not call `POST /responses/compact`. Do not send
`compact_threshold`. Do not fold `native_replay.items` as the compacted prefix.

B locks store / validate / inspect without changing Provider input. A
`history_compaction` Event that already carries `native_replay` must still
render as today's local text. B does not write live checkpoints from an
unexpected stream item; it makes the persist path correct so C and D can call
it. B does not turn the overlay on.

### C — standalone capture (explicit compact)

When the overlay is on after resolve, explicit `pixir compact` / ACP
`/compact` call `POST /responses/compact` with the compactable prefix (same
split as `pixir compact --tail-events`). Persist the entire returned `output`
as `mode: "standalone_window"`. Always write local text fallback in the same
Event. If the blob is unusable, fold local text.

C is the first slice that may send `native_replay.items` as the compacted
prefix, and only when the standalone window validates. C does not send
`compact_threshold` (that is D). Overflow / preflight / websocket-critical
stay local even if the overlay preference is on.

### D — threshold capture (ordinary Turns)

When the overlay is on after resolve, ordinary Turns send
`compact_threshold`. `open_responses` and Anthropic refuse it. When it fires,
append a visible `history_compaction` with trigger `native_threshold` plus a
`context_pressure` notice. Persist `threshold_item` (latest `cmp_`). Same-turn
output after the item is ordinary tail History, not part of the window. Still
write local fallback. Mid-turn Event timing is specified below: do not write a
checkpoint whose `to_seq` includes turns that were never compacted, and do not
write mid-Turn before the tail after `cmp_` is known.

D shares C's overlay preference. It does not add a second switch.

## 1. PR sequence (serial B → C → D)

Three PRs, in order. Do not stack C on an unmerged B, or D on an unmerged C.
Each PR may say "Part of #522" / "Addresses #522-B" (or C/D). None may use a
GitHub issue-closing keyword for #512 or #522.

### PR B — store / validate / inspect

**May touch**

- `lib/pixir/compaction.ex`: `native_replay` normalize / validate / inspect
  helpers; persist helper that writes `threshold_item` from a supplied `cmp_`
  item; local-text Event fields remain mandatory; `provider_history/1` stays
  "latest checkpoint + tail after `to_seq`".
- `lib/pixir/event.ex`: docs on `history_compaction/2` only if needed to say
  `data` may include optional `native_replay`. No new canonical type.
- `lib/pixir/session_diagnostics.ex` and/or `lib/pixir/replay_inspector.ex`:
  bounded inspect of mode, usability, item ids. No ciphertext.
- `lib/pixir/cli.ex` / compact `--json` projection: optional inspect fields
  (mode, usable, ids) when present. No new compact product.
- Tests listed in §7 for B.

**Must not touch**

- `Pixir.Provider.stream/2` request body (`context_management` /
  `compact_threshold`).
- Any `POST /responses/compact` client.
- Fold of `native_replay.items` in `Pixir.Provider` or
  `Pixir.Providers.Anthropic`.
- `Pixir.Turn` overflow / preflight / websocket-critical recovery.
- ACP `/compact` becoming native or a Skill/Tool.
- Fork replay types (already excludes `history_compaction`).
- Activating the overlay or native replay. A fixture Event with a usable
  `threshold_item` must still fold as local text.

B's exit criterion: store/validate/inspect are locked; Provider input is
unchanged.

### PR C — standalone capture on the overlay

**May touch**

- `lib/pixir/compaction.ex`: overlay-gated standalone path inside `compact/2`
  (or a sibling called only from that path); persist `standalone_window` from
  a scripted compact result; fold decision that *may* send `items` when
  guards pass; fallback reason on the same Event.
- `lib/pixir/provider.ex`: a compact-call seam (inject `transport:`), not a
  second Log. `store: false` stays. Do not reuse `stream/2` as the compact
  client.
- Overlay preference consult (same one D will use): after Provider/backend
  resolve. See §4. Existing `pixir compact` / ACP `/compact` stay the same
  commands; they become native when the overlay is on. Not a second compact
  product. No extra CLI flag name.
- `lib/pixir/turn.ex`: only to prove overflow / preflight /
  `websocket_critical_recovery` still call local `Compaction.compact/2` and
  never the standalone client, even when the overlay preference is on.
- `provider_usage` recording for the standalone call (`call_role`
  `compaction`).
- Tests listed in §7 for C.

**Must not touch**

- Sending `compact_threshold` on ordinary Turns (that is D).
- Mid-turn threshold Event timing (that is D).
- Overflow / critical preflight / websocket-critical as native recovery.
- Reducing standalone `output` to the `cmp_` item.
- A second overlay key or a second compact command.

C's exit criterion: overlay-on explicit compact uses standalone; overlay-off
and recovery stay local; fold may send the unpruned window when guards pass.

### PR D — threshold capture on the same overlay

**May touch**

- `lib/pixir/provider.ex`: attach `context_management` compaction only after
  Provider/backend resolve and the **same** overlay preference C used. Refuse
  `open_responses`. Capture a `cmp_` item from the ordinary stream.
- `lib/pixir/turn.ex`: mid-turn timing in §5; write `history_compaction` with
  trigger `native_threshold`; emit `context_pressure`; put threshold evidence
  on the Turn `provider_usage` Event.
- `lib/pixir/compaction.ex`: persist `threshold_item` (latest `cmp_` only);
  accept trigger `native_threshold` in the existing trigger list; fold uses
  the same C guards (now also for `threshold_item`).
- `lib/pixir/providers/anthropic.ex`: refuse native compact; keep local-text
  fold.
- Tests listed in §7 for D.

**Must not touch**

- A second off switch.
- Using standalone `/responses/compact` as overflow recovery.
- Transplanting parent `cmp_` windows on fork.
- Persisting `previous_response_id` on the checkpoint.
- ACP usage / tokenizer / `usage_update` work (#517).

D's exit criterion: overlay-on ordinary Turns may send `compact_threshold`;
mid-turn `to_seq` is honest; same-turn post-`cmp_` output is tail History;
explicit `false` and refused backends stay local.

## 2. `native_replay` schema and validation

Copy of ADR 0040 Decision 2. This plan does not change it.

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

The Event always also carries today's local fields (`range`, `strategy`,
`summary`, `limitations`, skill-activation limitation, pointers). Those are
the audit and the fallback projection.

### Persist contracts

`threshold_item` (B persist helper; D live path):

- `items` is a one-element list: the latest stream item with `type`
  `compaction`, `id` matching `cmp_…`, and `encrypted_content` present.
- Same-turn output after that item is **not** stored in `items`.
- Extra retained messages in `items` are a persist bug, not a feature.

`standalone_window` (C only):

- `items` is the entire `/responses/compact` `output` array, unpruned.
- Retained messages or tool items stay even when a `cmp_` is also present.
- Reducing the array to the compaction item is a validation failure
  (`standalone_window_pruned`), not a cleanup.

### Usable vs fallback

A window is **usable** (`recorded_usable: true`) only when all of these hold:

- `native_replay` is a map with string keys
- `mode` is exactly one of the two strings above
- `items` is a non-empty list
- a `cmp_` compaction item is present in `items`
- that item has non-empty `encrypted_content`
- capturing `provider`, `backend`, `dialect`, and `model` are present
- for `threshold_item`: `items` is exactly the latest `cmp_` item
- for `standalone_window`: `items` is a list and was not pruned down to `cmp_`
  alone when the compact `output` had more elements
- no unpaired `function_call` inside `items` (no matching output item in the
  same window)

Otherwise persist with `recorded_usable: false` and a string `fallback_reason`
on `native_replay` (and the same reason on the matching `provider_usage`
evidence). Suggested reason tokens (stable, not prose):

| Reason | When |
| --- | --- |
| `missing_compaction_item` | no `cmp_` in `items` |
| `missing_encrypted_content` | ciphertext missing or empty |
| `standalone_window_pruned` | standalone `items` reduced or not a list |
| `threshold_item_not_singleton` | threshold `items` is not exactly the latest `cmp_` |
| `unpaired_function_call` | `function_call` without matching output in the window |
| `malformed_native_replay` | schema/type errors |
| `guard_mismatch` | live Provider/backend/dialect/model ≠ capturing values |
| `backend_rejected` | 400 / unsupported-field after a real call (C/D) |
| `native_unavailable` | dialect/backend refused before the call |
| `overlay_off` | explicit `false`, or overlay refused after resolve |

Conservative rejection is correct. A 400 from a stale opaque item is worse
than a lossy local summary.

Inspect / CLI / diagnostics may show mode, usability, item ids, fallback
reason, and the local summary. They must not print `encrypted_content`.

## 3. Fold algorithm and overlay guard

Today (`Pixir.Compaction.provider_history/1` +
`Pixir.Provider.to_input_item/3` for `:history_compaction`): latest checkpoint
plus Events after `to_seq`; the checkpoint becomes one user-role text item
from `Compaction.render_for_provider/1`. Anthropic does the same via
`render_for_provider/1`.

One overlay check after Provider/backend resolve (same late-bound pattern as
hosted `web_search` in ADR 0022):

```text
preference = operator overlay preference
  (absent/nil = no preference; false = explicit off; true = explicit on)

after resolve:
  if Provider/backend is open_responses or Anthropic:
    overlay = off   (refuse; local only)
  else if preference is false:
    overlay = off   (explicit false always wins)
  else if Provider/backend is OpenAI Responses on chatgpt_codex
           or API-key OpenAI:
    overlay = on    (absence of override is on; explicit true is on)
  else:
    overlay = off
```

Capture (C/D, not B) uses that overlay bit:

- overlay on + explicit compact → standalone `/responses/compact`
- overlay on + ordinary Turn → send `compact_threshold`
- overlay off → today's local compact / no threshold field
- recovery triggers → local, ignoring overlay

Replay fold after a checkpoint exists (ADR 0040 Decision 2), with B forced to
the `else` branch:

```text
split = latest history_compaction + Events after to_seq

if slice is C or D
   and native_replay is present
   and recorded_usable
   and current Provider, backend, dialect, and model all match the capturing
       values
   and the window still validates (see §2):
  send native_replay.items as the compacted prefix
  then fold the raw tail Events
else:
  send the local text checkpoint as today
  then fold the raw tail Events
```

Never send both the native window and the local text checkpoint in the same
prefix.

Implementation notes:

- B ships the fold predicate as a function but **does not take the true
  branch** in `Pixir.Provider` / Anthropic fold. Tests in B assert the
  predicate can return usable and that fold still emits local text.
- C/D flip the Provider fold to honor the true branch. Anthropic never takes
  it (`guard_mismatch` / dialect refuse).
- Overlay-off does not delete an already-recorded `native_replay`. Fold still
  uses capturing-value guards: a usable window on a matching OpenAI Session
  may replay; a later Anthropic or `open_responses` Session falls back to
  local text.
- `provider_usage` Events stay out of the fold (already true).
- Compacted `skill_activation` Events at or before `to_seq` stay out of the
  fold (ADR 0020). The limitation sentence stays on the Event.
- Orphan `tool_call` repair stays Log-first (ADR 0018) before the next Turn.
  An unpaired `function_call` *inside* a standalone window makes that window
  unusable; it does not skip Log repair.

Standalone prefix vs tail: C sends only the compactable prefix (same split
`pixir compact --tail-events` already uses). The returned window replaces that
prefix. The withheld tail stays raw Events after `to_seq`. Appending that tail
after an unpruned window is not pruning the compact output.

## 4. Trigger matrix, one switch, and UX

### Trigger matrix

| Trigger | Overlay off, or refused backend | Overlay on (`chatgpt_codex`) | Overlay on (official `api.openai.com`) |
| --- | --- | --- | --- |
| Explicit `pixir compact` / ACP `/compact` | local | **local** (Codex `/compact` 404s) | native standalone `/responses/compact` |
| Ordinary Turn | no `compact_threshold` | send `compact_threshold`; persist `threshold_item` if a `cmp_` arrives | same |
| `overflow_recovery` | local | **local** (overflowing window cannot be sent) |
| `critical_pressure_preflight` | local | **local** |
| `websocket_critical_recovery` | local | **local** |

Every native fire still writes a visible `history_compaction`. Threshold also
emits `context_pressure`. Recovery is never threshold and never standalone.

### One switch

Follow hosted `web_search` (ADR 0022 / #523): resolve Provider/backend first,
then default. Absence/`nil` means no preference, not "off for every backend."
Explicit `false` always wins.

Existing compaction object already has `tail_events` and `model_assisted`.
The single overlay key that matches that style is `compaction.native`:

- absent / `nil` — no preference; after resolve, default-on for
  `chatgpt_codex` and API-key OpenAI
- `false` — overlay off on every backend
- `true` — request on; `open_responses` and Anthropic still refuse

Do not add a second key for threshold vs standalone. Do not ship a CLI flag
name. Presenters may later expose the same preference the way ACP already
exposes `web_search`; that is still one switch, not a second compact product.

### Existing command surface (unchanged names)

- `pixir compact <session_id> [--dry-run] [--json] [--tail-events N]`
- ACP `/compact` with an optional positive integer tail (Presenter parse of a
  runtime command)

ACP `/compact` stays a Presenter parse. It does not become a Skill, a free
model Tool, or a silent native call. Overlay-on makes that same command use
the standalone endpoint; it does not add a second command.

Current `Compaction` trigger list is `manual`, `overflow_recovery`,
`critical_pressure_preflight`, `websocket_critical_recovery`. D adds
`native_threshold` as a first-class trigger string (visible on the Event).
Do not reuse `manual` for a threshold fire.

Hysteresis (ADR 0040 Decision 3): a 400 or unsupported-field rejection
records structured evidence and does not retry every Turn on the same
checkpoint range. Support for one OpenAI capture mode still does not imply
the other is accepted by that backend; a refused field records
`native_unavailable` / `backend_rejected` and falls back to local.

### UX vs today

Today (main, no overlay implemented):

- `pixir compact` / ACP `/compact` always write a local text checkpoint
- ordinary Turns never send `compact_threshold`
- no mid-Turn native checkpoint

After C and D, overlay on (`chatgpt_codex` or official `api.openai.com`,
no explicit `false`):

- explicit compact is native only on the official host (`standalone_window`
  + local fallback). On `chatgpt_codex` it stays local.
- an ordinary Turn may emit a visible mid-Turn `history_compaction` when
  threshold fires (`native_threshold` + `context_pressure`)
- recovery compact looks the same as today (local)

Overlay off, other `open_responses` vendors, or Anthropic: same UX as today
(local).

## 5. Mid-turn threshold Event timing (D)

`compact_threshold` fires inside an ordinary Turn stream. The Turn may already
have recorded a `user_message` and, on later iterations, `tool_call` /
`tool_result` Events. After the `cmp_` item, the same Response may continue
and emit assistant text or function calls. Those post-item outputs are
ordinary tail History (ADR 0040 Decision 2).

Two forbidden writes:

1. A checkpoint whose `range.to_seq` includes Events that were never in the
   compacted prefix (later same-turn output, or a later Turn).
2. A mid-Turn checkpoint written before the implementation knows which stream
   items after `cmp_` are tail rather than window.

### Frozen input seq

At the start of the Provider call that may send `compact_threshold`, remember
`input_to_seq`: the last seq of the History that was actually sent as input
(after `provider_history/1`). That is the compactable prefix for this call.

`history_compaction.data.range.to_seq` for a `native_threshold` checkpoint
**is `input_to_seq`**, not `Log` tip after the Turn, and not the seq of the
checkpoint Event itself.

### When to write

Write the canonical `history_compaction` only after all of these are true:

- the latest `cmp_` item is complete (`id`, `type`, `encrypted_content`)
- later output items on this Response have been classified as tail, not as
  `native_replay.items`
- local text fallback for the compacted prefix is ready
- pending Log orphans in the prefix have been repaired as they are today

Preferred Log order for the producing iteration:

```text
... Events at or before input_to_seq (compacted prefix) ...
history_compaction (trigger native_threshold, to_seq = input_to_seq)
... same-turn Events after cmp_ (assistant_message, tool_call, ...) ...
provider_usage (this Turn call; threshold evidence rides here)
```

If a mid-stream `on_committed_call` would record a `tool_call` after `cmp_`
but before the checkpoint, **buffer it** and record it after the checkpoint
so the Log order matches the contract. Do not raise `to_seq` to include that
call. Do not put the call in `native_replay.items`.

Do not wait until a later user Turn to write the checkpoint. The next
tool-loop iteration in the same Turn must already fold through it (native
window + tail, or local text + tail). Waiting until Turn-end invites setting
`to_seq` to the last Event of the Turn — those post-`cmp_` Events were never
compacted.

### Notices and lifecycle

- Emit an ephemeral `context_pressure` notice when the threshold item is
  accepted or rejected (visible; not a second canonical type).
- `trigger` on the checkpoint is `native_threshold`.
- Next-Turn WebSocket continuation still resets. A mid-Turn `cmp_` may
  continue inference on the current Response; that does not license storing
  that Response id on the checkpoint, and it does not license continuing from
  it after the Turn ends or the socket drops.
- Transcript cache-prefix breaks; cache-key family is unchanged.
- If native capture fails, still write a local `history_compaction` with
  `native_replay.recorded_usable` false and a reason, then continue with
  local replay. Recovery paths must not wait on a native blob.

## 6. File-level seam map (not patches)

| File | B | C | D |
| --- | --- | --- | --- |
| `lib/pixir/compaction.ex` | schema, validate, inspect, persist helper; `provider_history/1` unchanged in behavior | overlay-gated standalone path; persist full `output`; fold predicate used | `native_threshold` trigger; persist latest `cmp_` only |
| `lib/pixir/event.ex` | docs only; no new type | no new type | no new type |
| `lib/pixir/provider.ex` | no request/fold change | `transport:`-injected compact call; fold *may* send `items` | attach `compact_threshold` when overlay on after resolve; capture `cmp_` from stream; fold already from C |
| `lib/pixir/providers/anthropic.ex` | still local text | still refuse native fold | still refuse `compact_threshold` |
| `lib/pixir/providers/registry.ex` / `resolved_provider_request.ex` | read-only for guard fields | overlay check after resolve; standalone only if on | same overlay check; field only if on |
| `lib/pixir/turn.ex` | no live ingest | assert overflow/preflight/websocket-critical stay local | mid-turn timing; `context_pressure`; usage evidence |
| `lib/pixir/cli.ex` | optional inspect fields on existing `--json` | same `pixir compact` command; native when overlay on | no second compact command |
| `lib/pixir/acp/server.ex` | no native call | same `/compact` parse; native when overlay on | still Presenter parse, not a Skill/Tool |
| `lib/pixir/fork.ex` | no change (`history_compaction` stays excluded) | no change | no change; do not transplant `cmp_` |
| `lib/pixir/session_diagnostics.ex` / `replay_inspector.ex` | inspect mode/ids/usable | same | same |
| `lib/pixir/renderer.ex` | no ciphertext | no ciphertext | no ciphertext |
| `lib/pixir/provider/connection.ex` | no checkpoint storage of `previous_response_id` | next-Turn reset unchanged | same; mid-Turn continue is connection-local |
| `test/pixir/compaction_test.exs` | B cases | C cases | D persist/fold cases |
| `test/pixir/provider_test.exs` | fold still local text | compact transport; unpruned window; no live net | field refused/sent by overlay+resolve; no live net |
| `test/pixir/turn_test.exs` | replay unchanged | overflow stays local with overlay on | mid-turn `to_seq`; overlay default-on after resolve |
| `test/pixir/event_test.exs` | string-keyed optional `native_replay` | — | — |
| `test/pixir/acp/server_test.exs` | `/compact` still local in B | overlay-on `/compact` is standalone; overlay-off is local | no silent Skill/Tool |
| `test/pixir/fork_test.exs` | still excludes `history_compaction` | same | same |
| `test/pixir/cli_test.exs` | inspect fields if added | overlay-on compact is standalone | — |

`Pixir.Provider.stream/2` remains the Turn client. C adds a distinct compact
client with the same `transport:` injection style. Do not teach `stream/2` to
POST `/responses/compact`.

Resolved Provider request already carries `provider`, `model`, `dialect`, and
`responses_backend`. Overlay and fold guards read those. This plan does not
invent a new resolve path.

## 7. ExUnit cases (no live network)

Inject `transport:` (Provider), scripted `provider:` (Turn),
`Pixir.ACP.Server.feed/2` (ACP), and constructed Events (Compaction/Event).
Assert structured `kind` / `fallback_reason` tokens, not prose.

### Shared / B (prove ingest without activating)

- `history_compaction` remains the only compaction Event type;
  `native_replay` is optional string-keyed data.
- Persist helper: a `cmp_` item → `mode: "threshold_item"`, singleton
  `items`, ids only in `compaction_item_ids`, local text present.
- Persist helper: a full compact `output` list stored as
  `threshold_item` is rejected (`threshold_item_not_singleton`) — do not
  silently drop retained items and call it threshold.
- Inspect / `--json` shows mode, usable, ids; never `encrypted_content`.
- `provider_history/1` + Provider fold: Event with usable `native_replay`
  still sends local text (B does not change replay).
- Anthropic fold still uses `render_for_provider/1`.
- Fork still excludes `history_compaction` (existing `fork_test.exs`).
- NDJSON cold decode of a checkpoint that includes `native_replay` round-trips
  string keys (no `String.to_existing_atom` on data keys).

### C (prove standalone contract on the overlay)

- After resolve to `chatgpt_codex` or API-key OpenAI, absence of override:
  `pixir compact` / ACP `/compact` call the compact client with the same
  prefix split as `--tail-events`.
- Explicit `compaction.native` `false`: those commands stay local.
- `open_responses` and Anthropic: those commands stay local.
- Persist: entire `output` list; "save only `cmp_`" fails
  `standalone_window_pruned`.
- Fold sends `items` only when guards pass; otherwise local text + reason.
- Model / Provider / backend / dialect mismatch drops the window.
- Unusable blobs (missing ciphertext, unpaired `function_call` in the window)
  fold local text.
- Overflow recovery, `critical_pressure_preflight`, and
  `websocket_critical_recovery` still write local checkpoints and do not call
  `/responses/compact`, even when the overlay is on.
- Standalone records `provider_usage` with `call_role` `compaction`; it is
  not folded as model context; no ciphertext in usage.
- Compacted prefix Events remain in the Log.
- Compacted `skill_activation` Events stay out of replay; limitation still
  recorded.
- Next-Turn continuation reset still happens; checkpoint has no
  `previous_response_id`.

### D (prove threshold contract on the same overlay)

- After resolve to `chatgpt_codex` or API-key OpenAI, absence of override:
  ordinary Turn requests include `compact_threshold: 200000` (product N;
  1000 is the API floor only).
- Explicit `false`: the field is absent.
- `open_responses` and Anthropic refuse the field (structured reason, no
  retry storm).
- When it fires: visible `history_compaction` with `trigger`
  `native_threshold` and a `context_pressure` notice.
- Persist is `threshold_item` (latest `cmp_` only); post-`cmp_` same-turn
  output is not in `items`.
- `range.to_seq` equals frozen `input_to_seq`, not the last Event of the
  Turn.
- Checkpoint is not written before the post-`cmp_` tail is classified;
  buffered post-`cmp_` `tool_call`s appear after the checkpoint, with seq >
  `to_seq`.
- Threshold evidence rides the Turn `provider_usage` Event (no extra usage
  Event unless a later slice has a truly separate compact call).
- Failed native capture still writes local fallback and continues.
- Overflow still cannot use standalone or threshold as recovery.
- C and D read the same overlay preference (one key, not two).

## 8. Non-goals and mix-avoidance

This plan does not:

- Implement native compact (no `lib/` / `test/` in the PR that lands this
  note).
- Rewrite ADR 0040's historical Decision text, or add a
  `provider_compaction` Event type.
- Use native compact for overflow, `critical_pressure_preflight`, or
  `websocket_critical_recovery`.
- Enable the overlay before Provider/backend resolve, or invent a second
  flag / second compact product.
- Use a GitHub issue-closing keyword for #512 or #522. Leave both open.
- Mix #515 (session hide), #516, #517 (tokenizer / ACP usage gauge /
  `usage_update`), #520, or #523. Native compact evidence is
  `provider_usage`, not ACP usage. #523 is the web_search pattern to copy,
  not work to combine.
- Adopt Anthropic-native compaction, Pinned Skills, or silent
  `compaction: auto`.
- Persist `previous_response_id` in checkpoints.
- Prune `/responses/compact` output down to `cmp_` alone.
- Print or log compaction ciphertext.
- Add MCP, `fs/*`, terminal client tools, or ACP v2 methods.
- Change `store: false` or delete compacted Events.
- Transplant parent `cmp_` windows across fork remapped seqs.
- Restore compacted Skill Activations (ADR 0020).
- Replace Log-first orphan repair with window-first repair (ADR 0018).

## Verification (this documentation slice)

```bash
git diff --check origin/main HEAD
```

Confirm the diff is docs only (no `lib/`, no `test/`), the PR body does not
use a GitHub issue-closing keyword for #512 or #522, and this note does not
mention a configuration-load entrypoint as a public API.

Later implementation slices use ADR 0040's ExUnit list plus §7 above:

```bash
mix test test/pixir/compaction_test.exs
mix test test/pixir/provider_test.exs
mix test test/pixir/turn_test.exs
mix test test/pixir/event_test.exs
mix test
mix check
```
