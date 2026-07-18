#!/usr/bin/env node

import {spawn} from "node:child_process";
import {existsSync} from "node:fs";
import {mkdtemp, readFile, rm} from "node:fs/promises";
import {dirname, join} from "node:path";
import {createInterface} from "node:readline";
import process from "node:process";
import {extraBrowserArgs} from "./chrome_args.mjs";

const MODES = new Set(["removal", "permission_denial", "corrupt_log", "empty_restoration", "runs_unheld"]);

function failure(kind, message, stage, details = {}) {
  const error = new Error(message);
  error.harnessKind = kind;
  error.harnessStage = stage;
  error.safeDetails = details;
  return error;
}

function safeError(error) {
  const profilePath = error?.safeDetails?.profile_path;
  return {ok: false, ...(profilePath ? {profile_path: profilePath} : {}), error: {kind: error?.harnessKind || "workspace_set_browser_harness_failed", message: error?.harnessKind ? error.message : "The workspace-set browser harness failed unexpectedly", details: {stage: error?.harnessStage || "unknown", ...(error?.safeDetails || {})}}};
}

function parseArgs(argv) {
  const options = {browser_timeout_ms: 12_000, flap_count: 3, dryRun: false};
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === "--dry-run") options.dryRun = true;
    else if (arg === "--exercise-cdp-crash") options.exerciseCdpCrash = true;
    else if (arg === "--exercise-phase-timeout") options.exercisePhaseTimeout = true;
    else if (arg === "--json") continue;
    else if (["--monitor", "--left-workspace", "--right-workspace", "--left-run-id", "--right-run-id", "--left-unit-id", "--right-unit-id", "--browser", "--profile-base", "--mode", "--browser-timeout-ms", "--flap-count"].includes(arg)) options[arg.slice(2).replaceAll("-", "_")] = argv[++index];
    else throw failure("invalid_args", "Unknown or incomplete workspace-set browser harness argument", "parse_args");
  }
  return options;
}

function validate(options) {
  for (const field of ["monitor", "left_workspace", "right_workspace", "left_run_id", "right_run_id", "left_unit_id", "right_unit_id", "browser", "profile_base", "mode"]) {
    if (!options[field]) throw failure("missing_required_arg", `Missing required --${field.replaceAll("_", "-")}`, "validate_args");
  }
  for (const field of ["monitor", "left_workspace", "right_workspace", "browser", "profile_base"]) {
    if (!existsSync(options[field])) throw failure(`${field}_missing`, `Required ${field.replaceAll("_", " ")} is missing`, "validate_inputs");
  }
  if (!MODES.has(options.mode)) throw failure("invalid_mode", "Unsupported degradation mode", "validate_args");
  if (typeof WebSocket !== "function") throw failure("node_websocket_unavailable", "Node.js does not provide WebSocket", "validate_runtime");
  options.browser_timeout_ms = Number(options.browser_timeout_ms);
  options.flap_count = Number(options.flap_count);
  if (!Number.isSafeInteger(options.browser_timeout_ms) || options.browser_timeout_ms < 250 || options.browser_timeout_ms > 30_000) throw failure("invalid_browser_timeout", "--browser-timeout-ms must be 250..30000", "validate_args");
  if (!Number.isSafeInteger(options.flap_count) || options.flap_count < 1 || options.flap_count > 10) throw failure("invalid_flap_count", "--flap-count must be 1..10", "validate_args");
}

function withTimeout(promise, timeoutMs, kind, message, stage) {
  return new Promise((resolve, reject) => {
    const timeout = setTimeout(() => reject(failure(kind, message, stage)), timeoutMs);
    Promise.resolve(promise).then(value => { clearTimeout(timeout); resolve(value); }, error => { clearTimeout(timeout); reject(error); });
  });
}

function waitForJsonLine(stream, predicate, stage, timeoutMs = 20_000) {
  return new Promise((resolve, reject) => {
    const lines = createInterface({input: stream});
    let settled = false;
    const finish = (callback, value) => { if (settled) return; settled = true; clearTimeout(timer); lines.close(); callback(value); };
    const timer = setTimeout(() => finish(reject, failure("process_readiness_timeout", "Child readiness was not observed", stage)), timeoutMs);
    lines.on("line", line => { try { const value = JSON.parse(line); if (predicate(value)) finish(resolve, value); } catch (_error) {} });
    lines.on("close", () => finish(reject, failure("process_readiness_stream_closed", "Child readiness stream closed", stage)));
  });
}

