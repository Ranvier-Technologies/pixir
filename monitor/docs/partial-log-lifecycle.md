# Partial parent Log lifecycle projection (issue 549)

Monitor reads canonical parent Events through the existing bounded Log interface.
The append-only Log remains truth: this projection does not append Events, replay
selected records differently, synthesize starts, discard contradictory lifecycle
records, increase read limits, or change the frozen Presenter contract.

## Gap boundary and validation

`Projection.PartialLifecycle.fold/2` validates a logical unit's selected lifecycle
records against `selection.tail_first_seq` when `selection.partial` is true. The
complete prefix starts with known-closed state. The tail starts with unknown
predecessor state exactly once, at that selection boundary (which can itself be
a non-lifecycle record). Sequence differences within the retained tail do not
create additional gaps.

An initial tail terminal or retry can be observed without its missing start.
After that close the state is known closed: another unmatched terminal or retry
is an error. A retained start establishes an active child, so overlap and exact
child-target mismatches within the segment still fail. Invalid start/terminal
statuses, malformed queued/retry statuses, and unsafe child identities fail.
Existing unit identity, Workflow binding conflicts, graph, and canonical sequence
validation remain in their original seams. Complete Logs retain their original
strict lifecycle folds and refusal behavior.

Source uses this validation both per Subagent and per resolved logical unit, for
list and detail. Builder uses the same module before constructing attempts. A
partial parent therefore remains in inventory when its only missing fact is an
omitted predecessor; its parent-observed `children` roster still associates child
Session ids with the parent without requiring an attempt row or child-side
parent pointer.

## Frozen contract representation

The prose contract requires a non-null ordinal for every durable attempt, even
though its JSON schema permits null. Only validated complete-prefix attempts are
emitted. Their ordinal, identity, and predecessor remain the complete-prefix
fold's proven values. An attempt still open at the gap retains its actual start
reference and timestamp, but its status becomes `unknown`, its end remains null,
and `attempt_continuity_unknown` explicitly disclaims continuity into the tail.

No tail attempt rows are emitted, including retained start/finish pairs: the
number of omitted execution epochs is unknown. Tail lifecycle records remain in
the unchanged parent input and in unit/evidence references. Units and the run
carry `attempt_lineage_unavailable` and missing-middle limitations. Generated
partial-parent lifecycle descriptions report observations, not First/Second,
resumed, or provisional attempts. Child evidence descriptions likewise do not
infer attempt attribution from the incomplete parent roster.

The served unit card labels its attempt count as retained with an unknown total
when lineage is incomplete. The unit inspector explains unavailable earlier
lineage instead of calling an empty retained list an engine-only unit with no
Subagent attempts. Complete-unit copy is unchanged. A Node VM test exercises the
actual served card and inspector renderers for both cases.

Known completed prefix pairs remain observable. Unit execution stays unknown,
completed-unit counts remain conservative lower bounds, and usage is incomplete.
Partial-parent attempts use unknown child windows and no attributed attempt usage;
unit usage is conservatively unallocated rather than charging a whole child Log
to a prefix attempt whose later reuse is unknown. Even an independently complete
child Log does not restore parent attempt lineage. This is not a claim of partial
child-detail support or completion.

Run completion still requires authoritative `workflow_finished` evidence in the
retained tail. A prefix finish cannot certify unread continuation. Post-terminal
child activity stays undetermined for partial parents, and diagnostics remain
unavailable through the existing bounded Source behavior.

## Verification and remaining scope

`test/projection/partial_lifecycle_test.exs` writes disposable raw canonical NDJSON
Logs, exercises actual bounded filesystem list/detail and `Projection.project`,
validates successful projections with the frozen Validator, and checks Log bytes
are unchanged. Regressions cover orphan terminal/retry observations, interrupted
prefix attempts, retained pairs, contiguous-tail contradictions, unsafe identities,
Workflow binding conflicts, child discovery, and complete-Log strict refusals.
The Source tests also retain authoritative-tail versus prefix-only Workflow finish
coverage; runtime/parity tests protect the complete-Log contract.

Oversized-child detail and combined byte/event selection are now integrated;
see `partial-child-evidence.md` and the Core bounded-reader release note.
Issue 549 is complete following maintainer acceptance on 2026-09-06 of unknown
omitted-event totals with exact omitted bytes. No omitted-event count is inferred
here. That acceptance does not turn partial lifecycle evidence into complete
attempt lineage, and release artifact verification remains a separate gate.
