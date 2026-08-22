#!/usr/bin/env node

// Executes the frozen window.PixirMonitorUI seam of app.js in node:vm, with a
// FAIL-CLOSED stub environment: any load-time touch outside the declared stub
// surface throws (stub drift becomes a red check, never silent absorption).
// The bootstrap promise never resolves, so loading app.js performs no fetch,
// opens no EventSource, and renders nothing. No Chrome, no npm.

import {readFileSync} from "node:fs";
import process from "node:process";
import vm from "node:vm";

function failure(kind, message, stage, details = {}) {
  const error = new Error(message);
  error.harnessKind = kind;
  error.harnessStage = stage;
  error.safeDetails = details;
  return error;
}

function safeError(error) {
  return {ok: false, error: {kind: error?.harnessKind || "ui_seam_check_failed", message: error?.harnessKind ? error.message : `The UI seam check failed unexpectedly: ${error?.message}`, details: {stage: error?.harnessStage || "unknown", ...(error?.safeDetails || {})}}};
}

function parseArgs(argv) {
  const options = {};
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === "--json") continue;
    if (["--app"].includes(arg)) options[arg.slice(2)] = argv[++index];
    else throw failure("invalid_args", "Unknown UI seam check argument", "parse_args");
  }
  if (!options.app) throw failure("missing_required_arg", "Missing required --app", "validate_args");
  return options;
}

// ── Fail-closed stub environment ─────────────────────────────────────────────

const TOLERATED_PROPS = new Set(["then", "toJSON", "constructor", "valueOf", "toString", "nodeType"]);

// Null-prototype targets so Object.prototype members cannot satisfy lookups,
// plus set/has/defineProperty traps: a load-time WRITE outside the allowlist
// is drift too, not just an unexpected read.
function failClosed(name, target, writable = []) {
  const bare = Object.assign(Object.create(null), target);
  const writeAllowlist = new Set(writable);
  return new Proxy(bare, {
    get(object, prop) {
      if (typeof prop === "string" && Object.prototype.hasOwnProperty.call(object, prop)) return object[prop];
      if (typeof prop === "symbol" || TOLERATED_PROPS.has(prop)) return undefined;
      throw failure("stub_drift", `app.js touched an unstubbed surface at load: ${name}.${String(prop)}`, "load_app");
    },
    has(object, prop) {
      return typeof prop === "string" && Object.prototype.hasOwnProperty.call(object, prop);
    },
    set(object, prop, value) {
      if (writeAllowlist.has(prop)) { object[prop] = value; return true; }
      throw failure("stub_drift", `app.js WROTE an unstubbed surface at load: ${name}.${String(prop)}`, "load_app");
    },
    defineProperty(object, prop, descriptor) {
      if (writeAllowlist.has(prop)) { Object.defineProperty(object, prop, descriptor); return true; }
      throw failure("stub_drift", `app.js defined an unstubbed surface at load: ${name}.${String(prop)}`, "load_app");
    },
    deleteProperty(_object, prop) {
      throw failure("stub_drift", `app.js deleted a stub surface at load: ${name}.${String(prop)}`, "load_app");
    }
  });
}

function inertNode(name) {
  return failClosed(name, {textContent: "", setAttribute() {}, classList: {add() {}}});
}

function buildSandbox(workspaceSetConfig) {
  const shellAttributes = new Map();
  if (workspaceSetConfig) shellAttributes.set("data-workspace-set", JSON.stringify(workspaceSetConfig));
  const shell = failClosed("shell", {
    hasAttribute: (name) => shellAttributes.has(name),
    getAttribute: (name) => (shellAttributes.has(name) ? shellAttributes.get(name) : null)
  });
  const documentStub = failClosed("document", {
    getElementById: (id) => inertNode(`document.getElementById(${id})`),
    querySelector: (selector) => {
      if (selector === "body > main") return shell;
      throw failure("stub_drift", `app.js queried an unstubbed selector at load: ${selector}`, "load_app");
    },
    addEventListener() {}
  });
  const windowStub = failClosed("window", {
    addEventListener() {},
    __pixirBootstrap: new Promise(() => {})
  }, ["PixirMonitorUI"]);
  const sandbox = {
    window: windowStub,
    document: documentStub,
    // `hash` is WRITABLE so the check can put the seam on a route the operator
    // is actually standing on. routeHash reads it to resolve a partial route
    // literal's absent manual field, and that inheritance is a property the
    // check has to be able to drive. app.js never writes location.hash at LOAD,
    // so the fail-closed guarantee for the load phase is unchanged.
    location: failClosed("location", {hash: ""}, ["hash"]),
    history: failClosed("history", {}),
    URLSearchParams,
    Set,
    Map,
    Object,
    Array,
    Number,
    String,
    JSON,
    Math,
    Date,
    RegExp,
    Error,
    Promise,
    console: failClosed("console", {})
  };
  sandbox.globalThis = sandbox;
  return sandbox;
}

// The seam is frozen, so the location stub each seam was loaded against is kept
// beside it rather than hung off it. The partial-literal check needs to move the
// ambient hash; a tampered seam (the red proofs build those by spreading) is
// simply absent from the map, and the check skips the ambient leg for it.
const SEAM_LOCATIONS = new WeakMap();

function loadSeam(appSource, workspaceSetConfig) {
  const sandbox = buildSandbox(workspaceSetConfig);
  vm.createContext(sandbox);
  vm.runInContext(appSource, sandbox, {filename: "app.js"});
  const seam = sandbox.window.PixirMonitorUI;
  if (!seam || typeof seam.parseRoute !== "function" || typeof seam.routeHash !== "function" || typeof seam.visible !== "function" || typeof seam.runsComparator !== "function" || typeof seam.resolveParentObservedChild !== "function" || typeof seam.glossaryEntries !== "function" || typeof seam.glossaryBySlug !== "function" || typeof seam.glossaryConcerns !== "function" || typeof seam.manualField !== "function" || typeof seam.manualRoute !== "function" || typeof seam.manualUnderlyingKey !== "function" || !Array.isArray(seam.manualRunValueSlugs) || !Array.isArray(seam.manualNoRunValueSlugs)) {
    throw failure("seam_missing", "window.PixirMonitorUI did not expose the expected frozen members", "load_app");
  }
  SEAM_LOCATIONS.set(seam, sandbox.location);
  return seam;
}

// ── Deterministic generator (no Math.random: seeded, reproducible) ──────────