function waitForDevTools(stream, timeoutMs = 15_000) {
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
  const eventListeners = new Set();
  const rejectPending = () => { for (const [id, waiter] of pending) { pending.delete(id); waiter.reject(failure("devtools_connection_closed", "Chrome DevTools closed", waiter.stage)); } };
  socket.addEventListener("message", event => { const message = JSON.parse(event.data); const waiter = pending.get(message.id); if (!waiter) { for (const listener of eventListeners) listener(message); return; } pending.delete(message.id); message.error ? waiter.reject(failure("devtools_command_failed", "Chrome DevTools command failed", waiter.stage, {code: message.error.code})) : waiter.resolve(message.result); });
  socket.addEventListener("close", rejectPending);
  socket.addEventListener("error", rejectPending);
  return {
    send(method, params = {}, sessionId = null, stage = "browser_command") {
      if (socket.readyState !== WebSocket.OPEN) return Promise.reject(failure("devtools_connection_closed", "Chrome DevTools is not open", stage));
      const id = nextId++;
      return withTimeout(new Promise((resolve, reject) => { pending.set(id, {resolve, reject, stage}); socket.send(JSON.stringify({id, method, params, ...(sessionId ? {sessionId} : {})})); }), 10_000, "devtools_command_timeout", "Chrome DevTools command timed out", stage).finally(() => pending.delete(id));
    },
    onEvent(listener) { eventListeners.add(listener); return () => eventListeners.delete(listener); },
    close() { socket.close(); }
  };
}

async function evaluate(client, sessionId, expression, stage) {
  const result = await client.send("Runtime.evaluate", {expression, returnByValue: true, awaitPromise: true}, sessionId, stage);
  if (result.exceptionDetails) throw failure("browser_expression_failed", "Browser assertion expression failed", stage);
  return result.result?.value;
}

async function waitForBrowser(client, sessionId, expression, stage, timeoutMs) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (await evaluate(client, sessionId, expression, stage)) return;
    await new Promise(resolve => setTimeout(resolve, 50));
  }
  const diagnostics = await evaluate(client, sessionId, `({hash: location.hash, text: document.body.textContent.slice(0, 1000), sections: document.querySelectorAll('.workspace-source').length})`, `${stage}_diagnostics`);
  throw failure("browser_assertion_timeout", "Browser did not converge", stage, {diagnostics});
}

async function stopChild(child) {
  const stopped = () => !child || child.exitCode !== null || child.signalCode !== null;
  if (stopped()) return true;
  child.kill("SIGTERM");
  await Promise.race([new Promise(resolve => child.once("exit", resolve)), new Promise(resolve => setTimeout(resolve, 1_000))]);
  if (!stopped()) { child.kill("SIGKILL"); await Promise.race([new Promise(resolve => child.once("exit", resolve)), new Promise(resolve => setTimeout(resolve, 1_000))]); }
  return stopped();
}

class DriverProtocol {
  constructor() {
    this.waiters = [];
    this.messages = [];
    this.nextCheckpoint = 1;
    this.lines = createInterface({input: process.stdin});
    this.lines.on("line", line => {
      let message;
      try { message = JSON.parse(line); } catch (_error) { return this.rejectFirst(failure("driver_protocol_invalid", "Driver sent invalid JSON", "driver_protocol")); }
      const waiter = this.waiters.shift();
      if (waiter) waiter.resolve(message); else this.messages.push(message);
    });
    this.lines.on("close", () => this.rejectFirst(failure("driver_protocol_closed", "Driver protocol closed before acknowledgement", "driver_protocol")));
  }
  rejectFirst(error) { const waiter = this.waiters.shift(); if (waiter) waiter.reject(error); }
  async checkpoint(command, details, timeoutMs) {
    const checkpoint = this.nextCheckpoint++;
    process.stderr.write(`${JSON.stringify({harness: "workspace_set", checkpoint, command, ...details})}\n`);
    const message = this.messages.length ? this.messages.shift() : await withTimeout(new Promise((resolve, reject) => this.waiters.push({resolve, reject})), timeoutMs, "driver_protocol_timeout", "Driver did not acknowledge filesystem phase", command);
    if (message?.phase !== command || message?.checkpoint !== checkpoint) throw failure("driver_protocol_mismatch", "Driver acknowledged the wrong checkpoint", command, {expected_checkpoint: checkpoint, received_checkpoint: message?.checkpoint || null, received: message?.phase || null});
    if (details.mode && message?.served_workspace !== details.servedWorkspace) throw failure("driver_path_identity_mismatch", "Driver did not mutate the exact served workspace path", command);
    if (message?.post_state !== "verified") throw failure("driver_post_state_unverified", "Driver did not verify the post-mutation filesystem state", command);
    return message;
  }
  close() { this.lines.close(); }
}

