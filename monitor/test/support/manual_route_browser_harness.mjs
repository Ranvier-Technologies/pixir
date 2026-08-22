#!/usr/bin/env node

// Real-browser behavioural proof of the instrument-manual ROUTE FAMILY.
//
// Two tiers already speak about this family and neither drives a browser:
// `test/ui/manual_pane_contract_test.exs` greps the bundle SOURCE, and
// `test/ui/manual_overlay_preservation_test.exs` executes the fast-path seam in
// node:vm against a minimal DOM. Neither one navigates: no real hashchange, no
// real history stack, no real fetch, no real render loop. This harness closes
// that gap over real Chrome via CDP, in the same bounded shape as its siblings
// (`malformed_scale_browser_harness.mjs`, `zoom_lifecycle_browser_harness.mjs`):
// launch capability is read from the one-use FIFO and never from argv, every
// wait is an explicit condition with a deadline, and there are no sleeps.
//
// WHAT THIS HARNESS DOES NOT DO. The Escape legs of the manual — Escape closes
// an open pane, Escape with the pane closed navigates nowhere, and closing
// preserves the underlying route — are already pinned per-frontier by
// `test/accessibility_gauntlet_test.exs` (`escape_dispatched_without_navigation`,
// `manual_pane_opens_for_escape_contract`, `escape_closes_open_manual_pane`,
// `escape_close_preserves_underlying_route`, on f1/f2/f3). Re-driving them here
// would duplicate a gate rather than add evidence, so this harness closes the
// pane through the pane's OWN Close control instead — the affordance the
// gauntlet does not exercise.
//
// The DEEP-LINK entry shape. `#manual/<slug>` cannot be a document-load URL in
// this architecture: the launch capability is one-use and the shell bootstrap
// replaceStates the whole fragment away before the app script even loads
// (lib/pixir_monitor/bootstrap.ex). The reachable production shape is therefore
// exactly what this harness drives — the identity pasted into an already-open
// Monitor — and the sharpest available proof is to enter it FROM A NON-DEFAULT
// ROUTE: a deep link taken while a run detail is painted must land the reader on
// the DEFAULT view with the pane open, never on the detail it came from and
// never on an unavailable view. That is the parseRoute intercept (app.js: the
// `segments[0] === "manual"` branch ahead of the workspace-set branch and the
// runs fallthrough) observed end to end.

import {spawn} from "node:child_process";
import {existsSync} from "node:fs";
import {mkdtemp, readFile, rm} from "node:fs/promises";
import {dirname, join} from "node:path";
import {createInterface} from "node:readline";
import process from "node:process";
import {extraBrowserArgs} from "./chrome_args.mjs";

const LEGS = [
  "boot_default_view",
  "deep_link_resolves_to_default_view",
  "unknown_slug_lands_on_index",
  "history_back_forward_restores_manual_state",
  "manual_only_toggle_issues_no_authoritative_refetch",
  "close_control_preserves_underlying_route",
  "no_refetch_over_unrederivable_view",
  "dotted_label_opens_its_term"
];

// The authoritative projection surfaces. Everything the app fetches for a
// snapshot lives under one of these two shapes (app.js: `/api/runs`,
// `/api/runs/<id>`, `/api/workspaces/<w>/runs[...]`); `/api/events` is the SSE
// hint stream and arrives over EventSource, not fetch, so it is not a refetch
// and cannot be confused for one. The preload records EVERY fetch pathname and
// the accounting below filters here, so a NEW authoritative endpoint added
// later still counts as a refetch instead of slipping past a narrow allowlist.
const PROJECTION_PATH_PATTERN = /^\/api\/(runs|workspaces)(\/|$)/;

// The SCOPED INVENTORY endpoint specifically — the list acquisition, as opposed
// to the per-run detail requests that share the `/api/runs` prefix. This is the
// request `acquireInventoryForResolution` issues in single mode, and naming it
// separately is what lets the dead-end leg COUNT that acquisition at the instant
// its view is attached, and then hold its baseline open until whatever it
// counted has settled — rather than hoping the request lands inside a time
// window, or demanding one the app was right not to issue.
// It is deliberately anchored to the exact path: `/api/runs/<id>` is a detail
// fetch and must not be mistaken for the inventory this leg waits on.
const INVENTORY_PATH_PATTERN = /^\/api\/runs$/;

// The fetch-recording preload, in the same idiom as browser_harness.mjs's
// `control.fetches`: wrap window.fetch, push the resolved pathname, forward
// untouched. It records requests in the page's own terms, which is what makes
// "zero authoritative requests across this toggle" a claim about the app rather
// than about CDP's view of the network. It is installed with
// Page.addScriptToEvaluateOnNewDocument so it is in place before the bundle
// loads and therefore before the very first snapshot request.
//
// It also keeps an OUTSTANDING counter, incremented at issue and decremented
// when the request settles either way. That counter is what turns the baseline
// below into a real quiescence gate instead of a stability heuristic: a
// request the app has already issued but not yet received is visible as
// in-flight, so the baseline cannot be taken over a moving snapshot. Without
// it, an authoritative request the app issues on its own — most sharply, the
// parent-resolution `/api/runs` that renderProjectionFailure fires
// SYNCHRONOUSLY on a structured run_not_found, before the dead end is even
// painted — could land on either side of the baseline purely by round-trip
// timing, either escaping the measured window entirely or being charged to the
// manual toggle as a false red.
const PRELOAD_SCRIPT = `(() => {
  const control = {fetches: [], hashes: [], outstanding: 0};
  window.__pixirManualRouteHarness = control;
  window.addEventListener("hashchange", () => control.hashes.push(location.hash));
  const nativeFetch = window.fetch.bind(window);
  window.fetch = function(input, init) {
    try { control.fetches.push(new URL(typeof input === "string" ? input : input.url, location.href).pathname); } catch (_error) {}
    control.outstanding += 1;
    let settled = false;
    const release = () => { if (settled) return; settled = true; control.outstanding -= 1; };
    let response;
    try { response = nativeFetch(input, init); }
    catch (error) { release(); throw error; }
    return response.then(
      value => { release(); return value; },
      error => { release(); throw error; }
    );
  };
})();`;

