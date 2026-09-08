#!/usr/bin/env node

// Executes the REAL stateful inventory-acquisition/repaint cycle of app.js in
// node:vm against a COUNTING fetch stub and a minimal DOM. This is the part of
// issue #438 that source-text pins and the pure-resolver seam cannot reach: the
// only loop-capable code in the change.
//
// The load-bearing property is BOUNDEDNESS. renderProjectionFailure repaints the
// dead end, the repaint re-enters the acquisition call site, and the acquisition
// completing triggers another repaint. If the acquired inventory comes back
// EMPTY or FAILED — precisely the brief's "evidence unavailable" case — a guard
// that is released before the repaint runs turns that cycle into an unbounded
// request storm against /api/runs (single mode) or /api/workspaces/<ws>/runs
// (workspace-set mode). Every scenario below therefore asserts an EXACT fetch
// count, and the harness caps requests so a runaway fails loudly instead of
// hanging.
//
// No Chrome, no npm: the same evidence tier as the presenter UI seam check and
// the bootstrap behavior check.

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
  return {ok: false, error: {kind: error?.harnessKind || "child_resolution_acquisition_check_failed", message: error?.harnessKind ? error.message : `The child resolution acquisition check failed unexpectedly: ${error?.message}`, details: {stage: error?.harnessStage || "unknown", ...(error?.safeDetails || {})}}};
}

function parseArgs(argv) {
  const options = {};
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === "--json") continue;
    if (["--app"].includes(arg)) options[arg.slice(2)] = argv[++index];
    else throw failure("invalid_args", "Unknown acquisition check argument", "parse_args");
  }
  if (!options.app) throw failure("missing_required_arg", "Missing required --app", "validate_args");
  return options;
}

// A runaway acquisition loop would otherwise spin forever inside the microtask
// queue. The cap converts it into a deterministic red result.
const REQUEST_CAP = 40;

// ── Minimal DOM ──────────────────────────────────────────────────────────────
//
// Only the surface the dead-end renderers actually touch. Anything they reach
// for that is not modeled throws, so a renderer growing a new DOM dependency
// surfaces here as an explicit failure rather than a silent pass.

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
    addEventListener() {},
    focus() {},
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
  return node;
}