const PRELOAD_SCRIPT = `(() => {
  const control = {retryToken: null};
  window.__pixirSetHarness = control;
  const nativeFetch = window.fetch.bind(window);
  window.fetch = function(input, init) {
    if (!control.retryToken) return nativeFetch(input, init);
    const token = control.retryToken;
    control.retryToken = null;
    const options = {...(init || {})};
    const headers = new Headers(options.headers || {});
    headers.set("x-pixir-harness-retry", token);
    options.headers = headers;
    return nativeFetch(input, options);
  };
})();`;

function workspaceHash(workspace, runId = null, unitId = null) {
  let hash = `#/workspaces/${encodeURIComponent(workspace)}/runs`;
  if (runId) hash += `/${encodeURIComponent(runId)}`;
  if (unitId) hash += `/units/${encodeURIComponent(unitId)}`;
  return hash;
}

async function navigateAndAssert(client, sessionId, hash, expression, stage, timeoutMs) {
  await evaluate(client, sessionId, `location.hash = ${JSON.stringify(hash)}; true`, `${stage}_navigate`);
  await waitForBrowser(client, sessionId, `location.hash === ${JSON.stringify(hash)} && (${expression})`, stage, timeoutMs);
}

async function healthyTraversal(client, sessionId, options) {
  await waitForBrowser(client, sessionId, `location.hash === "#/workspaces" && document.querySelectorAll('.workspace-source').length === 2 && document.querySelectorAll('.workspace-source[data-workspace="left"]').length === 1 && document.querySelectorAll('.workspace-source[data-workspace="right"]').length === 1`, "healthy_overview", options.browser_timeout_ms);
  for (const workspace of ["left", "right"]) {
    const runId = options[`${workspace}_run_id`];
    const unitId = options[`${workspace}_unit_id`];
    await navigateAndAssert(client, sessionId, workspaceHash(workspace), `document.querySelector('.runs-view') && !document.querySelector('.error-view')`, `healthy_${workspace}_list`, options.browser_timeout_ms);
    await navigateAndAssert(client, sessionId, workspaceHash(workspace, runId), `document.querySelector('.detail-view') && !document.querySelector('.error-view')`, `healthy_${workspace}_detail`, options.browser_timeout_ms);
    await navigateAndAssert(client, sessionId, workspaceHash(workspace, runId, unitId), `document.querySelector('.unit-view') && document.querySelectorAll('.attempt-card').length === 1 && !document.querySelector('.error-view')`, `healthy_${workspace}_unit`, options.browser_timeout_ms);
  }
  await navigateAndAssert(client, sessionId, "#/workspaces", `document.querySelectorAll('.workspace-source').length === 2`, "healthy_return_overview", options.browser_timeout_ms);
}

async function clickRetryAndCount(client, sessionId, network, options, stage) {
  const before = network.records.length;
  const token = `retry-${network.nextRetry++}`;
  const selector = `[data-focus-key="source-retry:left"]`;
  await evaluate(client, sessionId, `(() => { const node = document.querySelector(${JSON.stringify(selector)}); if (!node || node.textContent !== "Retry this source") throw new Error("source retry unavailable"); window.__pixirSetHarness.retryToken = ${JSON.stringify(token)}; node.focus(); node.click(); return true; })()`, `${stage}_click`);
  const exactLeftList = /^\/api\/workspaces\/left\/runs$/;
  const deadline = Date.now() + options.browser_timeout_ms;
  while (Date.now() < deadline) {
    const windowRecords = network.records.slice(before);
    const attributed = windowRecords.filter(record => record.retryToken === token);
    if (attributed.length === 1 && exactLeftList.test(attributed[0].path)) break;
    if (attributed.length > 1) throw failure("retry_scope_failed", "Retry emitted more than one attributed request", stage, {token, attributed});
    await new Promise(resolve => setTimeout(resolve, 25));
  }
  await new Promise(resolve => setTimeout(resolve, 250));
  const windowRecords = network.records.slice(before);
  const rightRequests = windowRecords.filter(record => record.workspace === "right");
  const attributed = windowRecords.filter(record => record.retryToken === token);
  if (attributed.length !== 1 || attributed[0].path !== "/api/workspaces/left/runs" || rightRequests.length !== 0) {
    throw failure("retry_scope_failed", "Retry was not exactly one click-attributed left list request with zero right requests", stage, {token, window_records: windowRecords});
  }
  await waitForBrowser(client, sessionId, `document.querySelectorAll('.workspace-source').length === 2`, `${stage}_render`, options.browser_timeout_ms);
}

