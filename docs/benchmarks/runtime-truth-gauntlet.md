# Runtime Truth Gauntlet

Pixir's backend Runtime Truth gauntlet is a fixture-backed diagnostic for the
failure-state contract in ADR 0026. It checks whether durable Log evidence,
replay/cache exclusions, and presenter projection agree before using a run as
release or registry confidence evidence.

This is not a performance benchmark and does not automate T3 Code or Zed UI
flows. It is a deterministic join gate for backend evidence packets produced by
manual dogfood, Pixir diagnostics, or no-network fixtures.

## Command Shape

```bash
bin/pixir-runtime-trust-gauntlet --help
bin/pixir-runtime-trust-gauntlet --list-scenarios --json
bin/pixir-runtime-trust-gauntlet --fixture-dir <dir> --json --fail-on-blocker --require-all-scenarios
```

Agent-facing properties:

- `--help` explains inputs and exit behavior.
- `--dry-run` reports planned fixtures without evaluating them.
- `--json` emits parseable output for parent review.
- `--fail-on-blocker` exits nonzero when backend readiness is blocked.
- `--require-all-scenarios` turns missing scenario coverage into a blocker.

## Scenario Matrix

| ID | Scenario | Contract evidence |
| --- | --- | --- |
| T0 | clean one-turn answer | Clean `assistant_message` plus presenter completion |
| T1 | partial answer then provider error | Partial assistant evidence is preserved and not projected as clean success |
| T2 | provider error before text | `turn_failed` evidence exists and stale assistant text is not replayed |
| T3 | tool call plus final answer | Tool calls/results are paired and a clean final answer exists |
| T4 | subagent timeout | Timeout evidence has child id, reason, duration, timeout, and next action |
| T5 | workflow partial outcome | Partial/failed/timed-out/held checkpoints are not collapsed into success |
| T6 | ACP load after partial assistant | Partial or failed Turns are not loaded as clean final answers |
| T7 | replay/cache after failure evidence | Audit-only failure events do not enter Provider replay or mutate prefix |
| T8 | client dogfood parity | T3/Zed-visible state agrees with Pixir diagnostics |
| T9 | turn timeout or interruption | Interrupted/timed-out Turns have `turn_failed` evidence and no clean completion |
| T10 | subagent completion | Completed child Session evidence is attributable and durable |
| T11 | workflow full completion | All checkpoints are `checkpoint_ready` and completion evidence is coherent |

## Output Contract

The top-level output includes:

- `backend_readiness`: `not_blocked` or `blocked`.
- `registry_readiness`: compatibility alias for older consumers.
- `summary.coverage_status`: `complete` only when every known scenario has at
  least one fixture.
- `summary.backend_blockers`: scenario/classification pairs that require a fix
  or more evidence.

Warnings are allowed when they represent honest, actionable partial outcomes
such as an explicit Subagent timeout. A warning is not release proof by itself;
it is evidence that the runtime did not hide the failure.

## Evidence Practice

For a real run, save sanitized fixtures and command output under an ignored local
artifact directory such as:

```text
.pixir/benchmarks/runtime-truth-gauntlet/<run-id>/
```

Do not commit raw session Logs, screenshots, credentials, local paths, or
workspace-specific runtime state. Commit only the gauntlet code, tests, and
stable documentation.
