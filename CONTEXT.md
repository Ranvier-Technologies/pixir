# Pixir — Context

Pixir is a minimal, local-first AI coding **harness** for the terminal, built on
the Elixir/BEAM runtime. It is the Pi harness philosophy (tiny core, do real
context engineering) reimagined with OTP supervision.

This document is the **glossary** of domain terms — the shared, precise language of
the project. It is intentionally free of implementation detail. Design and
implementation decisions live in `docs/adr/`.

## Glossary

### Harness
The system around a model that turns model completions into an agentic coding
runtime. In this 2026 agentic-coding sense, a Harness is not a test harness: it owns
the **Turn** loop, **Session** lifecycle, **History**, **Tools**, permissions,
workspace confinement, context loading, skill/subagent/workflow orchestration,
credential handling, and presenter/protocol surfaces.

Pixir is the Harness. Codex and Claude Code are also coding Harnesses in this sense.
A **Provider** supplies model completions to the Harness; it does not own agency.
Front-ends such as a terminal UI, ACP client, IDE, or T3 Code-style workbench may
present or drive a Harness, but they are not automatically the Harness unless they
own the agent loop and tool/runtime semantics.

### Presenter
A thin human or protocol-facing surface over the Harness. A Presenter may render
messages, collect input, subscribe to **Events**, parse slash commands, attach images,
or translate protocol frames, but it does not own **Session** state, **History**,
permissions, **Tools**, or the **Turn** loop.

The CLI renderer, ACP stdio server, a T3 Code adapter, and the source-checkout
Pixir Monitor are Presenters or Presenter adapters. Pixir Monitor is an experimental
sibling Phoenix/Bandit application; it reads recomputable Pixir projections without
adding Phoenix to the Harness core or the Hex package. Presenters may make interaction
nicer, but the Harness remains Pixir.

### Presenter Projection
The Presenter-side read model or UI state derived from Pixir **Events**. A Presenter
Projection may store chat bubbles, work-log rows, diff panels, tree views, or local
adapter bookkeeping so the UI can reload quickly. It is not the canonical replay source:
if it conflicts with the Pixir **Log**, the Log wins.

In Pixir Monitor, `pixir.presenter.run.v1` is recomputed from authoritative Pixir
evidence without a Presenter store. HTTP snapshots are authoritative; bounded SSE
messages are invalidation hints that trigger refetch, including after anomalies or
reconnect. Browser state is disposable. Execution, liveness, runtime gate,
model-authored advisory, and source provenance remain independent projection
dimensions, and retries remain attempts in one logical unit lineage.

In a T3 Code integration, the T3 database owns presentation state and product UX; Pixir
owns runtime truth. T3 may supply late UX context such as open files, selected ranges,
branch, model selection, diagnostics, and permission choices. Pixir still assembles
Provider input through its **Prompt Contract**, chooses Tools/Skills/Workflows, records
Events, and owns Provider transport decisions.

### Interactive Layer
The optional Presenter-side layer that turns human interaction into explicit Harness
inputs before a **Turn** starts. It may resolve `/skill` commands, expand prompt
templates, select **Skills**, attach files, render local UI state, or ask for missing
arguments. It must not become a second agent runtime.

In Pi terms, this is the useful part of "interactive": it prepares context and UX around
the core loop. In Pixir terms, it belongs at Presenter or adapter boundaries unless the
behavior changes durable **History** or runtime safety.

### Session
A single ongoing conversation between a user and Pixir. A Session has an identity,
an ordered **history**, and runs as exactly one **Agent** role at a time. A Session
may have a parent Session and child Sessions (see **Subagent**). The Session is the
unit of agency in Pixir — everything an agent "does" happens within one.

### Agent
A named **role** a Session runs as, defined by: a system prompt, the set of **Tools**
it may use, and a **permission profile** (e.g. `build` = full access, `plan` =
read-only). An Agent is configuration, not a separate running entity: switching the
Agent changes how the same Session behaves on its next **Turn**. (Contrast: in the
Kimojo reference, an Agent is its own process; in Pixir it is not.)

