#!/usr/bin/env node

import {spawn} from "node:child_process";
import {existsSync} from "node:fs";
import {mkdtemp, readFile, rm} from "node:fs/promises";
import {tmpdir} from "node:os";
import {dirname, join} from "node:path";
import {createInterface} from "node:readline";
import {extraBrowserArgs} from "./chrome_args.mjs";

const HELP = `Usage: node browser_harness.mjs [options]

Runs a bounded real-browser regression against the built Pixir Monitor escript,
including the route-backed Follow/refetch story from issue #334.
The one-use launch capability is sent to Chrome over DevTools Protocol and never
appears in process argv, output, or a persisted file created by this harness.

Required:
  --monitor PATH       Built pixir-monitor escript
  --workspace PATH     Isolated workspace containing the fixture Log
  --run-id ID          Expected run id
  --unit-id ID         Expected projected logical unit id
  --browser PATH       Chrome/Chromium-compatible executable
  --browser-timeout-ms N
                       Per-view convergence timeout (250..30000, default 12000)

Modes:
  --dry-run            Validate inputs without starting Monitor or Chrome
  --exercise-cdp-crash Kill Chrome with a command in flight to prove bounded cleanup
  --exercise-unit-timeout
                       Force a Unit-view convergence timeout to prove cleanup
  --json               Emit one structured JSON result (default)
  --help               Show this help
`;

// Installed before the real page loads. It only records bounded local browser
// observations and can replace authoritative HTTP response bodies with explicit
// deterministic test variants. It never reads or emits capability, cookie, Log,
// workspace, or provider bytes.
const PRELOAD_SCRIPT = `(() => {
  const control = {fetches: [], mode: null, release: null, event_source: null, hashes: []};
  window.__pixirBrowserHarness = control;
  window.addEventListener("hashchange", () => control.hashes.push(location.hash));
  const nativeFetch = window.fetch.bind(window);
  window.fetch = async function(input, init) {
    const url = new URL(typeof input === "string" ? input : input.url, location.href);
    const response = await nativeFetch(input, init);
    // This records network completion; delayed/transformed response visibility
    // happens only after the interception below releases the Fetch promise.
    control.fetches.push(url.pathname);
    if (!url.pathname.startsWith("/api/runs") || !control.mode) return response;
    if (control.mode === "transient_failure") {
      control.mode = null;
      return new Response(JSON.stringify({error: {kind: "projection_http_failed", message: "deterministic transient failure"}}), {status: 503, headers: {"content-type": "application/json"}});
    }
    if (control.mode === "identity_disappeared") {
      control.mode = null;
      return new Response(JSON.stringify({error: {kind: "run_not_found", message: "deterministic followed identity loss"}}), {status: 404, headers: {"content-type": "application/json"}});
    }
    if (control.mode === "delay_detail") {
      control.mode = null;
      await new Promise(resolve => { control.release = resolve; });
    }
    let payload;
    try { payload = await response.clone().json(); } catch (_error) { return response; }
    if (control.mode === "title_update") {
      payload.run = {...payload.run, title: "Followed run authoritative update"};
    } else if (control.mode === "terminal") {
      payload.execution = {...(payload.execution || {}), terminal: true, state: "completed", basis: "browser_harness"};
    } else if (control.mode === "owner_unavailable") {
      payload.liveness = {...(payload.liveness || {}), state: "owner_unavailable", basis: "browser_harness"};
    } else if (control.mode === "missing_unit") {
      payload.units = [];
    }
    return new Response(JSON.stringify(payload), {status: response.status, headers: {"content-type": "application/json"}});
  };
  const NativeEventSource = window.EventSource;
  window.EventSource = function(...args) {
    const source = new NativeEventSource(...args);
    control.event_source = source;
    return source;
  };
  window.EventSource.prototype = NativeEventSource.prototype;
})();`;

function parseArgs(argv) {
  const options = {json: true, dryRun: false, browser_timeout_ms: 12_000};
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === "--help") options.help = true;
    else if (arg === "--dry-run") options.dryRun = true;
    else if (arg === "--exercise-cdp-crash") options.exerciseCdpCrash = true;
    else if (arg === "--exercise-unit-timeout") options.exerciseUnitTimeout = true;
    else if (arg === "--json") options.json = true;
    else if (["--monitor", "--workspace", "--run-id", "--unit-id", "--browser", "--browser-timeout-ms"].includes(arg)) options[arg.slice(2).replaceAll("-", "_")] = argv[++index];
    else throw failure("invalid_args", "Unknown or incomplete browser harness argument", "parse_args");
  }
  return options;
}

function failure(kind, message, stage, details = {}) {
  const error = new Error(message);
  error.harnessKind = kind;
  error.harnessStage = stage;
  error.safeDetails = details;
  return error;
}

function safeError(error) {
  return {
    ok: false,
    error: {
      kind: error?.harnessKind || "browser_harness_failed",
      message: error?.harnessKind ? error.message : "The browser regression harness failed unexpectedly",
      details: {stage: error?.harnessStage || "unknown", ...(error?.safeDetails || {})},
      next_actions: ["Run with --dry-run --json", "Verify the built escript and browser executable", "Re-run the focused ExUnit browser test"]
    }
  };
}

