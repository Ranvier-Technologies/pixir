# AGENTS.md - Pixir Docs

This directory is source documentation: ADRs, roadmap, benchmark specs, reports, and
copyable examples.

- `CONTEXT.md` is the glossary only. Do not put implementation specs or scratch plans
  there.
- ADRs live in `docs/adr/`; add one only for a hard-to-reverse, surprising trade-off.
- `docs/benchmarks/AGENTS.md` owns benchmark specs and reports.
- `docs/examples/AGENTS.md` owns copyable examples; examples should be deterministic and
  offline unless explicitly named otherwise.
- `docs/landing/` and `docs/media/` are ignored local experiments unless the user
  explicitly asks to promote a specific artifact into public source.
- When public surfaces change, keep `README.md`, `docs/open-beta-quickstart.md`,
  release notes, and the relevant ADR links in sync.
- Do not commit ignored runtime evidence from `.pixir/benchmarks/`; summarize evidence in
  committed docs when needed.

Fast checks:

```bash
git diff --check
mix format --check-formatted
```
