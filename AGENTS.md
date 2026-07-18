# AGENTS.md - Pixir Harness

Pixir is an OTP-native, local-first coding-agent harness. The runtime spine is:

```text
Session -> Turn -> Provider -> Tools
```

The append-only Log is truth, the terminal CLI is the default presenter, and ACP over
stdio is the main client transport.

## Progressive Discovery

Do not read the whole repo up front. Load context in this order and stop once the task
is grounded enough:

1. **Start here:** this file gives the architecture map, invariants, commands, and beta
   stance.
2. **Human quickstart:** `README.md` and `docs/open-beta-quickstart.md` explain the
   source-install developer-preview path.
3. **Vocabulary:** `CONTEXT.md` defines Harness, Session, Agent, Skill, Workflow,
   Subagent, Event, Log, History, Workspace, Tool, Host Boundary Crossing, Provider,
   Credential, and PATCHMD. Use those meanings exactly.
4. **Architecture decisions:** read only the ADRs relevant to your change:
   - `0001` Session is the process; Agent is role/configuration.
   - `0002` ChatGPT subscription OAuth + OpenAI Responses API.
   - `0003` stateless Turns; local Log is source of truth.
   - `0004` unified Event envelope and canonical vs ephemeral events.
   - `0005` agent ergonomics: dry-run, help, structured errors, I/O discipline.
   - `0006` permission model.
   - `0007` encrypted reasoning item persistence/replay.
   - `0008` UI-agnostic Conversation driver.
   - `0009` ACP transport over stdio.
   - `0010` Agent Skills with progressive disclosure.
   - `0011` BEAM-native Subagents.
   - `0012` structural Workflows over Subagents.
   - `0013` Skill-backed Workflow Templates.
   - `0014` Workflow Checkpoint Bundles and honest partial outcomes.
   - `0015` PATCHMD customization maintenance.
   - `0016` open beta scope as source-install developer preview.
   - `0017` minimal Harness core and Presenter boundary.
   - `0018` durable History compaction and replay repair.
   - `0019` Provider usage, prompt-cache observability, and WebSocket continuation.
   - `0020` versioned Prompt Contract, cache-key family, and compaction triggers.
   - `0021` Session Resources and Image Attachments.
   - `0022` Provider-hosted Web Search evidence, not local Tool execution.
   - `0023` Skill Context Hydration as explicit, canonical, late-bound context.
   - `0024` Session Fork and Branch Summaries.
   - `0025` Hex package scope.
   - `0026` Runtime terminal-state and replay contract.
   - `0027` external command execution as a bounded host boundary.
   - `0028` Workspace Strategies and future virtual overlays.
   - `0029` Virtual Overlay changes export `virtual_diff` artifacts.
   - `0030` explicit apply and merge-back semantics for `virtual_diff`.
   - `0031` Git worktrees as lease-owned strategy for intended repo changes.
   - `0032` minimal Workflow Events for durable run decisions.
   - `0033` typed checkpoint outputs as harness-owned projections.
   - `0034` Delegate service runtime residency before async start.
   - `0035` Write-capable Sessions require an external evidence mirror.
   - `0036` Idle-timeout recovery does not auto-resume ambiguous work.
   - `0037` Anthropic provider registry routing, pa1 prompt contract, explicit
     cache control, and seam-parity transport.
   - `0038` Pixir Monitor is an experimental sibling source-checkout SPA using
     authoritative snapshots and bounded SSE invalidation hints.
   - `0039` Provider-output truncation is neutral, durable success evidence.
5. **Nearest local instructions:** read the closest subtree `AGENTS.md` before editing
   code, docs, tests, benchmarks, or ADRs.

## Screaming Architecture

The repo should reveal what Pixir is by its module names:

- `Pixir.Event` / `Pixir.Events` - Event envelope and pub/sub bus.
- `Pixir.Log` - append-only NDJSON under `.pixir/sessions/`.
- `Pixir.Session` / `Pixir.SessionSupervisor` - one process per conversation.
- `Pixir.Turn` - provider/tool loop for one user Turn.
- `Pixir.Conversation` - UI-agnostic multi-turn driver.
- `Pixir.Provider` - OpenAI Responses API dialect, stateless with `store: false`.
- `Pixir.Provider.{Connection,TransportPolicy,WebSocketClient}` - WebSocket-preferred
  transport policy and HTTP/SSE fallback. This is optimization plumbing; it never
  replaces local Logs.
- `Pixir.Provider.{Cache,HostedTools}` - prompt-cache metadata and Provider-hosted tools
  such as Web Search. Hosted tools are Provider evidence, not Pixir local Tool calls.
- `provider_usage` Events - durable token/cache evidence for each Provider call; never
  replayed as model context.
- `Pixir.Auth` - ChatGPT subscription OAuth and API-key fallback.
- `Pixir.Tools.*` / `Pixir.Tools.Executor` - permissioned, workspace-confined tools
  and the first enforcement boundary for Host Boundary Crossing.
- `Pixir.SessionResources` - durable local resources such as Image Attachments and ACP
  resource links; Provider image/file inputs are projections of these resources, not the
  resources themselves.
- `Pixir.Skills` / `Pixir.Agents` / `Pixir.Subagents` / `Pixir.Workflows` -
  installed practices, role configs, supervised child Sessions, and structural
  orchestration.
- `Pixir.SessionTree` - read-only projection of Session/Subagent hierarchy from Logs.
- `Pixir.Compaction` - durable `history_compaction` checkpoints and replay repair.
- `Pixir.CLI` / `Pixir.Renderer` - terminal presenter.
- `monitor/` - experimental source-only Pixir Monitor sibling app. It is a loopback-only,
  read-only Phoenix/Bandit Presenter over recomputable projections; its dependencies do
  not enter Pixir core or the Hex package. Read `monitor/AGENTS.md` before work there.