function validate(options) {
  for (const field of ["monitor", "workspace", "run_id", "unit_id", "browser"]) {
    if (!options[field]) throw failure("missing_required_arg", `Missing required --${field.replaceAll("_", "-")}`, "validate_args");
  }
  if (!existsSync(options.monitor)) throw failure("monitor_missing", "Built pixir-monitor escript is missing", "validate_inputs");
  if (!existsSync(options.workspace)) throw failure("workspace_missing", "Browser fixture workspace is missing", "validate_inputs");
  if (!existsSync(options.browser)) throw failure("browser_missing", "Chrome/Chromium executable is missing", "validate_inputs");
  if (typeof WebSocket !== "function") throw failure("node_websocket_unavailable", "Node.js does not provide the WebSocket client required for DevTools Protocol", "validate_runtime", {minimum_node_major: 22});
  options.browser_timeout_ms = Number(options.browser_timeout_ms);
  if (!Number.isSafeInteger(options.browser_timeout_ms) || options.browser_timeout_ms < 250 || options.browser_timeout_ms > 30_000) throw failure("invalid_browser_timeout", "--browser-timeout-ms must be an integer from 250 through 30000", "validate_args");
}

function waitForJsonLine(stream, predicate, stage, timeoutMs = 15_000) {
  return new Promise((resolve, reject) => {
    const lines = createInterface({input: stream});
    let settled = false;
    const timeout = setTimeout(() => finish(reject, failure("process_readiness_timeout", "A child process did not emit its bounded readiness record", stage)), timeoutMs);
    const finish = (callback, value) => {
      if (settled) return;
      settled = true;
      clearTimeout(timeout);
      lines.close();
      callback(value);
    };
    lines.on("line", line => {
      try {
        const value = JSON.parse(line);
        if (predicate(value)) finish(resolve, value);
      } catch (_error) {}
    });
    lines.on("close", () => finish(reject, failure("process_readiness_stream_closed", "A child process closed its readiness stream before emitting the expected record", stage)));
  });
}

function waitForDevTools(stream, timeoutMs = 15_000) {
  return new Promise((resolve, reject) => {
    const lines = createInterface({input: stream});
    let settled = false;
    const timeout = setTimeout(() => finish(reject, failure("browser_readiness_timeout", "Chrome did not expose its DevTools endpoint", "start_browser")), timeoutMs);
    const finish = (callback, value) => {
      if (settled) return;
      settled = true;
      clearTimeout(timeout);
      lines.close();
      callback(value);
    };
    lines.on("line", line => {
      const match = line.match(/DevTools listening on (ws:\/\/127\.0\.0\.1:\d+\/devtools\/browser\/[A-Za-z0-9-]+)/);
      if (match) finish(resolve, match[1]);
    });
    lines.on("close", () => finish(reject, failure("browser_readiness_stream_closed", "Chrome closed its readiness stream before exposing DevTools", "start_browser")));
  });
}

function withTimeout(promise, timeoutMs, kind, message, stage) {
  return new Promise((resolve, reject) => {
    const timeout = setTimeout(() => reject(failure(kind, message, stage)), timeoutMs);
    Promise.resolve(promise).then(
      value => {
        clearTimeout(timeout);
        resolve(value);
      },
      error => {
        clearTimeout(timeout);
        reject(error);
      }
    );
  });
}

async function connectDevTools(url) {
  const socket = new WebSocket(url);
  await withTimeout(new Promise((resolve, reject) => {
    socket.addEventListener("open", resolve, {once: true});
    socket.addEventListener("error", reject, {once: true});
  }), 10_000, "devtools_connect_timeout", "Could not connect to the local Chrome DevTools endpoint", "connect_browser");

  let nextId = 1;
  const pending = new Map();
  const rejectPending = (kind, message) => {
    for (const [id, waiter] of pending) {
      pending.delete(id);
      waiter.reject(failure(kind, message, waiter.stage));
    }
  };
  socket.addEventListener("message", event => {
    const message = JSON.parse(event.data);
    const waiter = pending.get(message.id);
    if (!waiter) return;
    pending.delete(message.id);
    if (message.error) waiter.reject(failure("devtools_command_failed", "A Chrome DevTools command failed", waiter.stage, {code: message.error.code}));
    else waiter.resolve(message.result);
  });
  socket.addEventListener("close", () => rejectPending("devtools_connection_closed", "The Chrome DevTools connection closed before a command completed"));
  socket.addEventListener("error", () => rejectPending("devtools_connection_failed", "The Chrome DevTools connection failed before a command completed"));

  return {
    send(method, params = {}, sessionId = null, stage = "browser_command") {
      if (socket.readyState !== WebSocket.OPEN) {
        return Promise.reject(failure("devtools_connection_closed", "The Chrome DevTools connection is not open", stage));
      }
      const id = nextId++;
      return withTimeout(new Promise((resolve, reject) => {
        const settle = callback => value => {
          pending.delete(id);
          callback(value);
        };
        pending.set(id, {resolve: settle(resolve), reject: settle(reject), stage});
        try {
          socket.send(JSON.stringify({id, method, params, ...(sessionId ? {sessionId} : {})}));
        } catch (_error) {
          pending.delete(id);
          reject(failure("devtools_send_failed", "A Chrome DevTools command could not be sent", stage));
        }
      }), 10_000, "devtools_command_timeout", "A Chrome DevTools command did not complete within its bound", stage)
        .finally(() => pending.delete(id));
    },
    close() { socket.close(); }
  };
}

