# Pixir — Roadmap (post-v0.1)

The v0.1 walking skeleton is implemented and **verified live end-to-end** (see
`AGENTS.md` status). This roadmap tracks what's next: features the plan/grill consciously
deferred (A), knobs still to tune (B), hardening gaps found while building the skeleton
(C), and the open beta release gate (D). Rationale lives in `docs/adr/`; vocabulary in
`CONTEXT.md`.

## A. Deferred features (from PLAN-v0.1 / the grill)

| Area | Notes | Source |
|---|---|---|
| Permission `:ask` gate | **Done (v1)** — `:auto` default · `:ask`/`:read_only` · safe-command list. Session-scoped "remember/allowlist" deferred | ADR 0006 |
| Conversational driver | **Done — `Pixir.Conversation`** (ADR 0008): UI-agnostic multi-turn loop; CLI refactored onto it. Terminal REPL is now just an optional presenter (deferred — target UI is non-Elixir). | ADR 0008 |
| ACP transport | **Done (ADR 0009) — verified live.** `pixir acp`: `Pixir.ACP.{Server,Protocol,Translate}` over `Conversation`, an ACP agent over stdio. Drives any ACP client. T3Code is currently dogfood through a local adapter, not an upstreamed public install path. | ADR 0009 |
| T3Code dogfood adapter | Local-only adapter used to validate ACP behavior, projection issues, and UX. It is not upstreamed and is not part of the beta packaging contract. | ADR 0009, ADR 0016 |
| Provider usage / prompt-cache / WebSocket transport | **Done for durable `provider_usage` and cache/WebSocket smokes.** Pixir now treats WebSocket as the preferred Provider transport direction with HTTP/SSE fallback, while continuing to tune continuation, fallback recovery, and cache-key evidence. | ADR 0019, ADR 0020 |
| `req_llm` / multi-provider | Anthropic, local models — a 2nd dialect behind the Provider seam | ADR 0002 (deferred) |
| Skills (`SKILL.md`) | **Done (ADR 0010)** — progressive discovery, `skills_list`/`skill_view`, durable `skill_activation` snapshots, Provider replay, no-network smoke. | ADR 0010 |
| Subagents | **Done (ADR 0011) for bounded supervised child Sessions.** Pixir has explicit spawn/wait/send/close/list tools, lifecycle `subagent_event`s, durable terminal states, compact replay summaries, isolated workspaces, diagnostics for stale/missing outcomes, and no-network fanout gauntlet coverage. Still experimental: long-running non-blocking client UX and cross-presenter live child-status projection. | ADR 0011, `docs/benchmarks/fanout-regression-gauntlet.md` |
| Workflows / subagent scheduler | **Done (ADR 0012) for v1 structural Workflows.** `Pixir.Workflows` validates dependency edges, runs through `Subagents.Manager`, fans out read-only steps, serializes overlapping writer write-sets, exposes `run_workflow`, and ships no-network tests/smoke. Workflow partial outcomes are honest runtime outcomes, not success. Still deferred: typed outputs, automatic merge-back from isolated writer snapshots, path-level tool-derived write-sets, and canonical workflow-level Events. | ADR 0012, `docs/design/0001-subagent-scheduler-write-set-orchestration.md` |
| Session Resources / Image Attachments | **Initial image slice done (ADR 0021).** Pixir ingests attachments and ACP `resource_link` blocks as durable Session Resources, projects images to the Provider when attached, and keeps later replay descriptor/digest-first unless `resource_view` explicitly rehydrates. Subagent inheritance and non-image Provider projection remain deferred. | ADR 0021 |
| Provider-hosted Web Search | **Deterministic slice done (ADR 0022).** Web Search is a Provider-hosted Responses tool, not a Pixir local Tool. Dry-run smoke and parser/request-shape tests are in place; live smoke remains opt-in. | ADR 0022 |
| Skill Context Hydration | **Design accepted (ADR 0023); implementation follow-up.** Hydrated Skill context should be explicit, canonical, permissioned, and late-bound, not hidden `SKILL.md` interpolation. | ADR 0023 |
| Subagents benchmark | **Done for first verifiable suite + real-network capability matrix V0 + correctness gauntlet.** Pixir stress adapter covers `N = 1,5,10,25,50`; paired T3 harnesses observe Pixir `spawn_agent`/`wait_agent` and Codex `collabAgentToolCall` `spawnAgent`/`wait`; `mix pixir.bench.real_subagents` records the cheap provider/model capability matrix; `mix pixir.bench.fanout_gauntlet` guards direct CLI and parent-led fanout honesty without network calls. Remaining work is the seeded fixture, `benchctl`, strict scoring, usage reconciliation, and T3-visible non-blocking status/result retrieval for long-lived child Sessions. | `docs/benchmarks/subagents.md`, `docs/benchmarks/subagents-report.md`, `docs/benchmarks/real-network-subagents.md`, `docs/benchmarks/fanout-regression-gauntlet.md` |
| Branching / fork | Fork a Session by replaying its Log to a chosen point; may build on Subagent parent-child metadata but remains a separate product surface. | CONTEXT |
| Web + LiveView | Web front-end — the trigger to adopt `Phoenix.PubSub` | PLAN |
| OAuth browser flow | The `127.0.0.1:1455` callback (device-code already shipped) | ADR 0002 (fast-follow) |

