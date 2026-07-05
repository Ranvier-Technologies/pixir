# Changelog

All notable changes to Pixir are recorded here. Pixir is a developer preview;
the CLI/ACP runtime is the public surface, and there is no stable Elixir library
API yet. Versions follow [Semantic Versioning](https://semver.org/) with the
caveat that pre-1.0 minor versions may still change behavior.

## [0.1.5]

### Fixed
- Clean CLI exits now release Session writer leases across one-shot, `resume`,
  and attached delegate (parent and children); stale leases from crashed runs
  remain fail-closed behind `--force-release-writer-lease`. Headless
  orchestrators no longer need the force flag on the happy path.
- `Subagents.Manager` survives late timeouts or cancels racing an
  already-terminated child Session; the recorded timeout/cancel evidence is the
  honest record either way.

### Added
- `pixir-delegate` skill family for orchestrating agents
  (`.agents/skills/pixir-delegate*`): a host-neutral delegation judgment core,
  real blind-run demonstrations, deterministic `fanout.sh`/`steer.sh` scripts,
  and variants for Claude Code, Codex root agents, and Pixir-native
  orchestration. Discoverable by Claude Code via `.claude/skills/`.
- Site route `/scale` with measured scale evidence (up to 64 concurrent
  workers) and bounded public claims.
- Delegate CLI contract documentation for expensive orchestrators
  (`docs/examples/delegate-cli-live/README.md`): a per-subcommand exit-code table,
  the read/scope vs write-policy denial distinction (`outside_workspace` vs
  `write_policy_denied`), and honest caveats for `next_actions` and
  `observed_applied_writes`.
- `SECURITY.md` with private vulnerability reporting and a clear
  tripwire-not-a-sandbox disclaimer, and `CONTRIBUTING.md` describing the real
  workflow and invariants.
- Partial-write observability: bounded-write delegate envelopes now report
  `observed_applied_writes` from child Session Logs as an at-least lower bound,
  without changing existing `writes_applied_to` / `contract_status` fields.

### Changed
- Elixir requirement moved to `~> 1.20`; CI runs on Elixir 1.20.2 / OTP 29.
- Delegate error locations now carry machine-readable metadata (`json_pointer`,
  `path`, `step_index`) alongside the human-facing 1-based field label.

### Fixed
- `mix check` no longer hangs after the test phase. The test step nested a BEAM
  node under `cmd env MIX_ENV=test mix ...` that did not exit cleanly on teardown;
  it now shells out with `MIX_ENV` as an environment variable and returns cleanly.
- Bash tool workspace confinement now rejects path escapes beyond `..` — absolute
  out-of-workspace paths, `$HOME`/`~`, and symlink prefixes resolving outside the
  workspace — before crossing the host boundary, surfaced honestly as
  `outside_workspace` rather than a write-policy denial.

## [0.1.4] and earlier

See the release notes at
`docs/release-notes/open-beta-developer-preview.md` for the 0.1.0–0.1.4 developer
preview history (runtime truth and fanout honesty, ACP Registry readiness, and
runtime diagnostics).
