#!/usr/bin/env node

// Executes the REAL manual-overlay fast path of app.js in node:vm against a
// minimal DOM, over BOTH legs of that fast path: views that a FAILURE painted,
// and views that painted successfully.
//
// The load-bearing property is PRESERVATION. Opening the instrument manual is a
// pure overlay move: the route's underlying view did not change, so the view the
// pane opens over must come back byte-identical. The failure views are the case
// that source-text pins cannot reach, because they are NOT re-derivable from
// state: renderProjectionFailure AND refresh's own finally block deliberately set
// `state.detail = null` while leaving the view painted, so a fast path that
// re-renders from state repaints a DIFFERENT view — a "Follow degraded" pane
// silently becomes "Follow snapshot unavailable", changing the asserted Follow
// state, the provenance sentence and the status line, and replaceContent drops
// data-error-kind on the way through.
//
// The identity-conflict scenarios cover the sub-family that never reaches
// renderProjectionFailure at all: renderDetail and renderUnit bail out to the
// conflict view DIRECTLY when the authoritative snapshot names a different run
// than the route. Re-deriving those relabels a contradiction as an outage, so
// they pin that the record lives at the view-mount seams, not at the classifier.
//
// The HEALTHY scenarios cover the fast path's OTHER leg. Failure views record a
// replayable paint, so every failure scenario above runs `replayLastPaint()`; a
// successfully painted view records none, so the overlay move falls through to
// `renderCurrentGuarded()` — the re-derive-from-state leg the headline criterion
// lives on, and the one no scenario reached before. Each declares the view class
// it must paint, so a fixture the real renderers reject surfaces as a wrong-view
// failure rather than silently retesting the failure leg.
//
// Every scenario therefore snapshots the painted view BEFORE the manual-only
// hashchange and requires an EXACT match after it, across data-follow-state,
// data-unavailable-class, the app-level error diagnostic, the status line and
// the full text of the view — with the manual pane itself excluded, since
// mounting it is the one legitimate difference.
//
// No Chrome, no npm: the same evidence tier as the child resolution acquisition
// check and the presenter UI seam check.

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
  return {ok: false, error: {kind: error?.harnessKind || "manual_overlay_preservation_check_failed", message: error?.harnessKind ? error.message : `The manual overlay preservation check failed unexpectedly: ${error?.message}`, details: {stage: error?.harnessStage || "unknown", ...(error?.safeDetails || {})}}};
}

function parseArgs(argv) {
  const options = {};
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === "--json") continue;
    if (["--app"].includes(arg)) options[arg.slice(2)] = argv[++index];
    else throw failure("invalid_args", "Unknown preservation check argument", "parse_args");
  }
  if (!options.app) throw failure("missing_required_arg", "Missing required --app", "validate_args");
  return options;
}

// ── Minimal DOM ──────────────────────────────────────────────────────────────
//
// Only the surface the failure renderers and the manual pane actually touch.
// Anything they reach for that is not modeled throws, so a renderer growing a
// new DOM dependency surfaces here as an explicit failure rather than a silent
// pass.

// Whether `target` is any of `roots` or lives anywhere beneath them. Used to
// decide whether a replaceChildren just detached the focused node.
function subtreeContains(roots, target) {
  for (const root of roots) {
    if (!root || typeof root !== "object") continue;
    if (root === target) return true;
    if (Array.isArray(root.children) && subtreeContains(root.children, target)) return true;
  }
  return false;
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
    // Click handlers are RETAINED rather than discarded, so a scenario can drive
    // a control the painted view actually exposes — the view repainting itself
    // through its own Refetch button is a real order the operator can produce,
    // and it is unreachable through hashchange alone.
    addEventListener(type, handler) { if (type === "click" && typeof handler === "function") node.onClickStub = handler; },
    // Focus is MODELED, not stubbed: the overlay's focus contract is one of the
    // properties under test, and a no-op focus() would let a keyboard dead-end
    // pass silently. The owning document is attached by buildDom.
    focus() { if (node.ownerDocumentStub) node.ownerDocumentStub.activeElement = node; },
    append(...nodes) { for (const child of nodes) { if (child && typeof child === "object") child.parentNode = node; node.children.push(child); } },
    prepend(...nodes) { for (const child of nodes.reverse()) { if (child && typeof child === "object") child.parentNode = node; node.children.unshift(child); } },
    // Detaching a subtree that holds focus RESETS document.activeElement to the
    // body — that is what a real browser does, and it is the whole mechanism of
    // the dead end under test. A stub that left activeElement pointing at the
    // detached node made "focus was preserved" pass vacuously: the check read a
    // key off a node no longer in the document. The reset is applied before the
    // new children land so the renderer's own focus() calls still win.
    replaceChildren(...nodes) {
      const detached = node.children;
      node.children = [];
      const owner = node.ownerDocumentStub;
      // Checked against the DETACHED set rather than by walking up from the
      // active node: append() never clears a child's stale parentNode, so the
      // upward chain still points into the tree this call just dropped.
      if (owner && owner.activeElement && subtreeContains(detached, owner.activeElement)) owner.activeElement = owner.body;
      node.append(...nodes);
    },
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
  // The manual fast path gates on `app.firstChild` to require something painted
  // to re-render AROUND. It is a live DOM property, so it must track children
  // rather than be a snapshot, or the fast path is unreachable here and every
  // scenario would pass by never exercising the code under test.
  Object.defineProperty(node, "firstChild", {get: () => node.children[0] || null, configurable: true});
  // The HEALTHY renderers read `childNodes` (distributionCard asks whether a
  // marker wrap came back empty before substituting a "0 observed" marker). It
  // is a live property for the same reason firstChild is: a snapshot would make
  // an emptied node still look populated.
  Object.defineProperty(node, "childNodes", {get: () => node.children, configurable: true});
  return node;
}

// Supports exactly the selector shapes the failure and manual code paths use:
// ".error-view", ".error-view[data-follow-state]", ".manual-pane",
// "details[data-disclosure-key]", "[data-focus-key]", and "a".
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
  // Nodes built before the override (app, status, shell, body) still need the
  // back-reference, or focus() on them would be a silent no-op.
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
  return {documentStub, app, status, shell};
}

function jsonResponse(status, payload) {
  return {ok: status >= 200 && status < 300, status, json: () => Promise.resolve(payload)};
}

// ── View snapshotting ────────────────────────────────────────────────────────
//
// The manual pane is EXCLUDED from the snapshot: mounting it is the one change
// opening the manual is allowed to make. Everything else about the painted view
// — its classes, its honesty datasets, its full text, and the status line — is
// the assertion the operator's trust rests on.

function isManualNode(node) {
  return Boolean(node && node.classList && (node.classList.contains("manual-pane") || node.classList.contains("manual-shell-toggle")));
}

function describeNode(node, out = []) {
  if (!node || typeof node !== "object" || !node.tagName) return out;
  if (isManualNode(node)) return out;
  const datasetKeys = Object.keys(node.dataset).sort();
  const dataset = datasetKeys.map((key) => `${key}=${node.dataset[key]}`).join(",");
  const attrs = [...node.attributes.entries()].map(([name, value]) => `${name}=${value}`).sort().join(",");
  // WHERE THE VIEW'S EXITS POINT is part of the preserved surface, and it was
  // outside the compared one: link() and projectedLink() assign `node.href` as
  // a plain PROPERTY, which never enters the attributes Map, so a repaint that
  // silently retargeted every exit — an overlay field frozen into a replayed
  // route, say, making "Unfollow and return to Runs" reopen the pane the reader
  // just closed — diffed clean on class, dataset, attributes and text alike.
  const href = `href=${node.href ?? ""}`;
  out.push(`${node.tagName}|${node.className}|${dataset}|${attrs}|${href}|${node.textContent}`);
  for (const child of node.children || []) describeNode(child, out);
  return out;
}

// The manual-shell wrapper is an inserted PARENT: when the pane is open the view
// hangs under `.manual-shell` instead of directly under #app. Descending through
// it keeps the comparison about the VIEW rather than about its mount depth.
function viewRoot(app) {
  const first = app.children.find((child) => child && child.tagName);
  if (first && first.classList && first.classList.contains("manual-shell")) {
    return first.children.find((child) => child && child.tagName && !isManualNode(child)) || first;
  }
  return first || null;
}

// While the pane is OPEN, a link target legitimately carries `manual=index`:
// the overlay is live route state, and a view re-rendered around the open pane
// re-serializes it so that following the link keeps the manual open. That is
// correct, and it is a difference the open leg must tolerate — so the open leg
// compares link targets with the overlay field normalized away. The CLOSE leg
// does not normalize: once the hash no longer names the manual, an exit that
// still points into it is the defect, not a rendering of live state.
function stripOverlay(view) {
  return view.replace(/([?&])manual=[^&|]*&?/g, (_all, lead) => (lead === "?" ? "?" : "")).replace(/[?&]\|/g, "|");
}

function snapshotView(app, status) {
  const root = viewRoot(app);
  return {
    view: root ? describeNode(root).join("\n") : "",
    viewClass: root ? root.className : null,
    followState: root && root.dataset ? root.dataset.followState ?? null : null,
    unavailableClass: root && root.dataset ? root.dataset.unavailableClass ?? null : null,
    appErrorPhase: app.dataset.errorPhase ?? null,
    appErrorKind: app.dataset.errorKind ?? null,
    status: status.textContent
  };
}

function manualPaneMounted(app) {
  return Boolean(app.querySelector(".manual-pane"));
}

// The focus key currently held, or null when focus sits on nothing keyed — the
// document-body dead end this check exists to catch.
function activeFocusKey(documentStub) {
  const active = documentStub.activeElement;
  return active && active.dataset && active.dataset.focusKey !== undefined ? active.dataset.focusKey : null;
}

// Whether focus landed anywhere INSIDE the repainted view. This is the property
// the close leg must hold and the one a focus key alone cannot express: a key
// read off a node the re-render detached looks identical to a key on a live
// control, and `null` conflates "on document.body" with "on an unkeyed control".
function focusInsideApp(documentStub, app) {
  const active = documentStub.activeElement;
  if (!active || active === documentStub.body) return false;
  return subtreeContains(app.children, active);
}

// ── Scenario execution ───────────────────────────────────────────────────────
//
// The harness enters through the REAL navigation path: it captures the
// hashchange listener app.js registers on window, fires it to reach the failure
// view, snapshots, then moves ONLY the manual field in the hash and fires it
// again. That second hashchange is exactly what pressing `?` does.

async function runScenario(appSource, scenario) {
  const {documentStub, app, status} = buildDom(scenario.workspaceSet || null);
  const requests = [];
  const fetchStub = (path) => {
    requests.push(path);
    const reply = scenario.reply(path, requests.length);
    if (reply === "network_error") return Promise.reject(new TypeError("network down"));
    return Promise.resolve(jsonResponse(reply.status, reply.payload));
  };
  const windowListeners = new Map();
  const locationStub = {hash: scenario.hash};
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
    URLSearchParams, URL, Set, Map, Object, Array, Number, String, JSON, Math, Date, RegExp, Error, TypeError, Promise, Boolean, Symbol, Intl,
    console: {log() {}, warn() {}, error() {}, debug() {}, info() {}}
  };
  sandbox.globalThis = sandbox;
  sandbox.self = sandbox;
  vm.createContext(sandbox);
  vm.runInContext(appSource, sandbox, {filename: "app.js"});

  const hashchange = windowListeners.get("hashchange");
  if (typeof hashchange !== "function") throw failure("hashchange_missing", "app.js registered no hashchange listener", scenario.name);

  const settle = async () => { for (let turn = 0; turn < 60; turn += 1) await new Promise((resolve) => setImmediate(resolve)); };

  hashchange();
  await settle();

  const before = snapshotView(app, status);
  if (!before.view) throw failure("nothing_painted", "The scenario painted no view to preserve, so the fast path was never exercised", scenario.name, {hash: scenario.hash, requests});
  if (manualPaneMounted(app)) throw failure("manual_already_open", "The manual pane was already mounted before the manual-only delta", scenario.name);

  const requestsBefore = requests.length;

  // Put the operator on a real control of the PAINTED view before pressing `?`,
  // so "closing returns me where I was" is an assertion with a subject. Views
  // that expose no keyed control leave this null, which the close leg tolerates.
  //
  // `unanchoredOpen` opts OUT of that, which is the only way to reach the
  // NULL-STASH order: the operator presses `?` with focus on unkeyed ground
  // (page whitespace, or a page that just loaded), so nothing is stashed to
  // return to. Anchoring unconditionally is what let the close leg's null-stash
  // dead end ship green — `focusBeforeOpen` was never null in any close
  // scenario, so the branch was never executed.
  const anchorControl = scenario.unanchoredOpen ? null : app.querySelectorAll("[data-focus-key]")[0] || null;
  if (anchorControl) anchorControl.focus();
  else documentStub.activeElement = documentStub.body;
  const focusBeforeOpen = activeFocusKey(documentStub);
  const keyedControlsBeforeOpen = app.querySelectorAll("[data-focus-key]").length;

  // The manual-only delta. Only the overlay field moves.
  locationStub.hash = scenario.manualHash;
  hashchange();
  await settle();

  const after = snapshotView(app, status);
  const manualOpen = manualPaneMounted(app);
  const requestsAfter = requests.length;
  const focusAfterOpen = activeFocusKey(documentStub);

  // The CLOSE leg. `closeHash` opts a scenario into it; the operator is first
  // placed on the Close control (which is what clicking it does before the
  // hashchange fires), because that is the exact state the dead-end needs.
  let focusAfterClose;
  let focusInsideAppAfterClose;
  let keyedControlsAfterClose;
  let manualOpenAfterClose;
  let afterClose;
  if (scenario.closeHash) {
    // A repaint WHILE THE PANE IS OPEN, for scenarios that opt in. This is the
    // order no other scenario reaches: they all capture the replayable record at
    // a pre-open paint, where the overlay field is already absent. Driving the
    // view's own control here re-records it with the pane open, which is the
    // only way a frozen overlay field can get into the record at all.
    if (scenario.repaintWhileOpen) {
      const control = app.querySelectorAll(`.${scenario.repaintWhileOpen}`)[0];
      if (!control || typeof control.onClickStub !== "function") throw failure("repaint_control_missing", "The scenario names a control to repaint through that the open view does not expose", scenario.name, {control: scenario.repaintWhileOpen});
      control.onClickStub();
      await settle();
      if (!manualPaneMounted(app)) throw failure("repaint_closed_manual", "Repainting through the view's own control while the manual pane was open unmounted the pane", scenario.name);
    }
    const closeControl = app.querySelectorAll("[data-focus-key]").find((node) => node.dataset.focusKey === "manual-close");
    if (!closeControl) throw failure("close_control_missing", "The open manual pane exposes no manual-close focus key", scenario.name);
    closeControl.focus();
    locationStub.hash = scenario.closeHash;
    hashchange();
    await settle();
    focusAfterClose = activeFocusKey(documentStub);
    // The key alone cannot express the dead end: a key read off a node the close
    // re-render detached is indistinguishable from a key on a live control, and
    // null conflates document.body with an unkeyed control. This asks the only
    // question that matters — did focus land anywhere inside the repainted view.
    focusInsideAppAfterClose = focusInsideApp(documentStub, app);
    keyedControlsAfterClose = app.querySelectorAll("[data-focus-key]").length;
    manualOpenAfterClose = manualPaneMounted(app);
    afterClose = snapshotView(app, status);
  }

  return {name: scenario.name, before, after, afterClose, requestsBefore, requestsAfter, requestsAfterClose: requests.length, manualOpen, requests, focusBeforeOpen, focusAfterOpen, focusAfterClose, focusInsideAppAfterClose, keyedControlsBeforeOpen, keyedControlsAfterClose, manualOpenAfterClose};
}

const RUN_ID = "20260819T000000-run";
const OTHER_RUN_ID = "20260819T000000-other";
const NOT_FOUND = {status: 404, payload: {error: {kind: "run_not_found"}}};
const EMPTY_LIST = {status: 200, payload: {runs: []}};
// A well-formed 200 detail snapshot that names a DIFFERENT run than the route
// asked for. This is the identity-conflict input, and it is the one failure
// family that never passes through renderProjectionFailure: refresh stores the
// snapshot, renderCurrent runs, and renderDetail/renderUnit bail out to the
// conflict view directly — then refresh's own finally block nulls state.detail
// while that view stays on screen.
const CONFLICTING_DETAIL = {status: 200, payload: {run: {id: OTHER_RUN_ID, title: "A different run", strategy: "fanout"}, units: [], projection_id: "projection:conflict", source: {mode: "live", as_of_seq: 1}}};
// The HEALTHY inputs. These are the ones that reach the fast path's OTHER leg:
// nothing fails, so no renderer ever records a lastPaint, state.lastPaint stays
// null, and the overlay move goes through `else renderCurrentGuarded()` — the
// re-derive-from-state leg, which the failure family can never execute.
const HEALTHY_DETAIL = {status: 200, payload: {run: {id: RUN_ID, title: "A healthy run", strategy: "fanout"}, units: [], projection_id: "projection:healthy", source: {mode: "live", as_of_seq: 7}}};
const HEALTHY_LIST = {status: 200, payload: {runs: [{id: RUN_ID, title: "A healthy run", strategy: "fanout"}], inventory: {total: 1, selected: 1, truncated: false, limitations: []}}};

function isDetail(path) { return path.includes("/runs/"); }

