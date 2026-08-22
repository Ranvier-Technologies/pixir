#!/usr/bin/env node

// Executes the compact unit-summary advisory chip of #554 in node:vm against a
// minimal DOM, over the golden fixtures (and the overlay-shaped invalid+stop
// unit). Source-string pins cannot reach this defect: the chip used to titleCase
// the raw verdict while the Unit Inspector card and the ON THIS RUN pane already
// classify through unitAdvisoryBucket (invalid-first) + ADVISORY_DISPLAY_ALIASES.
//
// The check paints the real renderers — cluster-inspector chips via unitSummary,
// the Inspector card via labeledTruthCard, the pane via manualUnitAdvisoryLabel —
// and requires the visible WORD to be byte-equal across those three surfaces.
// Marker TONE stays keyed on the raw projection token; that class must not move.
//
// No Chrome, no npm: the same evidence tier as the presenter UI seam check.

import {readFileSync} from "node:fs";
import {join} from "node:path";
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
  return {ok: false, error: {kind: error?.harnessKind || "unit_summary_advisory_chip_check_failed", message: error?.harnessKind ? error.message : `The unit-summary advisory chip check failed unexpectedly: ${error?.message}`, details: {stage: error?.harnessStage || "unknown", ...(error?.safeDetails || {})}}};
}

function parseArgs(argv) {
  const options = {};
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === "--json") continue;
    if (["--app", "--golden-dir"].includes(arg)) options[arg.slice(2)] = argv[++index];
    else throw failure("invalid_args", "Unknown unit-summary advisory chip check argument", "parse_args");
  }
  if (!options.app) throw failure("missing_required_arg", "Missing required --app", "validate_args");
  if (!options["golden-dir"]) throw failure("missing_required_arg", "Missing required --golden-dir", "validate_args");
  return options;
}

function createElement(tagName) {
  const node = {
    tagName: String(tagName).toLowerCase(),
    className: "",
    textContent: "",
    children: [],
    attributes: new Map(),
    dataset: {},
    style: {},
    open: false,
    parentNode: null,
    classList: {
      add(...names) { node.className = [node.className, ...names].filter(Boolean).join(" "); },
      contains(name) { return node.className.split(/\s+/).includes(name); }
    },
    setAttribute(name, value) { node.attributes.set(String(name), String(value)); },
    getAttribute(name) { return node.attributes.has(String(name)) ? node.attributes.get(String(name)) : null; },
    hasAttribute(name) { return node.attributes.has(String(name)); },
    removeAttribute(name) { node.attributes.delete(String(name)); },
    addEventListener() {},
    focus() { if (node.ownerDocumentStub) node.ownerDocumentStub.activeElement = node; },
    append(...nodes) { for (const child of nodes) { if (child && typeof child === "object") child.parentNode = node; node.children.push(child); } },
    prepend(...nodes) { for (const child of nodes.reverse()) { if (child && typeof child === "object") child.parentNode = node; node.children.unshift(child); } },
    replaceChildren(...nodes) { node.children = []; node.append(...nodes); },
    insertAdjacentElement(_position, element) { if (node.parentNode) node.parentNode.append(element); return element; },
    closest() { return null; },
    querySelector(selector) { return node.querySelectorAll(selector)[0] || null; },
    querySelectorAll(selector) {
      const matches = [];
      const walk = (current) => {
        for (const child of current.children) {
          if (child && typeof child === "object" && child.tagName) {
            if (matchesSelector(child, selector)) matches.push(child);
            walk(child);
          }
        }
      };
      walk(node);
      return matches;
    }
  };
  Object.defineProperty(node, "firstChild", {get: () => node.children[0] || null, configurable: true});
  Object.defineProperty(node, "childNodes", {get: () => node.children, configurable: true});
  return node;
}

