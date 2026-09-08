# Offline release verification

`bin/verify --release` is an explicit **offline-only acceptance profile for selected
source-checkout applications**, not a publication approval or a live-model readiness
claim. It adds gates to the existing full profile without changing the full/quick
command lists. `--release --quick` is rejected before commands or evidence writes.

## Run the profile

Prepare dependencies and toolchains separately before going offline. The verifier
never installs dependencies or invokes a Provider smoke task. Real local browser and
loopback HTTP tests are part of offline verification, not external service probes.

```sh
# Inspect the complete plan without creating evidence or running checks.
uv run python bin/verify --release --dry-run --json

# All applications present in this checkout; use an installed browser's real path.
PIXIR_MONITOR_BROWSER_BIN=/absolute/path/to/chrome uv run python bin/verify --release --json

# Explicitly selected applications, not an all-surface acceptance claim.
PIXIR_MONITOR_BROWSER_BIN=/absolute/path/to/chrome uv run python bin/verify --release --scope core --scope monitor --json
uv run python bin/verify --release --scope site --json

# An explicit operator timeout always wins, even if too short for lifecycle tests.
PIXIR_MONITOR_BROWSER_BIN=/absolute/path/to/chrome uv run python bin/verify --release --timeout 2400 --show-failures --json

# Verification-tooling regression suite (fake executables, no live application run).
uv run python -m unittest discover -s test -p verify_cli_test.py
```

The command-scoped browser assignment above does not change the calling shell's
persistent environment. On macOS an installed Chrome executable may be
`/Applications/Google Chrome.app/Contents/MacOS/Google Chrome`; quote paths containing
spaces. Use an existing supported executable; the verifier does not discover,
download, or install a browser. Monitor requires Node.js >= 22 with global
`WebSocket`. The release plan starts Monitor checks with an offline Node prerequisite
command that rejects a missing/inaccessible/non-file browser executable and an
unsupported Node runtime. Its exact JavaScript is included in `plan[].command`.
The real browser suites must still prove browser launch and CDP operation.

Frontend release scopes first execute `node --version` and `pnpm --version` and
require Node **24.x** and pnpm **11.5.0**, matching frontend CI. A mismatch records
`frontend_toolchain_mismatch` and skips that application's checks/build; it does not
install or switch toolchains. The required versions are visible in the dry-run plan,
and executed version checks record the observed versions. Monitor's independent
Node >=22 contract is unchanged. Full/quick profiles do not add these release gates.

For a container requiring sandbox exceptions, explicitly supply
`PIXIR_MONITOR_BROWSER_EXTRA_ARGS="--no-sandbox --disable-dev-shm-usage"` on the command.
The verifier forwards this opt-in; it never enables these flags automatically.

## Exact check commands and child environments

Commands run in scope order; repeated scopes are deduplicated. Within each scope,
commands run in the following order. Every child receives `NO_COLOR=1`.

| Scope / working directory | Release commands, in order | Additional child environment |
| --- | --- | --- |
| `core` / repository root | `mix format --check-formatted`; `mix compile --warnings-as-errors`; `mix test --warnings-as-errors`; `mix escript.build`; `./pixir doctor --json`; `mix docs --warnings-as-errors`; `uv run python -m unittest discover -s test -p verify_cli_test.py` | Mix commands: `HEX_OFFLINE=1`, `MIX_ENV=dev` except tests use `MIX_ENV=test`; tooling tests: `UV_OFFLINE=1` |
| `monitor` / `monitor/` | `node -e <prerequisite script in JSON plan>`; `mix format --check-formatted`; `mix compile --warnings-as-errors`; `mix test --warnings-as-errors`; `mix escript.build`; `./pixir-monitor self-check --json` | Mix commands: `HEX_OFFLINE=1`, `MIX_ENV=dev` except tests use `MIX_ENV=test`; prerequisite and test commands: `CI=true`, `PIXIR_MONITOR_LIFECYCLE=1`, required `PIXIR_MONITOR_BROWSER_BIN`, optional `PIXIR_MONITOR_BROWSER_EXTRA_ARGS` |
| `site` / `site/` | `node --version`; `pnpm --config.verifyDepsBeforeRun=error --version`; `pnpm --config.verifyDepsBeforeRun=error check`; `pnpm --config.verifyDepsBeforeRun=error build` | No additional overrides |

The site has an Astro check and build, not a separate test script. No `--stale`
selection is used in release mode. Monitor's lifecycle opt-in accompanies its entire
test suite, not a replacement subset. `CI=true` requests the Monitor tests' CI-like
fail-loud behavior; the explicit preflight also prevents silently proceeding without
the Node/browser prerequisites. When selecting Monitor alone, prepare the sibling
core dependency and fixture `./pixir` escript first, as for the standalone Monitor
suite. Selecting Monitor does not silently execute core acceptance checks.