const SCENARIOS = [
  // The finding's own case: a followed run 404s, so the pane shows "Follow
  // degraded" with data-follow-state, the identity-loss provenance and the
  // resolved-parent affordance. Pressing `?` must not repaint it as "Follow
  // snapshot unavailable".
  {
    name: "follow_degraded_survives_manual_open",
    paints: "error-view",
    hash: `#/runs/${RUN_ID}?follow=1`,
    manualHash: `#/runs/${RUN_ID}?follow=1&manual=index`,
    closeHash: `#/runs/${RUN_ID}?follow=1`,
    reply: (path) => (isDetail(path) ? NOT_FOUND : EMPTY_LIST)
  },
  // The non-follow dead end reaches the same fast path and must be preserved
  // with its unavailable class and app-level diagnostic intact.
  {
    name: "run_not_found_survives_manual_open",
    paints: "error-view",
    hash: `#/runs/${RUN_ID}`,
    manualHash: `#/runs/${RUN_ID}?manual=index`,
    reply: (path) => (isDetail(path) ? NOT_FOUND : EMPTY_LIST)
  },
  // A fetch outage rather than an identity loss: a different failure phase and
  // kind, whose diagnostic must also survive.
  {
    name: "detail_fetch_outage_survives_manual_open",
    paints: "error-view",
    hash: `#/runs/${RUN_ID}?follow=1`,
    manualHash: `#/runs/${RUN_ID}?follow=1&manual=index`,
    reply: (path) => (isDetail(path) ? "network_error" : EMPTY_LIST)
  },
  // The runs-list fetch failure the finding names explicitly.
  {
    name: "runs_list_failure_survives_manual_open",
    paints: "error-view",
    hash: "#/runs",
    manualHash: "#/runs?manual=index",
    reply: () => "network_error"
  },
  // IDENTITY CONFLICT, follow. The snapshot CONTRADICTS the followed identity —
  // a different assertion from an outage, and the one the other scenarios cannot
  // reach: it is painted straight out of renderDetail, never through
  // renderProjectionFailure. Re-deriving turns "the authoritative snapshot
  // contradicted the followed run identity" into "the authoritative snapshot
  // could not confirm the followed run", relabelling a contradiction as an
  // outage, so preservation must hold across the overlay move here too.
  {
    name: "follow_identity_conflict_survives_manual_open",
    paints: "error-view",
    hash: `#/runs/${RUN_ID}?follow=1`,
    manualHash: `#/runs/${RUN_ID}?follow=1&manual=index`,
    closeHash: `#/runs/${RUN_ID}?follow=1`,
    reply: (path) => (isDetail(path) ? CONFLICTING_DETAIL : EMPTY_LIST)
  },
  // IDENTITY CONFLICT, non-follow. Same seam, the renderUnavailable side:
  // "The requested run no longer matches this projection." must not decay into
  // the generic "Run projection is unavailable."
  {
    name: "identity_conflict_survives_manual_open",
    paints: "error-view",
    hash: `#/runs/${RUN_ID}`,
    manualHash: `#/runs/${RUN_ID}?manual=index`,
    reply: (path) => (isDetail(path) ? CONFLICTING_DETAIL : EMPTY_LIST)
  },
  // A REPAINT WHILE THE PANE IS OPEN. Every scenario above captures the
  // replayable record at a paint that happened BEFORE the pane opened, where the
  // overlay field is absent by construction — so none of them can see a route
  // frozen WITH the overlay in it. The operator can produce that order trivially:
  // open the pane over a dead end, then press the view's own "Refetch
  // authoritative snapshot" while it is open. The refetch fails again, the view
  // repaints, and whatever the repaint records is what the close replays. If that
  // record carries `manual=index`, every exit the restored view offers — the
  // primary one being "Unfollow and return to Runs" — points back into the pane
  // the operator just dismissed.
  // It is driven on a FOLLOW dead end because that is the family that reaches
  // renderFollowErrorView: the non-follow failures terminate in
  // renderUnavailable, whose record re-reads location.hash inside the thunk and
  // therefore cannot freeze anything.
  {
    name: "follow_degraded_repainted_while_manual_open_survives_close",
    paints: "error-view",
    hash: `#/runs/${RUN_ID}?follow=1`,
    manualHash: `#/runs/${RUN_ID}?follow=1&manual=index`,
    repaintWhileOpen: "continuation",
    closeHash: `#/runs/${RUN_ID}?follow=1`,
    reply: (path) => (isDetail(path) ? NOT_FOUND : EMPTY_LIST)
  },
  // ── The HAPPY PATH. ────────────────────────────────────────────────────────
  //
  // Everything above is a FAILURE view, and every failure view records a
  // lastPaint, so all of them take the `replayLastPaint()` leg. The headline
  // criterion — a manual-only delta is a no-refetch re-render that does not tear
  // down state.detail and leaves the run detail painted beside the pane — lives
  // on the OTHER leg, `else renderCurrentGuarded()`, and nothing reached it. A
  // regression in which the pane never mounts over a healthy view at all was
  // invisible to the whole suite.
  //
  // These scenarios paint successfully first, so state.lastPaint is null and the
  // re-derive leg runs for real. The same assertions apply unchanged: byte-
  // identical view, pane mounted, zero authoritative requests, focus handed over
  // and returned.
  {
    name: "healthy_run_detail_survives_manual_open",
    paints: "detail-view",
    hash: `#/runs/${RUN_ID}`,
    manualHash: `#/runs/${RUN_ID}?manual=index`,
    closeHash: `#/runs/${RUN_ID}`,
    reply: (path) => (isDetail(path) ? HEALTHY_DETAIL : HEALTHY_LIST)
  },
  // The followed variant: the Follow assertion on a healthy detail must survive
  // the overlay move without a refetch that could change what Follow asserts.
  {
    name: "healthy_followed_detail_survives_manual_open",
    paints: "detail-view",
    hash: `#/runs/${RUN_ID}?follow=1`,
    manualHash: `#/runs/${RUN_ID}?follow=1&manual=index`,
    closeHash: `#/runs/${RUN_ID}?follow=1`,
    reply: (path) => (isDetail(path) ? HEALTHY_DETAIL : HEALTHY_LIST)
  },
  // The healthy RUNS LIST, the other view an operator presses `?` over most.
  {
    name: "healthy_runs_list_survives_manual_open",
    paints: "runs-view",
    hash: "#/runs",
    manualHash: "#/runs?manual=index",
    closeHash: "#/runs",
    reply: () => HEALTHY_LIST
  },
  // ── The NULL-STASH close ───────────────────────────────────────────────────
  //
  // Every scenario above anchors focus on a keyed control before pressing `?`,
  // so the close leg always has a stash to return to. These two do not, and they
  // are the orders that actually happen: the operator presses `?` with focus on
  // unkeyed ground (page whitespace, or a page that just loaded and was never
  // clicked). The stash is null, so "return to where you were" has no subject —
  // and the pane's own Close control is about to be destroyed. Closing must
  // still land focus INSIDE the repainted view rather than on document.body.
  // Without the fallback the close leg skips the whole focus block and the
  // operator's next Tab restarts at the top of the document.
  {
    name: "unanchored_open_close_lands_focus_in_view_runs",
    paints: "runs-view",
    hash: "#/runs",
    manualHash: "#/runs?manual=index",
    closeHash: "#/runs",
    unanchoredOpen: true,
    reply: () => HEALTHY_LIST
  },
  {
    name: "unanchored_open_close_lands_focus_in_view_detail",
    paints: "detail-view",
    hash: `#/runs/${RUN_ID}`,
    manualHash: `#/runs/${RUN_ID}?manual=index`,
    closeHash: `#/runs/${RUN_ID}`,
    unanchoredOpen: true,
    reply: (path) => (isDetail(path) ? HEALTHY_DETAIL : HEALTHY_LIST)
  }
];

function diffSnapshots(before, after, {overlayOpen = false} = {}) {
  const differences = [];
  for (const field of ["followState", "unavailableClass", "appErrorPhase", "appErrorKind", "status"]) {
    if (before[field] !== after[field]) differences.push({field, before: before[field], after: after[field]});
  }
  const beforeView = overlayOpen ? stripOverlay(before.view) : before.view;
  const afterView = overlayOpen ? stripOverlay(after.view) : after.view;
  if (beforeView !== afterView) {
    const beforeLines = beforeView.split("\n");
    const afterLines = afterView.split("\n");
    const index = beforeLines.findIndex((line, position) => line !== afterLines[position]);
    differences.push({field: "view", before: beforeLines[index] ?? "(absent)", after: afterLines[index] ?? "(absent)"});
  }
  return differences;
}

async function checkScenario(appSource, scenario) {
  const result = await runScenario(appSource, scenario);
  // WHICH VIEW the scenario actually painted, checked BEFORE preservation. A
  // scenario declaring `paints` is asserting it reached the healthy leg of the
  // fast path (nothing failed, so no renderer recorded a lastPaint and the
  // overlay move re-derives from state). Without this the healthy family could
  // silently degrade into an error view — a fixture the renderers reject, a DOM
  // surface the harness does not model — and go on "passing" while testing the
  // failure leg for the seventh time.
  if (scenario.paints && !String(result.before.viewClass || "").split(/\s+/).includes(scenario.paints)) {
    throw failure("wrong_view_painted", "The scenario did not paint the view it declares, so it is not exercising the leg of the fast path it was written for", scenario.name, {expected: scenario.paints, painted: result.before.viewClass, status: result.before.status, requests: result.requests});
  }
  const differences = diffSnapshots(result.before, result.after, {overlayOpen: true});
  if (differences.length) {
    throw failure("view_not_preserved", "Opening the instrument manual repainted a DIFFERENT view over the failure it was opened on: the manual-only delta re-derived the view from state instead of reproducing it", scenario.name, {differences});
  }
  if (!result.manualOpen) {
    throw failure("manual_not_mounted", "The manual-only delta preserved the view but never mounted the manual pane", scenario.name);
  }
  // A manual-only delta is a pure overlay move: it must not issue any
  // authoritative request. Preservation bought by refetching would be a
  // different defect, not a fix.
  if (result.requestsAfter !== result.requestsBefore) {
    throw failure("manual_refetched", "The manual-only delta issued an authoritative request", scenario.name, {before: result.requestsBefore, after: result.requestsAfter, requests: result.requests});
  }
  // ── Focus across the overlay move ─────────────────────────────────────────
  //
  // Opening must land focus INSIDE the pane, and closing from the pane's own
  // Close control must return it to a real control of the view underneath.
  // Neither is what generic capture/restore does on its own: the hashchange
  // precedes the capture, so the close records `manual-close`, an element the
  // same re-render destroys, and focus falls to document.body — a keyboard dead
  // end where the next Tab restarts at the top of the document.
  if (scenario.closeHash) {
    if (result.focusAfterOpen === null) {
      throw failure("focus_lost_on_open", "Opening the instrument manual left focus on no keyed control", scenario.name, {focus_before_open: result.focusBeforeOpen});
    }
    if (result.manualOpenAfterClose) {
      throw failure("manual_not_closed", "The close leg left the manual pane mounted", scenario.name);
    }
    // ATTACHMENT, not just a key. `focusAfterClose` reads a key off whatever
    // document.activeElement points at, and a key on a node this re-render
    // detached is indistinguishable from a key on a live control — which is how
    // the null-stash dead end passed. This asks whether focus is anywhere inside
    // the repainted view, which is the property the operator actually feels.
    if (!result.focusInsideAppAfterClose && result.keyedControlsAfterClose > 0) {
      throw failure("focus_lost_on_close", "Closing the instrument manual left focus outside the repainted view (on document.body or on a node the close re-render detached): the next Tab restarts at the top of the document", scenario.name, {focus_before_open: result.focusBeforeOpen, focus_after_open: result.focusAfterOpen, focus_after_close: result.focusAfterClose ?? null, keyed_controls_after_close: result.keyedControlsAfterClose});
    }
    if (result.focusAfterClose === null && result.keyedControlsAfterClose > 0) {
      throw failure("focus_lost_on_close", "Closing the instrument manual from its own Close control dropped focus onto no keyed control: the next Tab restarts at the top of the document", scenario.name, {focus_before_open: result.focusBeforeOpen, focus_after_open: result.focusAfterOpen});
    }
    if (result.focusBeforeOpen !== null && result.focusAfterClose !== result.focusBeforeOpen) {
      throw failure("focus_not_returned", "Closing the instrument manual did not return focus to the control the operator held when it opened", scenario.name, {focus_before_open: result.focusBeforeOpen, focus_after_close: result.focusAfterClose});
    }
    // CLOSING is an overlay move in the same sense OPENING is, so the view it
    // returns to must be the view the operator left — the same assertion the
    // open leg makes, against the same `before`. The close leg used to check
    // only focus and pane absence, which let the restored view come back with
    // every exit retargeted (an overlay field frozen into the replayed route)
    // while the pane's own disappearance made it look correct.
    const closeDifferences = diffSnapshots(result.before, result.afterClose);
    if (closeDifferences.length) {
      throw failure("view_not_restored", "Closing the instrument manual returned a DIFFERENT view than the one it was opened over", scenario.name, {differences: closeDifferences});
    }
  }
  return {name: scenario.name, view_class: result.before.viewClass, follow_state: result.before.followState, unavailable_class: result.before.unavailableClass, error_kind: result.before.appErrorKind, authoritative_requests: result.requestsAfter, ...(scenario.closeHash ? {focus_before_open: result.focusBeforeOpen, focus_after_open: result.focusAfterOpen, focus_after_close: result.focusAfterClose} : {})};
}

// ── Red proof ────────────────────────────────────────────────────────────────
//
// Before trusting green, prove the preservation family BITES: patch the app
// source back to the pre-fix fast path (re-render from state unconditionally)
// and require the follow-degraded scenario to go red.

function tamperReDerive(appSource) {
  const tampered = appSource.replace(
    "      if (state.lastPaint !== null) replayLastPaint();\n      else renderCurrentGuarded();",
    "      renderCurrentGuarded();"
  );
  if (tampered === appSource) throw failure("tamper_target_missing", "The manual-only fast path no longer matches the shape the red proof patches; update the red proof rather than deleting it", "red_proof");
  return tampered;
}

async function checkRedProof(appSource) {
  const tampered = tamperReDerive(appSource);
  try {
    await checkScenario(tampered, SCENARIOS[0]);
  } catch (error) {
    if (error && error.harnessKind === "view_not_preserved") return {family: "manual_overlay_preservation", detected: "view_not_preserved"};
    throw error;
  }
  throw failure("red_proof_failed", "The preservation check stayed green against a fast path that re-derives the view from state", "red_proof");
}

// The focus family's own red proof. The fix has TWO independent parts and the
// proof strips BOTH, restoring the exact pre-fix code: the deliberate open/close
// handoff in the fast path, and the restoreView fallback that keeps a destroyed
// focus key from dropping onto document.body. Stripping only the handoff would
// leave the fallback masking the dead end, and the proof would pass on luck.
const FOCUS_FALLBACK = `      if (focusNode) focusNode.focus({preventScroll: true});
      else {
        const fallback = app.querySelectorAll("[data-focus-key]")[0];
        if (fallback) fallback.focus({preventScroll: true});
      }`;

function tamperGenericFocus(appSource) {
  const marker = "      const wasOpen = state.manual !== null;";
  const end = "      // Term-to-term inside the pane keeps generic restore";
  const start = appSource.indexOf(marker);
  const stop = appSource.indexOf(end);
  if (start === -1 || stop === -1 || stop < start) throw failure("focus_tamper_target_missing", "The manual open/close focus handoff no longer matches the shape the red proof patches; update the red proof rather than deleting it", "focus_red_proof");
  const withoutHandoff = appSource.slice(0, start) + "      state.manual = route.manual || null;\n      state.restore = captureView();\n" + appSource.slice(stop);
  if (!withoutHandoff.includes(FOCUS_FALLBACK)) throw failure("focus_fallback_tamper_target_missing", "The restoreView focus fallback no longer matches the shape the red proof patches; update the red proof rather than deleting it", "focus_red_proof");
  return withoutHandoff.replace(FOCUS_FALLBACK, "      if (focusNode) focusNode.focus({preventScroll: true});");
}

async function checkFocusRedProof(appSource) {
  const tampered = tamperGenericFocus(appSource);
  try {
    await checkScenario(tampered, SCENARIOS[0]);
  } catch (error) {
    if (error && (error.harnessKind === "focus_lost_on_close" || error.harnessKind === "focus_not_returned" || error.harnessKind === "focus_lost_on_open")) {
      return {family: "manual_overlay_focus", detected: error.harnessKind};
    }
    throw error;
  }
  throw failure("focus_red_proof_failed", "The focus check stayed green against a fast path that relies on generic capture/restore across the overlay move", "focus_red_proof");
}

// The NULL-STASH family's own red proof. The focus proof above always runs
// against an ANCHORED scenario, where a stash exists and the fallback is only a
// backstop; it therefore cannot speak for the order where the stash is null. Cut
// exactly the `focusFallback` guard — restoring the pre-fix `if (saved.focus)`,
// under which a null stash skipped the entire focus block, fallback included —
// and the unanchored scenarios must go red on focus landing outside the view.
function tamperNullStashFallback(appSource) {
  const target = "    if (saved.focus || saved.focusFallback) {\n      const focusNode = saved.focus ? Array.from";
  if (!appSource.includes(target)) throw failure("null_stash_tamper_target_missing", "The null-stash focus guard no longer matches the shape the red proof patches; update the red proof rather than deleting it", "null_stash_red_proof");
  return appSource.replace(target, "    if (saved.focus) {\n      const focusNode = saved.focus ? Array.from");
}

async function checkNullStashRedProof(appSource) {
  const tampered = tamperNullStashFallback(appSource);
  const unanchored = SCENARIOS.find((scenario) => scenario.name === "unanchored_open_close_lands_focus_in_view_runs");
  if (!unanchored) throw failure("null_stash_scenario_missing", "The unanchored close scenario the red proof drives is gone; the null-stash dead end would be unproven", "null_stash_red_proof");
  try {
    await checkScenario(tampered, unanchored);
  } catch (error) {
    if (error && error.harnessKind === "focus_lost_on_close") return {family: "manual_overlay_null_stash", detected: "focus_lost_on_close"};
    throw error;
  }
  throw failure("null_stash_red_proof_failed", "The focus check stayed green against a close leg that abandons focus when nothing was stashed", "null_stash_red_proof");
}

// The HEALTHY family's own red proof. The preservation and focus proofs both
// tamper with the REPLAY leg, so neither can speak for the other leg: a
// regression in which the fast path simply returns without re-rendering — the
// pane never mounting over any healthy view at all — left the whole suite green
// before this family existed. The proof cuts exactly that: the healthy leg
// returns having done nothing, and the healthy scenarios must go red on the
// missing pane while the failure scenarios, which never reach this leg, are
// untouched.
function tamperSkipHealthyLeg(appSource) {
  const target = "      if (state.lastPaint !== null) replayLastPaint();\n      else renderCurrentGuarded();";
  if (!appSource.includes(target)) throw failure("healthy_tamper_target_missing", "The manual-only fast path no longer matches the shape the healthy red proof patches; update the red proof rather than deleting it", "healthy_red_proof");
  return appSource.replace(target, "      if (state.lastPaint !== null) replayLastPaint();");
}

async function checkHealthyRedProof(appSource) {
  const tampered = tamperSkipHealthyLeg(appSource);
  const healthy = SCENARIOS.find((scenario) => scenario.name === "healthy_run_detail_survives_manual_open");
  if (!healthy) throw failure("healthy_scenario_missing", "The healthy scenario the red proof drives is gone; the re-derive leg of the fast path would be unproven", "healthy_red_proof");
  // Driven WITHOUT the close leg. With the pane never mounting there is no Close
  // control to focus, and that missing-control failure would fire first and mask
  // the assertion actually under proof — that the pane never mounted at all.
  const {closeHash: _closeHash, ...openOnly} = healthy;
  try {
    await checkScenario(tampered, openOnly);
  } catch (error) {
    if (error && error.harnessKind === "manual_not_mounted") return {family: "manual_overlay_healthy_leg", detected: "manual_not_mounted"};
    throw error;
  }
  throw failure("healthy_red_proof_failed", "The healthy family stayed green against a fast path that never re-renders over a successfully painted view: the manual pane would never mount at all", "healthy_red_proof");
}

// The RESTORATION family's own red proof. The three proofs above all tamper
// with the fast path, so none of them can speak for what the replayed record
// CONTAINS. This one restores the pre-fix record — the raw `route`, overlay
// field and all — and requires the repaint-while-open scenario to go red on the
// close leg, where the restored view's exits still point into the dismissed
// pane. It also guards the two assertions that made the defect invisible: with
// link targets outside describeNode, or with the close leg checking only focus
// and pane absence, this proof cannot detect anything.
const PAINT_ROUTE_RECORD = `    const paintRoute = Object.assign({}, route);
    delete paintRoute.manual;
    state.lastPaint = function () { renderFollowErrorView(paintRoute, options, failure); };`;

function tamperFreezeOverlay(appSource) {
  if (!appSource.includes(PAINT_ROUTE_RECORD)) throw failure("restore_tamper_target_missing", "The follow-failure paint record no longer matches the shape the restoration red proof patches; update the red proof rather than deleting it", "restore_red_proof");
  return appSource.replace(PAINT_ROUTE_RECORD, `    state.lastPaint = function () { renderFollowErrorView(route, options, failure); };`);
}

