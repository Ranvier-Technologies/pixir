# Partial child Log evidence in Monitor detail

This is the bounded child-evidence portion of issue 549. The integrated issue is
complete under the maintainer's 2026-09-06 acceptance of unknown omitted-event
totals with exact omitted bytes; the partial-evidence limitations below remain.
Parent and child append-only Logs remain canonical truth. All selection metadata
and projections below are recomputed, never written back to a Session Log.

## Read boundary

`Source.Filesystem.fetch_input/2` selects each parent-observed child with the
same public `Pixir.Log.fold_bounded/2` seam and workspace options used for the
parent. It preserves the existing per-Log byte cap and Monitor `max_events`
guard. There is no larger cap, index, full-read fallback, or manual Log rewrite.
Core's event-cap edge behavior is explicitly outside this slice.

Successful bounded child selections now retain their canonical portable Events
in `inputs.child_logs[session_id]`. Recomputable
`inputs.child_log_selections[session_id]` carries the corresponding Core
selection metadata, including partiality and incomplete trailing bytes. This is
an input field, **not** an addition to the frozen Presenter output schema.

A partial prefix/tail selection and an incomplete trailing append are distinct
from a missing/corrupt/unselectable child. Failed folds still leave a `null`
child entry and the existing missing-child fallback. A malformed retained
record is not dropped to make the rest of the sample look usable. Core currently
rejects a child with no selectable complete records; Monitor preserves that
unavailable result. Builder also handles an explicitly empty partial sample
without confusing it with a complete, present-empty Log.

Aggregate input completeness names prefix/tail or trailing partiality when no
child is missing. Mixed missing and partial inputs retain the missing aggregate
classification while each successfully selected child's metadata stays explicit.
The pre-existing partial-parent classification and PR624 lineage rules remain.

Manager diagnostics can hydrate full parent and child histories. Detail omits
that entire path whenever the parent or any selected child is incomplete, or a
child selection was unavailable (including retained corruption). A
trace test includes a complete-child positive control proving that diagnostics
are still invoked on the original complete-input path. Original complete-input
diagnostics behavior is otherwise unchanged.

For a complete parent whose child evidence prevents diagnostics hydration, the
caller explicitly supplies a bounded-snapshot-only observation. The existing
ActivityLedger can still establish durable growth across polls. The projection
uses `durable_snapshot`/`durable_log_activity` as appropriate and states that live
Owner reachability was not checked; it does not pretend to have probed another
runtime. Partial parents keep their conservative unknown liveness.

## Attribution and evidence

The frozen prose contract, especially Attempt lineage, Provider usage, Mutation,
and Post-terminal child activity, is authority alongside the frozen JSON schema.
A permissive nullable field alone is not permission to invent a fact.

For an incomplete child, every durable attempt keeps its canonical non-null
parent-derived ordinal, status, relation, predecessor, and parent evidence.
Its child event window is `unknown`, with null sequence bounds and no guessed
anchor refs. There is no `whole_child_log_single_attempt` shortcut, even when
only one parent attempt was retained: omitted child user-message anchors may
represent another epoch. Child-derived errors, usage, and decisive refs are
withheld from unknown attempt windows. Explicit parent error facts are kept.

Selected child records remain inspectable in the run evidence drawer with their
own canonical Session/sequence identities. Descriptions name retained child
observations rather than guessing first/second epochs or later attempt failure.
A partial primary child list wins over a verified mirror just as a complete
primary list does. An unavailable primary may still use the existing verified
mirror fallback; stale primary selection metadata does not taint that fallback.

Unit usage is a deduplicated incomplete fold of selected child usage where the
parent establishes the child association. Attempt-specific usage is omitted
when attribution is unknown. Run usage deduplicates `(session_id, seq)` across
units too when partial children are involved. Parent-gap usage remains withheld
under PR624. A queued unit without a durable attempt cannot certify complete
zero usage from a partial child either. Unit/run `source: incomplete`,
`complete: false`, and limitation notes qualify all sample counts, including zero.
Retained post-terminal partial-child usage is not assigned back to unit totals.

## Mutation and activity

For partial children, canonical parent bindings provide the unit's child roster
even when runtime Source has no terminal envelope. The unrelated existing
complete/missing-child mutation behavior is preserved. Successful write
call/result pairs in a retained contiguous segment still prove lower-bound
paths. Correlation keys include child Session and retained segment: a prefix
call and tail result cannot be joined across the missing middle just because
their call IDs match. Retained policy denials keep their evidence refs and never
become mutations. No retained writes means incomplete/indeterminate evidence,
not proof of `none`. Partial selections retain `mutation_evidence_incomplete`
even when positive lower-bound paths are present. An exact apply checkpoint
cannot make the aggregate run write set exact while other child evidence is
partial.

The frozen post-terminal activity dimension has no completeness or lower-bound
field. Therefore incomplete child activity is `undetermined`, with null
`event_count` and `latest_event_at`, not an exact selected count or an observed
zero. Provably later retained Events still keep their child IDs/evidence refs
and a root limitation notes their existence. Canonical parent execution,
liveness policy, and Workflow gates are not reclassified by this signal.

Human-readable notes on existing source, root, unit, attempt, usage, and mutation
limitation surfaces identify the child, prefix + tail versus trailing selection,
bytes read within the read bound, retained event count, and unknown total event
count. No exact unread event count or privacy filter is introduced.

## UI boundary and remaining work

The served-renderer bounded Log harness covers partial-child source, usage,
mutation, and general limitation panels using the actual `priv/static/app.js`
functions. Partial child notes do not masquerade as partial parent notes.
Frozen Presenter assets are unchanged. Root updated the served attempt card:
absent attempt usage now renders as unavailable, with unknown call/token totals,
instead of fabricating complete zero usage. Explicitly supplied complete zero
usage still renders as complete zero. The actual-renderer regression covers both
cases; no attempt totals or frozen schema fields are invented.

## Verification

Disposable real NDJSON tests cover prefix/tail visibility, unchanged Log bytes,
complete children, incomplete trailing appends, malformed retained records,
no selectable records, explicit zero-retained samples, partial parents plus
partial children, reused Session epochs, lower-bound writes and denials,
cross-gap correlation, post-terminal samples, mirror precedence, queued lineage,
run usage deduplication, and diagnostics bypass with a positive trace control.

```text
mix test test/projection/partial_child_evidence_test.exs test/projection/source_test.exs test/projection/mutation_child_evidence_test.exs test/projection/post_terminal_child_activity_test.exs
mix test test/projection/partial_lifecycle_test.exs test/projection/runtime_projection_test.exs test/projection/parity_test.exs
mix test --warnings-as-errors
mix format
mix format --check-formatted
mix compile --warnings-as-errors
git diff --check
```

Full browser/lifecycle profiling and independent read-I/O tracing remain
parent-owned verification. No frozen Presenter bytes, real Session Logs, global
configuration, Git history, or remote state are changed by this implementation.