function mulberry32(seed) {
  let a = seed >>> 0;
  return function () {
    a |= 0; a = (a + 0x6d2b79f5) | 0;
    let t = Math.imul(a ^ (a >>> 15), 1 | a);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

function pick(rand, values) { return values[Math.floor(rand() * values.length)]; }

// The frozen FILTER_VOCABULARIES verbatim (app.js:5-11), plus one deliberate
// out-of-vocabulary value per family: parseRoute must DROP those, and the
// idempotence property below holds after the first canonicalization pass.
const FILTERS = {
  strategy: ["workflow", "subagents", "unknown", "bogus_strategy"],
  execution: ["planned", "queued", "running", "completed", "partial", "failed", "timed_out", "cancelled", "detached", "closed", "held", "unknown", "bogus_execution"],
  liveness: ["unobserved", "not_applicable", "bogus_liveness"],
  source: ["live", "reconstructed", "mixed", "bogus_source"],
  attention: ["yes", "no", "bogus_attention"]
};
const SORTS = ["recency_desc", "recency_asc", "duration_desc", "duration_asc"];
const QUERIES = ["", "gate", "ünïcode 🎉 search", "a=b&c#d", "x".repeat(300)];
const IDS = ["20260715T000000-a1b2c3", "run with spaces", "wave:0:bucket:0", "workflow:zoom:step:α/β?γ"];
// The manual overlay is an ORTHOGONAL route field, so it is generated across
// every route family rather than as a family of its own. "index" is the
// pane-open-at-its-index sentinel; the off-shape values must all normalize TO
// that sentinel (an unknown term opens the index, it never yields an
// unavailable view and never survives verbatim into the hash).
const MANUALS = [null, "liveness", "dependency-gate", "run-not-found", "index", "NOT A SLUG", "../escape", "z".repeat(200)];
const MANUAL_OFF_SHAPE = new Set(["NOT A SLUG", "../escape", "z".repeat(200)]);

function generateRoute(rand, mode, workspaces) {
  // In set mode the workspace OVERVIEW is a route family of its own: it names no
  // workspace and has no runs path, so a serializer that only knows how to build
  // "#/workspaces/<ws>/runs" would navigate off it. Generating it here is what
  // makes the manual-overlay loop below prove the pane is orthogonal to the
  // overview too, not only to runs/detail/unit.
  const view = mode === "set" ? pick(rand, ["runs", "detail", "unit", "workspaces"]) : pick(rand, ["runs", "detail", "unit"]);
  if (view === "workspaces") return {view, filters: {}, sort: pick(rand, [...SORTS, undefined]), q: pick(rand, QUERIES), follow: false, manual: pick(rand, MANUALS)};
  const route = {view, filters: {}, sort: pick(rand, [...SORTS, undefined]), q: pick(rand, QUERIES), follow: rand() < 0.3, manual: pick(rand, MANUALS)};
  for (const name of Object.keys(FILTERS)) if (rand() < 0.4) route.filters[name] = pick(rand, FILTERS[name]);
  if (view !== "runs") route.runId = pick(rand, IDS);
  if (view === "unit") { route.unitId = pick(rand, IDS); if (rand() < 0.4) route.attemptId = "attempt:" + Math.floor(rand() * 9); }
  if (route.runId) {
    if (rand() < 0.4) route.zoomStart = Math.floor(rand() * 12);
    if (rand() < 0.3) route.selectedCluster = "wave:0:bucket:" + Math.floor(rand() * 3);
    if (rand() < 0.2) route.selectedArc = "arc:wave:0:wave:1";
    if (rand() < 0.3) route.memberPage = 1 + Math.floor(rand() * 4);
    if (rand() < 0.2) route.edgePage = 1 + Math.floor(rand() * 4);
  }
  if (mode === "set") route.workspace = pick(rand, workspaces);
  return route;
}

// ── Checks ───────────────────────────────────────────────────────────────────

function checkRoundTrip(seam, mode, workspaces) {
  const rand = mulberry32(mode === "set" ? 0x5e7 : 0x517);
  let cases = 0;
  // Per-family coverage counters: the 500-case total is only honest if every
  // claimed route-grammar family was actually generated and parsed.
  const coverage = {view_runs: 0, view_detail: 0, view_unit: 0, ...(mode === "set" ? {view_workspaces: 0} : {}), with_attempt: 0, with_zoom: 0, with_arc: 0, with_member_page: 0, with_edge_page: 0, bogus_filter_dropped: 0, with_manual_term: 0, with_manual_index: 0, manual_off_shape_normalized: 0, without_manual: 0};
  for (let index = 0; index < 500; index += 1) {
    const route = generateRoute(rand, mode, workspaces);
    // routeHash trusts pre-validated input, so raw generated routes (which may
    // carry out-of-vocabulary filters on purpose) get ONE canonicalization
    // pass through parseRoute first; from then on the round-trip must be a
    // fixed point AND every canonical field must survive it FIELD-WISE — a
    // regression that drops zoom/follow/attempt after parse cannot hide
    // behind hash equality of a shrunken route.
    const canonical = seam.parseRoute(seam.routeHash(route));
    const hash1 = seam.routeHash(canonical);
    const parsed = seam.parseRoute(hash1);
    const hash2 = seam.routeHash(parsed);
    if (hash1 !== hash2) throw failure("roundtrip_not_idempotent", "routeHash(parseRoute(hash)) diverged from its canonical fixed point", `roundtrip_${mode}`, {index, route, hash1, hash2});
    for (const fieldName of ["view", "runId", "unitId", "attemptId", "workspace", "sort", "q", "follow", "zoomStart", "selectedCluster", "selectedArc", "memberPage", "edgePage", "manual"]) {
      if (JSON.stringify(parsed[fieldName] ?? null) !== JSON.stringify(canonical[fieldName] ?? null)) throw failure("roundtrip_field_lost", `The canonical field ${fieldName} did not survive the hash round-trip`, `roundtrip_${mode}`, {index, fieldName, canonical_value: canonical[fieldName] ?? null, parsed_value: parsed[fieldName] ?? null});
    }
    for (const name of Object.keys(FILTERS)) {
      if (JSON.stringify(parsed.filters[name] ?? null) !== JSON.stringify(canonical.filters[name] ?? null)) throw failure("roundtrip_filter_lost", `The canonical filter ${name} did not survive the hash round-trip`, `roundtrip_${mode}`, {index, name});
    }
    if (route.runId && parsed.runId !== route.runId) throw failure("roundtrip_lost_run", "The run id did not survive the hash round-trip", `roundtrip_${mode}`, {index, route, parsed_run: parsed.runId});
    if (route.unitId && parsed.unitId !== route.unitId) throw failure("roundtrip_lost_unit", "The unit id did not survive the hash round-trip", `roundtrip_${mode}`, {index, route, parsed_unit: parsed.unitId});
    if (mode === "set" && parsed.view !== "workspaces" && parsed.workspace !== route.workspace) throw failure("roundtrip_lost_workspace", "The workspace did not survive the hash round-trip", `roundtrip_${mode}`, {index, route, parsed_workspace: parsed.workspace});
    for (const name of Object.keys(FILTERS)) {
      if (route.filters[name] && route.filters[name].startsWith("bogus_")) {
        if (parsed.filters[name]) throw failure("invalid_filter_survived", "An out-of-vocabulary filter survived canonicalization", `roundtrip_${mode}`, {index, name, value: parsed.filters[name]});
        coverage.bogus_filter_dropped += 1;
      }
    }
    // MANUAL AS AN OVERLAY, not a sibling view: the pane never changes the view
    // it rides on, and closing it returns EXACTLY the route that was underneath.
    // A regression that made the manual a fifth `view` value, or that dropped a
    // param while serializing it, dies right here.
    const opened = seam.parseRoute(seam.routeHash({...canonical, manual: "liveness"}));
    const closed = seam.parseRoute(seam.routeHash({...canonical, manual: null}));
    if (opened.manual !== "liveness") throw failure("manual_not_carried", "The manual field did not survive being set on an existing route", `roundtrip_${mode}`, {index, opened_manual: opened.manual ?? null});
    if (closed.manual ?? null) throw failure("manual_not_clearable", "Clearing the manual field left it set", `roundtrip_${mode}`, {index, closed_manual: closed.manual ?? null});
    for (const fieldName of ["view", "runId", "unitId", "attemptId", "workspace", "sort", "q", "follow", "zoomStart", "selectedCluster", "selectedArc", "memberPage", "edgePage"]) {
      if (JSON.stringify(opened[fieldName] ?? null) !== JSON.stringify(canonical[fieldName] ?? null)) throw failure("manual_overlay_replaced_view", `Opening the manual changed the underlying route field ${fieldName}`, `roundtrip_${mode}`, {index, fieldName, before: canonical[fieldName] ?? null, after: opened[fieldName] ?? null});
    }
    if (seam.routeHash(closed) !== seam.routeHash({...canonical, manual: null})) throw failure("manual_close_not_underlying", "Closing the manual did not return the underlying canonical route", `roundtrip_${mode}`, {index});
    coverage[`view_${route.view}`] += 1;
    if (route.manual === null) coverage.without_manual += 1;
    else if (route.manual === "index") coverage.with_manual_index += 1;
    else if (MANUAL_OFF_SHAPE.has(route.manual)) {
      if (parsed.manual !== "index") throw failure("manual_off_shape_survived", "An off-shape manual slug did not normalize to the index sentinel", `roundtrip_${mode}`, {index, requested: route.manual, parsed_manual: parsed.manual ?? null});
      coverage.manual_off_shape_normalized += 1;
    } else coverage.with_manual_term += 1;
    if (route.attemptId) coverage.with_attempt += 1;
    if (route.zoomStart > 0) coverage.with_zoom += 1;
    if (route.selectedArc) coverage.with_arc += 1;
    if (route.memberPage > 1) coverage.with_member_page += 1;
    if (route.edgePage > 1) coverage.with_edge_page += 1;
    cases += 1;
  }
  // Hand cases against the documented canonicalization contract, on
  // MODE-CORRECT route shapes (a "#/runs" URL in set mode demotes to the
  // workspaces view and would exercise nothing).
  const runsBase = mode === "set" ? `#/workspaces/${workspaces[0]}/runs` : "#/runs";
  let handCases = 0;
  const base = seam.parseRoute(runsBase + "?sort=recency_desc");
  if (base.view !== "runs" || seam.routeHash(base).includes("sort=")) throw failure("default_sort_serialized", "The default sort must stay out of the hash", `roundtrip_${mode}`, {parsed_view: base.view});
  handCases += 1;
  const badFilter = seam.parseRoute(runsBase + "?strategy=nonsense");
  if (badFilter.view !== "runs" || badFilter.filters.strategy) throw failure("invalid_filter_kept", "An out-of-vocabulary filter survived parseRoute", `roundtrip_${mode}`);
  handCases += 1;
  const longQ = seam.parseRoute(runsBase + "?q=" + encodeURIComponent("q".repeat(300)));
  if (Array.from(longQ.q).length !== 256) throw failure("query_unbounded", "The search query was not bounded to LIMITS.query code points", `roundtrip_${mode}`, {length: Array.from(longQ.q).length});
  handCases += 1;
  const followNoRun = seam.routeHash({view: "runs", filters: {}, sort: "recency_desc", q: "", follow: true, ...(mode === "set" ? {workspace: workspaces[0]} : {})});
  if (followNoRun.includes("follow=")) throw failure("follow_without_run", "follow serialized on a run-less route", `roundtrip_${mode}`);
  handCases += 1;
  const badEncoding = seam.parseRoute(runsBase + "/%zz");
  if (badEncoding.view !== "invalid") throw failure("bad_encoding_not_invalid", "A malformed percent-encoded segment did not parse to the invalid view", `roundtrip_${mode}`, {parsed_view: badEncoding.view});
  handCases += 1;
  // ── The #manual deep link ──────────────────────────────────────────────────
  //
  // `#manual/<slug>` is the identity pasted into an issue: it must be a
  // STANDALONE entry point that lands on the default view with the pane open.
  // The interception has to happen ahead of BOTH the workspace-set branch and
  // the runs fallthrough, so these cases run in both modes.
  const defaultView = mode === "set" ? "workspaces" : "runs";
  const deepLink = seam.parseRoute("#manual/liveness");
  if (deepLink.view !== defaultView) throw failure("manual_deep_link_wrong_view", "The manual deep link did not resolve to the default view", `roundtrip_${mode}`, {parsed_view: deepLink.view, expected: defaultView});
  if (deepLink.manual !== "liveness") throw failure("manual_deep_link_lost_slug", "The manual deep link did not carry its slug onto the route", `roundtrip_${mode}`, {parsed_manual: deepLink.manual ?? null});
  handCases += 1;
  const bareManual = seam.parseRoute("#manual");
  if (bareManual.view !== defaultView || bareManual.manual !== "index") throw failure("bare_manual_not_index", "A bare #manual did not open the pane at its index", `roundtrip_${mode}`, {parsed_view: bareManual.view, parsed_manual: bareManual.manual ?? null});
  handCases += 1;
  // An UNKNOWN-SHAPED slug lands on the index. It must never produce the
  // invalid view, and it must never leave the pane closed.
  for (const hostile of ["#manual/NOT A SLUG", "#manual/" + "z".repeat(400), "#manual/%zz"]) {
    const landed = seam.parseRoute(hostile);
    if (landed.view === "invalid") throw failure("manual_unknown_slug_unavailable", "An unknown manual slug resolved to an unavailable view", `roundtrip_${mode}`, {hostile, parsed_view: landed.view});
    if ((landed.manual ?? null) === null) throw failure("manual_unknown_slug_closed", "An unknown manual slug left the pane closed", `roundtrip_${mode}`, {hostile});
    handCases += 1;
  }
  // The deep link canonicalizes onto the ordinary route grammar in ONE pass and
  // is a fixed point from then on — that is what keeps it linkable and what
  // keeps the round-trip property above honest for manual routes.
  const deepOnce = seam.routeHash(seam.parseRoute("#manual/liveness"));
  const deepTwice = seam.routeHash(seam.parseRoute(deepOnce));
  if (deepOnce !== deepTwice) throw failure("manual_deep_link_not_stable", "The manual deep link did not stabilize after one canonicalization", `roundtrip_${mode}`, {once: deepOnce, twice: deepTwice});
  if (!deepOnce.includes("manual=liveness")) throw failure("manual_not_serialized", "The manual field was not serialized into the canonical hash", `roundtrip_${mode}`, {once: deepOnce});
  handCases += 1;
  // ── PARTIAL route literals keep the pane ───────────────────────────────────
  //
  // Every manual assertion above spreads the WHOLE canonical route, which is
  // what only semanticZoomRoute does in the app. The great majority of in-view
  // controls — filters, sort, Clear filters, Search, Clear search, run-row
  // links, matched-unit links, attempt nav, dropped-parent links, workspace
  // links, Return to Runs — build a fresh PARTIAL literal naming only the fields
  // that navigation changes. They never mention the manual, and reading that
  // absence as "close the pane" made the overlay silently vanish on most exits
  // while surviving the zoom exits: two contradictory behaviours on one screen,
  // and a direct contradiction of routeHash's own orthogonality contract. The
  // partial literal must INHERIT the pane state of the route it is navigating
  // from; only an EXPLICIT manual value (including null) may change it.
  const seamLocation = SEAM_LOCATIONS.get(seam);
  if (seamLocation) {
    const originalHash = seamLocation.hash;
    try {
      const standingOn = mode === "set" ? "#/workspaces/left/runs?manual=liveness" : "#/runs?manual=liveness";
      seamLocation.hash = standingOn;
      const partials = mode === "set"
        ? [
          {view: "runs", workspace: "left", filters: {}, sort: "recent", q: "gate"},
          {workspace: "left", runId: "20260715T000000-a1b2c3", filters: {}, sort: "recent", q: ""},
          {workspace: "left", view: "runs"}
        ]
        : [
          {view: "runs", filters: {}, sort: "recent", q: "gate"},
          {runId: "20260715T000000-a1b2c3", filters: {}, sort: "recent", q: ""},
          {view: "runs"}
        ];
      for (const partial of partials) {
        const landed = seam.parseRoute(seam.routeHash(partial));
        if (landed.manual !== "liveness") throw failure("manual_dropped_by_partial_route", "A partial route literal that never mentions the manual silently closed the pane: the overlay is not orthogonal to navigation", `roundtrip_${mode}`, {partial: JSON.stringify(partial), standing_on: standingOn, landed_manual: landed.manual ?? null, landed_hash: seam.routeHash(partial)});
        handCases += 1;
      }
      // The other half of the contract: an EXPLICIT value still decides. A
      // partial literal that inherits everything would make the Close link
      // unable to close the pane, which is a worse defect than the one above.
      for (const partial of partials) {
        const closed = seam.parseRoute(seam.routeHash({...partial, manual: null}));
        if ((closed.manual ?? null) !== null) throw failure("manual_not_closable_from_partial", "An explicit null manual on a partial route literal did not close the pane", `roundtrip_${mode}`, {partial: JSON.stringify(partial), standing_on: standingOn, landed_manual: closed.manual ?? null});
        const opened = seam.parseRoute(seam.routeHash({...partial, manual: "dependency-gate"}));
        if (opened.manual !== "dependency-gate") throw failure("manual_not_settable_from_partial", "An explicit manual slug on a partial route literal did not reach the hash", `roundtrip_${mode}`, {partial: JSON.stringify(partial), landed_manual: opened.manual ?? null});
        handCases += 1;
      }
      // And with the pane CLOSED underfoot, a partial literal must not invent
      // one. Inheritance is symmetric or it is a fabrication.
      seamLocation.hash = mode === "set" ? "#/workspaces/left/runs" : "#/runs";
      for (const partial of partials) {
        const landed = seam.parseRoute(seam.routeHash(partial));
        if ((landed.manual ?? null) !== null) throw failure("manual_invented_by_partial_route", "A partial route literal opened the manual pane over a route that had none", `roundtrip_${mode}`, {partial: JSON.stringify(partial), landed_manual: landed.manual ?? null});
        handCases += 1;
      }
    } finally {
      seamLocation.hash = originalHash;
    }
  }
  // The exported helpers the browser harness drives.
  if (typeof seam.manualField !== "function" || typeof seam.manualRoute !== "function" || seam.manualIndexSlug !== "index") throw failure("manual_seam_missing", "The manual parse/serialize helpers are not on the exported seam", `roundtrip_${mode}`, {manual_index_slug: seam.manualIndexSlug ?? null});
  if (seam.manualField("") !== null || seam.manualField("liveness") !== "liveness" || seam.manualField("NOT A SLUG") !== "index") throw failure("manual_field_contract", "manualField diverged from its normalization contract", `roundtrip_${mode}`);
  handCases += 1;
  // ── The manual-only delta key discriminates VIEWS ──────────────────────────
  //
  // The router treats "the manual field moved and nothing else did" as a pure
  // re-render: no generation bump, no refetch, the painted view kept underneath
  // the pane. That shortcut is only sound when the key it compares actually
  // changes on a view change. It is not the canonical hash alone: the key
  // carries the VIEW, and it must keep doing so. The unavailable route now
  // serializes its own path rather than falling through to the runs path, but
  // the discrimination must not come to REST on that — a serializer one
  // refactor from collapsing two views onto one path would let
  // `#/%zz` -> `#/runs?manual=index` skip the fetch and repaint a Runs page from
  // the unavailable view's empty state, asserting that zero runs were found when
  // nothing was ever asked for.
  if (typeof seam.manualUnderlyingKey !== "function") throw failure("manual_delta_key_missing", "The manual-only delta key is not exposed on the seam", `roundtrip_${mode}`);
  const unavailableKey = seam.manualUnderlyingKey(seam.parseRoute("#/%zz"));
  const defaultOpenKey = seam.manualUnderlyingKey(seam.parseRoute(mode === "set" ? "#/workspaces?manual=index" : "#/runs?manual=index"));
  if (seam.parseRoute("#/%zz").view !== "invalid") throw failure("undecodable_not_invalid", "An undecodable path no longer parses as the unavailable view", `roundtrip_${mode}`, {parsed_view: seam.parseRoute("#/%zz").view});
  if (unavailableKey === defaultOpenKey) throw failure("manual_delta_key_collapses_views", "A view change carrying a manual delta is misclassified as manual-only", `roundtrip_${mode}`, {unavailable_key: unavailableKey, default_key: defaultOpenKey});
  // ── The UNAVAILABLE route survives the overlay ────────────────────────────
  //
  // The pane is an overlay on EVERY route family, and the unavailable route is
  // the family where that claim is easiest to break and hardest to notice: it
  // names no workspace, no run and no unit, so a serializer that falls through
  // to the runs-path construction invents an entire destination for it.
  //
  // That is what shipped. Standing on `#/%zz`, the `?` binding calls
  // manualRoute(route, MANUAL_INDEX), which produced `#/runs?manual=index`
  // (single) or `#/workspaces/<first>/runs?manual=index` (set): opening the
  // manual silently NAVIGATED the reader onto a real view and discarded the
  // unavailable state for good. It is the same defect class as the overview
  // short-circuit above, on the one view whose whole message is "what you asked
  // for does not exist".
  //
  // Driven through manualRoute (the exact call both key bindings make) rather
  // than through routeHash, so the check speaks for the operator's real path,
  // and asserted in BOTH directions: opening must keep the view unavailable,
  // and closing must return the operator's own path.
  //
  // The last fixture is the one the first cut of this coverage missed: a hash
  // whose fragment does NOT begin with "/". Bootstrap rewrites only an empty or
  // bare "#", so `#%e0%a4%a` reaches parseRoute untouched from a pasted URL and
  // is stored with a slash-less invalidPath. Every fixture beginning "#/" walks
  // straight past the serializer's root-relative guard, so without this case the
  // guard was never exercised from parsed input at all — and behind it the
  // operator's bytes were being thrown away for a fabricated sentinel path.
  // Each fixture pins the EXACT hash a close must land on: identical to the
  // original where it was already root-relative, normalized with one leading
  // slash where it was not, and never a path the operator did not type.
  for (const [undecodable, expectedClosed] of [["#/%zz", "#/%zz"], ["#/runs/%e0%a4%a", "#/runs/%e0%a4%a"], ["#/workspaces/left/runs/%zz", "#/workspaces/left/runs/%zz"], ["#%e0%a4%a", "#/%e0%a4%a"]]) {
    const invalid = seam.parseRoute(undecodable);
    if (invalid.view !== "invalid") throw failure("invalid_fixture_not_invalid", "A fixture chosen for the unavailable-route family did not parse as unavailable, so the family is not being exercised", `roundtrip_${mode}`, {undecodable, parsed_view: invalid.view});
    // The operator's own bytes, taken off the fixture minus the "#" and any
    // leading slashes: whatever the serializer emits, opened or closed, has to
    // still CONTAIN them. A sentinel substitution keeps the view class and so
    // passes every assertion below while silently rewriting the address bar to
    // a path that was never requested; this is the assertion that sees it.
    const operatorBytes = undecodable.replace(/^#\/*/, "");
    for (const slug of [seam.manualIndexSlug, "liveness"]) {
      const openedHash = seam.manualRoute(invalid, slug);
      const opened = seam.parseRoute(openedHash);
      if (opened.view !== "invalid") throw failure("manual_demoted_invalid_route", "Opening the instrument manual over an unavailable route DEMOTED it to a real view: the unavailable state is silently discarded and unreachable again", `roundtrip_${mode}`, {undecodable, slug, opened_hash: openedHash, opened_view: opened.view});
      if (opened.manual !== slug) throw failure("manual_not_carried_on_invalid_route", "The manual field did not survive being opened over an unavailable route", `roundtrip_${mode}`, {undecodable, slug, opened_hash: openedHash, opened_manual: opened.manual ?? null});
      if (!openedHash.includes(operatorBytes)) throw failure("manual_open_discarded_invalid_path", "Opening the instrument manual over an unavailable route replaced the operator's undecodable path with a different one: the view class survives but the address bar now shows a path that was never requested", `roundtrip_${mode}`, {undecodable, slug, opened_hash: openedHash, operator_bytes: operatorBytes});
      // CLOSING returns the route the pane was opened over: the same bytes,
      // root-relative. A close that landed anywhere else would be the same
      // demotion arriving one step later.
      const closedHash = seam.manualRoute(opened, null);
      if (closedHash !== expectedClosed) throw failure("manual_close_left_invalid_route", "Closing the instrument manual over an unavailable route did not return the route it was opened on", `roundtrip_${mode}`, {undecodable, slug, closed_hash: closedHash, expected_closed: expectedClosed});
      if (seam.parseRoute(closedHash).view !== "invalid") throw failure("manual_close_demoted_invalid_route", "Closing the instrument manual over an unavailable route demoted it to a real view", `roundtrip_${mode}`, {undecodable, slug, closed_hash: closedHash});
      // And the overlay move is a MANUAL-ONLY delta, so the router's fast path
      // may take it: the underlying key must be stable across open and close on
      // this family exactly as it is on every other.
      if (seam.manualUnderlyingKey(invalid) !== seam.manualUnderlyingKey(opened)) throw failure("manual_delta_key_unstable_on_invalid_route", "Opening the manual pane over an unavailable route changed the underlying delta key", `roundtrip_${mode}`, {undecodable, slug});
    }
  }
  // A hand-built literal that claims the unavailable view but carries no path
  // must still SERIALIZE as unavailable. Every in-app control builds partial
  // literals, so "the route object came from parseRoute" is not an invariant the
  // serializer may assume; falling through to the runs path here would be the
  // same demotion reached by a different door.
  const bareInvalid = seam.parseRoute(seam.routeHash({view: "invalid", filters: {}, sort: seam.defaultSort, q: "", manual: null}));
  if (bareInvalid.view !== "invalid") throw failure("bare_invalid_literal_demoted", "Serializing a route literal that names the unavailable view produced a REAL view: an unavailable route built by hand is demoted", `roundtrip_${mode}`, {parsed_view: bareInvalid.view});
  // ROOT-RELATIVE, always. The unavailable branch is the only place routeHash
  // emits a path it did not construct itself, so it is the only place that
  // promise can be lost. Nothing the branch emits can execute — the value
  // reaches `location.hash` or an href starting with "#", where a leading
  // "javascript:" is a fragment and not a scheme — but the invariant is worth
  // holding directly rather than by case analysis, and a literal carrying an
  // arbitrary `invalidPath` is the caller that would break it.
  for (const hostile of ["javascript:alert(1)/%zz", "//evil.example/%zz", "%zz", "", "  /%zz"]) {
    const emitted = seam.routeHash({view: "invalid", invalidPath: hostile, filters: {}, sort: seam.defaultSort, q: "", manual: null});
    if (!emitted.startsWith("#/")) throw failure("invalid_route_hash_not_root_relative", "Serializing an unavailable route emitted a fragment that is not root-relative", `roundtrip_${mode}`, {invalid_path: hostile, emitted});
    if (seam.parseRoute(emitted).view !== "invalid") throw failure("hostile_invalid_path_demoted", "An unavailable route carrying an unusable path did not survive canonicalization as unavailable", `roundtrip_${mode}`, {invalid_path: hostile, emitted, parsed_view: seam.parseRoute(emitted).view});
  }
  handCases += 1;
  // Opening and closing the pane on ONE route is the delta the shortcut exists
  // for: the key must be stable across it, or the pane would refetch.
  for (const base of mode === "set" ? ["#/workspaces", "#/workspaces/left/runs", "#/workspaces/left/runs/20260715T000000-a1b2c3"] : ["#/runs", "#/runs/20260715T000000-a1b2c3"]) {
    const closedKey = seam.manualUnderlyingKey(seam.parseRoute(base));
    const openedKey = seam.manualUnderlyingKey(seam.parseRoute(seam.manualRoute(seam.parseRoute(base), "liveness")));
    if (closedKey !== openedKey) throw failure("manual_delta_key_unstable", "Opening the manual pane changed the underlying delta key", `roundtrip_${mode}`, {base, closed_key: closedKey, opened_key: openedKey});
  }
  handCases += 1;
  // A REACHABLE bookmark corpus with EXACT expected canonical hashes
  // (hand-derived from the routeHash contract and byte-pinned): a consistent
  // serializer corruption cannot hide behind mere stability. The set-mode
  // OVERVIEW is its own pinned path: it names no workspace, so canonicalizing
  // it must not invent one and drop the reader into a workspace's runs list.
  const corpus = mode === "set"
    ? [
        ["#/workspaces", "#/workspaces"],
        // The manual rides the OVERVIEW too: the pane is the only thing the
        // param adds, and the overview path survives underneath it.
        ["#/workspaces?manual=dependency-gate", "#/workspaces?manual=dependency-gate"],
        ["#/workspaces/left/runs", "#/workspaces/left/runs"],
        ["#/workspaces/right/runs/20260715T000000-a1b2c3?follow=1", "#/workspaces/right/runs/20260715T000000-a1b2c3?follow=1"],
        ["#/workspaces/left/runs/20260715T000000-a1b2c3?cluster=wave%3A0%3Abucket%3A0&members=2&zoom=6", "#/workspaces/left/runs/20260715T000000-a1b2c3?zoom=6&cluster=wave%3A0%3Abucket%3A0&members=2"],
        // The manual rides the DETAIL route: the run path and its follow flag
        // survive, and the pane is the only thing the param adds.
        ["#/workspaces/right/runs/20260715T000000-a1b2c3?follow=1&manual=dependency-gate", "#/workspaces/right/runs/20260715T000000-a1b2c3?follow=1&manual=dependency-gate"],
        // The deep link canonicalizes ONTO the default view, which in set mode
        // is the overview, pane open.
        ["#manual/liveness", "#/workspaces?manual=liveness"]
      ]
    : [
        ["#/runs", "#/runs"],
        ["#/runs?execution=held", "#/runs?execution=held"],
        ["#/runs/20260715T000000-a1b2c3?follow=1", "#/runs/20260715T000000-a1b2c3?follow=1"],
        ["#/runs/20260715T000000-a1b2c3/units/workflow%3Azoom%3Astep%3Aa?attempt=attempt%3A1", "#/runs/20260715T000000-a1b2c3/units/workflow%3Azoom%3Astep%3Aa?attempt=attempt%3A1"],
        ["#/runs/20260715T000000-a1b2c3?cluster=wave%3A0%3Abucket%3A0&members=2&zoom=6&arc=arc%3A0", "#/runs/20260715T000000-a1b2c3?zoom=6&cluster=wave%3A0%3Abucket%3A0&arc=arc%3A0&members=2"],
        // The manual rides the DETAIL route: the run path, its unit, and its
        // follow flag survive, and the pane is the only thing the param adds.
        ["#/runs/20260715T000000-a1b2c3?follow=1&manual=dependency-gate", "#/runs/20260715T000000-a1b2c3?follow=1&manual=dependency-gate"],
        ["#/runs/20260715T000000-a1b2c3/units/workflow%3Azoom%3Astep%3Aa?manual=index", "#/runs/20260715T000000-a1b2c3/units/workflow%3Azoom%3Astep%3Aa?manual=index"],
        // The deep link canonicalizes ONTO the default view, pane open.
        ["#manual/liveness", "#/runs?manual=liveness"],
        ["#manual", "#/runs?manual=index"],
        // An unknown term lands on the index rather than anywhere unavailable.
        ["#manual/not-a-real-term-here", "#/runs?manual=not-a-real-term-here"],
        ["#manual/NOT%20A%20SLUG", "#/runs?manual=index"]
      ];
  for (const [bookmark, expectedCanonical] of corpus) {
    const once = seam.routeHash(seam.parseRoute(bookmark));
    if (once !== expectedCanonical) throw failure("bookmark_canonical_mismatch", "A reachable bookmark did not canonicalize to its pinned hash", `roundtrip_${mode}`, {bookmark, once, expected: expectedCanonical});
    const twice = seam.routeHash(seam.parseRoute(once));
    if (once !== twice) throw failure("bookmark_not_stable", "A reachable bookmark hash did not stabilize after one canonicalization", `roundtrip_${mode}`, {bookmark, once, twice});
    handCases += 1;
  }
  if (mode === "set") {
    if (seam.parseRoute("#/workspaces").view !== "workspaces") throw failure("workspaces_view_missing", "The set-mode overview route did not parse to the workspaces view", `roundtrip_${mode}`);
    handCases += 1;
    if (seam.parseRoute("#/workspaces/not-configured/runs").view !== "workspaces") throw failure("unknown_workspace_not_demoted", "An unconfigured workspace route did not demote to the overview", `roundtrip_${mode}`);
    handCases += 1;
  }
  for (const [family, count] of Object.entries(coverage)) {
    if (count === 0) throw failure("coverage_family_empty", `The generator never exercised the ${family} route family`, `roundtrip_${mode}`, {coverage});
  }
  return {cases: cases + handCases, coverage};
}

function checkVisible(seam) {
  // Independent oracle: expected outputs are hand-computed from the frozen
  // token vocabulary, not re-derived by re-implementing the algorithm.
  const cap = seam.limits.field;
  if (cap !== 32768) throw failure("limits_drift", "LIMITS.field is no longer 32768", "visible", {cap});
  const cases = [
    {input: "abc", text: "abc", truncated: false, rawLength: 3},
    {input: null, text: "", truncated: false, rawLength: 0},
    {input: "\u001b", text: "\u27e6ESC\u27e7", truncated: false, rawLength: 1},
    {input: "\u007f", text: "\u27e6DEL\u27e7", truncated: false, rawLength: 1},
    {input: "\u0001", text: "\u27e6C0 U+0001\u27e7", truncated: false, rawLength: 1},
    {input: "\u0085", text: "\u27e6U+0085\u27e7", truncated: false, rawLength: 1},
    {input: "right\u202epayload", text: "right\u27e6U+202E\u27e7payload", truncated: false, rawLength: 13},
    {input: "\u200e", text: "\u27e6U+200E\u27e7", truncated: false, rawLength: 1},
    {input: "\u2066", text: "\u27e6U+2066\u27e7", truncated: false, rawLength: 1},
    {input: "\u061c", text: "\u27e6U+061C\u27e7", truncated: false, rawLength: 1},
    {input: "\u2028", text: "\u27e6U+2028\u27e7", truncated: false, rawLength: 1},
    {input: "\u2029", text: "\u27e6U+2029\u27e7", truncated: false, rawLength: 1},
    {input: "\u202d", text: "\u27e6U+202D\u27e7", truncated: false, rawLength: 1},
    {input: "\u200f", text: "\u27e6U+200F\u27e7", truncated: false, rawLength: 1},
    {input: "\u2067", text: "\u27e6U+2067\u27e7", truncated: false, rawLength: 1},
    {input: "\u2069", text: "\u27e6U+2069\u27e7", truncated: false, rawLength: 1},
    {input: 42, text: "42", truncated: false, rawLength: 2},
    {input: "\u{1f389}", text: "\u{1f389}", truncated: false, rawLength: 2},
    {input: "Z".repeat(32768), text: "Z".repeat(32768), truncated: false, rawLength: 32768},
    {input: "Z".repeat(32769), text: "Z".repeat(32768), truncated: true, rawLength: 32769},
    // Token expansion at the boundary: 32763 Z + the 5-unit ESC token = 32768
    // fits exactly; 32764 Z + 5 = 32769 overflows and the token drops whole.
    {input: "Z".repeat(32763) + "\u001b", text: "Z".repeat(32763) + "\u27e6ESC\u27e7", truncated: false, rawLength: 32764},
    {input: "Z".repeat(32764) + "\u001b", text: "Z".repeat(32764), truncated: true, rawLength: 32765}
  ];
  for (const [index, expected] of cases.entries()) {
    const shown = seam.visible(expected.input);
    if (shown.text !== expected.text || shown.truncated !== expected.truncated || shown.rawLength !== expected.rawLength) {
      throw failure("visible_contract_broken", "visible() diverged from the frozen token/bound contract", "visible", {case: index, expected: {truncated: expected.truncated, rawLength: expected.rawLength, text_prefix: expected.text.slice(0, 40)}, observed: {truncated: shown.truncated, rawLength: shown.rawLength, text_prefix: shown.text.slice(0, 40)}});
    }
  }
  return cases.length;
}

function temporalRow(id, latest, completeness) {
  return {id, temporal: {latest_at: {value: latest, basis: "max_parent_event_ts", completeness}}};
}

function durationRow(id, ms) {
  return {id, temporal: {duration: {ms, basis: "boundary_difference", completeness: "complete"}}};
}

function checkComparator(seam) {
  // Pinned total order: complete first in sort direction, then incomplete,
  // unknown, malformed (COMPLETENESS_RANK 0..3); sub-ms ties via the
  // normalized instant; exact ties by ascending id. The row set covers every
  // equivalence class: sub-ms instants, exact instant ties, the LEGACY
  // latest_at string fallback (valid and malformed), a malformed-labeled
  // boundary whose value still parses (the label must win), and real
  // complete durations with distinct and tied ms.
  const rows = [
    temporalRow("r-old", "2026-07-01T00:00:00Z", "complete"),
    temporalRow("r-new", "2026-07-15T00:00:00Z", "complete"),
    temporalRow("r-subms-lo", "2026-07-10T00:00:00.0000001Z", "complete"),
    temporalRow("r-subms-hi", "2026-07-10T00:00:00.0000002Z", "complete"),
    temporalRow("r-incomplete", null, "incomplete"),
    temporalRow("r-unknown", null, "unknown"),
    temporalRow("r-malformed", "not-a-time", "malformed"),
    temporalRow("mal-parseable", "2026-07-09T00:00:00Z", "malformed"),
    temporalRow("a-tie", "2026-07-05T00:00:00Z", "complete"),
    temporalRow("b-tie", "2026-07-05T00:00:00Z", "complete"),
    {id: "legacy-ok", latest_at: "2026-07-08T00:00:00Z"},
    {id: "legacy-bad", latest_at: "not-a-time-either"},
    durationRow("d-long", 9000),
    durationRow("d-short", 1000),
    durationRow("d-tie-a", 5000),
    durationRow("d-tie-b", 5000)
  ];
  const expectations = {
    recency_desc: ["r-new", "r-subms-hi", "r-subms-lo", "legacy-ok", "a-tie", "b-tie", "r-old", "r-incomplete", "d-long", "d-short", "d-tie-a", "d-tie-b", "r-unknown", "legacy-bad", "mal-parseable", "r-malformed"],
    recency_asc: ["r-old", "a-tie", "b-tie", "legacy-ok", "r-subms-lo", "r-subms-hi", "r-new", "r-incomplete", "d-long", "d-short", "d-tie-a", "d-tie-b", "r-unknown", "legacy-bad", "mal-parseable", "r-malformed"],
    duration_asc: ["d-short", "d-tie-a", "d-tie-b", "d-long", "a-tie", "b-tie", "legacy-bad", "legacy-ok", "mal-parseable", "r-incomplete", "r-malformed", "r-new", "r-old", "r-subms-hi", "r-subms-lo", "r-unknown"],
    duration_desc: ["d-long", "d-tie-a", "d-tie-b", "d-short", "a-tie", "b-tie", "legacy-bad", "legacy-ok", "mal-parseable", "r-incomplete", "r-malformed", "r-new", "r-old", "r-subms-hi", "r-subms-lo", "r-unknown"]
  };
  let orderChecks = 0;
  for (const [sort, expected] of Object.entries(expectations)) {
    const observed = rows.slice().sort(seam.runsComparator(sort)).map((row) => row.id);
    if (JSON.stringify(observed) !== JSON.stringify(expected)) throw failure("comparator_order_broken", `${sort} diverged from the pinned total order`, "comparator", {sort, observed, expected});
    orderChecks += 1;
  }
  // Properties over every pair AND every triple, every sort: antisymmetry and
  // transitivity (a cyclic comparator cannot hide behind pair checks).
  let pairs = 0;
  let triples = 0;
  for (const sort of Object.keys(expectations)) {
    const comparator = seam.runsComparator(sort);
    for (const a of rows) for (const b of rows) {
      const ab = Math.sign(comparator(a, b));
      const ba = Math.sign(comparator(b, a));
      if (a === b ? ab !== 0 : ab !== -ba) throw failure("comparator_not_antisymmetric", "The comparator is not antisymmetric", "comparator", {sort, a: a.id, b: b.id, ab, ba});
      pairs += 1;
    }
    for (const a of rows) for (const b of rows) for (const c of rows) {
      const ab = Math.sign(comparator(a, b));
      const bc = Math.sign(comparator(b, c));
      if (ab <= 0 && bc <= 0 && Math.sign(comparator(a, c)) > 0) throw failure("comparator_not_transitive", "The comparator is not transitive", "comparator", {sort, a: a.id, b: b.id, c: c.id});
      triples += 1;
    }
  }
  return {rows: rows.length, order_checks: orderChecks, pairs, triples};
}

// ── Parent-observed child resolution (issue #438) ───────────────────────────
//
// resolveParentObservedChild(sessionId, rows) is the ONLY resolution primitive:
// a pure, exact-equality scan over the parent-observed `children` already
// carried by held authoritative list rows. It reads nothing else — no child
// Log, no index, no network — so executing it here is the whole contract.

function childRow(id, children) {
  return {id, children};
}

function checkChildResolution(seam) {
  const resolve = seam.resolveParentObservedChild;
  if (typeof resolve !== "function") throw failure("child_resolution_missing", "The seam did not expose resolveParentObservedChild", "child_resolution");

  const rows = [
    childRow("parent-with-unit", [{session_id: "child-a", unit_id: "step:review"}, {session_id: "child-shared", unit_id: "step:one"}]),
    childRow("parent-without-unit", [{session_id: "child-b", unit_id: null}]),
    childRow("parent-second-observer", [{session_id: "child-shared", unit_id: "step:two"}]),
    childRow("parent-no-children", []),
    childRow("parent-malformed-children", "not-an-array"),
    childRow("parent-nonstring-child", [{session_id: 42, unit_id: "step:x"}, {session_id: null, unit_id: "step:y"}])
  ];

  const cases = [
    // Exact match carrying a unit: one candidate, unit preserved verbatim.
    {name: "resolved_with_unit", id: "child-a", candidates: [{runId: "parent-with-unit", unitId: "step:review"}]},
    // Exact match with no unit identified in parent evidence: unitId is null.
    {name: "resolved_without_unit", id: "child-b", candidates: [{runId: "parent-without-unit", unitId: null}]},
    // Ambiguity: BOTH observers are offered, in held-inventory order, none chosen.
    {name: "ambiguous", id: "child-shared", candidates: [{runId: "parent-with-unit", unitId: "step:one"}, {runId: "parent-second-observer", unitId: "step:two"}]},
    // Unknown id: no candidates at all — the dead end must stay unchanged.
    {name: "unresolved", id: "child-missing", candidates: []},
    // A parent's OWN run id is not a child observation of itself.
    {name: "parent_id_is_not_a_child", id: "parent-with-unit", candidates: []},
    // Prefix and case variants must NOT resolve: exact equality only.
    {name: "prefix_rejected", id: "child-", candidates: []},
    {name: "suffix_rejected", id: "child-a-extra", candidates: []},
    {name: "case_rejected", id: "CHILD-A", candidates: []},
    // Non-string / absent ids resolve nothing and must not throw.
    {name: "empty_rejected", id: "", candidates: []},
    {name: "null_rejected", id: null, candidates: []},
    {name: "number_rejected", id: 42, candidates: []}
  ];

  for (const testCase of cases) {
    const observed = resolve(testCase.id, rows);
    if (!Array.isArray(observed)) throw failure("child_resolution_shape", "resolveParentObservedChild did not return an array", "child_resolution", {case: testCase.name});
    const simplified = observed.map((candidate) => ({runId: candidate.runId, unitId: candidate.unitId ?? null}));
    if (JSON.stringify(simplified) !== JSON.stringify(testCase.candidates)) {
      throw failure("child_resolution_broken", `resolveParentObservedChild diverged for ${testCase.name}`, "child_resolution", {case: testCase.name, observed: simplified, expected: testCase.candidates});
    }
  }

  // Absent / malformed inventory resolves nothing rather than fabricating.
  for (const [index, inventory] of [null, undefined, "rows", {}, []].entries()) {
    const observed = resolve("child-a", inventory);
    if (!Array.isArray(observed) || observed.length !== 0) throw failure("child_resolution_fabricated", "resolveParentObservedChild resolved against an absent or malformed inventory", "child_resolution", {index});
  }

  // Purity: resolution must not mutate the inventory it reads.
  const before = JSON.stringify(rows);
  resolve("child-shared", rows);
  if (JSON.stringify(rows) !== before) throw failure("child_resolution_mutated_inventory", "resolveParentObservedChild mutated the held inventory", "child_resolution");

  return cases.length;
}

// ── Glossary accessor seam (#551) ───────────────────────────────────────────
//
// The three accessors are BEHAVIORAL contracts, not just exported names: the
// null-not-undefined answer T3's typeof-guard depends on, the corpus (never
// alphabetical) concern order, and the deep freeze that keeps a caller from
// corrupting a `concern` object SHARED across entries. Source greps in
// glossary_delivery_contract_test.exs cannot see any of the three, so they are
// executed here against the loaded seam.

function checkGlossary(seam) {
  const entries = seam.glossaryEntries();
  if (!Array.isArray(entries) || entries.length === 0) throw failure("glossary_entries_shape", "glossaryEntries() did not return a non-empty array", "glossary");

  // Repeat calls hand back the identical frozen reference, never a fresh copy.
  if (seam.glossaryEntries() !== entries) throw failure("glossary_entries_not_stable", "glossaryEntries() returned a different reference on a repeat call", "glossary");
  const concernsFirstRead = seam.glossaryConcerns();
  if (seam.glossaryConcerns() !== concernsFirstRead) throw failure("glossary_concerns_not_stable", "glossaryConcerns() returned a different reference on a repeat call", "glossary");

  // Every entry resolves by its own slug, to the SAME object the array holds.
  for (const entry of entries) {
    const found = seam.glossaryBySlug(entry.slug);
    if (found !== entry) throw failure("glossary_slug_lookup_broken", "glossaryBySlug did not resolve a corpus slug to its own entry", "glossary", {slug: entry.slug});
  }

  // The null contract, checked with === so `undefined` cannot pass as null:
  // an unknown `#manual/<slug>` is a routing miss the caller renders, never a
  // crash and never an undefined that a typeof guard would misread.
  for (const [index, miss] of ["no-such-slug", "", "LIVENESS", " liveness", null, undefined, 42, {}, []].entries()) {
    let observed;
    try {
      observed = seam.glossaryBySlug(miss);
    } catch (error) {
      throw failure("glossary_lookup_threw", "glossaryBySlug threw instead of answering null", "glossary", {index, message: String(error?.message || error)});
    }
    if (observed !== null) throw failure("glossary_lookup_not_null", "glossaryBySlug answered something other than exactly null for an unknown slug", "glossary", {index, observed_type: observed === undefined ? "undefined" : typeof observed});
  }

  // Concern order is the corpus's first-appearance order, DERIVED from the
  // entries themselves so this assertion tracks the corpus instead of pinning
  // a hand-copied list an alphabetical re-sort would still satisfy.
  const concerns = seam.glossaryConcerns();
  if (!Array.isArray(concerns) || concerns.length === 0) throw failure("glossary_concerns_shape", "glossaryConcerns() did not return a non-empty array", "glossary");
  const expectedKeys = [];
  for (const entry of entries) if (!expectedKeys.includes(entry.concern.key)) expectedKeys.push(entry.concern.key);
  const observedKeys = concerns.map((concern) => concern.key);
  if (JSON.stringify(observedKeys) !== JSON.stringify(expectedKeys)) throw failure("glossary_concern_order_broken", "glossaryConcerns() is not the corpus first-appearance order", "glossary", {observed: observedKeys, expected: expectedKeys});
  for (const concern of concerns) {
    if (typeof concern.key !== "string" || typeof concern.title !== "string" || typeof concern.blurb !== "string") throw failure("glossary_concern_record_shape", "a concern record lost one of its {key,title,blurb} fields", "glossary", {key: concern.key});
  }

  // Concerns are INTERNED: every entry of a group points at the one object
  // glossaryConcerns() holds for that key. This is asserted rather than assumed
  // because the projection rebuilds each entry's object literals, which would
  // hand out one distinct-but-equal concern per entry unless interning is real.
  // Two downstream contracts ride on it — the freeze probe below only protects
  // the corpus if the object it probes is the group's ONLY one, and T4/T5 group
  // the index by `concern` identity, which silently degrades to one member per
  // group when the objects merely compare equal.
  for (const entry of entries) {
    const canonical = concerns.find((concern) => concern.key === entry.concern.key);
    if (entry.concern !== canonical) throw failure("glossary_concern_not_interned", "an entry carries its own concern object instead of the shared one glossaryConcerns() holds", "glossary", {slug: entry.slug, key: entry.concern.key});
  }
  if (new Set(entries.map((entry) => entry.concern)).size !== concerns.length) throw failure("glossary_concern_not_interned", "the entries carry a different number of distinct concern objects than glossaryConcerns() reports", "glossary", {identities: new Set(entries.map((entry) => entry.concern)).size, concerns: concerns.length});

  // Deep freeze. `concern` objects are SHARED across entries (interned just
  // above), so an accepted write to one would silently corrupt the corpus for
  // every other caller and for the index — probe entry, nested concern, and the
  // arrays themselves.
  const probe = entries[0];
  const targets = [
    {name: "entry_field", apply: () => { probe.term = "tampered"; }, read: () => probe.term},
    {name: "entry_new_field", apply: () => { probe.injected = "tampered"; }, read: () => probe.injected},
    {name: "concern_field", apply: () => { probe.concern.title = "tampered"; }, read: () => probe.concern.title},
    {name: "entries_array", apply: () => { entries[0] = {term: "tampered"}; }, read: () => entries[0].term},
    {name: "concerns_array", apply: () => { concerns[0] = {key: "tampered"}; }, read: () => concerns[0].key}
  ];
  for (const target of targets) {
    const before = target.read();
    // Frozen writes throw in strict mode and are silently dropped otherwise;
    // either way the VALUE must be unchanged, which is the contract.
    try { target.apply(); } catch (_error) { /* strict-mode refusal is a pass */ }
    if (target.read() !== before) throw failure("glossary_not_frozen", "a glossary accessor handed back a mutable structure", "glossary", {target: target.name});
  }

  return {entries: entries.length, concerns: concerns.length};
}

// ── ON THIS RUN slug inventories (#551, T4 -> T7) ────────────────────────────
//
// The manual's fourth doctrine part is bound per-term, so the SET of terms with
// no run-scoped value is a real contract: it is exactly the set the pane is
// allowed to stay silent about. T7's anti-rot predicate consumes it, and it must
// consume it as DATA — two independent derivations of one set is two sources of
// truth for which silences are honest, and they drift the first time a term is
// added. It is therefore published as a frozen export and checked here for the
// three properties a consumer depends on: it PARTITIONS the corpus, it is
// frozen, and it is stable across reads.
function checkManualRunInventory(seam) {
  const bound = seam.manualRunValueSlugs;
  const unbound = seam.manualNoRunValueSlugs;
  if (!Array.isArray(bound) || bound.length === 0) throw failure("manual_bound_slugs_shape", "manualRunValueSlugs did not return a non-empty array", "manual_inventory");
  if (!Array.isArray(unbound) || unbound.length === 0) throw failure("manual_unbound_slugs_shape", "manualNoRunValueSlugs did not return a non-empty array", "manual_inventory");
  if (!Object.isFrozen(bound) || !Object.isFrozen(unbound)) throw failure("manual_inventory_not_frozen", "a slug inventory was handed back mutable, so a consumer could rewrite which silences count as honest", "manual_inventory");
  if (seam.manualNoRunValueSlugs !== unbound) throw failure("manual_inventory_not_stable", "manualNoRunValueSlugs returned a different reference on a repeat call", "manual_inventory");

  // A PARTITION of the corpus: every term is on exactly one side. A slug on
  // neither is a term the anti-rot tier can never adjudicate; a slug on both is
  // a claim the pane both has and lacks a value for it.
  const corpus = seam.glossaryEntries().map((entry) => entry.slug);
  const boundSet = new Set(bound);
  const unboundSet = new Set(unbound);
  if (boundSet.size !== bound.length || unboundSet.size !== unbound.length) throw failure("manual_inventory_duplicated", "a slug inventory carries duplicates", "manual_inventory");
  for (const slug of corpus) {
    const inBound = boundSet.has(slug);
    const inUnbound = unboundSet.has(slug);
    if (inBound === inUnbound) throw failure("manual_inventory_not_a_partition", "a corpus slug is on both inventories or on neither, so the anti-rot tier cannot tell whether the pane's silence about it is honest", "manual_inventory", {slug, bound: inBound, unbound: inUnbound});
  }
  for (const slug of bound.concat(unbound)) {
    if (!corpus.includes(slug)) throw failure("manual_inventory_off_corpus", "an inventory names a slug the corpus does not carry", "manual_inventory", {slug});
  }
  if (bound.length + unbound.length !== corpus.length) throw failure("manual_inventory_incomplete", "the two inventories do not add up to the corpus", "manual_inventory", {bound: bound.length, unbound: unbound.length, corpus: corpus.length});

  return {bound: bound.length, no_run_value: unbound.length, corpus: corpus.length};
}

// ── Labelled terms: the dotted affordance's refusal, EXECUTED ────────────────
//
// The source-pin contract test asserts that `labelledTermSlug` contains a
// `throw`. That is not the same as proving it throws. A dead link is exactly
// the failure mode the refusal exists to prevent, and it is invisible: the
// label still renders, the underline still paints, and the anchor lands on the
// manual's unknown-slug page. So the refusal is exercised here, in the same vm
// the rest of the seam runs in.
function checkLabelledTerms(seam) {
  const table = seam.labelledTerms;
  if (!table || typeof table !== "object") throw failure("labelled_terms_shape", "the seam did not expose the labelled-term table", "labelled_terms");
  const labels = Object.keys(table);
  if (labels.length === 0) throw failure("labelled_terms_empty", "the labelled-term table is empty", "labelled_terms");

  // Every shipped label resolves, and resolves to a slug the corpus carries.
  // Resolving to an absent slug would ship a dotted underline over a dead link.
  for (const label of labels) {
    let slug;
    try {
      slug = seam.labelledTermSlug(label);
    } catch (error) {
      throw failure("labelled_term_unresolvable", "a shipped label in the table did not resolve to a slug", "labelled_terms", {label, message: String(error?.message || error)});
    }
    if (slug !== table[label]) throw failure("labelled_term_slug_mismatch", "labelledTermSlug disagreed with the table it reads", "labelled_terms", {label, table_slug: table[label], resolved: slug});
    if (seam.glossaryBySlug(slug) === null) throw failure("labelled_term_dead_link", "a shipped label maps to a slug the glossary corpus does not carry", "labelled_terms", {label, slug});
  }

  // The MISMATCH cases, pinned as a positive property rather than left to
  // chance: the rail and the list ship different spellings of one dimension,
  // and the table is what absorbs that rather than either surface being
  // reworded. If someone "fixes" the spelling on either side, these go red.
  // (The list ships NO short "Attention" header — attention rides the row's
  // inline copy — so no Attention pair exists to pin; freezing one here was
  // inventory fiction the adversarial review caught on #553.)
  const mismatches = [
    ["Child activity after end", "Child after end"],
    ["Dependency gate", "Runtime gate"]
  ];
  for (const [longer, shorter] of mismatches) {
    if (!Object.prototype.hasOwnProperty.call(table, longer) || !Object.prototype.hasOwnProperty.call(table, shorter)) {
      throw failure("labelled_term_shipped_spelling_lost", "one of the two shipped spellings of a dimension is no longer in the table", "labelled_terms", {longer, shorter});
    }
  }
  // "Dependency gate" and "Runtime gate" are the same dimension under two
  // shipped labels, but they are DIFFERENT glossary entries (the corpus
  // documents the confusion explicitly). The other two pairs share one slug.
  for (const [longer, shorter] of mismatches.slice(0, 1)) {
    if (table[longer] !== table[shorter]) throw failure("labelled_term_pair_split", "two shipped spellings of one dimension no longer share a slug", "labelled_terms", {longer, shorter});
  }

  // The refusal. An unmapped label must THROW, not answer a falsy slug that a
  // caller would happily interpolate into a href.
  //
  // AND the throw must be a `MonitorDefect`. This half is what makes the
  // refusal survive the SHIPPED render path rather than only this harness.
  // Calling `labelledTermSlug` directly, as the loop below does, can never
  // observe what the operator sees: every render goes through
  // `renderCurrentGuarded`, which catches. Before the defect class existed, a
  // plain `Error` was absorbed by `normalizeProjectionFailure` into
  // `projection_render_failed` — the label name and the whole diagnostic
  // discarded, the view blanked, and a Monitor authoring typo reported to the
  // operator as "The fetched projection could not be displayed." The refusal
  // was neither red nor attributed in the shipped app. So the classification is
  // asserted here, against the same normalizer the guard uses.
  let defectsObserved = 0;
  for (const [index, unknown] of ["Not A Shipped Label", "", "execution", "gate", "hasOwnProperty", "toString", "__proto__", null, undefined, 42].entries()) {
    let resolved;
    try {
      resolved = seam.labelledTermSlug(unknown);
    } catch (error) {
      if (seam.isMonitorDefect(error) !== true) {
        throw failure("labelled_term_refusal_misattributed", "labelledTermSlug refused with something other than a MonitorDefect, so the shipped render guard would launder the Monitor's own bug into an accusation against the Log", "labelled_terms", {index, label: String(unknown), name: String(error?.name)});
      }
      // The decisive property: the shipped normalizer must NOT claim it.
      const normalized = seam.normalizeProjectionFailure(error);
      if (normalized === error || normalized.kind !== "projection_render_failed") {
        throw failure("labelled_term_normalizer_shape", "the shipped normalizer no longer answers projection_render_failed for a foreign error, so this check can no longer distinguish absorption from classification", "labelled_terms", {index, kind: String(normalized?.kind)});
      }
      defectsObserved += 1;
      continue;
    }
    throw failure("labelled_term_refusal_absent", "labelledTermSlug answered instead of refusing on an unmapped label", "labelled_terms", {index, label: String(unknown), resolved: String(resolved)});
  }
  if (defectsObserved === 0) throw failure("labelled_term_refusal_absent", "no refusal was observed at all", "labelled_terms", {});

  // A ProjectionFailure is NOT a defect: the classifier must not start routing
  // genuine upstream failures into the Monitor-defect view, which would be the
  // mirror-image lie (blaming ourselves for the Log's problem).
  const upstream = new Error("projection client failure");
  upstream.name = "ProjectionFailure";
  if (seam.isMonitorDefect(upstream) !== false) throw failure("labelled_term_defect_overreach", "isMonitorDefect claimed a ProjectionFailure, so genuine upstream failures would be repainted as Monitor bugs", "labelled_terms", {});

  return {labels: labels.length, slugs: new Set(Object.values(table)).size, defects_observed: defectsObserved};
}

// ── Red proof: before trusting green, prove each family goes red against a
// deliberately broken seam (the #362 red-proof idiom). Deleting an assertion
// body can no longer keep the run green, because the tampered variant would
// stop failing — but that holds only when the variant goes red on the
// assertion under proof, which is why every family below pins the expected
// `harnessKind` rather than accepting whichever one fires first.

// Each family names the assertion it is proving, and the raised `harnessKind`
// must MATCH it. Accepting any harnessKind was itself a hole: a variant that
// tripped some EARLIER check (a stability or shape guard) short-circuited
// before reaching the assertion under proof, and the mismatch was absorbed
// silently — the family still counted, while the assertion it claimed to prove
// stayed unexercised and could be deleted with the run still green. That is
// exactly what `glossary_concern_order` did (it raised
// `glossary_concerns_not_stable`). Pinning the kind converts that class of
// mistake from invisible into a red run.
function expectRed(family, expectedKind, tamperedSeam, run) {
  try {
    run(tamperedSeam);
  } catch (error) {
    if (!error || !error.harnessKind) throw error;
    if (error.harnessKind !== expectedKind) {
      throw failure("red_proof_wrong_kind", `The ${family} red proof went red on ${error.harnessKind} instead of ${expectedKind}, so the assertion it claims to prove was never reached`, "red_proof", {family, expected: expectedKind, observed: error.harnessKind});
    }
    return 1;
  }
  throw failure("red_proof_failed", `The ${family} checks stayed green against a deliberately broken seam`, "red_proof", {family});
}

function checkRedProof(seam) {
  let families = 0;
  const corruptedHash = Object.freeze({...seam, routeHash: (route) => {
    const hash = seam.routeHash(route);
    return hash + (hash.includes("?") ? "&" : "?") + "redproof=1";
  }});
  families += expectRed("roundtrip", "bookmark_canonical_mismatch", corruptedHash, (tampered) => checkRoundTrip(tampered, "single", []));
  const corruptedVisible = Object.freeze({...seam, visible: (value) => {
    const shown = seam.visible(value);
    return {...shown, text: shown.text.slice(0, 2)};
  }});
  families += expectRed("visible", "visible_contract_broken", corruptedVisible, (tampered) => checkVisible(tampered));
  const invertedComparator = Object.freeze({...seam, runsComparator: (sort) => {
    const comparator = seam.runsComparator(sort);
    return (a, b) => -comparator(a, b);
  }});
  families += expectRed("comparator", "comparator_order_broken", invertedComparator, (tampered) => checkComparator(tampered));
  // A resolver that answers on PREFIX instead of exact equality is precisely
  // the speculative-match failure the brief forbids: it must go red here.
  const fuzzyResolver = Object.freeze({...seam, resolveParentObservedChild: (sessionId, rows) => {
    const needle = typeof sessionId === "string" ? sessionId : "";
    if (!needle || !Array.isArray(rows)) return [];
    return rows.flatMap((row) => (Array.isArray(row.children) ? row.children : []).filter((child) => typeof child.session_id === "string" && child.session_id.startsWith(needle)).map((child) => ({runId: row.id, unitId: child.unit_id ?? null, childSessionId: child.session_id})));
  }});
  families += expectRed("child_resolution", "child_resolution_broken", fuzzyResolver, (tampered) => checkChildResolution(tampered));
  // The three glossary mutations that survived the source greps, each proven
  // to go red here: undefined-for-null, an alphabetically re-sorted concern
  // order, and a corpus handed back unfrozen.
  const undefinedMiss = Object.freeze({...seam, glossaryBySlug: (slug) => seam.glossaryBySlug(slug) ?? undefined});
  families += expectRed("glossary_null_contract", "glossary_lookup_not_null", undefinedMiss, (tampered) => checkGlossary(tampered));
  // The alphabetical re-sort — the regression an Elixir source grep cannot see,
  // since the corpus first-appearance order is the section ordering T4/T5 render
  // from. The sorted array is built ONCE, outside the accessor, and the same
  // frozen reference is handed back on every call: an accessor that re-sorted
  // per call would return a fresh array each time and trip the reference
  // stability check first, short-circuiting before the order comparison and
  // leaving that assertion unexercised. The variant must differ from the real
  // seam in exactly ONE respect — the order — so only the order check can catch
  // it. Interning is preserved too (the sort reorders the very same concern
  // objects), so the interning checks stay green.
  const sortedConcernList = Object.freeze(seam.glossaryConcerns().slice().sort((a, b) => (a.key < b.key ? -1 : a.key > b.key ? 1 : 0)));
  const sortedConcerns = Object.freeze({...seam, glossaryConcerns: () => sortedConcernList});
  families += expectRed("glossary_concern_order", "glossary_concern_order_broken", sortedConcerns, (tampered) => checkGlossary(tampered));
  // Thawed but STABLE, self-consistent (same reference every call, and
  // glossaryBySlug answers out of the thawed copy) and still INTERNED — the
  // thawed concerns are one mutable object per key, reused across the group and
  // handed back by glossaryConcerns — so this variant can only go red on the
  // freeze probe itself, never on a stability, lookup, or interning check.
  const thawedConcerns = new Map();
  for (const entry of seam.glossaryEntries()) if (!thawedConcerns.has(entry.concern.key)) thawedConcerns.set(entry.concern.key, {...entry.concern});
  const thawedCopy = seam.glossaryEntries().map((entry) => ({...entry, concern: thawedConcerns.get(entry.concern.key)}));
  const thawedBySlug = new Map(thawedCopy.map((entry) => [entry.slug, entry]));
  const thawedConcernList = seam.glossaryConcerns().map((concern) => thawedConcerns.get(concern.key));
  const thawedEntries = Object.freeze({...seam, glossaryEntries: () => thawedCopy, glossaryConcerns: () => thawedConcernList, glossaryBySlug: (slug) => (typeof slug === "string" && thawedBySlug.has(slug) ? thawedBySlug.get(slug) : null)});
  families += expectRed("glossary_freeze", "glossary_not_frozen", thawedEntries, (tampered) => checkGlossary(tampered));
  // Un-interned but otherwise perfect: every entry keeps a frozen, value-equal
  // concern of its own. Value assertions and the single-entry freeze probe all
  // stay green, so only the interning check can catch it — which is the whole
  // point, since this is the shape the projection had before it interned.
  const unInternedCopy = seam.glossaryEntries().map((entry) => Object.freeze({...entry, concern: Object.freeze({...entry.concern})}));
  const unInternedBySlug = new Map(unInternedCopy.map((entry) => [entry.slug, entry]));
  const unInternedConcerns = Object.freeze(unInternedCopy.reduce((acc, entry) => {
    if (!acc.some((concern) => concern.key === entry.concern.key)) acc.push(entry.concern);
    return acc;
  }, []));
  const unInterned = Object.freeze({...seam, glossaryEntries: () => unInternedCopy, glossaryConcerns: () => unInternedConcerns, glossaryBySlug: (slug) => (typeof slug === "string" && unInternedBySlug.has(slug) ? unInternedBySlug.get(slug) : null)});
  families += expectRed("glossary_concern_interning", "glossary_concern_not_interned", unInterned, (tampered) => checkGlossary(tampered));
  // The exact regression this task exists to prevent: a manual that behaves like
  // a FIFTH VIEW instead of an overlay dimension. This tampered seam parses a
  // manual route into its own view and drops the underlying route, which is the
  // naive implementation the brief rules out. It must go red.
  const manualAsView = Object.freeze({...seam, parseRoute: (hash) => {
    const parsed = seam.parseRoute(hash);
    return parsed.manual ? {...parsed, view: "manual", runId: undefined, unitId: undefined} : parsed;
  }});
  families += expectRed("manual_overlay", "roundtrip_lost_run", manualAsView, (tampered) => checkRoundTrip(tampered, "single", []));
  // The inventory drift the T7 seam actually has to survive: a term that is on
  // NEITHER side. It is what a corpus addition looks like when the derivation is
  // replaced by a hand-maintained list, and it leaves the anti-rot tier unable
  // to say whether the pane's silence about that term is honest or a hole.
  const droppedSlug = seam.manualNoRunValueSlugs[0];
  const partialInventory = Object.freeze({...seam, manualNoRunValueSlugs: Object.freeze(seam.manualNoRunValueSlugs.filter((slug) => slug !== droppedSlug))});
  families += expectRed("manual_inventory_partition", "manual_inventory_not_a_partition", partialInventory, (tampered) => checkManualRunInventory(tampered));
  // And a MUTABLE inventory, which a consumer could rewrite in place.
  const thawedInventory = Object.freeze({...seam, manualNoRunValueSlugs: [...seam.manualNoRunValueSlugs]});
  families += expectRed("manual_inventory_freeze", "manual_inventory_not_frozen", thawedInventory, (tampered) => checkManualRunInventory(tampered));
  // Every tamper below rewrites routeHash, and the assertions they must bite on
  // are driven through manualRoute — which on the real seam is a CLOSURE over
  // the real routeHash, so a spread that overrides routeHash alone never
  // reaches it and leaves those assertions permanently green. Each tampered
  // seam therefore rebuilds manualRoute on top of its own tampered routeHash,
  // exactly as app.js builds the real one.
  const withManualRoute = (tamperedHash) => (route, slug) => tamperedHash({...route, manual: slug === null || slug === undefined ? null : seam.manualField(slug)});
  // A manual that is parsed but never SERIALIZED silently loses the pane on
  // every navigation; the field-wise round-trip must catch that too.
  const manualNotSerializedHash = (route) => seam.routeHash({...route, manual: null});
  const manualNotSerialized = Object.freeze({...seam, routeHash: manualNotSerializedHash, manualRoute: withManualRoute(manualNotSerializedHash)});
  families += expectRed("manual_serialization", "manual_not_carried", manualNotSerialized, (tampered) => checkRoundTrip(tampered, "single", []));
  // The PARTIAL-LITERAL regression, which neither family above can reach: both
  // tamper the seam in ways the whole-route assertions catch, while the defect
  // here is a routeHash that reads an ABSENT manual field as a request to close
  // the pane. That is exactly what every in-view control's fresh partial literal
  // produces, and the whole-route round-trip stays green against it because it
  // always spreads the canonical route. The tampered seam inherits the real
  // seam's location stub so the ambient-hash leg can run against it.
  const manualDroppedOnPartialHash = (route) => seam.routeHash(Object.prototype.hasOwnProperty.call(route ?? {}, "manual") ? route : {...route, manual: null});
  const manualDroppedOnPartial = Object.freeze({...seam, routeHash: manualDroppedOnPartialHash, manualRoute: withManualRoute(manualDroppedOnPartialHash)});
  SEAM_LOCATIONS.set(manualDroppedOnPartial, SEAM_LOCATIONS.get(seam));
  families += expectRed("manual_partial_literal", "manual_dropped_by_partial_route", manualDroppedOnPartial, (tampered) => checkRoundTrip(tampered, "single", []));
  // The UNAVAILABLE-ROUTE demotion, restored exactly: a routeHash with no
  // serialization for `view: "invalid"`, which falls through to the runs-path
  // construction and invents a destination for the one view that names none.
  // This is what shipped, and none of the families above can see it — every one
  // of them drives routes whose path IS rebuildable from the parsed fields, so
  // the fall-through produces the right answer for them and only the unavailable
  // route is silently navigated away from.
  const invalidDemotedHash = (route) => seam.routeHash(route && route.view === "invalid" ? {...route, view: "runs", invalidPath: undefined} : route);
  const invalidRouteDemoted = Object.freeze({...seam, routeHash: invalidDemotedHash, manualRoute: withManualRoute(invalidDemotedHash)});
  SEAM_LOCATIONS.set(invalidRouteDemoted, SEAM_LOCATIONS.get(seam));
  families += expectRed("manual_invalid_route", "manual_demoted_invalid_route", invalidRouteDemoted, (tampered) => checkRoundTrip(tampered, "single", []));
  // The DEAD LINK: a label mapped to a slug the corpus does not carry. This is
  // the failure the affordance's refusal exists to make loud, and it is
  // completely invisible on screen — the label renders, the dotted underline
  // paints, and only a click lands on the manual's unknown-slug page.
  const deadLink = Object.freeze({...seam, labelledTerms: Object.freeze({...seam.labelledTerms, Execution: "no-such-term"}), labelledTermSlug: (label) => (label === "Execution" ? "no-such-term" : seam.labelledTermSlug(label))});
  families += expectRed("labelled_term_dead_link", "labelled_term_dead_link", deadLink, (tampered) => checkLabelledTerms(tampered));
  // The SILENT DEGRADATION: a resolver that answers a falsy slug for an
  // unmapped label instead of refusing. That is the shape a well-meaning
  // "don't crash the render" patch takes, and it is precisely what turns a red
  // build into a dead link nobody notices.
  const softRefusal = Object.freeze({...seam, labelledTermSlug: (label) => (Object.prototype.hasOwnProperty.call(seam.labelledTerms, label) ? seam.labelledTerms[label] : "")});
  families += expectRed("labelled_term_refusal", "labelled_term_refusal_absent", softRefusal, (tampered) => checkLabelledTerms(tampered));
  // THE MISATTRIBUTION: a refusal that throws a plain Error. This is what
  // shipped before the defect class, and it is the subtlest of the three
  // because the refusal LOOKS present — the function throws, the direct-call
  // check above is satisfied, and only the guarded render path reveals that the
  // operator is shown "The fetched projection could not be displayed." with the
  // label name gone. The tamper restores exactly that behavior, so if the
  // classification assertion is ever weakened this family stops going red.
  const plainErrorRefusal = Object.freeze({...seam, labelledTermSlug: (label) => {
    if (Object.prototype.hasOwnProperty.call(seam.labelledTerms, label)) return seam.labelledTerms[label];
    throw new Error("labelledTermSlug: no glossary term is mapped for the shipped label " + JSON.stringify(label));
  }});
  families += expectRed("labelled_term_misattribution", "labelled_term_refusal_misattributed", plainErrorRefusal, (tampered) => checkLabelledTerms(tampered));
  // THE MIRROR-IMAGE LIE: a classifier that claims genuine upstream failures as
  // Monitor defects, which would repaint a real projection outage as our bug
  // and send the operator away from the evidence that is actually broken.
  const overreachingClassifier = Object.freeze({...seam, isMonitorDefect: () => true});
  families += expectRed("labelled_term_defect_overreach", "labelled_term_defect_overreach", overreachingClassifier, (tampered) => checkLabelledTerms(tampered));
  return families;
}

// ── Main ─────────────────────────────────────────────────────────────────────

let exitCode = 0;
let output;
try {
  const options = parseArgs(process.argv.slice(2));
  const appSource = readFileSync(options.app, "utf8");

  const single = loadSeam(appSource, null);
  const set = loadSeam(appSource, {mode: "workspace_set", workspaces: ["left", "right"]});

  const redProofFamilies = checkRedProof(single);
  const roundtripSingle = checkRoundTrip(single, "single", []);
  const roundtripSet = checkRoundTrip(set, "set", ["left", "right"]);
  const visibleCases = checkVisible(single);
  const comparator = checkComparator(single);
  const childResolutionCases = checkChildResolution(single);
  const glossary = checkGlossary(single);
  const manualRunInventory = checkManualRunInventory(single);
  const labelledTerms = checkLabelledTerms(single);

  output = {
    ok: true,
    check: "pixir_monitor_ui_seam",
    executed_in: "node_vm_fail_closed_stub",
    roundtrip: {
      single: {cases: roundtripSingle.cases, coverage: roundtripSingle.coverage},
      workspace_set: {cases: roundtripSet.cases, coverage: roundtripSet.coverage}
    },
    visible_cases: visibleCases,
    comparator,
    child_resolution_cases: childResolutionCases,
    glossary,
    manual_run_inventory: manualRunInventory,
    labelled_terms: labelledTerms,
    red_proof_families: redProofFamilies
  };
} catch (error) {
  exitCode = 1;
  output = safeError(error);
}
process.stdout.write(`${JSON.stringify(output)}\n`);
process.exitCode = exitCode;