async function checkRestoreRedProof(appSource) {
  const tampered = tamperFreezeOverlay(appSource);
  const scenario = SCENARIOS.find((candidate) => candidate.name === "follow_degraded_repainted_while_manual_open_survives_close");
  if (!scenario) throw failure("restore_scenario_missing", "The repaint-while-open scenario the red proof drives is gone; a route frozen with the overlay field would be unproven", "restore_red_proof");
  try {
    await checkScenario(tampered, scenario);
  } catch (error) {
    if (error && error.harnessKind === "view_not_restored") return {family: "manual_overlay_restoration", detected: "view_not_restored"};
    throw error;
  }
  throw failure("restore_red_proof_failed", "The restoration family stayed green against a paint record that freezes the overlay field into the replayed route: every exit of the restored view would point back into the pane the operator just closed", "restore_red_proof");
}

// ── The STALE-REPLAY family (workspace-set) ──────────────────────────────────
//
// Every scenario above drives the fast path in SINGLE mode, where each of its
// two legs is reached through renderCurrent — the one site that clears
// state.lastPaint on a successful paint. Workspace-set mode has callers that
// bypass renderCurrent entirely: refresh's overview leg and
// refetchWorkspaceList's `finally` both call renderWorkspaceOverview()
// DIRECTLY, and both are on the hot path for an SSE invalidation and for the
// per-source Retry control.
//
// So a failed paint of the overview route could leave the replayable record
// ARMED underneath a healthy overview those direct callers then painted, and the
// next manual-only delta took the replay leg. The operator pressed `?` on a
// working Workspace Overview and got a failure view back — the exact inverse of
// what every scenario above pins, and unreachable from any of them.
//
// The order driven here is entirely honest: no tampering of the fast path, no
// synthetic lastPaint. A list row that PASSES the envelope (encodable id,
// object shape) but throws when the overview reads `attention` makes the
// renderer throw. The guarded caller paints a failure view and records. A
// subsequent SSE invalidation refetches a clean snapshot and repaints the
// healthy overview through refetchWorkspaceList's finally. Then `?`.
//
// This used to arm on a lone-surrogate run id. That id is now rejected at the
// envelope as an invalid row (#556), so it can no longer throw from
// renderWorkspaceOverview. The surrogate has its own family below; this one
// keeps a throw that still reaches the mount-seam record.

const STALE_REPLAY_WORKSPACES = {mode: "workspace_set", workspaces: ["left", "right"]};

function overviewPoisonRow() {
  const row = {id: "poison-arming", title: "poison"};
  Object.defineProperty(row, "attention", {
    enumerable: true,
    configurable: true,
    get() { throw new TypeError("overview_paint_poison"); }
  });
  return row;
}

function workspaceList(workspace, runs) {
  return {status: 200, payload: {workspace: workspace, source: {sessions_directory: "observed"}, snapshot: {schema: "pixir.monitor.runs", schema_version: 1, runs: runs, inventory: {total: runs.length, selected: runs.length, truncated: false, limitations: []}}}};
}

async function runStaleReplay(appSource) {
  const {documentStub, app, status} = buildDom(STALE_REPLAY_WORKSPACES);
  const requests = [];
  const sseHandlers = [];
  // Phase 0 poisons LEFT only, so RIGHT is never the source of a throw and the
  // healthy repaint needs exactly one refetch.
  let phase = 0;
  const fetchStub = (path) => {
    requests.push(`${phase}:${path}`);
    const workspace = path.includes("/workspaces/left") ? "left" : "right";
    const runs = phase === 0 && workspace === "left" ? [overviewPoisonRow()] : [];
    return Promise.resolve(jsonResponse(200, workspaceList(workspace, runs).payload));
  };
  const windowListeners = new Map();
  const locationStub = {hash: "#/workspaces"};
  const sandbox = {
    window: {
      addEventListener(type, handler) { windowListeners.set(type, handler); },
      scrollX: 0, scrollY: 0, scrollTo() {},
      // RESOLVED, unlike every scenario above: connect() runs only after the
      // bootstrap fulfills, and the SSE invalidation is the caller that reaches
      // renderWorkspaceOverview without passing through renderCurrent.
      __pixirBootstrap: Promise.resolve()
    },
    document: documentStub,
    location: locationStub,
    history: {replaceState() {}, state: null},
    fetch: fetchStub,
    EventSource: function () { return {addEventListener(type, handler) { if (type === "projection_changed") sseHandlers.push(handler); }, close() {}}; },
    setTimeout: (fn) => { void fn; return 0; },
    clearTimeout() {}, setInterval: () => 0, clearInterval() {},
    queueMicrotask,
    URLSearchParams, URL, Set, Map, Object, Array, Number, String, JSON, Math, Date, RegExp, Error, TypeError, Promise, Boolean, Symbol, Intl,
    console: {log() {}, warn() {}, error() {}, debug() {}, info() {}}
  };
  sandbox.globalThis = sandbox;
  sandbox.self = sandbox;
  vm.createContext(sandbox);
  vm.runInContext(appSource, sandbox, {filename: "app.js"});

  const hashchange = windowListeners.get("hashchange");
  if (typeof hashchange !== "function") throw failure("hashchange_missing", "app.js registered no hashchange listener", "stale_replay");
  const settle = async () => { for (let turn = 0; turn < 60; turn += 1) await new Promise((resolve) => setImmediate(resolve)); };

  // 1. Boot. The poisoned snapshot makes renderWorkspaceOverview throw; the
  //    guarded caller paints a failure view and records the replayable paint.
  await settle();
  const failed = snapshotView(app, status);
  if (sseHandlers.length === 0) throw failure("sse_not_connected", "app.js opened no projection_changed subscription, so the direct-caller repaint the family is about cannot be driven", "stale_replay", {requests});
  if (!String(failed.viewClass || "").split(/\s+/).includes("error-view")) throw failure("failure_not_painted", "The poisoned snapshot did not make the overview renderer fail, so no replayable paint was recorded and the family is not being exercised", "stale_replay", {view_class: failed.viewClass, status: failed.status, requests});

  // 2. A clean SSE invalidation for LEFT. refetchWorkspaceList stores the clean
  //    snapshot and its `finally` calls renderWorkspaceOverview() DIRECTLY —
  //    never through renderCurrent.
  phase = 1;
  for (const handler of sseHandlers) handler({lastEventId: "1", data: JSON.stringify({type: "projection_changed", projection_id: "projection:clean", workspace: "left"})});
  await settle();
  const healthy = snapshotView(app, status);
  if (!String(healthy.viewClass || "").split(/\s+/).includes("workspace-overview")) throw failure("healthy_overview_not_painted", "The clean refetch did not repaint a healthy Workspace Overview, so the stale-record leg is not being exercised", "stale_replay", {view_class: healthy.viewClass, status: healthy.status, requests});

  // 3. The operator presses `?`. A manual-only delta over a HEALTHY overview
  //    must re-derive it and mount the pane beside it — never replay a record
  //    left over from a paint two steps ago.
  const requestsBeforeManual = requests.length;
  locationStub.hash = "#/workspaces?manual=index";
  hashchange();
  await settle();
  const afterManual = snapshotView(app, status);

  return {failed, healthy, afterManual, manualOpen: manualPaneMounted(app), requests, requestsBeforeManual, requestsAfterManual: requests.length};
}

async function checkStaleReplay(appSource) {
  const result = await runStaleReplay(appSource);
  const painted = String(result.afterManual.viewClass || "").split(/\s+/);
  if (painted.includes("error-view") || !painted.includes("workspace-overview")) {
    throw failure("stale_failure_replayed_over_healthy_view", "Opening the instrument manual over a HEALTHY Workspace Overview replayed a failure view recorded by an earlier, superseded paint: the operator's working page was replaced by a stale outage", "stale_replay", {healthy_view_class: result.healthy.viewClass, healthy_status: result.healthy.status, after_manual_view_class: result.afterManual.viewClass, after_manual_status: result.afterManual.status});
  }
  // The healthy overview must come back UNCHANGED, not merely non-failing: a
  // re-derive that painted some other overview would satisfy the class check.
  const differences = diffSnapshots(result.healthy, result.afterManual, {overlayOpen: true});
  if (differences.length) throw failure("view_not_preserved", "The manual-only delta over a healthy Workspace Overview repainted a DIFFERENT view", "stale_replay", {differences});
  if (!result.manualOpen) throw failure("manual_not_mounted", "The manual-only delta over a healthy Workspace Overview never mounted the pane", "stale_replay");
  // Still a pure overlay move: no authoritative request.
  if (result.requestsAfterManual !== result.requestsBeforeManual) throw failure("manual_refetched", "The manual-only delta over a healthy Workspace Overview issued an authoritative request", "stale_replay", {before: result.requestsBeforeManual, after: result.requestsAfterManual, requests: result.requests});
  return {family: "workspace_overview_stale_replay", failure_view_class: result.failed.viewClass, healthy_view_class: result.healthy.viewClass, after_manual_view_class: result.afterManual.viewClass, authoritative_requests: result.requestsAfterManual};
}

// The stale-replay family's own red proof. It cuts exactly the fix — the clear
// at renderWorkspaceOverview's mount seam — and requires the scenario to go red
// on the replayed failure. None of the proofs above can speak for this: they all
// tamper with the fast PATH, while this defect is about which record the fast
// path finds when it gets there.
const OVERVIEW_CLEAR = `    state.lastPaint = null;
    const root = el("div", "view workspace-overview");`;

function tamperOverviewClear(appSource) {
  if (!appSource.includes(OVERVIEW_CLEAR)) throw failure("stale_replay_tamper_target_missing", "The workspace-overview mount seam no longer clears the replayable paint in the shape the red proof patches; update the red proof rather than deleting it", "stale_replay_red_proof");
  return appSource.replace(OVERVIEW_CLEAR, `    const root = el("div", "view workspace-overview");`);
}

async function checkStaleReplayRedProof(appSource) {
  const tampered = tamperOverviewClear(appSource);
  try {
    await checkStaleReplay(tampered);
  } catch (error) {
    if (error && error.harnessKind === "stale_failure_replayed_over_healthy_view") return {family: "workspace_overview_stale_replay", detected: "stale_failure_replayed_over_healthy_view"};
    throw error;
  }
  throw failure("stale_replay_red_proof_failed", "The stale-replay family stayed green against a workspace-overview mount seam that leaves a superseded failure record armed", "stale_replay_red_proof");
}

// ── UNLINKABLE RUN ID (#556) ────────────────────────────────────────────────
//
// A lone UTF-16 surrogate passes the list envelope's shape contract
// (`typeof id === "string" && id.length > 0`) and then encodeURIComponent
// throws URIError inside routeHash. On the workspace-set path that throw
// escaped UNCAUGHT from refetchWorkspaceList's finally as an unhandled
// rejection. The honest degradation is the existing invalid-row confession:
// reject the unlinkable row at the envelope, count it as an unprojected
// selected Log, paint the rest of the list, never build the href.
//
// Two executed legs plus the SSE finally path that used to reject uncaught.
// Removing the encode/envelope guards must turn this family red by naming
// that URIError unhandled rejection.

const UNLINKABLE_RUN_ID = "\uD800";
const UNLINKABLE_HEALTHY = {id: "healthy-run", title: "A healthy run", strategy: "fanout"};
const UNLINKABLE_ROW = {id: UNLINKABLE_RUN_ID, title: "unlinkable"};

function unlinkableSnapshot(extraInventory = {}) {
  return {
    schema: "pixir.monitor.runs",
    schema_version: 1,
    runs: [UNLINKABLE_HEALTHY, UNLINKABLE_ROW],
    inventory: Object.assign({
      total: 2,
      selected: 2,
      truncated: false,
      limitations: [],
      projected_runs: 2,
      non_parent_logs: 0,
      dropped_logs: 0
    }, extraInventory)
  };
}

const ENCODABLE_GUARD = `  function encodableComponent(value) {
    try { return encodeURIComponent(value); }
    catch (_error) { return null; }
  }`;
const ENCODABLE_UNGUARDED = `  function encodableComponent(value) {
    return encodeURIComponent(value);
  }`;
const VALID_LIST_ROW_GUARD = `    return row && typeof row === "object" && !Array.isArray(row) && typeof row.id === "string" && row.id.length > 0 && encodableComponent(row.id) !== null;`;
const VALID_LIST_ROW_UNGUARDED = `    return row && typeof row === "object" && !Array.isArray(row) && typeof row.id === "string" && row.id.length > 0;`;

function tamperUnlinkableGuards(appSource) {
  if (!appSource.includes(ENCODABLE_GUARD) || !appSource.includes(VALID_LIST_ROW_GUARD)) {
    throw failure("unlinkable_id_tamper_target_missing", "The unlinkable-id encode/envelope guard is no longer in the shape the red proof patches; update the red proof rather than deleting it", "unlinkable_run_id_red_proof");
  }
  return appSource.replace(ENCODABLE_GUARD, ENCODABLE_UNGUARDED).replace(VALID_LIST_ROW_GUARD, VALID_LIST_ROW_UNGUARDED);
}

function trackUnhandledRejections() {
  const seen = [];
  const handler = (reason) => {
    seen.push({
      name: reason && reason.name ? String(reason.name) : "",
      message: String(reason && reason.message || reason)
    });
  };
  process.on("unhandledRejection", handler);
  return {
    seen,
    stop() { process.off("unhandledRejection", handler); }
  };
}

function viewText(app) {
  const texts = [];
  const walk = (node) => {
    if (!node || typeof node !== "object") return;
    if (typeof node.textContent === "string" && node.textContent) texts.push(node.textContent);
    for (const child of node.children || []) walk(child);
  };
  walk(viewRoot(app));
  return texts.join("\n");
}

function hrefs(app) {
  return (app.querySelectorAll("a") || []).map((node) => String(node.href || ""));
}

async function runUnlinkableApp(appSource, options) {
  const workspaceSet = options.workspaceSet || null;
  const {documentStub, app, status} = buildDom(workspaceSet);
  const requests = [];
  const consoleErrors = [];
  const sseHandlers = [];
  let phase = options.initialPhase === undefined ? 0 : options.initialPhase;
  const fetchStub = (path) => {
    requests.push(`${phase}:${path}`);
    if (workspaceSet) {
      const workspace = path.includes("/workspaces/left") ? "left" : "right";
      const mixed = phase === 0 && workspace === "left";
      const runs = mixed ? [UNLINKABLE_HEALTHY, UNLINKABLE_ROW] : (workspace === "left" && phase === 1 ? [UNLINKABLE_HEALTHY, UNLINKABLE_ROW] : []);
      const snapshot = mixed || (workspace === "left" && phase === 1) ? unlinkableSnapshot() : {schema: "pixir.monitor.runs", schema_version: 1, runs: runs, inventory: {total: runs.length, selected: runs.length, truncated: false, limitations: [], projected_runs: runs.length, non_parent_logs: 0, dropped_logs: 0}};
      return Promise.resolve(jsonResponse(200, {workspace: workspace, source: {sessions_directory: "observed"}, snapshot: snapshot}));
    }
    return Promise.resolve(jsonResponse(200, unlinkableSnapshot()));
  };
  const windowListeners = new Map();
  const locationStub = {hash: options.hash};
  const sandbox = {
    window: {
      addEventListener(type, handler) { windowListeners.set(type, handler); },
      scrollX: 0, scrollY: 0, scrollTo() {},
      __pixirBootstrap: Promise.resolve()
    },
    document: documentStub,
    location: locationStub,
    history: {replaceState() {}, state: null},
    fetch: fetchStub,
    EventSource: function () { return {addEventListener(type, handler) { if (type === "projection_changed") sseHandlers.push(handler); }, close() {}}; },
    setTimeout: (fn) => { void fn; return 0; },
    clearTimeout() {}, setInterval: () => 0, clearInterval() {},
    queueMicrotask,
    URLSearchParams, URL, Set, Map, Object, Array, Number, String, JSON, Math, Date, RegExp, Error, TypeError, URIError, Promise, Boolean, Symbol, Intl,
    console: {log() {}, warn() {}, error(...args) { consoleErrors.push(args.map(String).join(" ")); }, debug() {}, info() {}}
  };
  sandbox.globalThis = sandbox;
  sandbox.self = sandbox;
  vm.createContext(sandbox);
  vm.runInContext(appSource, sandbox, {filename: "app.js"});
  const hashchange = windowListeners.get("hashchange");
  if (typeof hashchange !== "function") throw failure("hashchange_missing", "app.js registered no hashchange listener", options.family);
  const settle = async () => { for (let turn = 0; turn < 60; turn += 1) await new Promise((resolve) => setImmediate(resolve)); };
  const seam = sandbox.window.PixirMonitorUI;
  return {app, status, locationStub, hashchange, sseHandlers, requests, consoleErrors, settle, setPhase: (next) => { phase = next; }, routeHash: seam && seam.routeHash, parseRoute: seam && seam.parseRoute, defaultSort: seam && seam.defaultSort};
}

function namedUnhandledUriError(seen) {
  return seen.some((entry) => entry.name === "URIError" || /URI malformed|URIError/i.test(entry.message));
}

function assertUnlinkableHonesty(label, painted, text, links, consoleErrors, unhandled) {
  if (!String(painted.viewClass || "").split(/\s+/).includes(label.viewClass)) {
    throw failure("unlinkable_view_missing", "The " + label.leg + " did not paint the expected view after a lone-surrogate run id arrived among healthy rows", "unlinkable_run_id", {leg: label.leg, view_class: painted.viewClass, status: painted.status});
  }
  if (String(painted.viewClass || "").split(/\s+/).includes("error-view")) {
    throw failure("unlinkable_crashed", "The " + label.leg + " painted a failure view instead of confessing the unlinkable row and keeping the rest of the list", "unlinkable_run_id", {leg: label.leg, view_class: painted.viewClass, status: painted.status});
  }
  if (!text.includes("A healthy run")) {
    throw failure("unlinkable_healthy_row_missing", "The " + label.leg + " dropped the healthy row while declining the unlinkable id", "unlinkable_run_id", {leg: label.leg, text});
  }
  if (!label.confession.some((needle) => text.includes(needle))) {
    throw failure("unlinkable_confession_missing", "The " + label.leg + " did not count the unlinkable row in the existing unprojected/dropped confession", "unlinkable_run_id", {leg: label.leg, text});
  }
  if (links.some((href) => href.includes("%D800") || href.includes(UNLINKABLE_RUN_ID))) {
    throw failure("unlinkable_href_built", "The " + label.leg + " built a link whose href construction used the unlinkable id", "unlinkable_run_id", {leg: label.leg, links});
  }
  if (consoleErrors.length) {
    throw failure("unlinkable_console_error", "The " + label.leg + " wrote a console error while declining the unlinkable id", "unlinkable_run_id", {leg: label.leg, console_errors: consoleErrors});
  }
  if (unhandled.length) {
    throw failure("unhandled_rejection_uri_error", "The " + label.leg + " leaked an unhandled rejection while a lone-surrogate run id was in the list payload", "unlinkable_run_id", {leg: label.leg, unhandled});
  }
}