// One expression, evaluated at every leg boundary. Reading the whole shape at
// once keeps each observation a single point in time: a leg cannot pass by
// sampling the pane before a re-render and the view after it.
const SNAPSHOT = `(() => {
  const pane = document.querySelector('.manual-pane');
  const view = document.querySelector('#app .view');
  const control = window.__pixirManualRouteHarness;
  return {
    hash: location.hash,
    viewClass: view ? view.className : null,
    // The run identity the painted view actually rests on, read from the
    // run-scoped disclosure key rather than assumed from the hash.
    detailRunId: (document.querySelector('.detail-view details[data-disclosure-key^="run-overview:"]')?.dataset.disclosureKey || "").replace(/^run-overview:/, "") || null,
    detailTitle: document.querySelector('.detail-view h1')?.textContent || null,
    paneOpen: Boolean(pane),
    paneTerm: pane ? pane.dataset.manual : null,
    paneLabel: pane ? pane.getAttribute('aria-label') : null,
    paneRole: pane ? pane.tagName.toLowerCase() : null,
    routeChip: document.querySelector('.manual-route-id')?.textContent || null,
    entryTerm: document.querySelector('.manual-entry-term')?.textContent || null,
    unknownSlugCopy: document.querySelector('.manual-unknown-slug')?.textContent || null,
    indexTermLinks: document.querySelectorAll('.manual-term-list li a').length,
    closeHref: document.querySelector('.manual-pane [data-focus-key="manual-close"]')?.getAttribute('href') || null,
    errorView: Boolean(document.querySelector('.error-view')),
    unavailableClass: document.querySelector('[data-unavailable-class]')?.dataset.unavailableClass || null,
    errorKind: document.getElementById('app')?.dataset.errorKind || null,
    dottedLabels: document.querySelectorAll('[data-manual-term]').length,
    projectionFetches: control.fetches.filter(path => ${PROJECTION_PATH_PATTERN}.test(path)).length,
    allFetches: control.fetches.length,
    focusKey: document.activeElement && document.activeElement.dataset ? (document.activeElement.dataset.focusKey || null) : null,
    historyLength: history.length
  };
})()`;

function failure(kind, message, stage, details = {}) {
  const error = new Error(message);
  error.harnessKind = kind;
  error.harnessStage = stage;
  error.safeDetails = details;
  return error;
}

function safeError(error) {
  return {ok: false, error: {kind: error?.harnessKind || "manual_route_browser_harness_failed", message: error?.harnessKind ? error.message : "The manual route browser harness failed unexpectedly", details: {stage: error?.harnessStage || "unknown", ...(error?.safeDetails || {})}}};
}

function parseArgs(argv) {
  const options = {browser_timeout_ms: 60_000};
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === "--json") continue;
    if (["--monitor", "--workspace", "--browser", "--profile-base", "--run-id", "--known-slug", "--unknown-slug", "--browser-timeout-ms"].includes(arg)) options[arg.slice(2).replaceAll("-", "_")] = argv[++index];
    else throw failure("invalid_args", "Unknown or incomplete manual route browser harness argument", "parse_args");
  }
  return options;
}

function validate(options) {
  for (const field of ["monitor", "workspace", "browser", "profile_base", "run_id", "known_slug", "unknown_slug"]) {
    if (!options[field]) throw failure("missing_required_arg", `Missing required --${field.replaceAll("_", "-")}`, "validate_args");
  }
  for (const field of ["monitor", "workspace", "browser", "profile_base"]) {
    if (!existsSync(options[field])) throw failure(`${field}_missing`, `Required ${field.replaceAll("_", " ")} is missing`, "validate_inputs");
  }
  // Both slugs must be manualField-shaped, or the legs below would be asserting
  // against the normalizer's fallback rather than against the route family.
  const slugPattern = /^[a-z0-9]+(?:-[a-z0-9]+)*$/;
  for (const field of ["known_slug", "unknown_slug"]) {
    if (!slugPattern.test(options[field]) || options[field].length > 128) throw failure("invalid_slug", `--${field.replaceAll("_", "-")} must be a manual slug`, "validate_args");
  }
  if (options.known_slug === options.unknown_slug) throw failure("slugs_not_distinct", "The known and unknown manual slugs must differ", "validate_args");
  if (options.unknown_slug === "index") throw failure("unknown_slug_is_index", "The unknown slug must not be the index sentinel", "validate_args");
  if (typeof WebSocket !== "function") throw failure("node_websocket_unavailable", "Node.js does not provide WebSocket", "validate_runtime");
  options.browser_timeout_ms = Number(options.browser_timeout_ms);
  if (!Number.isSafeInteger(options.browser_timeout_ms) || options.browser_timeout_ms < 5_000 || options.browser_timeout_ms > 120_000) throw failure("invalid_browser_timeout", "--browser-timeout-ms must be 5000..120000", "validate_args");
}

function withTimeout(promise, timeoutMs, kind, message, stage) {
  return new Promise((resolve, reject) => {
    const timeout = setTimeout(() => reject(failure(kind, message, stage)), timeoutMs);
    Promise.resolve(promise).then(value => { clearTimeout(timeout); resolve(value); }, error => { clearTimeout(timeout); reject(error); });
  });
}

function waitForJsonLine(stream, predicate, stage, timeoutMs = 45_000) {
  return new Promise((resolve, reject) => {
    const lines = createInterface({input: stream});
    let settled = false;
    const finish = (callback, value) => { if (settled) return; settled = true; clearTimeout(timer); lines.close(); callback(value); };
    const timer = setTimeout(() => finish(reject, failure("process_readiness_timeout", "Child readiness was not observed", stage)), timeoutMs);
    lines.on("line", line => { try { const value = JSON.parse(line); if (predicate(value)) finish(resolve, value); } catch (_error) {} });
    lines.on("close", () => finish(reject, failure("process_readiness_stream_closed", "Child readiness stream closed", stage)));
  });
}

function waitForDevTools(stream, timeoutMs = 20_000) {
  return new Promise((resolve, reject) => {
    const lines = createInterface({input: stream});
    let settled = false;
    const finish = (callback, value) => { if (settled) return; settled = true; clearTimeout(timer); lines.close(); callback(value); };
    const timer = setTimeout(() => finish(reject, failure("browser_readiness_timeout", "Chrome did not expose DevTools", "start_browser")), timeoutMs);
    lines.on("line", line => { const match = line.match(/DevTools listening on (ws:\/\/127\.0\.0\.1:\d+\/devtools\/browser\/[A-Za-z0-9-]+)/); if (match) finish(resolve, match[1]); });
    lines.on("close", () => finish(reject, failure("browser_readiness_stream_closed", "Chrome readiness stream closed", "start_browser")));
  });
}

async function connectDevTools(url) {
  const socket = new WebSocket(url);
  await withTimeout(new Promise((resolve, reject) => { socket.addEventListener("open", resolve, {once: true}); socket.addEventListener("error", reject, {once: true}); }), 10_000, "devtools_connect_timeout", "Could not connect to Chrome DevTools", "connect_browser");
  let nextId = 1;
  const pending = new Map();
  const listeners = new Set();
  const rejectPending = () => { for (const [id, waiter] of pending) { pending.delete(id); waiter.reject(failure("devtools_connection_closed", "Chrome DevTools closed", waiter.stage)); } };
  socket.addEventListener("message", event => {
    const message = JSON.parse(event.data);
    const waiter = pending.get(message.id);
    if (!waiter) { for (const listener of listeners) listener(message); return; }
    pending.delete(message.id);
    message.error ? waiter.reject(failure("devtools_command_failed", "Chrome DevTools command failed", waiter.stage, {code: message.error.code})) : waiter.resolve(message.result);
  });
  socket.addEventListener("close", rejectPending);
  socket.addEventListener("error", rejectPending);
  return {
    send(method, params = {}, sessionId = null, stage = "browser_command") {
      if (socket.readyState !== WebSocket.OPEN) return Promise.reject(failure("devtools_connection_closed", "Chrome DevTools is not open", stage));
      const id = nextId++;
      return withTimeout(new Promise((resolve, reject) => { pending.set(id, {resolve, reject, stage}); socket.send(JSON.stringify({id, method, params, ...(sessionId ? {sessionId} : {})})); }), 10_000, "devtools_command_timeout", "Chrome DevTools command timed out", stage).finally(() => pending.delete(id));
    },
    onEvent(listener) { listeners.add(listener); return () => listeners.delete(listener); },
    close() { socket.close(); }
  };
}

