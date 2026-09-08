#!/usr/bin/env bash
# steer.sh — resume a session (or a delegate child) with one follow-up task.
#
# Usage:
#   steer.sh <session_id> "<next task>" [out.json]
#
# Environment:
#   PIXIR_BIN      explicit executable override; otherwise caller ./pixir,
#                  then PATH pixir only when no local candidate exists
#   PIXIR_POSTURE  permission flag matching the session's original posture
#                  (default: --read-only, correct for explorer children;
#                  set empty for write-capable sessions)
#
# Prints the model's answer (envelope .output) on stdout; full envelope goes
# to out.json when given. Never passes --force-release-writer-lease: a stale
# lease failing closed is evidence — inspect with `pixir diagnose session`
# before deciding to force anything.

set -euo pipefail

source "$(dirname -- "${BASH_SOURCE[0]}")/resolve-binary.sh"
PIXIR_POSTURE="${PIXIR_POSTURE---read-only}"

if [[ $# -lt 2 ]]; then
  echo "usage: steer.sh <session_id> \"<next task>\" [out.json]" >&2
  exit 2
fi

sid="$1"
task="$2"
out="${3:-}"

PIXIR_BIN="$(pixir_resolve_binary)" || exit 2
command -v jq >/dev/null || { echo "error: jq required" >&2; exit 2; }

pixir_report_binary

set +e
if [[ -n "$PIXIR_POSTURE" ]]; then
  envelope="$("$PIXIR_BIN" --json $PIXIR_POSTURE resume "$sid" "$task")"
else
  envelope="$("$PIXIR_BIN" --json resume "$sid" "$task")"
fi
ec=$?
set -e

[[ -n "$out" ]] && printf '%s\n' "$envelope" >"$out"

if [[ $ec -ne 0 ]]; then
  echo "resume failed (exit $ec) — envelope error and next_actions:" >&2
  printf '%s\n' "$envelope" | jq -r '.error // .' >&2 || printf '%s\n' "$envelope" >&2
  exit "$ec"
fi

printf '%s\n' "$envelope" | jq -r '.output'
