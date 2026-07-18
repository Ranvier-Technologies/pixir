# Pixir Presenter Workspace Set v1

Status: frozen (HITL approved 2026-07-14 on #339, epic #330)
Applies to: `pixir.presenter.workspace_set`, `schema_version: 1`
JSON Schema: `schema/pixir.presenter.workspace_set.v1.schema.json`
Embeds, verbatim and unmodified: the list document `pixir.monitor.runs` v1
(scoped list) and `pixir.presenter.run.v1` (scoped detail, by `$ref`)
Consumers: #349 (implementation), #340 (gate)
Frozen inputs: resolutions of #361 and #365, inventory of #368 (verified against
`origin/main` @ `34000a6`), honesty rules of #364, evidence style of #362

## Purpose

Workspace Overview projects exactly two explicitly configured local Pixir
workspaces into one read-only overview. It is a separately versioned local
contract: multi-root aggregation cannot honestly be built on the single-run
`pixir.presenter.run.v1` contract and must not be advertised as available on it.

This surface is named `Workspace Overview`. `Fleet` is reserved for a future
multi-machine product with hosts, node topology, and a different identity and
threat model; nothing in this contract may be presented as Fleet.

## Scope and exclusions

- Exactly two explicit local workspaces. The set size is frozen at 2. No
  discovery of any kind.