async function evaluate(client, sessionId, expression, stage) {
  const result = await client.send("Runtime.evaluate", {expression, returnByValue: true, awaitPromise: true}, sessionId, stage);
  if (result.exceptionDetails) throw failure("browser_expression_failed", "Browser assertion expression failed", stage, {text: result.exceptionDetails.text || null});
  return result.result?.value;
}

// Waits for `expression` to go true, and — when `observe` is given — returns the
// value of `observe` READ IN THE SAME EVALUATION that first saw the condition
// hold. That atomicity is not a nicety: the dead-end leg below needs to know
// what the app had already fetched AT THE INSTANT the view was attached, and a
// second round trip to read it would let requests issued after the paint be
// mistaken for requests issued before it.
async function waitForBrowser(client, sessionId, expression, stage, timeoutMs, observe = null) {
  const deadline = Date.now() + timeoutMs;
  const probe = observe
    ? `(() => { if (!(${expression})) return null; return {observed: (${observe})}; })()`
    : `(() => { return (${expression}) ? {observed: null} : null; })()`;
  while (Date.now() < deadline) {
    const result = await evaluate(client, sessionId, probe, stage);
    if (result) return result.observed;
    await new Promise(resolve => setTimeout(resolve, 50));
  }
  // The diagnostics are best-effort garnish on a failure that already
  // happened: if the page is wedged enough that the snapshot ALSO throws, the
  // timeout must still be the reported failure, not the garnish's own error.
  let diagnostics = null;
  try {
    diagnostics = await evaluate(client, sessionId, SNAPSHOT, `${stage}_diagnostics`);
  } catch (error) {
    diagnostics = {diagnostics_unavailable: String((error && error.message) || error)};
  }
  throw failure("browser_assertion_timeout", "Browser did not converge on the manual route condition", stage, {diagnostics});
}

// QUIESCENCE, not a sleep and not a stability heuristic. The no-refetch
// accounting is only meaningful over a view that has finished loading: with a
// request still in flight the toggle would be measured against a moving
// baseline and could pass or fail by timing.
//
// The gate is therefore the app's OWN in-flight state, read from the preload's
// outstanding counter, and not sample stillness. Stillness alone is a
// wall-clock bet: a request the app has already issued but that has not yet
// come back is indistinguishable from an app that is done, so on a fast
// localhost round trip the baseline happens to land after it and on a loaded
// runner it happens to land before it. Requiring `outstanding === 0` removes
// the bet entirely — a still-open request holds the baseline open until it
// settles, and the deadline makes a request that never settles a LOUD failure.
//
// The consecutive-sample window is kept on top of the in-flight gate, not
// instead of it: it covers the microtask gap between a response arriving and
// the continuation that reacts to it issuing the next request, so a chained
// acquisition is caught inside one call rather than splitting the baseline.
//
// `expected` closes the remaining hole on the dead-end leg — but it is an
// OBSERVED demand, never a predicted one, and the difference is the whole point.
//
// An in-flight counter can only see a request the app has already ISSUED. A
// request the app is still going to issue is indistinguishable from an app that
// is finished, so the dead-end baseline needs to know that the app's own
// parent-resolution acquisition is accounted for. The temptation is to DEMAND it
// — "one more `/api/runs` must arrive" — and that is a prediction the app never
// promised: `renderProjectionFailure` issues that acquisition only
// `if (identityLoss && !heldInventoryRows(route).length)`, and
// `acquireInventoryForResolution` short-circuits on an open or already-spent
// resolution. Held inventory, or a resolution still open from an earlier dead
// end, and the app correctly issues NOTHING. A predicted demand then never
// settles, burns the whole deadline, and fails LOUDLY while blaming the app for
// a request it was right not to make — a false red, which is worse than the
// early baseline the demand was added to prevent.
//
// So the caller passes what it OBSERVED the app to have already issued, read at
// the instant the view was attached (see the dead-end leg). The app decides
// about that acquisition SYNCHRONOUSLY, inside renderProjectionFailure, strictly
// BEFORE the error view reaches the DOM — so by the time the harness can see the
// view at all, the decision is made and irrevocable, and the recorded count at
// that instant is the truth rather than a guess. Waiting for a count that has
// already been reached is trivially satisfied; waiting for one still in flight
// holds the baseline open until it settles. Both branches are correct, and
// neither is a bet on latency.
async function waitForFetchQuiescence(client, sessionId, stage, timeoutMs, expected = null, stableSamples = 6) {
  const deadline = Date.now() + timeoutMs;
  const expectedPattern = expected ? expected.pattern : /^(?!)/;
  const expectedCount = expected ? expected.count : 0;
  let last = null;
  let stable = 0;
  let lastSample = null;
  while (Date.now() < deadline) {
    const sample = await evaluate(client, sessionId, `(() => { const control = window.__pixirManualRouteHarness; return {count: control.fetches.filter(path => ${PROJECTION_PATH_PATTERN}.test(path)).length, outstanding: control.outstanding, expected: control.fetches.filter(path => ${expectedPattern}.test(path)).length}; })()`, stage);
    lastSample = sample;
    if (sample.outstanding > 0 || sample.expected < expectedCount) {
      // Either something is still open, or a request this caller OBSERVED being
      // issued has somehow left the record. The count may not move again in the
      // meantime, so stillness must not accumulate underneath it.
      last = sample.count;
      stable = 0;
    } else if (sample.count === last) {
      stable += 1;
      if (stable >= stableSamples) return sample.count;
    } else {
      last = sample.count;
      stable = 1;
    }
    await new Promise(resolve => setTimeout(resolve, 50));
  }
  throw failure("fetch_quiescence_timeout", "Requests never went quiet, so the no-refetch accounting has no stable baseline", stage, {last_count: last, outstanding: lastSample ? lastSample.outstanding : null, expected_seen: lastSample ? lastSample.expected : null, expected_required: expectedCount});
}