async function permissionStory(client, sessionId, protocol, network, options, phases) {
  const leftUnitHash = workspaceHash("left", options.left_run_id, options.left_unit_id);
  await navigateAndAssert(client, sessionId, leftUnitHash, `document.querySelector('.unit-view')`, "permission_preserve_route", options.browser_timeout_ms);
  await protocol.checkpoint("degrade", {mode: options.mode, servedWorkspace: options.left_workspace}, options.browser_timeout_ms);
  await waitForBrowser(client, sessionId, `location.hash === ${JSON.stringify(leftUnitHash)} && document.querySelector('.stale-disclosure') && document.body.textContent.includes("Stale source snapshot · received ") && document.body.textContent.includes("refresh failure workspace_unavailable")`, "permission_stale_unit", options.browser_timeout_ms);
  phases.push("degrade_stale_unit_navigation_preserved");
  await navigateAndAssert(client, sessionId, workspaceHash("left"), `document.querySelector('.runs-view') && document.querySelector('.stale-disclosure')`, "permission_stale_list", options.browser_timeout_ms);
  const frozenReceipt = await evaluate(client, sessionId, `(() => { const value = document.querySelector('.stale-disclosure strong')?.textContent || ""; const match = value.match(/^Stale source snapshot · received (.+) · refresh failure workspace_unavailable$/); if (!match) throw new Error("stale list receipt unavailable"); return match[1]; })()`, "permission_capture_frozen_list_receipt");
  await navigateAndAssert(client, sessionId, workspaceHash("right"), `document.querySelector('.runs-view')`, "permission_healthy_list", options.browser_timeout_ms);
  await navigateAndAssert(client, sessionId, workspaceHash("right", options.right_run_id), `document.querySelector('.detail-view')`, "permission_healthy_detail", options.browser_timeout_ms);
  await navigateAndAssert(client, sessionId, workspaceHash("right", options.right_run_id, options.right_unit_id), `document.querySelector('.unit-view')`, "permission_healthy_unit", options.browser_timeout_ms);
  const exactSourceError = "Source unreachable · workspace_unavailable";
  const exactProvenance = `Authoritative scoped snapshot · last-observed ${frozenReceipt}`;
  const exactStaleDisclosure = `Stale snapshot held · received ${frozenReceipt} · refresh failure workspace_unavailable`;
  await navigateAndAssert(client, sessionId, "#/workspaces", `document.querySelectorAll('.workspace-source').length === 2 && document.querySelector('.workspace-source[data-workspace="left"] .source-error')?.textContent === ${JSON.stringify(exactSourceError)} && document.querySelector('.workspace-source[data-workspace="left"] .provenance')?.textContent === ${JSON.stringify(exactProvenance)} && document.querySelector('.workspace-source[data-workspace="left"] .stale-disclosure')?.textContent === ${JSON.stringify(exactStaleDisclosure)}`, "permission_overview", options.browser_timeout_ms);
  phases.push("healthy_source_fully_navigable", "exact_limitation_and_no_duplicate_sections");
  await clickRetryAndCount(client, sessionId, network, options, "permission_retry_degraded");
  phases.push("per_source_retry_network_scoped");
  await protocol.checkpoint("restore", {mode: options.mode, servedWorkspace: options.left_workspace}, options.browser_timeout_ms);
  await evaluate(client, sessionId, `(() => { const summary = document.querySelector('[data-focus-key="remaining-runs:left"]'); if (!summary) throw new Error("remaining runs disclosure unavailable"); if (!summary.parentElement?.open) summary.click(); return summary.parentElement?.open === true; })()`, "permission_open_remaining_runs_before_recovery");
  await waitForBrowser(client, sessionId, `document.querySelector('[data-focus-key="remaining-runs:left"]')?.parentElement?.open === true`, "permission_remaining_runs_open_before_recovery", options.browser_timeout_ms);
  await clickRetryAndCount(client, sessionId, network, options, "permission_retry_recovery");
  await waitForBrowser(client, sessionId, `!document.querySelector('.workspace-source[data-workspace="left"] .source-error') && document.querySelector('.workspace-source[data-workspace="left"] .provenance').textContent.includes("observed-at ")`, "permission_recovered", options.browser_timeout_ms);
  await waitForBrowser(client, sessionId, `document.querySelector('[data-focus-key="remaining-runs:left"]')?.parentElement?.open === true`, "permission_remaining_runs_open_after_recovery", options.browser_timeout_ms);
  phases.push("recovery_fresh_authoritative_fetch");
  let previous = await evaluate(client, sessionId, `document.querySelector('.workspace-source[data-workspace="left"] .provenance').textContent.match(/observed-at (.+)$/)[1]`, "capture_initial_receipt");
  for (let cycle = 1; cycle <= options.flap_count; cycle += 1) {
    await protocol.checkpoint("flap_degrade", {mode: options.mode, servedWorkspace: options.left_workspace, cycle}, options.browser_timeout_ms);
    await waitForBrowser(client, sessionId, `document.querySelector('.workspace-source[data-workspace="left"] .source-error')?.textContent === "Source unreachable · workspace_unavailable"`, `flap_${cycle}_degraded`, options.browser_timeout_ms);
    await protocol.checkpoint("flap_restore", {mode: options.mode, servedWorkspace: options.left_workspace, cycle}, options.browser_timeout_ms);
    await clickRetryAndCount(client, sessionId, network, options, `flap_${cycle}_retry`);
    await waitForBrowser(client, sessionId, `!document.querySelector('.workspace-source[data-workspace="left"] .source-error') && document.querySelector('.workspace-source[data-workspace="left"] .provenance')?.textContent.includes("observed-at ")`, `flap_${cycle}_healthy`, options.browser_timeout_ms);
    const receipt = await evaluate(client, sessionId, `document.querySelector('.workspace-source[data-workspace="left"] .provenance').textContent.match(/observed-at (.+)$/)[1]`, `flap_${cycle}_receipt`);
    if (receipt < previous) throw failure("receipt_boundary_reordered", "Rendered receipt boundary moved backwards", `flap_${cycle}`, {previous, receipt});
    previous = receipt;
  }
  phases.push("rapid_flapping_newest_receipt_monotonic");
}