### Skill
A reusable package of instructions and supporting resources that can guide a Session
during a **Turn**. A Skill is neither an **Agent** nor a **Tool**: it changes what the
Session knows how to do, not which role it runs as or which capabilities the model can
invoke directly.

A Skill is an installed practice for stochastic agent work. It gives the model better
priors, language, judgment, examples, failure modes, and reusable workflow shapes. Its
supporting resources may include references that teach taste and terminology, templates
that structure outputs, and scripts that perform deterministic operations. Loading a
Skill does not execute those scripts or run a Workflow by itself; execution still happens
through explicit **Tools** and permissioned **Workflow** calls.

Discovering a Skill reveals only bounded metadata about the installed practice. Its
references, templates, scripts, and assets are supporting resources, not global catalog
entries; a Session loads them deliberately when the practice calls for them.

### Skill Activation
The fact that a **Skill** was selected by the user or by the model to guide a specific
**Turn**. A Skill Activation is part of durable **History**, because replaying or
resuming a Session must preserve which Skills shaped the Turn.

### Skill Context Hydration
The explicit materialization of dynamic context for a **Skill Activation** during one
**Turn**. A Skill package may declare allowed context sources, but the Activation
chooses whether to hydrate one and records the resulting snapshot as a canonical
`skill_context_hydration` Event.

Hydrated context is not part of the stable Skill body and is not conversational
History. When sent to the **Provider**, it belongs in the late dynamic portion of the
**Prompt Contract** for the current Turn. This preserves cache-friendly Skill
instructions while making the exact dynamic facts auditable and replayable.

Pixir does not auto-run arbitrary shell snippets embedded in `SKILL.md`. Hydration
sources run only through explicit, permissioned, bounded Pixir surfaces, usually
read-only. The source identifier should be named `context_source_id` to avoid confusion
with `Pixir.Provider`.

### PATCHMD
A repo-local customization maintenance practice for keeping a customized Pixir checkout
aligned with canonical upstream changes. PATCHMD is not a **Provider**, **Tool**,
**Workflow**, or runtime dependency. It gives humans and Sessions a bounded way to state
what is being synchronized, classify incoming changes, preserve local practices, and
record acceptance evidence.

### Patch Charter
The active statement of one bounded PATCHMD intent: the donor, target, included paths,
preserved paths, conflict clusters, public seams, and acceptance checks. A Patch Charter
does not replace repo law; it narrows one synchronization or customization task.

### Patch Classification
The judgment step that labels donor changes against target constraints. Typical outcomes
are to port, preserve, adapt, reject, or defer a change. Classification is the reviewable
boundary between upstream movement and user-owned customization.

### Patch Evidence Ledger
The durable record of a PATCHMD run: classification, acceptance, proof, status, and
handoff artifacts. The ledger records what was checked; it is separate from CI state and
external review state.

### Patch Operator
A Skill-backed installed practice for carrying out PATCHMD work. The Patch Operator
applies judgment and vocabulary; deterministic validation still happens through explicit
commands or Tools.

### Workflow Template
A reusable Workflow shape supplied by a **Skill** or by Pixir itself. A Workflow
Template captures a practice as a parameterized orchestration recipe: which **Agents**
or **Subagents** participate, which steps depend on which previous results, what
evidence is expected, and what to do on common failure modes.

A Workflow Template is not running state. It becomes a concrete **Workflow** only when a
Session instantiates it with task-specific arguments and executes it through Pixir's
normal permissioned Tool surface.

### Subagent
A delegated child **Session** that performs a bounded task for a parent Session. A
Subagent has its own **Turn** context, role/custom-agent configuration, workspace
snapshot, permission posture, lifecycle, and Log, while the parent records canonical
Subagent lifecycle events so resume/fork can reconstruct the parent-child relationship.
Running Subagents persist timeout budgets and deadlines so a restarted Subagents manager
can reattach still-live child Sessions and rearm their timeout.
A Subagent is not a **Skill** and not a **Tool**: Skills change instructions, Tools are
capabilities, and Subagents are supervised concurrent workers.

A **detached Subagent** is one whose durable parent Log proves it existed, but the current
Pixir runtime no longer has a live child Session/Turn handle after attempting recovery.
Detached Subagents remain queryable by `subagent_id` and `child_session_id`; they are
reported explicitly instead of disappearing as `not_found`.

