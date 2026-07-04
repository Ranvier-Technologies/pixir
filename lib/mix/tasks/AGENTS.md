# AGENTS.md - Mix Tasks

This directory contains agent-facing smoke, benchmark, and helper commands.

- Prefer this file plus ADR 0005 before changing task behavior.
- Every task meant for agents should have `--help` or clear usage, `--json` where useful,
  and `--dry-run` before side effects or real-network spend.
- Errors should be structured and actionable enough for a root agent to recover.
- No-network smoke tasks must remain deterministic and offline; networked smoke tasks are
  manual validation surfaces, not ordinary test dependencies.
- Provider/network smokes such as `pixir.smoke.prompt_cache`, `pixir.smoke.websocket`,
  and `pixir.smoke.web_search` must make spend, auth, and next actions explicit.
- Never print token contents or credentials.

Fast checks:

```bash
mix test test/mix
mix compile --warnings-as-errors
mix format --check-formatted
```
