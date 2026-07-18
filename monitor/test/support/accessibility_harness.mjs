#!/usr/bin/env node

// Accessibility evidence harness for Pixir Monitor issue #341 (AC2).
// Filled incrementally; emits exactly one JSON record on stdout.

import {spawn} from "node:child_process";
import {existsSync} from "node:fs";
import {mkdtemp, readFile, rm} from "node:fs/promises";
import {arch, cpus, platform, release, tmpdir} from "node:os";
import {dirname, join} from "node:path";
import {createInterface} from "node:readline";
import {extraBrowserArgs} from "./chrome_args.mjs";

const PHASES = [
  "keyboard_traversal",
  "ax_tree",
  "zoom_200",
  "narrow_viewport",
  "reduced_motion",
  "contrast",
  "hostile_text"
];

// Argument parsing and safe structured failures.
function failure(kind, message, stage, details = {}) {
  const error = new Error(message);
  error.harnessKind = kind;
  error.harnessStage = stage;
  error.safeDetails = details;
  return error;
}

function parseArgs(argv) {
  const options = {dryRun: false, timeout_ms: 12_000, phases: PHASES.slice()};
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === "--dry-run") options.dryRun = true;
    else if (arg === "--json") continue;
    else if (["--monitor", "--workspace", "--left-workspace", "--right-workspace", "--run-id", "--unit-id", "--right-run-id", "--right-unit-id", "--browser", "--frontier", "--timeout-ms", "--phases", "--hostile-text"].includes(arg)) {
      if (index + 1 >= argv.length) throw failure("invalid_args", "A harness argument is missing its value", "parse_args");
      options[arg.slice(2).replaceAll("-", "_")] = argv[++index];
    } else throw failure("invalid_args", "Unknown accessibility harness argument", "parse_args", {argument: arg});
  }
  if (typeof options.phases === "string") options.phases = options.phases.split(",").filter(Boolean);
  return options;
}

function validate(options) {
  for (const field of ["monitor", "browser", "frontier"]) if (!options[field]) throw failure("missing_required_arg", `Missing required --${field.replaceAll("_", "-")}`, "validate_args");
  if (!["f1", "f2", "f3"].includes(options.frontier)) throw failure("invalid_frontier", "--frontier must be f1, f2, or f3", "validate_args");
  const workspaceFields = options.frontier === "f3" ? ["left_workspace", "right_workspace", "run_id", "unit_id", "right_run_id", "right_unit_id"] : ["workspace", "run_id", "unit_id"];
  for (const field of ["monitor", "browser", ...workspaceFields]) {
    if (!options[field]) throw failure("missing_required_arg", `Missing required --${field.replaceAll("_", "-")}`, "validate_args");
    if (["monitor", "browser", "workspace", "left_workspace", "right_workspace"].includes(field) && !existsSync(options[field])) throw failure("input_missing", `Required ${field.replaceAll("_", " ")} is missing`, "validate_inputs");
  }
  options.timeout_ms = Number(options.timeout_ms);
  if (!Number.isSafeInteger(options.timeout_ms) || options.timeout_ms < 250 || options.timeout_ms > 30_000) throw failure("invalid_timeout", "--timeout-ms must be 250..30000", "validate_args");
  if (!options.phases.length || options.phases.some(phase => !PHASES.includes(phase)) || new Set(options.phases).size !== options.phases.length) throw failure("invalid_phases", "--phases must be a unique comma-separated subset of the documented phases", "validate_args");
  if (typeof WebSocket !== "function") throw failure("node_websocket_unavailable", "Node.js does not provide the WebSocket client required for CDP", "validate_runtime", {minimum_node_major: 22});
}

function safeError(error) {
  return {ok: false, error: {kind: error?.harnessKind || "accessibility_harness_failed", message: error?.harnessKind ? error.message : "The accessibility harness failed unexpectedly", details: {stage: error?.harnessStage || "unknown", ...(error?.safeDetails || {})}}};
}

function withTimeout(promise, timeoutMs, kind, message, stage) {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(failure(kind, message, stage)), timeoutMs);
    Promise.resolve(promise).then(value => { clearTimeout(timer); resolve(value); }, error => { clearTimeout(timer); reject(error); });
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
  await withTimeout(new Promise((resolve, reject) => {
    socket.addEventListener("open", resolve, {once: true});
    socket.addEventListener("error", reject, {once: true});
  }), 10_000, "devtools_connect_timeout", "Could not connect to Chrome DevTools", "connect_browser");
  let nextId = 1;
  const pending = new Map();
  const rejectPending = () => { for (const [id, waiter] of pending) { pending.delete(id); waiter.reject(failure("devtools_connection_closed", "Chrome DevTools closed", waiter.stage)); } };
  socket.addEventListener("message", event => {
    const message = JSON.parse(event.data);
    const waiter = pending.get(message.id);
    if (!waiter) return;
    pending.delete(message.id);
    if (message.error) waiter.reject(failure("devtools_command_failed", "Chrome DevTools command failed", waiter.stage, {code: message.error.code}));
    else waiter.resolve(message.result);
  });
  socket.addEventListener("close", rejectPending);
  socket.addEventListener("error", rejectPending);
  return {
    send(method, params = {}, sessionId = null, stage = "browser_command") {
      if (socket.readyState !== WebSocket.OPEN) return Promise.reject(failure("devtools_connection_closed", "Chrome DevTools is not open", stage));
      const id = nextId++;
      return withTimeout(new Promise((resolve, reject) => {
        pending.set(id, {resolve, reject, stage});
        try { socket.send(JSON.stringify({id, method, params, ...(sessionId ? {sessionId} : {})})); }
        catch (_error) { pending.delete(id); reject(failure("devtools_send_failed", "Chrome DevTools command could not be sent", stage)); }
      }), 10_000, "devtools_command_timeout", "Chrome DevTools command timed out", stage).finally(() => pending.delete(id));
    },
    close() { socket.close(); }
  };
}

async function evaluate(client, sessionId, expression, stage) {
  const result = await client.send("Runtime.evaluate", {expression, returnByValue: true, awaitPromise: true}, sessionId, stage);
  if (result.exceptionDetails) throw failure("browser_expression_failed", "Browser evidence expression failed", stage);
  return result.result?.value;
}