// Returns the SNAPSHOT after arrival. When `observe` is given, the value it
// evaluates to AT THE ARRIVAL INSTANT is returned alongside as `observed` — the
// dead-end leg needs a reading taken in the same evaluation that first saw the
// view, not one taken a poll later.
async function navigateHash(client, sessionId, hash, condition, stage, timeoutMs, observe = null) {
  await evaluate(client, sessionId, `location.hash = ${JSON.stringify(hash)}; true`, `${stage}_navigate`);
  const observed = await waitForBrowser(client, sessionId, `location.hash === ${JSON.stringify(hash)} && (${condition})`, stage, timeoutMs, observe);
  const snapshot = await evaluate(client, sessionId, SNAPSHOT, `${stage}_snapshot`);
  return observe ? {...snapshot, observed} : snapshot;
}

async function stopChild(child) {
  const stopped = () => !child || child.exitCode !== null || child.signalCode !== null;
  if (stopped()) return true;
  child.kill("SIGTERM");
  await Promise.race([new Promise(resolve => child.once("exit", resolve)), new Promise(resolve => setTimeout(resolve, 1_000))]);
  if (!stopped()) { child.kill("SIGKILL"); await Promise.race([new Promise(resolve => child.once("exit", resolve)), new Promise(resolve => setTimeout(resolve, 1_000))]); }
  return stopped();
}

// Every leg records its own name, so a harness that quietly drops one reports
// fewer legs instead of passing. The driver pins the exact list.
function leg(legs, name, observations) {
  legs.push({name, ...observations});
  return observations;
}

function paneIsNamed(snapshot) {
  // The pane is a COMPLEMENTARY landmark, so it must carry its own accessible
  // name or a screen-reader operator lands in a bare "complementary".
  return snapshot.paneOpen && snapshot.paneRole === "aside" && snapshot.paneLabel === "Instrument manual";
}