async function checkUnlinkableRunId(appSource) {
  const tracker = trackUnhandledRejections();
  try {
    const single = await runUnlinkableApp(appSource, {family: "unlinkable_run_id", hash: "#/runs", workspaceSet: null});
    await single.settle();
    const singlePainted = snapshotView(single.app, single.status);
    assertUnlinkableHonesty(
      {leg: "single-workspace list", viewClass: "runs-view", confession: ["unprojected selected Logs: 1"]},
      singlePainted,
      viewText(single.app),
      hrefs(single.app),
      single.consoleErrors,
      tracker.seen
    );
    if (typeof single.routeHash !== "function" || typeof single.parseRoute !== "function") {
      throw failure("unlinkable_route_hash_missing", "The unlinkable fixture did not export routeHash/parseRoute, so the atomic pair cannot be executed", "unlinkable_run_id");
    }
    const halfBuilt = single.routeHash({runId: UNLINKABLE_RUN_ID, unitId: "step:review", filters: {}, sort: single.defaultSort, q: ""});
    const parsedHalf = single.parseRoute(halfBuilt);
    if (parsedHalf.runId || parsedHalf.unitId || /\/units(?:\/|\?|$)/.test(halfBuilt)) {
      throw failure("unlinkable_half_built_href", "routeHash emitted a half-built detail href after an unencodable runId; the run/unit pair must be rejected atomically", "unlinkable_run_id", {hash: halfBuilt, parsed_run: parsedHalf.runId ?? null, parsed_unit: parsedHalf.unitId ?? null});
    }

    const set = await runUnlinkableApp(appSource, {family: "unlinkable_run_id", hash: "#/workspaces", workspaceSet: STALE_REPLAY_WORKSPACES, initialPhase: 0});
    await set.settle();
    const overviewPainted = snapshotView(set.app, set.status);
    assertUnlinkableHonesty(
      {leg: "workspace-set overview", viewClass: "workspace-overview", confession: ["dropped_logs 1", "unprojected selected Logs: 1"]},
      overviewPainted,
      viewText(set.app),
      hrefs(set.app),
      set.consoleErrors,
      tracker.seen
    );
    if (set.sseHandlers.length === 0) throw failure("sse_not_connected", "workspace-set unlinkable fixture opened no projection_changed subscription", "unlinkable_run_id");

    set.locationStub.hash = "#/workspaces/left/runs";
    set.hashchange();
    await set.settle();
    const listPainted = snapshotView(set.app, set.status);
    assertUnlinkableHonesty(
      {leg: "workspace-set per-source list", viewClass: "runs-view", confession: ["unprojected selected Logs: 1"]},
      listPainted,
      viewText(set.app),
      hrefs(set.app),
      set.consoleErrors,
      tracker.seen
    );

    const sse = await runUnlinkableApp(appSource, {family: "unlinkable_run_id", hash: "#/workspaces", workspaceSet: STALE_REPLAY_WORKSPACES, initialPhase: 2});
    await sse.settle();
    if (sse.sseHandlers.length === 0) throw failure("sse_not_connected", "workspace-set SSE unlinkable fixture opened no projection_changed subscription", "unlinkable_run_id");
    sse.setPhase(1);
    for (const handler of sse.sseHandlers) handler({lastEventId: "1", data: JSON.stringify({type: "projection_changed", projection_id: "projection:unlinkable", workspace: "left"})});
    await sse.settle();
    const ssePainted = snapshotView(sse.app, sse.status);
    assertUnlinkableHonesty(
      {leg: "workspace-set SSE refetch", viewClass: "workspace-overview", confession: ["dropped_logs 1", "unprojected selected Logs: 1"]},
      ssePainted,
      viewText(sse.app),
      hrefs(sse.app),
      sse.consoleErrors,
      tracker.seen
    );

    return {
      family: "unlinkable_run_id",
      single_view_class: singlePainted.viewClass,
      overview_view_class: overviewPainted.viewClass,
      list_view_class: listPainted.viewClass,
      sse_view_class: ssePainted.viewClass,
      atomic_pair: "list_path",
      console_errors: 0,
      unhandled_rejections: 0
    };
  } finally {
    tracker.stop();
  }
}

async function checkUnlinkableRunIdRedProof(appSource) {
  const tampered = tamperUnlinkableGuards(appSource);
  const tracker = trackUnhandledRejections();
  try {
    const sse = await runUnlinkableApp(tampered, {family: "unlinkable_run_id_red_proof", hash: "#/workspaces", workspaceSet: STALE_REPLAY_WORKSPACES, initialPhase: 2});
    await sse.settle();
    if (sse.sseHandlers.length === 0) throw failure("sse_not_connected", "The unlinkable-id red proof opened no projection_changed subscription", "unlinkable_run_id_red_proof");
    sse.setPhase(1);
    for (const handler of sse.sseHandlers) handler({lastEventId: "1", data: JSON.stringify({type: "projection_changed", projection_id: "projection:unlinkable", workspace: "left"})});
    await sse.settle();
    await new Promise((resolve) => setImmediate(resolve));
    await new Promise((resolve) => setImmediate(resolve));
  } catch (error) {
    tracker.stop();
    if (error && (error.harnessKind === "unhandled_rejection_uri_error" || error.name === "URIError" || /URI malformed|URIError/i.test(error.message || ""))) {
      return {family: "unlinkable_run_id", detected: "unhandled_rejection_uri_error"};
    }
    throw error;
  }
  const seen = tracker.seen.slice();
  tracker.stop();
  if (namedUnhandledUriError(seen)) return {family: "unlinkable_run_id", detected: "unhandled_rejection_uri_error"};
  throw failure("unlinkable_id_red_proof_failed", "Un-guarding the encode path did not surface the URIError unhandled rejection the suite names", "unlinkable_run_id_red_proof", {unhandled: seen});
}

// ── ON THIS RUN: the reader binding, EXECUTED ────────────────────────────────
//
// The source-text pins in manual_pane_contract_test can prove the reader table
// exists and names its accessors. They cannot prove it PRODUCES anything: a
// table whose readers all return null, a scope guard that never finds the run,
// a distribution phrase built from the wrong counts, or an alias map applied to
// the wrong dimension all survive every source pin unchanged. This family runs
// the real binding over a real projection fixture and reads what the pane put on
// screen.
//
// Two legs, and they are different assertions:
//
//   - DETAIL scope: the run IS on screen, so each bound term must render its
//     value, its basis, and the SAME as-of seq the run overview prints, in the
//     shipped display vocabulary.
//   - LIST scope: no run is on screen. The pane must SAY so. This is the leg the
//     honesty of the whole part rests on, because the failure mode it guards is
//     silent: state.detail can still hold the last-visited run while the
//     operator looks at a list of fifty others, and a pane that reads it would
//     present that stale detail as "this run" with no visible tell.

// A projection fixture with enough shape to exercise every bound reader: an
// execution state with a basis, a liveness state with a basis, units carrying
// gate / advisory / attention, a source with a mode, a durable origin and an
// as-of seq, and a post-terminal child-activity record.
//
// Every unit ALSO carries its own execution, liveness and gate basis, and the
// opened one (ON_THIS_RUN_UNIT) is deliberately the DISAGREEING unit on every
// per-unit dimension: its gate is `held` where three siblings are ready, its
// attention is required where three are not, its advisory is unclassified where
// the fold reads four different buckets, and its execution and liveness differ
// from the run's. That is what makes the unit-scope leg falsifiable — a reader
// that quietly folded the run while the Unit Inspector painted this unit would
// print the run's numbers, and every one of them differs from this unit's.
const ON_THIS_RUN_SEQ = 34;
const ON_THIS_RUN_UNIT = "u3";
const ON_THIS_RUN_DETAIL = {
  status: 200,
  payload: {
    run: {id: RUN_ID, title: "A run with every dimension populated", strategy: "workflow"},
    projection_id: "projection:on-this-run",
    execution: {state: "running", basis: "parent_log_fold"},
    liveness: {state: "not_applicable", basis: "parent_log_only", reachable: false},
    source: {mode: "live", durable_origin: "parent_log", freshness: "current", as_of_seq: ON_THIS_RUN_SEQ, limitations: []},
    post_terminal_child_activity: {state: "none", basis: "child_log_scan"},
    units: [
      {logical_id: "u1", label: "one", execution: {state: "completed", basis: "subagent_events"}, liveness: {state: "not_applicable", basis: "terminal_execution"}, gate: {state: "checkpoint_ready", basis: "workflow_event"}, advisory: {present: true, verdict: "pass", parse_status: "ok"}, attention: {required: false}},
      {logical_id: "u2", label: "two", execution: {state: "completed", basis: "subagent_events"}, liveness: {state: "not_applicable", basis: "terminal_execution"}, gate: {state: "checkpoint_ready", basis: "workflow_event"}, advisory: {present: true, verdict: "unknown", parse_status: "ok"}, attention: {required: false}},
      {logical_id: ON_THIS_RUN_UNIT, label: "three", execution: {state: "queued", basis: "subagent_events"}, liveness: {state: "stale_handle", basis: "delegate_owner"}, gate: {state: "held", basis: "workflow_event"}, advisory: {present: true, verdict: "unknown", parse_status: "ok"}, attention: {required: true}},
      {logical_id: "u4", label: "four", execution: {state: "failed", basis: "subagent_events"}, liveness: {state: "not_applicable", basis: "terminal_execution"}, gate: {state: "checkpoint_ready", basis: "workflow_event"}, advisory: {present: true, verdict: "stop", parse_status: "invalid"}, attention: {required: false}}
    ]
  }
};
const ON_THIS_RUN_LIST = {status: 200, payload: {runs: [{id: RUN_ID, title: "A run with every dimension populated", strategy: "workflow"}], inventory: {total: 1, selected: 1, truncated: false, limitations: []}}};

// The pane's own text, which describeNode deliberately excludes. Collected as
// the concatenation of every descendant's textContent so an assertion can ask
// what the reader can actually read.
function collectText(node, out = []) {
  if (!node || typeof node !== "object") return out;
  if (node.textContent) out.push(node.textContent);
  for (const child of node.children || []) collectText(child, out);
  return out;
}

function manualPaneText(app) {
  const pane = app.querySelector(".manual-pane");
  return pane ? collectText(pane).join(" ") : null;
}

// Drives the real navigation path to `hash`, then opens the manual AT `slug`,
// and returns the pane's rendered text plus the ON THIS RUN dd's own text.
async function openManualAt(appSource, {hash, manualHash, reply, expectView}) {
  const {documentStub, app, status} = buildDom(null);
  void documentStub;
  const requests = [];
  const fetchStub = (path) => {
    requests.push(path);
    const answer = reply(path);
    return Promise.resolve(jsonResponse(answer.status, answer.payload));
  };
  const windowListeners = new Map();
  const locationStub = {hash};
  const sandbox = {
    window: {addEventListener(type, handler) { windowListeners.set(type, handler); }, scrollX: 0, scrollY: 0, scrollTo() {}, __pixirBootstrap: new Promise(() => {})},
    document: documentStub,
    location: locationStub,
    history: {replaceState() {}, state: null},
    fetch: fetchStub,
    EventSource: function () { return {addEventListener() {}, close() {}}; },
    setTimeout: (fn) => { void fn; return 0; },
    clearTimeout() {}, setInterval: () => 0, clearInterval() {},
    queueMicrotask,
    URLSearchParams, URL, Set, Map, Object, Array, Number, String, JSON, Math, Date, RegExp, Error, TypeError, Promise, Boolean, Symbol, Intl,
    console: {log() {}, warn() {}, error() {}, debug() {}, info() {}}
  };
  sandbox.globalThis = sandbox;
  sandbox.self = sandbox;
  vm.createContext(sandbox);
  vm.runInContext(appSource, sandbox, {filename: "app.js"});
  const hashchange = windowListeners.get("hashchange");
  if (typeof hashchange !== "function") throw failure("hashchange_missing", "app.js registered no hashchange listener", "on_this_run");
  const settle = async () => { for (let turn = 0; turn < 60; turn += 1) await new Promise((resolve) => setImmediate(resolve)); };
  hashchange();
  await settle();
  const painted = snapshotView(app, status);
  if (expectView && !String(painted.viewClass || "").split(/\s+/).includes(expectView)) {
    throw failure("wrong_view_painted", "The ON THIS RUN scenario did not paint the view it declares, so the binding is not being exercised in the scope it was written for", "on_this_run", {expected: expectView, painted: painted.viewClass, requests});
  }
  locationStub.hash = manualHash;
  hashchange();
  await settle();
  if (!manualPaneMounted(app)) throw failure("manual_not_mounted", "The manual pane never mounted, so nothing about ON THIS RUN was rendered", "on_this_run", {hash: manualHash});
  const dd = app.querySelector(".manual-on-this-run");
  const noRun = app.querySelector(".manual-no-run");
  const unbound = app.querySelector(".manual-unbound");
  return {
    paneText: manualPaneText(app),
    reading: dd ? collectText(dd).join("") : null,
    readingSlug: dd ? dd.dataset.manualSlug ?? null : null,
    noRun: noRun ? noRun.textContent : null,
    unbound: unbound ? unbound.textContent : null,
    // The HEADING, read as a node rather than as a substring of the pane's
    // prose: the unbound confession itself names the part, so a substring test
    // would report the heading present exactly where it must be absent.
    headingPresent: app.querySelectorAll("dt").some((node) => node.textContent === "ON THIS RUN"),
    viewClass: painted.viewClass
  };
}

const DETAIL_HASH = `#/runs/${RUN_ID}`;
const onThisRunReply = (path) => (isDetail(path) ? ON_THIS_RUN_DETAIL : ON_THIS_RUN_LIST);

// The bound-slug inventory the bundle itself publishes. Read by loading app.js
// with nothing driven, so it is the binding's own answer rather than a list this
// file maintains in parallel.
function readBoundSlugs(appSource) {
  const {documentStub} = buildDom(null);
  const sandbox = {
    window: {addEventListener() {}, scrollX: 0, scrollY: 0, scrollTo() {}, __pixirBootstrap: new Promise(() => {})},
    document: documentStub,
    location: {hash: "#/runs"},
    history: {replaceState() {}, state: null},
    fetch: () => new Promise(() => {}),
    EventSource: function () { return {addEventListener() {}, close() {}}; },
    setTimeout: () => 0, clearTimeout() {}, setInterval: () => 0, clearInterval() {},
    queueMicrotask,
    URLSearchParams, URL, Set, Map, Object, Array, Number, String, JSON, Math, Date, RegExp, Error, TypeError, Promise, Boolean, Symbol, Intl,
    console: {log() {}, warn() {}, error() {}, debug() {}, info() {}}
  };
  sandbox.globalThis = sandbox;
  sandbox.self = sandbox;
  vm.createContext(sandbox);
  vm.runInContext(appSource, sandbox, {filename: "app.js"});
  const bound = sandbox.window.PixirMonitorUI && sandbox.window.PixirMonitorUI.manualRunValueSlugs;
  if (!Array.isArray(bound) || bound.length === 0) throw failure("bound_inventory_missing", "app.js did not export a non-empty manualRunValueSlugs inventory, so coverage of the reader table cannot be established", "on_this_run_detail");
  return bound;
}

// The bound terms whose rendered reading is asserted VERBATIM. Each expectation
// is the exact string the shipped display vocabulary produces, so a reader that
// silently switched dimension, dropped its alias map, or lost its basis cannot
// stay green. `as of seq 34` is the SAME sequence the run overview prints, and
// `on this run` is the SCOPE every reading names: a count with no population
// stated is a number a reader can only guess the meaning of, and the sibling
// unit-scope leg below drives the same slugs where that population differs.
const ON_THIS_RUN_EXPECTATIONS = Object.freeze([
  {slug: "execution", reading: "running · on this run · basis parent log fold · as of seq 34"},
  {slug: "liveness", reading: "not applicable · on this run · basis parent log only · as of seq 34"},
  // The gate distribution, in shipped display order, with the shipped
  // {checkpoint_ready: "ready"} alias applied and zero buckets omitted.
  {slug: "dependency-gate", reading: "1 held · 3 ready · on this run · basis unit checkpoint fold · as of seq 34"},
  // The SAME dimension under the Unit Inspector's label for it.
  {slug: "runtime-gate", reading: "1 held · 3 ready · on this run · basis unit checkpoint fold · as of seq 34"},
  {slug: "checkpoint-ready", reading: "3 ready · on this run · basis unit checkpoint fold · as of seq 34"},
  // ADVISORY_DISPLAY_ALIASES plus the shipped pluralizer: two unknown-verdict
  // units read "2 unclassified verdicts", never "2 unknown".
  {slug: "model-advisory", reading: "1 pass · 2 unclassified verdicts · 1 invalid · on this run · basis model declared · as of seq 34"},
  {slug: "unclassified-verdict", reading: "2 unclassified verdicts · on this run · basis model declared · as of seq 34"},
  {slug: "invalid-advisory", reading: "1 invalid · on this run · basis model declared · as of seq 34"},
  {slug: "source-run-scoped", reading: "live · on this run · basis parent log · as of seq 34"},
  // The attention aliases: {yes: "required", no: "not required"}. "3 not
  // required" is the shipped phrase the design handoff names as contract.
  {slug: "attention", reading: "1 required · 3 not required · on this run · basis parent log · as of seq 34"},
  {slug: "parent-observed", reading: "1 required · 3 not required · on this run · basis parent log · as of seq 34"},
  // The post-terminal DIMENSION, in postTerminalLabel's words — the same
  // shipped label the runs-list cell and the truth card print, never a
  // titleCased state token.
  {slug: "child-after-end", reading: "No child events after the run ended · on this run · basis child log scan · as of seq 34"},
  // The as-of-seq entry's value IS the sequence, so it is not restated as a
  // suffix on itself. It also carries no basis: the sequence is a position in
  // the parent Log fold, not something read off the source evidence class, so
  // naming the source mode here would misattribute it.
  {slug: "as-of-seq", reading: "seq 34 · on this run"},
  // The terms that ARE a state VALUE rather than a dimension. The question a
  // reader who just met the word in a cell has is "is the run on screen in this
  // state right now", so the answer names the state the run IS in — a bare "no"
  // would leave them where they started. This fixture's run is not_applicable,
  // so both DETAIL-scope liveness values answer negatively and each names
  // not_applicable as what the run actually reads.
  {slug: "stale-handle", reading: "Not stale handle — this run reads not applicable · on this run · basis parent log only · as of seq 34"},
  {slug: "externally-owned", reading: "Not externally owned — this run reads not applicable · on this run · basis parent log only · as of seq 34"},
  // `unobserved` is NOT one of them, and this is the pin that says so. It is a
  // LIST-scope fold (source.ex list_liveness); the detail builder's liveness/4
  // cannot emit it, so the denial its two siblings render would be structurally
  // INVARIANT — "Not unobserved" on every run that has ever existed, with the
  // affirmative branch unreachable — and it would contradict the runs-list cell
  // that prints `unobserved` for this very run and is where the reader clicked
  // through from. The reading states the scope fact and then what this run
  // actually reads, both of which are true at once.
  {slug: "unobserved", reading: "A list-scope value only — no detail projection reads unobserved, so this run reads not applicable here while its row in the Runs list may still read unobserved. · on this run · basis parent log only · as of seq 34"},
  // The source-mode values, same shape. This run is live, so one answers
  // affirmatively and the other names live as what it actually reads.
  {slug: "live-source-mode", reading: "live · on this run · basis parent log · as of seq 34"},
  {slug: "reconstructed", reading: "Not reconstructed — this run reads live · on this run · basis parent log · as of seq 34"},
  // The post-terminal VALUE term, same shape as the liveness values and NOT the
  // whole dimension's reading: this fixture's run is `none`, so the entry must
  // deny the term and name what the run actually reads. Both halves quote
  // postTerminalLabel, the shipped vocabulary the list cell and truth card
  // print, so the pane and the rail cannot say different words about one value.
  {slug: "undetermined", reading: "Not undetermined — this run reads No child events after the run ended · on this run · basis child log scan · as of seq 34"}
]);

