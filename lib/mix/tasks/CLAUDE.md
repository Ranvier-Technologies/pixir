# lib/mix/tasks — dev/smoke scripts

Guided scripts for manual verification. Some hit the real network; others are no-network
offline smokes. They obey ADR 0005 too (`--help`/usage in `@moduledoc`, structured-ish
output, dry-run where they mutate).

- `pixir.smoke.login.ex` — `mix pixir.smoke.login [--wait]`: hits `auth.openai.com`, prints a
  real device code; `--wait` completes the flow.
- `pixir.smoke.e2e.ex` — `mix pixir.smoke.e2e [--probe-model] [--dry-run-tools]`: signs in,
  optionally validates the model, runs one real Turn in a scratch dir. Supports
  `--help` and `--json --help` without touching network state.
- `pixir.smoke.workflows.ex` — `mix pixir.smoke.workflows [--dry-run] [--json]`: no-network
  verification for ADR 0012 structural Workflows over Subagents.
- `pixir.smoke.workflows_real.ex` —
  `mix pixir.smoke.workflows_real [--scenario micro_parallel|dependency|writer_controlled]`:
  real-network Workflows smoke. Supports `--dry-run`, `--json`, and actionable
  structured errors.

Rules: networked smoke tasks are the only code paths that call the network outside the
injectable seams, so they're for humans/manual runs, not the test suite. No-network smoke
tasks should remain deterministic and offline. Never print token contents. Keep flags
documented in the `@moduledoc` (a fresh agent reads that as the help).
