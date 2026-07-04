#!/usr/bin/env bash
# T3 → Pixir dogfood verification for #16 WebSocket previous_response_id continuity.
# Usage:
#   ./bin/verify-t3-websocket-continuation.sh preflight
#   ./bin/verify-t3-websocket-continuation.sh analyze <session-id> [workspace]

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

usage() {
  cat <<'EOF'
verify-t3-websocket-continuation.sh — #16 dogfood helper

Commands:
  preflight                 Rebuild ./pixir and print the manual T3 checklist
  analyze <session-id>      Summarize provider_usage continuation + prompt-cache evidence

Environment:
  PIXIR_HOME                Optional (~/.pixir by default)
  PIXIR_MODEL               Default gpt-5.5 for dogfood prompts

Example:
  ./bin/verify-t3-websocket-continuation.sh preflight
  # after two T3 turns in the same thread:
  ./bin/verify-t3-websocket-continuation.sh analyze 20260619T120000-abc123 /path/to/workspace
EOF
}

preflight() {
  echo "== Pixir preflight =="
  mix escript.build
  ./pixir --version
  ./pixir doctor --json | head -c 400
  echo ""
  echo ""
  cat <<'EOF'
== T3 dogfood checklist (#16) ==

1. Rebuild grokwtree binaryPath in T3 PixirDriver config (this repo: mix escript.build → ./pixir).
2. Start T3 dev against the dogfood workspace (same long-lived Pixir ACP process per thread).
3. Pick model gpt-5.5 on the Pixir provider rail.
4. Send turn A with a stable >1k-token prefix (repeat a paragraph or open a large file context).
5. Without restarting Pixir/T3, send turn B in the SAME thread (short follow-up is fine).
6. Note the Pixir session id from T3 logs or .pixir/sessions/<id>.ndjson in the workspace.

Pass criteria (turn B provider_usage):
  - active_transport: "websocket"
  - continuation_attempted: true
  - used_previous_response_id: true
  - continuation_reset_reason: null (or not "no_previous_response")
  - websocket_stored_previous_response_id: present (resp_*)
  - websocket_key matches the session id string

Interpretation:
  - cached_tokens > 0  → prompt-cache hit on full-prefix replay
  - used_previous_response_id: true → WebSocket delta continuation (may lower input_tokens vs turn A)

Analyze after the run:
  ./bin/verify-t3-websocket-continuation.sh analyze <session-id> [workspace]
EOF
}

find_log() {
  local sid="$1"
  local ws="${2:-$ROOT}"

  if [[ -f "$ws/.pixir/sessions/${sid}.ndjson" ]]; then
    echo "$ws/.pixir/sessions/${sid}.ndjson"
    return 0
  fi

  if [[ -f "$ROOT/.pixir/sessions/${sid}.ndjson" ]]; then
    echo "$ROOT/.pixir/sessions/${sid}.ndjson"
    return 0
  fi

  echo "Log not found for session ${sid} under ${ws}/.pixir/sessions or repo .pixir" >&2
  return 1
}

analyze() {
  local sid="$1"
  local ws="${2:-$ROOT}"
  local log
  log="$(find_log "$sid" "$ws")"

  if ! command -v jq >/dev/null 2>&1; then
    echo "jq is required for analyze" >&2
    exit 1
  fi

  echo "== provider_usage continuation evidence =="
  echo "log: $log"
  echo ""

  jq -r '
    [inputs | select(.type == "provider_usage")]
    | to_entries[]
    | . as $row
    | "call \($row.key + 1): " +
      "transport=\(.value.data.active_transport // "?") " +
      "attempted=\(.value.data.continuation_attempted // false) " +
      "used_prev=\(.value.data.used_previous_response_id // false) " +
      "reset=\(.value.data.continuation_reset_reason // "null") " +
      "stored=\(.value.data.websocket_stored_previous_response_id // "null") " +
      "captured=\(.value.data.websocket_captured_response_id // "null") " +
      "cached=\(.value.data.usage_summary.cached_tokens // 0) " +
      "input=\(.value.data.usage_summary.input_tokens // 0)"
  ' "$log"

  echo ""
  echo "== prompt cache evidence =="
  jq -r '
    [inputs | select(.type == "provider_usage")]
    | if length == 0 then
        "CACHE: no provider_usage rows"
      elif length < 2 then
        "CACHE: turn 2 — n/a (only one provider call)"
      else
        (.[1].data.usage_summary.cached_tokens // 0) as $turn2_cached |
        if $turn2_cached > 0 then
          "CACHE: turn 2 — HIT (cached=\($turn2_cached))"
        else
          "CACHE: turn 2 — no hit (cached=0; later turns may still hit)"
        end
      end
  ' "$log"
  jq -r '
    [inputs | select(.type == "provider_usage")]
    | to_entries
    | map({
        turn: (.key + 1),
        cached: (.value.data.usage_summary.cached_tokens // 0),
        input: (.value.data.usage_summary.input_tokens // 0)
      })
    | if length == 0 then empty
      else
        . as $rows |
        ($rows | map(select(.cached > 0))) as $hits |
        if ($hits | length) == 0 then
          "CACHE: no prompt-cache hits in \($rows | length) provider call(s) (all cached=0)"
        elif ($hits | length) == 1 then
          "CACHE: first hit on turn \($hits[0].turn) (cached=\($hits[0].cached), input=\($hits[0].input))"
        else
          ($hits | map("turn \(.turn) cached=\(.cached)") | join(", ")) as $detail |
          "CACHE: first hit on turn \($hits[0].turn); \($hits | length) hit(s) total (\($detail))"
        end
      end
  ' "$log"
  echo ""

  local turn2_ok
  turn2_ok="$(jq -r '
    [inputs | select(.type == "provider_usage")] | if length < 2 then "false" else
      .[1].data.used_previous_response_id == true and
      .[1].data.continuation_attempted == true and
      (.[1].data.continuation_reset_reason == null or .[1].data.continuation_reset_reason == "")
    end
  ' "$log")"

  if [[ "$turn2_ok" == "true" ]]; then
    echo "RESULT: PASS — turn 2 shows WebSocket continuation"
    exit 0
  fi

  echo "RESULT: FAIL or INCOMPLETE — need ≥2 provider_usage rows with turn-2 continuation true"
  exit 1
}

cmd="${1:-}"
case "$cmd" in
  preflight) preflight ;;
  analyze)
    [[ $# -ge 2 ]] || { usage; exit 1; }
    analyze "$2" "${3:-$ROOT}"
    ;;
  -h | --help | help) usage ;;
  *)
    usage
    exit 1
    ;;
esac