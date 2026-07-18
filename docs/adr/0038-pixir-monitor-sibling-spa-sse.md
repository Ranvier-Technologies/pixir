# 38. Pixir Monitor is a sibling source-checkout SPA with authoritative snapshots and bounded SSE invalidation

Date: 2026-07-11
Status: Accepted
Implementation status: Implemented as an experimental source-only Presenter.

## Context

Pixir needs a richer read-only Presenter for inspecting supervised runs without moving runtime ownership into a browser or adding Phoenix to the Harness core. The existing boundary remains: Pixir executes and supervises work, canonical Logs are truth, and Presenters render projections. A browser database, socket process, or UI transcript must not become another source of Session, Workflow, gate, usage, or mutation state.

A LiveView prototype was considered for this local Presenter. It failed the strict Trusted Types browser kill-gate required for this surface. That is a v1 technology-selection result, not a permanent prohibition on LiveView; a future design may reconsider it if it satisfies the same security and truth boundaries.

The Presenter also needs to distinguish facts that are easy to conflate: execution state is not liveness, a runtime dependency gate is not a model-authored advisory, and source freshness or authority is not completion. Retries likewise must remain attempts within one logical unit rather than appearing as unrelated work.

## Decision

`monitor/` is a sibling Phoenix 1.8 application using Bandit. It is run from a source checkout and depends on Pixir by sibling path. Pixir core and the Pixir Hex package do not depend on Phoenix, Bandit, or the Monitor. Pixir Monitor is an experimental, source-only Presenter, not a packaged install or production-supported web product.

Pixir Monitor recomputes the renderer-neutral `pixir.presenter.run.v1` projection from authoritative Pixir evidence. It has no Presenter store. Canonical Pixir Logs remain truth; volatile runtime facts may supplement liveness only, and browser state is disposable. Retry attempts are grouped as one logical unit lineage rather than promoted to separate logical units.

The following four read-only flows are contractual for v1:

1. a bounded runs overview for discovery, grouping, and filtering;
2. a Workflow run view with its dependency DAG;
3. a parent-and-sibling fan-out view that does not invent dependency edges; and
4. a logical-unit inspector with bounded attempt lineage and referenced evidence.

Across those flows, execution, liveness, runtime dependency gate, model-authored advisory, and source provenance/freshness remain separate dimensions. In particular, an advisory cannot alter a runtime gate, and source mode cannot manufacture an execution result.

The browser obtains authoritative HTTP snapshots. Server-Sent Events carry only bounded `projection_changed` identifiers as invalidation hints; they do not carry or store projection truth. A bounded metadata-only watcher observes Log directory entries and regular-file metadata, while the hub coalesces pending hints per subscriber. SSE connections rotate after 300 seconds. Initial load, navigation without a usable snapshot, every rotation, reconnect or stream error, and every invalidation anomaly—including malformed, duplicate, reordered, or gapped events—cause an authoritative snapshot refetch. The UI never repairs truth from an SSE sequence.

The code-default source is the filesystem-backed projection source and does not depend on runtime `config.exs`. Inventory reads select the newest bounded N Logs and disclose total, selected, and truncated counts, so exceeding the selection bound does not make the Runs overview unavailable.

Presenter JavaScript and CSS are compiled into the BEAM and served without relying on source-checkout asset paths at runtime. The built escript exposes a structured self-check that starts the real ephemeral loopback listener, performs the one-use bootstrap internally, fetches both embedded assets and `/api/runs`, and does not print or persist capability material.

Endpoint restarts reinitialize active-port discovery, stale port state is cleared, and bounded discovery exhaustion remains visible without retry-log flooding. Automatic browser launch is Darwin-only. It transfers the capability-bearing URL through a private `0700` temporary directory and `0600` FIFO, never through process arguments.

Provider usage is projected only from durable `provider_usage` evidence. Missing or incomplete usage stays explicitly incomplete; the Monitor does not infer token usage from prose and does not invent monetary cost.

The HTTP surface is loopback-only and read-only:

- bind only literal `127.0.0.1` on an ephemeral port;
- validate the exact active-port `Host`, ignoring forwarded Host headers, and require the exact `Origin` wherever the route requires an Origin;
- evaluate Fetch Metadata fail-closed for authenticated and bootstrap requests;
- exchange a short-lived, one-use launch capability held only in memory for an opaque in-memory browser session;
- use an `HttpOnly`, `SameSite=Strict`, session-only cookie;
- serve a strict CSP with Trusted Types enforcement, self-hosted assets only, and no remote assets;
- render projected and hostile values as bounded literal text, never active markup, links, or implicit executable affordances; and
- expose no route that mutates runtime, Workflow, Session, workspace, evidence, projection inputs, policy, files, retries, resumes, cancellation, or apply state.

`POST /bootstrap` is the sole HTTP security-state transition. It does not mutate Pixir runtime state.

## Consequences

- Operators can inspect runs in a richer local browser surface while Pixir retains runtime and evidence authority.
- Phoenix and Bandit remain isolated from Pixir core and from the Hex distribution contract.
- Snapshot reads may repeat after harmless or hostile SSE conditions. This is intentional: refetching is safer than deriving truth from invalidation transport state.
- The absence of a Presenter store avoids reconciliation rules and migrations for a second truth source, at the cost of recomputation and bounded refetch traffic.
- Strict browser controls constrain framework and rendering choices. LiveView may be reconsidered only by passing the same kill-gates; this ADR does not ban it forever.
- The projection must preserve independent truth dimensions, logical retry lineage, source limitations, and incomplete usage rather than smoothing them into a simpler but misleading status.
- This implementation remains experimental and source-only. It does not expand the Pixir Hex package, stable public API, or production-support promise.

## Non-goals

- Do not make browser state, SSE order, or a Presenter database authoritative.
- Do not add runtime mutation controls, including execute, approve, retry, resume, cancel, apply, shell, policy, or file-open routes.
- Do not package Pixir Monitor in the Pixir Hex package or add Phoenix/Bandit to Pixir core.
- Do not promise production support, remote access, hosted deployment, or a packaged installer.
- Do not infer dependency edges for fan-out runs or merge execution, liveness, gate, advisory, and source into one status.
- Do not infer Provider usage or synthesize monetary cost.
- Do not treat the v1 LiveView rejection as a permanent framework ban.

## Verification Direction

Documentation and implementation review should verify:

- `monitor/` remains a sibling app whose dependency points toward Pixir, with no Phoenix/Bandit dependency flowing back into Pixir core or its Hex package;
- projection fixtures and schema validation cover the four flows, independent truth dimensions, retry lineage, source limitations, and usage derived only from `provider_usage`;
- HTTP tests cover literal-loopback binding, exact active-port Host, exact Origin where required, fail-closed Fetch Metadata, one-use launch expiry, cookie attributes, no-store responses, CSP/Trusted Types, local-only embedded assets, bounded hostile text, and the complete route inventory;
- inventory and watcher tests cover newest-N selection with total/selected/truncated disclosure, metadata-only polling, and coalesced pending hints;
- lifecycle tests cover 300-second SSE rotation with authoritative refetch, Endpoint restart port rediscovery, stale-state clearing, bounded exhaustion, and Darwin-only capability-safe browser handoff;
- browser tests prove malformed, duplicate, reordered, and gapped invalidations, stream errors, and reconnects all refetch authoritative snapshots; and
- route and UI audits find no runtime mutation path or implicit execution affordance.

The Monitor's documented source-checkout verification commands are the applicable implementation checks. Network exposure and production-support claims are outside this experimental contract.

## References

- `CONTEXT.md`: Harness, Presenter, Presenter Projection, Event, Log, Provider Usage.
- ADR 0003: stateless Turns and local Log as source of truth.
- ADR 0004: unified Event envelope and canonical versus ephemeral Events.
- ADR 0005: bounded output, structured errors, and I/O discipline.
- ADR 0016: source-install developer-preview scope.
- ADR 0017: minimal Harness core and Presenter boundary.
- ADR 0019: durable Provider usage evidence.
- ADR 0025: CLI/ACP-only Hex package scope.
- ADR 0026: runtime terminal-state and replay contract.
- `monitor/AGENTS.md` and `monitor/README.md`: local truth, security, route, and verification boundaries.
