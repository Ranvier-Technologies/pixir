# Pixir v0.1 — Build Order

The v0.1 architecture is locked. This is the **build sequence** (dependency order) for
the walking skeleton. Rationale lives in `docs/adr/`; vocabulary in `CONTEXT.md`. This
doc is a roadmap, not a spec — small knobs are decided in code.

## Goal (definition of done)

`pixir "…"` runs one full **Turn** against the model on a **ChatGPT subscription**,
the model uses `read`/`write`/`bash` confined to the **Workspace**, output streams to
stdout, and the **Session** is persisted to an NDJSON **Log** that `pixir resume` can
continue. (Scope: ADR 0001–0004; "walking skeleton only".)

## Build steps

0. **Scaffold** — `mix` escript project `pixir`; deps: `finch`, `jason` (no `req_llm`).
   Establish `~/.pixir/` and project `.pixir/` conventions; seed `AGENTS.md`;
   gitignore `.pixir/sessions/`.

1. **Events** (ADR 0004) — `Pixir.Events` facade over a `Registry` (keyed by
   `session_id`); message shape `{:pixir_event, event}`. Event constructors building the
   envelope `{id, session_id, seq, ts, type, data}`. Canonical vs ephemeral types.

2. **Log** (ADR 0003/0004) — append-only NDJSON at `.pixir/sessions/<id>.ndjson`;
   append canonical events; `fold/1` reconstructs **History**.

3. **Session** (ADR 0001) — GenServer per Session via `Sessions.Registry` under
   `SessionSupervisor`; owns role, `seq` counter, and Log append. Runs each Turn in a
   **supervised `Task`**; "interrupt" kills the Task (load-bearing invariant).

4. **Auth** (ADR 0002) — `Pixir.Auth` GenServer; device-code OAuth (PKCE) →
   `~/.pixir/auth.json`; serialize token refresh; also accept `OPENAI_API_KEY`.

5. **Provider** (ADR 0002/0003) — Responses API client over Finch, `store: false`,
   stateless: fold History → input items; SSE parsing → emit ephemeral
   `text_delta`/`reasoning_delta` and the final canonical `assistant_message`; surface
   `function_call` items.

6. **Tools + Executor** — `Pixir.Tool` behaviour (`__tool__/0` + `execute/2`); registry
   of `read`/`write`/`bash`; central Executor validates args vs schema, confines paths
   to the Workspace, runs the tool, emits `tool_call`/`tool_result`. Tools obey the
   ergonomics contract (ADR 0005): dry-run, structured errors, token-bounded results.

7. **Turn loop** — inside the Session's Task: call Provider → if `function_call` items,
   run them via the Executor, append `function_call_output`, repeat until a final
   answer with no calls; enforce an iteration cap.

8. **CLI (one-shot)** — escript entry: `pixir login` (device-code), `pixir "prompt"`
   (one Turn, streams to stdout), `pixir resume <id>`. Self-describing `--help` per
   subcommand and channel discipline per ADR 0005 (prompt from argv/stdin; human
   output on stdout; diagnostics on stderr).

9. **Renderer** — a stdout subscriber that pattern-matches event `type` (plain line
   output). This is the first thin front-end over the bus (validates D-05).

## Verify

A real one-shot run in a scratch Workspace that reads a file, writes a file, and runs a
shell command — then `pixir resume <id>` continues it.

## Deferred (post-v0.1)

Interactive permission gate (`:ask`) · WebSocket prompt-cache transport · interactive
REPL · Skills (`SKILL.md`) · `req_llm`/multi-provider · sub-agents / branching ·
web + LiveView front-end (the trigger to adopt `Phoenix.PubSub`).

## Open knobs (decide in code)

Default `build` system prompt · tool-loop iteration cap · stream-idle / tool timeouts ·
device-code & `resume` UX copy · model-channel truncation policy (limits + marker
format, ADR 0005).