// The post-terminal DIVERGENCE proof. Both slugs now speak postTerminalLabel,
// so the base fixture's `none` alone cannot separate a value term bound to the
// whole dimension from a correct one. The two slugs are therefore driven over a
// run whose post-terminal state IS `undetermined` and one where it is not: the
// affirmative case legitimately coincides (one state, one shipped phrase), and
// the `observed` case is where a wrongly-bound value term collapses into the
// dimension. Every reading is pinned verbatim regardless, so a reader that
// swapped dimension or dropped its label cannot stay green on either case.
function postTerminalDetail(activity) {
  return {status: 200, payload: {...ON_THIS_RUN_DETAIL.payload, projection_id: "projection:post-terminal", post_terminal_child_activity: activity}};
}

const POST_TERMINAL_EXPECTATIONS = Object.freeze([
  {
    name: "undetermined",
    detail: postTerminalDetail({state: "undetermined", basis: "child_log_scan", event_count: null}),
    // Affirmative: the run IS in this state, so the entry names it -- in the
    // rail's own words, parenthetical included.
    value: "Undetermined (child evidence unavailable) · on this run · basis child log scan · as of seq 34",
    // The dimension answers its own question in postTerminalLabel's words. Over
    // a run that IS undetermined the affirmative value term names that same
    // label, so the two readings COINCIDE here -- correctly: both quote the one
    // shipped phrase for this state. That is why the defect is cut by the
    // verbatim pins below and by the `observed` case, not by a blanket
    // inequality, which would have forced the value term to invent a second
    // wording for a state the rail already has words for.
    dimension: "Undetermined (child evidence unavailable) · on this run · basis child log scan · as of seq 34",
    diverges: false
  },
  {
    name: "observed",
    detail: postTerminalDetail({state: "observed", basis: "child_log_scan", event_count: 7}),
    value: "Not undetermined — this run reads 7 child events after the run ended · on this run · basis child log scan · as of seq 34",
    dimension: "7 child events after the run ended · on this run · basis child log scan · as of seq 34",
    // The run is NOT undetermined, so the value term must deny the term while
    // the dimension reports what the run reads. A value term wrongly bound to
    // the whole dimension collapses these two -- the shipped defect.
    diverges: true
  }
]);

async function checkOnThisRunPostTerminal(appSource) {
  const readings = [];
  for (const expectation of POST_TERMINAL_EXPECTATIONS) {
    const reply = (path) => (isDetail(path) ? expectation.detail : ON_THIS_RUN_LIST);
    const value = await openManualAt(appSource, {hash: DETAIL_HASH, manualHash: `${DETAIL_HASH}?manual=undetermined`, reply, expectView: "detail-view"});
    const dimension = await openManualAt(appSource, {hash: DETAIL_HASH, manualHash: `${DETAIL_HASH}?manual=child-after-end`, reply, expectView: "detail-view"});
    if (value.reading === null || dimension.reading === null) throw failure("post_terminal_not_rendered", "A post-terminal term rendered no ON THIS RUN reading over a run carrying a post-terminal record", "on_this_run_post_terminal", {case: expectation.name});
    if (expectation.diverges && value.reading === dimension.reading) throw failure("post_terminal_value_reads_dimension", "The `undetermined` VALUE term rendered the same string as the whole post-terminal dimension over a run that is NOT undetermined, so the pane answers 'what does undetermined read on this run' with a different state's value", "on_this_run_post_terminal", {case: expectation.name, rendered: value.reading});
    if (value.reading !== expectation.value) throw failure("post_terminal_wrong_value_reading", "The `undetermined` value term rendered a reading that is not the shipped post-terminal vocabulary", "on_this_run_post_terminal", {case: expectation.name, expected: expectation.value, rendered: value.reading});
    if (dimension.reading !== expectation.dimension) throw failure("post_terminal_wrong_dimension_reading", "The post-terminal dimension term rendered a reading that is not its own record", "on_this_run_post_terminal", {case: expectation.name, expected: expectation.dimension, rendered: dimension.reading});
    readings.push({case: expectation.name, value: value.reading, dimension: dimension.reading});
  }
  return {family: "on_this_run_post_terminal", as_of_seq: ON_THIS_RUN_SEQ, readings};
}

async function checkOnThisRunDetail(appSource) {
  const readings = [];
  // COMPLETENESS, asserted against the binding's own exported inventory rather
  // than against a list maintained beside it. A term added to the reader table
  // without an expectation here would otherwise ship with its rendering
  // unproven, and the count in the Elixir tier would move without anyone
  // noticing which term it was.
  const bound = readBoundSlugs(appSource);
  const covered = ON_THIS_RUN_EXPECTATIONS.map((expectation) => expectation.slug).sort();
  if (JSON.stringify(covered) !== JSON.stringify([...bound].sort())) {
    throw failure("on_this_run_coverage_gap", "The executed expectations do not cover exactly the slugs the reader table binds, so some binding ships with its rendering unproven", "on_this_run_detail", {covered, bound: [...bound].sort()});
  }
  for (const expectation of ON_THIS_RUN_EXPECTATIONS) {
    const result = await openManualAt(appSource, {hash: DETAIL_HASH, manualHash: `${DETAIL_HASH}?manual=${expectation.slug}`, reply: onThisRunReply, expectView: "detail-view"});
    if (result.reading === null) throw failure("on_this_run_not_rendered", "A bound term rendered no ON THIS RUN reading over a run that is on screen", "on_this_run_detail", {slug: expectation.slug, pane_text: result.paneText});
    if (result.readingSlug !== expectation.slug) throw failure("on_this_run_wrong_slug", "The rendered reading is not attributed to the term the pane is open at", "on_this_run_detail", {slug: expectation.slug, attributed: result.readingSlug});
    if (result.reading !== expectation.reading) throw failure("on_this_run_wrong_reading", "A bound term rendered a reading that is not the shipped display vocabulary for its dimension", "on_this_run_detail", {slug: expectation.slug, expected: expectation.reading, rendered: result.reading});
    if (result.noRun !== null) throw failure("on_this_run_claimed_no_run", "A bound term claimed no run was in scope while the run detail was painted beside the pane", "on_this_run_detail", {slug: expectation.slug});
    readings.push({slug: expectation.slug, reading: result.reading});
  }
  return {family: "on_this_run_detail_scope", as_of_seq: ON_THIS_RUN_SEQ, readings};
}

// The UNBOUND leg: a term the reader table does not bind omits the part even
// with a run fully in scope, and confesses the omission in wording that states
// THIS PANE's silence rather than characterising the term.
//
// TWO slugs are driven, because the bucket holds two classes and only one of
// them can falsify the confession:
//
//   INSTRUMENT — "read-only" is genuinely a property of the instrument, so a
//   value under that heading would be a fabrication. Any wording survives this
//   case, including a wording that asserts the term has no per-run value.
//
//   RAIL-READ — "mutation" sits in the `dimensions` concern beside Execution,
//   Liveness and Attention, and this same projection carries `run.mutation`,
//   which mutationPanel paints inches from the pane. It is unbound only because
//   the reader table has not bound it, not because the run has nothing to say.
//   Exercising it is the whole point of this leg: a confession that explains
//   the omission by claiming the TERM has no run-scoped value is a fabricated
//   claim about the instrument here, refuted by the panel on the same screen,
//   and the earlier wording ("it names a property of the instrument rather than
//   a reading off a run") shipped for months because the executed tier only
//   ever drove the instrument case, where it happened to be true.
//
// The fixture populates run.mutation precisely so the falsifying condition is
// LIVE rather than hypothetical: the rail has a value to paint while the pane
// stays silent, which is the exact configuration the old wording lied about.
const UNBOUND_INSTRUMENT_SLUG = "read-only";
const UNBOUND_RAIL_READ_SLUG = "mutation";

// Wording that ASSERTS something about the term rather than about the pane.
// Matched in the asserting form only: the shipped confession disclaims the very
// inference these phrases make ("not a claim that the term has no per-run value
// elsewhere in the Monitor"), so a bare substring test for "has no per-run
// value" would fail the pane for the sentence that protects the reader. Each
// refute therefore carries the subject that makes it a claim -- "This term
// has...", not "...has..." -- so the disclaimer survives and only the
// mischaracterisation is caught.
const TERM_CHARACTERISING_REFUTES = Object.freeze([
  "names a property of the instrument",
  "This term has no run-scoped value",
  "This term has no per-run value",
  "rather than a reading off a run"
]);

// `term` is the surface heading the corpus authors for the slug, asserted so a
// typo in the slug cannot pass as "unbound": an unresolvable slug renders no
// entry at all, and every assertion below would be satisfied by a pane showing
// nothing.
const UNBOUND_EXPECTATIONS = Object.freeze([
  {slug: UNBOUND_INSTRUMENT_SLUG, klass: "instrument", term: "read-only"},
  // Driven with a run whose mutation dimension IS populated, so a confession
  // that denies the term a run-scoped value is denying a value on screen.
  {slug: UNBOUND_RAIL_READ_SLUG, klass: "rail_read", term: "Mutation", railValue: "workspace_applied"}
]);

async function checkOnThisRunUnbound(appSource) {
  // Both slugs must actually BE unbound, or this leg proves nothing: a bound
  // slug renders a reading and every assertion below inverts. Read from the
  // bundle's own published inventory rather than assumed, so binding `mutation`
  // later fails here with an instruction instead of quietly gutting the leg.
  const bound = readBoundSlugs(appSource);
  for (const expectation of UNBOUND_EXPECTATIONS) {
    if (bound.includes(expectation.slug)) throw failure("unbound_fixture_slug_is_bound", "This leg drives a slug the reader table now binds, so it no longer exercises the omission path; re-point it at a slug that is still unbound, keeping one instrument-scoped and one the truth rail reads off this same run", "on_this_run_unbound", {slug: expectation.slug, class: expectation.klass});
  }
  const confessions = [];
  for (const expectation of UNBOUND_EXPECTATIONS) {
    const detail = expectation.railValue
      ? {status: 200, payload: {...ON_THIS_RUN_DETAIL.payload, projection_id: "projection:unbound-rail-read", mutation: {status: expectation.railValue, basis: "workspace_diff", observed_semantics: "applied"}}}
      : ON_THIS_RUN_DETAIL;
    const reply = (path) => (isDetail(path) ? detail : ON_THIS_RUN_LIST);
    const result = await openManualAt(appSource, {hash: DETAIL_HASH, manualHash: `${DETAIL_HASH}?manual=${expectation.slug}`, reply, expectView: "detail-view"});
    if (!result.paneText || !result.paneText.includes(expectation.term)) throw failure("unbound_entry_not_resolved", "The pane did not resolve the entry this leg drives, so its silence proves nothing about an unbound term", "on_this_run_unbound", {slug: expectation.slug, class: expectation.klass, expected_term: expectation.term, pane_text: result.paneText});
    if (result.headingPresent) throw failure("unbound_term_emitted_part", "A term the reader table does not bind emitted an ON THIS RUN heading, which promises a live value it cannot source", "on_this_run_unbound", {slug: expectation.slug, class: expectation.klass, pane_text: result.paneText});
    if (result.reading !== null) throw failure("unbound_term_fabricated_value", "A term the reader table does not bind rendered a reading", "on_this_run_unbound", {slug: expectation.slug, class: expectation.klass, rendered: result.reading});
    if (!result.unbound) throw failure("unbound_omission_unconfessed", "The omitted part was left as a silent gap rather than confessed", "on_this_run_unbound", {slug: expectation.slug, class: expectation.klass, pane_text: result.paneText});
    for (const refute of TERM_CHARACTERISING_REFUTES) {
      if (result.unbound.includes(refute)) throw failure("unbound_confession_characterises_term", "The confession explains the omission by claiming something about the TERM, which is false for the terms this same projection carries and the truth rail paints beside the pane", "on_this_run_unbound", {slug: expectation.slug, class: expectation.klass, refute, confession: result.unbound});
    }
    confessions.push({slug: expectation.slug, class: expectation.klass, rail_value: expectation.railValue ?? null, confession: result.unbound});
  }
  // The two classes must receive the SAME sentence. A confession that varies by
  // slug is a curated split list wearing the shape of one rule, and it rots the
  // moment a term moves between the buckets.
  const distinct = new Set(confessions.map((entry) => entry.confession));
  if (distinct.size !== 1) throw failure("unbound_confession_varies_by_term", "The pane printed different omission confessions for different unbound terms, so the wording is a per-term claim rather than one statement about the pane", "on_this_run_unbound", {confessions});
  return {family: "on_this_run_unbound", classes: confessions, confession: confessions[0].confession};
}

// ── The RESIDUAL leg ─────────────────────────────────────────────────────────
//
// The fixture above carries only in-vocabulary tokens, so it cannot see the
// defect this leg exists for: the pane folding a distribution WITHOUT the
// residual bucket the truth rail folds beside it. Two shapes are driven, and
// they fail differently, which is why both are here.
//
//   MIXED — recognized buckets plus one token the frozen order does not name.
//   A pane that drops the residual still prints a plausible reading, so the
//   defect is invisible unless the residual phrase is asserted verbatim.
//
//   RESIDUAL-ONLY — every unit carries a token outside the vocabulary. Here a
//   dropping pane produces the EMPTY phrase and falls through to the
//   "0 observed" default, asserting that a run with four units has none, while
//   the rail inches away reads "4 unrecognized". That is the pane fabricating a
//   claim about the run, so the assertion is both what it must read and what it
//   must never read.
const RESIDUAL_SEQ = 34;
function residualDetail(units) {
  return {
    status: 200,
    payload: {
      run: {id: RUN_ID, title: "A run whose gate tokens are not all in the vocabulary", strategy: "workflow"},
      projection_id: "projection:residual",
      execution: {state: "running", basis: "parent_log_fold"},
      liveness: {state: "not_applicable", basis: "parent_log_only", reachable: false},
      source: {mode: "live", durable_origin: "parent_log", freshness: "current", as_of_seq: RESIDUAL_SEQ, limitations: []},
      units
    }
  };
}

const MIXED_RESIDUAL_DETAIL = residualDetail([
  {logical_id: "u1", label: "one", gate: {state: "checkpoint_ready"}},
  {logical_id: "u2", label: "two", gate: {state: "held"}},
  {logical_id: "u3", label: "three", gate: {state: "weird_new_state"}}
]);

const ONLY_RESIDUAL_DETAIL = residualDetail([
  {logical_id: "u1", label: "one", gate: {state: "weird_new_state"}},
  {logical_id: "u2", label: "two", gate: {state: "weird_new_state"}},
  {logical_id: "u3", label: "three", gate: {state: "another_unshipped_token"}},
  {logical_id: "u4", label: "four", gate: {state: "another_unshipped_token"}}
]);

const RESIDUAL_EXPECTATIONS = Object.freeze([
  // The residual bucket is LAST, after the in-vocabulary buckets in their
  // frozen display order, exactly as the rail appends it.
  {name: "mixed", detail: MIXED_RESIDUAL_DETAIL, reading: "1 held · 1 ready · 1 unrecognized · on this run · basis unit checkpoint fold · as of seq 34"},
  // Four units, none nameable. The pane must count them, not deny them.
  {name: "residual_only", detail: ONLY_RESIDUAL_DETAIL, reading: "4 unrecognized · on this run · basis unit checkpoint fold · as of seq 34"}
]);

async function checkOnThisRunResidual(appSource) {
  const readings = [];
  for (const expectation of RESIDUAL_EXPECTATIONS) {
    const reply = (path) => (isDetail(path) ? expectation.detail : ON_THIS_RUN_LIST);
    const result = await openManualAt(appSource, {hash: DETAIL_HASH, manualHash: `${DETAIL_HASH}?manual=dependency-gate`, reply, expectView: "detail-view"});
    if (result.reading === null) throw failure("residual_not_rendered", "The gate term rendered no ON THIS RUN reading over a run carrying out-of-vocabulary tokens", "on_this_run_residual", {case: expectation.name, pane_text: result.paneText});
    if (result.reading !== expectation.reading) throw failure("residual_bucket_dropped", "The pane folded a distribution without the residual bucket the truth rail folds beside it, so the pane and the rail disagree about how many units the run has", "on_this_run_residual", {case: expectation.name, expected: expectation.reading, rendered: result.reading});
    if (expectation.name === "residual_only" && result.reading.includes("0 observed")) throw failure("residual_only_claimed_none", "The pane asserted no observations for a run whose every unit carries a token outside the shipped vocabulary", "on_this_run_residual", {case: expectation.name, rendered: result.reading});
    readings.push({case: expectation.name, reading: result.reading});
  }
  return {family: "on_this_run_residual", as_of_seq: RESIDUAL_SEQ, readings};
}

// The residual red proof: strip the residual bucket out of the ONE fold both
// the rail and the pane read, and require the leg to go red. Patching the fold
// itself is what makes the proof meaningful — a proof that patched only the
// pane could not tell whether the pane still had a private copy of the loop.
const RESIDUAL_APPEND = `    if (residual > 0) buckets.push({token: "unknown", phrase: residual + " unrecognized"});`;

function tamperResidual(appSource) {
  if (!appSource.includes(RESIDUAL_APPEND)) throw failure("residual_tamper_target_missing", "distributionBuckets no longer appends the residual bucket in the shape the red proof patches; update the red proof rather than deleting it", "residual_red_proof");
  return appSource.replace(RESIDUAL_APPEND, "");
}

async function checkOnThisRunResidualRedProof(appSource) {
  const tampered = tamperResidual(appSource);
  try {
    await checkOnThisRunResidual(tampered);
  } catch (error) {
    if (error && error.harnessKind === "residual_bucket_dropped") return {family: "on_this_run_residual", detected: "residual_bucket_dropped"};
    throw error;
  }
  throw failure("residual_red_proof_failed", "The residual leg stayed green against a fold that drops every out-of-vocabulary unit", "residual_red_proof");
}

