# Semantic zoom same-session bench gate

`semantic_zoom_gate.mjs` is the positive-and-negative gate for the frozen semantic-zoom v1 Presenter contract. It materializes the real 100-unit fixture, two independent copies of the 500-unit fixture, and the hostile 500-unit fixture, drives the **built** `pixir-monitor` escript, and measures all views in one Chrome process, browser context, and page. It has no npm dependencies and uses Node built-ins plus the Node-provided WebSocket client.

## Build and run

From `monitor/`:

```sh
MIX_ENV=dev mix escript.build
node bench/semantic_zoom_gate.mjs \
  --monitor ./pixir-monitor \
  --browser "/path/to/Chrome" \
  --workdir . \
  --evidence-out /path/to/semantic-zoom-evidence.json \
  --bench-sha "$(git rev-parse HEAD)" \
  --calibrate --json
```

`--workdir` is the Monitor source directory containing `mix.exs` and `bench/emit_fixture_workspace.exs`. The gate invokes, with that cwd, `mix run --no-start bench/emit_fixture_workspace.exs --fixture 100|500|hostile --out <temporary-dir>`. The hostile selector maps to `SemanticZoomFixture.hostile_input_500/0`. It starts one Monitor serve process at a time. Phase A's process is terminated before Phase B starts, and the healthy and hostile servers are likewise exchanged before their phases; ephemeral loopback ports therefore cannot conflict. Chrome, its isolated profile, browser context, and page remain the same throughout.

`--dry-run` checks required files/directories and executable bits and writes a path-safe validation artifact, but starts no child process. Unknown or incomplete arguments fail closed. Stdout is always exactly one JSON value. Child output is captured and never forwarded. Exit codes are: `0` success, `1` runtime/assertion failure, `2` CLI/input or invalid-prior-evidence failure, `3` normal mode refused because pins are uncalibrated or null, and `4` same-fingerprint performance regression.

## Reproducing the gate on a named host

Run every command from `monitor/` on the named host, with the same Chrome installation:

```sh
MIX_ENV=dev mix escript.build

node bench/semantic_zoom_gate.mjs \
  --monitor ./pixir-monitor \
  --browser "/path/to/Chrome" \
  --workdir . \
  --evidence-out /tmp/semantic-zoom-dry-run.json \
  --bench-sha "$(git rev-parse HEAD)" \
  --dry-run --json

node bench/semantic_zoom_gate.mjs \
  --monitor ./pixir-monitor \
  --browser "/path/to/Chrome" \
  --workdir . \
  --evidence-out /tmp/semantic-zoom-calibration.json \
  --bench-sha "$(git rev-parse HEAD)" \
  --calibrate --json

# Review /tmp/semantic-zoom-calibration.json, copy pins.proposed into
# bench/budgets.json, and review the resulting committed pin diff.
git diff -- bench/budgets.json

node bench/semantic_zoom_gate.mjs \
  --monitor ./pixir-monitor \
  --browser "/path/to/Chrome" \
  --workdir . \
  --evidence-out /tmp/semantic-zoom-enforced.json \
  --previous-evidence /path/to/prior/semantic-zoom-enforced.json \
  --bench-sha "$(git rev-parse HEAD)" \
  --json
```

The orchestrator commits reviewed evidence under `.docs/bench-evidence/337/` in the private repository. That directory is excluded from the public mirror. Do not commit temporary evidence from `/tmp` to this source tree.

Regression comparison is same-host-fingerprint-only by design. The stable fingerprint consists of OS platform and release, CPU model and core count, total-memory bucket in GiB, and Chrome major version. A mismatch records `compared: false` with reason `host_fingerprint_mismatch` and never fails the gate. A match compares every measured zoom subtree with `dom_tolerance`, every structural cardinality against its prior value, and 500-unit initial render time with the shared calibration headroom factor of `1.25`; a regression exits with code `4` and kind `performance_regression`.

**Claim limits.** The committed artifact supports a reproducible result on its named local host and host-independent claims about bounded rendering structure. It does not support comparisons across host fingerprints, broad browser or hardware claims, or a cross-machine performance claim.


Monitor is launched with `serve --workspace <workspace> --launch-mode fifo --json`. The FIFO path is read from structured stderr, and the one-use launch URL is read into memory, passed only as a CDP `Page.navigate` parameter, and immediately cleared. It is never placed in argv, stdout, the evidence artifact, or a gate-created persistent file. The evidence host descriptor contains only OS type/release/architecture, CPU model/count, and total memory; it contains no username or path.

The required evidence file is written once, after bounded cleanup, and contains the budget snapshot, host and Chrome descriptors, bench SHA supplied by the caller, all absolute measurements, assertions, proposed/enforced pins, negative-phase records (`refetch_samples`, `restoration_outcomes`, `hostile_findings`, and `red_proof`), and cleanup status. A failed run writes the same artifact shape with a safe structured error and all measurements available before failure.

## Named phases

