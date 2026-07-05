---
name: pixir-delegate
description: Use Pixir as a headless subagent runtime from an orchestrating agent (Claude Code, Codex, or any shell-capable harness) — one-shot workers (`pixir --json`), parallel fan-out to N children (`pixir delegate --spec`), resumable steering (`pixir resume`), evidence drill-down. Use when the user wants to fan out subagents or parallel workers, delegate analysis or bounded coding tasks to GPT/OpenAI models, run cheap background workers, or steer and retry a worker across turns.
allowed-tools: Bash(pixir:*), Bash(jq:*)
---

# Pixir Delegate — subagents without a wrapper agent

Runtime state, hydrated at invocation on harnesses that support `!` command
preprocessing (others see the raw placeholder — run it yourself):
pixir on PATH: !`echo "$(command -v pixir || echo 'not on PATH') · v$(pixir --version 2>/dev/null || echo '?') · $(pixir doctor --json 2>/dev/null | jq -r .status 2>/dev/null || echo 'doctor unavailable')"`

Know WHICH binary you are driving before delegating: if the workspace has a
local build (`./pixir`), prefer it by explicit path over PATH — versions can
differ silently. `pixir doctor --json` reports the local build's path under
the `source_install_binary` check.

Pixir speaks a machine contract directly: JSON envelopes on stdout, documented
exit codes, resumable session ids. The CLI is self-describing by design —
discover contracts from it at runtime instead of trusting any transcript of
them (including this one). Requirements: `pixir` on PATH, `jq`, authenticated
(a stored `pixir login` credential or `OPENAI_API_KEY`); verify with
`pixir doctor --json`.

## Pick the right shape

| Need | Use |
|---|---|
| One worker, one task | `pixir --json --read-only - < prompt.md` |
| N parallel workers | `pixir delegate --spec spec.json --json` |
| Steer one worker over turns | `pixir --json resume <sid> "next task"` |
| Fan out, then steer or retry one child | delegate, then `resume <child_session_id>` |

Do NOT spawn N independent one-shot processes for fan-out — each boots its own
VM. `delegate` exists so N children share one runtime. Prefer `resume` over
fresh sessions for follow-ups: resumed turns reuse the session's prompt-cache
family even from a new OS process.

**When not to delegate:** a child starts blind — if writing the self-contained
prompt costs more than doing the work, do it yourself. Sequentially dependent
steps want one `resume` chain, not fan-out. And a workspace whose state you
cannot share with another writer means read-only children or no delegation.

## Discover, don't memorize

- `pixir help` and `pixir delegate --help` are the contract of record —
  the latter also reveals a resident daemon lifecycle
  (`start`/`status`/`attach`/`cancel`/`daemon`) for long-lived orchestrators,
  beyond the attached shapes covered here.
- Envelope shapes are best learned by running: every `--json` invocation
  returns one machine-readable envelope on stdout. Orientation for the first
  read: a one-shot's answer is `.output`, its session `.session_id`, and it
  ships a ready-made `.resume_command`; delegate children live under
  `.children[]`; doctor checks are keyed by `.id`; `pixir tree` nests under
  `.tree.subagents` (and `.tree.forks`), not top-level children.

One validated starting spec (two children; grow `tasks` and `max_threads`
together):

```json
{
  "contract_version": 1,
  "strategy": "subagents",
  "tasks": [
    "Read README.md and reply with strict JSON: {\"file\":\"README.md\",\"purpose\":\"<one sentence>\"}",
    "Read CONTEXT.md and reply with strict JSON: {\"file\":\"CONTEXT.md\",\"purpose\":\"<one sentence>\"}"
  ],
  "subagents": {"role": "explorer", "max_threads": 2}
}
```

```bash
pixir delegate --spec spec.json --json --timeout-ms 600000 > envelope.json
jq -r '.children[] | "\(.status) \(.child_session_id)"' envelope.json
```

Make every task prompt self-contained and demand strict JSON output — each
child's `summary` in the envelope is its final message, parseable directly.

## Rehearse before acting

Dry-run is not documentation; it is non-mutating rehearsal. Before the first
real delegation in a workspace, or whenever you change the spec shape:

```bash
pixir delegate --spec spec.json --dry-run --json > plan.json
jq . plan.json
```

It needs no network and no auth. Treat its output as runtime teaching: fix
structured errors, follow `next_actions`, and run the real delegation only
once the planned shape matches your intent. This skill's job is not to
memorize Pixir's contract — it is to know when to ask Pixir to reveal the
current one.

## Judgment the CLI cannot give you

- **Set `subagents.max_threads` to your child count** unless deliberately
  throttling for provider rate limits: the default is deliberately small and
  silently queues the rest. It is also your backpressure lever — quota is
  shared across children.
- **Size `--timeout-ms` for waves**: with tasks > max_threads, children run in
  ceil(N / max_threads) waves; the timeout must cover all of them. Read-only
  analysis children typically finish in a few minutes each — budget generously;
  a timeout yields an honest partial envelope, not a crash. (`--timeout-ms` is
  valid on the attached form even though current help text lists it only under
  `delegate start` — known help gap.)
- `role: "explorer"` is read-only; write-capable fan-out needs a spec-level
  mode and write policy — a dry run of your draft spec walks you through the
  exact fields.

## When something fails

- Recovery guidance for one-shot and resume abnormal exits depends on mode:
  in `--json` mode it arrives **in the envelope** (`.resume_command`; timeouts
  also carry `.recovery`) and stderr stays silent; without `--json`, the exact
  resume command prints on stderr. Delegate partials put resume targets only
  in the envelope's `children[]`. Error envelopes carry `next_actions` —
  follow them.
- A stale writer lease fails closed **on purpose** (crashed runs leave
  evidence). Inspect first: `pixir diagnose session <sid> --json`. Force-release
  is a deliberate operator action, never a default.
- Delegate partial failure (`work_complete: false`): recover per child — read
  its `child_log_path`, then `pixir resume <child_session_id>`. Do not re-run
  the whole spec.
- If stdout fails to parse as JSON in `--json` mode, treat the run as failed
  and read stderr; do not scrape partial stdout.

A delegation does not close when the process exits — it closes when the
envelope is reconciled: every child status read, every `summary` parsed against
its contract, every failure dispositioned (resumed, retried, or reported).
The fields you reconcile: top-level `ok`/`status`/`work_complete`, and per
child `status`, `reason_code`, `child_session_id`, `child_log_path`, `summary`.
Never report fan-out success on exit code alone.

## Evidence

Sessions are append-only logs under `.pixir/sessions/<sid>.ndjson`. Use
`pixir diagnose session <sid> --json` and `pixir tree <sid> --json`;
`provider_usage` events carry per-call token and transport evidence (nested at
`.data.usage_summary` on each event line) — reconcile costs from logs, not
estimates.

## Deeper layers

- `references/delegation-core.md` — the host-neutral judgment core shared by
  every variant; canonical text for routing, refusal, rehearsal, closure.
- `references/demonstrations.md` — three real blind-run traces (build,
  pressure/failure, cross-surface transfer), annotated as practice, with
  session ids.
- `scripts/fanout.sh` and `scripts/steer.sh` — deterministic invocation:
  rehearsal-gated fan-out with disposition targets on partial (exit 3), and
  single-child steering that never force-releases a lease.
- Sibling variants: `pixir-delegate-native` (orchestrating from inside a
  Pixir session) and `pixir-delegate-codex` (Codex root agent; draft).
