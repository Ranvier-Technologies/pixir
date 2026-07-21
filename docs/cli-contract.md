# Pixir CLI Contract v1

| Contract | Version | Date |
| --- | ---: | --- |
| `pixir-cli-contract` | 1 | 2026-07-20 |

The fields listed in this document are promised for contract version 1; anything not
listed is unstable and may change without notice.

This is a checked-in, versioned caller contract with pinning tests. It is not a
generated schema. Unless a row says otherwise, a listed field is required in the
shape to which the row applies. “Nullable” means the field is present and its value
may be JSON `null`.

## One-shot and resume `--json`

`pixir --json "prompt"` and `pixir --json resume <session-id> "prompt"` suppress the
streaming presenter and write one final JSON value to stdout. Both paths use the same
turn-result envelope.

### Turn-result envelope

| Field | Type | Meaning | Notes |
| --- | --- | --- | --- |
| `ok` | boolean | Whether a non-empty final answer was delivered. | `true` only for `status: "completed"`. |
| `status` | string | Terminal presenter status. | Current values are `completed`, `incomplete`, `timed_out`, `interrupted`, and `error`. |
| `kind` | string | Envelope discriminator. | `one_shot_turn`. |
| `session_id` | string | Durable Session identifier. | Present after a Session has started. |
| `resume_command` | string | Ready-to-run command for continuing this Session. | Treat as an opaque command string. |
| `diagnostics` | object | Recovery and inspection commands. | Stable child fields are listed below. |
| `diagnostics.diagnose_command` | string | Ready-to-run session diagnosis command. | Treat as opaque text. |
| `output` | string | Final assistant answer. | Present only for successful `completed` results. |
| `output_truncation` | object or null | Final-answer Provider truncation projection. | Present on completed and incomplete clean Turn endings; the object's undocumented children remain unstable. |
| `warning_count` | integer | Number of observed output-truncation warnings. | Clean endings (`completed`/`incomplete`) only; omitted on `timed_out`, `interrupted`, and `error` envelopes. Non-negative. |
| `warnings_truncated` | boolean | Whether the retained `warnings` list is shorter than `warning_count`. | Clean endings only, as above. |
| `warnings` | array | Bounded output-truncation warnings. | Clean endings only, as above. Warning object fields are not declared by this contract. |
| `message` | string | Human diagnosis of the incomplete or failed result. | Present when the builder has no more specific durable failure fields; always present for `incomplete`. |
| `exit_code` | integer | Process exit selected for an abnormal result. | Present for `timed_out`, `interrupted`, and `error`; omitted from clean `completed` and `incomplete` envelopes. |
| `recovery` | object | Fail-closed timeout recovery guidance. | Present for `timed_out`. |
| `recovery.classification` | string | Timeout classification. | `presenter_idle_timeout`. |
| `recovery.diagnose_command` | string | Ready-to-run diagnosis command. | |
| `recovery.resume_command` | string | Ready-to-run resume command. | |
| `recovery.auto_retry` | object | Whether automatic replay is safe. | |
| `recovery.auto_retry.safe` | boolean | Automatic-retry safety decision. | `false` for presenter idle timeout. |
| `recovery.auto_retry.reason` | string | Reason automatic replay is not safe. | |
| `recovery.next_actions` | array of strings | Ordered recovery guidance. | Callers must not infer that a timeout made no side effects. |

A failure before a Session starts cannot supply Session recovery commands. In
`--json` mode that path uses the repository-wide structured error shape instead:

| Field | Type | Meaning | Notes |
| --- | --- | --- | --- |
| `ok` | boolean | Always `false`. | |
| `error` | object | Structured error. | |
| `error.kind` | string | Stable machine classification. | Branch on this, not prose. |
| `error.message` | string | Human-readable explanation. | Wording is not stable. |
| `error.details` | object | Machine context and possible next actions. | Undocumented children are unstable. |

Durable `turn_failed` data may add fields to an abnormal turn-result envelope. Those
additive fields are not promised here.

## `pixir tree --json`

A successful call returns `{"ok":true,"tree":...}`. Every nested child Session uses
the same Session-node shape as the root.