### Delegation Context
The explicit late dynamic Provider context Pixir gives to one **Subagent** **Turn** so
the child knows the bounded delegation it is executing. Delegation Context can include
the Subagent id, parent and child Session ids, agent role, task, depth and max depth,
timeout and deadline, effective permission and workspace posture, host-boundary
guidance, and optional **Workflow Step** or **Checkpoint Bundle** expectations.

Delegation Context is not the stable Prefix, not standalone **History**, and not a new
canonical Event. It is rendered through the late dynamic portion of the **Prompt
Contract** for the child Turn. Durable truth remains the parent's canonical
`subagent_event` lifecycle entries and the child's own **Log**, unless a future ADR adds
workflow-level or delegation-specific Events.

### Workflow
A bounded orchestration plan that coordinates multiple **Subagents** as one unit of
work. A Workflow is neither a **Skill** nor an **Agent**: it defines dependency edges
between child Sessions, the intended read/write posture of each step, and the condition
for collecting terminal summaries.

Workflow dependencies are structural edges, not prose instructions. A step becomes
ready only after every step it depends on has reached a terminal result.

Workflows are where Pixir composes stochastic and deterministic work. Subagents perform
bounded stochastic work; Tools and scripts provide deterministic operations; the Workflow
runtime owns the structural ordering, concurrency, and failure accounting.

### Workflow Step
One delegated unit of work inside a **Workflow**. A Workflow Step names the **Agent**
role to run, the task to perform, its dependency edges, and its declared **Read Set** /
**Write Set**. At runtime, a Step executes as a **Subagent**.

### Checkpoint Bundle
The structured evidence a **Workflow Step** produces when downstream work may safely
consume its result. A Checkpoint Bundle may include the step id, Subagent id, terminal
status, concise summary, produced contract or artifact, verification evidence, known
limitations, and whether the result is safe to use as a dependency.

A completed Subagent does not automatically imply a complete Checkpoint Bundle. The
Workflow decides whether the terminal result is usable, partial, or requires
orchestrator attention.

### Partial Workflow Outcome
The honest result of a Workflow that did not fully complete but still produced useful
facts. A Partial Workflow Outcome records which steps completed, which steps failed or
timed out, which Checkpoint Bundles are usable, which dependent steps were held, and
what action is safe next.

Partial outcomes are not successful completion. They exist so presenters and parent
agents do not hide timeouts, retry loops, or missing Subagent results behind misleading
assistant prose.

### Seam Obligation
A named cross-step compatibility concern that must be checked before treating a set of
Workflow Step results as integrated. Seam Obligations are created when steps can run in
parallel but may still interact through a shared API, schema, file, UI contract,
permission rule, or user-visible behavior.

Seam Obligations are different from blocking dependencies: they do not necessarily stop
parallel execution, but they must be resolved or consciously deferred before a Workflow
claims release-ready completion.

### Read Set
The set of **Workspace** paths a **Workflow Step** intends to read. Read Sets are used
to decide whether shared-workspace readers can safely run beside writers.

### Write Set
The set of **Workspace** paths a **Workflow Step** may mutate. A read-only step has an
empty Write Set. If Pixir cannot derive or receive a narrower Write Set for a writer,
the safe default is the whole Workspace.

### Turn
One cycle of work a Session performs in response to a single user input: the input
goes to the model, which produces a response that may request **Tool** calls; those
tools run and their results are fed back, repeating until the model returns a final
answer with no further tool calls. The internal repetitions are *tool-loop
iterations*; the whole input-to-final-answer cycle is the Turn.

### Event
A discrete, timestamped fact about what happened in a Session, broadcast on the event
bus. Two kinds:
- **Canonical events** — `user_message`, `assistant_message` (final), `reasoning`,
  `skill_activation`, `skill_context_hydration`, `subagent_event`, `session_fork`,
  `branch_summary`, `history_compaction`, `provider_usage`, `turn_failed`, `tool_call`,
  `tool_result`, `permission_decision`. These are **durable**: appended to the
  Session's **Log** and they define its **History**. A normal `assistant_message` is a
  final answer; an `assistant_message` with `metadata.partial == true` is durable
  partial evidence after a Provider error and is not replayed as final assistant
  context.