- Explicitly excluded: remote discovery, host identity, BEAM topology, AI chat.
- Aggregates remain disposable read models. Per-source HTTP snapshots stay
  authoritative; run.v1 facts pass through per source; the set adds scope and
  never re-derives (#361).

## Two modes, two separate contract cases

`serve` runs in exactly one of two modes, and the two surfaces are pinned as
separate contract cases so neither drifts into the other:

- **Single-workspace mode** (today's behavior): unscoped routes, today's SSE
  frame, today's bootstrap shell, today's 503 shape (post-#371,
  `workspace_basename`). This surface stays byte-identical to today. Fixtures
  must include negative cases proving no set-mode fact leaks into it.
- **Workspace-set mode**: the surface defined by this document. Fixtures must
  include negative cases proving no single-mode shape is accepted on it.

## Source identity and serve-time declaration

- Each source has an operator-assigned key, declared explicitly at serve time
  with `--workspace <key>=<path>`. The key is validated against the exact
  UnitIdentity safe-component rule (`[A-Za-z0-9][A-Za-z0-9_-]*`, at most 256
  bytes; the charset is ASCII, so byte and code-point bounds coincide).
- The key forms the identity component `workspace:<key>` via the existing colon
  grammar, is unique within the set, and is stable across path moves.
- The key doubles as the operator-facing label. There is no separate
  display-name field in v1.
- **Grammar: form decides, count validates.** A `--workspace` value containing
  `=` is always a keyed declaration: split on the first `=`; the key is the
  prefix, the path is the remainder (the path may itself contain `=`). A value
  without `=` is a plain single-workspace path, exactly as today.
- Workspace-set mode is entered by exactly two keyed declarations. All of the
  following are explicit serve-time errors, never silent reinterpretation.
  Each carries a stable machine-checkable kind token in its output (pinned by
  string contracts, fixture-enforceable):
  - exactly one keyed declaration (v1 has no labeled-single mode) —
    `workspace_declaration_single_keyed`,
  - three or more declarations — `workspace_declaration_too_many`,
  - a mix of keyed and plain declarations — `workspace_declaration_mixed`,
  - a duplicate key — `workspace_declaration_duplicate_key`,
  - a key failing the safe-component rule —
    `workspace_declaration_invalid_key`,
  - an empty path in a keyed declaration —
    `workspace_declaration_empty_path`.
- Consequence, pinned as a negative case: a plain single-workspace path that
  contains `=` misparses into a keyed declaration and fails serve-time with a
  clear error. It is never silently treated as a path.

## Set-mode discovery: the bootstrap shell embed

In workspace-set mode the bootstrap shell (`GET /`) embeds a `shell_config`
document (schema `$defs/shell_config`):

```json
{ "mode": "workspace_set", "workspaces": ["<key>", "<key>"] }
```

- **Mechanism (pinned, CSP-safe):** the set-mode shell carries the
  `shell_config` JSON, HTML-attribute-escaped, in a `data-workspace-set`
  attribute on the shell's `<main>` element. No new inline script is
  introduced: the hashed bootstrap script and the CSP policy (exact-hash
  `script-src`, Trusted Types) are unchanged. The SPA reads and strictly
  validates the attribute exactly once at boot.
- Mode resolution in the SPA: attribute present and valid → workspace-set
  mode; attribute absent → single-workspace mode. An attribute that is
  present but malformed (bad JSON, wrong shape) renders an explicit boot
  error — never a silent fallback to single mode, which would be an
  inference.
- `workspaces` lists the two declared keys in declaration order; declaration
  order is the stable section order everywhere (#365).
- Keys are constants for the process lifetime; there is no index endpoint and
  nothing refetches them.
- The single-workspace shell remains byte-identical to today and embeds
  nothing. A `shell_config` with fewer or more than two keys, duplicate keys,
  or an unknown `mode` is schema-invalid.

## Routes

Workspace-set mode serves:

- `GET /` — bootstrap shell with the `shell_config` embed.
- `POST /bootstrap` — unchanged.
- `GET /assets/app.css`, `GET /assets/app.js` — unchanged.
- `GET /api/workspaces/:key/runs` — scoped list snapshot (envelope, below).
- `GET /api/workspaces/:key/runs/:id` — scoped detail snapshot (envelope).
- `GET /api/events` — the ONE shared SSE stream (frame, below).
- `GET /api/runs`, `GET /api/runs/:id` — **404** with kind
  `unscoped_route_unavailable`: an explicit confession that this serve is
  workspace-set scoped, pointing at `/api/workspaces/:key/…`. Never a workspace
  inference, never the generic fallback.
- Scoped-key edges, mirroring today's run-id handling: a `:key` failing the
  safe-component rule answers **400** `invalid_workspace_key`; a valid but
  undeclared `:key` answers **404** `workspace_not_found` with
  `details.workspace` echoing the (charset-validated) requested key.
- Everything else — including a bare `/api/workspaces` with no key — falls to
  today's `match _` fallback: **405** `method_not_allowed`.

Single-workspace mode serves exactly today's route table; the scoped routes do
not exist there and fall to the same 405 fallback (no dedicated error).

SPA hash routes in set mode: the overview is the root view at `#/workspaces`;
depth extends the frozen grammar of #361:
`#/workspaces/:key/runs/:runId[/units/:unitId?attempt=…]` with today's
filter/sort/q/follow params scoped per source. An unrecognized hash falls back
to the overview, never to an inferred source. Single-mode SPA routes are
untouched.

## Scoped snapshot envelope

`GET /api/workspaces/:key/runs[/:id]` answers 200 with a workspace_set.v1
envelope:

```json
{
  "workspace": "<key>",
  "source": { "sessions_directory": "observed" | "absent" },
  "snapshot": { …the route's own single-mode document, verbatim… }
}
```

- `workspace` is the declared key: the payload is self-describing; a saved or
  logged snapshot never loses its source.
- `snapshot` embeds, verbatim, exactly the document single-workspace mode
  serves on the corresponding route — the two routes carry two different
  documents today and this contract does not merge them:
  - **list** (`…/runs`, schema `$defs/scoped_list_snapshot`): the
    `pixir.monitor.runs` v1 document — `schema`, `schema_version`, `runs`,
    `inventory` — exactly as `GET /api/runs` produces it. The per-source
    inventory confessions (`total` / `selected` / `truncated`,
    `limitations` such as `run_inventory_truncated` and
    `run_projection_incomplete`) live INSIDE this embedded document; the
    envelope never copies, moves, or re-derives them. `pixir.monitor.runs`
    has no standalone JSON Schema today; `$defs/runs_list_document` pins
    its top-level discriminators, the required inventory quartet, and the
    three projection-metadata keys production always enriches
    (`projected_runs`, `non_parent_logs`, `dropped_logs` — optional, since
    bare-rows providers synthesize only the quartet); the row shape remains
    owned by the list producer.
  - **detail** (`…/runs/:id`, schema `$defs/scoped_run_snapshot`): the
    `pixir.presenter.run.v1` document, pinned by `$ref` to the untouched
    run.v1 schema.
- **Pass-through parity (pinned definition):** for the same filesystem, the
  embedded `snapshot` is structurally identical to the single-mode response
  after normalizing the volatile clock stamps (`projected_at` and
  `observed_at`, at any depth) exactly as the existing fixture sanitization
  contract already does; the projector's test seams (injected
  `projection_projected_at` / input stamps) are the normative mechanism. No
  other field may differ. The envelope adds scope and never re-derives,
  filters, annotates, or reorders anything inside `snapshot`.
- `source.sessions_directory` is the provenance fact for zero (#365 decision
  6), transcribing what the server already distinguishes: `"observed"` (the
  `.pixir/sessions` directory exists; counts are real observations, including a
  real 0) versus `"absent"` (no `.pixir/sessions` directory observed; a
  mistyped root is diagnosable instead of a silent zero). It is present on
  every scoped 200, list and detail scope alike, and carries no judgment: a
  freshly declared workspace with `"absent"` is normal, never an attention
  condition.
- The envelope adds **no timestamp**. The embedded documents' own
  `projected_at`/`observed_at` pass through untouched inside `snapshot`; the
  per-source observed-at used by staleness disclosure is client-held receipt
  state (below), so fixtures stay deterministic (under the normalization
  above) and no NEW server wall-clock fact is introduced for thresholds to
  germinate on (#364).
- All envelope objects are `additionalProperties: false`.

## Scoped errors and failure isolation

- A failed source answers **503** on its own scoped routes only, with an error
  envelope (schema `$defs/scoped_error`):
  `{"error": {"kind", "message", "details"?}}`. The set-mode error kinds are
  a closed enum with pinned `details` requirements:
  - `workspace_unavailable` (503) — `details.workspace` required (the
    declared key), `details.reason` optional (sanitized through the existing
    safe-error-kind rule);
  - `run_not_found` (404) — `details.workspace` and `details.run_id`
    required (today's `run_id` detail survives, scoped);
  - `workspace_not_found` (404) — `details.workspace` required: the
    requested, charset-valid key;
  - `invalid_run_id` (400) — `details.workspace` required,
    `details.max_bytes` allowed (today's shape, scoped);
  - `invalid_workspace_key` (400) and `unscoped_route_unavailable` (404) —
    no `details` (a charset-invalid key is never echoed).
  In set mode `details.workspace` is always the label — never the basename,
  never any path fragment. Kinds pinned as detail-less must OMIT the
  `details` key entirely — an empty `details: {}` is schema-invalid
  (implementation note for #349: the existing security rejection helper
  always encodes `details: {}` and must not be reused verbatim for these
  kinds). Single-workspace mode keeps its post-#371 `workspace_basename`
  shape untouched.
- There is no set-level 503. The sibling source's routes, stream handling, and
  rendering are unaffected by the failure (#361, #365 decision 5c).
- Unavailability is never rendered as zero, empty, or successful. A source
  with nothing held renders an explicit per-source error card: label + error
  kind, no path, retry at hand. "Source unreachable" and "run not found in a
  reachable source" are distinct facts rendered distinctly (#365 decision 5a):
  the scoped 404 `run_not_found` keeps its meaning per source.

## Run-id collision rule

Set-level run identity is `(workspace key, run id)`. Equal sids across the two
roots are two unrelated runs: never merged, deduped, linked, or marked. No
cross-workspace inference of any kind — the #364 no-invented-relationships
doctrine extended to the set. The absence of any collision marker is
deliberate and pinned by a fixture (a marker would itself be an invented
relationship).

## Freshness and staleness

- Freshness is per source and independent: each source carries its own
  client-held observed-at; freshness is never pooled; a stale source never
  masks the other (#361).
- The per-source observed-at is **client-held receipt state**: the SPA records
  when it received each source's snapshot. It is not a schema field and not a
  server fact.
- Staleness is observational, never threshold-based: a source is stale exactly
  when its refresh is failing while a prior snapshot is held. No wall-clock
  classification ever derives it (#364 timestamp hazard).
- **Stale display**: the source section keeps the last held snapshot, headed by
  the per-source error card and an explicit disclosure — the snapshot's
  observed-at plus the current failure kind. It is never presented as current.
- **The disclosure travels**: held stale data is navigable at any depth, and
  the stale disclosure renders on every view — overview, list, run, unit,
  attempt — not just the overview banner. Data the client does not hold
  renders the unavailable state, not a gap.
- "Unavailable" (nothing held) and "stale" (last snapshot held) are
  distinguishable states, rendered distinctly.
- These display obligations are pinned by string contracts and the browser
  gate (#362 style), including the negative case: a stale deep view must be
  visually distinguishable from a fresh one.

## Per-source condition model

A source's degradation is a set of orthogonal facts on its source card — no
folded status enum, no health scalar, no worst-wins precedence (#365 decision
1, extending #363/#364):

- availability: `ok` | `unavailable:<kind>`,
- its own freshness (client-held observed-at, stale disclosure when
  applicable),
- the existing inventory and projection confessions verbatim, per source:
  `total` / `selected` / `truncated`, `run_inventory_truncated`,
  `run_projection_incomplete` with `dropped_logs` and `error_kinds`,
  `non_parent_logs` — all read from the embedded list document's `inventory`
  metadata (their wire home; detail-scope limitations stay inside the run.v1
  document),
- the zero-provenance fact (`sessions_directory`).

The existing per-source bounds (512 logs / 8 MiB / 20k events) apply per
workspace, with every count observed-only and its limitation beside it.
"Partially projected" and "malformed" need no new mechanism: the per-run drop
confessions surface per source. Source-level conditions live in
workspace_set.v1 only and are never injected into run.v1's attention reason
enum.

## No set-level sums

The overview is two source sections. Every count is per-source, observed-only,
with its limitation beside it and its source's observed-at. No number
aggregates across sources — a set total would pool freshness, and every
degradation mode would need an inclusion rule. With the set frozen at 2, both
addends are already in view (#365 decision 3).

## Attention and layout

Each source section renders, in order: its source condition (error card /
degradation banner) first, then its run-level attention region (the #364 order
intact: families worst-first, members by `seq`), then its healthy region.
Section order between the two sources is declaration order — stable, never
reshuffled by state; attention is signaled by the banner, not by layout
movement. There is no interleaved set-level attention region: `seq` does not
cross sources and timestamps are banned as an ordering axis, so an interleaved
list has no honest order (#365 decision 4).

## Path privacy

Absolute workspace roots never appear in any workspace_set payload — rows,
detail, error cards, shell embed, or SSE. Labels (keys) only; roots stay
server-side configuration. In set mode this tightens the error surface: the
scoped 503 carries the key, not the basename. Independent of the #369/#371
execution surface; neither is re-litigated here.

## SSE invalidation

- ONE shared stream at `GET /api/events` for both sources.
- The set-mode frame (schema `$defs/invalidation_frame`) is a strict
  frame-shape change:

  ```json
  { "type": "projection_changed", "workspace": "<key>", "projection_id": "…" }
  ```

  The client validates by exact key set `projection_id,type,workspace`
  (mirroring today's `projection_id,type` check). The single-mode frame is
  untouched. The two frames are separate contract cases with crossed negative
  fixtures: a frame carrying `workspace` in single mode is invalid; a frame
  missing `workspace` in set mode is invalid; extra keys are invalid in both.
- Sequence semantics are unchanged: one global monotonic sequence across the
  stream.
- A valid frame invalidates the named source only. Any anomaly — malformed
  frame, unknown `workspace` key, duplicate sequence id, reorder, gap —
  forces an authoritative refetch of ALL declared sources and never mutates
  view state directly; an unknown key never creates a source section.

## Fixtures and negative cases (normative; implemented by #349)

Fixtures are specified here and implemented by #349 with the real projector —
no hand-authored goldens. Positive scenarios:

1. `ws-two-healthy` — both sources projecting; declaration order; per-source
   counts with `sessions_directory: "observed"`.
2. `ws-zero-observed` — one source with an observed sessions directory and 0
   Session Logs; a real zero, no attention condition.
3. `ws-zero-absent` — one source with no `.pixir/sessions` directory;
   `sessions_directory: "absent"`; still no attention condition.
4. `ws-sid-collision` — the same sid in both roots; two unrelated runs; no
   marker of any kind.
5. `ws-truncated-source` — one source over bounds; confessions verbatim,
   scoped to that source only.
6. `ws-passthrough-parity` — for an identical filesystem, the scoped
   `snapshot` (list AND detail) is structurally identical to the single-mode
   response after normalizing the volatile clock stamps (`projected_at` /
   `observed_at`, at any depth) via the projector's test seams, exactly as
   the fixture sanitization contract already normalizes them. No other field
   may differ. This is the pass-through proof.

Mandatory negative cases (#362 style):

1. **Frame drift** — set frame missing `workspace`; single frame carrying
   `workspace`; extra keys in either; frame naming an undeclared key (client
   anomaly path: refetch-all, no new section). Schema-invalid and
   string-contract pinned.
2. **Envelope drift** — envelope missing `source.sessions_directory`; value
   outside the enum; extra envelope keys; a list `snapshot` whose
   discriminators are not `pixir.monitor.runs` / version 1 or a detail
   `snapshot` that fails the run.v1 schema; a `snapshot` that differs from
   the single-mode response beyond the normalized clock stamps (parity
   failure).
3. **Shell drift** — `shell_config` with one or three keys, duplicate keys, or
   unknown `mode`.
4. **Route confession** — unscoped `/api/runs[/:id]` in set mode answers 404
   `unscoped_route_unavailable`; scoped routes in single mode fall to today's
   fallback; `invalid_workspace_key` and `workspace_not_found` behave as
   pinned.
5. **Serve grammar** — each enumerated declaration violation fails serve-time
   carrying its pinned `workspace_declaration_*` kind token (message text
   stays free), including the plain-path-containing-`=` case.
6. **Path privacy** — with a sentinel root path, no workspace_set payload
   (200, 4xx, 503, SSE, shell) contains the absolute root string or any
   `workspace_basename` field. (The assertion targets the path and the
   legacy field, not every basename substring: an operator may legitimately
   pick a key equal to the root's basename.)
7. **Stale deep view** — browser gate: a stale unit-depth view carries the
   traveling disclosure and is visually distinguishable from a fresh one.
8. **Unavailability is never zero** — browser gate: an unavailable source
   renders the error card and never a zero count or empty-success state.
9. **No set sums** — no aggregate count across sources appears anywhere.
10. **Collision honesty** — two equal sids render independently with no merge,
    link, badge, or cross-reference marker.

## Versioning

`pixir.presenter.workspace_set` is versioned separately from
`pixir.presenter.run`. Any of the following requires v2, never a silent
mutation of v1:

- a change to the envelope's key set or required fields, the frame's key set,
  or the `shell_config` shape;
- a change to the route grammar, the key charset or bound, or the serve-time
  declaration grammar;
- a set size other than exactly 2;
- a separate display-name field;
- any server timestamp in the envelope;
- embedding any documents other than `pixir.monitor.runs` v1 (list) and
  `pixir.presenter.run.v1` (detail);
- any cross-workspace inference, merging, or set-level aggregate.

## Design evidence

The local two-workspace design artifact (six states, desktop + narrow) lives in
the design handoffs as design evidence, outside Git history:
`.docs/design-handoffs/pixir-monitor-workspace-set-freeze/design-workspace-set-freeze.html`.
It is evidence, not normative schema, and supersedes the rough visual probe
recorded at the #361 sign-off. The exact UI treatment remains owned by #349
under the string contracts and browser gate pinned here.

## References

- #339 (this freeze), #361 and #365 (frozen resolutions), #368 (inventory),
  #364 (honesty rules), #362 (evidence style), #349 (implementation),
  #340 (gate), ADR 0038 (monitor foundations).