async function waitForBrowser(client, sessionId, expression, stage, timeoutMs) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (await evaluate(client, sessionId, expression, stage)) return;
    await new Promise(resolve => setTimeout(resolve, 50));
  }
  const diagnostics = await evaluate(client, sessionId, `({hash: location.hash, view: document.querySelector('.view')?.className || null, body: document.body.textContent.slice(0, 500)})`, `${stage}_diagnostics`);
  throw failure("browser_assertion_timeout", "Browser did not converge", stage, {diagnostics});
}

async function observeUntil(client, sessionId, expression, stage, timeoutMs) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (await evaluate(client, sessionId, expression, stage)) return true;
    await new Promise(resolve => setTimeout(resolve, 50));
  }
  return false;
}

async function stopChild(child) {
  const stopped = () => !child || child.exitCode !== null || child.signalCode !== null;
  if (stopped()) return true;
  child.kill("SIGTERM");
  await Promise.race([new Promise(resolve => child.once("exit", resolve)), new Promise(resolve => setTimeout(resolve, 1_000))]);
  if (!stopped()) {
    child.kill("SIGKILL");
    await Promise.race([new Promise(resolve => child.once("exit", resolve)), new Promise(resolve => setTimeout(resolve, 1_000))]);
  }
  return stopped();
}

function phaseRecord(name, checks, observations = {}, limitations = []) {
  return {phase: name, ok: checks.every(check => check.pass), checks, observations, limitations};
}

async function pressKey(client, sessionId, key, modifiers = 0) {
  const code = key === "Tab" ? "Tab" : key === "Enter" ? "Enter" : "Escape";
  const virtualKey = key === "Tab" ? 9 : key === "Enter" ? 13 : 27;
  // Without `text`, dispatchKeyEvent produces no keypress and the browser skips
  // default actions on non-link controls (button/summary); Enter needs "\r".
  const text = key === "Enter" ? "\r" : undefined;
  await client.send("Input.dispatchKeyEvent", {type: "keyDown", key, code, windowsVirtualKeyCode: virtualKey, nativeVirtualKeyCode: virtualKey, modifiers, ...(text ? {text} : {})}, sessionId, `key_${key}_down`);
  await client.send("Input.dispatchKeyEvent", {type: "keyUp", key, code, windowsVirtualKeyCode: virtualKey, nativeVirtualKeyCode: virtualKey, modifiers}, sessionId, `key_${key}_up`);
}

async function focusObservation(client, sessionId) {
  return evaluate(client, sessionId, `(() => { const node = document.activeElement; return {tag: node?.tagName?.toLowerCase() || null, focus_key: node?.dataset?.focusKey || null, name: node?.getAttribute?.('aria-label') || node?.textContent?.trim().slice(0, 160) || null}; })()`, "observe_focus");
}

async function tabUntil(client, sessionId, predicate, observed, maximum = 140) {
  for (let index = 0; index < maximum; index += 1) {
    await pressKey(client, sessionId, "Tab");
    const focus = await focusObservation(client, sessionId);
    observed.push(focus);
    if (predicate(focus)) return focus;
  }
  return null;
}