- **Ephemeral events** — streaming deltas (text, reasoning), status, progress. These
  are broadcast for live display but **never persisted**.

Note the two faces of "reasoning" (ADR 0007): the **`reasoning` event** carries the
model's *encrypted reasoning item* (`rs_…`) — durable, because the Responses API
requires it re-injected on later turns; the **reasoning delta** is the human-facing
*summary text* — ephemeral, for live display only.

### Log
The per-Session, append-only sequence of **canonical Events**. The single source of
truth for a Session. There is no separate "messages" store — the Log is it.

### History
The ordered conversation state of a Session, derived as a fold over its **Log**.
History is a *projection*, not a stored thing: replaying the Log reconstructs History,
and **forking** a Session means replaying its Log up to a chosen point.

### Fork
An **inter-Session** branch: a new child Session whose **Log** replays a prefix of a
parent Session's **History** and then diverges. Pixir does not fork by adding sibling
message pointers inside one Log (contrast Pi `/tree` intra-file branching). Forks matter
for prompt cache because the shared prefix is exactly the part a Provider can reuse when
requests route to the same cache family via `fork_root_session_id`.

### Branch Summary
A lossy, durable synthesis of context carried into a **Fork** — not a second **History**
store and not **Compaction** of the active branch. In Pixir's first slice it is recorded
optionally when `pixir fork` creates a child Session, typically condensing the replayed
prefix the child inherited. It is analogous in *spirit* to Pi branch summarization (keep
abandoned-path context useful) but different in *trigger*: Pi attaches summaries when
navigating between branches inside one file with `/tree`; Pixir attaches them at fork
creation across Sessions. A Branch Summary affects future Provider input only when
recorded as a canonical Event with explicit limitations; the full replayed prefix in the
child Log remains authoritative for audit.

### Handoff
A transfer of working state to another human, agent, or Session, usually through a
summary or explicit instructions. A handoff may be excellent context, but it is not a
promise of byte-identical History and should not be treated as prompt-cache reuse by
default.

### Session Resource
A durable user-provided or Harness-created resource attached to a **Session** and
referenced from the **Log**. A Session Resource is not ambient prompt context: future
Provider input may include it, summarize it, or rehydrate it depending on the
**Prompt Contract**. The architecture is resource-general, but Pixir's first concrete
resource kind is **Image Attachment**. A payload-backed Session Resource has two
identities: `resource_id` names the Session/Log reference, while `content_sha256`
identifies the exact local payload bytes for dedupe, forks, cache evidence, and audit.
ACP `resource_link` blocks may become payload-backed Session Resources when Pixir can
read a local `file://` target; remote links are descriptor-only unless a later explicit
import/fetch records bytes.

### Image Attachment
A **Session Resource** whose payload is an image. An Image Attachment may be represented
as original visual content, a descriptor, a lossy visual digest, or a rehydrated Provider
image input. A summary of an Image Attachment is not equivalent to the original image.
The original image is projected to the Provider on the Turn where it is attached; later
Turns replay descriptor or digest by default and rehydrate the original only when visual
inspection is explicitly needed. Rehydration is an explicit Tool-mediated action: the
user or model may request it, but Pixir records the action instead of silently changing
Provider input.

### Resource View
The explicit Tool-mediated action that asks Pixir to rehydrate a **Session Resource**
for Provider inspection. A Resource View is not a generic file read and not a Presenter
preview: it is a recorded request to project a durable resource across the **Leakage
Boundary**. The first supported Resource View kind is image rehydration.

### Session Tree
The branching structure implied by parent and child Session relationships, **Subagents**,
**Forks**, and optional **Branch Summaries**. Pixir's canonical representation is still
the **Log**: a tree view is a read-only projection over durable Events and Session ids,
not a second store and not an intra-Log message graph.