| Field | Type | Meaning | Notes |
| --- | --- | --- | --- |
| `ok` | boolean | Projection succeeded. | `true` on this success shape. |
| `tree` | object | Root Session node. | |
| `tree.session_id` | string | Session identifier for this node. | |
| `tree.workspace` | string | Absolute workspace used to locate the Log. | |
| `tree.log_path` | string | Session Log path. | A path pointer, not a log-format promise. |
| `tree.log_exists` | boolean | Whether the referenced Log exists. | Missing child Logs are represented, not hidden. |
| `tree.event_count` | integer | Number of folded Events. | Non-negative; zero for a missing child Log. |
| `tree.event_counts` | object | Counts keyed by Event type. | Keys depend on observed Events. |
| `tree.first_event_ts` | string or null | First Event timestamp. | Nullable. |
| `tree.last_event_ts` | string or null | Last Event timestamp. | Nullable. |
| `tree.subagents` | array | Durable Subagent records. | Array order follows durable projection order, but callers should use identifiers. |
| `tree.subagents[].subagent_id` | string | Durable Subagent identifier. | |
| `tree.subagents[].events` | array of strings | Observed lifecycle event names. | |
| `tree.subagents[].first_seq` | integer | First parent-Log sequence for this Subagent. | |
| `tree.subagents[].last_seq` | integer | Last parent-Log sequence for this Subagent. | |
| `tree.subagents[].child_session_id` | string | Child Session identifier. | Present when durable lifecycle evidence recorded it. |
| `tree.subagents[].status` | string | Latest recorded child status. | Present when lifecycle evidence recorded it. |
| `tree.subagents[].session` | object or null | Nested child Session node. | A node is attached when child id and workspace are present. |
| `tree.forks` | array | Fork-child records discovered from child Logs. | |
| `tree.forks[].child_session_id` | string | Fork child Session identifier. | |
| `tree.forks[].parent_session_id` | string | Immediate parent Session identifier. | |
| `tree.forks[].fork_root_session_id` | string | Root identifier of the fork family. | |
| `tree.forks[].forked_to_seq` | integer | Parent replay boundary. | Non-negative. |
| `tree.forks[].replay_event_count` | integer | Number of replayed parent Events. | Non-negative. |
| `tree.forks[].from_seq` | integer | First replayed sequence. | |
| `tree.forks[].strategy` | string | Fork projection strategy. | |
| `tree.forks[].workspace` | string | Workspace used for the child projection. | |
| `tree.forks[].branch_summary` | object | Presence/provenance summary for branch synthesis. | Child fields are not declared here. |
| `tree.forks[].session` | object or null | Nested fork-child Session node. | |

On failure, `tree --json` emits the repository-wide structured error shape described
above instead of a success `tree` envelope.

## Durable Provider-usage evidence

The caller-facing stable projection is
`pixir diagnose session <session-id> --json` under `provider_usage`. It is derived from
canonical `provider_usage` Events in the local Log; it does not call the Provider and
it is not model replay context.

| Field | Type | Meaning | Notes |
| --- | --- | --- | --- |
| `provider_usage` | object | Provider-call usage projection for the Session. | Nested in the diagnose result. |
| `provider_usage.count` | integer | Number of canonical usage Events. | Non-negative. |
| `provider_usage.latest` | object or null | Projection of the latest usage Event. | `null` when no usage Event exists. |
| `provider_usage.latest.seq` | integer | Canonical Event sequence. | Present when `latest` is an object. |
| `provider_usage.latest.model` | string or null | Recorded model id. | Nullable for historical evidence. |
| `provider_usage.latest.active_transport` | string or null | Recorded active Provider transport. | Nullable for historical evidence. |
| `provider_usage.latest.continuation_attempted` | boolean or null | Whether continuation was attempted. | Nullable for historical evidence. |
| `provider_usage.latest.continuation_reset_reason` | string or null | Why continuation reset. | Nullable. |
| `provider_usage.latest.used_previous_response_id` | boolean or null | Whether the call used a previous response id. | Nullable. |
| `provider_usage.latest.usage_summary` | object or null | Provider-normalized token/cache summary. | The object's children are intentionally not promised by contract v1. |
| `provider_usage.output_truncation` | object | Bounded tri-state completeness summary. | Derived from successful usage evidence. |
| `provider_usage.output_truncation.counts` | object | Counts by tri-state. | |
| `provider_usage.output_truncation.counts.not_truncated` | integer | Calls explicitly known complete. | Non-negative. |
| `provider_usage.output_truncation.counts.truncated` | integer | Calls explicitly known truncated. | Non-negative. |
| `provider_usage.output_truncation.counts.unknown` | integer | Calls without conclusive completeness evidence. | Non-negative. |
| `provider_usage.output_truncation.latest` | object or null | Latest truncation projection. | Child fields are not declared here. |
| `provider_usage.output_truncation.positive_count` | integer | Total positive truncation observations. | Non-negative. |
| `provider_usage.output_truncation.positive_refs` | array | Bounded references to positive evidence. | Reference object children are not declared here. |
| `provider_usage.output_truncation.positive_refs_truncated` | boolean | Whether positive references were bounded. | |

The underlying Event is durable evidence, but raw NDJSON Event layout and raw Provider
usage payloads are not a caller-facing CLI contract.

## Delegate envelope