// The LIST-SCOPE degradation, driven through the order that actually produces
// it: visit the run detail FIRST so state.detail holds a real snapshot, then
// navigate to the runs list, then press `?`. A pane that reads state.detail
// without the scope guard renders the previous run's values here, and every
// preservation assertion in this file stays green while it does.
async function runListScopeDegradation(appSource) {
  const {documentStub, app, status} = buildDom(null);
  void documentStub;
  const requests = [];
  const fetchStub = (path) => {
    requests.push(path);
    const answer = onThisRunReply(path);
    return Promise.resolve(jsonResponse(answer.status, answer.payload));
  };
  const windowListeners = new Map();
  const locationStub = {hash: DETAIL_HASH};
  const sandbox = {
    window: {addEventListener(type, handler) { windowListeners.set(type, handler); }, scrollX: 0, scrollY: 0, scrollTo() {}, __pixirBootstrap: new Promise(() => {})},
    document: documentStub,
    location: locationStub,
    history: {replaceState() {}, state: null},
    fetch: fetchStub,
    EventSource: function () { return {addEventListener() {}, close() {}}; },
    setTimeout: (fn) => { void fn; return 0; },
    clearTimeout() {}, setInterval: () => 0, clearInterval() {},
    queueMicrotask,
    URLSearchParams, URL, Set, Map, Object, Array, Number, String, JSON, Math, Date, RegExp, Error, TypeError, Promise, Boolean, Symbol, Intl,
    console: {log() {}, warn() {}, error() {}, debug() {}, info() {}}
  };
  sandbox.globalThis = sandbox;
  sandbox.self = sandbox;
  vm.createContext(sandbox);
  vm.runInContext(appSource, sandbox, {filename: "app.js"});
  const hashchange = windowListeners.get("hashchange");
  if (typeof hashchange !== "function") throw failure("hashchange_missing", "app.js registered no hashchange listener", "list_scope_degradation");
  const settle = async () => { for (let turn = 0; turn < 60; turn += 1) await new Promise((resolve) => setImmediate(resolve)); };

  hashchange();
  await settle();
  const detail = snapshotView(app, status);
  if (!String(detail.viewClass || "").split(/\s+/).includes("detail-view")) throw failure("detail_not_painted", "The degradation scenario never painted the run detail, so state.detail never held the snapshot the stale read would come from", "list_scope_degradation", {view_class: detail.viewClass, requests});

  locationStub.hash = "#/runs";
  hashchange();
  await settle();
  const list = snapshotView(app, status);
  if (!String(list.viewClass || "").split(/\s+/).includes("runs-view")) throw failure("list_not_painted", "The degradation scenario never reached the runs list", "list_scope_degradation", {view_class: list.viewClass, requests});

  locationStub.hash = "#/runs?manual=liveness";
  hashchange();
  await settle();
  if (!manualPaneMounted(app)) throw failure("manual_not_mounted", "The manual pane never mounted over the runs list", "list_scope_degradation");
  const dd = app.querySelector(".manual-on-this-run");
  const noRun = app.querySelector(".manual-no-run");
  return {reading: dd ? collectText(dd).join("") : null, noRun: noRun ? noRun.textContent : null, paneText: manualPaneText(app), listViewClass: list.viewClass};
}

async function checkListScopeDegradation(appSource) {
  const result = await runListScopeDegradation(appSource);
  // The headline defect: a stale detail's values presented as "this run" while
  // the operator is looking at a list.
  if (result.reading !== null) throw failure("stale_detail_read_at_list_scope", "Opening the manual over the RUNS LIST rendered a run-scoped reading, which can only have come from a detail the view beside the pane is no longer painting", "list_scope_degradation", {rendered: result.reading});
  if (!result.noRun) throw failure("list_scope_silent", "The manual over the runs list emitted no statement about run scope at all, so the reader is left to guess whether a value was withheld or none exists", "list_scope_degradation", {pane_text: result.paneText});
  if (!result.noRun.includes("No run is in scope")) throw failure("list_scope_wrong_voice", "The list-scope statement is not the shipped no-run-in-scope copy", "list_scope_degradation", {rendered: result.noRun});
  if (!result.noRun.includes("Runs list")) throw failure("list_scope_unnamed", "The list-scope statement does not name the scope the reader is actually in", "list_scope_degradation", {rendered: result.noRun});
  return {family: "on_this_run_list_scope", statement: result.noRun};
}

// ── The UNIT-SCOPE leg ───────────────────────────────────────────────────────
//
// `manualRunInScope` admits `route.view === "unit"`, and until this leg existed
// nothing in the executed tier ever drove a unit route: every ON THIS RUN leg
// declares `expectView: "detail-view"`, so the whole unit branch of the guard
// shipped unexercised. What it shipped WITH was a reader table that folded the
// run on every route, which put a run-wide number under a heading reading ON
// THIS RUN while the Unit Inspector painted THAT UNIT's value for the same
// dimension inches away — two answers to one question on one screen.
//
// The fixture's opened unit disagrees with the run on every per-unit dimension
// (see ON_THIS_RUN_UNIT), so each expectation below is a string the run-folding
// reader could not produce. The SCOPE phrase is pinned too: a reading that
// happened to match the unit but still claimed to be about the run would be the
// same lie with better arithmetic.
const UNIT_HASH = `#/runs/${RUN_ID}/units/${ON_THIS_RUN_UNIT}`;
const UNIT_SCOPE_PHRASE = `on this unit (${ON_THIS_RUN_UNIT})`;

// Per-unit dimensions: the value MUST be this unit's, and the scope phrase MUST
// name the unit. Each `runReading` is what the run fold produces for the same
// slug, asserted DIFFERENT so the leg cannot pass by coincidence.
const UNIT_SCOPE_EXPECTATIONS = Object.freeze([
  {slug: "execution", reading: "queued · on this unit (u3) · basis subagent events · as of seq 34"},
  {slug: "liveness", reading: "stale handle · on this unit (u3) · basis delegate owner · as of seq 34"},
  // The dimension the corpus DEFINES as per-unit: "the Unit Inspector's label
  // for the runtime's own gate decision on one unit". Both the value and the
  // basis are the unit's, which is the pair the "Runtime gate" truthCard paints.
  {slug: "runtime-gate", reading: "held · on this unit (u3) · basis workflow event · as of seq 34"},
  // The rail's label for the same dimension, answered about the same entity:
  // one dimension, one reader, so the label cannot change the answer.
  {slug: "dependency-gate", reading: "held · on this unit (u3) · basis workflow event · as of seq 34"},
  // A gate VALUE term, whose corpus surface_string is the single word "Ready".
  // At unit scope the honest answer is whether THIS unit is ready, not how many
  // of its siblings are.
  {slug: "checkpoint-ready", reading: "Not ready — this unit reads held · on this unit (u3) · basis workflow event · as of seq 34"},
  {slug: "model-advisory", reading: "unclassified verdict · on this unit (u3) · basis model declared · as of seq 34"},
  {slug: "unclassified-verdict", reading: "unclassified verdict · on this unit (u3) · basis model declared · as of seq 34"},
  {slug: "invalid-advisory", reading: "Not invalid — this unit reads unclassified verdict · on this unit (u3) · basis model declared · as of seq 34"},
  {slug: "attention", reading: "required · on this unit (u3) · basis parent log · as of seq 34"},
  {slug: "parent-observed", reading: "required · on this unit (u3) · basis parent log · as of seq 34"},
  {slug: "stale-handle", reading: "stale handle · on this unit (u3) · basis delegate owner · as of seq 34"},
  {slug: "externally-owned", reading: "Not externally owned — this unit reads stale handle · on this unit (u3) · basis delegate owner · as of seq 34"}
]);

// Run-scoped dimensions, driven on the SAME unit route. These must NOT narrow:
// no unit carries a source mode, a post-terminal record or an as-of seq, so a
// reader that "helpfully" scoped them to the opened unit would be inventing a
// per-unit value no projection produces. They keep saying `on this run`, which
// is what they are facts about.
const UNIT_ROUTE_RUN_SCOPED = Object.freeze([
  {slug: "source-run-scoped", reading: "live · on this run · basis parent log · as of seq 34"},
  {slug: "live-source-mode", reading: "live · on this run · basis parent log · as of seq 34"},
  {slug: "reconstructed", reading: "Not reconstructed — this run reads live · on this run · basis parent log · as of seq 34"},
  {slug: "child-after-end", reading: "No child events after the run ended · on this run · basis child log scan · as of seq 34"},
  {slug: "undetermined", reading: "Not undetermined — this run reads No child events after the run ended · on this run · basis child log scan · as of seq 34"},
  {slug: "as-of-seq", reading: "seq 34 · on this run"}
]);

// The run-scope reading of each per-unit slug, read off the detail expectations
// rather than restated, so "the unit reading differs from the run reading" is
// checked against the one list that defines what the run reading is.
function detailReadingFor(slug) {
  const found = ON_THIS_RUN_EXPECTATIONS.find((expectation) => expectation.slug === slug);
  if (!found) throw failure("unit_scope_slug_missing_detail_expectation", "A slug the unit-scope leg drives has no detail-scope expectation to be compared against, so the leg cannot prove the two scopes differ", "on_this_run_unit_scope", {slug});
  return found.reading;
}

async function checkOnThisRunUnitScope(appSource) {
  const readings = [];
  for (const expectation of UNIT_SCOPE_EXPECTATIONS) {
    const result = await openManualAt(appSource, {hash: UNIT_HASH, manualHash: `${UNIT_HASH}?manual=${expectation.slug}`, reply: onThisRunReply, expectView: "unit-view"});
    if (result.reading === null) throw failure("unit_scope_not_rendered", "A bound term rendered no ON THIS RUN reading over a logical unit that is on screen", "on_this_run_unit_scope", {slug: expectation.slug, pane_text: result.paneText});
    if (result.reading !== expectation.reading) throw failure("unit_scope_wrong_reading", "On the Unit Inspector the pane rendered a value that is not the opened unit's, so the pane and the truth card beside it answer one question with two different values", "on_this_run_unit_scope", {slug: expectation.slug, expected: expectation.reading, rendered: result.reading});
    if (!result.reading.includes(UNIT_SCOPE_PHRASE)) throw failure("unit_scope_unnamed", "A unit-scoped reading did not name the unit it is a fold over, leaving the reader to assume it was about whatever they were looking at", "on_this_run_unit_scope", {slug: expectation.slug, rendered: result.reading});
    // The falsifying comparison: the run fold's answer for this same slug. If
    // they ever coincide, this expectation has stopped proving anything and the
    // fixture must be re-shaped rather than the assertion relaxed.
    const runReading = detailReadingFor(expectation.slug);
    if (result.reading === runReading) throw failure("unit_scope_indistinguishable", "The unit-scope reading is byte-identical to the run-scope one for this slug, so this expectation cannot tell a scoped reader from a run-folding one; re-shape the fixture so the opened unit disagrees with its run", "on_this_run_unit_scope", {slug: expectation.slug, rendered: result.reading});
    readings.push({slug: expectation.slug, scope: "unit", reading: result.reading});
  }
  for (const expectation of UNIT_ROUTE_RUN_SCOPED) {
    const result = await openManualAt(appSource, {hash: UNIT_HASH, manualHash: `${UNIT_HASH}?manual=${expectation.slug}`, reply: onThisRunReply, expectView: "unit-view"});
    if (result.reading !== expectation.reading) throw failure("unit_route_run_scoped_drifted", "A run-scoped dimension rendered something other than its run reading while a unit was open, which means the pane invented a per-unit value for a dimension no unit carries", "on_this_run_unit_scope", {slug: expectation.slug, expected: expectation.reading, rendered: result.reading});
    readings.push({slug: expectation.slug, scope: "run", reading: result.reading});
  }

  // ABSENCE, which the bucket vocabulary has no token for. The `present === true`
  // guard keeps it out of every count, and the corpus says so outright under
  // `unclassified verdict`: "No advisory. Absence never reaches a bucket."
  //
  // The Inspector card renders `unit.advisory.verdict` through marker(), whose
  // titleCase resolves the missing field to "unknown" -- the very word the alias
  // map exists to rename, because an unclassifiable verdict and no verdict at
  // all are different facts. The pane must NOT quote that: doing so would make
  // the one surface built to prevent that confusion the surface teaching it.
  // This is the single place the pane deliberately says something the card does
  // not, and the assertion pins both halves of that decision.
  const absentUnit = "u-no-advisory";
  const absentDetail = {status: 200, payload: {...ON_THIS_RUN_DETAIL.payload, projection_id: "projection:advisory-absent", units: [...ON_THIS_RUN_DETAIL.payload.units, {logical_id: absentUnit, label: "five", execution: {state: "queued", basis: "subagent_events"}, liveness: {state: "stale_handle", basis: "delegate_owner"}, gate: {state: "held", basis: "workflow_event"}, advisory: {present: false}, attention: {required: false}}]}};
  const absentHash = `#/runs/${RUN_ID}/units/${absentUnit}`;
  const absent = await openManualAt(appSource, {hash: absentHash, manualHash: `${absentHash}?manual=model-advisory`, reply: (path) => (isDetail(path) ? absentDetail : ON_THIS_RUN_LIST), expectView: "unit-view"});
  const absentExpected = `no advisory · on this unit (${absentUnit}) · basis model declared · as of seq 34`;
  if (absent.reading !== absentExpected) throw failure("unit_absent_advisory_wrong_reading", "A unit carrying NO advisory did not read as absence. Absence never reaches a bucket, so the pane must name it rather than borrow the card's titleCase of a missing field, which resolves to `unknown` -- the exact word the alias map renames because an unclassifiable verdict and no verdict at all are different facts", "on_this_run_unit_scope", {expected: absentExpected, rendered: absent.reading});
  if (/\bunclassified verdict\b/.test(absent.reading) || /\bunknown\b/.test(absent.reading)) throw failure("unit_absent_advisory_read_as_unknown", "A unit with no advisory at all was reported as an unclassified or unknown VERDICT, which asserts the model wrote something it did not", "on_this_run_unit_scope", {rendered: absent.reading});
  readings.push({slug: "model-advisory", scope: "unit_absent_advisory", reading: absent.reading});

  // THE ONE TOKEN THE ALIAS RENAMES. Every unit-scope gate expectation above
  // opens u3, whose gate is `held` -- a token GATE_DISPLAY_ALIASES leaves
  // alone, so the whole family passed while the pane and the card printed
  // different words for `checkpoint_ready`, the single value the alias map
  // exists to rename. The blind spot was structural: no fixture unit in scope
  // carried it.
  //
  // Opening u1 closes it. The Unit Inspector's "Runtime gate" card renders
  // marker(unit.gate.state) -> titleCase -> "checkpoint ready"; the pane quotes
  // the surface it explains, so it must say the same. "ready" here would be the
  // distribution's word for a COUNT, printed where one unit's state was asked
  // for.
  const readyUnit = "u1";
  const readyHash = `#/runs/${RUN_ID}/units/${readyUnit}`;
  const readyExpected = `checkpoint ready · on this unit (${readyUnit}) · basis workflow event · as of seq 34`;
  for (const slug of ["runtime-gate", "dependency-gate"]) {
    const ready = await openManualAt(appSource, {hash: readyHash, manualHash: `${readyHash}?manual=${slug}`, reply: onThisRunReply, expectView: "unit-view"});
    if (ready.reading !== readyExpected) throw failure("unit_gate_word_diverged_from_card", "On a unit whose gate is `checkpoint_ready` the pane printed a different word than the Unit Inspector's Runtime gate card renders for the same value, so one gate state has two names inches apart on the one route where this term's surface string appears", "on_this_run_unit_scope", {slug, expected: readyExpected, rendered: ready.reading});
    readings.push({slug, scope: "unit_checkpoint_ready", reading: ready.reading});
  }
  // The denial half of the value term, read off the SAME unit: the term keeps
  // its own surface string ("Ready") and the state quotes the card.
  const readyDenial = await openManualAt(appSource, {hash: readyHash, manualHash: `${readyHash}?manual=checkpoint-ready`, reply: onThisRunReply, expectView: "unit-view"});
  const readyDenialExpected = `ready · on this unit (${readyUnit}) · basis workflow event · as of seq 34`;
  if (readyDenial.reading !== readyDenialExpected) throw failure("unit_gate_value_wrong_reading", "The checkpoint-ready VALUE term did not read affirmatively on a unit that is in that state", "on_this_run_unit_scope", {expected: readyDenialExpected, rendered: readyDenial.reading});
  readings.push({slug: "checkpoint-ready", scope: "unit_checkpoint_ready", reading: readyDenial.reading});

  // A unit with NO ATTENTION RECORD. `required === true ? "yes" : "no"`
  // collapsed absence into the negative, so this unit read "not required ·
  // basis parent log" -- a fabricated negative carrying a fabricated basis. The
  // projection asserts neither. The pane must say so, and must claim NO basis:
  // the parent Log is where a fact READ off the record came from, and there is
  // no record here for it to be the provenance of.
  const noAttentionUnit = "u-no-attention";
  const noAttentionDetail = {status: 200, payload: {...ON_THIS_RUN_DETAIL.payload, projection_id: "projection:attention-absent", units: [...ON_THIS_RUN_DETAIL.payload.units, {logical_id: noAttentionUnit, label: "six", execution: {state: "queued", basis: "subagent_events"}, liveness: {state: "stale_handle", basis: "delegate_owner"}, gate: {state: "held", basis: "workflow_event"}, advisory: {present: true, verdict: "pass", parse_status: "ok"}}]}};
  const noAttentionHash = `#/runs/${RUN_ID}/units/${noAttentionUnit}`;
  for (const slug of ["attention", "parent-observed"]) {
    const missing = await openManualAt(appSource, {hash: noAttentionHash, manualHash: `${noAttentionHash}?manual=${slug}`, reply: (path) => (isDetail(path) ? noAttentionDetail : ON_THIS_RUN_LIST), expectView: "unit-view"});
    if (missing.reading === null) throw failure("unit_absent_attention_not_rendered", "A unit with no attention record rendered no reading at all where an honest statement of absence was required", "on_this_run_unit_scope", {slug});
    if (/\bnot required\b/.test(missing.reading)) throw failure("unit_absent_attention_read_as_no", "A unit whose projection carries NO attention record was reported `not required`, which asserts a negative the projection never made", "on_this_run_unit_scope", {slug, rendered: missing.reading});
    if (missing.reading.includes("basis parent log")) throw failure("unit_absent_attention_fabricated_basis", "A unit with no attention record carried the parent-log basis, attributing a provenance to a fact that was never read from anything", "on_this_run_unit_scope", {slug, rendered: missing.reading});
    if (!missing.reading.includes("No attention record on this unit")) throw failure("unit_absent_attention_unnamed", "A unit with no attention record did not state that absence in the pane's own voice", "on_this_run_unit_scope", {slug, rendered: missing.reading});
    readings.push({slug, scope: "unit_absent_attention", reading: missing.reading});
  }

  // THE SAME ABSENCE, ONE BRANCH AWAY. Narrowing only the unit branch left the
  // run fold collapsing three cases into two inside runAttentionCounts, so the
  // very unit above -- driven at RUN scope, on the more-travelled run-detail
  // route -- was still counted in the negative bucket and printed as one of
  // "N not required" under `basis parent log`. Same fabricated negative, same
  // fabricated provenance, hidden inside a number instead of stated in a
  // sentence.
  //
  // The run carries five units here: one required, three that assert `required:
  // false`, and one the projection says nothing about. The honest fold counts
  // FOUR, because a count is a claim about units the projection spoke about.
  // Pinned verbatim: "1 required · 4 not required" is the shipped defect and
  // "1 required · 3 not required" is the fold excluding what it did not read,
  // and only a verbatim pin separates them.
  const absentAttentionRunExpected = "1 required · 3 not required · on this run · basis parent log · as of seq 34";
  for (const slug of ["attention", "parent-observed"]) {
    const folded = await openManualAt(appSource, {hash: DETAIL_HASH, manualHash: `${DETAIL_HASH}?manual=${slug}`, reply: (path) => (isDetail(path) ? noAttentionDetail : ON_THIS_RUN_LIST), expectView: "detail-view"});
    if (folded.reading !== absentAttentionRunExpected) throw failure("run_absent_attention_counted_as_no", "The run-scope attention fold counted a unit whose projection carries NO attention record into the `not required` bucket, asserting a negative the projection never made and attributing it to the parent Log, which observed nothing about that unit", "on_this_run_unit_scope", {slug, expected: absentAttentionRunExpected, rendered: folded.reading});
    readings.push({slug, scope: "run_absent_attention", reading: folded.reading});
  }
  return {family: "on_this_run_unit_scope", unit: ON_THIS_RUN_UNIT, as_of_seq: ON_THIS_RUN_SEQ, readings};
}

