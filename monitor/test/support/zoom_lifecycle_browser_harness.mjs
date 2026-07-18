#!/usr/bin/env node

import {spawn} from "node:child_process";
import {existsSync} from "node:fs";
import {mkdtemp, readFile, rm, stat} from "node:fs/promises";
import {dirname, join} from "node:path";
import {createInterface} from "node:readline";
import process from "node:process";
import {extraBrowserArgs} from "./chrome_args.mjs";

const PHASES = ["serve_boot", "expand_state", "sse_lands_on_expansion", "selection_clamp_honesty"];

function failure(kind, message, stage, details = {}) {
  const error = new Error(message);
  error.harnessKind = kind;
  error.harnessStage = stage;
  error.safeDetails = details;
  return error;
}

function safeError(error) {
  const profilePath = error?.safeDetails?.profile_path;
  return {ok: false, ...(profilePath ? {profile_path: profilePath} : {}), error: {kind: error?.harnessKind || "zoom_lifecycle_browser_harness_failed", message: error?.harnessKind ? error.message : "The zoom lifecycle browser harness failed unexpectedly", details: {stage: error?.harnessStage || "unknown", ...(error?.safeDetails || {})}}};
}

function parseArgs(argv) {
  const options = {browser_timeout_ms: 60_000};
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === "--json") continue;
    if (["--monitor", "--workspace", "--run-id", "--log", "--browser", "--profile-base", "--browser-timeout-ms"].includes(arg)) options[arg.slice(2).replaceAll("-", "_")] = argv[++index];
    else throw failure("invalid_args", "Unknown or incomplete zoom lifecycle browser harness argument", "parse_args");
  }
  return options;
}

function validate(options) {
  for (const field of ["monitor", "workspace", "run_id", "log", "browser", "profile_base"]) {
    if (!options[field]) throw failure("missing_required_arg", `Missing required --${field.replaceAll("_", "-")}`, "validate_args");
  }
  for (const field of ["monitor", "workspace", "log", "browser", "profile_base"]) {
    if (!existsSync(options[field])) throw failure(`${field}_missing`, `Required ${field.replaceAll("_", " ")} is missing`, "validate_inputs");
  }
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
  if (result.exceptionDetails) throw failure("browser_expression_failed", "Browser assertion expression failed", stage);
  return result.result?.value;
}

async function waitForBrowser(client, sessionId, expression, stage, timeoutMs) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (await evaluate(client, sessionId, expression, stage)) return;
    await new Promise(resolve => setTimeout(resolve, 100));
  }
  const diagnostics = await evaluate(client, sessionId, `({hash: location.hash, text: document.body.textContent.slice(0, 1600), navigationEntries: performance.getEntriesByType("navigation").length})`, `${stage}_diagnostics`);
  throw failure("browser_assertion_timeout", "Browser did not converge", stage, {diagnostics});
}

async function waitUntil(predicate, timeoutMs, stage, intervalMs = 100) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const value = predicate();
    if (value) return value;
    await new Promise(resolve => setTimeout(resolve, intervalMs));
  }
  throw failure("observation_timeout", "Zoom lifecycle observation did not converge", stage);
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
    process.stderr.write(`${JSON.stringify({harness: "zoom_lifecycle", checkpoint, phase, ...details})}\n`);
    const message = this.messages.length ? this.messages.shift() : await withTimeout(new Promise((resolve, reject) => this.waiters.push({resolve, reject})), timeoutMs, "driver_protocol_timeout", "Driver did not acknowledge zoom lifecycle checkpoint", phase);
    if (message?.phase !== phase || message?.checkpoint !== checkpoint) throw failure("driver_protocol_mismatch", "Driver acknowledged the wrong zoom lifecycle checkpoint", phase, {expected_checkpoint: checkpoint, received_checkpoint: message?.checkpoint || null, received_phase: message?.phase || null});
    if (message?.post_state !== "verified") throw failure("driver_post_state_unverified", "Driver did not verify the zoom lifecycle checkpoint", phase);
    this.completedPhases.push(phase);
    return message;
  }
  close() { this.lines.close(); }
}

function headerValue(headers, name) {
  const found = Object.entries(headers || {}).find(([key]) => key.toLowerCase() === name);
  return found ? String(found[1]) : null;
}

