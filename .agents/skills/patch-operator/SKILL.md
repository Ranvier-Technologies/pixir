---
name: patch-operator
description: "Run bounded patch work in this repository using the installed Patch Operator Kit. Use when reconciling upstream/donor changes, backporting a fix, or landing any scoped change that needs a charter, local acceptance, and an honest handoff. Drives the patch:* command surface and the .docs/ templates. Keeps local proof separate from CI/external review. Do not use for unbounded refactors, exact-spec implementation, or non-UI text answers."
---

# Patch Operator

> Maintainer practice: the UV-backed PATCH kit CLI (`scripts/patch_cli.py`)
> that this skill drives is not distributed with this repository.

Operate one bounded patch at a time, with a written charter, Skill-led classification, local
acceptance, and a handoff that never confuses local proof with CI or external review. This skill
is installed by the Patch Operator Kit; it reads the repo's `patch:*` commands, `.docs/`
templates, and `.agents/skills/references/`.

## Preconditions (read before acting)

1. **Repo law** — read `AGENTS.md` (preferred) or `CLAUDE.md`. Those are the only law files; if
   both exist, `AGENTS.md` wins. Obey its constraints over anything here.
2. **Kit config** — read `.docs/patch-kit/config.json` for `profile`, `commandRunner`, and
   `capabilities`. Run a step only if the matching `patch:*` capability is enabled. `minimal`
   has the core loop; `review-proof` adds review + proof + drift.
3. **One active patch** — there is at most one `patch.md` at the repo root. If one exists and is
   unfinished, continue it; do not open a second.

## The loop

Each step maps to a command and writes one artifact. Templates live in `.docs/templates/`.

| # | Step | Command | Artifact | Capability |
|:--|:--|:--|:--|:--|
| 1 | **Charter** the patch | author `patch.md`, then `<runner> run patch:truth:check` | `patch.md` | `patch:truth:check` |
| 2 | **Isolate** a worktree | `<runner> run patch:worktree:init -- --dry-run` then run for real | — | `patch:worktree:init` |
| 3 | **Classify** the donor range | Skill produces JSON, then `patch:classify --input-json <file-or-stdin> --write` | `classification.json` | `patch:classify` |
| 4 | **Implement** `Port` / `Adapt` scope only | (your edits) | — | core |
| 5 | **Accept locally** | `<runner> run patch:accept -- --dry-run` -> `<runner> run patch:accept` | `runs/accept-latest.json` | `patch:accept` |
| 6 | **Status** (any time) | `<runner> run patch:status` | `status.md` | `patch:status` |
| 7 | **Review** (external) | `<runner> run patch:review:coderabbit -- --dry-run` then run for real | `review-triage.md` | `patch:review:coderabbit` |
| 8 | **Proof** (local streams) | `<runner> run patch:proof:runtime` / `patch:proof:playwright` / `patch:diff:snapshot` / `patch:drift:analyze` | `proof-bundle.md` | proof/drift capabilities |
| 9 | **Handoff** | author `handoff-pr-summary.md` | `handoff-pr-summary.md` | core |
| — | **Hygiene** | `<runner> run patch:artifacts:prune -- --dry-run` then run for real | — | `patch:artifacts:prune` |

Artifacts for the current patch live under `.docs/patches/<patch-spec.id>/`.

Use the package runner recorded in config (`bun`, `pnpm`, `npm`, or `yarn`). The package scripts
invoke the kit's `uv run scripts/patch_cli.py ...` commands; do not bypass them unless the target
repo has no `package.json` command surface.

When forwarding flags through package scripts, use the target runner's convention. If the runner
would obscure stdin or flag forwarding, call `uv run scripts/patch_cli.py ...` directly and record
the command in the evidence ledger.

### Step detail

1. **Charter.** Fill `patch.template.md`: a stable `patch-spec.id`, donor/target refs, an explicit
   in/out scope, and a one-sentence **stop condition**. The stop condition is the whole point —
   when it is true, the patch is done; nothing more goes in. `patch:truth:check` validates that
   every "out of scope" line has a matching classification row.
2. **Worktree.** Work in `.patch-worktrees/<patch-spec.id>` so the main tree stays clean.
3. **Classify.** Read `references/classification-rubric.md` and
   `references/artifact-contract.md`. For each donor change and target constraint, choose exactly
   one canonical label: `Port`, `Preserve`, `Adapt`, `Reject`, or `Defer`. The Skill owns this
   judgment. The CLI validates and writes it to `.docs/patches/<patch-id>/classification.json`.
4. **Implement `Port` and approved `Adapt` scope only.** If you discover a tempting adjacent
   change, **reclassify it** — do not silently widen scope.
5. **Accept locally.** Always `--dry-run` first. A `passed` result is **local**: it means the
   acceptance commands succeeded on this worktree. It does **not** mean CI is green.
6. **Status** renders a <60-second scan with a proof ledger; regenerate it, don't hand-edit.
7. **Review** (if enabled). CodeRabbit is canonical for `review-proof` but is an **external CLI** —
   never add it as a package dependency. Triage every finding: `fix_now` (resolve before handoff),
   `defer_out_of_scope` (→ classification), `infra_failed` (not a code issue), or
   `accepted_with_recorded_gap` (record the reason in the ledger).
8. **Proof** (if enabled). Capture each stream with an explicit state. If a stream doesn't apply
   (e.g. no UI for a library change), record `not_applicable` — never fake a pass. State the
   residual risk created by anything you deferred.
9. **Handoff.** Author the PR/handoff summary. Keep a **local** column and an **external** column.
   Name every accepted gap and every deferred item so reviewers don't re-litigate scope.

## Non-negotiables

- **Local acceptance ≠ CI green ≠ review clear.** Keep the three separate in every artifact. A
  patch may be `local-accepted` while CI is `pending`.
- **Stay in scope.** `Port` plus approved `Adapt` decisions from `classification.json` are the
  boundary. Reclassify, never widen.
- **Scripts run through `uv` / `uvx`** — never raw `python` + `pip`. Package scripts are the
  user-facing command surface and should call the UV-backed scripts.
- **Mutating commands dry-run first**; success is machine-readable on **stdout** (JSON), structured
  errors go to **stderr** with a non-zero exit.
- **Repo law is only `AGENTS.md` or `CLAUDE.md`** (`AGENTS.md` preferred).
- **CodeRabbit stays external.**
- **Ask before** scope widening, preserve-path changes, destructive actions, external side effects,
  repo-wide changes, reinstalling the kit, or rewriting law files. Evidence creation and scope
  narrowing are autonomous.

## Done means

- `patch.md` stop condition is satisfied.
- Classification is recorded (`classification.json`).
- Local acceptance recorded (`runs/accept-latest.json`).
- If enabled: review triaged with no unresolved `fix_now`; proof bundle captured.
- `handoff-pr-summary.md` written, with every remaining CI/external gap named and accepted.

## When NOT to use

Unbounded refactors, exact-spec implementation from a detailed ticket, pure text answers, or any
change that doesn't benefit from a charter + scope boundary. Those don't need a patch.

<!--
PROFILE NOTE
This stub is capability-gated: steps 7–8 are skipped automatically when config.json lacks those
capabilities, so the same file serves `minimal` and `review-proof`. If a future profile needs
bespoke review/proof wording, add an overlay at .agents/skills/patch-operator/<profile>.md rather
than forking this file.
-->