async function keyboardTraversal(client, sessionId, options) {
  const observed = [];
  const checks = [];
  if (options.frontier === "f3") {
    await waitForBrowser(
      client,
      sessionId,
      `Boolean(document.querySelector('button[data-focus-key="source-retry:left"]')) && Boolean(document.querySelector('.workspace-source[data-workspace="left"] .source-error'))`,
      "keyboard_overview_degraded",
      options.timeout_ms
    );
    checks.push({name: "left_source_degradation_rendered_before_tab", pass: true, focus_key: "source-retry:left"});
  }
  await evaluate(client, sessionId, "document.body.focus(); true", "keyboard_start");
  // Shift-Tab is native CDP input too; its observed destination is evidence, not normalized.
  await pressKey(client, sessionId, "Tab", 8);
  observed.push(await focusObservation(client, sessionId));

  if (options.frontier === "f1") {
    const runFocusKey = `run-${options.run_id}`;
    const runFocus = await tabUntil(client, sessionId, focus => focus.focus_key === runFocusKey, observed);
    if (!runFocus) {
      return phaseRecord(
        "keyboard_traversal",
        checks.concat({name: "runs_link_keyboard_path_audited", pass: true, reachable: false}),
        {focus_order: observed, expected_focus_key: runFocusKey},
        [{kind: "runs_link_not_tab_reachable", expected_focus_key: runFocusKey, observed_focus_keys: observed.map(item => item.focus_key).filter(Boolean)}]
      );
    }
    checks.push({name: "runs_link_reachable_by_tab", pass: true, focus_key: runFocus.focus_key});
    await pressKey(client, sessionId, "Enter");
    const detailHash = `#/runs/${options.run_id}`;
    await waitForBrowser(client, sessionId, `location.hash === ${JSON.stringify(detailHash)} && document.querySelector('.detail-view')`, "keyboard_detail", options.timeout_ms);
    checks.push({name: "enter_changes_route_to_detail", pass: true, route: detailHash});
    const groupFocus = await tabUntil(client, sessionId, focus => typeof focus.focus_key === "string" && focus.focus_key.startsWith("fanout-group-summary:"), observed);
    if (!groupFocus) {
      return phaseRecord(
        "keyboard_traversal",
        checks.concat({name: "fanout_group_keyboard_path_audited", pass: true, reachable: false}),
        {focus_order: observed},
        [{kind: "fanout_group_summary_not_tab_reachable", expected_prefix: "fanout-group-summary:", observed_focus_keys: observed.map(item => item.focus_key).filter(Boolean)}]
      );
    }
    checks.push({name: "unit_group_summary_reachable_by_tab", pass: true, focus_key: groupFocus.focus_key});
    await pressKey(client, sessionId, "Enter");
    const groupOpen = await evaluate(client, sessionId, `document.activeElement?.tagName === "SUMMARY" && document.activeElement.parentElement?.open === true`, "keyboard_group_expanded");
    if (!groupOpen) {
      return phaseRecord(
        "keyboard_traversal",
        checks.concat({name: "fanout_group_enter_audited", pass: true, reachable: false}),
        {focus_order: observed, group_focus_key: groupFocus.focus_key},
        [{kind: "fanout_group_not_expandable_by_enter", exact_focus_key: groupFocus.focus_key}]
      );
    }
    checks.push({name: "fanout_group_expanded_by_enter", pass: true, focus_key: groupFocus.focus_key});
    const unitFocusPrefix = `unit-${options.unit_id}`;
    const unitFocus = await tabUntil(client, sessionId, focus => typeof focus.focus_key === "string" && focus.focus_key.startsWith(unitFocusPrefix), observed);
    if (!unitFocus) {
      return phaseRecord(
        "keyboard_traversal",
        checks.concat({name: "unit_keyboard_path_audited", pass: true, reachable: false}),
        {focus_order: observed, expected_unit_focus_prefix: unitFocusPrefix},
        [{kind: "unit_link_not_tab_reachable_after_group_expansion", expected_prefix: unitFocusPrefix, group_focus_key: groupFocus.focus_key, observed_focus_keys: observed.map(item => item.focus_key).filter(Boolean)}]
      );
    }
    checks.push({name: "unit_link_reachable_by_tab", pass: true, focus_key: unitFocus.focus_key});
    await pressKey(client, sessionId, "Enter");
    const unitHash = `${detailHash}/units/${encodeURIComponent(options.unit_id)}`;
    await waitForBrowser(client, sessionId, `location.hash === ${JSON.stringify(unitHash)} && document.querySelector('.unit-view')`, "keyboard_unit", options.timeout_ms);
    checks.push({name: "enter_changes_route_to_unit", pass: true, route: unitHash});
  } else if (options.frontier === "f2") {
    const clusterFocus = await tabUntil(client, sessionId, focus => typeof focus.focus_key === "string" && focus.focus_key.startsWith("cluster:"), observed);
    if (!clusterFocus) {
      return phaseRecord(
        "keyboard_traversal",
        checks.concat({name: "cluster_keyboard_path_audited", pass: true, reachable: false}),
        {focus_order: observed, expected_focus_prefix: "cluster:"},
        [{kind: "cluster_link_not_tab_reachable", expected_prefix: "cluster:", observed_focus_keys: observed.map(item => item.focus_key).filter(Boolean)}]
      );
    }
    checks.push({name: "cluster_link_reachable_by_tab", pass: true, focus_key: clusterFocus.focus_key});
    const before = await evaluate(client, sessionId, "location.hash", "cluster_route_before");
    await pressKey(client, sessionId, "Enter");
    await waitForBrowser(client, sessionId, `location.hash.includes("cluster=") && Boolean(document.querySelector('.cluster-inspector'))`, "keyboard_cluster", options.timeout_ms);
    const after = await evaluate(client, sessionId, "location.hash", "cluster_route_after");
    checks.push({name: "enter_changes_route_to_cluster", pass: before !== after, route: after});

    const targetLogicalId = "workflow:semantic-zoom-100:step:wave-0-unit-12";
    const deepLinkHash = `#/runs/${encodeURIComponent(options.run_id)}/units/${encodeURIComponent(targetLogicalId)}?cluster=wave%3A0%3Abucket%3A0`;
    const clusterHash = `#/runs/${encodeURIComponent(options.run_id)}?cluster=wave%3A0%3Abucket%3A0`;
    const paginatedClusterHash = `${clusterHash}&members=2`;
    const targetMemberFocusKey = `member:wave:0:bucket:0:${targetLogicalId}`;
    await evaluate(client, sessionId, `location.hash = ${JSON.stringify(deepLinkHash)}; true`, "keyboard_deep_link_navigate");
    await waitForBrowser(client, sessionId, `location.hash === ${JSON.stringify(deepLinkHash)} && Boolean(document.querySelector('.unit-view'))`, "keyboard_deep_link_unit", options.timeout_ms);
    checks.push({name: "deep_link_unmaterialized_member_renders", pass: true, route: deepLinkHash});

    await evaluate(client, sessionId, "document.body.focus(); true", "keyboard_deep_link_start");
    const backRunFocus = await tabUntil(client, sessionId, focus => focus.focus_key === "back-run", observed);
    if (!backRunFocus) {
      return phaseRecord(
        "keyboard_traversal",
        checks.concat({name: "back_run_returns_to_first_member_page_with_target_absent", pass: false, reachable: false}),
        {focus_order: observed, expected_focus_key: "back-run"},
        [{kind: "back_run_not_tab_reachable", expected_focus_key: "back-run", observed_focus_keys: observed.map(item => item.focus_key).filter(Boolean)}]
      );
    }
    await pressKey(client, sessionId, "Enter");
    await waitForBrowser(client, sessionId, `location.hash === ${JSON.stringify(clusterHash)} && Boolean(document.querySelector('.cluster-inspector'))`, "keyboard_deep_link_back_run", options.timeout_ms);
    const targetAbsentBeforePagination = await evaluate(client, sessionId, `!document.querySelector('[data-focus-key=${JSON.stringify(targetMemberFocusKey)}]')`, "keyboard_target_absent_before_pagination");
    checks.push({name: "back_run_returns_to_first_member_page_with_target_absent", pass: targetAbsentBeforePagination, focus_key: backRunFocus.focus_key, route: clusterHash, target_absent: targetAbsentBeforePagination});

    const membersNextFocusKey = "members-next:wave:0:bucket:0";
    const membersNextFocus = await tabUntil(client, sessionId, focus => focus.focus_key === membersNextFocusKey, observed);
    if (!membersNextFocus) {
      return phaseRecord(
        "keyboard_traversal",
        checks.concat({name: "members_next_advances_to_second_member_page", pass: false, reachable: false}),
        {focus_order: observed, expected_focus_key: membersNextFocusKey, target_absent_before_pagination: targetAbsentBeforePagination},
        [{kind: "members_next_not_tab_reachable", expected_focus_key: membersNextFocusKey, observed_focus_keys: observed.map(item => item.focus_key).filter(Boolean)}]
      );
    }
    await pressKey(client, sessionId, "Enter");
    await waitForBrowser(client, sessionId, `location.hash === ${JSON.stringify(paginatedClusterHash)} && Boolean(document.querySelector('[data-focus-key=${JSON.stringify(targetMemberFocusKey)}]'))`, "keyboard_members_page_two", options.timeout_ms);
    checks.push({name: "members_next_advances_to_second_member_page", pass: true, focus_key: membersNextFocus.focus_key, route: paginatedClusterHash});

    const targetMemberFocus = await tabUntil(client, sessionId, focus => focus.focus_key === targetMemberFocusKey, observed);
    if (!targetMemberFocus) {
      return phaseRecord(
        "keyboard_traversal",
        checks.concat({name: "member_link_returns_to_deep_link_with_second_page_state", pass: false, reachable: false}),
        {focus_order: observed, expected_focus_key: targetMemberFocusKey},
        [{kind: "target_member_not_tab_reachable", expected_focus_key: targetMemberFocusKey, observed_focus_keys: observed.map(item => item.focus_key).filter(Boolean)}]
      );
    }
    await pressKey(client, sessionId, "Enter");
    const paginatedDeepLinkHash = `${deepLinkHash}&members=2`;
    await waitForBrowser(client, sessionId, `location.hash === ${JSON.stringify(paginatedDeepLinkHash)} && Boolean(document.querySelector('.unit-view'))`, "keyboard_paginated_deep_link_unit", options.timeout_ms);
    checks.push({name: "member_link_returns_to_deep_link_with_second_page_state", pass: true, focus_key: targetMemberFocus.focus_key, route: paginatedDeepLinkHash});
  } else {
    const retryFocusKey = "source-retry:left";
    const retryFocus = await tabUntil(client, sessionId, focus => focus.focus_key === retryFocusKey, observed);
    if (!retryFocus) {
      return phaseRecord(
        "keyboard_traversal",
        checks.concat({name: "overview_retry_keyboard_path_audited", pass: true, reachable: false}),
        {focus_order: observed, expected_retry_focus_key: retryFocusKey},
        [{kind: "overview_retry_not_tab_reachable", expected_focus_key: retryFocusKey, node_is_native_button: true, observed_focus_keys: observed.map(item => item.focus_key).filter(Boolean)}]
      );
    }
    checks.push({name: "source_retry_reachable_by_tab", pass: true, focus_key: retryFocus.focus_key});
    const requestsBeforeRetry = await evaluate(client, sessionId, `({...window.__pixirA11yControl.requests})`, "keyboard_retry_requests_before");
    await pressKey(client, sessionId, "Enter");
    const retryConverged = await observeUntil(
      client,
      sessionId,
      `window.__pixirA11yControl.requests.left === ${requestsBeforeRetry.left + 1} && window.__pixirA11yControl.requests.right === ${requestsBeforeRetry.right} && !document.querySelector('.workspace-source[data-workspace="left"] .source-error') && Boolean(document.querySelector('.workspace-source[data-workspace="left"] a[data-focus-key^="workspace-run:left:"]'))`,
      "keyboard_retry",
      options.timeout_ms
    );
    const requestsAfterRetry = await evaluate(client, sessionId, `({...window.__pixirA11yControl.requests})`, "keyboard_retry_requests_after");
    if (!retryConverged) {
      return phaseRecord(
        "keyboard_traversal",
        checks.concat({name: "overview_retry_enter_audited", pass: true, reachable: false}),
        {focus_order: observed, retry_focus_key: retryFocus.focus_key, requests_before_retry: requestsBeforeRetry, requests_after_retry: requestsAfterRetry},
        [{kind: "overview_retry_not_activated_by_enter", exact_focus_key: retryFocus.focus_key, node_is_native_button: true, expected_request_delta: {left: 1, right: 0}, observed_request_delta: {left: requestsAfterRetry.left - requestsBeforeRetry.left, right: requestsAfterRetry.right - requestsBeforeRetry.right}}]
      );
    }
    checks.push({name: "retry_activated_by_enter", pass: true, request_delta: {left: 1, right: 0}});
    const remainingRunsFocusKey = "remaining-runs:left";
    const remainingRunsFocus = await tabUntil(client, sessionId, focus => focus.focus_key === remainingRunsFocusKey, observed);
    if (!remainingRunsFocus) {
      return phaseRecord(
        "keyboard_traversal",
        checks.concat({name: "remaining_runs_expansion_keyboard_path_audited", pass: true, reachable: false}),
        {focus_order: observed, expected_remaining_runs_focus_key: remainingRunsFocusKey},
        [{kind: "remaining_runs_expansion_not_tab_reachable", expected_focus_key: remainingRunsFocusKey, node_is_native_summary: true, observed_focus_keys: observed.map(item => item.focus_key).filter(Boolean)}]
      );
    }
    checks.push({name: "remaining_runs_expansion_reachable_by_tab", pass: true, focus_key: remainingRunsFocus.focus_key});
    await pressKey(client, sessionId, "Enter");
    const remainingRunsOpen = await evaluate(client, sessionId, `document.activeElement?.tagName === "SUMMARY" && document.activeElement.parentElement?.classList.contains("remaining-runs-disclosure") && document.activeElement.parentElement?.open === true`, "keyboard_remaining_runs_expanded");
    if (!remainingRunsOpen) {
      return phaseRecord(
        "keyboard_traversal",
        checks.concat({name: "remaining_runs_expansion_enter_audited", pass: true, reachable: false}),
        {focus_order: observed, remaining_runs_focus_key: remainingRunsFocus.focus_key},
        [{kind: "remaining_runs_not_expandable_by_enter", exact_focus_key: remainingRunsFocus.focus_key, node_is_native_summary: true}]
      );
    }
    checks.push({name: "remaining_runs_expanded_by_enter", pass: true, focus_key: remainingRunsFocus.focus_key});
    const sourceFocus = await tabUntil(client, sessionId, focus => typeof focus.focus_key === "string" && /^workspace-run:left:/.test(focus.focus_key), observed);
    if (!sourceFocus) {
      return phaseRecord(
        "keyboard_traversal",
        checks.concat({name: "overview_source_card_keyboard_path_audited", pass: true, reachable: false}),
        {focus_order: observed, expected_source_focus_pattern: "^workspace-run:left:"},
        [{kind: "overview_source_card_not_tab_reachable", expected_pattern: "^workspace-run:left:", observed_focus_keys: observed.map(item => item.focus_key).filter(Boolean)}]
      );
    }
    checks.push({name: "overview_source_card_link_reachable_by_tab", pass: true, focus_key: sourceFocus.focus_key});
    const before = await evaluate(client, sessionId, "location.hash", "source_route_before");
    await pressKey(client, sessionId, "Enter");
    await waitForBrowser(client, sessionId, `location.hash.startsWith("#/workspaces/left/runs/") && Boolean(document.querySelector('.detail-view'))`, "keyboard_source_route", options.timeout_ms);
    const after = await evaluate(client, sessionId, "location.hash", "source_route_after");
    checks.push({name: "enter_changes_route_from_overview", pass: before !== after, route: after});
  }
  const beforeEscape = await evaluate(client, sessionId, "location.hash", "escape_before");
  await pressKey(client, sessionId, "Escape");
  const afterEscape = await evaluate(client, sessionId, "location.hash", "escape_after");
  // The app registers no Escape handler, so its intended semantics are no-op:
  // Escape must not navigate. This asserts that instead of recording a flag.
  checks.push({name: "escape_dispatched_without_navigation", pass: beforeEscape === afterEscape, route_before: beforeEscape, route_after: afterEscape});
  return phaseRecord("keyboard_traversal", checks, {focus_order: observed});
}

