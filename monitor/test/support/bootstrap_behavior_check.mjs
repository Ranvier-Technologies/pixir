#!/usr/bin/env node

// Executes the REAL inline bootstrap source (extracted from the served shell)
// in node:vm and drives the failure classification behaviorally: absent
// capability, rejected capability, non-launch server rejections, network
// failure, and a Trusted Types throw. Asserts the rendered status copy per
// category, the base-URL history replacement, and that the launch token never
// reaches the rendered text. No Chrome, no npm — the same evidence tier as
// the presenter UI seam check.

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
  return {ok: false, error: {kind: error?.harnessKind || "bootstrap_behavior_check_failed", message: error?.harnessKind ? error.message : `The bootstrap behavior check failed unexpectedly: ${error?.message}`, details: {stage: error?.harnessStage || "unknown", ...(error?.safeDetails || {})}}};
}

function parseArgs(argv) {
  const options = {};
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === "--json") continue;
    if (["--source"].includes(arg)) options[arg.slice(2)] = argv[++index];
    else throw failure("invalid_args", "Unknown bootstrap behavior check argument", "parse_args");
  }
  if (!options.source) throw failure("missing_required_arg", "Missing required --source", "validate_args");
  return options;
}

const TOKEN = "tok-behavior-check-secret";

const ABSENT_COPY = "Open the Monitor through the one-use link printed by pixir-monitor serve. This page was opened without one.";
const REJECTED_COPY = "Launch link invalid, expired, or already used. Launch tokens are one-use and expire in 30 seconds. Run pixir-monitor serve again to mint a fresh one.";
const GENERIC_COPY = "Monitor failed to start before loading. Reload the page, or run pixir-monitor serve again for a fresh session.";
const ASSET_COPY = "Monitor interface failed to load. Reload the page, or run pixir-monitor serve again for a fresh session.";

function buildSandbox(scenario) {
  const statusNode = {textContent: "Starting read-only monitor…"};
  const replaceStateCalls = [];
  const bodies = [];

  const sandbox = {
    URLSearchParams,
    location: {hash: scenario.hash},
    history: {replaceState: (...args) => replaceStateCalls.push(args)},
    document: {
      title: "boot",
      getElementById: (id) => (id === "status" ? statusNode : null),
      createElement: () => ({}),
      head: {
        append: (element) => {
          // Simulate a failing app.js asset: the browser fires onerror after
          // the element joins the document. The MECHANISM is asserted, not
          // just the outcome: a source that renders the asset copy without
          // wiring onerror must fail here, never pass vacuously.
          if (scenario.assetFailure && element && element.src) {
            if (typeof element.onerror !== "function") {
              throw failure("onerror_not_wired", "The app.js script element carries no onerror terminal handler", scenario.name);
            }
            setImmediate(() => element.onerror());
          }
        }
      }
    },
    fetch: (_url, init) => {
      bodies.push(init && init.body);
      if (scenario.network === "reject") return Promise.reject(new TypeError("network down"));
      // Real Response.ok is 200-299 only, never "anything below 400".
      return Promise.resolve({ok: scenario.status >= 200 && scenario.status < 300, status: scenario.status});
    }
  };
  sandbox.window = scenario.trustedTypesThrow
    ? {trustedTypes: {createPolicy: () => { throw new TypeError("policy refused"); }}}
    : {};
  return {sandbox, statusNode, replaceStateCalls, bodies};
}