async function successfulDegradationStory(client, sessionId, protocol, options, phases) {
  const leftUnitHash = workspaceHash("left", options.left_run_id, options.left_unit_id);
  await navigateAndAssert(client, sessionId, leftUnitHash, `document.querySelector('.unit-view')`, `${options.mode}_preserve_route`, options.browser_timeout_ms);
  await protocol.checkpoint("degrade", {mode: options.mode, servedWorkspace: options.left_workspace}, options.browser_timeout_ms);
  if (options.mode === "corrupt_log") {
    await waitForBrowser(client, sessionId, `location.hash === ${JSON.stringify(leftUnitHash)} && document.querySelector('.unit-view')`, "corrupt_navigation_preserved", options.browser_timeout_ms);
  } else {
    await waitForBrowser(client, sessionId, `location.hash === ${JSON.stringify(leftUnitHash)} && document.querySelector('.stale-disclosure') && document.body.textContent.includes("refresh failure run_not_found")`, `${options.mode}_navigation_preserved`, options.browser_timeout_ms);
  }
  phases.push("degrade_navigation_state_preserved");
  await navigateAndAssert(client, sessionId, "#/workspaces", `document.querySelectorAll('.workspace-source').length === 2`, `${options.mode}_degraded_overview`, options.browser_timeout_ms);
  if (options.mode === "corrupt_log") {
    await waitForBrowser(client, sessionId, `document.querySelector('.workspace-source[data-workspace="left"] .limitation')?.textContent.startsWith("Observed count limited: run_projection_incomplete · observed-at ") && document.querySelectorAll('.workspace-source').length === 2`, "corrupt_limitation", options.browser_timeout_ms);
    phases.push("exact_run_projection_incomplete_limitation");
  } else if (options.mode === "removal") {
    await waitForBrowser(client, sessionId, `document.querySelector('.workspace-source[data-workspace="left"] .source-condition')?.textContent.includes("Sessions directory provenance: absent") && document.querySelectorAll('.workspace-source').length === 2`, "removal_absent", options.browser_timeout_ms);
    phases.push("removed_sessions_directory_absent_not_zero_inferred");
  } else {
    await waitForBrowser(client, sessionId, `document.querySelector('.workspace-source[data-workspace="left"] .source-condition')?.textContent.includes("Sessions directory provenance: observed") && document.querySelector('.workspace-source[data-workspace="left"] .source-condition')?.textContent.includes("Observed Session Logs: 0 · selected 0")`, "empty_observed", options.browser_timeout_ms);
    phases.push("empty_source_observed_zero");
  }
  await navigateAndAssert(client, sessionId, workspaceHash("right"), `document.querySelector('.runs-view')`, `${options.mode}_healthy_list`, options.browser_timeout_ms);
  await navigateAndAssert(client, sessionId, workspaceHash("right", options.right_run_id), `document.querySelector('.detail-view')`, `${options.mode}_healthy_detail`, options.browser_timeout_ms);
  await navigateAndAssert(client, sessionId, workspaceHash("right", options.right_run_id, options.right_unit_id), `document.querySelector('.unit-view')`, `${options.mode}_healthy_unit`, options.browser_timeout_ms);
  phases.push("healthy_source_fully_navigable");
  await protocol.checkpoint("restore", {mode: options.mode, servedWorkspace: options.left_workspace}, options.browser_timeout_ms);
  await navigateAndAssert(client, sessionId, "#/workspaces", `document.querySelectorAll('.workspace-source').length === 2`, `${options.mode}_overview`, options.browser_timeout_ms);
  await waitForBrowser(client, sessionId, `document.querySelector('.workspace-source[data-workspace="left"] .source-condition')?.textContent.includes("Sessions directory provenance: observed") && !document.querySelector('.workspace-source[data-workspace="left"] .limitation') && !document.querySelector('.workspace-source[data-workspace="left"] .source-error')`, `${options.mode}_recovered`, options.browser_timeout_ms);
  phases.push("recovery_fresh_authoritative_fetch", "no_duplicate_source_sections");
}

