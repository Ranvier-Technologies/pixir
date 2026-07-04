# 26. Runtime terminal-state and replay contract

Date: 2026-06-24

Status: Accepted

Implementation status: Contract accepted. Enforcement is tracked by #81, #82,
#83, and the join gauntlet in #84.

## Context

ADR 0003 and ADR 0004 make the append-only Log the source of truth, with a
deliberate split between canonical durable Events and ephemeral presenter
updates. ADR 0018 then requires replay and repair to derive Provider input from
that Log instead of from presenter transcripts.

That contract is now broad enough to need explicit terminal-state semantics.
Pixir can stream partial text, preserve a partial `assistant_message`, record
`turn_failed`, launch child Sessions as Subagents, and report Workflow partial
outcomes. Without a single vocabulary, a presenter, diagnostic, benchmark, or
operator can accidentally treat "process exited", "stream showed text", "child
timed out", or "workflow produced partial checkpoints" as clean completion.

The current implementation already contains the important primitives:

| Surface | Current evidence |
| --- | --- |
| Turn loop | `Pixir.Turn` records `user_message`, calls the Provider from folded History, persists final `assistant_message`, and records `turn_failed` while preserving useful partial assistant text after Provider errors. |
| Event vocabulary | `Pixir.Event` distinguishes canonical Events from ephemeral deltas and documents partial assistant evidence and audit-only `turn_failed`. |
| Provider replay | `Pixir.Provider` excludes partial `assistant_message`, `provider_usage`, and `turn_failed` from Provider input while still replaying clean assistant messages, tool pairs, compaction, branch summaries, and selected Subagent terminal events. |
| ACP replay | `Pixir.ACP.Translate` omits partial assistant evidence and `turn_failed` from clean transcript replay. |
| Diagnostics | `Pixir.SessionDiagnostics` warns on missing assistant/failure evidence, preserved partial assistants, durable turn failures, and Subagent timeout evidence. |
| Workflows | `Pixir.Workflows` separates `completion_ready` from `partial_outcome_ready` and returns failed, timeout, partial, and needs-orchestrator step evidence. |

This ADR fixes the backend vocabulary before further Scheduler and WorkflowRun
work. Presenters should project the vocabulary, not invent a separate truth.

## Decision

Pixir has three related but separate channels:

1. **Provider replay context**: canonical history that is folded into future
   Provider requests.
2. **Audit evidence**: durable Log facts that explain what happened but are not
   automatically model-visible on future Turns.
3. **Presenter projection**: ephemeral or replayed UI wire updates for CLI, ACP,
   T3 Code, Zed, or other clients.

Terminal state names are backend contract terms. Presenters may render friendlier
phrasing, but they must not collapse failure or partial states into clean
completion.

### Turn terminal states

| State | Meaning | Required durable evidence | Provider replay | Presenter contract |
| --- | --- | --- | --- | --- |
| `completed` | The Turn reached a clean assistant answer after the Provider/tool loop. | A non-partial canonical `assistant_message` after the current `user_message`; tool calls are paired or repaired. | Replay the clean `assistant_message`. | May show as normal final answer. |
| `partial_failed` | The Provider emitted useful assistant text but the Turn failed before clean completion. | `assistant_message` with `metadata.partial == true`, plus `turn_failed` or equivalent terminal failure metadata. | Do not replay the partial `assistant_message`; do not replay `turn_failed`. | May show partial text only as partial/failure evidence, not as normal final answer. |
| `failed` | The Turn failed without useful assistant text. | `turn_failed` with `terminal_status`, `error_kind`, and actionable `details` where available. | Do not replay. | Must show a failure/diagnostic state, not a clean answer. |
| `interrupted` | The operator or presenter interrupted the Turn. | Terminal status/failure evidence plus orphan tool-call repair if needed. | Do not replay as assistant content. | Must show cancellation/interruption. |
| `timed_out` | The Turn exceeded its configured time budget. | `turn_failed` or equivalent terminal timeout evidence with timeout and next-action context. | Do not replay as assistant content. | Must show timeout and next action. |

`completed` means "clean terminal evidence exists in the Log". It does not mean
that a process exited, a Task returned, the Provider stream closed, a presenter
displayed some text, or a client marked a prompt as done.

### Subagent terminal states

Subagents are supervised child Sessions. Parent state is a projection of child
state and manager evidence, not a second conversation transcript.

| State | Meaning | Required durable evidence | Parent replay impact |
| --- | --- | --- | --- |
| `completed` | The child Session completed and returned usable summary/checkpoint evidence. | `subagent_event` with child id, child session id, status, summary or checkpoint evidence, elapsed time when available. | May be folded into parent Provider context as selected terminal Subagent evidence. |
| `failed` | The child ended with an unrecovered failure. | `subagent_event` with reason, status, child id, child session id, and next actions. | May be folded into parent context if the parent must reason about failure. |
| `timed_out` | The child exceeded its configured timeout. | `subagent_event` with `timeout_ms`, `elapsed_ms`, `reason`, `child_session_id`, and `next_actions`. | May be folded into parent context if the parent must decide retry/partial synthesis. |
| `interrupted` / `cancelled` | The parent/operator cancelled the child. | `subagent_event` with cancellation reason and child identity. | May be folded into parent context if relevant to the parent decision. |
| `detached` | The child is no longer synchronously controlled by the current manager path. | `subagent_event` or diagnostic evidence with child identity and how to inspect/resume. | Audit/diagnostic by default; model-visible only if an explicit future contract chooses that. |

