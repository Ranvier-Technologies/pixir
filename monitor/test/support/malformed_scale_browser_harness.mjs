#!/usr/bin/env node

import {spawn} from "node:child_process";
import {existsSync} from "node:fs";
import {mkdtemp, readFile, rm} from "node:fs/promises";
import {dirname, join} from "node:path";
import {createInterface} from "node:readline";
import process from "node:process";
import {extraBrowserArgs} from "./chrome_args.mjs";

function failure(kind, message, stage, details = {}) {
  const error = new Error(message);
  error.harnessKind = kind;
  error.harnessStage = stage;
  error.safeDetails = details;
  return error;
}

function safeError(error) {
  return {ok: false, error: {kind: error?.harnessKind || "malformed_scale_browser_harness_failed", message: error?.harnessKind ? error.message : "The malformed scale browser harness failed unexpectedly", details: {stage: error?.harnessStage || "unknown", ...(error?.safeDetails || {})}}};
}

function parseArgs(argv) {
  const options = {browser_timeout_ms: 60_000};
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === "--json") continue;
    if (["--monitor", "--workspace", "--browser", "--profile-base", "--run-id", "--oracle-file", "--browser-timeout-ms"].includes(arg)) options[arg.slice(2).replaceAll("-", "_")] = argv[++index];
    else throw failure("invalid_args", "Unknown or incomplete malformed scale browser harness argument", "parse_args");
  }
  return options;
}

function validate(options) {
  for (const field of ["monitor", "workspace", "browser", "profile_base", "run_id", "oracle_file"]) {
    if (!options[field]) throw failure("missing_required_arg", `Missing required --${field.replaceAll("_", "-")}`, "validate_args");
  }
  for (const field of ["monitor", "workspace", "browser", "profile_base", "oracle_file"]) {
    if (!existsSync(options[field])) throw failure(`${field}_missing`, `Required ${field.replaceAll("_", " ")} is missing`, "validate_inputs");
  }
  if (typeof WebSocket !== "function") throw failure("node_websocket_unavailable", "Node.js does not provide WebSocket", "validate_runtime");
  options.browser_timeout_ms = Number(options.browser_timeout_ms);
  if (!Number.isSafeInteger(options.browser_timeout_ms) || options.browser_timeout_ms < 1_000 || options.browser_timeout_ms > 120_000) throw failure("invalid_browser_timeout", "--browser-timeout-ms must be 1000..120000", "validate_args");
}

function validateOracle(oracle) {
  if (!oracle || !Array.isArray(oracle.windows) || !Array.isArray(oracle.malformed_units) || !Array.isArray(oracle.source_limitations)) throw failure("oracle_invalid", "The read-model ordering oracle has an invalid shape", "read_oracle");
  const starts = oracle.windows.map(window => window?.start);
  if (JSON.stringify(starts) !== JSON.stringify([0, 6, 12])) throw failure("oracle_windows_invalid", "The read-model oracle does not cover the pinned zoom windows", "read_oracle", {starts});
  for (const window of oracle.windows) {
    if (!Array.isArray(window.clusters) || window.clusters.some(cluster => typeof cluster?.key !== "string" || !Array.isArray(cluster.members) || cluster.members.some(id => typeof id !== "string"))) throw failure("oracle_clusters_invalid", "The read-model oracle contains an invalid cluster", "read_oracle", {start: window.start});
  }
  if (oracle.malformed_units.some(unit => typeof unit?.logical_id !== "string" || !Array.isArray(unit.attempts) || !Array.isArray(unit.limitations) || !Array.isArray(unit.raw_unknown_values))) throw failure("oracle_units_invalid", "The read-model oracle contains an invalid malformed Unit", "read_oracle");
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
    await new Promise(resolve => setTimeout(resolve, 50));
  }
  const diagnostics = await evaluate(client, sessionId, `({hash: location.hash, text: document.body.textContent.slice(0, 1600), clusters: document.querySelectorAll('.cluster-card').length, units: document.querySelectorAll('.unit-card').length})`, `${stage}_diagnostics`);
  throw failure("browser_assertion_timeout", "Browser did not converge", stage, {diagnostics});
}

async function navigateAndAssert(client, sessionId, hash, expression, stage, timeoutMs) {
  await evaluate(client, sessionId, `location.hash = ${JSON.stringify(hash)}; true`, `${stage}_navigate`);
  await waitForBrowser(client, sessionId, `location.hash === ${JSON.stringify(hash)} && (${expression})`, stage, timeoutMs);
}

