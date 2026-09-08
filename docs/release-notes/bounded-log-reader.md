# Bounded Log reader ownership (source checkout)

This source-only architecture slice places bounded Log selection in
`Pixir.Log.fold_bounded/2`. Monitor consumes that public Session-id/Workspace
interface and formats its selection metadata; it no longer owns an NDJSON
reader or a canonical Event decoder. The normal Log folds and bounded selection
share the private canonical type/envelope decoder. Core does not depend on Monitor.

## Read contract

- `Log.fold_bounded(session_id, workspace: workspace)` returns
  `{:ok, %{history: events, selection: metadata}}` or a structured Log error.
- The default `:max_log_bytes` remains 8 MiB. Optional `:max_events` is a
  nonnegative integer; leaving it absent preserves Core's byte-only behavior.
  Monitor explicitly supplies its existing default of 20,000 events for parent
  and lazily discovered child Logs. Neither cap is raised.
- Exceeding either bound selects complete prefix and tail records from at most
  two positional reads, with no middle scan, full-read fallback, index, cache,
  or Log rewrite. Event-cap selection can therefore be partial even when the
  entire file fits the byte budget. Odd event quotas favor the tail; capacity
  unused by either physical window is reassigned to the other.
- Event selection counts raw nonempty NDJSON records conservatively, then decodes
  only selected records through the shared canonical decoder. Retained event
  counts are the actual decoded History length. Original byte spans, including
  whitespace, blank lines, CRLF, UTF-8, and complete EOF records, determine the
  non-overlapping cuts; Events are never reencoded to estimate omitted bytes.
- `bytes_read` counts physical positional I/O; `bytes_omitted` counts bytes not
  selected as History. An event-capped file can be physically read in full while
  its selected History still omits a middle. Neither metric implies that omitted
  records were validated.
- Caps of zero or one allow complete under-limit Histories; a two-ended sample
  that cannot fit fails with structured `:log_event_limit`. Invalid event-cap
  types and negative caps also fail structurally. Monitor maps this kind to its
  existing `run_event_limit`, not a byte-limit remedy. Its post-read event guard
  remains defense in depth rather than dropping valid default-cap samples.
- Session ids and every Pixir-owned path component below the trusted Workspace
  are checked by `SessionId` and `Paths.inspect_state_path`. Existing and dangling
  symlinks are rejected. This remains a preflight, not same-UID race protection.
- Selected records must have nonnegative integer seqs, the requested Session
  identity, and map data. Full selections retain normal seq ordering; partial
  selections must already be ordered. Duplicate selected seqs fail explicitly.
- Complete JSON at the observed EOF does not require LF. Unfinished append bytes
  are reported separately and never repaired. Malformed retained records fail;
  omitted middle bytes are not decoded or certified valid.
- `selection` retains exact observed bytes, bytes read, retained event count,
  omitted bytes, and unfinished trailing bytes. Omitted event counts are
  **unknown**, not inferred from seq gaps.
- A missing Log is `:log_not_found`, explicitly adapted to Monitor's existing
  `run_not_found` behavior. An existing empty Log is distinct. Ordinary `Log.fold`
  and `Log.fold_append_order` still treat a missing Log as empty History.

## Partiality and legitimate refusals

The final issue 549 contract explicitly accepts **unknown omitted-event counts**
(maintainer acceptance on 2026-09-06): unread or unparsed middle bytes could contain
corrupt records, and seq endpoint differences are not exact event totals.
Exact omitted bytes and retained event counts remain available. Users continue to see the
existing unknown-total and lower-bound limitations. Partial selections always
carry `tail_first_seq`, including event-only partiality, so the existing gap-aware
parent lifecycle and per-child evidence rules retain their boundary.

Bounded selection is not universal projectability. Legitimate unprojectable
classes include a single oversized record (or no complete record in either byte
window), no retained run identity, retained corruption or invalid selected
Session/sequence, and an event cap too small for a two-ended sample. Existing
strict lifecycle and identity validation can also refuse retained contradictions.
No fallback may hydrate a full parent or child Log to conceal these limits.

## Deliberately unchanged

This is bounded selection, not a universal Presenter projection API. Issue 549
is complete under the accepted unknown-count contract; publication and verification
of a release artifact remain separate gates. Monitor's existing partial-count
limitations, gap-aware lifecycle rules, child evidence rules, and projection
semantics remain in place. Partial reads still omit diagnostics that would
hydrate the full Log. Ordinary Core folds and append-order replay are unchanged.
The frozen Presenter assets are untouched. No packaged release or rebuilt binary
freshness is implied by these source changes.

Reader tests live in `test/pixir/log_bounded_test.exs`; normal replay tests remain
in `test/pixir/log_test.exs`. Monitor retains limitations/error formatting tests
and its existing source/list/detail contract suite. Focused core verification:

```sh
mix test test/pixir/log_test.exs test/pixir/log_bounded_test.exs
```
