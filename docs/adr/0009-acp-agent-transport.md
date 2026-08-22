# 9. ACP (Agent Client Protocol) is the front-end transport; Pixir is the agent

Date: 2026-05-30
Status: Accepted
Amended 2026-08-16 (issue #515-A): ACP `session/delete` hide becomes a
workspace-confined sidecar consulted by the ACP presenter — see
"Amendment (2026-08-16, issue #515-A): durable session hide" below.
This amendment records persistence policy only; no new file is created
under `.pixir` until #515-B.

## Context

One early target front-end is **T3Code** (`pingdotgg/t3code`) — an open-source GUI for
agentic harnesses (Codex, Claude, OpenCode, Cursor) — where Pixir can be tested through
a local adapter. T3Code talks to agent backends over **Zed's Agent Client Protocol (ACP)**:
JSON-RPC 2.0, newline-delimited (ndjson), over the agent subprocess's **stdio**. It
vendors the official ACP schema (`v0.11.3`, `PROTOCOL_VERSION = 1`) in
`packages/effect-acp`, and the `cursor` provider already runs through this path
(`agent acp`).

This supersedes the earlier idea (ADR 0008's follow-up) of a bespoke HTTP/WebSocket tier:
ACP is a documented standard that T3Code — and other clients (Zed, etc.) — already
speak, so implementing it makes Pixir a drop-in agent for any ACP client, not just T3
Code. The bus-is-the-seam architecture (ADR 0004) and the UI-agnostic driver (ADR 0008)
mean the core needs no changes; ACP is just another presenter over the bus.

Two integration pieces follow, and they are independent:
- **Piece A (this repo):** Pixir ships an executable that speaks ACP as the *agent
  (server)* over stdio.
- **T3Code dogfood adapter:** a local adapter can validate ACP behavior, projection
  issues, and UX. It is not upstreamed or packaged as part of Pixir's beta.

The ACP/T3 relationship follows ADR 0017: T3 Code is a product Presenter and projection
layer, not the Pixir Harness. T3 may send prompts, mode/model changes, permission
decisions, and late UX context. Late Presenter UX facts should use
`_meta.pixir.presenter_context` on `session/prompt` when crossing ACP. Pixir owns
Session truth, History folding, Tool execution, Skills/Subagents/Workflows, Provider
input assembly, Provider transport, and `provider_usage` evidence.

## Decision

`pixir acp` starts the OTP app and runs an ACP **agent** over stdio. Concretely:

1. **A single `Pixir.ACP.Server` owns stdio.** There is one stdin/stdout pair per
   subprocess, so one supervised owner reads ndjson lines, decodes JSON-RPC, dispatches
   by method, and holds the `acp_session_id ↔ pixir_session_id` map. **stdout carries
   only JSON-RPC** (ADR 0005 channel discipline); diagnostics go to stderr. The terminal
   `Renderer` is unused in ACP mode — `ACP.Server` is an alternative presenter over the
   same Events bus (validating ADR 0008 again).

2. **Pixir executes all tools; ACP only reports.** T3 Code advertises `fs` and `terminal`
   client capabilities as **false** (`AcpSessionRuntime.ts:243`), so an agent must not
   delegate file/terminal work to the client. Pixir runs `read`/`write`/`edit`/`bash`
   through its own Executor (keeping Workspace confinement, permissions, dry-run,
   truncation) and reports via `session/update`. `agentCapabilities` advertise only what
   is true. `authMethods` advertises terminal auth through `pixir login`; Pixir still
   owns OAuth and Credential storage outside the ACP stdio channel (ADR 0002).

3. **Driving maps onto `Pixir.Conversation` (ADR 0008):** `session/new` → `start`;
   `session/prompt` → `subscribe` + `send`, then consume the bus translating events to
   `session/update`, resolving the request with a `PromptResponse{stopReason}` on the
   terminal status; `session/cancel` (a notification) → `interrupt`, and the active prompt
   resolves with `stopReason:"cancelled"`.

4. **Event → `session/update` mapping** (the Log is never altered — this is presentation
   only; canonical events stay durable for History/resume/replay):
   - `text_delta` (ephemeral) → `agent_message_chunk`; `reasoning_delta` →
     `agent_thought_chunk`. **Stream the deltas; do not re-emit the canonical
     `assistant_message`** (same text → would duplicate). **Fallback:** if a Turn emitted
     no deltas (e.g. the synthetic iteration-cap message), emit `assistant_message` as one
     chunk so no text is lost.
   - ACP assistant item ids are presentation ids, not Pixir History ids. Client-side
     adapters that project ACP into their own read model must not assume raw ACP ids such
     as `assistant:<acp-session>:segment:1` are globally unique across Turns, replay, or
     workflow/tool boundaries. The T3 Pixir adapter therefore scopes runtime assistant
     item ids by Turn before projection, e.g.
     `pixir:<turn_id>:<raw_acp_assistant_item_id>`, so
     `thread.turn-diff-completed.assistantMessageId` points at a message row for the
     current Turn instead of accidentally reusing a prior assistant message.
   - `tool_call` → `tool_call` (`toolCallId`=call_id, `title`, `kind` mapped
     read→read/write→edit/edit→edit/bash→execute, `status:"in_progress"`); `tool_result`
     → `tool_call_update` (`status` = `ok ? "completed" : "failed"`, `content`). A `bash`
     nonzero exit is a successful result with `ok:false` (ADR 0005) → maps to
     `status:"failed"`, not a protocol error.
   - Higher-level Pixir runtime tools such as `spawn_agent`, `wait_agent`,
     `list_agents`, `close_agent`, and `run_workflow` may include semantic metadata in
     standard ACP tool-call fields such as `rawInput`, `rawOutput`, title/detail, and
     content. This is still ACP presentation, not a new Log fact and not a custom
     JSON-RPC method. Clients such as T3 Code can use that metadata to project Pixir
     Subagents/Workflows onto their native collaboration/task read models without
     guessing from prose. In T3 Code specifically, this mapping belongs in the Pixir
     adapter path, not the generic ACP runtime, so Cursor and other ACP providers keep
     their existing projection behavior.
   - For T3 presentation, the primary user-facing unit should be the Pixir Subagent
     child Session. `run_workflow` remains the orchestration tool that schedules and
     summarizes work; the child `subagent_event` lifecycle should project as
     collaboration/task activity. This avoids hiding real concurrent workers behind a
     single workflow blob while still keeping the Workflow as Pixir's structural plan.
     Subagent presentation item ids should be scoped to the Pixir/ACP Session, not the
     Turn: a child Session may be queried, waited on, or closed across later Turns, so
     `pixir:<session>:subagent:<subagent_id>` should remain stable for that child while
     still avoiding collisions from user-supplied or restored Subagent ids.
     Pixir's richer lifecycle statuses collapse into the client's smaller item/task
     status model only for presentation: queued/started/running/input events are
     in-progress, successful terminal summaries are completed, provider/runtime failures
     and timeouts are failed, and states such as cancelled, closed, or detached keep their
     exact Pixir status in metadata/detail so the UI does not pretend they mean a normal
     failure or a successful answer.
     This presentation mapping does not relax permissions: spawning Subagents and running
     Workflows remain lifecycle mutations under ADR 0011/0012. Any future
     read-only/plan-mode explorer fan-out is a separate permission decision, not a T3
     adapter side effect.

5. **A failed Turn is reported as content, not a protocol error.** Verified against T3
   Code: `CursorAdapter.ts:990` treats any `stopReason ≠ cancelled` as `completed`, while
   a JSON-RPC error becomes a `ProviderAdapterRequestError` (a provider-failure view). So
   a turn-level failure (provider error, iteration cap, usage limit) is emitted as an
   `agent_message_chunk` + `stopReason:"end_turn"` (user reads it in the chat). JSON-RPC
   errors are reserved for genuine protocol faults (unknown method, invalid params,
   unknown session).

   *Amended 2026-08-02 (issue #465).* The chat rendering above stands unchanged — but it
   left a client unable to DISTINGUISH a failed Turn from a completed one without parsing
   chat text, which is how a raw provider error ended up rendered as an ordinary
   assistant message in the T3 investigation of 2026-07-31. The `session/prompt` RESULT
   therefore additionally carries `_meta.pixir.turn_failure` exactly when a
   `turn_failed` event was OBSERVED during the prompt. The contract is evidence-based:
   key presence means a `turn_failed` was seen, never an inference from the terminal
   shape — a refused prompt (`:busy`), a silent stall, or an idle timeout without
   evidence all claim nothing. The fields stay bounded and type-guarded —
   `terminal_status` and `error_kind`, each only when the producer recorded a binary;
   never the error message or details, which already travel as chat content. The facts
   ride REGARDLESS of the final `stopReason`: a cancel that raced a failure keeps
   `stopReason:"cancelled"` with the facts attached, and a Turn that recorded
   `turn_failed` but died before its terminal status carries them under the idle-timeout
   resolution too. `_meta` is the ACP extension channel this server already uses
   (`initialize._meta.pixir`, prompt `_meta` knobs), so clients that do not know the key
   are unaffected, and JSON-RPC errors remain reserved for protocol faults.

6. **Current ACP v1 surface.** Handle `initialize`, `authenticate`, `logout`,
   `session/new`, `session/prompt`, `session/cancel`, `session/load`, `session/resume`,
   `session/set_mode`, and `session/set_config_option`; emit `session/update`; originate
   `session/request_permission` when interactive permissions require it. `initialize`
   advertises only supported optional capabilities: `loadSession`, image prompts, and
   `sessionCapabilities.resume`. `session/list`, `session/close`, `session/delete`,
   audio prompts, embedded resources, client `fs/*`, and client `terminal/*` remain
   unadvertised until Pixir implements them deliberately.

7. **Model selection uses ACP config options.** The canonical ACP v1 model selector is a
   `SessionConfigOption` with `category:"model"` and `id:"model"`, updated through
   `session/set_config_option`. Pixir also keeps `_meta.pixir.models` and the
   `session/set_model` JSON-RPC method as Pixir/T3 compatibility extensions for existing
   local adapters. Those extensions are presentation protocol conveniences; they do not
   change Pixir's Provider prompt contract or Session Log semantics.

8. **Prompt content support is explicit.** Pixir supports text and image content blocks
   and accepts ACP baseline `resource_link` blocks as Session Resource descriptors. A
   readable local `file://` resource link may be copied into Pixir's Session Resource
   store; remote links remain descriptor-only unless a later explicit import/fetch
   records bytes. Pixir does not inline arbitrary linked contents into the stable
   Provider prefix, and it preserves the Log-as-truth / Provider-projection boundary.

## Amendment (2026-08-16, issue #515-A): durable session hide

The original Decision above still stands for what ACP is: a Presenter
over `Conversation` and the Events bus. Decision 6's historical sentence
that `session/list`, `session/close`, and `session/delete` remain
unadvertised is superseded in fact by #521, which advertised those
capabilities and implemented in-memory hide (`deleted_sessions` MapSet).
That MapSet dies with the ACP process; hidden Sessions reappear in
`session/list` after restart. This amendment decides the durable form
before #515-B creates any new path under `.pixir`.

#521's hide contract on the wire stays: soft-hide from list, Log
untouched, `gc` unchanged, delete-while-active rejected, missing or
already-hidden ids succeed, load-after-hide fails closed. What changes
is **where that hide lives**.

### Why amend ADR 0009

Hide is ACP presenter metadata, not a new runtime artifact class.
ADR 0009 already owns `session/delete`. A new ADR would split that
contract across two documents. Stretching 0009 would mean inventing a
general workspace metadata store. This amendment does not: it records
one hide sidecar for ACP `session/delete`.

### Owner

The local Harness owns hide. ACP `session/delete`, `session/list`,
`session/load`, and `session/resume` consult it. It is not editor state,
not a T3 or other Presenter Projection catalog, and not a conversation
Event.

Presenter asks; runtime is truth; the local Log remains the audit trail.

### Location

Workspace-confined sidecar, sibling of writer leases:

`<workspace>/.pixir/session_hides/<session_id>.json`

Per-id files, not a single catalog, not a line in the NDJSON Log, and
not `~/.pixir/`. Filename membership is the list filter. The JSON body
is bounded audit (`version`, `session_id`, `hidden_at`) with no
conversation content and no secrets.

Rejected alternatives:

- A `session_deleted` Event contaminates History with presentation
  state, requires opening a closed Session to append, would change Log
  bytes, and would be an ADR 0004 canonical-type schema change.
- An editor catalog is Presenter Projection, not Harness truth
  (ADR 0017). After restart, Pixir `session/list` would still rediscover
  the NDJSON.
- A global hide list under `~/.pixir/` is not workspace-confined; ACP
  list is workspace-scoped.
- Renaming or mutating the NDJSON would make hide look like Log trash.
- A marker inside `.pixir/sessions/` couples hide to the directory that
  `gc` and `Log.fold/2` scan for `*.ndjson`.
- One catalog JSON needs read-modify-write. `SessionLease` already
  established exclusive create of per-id files.

### Identity

ACP `session/delete` receives `sessionId` only. `session/load` and
`session/resume` already require `cwd`. After `session/close`, #521's
`forget_session/3` drops the workspace map entry, so delete cannot
assume the id is still registered.

Resolve `sessionId` → workspace as follows:

1. Validate the id with `Pixir.SessionId` first. Invalid ids are
   `-32602` and must not be echoed.
2. If the id is registered in this ACP Server (`state.sessions`),
   reject as delete-while-active (`-32602`).
3. Build the candidate workspace set: any absolute `cwd` the client
   sent (optional extra field; honor when present and absolute),
   workspaces this Server still has registered, workspaces this Server
   has successfully listed in this process, and the ACP process working
   directory.
4. For each unique candidate, `Paths.inspect_state_path/3` the Log
   `<ws>/.pixir/sessions/<id>.ndjson` without following symlinks.
   Skip a candidate that is unsafe. Do not guess a workspace by
   creating a hide file where no Log was observed.
5. Exactly one candidate has a regular Log → that workspace owns the
   hide file.
6. Multiple candidates have a regular Log → fail closed (`-32602`,
   ambiguous workspace).
7. Zero candidates have a regular Log → idempotent success (missing
   or already hidden). Do not invent a hide record in a guessed
   workspace.

`session/list` with `cwd` consults that workspace's hide directory.
`session/list` without `cwd` consults each known workspace's hide
directory. `session/load` and `session/resume` consult the hide file
in the supplied `cwd`. #521's resume path does not check
`deleted_sessions`; #515-B must apply the same fail-closed hide check
to resume as to load.

### Semantics

- Hide survives ACP process restart.
- The Session Log remains byte-identical. Hide never appends, rewrites,
  renames, or deletes NDJSON.
- `session/load` and `session/resume` of a hidden id fail closed
  (`-32602`, "session has been deleted").
- Delete while the id is registered in this ACP Server is rejected.
  A writer lease in another process is not ACP-active for this check;
  hide is presenter metadata, not a write lock.
- Missing or already-hidden ids succeed. Exclusive create against an
  existing hide file is success, not an error.
- An unsafe hide path (symlink, unexpected type) is fail-closed: do
  not re-expose the Session. `session/list` must not show an id whose
  hide path cannot be classified as absent.

### Relationship to GC

Hiding does not make a Session collectable. `pixir gc` reclaims
isolated Subagent workspaces and never deletes or moves NDJSON under
`.pixir/sessions`, including child Logs inside snapshots. Parent
Session Logs remain the only lifecycle evidence. A hidden Session's
Log still anchors referenced isolated workspaces. Hide files are not
a GC input and are not a GC target in this decision.

### Concurrency

#515-B must:

- validate the Session id before any path construction;
- create `.pixir/session_hides` through `Paths.ensure_state_dir/2`
  (component-at-a-time, no `mkdir_p`, no symlink follow);
- `lstat` every existing component below the trusted Workspace root;
- create the hide file with exclusive create (same atomic pattern as
  `SessionLease.acquire/2`);
- treat an already-present regular hide file as idempotent success;
- refuse existing or dangling symlinks with `unsafe_state_path`.

This is the same static tripwire as `Pixir.Paths`, `Pixir.Log`, and
`Pixir.SessionLease`: not a same-UID race-free guarantee.

This amendment does not implement the sidecar (#515-B). Until that
lands, shipped hide remains the in-memory `deleted_sessions` MapSet
#521 left.

## Consequences

- **Standards-based reach:** any ACP client can drive Pixir, not just T3 Code.
- **Core untouched:** ACP is a presenter over the bus + `Conversation`; no changes to
  Session/Turn/Log. Validates ADR 0004 + 0008 a second time.
- **Piece A is independently testable + live-verifiable** — feed JSON-RPC on stdin, read
  stdout, no T3 Code needed; unit-test via the same injectable provider/auth seams.
- **Channel discipline is load-bearing:** any stray stdout write (a stray `IO.puts`, a
  library banner) corrupts the JSON-RPC stream. ACP mode must route everything non-protocol
  to stderr.
- **Permission HITL is implemented through ACP:** the injectable asker maps to
  `session/request_permission` (`PermissionOption[]` ↔ the asker's decision; the
  `permission_decision` canonical event ↔ the chosen `kind`).
- **The T3Code adapter is a separate, dependent effort** in TypeScript; the current
  dogfood path is local-only and not an upstreamed Pixir beta deliverable.
- **Projection correctness is part of client integration, not Pixir core.** Pixir owns
  canonical `assistant_message` Events and ACP streaming updates; a client like T3 owns
  its own projection database. When a UI shows duplicated assistant text, compare
  `projection_turns.assistant_message_id`, `projection_thread_messages.message_id`, and
  `thread.turn-diff-completed.assistantMessageId` before changing Pixir's Log semantics.
- **Provider prompt assembly is not a T3 concern.** T3 supplies UX context; Pixir decides
  how that context enters the Prompt Contract, what belongs in the stable prefix versus
  late dynamic input, which Tool schemas are exposed, and whether WebSocket continuation
  or HTTP/SSE fallback is used. `previous_response_id` is Pixir/Provider transport
  optimization metadata, not T3 session truth.
- **ACP hide is Harness metadata, not History.** After the 2026-08-16 amendment,
  `session/delete` remains a Presenter request. The durable answer lives in
  `.pixir/session_hides/`, not in the Session Log and not in an editor catalog.
  Restart must not resurrect a hidden id in `session/list`. The NDJSON stays
  byte-identical, so resume/replay/fork/gc keep their existing evidence.
- **Identity is resolved, not guessed.** `session/delete` still accepts only
  `sessionId` on the wire. The Server maps that id onto a workspace by probing
  candidate Logs. Ambiguous multi-workspace hits fail closed; a missing Log is
  idempotent success and does not invent a hide file.

## Non-goals

- Do not implement the sidecar in this amendment (#515-B).
- Do not write a `session_deleted` Event or any other canonical type for hide.
- Do not hard-delete, rename, or rewrite NDJSON.
- Do not treat hide as chat trash or as a `gc` collectability signal.
- Do not store hide in an editor catalog, `~/.pixir/`, or `.pixir/sessions/`.
- Do not mix #516, #517, #520, #522, or #523.
- Do not add MCP, client `fs/*`, client `terminal/*`, or ACP v2.

## Verification Direction

This amendment is documentation only. Later #515-B must prove, with ExUnit
seams and no network:

```bash
mix test test/pixir/acp/server_test.exs
mix compile --warnings-as-errors
mix format --check-formatted
git diff --check docs/adr
```

Regression coverage should prove:

- a hidden id is absent from `session/list` after a new ACP Server process
  opens the same workspace;
- the Session Log bytes are unchanged by `session/delete`;
- `session/load` and `session/resume` of a hidden id return `-32602`;
- delete while the id is registered in this Server returns `-32602`;
- missing and already-hidden ids succeed;
- a Log present in two candidate workspaces fails closed;
- a symlink or other unsafe hide path does not re-expose the Session;
- `pixir gc` planning is unchanged for a hidden parent that still references
  isolated Subagent workspaces;
- no `session_deleted` Event is appended.

## References

- ADR 0003: stateless Turns; local Log is the source of truth.
- ADR 0004: unified Event envelope; adding a canonical type is a Log schema
  change.
- ADR 0005: structured errors; invalid Session ids are not echoed.
- ADR 0017: Presenters own presentation; Pixir owns runtime truth.
- `Pixir.Paths` / `Pixir.SessionLease`: workspace-confined state paths,
  `lstat` preflight, exclusive create, no symlink follow.
- `Pixir.Subagents.GC`: parent Session Logs are the only lifecycle evidence;
  NDJSON is never deleted or moved.
- Issue #515 (soft-hide, not Log trash); parent epic #512.
- #521: in-memory `deleted_sessions` MapSet.
