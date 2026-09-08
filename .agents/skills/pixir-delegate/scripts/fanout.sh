#!/usr/bin/env bash
# fanout.sh — deterministic pixir delegate fan-out with rehearsal and closure.
#
# Usage:
#   fanout.sh <out_dir> "<task 1>" ["<task 2>" ...]
#
# Environment:
#   PIXIR_BIN          explicit executable override; otherwise caller ./pixir,
#                      then PATH pixir only when no local candidate exists
#   PIXIR_ROLE         subagent role (default: explorer, read-only)
#   PIXIR_MAX_THREADS  concurrency (default: task count)
#   PIXIR_TIMEOUT_MS   delegate timeout (default: 600000; must cover all
#                      waves when tasks > max_threads)
#   PIXIR_SKIP_REHEARSAL  1 to skip the dry-run gate (default: 0)
#
# Artifacts in <out_dir>: spec.json, plan.json (rehearsal), envelope.json.
# Exit codes: 0 only when Pixir exits 0 with a validated complete envelope ·
# 3 validated partial evidence (non-completed children listed with bounded
# recovery pointers) · 2 usage/rehearsal/admission/process/envelope failure.
# Closure discipline: this script reports; reconciling summaries against
# their contracts and dispositioning children remains the caller's job.

set -euo pipefail

source "$(dirname -- "${BASH_SOURCE[0]}")/resolve-binary.sh"
PIXIR_ROLE="${PIXIR_ROLE:-explorer}"
PIXIR_TIMEOUT_MS="${PIXIR_TIMEOUT_MS:-600000}"
PIXIR_SKIP_REHEARSAL="${PIXIR_SKIP_REHEARSAL:-0}"