function matchesSelector(node, selector) {
  const classMatch = selector.match(/^\.([A-Za-z0-9_-]+)/);
  if (classMatch && !node.classList.contains(classMatch[1])) return false;
  const tagMatch = selector.match(/^([a-z]+)(?:\[|#|\.|$)/);
  if (tagMatch && node.tagName !== tagMatch[1]) return false;
  const attrEq = selector.match(/\[data-([A-Za-z-]+)="([^"]+)"\]/);
  if (attrEq) {
    const camel = attrEq[1].replace(/-([a-z])/g, (_all, letter) => letter.toUpperCase());
    if (node.dataset[camel] !== attrEq[2]) return false;
  } else {
    const attrMatch = selector.match(/\[data-([A-Za-z-]+)\]/);
    if (attrMatch) {
      const camel = attrMatch[1].replace(/-([a-z])/g, (_all, letter) => letter.toUpperCase());
      if (node.dataset[camel] === undefined) return false;
    }
  }
  return true;
}

function buildDom() {
  const app = createElement("div");
  app.id = "app";
  const status = createElement("p");
  status.id = "status";
  const shell = createElement("main");
  const body = createElement("body");
  body.append(shell);
  const byId = {app, status};
  const documentStub = {
    body,
    activeElement: null,
    getElementById: (id) => byId[id] || null,
    createElement,
    querySelector: (selector) => (selector === "body > main" ? shell : body.querySelector(selector)),
    querySelectorAll: (selector) => body.querySelectorAll(selector),
    addEventListener() {}
  };
  documentStub.activeElement = body;
  for (const node of [app, status, shell, body]) node.ownerDocumentStub = documentStub;
  const originalCreate = documentStub.createElement;
  documentStub.createElement = (tagName) => {
    const node = originalCreate(tagName);
    node.ownerDocumentStub = documentStub;
    let currentId = "";
    Object.defineProperty(node, "id", {
      get: () => currentId,
      set: (value) => { currentId = String(value); byId[currentId] = node; },
      configurable: true
    });
    return node;
  };
  body.append(app, status);
  return {documentStub, app, status};
}

function jsonResponse(status, payload) {
  return {ok: status >= 200 && status < 300, status, json: () => Promise.resolve(payload)};
}

function walk(node, visit) {
  if (!node || typeof node !== "object" || !node.tagName) return;
  visit(node);
  for (const child of node.children || []) walk(child, visit);
}

function findNodes(root, predicate) {
  const found = [];
  walk(root, (node) => { if (predicate(node)) found.push(node); });
  return found;
}

function markerToneClass(node) {
  return String(node.className || "").split(/\s+/).find((name) => name.startsWith("marker-") && name !== "marker") || null;
}

function advisoryChip(unitCard) {
  const header = (unitCard.children || []).find((child) => child.tagName === "header");
  if (!header) return null;
  const marker = (header.children || []).find((child) => child.dataset && child.dataset.dimension === "advisory");
  if (!marker) return null;
  return {word: marker.textContent, tone: markerToneClass(marker)};
}

function advisoryCard(app) {
  const card = findNodes(app, (node) => node.classList.contains("truth-card") && node.dataset.truthDimension === "advisory")[0];
  if (!card) return null;
  const marker = (card.children || []).find((child) => child.classList && child.classList.contains("marker"));
  if (!marker) return null;
  return {word: marker.textContent, tone: markerToneClass(marker)};
}

function paneWord(app) {
  const value = findNodes(app, (node) => node.classList.contains("manual-run-value"))[0];
  return value ? value.textContent : null;
}

function loadGolden(goldenDir, id) {
  return JSON.parse(readFileSync(join(goldenDir, `${id}.json`), "utf8"));
}

function cloneProjection(projection) {
  return JSON.parse(JSON.stringify(projection));
}

function withAdvisory(projection, advisory) {
  const next = cloneProjection(projection);
  const unit = next.units[0];
  unit.advisory = Object.assign({}, unit.advisory, advisory);
  return next;
}

async function paint(appSource, projection, hash) {
  const {documentStub, app} = buildDom();
  const requests = [];
  const fetchStub = (path) => {
    requests.push(path);
    if (String(path).includes("/api/runs/") && String(path).includes(encodeURIComponent(projection.run.id))) {
      return Promise.resolve(jsonResponse(200, projection));
    }
    if (String(path) === `/api/runs/${projection.run.id}`) {
      return Promise.resolve(jsonResponse(200, projection));
    }
    return Promise.resolve(jsonResponse(404, {error: {kind: "run_not_found"}}));
  };
  const windowListeners = new Map();
  const locationStub = {hash};
  const sandbox = {
    window: {
      addEventListener(type, handler) { windowListeners.set(type, handler); },
      scrollX: 0, scrollY: 0, scrollTo() {},
      __pixirBootstrap: new Promise(() => {})
    },
    document: documentStub,
    location: locationStub,
    history: {replaceState() {}, state: null},
    fetch: fetchStub,
    EventSource: function () { return {addEventListener() {}, close() {}}; },
    setTimeout: (fn) => { void fn; return 0; },
    clearTimeout() {}, setInterval: () => 0, clearInterval() {},
    queueMicrotask,
    requestAnimationFrame: (fn) => { void fn; return 0; },
    URLSearchParams, URL, Set, Map, Object, Array, Number, String, JSON, Math, Date, RegExp, Error, TypeError, Promise, Boolean, Symbol, Intl,
    console: {log() {}, warn() {}, error() {}, debug() {}, info() {}}
  };
  sandbox.globalThis = sandbox;
  sandbox.self = sandbox;
  vm.createContext(sandbox);
  vm.runInContext(appSource, sandbox, {filename: "app.js"});
  const hashchange = windowListeners.get("hashchange");
  if (typeof hashchange !== "function") throw failure("hashchange_missing", "app.js registered no hashchange listener", hash);
  const settle = async () => { for (let turn = 0; turn < 60; turn += 1) await new Promise((resolve) => setImmediate(resolve)); };
  hashchange();
  await settle();
  return {app, locationStub, hashchange, settle, requests};
}

async function navigate(session, hash) {
  session.locationStub.hash = hash;
  session.hashchange();
  await session.settle();
}

async function readChip(appSource, projection, unitId) {
  const runId = projection.run.id;
  const session = await paint(appSource, projection, `#/runs/${encodeURIComponent(runId)}`);
  const inspect = findNodes(session.app, (node) => node.tagName === "a" && typeof node.href === "string" && node.href.includes("cluster="));
  if (!inspect.length) throw failure("cluster_inspect_missing", "The painted run detail exposed no cluster inspect link, so the compact chip was never built", unitId, {run_id: runId});
  for (const link of inspect) {
    await navigate(session, link.href);
    const card = findNodes(session.app, (node) => node.classList.contains("unit-card") && node.dataset.unitId === unitId)[0];
    if (!card) continue;
    const chip = advisoryChip(card);
    if (!chip) throw failure("advisory_chip_missing", "A present-advisory unit card painted no advisory chip", unitId, {run_id: runId});
    return chip;
  }
  throw failure("unit_card_missing", "No cluster inspector painted the requested unit's compact card", unitId, {run_id: runId});
}

async function readCardAndPane(appSource, projection, unitId) {
  const runId = projection.run.id;
  const hash = `#/runs/${encodeURIComponent(runId)}/units/${encodeURIComponent(unitId)}?manual=model-advisory`;
  const session = await paint(appSource, projection, hash);
  const card = advisoryCard(session.app);
  if (!card) throw failure("advisory_card_missing", "The Unit Inspector painted no Model advisory card", unitId, {run_id: runId});
  const word = paneWord(session.app);
  if (word === null) throw failure("advisory_pane_missing", "The ON THIS RUN pane painted no model-advisory value", unitId, {run_id: runId});
  return {card, pane: word};
}

async function observe(appSource, projection, unitId) {
  const chip = await readChip(appSource, projection, unitId);
  const {card, pane} = await readCardAndPane(appSource, projection, unitId);
  return {chip, card, pane};
}

function expectShape(name, observed, {word, tone, rawWord}) {
  if (observed.chip.word !== word) {
    throw failure("chip_word_wrong", "The compact advisory chip painted a word that is not the classified display word", name, {expected: word, rendered: observed.chip.word});
  }
  if (rawWord && observed.chip.word === rawWord) {
    throw failure("chip_still_raw_token", "The compact advisory chip still paints the raw verdict token", name, {rendered: observed.chip.word});
  }
  if (observed.card.word !== word) {
    throw failure("card_word_wrong", "The Unit Inspector advisory card painted a different word than the classified display word", name, {expected: word, rendered: observed.card.word});
  }
  if (observed.pane !== word) {
    throw failure("pane_word_wrong", "The ON THIS RUN pane painted a different word than the classified display word", name, {expected: word, rendered: observed.pane});
  }
  if (observed.chip.word !== observed.card.word || observed.chip.word !== observed.pane) {
    throw failure("surfaces_diverged", "Chip, Inspector card, and pane are not byte-equal for the advisory word", name, {chip: observed.chip.word, card: observed.card.word, pane: observed.pane});
  }
  if (observed.chip.tone !== tone) {
    throw failure("chip_tone_moved", "The compact chip's tone class moved off the raw projection token", name, {expected: tone, rendered: observed.chip.tone});
  }
  if (observed.card.tone !== tone) {
    throw failure("card_tone_moved", "The Inspector card's tone class moved off the raw projection token", name, {expected: tone, rendered: observed.card.tone});
  }
  return {name, word: observed.chip.word, tone: observed.chip.tone, card: observed.card.word, pane: observed.pane};
}

function defectSource(appSource) {
  const from = 'if (unit.advisory && unit.advisory.present) header.append(labeledMarker(unitAdvisoryLabel(unit), unit.advisory.verdict, "advisory", "model_declared"));';
  const to = 'if (unit.advisory && unit.advisory.present) header.append(marker(unit.advisory.verdict, "advisory", "model_declared"));';
  if (!appSource.includes(from)) throw failure("chip_call_site_missing", "The shipped chip call site is gone, so the red proof cannot reinstate the raw-token defect", "red_proof");
  return appSource.replace(from, to);
}

async function checkRedProof(appSource, golden) {
  const unit = golden.units[0];
  const observed = await observe(defectSource(appSource), golden, unit.logical_id);
  if (observed.chip.word === "invalid") {
    throw failure("red_proof_stayed_green", "Reinstating marker(unit.advisory.verdict) still painted 'invalid', so this check is no longer proving the compact-chip defect", "red_proof", {rendered: observed.chip.word});
  }
  if (observed.chip.word !== "unknown") {
    throw failure("red_proof_unexpected_word", "The pre-fix chip path did not paint the raw unknown token over the golden invalid fixture", "red_proof", {rendered: observed.chip.word});
  }
  return {family: "unit_summary_advisory_chip", detected: "chip_still_raw_token", rendered: observed.chip.word};
}

async function main() {
  const options = parseArgs(process.argv.slice(2));
  const appSource = readFileSync(options.app, "utf8");
  const goldenDir = options["golden-dir"];
  const goldenInvalid = loadGolden(goldenDir, "invalid-model-advisory");
  const goldenF4 = loadGolden(goldenDir, "f4-advisory-retry-reconstructed");
  const invalidUnit = goldenInvalid.units.find((unit) => unit.advisory && unit.advisory.present === true && unit.advisory.parse_status === "invalid");
  if (!invalidUnit) throw failure("golden_invalid_missing", "The invalid-model-advisory golden no longer carries a present invalid advisory", "golden");
  const f4Stop = goldenF4.units.find((unit) => unit.advisory && unit.advisory.present === true && unit.advisory.verdict === "stop" && unit.advisory.parse_status !== "invalid");
  if (!f4Stop) throw failure("golden_f4_stop_missing", "The f4 golden no longer carries a present stop advisory", "golden");

  const overlayStopInvalid = withAdvisory(goldenInvalid, {verdict: "stop", parse_status: "invalid"});
  const unclassified = withAdvisory(goldenInvalid, {verdict: "unknown", parse_status: "ok"});
  const stop = withAdvisory(goldenInvalid, {verdict: "stop", parse_status: "valid"});
  const needsReview = withAdvisory(goldenInvalid, {verdict: "needs_review", parse_status: "valid"});
  const pass = withAdvisory(goldenInvalid, {verdict: "pass", parse_status: "valid"});

  const redProof = await checkRedProof(appSource, goldenInvalid);
  const scenarios = [
    expectShape("golden_invalid", await observe(appSource, goldenInvalid, invalidUnit.logical_id), {word: "invalid", tone: "marker-unknown", rawWord: "unknown"}),
    expectShape("overlay_stop_invalid", await observe(appSource, overlayStopInvalid, overlayStopInvalid.units[0].logical_id), {word: "invalid", tone: "marker-stop", rawWord: "stop"}),
    expectShape("present_unclassified", await observe(appSource, unclassified, unclassified.units[0].logical_id), {word: "unclassified verdict", tone: "marker-unknown", rawWord: "unknown"}),
    expectShape("present_stop", await observe(appSource, stop, stop.units[0].logical_id), {word: "stop", tone: "marker-stop"}),
    expectShape("present_needs_review", await observe(appSource, needsReview, needsReview.units[0].logical_id), {word: "needs review", tone: "marker-needs_review"}),
    expectShape("present_pass", await observe(appSource, pass, pass.units[0].logical_id), {word: "pass", tone: "marker-pass"}),
    expectShape("golden_f4_stop", await observe(appSource, goldenF4, f4Stop.logical_id), {word: "stop", tone: "marker-stop"})
  ];

  process.stdout.write(`${JSON.stringify({ok: true, check: "pixir_monitor_unit_summary_advisory_chip", executed_in: "node_vm_minimal_dom", red_proof: redProof, scenarios})}\n`);
}

main().then(
  () => process.exit(0),
  (error) => {
    process.stdout.write(`${JSON.stringify(safeError(error))}\n`);
    process.exit(1);
  }
);