Queued and running are non-terminal. A parent wait must not report success merely
because a child exists. Timeout and detached states must be explicit and
operator-actionable.

### Workflow terminal states

Workflows are structural orchestration over Subagents, not a separate agent
truth source. A Workflow terminal state is derived from step evidence.

| State | Meaning | Required evidence |
| --- | --- | --- |
| `completed` / `completion_ready` | Every required step produced checkpoint-ready evidence. | Workflow result with all steps checkpoint-ready and dependent-safe usable checkpoints. |
| `partial` / `partial_outcome_ready` | At least one step produced usable partial evidence, or the workflow can synthesize a bounded partial result. | Workflow result with partial/failed/timeout/needs-orchestrator step lists and safe next actions. |
| `failed` | No safe useful outcome is available without rerun or human decision. | Failed step evidence and next actions. |
| `timed_out` | One or more steps timed out and the workflow cannot honestly promote a full completion. | Timeout step evidence propagated from Subagents. |
| `held` / `needs_orchestrator` | The workflow needs human or parent-orchestrator decision before continuing. | Held or needs-orchestrator step evidence and next actions. |

Workflow `ok == true` is reserved for full completion. Partial results are valid
runtime outcomes, but not successful completion.

### Replay and cache impact

Provider replay must include only events that are intentionally part of model
conversation state. Audit-only and presenter-only evidence must not change the
effective Provider input prefix.

| Event class | Examples | Replay/cache impact |
| --- | --- | --- |
| Provider-replayed conversation | `user_message`, clean non-partial `assistant_message`, paired `tool_call`/`tool_result`, valid same-model reasoning items, `history_compaction`, `branch_summary`, selected terminal `subagent_event` context. | Can affect prompt-cache prefix and future model behavior. |
| Audit-only durable evidence | `provider_usage`, `turn_failed`, partial `assistant_message`, diagnostic-only timeout/failure markers. | Must not be replayed to the Provider; should not affect prompt-cache prefix. |
| Presenter-only ephemeral evidence | `text_delta`, `reasoning_delta`, `status`, `plan`, `context_pressure`. | Never logged as replay history; does not affect prompt-cache prefix. |

Subagent and Workflow terminal facts are the one deliberate edge: when Pixir
folds terminal `subagent_event` summaries into parent Provider input, those
facts become model-visible and therefore can affect prefix/cache behavior. If a
Subagent fact is only diagnostic evidence, it must stay out of replay.

### Presenter projection

Presenters must preserve the backend truth:

- CLI may print partial text, but should label terminal failures clearly.
- ACP live streaming may emit `agent_message_chunk` from text deltas, but session
  replay must not project partial assistant evidence as a clean transcript.
- T3 Code and Zed may show client-native completion affordances, but Pixir's Log
  and diagnostics remain the source of truth for whether the Turn completed,
  failed, timed out, or produced partial evidence.
- Technical strings such as `Provider stream process exited.` are diagnostics,
  not normal assistant answers.

## Consequences

- Runtime code can now be audited against a small state matrix instead of ad hoc
  prose.
- Diagnostics can distinguish clean completion from partial/failure evidence.
- Prompt-cache claims remain meaningful because audit-only events do not silently
  change Provider replay.
- Subagent and Workflow scheduling work can proceed in parallel only after this
  contract is accepted, because they share terminal vocabulary.
- Some existing behavior may be compliant by construction, but tests should still
  lock the contract down in #81, #82, #83, and #84.

## Non-goals

- This ADR does not redesign CLI, ACP, T3 Code, or Zed UI surfaces.
- This ADR does not define a public stable Elixir API.
- This ADR does not implement a new Scheduler or durable WorkflowRun process.
- This ADR does not make public performance claims.
- This ADR does not change Provider replay by itself; it defines the contract that
  implementation PRs must satisfy.

## Verification Direction

Immediate verification for this ADR:

```bash
git diff --check docs/adr
mix format --check-formatted
```

Follow-up implementation checks:

```bash
mix test test/pixir/turn_test.exs
mix test test/pixir/session_diagnostics_test.exs
mix test test/pixir/subagents_test.exs
mix test test/pixir/workflows_test.exs
```

The final join gate (#84) must run a backend gauntlet that covers:

- clean Turn completion,
- Provider stream error after partial text,
- interrupted or timed-out Turn,
- Subagent completion,
- Subagent timeout,
- Workflow full completion,
- Workflow partial outcome,
- replay/cache inspection proving audit-only events do not enter Provider input,
- presenter projection checks for ACP/T3/Zed where local harnesses are available.

## References

- ADR 0003: Stateless Turns and local Log source of truth.
- ADR 0004: Unified Event envelope and canonical vs ephemeral events.
- ADR 0009: ACP transport and presenter boundary.
- ADR 0011: BEAM-native Subagents.
- ADR 0012: Structural Workflows over Subagents.
- ADR 0014: Workflow Checkpoint Bundles and partial outcomes.
- ADR 0018: Durable History compaction and replay repair.
- ADR 0019: Provider usage and prompt-cache evidence.
- ADR 0020: Prompt Contract, cache family, and compaction triggers.
- `Pixir.Event`, `Pixir.Turn`, `Pixir.Provider`, `Pixir.ACP.Translate`,
  `Pixir.SessionDiagnostics`, the internal Subagents manager, and
  `Pixir.Workflows`.