async function stopChild(child) {
  const stopped = () => !child || child.exitCode !== null || child.signalCode !== null;
  if (stopped()) return true;
  child.kill("SIGTERM");
  await Promise.race([new Promise(resolve => child.once("exit", resolve)), new Promise(resolve => setTimeout(resolve, 1_000))]);
  if (!stopped()) { child.kill("SIGKILL"); await Promise.race([new Promise(resolve => child.once("exit", resolve)), new Promise(resolve => setTimeout(resolve, 1_000))]); }
  return stopped();
}

function titleCase(value) {
  return String(value ?? "unknown").replaceAll("_", " ");
}

function projectedFieldText(value) {
  return value === null || value === undefined ? "" : String(value);
}

async function malformedScaleStory(client, sessionId, options, oracle, securityErrors) {
  const runHash = `#/runs/${encodeURIComponent(options.run_id)}`;
  let maximumClusterCards = 0;
  let maximumUnitCards = 0;
  let orderingMatches = true;
  let sourceAggregateLimitationVisible = true;

  for (const window of oracle.windows) {
    const windowHash = runHash + (window.start > 0 ? `?zoom=${window.start}` : "");
    await navigateAndAssert(client, sessionId, windowHash, `document.querySelector('.detail-view .semantic-zoom') && !document.querySelector('.error-view')`, `zoom_window_${window.start}`, options.browser_timeout_ms);
    const sourceLimitationText = await evaluate(client, sessionId, `document.querySelector('.semantic-zoom > .provenance')?.textContent || ""`, `zoom_window_${window.start}_source_limitations`);
    const expectedSourceLimitations = oracle.source_limitations.map(titleCase);
    const sourceLimitationsVisible = expectedSourceLimitations.every(copy => sourceLimitationText.includes(copy));
    sourceAggregateLimitationVisible = sourceAggregateLimitationVisible && sourceLimitationsVisible;
    if (!sourceLimitationsVisible) throw failure("source_limitation_missing", "The run-scoped aggregate malformed-timestamp limitation was not rendered with projection-derived copy", `zoom_window_${window.start}_source_limitations`, {expected: expectedSourceLimitations, observed: sourceLimitationText});
    const bounds = await evaluate(client, sessionId, `({clusters: document.querySelectorAll('.cluster-overview .cluster-card').length, units: document.querySelectorAll('.cluster-inspector .unit-card').length})`, `zoom_window_${window.start}_bounds`);
    maximumClusterCards = Math.max(maximumClusterCards, bounds.clusters);
    maximumUnitCards = Math.max(maximumUnitCards, bounds.units);
    if (bounds.clusters !== window.entity_count || bounds.units !== 0) throw failure("cluster_dom_unbounded", "The unselected zoom window did not render exactly the oracle's window entities at cluster-level bounds", `zoom_window_${window.start}_bounds`, {bounds, oracle_entities: window.entity_count});

    for (const cluster of window.clusters) {
      const params = new URLSearchParams();
      if (window.start > 0) params.set("zoom", String(window.start));
      params.set("cluster", cluster.key);
      const memberPage = Math.max(1, Math.ceil(cluster.members.length / 12));
      if (memberPage > 1) params.set("members", String(memberPage));
      const clusterHash = `${runHash}?${params.toString()}`;
      await navigateAndAssert(client, sessionId, clusterHash, `document.querySelector('.cluster-inspector') && document.querySelectorAll('.cluster-inspector .unit-card').length === ${cluster.members.length} && !document.querySelector('.error-view')`, `cluster_${window.start}_${cluster.key}`, options.browser_timeout_ms);
      const observed = await evaluate(client, sessionId, `Array.from(document.querySelectorAll('.cluster-inspector .unit-card')).map(node => node.dataset.unitId)`, `cluster_${window.start}_${cluster.key}_order`);
      maximumClusterCards = Math.max(maximumClusterCards, await evaluate(client, sessionId, `document.querySelectorAll('.cluster-overview .cluster-card').length`, `cluster_${window.start}_${cluster.key}_cards`));
      maximumUnitCards = Math.max(maximumUnitCards, observed.length);
      if (JSON.stringify(observed) !== JSON.stringify(cluster.members)) {
        orderingMatches = false;
        throw failure("member_order_mismatch", "Selected-cluster Unit order diverged from the Elixir read-model oracle", `cluster_${window.start}_${cluster.key}_order`, {cluster: cluster.key, expected: cluster.members, observed});
      }
      if (observed.length >= 500) throw failure("unit_dom_unbounded", "A selected cluster rendered the full 500-Unit graph", `cluster_${window.start}_${cluster.key}_bounds`, {rendered_units: observed.length});
    }
  }

  let malformedValuesInert = true;
  let projectionLimitationsPresent = true;
  for (const unit of oracle.malformed_units) {
    const unitHash = `${runHash}/units/${encodeURIComponent(unit.logical_id)}`;
    await navigateAndAssert(client, sessionId, unitHash, `document.querySelector('.unit-view') && !document.querySelector('.error-view')`, `malformed_unit_${unit.logical_id}`, options.browser_timeout_ms);
    const observed = await evaluate(client, sessionId, `(() => {
      const field = (root, label) => Array.from(root.querySelectorAll('.field')).find(node => node.querySelector(':scope > dt')?.textContent === label)?.querySelector(':scope > dd') || null;
      const root = document.querySelector('.unit-view');
      const attempts = Array.from(root.querySelectorAll('.attempt-card')).map(card => ({attemptId: card.dataset.attemptId, started: field(card, "Started")?.textContent ?? null, ended: field(card, "Ended")?.textContent ?? null, startedElements: field(card, "Started")?.childElementCount ?? -1, endedElements: field(card, "Ended")?.childElementCount ?? -1, limitations: Array.from(card.querySelectorAll(':scope > .limitation')).map(node => node.textContent), limitationElements: Array.from(card.querySelectorAll(':scope > .limitation')).map(node => node.childElementCount)}));
      const limitationNodes = Array.from(root.querySelectorAll('.limitations-panel li'));
      return {executionKind: field(root.querySelector('.run-overview'), "Execution kind")?.textContent ?? null, workspace: field(root.querySelector('.run-overview'), "Workspace")?.textContent ?? null, posture: field(root.querySelector('.run-overview'), "Posture")?.textContent ?? null, executionKindElements: field(root.querySelector('.run-overview'), "Execution kind")?.childElementCount ?? -1, workspaceElements: field(root.querySelector('.run-overview'), "Workspace")?.childElementCount ?? -1, postureElements: field(root.querySelector('.run-overview'), "Posture")?.childElementCount ?? -1, attempts, limitations: limitationNodes.map(node => node.textContent), limitationElements: limitationNodes.map(node => node.childElementCount), scripts: root.querySelectorAll('script').length};
    })()`, `malformed_unit_${unit.logical_id}_fields`);

    const expectedAttempts = unit.attempts.map(attempt => ({attemptId: attempt.attempt_id, started: projectedFieldText(attempt.started_at), ended: projectedFieldText(attempt.ended_at), limitations: attempt.limitations.map(titleCase)}));
    const observedAttempts = observed.attempts.map(attempt => ({attemptId: attempt.attemptId, started: attempt.started, ended: attempt.ended, limitations: attempt.limitations}));
    const expectedLimitations = unit.limitations.map(titleCase);
    const rawUnknownCopies = unit.raw_unknown_values.map(titleCase);
    const inert = observed.executionKind === "unknown" && observed.workspace === "unknown" && observed.posture === "unknown" && observed.executionKind === unit.execution_kind && observed.workspace === unit.workspace_mode && observed.posture === unit.posture && observed.executionKindElements === 0 && observed.workspaceElements === 0 && observed.postureElements === 0 && observed.limitationElements.every(count => count === 0) && observed.attempts.every(attempt => attempt.started === "" && attempt.ended === "" && attempt.startedElements === 0 && attempt.endedElements === 0 && attempt.limitationElements.every(count => count === 0)) && observed.scripts === 0 && rawUnknownCopies.every(copy => observed.limitations.some(limitation => limitation.includes(copy))) && JSON.stringify(observedAttempts.map(({attemptId, started, ended}) => ({attemptId, started, ended}))) === JSON.stringify(expectedAttempts.map(({attemptId, started, ended}) => ({attemptId, started, ended})));
    // Subset, not set-equality: the unit legitimately carries other projection
    // limitations (e.g. child log missing) beside the malformed-field confessions.
    const exactLimitations = expectedLimitations.length + expectedAttempts.reduce((count, attempt) => count + attempt.limitations.length, 0) > 0 && expectedLimitations.every(copy => observed.limitations.includes(copy)) && expectedAttempts.every((attempt, index) => attempt.limitations.every(copy => (observedAttempts[index]?.limitations || []).includes(copy)));
    malformedValuesInert = malformedValuesInert && inert;
    projectionLimitationsPresent = projectionLimitationsPresent && exactLimitations;
    if (!inert) throw failure("malformed_value_not_inert", "A malformed projected value did not remain exact textContent-only output", `malformed_unit_${unit.logical_id}_inert`, {observed});
    if (!exactLimitations) throw failure("malformed_limitation_mismatch", "Malformed-field limitation copy from the projection oracle was not present in the rendered view", `malformed_unit_${unit.logical_id}_limitations`, {expected_unit: expectedLimitations, expected_attempts: expectedAttempts.map(attempt => attempt.limitations), observed_unit: observed.limitations, observed_attempts: observedAttempts.map(attempt => attempt.limitations)});
  }

  if (securityErrors.length) throw failure("browser_security_error", "The browser reported a console, runtime, or security error during the malformed scale sweep", "security_console", {count: securityErrors.length, first: securityErrors[0]});
  return {windowsChecked: oracle.windows.map(window => window.start), malformedUnitsChecked: oracle.malformed_units.length, orderingMatches, malformedValuesInert, projectionLimitationsPresent, sourceAggregateLimitationVisible, maximumClusterCards, maximumUnitCards};
}

