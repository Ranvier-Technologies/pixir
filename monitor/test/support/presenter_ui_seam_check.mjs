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
    location: failClosed("location", {hash: ""}),
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

function loadSeam(appSource, workspaceSetConfig) {
  const sandbox = buildSandbox(workspaceSetConfig);
  vm.createContext(sandbox);
  vm.runInContext(appSource, sandbox, {filename: "app.js"});
  const seam = sandbox.window.PixirMonitorUI;
  if (!seam || typeof seam.parseRoute !== "function" || typeof seam.routeHash !== "function" || typeof seam.visible !== "function" || typeof seam.runsComparator !== "function") {
    throw failure("seam_missing", "window.PixirMonitorUI did not expose the expected frozen members", "load_app");
  }
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

function generateRoute(rand, mode, workspaces) {
  const view = pick(rand, ["runs", "detail", "unit"]);
  const route = {view, filters: {}, sort: pick(rand, [...SORTS, undefined]), q: pick(rand, QUERIES), follow: rand() < 0.3};
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
  const coverage = {view_runs: 0, view_detail: 0, view_unit: 0, with_attempt: 0, with_zoom: 0, with_arc: 0, with_member_page: 0, with_edge_page: 0, bogus_filter_dropped: 0};
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
    for (const fieldName of ["view", "runId", "unitId", "attemptId", "workspace", "sort", "q", "follow", "zoomStart", "selectedCluster", "selectedArc", "memberPage", "edgePage"]) {
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
    coverage[`view_${route.view}`] += 1;
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
  // A REACHABLE bookmark corpus with EXACT expected canonical hashes
  // (hand-derived from the routeHash contract and byte-pinned): a consistent
  // serializer corruption cannot hide behind mere stability. Note the
  // contract quirk pinned on purpose: routeHash always emits run-shaped
  // paths, so the set-mode overview bookmark canonicalizes to the FIRST
  // configured workspace's runs list.
  const corpus = mode === "set"
    ? [
        ["#/workspaces", "#/workspaces/left/runs"],
        ["#/workspaces/left/runs", "#/workspaces/left/runs"],
        ["#/workspaces/right/runs/20260715T000000-a1b2c3?follow=1", "#/workspaces/right/runs/20260715T000000-a1b2c3?follow=1"],
        ["#/workspaces/left/runs/20260715T000000-a1b2c3?cluster=wave%3A0%3Abucket%3A0&members=2&zoom=6", "#/workspaces/left/runs/20260715T000000-a1b2c3?zoom=6&cluster=wave%3A0%3Abucket%3A0&members=2"]
      ]
    : [
        ["#/runs", "#/runs"],
        ["#/runs?execution=held", "#/runs?execution=held"],
        ["#/runs/20260715T000000-a1b2c3?follow=1", "#/runs/20260715T000000-a1b2c3?follow=1"],
        ["#/runs/20260715T000000-a1b2c3/units/workflow%3Azoom%3Astep%3Aa?attempt=attempt%3A1", "#/runs/20260715T000000-a1b2c3/units/workflow%3Azoom%3Astep%3Aa?attempt=attempt%3A1"],
        ["#/runs/20260715T000000-a1b2c3?cluster=wave%3A0%3Abucket%3A0&members=2&zoom=6&arc=arc%3A0", "#/runs/20260715T000000-a1b2c3?zoom=6&cluster=wave%3A0%3Abucket%3A0&arc=arc%3A0&members=2"]
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

// ── Red proof: before trusting green, prove each family goes red against a
// deliberately broken seam (the #362 red-proof idiom). Deleting an assertion
// body can no longer keep the run green, because the tampered variant would
// stop failing.

function expectRed(family, tamperedSeam, run) {
  try {
    run(tamperedSeam);
  } catch (error) {
    if (error && error.harnessKind) return 1;
    throw error;
  }
  throw failure("red_proof_failed", `The ${family} checks stayed green against a deliberately broken seam`, "red_proof", {family});
}

function checkRedProof(seam) {
  let families = 0;
  const corruptedHash = Object.freeze({...seam, routeHash: (route) => {
    const hash = seam.routeHash(route);
    return hash + (hash.includes("?") ? "&" : "?") + "redproof=1";
  }});
  families += expectRed("roundtrip", corruptedHash, (tampered) => checkRoundTrip(tampered, "single", []));
  const corruptedVisible = Object.freeze({...seam, visible: (value) => {
    const shown = seam.visible(value);
    return {...shown, text: shown.text.slice(0, 2)};
  }});
  families += expectRed("visible", corruptedVisible, (tampered) => checkVisible(tampered));
  const invertedComparator = Object.freeze({...seam, runsComparator: (sort) => {
    const comparator = seam.runsComparator(sort);
    return (a, b) => -comparator(a, b);
  }});
  families += expectRed("comparator", invertedComparator, (tampered) => checkComparator(tampered));
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
    red_proof_families: redProofFamilies
  };
} catch (error) {
  exitCode = 1;
  output = safeError(error);
}
process.stdout.write(`${JSON.stringify(output)}\n`);
process.exitCode = exitCode;
