# T3 Harness Templates

These files are Pixir-owned templates for the paired local T3 Code checkout. They let
`mix pixir.bench.real_subagents` drive T3's Pixir ACP and Codex provider paths without
depending on untracked scripts that only exist on one machine.

They are local benchmark adapters, not a T3 Code upstream contribution.

## Install

From the Pixir repo:

```bash
mix pixir.bench.install_t3_harnesses --dry-run --json
mix pixir.bench.install_t3_harnesses
```

Use `--force` only when intentionally overwriting local harness edits in the T3
checkout:

```bash
mix pixir.bench.install_t3_harnesses --force
```

The default T3 checkout path is `$T3_CODE_PATH` when set, otherwise a sibling checkout
next to Pixir:

```text
../t3code
```

Override it with:

```bash
mix pixir.bench.install_t3_harnesses --t3-code-path /path/to/t3code
```

## Verify

In the T3 checkout:

```bash
source ~/.nvm/nvm.sh && nvm use 24
bunx oxfmt --check scripts/pixir-subagents-benchmark.ts scripts/codex-subagents-observability-probe.ts
bun run typecheck --filter='t3' --force
```

Then, in the Pixir repo:

```bash
mix pixir.bench.real_subagents --scenario common_model_gate --models gpt-5.5 --reasoning-effort low --dry-run --json
```

## Templates

- `pixir-subagents-benchmark.ts` installs to
  `scripts/pixir-subagents-benchmark.ts`.
- `codex-subagents-observability-probe.ts` installs to
  `scripts/codex-subagents-observability-probe.ts`.