// Supports exactly the selector shapes the dead-end code path uses:
// ".error-view", ".error-view[data-follow-state]", "details[data-disclosure-key]",
// "[data-focus-key]", and "a".
function matchesSelector(node, selector) {
  const classMatch = selector.match(/^\.([A-Za-z0-9_-]+)/);
  if (classMatch && !node.classList.contains(classMatch[1])) return false;
  const tagMatch = selector.match(/^([a-z]+)(?:\[|$)/);
  if (tagMatch && node.tagName !== tagMatch[1]) return false;
  const attrMatch = selector.match(/\[data-([A-Za-z-]+)\]/);
  if (attrMatch) {
    const camel = attrMatch[1].replace(/-([a-z])/g, (_all, letter) => letter.toUpperCase());
    if (node.dataset[camel] === undefined) return false;
  }
  return true;
}

function buildDom(workspaceSetConfig) {
  const app = createElement("div");
  app.id = "app";
  const status = createElement("p");
  status.id = "status";
  const shell = createElement("main");
  if (workspaceSetConfig) shell.setAttribute("data-workspace-set", JSON.stringify(workspaceSetConfig));
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
  // Elements created after load must still be findable by id (announce() and
  // setStatus() both mint singletons keyed by id and would otherwise re-create
  // them on every repaint, masking repaint counts).
  const originalCreate = documentStub.createElement;
  documentStub.createElement = (tagName) => {
    const node = originalCreate(tagName);
    let currentId = "";
    Object.defineProperty(node, "id", {
      get: () => currentId,
      set: (value) => { currentId = String(value); byId[currentId] = node; },
      configurable: true
    });
    return node;
  };
  body.append(app, status);
  return {documentStub, app, status, shell};
}

// ── Scenario execution ───────────────────────────────────────────────────────

function jsonResponse(status, payload) {
  return {ok: status >= 200 && status < 300, status, json: () => Promise.resolve(payload)};
}

// The bootstrap promise never resolves, so app.js never starts itself. The
// harness enters through the REAL navigation path instead of poking an
// internal: it captures the hashchange listener app.js registers on window and
// fires it, which is exactly what the browser does when an operator opens a
// child-id bookmark.
async function runNavigated(appSource, scenario) {
  const {documentStub, app} = buildDom(scenario.workspaceSet || null);
  const requests = [];
  let overflowed = false;
  const fetchStub = (path) => {
    requests.push(path);
    // Past the cap the stub goes INERT — a promise that never settles. A
    // rejection would be caught by the very repaint path under test and would
    // feed the runaway another turn, hanging the harness instead of failing it.
    // Never settling drains the microtask queue, so the turn loop below ends and
    // the overflow is reported as a red result.
    if (requests.length > REQUEST_CAP) { overflowed = true; return new Promise(() => {}); }
    const reply = scenario.reply(path, requests.length);
    if (reply === "network_error") return Promise.reject(new TypeError("network down"));
    return Promise.resolve(jsonResponse(reply.status, reply.payload));
  };
  const windowListeners = new Map();
  const sandbox = {
    window: {
      addEventListener(type, handler) { windowListeners.set(type, handler); },
      scrollX: 0, scrollY: 0, scrollTo() {},
      __pixirBootstrap: new Promise(() => {})
    },
    document: documentStub,
    location: {hash: scenario.hash},
    history: {replaceState() {}},
    fetch: fetchStub,
    EventSource: function () { return {addEventListener() {}, close() {}}; },
    // No timer globals: production currently uses none on this route. A future
    // timer must get an explicit execution model, not a callback-swallowing stub.
    queueMicrotask,
    URLSearchParams, URL, Set, Map, Object, Array, Number, String, JSON, Math, Date, RegExp, Error, TypeError, Promise, Boolean, Symbol, Intl,
    console: {log() {}, warn() {}, error() {}, debug() {}, info() {}}
  };
  sandbox.globalThis = sandbox;
  sandbox.self = sandbox;
  vm.createContext(sandbox);
  vm.runInContext(appSource, sandbox, {filename: "app.js"});

  const hashchange = windowListeners.get("hashchange");
  if (typeof hashchange !== "function") throw failure("hashchange_missing", "app.js registered no hashchange listener", scenario.name);
  hashchange();
  for (let turn = 0; turn < 60; turn += 1) await new Promise((resolve) => setImmediate(resolve));

  return {name: scenario.name, requests: requests.slice(), overflowed, app};
}

const RUN_ID = "child-session-abcdef";
const PARENT_ID = "20260715T000000-parent";

const NOT_FOUND = {status: 404, payload: {error: {kind: "run_not_found"}}};
const EMPTY_LIST = {status: 200, payload: {runs: []}};
const RESOLVING_LIST = {status: 200, payload: {runs: [{id: PARENT_ID, children: [{session_id: RUN_ID, unit_id: "step:review"}]}]}};

function isDetail(path) { return path.includes("/runs/"); }
function isList(path) { return !isDetail(path); }

const SCENARIOS = [
  // ── The defect, in single mode, on the brief's own "evidence unavailable"
  // case: the acquired inventory is EMPTY, so every repaint finds the dead end
  // still unresolved. Acquisition must happen ONCE and stop.
  {
    name: "single_empty_inventory_bounded",
    hash: `#/runs/${RUN_ID}?follow=1`,
    reply: (path) => (isDetail(path) ? NOT_FOUND : EMPTY_LIST),
    expect: {detail: 1, list: 1}
  },
  // Same dead end, but the inventory acquisition itself FAILS. refetch's catch
  // stores only a listError and never a list snapshot, so heldInventoryRows
  // stays empty forever — the second way the same loop opens.
  {
    name: "single_failing_inventory_bounded",
    hash: `#/runs/${RUN_ID}?follow=1`,
    reply: (path) => (isDetail(path) ? NOT_FOUND : "network_error"),
    expect: {detail: 1, list: 1}
  },
  // The non-follow "Projection unavailable" dead end reaches the same call site.
  {
    name: "single_non_follow_empty_inventory_bounded",
    hash: `#/runs/${RUN_ID}`,
    reply: (path) => (isDetail(path) ? NOT_FOUND : EMPTY_LIST),
    expect: {detail: 1, list: 1}
  },
  // Workspace-set mode: refetchWorkspaceList's catch path is the one the
  // verifier named explicitly. It must also acquire exactly once.
  {
    name: "workspace_set_failing_inventory_bounded",
    hash: `#/workspaces/left/runs/${RUN_ID}?follow=1`,
    workspaceSet: {mode: "workspace_set", workspaces: ["left", "right"]},
    reply: (path) => (isDetail(path) ? NOT_FOUND : "network_error"),
    expect: {detail: 1, list: 1}
  },
  {
    name: "workspace_set_empty_inventory_bounded",
    hash: `#/workspaces/left/runs/${RUN_ID}?follow=1`,
    workspaceSet: {mode: "workspace_set", workspaces: ["left", "right"]},
    reply: (path) => (isDetail(path) ? NOT_FOUND : {status: 200, payload: {workspace: "left", snapshot: {runs: []}}}),
    expect: {detail: 1, list: 1}
  },
  // The SUCCESS path must still work: one acquisition, and the repaint that
  // follows it renders the resolved parent affordance. Boundedness must not have
  // been bought by disabling resolution.
  {
    name: "single_resolving_inventory_renders_parent",
    hash: `#/runs/${RUN_ID}?follow=1`,
    reply: (path) => (isDetail(path) ? NOT_FOUND : RESOLVING_LIST),
    expect: {detail: 1, list: 1},
    expectResolved: PARENT_ID
  }
];

function countRequests(requests) {
  return {detail: requests.filter(isDetail).length, list: requests.filter(isList).length};
}

function collectText(node, out = []) {
  if (!node || typeof node !== "object") return out;
  if (node.textContent) out.push(node.textContent);
  for (const child of node.children || []) collectText(child, out);
  return out;
}

async function checkScenario(appSource, scenario) {
  const result = await runNavigated(appSource, scenario);
  if (result.overflowed) {
    throw failure("acquisition_unbounded", "The inventory acquisition ran away: the dead end kept issuing authoritative list requests instead of converging after one attempt", scenario.name, {requests: result.requests.length, cap: REQUEST_CAP, sample: result.requests.slice(0, 6)});
  }
  const counts = countRequests(result.requests);
  if (counts.list !== scenario.expect.list) {
    throw failure("acquisition_count_mismatch", "The dead end did not acquire the scoped inventory exactly once", scenario.name, {expected_list_requests: scenario.expect.list, observed_list_requests: counts.list, requests: result.requests});
  }
  if (counts.detail !== scenario.expect.detail) {
    throw failure("detail_count_mismatch", "The dead end issued an unexpected number of authoritative detail requests", scenario.name, {expected: scenario.expect.detail, observed: counts.detail, requests: result.requests});
  }
  const rendered = collectText(result.app).join("\n");
  if (scenario.expectResolved) {
    if (!rendered.includes("Parent-observed child Session") || !rendered.includes(scenario.expectResolved)) {
      throw failure("resolution_not_rendered", "A resolving inventory did not repaint the dead end with the owning parent affordance", scenario.name, {rendered: rendered.slice(0, 400)});
    }
  } else if (rendered.includes("Parent-observed child Session")) {
    throw failure("resolution_fabricated", "An unresolvable dead end rendered a parent affordance anyway", scenario.name, {rendered: rendered.slice(0, 400)});
  }
  return {name: scenario.name, list_requests: counts.list, detail_requests: counts.detail};
}

// ── Red proof ────────────────────────────────────────────────────────────────
//
// Before trusting green, prove the boundedness family BITES: patch the app
// source back to the pre-fix guard discipline (release the single-flight handle
// BEFORE the repaint, with no per-id attempt marker) and require the empty-
// inventory scenario to go red. A harness that cannot detect the original defect
// is not evidence.

function tamperUnbounded(appSource) {
  let tampered = appSource.replace(
    'if (state.resolutionInFlight || state.resolutionAttemptedFor === route.runId) return;\n    state.resolutionAttemptedFor = route.runId;',
    "if (state.resolutionInFlight) return;"
  );
  if (tampered === appSource) throw failure("tamper_target_missing", "The acquisition guard no longer matches the shape the red proof patches; update the red proof rather than deleting it", "red_proof");
  const before = tampered;
  tampered = tampered.replace(
    'try {\n        if (failure && current.runId === route.runId && state.resolutionFor === route.runId && app.querySelector(".error-view")) renderProjectionFailureSafely(failure);\n      } finally { state.resolutionInFlight = null; }',
    'state.resolutionInFlight = null;\n      if (failure && current.runId === route.runId && state.resolutionFor === route.runId && app.querySelector(".error-view")) renderProjectionFailureSafely(failure);'
  );
  if (tampered === before) throw failure("tamper_target_missing", "The acquisition repaint no longer matches the shape the red proof patches; update the red proof rather than deleting it", "red_proof");
  return tampered;
}

async function checkRedProof(appSource) {
  const tampered = tamperUnbounded(appSource);
  const scenario = SCENARIOS[0];
  try {
    await checkScenario(tampered, scenario);
  } catch (error) {
    if (error && error.harnessKind === "acquisition_unbounded") return {family: "acquisition_boundedness", detected: "acquisition_unbounded"};
    if (error && error.harnessKind === "acquisition_count_mismatch") return {family: "acquisition_boundedness", detected: "acquisition_count_mismatch"};
    throw error;
  }
  throw failure("red_proof_failed", "The boundedness check stayed green against a deliberately unbounded acquisition guard", "red_proof");
}

async function main() {
  const options = parseArgs(process.argv.slice(2));
  const appSource = readFileSync(options.app, "utf8");
  const redProof = await checkRedProof(appSource);
  const scenarios = [];
  for (const scenario of SCENARIOS) scenarios.push(await checkScenario(appSource, scenario));
  return {ok: true, check: "pixir_monitor_child_resolution_acquisition", executed_in: "node_vm_minimal_dom", request_cap: REQUEST_CAP, red_proof: redProof, scenarios};
}

main().then(
  (result) => { process.stdout.write(`${JSON.stringify(result)}\n`); process.exit(0); },
  (error) => { process.stdout.write(`${JSON.stringify(safeError(error))}\n`); process.exit(1); }
);