### Compaction
The process of creating a bounded summary of older **History** when a Session grows
large enough that replaying every item into the Provider is wasteful or impossible.
Compaction is not deletion and not a Presenter convenience: any compacted summary that
affects future model input must be derivable from, or recorded as, durable Log-backed
state. Pixir's first concrete form is a canonical `history_compaction` Event: Provider
replay sees the latest checkpoint plus the recent uncompressed tail, while the full Log
remains authoritative for audit, repair, and deeper reconstruction.

### Summary
A lossy, human- or model-readable synthesis of prior context. A summary may be produced
by a human, a model, or deterministic code, and it can be useful context — but by itself
it carries no authority: it is not the **Log**, not a replay checkpoint, and never a
source of truth. In Pixir a summary appears as a bounded field inside a **Compaction**
checkpoint or a **Branch Summary** Event, always labeled with its limitations.

### Workspace
The single root directory a Session is allowed to operate within. All file **Tools**
resolve and confine paths to the Workspace; reads or writes outside it are refused.
Confinement is the v0.1 safety floor. (The interactive **permission gate** — asking
before risky operations — is post-v0.1; until then a role limits danger only by which
Tools it includes.)

### Workspace Strategy
The runtime choice for how a **Subagent** or **Workflow** step sees files. A Workspace
Strategy may use the parent **Workspace** directly, a bounded physical snapshot, or a
virtual overlay. The strategy describes fidelity and mutation semantics; it is not
itself a **Tool** and does not bypass workspace confinement or permissions.

Current implemented strategies are `shared`, `isolated`, and explicit Workflow-step
`virtual_overlay`. `spawn_agent` still accepts only `shared` and `isolated` until a
future child Session with a virtual toolset exists. Branch-backed worktrees remain an
accepted design direction, not a current public runtime surface.

### Git Worktree Strategy
A future opt-in **Workspace Strategy** for intentional repository mutation that needs a
real branch, commit, PR, Git merge behavior, or host dependency/toolchain evidence.
`git_worktree` is expensive evidence, not a default workspace convenience.

Pixir should avoid allocating a Git worktree when a bounded file artifact,
**Virtual Diff Artifact**, or patch artifact is enough. A Git Worktree Strategy uses a
lease-owned branch-backed physical workspace with explicit owner, base SHA, branch,
worktree path, cleanup policy, host-boundary summary, and no automatic merge-back to
the parent **Workspace**. Worktree paths are canonicalized and must remain under the
configured Pixir worktree root after resolving `.`/`..` segments and symlinks.

### Virtual Overlay
A **Workspace Strategy** where selected parent files are imported into a BEAM-native
virtual filesystem for shell-shaped exploration or scratch edits. The current runtime
surface is explicit Workflow-step opt-in with bounded `read_set` and
`virtual_commands`. A Virtual Overlay can expose commands such as virtual `find`,
`grep`, `sed`, `jq`, or `diff` without mutating the parent **Workspace** and without
running host binaries.

A Virtual Overlay is lower fidelity than a real workspace: it cannot run real `mix`,
`git`, `node`, package managers, compilers, tests, or arbitrary host shells. Exporting
changes from a Virtual Overlay requires an explicit **Virtual Diff Artifact**.

### Virtual Diff Artifact
A structured result artifact that represents changes made inside a **Virtual Overlay**.
A Virtual Diff Artifact records the imported **Read Set**, virtual command evidence,
changed files, unified diff or unsupported-file caveats, limits, fidelity caveats, and
an explicit `not_applied` status.

A Virtual Diff Artifact is not a parent **Workspace** mutation, not a host command, and
not a new canonical **Event** by itself. Applying it to a real Workspace requires a
future explicit permissioned apply or merge-back path.

### Workflow Event
A canonical **Event** type that records durable **Workflow** run decisions, not live
progress noise. Workflow Events use one Log type, `workflow_event`, with a string-keyed
`kind` such as `workflow_started`, `step_scheduled`, `checkpoint_decided`,
`step_held`, or `workflow_finished`.

Workflow Events do not replace `tool_result`, `subagent_event`, or **Checkpoint
Bundles**. They provide a replayable run spine for resume, fork, replay repair, and
diagnostics when a Workflow is interrupted or when a future runtime needs to
reconstruct graph/checkpoint state from the **Log**.