The existing, more detailed Delegate caller documentation remains authoritative for
Delegate-specific interpretation and examples:
[`docs/examples/delegate-cli-live/README.md`](examples/delegate-cli-live/README.md#contract).
This contract pins the common fields integrations use across attached result shapes.
Fields that only exist after a child starts are conditional as noted.

| Field | Type | Meaning | Notes |
| --- | --- | --- | --- |
| `ok` | boolean | High-level result indication. | Do not collapse it with `work_complete`. |
| `status` | string | Delegate command/work status. | |
| `work_complete` | boolean | Whether delegated work reached clean terminal success. | |
| `children` | array | Child result projections. | Present for Subagent result shapes. Array order is not a task identity. |
| `children[].index` | integer | Zero-based source `tasks[]` position. | Join by this value, not array position. |
| `children[].status` | string | Child lifecycle/terminal status. | |
| `children[].reason_code` | string | Stable child outcome classification. | Added by the v1 envelope builder. |
| `children[].child_session_id` | string | Durable child Session identifier. | Present after spawn succeeds. |
| `children[].child_log_path` | string | Durable child Log path. | Present after spawn succeeds. |
| `children[].summary` | string | Bounded child summary. | Evidence pointer, not proof by itself. |
| `children[].retry_history` | array | Bounded history of automatic retry attempts. | Present when the runtime retried the child. |
| `children[].resume_command` | string | Ready-to-run child-specific recovery command. | Present for non-completed recoverable children; recover the child, not the whole spec. |

### Delegate spec-surface admission

Delegate specs are admitted once, before dry-run planning, one-shot execution, or
attached execution starts. Admission is fail-closed for the remaining tolerant nested
surfaces:

- The root `limits` timeout-knob bag must be an object and accepts only
  `child_timeout_ms`, `delegate_timeout_ms`, `timeout_ms`, and `wait_horizon_ms`.
  Unknown keys are rejected at `/limits/<key>` with the accepted vocabulary; values
  retain the runtime timeout normalizer's existing contract.
- A root `steps` field is valid only when `strategy` is `workflow`. Other strategies
  receive an `invalid_spec` rejection at `/steps`; callers should either select the
  Workflow strategy or remove the field.
- A Workflow step may include `limits` only when its `workspace_mode` is
  `virtual_overlay`. In either root `steps` or nested `workflow.steps`, `limits` must be
  an object whose keys come from `Pixir.VirtualOverlay.limit_keys/0` and whose values
  are non-negative integers. Unknown keys point to the exact
  `/steps/<index>/limits/<key>` (or nested equivalent) and report the accepted keys.
- The root `workflow` field is valid only when `strategy` is `workflow`, and its value
  must be an object. That object is a closed shell whose only accepted key is currently
  `steps`; strategy mismatches and non-object values are rejected at `/workflow`, while
  unknown nested keys are rejected at `/workflow/<key>`. Root `steps` and
  `workflow.steps` cannot both be present: co-presence is rejected at
  `/workflow/steps` as mutually exclusive, regardless of the root value.

**Recorded decision (2026-07-20):** `template_args` is free-form by design. Template
authors choose arbitrary substitution values, so validating its contents against
template placeholders is explicitly out of scope for Delegate spec admission. The
Delegate CLI path does not instantiate Workflow Templates today: template-only specs
are rejected for missing `steps` (or `workflow.steps`).

## Exit-code semantics

Exit codes are path-scoped. Callers must first identify the command path, then parse its
JSON envelope.

### One-shot and resume

| Exit | Meaning |
| ---: | --- |
| `0` | A non-empty final assistant answer was delivered. |
| `1` | General Turn/runtime error. |
| `2` | Invalid arguments or a requested Session was not found at session start. |
| `1` | Also: resuming an id whose Log is missing fails during posture restoration (`resume_policy_unavailable`) before session start, so it exits `1`, not `2`. |
| `3` | Permission, bounded-write, workspace, or disabled-shell denial. |
| `5` | Session writer lease is active, stale, ambiguous, or lost. |
| `6` | Turn ended without a non-empty final assistant message. |
| `124` | Presenter idle timeout; inspect the fail-closed `recovery` object before resuming. |
| `130` | Turn was interrupted. |

### Tree and session diagnosis

`0` means the projection/diagnosis command completed successfully. `2` means invalid
arguments or a missing Session. Structured permission errors map to `3`, writer-lease
errors map to `5`, and other projection errors map to `1`. A diagnosis may itself
return `ok: false` and exit `1` when its checks block readiness.

### Delegate

Delegate has its own path-scoped meanings, including incomplete domain work at exit
`6`. Use the complete table in
[`docs/examples/delegate-cli-live/README.md`](examples/delegate-cli-live/README.md#exit-codes-are-path-scoped).
The envelope's `exit_code` is the same code selected for the process.

## Shell composition

**Read-only shell composition (pipes) is REJECTED: the one-rule fail-closed
metacharacter boundary stays; the native alternatives are `read` offset/limit paging
and delegation.**

This is a deliberate parser-surface decision, not an omitted feature. Treating a pipe
as read-only would require Pixir to parse and classify multiple commands, quoting,
redirection, substitutions, and command boundaries with shell fidelity. Contract v1
keeps one conservative rule: a command containing a shell metacharacter is not on the
read-only safe-command path. Use the native `read` tool's `offset` and `limit` for
bounded file paging, or delegate bounded read-only work to Pixir-managed Subagents.

## Explicitly not promised

Contract v1 does **not** promise:

- JSON object key ordering;
- human-readable stdout/stderr wording, summaries, help text, or error prose;
- NDJSON Log file layout or other on-disk log formats;
- fields not listed in this document, including additive diagnostics and raw Provider
  payload fields;
- ordering of `children` as task identity; or
- stability of opaque command strings beyond their documented purpose.