async function emptyRestorationStory(client, sessionId, protocol, network, options, phases) {
  const leftUnitHash = workspaceHash("left", options.left_run_id, options.left_unit_id);
  await navigateAndAssert(client, sessionId, leftUnitHash, `document.querySelector('.unit-view')`, "empty_preserve_route", options.browser_timeout_ms);
  await protocol.checkpoint("prepare_empty", {mode: options.mode, servedWorkspace: options.left_workspace}, options.browser_timeout_ms);
  await waitForBrowser(client, sessionId, `location.hash === ${JSON.stringify(leftUnitHash)} && document.querySelector('.stale-disclosure') && document.body.textContent.includes("refresh failure run_not_found")`, "empty_run_removed", options.browser_timeout_ms);
  phases.push("degrade_navigation_state_preserved");
  await navigateAndAssert(client, sessionId, "#/workspaces", `document.querySelector('.workspace-source[data-workspace="left"] .source-condition')?.textContent.includes("Observed Session Logs: 0 · selected 0") && document.querySelectorAll('.workspace-source').length === 2`, "empty_observed_overview", options.browser_timeout_ms);
  await protocol.checkpoint("degrade", {mode: options.mode, servedWorkspace: options.left_workspace}, options.browser_timeout_ms);
  await waitForBrowser(client, sessionId, `document.querySelector('.workspace-source[data-workspace="left"] .source-error')?.textContent === "Source unreachable · workspace_unavailable" && document.querySelector('.workspace-source[data-workspace="left"] .stale-disclosure')`, "empty_unavailable_overview", options.browser_timeout_ms);
  await protocol.checkpoint("restore_empty", {mode: options.mode, servedWorkspace: options.left_workspace}, options.browser_timeout_ms);
  await clickRetryAndCount(client, sessionId, network, options, "empty_retry_recovery");
  await waitForBrowser(client, sessionId, `!document.querySelector('.workspace-source[data-workspace="left"] .source-error') && document.querySelector('.workspace-source[data-workspace="left"] .source-condition')?.textContent.includes("Sessions directory provenance: observed") && document.querySelector('.workspace-source[data-workspace="left"] .source-condition')?.textContent.includes("Observed Session Logs: 0 · selected 0")`, "empty_observed_restored", options.browser_timeout_ms);
  phases.push("empty_source_observed_zero", "per_source_retry_network_scoped");
  await navigateAndAssert(client, sessionId, workspaceHash("right"), `document.querySelector('.runs-view')`, "empty_healthy_list", options.browser_timeout_ms);
  await navigateAndAssert(client, sessionId, workspaceHash("right", options.right_run_id), `document.querySelector('.detail-view')`, "empty_healthy_detail", options.browser_timeout_ms);
  await navigateAndAssert(client, sessionId, workspaceHash("right", options.right_run_id, options.right_unit_id), `document.querySelector('.unit-view')`, "empty_healthy_unit", options.browser_timeout_ms);
  phases.push("healthy_source_fully_navigable");
  await protocol.checkpoint("restore", {mode: options.mode, servedWorkspace: options.left_workspace}, options.browser_timeout_ms);
  await navigateAndAssert(client, sessionId, "#/workspaces", `document.querySelectorAll('.workspace-source').length === 2`, "empty_final_overview", options.browser_timeout_ms);
  await waitForBrowser(client, sessionId, `document.querySelector('.workspace-source[data-workspace="left"] .source-condition')?.textContent.includes("Observed Session Logs: 1 · selected 1") && !document.querySelector('.workspace-source[data-workspace="left"] .source-error')`, "empty_final_recovery", options.browser_timeout_ms);
  phases.push("recovery_fresh_authoritative_fetch", "no_duplicate_source_sections");
}