async function manualRouteStory(client, sessionId, options, consoleErrors) {
  const legs = [];
  const runHash = `#/runs/${encodeURIComponent(options.run_id)}`;
  const knownDeepLink = `#manual/${options.known_slug}`;
  const unknownDeepLink = `#manual/${options.unknown_slug}`;

  // ── 1. Boot lands on the default view with the pane CLOSED ────────────────
  await waitForBrowser(client, sessionId, `document.title === "Pixir Monitor" && location.hash === "#/runs" && document.querySelector('.runs-view') && !location.hash.startsWith("#launch=")`, "boot_default_view", options.browser_timeout_ms);
  const booted = await evaluate(client, sessionId, SNAPSHOT, "boot_default_view_snapshot");
  if (booted.paneOpen || booted.errorView) throw failure("boot_state_unexpected", "The Monitor did not boot on a clean default view with the manual closed", "boot_default_view", {booted});
  leg(legs, "boot_default_view", {hash: booted.hash, view_class: booted.viewClass, pane_open: booted.paneOpen});

  // ── 2. The DEEP LINK, taken from a NON-DEFAULT route ──────────────────────
  //
  // Painting a run detail first is what gives this leg its teeth. A deep link
  // that merely "kept the current route and opened a pane" would land on the
  // DETAIL view and still show the pane; only the parseRoute intercept produces
  // the default view. So the detail is established and pinned by identity
  // first, and the deep link must then move OFF it.
  const detail = await navigateHash(client, sessionId, runHash, `document.querySelector('.detail-view') && !document.querySelector('.error-view')`, "detail_precondition", options.browser_timeout_ms);
  if (detail.detailRunId !== options.run_id) throw failure("detail_precondition_unmet", "The detail precondition did not paint the requested run", "detail_precondition", {detail});

  const deepLinked = await navigateHash(client, sessionId, knownDeepLink, `document.querySelector('.manual-pane[data-manual=${JSON.stringify(options.known_slug)}]') && document.querySelector('.runs-view')`, "deep_link_resolves_to_default_view", options.browser_timeout_ms);
  const deepLinkHonest =
    paneIsNamed(deepLinked) &&
    deepLinked.paneTerm === options.known_slug &&
    // The DEFAULT view, not the detail it came from and not an unavailable one.
    /\bruns-view\b/.test(deepLinked.viewClass || "") &&
    !/\bdetail-view\b/.test(deepLinked.viewClass || "") &&
    !deepLinked.errorView &&
    deepLinked.unavailableClass === null &&
    deepLinked.errorKind === null &&
    // The pane resolved the slug to a real entry rather than falling back to the
    // index: the route chip names the slug and an entry body was rendered.
    deepLinked.routeChip === `#manual/${options.known_slug}` &&
    typeof deepLinked.entryTerm === "string" && deepLinked.entryTerm.length > 0 &&
    deepLinked.unknownSlugCopy === null &&
    // Close returns to the DEFAULT route, which is the route the deep link
    // resolved onto — the pane never invented a route of its own.
    deepLinked.closeHref === "#/runs";
  if (!deepLinkHonest) throw failure("deep_link_not_resolved", "A #manual/<slug> deep link taken from a run detail did not resolve to the default view with the pane open on that entry", "deep_link_resolves_to_default_view", {deep_linked: deepLinked, from_detail: detail});
  leg(legs, "deep_link_resolves_to_default_view", {hash: deepLinked.hash, view_class: deepLinked.viewClass, pane_term: deepLinked.paneTerm, pane_label: deepLinked.paneLabel, route_chip: deepLinked.routeChip, entry_term: deepLinked.entryTerm, close_href: deepLinked.closeHref, entered_from: detail.hash});

  // ── 3. An UNKNOWN slug lands on the INDEX, never on an unavailable view ───
  const unknown = await navigateHash(client, sessionId, unknownDeepLink, `document.querySelector('.manual-pane[data-manual=${JSON.stringify(options.unknown_slug)}]') && document.querySelector('.manual-term-list li a')`, "unknown_slug_lands_on_index", options.browser_timeout_ms);
  const unknownHonest =
    paneIsNamed(unknown) &&
    unknown.paneTerm === options.unknown_slug &&
    /\bruns-view\b/.test(unknown.viewClass || "") &&
    // The whole point: an unrecognized term is a routing miss the pane RENDERS.
    !unknown.errorView &&
    unknown.unavailableClass === null &&
    unknown.errorKind === null &&
    // The index, with the requested slug named back to the reader verbatim.
    unknown.indexTermLinks > 0 &&
    unknown.entryTerm === null &&
    typeof unknown.unknownSlugCopy === "string" &&
    unknown.unknownSlugCopy.includes(options.unknown_slug) &&
    // The chip names the route that actually opens what is on screen — the
    // index — rather than pinning a slug that opens nothing.
    unknown.routeChip === "#manual/index";
  if (!unknownHonest) throw failure("unknown_slug_not_indexed", "An unknown #manual/<slug> did not land on the manual index with the pane open", "unknown_slug_lands_on_index", {unknown});
  leg(legs, "unknown_slug_lands_on_index", {hash: unknown.hash, view_class: unknown.viewClass, pane_term: unknown.paneTerm, route_chip: unknown.routeChip, index_term_links: unknown.indexTermLinks, unknown_slug_named: true});

  // ── 4. BACK / FORWARD restore manual state ────────────────────────────────
  //
  // The stack at this point is, in order: the default view, the run detail, the
  // known deep link, the unknown deep link. One step back must restore the
  // KNOWN entry (pane open on that term); one step forward must restore the
  // UNKNOWN one (pane open on the index copy). Both are asserted on the full
  // shape, not merely on the hash, so a restored hash with a closed pane fails.
  await evaluate(client, sessionId, `history.back(); true`, "history_back");
  await waitForBrowser(client, sessionId, `location.hash === ${JSON.stringify(knownDeepLink)} && document.querySelector('.manual-pane[data-manual=${JSON.stringify(options.known_slug)}]')`, "history_back_restores_manual", options.browser_timeout_ms);
  const back = await evaluate(client, sessionId, SNAPSHOT, "history_back_snapshot");

  // A SECOND step back, to the route UNDER the manual entries. This is what
  // proves each deep link pushed a history entry of its own rather than being
  // replaceState'd over its predecessor: with the manual entries collapsed, one
  // step back from the known deep link would already be the run detail and the
  // step above would have landed somewhere else. It also pins that stepping out
  // of the manual restores a CLOSED pane over the underlying view, which is the
  // same overlay property the Close control leg asserts, reached by the browser
  // control instead of by an affordance the app renders.
  await evaluate(client, sessionId, `history.back(); true`, "history_back_beneath");
  await waitForBrowser(client, sessionId, `location.hash === ${JSON.stringify(runHash)} && !document.querySelector('.manual-pane') && document.querySelector('.detail-view')`, "history_back_reaches_underlying_route", options.browser_timeout_ms);
  const beneath = await evaluate(client, sessionId, SNAPSHOT, "history_beneath_snapshot");

  await evaluate(client, sessionId, `history.forward(); true`, "history_forward_to_known");
  await waitForBrowser(client, sessionId, `location.hash === ${JSON.stringify(knownDeepLink)} && document.querySelector('.manual-pane[data-manual=${JSON.stringify(options.known_slug)}]')`, "history_forward_restores_known", options.browser_timeout_ms);
  await evaluate(client, sessionId, `history.forward(); true`, "history_forward");
  await waitForBrowser(client, sessionId, `location.hash === ${JSON.stringify(unknownDeepLink)} && document.querySelector('.manual-pane[data-manual=${JSON.stringify(options.unknown_slug)}]')`, "history_forward_restores_manual", options.browser_timeout_ms);
  const forward = await evaluate(client, sessionId, SNAPSHOT, "history_forward_snapshot");
  const historyHonest =
    paneIsNamed(back) && back.paneTerm === options.known_slug && back.routeChip === `#manual/${options.known_slug}` && back.entryTerm === deepLinked.entryTerm && !back.errorView &&
    !beneath.paneOpen && beneath.detailRunId === options.run_id && !beneath.errorView &&
    paneIsNamed(forward) && forward.paneTerm === options.unknown_slug && forward.routeChip === "#manual/index" && forward.indexTermLinks === unknown.indexTermLinks && !forward.errorView;
  if (!historyHonest) throw failure("history_did_not_restore_manual", "Browser back/forward did not restore the manual overlay state", "history_back_forward_restores_manual_state", {back, beneath, forward});
  leg(legs, "history_back_forward_restores_manual_state", {back_hash: back.hash, back_pane_term: back.paneTerm, back_entry_term: back.entryTerm, beneath_hash: beneath.hash, beneath_pane_open: beneath.paneOpen, beneath_detail_run_id: beneath.detailRunId, forward_hash: forward.hash, forward_pane_term: forward.paneTerm, forward_index_term_links: forward.indexTermLinks});

  // ── 5. The overlay rides beside an ALREADY-PAINTED view ───────────────────
  //
  // The manual is an overlay FIELD, not a fifth view, precisely so that a
  // manual-only hash delta can be served as a pure re-render with the view the
  // pane opens over left standing. This leg is the behavioural proof of that
  // claim over a HEALTHY run detail: the run is painted and allowed to go
  // quiescent, the pane is opened and closed over it, the run stays painted BY
  // IDENTITY beside the pane, and the recorded count of authoritative projection
  // requests must not move by one.
  //
  // A HEALTHY view cannot carry the no-refetch claim ON ITS OWN, and saying so
  // is the honest part. Deleting the manual fast path entirely leaves this leg
  // green: the ordinary path's own `matchingDetail` branch re-renders a healthy
  // detail from `state.detail` without refetching, so on a healthy view the fast
  // path's contribution is view PRESERVATION, not request suppression. The leg
  // that actually discriminates runs over a view whose state is NOT
  // re-derivable, and it is leg 7 below.
  //
  // Opening goes through the `?` binding as a REAL Chrome key event, not a
  // synthetic dispatch: the binding is a document-level keydown handler and a
  // JS-constructed event would prove only that the handler exists, not that the
  // browser routes the key to it.
  await navigateHash(client, sessionId, runHash, `document.querySelector('.detail-view') && !document.querySelector('.manual-pane') && !document.querySelector('.error-view')`, "toggle_precondition", options.browser_timeout_ms);
  const baselineFetches = await waitForFetchQuiescence(client, sessionId, "toggle_quiescence", options.browser_timeout_ms);
  const beforeToggle = await evaluate(client, sessionId, SNAPSHOT, "before_toggle_snapshot");
  if (beforeToggle.detailRunId !== options.run_id || beforeToggle.paneOpen) throw failure("toggle_precondition_unmet", "The no-refetch toggle did not start from a painted, pane-closed run detail", "manual_only_toggle_issues_no_authoritative_refetch", {before_toggle: beforeToggle});

  await client.send("Input.dispatchKeyEvent", {type: "keyDown", key: "?", code: "Slash", text: "?", windowsVirtualKeyCode: 191, modifiers: 8}, sessionId, "press_question_key");
  await client.send("Input.dispatchKeyEvent", {type: "keyUp", key: "?", code: "Slash", windowsVirtualKeyCode: 191, modifiers: 8}, sessionId, "release_question_key");
  await waitForBrowser(client, sessionId, `document.querySelector('.manual-pane') && document.querySelector('.detail-view')`, "manual_opens_over_painted_detail", options.browser_timeout_ms);
  const opened = await evaluate(client, sessionId, SNAPSHOT, "opened_snapshot");
  const openedOverDetail =
    paneIsNamed(opened) &&
    opened.paneTerm === "index" &&
    // The whole reason the manual is an overlay: the run the pane sits beside
    // is STILL PAINTED, by identity, not merely by view class.
    /\bdetail-view\b/.test(opened.viewClass || "") &&
    opened.detailRunId === options.run_id &&
    opened.detailTitle === beforeToggle.detailTitle &&
    !opened.errorView &&
    opened.unavailableClass === null &&
    opened.errorKind === null;
  if (!openedOverDetail) throw failure("manual_did_not_open_over_painted_view", "Opening the manual over a painted run detail did not leave that run painted beside the pane", "manual_only_toggle_issues_no_authoritative_refetch", {before_toggle: beforeToggle, opened});

  // ── 6. CLOSING through the pane's OWN control preserves the route ─────────
  //
  // The gauntlet already pins the Escape route out of the pane. This drives the
  // other affordance — the Close link the pane renders — and asserts the same
  // property from it: the underlying route comes back, by identity.
  const closeClicked = await evaluate(client, sessionId, `(() => { const node = document.querySelector('.manual-pane [data-focus-key="manual-close"]'); if (!node) return false; node.click(); return true; })()`, "click_manual_close");
  if (!closeClicked) throw failure("close_control_missing", "The manual pane rendered no Close control to drive", "close_control_preserves_underlying_route", {opened});
  await waitForBrowser(client, sessionId, `location.hash === ${JSON.stringify(runHash)} && !document.querySelector('.manual-pane') && document.querySelector('.detail-view')`, "close_control_preserves_underlying_route", options.browser_timeout_ms);
  const closed = await evaluate(client, sessionId, SNAPSHOT, "closed_snapshot");
  const closeHonest =
    !closed.paneOpen &&
    closed.hash === runHash &&
    closed.detailRunId === options.run_id &&
    closed.detailTitle === beforeToggle.detailTitle &&
    !closed.errorView &&
    closed.unavailableClass === null &&
    closed.errorKind === null;
  if (!closeHonest) throw failure("close_did_not_preserve_route", "Closing the manual through its own Close control did not preserve the underlying route", "close_control_preserves_underlying_route", {before_toggle: beforeToggle, closed});

  // The accounting. Sampled AFTER the close settles, so a refetch issued by
  // either half of the toggle is caught; the delta must be exactly zero.
  const settledFetches = await waitForFetchQuiescence(client, sessionId, "toggle_settle", options.browser_timeout_ms);
  const refetchDelta = settledFetches - baselineFetches;
  if (refetchDelta !== 0) throw failure("manual_toggle_refetched", "A manual-only open/close toggle over an already-painted view issued an authoritative projection request", "manual_only_toggle_issues_no_authoritative_refetch", {baseline_projection_fetches: baselineFetches, settled_projection_fetches: settledFetches, delta: refetchDelta});
  leg(legs, "manual_only_toggle_issues_no_authoritative_refetch", {baseline_projection_fetches: baselineFetches, settled_projection_fetches: settledFetches, projection_refetch_delta: refetchDelta, opened_over_run_id: opened.detailRunId, opened_focus_key: opened.focusKey});
  leg(legs, "close_control_preserves_underlying_route", {hash: closed.hash, view_class: closed.viewClass, detail_run_id: closed.detailRunId, pane_open: closed.paneOpen});

  // ── 7. The NO-REFETCH property where it is OBSERVABLE ─────────────────────
  //
  // The leg that bites. On a healthy view the ordinary path re-renders from
  // `state.detail` and issues nothing, so removing the manual fast path there
  // changes no request count. The property is only DISTINGUISHABLE over a view
  // that is not re-derivable from state — precisely the views the node:vm tier
  // names, where `state.detail` is null while the view stays painted.
  //
  // The route driven here is honest and reachable: a run id this workspace does
  // not contain. `/api/runs/<missing>` answers 404, the not-found dead end is
  // painted, and `state.detail` stays null under it. A manual-only delta there
  // must STILL be a pure re-render — the operator pressed `?` on a dead end and
  // must get the pane beside the same dead end, with its `not_found` taxonomy
  // and its copy intact and with nothing refetched.
  //
  // Deleting the fast path makes exactly this leg red: measured on this base,
  // the toggle then issues one authoritative request on open and another on
  // close. No fixture is tampered and no state is synthesized; the workspace is
  // the same one every other leg reads.
  const missingRunId = `${options.run_id}-absent`;
  const missingHash = `#/runs/${encodeURIComponent(missingRunId)}`;
  // The count of index acquisitions already recorded BEFORE this navigation. It
  // is the FLOOR the arrival reading below is compared against, never a demand
  // in its own right.
  const inventoryBefore = await evaluate(client, sessionId, `window.__pixirManualRouteHarness.fetches.filter(path => ${INVENTORY_PATH_PATTERN}.test(path)).length`, "dead_end_inventory_mark");
  // The arrival reading is taken IN THE SAME EVALUATION that first sees the
  // dead end attached — see waitForBrowser's `observe`. That atomicity is what
  // makes the number below an observation instead of a race.
  const deadEndArrival = await navigateHash(client, sessionId, missingHash, `document.querySelector('.error-view') && !document.querySelector('.manual-pane')`, "dead_end_precondition", options.browser_timeout_ms, `window.__pixirManualRouteHarness.fetches.filter(path => ${INVENTORY_PATH_PATTERN}.test(path)).length`);
  if (deadEndArrival.unavailableClass === null) throw failure("dead_end_precondition_unmet", "The absent-run route did not paint an unavailable view carrying its taxonomy", "no_refetch_over_unrederivable_view", {dead_end: deadEndArrival});

  // The 404 paint is NOT the settled dead end, and this is the leg where that
  // distinction decides the result. `renderProjectionFailure` fires the
  // parent-resolution inventory acquisition on a structured `run_not_found`
  // (app.js: `if (identityLoss && !heldInventoryRows(route).length)
  // acquireInventoryForResolution(route)`), and when it fires it repaints this
  // same dead end once the acquisition lands.
  //
  // The wait condition the navigation above uses — an error view with no pane —
  // is satisfied by the PAINT, which can happen while that acquisition is still
  // open. A baseline taken there is a coin flip decided by round-trip latency:
  // land the acquisition after the leg and the delta measures nothing at all,
  // land it between baseline and settle and the harness blames the manual
  // toggle for a request the app issued on its own.
  //
  // What removes the coin flip is an ORDERING FACT, not a prediction. The
  // acquisition decision is made SYNCHRONOUSLY inside renderProjectionFailure,
  // and every branch below it paints through replaceContent — so the request is
  // either issued or declined BEFORE the error view exists in the DOM. The
  // reading taken at the arrival instant is therefore the app's finished
  // decision, and the baseline simply waits for whatever it saw to settle.
  //
  // Demanding `inventoryBefore + 1` instead would be a PREDICTION, and a false
  // one: that same guard declines the acquisition outright when inventory is
  // already held for the routed scope, and acquireInventoryForResolution
  // short-circuits on a resolution already open or already spent for this id.
  // On any of those the demanded request never comes, the gate burns its whole
  // deadline, and the leg fails loudly blaming the app for a request it was
  // right not to make. An observation cannot be wrong that way: nothing issued
  // means nothing to wait for, and the ordering fact above is what licenses
  // reading "nothing issued" as final rather than as "not yet".
  //
  // The floor comparison keeps the observation honest in the other direction: a
  // reading that did not even reach `inventoryBefore` would mean the recorder
  // lost requests, and the accounting would be measuring a record it cannot
  // trust.
  const inventoryAtArrival = deadEndArrival.observed;
  if (!Number.isSafeInteger(inventoryAtArrival) || inventoryAtArrival < inventoryBefore) throw failure("dead_end_inventory_record_unusable", "The recorded inventory count went backwards across the dead-end navigation", "no_refetch_over_unrederivable_view", {inventory_before: inventoryBefore, inventory_at_arrival: inventoryAtArrival});

  // The reference snapshot is re-taken after quiescence for the same reason:
  // taken at arrival it could be a pre-acquisition observation, and the "came
  // back UNCHANGED" comparison below would be against a view the toggle never
  // started from.
  const deadEndBaseline = await waitForFetchQuiescence(client, sessionId, "dead_end_quiescence", options.browser_timeout_ms, {pattern: INVENTORY_PATH_PATTERN, count: inventoryAtArrival});
  const deadEnd = await evaluate(client, sessionId, SNAPSHOT, "dead_end_settled_snapshot");
  if (deadEnd.unavailableClass === null || !deadEnd.errorView || deadEnd.paneOpen || deadEnd.hash !== missingHash) throw failure("dead_end_precondition_unmet", "The absent-run route did not settle on an unavailable view carrying its taxonomy", "no_refetch_over_unrederivable_view", {dead_end_arrival: deadEndArrival, dead_end: deadEnd});

  await client.send("Input.dispatchKeyEvent", {type: "keyDown", key: "?", code: "Slash", text: "?", windowsVirtualKeyCode: 191, modifiers: 8}, sessionId, "press_question_key_dead_end");
  await client.send("Input.dispatchKeyEvent", {type: "keyUp", key: "?", code: "Slash", windowsVirtualKeyCode: 191, modifiers: 8}, sessionId, "release_question_key_dead_end");
  await waitForBrowser(client, sessionId, `document.querySelector('.manual-pane') && document.querySelector('.error-view')`, "manual_opens_over_dead_end", options.browser_timeout_ms);
  const deadEndOpened = await evaluate(client, sessionId, SNAPSHOT, "dead_end_opened_snapshot");

  const deadEndCloseClicked = await evaluate(client, sessionId, `(() => { const node = document.querySelector('.manual-pane [data-focus-key="manual-close"]'); if (!node) return false; node.click(); return true; })()`, "click_manual_close_dead_end");
  if (!deadEndCloseClicked) throw failure("close_control_missing", "The manual pane rendered no Close control over the dead end", "no_refetch_over_unrederivable_view", {dead_end_opened: deadEndOpened});
  await waitForBrowser(client, sessionId, `location.hash === ${JSON.stringify(missingHash)} && !document.querySelector('.manual-pane') && document.querySelector('.error-view')`, "dead_end_close", options.browser_timeout_ms);
  const deadEndClosed = await evaluate(client, sessionId, SNAPSHOT, "dead_end_closed_snapshot");
  const deadEndSettled = await waitForFetchQuiescence(client, sessionId, "dead_end_settle", options.browser_timeout_ms);
  const deadEndDelta = deadEndSettled - deadEndBaseline;

  // The dead end must come back UNCHANGED, not merely be an error view again:
  // re-deriving one unavailable class as another is a silent relabelling of what
  // the operator is being told.
  const deadEndPreserved =
    paneIsNamed(deadEndOpened) &&
    deadEndOpened.unavailableClass === deadEnd.unavailableClass &&
    deadEndClosed.unavailableClass === deadEnd.unavailableClass &&
    deadEndClosed.viewClass === deadEnd.viewClass &&
    !deadEndClosed.paneOpen &&
    deadEndClosed.hash === missingHash;
  if (!deadEndPreserved) throw failure("dead_end_not_preserved", "The manual overlay move did not reproduce the unavailable view it opened over", "no_refetch_over_unrederivable_view", {dead_end: deadEnd, dead_end_opened: deadEndOpened, dead_end_closed: deadEndClosed});
  if (deadEndDelta !== 0) throw failure("manual_toggle_refetched", "A manual-only open/close toggle over a view that is not re-derivable from state issued an authoritative projection request", "no_refetch_over_unrederivable_view", {baseline_projection_fetches: deadEndBaseline, settled_projection_fetches: deadEndSettled, delta: deadEndDelta});
  // `resolution_acquisitions_observed` is the app's OWN decision, recorded rather
  // than predicted: how many parent-resolution acquisitions this dead end had
  // already issued at the instant its view was attached. On this base and this
  // fixture it is 1 — the route change nulled the held list on the way in, so
  // the app owed the acquisition and made it. It is reported instead of asserted
  // inside the harness because the harness must not require a number the app
  // never promised: a base where the inventory is already held would record 0
  // and still be a correct dead end. The driver pins what this base actually
  // does, and a change in that number is then a visible evidence change rather
  // than a silent one or a 60-second false red.
  leg(legs, "no_refetch_over_unrederivable_view", {unavailable_class: deadEnd.unavailableClass, reference_taken_after_quiescence: true, resolution_acquisitions_observed: inventoryAtArrival - inventoryBefore, baseline_projection_fetches: deadEndBaseline, settled_projection_fetches: deadEndSettled, projection_refetch_delta: deadEndDelta, view_class: deadEndClosed.viewClass, hash: deadEndClosed.hash});

  // ── 8. The DOTTED LABEL, existence-guarded ────────────────────────────────
  //
  // T5's labels are INTEGRATED: `data-manual-term="<slug>"` ships on every
  // dotted label, so the driver now REQUIRES this leg to report `exercised` —
  // a `not_present` here means the labels regressed, and the driver fails on
  // it. The harness still records rather than throws (the driver owns the
  // verdict), and the decision stays a real DOM existence check, not a flag
  // the driver could set, so the leg cannot be silently disabled.
  //
  // Probed on the run DETAIL, not on the dead end this story last visited:
  // dotted labels annotate PROJECTED VALUES, and a dead end has none to
  // annotate, so probing there would report `not_present` forever and the leg
  // would stay dormant even after T5 lands.
  await navigateHash(client, sessionId, runHash, `document.querySelector('.detail-view') && !document.querySelector('.manual-pane') && !document.querySelector('.error-view')`, "dotted_label_precondition", options.browser_timeout_ms);
  const dotted = await evaluate(client, sessionId, `(() => {
    const node = document.querySelector('[data-manual-term]');
    if (!node) return {present: false, count: document.querySelectorAll('[data-manual-term]').length};
    const slug = node.dataset.manualTerm;
    node.click();
    return {present: true, slug, count: document.querySelectorAll('[data-manual-term]').length};
  })()`, "dotted_label_probe");
  if (dotted.present) {
    await waitForBrowser(client, sessionId, `document.querySelector('.manual-pane[data-manual=${JSON.stringify(dotted.slug)}]')`, "dotted_label_opens_its_term", options.browser_timeout_ms);
    const dottedOpened = await evaluate(client, sessionId, SNAPSHOT, "dotted_label_snapshot");
    if (!paneIsNamed(dottedOpened) || dottedOpened.paneTerm !== dotted.slug || dottedOpened.errorView) throw failure("dotted_label_did_not_open_term", "A dotted label did not open the manual on its own term", "dotted_label_opens_its_term", {dotted, dotted_opened: dottedOpened});
    leg(legs, "dotted_label_opens_its_term", {status: "exercised", slug: dotted.slug, labels_present: dotted.count, pane_term: dottedOpened.paneTerm});
  } else {
    leg(legs, "dotted_label_opens_its_term", {status: "not_present", labels_present: 0});
  }

  if (consoleErrors.length) throw failure("browser_console_error", "The browser reported a runtime or console error during the manual route sweep", "console_errors", {count: consoleErrors.length, first: consoleErrors[0]});
  return {legs, projectionFetchTotal: deadEndSettled, indexTermCount: unknown.indexTermLinks};
}

