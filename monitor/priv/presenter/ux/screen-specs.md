# Presenter Projection v1 — Screen Specifications

Status: frozen UX contract for the follow-up implementation Goal  
Projection: `pixir.presenter.run.v1`  
Primary operator question: **What happened, what is alive now, what is blocked, and what evidence supports that answer?**

## Shared presentation rules

- The UI consumes the projection and never derives a competing run state.
- Execution, liveness, workflow gate, model advisory, and source are separate
  visual dimensions. They must not collapse into one status badge.
- `source.mode` uses only `live`, `reconstructed`, or `mixed`. A trigger such as
  user request, timer, webhook, or policy is not a source mode and is absent from
  v1.
- A logical unit owns zero or more attempts. A child Session is evidence inside
  an attempt, not the identity of the unit.
- Durable evidence determines execution and gate state. Live Manager/Owner data
  may update liveness only.
- Model summaries and review verdicts are always labeled **Advisory**.
- Usage appears under an **Evidence-derived usage** disclosure. It shows exact
  provider/model counters and completeness, never estimated money.
- Mutating guidance may be displayed only when present in `safe_actions`; it is
  copy-only or informational. The read-only monitor has no execute, retry,
  resume, cancel, or apply control.
- All user/model/log strings render as plain text under the threat model. No
  Markdown, automatic links, terminal deep links, or arbitrary file opening.

## Screen 1 — Runs

### Purpose

Let an operator find the run that needs attention without reading raw Logs or
mistaking a reconstructed historical run for a live process.

### Information hierarchy

1. Page title and compact source explanation.
2. Filters: strategy, execution, liveness, source, attention only.
3. Three row groups: **Needs attention**, **Active**, and **Recent**.
4. One dense, scannable table; rows are not individual cards.

### Row contract

| UI field | Projection source | Rule |
| --- | --- | --- |
| Run | `run.title`, `run.id` | Title first; stable id secondary and copyable. |
| Strategy | `run.strategy` | `workflow`, `subagents`, or `unknown`; “Fan-out” is only the display label for `subagents`. |
| Execution | `execution.state` | Durable state; never overwritten by liveness. |
| Live now | `liveness.state`, `liveness.reachable`, `liveness.observed_at` | Uses the contract states live, stale handle, owner unavailable, unknown, or not applicable; reachability remains a separate fact. |
| Gate | unit `gate.state` summary | Show ready/held/failed/partial counts; omit for fan-out without gates. |
| Advisory | unit `advisory` summary | Show advisory attention separately from gate. |
| Source | `source.mode`, `source.freshness` | Only Live, Reconstructed, or Mixed. |
| Progress | `counts.completed_units`, `counts.planned_units` | Use observed/planned wording when the plan is incomplete. |
| Mutation | `mutation.status`, `mutation.observed_semantics` | Show both effect and evidence semantics, for example “Workspace applied · exact”. |

### Grouping rules

- **Needs attention** when `counts.attention_units > 0`. The presenter never
  recomputes attention from a second condition list.
- **Active** only when attention is zero, execution is non-terminal, and
  liveness is `live`.
- **Recent** for all other runs, ordered by live observation, then latest
  durable timestamp, then `projected_at`; ties use `run.id` ascending.
- Within every group, rows use that same descending observation/durable/
  projection timestamp order, with `run.id` ascending as the deterministic
  tie-breaker. Group membership is still determined only by the rules above.
- A run may be completed and still appear in Needs attention. F4 is the pinned
  example: apply completed, while review advisory says stop/mergeable false.

### Primary interaction

Selecting a row opens Run Detail and preserves filters in navigation state.
There is no run-level mutation control.

### Empty and degraded states

- No runs: explain which Pixir home/evidence inventory was scanned.
- Live-only/no durable Log: show execution **Unknown**, liveness **Live**, source
  **Live**, and `durable_log_unavailable` visibly.
- Missing child Log: keep the row navigable and show the evidence limitation.

## Screen 2 — Run Detail

### Purpose

Explain the structure and outcome of one workflow or fan-out while keeping
runtime truth, advisory judgment, and evidence provenance visibly distinct.

### Header truth rail

Five adjacent, equal-priority facts:

1. **Execution** — `execution.state` and its durable basis.
2. **Live now** — `liveness.state`, reachability, observation time.
3. **Gate summary** — aggregate of unit gate states.
4. **Advisory summary** — count and highest-severity explicit verdict.
5. **Source** — mode, freshness, last durable time, and limitations.

Mutation state sits beneath this rail because completed execution does not imply
an exact workspace result.

For display aggregation only, explicit advisory severity is frozen as
`stop > needs_review > pass > unknown`. Invalid/unparseable advisories are
counted separately and never receive an invented verdict. This ordering has no
effect on execution, workflow gates, attention derivation, or safe actions.

### Main canvas modes

#### Workflow

- Derive nodes from `flatten(graph.waves)` and resolve them against
  `units[].logical_id`; render `graph.edges` as the dependency DAG.
- Node label comes from the matching logical unit.
- Node styling shows execution; a separate lower marker shows gate.
- An advisory marker never changes node execution or edge eligibility.
- Held/failed dependency edges are `graph.edges[]` whose state is `blocked`.
  The UI may name only the edge's `from` unit as the blocker; v1 has no separate
  `blocked_edges` object.
- Selecting a node opens the unit summary rail and Unit Inspector.

#### Fan-out

- Render the parent run with sibling logical units in a compact tree/list.
- Parallel siblings align on the same level; no dependency edge is invented.
- Each unit shows attempt count, terminal result, liveness, and evidence gaps.
- This is the same Run Detail route and projection contract, not a second state
  model. The implementation Goal may give it a dedicated route/state for focus.