async function runsUnheldStory(client, sessionId, protocol, network, options, phases) {
  await waitForBrowser(client, sessionId, `location.hash === "#/workspaces" && document.querySelectorAll('.workspace-source').length === 2 && document.querySelector('.workspace-source[data-workspace="left"] .source-error')?.textContent === "Source unreachable · workspace_unavailable" && document.querySelector('.workspace-source[data-workspace="left"] .source-runs h3')?.textContent === "Remaining observed runs" && !document.querySelector('.workspace-source[data-workspace="left"] .remaining-runs-disclosure')`, "runs_unheld_overview", options.browser_timeout_ms);
  const leftRunsHash = workspaceHash("left");
  await navigateAndAssert(client, sessionId, leftRunsHash, `document.querySelector('.error-view') && document.querySelector('.error-view h1')?.textContent === "Projection unavailable" && document.getElementById('app').textContent.trim().length > 0 && !document.querySelector('.runs-view') && !document.querySelector('.stale-disclosure')`, "runs_unheld_direct", options.browser_timeout_ms);
  phases.push("runs_unheld_unavailable_not_blank");
  await navigateAndAssert(client, sessionId, "#/workspaces", `document.querySelector('[data-focus-key="source-retry:left"]')?.textContent === "Retry this source"`, "runs_unheld_retry_overview", options.browser_timeout_ms);
  await protocol.checkpoint("restore", {mode: options.mode, servedWorkspace: options.left_workspace}, options.browser_timeout_ms);
  await clickRetryAndCount(client, sessionId, network, options, "runs_unheld_retry");
  await waitForBrowser(client, sessionId, `!document.querySelector('.workspace-source[data-workspace="left"] .source-error') && document.querySelector('.workspace-source[data-workspace="left"] .source-condition')?.textContent.includes("Observed Session Logs: 1 · selected 1")`, "runs_unheld_recovered_overview", options.browser_timeout_ms);
  await navigateAndAssert(client, sessionId, leftRunsHash, `document.querySelector('.runs-view') && !document.querySelector('.error-view')`, "runs_unheld_recovered_runs", options.browser_timeout_ms);
  phases.push("per_source_retry_network_scoped", "recovery_fresh_authoritative_fetch", "healthy_source_fully_navigable");
}