- `Pixir.ACP.*` - ACP stdio presenter. stdout is JSON-RPC only.

## Beta Stance

Pixir Harness is public as an early source-install developer preview:

- Supported: source build, CLI, ACP stdio, OpenAI Responses provider, ChatGPT
  subscription OAuth/API-key fallback, core tools, Skills, Subagents, Workflows,
  Workflow Templates, Session Resources/Image Attachments/resource links, Provider
  usage, opt-in Provider-hosted Web Search, and local diagnostics.
- Experimental: the source-only `monitor/` Pixir Monitor sibling app, long-running
  non-blocking Subagent UX, Workflow Templates as product surface, PATCHMD customization
  operations, benchmark drivers, and client-specific projection behavior. Pixir Monitor
  is loopback-only and read-only; it is not part of the Hex package or a production
  support promise. Skill Context Hydration is accepted as a design direction but is not
  yet an implemented public surface.
- Not included: stable public Elixir API, packaged T3Code provider, MCP support,
  packaged/Hex web UI, self-update, telemetry, or production support promises.

T3Code integration is dogfood through a separate local adapter/patch workflow. Do not
imply an upstream T3Code PR or packaged provider install path unless a later decision
changes that.

## Commands

```bash
mix deps.get
mix compile
mix compile --warnings-as-errors
mix test [--stale]
mix format
mix format --check-formatted
mix escript.build
./pixir help
./pixir --version
./pixir doctor
./pixir doctor --json
./pixir tree <session-id> --json
./pixir compact <session-id> --dry-run --json
mix check
mix pixir.smoke.skills
mix pixir.smoke.subagents
mix pixir.smoke.workflows --dry-run --json
mix pixir.smoke.prompt_cache --dry-run --json
mix pixir.smoke.websocket --dry-run --json
mix pixir.smoke.web_search --dry-run --json
```

Run Python files, if any are added later, with:

```bash
uv run python file_name.py
```

The built `./pixir` binary and `.pixir/` runtime state are gitignored. Global Pixir
state lives under `~/.pixir/` unless `PIXIR_HOME` overrides it.

## Non-Negotiable Invariants

1. **The Log is the source of truth.** Do not persist conversation state elsewhere and
   expect resume/fork/replay to work.
2. **Canonical vs ephemeral matters.** Canonical Events are durable; streaming deltas,
   status updates, and plan updates are bus-only.
3. **Event `data` uses string keys.** Envelope keys are atoms; data must round-trip
   through JSON/NDJSON.
4. **Bus access goes through `Pixir.Events`.** Do not reach into `Registry` directly.
5. **Public functions return `{:ok, term} | {:error, term}`.**
6. **Workspace confinement is central.** Tools must not bypass `Pixir.Tools.Executor`
   or `Pixir.Tools.Workspace`.
7. **Secrets never enter repo, Log, stdout, or diagnostics.** OAuth tokens live in
   `~/.pixir/auth.json`; `OPENAI_API_KEY` is never persisted.
8. **ACP stdout is JSON-RPC only.** Diagnostics go to stderr.

## Tool And Command Ergonomics

ADR 0005 is a contract:

- Side-effecting tools and commands are dry-runnable where relevant.
- Commands expose help.
- Agent-facing failures use structured errors with `kind`, `message`, `details`, and
  next-action context when possible.
- A nonzero shell exit is a successful tool result with `exit_code` and `"ok" => false`,
  not an internal tool error.
- Model-channel output is bounded and clean: no ANSI, prompts, spinners, or raw floods.

## Tests

Use ExUnit seams instead of real network calls:

- Provider tests inject `transport:`.
- Auth tests inject isolated stores and OAuth adapters.
- Turn/Conversation tests inject scripted providers.
- ACP tests drive `Pixir.ACP.Server.feed/2`.
- Tool contract tests live in `test/support/tool_contract.ex`.
- Assert structured error `kind`, not prose.

Networked smoke tasks are manual/opt-in.

## Provider Rules

- Requests remain stateless with `store: false`; the local Log is the source of truth.
- `provider_usage` records token/cache accounting per Provider call and is audit
  evidence only, not Provider replay context.
- Prompt-cache claims require observed `cached_tokens`; short prompts are expected to
  report zero cached tokens.
- `prompt_cache_key` is a bounded routing hint for stable prefix families. Do not put
  raw paths, user text, timestamps, request ids, emails, or secrets in it. Preserve the
  same safe key across WebSocket -> HTTP/SSE fallback when the dialect supports it.
- Keep `prompt_cache_retention` gated by backend support. Do not blindly send `"24h"`
  on the ChatGPT/Codex subscription path.
- WebSocket continuation is the intended default Provider transport direction through
  an `auto` policy: try WebSocket first, then fall back to HTTP/SSE with a visible
  reason, then retry WebSocket after backoff instead of downgrading forever. The smoke
  remains opt-in/manual, and `previous_response_id` is connection-local optimization
  state, not durable Session state. The Log remains authoritative.

## Git And Local State

- `.pixir/sessions/`, `.pixir/benchmarks/`, `.pixir/subagents/`, and `.pixir/smoke/`
  are local runtime state and must stay ignored.
- `~/.pixir/auth.json` and `~/.pixir/config.json` are user-global state, not repo files.
- After Elixir changes used by the CLI/escript path, rebuild with `mix escript.build`
  before claiming the local binary reflects the change.