`plan[].env` and each executed/check row expose the command-specific environment
overrides. `required_env` names the required browser variable even when missing in a
dry-run; configured browser path/extra arguments are included when provided. The
rest of the caller's environment is inherited but is not dumped into evidence.
Overrides use a fresh environment dictionary for each subprocess, never a global
`os.environ` mutation. Full and quick modes retain their existing inherited Mix
environment and do not force Monitor lifecycle or CI gates.

Frontend commands retain pnpm's `verifyDepsBeforeRun=error` safety: stale dependencies
fail instead of being auto-installed. Mix dependencies and frontend dependencies must
already exist locally; release Mix commands use Hex offline mode and the tooling
suite uses uv offline mode. This profile is a fixed offline command selection, not
an OS-level network sandbox for arbitrary modified project scripts.

## Timeouts, failures, and evidence

- Release defaults to **1,800 seconds per command**, leaving room for Monitor's
  up-to-660-second lifecycle test plus the normal suite. This is a bounded budget,
  not a promise about every machine's runtime. Full/quick retain 600 seconds.
- `--timeout N` replaces that budget exactly. `timeout_seconds` records the effective
  value in both plans and manifests; an insufficient explicit value produces a
  `timed_out` failure rather than being silently raised. Nonpositive/nonfinite values
  are rejected.
- Timeout cleanup retains the existing process-group TERM, bounded five-second wait,
  then KILL-and-reap behavior. Each failing command blocks later commands only in its
  own scope. Independent selected scopes still run, and any failure exits nonzero.
- Command output goes to per-command logs, never into JSON stdout. `--show-failures`
  emits a bounded log tail on stderr. The manifest is updated after each check.
- Evidence defaults to `/tmp/codex-runs/verify-*`; `--output-dir` must name a new
  directory. Existing evidence is never overwritten.
- Dry-run creates no evidence, runs no acceptance checks, does not launch a browser,
  and does not validate installed executables. Git metadata reads disable optional
  index locks/writes with a child-only `GIT_OPTIONAL_LOCKS=0` override.

## Coverage is explicit, not inferred

`scopes` lists selected present applications. The `coverage` object separately lists:

- `requested`: expanded requested applications (`all` expands to every known scope,
  including applications absent from this checkout).
- `executed`: scopes with an attempted command; **not** a synonym for passing.
- `completed`: scopes whose every planned command passed.
- `not_run`: present scopes omitted by selection, dry-run, still pending, or with
  remaining commands blocked by an earlier failure. A partially executed scope can
  appear in both `executed` and `not_run`; per-command `checks` disambiguate it.
- `not_applicable`: applications absent from the checkout. Explicitly requesting an
  absent scope is still an error rather than silent success.
- `all_surfaces_completed`: true only when all known surfaces, not merely all present
  or selected surfaces, have completed. Always interpret it with `mode`; quick/full
  completion is not release-profile completion.

A green selected-scope run has `readiness.label = "offline_only"` and
`readiness.status = "selected_scopes_passed"`. A successful dry-run means only that a
plan was constructed; readiness remains `not_run`. Missing applications and unselected
scopes never become implied release coverage.

**Per-test omission accounting remains a gap.** The verifier does not parse arbitrary
ExUnit stdout to invent skip/exclusion counts. Successful command exits, the explicit
Monitor prerequisite gate, and the recorded lifecycle/CI environment establish the
planned acceptance profile; they do not prove that every individual test ran. Review
native suite summaries/logs for omissions. A robust machine-readable per-test result
seam would be separate work, not a claim made by this manifest.

## Residual gates outside this profile

The readiness record explicitly does **not** claim:

1. Live Provider/model connectivity, authentication refresh, live prompt-cache or
   WebSocket behavior, model quality, or external endpoint compatibility. Run the
   separately approved opt-in live probes with real evidence before claiming these.
2. An OS/toolchain/browser matrix. One local run covers its host only; Darwin browser
   handoff, supported Linux configurations, client-specific behavior, and other
   published support promises need their own recorded evidence.
3. Manual publication checks: version/changelog review, package contents, release
   artifacts, public-mirror/privacy review, credentials/permissions, and publication
   itself remain explicit human/operator gates.
4. Complete per-test omission accounting, as described above.

This document describes commands and evidence semantics. It is not a record that the
full release suite, live probes, OS matrix, or publication checks have been completed.
