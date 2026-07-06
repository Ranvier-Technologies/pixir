# Changelog

All notable changes to Pixir are recorded here. Issue and PR references
(`#N`) point to the private development repository; this public mirror
carries curated history, so those references may not resolve here. Pixir is a developer preview;
the CLI/ACP runtime is the public surface, and there is no stable Elixir library
API yet. Versions follow [Semantic Versioning](https://semver.org/) with the
caveat that pre-1.0 minor versions may still change behavior.

## [Unreleased]

### Changed
- A `bash` call denied because the bounded write policy disables the shell now
  surfaces as `kind: "bash_disabled"` ("shell is disabled by the bounded write
  policy") instead of the misleading `write_policy_denied` ("write denied"),
  with shell-free `next_actions` (`use_native_read_tools`,
  `use_edit_or_write_within_allowed_globs`). The denial keeps exit code 3 but
  is no longer terminal for the child's Turn: the model can adapt with native
  tools instead of dying on a read-only command. Write-allowlist denials keep
  `write_policy_denied` and remain terminal (#218).

### Added
- Delegate spec transport knob: `subagents.transport` (or top-level
  `transport`) accepts `auto` | `websocket` | `http_sse`; invalid values fail
  `--dry-run` with a structured error and the effective value is surfaced as
  `limits.transport` (#205).
- Manager-level bounded auto-retry for read-only subagent children killed by
  mid-stream websocket drops or provider-declared-retryable server errors,
  with jittered re-queueing, an observable `retrying` lifecycle event, and a
  retry confession on delegate envelopes (`children[].retry_attempts`,
  `retry_max_attempts`, `current_attempt_index`, `retry_history`; present only
  when a retry happened) (#205).
- `usage_summary.model` is now populated on provider usage events, and
  subagent session ids are aliased in `pixir tree` projections (#216).
- Isolated subagent workspace snapshots accept extra exclusion directory names
  (directory basenames, byte-exact, matched at any depth) via
  `config :pixir, :subagents, snapshot_excluded_dir_names: [...]` or the
  `:excluded_dir_names` snapshot option; built-in defaults (`.git`, `.pixir`,
  `_build`, ...) always stay in effect, invalid names and a non-keyword
  `:subagents` application env fail closed with structured errors, and the
  effective list is confessed as `excluded_dir_names` in snapshot metadata and
  runtime failure envelopes (never on validation failures, where no effective
  policy ran) (#221).

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