async function run(options) {
  const profile = await mkdtemp(join(options.profile_base, "pixir-monitor-workspace-set-browser-"));
  const protocol = new DriverProtocol();
  let browser = null;
  let monitor = null;
  let client = null;
  let browserContextId = null;
  let fifoPath = null;
  let runError = null;
  let runResult = null;
  try {
    browser = spawn(options.browser, ["--headless=new", "--disable-background-networking", "--disable-component-update", "--disable-default-apps", "--disable-sync", "--metrics-recording-only", "--no-first-run", "--no-default-browser-check", "--remote-debugging-port=0", ...extraBrowserArgs(), `--user-data-dir=${profile}`, "about:blank"], {stdio: ["ignore", "ignore", "pipe"]});
    const devToolsUrl = await waitForDevTools(browser.stderr);
    client = await connectDevTools(devToolsUrl);
    browserContextId = (await client.send("Target.createBrowserContext", {disposeOnDetach: true}, null, "create_browser_context")).browserContextId;
    monitor = spawn(options.monitor, ["serve", "--workspace", `left=${options.left_workspace}`, "--workspace", `right=${options.right_workspace}`, "--launch-mode", "fifo", "--json"], {stdio: ["ignore", "pipe", "pipe"]});
    const serving = waitForJsonLine(monitor.stdout, value => value?.ok === true && value?.status === "serving", "monitor_serving", 35_000);
    serving.catch(() => {});
    const readiness = await waitForJsonLine(monitor.stderr, value => value?.ok === true && value?.status === "ready" && value?.launch_mode === "fifo", "monitor_readiness");
    fifoPath = readiness.fifo_path;
    let launchUrl = (await withTimeout(readFile(fifoPath, "utf8"), 15_000, "fifo_reader_timeout", "Monitor did not issue browser handoff", "read_handoff")).trim();
    const launchUri = new URL(launchUrl);
    const target = await client.send("Target.createTarget", {url: "about:blank", browserContextId}, null, "create_page");
    launchUrl = "";
    const sessionId = (await client.send("Target.attachToTarget", {targetId: target.targetId, flatten: true}, null, "attach_target")).sessionId;
    await client.send("Runtime.enable", {}, sessionId, "enable_runtime");
    await client.send("Page.enable", {}, sessionId, "enable_page");
    await client.send("Network.enable", {}, sessionId, "enable_network");
    await client.send("Page.addScriptToEvaluateOnNewDocument", {source: PRELOAD_SCRIPT}, sessionId, "install_harness");
    const network = {records: [], nextRetry: 1};
    client.onEvent(message => {
      if (message.sessionId !== sessionId || message.method !== "Network.requestWillBeSent") return;
      try {
        const path = new URL(message.params.request.url).pathname;
        const match = path.match(/^\/api\/workspaces\/(left|right)\/runs(?:\/|$)/);
        if (match) {
          const headers = message.params.request.headers || {};
          const retryHeader = Object.entries(headers).find(([name]) => name.toLowerCase() === "x-pixir-harness-retry");
          network.records.push({workspace: match[1], path, timestamp: message.params.timestamp, retryToken: retryHeader ? String(retryHeader[1]) : null});
        }
      } catch (_error) {}
    });
    await client.send("Page.navigate", {url: launchUri.href}, sessionId, "bootstrap_navigation");
    if (options.exerciseCdpCrash) {
      const inFlight = client.send("Runtime.evaluate", {expression: "new Promise(() => {})", awaitPromise: true}, sessionId, "exercise_cdp_crash");
      setTimeout(() => browser.kill("SIGKILL"), 50);
      await inFlight;
      throw failure("cdp_crash_not_observed", "Chrome stayed connected during crash exercise", "exercise_cdp_crash");
    }
    if (options.exercisePhaseTimeout) await waitForBrowser(client, sessionId, "false", "exercise_phase_timeout", 250);
    const phases = [];
    if (options.mode === "runs_unheld") {
      await runsUnheldStory(client, sessionId, protocol, network, options, phases);
    } else {
      await healthyTraversal(client, sessionId, options);
      phases.push("healthy_both_overview_list_detail_unit");
      if (options.mode === "permission_denial") await permissionStory(client, sessionId, protocol, network, options, phases);
      else if (options.mode === "empty_restoration") await emptyRestorationStory(client, sessionId, protocol, network, options, phases);
      else await successfulDegradationStory(client, sessionId, protocol, options, phases);
    }
    await serving;
    const handoffCleaned = !existsSync(fifoPath) && !existsSync(dirname(fifoPath));
    if (!handoffCleaned) throw failure("handoff_cleanup_failed", "One-use FIFO was not removed", "verify_cleanup");
    runResult = {ok: true, check: "pixir_monitor_workspace_set_browser_degradation", mode: options.mode, phases, browser: "chrome_devtools_protocol", launch_fragment_cleared: true, handoff_cleaned: true, network_requests: {left: network.records.filter(record => record.workspace === "left").length, right: network.records.filter(record => record.workspace === "right").length}};
    return runResult;
  } catch (error) {
    runError = error;
    throw error;
  } finally {
    protocol.close();
    if (client) {
      if (browserContextId) { try { await client.send("Target.disposeBrowserContext", {browserContextId}, null, "dispose_browser_context"); } catch (_error) {} }
      try { await client.send("Browser.close", {}, null, "close_browser"); } catch (_error) {}
      client.close();
    }
    const browserStopped = await stopChild(browser);
    const monitorStopped = await stopChild(monitor);
    await rm(profile, {recursive: true, force: true});
    const cleanup = {browser_stopped: browserStopped, monitor_stopped: monitorStopped, profile_removed: !existsSync(profile)};
    if (runError) runError.safeDetails = {...(runError.safeDetails || {}), cleanup, profile_path: profile};
    else if (runResult) { runResult.cleanup = cleanup; runResult.profile_path = profile; }
  }
}

let exitCode = 0;
let output;
try {
  const options = parseArgs(process.argv.slice(2));
  validate(options);
  output = options.dryRun ? {ok: true, dry_run: true, check: "pixir_monitor_workspace_set_browser_degradation", mode: options.mode, launch_capability_transport: "cdp_only"} : await run(options);
} catch (error) {
  exitCode = 1;
  output = safeError(error);
}
process.stdout.write(`${JSON.stringify(output)}\n`);
process.exitCode = exitCode;
