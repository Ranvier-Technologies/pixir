---
name: pixir-delegate
description: Use Pixir as a headless subagent runtime from Claude Code or any harness with skill `!` preprocessing (Codex roots and other no-hydration hosts use pixir-delegate-codex instead) — one-shot workers (`pixir --json`), parallel fan-out to N children (`pixir delegate --spec`), resumable steering (`pixir resume`), evidence drill-down. Use when the user wants to fan out subagents or parallel workers, delegate analysis or bounded coding tasks to GPT/OpenAI models, run cheap background workers, or steer and retry a worker across turns.
allowed-tools: Bash(pixir:*), Bash(jq:*)
---

# Pixir Delegate — subagents without a wrapper agent

Runtime state, hydrated by the harness at invocation. Preprocessing is this
variant's contract: if the line below reads as a raw placeholder, you are on
the wrong variant; use `pixir-delegate-codex` (explicit preflight, no
hydration) instead of working around it here.
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
fresh sessions for follow-ups: a resumed turn reuses the session's history and
prompt-cache key, but do NOT budget on guaranteed cache hits (a blind-run
measured 0% cached on a resume minutes after the fan-out; hits depend on
provider cache state). Session ids look global but `resume` resolves them
against `$PWD/.pixir/sessions/` only — run it from the workspace root, not
from a scratchpad.

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
  a timeout yields an honest partial envelope, not a crash.
- `role: "explorer"` is read-only; write-capable fan-out needs a spec-level
  mode and write policy — a dry run of your draft spec walks you through the
  exact fields.
- **Specs validate fail-closed**: an unknown top-level or `subagents` key is
  rejected as structured `invalid_spec` with a `json_pointer` to the exact
  field, in dry-run and real runs alike — the rehearsal now catches typos.
  On binaries at 0.1.6 or older, unknown fields are still silently ignored:
  there, confirm a knob exists in the revealed contract before trusting it.
- **Model/effort per delegation**: `subagents.model` and
  `subagents.reasoning_effort` (`low|medium|high|xhigh`) apply to every child;
  a spec knob wins over config defaults. They mirror ACP `session/prompt`
  `_meta` exactly. The effective value is proven by each child's
  `provider_usage` events, never echoed in the envelope — reconcile from
  logs. Binaries at 0.1.6 or older ignore these fields silently; verify the
  evidence before assuming the pin took effect.

## When something fails

- Recovery guidance follows the mode contract: in `--json` mode it arrives
  **in the envelope** (one-shot/resume: `.resume_command`, timeouts also
  `.recovery`; subagents-strategy delegate partials: ready-made
  `children[].resume_command` and `children[].diagnose_command` on each
  non-completed child) and stderr stays silent; without `--json`, a terse
  resume hint prints on stderr per child (the diagnose command and richer
  recovery data live only in the envelope). Workflow-strategy children carry
  step buckets and evidence instead of these commands; recover those via
  diagnostics. Error envelopes carry `next_actions`; follow them.
- A stale writer lease fails closed **on purpose** (crashed runs leave
  evidence). Inspect first: `pixir diagnose session <sid> --json`. Force-release
  is a deliberate operator action, never a default.
- Delegate partial failure (`work_complete: false`): the runtime may already
  have auto-retried eligible read-only children (transient transport and
  retryable provider errors) — check `children[].retry_history` first and do
  not re-retry what the runtime already retried. For children still not
  completed, recover per child: read its `child_log_path`, then run the
  child's own `resume_command` from the envelope. Do not re-run the whole
  spec.
- If stdout fails to parse as JSON in `--json` mode, treat the run as failed
  and read stderr; do not scrape partial stdout.

A delegation does not close when the process exits — it closes when the
envelope is reconciled: every child status read, every `summary` parsed against
its contract, every failure dispositioned (resumed, retried, or reported).
The fields you reconcile: top-level `ok`/`status`/`work_complete`, and per
child `status`, `reason_code`, `child_session_id`, `child_log_path`, `summary`,
plus the conditional confessions when present: `retry_attempts`/`retry_history`
(a child that arrived on a second attempt is part of the record; distrust a
successful retry when the task was not idempotent) and `resume_command` on
non-completed children. Two mapping caveats: nothing in the envelope promises
that `children[]` order matches `tasks[]` order — join children to tasks by
`children[].index`, the zero-based `tasks[]` position (spawn-assigned, stable
across a child's retry lineage; legacy `task`+`count` specs omit it, and
binaries at 0.1.6 or older leave it null — there, fall back to making each
contract self-identifying by including the task's subject in the child's
JSON); and there is no aggregate cost field anywhere — per-delegation totals
are computed by summing `provider_usage` events across the child logs. Never
report fan-out success on exit code alone.

## Evidence

Sessions are append-only logs under `.pixir/sessions/<sid>.ndjson`. Use
`pixir diagnose session <sid> --json` and `pixir tree <sid> --json`;
`provider_usage` events carry per-call token and transport evidence (nested at
`.data.usage_summary` on each event line) — reconcile costs from logs, not
estimates.

## Deeper layers

- `references/delegation-core.md` — the host-neutral judgment core shared by
  every variant; canonical text for routing, refusal, rehearsal, closure.
- `references/demonstrations.md` — four real traces (build, pressure/failure,
  cross-surface transfer, and a production pre-merge review gate), annotated
  as practice, with session ids.
- `scripts/fanout.sh` and `scripts/steer.sh` — deterministic invocation:
  rehearsal-gated fan-out with disposition targets on partial (exit 3), and
  single-child steering that never force-releases a lease.
- Sibling variants: `pixir-delegate-native` (orchestrating from inside a
  Pixir session) and `pixir-delegate-codex` (Codex root agent; explicit
  preflight instead of hydration).
