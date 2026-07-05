#!/usr/bin/env bash
# fanout.sh — deterministic pixir delegate fan-out with rehearsal and closure.
#
# Usage:
#   fanout.sh <out_dir> "<task 1>" ["<task 2>" ...]
#
# Environment:
#   PIXIR_BIN          pixir binary (default: pixir on PATH — prefer an
#                      explicit local build; versions can differ silently)
#   PIXIR_ROLE         subagent role (default: explorer, read-only)
#   PIXIR_MAX_THREADS  concurrency (default: task count)
#   PIXIR_TIMEOUT_MS   delegate timeout (default: 600000; must cover all
#                      waves when tasks > max_threads)
#   PIXIR_SKIP_REHEARSAL  1 to skip the dry-run gate (default: 0)
#
# Artifacts in <out_dir>: spec.json, plan.json (rehearsal), envelope.json.
# Exit codes: 0 all children completed · 3 partial (non-completed children
# listed on stderr with their resume targets) · 2 usage/rehearsal failure.
# Closure discipline: this script reports; reconciling summaries against
# their contracts and dispositioning children remains the caller's job.

set -euo pipefail

PIXIR_BIN="${PIXIR_BIN:-pixir}"
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

command -v "$PIXIR_BIN" >/dev/null || { echo "error: '$PIXIR_BIN' not found" >&2; exit 2; }
command -v jq >/dev/null || { echo "error: jq required" >&2; exit 2; }

echo "driving: $(command -v "$PIXIR_BIN") · v$("$PIXIR_BIN" --version)" >&2

max_threads="${PIXIR_MAX_THREADS:-$#}"

jq -n --arg role "$PIXIR_ROLE" --argjson mt "$max_threads" \
  '{contract_version: 1, strategy: "subagents",
    tasks: $ARGS.positional,
    subagents: {role: $role, max_threads: $mt}}' \
  --args -- "$@" >"$out_dir/spec.json"

if [[ "$PIXIR_SKIP_REHEARSAL" != "1" ]]; then
  if ! "$PIXIR_BIN" delegate --spec "$out_dir/spec.json" --dry-run --json \
      >"$out_dir/plan.json" 2>&1; then
    echo "rehearsal failed — structured errors and next_actions:" >&2
    jq -r '.error // .' "$out_dir/plan.json" >&2 || cat "$out_dir/plan.json" >&2
    exit 2
  fi
  echo "rehearsal: $(jq -r '.status' "$out_dir/plan.json") ($(jq -r '.beam_coordination.planned_child_count // "?"' "$out_dir/plan.json") children)" >&2
fi

set +e
"$PIXIR_BIN" delegate --spec "$out_dir/spec.json" --json \
  --timeout-ms "$PIXIR_TIMEOUT_MS" >"$out_dir/envelope.json"
run_ec=$?
set -e

if ! jq -e . "$out_dir/envelope.json" >/dev/null 2>&1; then
  echo "error: envelope did not parse as JSON (exit $run_ec) — treat run as failed" >&2
  exit 2
fi

jq -r '.children[] | "\(.status)\t\(.child_session_id)\t\(.reason_code // "-")"' \
  "$out_dir/envelope.json"

if [[ "$(jq -r '.work_complete' "$out_dir/envelope.json")" == "true" ]]; then
  exit 0
fi

echo "partial: disposition each non-completed child (do NOT re-run the spec):" >&2
jq -r '.children[] | select(.status != "completed")
  | "  \(.status) \(.child_session_id) → steer.sh \(.child_session_id) \"...\"  (log: \(.child_log_path))"' \
  "$out_dir/envelope.json" >&2
exit 3