async function runScenario(source, scenario) {
  const {sandbox, statusNode, replaceStateCalls, bodies} = buildSandbox(scenario);
  vm.createContext(sandbox);
  vm.runInContext(source, sandbox, {filename: "bootstrap-inline.js"});
  if (!sandbox.window.__pixirBootstrap || typeof sandbox.window.__pixirBootstrap.then !== "function") {
    throw failure("bootstrap_promise_missing", "The bootstrap source did not expose window.__pixirBootstrap", scenario.name);
  }
  let rejected = false;
  await sandbox.window.__pixirBootstrap.then(() => {}, () => { rejected = true; });
  // The source's own catch handler is a sibling consumer; give it a turn
  // (two, so the asset-failure onerror scheduled by append also lands).
  await new Promise((resolve) => setImmediate(resolve));
  await new Promise((resolve) => setImmediate(resolve));

  const text = statusNode.textContent;
  if (text !== scenario.expected) {
    throw failure("copy_mismatch", "The rendered status copy does not match the expected category", scenario.name, {expected: scenario.expected, observed: text});
  }
  if (rejected === Boolean(scenario.fulfills)) {
    throw failure("bootstrap_settlement_mismatch", "window.__pixirBootstrap must stay rejected on bootstrap failure (and fulfilled on asset failure) so app.js semantics are unchanged", scenario.name, {rejected});
  }
  if (text.includes(TOKEN)) {
    throw failure("token_echoed", "The launch token leaked into the rendered status copy", scenario.name);
  }
  if (replaceStateCalls.length !== 1 || replaceStateCalls[0][2] !== "/") {
    throw failure("base_url_not_restored", "history.replaceState must rewrite the URL to the base path exactly once before any subresource work", scenario.name, {calls: replaceStateCalls});
  }
  if (sandbox.document.title !== "Pixir Monitor") {
    throw failure("title_not_set", "The document title must be set before bootstrap resolves", scenario.name);
  }
  if (scenario.hash === "" && bodies[0] !== JSON.stringify({launch: null})) {
    throw failure("absent_body_mismatch", "An absent fragment must still post launch:null so the exchange stays single-path", scenario.name, {observed: bodies[0]});
  }
  const copy =
    text === REJECTED_COPY ? "rejected" : text === ABSENT_COPY ? "absent" : text === ASSET_COPY ? "asset" : "generic";

  return {name: scenario.name, copy};
}

const SCENARIOS = [
  {name: "absent_fragment_401", hash: "", status: 401, expected: ABSENT_COPY},
  {name: "rejected_capability_401", hash: `#launch=${TOKEN}`, status: 401, expected: REJECTED_COPY},
  // "#launch=" carries an empty token, not an absent one: the server folds it
  // into the same invalid_launch 401 and the copy says invalid/expired/used.
  {name: "empty_fragment_401", hash: "#launch=", status: 401, expected: REJECTED_COPY},
  {name: "forbidden_403", hash: `#launch=${TOKEN}`, status: 403, expected: GENERIC_COPY},
  {name: "body_too_large_413", hash: `#launch=${TOKEN}`, status: 413, expected: GENERIC_COPY},
  {name: "server_error_500", hash: `#launch=${TOKEN}`, status: 500, expected: GENERIC_COPY},
  {name: "network_failure", hash: `#launch=${TOKEN}`, status: 200, network: "reject", expected: GENERIC_COPY},
  {name: "trusted_types_throw", hash: `#launch=${TOKEN}`, status: 200, trustedTypesThrow: true, expected: GENERIC_COPY},
  // A 200 bootstrap whose app.js asset fails must reach terminal copy too;
  // the promise is legitimately FULFILLED here (the exchange succeeded).
  {name: "asset_load_failure", hash: `#launch=${TOKEN}`, status: 200, assetFailure: true, fulfills: true, expected: ASSET_COPY}
];

async function main() {
  const options = parseArgs(process.argv.slice(2));
  const source = readFileSync(options.source, "utf8");
  const results = [];
  for (const scenario of SCENARIOS) results.push(await runScenario(source, scenario));
  return {ok: true, check: "pixir_monitor_bootstrap_behavior", executed_in: "node_vm", scenarios: results.map((entry) => entry.name), copies: results.map((entry) => entry.copy)};
}

main().then(
  (result) => { console.log(JSON.stringify(result)); process.exit(0); },
  (error) => { console.log(JSON.stringify(safeError(error))); process.exit(1); }
);