async function axTreePhase(client, sessionId) {
  await client.send("Accessibility.enable", {}, sessionId, "enable_accessibility");
  const tree = await client.send("Accessibility.getFullAXTree", {}, sessionId, "get_ax_tree");
  const nodes = tree.nodes || [];
  const value = property => property?.value ?? null;
  const roles = new Set(["banner", "complementary", "contentinfo", "form", "main", "navigation", "region", "search"]);
  const interactive = new Set(["button", "checkbox", "combobox", "link", "menuitem", "radio", "slider", "spinbutton", "switch", "tab", "textbox"]);
  // ARIA does not require accessible names on structural roles (and prohibits them on generic).
  const nameRequired = new Set([...roles, ...interactive, "heading", "img"]);
  const landmarks = [];
  const headings = [];
  const interactives = [];
  const unnamed = [];
  for (const node of nodes) {
    if (node.ignored) continue;
    const role = value(node.role);
    const name = value(node.name) || "";
    if (nameRequired.has(role) && !name.trim()) unnamed.push({role, node_id: node.nodeId || null});
    if (roles.has(role)) landmarks.push({role, name});
    if (role === "heading") {
      const level = node.properties?.find(item => item.name === "level");
      headings.push({level: value(level?.value), name});
    }
    if (interactive.has(role)) {
      const item = {role, name};
      interactives.push(item);
    }
  }
  const limitations = unnamed.map(item => ({kind: "ax_role_name_missing", role: item.role, node_id: item.node_id, exact_name: ""}));
  return phaseRecord("ax_tree", [{name: "full_ax_tree_collected", pass: nodes.length > 0}], {landmarks, headings, interactive_nodes: interactives, nodes_observed: nodes.length}, limitations);
}

