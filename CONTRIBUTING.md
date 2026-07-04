# Contributing to Pixir

Pixir is a developer preview. Contributions are welcome, but the runtime has a
small set of load-bearing invariants that keep resume, replay, and the delegate
contract honest. Read `AGENTS.md` first — it is the canonical guide for anyone
(human or agent) changing this repo — then `CONTEXT.md` for vocabulary and the
relevant ADR under `docs/adr/`.

## Before you start

- `AGENTS.md` — architecture map, invariants, commands, and the beta stance.
- `CONTEXT.md` — the exact meanings of Session, Turn, Log, History, Workspace,
  Tool, Host Boundary Crossing, Provider, and more. Use those terms precisely.
- `docs/adr/` — read only the ADRs relevant to your change. In particular:
  ADR 0003 (the append-only Log is the source of truth), ADR 0004 (canonical vs
  ephemeral events), ADR 0005 (agent ergonomics: dry-run, structured errors),
  and ADR 0006 (permission model).

## Development workflow

```bash
mix deps.get
mix compile --warnings-as-errors
mix test
mix format
mix escript.build
./pixir doctor --json
```

## Before opening a pull request

Every PR should pass, at minimum:

```bash
mix format --check-formatted
mix compile --warnings-as-errors
mix test
```

`mix check` is the preferred full local gate. It runs formatting,
warnings-as-errors compilation, tests, escript build, no-network smokes, and docs;
CI mirrors the same contract.

## Invariants — breaking these breaks resume/replay

- **The Log is the source of truth** (ADR 0003). Re-derive History from the Log
  each iteration; never thread turn state in memory expecting it to persist.
- **Canonical vs ephemeral events** (ADR 0004). Only canonical events are logged
  with a monotonic `seq`. Adding a canonical event type is a Log schema change and
  needs an ADR.
- **Never decode Log/NDJSON via `String.to_existing_atom`** — that crashed cold
  resumes. Decode against `Event.canonical_types/0`.
- **Assert structured errors by `kind`, not message text**, in both code and
  tests.
- **Tests never hit the network** — they drive the injectable seams (`transport:`,
  `oauth:`, `provider:` stubs). Every new tool must be registered in
  `test/support/tool_contract.ex`.
- **The delegate CLI envelope is a versioned public contract.** Exit codes and
  envelope keys are contract; a change needs a `contract_version` bump and updated
  tests under `test/pixir/delegate/`.

## Reporting bugs and security issues

- Functional bugs: open a GitHub issue with your OS/Elixir version, the command
  run, and `pixir doctor --json` output (secrets removed).
- Security vulnerabilities: **do not** open a public issue — follow
  [`SECURITY.md`](SECURITY.md).

## License

By contributing, you agree that your contributions are licensed under the MIT
License, the same as the rest of the project (`LICENSE`).
