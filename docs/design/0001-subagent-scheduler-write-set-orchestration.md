# Design note 0001 — A write-set scheduler for subagent orchestration

Date: 2026-06-02
Status: **Investigation / proposal, partially promoted by ADR 0012**
Verified-against: `lib/pixir/permissions.ex`, `lib/pixir/subagents/manager.ex`,
`lib/pixir/subagents.ex`, `lib/pixir/tool.ex`, `lib/pixir/event.ex` (all read 2026-06-02)

> **What this is.** A design investigation, not a decision. It reverse-engineers how the
> prompt/`.sh`-driven "workflow" patterns in other agent stacks orchestrate fan-out, names
> *why* they force a human to hand-map chained dependencies and read-vs-write permissions,
> and proposes how Pixir could make collisions safe-by-construction by reusing machinery it
> already owns (ADR 0011 `Pixir.Subagents.Manager`, ADR 0006 `Pixir.Permissions.mutating?/2`,
> ADR 0003 Log-as-truth). It records **options and caveats**, not a chosen path. Promote the
> chosen subset to an ADR before building.
>
> Vocabulary in `CONTEXT.md`. Decisions it builds on: ADR 0001/0003/0004/0005/0006/0011.
> `[VERIFY]` / `[CONTRADICTS]` tags below are honesty markers from an adversarial code-check
> pass — they flag claims that are *net-new* or that an earlier draft got wrong; keep them.
>
> **2026-06-03 update.** ADR 0012 promotes a smaller v1: `Pixir.Workflows`, a
> deterministic runtime plan over existing Subagents with structural dependencies,
> explicit read/write posture, conservative write-set serialization, and no new
> canonical workflow Event yet. The larger `Pixir.Scheduler`, typed outputs,
> tool-derived path write-sets, and merge-back/worktree ideas below remain future work.

## 1. The problem this came from

> *"Los agentes se pisan la cola entre ellos si yo no mapeo manualmente las chained
> dependencies y read-vs-write permits."*

Delegated workers step on each other's work unless a human manually maps (a) chained
dependencies and (b) which work reads vs writes. This note isolates the structural cause
and asks what Pixir's BEAM/OTP substrate lets us do instead.

## 2. How the surveyed orchestrators actually work