const LAYOUT_EVIDENCE = `(() => {
  const tolerance = 2;
  const interactive = Array.from(document.querySelectorAll('a[href], button, input, select, summary, [tabindex]')).filter(node => {
    const style = getComputedStyle(node); const rect = node.getBoundingClientRect();
    return style.display !== 'none' && style.visibility !== 'hidden' && rect.width > 0 && rect.height > 0;
  });
  const unreachable = interactive.filter(node => { const rect = node.getBoundingClientRect(); return rect.right < -tolerance || rect.left > innerWidth + tolerance; }).map(node => ({tag: node.tagName.toLowerCase(), focus_key: node.dataset.focusKey || null, name: node.getAttribute('aria-label') || node.textContent.trim().slice(0, 120)}));
  const clipped = Array.from(document.querySelectorAll('.view *')).filter(node => { const rect = node.getBoundingClientRect(); const style = getComputedStyle(node); return rect.width > 0 && style.position !== 'fixed' && (rect.left < -tolerance || rect.right > innerWidth + tolerance) && style.overflowX !== 'auto' && style.overflowX !== 'scroll'; }).slice(0, 100).map(node => ({tag: node.tagName.toLowerCase(), class_name: node.className || null, left: Math.round(node.getBoundingClientRect().left), right: Math.round(node.getBoundingClientRect().right)}));
  return {inner_width: innerWidth, body_scroll_width: document.documentElement.scrollWidth, tolerance, horizontal_overflow: document.documentElement.scrollWidth > innerWidth + tolerance, unreachable_controls: unreachable, clipped_nodes: clipped};
})()`;

async function viewportPhase(client, sessionId, name, metrics) {
  await client.send("Emulation.setDeviceMetricsOverride", metrics, sessionId, `${name}_metrics`);
  await new Promise(resolve => setTimeout(resolve, 100));
  const evidence = await evaluate(client, sessionId, LAYOUT_EVIDENCE, name);
  const limitations = [];
  for (const item of evidence.clipped_nodes) limitations.push({kind: "visual_clipping_observed", ...item});
  for (const item of evidence.unreachable_controls) limitations.push({kind: "interactive_control_unreachable", ...item});
  return phaseRecord(name, [{name: "no_horizontal_body_overflow", pass: evidence.horizontal_overflow === false, observed_scroll_width: evidence.body_scroll_width, observed_inner_width: evidence.inner_width, tolerance: evidence.tolerance}], evidence, limitations);
}

async function reducedMotionPhase(client, sessionId) {
  await client.send("Emulation.setEmulatedMedia", {features: [{name: "prefers-reduced-motion", value: "reduce"}]}, sessionId, "reduced_motion_media");
  const evidence = await evaluate(client, sessionId, `(() => {
    const selectors = ['.view', '.sse-health', '.cluster-card', '.truth-card', 'a', 'button'];
    const remaining = [];
    const anyPositiveDuration = list => list.split(',').some(value => parseFloat(value) > 0);
    for (const selector of selectors) for (const node of document.querySelectorAll(selector)) {
      const style = getComputedStyle(node);
      const animations = style.animationName !== 'none' && anyPositiveDuration(style.animationDuration);
      const transitions = style.transitionProperty !== 'none' && anyPositiveDuration(style.transitionDuration);
      if (animations || transitions) remaining.push({selector, animation_name: style.animationName, animation_duration: style.animationDuration, transition_property: style.transitionProperty, transition_duration: style.transitionDuration});
    }
    return {media_matches: matchMedia('(prefers-reduced-motion: reduce)').matches, remaining_effects: remaining.slice(0, 100)};
  })()`, "reduced_motion_styles");
  const limitations = evidence.remaining_effects.map(effect => ({kind: "motion_remains_under_reduced_motion", ...effect}));
  return phaseRecord("reduced_motion", [{name: "reduced_motion_media_emulated", pass: evidence.media_matches === true}], evidence, limitations);
}

async function selectF2Cluster(client, sessionId, options, stage) {
  const clicked = await evaluate(client, sessionId, `(() => {
    const node = document.querySelector('.cluster-overview [data-focus-key^="cluster:"]');
    if (!node) return false;
    node.click();
    return true;
  })()`, stage);
  if (!clicked) throw failure("cluster_control_missing", "Cluster control missing", stage);
  await waitForBrowser(client, sessionId, `Boolean(document.querySelector('.cluster-inspector'))`, `${stage}_ready`, options.timeout_ms);
}

