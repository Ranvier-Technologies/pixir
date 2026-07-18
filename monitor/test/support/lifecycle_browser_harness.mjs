#!/usr/bin/env node

import {spawn} from "node:child_process";
import {existsSync} from "node:fs";
import {mkdtemp, readFile, rm, stat} from "node:fs/promises";
import {basename, dirname, join} from "node:path";
import {createInterface} from "node:readline";
import process from "node:process";
import {extraBrowserArgs} from "./chrome_args.mjs";

const PHASES = ["serve_boot", "browse_baseline", "live_log_growth", "sse_rotation_300s", "escript_restart", "stale_display_and_new_session"];

function failure(kind, message, stage, details = {}) {
  const error = new Error(message);
  error.harnessKind = kind;
  error.harnessStage = stage;
  error.safeDetails = details;
  return error;
}

function safeError(error) {
  const profilePath = error?.safeDetails?.profile_path;
  return {ok: false, ...(profilePath ? {profile_path: profilePath} : {}), error: {kind: error?.harnessKind || "lifecycle_browser_harness_failed", message: error?.harnessKind ? error.message : "The lifecycle browser harness failed unexpectedly", details: {stage: error?.harnessStage || "unknown", ...(error?.safeDetails || {})}}};
}

function parseArgs(argv) {
  const options = {browser_timeout_ms: 30_000};
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === "--json") continue;
    if (["--monitor", "--workspace", "--existing-log", "--browser", "--profile-base", "--browser-timeout-ms"].includes(arg)) options[arg.slice(2).replaceAll("-", "_")] = argv[++index];
    else throw failure("invalid_args", "Unknown or incomplete lifecycle browser harness argument", "parse_args");
  }
  return options;
}

function validate(options) {
  for (const field of ["monitor", "workspace", "existing_log", "browser", "profile_base"]) {
    if (!options[field]) throw failure("missing_required_arg", `Missing required --${field.replaceAll("_", "-")}`, "validate_args");
    if (!existsSync(options[field])) throw failure(`${field}_missing`, `Required ${field.replaceAll("_", " ")} is missing`, "validate_inputs");
  }
  if (typeof WebSocket !== "function") throw failure("node_websocket_unavailable", "Node.js does not provide WebSocket", "validate_runtime");
  options.browser_timeout_ms = Number(options.browser_timeout_ms);
  if (!Number.isSafeInteger(options.browser_timeout_ms) || options.browser_timeout_ms < 5_000 || options.browser_timeout_ms > 60_000) throw failure("invalid_browser_timeout", "--browser-timeout-ms must be 5000..60000", "validate_args");
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
  if (result.exceptionDetails) throw failure("browser_expression_failed", "Browser assertion expression failed", stage);
  return result.result?.value;
}

async function waitForBrowser(client, sessionId, expression, stage, timeoutMs) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (await evaluate(client, sessionId, expression, stage)) return;
    await new Promise(resolve => setTimeout(resolve, 100));
  }
  const diagnostics = await evaluate(client, sessionId, `({hash: location.hash, text: document.body.textContent.slice(0, 1200), navigationEntries: performance.getEntriesByType("navigation").length})`, `${stage}_diagnostics`);
  throw failure("browser_assertion_timeout", "Browser did not converge", stage, {diagnostics});
}

async function waitUntil(predicate, timeoutMs, stage, intervalMs = 100) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const value = predicate();
    if (value) return value;
    await new Promise(resolve => setTimeout(resolve, intervalMs));
  }
  throw failure("observation_timeout", "Lifecycle observation did not converge", stage);
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
    this.completedPhases = [];
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
  async checkpoint(phase, details, timeoutMs = 30_000) {
    const checkpoint = this.nextCheckpoint++;
    process.stderr.write(`${JSON.stringify({harness: "lifecycle", checkpoint, phase, ...details})}\n`);
    const message = this.messages.length ? this.messages.shift() : await withTimeout(new Promise((resolve, reject) => this.waiters.push({resolve, reject})), timeoutMs, "driver_protocol_timeout", "Driver did not acknowledge lifecycle checkpoint", phase);
    if (message?.phase !== phase || message?.checkpoint !== checkpoint) throw failure("driver_protocol_mismatch", "Driver acknowledged the wrong lifecycle checkpoint", phase, {expected_checkpoint: checkpoint, received_checkpoint: message?.checkpoint || null, received_phase: message?.phase || null});
    if (message?.post_state !== "verified") throw failure("driver_post_state_unverified", "Driver did not verify the lifecycle checkpoint", phase);
    this.completedPhases.push(phase);
  }
  close() { this.lines.close(); }
}