1. **materialize_fixtures** — create real 100u, mutable 500u, dedicated pristine red-proof 500u, and hostile 500u workspaces under a temporary root.
2. **start_browser_session** — launch one isolated headless Chrome and attach one page through CDP.
3. **phase_a_100_initial** — bootstrap the 100u serve instance, navigate to its Workflow detail, and measure initial convergence.
4. **phase_b_500_initial** — cleanly stop the first server, bootstrap the 500u instance in the same browser page, and take the same measurements.
5. **phase_c_500_expansion_walk** — inspect a cluster at member page 1, advance to member page 2, open an arc ledger at edge page 1, advance to edge page 2, then activate overflow level 1 and level 2.
6. **phase_d_refetch** — append 25 deterministic, decoder-recognized `assistant_message` events to the served 500u Session Log one at a time; each size-changing append must produce an SSE-driven authoritative rerender, return every structural cardinality and zoom-node count to the same fixed point, and keep every B1s structural check green.
7. **phase_e_restoration** — exercise a wave-13 unit deep link and browser-history restoration, member page 3 through the DOM-provided `members-next:*` target, and native CDP Tab/Enter traversal whose expected focus order is read from the live DOM.
8. **phase_f_hostile** — exchange the healthy server for the hostile fixture and require literal inert script text, no injected script/dialog/security-relevant console error, and bounded rendering of the 32,768-character field.
9. **phase_g_red_proof** — start a dedicated pristine 500u workspace that phase D never mutated, clone a real inspector member card at least 500 times, require exactly the member-card structural ceiling to turn red, navigate through the in-product Runs view back to the cluster, and require the authoritative view to return green. Any authoritative render rebuilds the zoom subtree with `replaceChildren`, so injected clones cannot survive this operator-visible navigation. Browser reload is deliberately not used: the one-use launch capability is consumed during bootstrap, making reload structurally unavailable.
10. **assert_gate** — enforce structural-only assertions in calibration mode, or structural and pinned same-session assertions in normal mode.
11. **cleanup** — dispose the browser context, close/reap Chrome and Monitor, and remove the temporary profile and fixture root within fixed bounds.

Convergence is polled every 50 ms for at most 15 seconds. Refetch cycles have an additional 5-second per-cycle bound and fail closed if the zoom section is not authoritatively replaced. Each refetch append is exactly one NDJSON line with the canonical envelope keys `id`, `session_id`, `seq`, `ts`, `type`, and `data`; `type` is the decoder-recognized `assistant_message`, `data` is `{"text":"bench refetch cycle <n>"}`, and sequence numbers begin one beyond the fixture's final real event. The message changes the Log watcher's `(mtime, size)` fingerprint without changing semantic-zoom structure. It requires the expected canonical hash, a populated `.semantic-zoom > .cluster-overview`, a `.detail-view`, and no `.error-view`. Initial `render_ms` starts immediately before assigning the detail hash and ends at convergence. Step latency uses the same boundary. `zoom_subtree_nodes` counts element descendants of `section.semantic-zoom`; `body_total_nodes` counts element descendants of `body`. CDP `Performance.getMetrics` records `JSHeapUsedSize` and `Nodes` immediately before and after each initial detail navigation.

## Structural assertions

Every measured semantic-zoom state checks:

- level zero has at most 7 entity cards; deeper windows have at most 8;
- at most 6 `.cluster-cluster`, one `.cluster-overflow`, and one `.cluster-boundary` card;
- the boundary is absent at `zoomStart == 0` and exactly one is present at deeper levels;
- every entity card has exactly five `.cluster-distribution` rows (Execution, Liveness, Dependency gate, Model advisory, Attention);
- exactly one direct section-level run-scoped Source presentation exists;
- level-zero non-empty graphs render at least one aggregate arc, and aggregate arc links are at most `C(entity_cards, 2) + 1`;
- phase contexts that open a member inspector or exact-edge ledger require positive `minMemberCards` or `minLedgerRows` convergence before measurement;
- member cards are at most `12 * memberPage`; exact-edge ledger rows are at most `100 * edgePage`.

The arc ceiling is deliberately tighter than a generic directed-graph bound. Workflow exact edges advance in topological order, so each unordered pair of visible entities can produce at most one aggregate arc. Intra-wave exact edges cannot exist. Only an overflow entity can legally have a self-arc, giving `C(entities, 2) + 1`.

## Calibration and numeric pins

The committed `budgets.json` carries named-host-calibrated values for every pin, including the B5a per-step ceilings (calibrated 2026-07-15). Normal mode refuses to launch unless every required pin, including B5a, is present and finite. `--calibrate` still runs the complete protocol, enforces only the structural assertions above, and emits proposed pins without editing `budgets.json`:

- `dom_tolerance = ceil(abs(zoom500 - zoom100) * 1.25) + 10`
- `initial_ceiling = ceil(body500 * 1.20) + 50`
- each additive `*_step_nodes = ceil(max(0, page2_nodes - page1_nodes) * 1.25) + 20`
- each `*_page_2_ceiling = ceil(page2_nodes * 1.15) + 20`
- `overflow_zoom_ceiling = ceil(max(level1_nodes, level2_nodes) * 1.15) + 20`; overflow is scored as a replacement-window result, never as a signed delta
- `denom_floor_ms = 25`
- `k = ceil100(max(1.50, render500 / max(render100, 25) * 1.25))`
- `expansion_ratio = ceil100(max(2.00, maximum_step_latency / max(render500, 1) * 1.25))`; the frozen B5 ratio form remains enforced
- each additive B5a absolute step pin `*_step_ms = max(ceil(measured step latency (single sample per step) * 1.25), 25)`; the 25ms floor absorbs single-digit-ms timer noise on cheap steps; normal mode enforces both B5 and B5a and refuses null B5a pins

`ceil100` rounds upward to two decimal places. The fixed slack covers polling granularity and minor same-host noise while preserving reviewable pins. The orchestrator must review named-host calibration evidence, copy the proposed values into `pins`, set `calibrated` to `true`, and rerun normal mode. Absolute measurements are always evidence; only structural or same-session-relative values are assertions.