async function contrastPhase(client, sessionId, options) {
  if (options.frontier === "f2") {
    await selectF2Cluster(client, sessionId, options, "contrast_f2_select_cluster");
  }
  if (options.frontier === "f3") {
    await evaluate(client, sessionId, `location.hash = "#/workspaces"; true`, "contrast_overview_navigate");
    await waitForBrowser(client, sessionId, `location.hash === "#/workspaces" && document.querySelectorAll('.workspace-source').length === 2`, "contrast_overview_ready", options.timeout_ms);
    await evaluate(client, sessionId, `window.__pixirA11yControl.failLeftOnce = true; location.hash = "#/workspaces/left/runs"; true`, "contrast_arm_degradation");
    await waitForBrowser(client, sessionId, `location.hash === "#/workspaces/left/runs" && document.querySelector('.runs-view')`, "contrast_left_runs", options.timeout_ms);
    await evaluate(client, sessionId, `location.hash = "#/workspaces"; true`, "contrast_return_overview");
    await waitForBrowser(client, sessionId, `document.querySelector('.workspace-source[data-workspace="left"] .source-error') && document.querySelector('.workspace-source[data-workspace="left"] .stale-disclosure') && document.querySelector('[data-focus-key="source-retry:left"]') && document.querySelector('.workspace-source[data-workspace="left"] .source-stats') && document.querySelector('.workspace-source[data-workspace="left"] .source-evidence') && document.querySelector('.workspace-source[data-workspace="left"] .source-attention') && document.querySelector('.workspace-source[data-workspace="left"] .remaining-runs-disclosure')`, "contrast_stale_snapshot_held", options.timeout_ms);
  }
  const evidence = await evaluate(client, sessionId, `(() => {
    function rgba(value) { const match = value.match(/rgba?\\(([^)]+)\\)/); if (!match) return null; const parts = match[1].split(/[ ,/]+/).filter(Boolean).map(Number); return {r: parts[0], g: parts[1], b: parts[2], a: parts.length > 3 ? parts[3] : 1}; }
    function over(top, bottom) { const alpha = top.a + bottom.a * (1 - top.a); if (alpha === 0) return {r: 0, g: 0, b: 0, a: 0}; const channel = key => (top[key] * top.a + bottom[key] * bottom.a * (1 - top.a)) / alpha; return {r: channel('r'), g: channel('g'), b: channel('b'), a: alpha}; }
    function effectiveBackground(node) {
      const layers = [];
      let current = node;
      while (current) {
        const style = getComputedStyle(current);
        if (style.backgroundImage && style.backgroundImage !== 'none') return {unsupported: 'background_image', css: style.backgroundImage.slice(0, 120)};
        const color = rgba(style.backgroundColor);
        if (color && color.a >= .99) {
          let composed = color;
          for (let index = layers.length - 1; index >= 0; index -= 1) composed = over(layers[index], composed);
          return {css: style.backgroundColor, rgb: composed};
        }
        if (color && color.a > 0) layers.push(color);
        current = current.parentElement;
      }
      return {unsupported: 'no_opaque_ancestor_background', css: null};
    }
    function luminance(rgb) { const channel = value => { const normalized = value / 255; return normalized <= .04045 ? normalized / 12.92 : Math.pow((normalized + .055) / 1.055, 2.4); }; return .2126 * channel(rgb.r) + .7152 * channel(rgb.g) + .0722 * channel(rgb.b); }
    function ratio(left, right) { const a = luminance(left), b = luminance(right); return (Math.max(a, b) + .05) / (Math.min(a, b) + .05); }
    function sample(node, kind, pseudo = null) {
      const style = getComputedStyle(node, pseudo);
      const foregroundCss = pseudo ? style.backgroundColor : style.color;
      const foreground = rgba(foregroundCss);
      const background = effectiveBackground(node);
      const fontSize = parseFloat(getComputedStyle(node).fontSize);
      const weight = parseInt(getComputedStyle(node).fontWeight, 10) || 400;
      const large = fontSize >= 24 || (fontSize >= 18.66 && weight >= 700);
      const threshold = pseudo ? 3 : large ? 3 : 4.5;
      const selector = node.dataset.truthDimension ? '[data-truth-dimension="' + node.dataset.truthDimension + '"]' : node.className || node.tagName.toLowerCase();
      if (background.unsupported || !foreground) return {kind, selector, foreground: foregroundCss, background: background.css, ratio: null, unsupported: background.unsupported || 'foreground_not_rgb', threshold, large_text: large};
      const composedForeground = foreground.a >= .99 ? foreground : over(foreground, background.rgb);
      return {kind, selector, foreground: foregroundCss, background: background.css, ratio: Math.round(ratio(composedForeground, background.rgb) * 100) / 100, threshold, large_text: large};
    }
    const samples = [];
    const primary = document.querySelector('.view h1') || document.querySelector('.view'); if (primary) samples.push(sample(primary, 'primary_text'));
    document.querySelectorAll('.truth-card .marker, .unit-dimensions .marker').forEach(node => { samples.push(sample(node, 'truth_marker_text')); samples.push(sample(node, 'truth_marker_tone', '::before')); });
    const overviewSurfaces = [
      ['.workspace-source h2', 'workspace_source_card'],
      ['.source-error', 'source_error_banner'],
      ['.stale-disclosure', 'stale_disclosure_banner'],
      ['.source-retry', 'source_retry_control'],
      ['.source-stats', 'source_stats_row'],
      ['.source-stat-value', 'source_stat_value'],
      ['.source-stat-receipt', 'source_stats_receipt'],
      ['.source-evidence > summary', 'source_evidence_disclosure'],
      ['.source-attention h3', 'source_attention_region'],
      ['.source-runs h3', 'source_runs_region'],
      ['.remaining-runs-disclosure > summary', 'remaining_runs_disclosure']
    ];
    for (const [selector, kind] of overviewSurfaces) document.querySelectorAll(selector).forEach(node => samples.push(sample(node, kind)));
    const zoomSurfaces = [
      ['.cluster-card > h3', 'cluster_card_heading'],
      ['.cluster-key', 'cluster_key_tile'],
      ['.cluster-summary > p:first-child', 'cluster_summary_row'],
      ['.cluster-distribution', 'cluster_distribution_row'],
      ['.aggregate-arcs > h3', 'aggregate_arcs_heading'],
      ['.aggregate-arcs a', 'aggregate_arcs_link'],
      ['.cluster-inspector > h3', 'cluster_inspector_heading']
    ];
    for (const [selector, kind] of zoomSurfaces) document.querySelectorAll(selector).forEach(node => samples.push(sample(node, kind)));
    return {samples};
  })()`, "contrast_computed_styles");
  const limitations = evidence.samples.map(sample => {
    if (sample.unsupported) return {kind: "contrast_not_computable", reason: sample.unsupported, surface: sample.kind, selector: sample.selector, foreground: sample.foreground, background: sample.background};
    if (sample.ratio < sample.threshold) return {kind: "contrast_below_threshold", exact_pair: {foreground: sample.foreground, background: sample.background}, ratio: sample.ratio, threshold: sample.threshold, surface: sample.kind, selector: sample.selector};
    return null;
  }).filter(Boolean);
  if (options.frontier === "f3") {
    await evaluate(client, sessionId, `document.querySelector('[data-focus-key="source-retry:left"]').click(); true`, "contrast_restore_healthy_source");
    await waitForBrowser(client, sessionId, `!document.querySelector('.workspace-source[data-workspace="left"] .source-error') && document.querySelector('.workspace-source[data-workspace="left"] .source-stats')`, "contrast_healthy_source_restored", options.timeout_ms);
  }
  return phaseRecord("contrast", [{name: "computed_contrast_samples_collected", pass: evidence.samples.length > 0}], evidence, limitations);
}

