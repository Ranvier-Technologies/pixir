# 36. Idle-timeout recovery does not auto-resume ambiguous work

Date: 2026-07-03
Status: Accepted
Implementation status: Decision documented; PR #174 implements deterministic manual
recovery guidance. Amended 2026-08-01 (issue #462): the dangling-tool-call recovery is
the first automatic TURN-LEVEL recovery retry implemented under this ADR's conditions — see
"Amendment: the dangling-tool-call retry (#462)" below.

## Context

Pixir executor dogfood exposed a provider stream stall during a write-capable one-shot
run. The CLI exited with a provider idle-timeout failure and the operator had to inspect
partial filesystem changes, recover context manually, and relaunch work with explicit
instructions.

PR #174 improved the deterministic recovery path:

- `turn_failed.details.recovery` now records diagnose and resume commands;
- one-shot JSON and stderr output expose copyable recovery guidance;
- diagnostics distinguish provider stream idle timeout from permission, workspace, and
  tool failures.

The remaining question is whether Pixir should automatically retry or resume after an
idle timeout.

ADR 0003 and ADR 0019 are the hard boundary. Pixir sends Responses requests with
`store: false`, and the local Log is the source of truth. A WebSocket
`previous_response_id` is connection-local optimization state, not durable Session
state. If a provider stream dies, Pixir cannot reattach to the remote stream as if the
backend owned the conversation. Any cross-turn "resume" is a fresh Provider invocation
rebuilt from Pixir's Log.

That distinction matters most for write-capable executor sessions. A timed-out request
may have already emitted text, requested tools, run host commands, edited files, or
left effects outside the model transcript. Arbitrary bash idempotency cannot be proven
by Pixir, and the current permission safe-list is an ergonomics heuristic, not a
proof-grade read-only classifier. Silent replay can duplicate writes, race a parent
orchestrator that already retried the task, or produce two active writers in the same
Workspace.

## Decision

Pixir v1 does not automatically cross-turn resume ambiguous work after provider idle
timeout.

Idle-timeout recovery is manual by default:

- record durable timeout evidence in the Log;
- report a structured terminal failure;
- print or return exact diagnose/resume commands;
- let the operator or outer orchestrator decide whether to resume.

Pixir separates four recovery concepts that must not be collapsed:

| Concept | Meaning | v1 stance |
| --- | --- | --- |
| Transport fallback | Switch from WebSocket to HTTP/SSE, or reconnect later, while preserving Log truth. | Allowed by ADR 0019 when it does not hide provider/model failure. |
| Provider request retry | Retry the same live Turn request after a transport/provider interruption. | Future opt-in only, and only before any durable output or tool-side-effect evidence exists for that request segment. |
| Manual resume | Start a new Turn or CLI invocation from Log evidence and explicit operator intent. | Supported through recovery guidance and `pixir resume`. |
| Automatic Turn resume | Pixir silently starts new semantic work after a timed-out Turn. | Not allowed in v1. |

Write-capable executor sessions must not auto-resume after idle timeout. A future ADR is
required before enabling any automatic recovery that can re-enter write-capable work.

Read-only auto-resume is also deferred. A future implementation may classify some
sessions or request segments as safe to retry, but that decision must use durable,
Log-observable predicates instead of claims such as "the command is idempotent." At
minimum, a future automatic provider request retry must prove:

- the retry happens inside the same live Turn, not as hidden cross-turn resume;
- the interrupted request segment emitted no durable assistant output, tool call,
  tool result, provider usage, or permission/workspace decision that could affect
  future behavior;
- no local Tool or host command crossed the boundary in that segment;
- the retry is bounded by attempt count, backoff, and a circuit breaker;
- retry attempts and final outcome are visible in structured evidence;
- a single-writer or owner guard prevents concurrent manual and automatic recovery;
- CLI exit codes and JSON shapes remain versioned and do not hide recovered timeouts.

Safe-resume prompts are helpful operator guidance, but they are not a safety mechanism.
Safety comes from Log predicates, permission/workspace posture, bounded retries,
single-writer ownership, and explicit evidence.

`previous_response_id` must never be promoted to durable resume truth. It may speed up a
healthy live connection, but if the socket, model, prompt shape, or Session branch
changes, Pixir resumes from the Log, not from Provider continuation state.

## Amendment: the dangling-tool-call retry (#462)

Date: 2026-08-01.

This ADR's Decision table lists "Provider request retry" as *"future opt-in only"*, and
the header above previously read "no automatic retry or resume behavior is implemented."
That is no longer accurate. Issue #462 ships the first automatic TURN-LEVEL recovery
retry in Pixir, and it is recorded here rather than in a new ADR because it is exactly
the narrow case this ADR anticipated, not an expansion of it.

Precision about "first", because the unqualified claim overstates it: Pixir has always
retried transient provider failures at the transport and status level, in
`Pixir.Provider.attempt/5`, which re-sends the *same* request after a network blip, a
429, or a 5xx. What is new is a retry at the Turn level, triggered by a structured
`:dangling_tool_call` error, that **modifies the request it re-sends** — the Turn rebuilds
it from the Log with synthesized evidence appended. Retrying an unchanged request is a
transport concern; changing the request because the conversation state was wrong is a
recovery decision, and it is that class this ADR's conditions are applied to below.

**What it does.** When a Turn's provider request is rejected with the structured
dangling-call error — `invalid_request_error` over HTTP 200, `param: "input"`, "No tool
output found for function call `<id>`" — for a call id that appears in no Log event,
Pixir synthesizes a cancelled tool output for exactly that id and retries the request.
The class arises when the provider committed a function call that Pixir never persisted
(a Turn killed between commit and persist, or a Log written by a pre-#462 binary).

**Why this is a retry and not a resume.** The distinction this ADR draws is preserved:
Pixir does not reattach to a dead stream and does not start new semantic work. It rebuilds
the request from its own Log, with one synthesized event added to it, and re-sends it
inside the same Turn. `previous_response_id` is not involved.

### The ADR's conditions, point by point

The ADR requires a future automatic provider request retry to prove seven things. Each is
addressed below.

1. **"the retry happens inside the same live Turn, not as hidden cross-turn resume."**
   Satisfied. The recovery is a branch of `Pixir.Turn`'s existing
   `handle_provider_error/6`, alongside the overflow and critical-transport recoveries. It
   re-enters `loop/3` with the same Turn state and the same iteration counter. No new Turn
   is started, and nothing crosses a Turn boundary.

2. **"the interrupted request segment emitted no durable assistant output, tool call, tool
   result, provider usage, or permission/workspace decision."** Satisfied, and provable
   from the Log rather than asserted. The rejection is a *request validation* failure: the
   provider rejected the input before generating anything, so the segment emitted no
   output of any kind — there is no `provider_usage` to record and no assistant text.
   Recovery additionally refuses to fire when the named id is already a persisted
   `tool_call` (`persisted_call_id?/2`), so the retry only ever covers a call for which no
   durable evidence exists. A call that did persist belongs to the pre-existing orphan
   reconciliation, untouched here.

3. **"no local Tool or host command crossed the boundary in that segment."** Satisfied by
   construction, and this is the load-bearing point. The whole premise of the class is that
   the call was *never executed*: it existed only provider-side, so no `Tools.Executor`
   invocation, no bash, no filesystem write happened for it. The synthesized output says
   so explicitly — it is an `ok: false` result carrying the `orphan_tool_call` error kind
   with reason `provider_dangling_tool_call`, i.e. an assertion that the call did NOT run.
   Pixir never fabricates a success, never invents tool output, and never claims a host
   command executed. The write-capable prohibition this ADR is most protective of is not
   engaged: nothing is re-entered, because nothing ran.

4. **"the retry is bounded by attempt count, backoff, and a circuit breaker."** Satisfied
   by a double bound. Per id: `dangling_call_recoveries` is a `MapSet` and a second
   rejection naming an already-recovered id surfaces the provider error unchanged (once
   per id, per Turn). In total: `@dangling_call_recovery_budget` caps recoveries across
   *all* ids, because the Responses validator names one missing output per round and a
   per-id bound alone would not bound the loop. Across the Session's lifetime:
   `@dangling_call_session_budget` is read off the Log itself — the count of synthesized
   markers already there — because a per-Turn budget resets every Turn, so a provider
   naming fresh ids each Turn would otherwise append two durable events per recovery for
   the life of the Session. That ceiling needs no state and survives a restart. Once any
   bound is spent the original error is surfaced. No backoff is applied and none is
   appropriate: this is not a
   contention or overload error but a deterministic input-validation rejection, and
   re-sending the identical request after a delay would fail identically. The budget is the
   circuit breaker.

5. **"retry attempts and final outcome are visible in structured evidence."** Satisfied,
   and this is the strongest condition here. Every recovery appends *two durable Log
   events before the retry is issued*: a `tool_call` marked
   `synthesized: {reason: "provider_dangling_tool_call"}`, and its paired `tool_result`
   carrying the `orphan_tool_call` error. The Log therefore records that a synthetic output
   was injected, for which id, and why — the Log never silently pretends the call ran. If
   the recovery cannot be recorded, `record_dangling_call_recovery/2` returns `:no_recovery`
   and the original provider error surfaces; the retry is strictly gated on the evidence
   landing first. A final failure after the budget is spent is an ordinary `turn_failed`
   carrying the unmodified provider error.

6. **"a single-writer or owner guard prevents concurrent manual and automatic recovery."**
   Satisfied by the pre-existing guard, unchanged. The recovery runs inside a live Turn,
   and a Session admits one Turn at a time (`start_turn` returns `{:error, :busy}`
   otherwise); all Log appends go through the Session process holding the writer lease
   (ADR 0035). An operator's manual `pixir resume` cannot run concurrently with this
   recovery because it would need a Turn slot that is already held.

7. **"CLI exit codes and JSON shapes remain versioned and do not hide recovered
   timeouts."** Satisfied. A recovered Turn's envelope and exit contract are those of a
   normal Turn — the recovery is visible in the Log, not in the exit code, which is the
   pinned decision in the #462 brief. Nothing is hidden: the synthesized pair is in the
   Log for any consumer to read. A Turn that exhausts the budget fails with the provider's
   own error, so a genuinely unrecoverable Session still reports failure.

### Scope of the amendment

This amendment authorizes automatic retry for the structured dangling-call rejection and
nothing else. It does not relax the idle-timeout stance: an idle timeout still records
durable evidence and reports a structured terminal failure with manual recovery guidance,
exactly as decided above. It does not enable read-only auto-resume, does not touch
`previous_response_id`, and does not permit re-entering work that may have executed. Any
other automatic recovery class still requires its own decision.

Note also that #462's layer 1 (persisting each function call the moment the provider
commits it on the wire, so a cancelled Turn cannot lose it) is not a retry at all and is
not governed by this ADR — it is ordinary durable-evidence recording. Layer 1 is what
prevents the poisoning; this retry heals Logs already poisoned, including by older
binaries.

## Consequences

- Pixir remains safe for Claude, Codex, Fable, T3, Zed, and other orchestrators that may
  have their own timeout and retry policies. Pixir will not secretly create a second
  writer while an outer orchestrator is also recovering.
- Operators get deterministic recovery instructions instead of hidden semantic replay.
- Some provider stalls that could eventually be recoverable still require manual action
  in v1. That friction is intentional until Pixir can prove the replay is safe.
- Future retry work can still happen, but it must be named as retry, not stream
  reattachment or durable Provider resume.
- The permission safe-list should not be used as the sole basis for read-only
  auto-resume. It may need hardening before any automatic read-only retry policy.

## Non-goals

- This ADR does not implement automatic retry, automatic resume, or new CLI flags.
  (Amended 2026-08-01: the dangling-tool-call retry of #462 is the one automatic retry
  now implemented, under the conditions enumerated in the amendment above. Automatic
  resume and CLI flags remain unimplemented.)
- This ADR does not prove idempotency for arbitrary bash, `git`, `node`, `mix`, or
  other host commands.
- This ADR does not enable `store: true` or Provider-hosted Session persistence.
- This ADR does not change WebSocket fallback semantics from ADR 0019.
- This ADR does not implement Workflow resume.
- This ADR does not change `pixir resume` behavior by itself.

## Verification Direction

Immediate documentation checks:

```bash
git diff --check docs/adr AGENTS.md
mix format --check-formatted
```

Future implementation checks should prove:

- provider idle timeout before any provider output records manual recovery guidance and
  does not silently start a new Turn;
- provider idle timeout after a write-capable `tool_call` never auto-resumes;
- a concurrent manual resume and any future automatic recovery path cannot both own the
  same write-capable Workspace;
- SIGTERM or outer-orchestrator timeout still leaves enough durable evidence or stderr
  guidance for manual recovery;
- read-only retry gates reject shell commands whose apparent command family can still
  mutate through flags, redirection, path traversal, or nested tools.

Dangling-tool-call retry checks (implemented, `#462`). The amendment above records
behavior that already ships, so these are the checks that let a later reader confirm
conditions 4, 5, and 6 without re-deriving them from the code:

- **condition 4, bounded by attempt count and a circuit breaker** — a second rejection
  naming an already-recovered id surfaces the provider error unchanged; a provider naming
  a *fresh* id every round stops at the per-Turn budget and fails with the provider's own
  error; a Session whose Log already carries the Session-lifetime ceiling of synthesized
  markers refuses further recovery, with the refusal logged and its counts named;
- **condition 5, retry attempts visible in structured evidence** — the synthesized
  `tool_call` and its paired `orphan_tool_call` result are both durable in the Log *before*
  the retry is issued, and a recovery whose evidence cannot be recorded surfaces the
  original error instead of retrying; the classifier→Turn seam is driven end to end so
  the `details.call_id` shape cannot drift between the two halves;
- **condition 6, single-writer/owner guard** — the recovery only runs inside a live Turn
  and a Session admits one Turn at a time, so a manual `pixir resume` cannot run
  concurrently; a rejection naming an id the Log already carries records no synthesized
  pair at all, leaving that call to the pre-existing orphan reconciliation;
- **the exit contract (condition 7)** — a recovered Turn's envelope and exit code match a
  normal Turn's, and a Turn that exhausts a bound still fails with the provider's error.

## References

- ADR 0003: stateless Turns and local Log source of truth.
- ADR 0004: unified Event envelope and canonical versus ephemeral evidence.
- ADR 0006: permission model and safe-list ergonomics.
- ADR 0017: minimal Harness core and Presenter boundary.
- ADR 0019: Provider usage, prompt-cache observability, and WebSocket continuation.
- ADR 0026: runtime terminal-state and replay contract.
- ADR 0027: external command execution as a bounded host boundary.
- ADR 0035: write-capable Sessions require an external evidence mirror.
- Issue #159: Provider idle-timeout recovery and resume guidance for executor sessions.
- PR #174: deterministic idle-timeout recovery guidance.
- Issue #462: cancelling a Turn mid-stream must not poison the Session; source of the
  2026-08-01 amendment and of the first automatic turn-level recovery retry.
