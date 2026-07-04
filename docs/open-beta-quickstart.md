# Pixir Open Beta Quickstart

Pixir's first open beta is a developer preview. The supported public surface is the
Pixir runtime, terminal CLI, and ACP over stdio. Hex distribution, when used, installs
the same CLI/ACP runtime and does not imply a stable public Elixir library API.

## What You Need

- Elixir compatible with `mix.exs`.
- A local checkout of this repository for source installs, or Hex package access for
  escript installs.
- Either ChatGPT subscription login through `pixir login` or an `OPENAI_API_KEY`.

See `docs/adr/0016-open-beta-scope.md` for the open beta scope and
`docs/adr/0025-hex-package-scope.md` for the CLI/ACP-only Hex package contract.

## Install From Hex

```bash
mix escript.install hex pixir
pixir --version
pixir help
pixir doctor --json
```

## Install From Source

```bash
mix deps.get
mix escript.build
./pixir help
./pixir doctor --json
```

`doctor` is local-only and no-network. It checks the runtime version, source-install
binary, workspace/session-log writability, local credential presence, `config.json`
shape, and ACP command availability. It may create `.pixir/sessions` and remove a
temporary probe file. It does not prove that the Provider accepts your selected model;
use a smoke task for that.

After a Session exists, use local replay diagnostics when another agent, ACP client, or
operator needs evidence about replay continuity. Use `pixir` for package installs and
`./pixir` for source checkouts:

```bash
pixir inspect-replay <session-id> --json
pixir diagnose session <session-id> --json
```

These commands read the local Log. They do not call the Provider.

## Sign In

```bash
pixir login
```

Follow the printed device-code instructions. The subscription credential is stored under
`~/.pixir/auth.json` with local file permissions. As a fallback, set `OPENAI_API_KEY`.

## Run A First Turn

From a project directory:

```bash
pixir --read-only "inspect this repo and summarize the architecture"
```

Pixir writes the model answer to stdout and activity/session details to stderr. Session
Logs are stored under `.pixir/sessions/` in the workspace and can be resumed:

```bash
pixir resume <session-id> "continue from there"
```

### Reading One-Shot Results

One-shot runs (`pixir "prompt"` and `pixir resume <id> "prompt"`) are a completion
contract for scripts and orchestrators, not an interactive session:

- **stdout** carries only the model's final report. If the transport delivers final
  text that never arrived as streamed deltas, Pixir still flushes it to stdout before
  exiting.
- **stderr** carries activity, diagnostics, and the exact resume command
  (`pixir resume <session-id> "..."`) on every terminal path, including idle timeout.
- Exit codes: `0` answer delivered; `1` turn error; `6` turn completed without a final
  assistant message (an honest incomplete — stderr names the
  `pixir diagnose session <session-id> --json` command to inspect the Log); `124` idle
  timeout; `130` interrupted.

Read the final report from stdout; read everything about *how the run went* from
stderr and the Log-backed diagnostics (`diagnose`, `inspect-replay`, `tree`).

## Permission Modes

```bash
pixir --read-only "inspect this repo"
pixir --ask "make a small change and test it"
```

`--read-only` denies mutations. `--ask` prompts before writes and unsafe shell commands.

## ACP Clients

Point an ACP client at the installed or built escript:

```bash
pixir acp
```

ACP is the beta UI transport contract. Pixir still executes tools internally and reports
tool lifecycle through ACP updates.

### Presenter Confidence

The open beta treats ACP clients and local dogfood presenters as operator surfaces over
the same Pixir runtime. Local parity gauntlets have exercised CLI, T3 Code Pixir
dogfood, and Zed ACP against the same source-built binary and workspace for simple
answers, file reads, and bounded Subagent work.

Use that as developer-preview confidence, not as a strict UI parity claim. For any
important presenter result, prefer Log-backed evidence: the visible answer, the
matching `.pixir/sessions/<session-id>.ndjson`, `inspect-replay`, `diagnose`, and
`tree` when Subagents are involved.

## Subagents And Workflows

Pixir supports supervised Subagents and structural Workflows. For beta users, the
honest contract is operational but narrow:

- bounded Subagents run as supervised child Sessions and record durable terminal
  evidence;
- `wait_agent` can return structured partial outcomes when only some children complete;
- completed Subagents and Workflow steps may produce useful checkpoint bundles;
- partial Workflow outcomes are not success;
- timed-out, failed, cancelled, or detached children must be reported honestly with
  child ids and actionable state;
- direct CLI fanout and parent-led Subagent fanout are covered by the no-network fanout
  regression gauntlet;
- long-running non-blocking Subagent status/result retrieval remains an experimental
  client UX surface, especially in ACP clients that choose their own presentation model.

Use `mix pixir.bench.fanout_gauntlet --dry-run --json` from a source checkout when you
need reproducible evidence for those claims. The gauntlet is a correctness and honesty
gate, not a performance benchmark.

For a copyable Codex/Claude Code style delegate call, see
`docs/examples/delegate-cli-live/`. Its dry-run path is local-only; running without
`--dry-run` uses the configured Provider.

## Local Verification

For a package install, start with:

```bash
pixir doctor --json
```

For a source checkout, maintainers can run the broader local gate:

```bash
mix check
```

Networked smoke tasks are manual/opt-in and belong to source-checkout verification, not
normal package use.

## Images And Hosted Search

Pixir treats image attachments as durable local Session Resources. The original resource
is local Pixir evidence; OpenAI `input_image` is only the Provider projection used when
the Turn needs the image. Later Turns should replay descriptors or digests by default
unless `resource_view` explicitly rehydrates the original image.

ACP `resource_link` blocks are also accepted as Session Resource descriptors. Readable
local `file://` links are copied into Pixir's local resource store; remote links are
recorded as references but are not fetched automatically.

Provider-hosted Web Search is opt-in. It is not MCP and not a local browser tool:
OpenAI runs the hosted search and Pixir records bounded source evidence in
`provider_usage`.
