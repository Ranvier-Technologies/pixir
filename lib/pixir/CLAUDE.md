# lib/pixir — the core

The spine: Events bus → Log → Session → Turn → Conversation, plus the front-end seam.

## Map

- `event.ex` / `events.ex` — the Event envelope + the `Registry`-backed bus. **The bus is
  the seam between core and every front-end** (ADR 0004); subscribers get `{:pixir_event, e}`.
- `log.ex` — append-only NDJSON; `fold/2` → History. Decode validates against
  `Event.canonical_types/0` (never `String.to_existing_atom` — that crashed cold resumes).
- `session.ex` / `session_supervisor.ex` — the Session GenServer (one unit of agency, ADR
  0001); a Turn is a 1-arity fn run in a supervised Task.
- `turn.ex` — the tool loop: record user_message → fold History → Provider → run tools → repeat.
- `skills.ex` / `workflows.ex` / `subagents.ex` — installed practices, structural
  Workflow scheduling, and supervised child Sessions. Workflow Templates are supporting
  Skill files, not eager prompt/catalog state.
- `conversation.ex` — the **UI-agnostic multi-turn driver** (ADR 0008). Every front-end's
  entry point: `start`/`send`/`await`/`interrupt`/`history`. Stateless over Session.
- `cli.ex` / `renderer.ex` — the terminal front-end, a thin presenter over `Conversation`.

## Invariants (break these and resume/replay break)

- **Log is the source of truth** (ADR 0003): never thread turn state in memory expecting it
  to persist — re-derive History from the Log each iteration.
- **Canonical vs ephemeral** (ADR 0004): only canonical Events (`user_message`,
  `assistant_message`, `reasoning`, `skill_activation`, `subagent_event`, `tool_call`,
  `tool_result`, `permission_decision`) are logged and get a monotonic `seq`.
  Deltas/status are ephemeral, bus-only. Adding a canonical type is a Log schema change
  → needs an ADR.
- Event `data` is **string-keyed** (round-trips identically through the Log); envelope keys
  are atoms.
- Bus access goes through `Pixir.Events`, never `Registry` directly.
- A terminal status is `done | error | interrupted` — all three (the Renderer/await loop
  hung on `interrupted` once; don't reintroduce that).

Reasoning-item capture/replay specifics: see ADR 0007 (`provider.ex` captures, `turn.ex`
records before tool_calls, `provider.ex` replays guarded by model).