### Typed Checkpoint Output
An optional machine-readable payload or artifact reference attached to a **Workflow**
Checkpoint Bundle. A Typed Checkpoint Output is a harness-owned projection from
deterministic Pixir evidence first: child **Log** entries, **Tool** results, structured
artifacts, Workflow decisions, and Subagent lifecycle state.

Typed Checkpoint Outputs do not require every Subagent or model response to be strict
JSON. Ordinary summaries remain prose. Model-declared JSON is allowed only when a
Workflow Template or step explicitly asks for it, and Pixir marks that provenance as
lower-trust than deterministic projections. Typed payloads are used when downstream
dependency decisions, diagnostics, replay repair, presenters, or future resume logic
need stable structure.

Initial provenance values are `harness_projection`, `tool_result`, `artifact`,
`workflow_event_fold`, and `model_declared`. Structured artifacts such as a **Virtual
Diff Artifact** keep their own contract and may be referenced from a Typed Checkpoint
Output instead of being reshaped.

The current runtime emits Checkpoint Bundle `version: 2` with
`workflow_checkpoint.v1` typed payloads and `artifact_ref.v1` references for
`virtual_diff` evidence. A broader schema registry and template-declared typed model
payloads remain future work.

### Virtual Diff Apply
A future explicit operation that applies a **Virtual Diff Artifact** to a real
**Workspace**. Virtual Diff Apply is separate from **Virtual Overlay** execution:
producing a virtual diff never mutates the parent Workspace by itself.

The accepted contract is permissioned, dry-runnable, workspace-confined, hash-checked,
and auditable. v0 apply is all-or-nothing: conflicted, unsupported, truncated,
caveated, unreconstructable, or outside-Workspace changes prevent mutation rather than
silently applying a subset. Workspace confinement is checked against canonical,
resolved paths, including `.`/`..` and symlinks, before any mutation. During a
**Session** Turn, audit evidence uses the existing `tool_call`, `tool_result`, and,
when relevant, `permission_decision` Events instead of adding a new canonical Event
type.

### Tool
A capability the model can invoke during a **Turn** — e.g. `read`, `write`, `bash`. A
Tool declares a name, a description, and a parameter schema, and runs to produce a
result. Pixir — not the model and not the **Provider** — executes Tools: it validates
the arguments against the schema, confines file paths to the **Workspace**, runs the
Tool, and records a `tool_call` and `tool_result` **Event**. (v0.1 Tools: `read`,
`write`, `bash`.)

Tools are Pixir's deterministic operations boundary. A Skill may recommend a script or
command, and a Workflow may sequence many Tools through Subagents, but a Tool remains an
explicit, permissioned operation with dry-run, structured errors, and bounded output.

### Host Boundary Crossing
An operation where Pixir asks the host operating system to run or manage work outside
the BEAM runtime, especially external process execution through `System.cmd/3`,
`Port.open/2`, `:os.cmd/1`, shells, `git`, `mix`, `node`, or similar runtimes.

A Host Boundary Crossing is different from BEAM fanout: many Sessions, Subagents,
Tasks, timers, and mailboxes may still live inside one `beam.smp`, while every external
process spawn is visible to the host. Pixir treats those crossings as scarce,
observable, and rate-limited operations under ADR 0027.

### Provider-hosted Tool
A capability executed by the **Provider** as part of a model response, not by Pixir's
local Tool runtime. Provider-hosted Tools may appear in the OpenAI Responses `tools`
array, but Pixir does not validate their arguments, run them through
`Pixir.Tools.Executor`, or record them as local `tool_call` / `tool_result` Events.

Provider-hosted Tool evidence belongs to **Provider Usage** or another explicit
Provider-evidence surface. It is durable audit data, not a replacement for Pixir's
**Log**, and it is not replayed as conversational **History** unless a future **Prompt
Contract** says so.

### Provider
The backend that serves model completions to a Session. v0.1 targets a single
provider dialect — the **OpenAI Responses API** — reached with either kind of
**Credential**. Additional providers (Anthropic, local models, etc.) are post-v0.1.