function headersValue(headers, name) {
  if (!headers) return null;
  const found = Object.entries(headers).find(([key]) => key.toLowerCase() === name);
  return found ? String(found[1]) : null;
}

function installNetworkRecorder(client, sessionId) {
  const network = {events: [], apiReceipts: []};
  client.onEvent(message => {
    if (message.sessionId !== sessionId) return;
    if (message.method === "Network.requestWillBeSent") {
      try {
        const path = new URL(message.params.request.url).pathname;
        if (path === "/api/events") network.events.push({requestId: message.params.requestId, startedAt: message.params.timestamp, responseAt: null, endedAt: null, status: null});
      } catch (_error) {}
    } else if (message.method === "Network.responseReceived") {
      let path;
      try { path = new URL(message.params.response.url).pathname; } catch (_error) { return; }
      if (path === "/api/events") {
        const record = network.events.find(item => item.requestId === message.params.requestId);
        if (record) { record.responseAt = message.params.timestamp; record.status = message.params.response.status; }
      } else if (path === "/api/runs" && message.params.response.status === 200) {
        network.apiReceipts.push({requestId: message.params.requestId, receivedAt: message.params.timestamp, contentSha256: headersValue(message.params.response.headers, "x-content-sha256")});
      }
    } else if (message.method === "Network.loadingFinished") {
      const record = network.events.find(item => item.requestId === message.params.requestId);
      if (record) record.endedAt = message.params.timestamp;
    } else if (message.method === "Network.loadingFailed") {
      const record = network.events.find(item => item.requestId === message.params.requestId);
      if (record) record.endedAt = message.params.timestamp;
    }
  });
  return network;
}

async function startMonitor(options, stage) {
  const child = spawn(options.monitor, ["serve", "--workspace", options.workspace, "--launch-mode", "fifo", "--json"], {stdio: ["ignore", "pipe", "pipe"]});
  const spawnFailed = new Promise((_resolve, reject) => child.on("error", error => reject(failure("monitor_spawn_failed", `Monitor process could not be spawned: ${error.code || error.message}`, stage))));
  spawnFailed.catch(() => {});
  try {
    const serving = waitForJsonLine(child.stdout, value => value?.ok === true && value?.status === "serving", `${stage}_serving`, 60_000);
    serving.catch(() => {});
    const readiness = await Promise.race([waitForJsonLine(child.stderr, value => value?.ok === true && value?.status === "ready" && value?.launch_mode === "fifo", `${stage}_readiness`, 45_000), spawnFailed]);
    let launchUrl = (await withTimeout(readFile(readiness.fifo_path, "utf8"), 15_000, "fifo_reader_timeout", "Monitor did not issue browser handoff", `${stage}_handoff`)).trim();
    const launchUri = new URL(launchUrl);
    launchUrl = "";
    await Promise.race([serving, spawnFailed]);
    return {child, fifoPath: readiness.fifo_path, launchUri};
  } catch (error) {
    await stopChild(child);
    throw error;
  }
}

async function createPage(client, browserContextId, launchUri, stage) {
  const target = await client.send("Target.createTarget", {url: "about:blank", browserContextId}, null, `${stage}_create_page`);
  const sessionId = (await client.send("Target.attachToTarget", {targetId: target.targetId, flatten: true}, null, `${stage}_attach_page`)).sessionId;
  await client.send("Runtime.enable", {}, sessionId, `${stage}_enable_runtime`);
  await client.send("Page.enable", {}, sessionId, `${stage}_enable_page`);
  await client.send("Network.enable", {}, sessionId, `${stage}_enable_network`);
  const network = installNetworkRecorder(client, sessionId);
  await client.send("Page.navigate", {url: launchUri.href}, sessionId, `${stage}_bootstrap_navigation`);
  return {targetId: target.targetId, sessionId, network};
}

async function navigationCount(client, sessionId, stage) {
  return evaluate(client, sessionId, `performance.getEntriesByType("navigation").length`, stage);
}

