# Pixir Harness Open Beta Developer Preview

Date: 2026-06-09

Pixir Harness is available as an early developer preview. This note records the public
preview scope for source installs and the narrow Hex CLI/ACP distribution path. It does
not define a stable Elixir library contract.

## 0.1.4 Runtime Truth And Fanout Honesty Update

Pixir 0.1.4 keeps the same CLI/ACP-only Hex contract and tightens backend
evidence for terminal Turn and Subagent outcomes:

- terminal Turn failures are persisted as durable evidence instead of being
  collapsed into clean completion;
- `wait_agent` reports structured partial outcomes when only some children finish;
- Subagent terminal evidence, stale fanout diagnostics, and runtime-truth gauntlets
  make bounded fanout easier to audit;
- ADR 0026 documents the runtime terminal-state and replay contract now exposed in
  HexDocs.

This release does not claim a complete scheduler, WorkflowRun runtime, production
SLA, SAAAS surface, or performance superiority.

Post-release dogfood also validated developer-preview presenter confidence across the
CLI, T3 Code Pixir dogfood, and Zed ACP when all presenters point at the same
source-built binary and workspace. That evidence supports local dogfood and operator
feedback, but it is not a public claim of strict UI parity or bundled T3/Zed support.
The next hardening priority is Subagent/Workflow operability: clearer depth and timeout
ergonomics, parent/child diagnostics, and honest partial/cancel/timeout outcomes.

## 0.1.3 ACP Registry Readiness Update

Pixir 0.1.3 keeps the same CLI/ACP-only Hex contract and adds the pieces needed for
public ACP Registry validation:

- ACP `initialize` now advertises terminal authentication through `pixir login`, while
  Pixir still owns OAuth and credential storage outside the ACP stdio channel.
- ACP message projection and diagnostics preserve partial assistant evidence more
  honestly when Provider streams end unexpectedly.
- Turn, CLI, Subagent, `wait_agent`, and diagnostics hardening now make fanout failures
  and timeouts visible as terminal evidence instead of clean completion.
- Source checkouts include `mix pixir.bench.fanout_gauntlet`, a no-network correctness
  gauntlet for direct CLI fanout and parent-led Subagent fanout. It is evidence for
  outcome honesty, not a public performance benchmark.
- Source checkouts include the repo-local `bin/diagnose-t3-pixir-projection` helper for
  comparing Pixir Log truth, T3 provider logs, and T3 projection storage when a
  response is not visible where expected. It is not part of the Hex package surface.
- CI is split into clearer Pixir check gates and the projection diagnostic tests can run
  with `uv` or a plain Python runner.

This release is the intended Hex base for the public `npx` ACP Registry wrapper.

## 0.1.1 Runtime Diagnostics Update

Pixir 0.1.1 keeps the same CLI/ACP-only Hex contract and adds local Session diagnostic
surfaces for operators:

- `pixir inspect-replay <session-id> --json` inspects replay continuity from the local
  Log.
- `pixir diagnose session <session-id> --json` emits a structured Session diagnostic
  verdict for replay, lifecycle, and local evidence review.
- Replay folding now tolerates transparent lifecycle/status Events between matched
  `tool_call` and `tool_result` records.
- The escript SIGINT path no longer depends on `Mix.env/0` at runtime.

The repo-local Codex/Pixir operator Skills are intentionally not part of the Hex
package. They remain workflow guidance for this repository, not a public Pixir package
contract.

This is not a stable ecosystem release. The goal is to let early users install Pixir,
run `doctor`, try a first terminal or ACP-driven turn, and report the first
installation, auth, model, and workflow failures with useful evidence.

## What Is Supported

- Source install from `https://github.com/Ranvier-Technologies/pixir-harness`.
- Hex escript installation when the `pixir` package is available, scoped to the same
  CLI/ACP runtime.
- Terminal CLI through the installed `pixir` escript or a source-built `./pixir`.
- ChatGPT subscription login through `pixir login`, with `OPENAI_API_KEY` as a fallback.
- Local append-only Session Logs under `.pixir/sessions/`.
- `pixir doctor --json` as the first no-network diagnostic gate.
- ACP over stdio through `pixir acp`.
- Agent Skills, Subagents, Workflows, Session tree inspection, and durable compaction
  checkpoints.
- Durable Provider usage accounting for token/cache evidence.
- Initial Image Attachment support through local Session Resources and Provider
  projection.
- Provider-hosted Web Search request/evidence plumbing, with opt-in smoke verification.

## What Is Experimental

- Long-running, non-blocking Subagent status and result retrieval in specific clients.
- Workflow partial outcomes and checkpoint bundles as a polished product experience.
- Presenter/client integrations beyond ACP stdio.
- Networked smoke tests for model/provider behavior.
- Skill Context Hydration, which is accepted as a design direction but not yet a public
  implemented surface.

## What Is Out Of Scope For This Preview

- Stable public Elixir API.
- Broad package ecosystem or extension API promises.
- MCP server support.
- Packaged T3Code provider.
- Self-update/install channel.
- Production SLA, telemetry, or hosted service guarantees.

## Newcomer Smoke

The expected first-run proof is:

```bash
git clone https://github.com/Ranvier-Technologies/pixir-harness.git
cd pixir-harness
mix deps.get
mix escript.build
./pixir doctor --json
```

Run this smoke against the current checkout or installed package before reporting setup
results. Use `pixir` instead of `./pixir` for package installs.

## Open-Source Release Checklist

Before changing the GitHub repository visibility, maintainers should run the local
gate and a history-aware secret scan against the exact ref that will become public.
Prefer a clean clone of `origin/main` so local-only runtime refs, ignored `.pixir/`
state, and worktree artifacts do not hide or invent release findings:

```bash
mix check
trufflehog git file://$PWD --no-update --fail
```

If `trufflehog` is unavailable, use an equivalent tool such as:

```bash
gitleaks detect --source . --no-banner --redact --exit-code 1
```

Record the command and whether it scanned a clean clone or a local checkout in the
release notes or PR. Do not rely only on filename scans.

Recommended public repository metadata:

- Description: `Elixir/OTP runtime for supervised coding-agent sessions with CLI, ACP, Subagents, Workflows, and replayable evidence.`
- Homepage: `https://pixir.dev`
- License: MIT

Changing repository visibility is a manual release action. Do not automate it from a
maintenance PR; confirm the final local gate, secret scan, and owner approval first.
After the repository becomes public, enable GitHub Private Vulnerability Reporting in
the repository Security settings before inviting broader security review.

## Feedback To Capture

When a preview user reports a failure, ask for:

- exact OS and Elixir version;
- command run;
- `pixir doctor --json` output with secrets removed;
- whether they used ChatGPT subscription login or `OPENAI_API_KEY`;
- the relevant `.pixir/sessions/<id>.ndjson` only when safe to share.
