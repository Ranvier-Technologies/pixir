# Delegation core — host-neutral judgment

This is the judgment layer shared by every pixir-delegate variant. Actuation
surfaces differ per host (external CLI, Codex-root daemon, Pixir-native
Subagent tools); this doctrine does not. A variant SKILL.md teaches its
surface's mechanics and defers here for the practice.

Proven to transfer: an orchestrator running inside Pixir used this core to
justify choosing native Subagent tools over the CLI commands the Claude
variant teaches — the judgment held even against the recipes.

## Routing

| Situation | Shape |
|---|---|
| One worker, one task | one-shot |
| N independent parallel workers | shared-runtime fan-out |
| Sequentially dependent steps | one steered chain (resume), never fan-out |
| Fan out, then steer or retry one child | fan-out + per-child resume |

Anti-pattern: N independent one-shot processes for fan-out. Every surface has
a shared-runtime form; use it.

## Refusal — when not to delegate

- A child starts blind. If writing the self-contained prompt costs more than
  doing the work, do it yourself.
- Sequential dependencies want one chain, not parallel children.
- A workspace whose state you cannot share with another writer means
  read-only children or no delegation.
- One trivial question is not a delegation.

## Rehearsal — before the first real act

Rehearse in whatever non-mutating form the surface offers (CLI: `--dry-run`;
other surfaces: validate the plan/spec/schema without spending provider
tokens). Treat structured errors and `next_actions` as the runtime teaching
you its current contract. Do not memorize contracts; ask the runtime to
reveal them at the moment of use. Know exactly WHICH binary/runtime version
you are driving before delegating through it.

Readiness classification (doctor or equivalent): `ready` proceeds;
`ready_with_warnings` means read the non-passed checks and judge — a missing
local build is non-blocking, failed auth is not; an error status never
delegates. Record the classification in your closure report.

## Sizing

- Concurrency: set the surface's thread/child limit to your child count
  unless deliberately throttling — provider quota is shared across children
  and the limit is your backpressure lever.
- Timeouts cover waves: with tasks > concurrency, children run in
  ceil(N / concurrency) waves. A timeout yields an honest partial, not a
  crash — budget generously.

## Contracts

Every child prompt is self-contained and demands strict JSON output against
an explicit schema. The child's final message is your data; make it
parseable on arrival.

- Evidence citations in child contracts should allow line RANGES
  (`file:start-end`); single-line citations are fragile for multi-line
  sections and push children toward `uncertain` verdicts.
- For large files, instruct sectioned reads in the task prompt — a child
  that truncates its source produces confident-looking partial evidence.
- Read-only children run only bare safe-listed shell commands (no pipes,
  chaining, or redirection — by design). Shape tasks around their read
  tools; do not fight the posture.

## Closure — evidence-gated, never exit-code-gated

A delegation closes when its outcome is reconciled: every child's terminal
status read, every summary parsed against its declared contract, every
non-completed child dispositioned — resumed, retried, or reported. Partial
failure recovers per child; never re-run the whole batch. If the surface's
output fails to parse, the run failed — read the error channel, do not
scrape fragments.

## Evidence

Every child is a durable session with an append-only log. Reconcile costs
and behavior from logged per-call usage evidence, not estimates. Timed-out
or failed children remain resumable sessions — recovery is a first-class
move, not an apology.