async function evaluate(client, sessionId, expression, stage) {
  const result = await client.send("Runtime.evaluate", {expression, returnByValue: true, awaitPromise: true}, sessionId, stage);
  if (result.exceptionDetails) throw failure("browser_expression_failed", "A bounded browser assertion expression failed", stage);
  return result.result?.value;
}

async function waitForBrowser(client, sessionId, expression, stage, timeoutMs) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (await evaluate(client, sessionId, expression, stage)) return;
    await new Promise(resolve => setTimeout(resolve, 50));
  }
  const diagnostics = ["cross_run_navigation_after_identity_loss_cleared", "cross_run_navigation_recovered", "classified_render_failure"].includes(stage)
    ? await evaluate(client, sessionId, `({hash: location.hash, release: window.__pixirBrowserHarness.release !== null, retry: Boolean(document.querySelector('.follow-retry')), error_classes: Array.from(document.querySelectorAll('.error-view')).map(node => node.className), detail: Boolean(document.querySelector('.detail-view')), follow: Boolean(document.querySelector('.follow-panel[data-follow-state="following"]')), status: document.getElementById("status")?.textContent || "", body_length: document.body.textContent.length, fetches: window.__pixirBrowserHarness.fetches.slice(-6), hashes: window.__pixirBrowserHarness.hashes.slice(-4)})`, `${stage}_diagnostics`)
    : undefined;
  throw failure("browser_assertion_timeout", "The browser did not converge to the expected safe UI state", stage, diagnostics ? {diagnostics} : {});
}

async function stopChild(child) {
  const stopped = () => !child || child.exitCode !== null || child.signalCode !== null;
  if (stopped()) return true;
  child.kill("SIGTERM");
  await Promise.race([
    new Promise(resolve => child.once("exit", resolve)),
    new Promise(resolve => setTimeout(resolve, 1_000))
  ]);
  if (!stopped()) {
    child.kill("SIGKILL");
    await Promise.race([
      new Promise(resolve => child.once("exit", resolve)),
      new Promise(resolve => setTimeout(resolve, 1_000))
    ]);
  }
  return stopped();
}

