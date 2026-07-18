# Pixir Presenter Semantic Zoom v1

Status: frozen (HITL approved 2026-07-14 on #336, epic #330)  
Applies to: `pixir.presenter.run`, `schema_version: 1` (`projection-v1.md`)  
Consumers: #348 (bounded 100-unit implementation), #337 (500-unit performance gate)

## Purpose

Large Workflow runs need an overview that stays bounded regardless of graph
size without ever misrepresenting the dependency set. Semantic zoom is a
deterministic Presenter read model over the projected Workflow graph: a
bounded set of clusters with aggregate arcs at the overview level, and exact
dependency edges revealed only through expansion.

Clusters are Presenter structure. They never become runtime truth and never
infer an edge, gate, advisory, liveness state, or completion result. An
aggregate overview arc is not an exact dependency and must never be presented
as the underlying dependency set.

## Scope

- Applies only to Workflow runs whose projection carries `graph` with
  non-empty `graph.waves`.
- Delegate fan-out runs are out of scope: they never acquire dependency
  edges; their grouping is owned elsewhere (#338, decision #364).

## Inputs (exhaustive)

This contract reads exactly five projected surfaces, nothing else. Cluster
structure (keys, buckets, arcs) derives from the first two only; the last
three feed summaries, presentation, and honesty:

1. `graph.waves`: array of waves, each an array of logical unit ids. Array
   order is normative at both levels: wave order is topological, and in-wave
   order preserves the planned `steps[]` order.
2. `graph.edges`: flat list of `{from, to, state}` with
   `state` in `{ready, blocked, unknown}` (pinned by
   `schema/pixir.presenter.run.v1.schema.json`).
3. Per-unit truth dimensions from `units`: `execution`, `liveness`, `gate`,
   `advisory`, `attention`. The Source dimension is run-scoped in projection
   v1: the unit schema has no `source` field, and `source` lives at the
   projection root (`pixir.presenter.run.v1.schema.json`). Clusters therefore
   never fold Source per member; see the summaries section.
4. Root `source` (mode, durable origin, freshness, limitations): the
   run-scoped Source presentation at every level.
5. Run-level `limitations`: the honesty predicate of the summaries section.

No phase semantics are ever inferred from `step_id` or `logical_id`.
`logical_id` participates only as an opaque string tiebreaker. Timestamps
never order anything.

## Cluster derivation

Indexing: the `<topological-wave>` key component is the 0-based index into
`graph.waves`; the `<stable-ordinal>` component is the 0-based chunk index
within the wave. Display copy adds +1 uniformly ("Wave 1" renders wave index
0), matching the existing renderer.

### Slot allocation (per zoom window)

A zoom window is a contiguous suffix of waves `[a .. W-1]`; level 0 has
`a = 0`.

- If the window holds more than 6 waves: waves `a .. a+5` receive one cluster
  each (single bucket, ordinal 0); waves `a+6 .. W-1` fold whole into the
  overflow pseudo-cluster. Waves are never merged: the key encodes exactly
  one wave, so a cluster can never span waves.
- If the window holds 6 or fewer waves: every wave starts with one bucket,
  and the remaining slots split the largest waves:

```
buckets[w] := 1 for each wave w in the window
repeat (6 - windowSize) times:
  candidates := waves with buckets[w] < unitCount[w]
  if candidates is empty: stop
  w* := candidate maximizing unitCount[w] / buckets[w]
        (compare by cross-multiplication, integers only;
         tie resolves to the lower wave index)
  buckets[w*] += 1
```

### Bucket chunking

A wave with `n` units and `b` buckets splits into `b` contiguous chunks of
the wave's unit array in projected order. With `q = floor(n / b)` and
`r = n mod b`, chunks `0 .. r-1` hold `q + 1` units and chunks `r .. b-1`
hold `q`. Chunk index = bucket ordinal.

### Keys

- Cluster key: `wave:<wave-index>:bucket:<chunk-index>`, both 0-based.
- Overflow key: `overflow:waves:<start>-<end>`, 0-based inclusive wave range.
- Keys are absolute at every zoom level. A cluster's key never depends on the
  level or path through which it became visible.

### Overflow and recursive zoom

Activating the overflow opens the next zoom level: the same derivation
applied to the window starting at the overflow's first wave. Each level shows
at most six clusters plus at most one overflow.

This clause is an approved refinement (adjudicated on #336, 2026-07-14) of
the #363 sentence "overflow expands to members": members remain reachable via
at most `ceil(W / 6)` overflow activations plus one cluster expansion, and
every level's overflow preserves member count and the independent dimension
presentation of the summaries section (five member distributions plus
run-scoped Source), so every #363 promise holds.

## Ordering (total, deterministic)

There is exactly one normative display order for units, everywhere:
ascending `(wave index, bucket ordinal, logical_id)` (#362). Chunk
membership is determined by wave-array position (derivation, section above);
positional order within a chunk is not a display order.

- Clusters: ascending wave index, then ascending bucket ordinal.
- Member pages and any flattened listing of units: the normative unit order.
- Edge ledgers: ascending by the normative unit order of `from`, then the
  normative unit order of `to`.
- Timestamps never participate in ordering.

## Cluster summaries: six independent dimensions

The six truth dimensions (Execution, Liveness, runtime Dependency gate,
Model advisory, Source, Attention) remain independent and visible at both
levels, in the only form projection v1 can support:

- Five per-unit dimensions fold into per-cluster distributions computed over
  all members from `units`: Execution, Liveness, gate, advisory, Attention.
  Value vocabularies are the pinned v1 enums; no new states are invented.
- Source is run-scoped in v1 (root `source`: mode, durable origin,
  freshness, limitations). It is presented unfolded at every level, always
  labeled run-scoped, and is never synthesized per member or per cluster. A
  per-unit source field would be a v2 projection surface.

Rules:

- No folded or composite status ever replaces the distributions. For the
  five per-unit dimensions, no successful-looking cluster may conceal a
  worse member state: the worst member state in each of those five
  dimensions remains visible as a distribution segment and as a drill-down
  target. Source honesty is separate and run-scoped: the unfolded Source
  card always shows mode, durable origin, freshness, and its limitations,
  and is never reduced to a health summary.
- Honesty under incompleteness: projection v1 has no run-detail truncation
  flag. The honesty predicate is: (a) any cluster member absent from
  `units`, or (b) any projected run-level `limitations` entry affecting
  graph or unit completeness. When it holds, every affected cluster and arc
  count carries the explicit limitation beside it and never renders as
  complete. (`run_inventory_truncated` exists only as list-inventory
  metadata for `pixir.monitor.runs`, `source.ex`; the run-detail view must
  not claim it as its own flag.)

## Aggregate arcs

- Identity: the ordered pair `(from-entity-key, to-entity-key)` of entities
  visible at the current level. Entity keys are cluster keys, the overflow
  key, or the boundary key (below). Both endpoints may be the same entity
  when both exact endpoints fold into one multi-wave entity: the
  overflow-to-overflow self-arc is legal and required (an edge between two
  waves inside the overflow has no other home). Two single-wave clusters can
  never form a self-arc.
- Mapping: each projected exact edge maps to exactly one visible arc via the
  entity assignment of its endpoints. Intra-wave exact edges cannot exist by
  wave construction: every exact edge crosses wave boundaries (this is a
  statement about exact edges, not about entity keys). An arc exists if and
  only if it aggregates at least one exact edge.
- Counts: each arc carries `{ready, blocked, unknown}` per the pinned
  `edge.state` enum. The total is derived by summation, never a separate
  authored field.
- Boundary aggregate: at levels deeper than 0, edges with an endpoint before
  the window aggregate onto one explicit upstream boundary entity with the
  frozen key `boundary:upstream:waves:<a>-<b>`, where `<a>-<b>` is the
  0-based inclusive range of all waves before the window start (at a window
  starting at wave `s`, that is `0`-`s-1`). One boundary entity per level; it
  carries the same per-state counts, its arcs are activable with complete
  ledgers, and it is visibly marked as crossing the zoom boundary. Nothing is
  silently dropped. This key grammar is versioned with the rest.

## Expansion and exact-edge reveal

- Expanding a cluster reveals its member logical units, paged 12 per page
  (#362).
- Activating an arc, including arcs touching the overflow or a boundary
  aggregate, opens the complete exact-edge ledger for that arc: every
  `from`/`to` logical-unit pair with its edge state, paged 100 per page
  (#362), ordered per the ordering section. Activation may auto-expand both
  endpoint clusters.
- Discoverability obligation (executable): for every edge in `graph.edges`
  there is a finite activation sequence that surfaces it in a ledger, and
  already at level 0 the arc covering it is present and activable. Arcs
  into, out of, and within the overflow (the self-arc) are first-class. The
  proof check asserts: the union of all level-0 arc ledgers, including the
  overflow self-arc ledger, equals `graph.edges` exactly, with no duplicates
  and no omissions.

## Fixtures and negative cases

Positive (seeded generator, #362): the 100-unit golden fixture and the
500-unit structural fixture must both exercise: waves under and over 6,
bucket splitting with remainder chunks, overflow recursion of depth 2 or more
(500-unit), arcs with mixed per-state counts, and the level-0 ledger-union
proof.

Sketches:

- 100-unit golden: waves of sizes `[30, 40, 20, 10]`. Allocation grants the
  two spare slots to waves 1 then 0; clusters `wave:0:bucket:0..1` (15+15),
  `wave:1:bucket:0..1` (20+20), `wave:2:bucket:0` (20), `wave:3:bucket:0`
  (10); no overflow.
- 500-unit structural: 14 waves, sizes 36 units in each of waves 0..11 and
  34 in each of waves 12..13 (total 500). Level 0 shows waves 0..5 plus
  `overflow:waves:6-13`; activating overflow shows waves 6..11 plus
  `overflow:waves:12-13`; the second activation opens a window of two
  34-unit waves, and the four spare slots split them into buckets [3, 3]
  (chunks 12+11+11 each), terminating with splitting.

Degenerate:

- `graph` absent or `graph.waves` empty: no cluster view is synthesized; the
  existing empty state renders.
- Fewer units than slots: buckets never exceed unit count; fewer than six
  clusters is legal.
- Single wave: up to six buckets of one wave; no arcs, since no edges can
  exist.

The four mandatory negative cases (#362), instantiated for this contract:

1. Red-proof mutation self-test: an unbounded variant (all unit cards, or the
   restored full edge dump) must turn the DOM assertions red before the real
   run goes green.
2. Truncated-inventory honesty, two fixtures with distinct scopes:
   (a) list scope: a runs inventory behind the 512-log bound carrying the
   list-scope `run_inventory_truncated` limitation (#362, `source.ex`);
   every list-scope count renders with the limitation beside it. This flag
   never appears on run detail and never marks clusters.
   (b) run-detail scope: a 500-unit run whose cluster and arc counts are
   driven only by the honesty predicate of the summaries section (members
   absent from `units`, or a projected run-level `limitations` entry);
   every affected cluster and arc count carries that limitation and never
   renders as complete.
3. Hostile text at scale: seeded hostile payloads (script tags, entities,
   fields at the 32768 cap) in ids and labels across clusters, arcs, and
   ledgers; the textContent-only/Trusted Types pins hold.
4. Malformed fields at scale: seeded malformed timestamps and unknown enum
   values in a slice of units; rendering stays bounded and ordering stays
   wave, then bucket ordinal, then `logical_id`; timestamps never order
   anything.

## Versioning

This contract is `semantic-zoom` v1, bound to `pixir.presenter.run`
`schema_version: 1`, and follows the `projection-v1.md` versioning
discipline: additive, ignorable presentation refinements may land within v1;
any change to the key grammar, slot allocation, chunking, ordering, arc
identity or count semantics, expansion semantics, or the discoverability
obligation requires v2.

Per the #360 support rule, the strings frozen here are exactly what #348
needs and no more; touching them later is a contract change with automatic
demotion.

## Design evidence

The approved desktop (truth rail above a two-column cluster
overview/inspector hierarchy) and narrow (stacked truth rail, cluster
overview, selected cluster/logical unit/attempt lineage, no horizontal
overflow) hierarchies received explicit HITL design approval recorded on
#336. The rail in this view presents all six dimensions: the shipped
five-card rail (`app.js` `truthRail`, "Five independent truth dimensions")
plus an Attention distribution card; its Source card stays run-scoped per
the summaries section. Annotation artifacts remain local design evidence,
mirror-excluded and uncommitted; this document, not any rendered artifact,
is normative.
