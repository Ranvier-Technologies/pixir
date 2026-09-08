#!/usr/bin/env bash
# Shared binary resolution for fanout, steer, and explicit skill preflight.
# Source this file, then: PIXIR_BIN="$(pixir_resolve_binary)" || exit 2
# Resolves against the caller's CWD; never changes CWD, PATH, or build state.

pixir_resolve_binary() {
  local candidate origin

  if [[ -n "${PIXIR_BIN:-}" ]]; then
    candidate="$PIXIR_BIN"
    origin="PIXIR_BIN"
    # An explicit command name is allowed, but must name a PATH executable,
    # not a shell function, alias, or builtin. Slash-containing values are paths.
    if [[ "$candidate" != */* ]]; then
      candidate="$(type -P -- "$candidate")" || {
        echo "error: PIXIR_BIN does not name an executable file" >&2
        return 2
      }
    fi
  elif [[ -e ./pixir || -L ./pixir ]]; then
    # A directory, nonexecutable file, or broken symlink is still a local
    # candidate: do not hide a broken checkout behind an older PATH install.
    candidate="$PWD/pixir"
    origin="local pixir"
  else
    origin="PATH pixir"
    candidate="$(type -P pixir)" || {
      echo "error: pixir not found in caller workspace or PATH" >&2
      return 2
    }
  fi

  if [[ "$candidate" != /* ]]; then
    candidate="$PWD/$candidate"
  fi

  if [[ ! -f "$candidate" || ! -x "$candidate" ]]; then
    echo "error: $origin is not an executable file: $candidate" >&2
    return 2
  fi

  printf '%s\n' "$candidate"
}

pixir_report_binary() {
  printf 'driving: %s · v%s\n' "$PIXIR_BIN" "$("$PIXIR_BIN" --version)" >&2
}