async function run(options) {
  const profile = await mkdtemp(join(options.profile_base, "pixir-monitor-manual-route-"));
  let browser = null;
  let monitor = null;
  let client = null;
  let browserContextId = null;
  let fifoPath = null;
  let result = null;
  let runError = null;
  try {
    browser = spawn(options.browser, ["--headless=new", "--disable-background-networking", "--disable-component-update", "--disable-default-apps", "--disable-sync", "--metrics-recording-only", "--no-first-run", "--no-default-browser-check", "--remote-debugging-port=0", ...extraBrowserArgs(), `--user-data-dir=${profile}`, "about:blank"], {stdio: ["ignore", "ignore", "pipe"]});
    const browserSpawnFailed = new Promise((_resolve, reject) => browser.on("error", error => reject(failure("browser_spawn_failed", `Browser process could not be spawned: ${error.code || error.message}`, "launch_browser"))));
    browserSpawnFailed.catch(() => {});
    client = await connectDevTools(await Promise.race([waitForDevTools(browser.stderr), browserSpawnFailed]));
    browserContextId = (await client.send("Target.createBrowserContext", {disposeOnDetach: true}, null, "create_browser_context")).browserContextId;

    monitor = spawn(options.monitor, ["serve", "--workspace", options.workspace, "--launch-mode", "fifo", "--json"], {stdio: ["ignore", "pipe", "pipe"]});
    const monitorSpawnFailed = new Promise((_resolve, reject) => monitor.on("error", error => reject(failure("monitor_spawn_failed", `Monitor process could not be spawned: ${error.code || error.message}`, "start_monitor"))));
    monitorSpawnFailed.catch(() => {});
    const serving = waitForJsonLine(monitor.stdout, value => value?.ok === true && value?.status === "serving", "monitor_serving", 60_000);
    serving.catch(() => {});
    const readiness = await Promise.race([waitForJsonLine(monitor.stderr, value => value?.ok === true && value?.status === "ready" && value?.launch_mode === "fifo", "monitor_readiness", 45_000), monitorSpawnFailed]);
    fifoPath = readiness.fifo_path;
    // The launch capability is read from the one-use FIFO and dropped from this
    // process's own reachable state as soon as it is parsed; it never appears in
    // argv, in an env var, or in the evidence record.
    let launchUrl = (await withTimeout(readFile(fifoPath, "utf8"), 15_000, "fifo_reader_timeout", "Monitor did not issue browser handoff", "read_handoff")).trim();
    const launchUri = new URL(launchUrl);
    launchUrl = "";

    const target = await client.send("Target.createTarget", {url: "about:blank", browserContextId}, null, "create_page");
    const sessionId = (await client.send("Target.attachToTarget", {targetId: target.targetId, flatten: true}, null, "attach_target")).sessionId;
    const consoleErrors = [];
    client.onEvent(message => {
      if (message.sessionId !== sessionId) return;
      // Runtime exceptions always count. Console entries count only at error
      // level: Chrome emits benign warnings (Permissions-Policy and friends) on
      // every navigation and those are not a route-family regression.
      if (message.method === "Runtime.exceptionThrown") consoleErrors.push({kind: "runtime_exception", text: message.params?.exceptionDetails?.text || "exception"});
      if (message.method === "Runtime.consoleAPICalled" && ["error", "assert"].includes(message.params?.type)) consoleErrors.push({kind: "console", type: message.params.type});
    });
    await client.send("Runtime.enable", {}, sessionId, "enable_runtime");
    await client.send("Page.enable", {}, sessionId, "enable_page");
    await client.send("Page.addScriptToEvaluateOnNewDocument", {source: PRELOAD_SCRIPT}, sessionId, "install_fetch_recorder");
    await client.send("Page.navigate", {url: launchUri.href}, sessionId, "bootstrap_navigation");

    const story = await manualRouteStory(client, sessionId, options, consoleErrors);
    await Promise.race([serving, monitorSpawnFailed]);

    const launchFragmentCleared = await evaluate(client, sessionId, `!location.hash.startsWith("#launch=")`, "launch_fragment_cleared");
    const handoffCleaned = !existsSync(fifoPath) && !existsSync(dirname(fifoPath));
    if (!handoffCleaned) throw failure("handoff_cleanup_failed", "The one-use FIFO handoff was not removed", "verify_cleanup");
    if (!launchFragmentCleared) throw failure("launch_fragment_not_cleared", "Launch capability remained in the browser fragment", "verify_launch_fragment");
    const legNames = story.legs.map(entry => entry.name);
    if (JSON.stringify(legNames) !== JSON.stringify(LEGS)) throw failure("leg_order_mismatch", "The completed manual route legs do not match the expected order", "verify_cleanup", {completed: legNames});

    result = {
      ok: true,
      check: "pixir_monitor_manual_route",
      legs: story.legs,
      leg_names: legNames,
      projection_fetch_total: story.projectionFetchTotal,
      index_term_count: story.indexTermCount,
      console_errors: consoleErrors.length,
      launch_fragment_cleared: launchFragmentCleared === true,
      handoff_cleaned: handoffCleaned
    };
    return result;
  } catch (error) {
    runError = error;
    throw error;
  } finally {
    if (client) {
      if (browserContextId) { try { await client.send("Target.disposeBrowserContext", {browserContextId}, null, "dispose_browser_context"); } catch (_error) {} }
      try { await client.send("Browser.close", {}, null, "close_browser"); } catch (_error) {}
      client.close();
    }
    const browserStopped = await stopChild(browser);
    const monitorStopped = await stopChild(monitor);
    await rm(profile, {recursive: true, force: true});
    const cleanup = {browser_stopped: browserStopped, monitor_stopped: monitorStopped, profile_removed: !existsSync(profile)};
    if (runError) runError.safeDetails = {...(runError.safeDetails || {}), cleanup};
    else if (result) result.cleanup = cleanup;
  }
}

let exitCode = 0;
let output;
try {
  const options = parseArgs(process.argv.slice(2));
  validate(options);
  output = await run(options);
} catch (error) {
  exitCode = 1;
  output = safeError(error);
}
process.stdout.write(`${JSON.stringify(output)}\n`);
process.exitCode = exitCode;