Five orchestration designs from other agent stacks were read in full. They fall into two
camps — a **prose/`.sh` queue** camp (the one that exhibits the failure) and a **call-graph
engine** camp (the contrast that doesn't).

| Design | Orchestration model | Dependencies | Read/write split | Collision prevention |
|---|---|---|---|---|
| Cloud-Infrastructure-Agent | Prose-queue — an LLM reads English delegation messages | Free-text `Dependencies: requires 1A` — **labels, not edges** | "Tool Strategy" prose; no split | **None.** "delegate one at a time" is a guideline |
| ralph-loop | Bash stop-hook re-invoke loop | Implicit (re-reads its own FS output) | None | session_id guard only |
| codex-exec-subagent | Bash TSV batch, serial-or-parallel | None in the manifest | Per-*batch* sandbox `-s` flag | Timestamped output filenames |
| subagent primitive (substrate of all above) | Agent tool + frontmatter allowlist | Hand-authored prose | allowlist **static-per-type & unenforced** | None — shared cwd by default |
| Workflow engine (the good contrast) | JS call-graph — `await` / `pipeline` / `parallel` | **Structural** (`await` *is* the edge) | `isolation:'worktree'` per writer | Worktree isolation + schema returns |

Key observed fact in the substrate camp: the per-agent tool allowlist is **advisory**. One
surveyed skill states verbatim that the Agent tool *cannot* enforce tool restriction — a
subagent gets the full tool set and is asked, by prompt only, to refrain. So even the coarse
read-only-vs-write boundary those stacks *appear* to have is not a runtime gate.

## 3. Root cause: the orchestrator is the scheduler, and the schedule lives in its head

In every prose-queue design the dispatcher is an LLM following English, and the "queue" is a
hand-authored sequence of delegation messages. Three structural absences compound and force
the human to be the scheduler:

1. **Dependencies are strings, not edges.** `requires 1A` enforces nothing; ordering is
   whatever the LLM does next. No machine refuses to start B before A's outputs exist.
2. **Results come back as prose, not typed values.** There is no `await`-point on a value,
   so the engine cannot even *see* that B consumed A's output — there is nothing to
   serialize on.
3. **No per-*item* write-set.** The only permission knob is static-per-agent-*type* and
   unenforced, so the dispatcher cannot answer the one question that decides
   parallelizability: *"does this batch only read?"* Five readers over one diff (safe to
   parallelize) and two writers editing the same file (must serialize) look identical.

With no edges, no typed returns, and no per-item write-set, the dependency DAG and the
write-conflict map can only live in the human's manual orchestration — which is exactly the
labor being complained about.

### Where the manual mapping bites (the concrete moments you become the scheduler)

- Authoring the queue and hand-filling each `Dependencies:` field, with no validator that
  asserted deps match the real data flow.
- Choosing what to dispatch next, because `Blocked`/`Ready` are just labels you re-read.
- Deciding parallel vs serial — judging by hand whether a "launch 5 agents" batch touches
  disjoint files, with no safe-to-parallelize signal from the engine.
- Handling retries: a retried task can overlap a still-running successor; nothing detects it.
- Synthesizing prose outputs by hand because results aren't typed/mergeable values.
- Avoiding shared-cwd collisions by injecting prompt warnings or serializing writers manually.

## 4. What the good engine does instead (transferable principles)

- **Data dependencies are structural, not metadata** — express "B needs A" as B consuming
  A's *value* (`await`), so the runtime serializes automatically. The call graph *is* the
  dependency spec; there is no free-text field to author or get wrong.
- **Pipeline without a global barrier** — each item flows stage-to-stage at its own pace
  (A can be in stage 3 while B is in stage 1). Correct per-item ordering, no hand-batched waves.
- **`parallel` is an explicit, bounded barrier primitive**, not a prose instruction an LLM
  interprets ad hoc.
- **Isolate writers instead of permissioning them** — give each write-capable worker its own
  filesystem (a worktree), so concurrent writes physically cannot collide. Isolation *is* the
  permission boundary.
- **Read-only fan-out is the cheap default** — reads don't conflict, so many readers share
  source freely; only writers pay the isolation cost. The read/write distinction is baked in,
  so the human never classifies it per task.
- **Return schema-validated values, not prose** — typed returns remove the parse-and-merge
  step and create the real `await`-points a scheduler can order on.
- **Bound concurrency at the engine** (a cap), not by the human guessing.
- **Fail loud and early on unsafe composition** — a conflicting parallel call surfaces as
  failing code at dispatch, not a silent file clobber discovered later.

## 5. The Pixir-native opportunity

The decisive insight: **Pixir already classifies read vs write per tool, and already isolates
each child's workspace.** The information the prose-queue stacks lack — and force the human to
supply — Pixir can *derive*.

What Pixir already has (all verified in source 2026-06-02):

| Good-engine concept | Pixir equivalent that already exists | Evidence |
|---|---|---|
| Engine-owned concurrency cap | `Manager` queues via `running_count(state, parent_sid) < spec.max_threads` | `manager.ex:67,710,743` |
| `max_threads` / `max_depth` defaults | `Subagents.default_limits/0` → `max_threads: 6`, `max_depth: 1` (config `:pixir, :subagents`) | `subagents.ex:14,18-19` |
| Writer isolation | `prepare_workspace/1` → `copy_snapshot` via `File.cp_r` into `.pixir/subagents/<id>/workspace` | `manager.ex:368-405` |
| Dependencies as data | `subagent_event` is a **canonical** parent-Log type; folded by `Subagents.reconstruct/1` | `event.ex:41`, ADR 0011 |
| Deterministic join | `wait_agent` blocks on a set of ids until all are `Subagents.terminal?/1` | ADR 0011 |
| **Per-task read/write posture** | `Pixir.Permissions.mutating?/2` + `child_permission_mode(%{sandbox_mode: "read-only"}, _) → :read_only` | `permissions.ex:48-61`, `manager.ex:817-818` |

`mutating?/2` as it actually reads (`permissions.ex:48-61`):

```
read, skills_list, skill_view, wait_agent, list_agents, update_plan  => false  (reader)
spawn_agent, send_input, close_agent, write                          => true   (writer)
bash(command)                                                        => not safe_command?(command)
_ (catch-all)                                                        => true   (writer)
```

So a `:read_only` child has a **provably-empty write-set**, and the scheduler can read each
task's read/writer posture straight off its permission mode. That is the lever no prose-queue
stack has.

## 6. Proposed design — `Pixir.Scheduler` (net-new)

A small `Pixir.Scheduler` GenServer that accepts queued sub-turns and, **routing all
execution through the existing `Pixir.Subagents.Manager`** (so capacity stays governed by
`max_threads`/`max_depth`, never a second authority):

1. **Derive posture, don't ask.** Fold each sub-turn's permitted tools through `mutating?/2`
   to label it reader or writer. A `:read_only` child ⇒ empty write-set.
2. **Build a write-set interference graph.** Edge between two tasks iff their write-sets
   overlap (write∩write) or a writer overlaps a reader (write∩read). Run a maximal edge-free
   set: disjoint writers parallelize, overlapping writers serialize, pure readers fan out free.
3. **Dependencies as Log-Event readiness** (the structural-edge principle). A sub-turn
   declares its inputs as references to canonical Events; the scheduler subscribes to the
   `Pixir.Events` bus and marks a task runnable when its declared input Events exist in the
   parent Log. "B needs A" becomes B consuming A's `subagent_event` — resume/fork-safe because
   readiness is a pure fold over the Log (ADR 0003/0004).
4. **Isolate writers** using ADR 0011's existing snapshot; pure readers may use
   `workspace_mode "shared"`.
5. **Fail early** on unsafe composition (intersecting writers, dependency cycle) with an
   ADR 0005 structured error at spawn, mirroring the existing `check_depth` guard.

### Options weighed

- **Option 1 — WriteSet conflict-graph scheduler (recommended core).** §6 above. Erases the
  manual read/write classification because the label is *derived* from `mutating?/2`. Cost:
  path-level write-sets are net-new (see §7).
- **Option 2 — GenStage pipeline with per-stage demand.** Literal "no global barrier"
  per-item pipelining. **Judged out of scope:** GenStage is a new dependency that *overlaps*
  the Manager's existing queue+capacity mechanism — running both risks two competing
  concurrency authorities. Revisit only for genuinely latency-uneven staged pipelines, and
  only after reconciling with the Manager's cap.
- **Option 3 — Log-Event dependency resolution (recommended dependency layer).** Folded into
  Option 1 as step 3. Alone it expresses *data* dependencies but not write-write
  anti-dependencies (two independent tasks both writing `main.go` have no Event edge yet must
  serialize), so it is **co-required** with the write-set graph, not an alternative.

**Recommendation:** ship Option 1 as `Pixir.Scheduler`, fold in Option 3 for dependency
ordering, keep Option 2 on the shelf.

## 7. Honest caveats (the real engineering)

These are the load-bearing risks. Several were inventions in an earlier draft that an
adversarial code-check corrected — kept here so the next person doesn't re-make them.

- **`[VERIFY]` Path-level write-sets do not exist.** `mutating?/2` decides reader/writer per
  `(tool_name, args)` call but emits **no path set**. The path-overlap edge needs per-tool
  "paths I would touch" metadata that must be added (likely via `__tool__/0` self-description
  + ADR 0005 dry-run plans). Until then write-sets default to the whole workspace and any
  writer serializes pessimistically.
- **`bash` write-set derivation is fundamentally hard.** An arbitrary command can touch
  anything, so `bash`-capable writers must conservatively claim the whole workspace until a
  dry-run plan or path-allowlist tightens it. Over-serialize (slow) vs under-claim (collide)
  is a real dial; ADR 0006's "prefer refuse over silent risk" stance says err toward
  over-serializing.
- **BEAM process isolation isolates *mutable state*, not the *filesystem*.** Each child
  Session is its own process (no shared ETS/GenServer state), but parallel writers to a shared
  tree still collide. Safety comes from the workspace snapshot, not from being separate
  processes. The snapshot (`File.cp_r`) is therefore **not optional** for writers — derivation
  decides scheduling, isolation guarantees safety.
- **`[CONTRADICTS ADR-0011]` There is no git worktree.** Isolation is a plain recursive copy
  (`File.cp_r`, `manager.ex:385-405`). The snapshot **excludes `.git`** (`excluded?/1`:
  `.git, .pixir, _build, deps, node_modules` — `manager.ex:405`), so a default-isolated child
  has *no git history* and cannot do real-repo/branch work at all. A `git worktree add` per
  writer (with merge-back) is a reasonable **net-new** upgrade for real-repo writers — but it
  is not current behavior; do not document it as such.
- **`[CONTRADICTS ADR-0005]` No `:conflict` / `:write_conflict` error kind exists.**
  `t:Pixir.Tool.kind/0` (`tool.ex:83-117`) has no such member. A write-conflict refusal must
  reuse an existing kind (`:permission_denied`, already used by `check_depth`; or
  `:invalid_args`) **or** add a kind deliberately as an ADR-0005-governed vocabulary change.
  It is not a free choice.
- **`[VERIFY]` Typed return schema is net-new.** ADR 0011 records only a *compact terminal
  summary* (the child's last `assistant_message` text) folded into parent input — **free
  text**, not a declared schema. The "serialize on a value you can see" property needs a
  per-agent output schema that does not exist yet.
- **`[VERIFY]` The concurrency cap is config-derived, not machine-derived.** Default
  `max_threads` is a fixed `6` (`subagents.ex:18`), not `System.schedulers_online()`-based.
  Tying it to schedulers is a proposed change, not existing behavior.
- **`[VERIFY]` No `Pixir.Scheduler`, interference graph, write-set, read-set, path-glob, or
  lease exists today.** The entire scheduler is net-new. Concurrency today is solely the
  Manager's `running_count < max_threads` queue gate.
- **Snapshot merge-back is unspecified.** How a writer's isolated-snapshot result lands back
  in the parent is undefined and is where a subtler conflict can reappear at merge time. This
  risk exists for the *current* `File.cp_r` snapshot too, not only for a future worktree tier.
- **Dependency cycles / stuck upstreams.** A `depends_on` cycle, or a task whose upstream
  never reaches terminal status (crashed/timed-out child), must be detected and surfaced as a
  structured error, else queued tasks hang forever. Cycle detection is net-new.
- **Terminology to get right.** Terminal statuses in code are
  `completed | failed | cancelled | timed_out | closed | detached`
  (`subagents.ex:8` `@terminal_statuses`) — not the bare word "finished". The canonical audit
  event is `permission_decision` (`event.ex:41`), not "permission_request". The Manager is a
  plain named GenServer (`Pixir.Subagents.Manager`) that starts children via
  `Pixir.SessionSupervisor` — **not** a `DynamicSupervisor`.

## 8. ADR / CONTEXT touchpoints (for the future ADR)

- **ADR 0011 (BEAM-native subagents)** — this *extends* it: adds dependency edges, a
  write-set conflict serializer, and (optionally) a worktree-escalation tier above the
  existing snapshot. Revisit the "shared workspace mode for trusted workflows" line so
  shared/snapshot is the read-only default and a worktree is the writer escalation.
- **ADR 0001 (single-process Session)** — *not* violated: "a Sub-agent is just another
  Session." The scheduler must spawn child Sessions through `Pixir.SessionSupervisor` under
  the Manager, never bare `Task.Supervisor` tasks.
- **ADR 0003 (Log-as-truth / stateless turns)** — the parent Log's terminal `subagent_event`
  entries are the dependency substrate; readiness is a fold-over-Log, so resume/fork
  reconstruct the DAG from the Log.
- **ADR 0006 (permissions `:auto`/`:ask`/`:read_only`)** — source of the derived write-set;
  `mutating?/2` + a `:read_only` child = empty write-set. Its "prefer refuse over silent risk"
  stance justifies conservative over-serialization.
- **ADR 0005 (ergonomics: dry-run, structured errors, distinct channels)** — unsafe
  composition fails early as `%{ok: false, error: %{kind, message, details}}` at spawn;
  `dry_run` should preview the derived write-set and chosen lane. The `:conflict` kind
  question lives here.
- **ADR 0004 (unified Event log)** — the scheduler is a `Pixir.Events` bus subscriber. Any new
  canonical type (e.g. `scheduler_decision` carrying the derived read/write-set and the
  parallel-vs-serial decision) or new field on `subagent_event` data is a Log-schema change
  that needs its own deliberate ADR (per `lib/pixir/CLAUDE.md`).
- **CONTEXT.md glossary** — `write-set`, `lane`, and `worktree` are **not yet** glossary
  terms; introducing them needs a CONTEXT/ADR update. Existing terms it leans on: Subagent,
  Workspace (the confinement floor), Tool (whose mutating flag is read), Log/History (the fold
  computing readiness).

## 9. Provenance

Produced by a 3-phase multi-agent investigation (recon of the 5 orchestrators in parallel →
single diagnosis → two independent BEAM-synthesis angles, each adversarially verified against
Pixir source). Every code claim in §5–§8 was re-checked by hand against the files listed in
the header before this note was written. The `[VERIFY]`/`[CONTRADICTS]` tags are the residue
of that verification pass and mark precisely the claims that are net-new or were corrected.