### Web Search
Pixir's first concrete **Provider-hosted Tool**: OpenAI hosted `web_search` in the
Responses dialect. Web Search is useful when a Turn needs current external facts or
source citations. It is not MCP, not local browser automation, and not a Pixir local
Tool. Pixir may ask the Provider to run it, then record bounded lifecycle/citation/source
evidence so humans and agents can audit what happened.

Web Search output crosses the **Leakage Boundary** because the Provider receives the
query and search context. It should be opt-in at the product layer until Pixir has a
clear policy for which Turns may use current web evidence by default.

### Leakage Boundary
The point where Pixir projects local Session state, **History**, **Session Resources**,
Tool results, or other artifacts out of the user's machine to a **Provider**. Local
persistence inside Pixir is not leakage: Pixir is local-first, and the Log, resources,
attachments, artifacts, and Presenter projections live on the user's machine by design.
Provider input is the boundary where upload policy, rehydration, cache behavior, and
user intent matter.

### Provider Usage
The token and cache accounting returned by one Provider call. In the OpenAI Responses
dialect, the authoritative prompt-cache evidence is the final stream usage payload,
especially `cached_tokens` inside the input/prompt token details. Provider Usage is
durable Harness evidence, not conversational context: Pixir records it so humans,
root agents, Subagents, and Workflows can audit cost/cache behavior after the fact, but
it is not replayed back to the model as a message.

### Context Pressure
The active Session's Provider-window pressure, derived from **Provider Usage** and the
active model's conservative input-token window. Context Pressure drives warnings,
visible recovery, and Presenter gauges. It is not **History**, not Provider memory, and
not model input.

### Prompt Cache
The Provider-side reuse of a stable prompt prefix. A cache hit is proven only by
observed cached-token accounting, not by latency, intuition, or shorter answers. Prompt
cache is compatible with Pixir's local-Log truth because the Provider cache is an
optimization; it never becomes the source of Session state.

### Cache-Key Family
A short, non-secret routing hint that groups requests expected to share the same stable
prefix. A cache-key family should describe the stable surface — model, mode, Session or
fork family, Tool set, and Skill index — without raw paths, user text, timestamps,
request ids, emails, or secrets. It is portable across supported Provider transports:
if Pixir falls back from WebSocket to HTTP/SSE, the same cache-key family should travel
with the full replay request. It is a Provider routing hint, not memory, and it does
not guarantee by itself that two requests land on the same engine.

### Prompt Contract
The versioned agreement about how Provider input is layered: which material is stable
cacheable prefix, which is project-stable, and which is late dynamic payload. Authority
and cacheability are separate axes — a developer-authority fact can still arrive late,
because authority is carried by role, not position. Changing the Prompt Contract is a
deliberate lifecycle event: changes are batched, versioned, and observable in **Provider
Usage** evidence rather than shipped as invisible refactors.

### Prompt Cache Retention
A Provider request option for keeping eligible prompt-cache entries around longer than
the default ephemeral window. In the public OpenAI API this is expressed as
`prompt_cache_retention` (for example `"24h"`), but Pixir treats it as a dialect feature:
the ChatGPT/Codex subscription path must prove support before Pixir sends it. Retention is
still a cache policy, not Session persistence.

### WebSocket Continuation
Pixir's preferred Responses transport direction: keep a live WebSocket, create a
Response, and continue from its `previous_response_id` by sending only new input. The
continuation state is connection-local and finite, and it remains compatible with
`store: false` because the remote service is not Pixir's durable Session store. If the
socket closes, the model changes, the prompt diverges, compaction rewrites replay shape,
or a Session forks outside the shared prefix, Pixir falls back to full or compacted Log
replay over HTTP/SSE or a fresh WebSocket. Parallel Subagents use separate Provider
connections. A fallback may keep the **Cache-Key Family**, but it must not assume the
same `previous_response_id` is still usable.

### Credential
The proof of identity a Session presents to a **Provider**. Two kinds, both reaching
the same Responses Provider:
- **Subscription** — an OAuth token from *Sign in with ChatGPT (Codex)*, drawing on
  the user's ChatGPT Plus/Pro plan. Auto-refreshes; the primary path.
- **API key** — a pay-per-token `OPENAI_API_KEY`. The fallback path.