// The unit-scope red proof: rebind the gate reader to the RUN fold on every
// route — the shipped defect exactly — and require the leg to go red.
const GATE_UNIT_BRANCH = `    if (scope.unit) return {value: unitGateLabel(scope.unit), basis: scope.unit.gate && scope.unit.gate.basis, scope: manualUnitScopeLabel(scope.unit)};`;

function tamperGateScope(appSource) {
  if (!appSource.includes(GATE_UNIT_BRANCH)) throw failure("unit_scope_tamper_target_missing", "manualGateReading no longer narrows to the opened unit in the shape the red proof patches; update the red proof rather than deleting it", "unit_scope_red_proof");
  return appSource.replace(GATE_UNIT_BRANCH, "");
}

async function checkOnThisRunUnitScopeRedProof(appSource) {
  const tampered = tamperGateScope(appSource);
  try {
    await checkOnThisRunUnitScope(tampered);
  } catch (error) {
    if (error && error.harnessKind === "unit_scope_wrong_reading") return {family: "on_this_run_unit_scope", detected: "unit_scope_wrong_reading"};
    throw error;
  }
  throw failure("unit_scope_red_proof_failed", "The unit-scope leg stayed green against a gate reader that folds the whole run while the Unit Inspector paints one unit", "unit_scope_red_proof");
}

// Reinstate the SHIPPED gate-word defect exactly: send the pane's unit branch
// back through the distribution aliases instead of the card's own label path,
// which renames `checkpoint_ready` to "ready" while the card says "checkpoint
// ready". Without a checkpoint_ready unit in scope this tamper is invisible,
// which is precisely why the leg now opens one.
const GATE_SHARED_LABEL = `  function unitGateLabel(unit) { return titleCase(unit && unit.gate && unit.gate.state); }`;

async function checkUnitGateWordRedProof(appSource) {
  if (!appSource.includes(GATE_SHARED_LABEL)) throw failure("unit_gate_word_tamper_target_missing", "unitGateLabel is no longer the shared label path in the shape the red proof patches; update the red proof rather than deleting it", "unit_gate_word_red_proof");
  const tampered = appSource.replace(GATE_SHARED_LABEL, `  function unitGateLabel(unit) { return distributionValueLabel(scalar(unit && unit.gate && unit.gate.state, "unknown"), GATE_DISPLAY_ALIASES); }`);
  try {
    await checkOnThisRunUnitScope(tampered);
  } catch (error) {
    if (error && error.harnessKind === "unit_gate_word_diverged_from_card") return {family: "on_this_run_unit_scope", detected: "unit_gate_word_diverged_from_card"};
    throw error;
  }
  throw failure("unit_gate_word_red_proof_failed", "The unit-scope leg stayed green against a pane that renames the gate value the card beside it spells out in full", "unit_gate_word_red_proof");
}

// Reinstate the SHIPPED absent-attention defect at UNIT scope: collapse the
// three cases back into two, so a unit with no attention record reads `not
// required` with the parent-log basis stapled to it. Patched at the bucket
// reader, which is where both scopes now decide it.
//
// The tamper reinstates the shipped EXPRESSION, `unit.attention &&
// unit.attention.required === true ? "yes" : "no"`, rather than merely deleting
// the absence guard. Deleting it would leave the reader dereferencing an absent
// object and THROWING, which renderManualOnThisRun catches into the
// carries-no-value copy -- a different, honest-by-accident degradation that
// happens not to print `not required`. A red proof that goes red for the wrong
// reason proves the assertion catches crashes, not fabrications, so this one
// restores the defect that actually shipped.
const ATTENTION_BUCKET_ABSENCE = `    if (!unitHasAttentionRecord(unit)) return null;
    return unit.attention.required === true ? "yes" : "no";`;
const ATTENTION_BUCKET_COLLAPSED = `    return unit.attention && unit.attention.required === true ? "yes" : "no";`;

function tamperAttentionAbsence(appSource, kind) {
  if (!appSource.includes(ATTENTION_BUCKET_ABSENCE)) throw failure(kind + "_tamper_target_missing", "unitAttentionBucket no longer excludes an absent attention record in the shape the red proof patches; update the red proof rather than deleting it", kind);
  return appSource.replace(ATTENTION_BUCKET_ABSENCE, ATTENTION_BUCKET_COLLAPSED);
}

async function checkUnitAbsentAttentionRedProof(appSource) {
  const tampered = tamperAttentionAbsence(appSource, "unit_absent_attention_red_proof");
  try {
    await checkOnThisRunUnitScope(tampered);
  } catch (error) {
    if (error && error.harnessKind === "unit_absent_attention_read_as_no") return {family: "on_this_run_unit_scope", detected: "unit_absent_attention_read_as_no"};
    throw error;
  }
  throw failure("unit_absent_attention_red_proof_failed", "The unit-scope leg stayed green against a pane that reports a unit with no attention record as `not required`", "unit_absent_attention_red_proof");
}

// The RUN-scope half of the same defect, proved separately because it survived
// the unit-scope fix: the tamper above is caught by the unit assertions before
// the run fold is ever reached, so a fold that still counts absence as "no"
// would ride along invisibly behind them. This proof restores absence to the
// negative bucket for the FOLD ALONE -- the unit branch keeps its honest
// answer -- and requires the run-scope assertion to be the one that fires.
async function checkRunAbsentAttentionRedProof(appSource) {
  const tampered = appSource.replace(
    `  function runAttentionCounts(run) { return stateCounts(run.units, unitAttentionBucket); }`,
    `  function runAttentionCounts(run) { return stateCounts(run.units, function (unit) { return unit.attention && unit.attention.required === true ? "yes" : "no"; }); }`
  );
  if (tampered === appSource) throw failure("run_absent_attention_tamper_target_missing", "runAttentionCounts no longer folds through unitAttentionBucket in the shape the red proof patches; update the red proof rather than deleting it", "run_absent_attention_red_proof");
  try {
    await checkOnThisRunUnitScope(tampered);
  } catch (error) {
    if (error && error.harnessKind === "run_absent_attention_counted_as_no") return {family: "on_this_run_unit_scope", detected: "run_absent_attention_counted_as_no"};
    throw error;
  }
  throw failure("run_absent_attention_red_proof_failed", "The leg stayed green against a run fold that counts a unit with no attention record into the `not required` bucket", "run_absent_attention_red_proof");
}

// ── The UNIT-ABSENT leg ──────────────────────────────────────────────────────
//
// The scope guard used to key on ROUTE SHAPE alone. `renderUnit` bails to
// renderUnavailable("This logical unit is absent or its provisional deep link
// was invalidated.") WITHOUT clearing state.detail — unlike renderProjectionFailure,
// which nulls it — so every identity check in manualRunInScope still passed and
// the pane rendered a live, basis-attributed, seq-stamped ON THIS RUN reading
// beside a view declaring the projection unavailable. A positive claim about a
// run the screen says is unavailable is the exact class the reader table exists
// to prevent.
//
// The route is a REQUEST; the painted view is the RECEIPT. This leg drives the
// bail-out and requires the pane to state no run is in scope.
const ABSENT_UNIT_HASH = `#/runs/${RUN_ID}/units/zzz-not-a-unit`;

async function checkOnThisRunUnitAbsent(appSource) {
  const statements = [];
  // Driven across a per-unit slug and a run-scoped one: the defect was that a
  // route-shape guard passed for BOTH, so a fix that only narrowed the per-unit
  // family would leave `execution` reading "running · basis parent log fold"
  // beside "Projection unavailable".
  for (const slug of ["runtime-gate", "execution", "as-of-seq"]) {
    const result = await openManualAt(appSource, {hash: ABSENT_UNIT_HASH, manualHash: `${ABSENT_UNIT_HASH}?manual=${slug}`, reply: onThisRunReply, expectView: "error-view"});
    if (result.reading !== null) throw failure("unit_absent_read_a_run", "The pane rendered a live ON THIS RUN reading beside a view declaring the requested projection unavailable, so it makes a positive claim about a run the screen beside it says it cannot show", "on_this_run_unit_absent", {slug, rendered: result.reading});
    if (!result.noRun) throw failure("unit_absent_silent", "The pane emitted no statement about run scope beside the unavailable view, leaving the reader to guess whether a value was withheld or none exists", "on_this_run_unit_absent", {slug, pane_text: result.paneText});
    if (!result.noRun.includes("No run is in scope")) throw failure("unit_absent_wrong_voice", "The statement beside the unavailable view is not the shipped no-run-in-scope copy", "on_this_run_unit_absent", {slug, rendered: result.noRun});
    // The copy must point at the view rather than diagnose on its own: the view
    // beside the pane already says what went wrong, and a pane repeating a
    // diagnosis it did not make is the pane speaking beyond its evidence.
    if (!result.noRun.includes("the view beside this pane is not painting one")) throw failure("unit_absent_copy_unhelpful", "The statement does not point the reader at the view that actually explains why no run is painted", "on_this_run_unit_absent", {slug, rendered: result.noRun});
    statements.push({slug, statement: result.noRun});
  }
  const distinct = new Set(statements.map((entry) => entry.statement));
  if (distinct.size !== 1) throw failure("unit_absent_statement_varies", "The pane printed different no-run statements for different slugs beside one unavailable view, so the wording is a per-term claim rather than one statement about scope", "on_this_run_unit_absent", {statements});

  // THE CASE THAT MUST STAY GREEN. The same absent unit UNDER FOLLOW paints
  // "Unit unavailable while following", whose own provenance states that "the
  // followed run identity is still projected. Only this logical unit is absent
  // within the followed run; Follow did not switch or lose the run." The run
  // really is on screen and really is the followed one, so denying run scope
  // there would make the pane refuse a value the view beside it is affirming --
  // a blanket route-view denial, which is the fix this leg must NOT accept.
  const followHash = `${ABSENT_UNIT_HASH}?follow=1`;
  const follow = await openManualAt(appSource, {hash: followHash, manualHash: `${followHash}&manual=execution`, reply: onThisRunReply, expectView: "follow-unit-unavailable"});
  if (follow.reading === null) throw failure("follow_unit_unavailable_denied_run_scope", "Beside 'Unit unavailable while following' -- a view whose own copy states the followed run identity is still projected -- the pane refused to read the run, so the fix denies scope by view class instead of by whether a run is actually painted", "on_this_run_unit_absent", {pane_text: follow.paneText, no_run: follow.noRun});
  const followExpected = detailReadingFor("execution");
  if (follow.reading !== followExpected) throw failure("follow_unit_unavailable_wrong_reading", "The run-scoped reading beside the followed-unit-unavailable view is not the run's own reading", "on_this_run_unit_absent", {expected: followExpected, rendered: follow.reading});
  return {family: "on_this_run_unit_absent", statement: statements[0].statement, slugs: statements.map((entry) => entry.slug), follow_unit_unavailable_reading: follow.reading};
}

// The unit-absent red proof: restore the ROUTE-SHAPE-ONLY guard by deleting the
// painted-view check, and require the leg to go red on the reading it produces.
const PAINTED_VIEW_GUARD = `    if (!paintedRunScopeView(painted)) return null;`;

function tamperPaintedGuard(appSource) {
  if (!appSource.includes(PAINTED_VIEW_GUARD)) throw failure("unit_absent_tamper_target_missing", "manualRunInScope no longer consults the painted view in the shape the red proof patches; update the red proof rather than deleting it", "unit_absent_red_proof");
  return appSource.replace(PAINTED_VIEW_GUARD, "");
}

async function checkOnThisRunUnitAbsentRedProof(appSource) {
  const tampered = tamperPaintedGuard(appSource);
  try {
    await checkOnThisRunUnitAbsent(tampered);
  } catch (error) {
    if (error && error.harnessKind === "unit_absent_read_a_run") return {family: "on_this_run_unit_absent", detected: "unit_absent_read_a_run"};
    throw error;
  }
  throw failure("unit_absent_red_proof_failed", "The unit-absent leg stayed green against a scope guard that keys on route shape alone, which is the shipped defect", "unit_absent_red_proof");
}

// ── The detail-leg red proof ─────────────────────────────────────────────────
//
// The detail leg asserts nineteen exact readings, which sounds unfalsifiable
// until you ask what a broken binding looks like: readers that all return null
// render the honest "this snapshot did not populate it" line, and the whole
// family would then be asserting nothing about the accessors at all. The tamper
// makes every reader return null and requires the family to go red on a term
// that must have a value.
const READER_DISPATCH = `    try { reading = MANUAL_RUN_READERS[slug]({run: run, unit: manualUnitInScope(run, route)}); } catch (_error) { reading = null; }`;

function tamperReaders(appSource) {
  if (!appSource.includes(READER_DISPATCH)) throw failure("reader_tamper_target_missing", "renderManualOnThisRun no longer dispatches through the reader table in the shape the red proof patches; update the red proof rather than deleting it", "on_this_run_red_proof");
  return appSource.replace(READER_DISPATCH, `    reading = null;`);
}

async function checkOnThisRunRedProof(appSource) {
  const tampered = tamperReaders(appSource);
  try {
    await checkOnThisRunDetail(tampered);
  } catch (error) {
    if (error && error.harnessKind === "on_this_run_not_rendered") return {family: "on_this_run_detail_scope", detected: "on_this_run_not_rendered"};
    throw error;
  }
  throw failure("on_this_run_red_proof_failed", "The detail leg stayed green against a binding whose readers produce no value at all", "on_this_run_red_proof");
}

// ── The post-terminal red proof ──────────────────────────────────────────────
//
// The tamper reinstates the shipped defect exactly: bind the `undetermined`
// VALUE slug back to the whole-dimension reader. The leg must go red on
// `post_terminal_value_reads_dimension`, which is the assertion that the base
// fixture's `none` state could not make.
const POST_TERMINAL_VALUE_BINDING = `    "undetermined": function (scope) { return manualPostTerminalValueReading(scope, "undetermined"); },`;

function tamperPostTerminalValue(appSource) {
  if (!appSource.includes(POST_TERMINAL_VALUE_BINDING)) throw failure("post_terminal_tamper_target_missing", "the reader table no longer binds `undetermined` to a value-reading in the shape the red proof patches; update the red proof rather than deleting it", "post_terminal_red_proof");
  return appSource.replace(POST_TERMINAL_VALUE_BINDING, `    "undetermined": function (scope) { return manualPostTerminalReading(scope); },`);
}

async function checkOnThisRunPostTerminalRedProof(appSource) {
  const tampered = tamperPostTerminalValue(appSource);
  try {
    await checkOnThisRunPostTerminal(tampered);
  } catch (error) {
    if (error && error.harnessKind === "post_terminal_value_reads_dimension") return {family: "on_this_run_post_terminal", detected: "post_terminal_value_reads_dimension"};
    throw error;
  }
  throw failure("post_terminal_red_proof_failed", "The post-terminal leg stayed green against a binding whose value term reads the whole dimension", "post_terminal_red_proof");
}

// ── The list-scope red proof ─────────────────────────────────────────────────
//
// The proof cuts the SILENT-OMISSION defect, which is the one this leg actually
// has to be able to see. `routeChanged` already nulls `state.detail` on the runs
// route, so a scope guard removed today would find nothing to read and the
// degradation would look correct for the wrong reason — the pane would print
// nothing, and printing nothing under a heading the reader has learned to expect
// is exactly the ambiguity this part exists to remove. The tamper therefore
// makes the binding OMIT the part at list scope instead of stating the scope,
// and the family must go red on `list_scope_silent`.
//
// The stale-detail assertion in the family above is kept regardless: it costs
// one comparison, and it is the assertion that stays meaningful if a future
// route change ever leaves a detail populated under a list paint.
const NO_RUN_STATEMENT = `    if (!run) {
      parts.append(text("dd", manualNoRunCopy(route, painted), "manual-no-run"));
      return true;
    }`;

function tamperNoRunStatement(appSource) {
  if (!appSource.includes(NO_RUN_STATEMENT)) throw failure("no_run_tamper_target_missing", "renderManualOnThisRun no longer states the no-run-in-scope case in the shape the red proof patches; update the red proof rather than deleting it", "list_scope_red_proof");
  return appSource.replace(NO_RUN_STATEMENT, `    if (!run) {
      return true;
    }`);
}

async function checkListScopeRedProof(appSource) {
  const tampered = tamperNoRunStatement(appSource);
  try {
    await checkListScopeDegradation(tampered);
  } catch (error) {
    if (error && error.harnessKind === "list_scope_silent") return {family: "on_this_run_list_scope", detected: "list_scope_silent"};
    throw error;
  }
  throw failure("list_scope_red_proof_failed", "The list-scope family stayed green against a binding that says nothing at all about run scope over the runs list", "list_scope_red_proof");
}

// ── The STREAM-TRANSITION family ─────────────────────────────────────────────
//
// Every family above enters through `hashchange`. This one enters through the
// SSE stream itself, and it is the path where NOTHING generic protects focus.
//
// The runs list paints an orientation line — `.stream-vocabulary` — that QUOTES
// the SSE health pill, and each quoted term is a native `<a href>` built by
// `labelledTerm`: a real tab stop on the very first screen. Because the pill's
// wording is state-dependent ("coalesced" is emitted on the connected state
// alone), `setStatus` refills that line whenever the observed vocabulary
// changes, and refilling calls `replaceChildren()` on the subtree holding those
// anchors.
//
// `source.onopen` and `source.onerror` call `setStatus` DIRECTLY. There is no
// view re-render on that path, so `replaceContent` never runs, `restoreView`
// never runs, and nothing whatsoever lands focus back. An operator tabbing into
// the first screen during the `connecting` window — which is where every page
// load starts, and the authoritative fetch routinely paints the runs list before
// the stream opens — has focus collapsed to `document.body` seconds later, with
// no action of their own, by `connecting -> connected`. The next Tab restarts at
// the top of the document.
//
// A same-state guard cannot reach this: a same-state render is precisely the
// case where the repaint is unnecessary, while every REAL transition is a case
// where it must happen AND focus must survive it. So the preservation lives
// inside the repaint, with the destruction, and this family drives real
// transitions to prove it.
//
// It drives BOTH directions. Focus inside the line must be kept — including the
// case where the term it holds legitimately vanishes — and focus OUTSIDE the
// line must be left alone, because a repaint that restored unconditionally would
// yank the operator out of whatever they were reading on every stream flicker.
// Each has its own red proof, so no leg is standing on another's evidence.

// The DOM stub's `textContent` is a flat per-node property, not the aggregate a
// browser computes, so a sentence assembled from sibling spans reads as "" on
// its parent. The honesty half of this family is about what the SENTENCE says,
// so it needs the aggregate.

const STREAM_TERM_HINTS = "manual-term-label:front-door:hints-only:hints only";
const STREAM_TERM_REFETCH = "manual-term-label:front-door:last-successful-authoritative-refetch:last successful authoritative refetch";
const STREAM_TERM_COALESCED = "manual-term-label:front-door:coalesced:coalesced";