## B. Open knobs (decide/tune in code)

- Default `build` system prompt (basic one exists)
- Tool-loop iteration cap (currently 12)
- `bash` timeout — *resolved*: `bash_timeout_ms` (default 120s); **stream-idle timeout still open**
- Provider retries — `max_retries` (default 2, capped exponential backoff)
- Device-code / `resume` UX copy
- Model-channel truncation policy (currently 16 KB, ADR 0005)
- Model id — *resolved*: `config :pixir, :model` → `PIXIR_MODEL` → `~/.pixir/config.json` → `gpt-5.5`

## B2. Pi-inspired harness ergonomics

ADR 0017 locks the product boundary: Pixir should borrow Pi's useful minimal-core
shape without moving interaction glue into the core Turn loop.

Near-term slices:

1. **Presenter preflight for interactive commands.** Keep `/skill`, prompt template
   expansion, model selection, and adapter UX outside the core unless they create
   canonical History.
2. **Session tree projection.** Expose a read-only tree/fork projection over Logs,
   parent-child Session ids, Subagent lifecycle events, and future branch summaries.
   Do not create a second message store.
3. **Compaction and replay repair.** **Initial slice done (ADR 0018).** Pixir records
   canonical `history_compaction` checkpoints, replays latest checkpoint plus tail, and
   reconciles pending `tool_call` Events before a new Turn or interrupt. The
   model-assisted compaction contract is in code as a short developer instruction plus
   strict schema, but networked/model-assisted compaction is still deferred alongside
   automatic thresholds and UX around compaction previews.
4. **Installable practice boundary.** Treat Skills, Workflow Templates, and PATCHMD
   patcher repos as the growth mechanism before considering package-catalog behavior.
5. **Adapter safety rails.** Put T3-specific doctors, repairs, and projection checks in
   the T3 adapter/patcher repo, not Pixir core.

## D. Open beta scope

ADR 0016 locks the first open beta as terminal/ACP-first developer preview: source
install remains the baseline, Hex is not a beta prerequisite, T3Code dogfood adapter is
not upstreamed, telemetry is off by default, and the release gate focuses on first-run
UX, diagnostics, docs, CI/CD, and honest Subagent/T3 limitations. ADR 0025 separately
allows Hex only as a CLI/ACP distribution path.

## C. Hardening gaps (found while building — beyond the formal plan)

What separates the walking skeleton from a daily-usable MVP:

1. ~~Reasoning items not persisted/replayed.~~ **Done (2026-05-29, ADR 0007) — verified
   live.** The encrypted reasoning item (`rs_…`) is now a canonical `reasoning` event,
   recorded before its paired `tool_call` (so `seq` keeps `rs_`<`fc_`) and re-injected as
   `input` by the Provider, dropping items captured under a different model (the
   `model`-guard mirrors Pi's `isDifferentModel`). Arrival-order capture preserves
   intra-turn interleaving for free. A live 2-Turn session persisted four `rs_` items
   (with `encrypted_content`) and the Responses API accepted them on `resume`.
   **Deferred:** strict id-based `fc_`/`rs_` pairing (Pixir sends no `fc_` ids; order
   suffices today) and any `encrypted_content` staleness handling (no evidence it
   expires; resolve empirically if ever 400'd).
2. ~~No retry/backoff.~~ **Done** — `Provider.stream` retries network/`:rate_limited`/5xx
   with capped exponential backoff (`max_retries`); terminal errors aren't retried.
3. **Stream-idle timeout** still open. ~~`bash` can hang~~ **Done** — `bash` runs via a
   `Port` and is killed on `bash_timeout_ms` (default 120s).
4. ~~Token refresh only stub-tested.~~ **Done (2026-05-29) — verified live.** Forced a
   stale `expires_at` and ran a real Turn: `Pixir.Auth` refreshed against `auth.openai.com`,
   rotated **both** access and refresh tokens, and re-persisted the fresh credential (0600)
   before returning — closing the refresh-token-rotation hazard. A refresh failure no longer
   "kills the session": a rejected refresh token (4xx) is re-mapped to an actionable
   `:not_authenticated` ("run `pixir login`"); a transient failure keeps its retryable
   `:network` kind. Failure-path tests in `auth_test.exs`.
5. ~~Missing `edit` tool.~~ **Done** — `Pixir.Tools.Edit` (exact match, unique-unless
   `replace_all`, dry-run, atomic write).
6. ~~`bash` + `resume` not yet verified live.~~ **Done (2026-05-29)** — verified live end-to-end
   on `gpt-5.3-codex-spark`: a 2-Turn session (write+bash, then `resume` → edit+bash; the model
   correctly recalled the pre-edit value from folded History). Closing this **surfaced and fixed a
   real bug**: the Log type decoder used `String.to_existing_atom`, so every cold `resume`
   crashed (`:unknown_event_type` on `user_message`) because the writer's atoms weren't loaded in
   the fresh process — resume was in fact broken, not just unverified. Now validates against
   `Event.canonical_types/0`; CLI resume also folds `start_session` into its `with` so a
   bad fold prints a structured error instead of a `MatchError`. Regression tests in `log_test.exs`.
7. ~~No CLI interrupt (Ctrl-C).~~ **Done** — the escript traps SIGINT and routes it
   to `Session.interrupt/1` through the CLI presenter path.
8. ~~`config.json` reads only `model`.~~ **Done** — `~/.pixir/config.json` now covers
   model, compaction, timeout, permission, and transport-related knobs.
9. **T3-visible long-running Subagent lifecycle UX is not yet complete.** Pixir can spawn
   and wait on supervised child Sessions, Workflows can run structural dependency graphs,
   and terminal Subagent outcomes are now durable and diagnosable. A T3 user should
   eventually be able to launch long-running Subagents, keep the root Turn non-blocking,
   inspect live child status on demand, and retrieve durable terminal summaries after
   reconnect/reload. That client UX is distinct from the runtime truth fixes and from the
   no-network fanout gauntlet.

## Suggested order toward an MVP

1. ~~Permission `:ask` gate (ADR 0006)~~ — **done (v1)**
2. ~~`edit` tool + retry/backoff + `bash` timeout~~ — **done**
3. ~~Close live verification of `bash` + `resume`~~ — **done** (and fixed a resume-breaking bug; see C6)
4. ~~Persist/replay reasoning items (correctness on multi-tool turns)~~ — **done (ADR 0007)**
5. ~~Conversational driver (`Pixir.Conversation`, ADR 0008)~~ — **done**; CLI refactored onto it
6. ~~Live token refresh hardening~~ — **done (C4)**
7. ~~Design the non-Elixir UI transport~~ — **done (ADR 0009)**: it's ACP, not a bespoke
   HTTP/WS tier. Any ACP client can drive Pixir over stdio; T3Code remains local dogfood.
8. ~~Build the ACP agent (Piece A)~~ — **done (2026-05-30) — verified live.** `pixir acp`:
   `Pixir.ACP.{Server,Protocol,Translate}` over `Conversation`. v1 minimal
   (`initialize`/`session/new`/`session/prompt`/`session/cancel` + `session/update`),
   `:auto` only. **Verified live by piping JSON-RPC on stdin**: full handshake, a real turn
   that wrote a file via the tool (executed internally, reported as `tool_call`/`tool_call_update`),
   mid-turn `session/cancel` → `cancelled`, unknown method → -32601, malformed JSON → -32700
   without crashing. The adversarial pass **caught + fixed a stdout-pollution bug** (the OTP-28
   Logger redirect was a no-op → logs leaked to stdout, corrupting ndjson) with a regression
   test that exercises the real escript. 162 tests green.
9. **T3Code dogfood adapter** — local adapter for ACP pressure testing; not upstreamed and not packaged.
   (Terminal REPL stays deferred — ACP keeps it a thin optional presenter.)
