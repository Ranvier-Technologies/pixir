#!/usr/bin/env bash
# Two concurrent Pixir Monitor test suites on one host (#555).
#
# Two-terminal procedure (same checkout):
#   1. cd monitor && mix deps.get && mix escript.build
#   2. Terminal A:
#        MIX_BUILD_PATH=/tmp/pixir-monitor-build-a mix test
#   3. Terminal B (start immediately):
#        MIX_BUILD_PATH=/tmp/pixir-monitor-build-b mix test
#   4. Both must exit 0. Repeat for three consecutive trials.
#
# Each `mix test` installs PIXIR_MONITOR_TEST_RUN (pid + random) so browser
# profile globs, escript tmp roots, and workspace-set fixture dirs cannot
# see or delete each other. MIX_BUILD_PATH keeps compile artifacts apart;
# do not change CI runner topology — CI remains one suite per job.
#
# This script runs the same pair in one process. Pass --isolation-only to
# exercise the planted-foreign-dir + grep pin without the full browser suite.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TRIALS="${TRIALS:-1}"
ISOLATION_ONLY=0
if [[ "${1:-}" == "--isolation-only" ]]; then
  ISOLATION_ONLY=1
  shift
fi

cd "$ROOT"

mix deps.get
mix escript.build

run_one() {
  local label="$1"
  local build="$2"
  local log="$3"
  if [[ "$ISOLATION_ONLY" -eq 1 ]]; then
    MIX_BUILD_PATH="$build" mix test test/test_run_isolation_test.exs --trace >"$log" 2>&1
  else
    MIX_BUILD_PATH="$build" mix test >"$log" 2>&1
  fi
}

trial=1
while [[ "$trial" -le "$TRIALS" ]]; do
  stamp="$(date +%s)-$$-$trial"
  build_a="/tmp/pixir-monitor-build-a-$stamp"
  build_b="/tmp/pixir-monitor-build-b-$stamp"
  log_a="/tmp/pixir-monitor-suite-a-$stamp.log"
  log_b="/tmp/pixir-monitor-suite-b-$stamp.log"

  run_one a "$build_a" "$log_a" &
  pid_a=$!
  run_one b "$build_b" "$log_b" &
  pid_b=$!

  status_a=0
  status_b=0
  wait "$pid_a" || status_a=$?
  wait "$pid_b" || status_b=$?

  echo "trial $trial: suite_a=$status_a suite_b=$status_b"
  echo "  A log: $log_a"
  echo "  B log: $log_b"

  if [[ "$status_a" -ne 0 || "$status_b" -ne 0 ]]; then
    echo "concurrent suites failed on trial $trial" >&2
    tail -n 40 "$log_a" >&2 || true
    tail -n 40 "$log_b" >&2 || true
    exit 1
  fi

  trial=$((trial + 1))
done
