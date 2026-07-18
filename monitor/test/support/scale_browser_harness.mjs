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
  return {ok: false, error: {kind: error?.harnessKind || "scale_browser_harness_failed", message: error?.harnessKind ? error.message : "The scale browser harness failed unexpectedly", details: {stage: error?.harnessStage || "unknown", ...(error?.safeDetails || {})}}};
}

function parseArgs(argv) {
  const options = {browser_timeout_ms: 60_000};
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === "--json") continue;
    if (["--monitor", "--workspace", "--browser", "--profile-base", "--cap-run-id", "--at-cap-unit-id", "--over-cap-unit-id", "--expansion-cap-unit-id", "--browser-timeout-ms"].includes(arg)) options[arg.slice(2).replaceAll("-", "_")] = argv[++index];
    else throw failure("invalid_args", "Unknown or incomplete scale browser harness argument", "parse_args");
  }
  return options;
}

function validate(options) {
  for (const field of ["monitor", "workspace", "browser", "profile_base", "cap_run_id", "at_cap_unit_id", "over_cap_unit_id", "expansion_cap_unit_id"]) {
    if (!options[field]) throw failure("missing_required_arg", `Missing required --${field.replaceAll("_", "-")}`, "validate_args");
  }
  for (const field of ["monitor", "workspace", "browser", "profile_base"]) {
    if (!existsSync(options[field])) throw failure(`${field}_missing`, `Required ${field.replaceAll("_", " ")} is missing`, "validate_inputs");
  }
  if (typeof WebSocket !== "function") throw failure("node_websocket_unavailable", "Node.js does not provide WebSocket", "validate_runtime");
  options.browser_timeout_ms = Number(options.browser_timeout_ms);
  if (!Number.isSafeInteger(options.browser_timeout_ms) || options.browser_timeout_ms < 1_000 || options.browser_timeout_ms > 120_000) throw failure("invalid_browser_timeout", "--browser-timeout-ms must be 1000..120000", "validate_args");
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
  const rejectPending = () => { for (const [id, waiter] of pending) { pending.delete(id); waiter.reject(failure("devtools_connection_closed", "Chrome DevTools closed", waiter.stage)); } };
  socket.addEventListener("message", event => {
    const message = JSON.parse(event.data);
    const waiter = pending.get(message.id);
    if (!waiter) return;
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
  const diagnostics = await evaluate(client, sessionId, `({hash: location.hash, text: document.body.textContent.slice(0, 1200), rows: document.querySelectorAll('.runs-table tbody tr').length})`, `${stage}_diagnostics`);
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

async function scaleStory(client, sessionId, options) {
  const exactInventory = "Scanned inventory: 512 selected of 513 Session Logs · projected runs: 512 · non-run Logs: 0 · unprojected selected Logs: 0 · truncated: yes.";
  await waitForBrowser(client, sessionId, `location.hash === "#/runs" && document.querySelector('.runs-view') && document.querySelectorAll('.runs-table tbody tr').length === 50 && document.querySelector('.inventory-summary')?.textContent === ${JSON.stringify(exactInventory)} && document.querySelector('.inventory-notice p')?.textContent === "Newest 512 of 513 Session Logs selected." && document.querySelector('.inventory-limitations strong')?.textContent === "run_inventory_truncated"`, "initial_scale_inventory", options.browser_timeout_ms);

  let shown = 50;
  while (shown < 512) {
    const remaining = 512 - shown;
    const reveal = Math.min(50, remaining);
    const exactContinuation = `Show next ${reveal} Recent runs (${shown} of 512 shown, ${remaining} remaining)`;
    const observedContinuation = await evaluate(client, sessionId, `document.querySelector('.run-group .continuation')?.textContent || null`, `continuation_${shown}_text`);
    if (observedContinuation !== exactContinuation) throw failure("continuation_arithmetic_failed", "Run continuation did not confess the exact next-page arithmetic", `continuation_${shown}_text`, {expected: exactContinuation, observed: observedContinuation});
    const clicked = await evaluate(client, sessionId, `(() => { const node = document.querySelector('.run-group .continuation'); if (!node) return false; node.click(); return true; })()`, `advance_runs_${shown}`);
    if (!clicked) throw failure("continuation_missing", "Run continuation disappeared before all selected rows were shown", `advance_runs_${shown}`);
    const expectedShown = shown + reveal;
    await waitForBrowser(client, sessionId, `document.querySelectorAll('.runs-table tbody tr').length === ${expectedShown}`, `advance_runs_${shown}_render`, options.browser_timeout_ms);
    shown = expectedShown;
  }
  const paginationComplete = await evaluate(client, sessionId, `document.querySelectorAll('.runs-table tbody tr').length === 512 && !document.querySelector('.run-group .continuation')`, "advance_runs_complete");
  if (!paginationComplete) throw failure("pagination_total_failed", "The final page did not show all 512 rows with no continuation remaining", "advance_runs_complete");

  const capHash = `#/runs/${encodeURIComponent(options.cap_run_id)}`;
  await navigateAndAssert(client, sessionId, capHash, `document.querySelector('.detail-view') && !document.querySelector('.error-view')`, "cap_run_detail", options.browser_timeout_ms);

  const atCapHash = `${capHash}/units/${encodeURIComponent(options.at_cap_unit_id)}`;
  await navigateAndAssert(client, sessionId, atCapHash, `document.querySelector('.unit-view') && !document.querySelector('.error-view')`, "pure_32768_boundary", options.browser_timeout_ms);
  await waitForBrowser(client, sessionId, `(() => { const field = Array.from(document.querySelectorAll('.unit-view .field')).find(node => node.querySelector('dt')?.textContent === "Agent"); return field?.querySelector('dd')?.textContent === "A".repeat(32768) && !field.querySelector('.truncation'); })()`, "pure_32768_full_without_confession", options.browser_timeout_ms);

  const overCapHash = `${capHash}/units/${encodeURIComponent(options.over_cap_unit_id)}`;
  await navigateAndAssert(client, sessionId, overCapHash, `document.querySelector('.unit-view') && !document.querySelector('.error-view')`, "pure_32769_boundary", options.browser_timeout_ms);
  const overCapConfession = "Visible preview limited to 32 KiB (32769 source characters).";
  await waitForBrowser(client, sessionId, `(() => { const field = Array.from(document.querySelectorAll('.unit-view .field')).find(node => node.querySelector('dt')?.textContent === "Agent"); return field?.querySelector('dd')?.textContent === "B".repeat(32768) && field.querySelector('.truncation')?.textContent === ${JSON.stringify(overCapConfession)}; })()`, "pure_32769_confession", options.browser_timeout_ms);

  const expansionHash = `${capHash}/units/${encodeURIComponent(options.expansion_cap_unit_id)}`;
  await navigateAndAssert(client, sessionId, expansionHash, `document.querySelector('.unit-view') && !document.querySelector('.error-view')`, "control_expansion_at_raw_cap_unit", options.browser_timeout_ms);
  const expansionConfession = "Visible preview limited to 32 KiB (32768 source characters).";
  await waitForBrowser(client, sessionId, `(() => { const field = Array.from(document.querySelectorAll('.unit-view .field')).find(node => node.querySelector('dt')?.textContent === "Agent"); return field?.querySelector('.truncation')?.textContent === ${JSON.stringify(expansionConfession)} && typeof window.__pixirScaleInjected === "undefined" && !document.querySelector('script[data-pixir-scale-hostile]') && !document.querySelector('.error-view'); })()`, "control_expansion_honesty_at_raw_cap", options.browser_timeout_ms);

  return ["every_continuation_exact_through_final_12", "all_512_rows_and_no_continuation_remaining", "inventory_512_of_513_confessed", "pure_32768_full_without_confession", "pure_32769_confessed", "control_expansion_honesty_at_raw_cap"];
}

async function run(options) {
  const profile = await mkdtemp(join(options.profile_base, "pixir-monitor-scale-"));
  let browser = null;
  let monitor = null;
  let client = null;
  let browserContextId = null;
  let fifoPath = null;
  let result = null;
  let runError = null;
  try {
    browser = spawn(options.browser, ["--headless=new", "--disable-background-networking", "--disable-component-update", "--disable-default-apps", "--disable-sync", "--metrics-recording-only", "--no-first-run", "--no-default-browser-check", "--remote-debugging-port=0", ...extraBrowserArgs(), `--user-data-dir=${profile}`, "about:blank"], {stdio: ["ignore", "ignore", "pipe"]});
    client = await connectDevTools(await waitForDevTools(browser.stderr));
    browserContextId = (await client.send("Target.createBrowserContext", {disposeOnDetach: true}, null, "create_browser_context")).browserContextId;
    monitor = spawn(options.monitor, ["serve", "--workspace", options.workspace, "--launch-mode", "fifo", "--json"], {stdio: ["ignore", "pipe", "pipe"]});
    const serving = waitForJsonLine(monitor.stdout, value => value?.ok === true && value?.status === "serving", "monitor_serving", 60_000);
    serving.catch(() => {});
    const readiness = await waitForJsonLine(monitor.stderr, value => value?.ok === true && value?.status === "ready" && value?.launch_mode === "fifo", "monitor_readiness", 45_000);
    fifoPath = readiness.fifo_path;
    let launchUrl = (await withTimeout(readFile(fifoPath, "utf8"), 15_000, "fifo_reader_timeout", "Monitor did not issue browser handoff", "read_handoff")).trim();
    const launchUri = new URL(launchUrl);
    const target = await client.send("Target.createTarget", {url: "about:blank", browserContextId}, null, "create_page");
    launchUrl = "";
    const sessionId = (await client.send("Target.attachToTarget", {targetId: target.targetId, flatten: true}, null, "attach_target")).sessionId;
    await client.send("Runtime.enable", {}, sessionId, "enable_runtime");
    await client.send("Page.enable", {}, sessionId, "enable_page");
    await client.send("Page.navigate", {url: launchUri.href}, sessionId, "bootstrap_navigation");
    await waitForBrowser(client, sessionId, `document.title === "Pixir Monitor" && !location.hash.startsWith("#launch=") && Boolean(document.querySelector('.view'))`, "initial_view", options.browser_timeout_ms);
    const launchFragmentCleared = await evaluate(client, sessionId, `!location.hash.startsWith("#launch=")`, "launch_fragment_cleared");
    const phases = await scaleStory(client, sessionId, options);
    await serving;
    const handoffCleaned = !existsSync(fifoPath) && !existsSync(dirname(fifoPath));
    if (!handoffCleaned) throw failure("handoff_cleanup_failed", "One-use FIFO was not removed", "verify_cleanup");
    if (!launchFragmentCleared) throw failure("launch_fragment_not_cleared", "Launch capability remained in the browser fragment", "verify_launch_fragment");
    result = {ok: true, check: "pixir_monitor_scale", phases, browser: "chrome_devtools_protocol", launch_fragment_cleared: launchFragmentCleared === true, handoff_cleaned: true};
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