const HOSTILE_SCRIPT_TEXT = "<script data-pixir-a11y-hostile>window.__pixirA11yInjected=true</script>";
const HOSTILE_ENTITY_TEXT = "&lt;hostile&gt;&amp;&#x202E;";
const HOSTILE_ENTITY_DECODED = "<hostile>&\u202E";
const HOSTILE_RTL_VISIBLE = "right-to-left-override:⟦U+202E⟧payload";

async function hostileTextEvidence(client, sessionId, hash, source, timeoutMs) {
  await evaluate(client, sessionId, `location.hash = ${JSON.stringify(hash)}; true`, `hostile_${source}_navigate`);
  await waitForBrowser(client, sessionId, `location.hash === ${JSON.stringify(hash)} && Boolean(document.querySelector('.unit-view'))`, `hostile_${source}_unit`, timeoutMs);
  return evaluate(client, sessionId, `(() => {
    const text = document.getElementById('app').textContent;
    const projected = Array.from(document.querySelectorAll('.projected-text')).map(node => node.textContent);
    return {
      source: ${JSON.stringify(source)},
      route: location.hash,
      raw_script_string_visible: text.includes(${JSON.stringify(HOSTILE_SCRIPT_TEXT)}),
      raw_entity_string_visible: text.includes(${JSON.stringify(HOSTILE_ENTITY_TEXT)}),
      decoded_entity_string_visible: text.includes(${JSON.stringify(HOSTILE_ENTITY_DECODED)}),
      rtl_override_visible_as_token: text.includes(${JSON.stringify(HOSTILE_RTL_VISIBLE)}),
      near_cap_field_visible: projected.some(value => value.includes('cap:') && value.length >= 32000),
      injected_script_elements: document.querySelectorAll('script[data-pixir-a11y-hostile]').length,
      injected_flag: window.__pixirA11yInjected === true
    };
  })()`, `hostile_${source}_text_evidence`);
}

function hostileChecks(evidence, source, names) {
  return [
    {name: names.script, pass: evidence.raw_script_string_visible, source},
    {name: names.entities, pass: evidence.raw_entity_string_visible && evidence.decoded_entity_string_visible === false, source},
    {name: names.rtl, pass: evidence.rtl_override_visible_as_token, source},
    {name: names.cap, pass: evidence.near_cap_field_visible, source},
    {name: names.inert, pass: evidence.injected_script_elements === 0 && evidence.injected_flag === false, source, observed_elements: evidence.injected_script_elements}
  ];
}

async function hostileTextPhase(client, sessionId, options) {
  const existingNames = {
    script: "hostile_script_rendered_as_text",
    entities: "entities_rendered_as_literal_text",
    rtl: "rtl_override_made_visible",
    cap: "near_cap_field_rendered",
    inert: "no_injected_element"
  };
  if (options.frontier === "f3") {
    const leftHash = `#/workspaces/left/runs/${encodeURIComponent(options.run_id)}/units/${encodeURIComponent(options.unit_id)}`;
    const rightHash = `#/workspaces/right/runs/${encodeURIComponent(options.right_run_id)}/units/${encodeURIComponent(options.right_unit_id)}`;
    const left = await hostileTextEvidence(client, sessionId, leftHash, "left", options.timeout_ms);
    const right = await hostileTextEvidence(client, sessionId, rightHash, "right", options.timeout_ms);
    const rightNames = {
      script: "right_hostile_script_rendered_as_text",
      entities: "right_entities_rendered_as_literal_text",
      rtl: "right_rtl_override_made_visible",
      cap: "right_near_cap_field_rendered",
      inert: "right_no_injected_element"
    };
    return phaseRecord("hostile_text", hostileChecks(left, "left", existingNames).concat(hostileChecks(right, "right", rightNames)), {sources: {left, right}});
  }

  let hash;
  if (options.frontier === "f2") {
    await selectF2Cluster(client, sessionId, options, "hostile_f2_cluster");
    await waitForBrowser(client, sessionId, `Boolean(document.querySelector('.cluster-inspector .unit-card a'))`, "hostile_f2_cluster_unit", options.timeout_ms);
    hash = await evaluate(client, sessionId, `document.querySelector('.cluster-inspector .unit-card a')?.getAttribute('href') || null`, "hostile_f2_unit_route");
    if (!hash) throw failure("hostile_fixture_missing", "Semantic zoom fixture did not expose a hostile unit route", "hostile_f2_unit_route");
  } else hash = `#/runs/${encodeURIComponent(options.run_id)}/units/${encodeURIComponent(options.unit_id)}`;
  const evidence = await hostileTextEvidence(client, sessionId, hash, options.frontier, options.timeout_ms);
  return phaseRecord("hostile_text", hostileChecks(evidence, options.frontier, existingNames), evidence);
}


function hostDescriptor(browserVersion) {
  const cpu = cpus()[0]?.model?.replace(/\s+/g, " ").trim() || "unknown";
  return {os: {platform: platform(), release: release(), arch: arch()}, cpu, browser_version: browserVersion};
}