// The transitions an operator actually meets, each naming the anchor focus is
// standing on when the stream moves.
//
// `openFirst` reaches the connected state before the scenario begins, which is
// the only way to put focus on "coalesced" at all — and therefore the only way
// to drive the case where the term focus is standing on LEGITIMATELY VANISHES.
// That case cannot be served by restoring the same key; it is what the in-line
// fallback exists for, and without it the family would only ever prove the easy
// half.
const STREAM_SCENARIOS = [
  {
    name: "initial_open_keeps_focus_on_hints_only",
    focusKey: STREAM_TERM_HINTS,
    transition: "open",
    expectFocus: STREAM_TERM_HINTS
  },
  {
    name: "initial_open_keeps_focus_on_last_refetch",
    focusKey: STREAM_TERM_REFETCH,
    transition: "open",
    expectFocus: STREAM_TERM_REFETCH
  },
  {
    name: "stream_down_keeps_focus_on_surviving_term",
    openFirst: true,
    focusKey: STREAM_TERM_HINTS,
    transition: "error",
    expectFocus: STREAM_TERM_HINTS
  },
  // The term focus holds is "coalesced", which the down vocabulary does not
  // carry. Landing must stay INSIDE the sentence rather than on document.body.
  {
    name: "stream_down_lands_in_line_when_the_held_term_vanishes",
    openFirst: true,
    focusKey: STREAM_TERM_COALESCED,
    transition: "error",
    expectFocus: STREAM_TERM_HINTS
  },
  // THE OTHER DIRECTION, and the failure mode a careless fix introduces: focus
  // parked on an anchor the repaint does not touch must be LEFT ALONE. The runs
  // list also paints a dimension front door whose terms are the same kind of
  // anchor, and a repaint that "restored" focus unconditionally would yank the
  // operator out of whatever they were reading every time the stream flickered —
  // a worse defect than the one being fixed, and one no assertion above can see.
  {
    name: "a_transition_does_not_steal_focus_from_another_line",
    focusKey: "manual-term-label:list-front-door:execution:Execution",
    outsideLine: true,
    transition: "open",
    expectFocus: "manual-term-label:list-front-door:execution:Execution"
  }
];

const STREAM_LIST = {status: 200, payload: {runs: [{id: RUN_ID, title: "A healthy run", strategy: "fanout"}], inventory: {total: 1, selected: 1, truncated: false, limitations: []}}};

async function runStreamScenario(appSource, scenario) {
  const {documentStub, app, status} = buildDom(null);
  const sources = [];
  const windowListeners = new Map();
  const locationStub = {hash: "#/runs"};
  const sandbox = {
    window: {
      addEventListener(type, handler) { windowListeners.set(type, handler); },
      scrollX: 0, scrollY: 0, scrollTo() {},
      // RESOLVED: connect() runs only after the bootstrap fulfills, and the SSE
      // handlers are the entire subject of this family.
      __pixirBootstrap: Promise.resolve()
    },
    document: documentStub,
    location: locationStub,
    history: {replaceState() {}, state: null},
    fetch: () => Promise.resolve(jsonResponse(STREAM_LIST.status, STREAM_LIST.payload)),
    // Retains the handlers app.js ASSIGNS (source.onopen / source.onerror) rather
    // than only the ones it addEventListener's, because the transition path under
    // test is assignment-based.
    EventSource: function () { const source = {addEventListener() {}, close() {}}; sources.push(source); return source; },
    setTimeout: (fn) => { void fn; return 0; },
    clearTimeout() {}, setInterval: () => 0, clearInterval() {},
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
  const settle = async () => { for (let turn = 0; turn < 60; turn += 1) await new Promise((resolve) => setImmediate(resolve)); };

  hashchange();
  await settle();

  if (sources.length === 0) throw failure("stream_not_opened", "app.js opened no EventSource, so no stream transition can be driven", scenario.name);
  const source = sources[0];
  if (typeof source.onopen !== "function" || typeof source.onerror !== "function") {
    throw failure("stream_handlers_missing", "The EventSource carries no onopen/onerror handlers, so the transition path this family is about no longer exists", scenario.name);
  }

  if (scenario.openFirst) { source.onopen(); await settle(); }

  const line = app.querySelector(".stream-vocabulary");
  if (!line) throw failure("orientation_line_absent", "The runs view painted no .stream-vocabulary line, so the anchors this family protects are not on screen", scenario.name, {view_class: app.children[0] ? app.children[0].className : null});

  // Scenarios that drive the repaint search the LINE; the no-steal scenario
  // deliberately stands somewhere else on the page, so it searches the view.
  const anchors = (scenario.outsideLine ? app : line).querySelectorAll("[data-focus-key]");
  const target = anchors.find((node) => node.dataset.focusKey === scenario.focusKey);
  if (!target) {
    throw failure("term_not_painted", "The view does not carry the term this scenario stands on, so the transition it drives is not the one it was written for", scenario.name, {wanted: scenario.focusKey, painted: anchors.map((node) => node.dataset.focusKey)});
  }
  if (scenario.outsideLine && subtreeContains(line.children, target)) {
    throw failure("term_inside_the_line", "The no-steal scenario anchored INSIDE the repainted line, so it is not proving what it claims", scenario.name, {wanted: scenario.focusKey});
  }
  target.focus();
  const focusBefore = activeFocusKey(documentStub);
  const quotedBefore = collectText(line).join("");

  if (scenario.transition === "open") source.onopen(); else source.onerror();
  await settle();

  const lineAfter = app.querySelector(".stream-vocabulary");
  return {
    name: scenario.name,
    focusBefore,
    focusAfter: activeFocusKey(documentStub),
    focusInsideApp: focusInsideApp(documentStub, app),
    focusInsideLine: Boolean(lineAfter) && subtreeContains(lineAfter.children, documentStub.activeElement),
    quotedBefore,
    quotedAfter: lineAfter ? collectText(lineAfter).join("") : null,
    // The pill is a SIBLING of #status, inserted by setStatus with
    // insertAdjacentElement, so its text is not on the status line itself.
    pill: [status.textContent, documentStub.getElementById("sse-health") ? documentStub.getElementById("sse-health").textContent : ""].filter(Boolean).join(" | ")
  };
}

async function checkStreamScenario(appSource, scenario) {
  const result = await runStreamScenario(appSource, scenario);
  if (result.focusBefore !== scenario.focusKey) {
    throw failure("stream_focus_not_anchored", "The scenario could not place focus on the term it drives the transition against", scenario.name, {wanted: scenario.focusKey, got: result.focusBefore});
  }
  // ATTACHMENT first, for the same reason the close leg checks it: a key read off
  // a node the repaint detached is indistinguishable from a key on a live one.
  if (!result.focusInsideApp) {
    throw failure("stream_focus_lost", "A stream transition repainted the orientation line and left focus outside the document's painted view (on document.body): the operator's next Tab restarts at the top of the document", scenario.name, {focus_before: result.focusBefore, focus_after: result.focusAfter});
  }
  // Only for scenarios standing INSIDE the repainted sentence. The no-steal
  // scenario stands elsewhere on purpose, and requiring it to end up in the line
  // would assert the very theft it exists to forbid.
  if (!scenario.outsideLine && !result.focusInsideLine) {
    throw failure("stream_focus_left_the_line", "A stream transition moved focus out of the sentence the operator was reading", scenario.name, {focus_before: result.focusBefore, focus_after: result.focusAfter});
  }
  if (scenario.outsideLine && result.focusInsideLine) {
    throw failure("stream_focus_stolen", "A stream transition YANKED focus into the orientation line from a control the repaint does not touch: the operator is pulled out of whatever they were reading every time the stream flickers", scenario.name, {focus_before: result.focusBefore, focus_after: result.focusAfter});
  }
  if (result.focusAfter !== scenario.expectFocus) {
    throw failure("stream_focus_moved", "A stream transition landed focus somewhere other than the term this scenario requires", scenario.name, {focus_before: result.focusBefore, focus_after: result.focusAfter, expected: scenario.expectFocus});
  }
  return {name: scenario.name, focus_before: result.focusBefore, focus_after: result.focusAfter, quoted_before: result.quotedBefore, quoted_after: result.quotedAfter, pill: result.pill};
}

// The HONESTY half of the same family, and the reason the repaint exists at all:
// after a transition the sentence must quote the pill it is standing under. A
// focus fix that froze the line would pass every assertion above while
// reintroducing the absent-text claim this arc was opened to remove.
async function checkStreamQuoteHonesty(appSource) {
  const connected = await runStreamScenario(appSource, {name: "quote_follows_the_pill", focusKey: STREAM_TERM_HINTS, transition: "open", expectFocus: STREAM_TERM_HINTS});
  if (connected.quotedBefore.includes("coalesced")) {
    throw failure("stale_quote_before", "The connecting-state orientation line already quoted a term the connecting pill does not emit", "stream_quote_honesty", {quoted: connected.quotedBefore});
  }
  if (!connected.quotedAfter.includes("coalesced")) {
    throw failure("quote_did_not_follow_pill", "The stream reached the connected state, whose pill emits \"coalesced\", and the orientation line did not repaint to quote it: the sentence names pill text that is not what the pill says", "stream_quote_honesty", {pill: connected.pill, quoted: connected.quotedAfter});
  }
  const down = await runStreamScenario(appSource, {name: "quote_drops_absent_term", openFirst: true, focusKey: STREAM_TERM_HINTS, transition: "error", expectFocus: STREAM_TERM_HINTS});
  if (!down.quotedBefore.includes("coalesced")) {
    throw failure("stale_quote_before", "The connected-state orientation line did not quote \"coalesced\", so the drop this check is about cannot be observed", "stream_quote_honesty", {quoted: down.quotedBefore});
  }
  if (down.quotedAfter.includes("coalesced")) {
    throw failure("quote_asserts_absent_text", "The stream went down, whose pill does not emit \"coalesced\", and the orientation line still quotes it: the Monitor is asserting text that is not on screen", "stream_quote_honesty", {pill: down.pill, quoted: down.quotedAfter});
  }
  return {family: "stream_vocabulary_quote", connected_quotes_coalesced: true, down_drops_coalesced: true};
}

// The stream family's own red proof. Every proof above tampers with the manual
// fast path or the paint record; none can speak for a repaint driven by the
// stream. This one cuts exactly the fix — the focus capture and restore inside
// repaintStreamVocabularyLine — and requires a real transition to go red.
//
// It deliberately does NOT touch the same-state guard in setStatus, because the
// guard is not the protection: with the guard intact and the in-repaint
// restoration gone, a real transition still collapses focus to document.body.
// That is the whole claim of this family, and the proof is what makes it a claim
// rather than an assertion.
const STREAM_FOCUS_CAPTURE = `    const active = document.activeElement;
    const held = active && active.dataset && Array.from(line.querySelectorAll("[data-focus-key]")).indexOf(active) !== -1
      ? active.dataset.focusKey
      : null;`;

const STREAM_FOCUS_RESTORE = `    if (held !== null) {
      const anchors = Array.from(line.querySelectorAll("[data-focus-key]"));
      const same = anchors.find(function (candidate) { return candidate.dataset.focusKey === held; });
      const landing = same || anchors[0];
      if (landing) landing.focus({preventScroll: true});
    }`;

function tamperStreamFocus(appSource) {
  if (!appSource.includes(STREAM_FOCUS_CAPTURE) || !appSource.includes(STREAM_FOCUS_RESTORE)) {
    throw failure("stream_tamper_target_missing", "The orientation line's focus capture/restore no longer matches the shape the stream red proof patches; update the red proof rather than deleting it", "stream_red_proof");
  }
  return appSource.replace(STREAM_FOCUS_CAPTURE, "").replace(STREAM_FOCUS_RESTORE, "");
}

async function checkStreamRedProof(appSource) {
  const tampered = tamperStreamFocus(appSource);
  try {
    await checkStreamScenario(tampered, STREAM_SCENARIOS[0]);
  } catch (error) {
    if (error && error.harnessKind === "stream_focus_lost") return {family: "stream_vocabulary_focus", detected: "stream_focus_lost"};
    throw error;
  }
  throw failure("stream_red_proof_failed", "The stream family stayed green against a repaint that restores no focus: connecting -> connected would collapse focus to document.body seconds after page load with no operator action at all", "stream_red_proof");
}

// And a SECOND proof for the vanishing-term leg, because the proof above always
// drives a term that survives the transition — where restoring the same key is
// enough and the fallback is never reached. Cutting only the fallback (leaving
// the same-key restore intact) must still turn the "coalesced" scenario red, or
// the fallback is untested code shipping on the operator's behalf.
function tamperStreamFallback(appSource) {
  const target = "      const landing = same || anchors[0];";
  if (!appSource.includes(target)) throw failure("stream_fallback_tamper_target_missing", "The in-line focus fallback no longer matches the shape the vanishing-term red proof patches; update the red proof rather than deleting it", "stream_fallback_red_proof");
  return appSource.replace(target, "      const landing = same;");
}

async function checkStreamFallbackRedProof(appSource) {
  const tampered = tamperStreamFallback(appSource);
  const vanishing = STREAM_SCENARIOS.find((scenario) => scenario.name === "stream_down_lands_in_line_when_the_held_term_vanishes");
  if (!vanishing) throw failure("stream_fallback_scenario_missing", "The vanishing-term scenario the red proof drives is gone; the in-line fallback would be unproven", "stream_fallback_red_proof");
  try {
    await checkStreamScenario(tampered, vanishing);
  } catch (error) {
    if (error && error.harnessKind === "stream_focus_lost") return {family: "stream_vocabulary_focus_fallback", detected: "stream_focus_lost"};
    throw error;
  }
  throw failure("stream_fallback_red_proof_failed", "The vanishing-term leg stayed green against a repaint with no in-line fallback: focus standing on a term the new vocabulary drops would land on document.body", "stream_fallback_red_proof");
}

// The NO-STEAL leg's own red proof. The two proofs above both cut protection
// away and watch focus be LOST; this one widens the capture past the line and
// watches focus be TAKEN. Dropping the containment test is the natural careless
// simplification — "just remember whatever was focused" — and it turns every
// stream flicker into a yank out of whatever the operator was reading.
function tamperStreamScope(appSource) {
  const target = `Array.from(line.querySelectorAll("[data-focus-key]")).indexOf(active) !== -1`;
  if (!appSource.includes(target)) throw failure("stream_scope_tamper_target_missing", "The repaint's line-scoped focus capture no longer matches the shape the no-steal red proof patches; update the red proof rather than deleting it", "stream_scope_red_proof");
  return appSource.replace(target, "active.dataset.focusKey !== undefined");
}

async function checkStreamScopeRedProof(appSource) {
  const tampered = tamperStreamScope(appSource);
  const noSteal = STREAM_SCENARIOS.find((scenario) => scenario.name === "a_transition_does_not_steal_focus_from_another_line");
  if (!noSteal) throw failure("stream_scope_scenario_missing", "The no-steal scenario the red proof drives is gone; a repaint that yanks focus across the page would be unproven", "stream_scope_red_proof");
  try {
    await checkStreamScenario(tampered, noSteal);
  } catch (error) {
    if (error && error.harnessKind === "stream_focus_stolen") return {family: "stream_vocabulary_focus_scope", detected: "stream_focus_stolen"};
    throw error;
  }
  throw failure("stream_scope_red_proof_failed", "The no-steal leg stayed green against a repaint that captures focus from anywhere in the document: every stream transition would pull the operator into the orientation line", "stream_scope_red_proof");
}

async function main() {
  const options = parseArgs(process.argv.slice(2));
  const appSource = readFileSync(options.app, "utf8");
  const redProof = await checkRedProof(appSource);
  const focusRedProof = await checkFocusRedProof(appSource);
  const nullStashRedProof = await checkNullStashRedProof(appSource);
  const healthyRedProof = await checkHealthyRedProof(appSource);
  const restoreRedProof = await checkRestoreRedProof(appSource);
  const staleReplayRedProof = await checkStaleReplayRedProof(appSource);
  const unlinkableRunIdRedProof = await checkUnlinkableRunIdRedProof(appSource);
  const onThisRunRedProof = await checkOnThisRunRedProof(appSource);
  const residualRedProof = await checkOnThisRunResidualRedProof(appSource);
  const postTerminalRedProof = await checkOnThisRunPostTerminalRedProof(appSource);
  const listScopeRedProof = await checkListScopeRedProof(appSource);
  const unitScopeRedProof = await checkOnThisRunUnitScopeRedProof(appSource);
  const unitAbsentRedProof = await checkOnThisRunUnitAbsentRedProof(appSource);
  const unitGateWordRedProof = await checkUnitGateWordRedProof(appSource);
  const unitAbsentAttentionRedProof = await checkUnitAbsentAttentionRedProof(appSource);
  const runAbsentAttentionRedProof = await checkRunAbsentAttentionRedProof(appSource);
  const streamRedProof = await checkStreamRedProof(appSource);
  const streamFallbackRedProof = await checkStreamFallbackRedProof(appSource);
  const streamScopeRedProof = await checkStreamScopeRedProof(appSource);
  const scenarios = [];
  for (const scenario of SCENARIOS) scenarios.push(await checkScenario(appSource, scenario));
  const staleReplay = await checkStaleReplay(appSource);
  const unlinkableRunId = await checkUnlinkableRunId(appSource);
  const onThisRunDetail = await checkOnThisRunDetail(appSource);
  const onThisRunUnbound = await checkOnThisRunUnbound(appSource);
  const onThisRunResidual = await checkOnThisRunResidual(appSource);
  const onThisRunPostTerminal = await checkOnThisRunPostTerminal(appSource);
  const onThisRunListScope = await checkListScopeDegradation(appSource);
  const onThisRunUnitScope = await checkOnThisRunUnitScope(appSource);
  const onThisRunUnitAbsent = await checkOnThisRunUnitAbsent(appSource);
  const streamScenarios = [];
  for (const scenario of STREAM_SCENARIOS) streamScenarios.push(await checkStreamScenario(appSource, scenario));
  const streamQuoteHonesty = await checkStreamQuoteHonesty(appSource);
  return {ok: true, check: "pixir_monitor_manual_overlay_preservation", executed_in: "node_vm_minimal_dom", red_proof: redProof, focus_red_proof: focusRedProof, null_stash_red_proof: nullStashRedProof, healthy_red_proof: healthyRedProof, restore_red_proof: restoreRedProof, stale_replay_red_proof: staleReplayRedProof, unlinkable_run_id_red_proof: unlinkableRunIdRedProof, stream_red_proof: streamRedProof, stream_fallback_red_proof: streamFallbackRedProof, stream_scope_red_proof: streamScopeRedProof, on_this_run_red_proof: onThisRunRedProof, residual_red_proof: residualRedProof, post_terminal_red_proof: postTerminalRedProof, list_scope_red_proof: listScopeRedProof, unit_scope_red_proof: unitScopeRedProof, unit_absent_red_proof: unitAbsentRedProof, unit_gate_word_red_proof: unitGateWordRedProof, unit_absent_attention_red_proof: unitAbsentAttentionRedProof, run_absent_attention_red_proof: runAbsentAttentionRedProof, stale_replay: staleReplay, unlinkable_run_id: unlinkableRunId, stream_scenarios: streamScenarios, stream_quote_honesty: streamQuoteHonesty, on_this_run_detail: onThisRunDetail, on_this_run_unbound: onThisRunUnbound, on_this_run_residual: onThisRunResidual, on_this_run_post_terminal: onThisRunPostTerminal, on_this_run_list_scope: onThisRunListScope, on_this_run_unit_scope: onThisRunUnitScope, on_this_run_unit_absent: onThisRunUnitAbsent, scenarios};
}

main().then(
  (result) => { process.stdout.write(`${JSON.stringify(result)}\n`); process.exit(0); },
  (error) => { process.stdout.write(`${JSON.stringify(safeError(error))}\n`); process.exit(1); }
);