if [[ $# -lt 2 ]]; then
  echo "usage: fanout.sh <out_dir> \"<task 1>\" [\"<task 2>\" ...]" >&2
  exit 2
fi

out_dir="$1"
shift
mkdir -p "$out_dir"

PIXIR_BIN="$(pixir_resolve_binary)" || exit 2
command -v jq >/dev/null || { echo "error: jq required" >&2; exit 2; }

pixir_report_binary

max_threads="${PIXIR_MAX_THREADS:-$#}"

jq -n --arg role "$PIXIR_ROLE" --argjson mt "$max_threads" \
  '{contract_version: 1, strategy: "subagents",
    tasks: $ARGS.positional,
    subagents: {role: $role, max_threads: $mt}}' \
  --args -- "$@" >"$out_dir/spec.json"

if [[ "$PIXIR_SKIP_REHEARSAL" != "1" ]]; then
  if ! "$PIXIR_BIN" delegate --spec "$out_dir/spec.json" --dry-run --json \
      --timeout-ms "$PIXIR_TIMEOUT_MS" >"$out_dir/plan.json" 2>&1; then
    echo "rehearsal failed — structured errors and next_actions:" >&2
    jq -r '.error // .' "$out_dir/plan.json" >&2 || cat "$out_dir/plan.json" >&2
    exit 2
  fi
  if ! jq -e . "$out_dir/plan.json" >/dev/null 2>&1; then
    echo "error: rehearsal did not return valid JSON — inspect $out_dir/plan.json" >&2
    exit 2
  fi
  if [[ "$(jq -r '.would_reject // false' "$out_dir/plan.json")" == "true" ]]; then
    echo "rehearsal would reject the real run at PIXIR_TIMEOUT_MS=$PIXIR_TIMEOUT_MS; increase it to suggested_timeout_ms=$(jq -r '.suggested_timeout_ms // "unknown"' "$out_dir/plan.json") or follow plan.json next_actions" >&2
    exit 2
  fi
  echo "rehearsal: $(jq -r '.status' "$out_dir/plan.json") ($(jq -r '.beam_coordination.planned_child_count // "?"' "$out_dir/plan.json") children)" >&2
fi

set +e
"$PIXIR_BIN" delegate --spec "$out_dir/spec.json" --json \
  --timeout-ms "$PIXIR_TIMEOUT_MS" >"$out_dir/envelope.json"
run_ec=$?
set -e

# Bash reports a signal-terminated child as 128 + signal. No envelope can turn
# that process-level failure into a successful or recoverable wrapper verdict.
if ((run_ec >= 129 && run_ec <= 192)); then
  echo "error: Pixir terminated by signal $((run_ec - 128)); no wrapper success or partial verdict is safe" >&2
  exit 2
fi

# JSON mode promises exactly one envelope object. Slurp here only to verify
# cardinality; every later jq invocation operates on that single object.
if ! jq -e -s 'length == 1 and (.[0] | type == "object")' \
    "$out_dir/envelope.json" >/dev/null 2>&1; then
  echo "error: Pixir did not return one valid JSON object (exit $run_ec) — inspect envelope.json in the requested output directory" >&2
  exit 2
fi

# Rejections and error envelopes are command failures, never partial work. Keep
# their diagnostic output fixed and bounded: the artifact holds the details.
envelope_status="$(jq -r '.status | if type == "string" then . else "" end' \
  "$out_dir/envelope.json")"
if [[ "$envelope_status" == "rejected" ]]; then
  if jq -e '.kind == "horizon_shorter_than_critical_path"' \
      "$out_dir/envelope.json" >/dev/null 2>&1; then
    echo "delegate launch rejected before child traversal (horizon_shorter_than_critical_path)" >&2
    echo "next action: increase_wait_horizon_to_suggested_timeout_ms; inspect envelope.json for bounded arithmetic and other next_actions" >&2
  else
    echo "delegate returned rejected before child traversal — inspect envelope.json in the requested output directory" >&2
  fi
  exit 2
fi
if [[ "$envelope_status" == "error" ]]; then
  echo "delegate returned error before child traversal — inspect envelope.json in the requested output directory" >&2
  exit 2
fi

# Validate the top-level object and the fact that children is an array before
# any .children[] traversal. This is deliberately a separate jq pass.
if ! jq -e '
    ((.ok | type) == "boolean") and
    ((.status | type) == "string") and
    ((.work_complete | type) == "boolean") and
    ((.children | type) == "array")
  ' "$out_dir/envelope.json" >/dev/null 2>&1; then
  echo "error: invalid envelope top-level or children shape; no child traversal was attempted" >&2
  exit 2
fi

# Compare the validated array cardinality with the generated spec before any
# child traversal. A missing/empty/extra result cannot close a requested task.
if ! jq -e '((.tasks | type) == "array") and ((.tasks | length) > 0)' \
    "$out_dir/spec.json" >/dev/null 2>&1; then
  echo "error: generated spec has no valid task array; refusing envelope traversal" >&2
  exit 2
fi
spec_task_count="$(jq '.tasks | length' "$out_dir/spec.json")"
envelope_child_count="$(jq '.children | length' "$out_dir/envelope.json")"
partial_spawn_case=false
if ((envelope_child_count != spec_task_count)); then
  if jq -e --argjson spec_tasks "$spec_task_count" \
      --argjson actual_children "$envelope_child_count" '
      def nonnegative_integer:
        (type == "number") and (. >= 0) and ((floor) == .);
      .ok == false and
      .status == "partial" and
      .work_complete == false and
      ((.spawn_failure | type) == "object") and
      ((.beam_coordination | type) == "object") and
      (.beam_coordination.planned_child_count | nonnegative_integer) and
      (.beam_coordination.spawned_child_count | nonnegative_integer) and
      .beam_coordination.planned_child_count == $spec_tasks and
      .beam_coordination.spawned_child_count == $actual_children and
      .beam_coordination.planned_child_count > .beam_coordination.spawned_child_count
    ' "$out_dir/envelope.json" >/dev/null 2>&1; then
    partial_spawn_case=true
  else
    echo "error: envelope child count does not match spec task count; refusing contradictory fan-out evidence" >&2
    exit 2
  fi
fi

# Child fields used below must be bounded and safe to render. Other envelope
# evidence remains in envelope.json and is never echoed to diagnose a shape
# error.
if ! jq -e '
    all(.children[];
      (type == "object") and
      ((.status | type) == "string") and
      (.status | IN("completed", "failed", "timed_out", "cancelled", "detached", "closed", "queued", "running", "partial", "incomplete")) and
      (.child_session_id == null or
        (((.child_session_id | type) == "string") and
         (.child_session_id | test("\\A[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}\\z")))) and
      (.reason_code == null or
        (((.reason_code | type) == "string") and
         (.reason_code | test("\\A[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}\\z")))) and
      (.index == null or
        (((.index | type) == "number") and .index >= 0 and (.index | floor) == .index)) and
      (.retry_attempts == null or
        (((.retry_attempts | type) == "number") and .retry_attempts >= 0 and
         (.retry_attempts | floor) == .retry_attempts)) and
      (.child_log_path == null or
        (((.child_log_path | type) == "string") and (.child_log_path | length) <= 4096)) and
      (.resume_command == null or
        (((.resume_command | type) == "string") and (.resume_command | length) <= 4096)) and
      (.diagnose_command == null or
        (((.diagnose_command | type) == "string") and (.diagnose_command | length) <= 4096))
    )
  ' "$out_dir/envelope.json" >/dev/null 2>&1; then
  echo "error: invalid envelope child shape; unsafe child payload was not rendered" >&2
  exit 2
fi

verdict="$(jq -r '
  if .ok == true and .status == "completed" and .work_complete == true then
    "complete"
  elif .ok == false and
       (.status | IN("partial", "timed_out", "failed", "cancelled")) and
       .work_complete == false then
    "partial"
  else
    "contradictory"
  end
' "$out_dir/envelope.json")"

if [[ "$verdict" == "contradictory" ]]; then
  echo "error: contradictory ok/status/work_complete envelope; refusing to infer success or partial work" >&2
  exit 2
fi

if [[ "$verdict" == "complete" && "$run_ec" -ne 0 ]]; then
  echo "error: Pixir exit $run_ec contradicts a complete envelope; refusing forged success" >&2
  exit 2
fi

if [[ "$verdict" == "partial" && "$run_ec" -ne 6 ]]; then
  echo "error: Pixir exit $run_ec contradicts a partial envelope; expected exit 6" >&2
  exit 2
fi

if [[ "$verdict" == "complete" ]] &&
    ! jq -e 'all(.children[]; .status == "completed")' \
      "$out_dir/envelope.json" >/dev/null 2>&1; then
  echo "error: complete envelope contains a non-completed child; refusing contradictory fan-out evidence" >&2
  exit 2
fi

if [[ "$verdict" == "partial" && "$partial_spawn_case" != "true" ]] &&
    ! jq -e 'any(.children[]; .status != "completed")' \
      "$out_dir/envelope.json" >/dev/null 2>&1; then
  echo "error: partial envelope has no non-completed child; refusing contradictory fan-out evidence" >&2
  exit 2
fi

# Keep terminal output bounded even for a very wide caller-supplied fan-out.
display_limit=50
jq -r --argjson limit "$display_limit" '
  .children[:$limit][]
  | "\(.status)\t\(.child_session_id // "-")\t\(.reason_code // "-")\tretries:\(.retry_attempts // 0)"
' "$out_dir/envelope.json"
child_count="$(jq '.children | length' "$out_dir/envelope.json")"
if ((child_count > display_limit)); then
  echo "... $((child_count - display_limit)) additional children retained in envelope.json" >&2
fi

if [[ "$verdict" == "complete" ]]; then
  exit 0
fi

# A valid incomplete envelope is honest partial evidence only alongside Pixir's
# exact terminal-incomplete process exit 6.
# Point to each bounded recovery entry without printing arbitrary command/path
# strings from the envelope.
echo "partial: disposition each non-completed child (do NOT re-run the spec):" >&2
jq -r --argjson limit "$display_limit" '
  .children
  | to_entries
  | map(select(.value.status != "completed"))
  | .[:$limit][]
  | "  child[\(.value.index // .key)] status=\(.value.status) session=\(.value.child_session_id // "unavailable") runtime_retries=\(.value.retry_attempts // 0)\n    recovery: inspect this child entry in envelope.json; use resume_command when present, then diagnose_command and child_log_path"
' "$out_dir/envelope.json" >&2
remaining_count="$(jq '[.children[] | select(.status != "completed")] | length' \
  "$out_dir/envelope.json")"
if ((remaining_count > display_limit)); then
  echo "  ... $((remaining_count - display_limit)) additional recovery entries retained in envelope.json" >&2
fi
exit 3
