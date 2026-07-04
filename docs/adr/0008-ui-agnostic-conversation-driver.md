# 8. A UI-agnostic conversational driver; the bus is the only observation seam

Date: 2026-05-29
Status: Accepted

## Context

The v0.1 CLI runs exactly one Turn per process (`one_shot`/`resume` start a Session,
run a Turn, print the resume id, halt). The *multi-turn loop* — accept input → run a
Turn → stream events → accept the next input while keeping the **Session** alive — does
not exist anywhere; the CLI inlines a single non-looping iteration of it.

That loop is needed identically by every front-end. The target front-end here is **not
the terminal**: the user drives Pixir from a non-Elixir UI (an HTTP/WebSocket client,
eventually). ADR 0004 already established that *"the event bus is the seam between the
core and every front-end"* and that front-ends are thin subscribers; ADR 0001 makes the
**Session** the single stateful unit of agency. So the missing piece is a small,
UI-agnostic *driver* over that core — and the terminal REPL the ROADMAP listed is just
one optional presenter of it, which this user will skip.

## Decision

Add `Pixir.Conversation`: a **stateless functional module** over the existing
`Session`/`Turn`/`Events` API. It owns orchestration, not state.

- **Not a process.** The `Session` GenServer already owns turn state, history, `seq`,
  and interrupt. A second process would duplicate ownership and re-introduce the
  two-store hazard ADR 0004 was written to avoid. Any *per-client* state (a socket, a
  pending permission reply) belongs to the **transport tier**, not the driver.
- **`start(opts)`** — no `:id` mints a new Session; an `:id` resumes it, centralizing the
  resume robustness previously inlined in `CLI.resume` (the `Log.exists?` guard and
  corrupt-log-fold → structured error, not a `MatchError`). Re-starting an
  already-running Session **idempotently returns the live one** (the supervisor's
  `:already_started` path), so a reconnecting client can reattach.
- **`send(session_id, prompt, opts)`** — the generalized one-turn driver:
  `start_turn(sid, fn ctx -> Turn.run(ctx, prompt, …) end)`. Non-blocking; the caller
  observes via the bus.
- **Observation is the `Events` bus, full stop.** The driver invents no new streaming
  abstraction. An out-of-process UI's transport tier subscribes
  (`Events.subscribe(session_id)`) and forwards each `{:pixir_event, event}` over its
  socket as JSON (events are already string-keyed/JSON-shaped, ADR 0004). For
  *in-process* callers (tests, an optional terminal presenter) the driver offers
  **`await/2`**: consume until a terminal `status`, with an optional `on_event` callback
  (mirroring `Provider.stream`'s `:on_delta`), returning `:done | :error | :interrupted
  | :timeout`.
- **Permissions stay injectable.** The driver implements no prompting; it passes the
  `asker` function through to `Turn.run` unchanged (defaulting to the permission-mode
  behavior, so `:auto` works immediately). Async, remote permission decisions are a
  **transport-tier** concern: that layer supplies an asker closure that blocks the Turn
  task while it round-trips the decision over its socket. Deferred deliberately, not
  silently.

The CLI is refactored onto the driver (its front-end logic becomes a thin
`await` + terminal renderer), which both proves the seam and deletes the duplicated
turn/resume logic.

## Consequences

- **One multi-turn surface reused by every front-end** — terminal, HTTP/WS, editor, or
  an embedding Elixir app. The HTTP/WS tier (a later step) adds: a transport endpoint,
  Log-backed cursor backfill for reconnects, the `Phoenix.PubSub` backend swap (already
  anticipated in `events.ex`), the async permission path, and auth/multi-session
  management — none of which the driver itself needs to know about.
- **Fixes a latent bug:** the Renderer's `consume_until_done` treated only
  `done`/`error` as terminal, so an `interrupted` turn hung until idle-timeout. `await`
  (and the refactored Renderer path) treat `interrupted` as terminal.
- **The terminal REPL is now optional** — it would be `await` + a render callback in a
  read-input loop. This user can skip it entirely.
- **Cost:** the driver is a deliberately thin layer; the temptation to grow it into a
  stateful session manager must be resisted — that state is the transport tier's.
