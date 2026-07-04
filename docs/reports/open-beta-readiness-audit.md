# Pixir Open Beta Readiness Audit

Date: 2026-06-05
Scope: ADR 0016 source-install developer preview

## Verdict

Pixir is ready for a source-install developer-preview beta gate locally. This does not
mean Hex publication, a packaged T3 Code provider, multi-provider support, telemetry, or
a production support contract are ready.

## Completion Audit

| Requirement | Evidence | Status |
|:--|:--|:--|
| Open beta scope locked | `docs/adr/0016-open-beta-scope.md` accepted | proved |
| Source install path | `mix deps.get`, `mix escript.build`, `./pixir help`, `./pixir --version` | proved |
| First-run diagnostics | `./pixir doctor --json`; `Pixir.Doctor` tests | proved |
| CI/CD gate includes diagnostics | `mix check` now builds escript and runs `./pixir doctor --json`; `.github/workflows/ci.yml` runs `mix check` | proved locally |
| Newcomer docs | `docs/open-beta-quickstart.md`, README installation link, ADR 0016 | proved |
| T3 stance honest | ADR 0016 and quickstart mark the T3Code adapter as dogfood, local-only, and not upstreamed | proved |
| Subagent lifecycle limitations honest | ADR 0016 and quickstart document partial outcomes and experimental non-blocking UX | proved |
| Security posture clear | ADR 0016 says no telemetry by default, secrets out of logs/stdout/diagnostics, user-triggered diagnostics | proved |

## Commands Run

```bash
mix deps.get
mix check
mix escript.build
./pixir help
./pixir --version
./pixir doctor --json
mix pixir.smoke.skills
mix pixir.smoke.subagents
mix pixir.smoke.workflows --dry-run --json
git diff --check
```

Observed local result:

- `mix check`: 298 tests, 0 failures; escript built; `doctor --json` returned `ok: true`
  and proved session-log writability; workflow dry-run and docs generation passed.
- `mix pixir.smoke.skills`: passed; canonical skill activation/replay/confinement covered.
- `mix pixir.smoke.subagents`: passed; 50 child sessions completed with isolated writes.
- `mix pixir.smoke.workflows --dry-run --json`: returned `ok: true`.

## Residual Limits

- Networked provider smokes remain manual/opt-in.
- T3Code is still dogfood through a local adapter, not a public install path.
- Long-running non-blocking Subagent status/result retrieval remains experimental UX.
- Hex publication is intentionally deferred until the public package/API contract is
  worth stabilizing.

## Proof Closure

declared -> scoped -> implemented -> locally validated -> documented -> beta-gate-ready