async function run(options) {
  const profile = await mkdtemp(join(tmpdir(), "pixir-monitor-browser-"));
  let browser = null;
  let monitor = null;
  let client = null;
  let browserContextId = null;
  let fifoPath = null;
  let runError = null;
  let runResult = null;

  try {
    browser = spawn(options.browser, [
      "--headless=new",
      "--disable-background-networking",
      "--disable-component-update",
      "--disable-default-apps",
      "--disable-sync",
      "--metrics-recording-only",
      "--no-first-run",
      "--no-default-browser-check",
      "--remote-debugging-port=0",
      ...extraBrowserArgs(),
      `--user-data-dir=${profile}`,
      "about:blank"
    ], {stdio: ["ignore", "ignore", "pipe"]});

    const devToolsUrl = await waitForDevTools(browser.stderr);
    client = await connectDevTools(devToolsUrl);
    browserContextId = (await client.send("Target.createBrowserContext", {disposeOnDetach: true}, null, "create_browser_context")).browserContextId;

    monitor = spawn(options.monitor, ["serve", "--workspace", options.workspace, "--launch-mode", "fifo", "--json"], {stdio: ["ignore", "pipe", "pipe"]});
    const serving = waitForJsonLine(monitor.stdout, value => value?.ok === true && value?.status === "serving", "monitor_serving", 35_000);
    serving.catch(() => {});
    const readiness = await waitForJsonLine(monitor.stderr, value => value?.ok === true && value?.status === "ready" && value?.launch_mode === "fifo", "monitor_readiness");
    fifoPath = readiness.fifo_path;

    let launchUrl = (await withTimeout(readFile(fifoPath, "utf8"), 15_000, "fifo_reader_timeout", "Monitor did not issue its one-use browser handoff", "read_handoff")).trim();
    const launchUri = new URL(launchUrl);
    const origin = launchUri.origin;
    const target = await client.send("Target.createTarget", {url: "about:blank", browserContextId}, null, "create_page");
    launchUrl = "";
    const attached = await client.send("Target.attachToTarget", {targetId: target.targetId, flatten: true}, null, "attach_target");
    const sessionId = attached.sessionId;
    await client.send("Runtime.enable", {}, sessionId, "enable_runtime");
    await client.send("Page.enable", {}, sessionId, "enable_page");
    await client.send("Page.addScriptToEvaluateOnNewDocument", {source: PRELOAD_SCRIPT}, sessionId, "install_browser_harness");
    await client.send("Page.navigate", {url: launchUri.href}, sessionId, "bootstrap_navigation");

    if (options.exerciseCdpCrash) {
      const inFlight = client.send("Runtime.evaluate", {expression: "new Promise(() => {})", awaitPromise: true}, sessionId, "exercise_cdp_crash");
      setTimeout(() => browser.kill("SIGKILL"), 50);
      await inFlight;
      throw failure("cdp_crash_not_observed", "Chrome remained connected during the requested CDP crash exercise", "exercise_cdp_crash");
    }

    await waitForBrowser(client, sessionId, `document.title === "Pixir Monitor" && location.hash.startsWith("#/runs") && !location.hash.startsWith("#launch=") && Boolean(document.querySelector('a[href="#/runs/${options.run_id}"]')) && !document.querySelector('.error-view')`, "runs_view", options.browser_timeout_ms);

    const detailHash = `#/runs/${options.run_id}`;
    const unitHash = `#/runs/${options.run_id}/units/${encodeURIComponent(options.unit_id)}`;
    await evaluate(client, sessionId, `location.hash = ${JSON.stringify(detailHash)}; true`, "navigate_detail");
    await waitForBrowser(client, sessionId, `location.hash === ${JSON.stringify(detailHash)} && Array.from(document.querySelectorAll("a")).some(link => link.getAttribute("href") === ${JSON.stringify(unitHash)}) && !document.querySelector('.error-view')`, "detail_view", options.browser_timeout_ms);

    await evaluate(client, sessionId, `location.hash = ${JSON.stringify(unitHash)}; true`, "navigate_unit");
    const unitExpression = options.exerciseUnitTimeout
      ? "false"
      : `location.hash === ${JSON.stringify(unitHash)} && document.querySelectorAll('.attempt-card').length === 1 && !document.querySelector('.error-view')`;
    await waitForBrowser(client, sessionId, unitExpression, "unit_view", options.browser_timeout_ms);

    const followDetailHash = `${detailHash}?follow=1`;
    const followUnitHash = `${unitHash}?follow=1`;
    const followExpression = `location.hash === ${JSON.stringify(followDetailHash)} && document.querySelector('.follow-panel[data-follow-state="following"]') && document.body.textContent.includes("Following this run")`;
    const triggerInvalidation = async (eventId, data, stage) => {
      const before = await evaluate(client, sessionId, "window.__pixirBrowserHarness.fetches.length", `${stage}_count`);
      await evaluate(client, sessionId, `(() => {
        const source = window.__pixirBrowserHarness.event_source;
        if (!source) throw new Error("SSE source was not captured");
        const event = new MessageEvent("projection_changed", {data: ${JSON.stringify(JSON.stringify(data))}});
        Object.defineProperty(event, "lastEventId", {value: ${JSON.stringify(String(eventId))}});
        source.dispatchEvent(event);
        return true;
      })()`, stage);
      await waitForBrowser(client, sessionId, `window.__pixirBrowserHarness.fetches.length > ${before}`, `${stage}_refetch`, options.browser_timeout_ms);
    };
    const setMode = mode => evaluate(client, sessionId, `window.__pixirBrowserHarness.mode = ${JSON.stringify(mode)}; true`, `set_${mode}`);

    // Route entry/exit plus reload and browser history are exercised against the
    // real built escript before any response fixture is introduced.
    await evaluate(client, sessionId, `location.hash = ${JSON.stringify(followDetailHash)}; true`, "enter_follow");
    await waitForBrowser(client, sessionId, followExpression, "follow_detail", options.browser_timeout_ms);
    const followedUrl = await evaluate(client, sessionId, "location.href", "capture_follow_url");
    await client.send("Page.navigate", {url: followedUrl}, sessionId, "reload_follow");
    await waitForBrowser(client, sessionId, followExpression, "follow_reload", options.browser_timeout_ms);
    await evaluate(client, sessionId, `document.querySelector('[data-focus-key="follow-off"]').click(); true`, "leave_follow");
    await waitForBrowser(client, sessionId, `location.hash === ${JSON.stringify(detailHash)} && document.querySelector('.follow-panel[data-follow-state="not_following"]')`, "follow_left", options.browser_timeout_ms);
    await evaluate(client, sessionId, `document.querySelector('[data-focus-key="follow-on"]').click(); true`, "reenter_follow");
    await waitForBrowser(client, sessionId, followExpression, "follow_reentered", options.browser_timeout_ms);
    await evaluate(client, sessionId, `location.hash = "#/runs"; true`, "history_runs");
    await waitForBrowser(client, sessionId, `location.hash === "#/runs" && !document.querySelector(".follow-panel")`, "history_runs_view", options.browser_timeout_ms);
    await evaluate(client, sessionId, `history.back(); true`, "history_back");
    await waitForBrowser(client, sessionId, followExpression, "history_back_follow", options.browser_timeout_ms);
    await evaluate(client, sessionId, `history.forward(); true`, "history_forward");
    await waitForBrowser(client, sessionId, `location.hash === "#/runs" && !document.querySelector(".follow-panel")`, "history_forward_runs", options.browser_timeout_ms);

    // A detail response is changed only at the HTTP boundary. The test then
    // proves the existing run/unit/attempt view restores focus, disclosures, and
    // scroll after the authoritative refetch.
    await evaluate(client, sessionId, `location.hash = ${JSON.stringify(followUnitHash)}; true`, "follow_unit");
    await waitForBrowser(client, sessionId, `location.hash === ${JSON.stringify(followUnitHash)} && document.querySelectorAll('.attempt-card').length === 1 && document.querySelector('.follow-panel[data-follow-state="following"]')`, "follow_unit_view", options.browser_timeout_ms);
    await evaluate(client, sessionId, `(() => {
      document.body.style.minHeight = "2400px";
      const focus = document.querySelector('[data-focus-key^="attempt-"]');
      const disclosure = document.querySelector('details[data-disclosure-key^="activity:"]');
      if (!focus || !disclosure) throw new Error("follow restoration anchors were not rendered");
      focus.focus(); disclosure.open = true; window.scrollTo(0, 180); return true;
    })()`, "prepare_restoration");
    await setMode("title_update");
    await triggerInvalidation("1", {type: "projection_changed", projection_id: "fixture-follow"}, "authoritative_update");
    await waitForBrowser(client, sessionId, `location.hash === ${JSON.stringify(followUnitHash)} && document.querySelector('.unit-view a[data-focus-key="back-run"]').textContent.includes("Followed run authoritative update") && document.activeElement && document.activeElement.dataset.focusKey && document.activeElement.dataset.focusKey.startsWith("attempt-") && Array.from(document.querySelectorAll('details[data-disclosure-key^="activity:"]')).some(node => node.open) && window.scrollY >= 120`, "restoration_after_refetch", options.browser_timeout_ms);
    await setMode(null);

    // Every invalidation shape is delivered through the real EventSource object;
    // the only observable consequence is another bounded authoritative refetch.
    await triggerInvalidation("bad", {hostile: "must-not-become-truth"}, "malformed_invalidation");
    await triggerInvalidation("7", {type: "projection_changed", projection_id: "fixture-follow"}, "valid_invalidation");
    await triggerInvalidation("7", {type: "projection_changed", projection_id: "fixture-follow"}, "duplicate_invalidation");
    await triggerInvalidation("9", {type: "projection_changed", projection_id: "fixture-follow"}, "gapped_invalidation");
    await triggerInvalidation("8", {type: "projection_changed", projection_id: "fixture-follow"}, "reordered_invalidation");
    const errorBefore = await evaluate(client, sessionId, "window.__pixirBrowserHarness.fetches.length", "stream_error_count");
    await evaluate(client, sessionId, `window.__pixirBrowserHarness.event_source.dispatchEvent(new Event("error")); true`, "stream_error");
    await waitForBrowser(client, sessionId, `window.__pixirBrowserHarness.fetches.length > ${errorBefore}`, "stream_error_refetch", options.browser_timeout_ms);
    const reconnectBefore = await evaluate(client, sessionId, "window.__pixirBrowserHarness.fetches.length", "stream_reconnect_count");
    await evaluate(client, sessionId, `window.__pixirBrowserHarness.event_source.dispatchEvent(new Event("open")); true`, "stream_reconnect");
    await waitForBrowser(client, sessionId, `window.__pixirBrowserHarness.fetches.length > ${reconnectBefore} && document.querySelector(".sse-health").textContent.includes("SSE connected")`, "stream_reconnect_refetch", options.browser_timeout_ms);

    await evaluate(client, sessionId, `location.hash = ${JSON.stringify(followDetailHash)}; true`, "follow_terminal_route");
    await waitForBrowser(client, sessionId, followExpression, "follow_terminal_route_ready", options.browser_timeout_ms);
    await setMode("terminal");
    await triggerInvalidation("20", {type: "projection_changed", projection_id: "fixture-follow"}, "terminal_transition");
    await waitForBrowser(client, sessionId, `document.body.textContent.includes("Followed run reached a terminal state: completed") && document.querySelector('.follow-panel[data-follow-state="following"]')`, "terminal_transition_visible", options.browser_timeout_ms);
    await setMode("owner_unavailable");
    await triggerInvalidation("21", {type: "projection_changed", projection_id: "fixture-follow"}, "unavailable_transition");
    await waitForBrowser(client, sessionId, `document.body.textContent.includes("Followed run is owner unavailable") && document.querySelector('.follow-panel[data-follow-state="following"]')`, "unavailable_transition_visible", options.browser_timeout_ms);
    await setMode("identity_disappeared");
    await triggerInvalidation("23", {type: "projection_changed", projection_id: "fixture-follow"}, "identity_disappeared_transition");
    await waitForBrowser(client, sessionId, `document.querySelector('.follow-degraded[data-follow-state="degraded"]') && document.body.textContent.includes("The followed run is not projected in the authoritative snapshot")`, "identity_disappeared_visible", options.browser_timeout_ms);
    const identityLossOtherRunHash = "#/runs/other-followed-run?follow=1";
    await setMode("delay_detail");
    await evaluate(client, sessionId, `location.hash = ${JSON.stringify(identityLossOtherRunHash)}; true`, "cross_run_navigation_after_identity_loss");
    await waitForBrowser(client, sessionId, `window.__pixirBrowserHarness.release !== null && !document.querySelector('.error-view[data-follow-state]') && !document.getElementById("app").textContent.includes("The followed run is not projected in the authoritative snapshot") && !document.querySelector('.follow-retry')`, "cross_run_navigation_after_identity_loss_cleared", options.browser_timeout_ms);
    await evaluate(client, sessionId, "window.__pixirBrowserHarness.release(); window.__pixirBrowserHarness.release = null; true", "cross_run_navigation_after_identity_loss_release");
    await waitForBrowser(client, sessionId, `location.hash === ${JSON.stringify(identityLossOtherRunHash)} && document.querySelector('.follow-degraded[data-follow-state="degraded"]')`, "cross_run_navigation_after_identity_loss_degraded", options.browser_timeout_ms);
    await evaluate(client, sessionId, `location.hash = ${JSON.stringify(followUnitHash)}; true`, "cross_run_navigation_after_identity_loss_recovery");
    await waitForBrowser(client, sessionId, `location.hash === ${JSON.stringify(followUnitHash)} && document.querySelector('.follow-panel[data-follow-state="following"]') && !document.querySelector('.error-view')`, "cross_run_navigation_after_identity_loss_recovered", options.browser_timeout_ms);
    await setMode(null);
    await triggerInvalidation("24", {type: "projection_changed", projection_id: "fixture-follow"}, "identity_disappeared_recovery");
    await waitForBrowser(client, sessionId, `location.hash === ${JSON.stringify(followUnitHash)} && document.querySelectorAll('.attempt-card').length === 1 && document.querySelector('.follow-panel[data-follow-state="following"]')`, "identity_disappeared_recovered", options.browser_timeout_ms);
    await evaluate(client, sessionId, `location.hash = ${JSON.stringify(followUnitHash)}; true`, "transient_failure_follow_unit_route");
    await waitForBrowser(client, sessionId, `location.hash === ${JSON.stringify(followUnitHash)} && document.querySelector('.follow-panel[data-follow-state="following"]')`, "transient_failure_follow_unit_ready", options.browser_timeout_ms);
    await setMode("transient_failure");
    await triggerInvalidation("25", {type: "projection_changed", projection_id: "fixture-follow"}, "transient_failure_transition");
    await waitForBrowser(client, sessionId, `document.querySelector('.follow-snapshot-unavailable[data-follow-state="snapshot_unavailable"]') && document.body.textContent.includes("The latest authoritative response could not be used") && document.body.textContent.includes("identity was last confirmed") && !document.body.textContent.includes("The followed run is not projected in the authoritative snapshot")`, "transient_failure_neutral", options.browser_timeout_ms);
    await setMode("delay_detail");
    await evaluate(client, sessionId, `location.hash = ${JSON.stringify(followDetailHash)}; true`, "same_run_navigation_from_neutral");
    await waitForBrowser(client, sessionId, `window.__pixirBrowserHarness.release !== null && location.hash === ${JSON.stringify(followDetailHash)} && !document.querySelector('.error-view[data-follow-state]')`, "same_run_navigation_from_neutral_cleared", options.browser_timeout_ms);
    await evaluate(client, sessionId, "window.__pixirBrowserHarness.release(); window.__pixirBrowserHarness.release = null; true", "same_run_navigation_from_neutral_release");
    await waitForBrowser(client, sessionId, `${followExpression} && !document.querySelector('.error-view')`, "same_run_navigation_from_neutral_recovered", options.browser_timeout_ms);
    const failureOtherRunHash = "#/runs/other-followed-run?follow=1";
    await setMode("delay_detail");
    await evaluate(client, sessionId, `location.hash = ${JSON.stringify(failureOtherRunHash)}; true`, "cross_run_navigation_clears_failure_view");
    await waitForBrowser(client, sessionId, `window.__pixirBrowserHarness.release !== null && !document.body.textContent.includes("The latest authoritative response could not be used") && !document.querySelector('.follow-retry')`, "cross_run_navigation_clears_failure_view", options.browser_timeout_ms);
    await evaluate(client, sessionId, "window.__pixirBrowserHarness.release(); window.__pixirBrowserHarness.release = null; true", "cross_run_navigation_failure_release");
    await waitForBrowser(client, sessionId, `location.hash === ${JSON.stringify(failureOtherRunHash)} && document.querySelector('.follow-degraded[data-follow-state="degraded"]')`, "cross_run_navigation_failure_degraded", options.browser_timeout_ms);
    await evaluate(client, sessionId, `location.hash = ${JSON.stringify(followUnitHash)}; true`, "cross_run_navigation_failure_recovery");
    await waitForBrowser(client, sessionId, `location.hash === ${JSON.stringify(followUnitHash)} && document.querySelector('.follow-panel[data-follow-state="following"]') && !document.querySelector('.error-view')`, "cross_run_navigation_failure_recovered", options.browser_timeout_ms);
    const transientRecoveryBefore = await evaluate(client, sessionId, "window.__pixirBrowserHarness.fetches.length", "transient_recovery_count");
    await setMode(null);
    await evaluate(client, sessionId, `location.hash = ${JSON.stringify(followDetailHash)}; true`, "transient_recovery_same_run_route");
    await waitForBrowser(client, sessionId, followExpression, "transient_recovery_same_run_ready", options.browser_timeout_ms);
    await triggerInvalidation("26", {type: "projection_changed", projection_id: "fixture-follow"}, "transient_recovery_authoritative_refetch");
    await waitForBrowser(client, sessionId, `window.__pixirBrowserHarness.fetches.length > ${transientRecoveryBefore} && ${followExpression} && !document.querySelector('.error-view')`, "transient_recovery_authoritative_refetch", options.browser_timeout_ms);

    // Navigation wins over an older response: delay a list refetch, move to the
    // followed detail route, then release the old response and require detail
    // convergence through the trailing navigation refresh.
    await evaluate(client, sessionId, `location.hash = "#/runs"; true`, "inflight_runs");
    await waitForBrowser(client, sessionId, `location.hash === "#/runs"`, "inflight_runs_ready", options.browser_timeout_ms);
    await setMode("delay_detail");
    const inflightBefore = await evaluate(client, sessionId, "window.__pixirBrowserHarness.fetches.length", "inflight_fetch_count");
    const trailingDetailPath = `/api/runs/${encodeURIComponent(options.run_id)}`;
    await evaluate(client, sessionId, `(() => {
      const source = window.__pixirBrowserHarness.event_source;
      const event = new MessageEvent("projection_changed", {data: JSON.stringify({type: "projection_changed", projection_id: "fixture-follow"})});
      Object.defineProperty(event, "lastEventId", {value: "30"}); source.dispatchEvent(event); return true;
    })()`, "start_inflight_refetch");
    await waitForBrowser(client, sessionId, "window.__pixirBrowserHarness.release !== null", "inflight_fetch_started", options.browser_timeout_ms);
    await evaluate(client, sessionId, `location.hash = ${JSON.stringify(followDetailHash)}; true`, "navigate_during_inflight");
    await evaluate(client, sessionId, "window.__pixirBrowserHarness.release(); window.__pixirBrowserHarness.release = null; true", "release_stale_fetch");
    await waitForBrowser(client, sessionId, `window.__pixirBrowserHarness.fetches.slice(${inflightBefore}).includes(${JSON.stringify(trailingDetailPath)}) && ${followExpression} && !document.querySelector('.follow-degraded')`, "inflight_navigation_converged", options.browser_timeout_ms);

    const missingUnitHash = `#/runs/${options.run_id}/units/${encodeURIComponent("missing-unit")}`;
    await evaluate(client, sessionId, `location.hash = ${JSON.stringify(missingUnitHash)}; true`, "navigate_missing_unit");
    await waitForBrowser(client, sessionId, `location.hash === ${JSON.stringify(missingUnitHash)} && document.querySelector('.error-view') && document.body.textContent.includes("This logical unit is absent or its provisional deep link was invalidated.") && document.getElementById("status").textContent.includes("Requested projection unavailable; return to Runs or relaunch.")`, "missing_unit_honesty", options.browser_timeout_ms);

    await evaluate(client, sessionId, `location.hash = ${JSON.stringify(followUnitHash)}; true`, "same_run_follow_unit_route");
    await waitForBrowser(client, sessionId, `location.hash === ${JSON.stringify(followUnitHash)} && document.querySelector('.follow-panel[data-follow-state="following"]') && document.querySelectorAll('.attempt-card').length === 1 && !document.querySelector('.error-view')`, "same_run_follow_unit_ready", options.browser_timeout_ms);
    await setMode("missing_unit");
    await triggerInvalidation("22", {type: "projection_changed", projection_id: "fixture-follow"}, "same_run_missing_unit_transition");
    await waitForBrowser(client, sessionId, `document.querySelector('.follow-unit-unavailable[data-follow-state="unit_unavailable"]') && document.body.textContent.includes("The followed run identity is still projected") && !document.body.textContent.includes("The followed run identity is no longer projected")`, "same_run_missing_unit_honest", options.browser_timeout_ms);
    await evaluate(client, sessionId, `location.hash = ${JSON.stringify(followDetailHash)}; true`, "same_run_detail_from_missing_unit");
    await waitForBrowser(client, sessionId, `location.hash === ${JSON.stringify(followDetailHash)} && document.querySelector('.follow-panel[data-follow-state="following"]') && !document.querySelector('.error-view')`, "same_run_detail_from_missing_unit_recovered", options.browser_timeout_ms);
    await setMode(null);
    const sameRunRecoveryBefore = await evaluate(client, sessionId, "window.__pixirBrowserHarness.fetches.length", "same_run_recovery_refetch_count");
    await triggerInvalidation("27", {type: "projection_changed", projection_id: "fixture-follow"}, "same_run_recovery_refetch");
    await waitForBrowser(client, sessionId, `window.__pixirBrowserHarness.fetches.length > ${sameRunRecoveryBefore} && location.hash === ${JSON.stringify(followDetailHash)} && document.querySelector('.detail-view') && !document.querySelector('.error-view')`, "same_run_recovery_refetched", options.browser_timeout_ms);
    const otherRunHash = "#/runs/other-followed-run?follow=1";
    await evaluate(client, sessionId, `location.hash = ${JSON.stringify(otherRunHash)}; true`, "cross_run_navigation_clears_old_view");
    await waitForBrowser(client, sessionId, `location.hash === ${JSON.stringify(otherRunHash)} && !document.querySelector('.detail-view') && !document.querySelector('.follow-panel[data-follow-state="following"]') && !document.querySelector('.follow-unit-unavailable')`, "cross_run_navigation_clears_old_view", options.browser_timeout_ms);
    await waitForBrowser(client, sessionId, `location.hash === ${JSON.stringify(otherRunHash)} && document.querySelector('.follow-degraded[data-follow-state="degraded"]')`, "cross_run_navigation_degraded", options.browser_timeout_ms);
    await evaluate(client, sessionId, `location.hash = ${JSON.stringify(detailHash)}; true`, "cross_run_navigation_recovery");
    await waitForBrowser(client, sessionId, `location.hash === ${JSON.stringify(detailHash)} && document.querySelector('.detail-view') && !document.querySelector('.error-view')`, "cross_run_navigation_recovered", options.browser_timeout_ms);
    await evaluate(client, sessionId, `(() => { const original = document.createElement.bind(document); document.createElement = function (tag, ...args) { if (tag === "article") { document.createElement = original; throw new Error("forced render fault"); } return original(tag, ...args); }; location.hash = ${JSON.stringify(unitHash)}; return true; })()`, "force_render_failure");
    await waitForBrowser(client, sessionId, `Boolean(document.querySelector('.error-view[data-error-phase="render"][data-error-kind="projection_render_failed"]')) && document.body.textContent.includes("The fetched projection could not be displayed.") && document.getElementById("status").textContent.includes("Snapshot loaded but could not be displayed.")`, "classified_render_failure", options.browser_timeout_ms);

    await evaluate(client, sessionId, `(() => { window.__pixirUnhandledRejections = 0; window.addEventListener("unhandledrejection", () => { window.__pixirUnhandledRejections += 1; }); const original = document.createElement.bind(document); document.createElement = function (tag, ...args) { if (tag === "div") { document.createElement = original; throw new Error("forced failure renderer fault"); } return original(tag, ...args); }; location.hash = "#/runs/missing-renderer-fallback"; return true; })()`, "force_failure_renderer_fault");
    await waitForBrowser(client, sessionId, `document.getElementById("app").dataset.errorPhase === "fetch" && document.getElementById("app").dataset.errorKind === "projection_failure_renderer_failed" && document.getElementById("app").textContent.includes("Projection unavailable. The authoritative projection could not be fetched.") && document.getElementById("status").textContent.includes("Snapshot unavailable; relaunch or wait for convergence.") && window.__pixirUnhandledRejections === 0`, "classified_failure_renderer_fallback", options.browser_timeout_ms);
    await serving;

    const fifoCleaned = !existsSync(fifoPath) && !existsSync(dirname(fifoPath));
    if (!fifoCleaned) throw failure("handoff_cleanup_failed", "Monitor did not remove the one-use FIFO handoff directory", "verify_cleanup");

    const launchFragmentCleared = await evaluate(client, sessionId, `!location.hash.startsWith("#launch=")`, "launch_fragment_cleared");
    if (!launchFragmentCleared) throw failure("launch_fragment_not_cleared", "Launch capability remained in the browser fragment", "verify_launch_fragment");

    runResult = {
      ok: true,
      check: "pixir_monitor_browser_story",
      browser: "chrome_devtools_protocol",
      launch_fragment_cleared: launchFragmentCleared === true,
      runs_view: true,
      detail_view: true,
      unit_view: true,
      follow_route_reload_history: true,
      follow_refetch_restoration: true,
      invalidation_only_refetch: true,
      terminal_transition_visible: true,
      unavailable_transition_visible: true,
      missing_unit_honest: true,
      same_run_missing_unit_honest: true,
      identity_disappeared_visible: true,
      transient_failure_neutral: true,
      same_run_navigation_from_neutral_cleared: true,
      transient_failure_same_run_refetched: true,
      identity_disappeared_recovered: true,
      cross_run_navigation_after_identity_loss_cleared: true,
      cross_run_navigation_cleared: true,
      cross_run_navigation_after_failure_cleared: true,
      inflight_navigation_converged: true,
      attempt_cards: 1,
      render_failure_classified: true,
      failure_renderer_fallback: true,
      projection_unavailable: false,
      handoff_cleaned: true,
      origin: new URL(origin).hostname
    };
    return runResult;
  } catch (error) {
    runError = error;
    throw error;
  } finally {
    if (client) {
      if (browserContextId) {
        try { await client.send("Target.disposeBrowserContext", {browserContextId}, null, "dispose_browser_context"); } catch (_error) {}
      }
      try { await client.send("Browser.close", {}, null, "close_browser"); } catch (_error) {}
      client.close();
    }
    const browserStopped = await stopChild(browser);
    const monitorStopped = await stopChild(monitor);
    await rm(profile, {recursive: true, force: true});
    const cleanup = {browser_stopped: browserStopped, monitor_stopped: monitorStopped, profile_removed: !existsSync(profile)};
    if (runError) runError.safeDetails = {...(runError.safeDetails || {}), cleanup};
    else if (runResult) runResult.cleanup = cleanup;
  }
}

let exitCode = 0;
let output;
let help = false;
try {
  const options = parseArgs(process.argv.slice(2));
  if (options.help) {
    help = true;
  } else {
    validate(options);
    output = options.dryRun
      ? {ok: true, dry_run: true, check: "pixir_monitor_browser_story", browser: "chrome_devtools_protocol", launch_capability_transport: "cdp_only"}
      : await run(options);
  }
} catch (error) {
  exitCode = 1;
  output = safeError(error);
}

process.stdout.write(help ? HELP : `${JSON.stringify(output)}\n`);
process.exitCode = exitCode;