async function run(options) {
  const profile = await mkdtemp(join(options.profile_base, "pixir-monitor-lifecycle-"));
  const protocol = new DriverProtocol();
  let browser = null;
  let monitor = null;
  const monitors = [];
  let client = null;
  let browserContextId = null;
  const fifoPaths = [];
  let runError = null;
  let result = null;
  try {
    browser = spawn(options.browser, ["--headless=new", "--disable-background-networking", "--disable-component-update", "--disable-default-apps", "--disable-sync", "--metrics-recording-only", "--no-first-run", "--no-default-browser-check", "--remote-debugging-port=0", ...extraBrowserArgs(), `--user-data-dir=${profile}`, "about:blank"], {stdio: ["ignore", "ignore", "pipe"]});
    const browserSpawnFailed = new Promise((_resolve, reject) => browser.on("error", error => reject(failure("browser_spawn_failed", `Browser process could not be spawned: ${error.code || error.message}`, "launch_browser"))));
    browserSpawnFailed.catch(() => {});
    client = await connectDevTools(await Promise.race([waitForDevTools(browser.stderr), browserSpawnFailed]));
    browserContextId = (await client.send("Target.createBrowserContext", {disposeOnDetach: true}, null, "create_browser_context")).browserContextId;

    const first = await startMonitor(options, "initial_monitor");
    monitors.push(first.child);
    monitor = first.child;
    fifoPaths.push(first.fifoPath);
    await protocol.checkpoint("serve_boot", {servedWorkspace: options.workspace, expectedCount: 8, monitorPid: monitor.pid});
    const oldPage = await createPage(client, browserContextId, first.launchUri, "old_tab");
    await waitForBrowser(client, oldPage.sessionId, `document.title === "Pixir Monitor" && location.hash === "#/runs" && document.querySelector('.runs-view') && document.querySelectorAll('.runs-table tbody tr').length === 8 && !location.hash.startsWith("#launch=")`, "browse_baseline_render", options.browser_timeout_ms);
    await waitUntil(() => oldPage.network.events.length >= 1 && oldPage.network.apiReceipts.length >= 1, options.browser_timeout_ms, "browse_baseline_network");
    if (await navigationCount(client, oldPage.sessionId, "browse_baseline_navigation") !== 1) throw failure("navigation_entry_count_failed", "Baseline did not have exactly one navigation entry", "browse_baseline");
    const baselineRows = await evaluate(client, oldPage.sessionId, `document.querySelectorAll('.runs-table tbody tr').length`, "browse_baseline_rows");
    const baselineReceipt = oldPage.network.apiReceipts.at(-1);
    await protocol.checkpoint("browse_baseline", {servedWorkspace: options.workspace, expectedCount: 8});

    const beforeSize = (await stat(options.existing_log)).size;
    await protocol.checkpoint("live_log_growth", {servedWorkspace: options.workspace, existingLog: options.existing_log, beforeSize});
    await waitForBrowser(client, oldPage.sessionId, `document.querySelector('.runs-view') && document.querySelectorAll('.runs-table tbody tr').length === 9 && document.querySelector('.inventory-summary')?.textContent.includes("9 selected of 9 Session Logs")`, "live_growth_render", options.browser_timeout_ms);
    await waitUntil(() => oldPage.network.apiReceipts.some(receipt => receipt.receivedAt > baselineReceipt.receivedAt), options.browser_timeout_ms, "live_growth_fresh_receipt");
    if (await navigationCount(client, oldPage.sessionId, "live_growth_navigation") !== 1) throw failure("navigation_entry_count_failed", "Live growth changed the navigation entry count", "live_log_growth");
    const grownRows = await evaluate(client, oldPage.sessionId, `document.querySelectorAll('.runs-table tbody tr').length`, "live_growth_rows");
    // The append itself must be projected, not merely the added file: the grown
    // run's detail (hash navigation only, no reload) must show the moved seq.
    const grownRunId = basename(options.existing_log, ".ndjson");
    await evaluate(client, oldPage.sessionId, `location.hash = ${JSON.stringify(`#/runs/${grownRunId}`)}; true`, "growth_detail_nav");
    await waitForBrowser(client, oldPage.sessionId, `/as of seq 1(?!\\d)/.test(document.body.textContent)`, "growth_detail_seq_moved", options.browser_timeout_ms);
    await evaluate(client, oldPage.sessionId, `location.hash = "#/runs"; true`, "growth_detail_back");
    await waitForBrowser(client, oldPage.sessionId, `document.querySelector('.runs-view') && document.querySelectorAll('.runs-table tbody tr').length === 9`, "growth_detail_return", options.browser_timeout_ms);
    if (await navigationCount(client, oldPage.sessionId, "growth_detail_navigation") !== 1) throw failure("navigation_entry_count_failed", "The detail round-trip changed the navigation entry count", "live_log_growth");

    await protocol.checkpoint("sse_rotation_300s", {servedWorkspace: options.workspace, expectedCount: 9});
    // The fixture remains completely quiet here, so the ONLY thing that can close
    // the observed stream inside the window is the 300s server timer (keepalives
    // do not count toward the 100-event cap). The rotation candidate is the
    // stream that is OPEN at this moment: an earlier transient reconnect must not
    // be mistaken for the rotation, and the lifetime bound below fails closed if
    // anything other than the timer ended it.
    const rotationCandidates = oldPage.network.events.filter(item => item.responseAt !== null && item.endedAt === null);
    if (rotationCandidates.length !== 1) throw failure("sse_rotation_candidate_ambiguous", "Exactly one open /api/events stream must exist when the quiet window starts", "sse_rotation_300s", {open_streams: rotationCandidates.length, total_streams: oldPage.network.events.length});
    const rotationStream = rotationCandidates[0];
    if (rotationStream.status !== 200) throw failure("sse_stream_unauthenticated", "The observed /api/events stream was not an authenticated 200 response", "sse_rotation_300s", {status: rotationStream.status});
    const streamsBeforeRotation = oldPage.network.events.length;
    await waitUntil(() => rotationStream.endedAt !== null, 330_000, "sse_timer_close", 250);
    const streamLifetimeSeconds = rotationStream.endedAt - rotationStream.responseAt;
    if (streamLifetimeSeconds < 290 || streamLifetimeSeconds > 330) throw failure("sse_rotation_not_timer_shaped", "The observed /api/events stream did not live the 300s server-timer lifetime, so whatever closed it was not the rotation under test", "sse_rotation_300s", {stream_lifetime_seconds: streamLifetimeSeconds});
    await waitUntil(() => oldPage.network.events.length > streamsBeforeRotation && oldPage.network.events.slice(streamsBeforeRotation).some(item => item.responseAt !== null), 15_000, "sse_native_reconnect", 100);
    const reconnectedStream = oldPage.network.events.slice(streamsBeforeRotation).find(item => item.responseAt !== null);
    if (reconnectedStream.startedAt <= rotationStream.endedAt) throw failure("sse_reconnect_out_of_order", "The reconnected /api/events request did not start after the rotated stream ended", "sse_rotation_300s", {rotated_ended_at: rotationStream.endedAt, reconnect_started_at: reconnectedStream.startedAt});
    if (reconnectedStream.status !== 200) throw failure("sse_reconnect_unauthenticated", "The reconnected /api/events stream was not an authenticated 200 response", "sse_rotation_300s", {status: reconnectedStream.status});
    await waitUntil(() => oldPage.network.apiReceipts.some(receipt => receipt.receivedAt > reconnectedStream.responseAt), options.browser_timeout_ms, "sse_reconnect_authoritative_refetch");
    if (await navigationCount(client, oldPage.sessionId, "sse_rotation_navigation") !== 1) throw failure("navigation_entry_count_failed", "SSE rotation changed the navigation entry count", "sse_rotation_300s");

    const frozenReceipt = await evaluate(client, oldPage.sessionId, `document.getElementById("sse-health")?.textContent.match(/last successful authoritative refetch (.+)$/)?.[1] || null`, "capture_frozen_receipt");
    if (!frozenReceipt) throw failure("receipt_missing", "The old tab did not expose its last-observed receipt", "escript_restart");
    await protocol.checkpoint("escript_restart", {servedWorkspace: options.workspace, monitorPid: monitor.pid}, 30_000);
    await waitForBrowser(client, oldPage.sessionId, `document.getElementById("sse-health")?.textContent.includes("SSE down") && document.querySelector('.error-view')?.textContent.includes("Projection unavailable")`, "old_tab_honest_stale", options.browser_timeout_ms);
    const staleReceipt = await evaluate(client, oldPage.sessionId, `document.getElementById("sse-health")?.textContent.match(/last successful authoritative refetch (.+)$/)?.[1] || null`, "old_tab_stale_receipt");
    if (staleReceipt !== frozenReceipt) throw failure("stale_receipt_changed", "The old tab changed its frozen last-observed receipt while unavailable", "escript_restart", {frozen_receipt: frozenReceipt, stale_receipt: staleReceipt});

    const second = await startMonitor(options, "restarted_monitor");
    monitors.push(second.child);
    monitor = second.child;
    // No port-inequality assertion: the kernel may legitimately rebind the same
    // ephemeral port, and nothing in the product promises a new one. The new
    // session's freshness is what the new-tab pins below prove.
    fifoPaths.push(second.fifoPath);
    await protocol.checkpoint("stale_display_and_new_session", {servedWorkspace: options.workspace, expectedCount: 9, monitorPid: monitor.pid});
    const oldEvidenceBeforeNewTab = await evaluate(client, oldPage.sessionId, `({receipt: document.getElementById("sse-health")?.textContent.match(/last successful authoritative refetch (.+)$/)?.[1] || null, stale: Boolean(document.getElementById("sse-health")?.textContent.includes("SSE down") && document.querySelector('.error-view')?.textContent.includes("Projection unavailable")), navigations: performance.getEntriesByType("navigation").length})`, "old_tab_evidence_before_new_tab");
    if (!oldEvidenceBeforeNewTab.stale || oldEvidenceBeforeNewTab.receipt !== frozenReceipt || oldEvidenceBeforeNewTab.navigations !== 1) throw failure("old_tab_not_fail_closed", "The old tab did not retain its honest stale state before the new tab existed", "stale_display_and_new_session", {old_evidence: oldEvidenceBeforeNewTab});

    const newPage = await createPage(client, browserContextId, second.launchUri, "new_tab");
    await waitForBrowser(client, newPage.sessionId, `document.title === "Pixir Monitor" && location.hash === "#/runs" && document.querySelector('.runs-view') && document.querySelectorAll('.runs-table tbody tr').length === 9 && document.getElementById("sse-health")?.textContent.includes("SSE connected")`, "new_tab_fresh", options.browser_timeout_ms);
    if (await navigationCount(client, newPage.sessionId, "new_tab_navigation") !== 1) throw failure("navigation_entry_count_failed", "The new session did not have exactly one navigation entry", "stale_display_and_new_session");
    const oldEvidenceAfterNewTab = await evaluate(client, oldPage.sessionId, `({receipt: document.getElementById("sse-health")?.textContent.match(/last successful authoritative refetch (.+)$/)?.[1] || null, stale: Boolean(document.getElementById("sse-health")?.textContent.includes("SSE down") && document.querySelector('.error-view')?.textContent.includes("Projection unavailable")), navigations: performance.getEntriesByType("navigation").length})`, "old_tab_evidence_after_new_tab");
    if (!oldEvidenceAfterNewTab.stale || oldEvidenceAfterNewTab.receipt !== frozenReceipt || oldEvidenceAfterNewTab.navigations !== 1) throw failure("old_tab_cross_contaminated", "The fresh session contaminated the old tab's fail-closed display", "stale_display_and_new_session");

    const handoffsCleaned = fifoPaths.every(path => !existsSync(path) && !existsSync(dirname(path)));
    if (!handoffsCleaned) throw failure("handoff_cleanup_failed", "A one-use FIFO handoff was not removed", "verify_cleanup");
    const oldFragmentCleared = await evaluate(client, oldPage.sessionId, `!location.hash.startsWith("#launch=")`, "old_tab_fragment_cleared");
    const newFragmentCleared = await evaluate(client, newPage.sessionId, `!location.hash.startsWith("#launch=")`, "new_tab_fragment_cleared");
    if (JSON.stringify(protocol.completedPhases) !== JSON.stringify(PHASES)) throw failure("phase_order_mismatch", "The completed checkpoints do not match the expected lifecycle order", "verify_cleanup", {completed: protocol.completedPhases});
    result = {ok: true, check: "pixir_monitor_lifecycle", phases: protocol.completedPhases, browser: "chrome_devtools_protocol", baseline_count: baselineRows, grown_count: grownRows, event_requests: oldPage.network.events.length, rotated_stream_lifetime_seconds: streamLifetimeSeconds, navigation_entries: oldEvidenceAfterNewTab.navigations, launch_fragment_cleared: oldFragmentCleared && newFragmentCleared, handoffs_cleaned: handoffsCleaned};
    return result;
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
    let monitorStopped = true;
    for (const child of monitors) monitorStopped = (await stopChild(child)) && monitorStopped;
    if (!monitors.includes(monitor)) monitorStopped = (await stopChild(monitor)) && monitorStopped;
    await rm(profile, {recursive: true, force: true});
    const cleanup = {browser_stopped: browserStopped, monitor_stopped: monitorStopped, profile_removed: !existsSync(profile)};
    if (runError) runError.safeDetails = {...(runError.safeDetails || {}), cleanup, profile_path: profile};
    else if (result) { result.cleanup = cleanup; result.profile_path = profile; }
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