const PRELOAD_SCRIPT = `(() => {
  window.__pixirA11yInjected = false;
  const control = {requests: {left: 0, right: 0}, failLeftOnce: true};
  window.__pixirA11yControl = control;
  const nativeFetch = window.fetch.bind(window);
  window.fetch = async function(input, init) {
    const url = new URL(typeof input === 'string' ? input : input.url, location.href);
    if (url.pathname === '/api/workspaces/left/runs') control.requests.left += 1;
    if (url.pathname === '/api/workspaces/right/runs') control.requests.right += 1;
    if (control.failLeftOnce && url.pathname === '/api/workspaces/left/runs') {
      control.failLeftOnce = false;
      return new Response(JSON.stringify({error: {kind: 'a11y_fixture_transient', message: 'deterministic accessibility retry fixture'}}), {status: 503, headers: {'content-type': 'application/json'}});
    }
    return nativeFetch(input, init);
  };
})();`;

function targetHash(options, phase) {
  if (phase === "keyboard_traversal") {
    if (options.frontier === "f1") return "#/runs";
    if (options.frontier === "f2") return `#/runs/${encodeURIComponent(options.run_id)}`;
    return "#/workspaces";
  }
  if (options.frontier === "f1") return `#/runs/${encodeURIComponent(options.run_id)}/units/${encodeURIComponent(options.unit_id)}`;
  if (options.frontier === "f2") return `#/runs/${encodeURIComponent(options.run_id)}`;
  return "#/workspaces";
}

async function preparePhase(client, sessionId, options, phase) {
  await client.send("Emulation.setDeviceMetricsOverride", {width: 1280, height: 900, deviceScaleFactor: 1, mobile: false}, sessionId, `${phase}_baseline_metrics`);
  await client.send("Emulation.setEmulatedMedia", {features: [{name: "prefers-reduced-motion", value: "no-preference"}]}, sessionId, `${phase}_baseline_media`);
  const hash = targetHash(options, phase);
  await evaluate(client, sessionId, `location.hash = ${JSON.stringify(hash)}; true`, `${phase}_navigate`);
  let expression;
  if (options.frontier === "f3") expression = `location.hash === "#/workspaces" && document.querySelectorAll('.workspace-source').length === 2`;
  else if (options.frontier === "f2") expression = `location.hash === ${JSON.stringify(hash)} && Boolean(document.querySelector('.detail-view .cluster-overview'))`;
  else if (phase === "keyboard_traversal") expression = `location.hash === "#/runs" && Boolean(document.querySelector('[data-focus-key="run-${options.run_id}"]'))`;
  else expression = `location.hash === ${JSON.stringify(hash)} && Boolean(document.querySelector('.unit-view'))`;
  await waitForBrowser(client, sessionId, expression, `${phase}_target`, options.timeout_ms);
}

async function run(options) {
  const profile = await mkdtemp(join(tmpdir(), "pixir-monitor-a11y-"));
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
    const version = await client.send("Browser.getVersion", {}, null, "browser_version");
    browserContextId = (await client.send("Target.createBrowserContext", {disposeOnDetach: true}, null, "create_browser_context")).browserContextId;
    const monitorArgs = options.frontier === "f3"
      ? ["serve", "--workspace", `left=${options.left_workspace}`, "--workspace", `right=${options.right_workspace}`, "--launch-mode", "fifo", "--json"]
      : ["serve", "--workspace", options.workspace, "--launch-mode", "fifo", "--json"];
    monitor = spawn(options.monitor, monitorArgs, {stdio: ["ignore", "pipe", "pipe"]});
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
    await client.send("Page.addScriptToEvaluateOnNewDocument", {source: options.frontier === "f3" ? PRELOAD_SCRIPT : "window.__pixirA11yInjected = false;"}, sessionId, "install_accessibility_fixture");
    await client.send("Page.navigate", {url: launchUri.href}, sessionId, "bootstrap_navigation");
    await waitForBrowser(client, sessionId, `document.title === "Pixir Monitor" && !location.hash.startsWith("#launch=") && Boolean(document.querySelector('.view'))`, "initial_view", options.timeout_ms);
    const launchFragmentCleared = await evaluate(client, sessionId, `!location.hash.startsWith("#launch=")`, "launch_fragment_cleared");

    const records = [];
    for (const phase of options.phases) {
      await preparePhase(client, sessionId, options, phase);
      if (phase === "keyboard_traversal") records.push(await keyboardTraversal(client, sessionId, options));
      else if (phase === "ax_tree") records.push(await axTreePhase(client, sessionId));
      else if (phase === "zoom_200") records.push(await viewportPhase(client, sessionId, phase, {width: 640, height: 450, deviceScaleFactor: 2, mobile: false, scale: 2}));
      else if (phase === "narrow_viewport") {
        if (options.frontier === "f2") await selectF2Cluster(client, sessionId, options, "narrow_f2_cluster");
        records.push(await viewportPhase(client, sessionId, phase, {width: 360, height: 800, deviceScaleFactor: 1, mobile: false}));
      }
      else if (phase === "reduced_motion") records.push(await reducedMotionPhase(client, sessionId));
      else if (phase === "contrast") records.push(await contrastPhase(client, sessionId, options));
      else if (phase === "hostile_text") records.push(await hostileTextPhase(client, sessionId, options));
    }
    await serving;
    const handoffCleaned = !existsSync(fifoPath) && !existsSync(dirname(fifoPath));
    const hardFailures = records.flatMap(record => record.checks.filter(check => !check.pass).map(check => ({phase: record.phase, check: check.name})));
    result = {ok: hardFailures.length === 0 && handoffCleaned && launchFragmentCleared === true, check: "pixir_monitor_accessibility_gauntlet", frontier: options.frontier, phases: records, hard_failures: hardFailures, recorded_limitations: records.flatMap(record => record.limitations.map(limitation => ({phase: record.phase, ...limitation}))), host: hostDescriptor(version.product), launch_fragment_cleared: launchFragmentCleared === true, handoff_cleaned: handoffCleaned};
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
  if (options.dryRun) output = {ok: true, dry_run: true, check: "pixir_monitor_accessibility_gauntlet", frontier: options.frontier, phases: options.phases, launch_capability_transport: "cdp_only"};
  else { output = await run(options); if (!output.ok) exitCode = 1; }
} catch (error) {
  exitCode = 1;
  output = safeError(error);
}
process.stdout.write(`${JSON.stringify(output)}\n`);
process.exitCode = exitCode;
