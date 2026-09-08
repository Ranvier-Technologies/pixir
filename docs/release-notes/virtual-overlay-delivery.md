# Virtual overlay lifetime, delivery and feedback

The purpose of virtual overlays is to avoid a physical workspace copy per child.
This change does not add a persistent Session filesystem or an import cache:
commands within one invocation share virtual edits; the next invocation reimports
the operator's files. Canonical Logs and artifacts remain durable on disk.

`run_virtual_commands` accepts optional boolean `deliverable`. Marking a successful
invocation selects its artifact for child delivery even if later unmarked reads
produce empty diffs. A later successful explicit mark replaces it; marking an empty
diff is valid. Without a mark, the latest successful artifact remains the fallback.
Invalid values are rejected; operator-owned read sets and limits cannot be supplied
by the model. Selection metadata lives outside the unchanged `virtual_diff` v1 body.

    {"commands":["sed -i 's/old/new/' source.txt","cat source.txt"],"deliverable":true}

Selection requires the matching canonical virtual-command call and successful
result. Failed, unmatched, duplicate, dry-run and mismatched-intent results cannot
override delivery. A validated warm-start boundary clears inherited explicit
preference for the new child segment while retaining legacy unmarked fallback.
Cold projection preserves the chosen reference. Selection never applies changes:
the separate permissioned `apply_virtual_diff` operation still defaults to dry-run
and checks the artifact/preimage before any explicit mutation.

Model feedback reserves space for command IDs/statuses/exit codes before stdout,
stderr and diff excerpts. Display, excerpt and omission counts are explicit; total
feedback remains below 16,000 bytes, with existing terminal-control neutralization.
Status and excerpt cuts use the shared `Pixir.Tool.truncate/2` standard marker and
its explicit `{:total_bytes, budget}` form, reserving marker bytes and normalizing
UTF-8. Existing integer-prefix callers retain their established behavior.
Full operator-bounded evidence stays in the canonical artifact; feedback limits do
not imply that the artifact itself is untruncated.

This is a separate Tool/Prompt Contract change: `px8` and `pa5` label the new
schema/description. Existing Layer 0, fence tokens and cache-control layout are
unchanged; old Log/fixture labels remain historical. An initial cache restart is
intentional. Do not mix its performance/observability window with the independently
verified WebSocket recovery change or claim a model-speed improvement.

Both changes ship in 0.1.16 after separate PRs and staged live probes. ADR 0020
requires attributable verification windows, not separate version numbers. The final
combined candidate still requires full release acceptance; the individual probes do
not establish a comparative cache-hit-rate or speed improvement.

Behavioral tests cover invocation reset, explicit/default selection, replacement,
empty marks, malformed inputs, forged pairs, warm-start/cold restore, bounded
feedback, and explicit dry-run/apply of a newline-terminated selected fixture after
a later read. The existing no-trailing-newline diff edge is not silently fixed here.
