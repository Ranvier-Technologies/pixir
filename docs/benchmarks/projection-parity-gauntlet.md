# Projection Parity Gauntlet

Pixir's projection parity gauntlet checks whether canonical Pixir evidence agrees with
what users see through CLI, ACP, T3 Code, and Zed. It is a Registry-readiness evidence
adapter, not a new source of truth.

The Log and `pixir diagnose session <session-id> --json` remain canonical. Presenters
are evaluated by comparing their visible state against that evidence.

## Command Shape

```bash
bin/pixir-projection-parity-gauntlet --help
bin/pixir-projection-parity-gauntlet --list-scenarios --json
bin/pixir-runtime-trust-gauntlet --fixture-dir <dir> --json --fail-on-blocker --require-all-scenarios > runtime-truth.json
bin/pixir-projection-parity-gauntlet --runtime-truth-result runtime-truth.json --json --fail-on-blocker
bin/pixir-projection-parity-gauntlet --runtime-truth-result runtime-truth.json --evidence-dir <packet-or-packets-dir> --json --fail-on-blocker
```

Agent-facing properties:

- `--help` explains inputs and exit behavior.
- `--dry-run` reports planned inputs without reading files.
- `--json` emits parseable output for parent review.
- `--fail-on-blocker` exits nonzero when projection readiness is `blocked` by
  runtime-truth or Presenter Registry blockers.
- Missing live T3/Zed packets are a warning in this slice, not a backend blocker.

## Scenario Matrix

| ID | Scenario | Runtime-truth coverage | Presenters | Blocks Registry when |
| --- | --- | --- | --- | --- |
| P0 | simple prompt | T0 | CLI, ACP, T3 Code, Zed | A clean visible answer lacks clean Pixir assistant evidence. |
| P1 | file read or tool use | T3 | CLI, ACP, T3 Code, Zed | Tool activity is visible without paired `tool_call` / `tool_result`, or paired evidence is hidden. |
| P2 | partial or failed Turn | T1, T2, T6, T9 | CLI, ACP, T3 Code, Zed | Partial or failed evidence is projected as clean final success. |
| P3 | Subagent timeout or completion | T4, T10 | CLI, ACP, T3 Code, Zed | Timeout/completion lacks child id, status, duration, or actionable terminal evidence. |
| P4 | Workflow partial or diagnostic outcome | T5, T11 | CLI, ACP, T3 Code | Partial, held, failed, or completed Workflow evidence is collapsed into an inaccurate Presenter state. |
| P5 | ACP replay or load | T6, T7 | ACP, T3 Code, Zed | ACP load/replay promotes audit-only partial/failure evidence into clean History. |

## Rubric

| Status | Meaning |
| --- | --- |
| `pass` | Pixir canonical diagnostics and Presenter-visible state agree for the scenario. |
| `warn` | Evidence is honest but incomplete, manual Presenter packets are pending, or an actionable partial state is visible. |
| `fail` | A Presenter reports clean completion without matching clean Pixir evidence, or partial/failure evidence is projected as success. |

Hard fail examples:

- Presenter says completed while Pixir lacks clean `assistant_message` evidence and lacks explicit failure evidence.
- `metadata.partial == true` assistant evidence is projected as a normal final answer.
- `turn_failed`, Subagent timeout, or Workflow partial evidence is hidden behind a clean completed UI state.
- ACP load/replay shows a stale or partial answer as clean History.

Warning examples:

- Subagent timeout is explicit and actionable.
- Workflow outcome is partial with held steps and safe next actions.
- Runtime-truth fixtures pass, but refreshed T3/Zed live packets have not been recorded yet.

## Evidence Packet

For each live Presenter run, save a small gitignored packet such as:

```text
.pixir/benchmarks/projection-parity/<timestamp>-<presenter>-<scenario>/
```

Required canonical files:

```text
INDEX.md
scenario-id.txt
session-id.txt
pixir-diagnose.json
classification.md
```

Required visible notes file, using one of:

```text
presenter-visible-notes.md
zed-or-t3-visible-notes.md
cli-visible-notes.md
acp-visible-notes.md
```

Recommended optional files:

```text
pixir-tree.json
pixir-version.txt
runtime-truth-gauntlet.json
projection-parity-gauntlet.json
```

Do not commit raw Logs, screenshots, personal absolute paths, credentials, or local
Presenter databases. Commit only summarized findings and issue comments.

## T3 And Zed Dogfood

Use non-personal paths in committed docs and issue comments:

```bash
mix escript.build
./pixir --version
./pixir doctor --json
```

After a Presenter run, capture canonical evidence:

```bash
./pixir diagnose session <session-id> --json > pixir-diagnose.json
./pixir tree <session-id> --json > pixir-tree.json
```

Minimum refreshed dogfood packet:

- one Zed packet for P0 or P1;
- one T3 Code packet for P3 or P4;
- both packets compared against `pixir diagnose session --json`;
- any mismatch classified as `pixir_core`, `pixir_acp_translation`,
  `zed_projection`, `t3_projection_ui`, `t3_adapter_bridge`, or `operator_config`.

## Relationship To Runtime Truth

`bin/pixir-runtime-trust-gauntlet` remains the deterministic fixture-backed backend
gate. The projection parity gauntlet consumes its JSON output and adds a Presenter
evidence layer:

```text
runtime fixtures -> runtime-truth-gauntlet.json -> projection-parity-gauntlet.json
                                                     ^
                                                     |
                                      Presenter evidence packets
```

Use the runtime-truth result for no-network CLI/ACP-compatible checks. Use Presenter
packets for client-specific behavior that cannot be proved from backend fixtures alone.

## Registry Readiness Summary

For #52, report:

- runtime-truth readiness: `not_blocked`, `warning`, or `blocked`;
- Presenter evidence readiness: `not_blocked`, `warning`, or `blocked`;
- scenario statuses P0-P5;
- blockers and warnings from `projection-parity-gauntlet.json`;
- whether T3/Zed evidence is refreshed for the target Pixir binary.

The gauntlet can show that Pixir is not blocked by backend/projection evidence, but it
does not publish Registry metadata or replace a final Registry review.