async function run(options) {
  const profile = await mkdtemp(join(options.profile_base, "pixir-monitor-malformed-scale-"));
  let browser = null;
  let monitor = null;
  let client = null;
  let browserContextId = null;
  let fifoPath = null;
  let result = null;
  let runError = null;
  try {
    const oracle = JSON.parse(await readFile(options.oracle_file, "utf8"));
    validateOracle(oracle);
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
    let launchUrl = (await withTimeout(readFile(fifoPath, "utf8"), 15_000, "fifo_reader_timeout", "Monitor did not issue browser handoff", "read_handoff")).trim();
    const launchUri = new URL(launchUrl);
    const target = await client.send("Target.createTarget", {url: "about:blank", browserContextId}, null, "create_page");
    launchUrl = "";
    const sessionId = (await client.send("Target.attachToTarget", {targetId: target.targetId, flatten: true}, null, "attach_target")).sessionId;
    const securityErrors = [];
    client.onEvent(message => {
      if (message.sessionId !== sessionId) return;
      // Mirror the bench gate's discipline (semantic_zoom_gate.mjs:156-159):
      // runtime exceptions always count; console/log entries count only at
      // error level AND matching the security pattern — Chrome emits benign
      // security-source warnings (Permissions-Policy) on every navigation, and
      // the read-only surface answering 405 to non-GET probes is honest, not a
      // security failure.
      const securityPattern = /(script|content security|csp|trusted types|xss|unsafe|injection)/i;
      if (message.method === "Runtime.exceptionThrown") securityErrors.push({kind: "runtime_exception", text: message.params?.exceptionDetails?.text || "exception"});
      if (message.method === "Runtime.consoleAPICalled" && ["error", "assert"].includes(message.params?.type) && securityPattern.test((message.params?.args || []).map(arg => String(arg?.value ?? "")).join(" "))) securityErrors.push({kind: "console", type: message.params.type});
      if (message.method === "Log.entryAdded" && message.params?.entry?.level === "error" && securityPattern.test(String(message.params?.entry?.text || ""))) securityErrors.push({kind: "log", source: message.params.entry.source, level: message.params.entry.level, text: message.params.entry.text});
    });
    await client.send("Runtime.enable", {}, sessionId, "enable_runtime");
    await client.send("Log.enable", {}, sessionId, "enable_log");
    await client.send("Page.enable", {}, sessionId, "enable_page");
    await client.send("Page.navigate", {url: launchUri.href}, sessionId, "bootstrap_navigation");
    await waitForBrowser(client, sessionId, `document.title === "Pixir Monitor" && !location.hash.startsWith("#launch=") && Boolean(document.querySelector('.view'))`, "initial_view", options.browser_timeout_ms);
    const launchFragmentCleared = await evaluate(client, sessionId, `!location.hash.startsWith("#launch=")`, "launch_fragment_cleared");
    const story = await malformedScaleStory(client, sessionId, options, oracle, securityErrors);
    await serving;
    const handoffCleaned = !existsSync(fifoPath) && !existsSync(dirname(fifoPath));
    if (!handoffCleaned) throw failure("handoff_cleanup_failed", "The one-use FIFO was not removed", "verify_cleanup");
    if (!launchFragmentCleared) throw failure("launch_fragment_not_cleared", "Launch capability remained in the browser fragment", "verify_launch_fragment");
    result = {ok: story.orderingMatches && story.malformedValuesInert && story.projectionLimitationsPresent && story.sourceAggregateLimitationVisible && securityErrors.length === 0, check: "pixir_monitor_malformed_scale", windows_checked: story.windowsChecked, malformed_units_checked: story.malformedUnitsChecked, ordering_matches_read_model: story.orderingMatches, malformed_values_inert: story.malformedValuesInert, projection_limitations_present: story.projectionLimitationsPresent, source_aggregate_limitation_visible: story.sourceAggregateLimitationVisible, maximum_cluster_cards: story.maximumClusterCards, maximum_unit_cards: story.maximumUnitCards, console_security_errors: securityErrors.length, launch_fragment_cleared: launchFragmentCleared === true, handoff_cleaned: handoffCleaned};
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
