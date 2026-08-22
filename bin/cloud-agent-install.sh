#!/usr/bin/env bash
# Idempotent repository bootstrap for the Pixir Harness Cloud Agent environment.
#
# Runs after the source checkout. Refreshes Hex/Rebar, fetches and compiles
# dependencies, and builds the CLI escript for both the core app and the
# experimental `monitor/` sibling. Safe to run repeatedly.
set -euo pipefail

export MIX_ENV="${MIX_ENV:-dev}"

# Non-interactive Hex/Rebar; --force keeps this idempotent across reruns.
mix local.hex --force
mix local.rebar --force

# Core app: deps, compile, and the ./pixir escript.
mix deps.get
mix compile
mix escript.build

# Pixir Monitor sibling app (source-checkout-only dev surface). Guarded so the
# install still succeeds if the directory is ever absent.
if [ -f monitor/mix.exs ]; then
  (
    cd monitor
    mix deps.get
    mix compile
    mix escript.build
  )
fi

echo "cloud-agent-install: done (elixir $(elixir --version | tail -1))"
