# AGENTS.md - Pixir ADRs

This directory records accepted architecture decisions.

- Use ADRs for decisions that are hard to reverse, surprising without context, and based
  on a real trade-off.
- Keep ADRs decision-shaped: Context, Decision, Consequences, Non-goals, Verification
  Direction, References.
- Do not use ADRs as task trackers. Put implementation task plans under `ai_docs/tasks/`.
- If implementation status changes, update the status line without rewriting the
  historical decision unless the decision itself changed.

Fast checks:

```bash
git diff --check docs/adr
mix format --check-formatted
```
