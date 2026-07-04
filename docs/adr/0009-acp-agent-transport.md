# 9. ACP (Agent Client Protocol) is the front-end transport; Pixir is the agent

Date: 2026-05-30
Status: Accepted

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