function installReceiptRecorder(client, sessionId, runId) {
  const receipts = [];
  client.onEvent(message => {
    if (message.sessionId !== sessionId || message.method !== "Network.responseReceived") return;
    try {
      const url = new URL(message.params.response.url);
      if (url.pathname === `/api/runs/${encodeURIComponent(runId)}` && message.params.response.status === 200) receipts.push({receivedAt: message.params.timestamp, contentSha256: headerValue(message.params.response.headers, "x-content-sha256")});
    } catch (_error) {}
  });
  return receipts;
}

async function run(options) {
  const profile = await mkdtemp(join(options.profile_base, "pixir-monitor-zoom-lifecycle-"));
  const protocol = new DriverProtocol();
  let browser = null;
  let monitor = null;
  const monitors = [];
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
    monitors.push(monitor);
    const monitorSpawnFailed = new Promise((_resolve, reject) => monitor.on("error", error => reject(failure("monitor_spawn_failed", `Monitor process could not be spawned: ${error.code || error.message}`, "start_monitor"))));
    monitorSpawnFailed.catch(() => {});
    const serving = waitForJsonLine(monitor.stdout, value => value?.ok === true && value?.status === "serving", "monitor_serving", 60_000);
    serving.catch(() => {});
    const readiness = await Promise.race([waitForJsonLine(monitor.stderr, value => value?.ok === true && value?.status === "ready" && value?.launch_mode === "fifo", "monitor_readiness", 45_000), monitorSpawnFailed]);
    fifoPath = readiness.fifo_path;
    let launchUrl = (await withTimeout(readFile(fifoPath, "utf8"), 15_000, "fifo_reader_timeout", "Monitor did not issue browser handoff", "read_handoff")).trim();
    const launchUri = new URL(launchUrl);
    launchUrl = "";
    await Promise.race([serving, monitorSpawnFailed]);

    await protocol.checkpoint("serve_boot", {servedWorkspace: options.workspace, runId: options.run_id, monitorPid: monitor.pid});

    const target = await client.send("Target.createTarget", {url: "about:blank", browserContextId}, null, "create_page");
    const sessionId = (await client.send("Target.attachToTarget", {targetId: target.targetId, flatten: true}, null, "attach_page")).sessionId;
    await client.send("Runtime.enable", {}, sessionId, "enable_runtime");
    await client.send("Page.enable", {}, sessionId, "enable_page");
    await client.send("Network.enable", {}, sessionId, "enable_network");
    const receipts = installReceiptRecorder(client, sessionId, options.run_id);
    await client.send("Page.navigate", {url: launchUri.href}, sessionId, "bootstrap_navigation");
    await waitForBrowser(client, sessionId, `document.title === "Pixir Monitor" && location.hash === "#/runs" && document.querySelector('.runs-view') && !location.hash.startsWith("#launch=")`, "initial_runs", options.browser_timeout_ms);

    const detailHash = `#/runs/${encodeURIComponent(options.run_id)}`;
    await evaluate(client, sessionId, `location.hash = ${JSON.stringify(detailHash)}; true`, "detail_navigation");
    await waitForBrowser(client, sessionId, `location.hash === ${JSON.stringify(detailHash)} && document.querySelector('.detail-view .semantic-zoom') && document.querySelector('[data-focus-key="cluster:wave:0:bucket:0"]')`, "detail_ready", options.browser_timeout_ms);
    await waitUntil(() => receipts.length >= 1, options.browser_timeout_ms, "detail_receipt");

    const clusterClicked = await evaluate(client, sessionId, `(() => { const node = document.querySelector('[data-focus-key="cluster:wave:0:bucket:0"]'); if (!node) return false; node.click(); return true; })()`, "select_cluster");
    if (!clusterClicked) throw failure("cluster_affordance_missing", "The verified cluster affordance was not available", "expand_state");
    await waitForBrowser(client, sessionId, `new URLSearchParams(location.hash.split("?")[1] || "").get("cluster") === "wave:0:bucket:0" && document.querySelector('.cluster-inspector') && document.querySelector('[data-focus-key="members-next:wave:0:bucket:0"]')`, "cluster_selected", options.browser_timeout_ms);
    const nextClicked = await evaluate(client, sessionId, `(() => { const node = document.querySelector('[data-focus-key="members-next:wave:0:bucket:0"]'); if (!node) return false; node.click(); return true; })()`, "members_next");
    if (!nextClicked) throw failure("members_next_affordance_missing", "The verified member-page affordance was not available", "expand_state");
    await waitForBrowser(client, sessionId, `new URLSearchParams(location.hash.split("?")[1] || "").get("members") === "2" && document.querySelectorAll('.cluster-inspector .unit-card').length > 12`, "member_page_two", options.browser_timeout_ms);

    await evaluate(client, sessionId, `(() => { const summary = document.querySelector('details[data-disclosure-key] > summary'); if (!summary) return false; summary.click(); return summary.parentElement.open; })()`, "open_disclosure");
    const expansion = await evaluate(client, sessionId, `({hash: location.hash, zoomStart: document.querySelector('.semantic-zoom')?.dataset.zoomStart || null, selectedCluster: new URLSearchParams(location.hash.split("?")[1] || "").get("cluster"), memberPage: Number(new URLSearchParams(location.hash.split("?")[1] || "").get("members")), memberIds: Array.from(document.querySelectorAll('.cluster-inspector .unit-card')).map(node => node.dataset.unitId), openKeys: Array.from(document.querySelectorAll('details[data-disclosure-key][open]')).map(node => node.dataset.disclosureKey), navigationEntries: performance.getEntriesByType("navigation").length})`, "capture_expansion");
    if (expansion.zoomStart !== "0" || expansion.selectedCluster !== "wave:0:bucket:0" || expansion.memberPage !== 2 || expansion.memberIds.length <= 12 || expansion.openKeys.length < 1 || expansion.navigationEntries !== 1) throw failure("expanded_state_unverified", "The expanded semantic zoom state was not fully established", "expand_state", {expansion});
    await protocol.checkpoint("expand_state", {servedWorkspace: options.workspace, logSize: (await stat(options.log)).size, selectedCluster: expansion.selectedCluster, memberPage: expansion.memberPage});

    const baselineReceipt = receipts.at(-1);
    const beforeLines = (await readFile(options.log, "utf8")).trimEnd().split("\n").map(line => JSON.parse(line));
    const beforeSeq = Math.max(...beforeLines.map(event => event.seq));
    const beforeSize = (await stat(options.log)).size;
    await protocol.checkpoint("sse_lands_on_expansion", {servedWorkspace: options.workspace, beforeSize, beforeSeq, selectedCluster: expansion.selectedCluster, memberPage: expansion.memberPage});
    const expectedSeq = beforeSeq + 1;
    await waitForBrowser(client, sessionId, `new RegExp("as of seq ${expectedSeq}(?!\\\\d)").test(document.body.textContent)`, "appended_seq_projected", options.browser_timeout_ms);
    await waitUntil(() => receipts.some(receipt => receipt.receivedAt > baselineReceipt.receivedAt && receipt.contentSha256 && receipt.contentSha256 !== baselineReceipt.contentSha256), options.browser_timeout_ms, "fresh_authoritative_receipt");
    const preserved = await evaluate(client, sessionId, `({zoomStart: document.querySelector('.semantic-zoom')?.dataset.zoomStart || null, selectedCluster: new URLSearchParams(location.hash.split("?")[1] || "").get("cluster"), memberPage: Number(new URLSearchParams(location.hash.split("?")[1] || "").get("members")), memberIds: Array.from(document.querySelectorAll('.cluster-inspector .unit-card')).map(node => node.dataset.unitId), openKeys: Array.from(document.querySelectorAll('details[data-disclosure-key][open]')).map(node => node.dataset.disclosureKey), navigationEntries: performance.getEntriesByType("navigation").length})`, "verify_preserved_expansion");
    const selectionPreserved = preserved.selectedCluster === expansion.selectedCluster;
    const zoomWindowPreserved = preserved.zoomStart === expansion.zoomStart;
    const memberPagePreserved = preserved.memberPage === expansion.memberPage && JSON.stringify(preserved.memberIds) === JSON.stringify(expansion.memberIds);
    const disclosuresPreserved = expansion.openKeys.every(key => preserved.openKeys.includes(key));
    if (!selectionPreserved || !zoomWindowPreserved || !memberPagePreserved || !disclosuresPreserved || preserved.navigationEntries !== 1) throw failure("expanded_state_not_preserved", "Authoritative refetch did not preserve the expanded semantic zoom state", "sse_lands_on_expansion", {expansion, preserved});

    // The clamp is exercised through a REAL reachable transition — an
    // overshooting deep link (members=99) on the UNCHANGED append-only store —
    // never by rewriting canonical Log history. The driver verifies the store
    // is byte-identical and returns the read-model expectation.
    const logSizeBeforeClamp = (await stat(options.log)).size;
    const clampAck = await protocol.checkpoint("selection_clamp_honesty", {servedWorkspace: options.workspace, selectedCluster: preserved.selectedCluster, memberPage: preserved.memberPage, logSize: logSizeBeforeClamp});
    const clampExpectation = clampAck?.clamp_expectation;
    if (!clampExpectation || !Number.isInteger(clampExpectation.member_page_max) || clampExpectation.member_page_max < 2 || !Array.isArray(clampExpectation.visible_member_ids) || clampExpectation.visible_member_ids.length === 0) throw failure("clamp_expectation_missing", "The driver did not return its read-model-derived clamp expectation", "selection_clamp_honesty");
    const overshootParams = new URLSearchParams();
    overshootParams.set("cluster", clampExpectation.selected_cluster);
    overshootParams.set("members", "99");
    const overshootMembers = await evaluate(client, sessionId, `location.hash = ${JSON.stringify(`${detailHash}?${overshootParams.toString()}`)}; new URLSearchParams(location.hash.split("?")[1] || "").get("members")`, "clamp_overshoot_navigation");
    if (overshootMembers !== "99") throw failure("clamp_overshoot_not_applied", "The overshooting deep link was never applied, so the clamp would be vacuous", "selection_clamp_honesty", {observed_members: overshootMembers});
    await waitForBrowser(client, sessionId, `new URLSearchParams(location.hash.split("?")[1] || "").get("members") === ${JSON.stringify(String(clampExpectation.member_page_max))} && document.querySelectorAll('.cluster-inspector .unit-card').length === ${clampExpectation.visible_member_ids.length}`, "selection_clamped", options.browser_timeout_ms);
    const clamped = await evaluate(client, sessionId, `({hash: location.hash, selectedCluster: new URLSearchParams(location.hash.split("?")[1] || "").get("cluster"), memberPage: new URLSearchParams(location.hash.split("?")[1] || "").get("members"), memberIds: Array.from(document.querySelectorAll('.cluster-inspector .unit-card')).map(node => node.dataset.unitId), navigationEntries: performance.getEntriesByType("navigation").length})`, "capture_clamped_state");
    const clampHonest = clamped.hash.startsWith(detailHash) && clamped.selectedCluster === clampExpectation.selected_cluster && clamped.memberPage === String(clampExpectation.member_page_max) && JSON.stringify(clamped.memberIds) === JSON.stringify(clampExpectation.visible_member_ids) && clamped.navigationEntries === 1;
    if (!clampHonest) throw failure("selection_clamp_failed", "The overshooting deep link was not honestly clamped to the read-model-derived last page", "selection_clamp_honesty", {clamped, clamp_expectation: clampExpectation});

    const handoffCleaned = !existsSync(fifoPath) && !existsSync(dirname(fifoPath));
    if (!handoffCleaned) throw failure("handoff_cleanup_failed", "The one-use FIFO handoff was not removed", "verify_cleanup");
    if (JSON.stringify(protocol.completedPhases) !== JSON.stringify(PHASES)) throw failure("phase_order_mismatch", "The completed checkpoints do not match the expected zoom lifecycle order", "verify_cleanup", {completed: protocol.completedPhases});
    const fragmentCleared = await evaluate(client, sessionId, `!location.hash.startsWith("#launch=")`, "launch_fragment_cleared");
    const staleMemberRows = clamped.memberIds.filter(id => !clampExpectation.visible_member_ids.includes(id)).length;
    result = {ok: fragmentCleared === true, check: "pixir_monitor_zoom_lifecycle", phases: protocol.completedPhases, navigation_entries: clamped.navigationEntries, fresh_receipt: receipts.length >= 2, selection_preserved: selectionPreserved, zoom_window_preserved: zoomWindowPreserved, member_page_preserved: memberPagePreserved, disclosures_preserved: disclosuresPreserved, selection_clamped: clampHonest, stale_member_rows: staleMemberRows, launch_fragment_cleared: fragmentCleared === true, handoff_cleaned: handoffCleaned};
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