### Attempt lineage rail

For the selected logical unit, render `attempts` as a chronological chain:

```text
Attempt 1 · fresh · failed · websocket_closed · child-f4-a
    ↓ retry
Attempt 2 · retry · completed · child-f4-b
```

- Ordinal, relation, predecessor, child Session id, status, timestamps, and
  error kind come directly from each attempt.
- Human labels use `ordinal + 1` through the versioned
  `pixir.presenter.ui.attempt-display-number.v1` derivation; a null ordinal is
  displayed as `Provisional`, never guessed as attempt 1.
- Never display `1/1` or one mutable “current session” field as a substitute.
- Repeated child Session ids remain separate attempts when the evidence marks a
  new execution epoch.
- A retry/resume relation belongs between attempts, not between independent
  rows in the Runs list.

### F4 pinned composition

- Workflow DAG: propose → review → apply.
- All three runtime gates: **Checkpoint ready**.
- Review advisory: **Stop**, **Mergeable: no**, declared gate **Partial**.
- Apply execution: **Completed** with exact mutation.
- Review lineage: failed WebSocket attempt followed by successful retry.
- The screen must make the disagreement legible without calling it a system
  contradiction or retroactively marking apply failed.

### Evidence drawer

Selecting any status joins its evidence ids to the root inventory and displays
only fields v1 actually projects: authority, source kind, Session id, sequence,
and description. v1 evidence has no event-type or timestamp field. Missing
evidence remains a visible limitation; it is not replaced by presenter
inference.

## Screen 3 — Unit Inspector

### Purpose

Inspect one logical unit across its full retry/resume lineage without losing the
relationship between durable Logs and volatile runtime activity.

### Header

- Logical label and `logical_id`.
- Agent, posture, execution kind, workspace mode.
- Separate chips for execution, live now, gate, advisory, mutation, and source.

### Attempt-first structure

Attempts are first-class expandable sections ordered chronologically by default:

- **Attempt 1 — fresh — failed**
  - child Session id and time range;
  - error kind and terminal evidence;
  - durable activity for that Session;
  - evidence-derived usage for that attempt.
- **Attempt 2 — retry — completed**
  - explicit predecessor link back to Attempt 1;
  - child Session id and time range;
  - durable activity and final summary;
  - evidence-derived usage for that attempt.

An operator may switch activity order to newest-first, but the control and the
current order must be labeled. Attempt sections themselves never reorder.

### Activity semantics

- Attempt activity is an evidence table produced only by joining
  `attempt.evidence_refs[]` to root `evidence[]`. Its columns are Authority,
  Source kind, Session, Seq, and Description; no detailed event is invented.
- Ephemeral activity is labeled **Live activity — not durable** and never moves
  execution or gate badges.
- Gaps, duplicates, reconnects, missing child Logs, and truncation appear as
  presenter limitations in the affected attempt.
- Model text, diffs, tool output, paths, and commands use the hostile-content
  rendering rules in `threat-model.md`.

### Usage disclosure

- Fold only `provider_usage` evidence within the attempt.
- Group by provider and model; display calls and exact token/cache counters.
- Show **Complete** or **Incomplete** with limitations.
- Run/unit totals are sums of their attempt groups only when the underlying
  evidence is complete enough to support the stated total.
- Never display dollars, estimated prices, or a fabricated cache-hit percentage.

### Safe actions

- Render only structured `safe_actions` from the projection.
- `copy_only`: available only when `command` is a non-empty string; apply the
  clipboard review rules in `threat-model.md` before writing it.
- `informational`: show guidance without a primary-action treatment.
- An action that is not projected is omitted. An unavailable capability is
  explained through limitations, not a nonexistent `disabled` presentation.
- No action invokes Pixir, a shell, an editor, the filesystem, or the Provider.

## Cross-screen navigation

```text
Runs
  → Run Detail (workflow DAG or fan-out tree)
      → Unit Inspector (logical unit)
          → Evidence drawer (attempt/event reference)
```

Back navigation restores the prior run selection, viewport, filters, and open
attempt. Deep links use stable run/logical-unit/attempt identifiers, never host
filesystem paths.

## Accessibility and density

- State is communicated by text and shape as well as color.
- Keyboard navigation covers rows, graph nodes, attempts, disclosures, evidence,
  and copy controls with a visible focus indicator.
- The DAG has a list/table equivalent using the same logical ordering.
- Status labels have stable language; no icon-only state.
- Minimum body size is 14 px in a desktop 1440 × 1024 viewport.
- Long ids, commands, and paths wrap or scroll without shifting status columns.
- Live updates preserve focus and announce concise changes through a polite live
  region; historical activity does not jump while the operator is reading.

## Deterministic render contract

Final acceptance rasters are generated only after corrected goldens validate:

1. A pure transform writes `ux/render-data.json` from the golden projections.
2. `ux/render-data.schema.json` validates every displayed field and aggregate.
3. Runs uses every golden; Run Detail uses the F4 golden; Unit Inspector uses
   the F4 review unit.
4. A local HTML renderer marks variable values with their source JSON pointer
   and aggregates with a versioned derivation id.
5. Browser capture uses a fixed viewport, UTC, fixed locale, local font, and
   blocked network.
6. DOM validation proves every variable string belongs to the render manifest.
7. `ux/render-provenance.json` records the hashes of goldens, manifest,
   renderer, viewport, and PNGs.

Visible values may be shortened for layout only when the full exact value
remains accessible. No title, id, timestamp, event, PID, version, runtime-health
claim, navigation route, or control may exist solely in a raster.
