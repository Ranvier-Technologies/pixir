#!/usr/bin/env node

// Gate issue #337 negative-path phases run after the calibrated positive protocol.
async function phase_d_refetch(runtime) {
  const fixture = runtime.workspaces["500"];
  const hash = `#/runs/${encodeURIComponent(fixture.runId)}`;
  await evaluate(runtime, `location.hash = ${JSON.stringify(hash)}; true`, "phase_d_refetch_reset");
  const fixed = await awaitConvergence(runtime, {label: "phase_d_refetch_fixed_point", hash, zoomStart: 0, memberPage: 1, edgePage: 1});
  const samples = [];
  const logPath = join(fixture.path, ".pixir", "sessions", `${fixture.runId}.ndjson`);
  const cycles = runtime.budgets.negative.refetch_cycles;
  for (let cycle = 1; cycle <= cycles; cycle += 1) {
    await evaluate(runtime, `window.__pixirGateZoom = document.querySelector("section.semantic-zoom"); true`, `phase_d_refetch_${cycle}_mark`);
    const seq = fixture.events + cycle;
    const event = {
      id: `event-${fixture.runId}-${seq}`,
      session_id: fixture.runId,
      seq,
      ts: `2026-07-16T00:00:${String(cycle).padStart(2, "0")}Z`,
      type: "assistant_message",
      data: {text: `bench refetch cycle ${cycle}`}
    };
    const started = performance.now();
    await appendFile(logPath, `${JSON.stringify(event)}\n`, "utf8");
    const deadline = performance.now() + runtime.budgets.timeouts_ms.refetch_cycle;
    let replaced = false;
    while (performance.now() < deadline) {
      replaced = await evaluate(runtime, `Boolean(window.__pixirGateZoom && document.querySelector("section.semantic-zoom") && document.querySelector("section.semantic-zoom") !== window.__pixirGateZoom)`, `phase_d_refetch_${cycle}_poll`);
      if (replaced) break;
      await new Promise(resolveWait => setTimeout(resolveWait, 50));
    }
    if (!replaced) throw failure("refetch_invalidation_missed", "An appended Log event did not trigger an authoritative refetch", "phase_d_refetch", {cycle});
    const snapshot = await awaitConvergence(runtime, {label: `phase_d_refetch_${cycle}`, hash, zoomStart: 0, memberPage: 1, edgePage: 1});
    const checks = structuralChecks(snapshot, runtime.budgets.structural, `phase_d_refetch_${cycle}`);
    const fixedPointCardinalities = {
      zoom_subtree_nodes: snapshot.zoom_subtree_nodes === fixed.zoom_subtree_nodes,
      entity_cards: snapshot.entity_cards === fixed.entity_cards,
      cluster_cards: snapshot.cluster_cards === fixed.cluster_cards,
      overflow_cards: snapshot.overflow_cards === fixed.overflow_cards,
      boundary_cards: snapshot.boundary_cards === fixed.boundary_cards,
      distribution_rows: JSON.stringify(snapshot.distribution_rows) === JSON.stringify(fixed.distribution_rows),
      arc_links: snapshot.arc_links === fixed.arc_links,
      member_cards: snapshot.member_cards === fixed.member_cards,
      ledger_rows: snapshot.ledger_rows === fixed.ledger_rows
    };
    const fixedPoint = Object.values(fixedPointCardinalities).every(Boolean);
    if (!fixedPoint || checks.some(check => !check.pass)) throw failure("refetch_fixed_point_failed", "Authoritative refetch did not return to the full structural fixed point", "phase_d_refetch", {cycle, fixed_point_cardinalities: fixedPointCardinalities, failed: checks.filter(check => !check.pass).map(check => check.id)});
    runtime.assertions.push(...checks);
    samples.push({cycle, seq, duration_ms: performance.now() - started, zoom_subtree_nodes: snapshot.zoom_subtree_nodes, fixed_point: fixedPoint, fixed_point_cardinalities: fixedPointCardinalities, structural_green: true});
  }
  runtime.phases.phase_d_refetch = {cycles, fixed_point_nodes: fixed.zoom_subtree_nodes, refetch_samples: samples};
}

async function phase_e_restoration(runtime) {
  const runId = runtime.workspaces["500"].runId;
  const base = `#/runs/${encodeURIComponent(runId)}`;
  const outcomes = {};

  const deepClusterHash = `${base}?zoom=12&cluster=${encodeURIComponent("wave:12:bucket:0")}`;
  await evaluate(runtime, `location.hash = ${JSON.stringify(deepClusterHash)}; true`, "phase_e_deep_cluster");
  await awaitConvergence(runtime, {label: "phase_e_deep_cluster", hash: deepClusterHash, zoomStart: 12, memberPage: 1, minMemberCards: 1});
  const before = await evaluate(runtime, `(() => {
    const link = document.querySelector(".cluster-inspector a[data-focus-key*='member:']");
    if (!link) return null;
    link.scrollIntoView({block: "center"}); link.focus();
    return {href: link.getAttribute("href"), focus: link.dataset.focusKey, scroll_y: window.scrollY, unit_id: link.closest(".unit-card")?.dataset.unitId || null};
  })()`, "phase_e_deep_capture");
  if (!before?.href || !before?.focus || !before?.unit_id) throw failure("restoration_target_missing", "A wave-13 unit deep-link target is missing", "phase_e_restoration");
  for (const type of ["keyDown", "keyUp"]) await runtime.cdp.send("Input.dispatchKeyEvent", {type, key: "Enter", code: "Enter", windowsVirtualKeyCode: 13, nativeVirtualKeyCode: 13}, runtime.sessionId, "phase_e_fresh_unit_navigation");
  const unitReady = await withTimeout((async () => {
    while (true) {
      const value = await evaluate(runtime, `({unit: Boolean(document.querySelector(".unit-view")), id: document.querySelector(".unit-view .lede")?.textContent || ""})`, "phase_e_unit_poll");
      if (value.unit && value.id.includes(before.unit_id)) return value;
      await new Promise(resolveWait => setTimeout(resolveWait, 50));
    }
  })(), runtime.budgets.timeouts_ms.view_convergence, "restoration_unit_timeout", "The unit deep link did not converge", "phase_e_restoration");
  const navigation = await runtime.cdp.send("Page.getNavigationHistory", {}, runtime.sessionId, "phase_e_navigation_history");
  const priorEntry = navigation.entries.slice(0, navigation.currentIndex).reverse().find(entry => entry.url.includes(deepClusterHash));
  if (!priorEntry) throw failure("restoration_history_missing", "The pre-inspector history entry is missing", "phase_e_restoration");
  await runtime.cdp.send("Page.navigateToHistoryEntry", {entryId: priorEntry.id}, runtime.sessionId, "phase_e_unit_back");
  await awaitConvergence(runtime, {label: "phase_e_unit_back", hash: deepClusterHash, zoomStart: 12, memberPage: 1, minMemberCards: 1});
  const restored = await evaluate(runtime, `({focus: document.activeElement?.dataset?.focusKey || null, scroll_y: window.scrollY, selected: Boolean(document.querySelector(".cluster-inspector"))})`, "phase_e_restored_state");
  const restorationPass = restored.selected && restored.focus === before.focus && Math.abs(restored.scroll_y - before.scroll_y) <= runtime.budgets.negative.scroll_tolerance_px;
  if (!restorationPass) throw failure("restoration_failed", "Selection, focus, or scroll was not restored after the unit deep link", "phase_e_restoration", {focus_restored: restored.focus === before.focus, selection_restored: restored.selected, scroll_delta: Math.abs(restored.scroll_y - before.scroll_y)});
  outcomes.deep_link = {unit_ready: unitReady.unit, unit_id: before.unit_id, selection_restored: restored.selected, focus_restored: true, scroll_restored: true, focus_key: before.focus};

  const pageThreeCluster = "wave:0:bucket:0";
  const pageTwoHash = `${base}?cluster=${encodeURIComponent(pageThreeCluster)}&members=2`;
  await evaluate(runtime, `location.hash = ${JSON.stringify(pageTwoHash)}; true`, "phase_e_member_page_2");
  await awaitConvergence(runtime, {label: "phase_e_member_page_2", hash: pageTwoHash, zoomStart: 0, memberPage: 2, minMemberCards: 13});
  const pageThreeDriver = await evaluate(runtime, `(() => { const next = document.querySelector(".cluster-inspector [data-focus-key*='members-next:']"); return {href: next?.getAttribute("href") || null, focus_key: next?.dataset.focusKey || null}; })()`, "phase_e_member_page_3_driver");
  if (!pageThreeDriver.href || !String(pageThreeDriver.focus_key || "").includes("members-next:")) throw failure("member_page_focus_missing", "The app-defined members-next focus target for page 3 is missing", "phase_e_restoration");
  const pageThreeHash = pageThreeDriver.href;
  await evaluate(runtime, `location.hash = ${JSON.stringify(pageThreeHash)}; true`, "phase_e_member_page_3");
  await awaitConvergence(runtime, {label: "phase_e_member_page_3", hash: pageThreeHash, zoomStart: 0, memberPage: 3, minMemberCards: 25});
  const pageFinding = await evaluate(runtime, `(() => { const cards = Array.from(document.querySelectorAll(".cluster-inspector .unit-card")); const next = document.querySelector(".cluster-inspector [data-focus-key*='members-next:']"); return {count: cards.length, first: cards[0]?.dataset.unitId || null, last: cards.at(-1)?.dataset.unitId || null, next_focus_key: next?.dataset.focusKey || null}; })()`, "phase_e_member_page_3_finding");
  if (pageFinding.count !== 36 || pageFinding.next_focus_key !== null) throw failure("member_page_window_failed", "Member page 3 did not render the expected cumulative member window and terminal focus state", "phase_e_restoration", pageFinding);
  outcomes.member_page_3 = {...pageFinding, cluster_key: pageThreeCluster, cumulative_window: true, members_next_focus_key: pageThreeDriver.focus_key};

  await evaluate(runtime, `location.hash = ${JSON.stringify(base)}; true`, "phase_e_keyboard_root");
  await awaitConvergence(runtime, {label: "phase_e_keyboard_root", hash: base, zoomStart: 0, memberPage: 1, edgePage: 1});
  const firstCluster = await evaluate(runtime, `(() => { const node = document.querySelector(".cluster-overview .cluster-cluster a[data-focus-key*='cluster:']"); node?.focus(); return node?.dataset.focusKey || null; })()`, "phase_e_keyboard_focus_cluster");
  if (!firstCluster) throw failure("keyboard_target_missing", "No cluster focus target exists", "phase_e_restoration");
  for (const type of ["keyDown", "keyUp"]) await runtime.cdp.send("Input.dispatchKeyEvent", {type, key: "Enter", code: "Enter", windowsVirtualKeyCode: 13, nativeVirtualKeyCode: 13}, runtime.sessionId, "phase_e_keyboard_enter");
  const selectedHash = await requiredHref(runtime, `Array.from(document.querySelectorAll(".cluster-overview a[data-focus-key]")).find(node => node.dataset.focusKey === ${JSON.stringify(firstCluster)})?.getAttribute("href") || null`, "phase_e_keyboard_selected_hash");
  await awaitConvergence(runtime, {label: "phase_e_keyboard_selected", hash: selectedHash, zoomStart: 0, memberPage: 1, minMemberCards: 1});
  const traversal = [await evaluate(runtime, `document.activeElement?.dataset?.focusKey || null`, "phase_e_keyboard_active_0")];
  for (let step = 0; step < 100 && !String(traversal.at(-1) || "").includes("member:"); step += 1) {
    const expected = await evaluate(runtime, `(() => { const nodes = Array.from(document.querySelectorAll("a[href],button:not([disabled]),select:not([disabled]),summary,[tabindex]:not([tabindex='-1'])")).filter(node => node.getClientRects().length); const index = nodes.indexOf(document.activeElement); return nodes[(index + 1) % nodes.length]?.dataset?.focusKey || null; })()`, `phase_e_keyboard_expected_${step}`);
    for (const type of ["keyDown", "keyUp"]) await runtime.cdp.send("Input.dispatchKeyEvent", {type, key: "Tab", code: "Tab", windowsVirtualKeyCode: 9, nativeVirtualKeyCode: 9}, runtime.sessionId, `phase_e_keyboard_tab_${step}`);
    const actual = await evaluate(runtime, `document.activeElement?.dataset?.focusKey || null`, `phase_e_keyboard_actual_${step}`);
    if (actual !== expected) throw failure("keyboard_order_failed", "Native keyboard traversal diverged from DOM focus order", "phase_e_restoration", {step, expected, actual});
    traversal.push(actual);
  }
  if (!String(traversal.at(-1) || "").includes("member:")) throw failure("keyboard_inspector_unreached", "Tab traversal did not reach the selected cluster inspector", "phase_e_restoration");
  outcomes.keyboard = {enter_selected_cluster: true, order_source: "live_dom", focus_key_order: traversal, inspector_reached: true};
  runtime.phases.phase_e_restoration = {restoration_outcomes: outcomes};
}

async function phase_f_hostile(runtime) {
  runtime.cleanup.phase_f_healthy_monitor_stopped = await stopChild(runtime.activeMonitor, runtime.budgets.timeouts_ms);
  runtime.activeMonitor = null;
  const consoleEvents = [];
  const logEvents = [];
  const dialogs = [];
  const offConsole = runtime.cdp.on("Runtime.consoleAPICalled", (params, sessionId) => {
    if (sessionId === runtime.sessionId) consoleEvents.push({type: params.type, text: (params.args || []).map(arg => String(arg.value ?? arg.description ?? "")).join(" ").slice(0, 2048)});
  });
  const offLog = runtime.cdp.on("Log.entryAdded", (params, sessionId) => {
    if (!sessionId || sessionId === runtime.sessionId) logEvents.push({level: params.entry?.level || "unknown", source: params.entry?.source || "unknown", text: String(params.entry?.text || "").slice(0, 2048)});
  });
  const offDialog = runtime.cdp.on("Page.javascriptDialogOpening", (params, sessionId) => {
    if (sessionId === runtime.sessionId) {
      dialogs.push({type: params.type || "unknown", message: String(params.message || "").slice(0, 256)});
      runtime.cdp.send("Page.handleJavaScriptDialog", {accept: false}, runtime.sessionId, "phase_f_dismiss_unexpected_dialog").catch(() => {});
    }
  });
  await runtime.cdp.send("Log.enable", {}, runtime.sessionId, "phase_f_enable_log");
  const monitor = await launchServe(runtime, runtime.workspaces.hostile.path);
  runtime.activeMonitor = monitor;
  const detailHash = await waitForRunsView(runtime, runtime.workspaces.hostile.runId, "phase_f_hostile");
  await evaluate(runtime, `location.hash = ${JSON.stringify(detailHash)}; true`, "phase_f_hostile_detail");
  await awaitConvergence(runtime, {label: "phase_f_hostile_detail", hash: detailHash, zoomStart: 0, memberPage: 1, edgePage: 1});

  const scriptHash = `${detailHash}?cluster=${encodeURIComponent("wave:1:bucket:0")}`;
  await evaluate(runtime, `location.hash = ${JSON.stringify(scriptHash)}; true`, "phase_f_script_cluster");
  await awaitConvergence(runtime, {label: "phase_f_script_cluster", hash: scriptHash, zoomStart: 0, memberPage: 1, minMemberCards: 1});
  const scriptFinding = await evaluate(runtime, `(() => { const raw = "<script>alert('semantic zoom')</script>"; const textNode = Array.from(document.querySelectorAll(".cluster-inspector .projected-text")).find(node => node.textContent.includes(raw)); const injected = Array.from(document.scripts).some(node => node.textContent.includes("alert('semantic zoom')")); return {raw_text_present: Boolean(textNode), injected_script_present: injected, matching_tag: textNode?.tagName || null}; })()`, "phase_f_script_finding");

  const capHash = `${detailHash}?cluster=${encodeURIComponent("wave:4:bucket:0")}&members=2`;
  await evaluate(runtime, `location.hash = ${JSON.stringify(capHash)}; true`, "phase_f_cap_cluster");
  await awaitConvergence(runtime, {label: "phase_f_cap_cluster", hash: capHash, zoomStart: 0, memberPage: 2, minMemberCards: 20});
  const capFinding = await evaluate(runtime, `(() => { const node = Array.from(document.querySelectorAll(".cluster-inspector .projected-text")).find(candidate => candidate.textContent.startsWith("cap:")); const card = node?.closest(".unit-card"); return {present: Boolean(node), rendered_characters: node?.textContent.length || 0, card_scroll_width: card?.scrollWidth || 0, card_client_width: card?.clientWidth || 0, body_scroll_width: document.body.scrollWidth, viewport_width: document.documentElement.clientWidth, dialog_elements: document.querySelectorAll("dialog").length, truncation_notice: Boolean(node?.parentElement?.querySelector(".truncation"))}; })()`, "phase_f_cap_finding");
  await new Promise(resolveWait => setTimeout(resolveWait, 100));
  offConsole(); offLog(); offDialog();
  const securityPattern = /(script|content security|csp|trusted types|xss|unsafe|injection)/i;
  const securityErrors = [
    ...consoleEvents.filter(entry => entry.type === "error" && securityPattern.test(entry.text)).map(entry => ({channel: "console", ...entry})),
    ...logEvents.filter(entry => entry.level === "error" && securityPattern.test(entry.text)).map(entry => ({channel: "log", ...entry}))
  ];
  const bounded = capFinding.present && capFinding.rendered_characters === 32_768 && capFinding.body_scroll_width <= capFinding.viewport_width + runtime.budgets.negative.horizontal_overflow_tolerance_px;
  if (dialogs.length || capFinding.dialog_elements !== 0 || securityErrors.length || !scriptFinding.raw_text_present || scriptFinding.injected_script_present || !bounded) throw failure("hostile_render_failed", "Hostile projection content was not rendered inertly and within bounds", "phase_f_hostile", {dialogs: dialogs.length, dialog_elements: capFinding.dialog_elements, security_errors: securityErrors.length, script_finding: scriptFinding, cap_finding: capFinding});
  runtime.phases.phase_f_hostile = {hostile_findings: {dialogs, security_errors: securityErrors, console_error_count: consoleEvents.filter(entry => entry.type === "error").length, log_error_count: logEvents.filter(entry => entry.level === "error").length, script_payload: scriptFinding, capped_field: {...capFinding, bounded}}};
}

async function phase_g_red_proof(runtime) {
  runtime.cleanup.phase_g_hostile_monitor_stopped = await stopChild(runtime.activeMonitor, runtime.budgets.timeouts_ms);
  runtime.activeMonitor = null;
  const fixture = runtime.workspaces.redProof;
  const monitor = await launchServe(runtime, fixture.path);
  runtime.activeMonitor = monitor;
  const detailHash = await waitForRunsView(runtime, fixture.runId, "phase_g_red_proof");
  const clusterHash = `${detailHash}?cluster=${encodeURIComponent("wave:0:bucket:0")}`;
  await evaluate(runtime, `location.hash = ${JSON.stringify(clusterHash)}; true`, "phase_g_healthy_navigation");
  const healthyBefore = await awaitConvergence(runtime, {label: "phase_g_healthy_before", hash: clusterHash, zoomStart: 0, memberPage: 1, minMemberCards: 1});
  const beforeChecks = structuralChecks(healthyBefore, runtime.budgets.structural, "phase_g_healthy_before");
  if (beforeChecks.some(check => !check.pass)) throw failure("red_proof_baseline_red", "The red-proof baseline was not green", "phase_g_red_proof", {failed: beforeChecks.filter(check => !check.pass).map(check => check.id)});

  const cloneCount = Math.max(500, runtime.budgets.negative.red_proof_clones);
  const injectedCount = await evaluate(runtime, `(() => { const inspector = document.querySelector("section.semantic-zoom .cluster-inspector"); const real = inspector?.querySelector(".unit-card"); if (!inspector || !real) return 0; for (let index = 0; index < ${cloneCount}; index += 1) { const clone = real.cloneNode(true); clone.dataset.gateRedProofClone = String(index); inspector.append(clone); } return inspector.querySelectorAll(".unit-card[data-gate-red-proof-clone]").length; })()`, "phase_g_inject_clones");
  if (injectedCount < 500) throw failure("red_proof_injection_failed", "The required real member-card clones were not injected", "phase_g_red_proof", {injected_count: injectedCount});
  const poisoned = await evaluate(runtime, DOM_SNAPSHOT_EXPRESSION, "phase_g_poisoned_snapshot");
  const poisonedChecks = structuralChecks(poisoned, runtime.budgets.structural, "phase_g_poisoned");
  const redIds = poisonedChecks.filter(check => !check.pass).map(check => check.id);
  const unexpectedRed = redIds.filter(id => !id.endsWith(":member_page_ceiling"));
  if (!redIds.some(id => id.endsWith(":member_page_ceiling")) || unexpectedRed.length) throw failure("red_proof_did_not_fail_exactly", "The hostile DOM mutation did not turn exactly the member-card bound red", "phase_g_red_proof", {red_ids: redIds, unexpected_red: unexpectedRed});

  await evaluate(runtime, `location.hash = "#/runs"; true`, "phase_g_recovery_runs_navigation");
  await waitForRunsView(runtime, fixture.runId, "phase_g_recovery");
  await evaluate(runtime, `location.hash = ${JSON.stringify(clusterHash)}; true`, "phase_g_recovery_cluster_navigation");
  const recovered = await awaitConvergence(runtime, {label: "phase_g_recovered", hash: clusterHash, zoomStart: 0, memberPage: 1, minMemberCards: 1});
  const recoveryChecks = structuralChecks(recovered, runtime.budgets.structural, "phase_g_recovered");
  if (recoveryChecks.some(check => !check.pass) || recovered.member_cards !== healthyBefore.member_cards) throw failure("red_proof_recovery_failed", "In-product navigation did not restore the authoritative green view", "phase_g_red_proof", {failed: recoveryChecks.filter(check => !check.pass).map(check => check.id), expected_members: healthyBefore.member_cards, actual_members: recovered.member_cards});
  runtime.assertions.push(...beforeChecks, ...recoveryChecks);
  runtime.phases.phase_g_red_proof = {baseline_workspace: "dedicated_pristine_500", red_proof: {injected_clones: injectedCount, poisoned_member_cards: poisoned.member_cards, poisoned_zoom_subtree_nodes: poisoned.zoom_subtree_nodes, assertion_ids_red: redIds, unexpected_assertion_ids_red: unexpectedRed, recovery_green: true, restored_member_cards: recovered.member_cards}};
}

import {spawn} from "node:child_process";
import {constants as fsConstants, existsSync, statSync} from "node:fs";
import {access, appendFile, mkdtemp, readFile, rename, rm, writeFile} from "node:fs/promises";
import {arch, cpus, platform, release, totalmem, tmpdir} from "node:os";
import {dirname, join, resolve} from "node:path";
import {createInterface} from "node:readline";
import {performance} from "node:perf_hooks";
import {fileURLToPath} from "node:url";

const SCRIPT_DIR = dirname(fileURLToPath(import.meta.url));
const BUDGETS_PATH = join(SCRIPT_DIR, "budgets.json");
const CALIBRATION_HEADROOM_FACTOR = 1.25;
const GIBIBYTE = 1024 ** 3;
const HOST_FINGERPRINT_FIELDS = ["os_platform", "os_release", "cpu_model", "core_count", "total_memory_bucket_gib", "chrome_major_version"];

function failure(kind, message, stage, details = {}, exitCode = 1) {
  const error = new Error(message);
  Object.assign(error, {gateKind: kind, gateStage: stage, safeDetails: details, exitCode});
  return error;
}

function safeError(error) {
  return {kind: error?.gateKind || "semantic_zoom_gate_failed", message: error?.gateKind ? error.message : "The semantic zoom gate failed unexpectedly", details: {stage: error?.gateStage || "unknown", ...(error?.safeDetails || {})}};
}

function parseArgs(argv) {
  const options = {json: true, calibrate: false, dryRun: false};
  const valued = new Set(["--monitor", "--browser", "--workdir", "--evidence-out", "--bench-sha", "--previous-evidence"]);
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === "--calibrate") options.calibrate = true;
    else if (arg === "--dry-run") options.dryRun = true;
    else if (arg === "--json") options.json = true;
    else if (valued.has(arg) && index + 1 < argv.length && !argv[index + 1].startsWith("--")) options[arg.slice(2).replaceAll("-", "_")] = argv[++index];
    else throw failure("invalid_arguments", "Unknown or incomplete semantic zoom gate argument", "parse_args", {}, 2);
  }
  return options;
}

async function validateInputs(options, budgets) {
  for (const field of ["monitor", "browser", "workdir", "evidence_out", "bench_sha"]) if (!options[field]) throw failure("missing_required_argument", `Missing required --${field.replaceAll("_", "-")}`, "validate_inputs", {}, 2);
  options.monitor = resolve(options.monitor);
  options.browser = resolve(options.browser);
  options.workdir = resolve(options.workdir);
  options.evidence_out = resolve(options.evidence_out);
  if (options.previous_evidence) options.previous_evidence = resolve(options.previous_evidence);
  for (const [field, path] of [["monitor", options.monitor], ["browser", options.browser]]) {
    if (!existsSync(path) || !statSync(path).isFile()) throw failure(`${field}_missing`, `Required ${field} executable is missing`, "validate_inputs", {}, 2);
    if ((statSync(path).mode & 0o111) === 0) throw failure(`${field}_not_executable`, `Required ${field} file is not executable`, "validate_inputs", {}, 2);
  }
  if (!existsSync(options.workdir) || !statSync(options.workdir).isDirectory()) throw failure("workdir_missing", "Monitor workdir is missing", "validate_inputs", {}, 2);
  if (options.previous_evidence && (!existsSync(options.previous_evidence) || !statSync(options.previous_evidence).isFile())) throw failure("previous_evidence_missing", "Previous evidence file is missing", "validate_inputs", {}, 2);
  if (!existsSync(join(options.workdir, "mix.exs")) || !existsSync(join(options.workdir, "bench", "emit_fixture_workspace.exs"))) throw failure("workdir_invalid", "Monitor workdir lacks required materialization files", "validate_inputs", {}, 2);
  if (!/^[0-9a-fA-F]{7,64}$/.test(options.bench_sha)) throw failure("bench_sha_invalid", "--bench-sha must be a hexadecimal Git object id", "validate_inputs", {}, 2);
  if (!existsSync(dirname(options.evidence_out)) || !statSync(dirname(options.evidence_out)).isDirectory()) throw failure("evidence_parent_missing", "Evidence output parent directory is missing", "validate_inputs", {}, 2);
  try { await access(dirname(options.evidence_out), fsConstants.W_OK); } catch (_error) { throw failure("evidence_parent_not_writable", "Evidence output parent is not writable", "validate_inputs", {}, 2); }
  const requiredPins = ["dom_tolerance", "initial_ceiling", "member_step_nodes", "member_page_2_ceiling", "edge_step_nodes", "edge_page_2_ceiling", "overflow_zoom_ceiling", "k", "denom_floor_ms", "expansion_ratio", "cluster_member_page_1_step_ms", "cluster_member_page_2_step_ms", "arc_edge_page_1_step_ms", "arc_edge_page_2_step_ms", "overflow_level_1_step_ms", "overflow_level_2_step_ms"];
  const requiredNegative = ["refetch_cycles", "scroll_tolerance_px", "horizontal_overflow_tolerance_px", "red_proof_clones"];
  if (requiredNegative.some(name => typeof budgets.negative?.[name] !== "number" || !Number.isFinite(budgets.negative[name]) || budgets.negative[name] < 0) || !Number.isSafeInteger(budgets.negative.refetch_cycles) || budgets.negative.refetch_cycles < 1 || !Number.isSafeInteger(budgets.negative.red_proof_clones) || budgets.negative.red_proof_clones < 500 || typeof budgets.timeouts_ms?.refetch_cycle !== "number" || budgets.timeouts_ms.refetch_cycle <= 0) throw failure("negative_budgets_invalid", "Negative-phase budgets must be finite non-negative numbers, with positive integer refetch cycles, at least 500 integer red-proof clones, and a positive refetch timeout", "validate_budgets", {required_negative: requiredNegative}, 3);
  if (!options.calibrate && !options.dryRun && (budgets.calibrated !== true || requiredPins.some(name => typeof budgets.pins?.[name] !== "number" || !Number.isFinite(budgets.pins[name]) || budgets.pins[name] < 0))) throw failure("budgets_uncalibrated", "Normal mode requires calibrated finite numeric pins", "validate_budgets", {required_pins: requiredPins}, 3);
}
async function materialize(runtime, fixture, outputLabel = fixture) {
  const out = join(runtime.tempRoot, `${outputLabel}u`);
  const child = spawn("mix", ["run", "--no-start", "bench/emit_fixture_workspace.exs", "--fixture", fixture, "--out", out], {cwd: runtime.options.workdir, stdio: ["ignore", "pipe", "pipe"]});
  runtime.children.push(child);
  let stdout = "";
  let stderr = "";
  child.stdout.on("data", chunk => { if (stdout.length < 65_536) stdout += chunk.toString(); });
  child.stderr.on("data", chunk => { if (stderr.length < 65_536) stderr += chunk.toString(); });
  const code = await withTimeout(new Promise((resolveExit, rejectExit) => {
    child.once("error", rejectExit);
    child.once("exit", resolveExit);
  }), runtime.budgets.timeouts_ms.fixture_materialization, "fixture_materialization_timeout", "Fixture materialization timed out", "materialize_fixtures");
  if (code !== 0) throw failure("fixture_materialization_failed", "Fixture materialization failed", "materialize_fixtures", {fixture});
  let record;
  try { record = JSON.parse(stdout.trim().split("\n").at(-1)); } catch (_error) { throw failure("fixture_materialization_invalid", "Fixture materializer did not emit JSON", "materialize_fixtures", {fixture}); }
  if (record.fixture !== fixture || typeof record.run_id !== "string" || !record.run_id) throw failure("fixture_materialization_invalid", "Fixture materializer emitted an invalid record", "materialize_fixtures", {fixture});
  return {path: out, runId: record.run_id, events: record.events};
}
function withTimeout(promise, timeoutMs, kind, message, stage) {
  return new Promise((resolvePromise, rejectPromise) => {
    const timer = setTimeout(() => rejectPromise(failure(kind, message, stage)), timeoutMs);
    Promise.resolve(promise).then(value => { clearTimeout(timer); resolvePromise(value); }, error => { clearTimeout(timer); rejectPromise(error); });
  });
}

async function connectCdp(url, timeouts) {
  if (typeof WebSocket !== "function") throw failure("node_websocket_unavailable", "Node.js must provide a WebSocket client", "connect_cdp", {minimum_node_major: 22}, 2);
  const socket = new WebSocket(url);
  await withTimeout(new Promise((ok, bad) => {
    socket.addEventListener("open", ok, {once: true});
    socket.addEventListener("error", bad, {once: true});
  }), timeouts.cdp_connect, "cdp_connect_timeout", "Chrome DevTools connection timed out", "connect_cdp");
  let nextId = 1;
  const pending = new Map();
  const listeners = new Map();
  function rejectPending(kind) {
    for (const [id, waiter] of pending) { pending.delete(id); waiter.reject(failure(kind, "Chrome DevTools disconnected", waiter.stage)); }
  }
  socket.addEventListener("message", event => {
    const message = JSON.parse(event.data);
    const waiter = pending.get(message.id);
    if (!waiter) {
      for (const listener of listeners.get(message.method) || []) listener(message.params || {}, message.sessionId || null);
      return;
    }
    pending.delete(message.id);
    if (message.error) waiter.reject(failure("cdp_command_failed", "A Chrome DevTools command failed", waiter.stage, {code: message.error.code}));
    else waiter.resolve(message.result);
  });
  socket.addEventListener("close", () => rejectPending("cdp_connection_closed"));
  socket.addEventListener("error", () => rejectPending("cdp_connection_failed"));
  return {
    send(method, params = {}, sessionId = null, stage = "cdp_command") {
      const id = nextId++;
      return withTimeout(new Promise((resolveCommand, rejectCommand) => {
        if (socket.readyState !== WebSocket.OPEN) return rejectCommand(failure("cdp_connection_closed", "Chrome DevTools is not connected", stage));
        pending.set(id, {resolve: resolveCommand, reject: rejectCommand, stage});
        try { socket.send(JSON.stringify({id, method, params, ...(sessionId ? {sessionId} : {})})); }
        catch (_error) { pending.delete(id); rejectCommand(failure("cdp_send_failed", "Could not send a Chrome DevTools command", stage)); }
      }), timeouts.cdp_command, "cdp_command_timeout", "A Chrome DevTools command timed out", stage).finally(() => pending.delete(id));
    },
    on(method, listener) {
      const registered = listeners.get(method) || [];
      registered.push(listener);
      listeners.set(method, registered);
      return () => listeners.set(method, (listeners.get(method) || []).filter(candidate => candidate !== listener));
    },
    close() { socket.close(); }
  };
}

function waitForDevTools(stream, timeoutMs) {
  return withTimeout(new Promise((resolveUrl, rejectUrl) => {
    const lines = createInterface({input: stream});
    let settled = false;
    function finish(callback, value) { if (settled) return; settled = true; lines.close(); callback(value); }
    lines.on("line", line => {
      const match = line.match(/DevTools listening on (ws:\/\/127\.0\.0\.1:\d+\/devtools\/browser\/[A-Za-z0-9-]+)/);
      if (match) finish(resolveUrl, match[1]);
    });
    lines.on("close", () => finish(rejectUrl, failure("browser_readiness_stream_closed", "Chrome closed before exposing DevTools", "start_browser_session")));
  }), timeoutMs, "browser_readiness_timeout", "Chrome did not expose DevTools in time", "start_browser_session");
}

async function startBrowser(runtime) {
  runtime.profile = await mkdtemp(join(tmpdir(), "pixir-monitor-gate-browser-"));
  const browser = spawn(runtime.options.browser, ["--headless=new", "--disable-background-networking", "--disable-component-update", "--disable-default-apps", "--disable-sync", "--metrics-recording-only", "--no-first-run", "--no-default-browser-check", "--remote-debugging-port=0", `--user-data-dir=${runtime.profile}`, "about:blank"], {stdio: ["ignore", "ignore", "pipe"]});
  runtime.browser = browser;
  runtime.children.push(browser);
  const spawnFailed = new Promise((_resolveSpawn, rejectSpawn) => browser.once("error", error => rejectSpawn(failure("browser_spawn_failed", "Chrome could not be started", "start_browser_session", {code: error?.code || "unknown"}))));
  const devtoolsUrl = await Promise.race([waitForDevTools(browser.stderr, runtime.budgets.timeouts_ms.browser_readiness), spawnFailed]);
  runtime.cdp = await connectCdp(devtoolsUrl, runtime.budgets.timeouts_ms);
  runtime.browserVersion = await runtime.cdp.send("Browser.getVersion", {}, null, "browser_version");
  runtime.contextId = (await runtime.cdp.send("Target.createBrowserContext", {disposeOnDetach: true}, null, "create_browser_context")).browserContextId;
  const target = await runtime.cdp.send("Target.createTarget", {url: "about:blank", browserContextId: runtime.contextId}, null, "create_page");
  runtime.sessionId = (await runtime.cdp.send("Target.attachToTarget", {targetId: target.targetId, flatten: true}, null, "attach_page")).sessionId;
  await runtime.cdp.send("Runtime.enable", {}, runtime.sessionId, "enable_runtime");
  await runtime.cdp.send("Page.enable", {}, runtime.sessionId, "enable_page");
  await runtime.cdp.send("Performance.enable", {}, runtime.sessionId, "enable_performance");
}

async function stopChild(child, timeouts) {
  const stopped = () => !child || child.exitCode !== null || child.signalCode !== null;
  if (stopped()) return true;
  child.kill("SIGTERM");
  await Promise.race([new Promise(resolveExit => child.once("exit", resolveExit)), new Promise(resolveWait => setTimeout(resolveWait, timeouts.child_term_grace))]);
  if (!stopped()) {
    child.kill("SIGKILL");
    await Promise.race([new Promise(resolveExit => child.once("exit", resolveExit)), new Promise(resolveWait => setTimeout(resolveWait, timeouts.child_kill_grace))]);
  }
  return stopped();
}
function waitForJsonLine(stream, predicate, stage, timeoutMs) {
  return withTimeout(new Promise((resolveValue, rejectValue) => {
    const lines = createInterface({input: stream});
    let settled = false;
    function finish(callback, value) { if (settled) return; settled = true; lines.close(); callback(value); }
    lines.on("line", line => { try { const value = JSON.parse(line); if (predicate(value)) finish(resolveValue, value); } catch (_error) {} });
    lines.on("close", () => finish(rejectValue, failure("process_readiness_stream_closed", "A child readiness stream closed early", stage)));
  }), timeoutMs, "process_readiness_timeout", "A child did not emit its readiness record in time", stage);
}

async function launchServe(runtime, workspace) {
  const monitor = spawn(runtime.options.monitor, ["serve", "--workspace", workspace, "--launch-mode", "fifo", "--json"], {stdio: ["ignore", "pipe", "pipe"]});
  runtime.monitors.push(monitor);
  const spawnFailed = new Promise((_resolveSpawn, rejectSpawn) => monitor.once("error", error => rejectSpawn(failure("monitor_spawn_failed", "Pixir Monitor could not be started", "monitor_readiness", {code: error?.code || "unknown"}))));
  const serving = Promise.race([waitForJsonLine(monitor.stdout, value => value?.ok === true && value?.status === "serving", "monitor_serving", runtime.budgets.timeouts_ms.monitor_serving), spawnFailed]);
  serving.catch(() => {});
  const ready = await Promise.race([waitForJsonLine(monitor.stderr, value => value?.ok === true && value?.status === "ready" && value?.launch_mode === "fifo" && typeof value?.fifo_path === "string", "monitor_readiness", runtime.budgets.timeouts_ms.monitor_readiness), spawnFailed]);
  let launchUrl = (await withTimeout(readFile(ready.fifo_path, "utf8"), runtime.budgets.timeouts_ms.fifo_handoff, "fifo_handoff_timeout", "Monitor did not issue its one-use handoff", "fifo_handoff")).trim();
  if (!/^http:\/\/127\.0\.0\.1:\d+\/#launch=/.test(launchUrl)) throw failure("invalid_launch_handoff", "Monitor emitted an invalid launch handoff", "fifo_handoff");
  await runtime.cdp.send("Page.navigate", {url: launchUrl}, runtime.sessionId, "launch_navigation");
  launchUrl = "";
  await serving;
  return monitor;
}
async function evaluate(runtime, expression, stage) {
  const result = await runtime.cdp.send("Runtime.evaluate", {expression, returnByValue: true, awaitPromise: true}, runtime.sessionId, stage);
  if (result.exceptionDetails) throw failure("browser_expression_failed", "A browser measurement expression failed", stage);
  return result.result?.value;
}

const DOM_SNAPSHOT_EXPRESSION = `(() => {
  const zoom = document.querySelector("section.semantic-zoom");
  if (!zoom) return null;
  const cards = Array.from(zoom.querySelectorAll(":scope > .cluster-overview > .cluster-card"));
  const params = new URLSearchParams(location.hash.split("?")[1] || "");
  const zoomStart = Number(zoom.dataset.zoomStart || "0");
  const distributions = cards.map(card => card.querySelectorAll(":scope .cluster-distribution").length);
  const sourcePresentations = Array.from(zoom.children).filter(node => node.matches && node.matches("p.provenance") && node.textContent.startsWith("Source (run-scoped)" )).length;
  return {
    hash: location.hash,
    zoom_start: zoomStart,
    zoom_subtree_nodes: zoom.querySelectorAll("*").length,
    body_total_nodes: document.body.querySelectorAll("*").length,
    entity_cards: cards.length,
    cluster_cards: cards.filter(card => card.classList.contains("cluster-cluster")).length,
    overflow_cards: cards.filter(card => card.classList.contains("cluster-overflow")).length,
    boundary_cards: cards.filter(card => card.classList.contains("cluster-boundary")).length,
    distribution_rows: distributions,
    run_scoped_source_presentations: sourcePresentations,
    arc_links: zoom.querySelectorAll(":scope > .aggregate-arcs a").length,
    member_cards: zoom.querySelectorAll(":scope > .cluster-inspector .unit-card").length,
    ledger_rows: zoom.querySelectorAll(":scope > .exact-edge-ledger ol > li").length,
    member_page: Math.max(1, Number(params.get("members") || "1")),
    edge_page: Math.max(1, Number(params.get("edges") || "1")),
    error: Boolean(document.querySelector(".error-view")),
    detail: Boolean(document.querySelector(".detail-view"))
  };
})()`;

async function awaitConvergence(runtime, expected) {
  const deadline = performance.now() + runtime.budgets.timeouts_ms.view_convergence;
  while (performance.now() < deadline) {
    const snapshot = await evaluate(runtime, DOM_SNAPSHOT_EXPRESSION, `${expected.label}_poll`);
    if (snapshot && snapshot.detail && !snapshot.error && snapshot.entity_cards > 0 && (!expected.hash || snapshot.hash === expected.hash) && (expected.zoomStart === undefined || snapshot.zoom_start === expected.zoomStart) && (expected.memberPage === undefined || snapshot.member_page === expected.memberPage) && (expected.edgePage === undefined || snapshot.edge_page === expected.edgePage) && (expected.minArcLinks === undefined || snapshot.arc_links >= expected.minArcLinks) && (expected.minMemberCards === undefined || snapshot.member_cards >= expected.minMemberCards) && (expected.memberCards === undefined || snapshot.member_cards === expected.memberCards) && (expected.minLedgerRows === undefined || snapshot.ledger_rows >= expected.minLedgerRows)) return snapshot;
    await new Promise(resolveWait => setTimeout(resolveWait, 50));
  }
  throw failure("browser_convergence_timeout", "The semantic zoom view did not converge", expected.label);
}

function structuralChecks(snapshot, structural, label) {
  const entityCeiling = snapshot.zoom_start === 0 ? structural.level_zero_entity_cards : structural.deeper_entity_cards;
  const arcCeiling = snapshot.entity_cards * (snapshot.entity_cards - 1) / 2 + 1;
  return [
    ["entity_ceiling", snapshot.entity_cards <= entityCeiling, snapshot.entity_cards, entityCeiling],
    ["cluster_card_ceiling", snapshot.cluster_cards <= structural.cluster_cards, snapshot.cluster_cards, structural.cluster_cards],
    ["overflow_card_ceiling", snapshot.overflow_cards <= structural.overflow_cards, snapshot.overflow_cards, structural.overflow_cards],
    ["boundary_card_ceiling", snapshot.boundary_cards <= structural.boundary_cards, snapshot.boundary_cards, structural.boundary_cards],
    ["boundary_level_rule", snapshot.boundary_cards === (snapshot.zoom_start > 0 ? 1 : 0), snapshot.boundary_cards, snapshot.zoom_start > 0 ? 1 : 0],
    ["distribution_rows", snapshot.distribution_rows.length === snapshot.entity_cards && snapshot.distribution_rows.every(count => count === structural.distribution_rows_per_entity), snapshot.distribution_rows, structural.distribution_rows_per_entity],
    ["run_scoped_source_once", snapshot.run_scoped_source_presentations === structural.run_scoped_source_presentations, snapshot.run_scoped_source_presentations, structural.run_scoped_source_presentations],
    ["arc_minimum", snapshot.zoom_start !== 0 || snapshot.arc_links >= structural.level_zero_arc_links_min, snapshot.arc_links, structural.level_zero_arc_links_min],
    ["arc_ceiling", snapshot.arc_links <= arcCeiling, snapshot.arc_links, arcCeiling],
    ["member_page_ceiling", snapshot.member_cards <= structural.member_page_size * snapshot.member_page, snapshot.member_cards, structural.member_page_size * snapshot.member_page],
    ["edge_page_ceiling", snapshot.ledger_rows <= structural.edge_page_size * snapshot.edge_page, snapshot.ledger_rows, structural.edge_page_size * snapshot.edge_page]
  ].map(([name, pass, actual, limit]) => ({id: `B1s:${label}:${name}`, pass, actual, limit}));
}
async function performanceMetrics(runtime) {
  const result = await runtime.cdp.send("Performance.getMetrics", {}, runtime.sessionId, "performance_metrics");
  const values = Object.fromEntries(result.metrics.map(metric => [metric.name, metric.value]));
  const metrics = {JSHeapUsedSize: values.JSHeapUsedSize ?? null, Nodes: values.Nodes ?? null};
  if (!Number.isFinite(metrics.JSHeapUsedSize) || !Number.isFinite(metrics.Nodes)) throw failure("performance_metrics_missing", "Chrome omitted required Performance metrics", "performance_metrics");
  return metrics;
}

async function waitForRunsView(runtime, runId, label) {
  const wanted = `#/runs/${encodeURIComponent(runId)}`;
  const deadline = performance.now() + runtime.budgets.timeouts_ms.view_convergence;
  while (performance.now() < deadline) {
    const ready = await evaluate(runtime, `document.title === "Pixir Monitor" && location.hash.startsWith("#/runs") && !location.hash.startsWith("#launch=") && Array.from(document.querySelectorAll("a")).some(link => link.getAttribute("href") === ${JSON.stringify(wanted)}) && !document.querySelector(".error-view")`, `${label}_runs_poll`);
    if (ready) return wanted;
    await new Promise(resolveWait => setTimeout(resolveWait, 50));
  }
  throw failure("browser_convergence_timeout", "The Runs view did not converge", `${label}_runs`);
}

async function measureInitial(runtime, fixture, label) {
  const monitor = await launchServe(runtime, fixture.path);
  runtime.activeMonitor = monitor;
  const detailHash = await waitForRunsView(runtime, fixture.runId, label);
  const before = await performanceMetrics(runtime);
  const started = performance.now();
  await evaluate(runtime, `location.hash = ${JSON.stringify(detailHash)}; true`, `${label}_navigate_detail`);
  const snapshot = await awaitConvergence(runtime, {label, hash: detailHash, zoomStart: 0, memberPage: 1, edgePage: 1, minArcLinks: 1});
  const renderMs = performance.now() - started;
  const after = await performanceMetrics(runtime);
  return {...snapshot, render_ms: renderMs, performance: {before, after, delta: {JSHeapUsedSize: after.JSHeapUsedSize - before.JSHeapUsedSize, Nodes: after.Nodes - before.Nodes}}};
}

async function phaseA100(runtime) {
  runtime.phases.phase_a_100_initial = await measureInitial(runtime, runtime.workspaces["100"], "phase_a_100_initial");
  runtime.cleanup.phase_a_monitor_stopped = await stopChild(runtime.activeMonitor, runtime.budgets.timeouts_ms);
  runtime.activeMonitor = null;
}

async function phaseB500(runtime) {
  runtime.phases.phase_b_500_initial = await measureInitial(runtime, runtime.workspaces["500"], "phase_b_500_initial");
}
async function requiredHref(runtime, expression, stage) {
  const href = await evaluate(runtime, expression, stage);
  if (typeof href !== "string" || !href.startsWith("#/runs/")) throw failure("expansion_target_missing", "A required semantic zoom expansion target is missing", stage);
  return href;
}

async function navigateMeasured(runtime, label, href, expected = {}) {
  const started = performance.now();
  await evaluate(runtime, `location.hash = ${JSON.stringify(href)}; true`, `${label}_navigate`);
  const snapshot = await awaitConvergence(runtime, {label, hash: href, ...expected});
  return {...snapshot, step_latency_ms: performance.now() - started};
}

async function phaseCExpansion(runtime) {
  const states = {};
  const clusterHref = await requiredHref(runtime, `document.querySelector("section.semantic-zoom .cluster-cluster a[data-focus-key*='cluster:']")?.getAttribute("href")`, "select_cluster");
  states.cluster_member_page_1 = await navigateMeasured(runtime, "cluster_member_page_1", clusterHref, {zoomStart: 0, memberPage: 1, edgePage: 1, minMemberCards: 1});
  const memberHref = await requiredHref(runtime, `document.querySelector("section.semantic-zoom .cluster-inspector a[data-focus-key*='members-next:']")?.getAttribute("href")`, "select_member_page_2");
  states.cluster_member_page_2 = await navigateMeasured(runtime, "cluster_member_page_2", memberHref, {zoomStart: 0, memberPage: 2, edgePage: 1, minMemberCards: 13});
  const arcHref = await requiredHref(runtime, `(() => { const links = Array.from(document.querySelectorAll("section.semantic-zoom .aggregate-arcs a[data-focus-key*='arc:']")); const link = links.find(node => { const match = node.textContent.match(/ · (\\d+) observed edges/); return match && Number(match[1]) > 100; }); return link?.getAttribute("href") || null; })()`, "select_arc");
  states.arc_edge_page_1 = await navigateMeasured(runtime, "arc_edge_page_1", arcHref, {zoomStart: 0, memberPage: 1, edgePage: 1, memberCards: 0, minLedgerRows: 1});
  const edgeHref = await requiredHref(runtime, `document.querySelector("section.semantic-zoom .exact-edge-ledger a[data-focus-key*='edges-next:']")?.getAttribute("href")`, "select_edge_page_2");
  states.arc_edge_page_2 = await navigateMeasured(runtime, "arc_edge_page_2", edgeHref, {zoomStart: 0, memberPage: 1, edgePage: 2, memberCards: 0, minLedgerRows: 101});
  const overflowOneHref = await requiredHref(runtime, `document.querySelector("section.semantic-zoom .cluster-overflow a[data-focus-key*='overflow:']")?.getAttribute("href")`, "select_overflow_level_1");
  states.overflow_level_1 = await navigateMeasured(runtime, "overflow_level_1", overflowOneHref, {zoomStart: 6, memberPage: 1, edgePage: 1});
  const overflowTwoHref = await requiredHref(runtime, `document.querySelector("section.semantic-zoom .cluster-overflow a[data-focus-key*='overflow:']")?.getAttribute("href")`, "select_overflow_level_2");
  states.overflow_level_2 = await navigateMeasured(runtime, "overflow_level_2", overflowTwoHref, {zoomStart: 12, memberPage: 1, edgePage: 1});
  runtime.phases.phase_c_500_expansion_walk = states;
}
function ceil100(value) { return Math.ceil(value * 100) / 100; }

function calibrate(runtime) {
  const a = runtime.phases.phase_a_100_initial;
  const b = runtime.phases.phase_b_500_initial;
  const c = runtime.phases.phase_c_500_expansion_walk;
  const memberDelta = Math.max(0, c.cluster_member_page_2.zoom_subtree_nodes - c.cluster_member_page_1.zoom_subtree_nodes);
  const edgeDelta = Math.max(0, c.arc_edge_page_2.zoom_subtree_nodes - c.arc_edge_page_1.zoom_subtree_nodes);
  const maximumLatency = Math.max(...Object.values(c).map(state => state.step_latency_ms));
  return {
    dom_tolerance: Math.ceil(Math.abs(b.zoom_subtree_nodes - a.zoom_subtree_nodes) * CALIBRATION_HEADROOM_FACTOR) + 10,
    initial_ceiling: Math.ceil(b.body_total_nodes * 1.20) + 50,
    member_step_nodes: Math.ceil(memberDelta * CALIBRATION_HEADROOM_FACTOR) + 20,
    member_page_2_ceiling: Math.ceil(c.cluster_member_page_2.zoom_subtree_nodes * 1.15) + 20,
    edge_step_nodes: Math.ceil(edgeDelta * CALIBRATION_HEADROOM_FACTOR) + 20,
    edge_page_2_ceiling: Math.ceil(c.arc_edge_page_2.zoom_subtree_nodes * 1.15) + 20,
    overflow_zoom_ceiling: Math.ceil(Math.max(c.overflow_level_1.zoom_subtree_nodes, c.overflow_level_2.zoom_subtree_nodes) * 1.15) + 20,
    k: ceil100(Math.max(1.50, b.render_ms / Math.max(a.render_ms, 25) * CALIBRATION_HEADROOM_FACTOR)),
    denom_floor_ms: 25,
    expansion_ratio: ceil100(Math.max(2.00, maximumLatency / Math.max(b.render_ms, 1) * CALIBRATION_HEADROOM_FACTOR)),
    cluster_member_page_1_step_ms: Math.max(Math.ceil(c.cluster_member_page_1.step_latency_ms * CALIBRATION_HEADROOM_FACTOR), 25),
    cluster_member_page_2_step_ms: Math.max(Math.ceil(c.cluster_member_page_2.step_latency_ms * CALIBRATION_HEADROOM_FACTOR), 25),
    arc_edge_page_1_step_ms: Math.max(Math.ceil(c.arc_edge_page_1.step_latency_ms * CALIBRATION_HEADROOM_FACTOR), 25),
    arc_edge_page_2_step_ms: Math.max(Math.ceil(c.arc_edge_page_2.step_latency_ms * CALIBRATION_HEADROOM_FACTOR), 25),
    overflow_level_1_step_ms: Math.max(Math.ceil(c.overflow_level_1.step_latency_ms * CALIBRATION_HEADROOM_FACTOR), 25),
    overflow_level_2_step_ms: Math.max(Math.ceil(c.overflow_level_2.step_latency_ms * CALIBRATION_HEADROOM_FACTOR), 25)
  };
}

function memoryBucket(bytes) {
  return Number.isFinite(bytes) && bytes > 0 ? Math.round(bytes / GIBIBYTE) : null;
}

function chromeMajor(product) {
  const match = String(product || "").match(/(?:Chrome|Chromium)\/(\d+)/);
  return match ? Number(match[1]) : null;
}

function hostFingerprintFromArtifact(artifact) {
  if (artifact?.host_fingerprint) return artifact.host_fingerprint;
  return {
    os_platform: artifact?.host?.os ?? null,
    os_release: artifact?.host?.os_release ?? null,
    cpu_model: artifact?.host?.cpu_model ?? null,
    core_count: artifact?.host?.core_count ?? null,
    total_memory_bucket_gib: memoryBucket(artifact?.host?.memory_bytes),
    chrome_major_version: chromeMajor(artifact?.chrome?.product)
  };
}

function currentHostFingerprint(runtime) {
  const cpuList = cpus();
  return {
    os_platform: platform(),
    os_release: release(),
    cpu_model: cpuList[0]?.model || "unknown",
    core_count: cpuList.length,
    total_memory_bucket_gib: memoryBucket(totalmem()),
    chrome_major_version: chromeMajor(runtime.browserVersion?.product)
  };
}

function comparableStates(phases) {
  return {
    phase_a_100_initial: phases?.phase_a_100_initial,
    phase_b_500_initial: phases?.phase_b_500_initial,
    ...Object.fromEntries(Object.entries(phases?.phase_c_500_expansion_walk || {}).map(([name, state]) => [`phase_c_500_expansion_walk.${name}`, state]))
  };
}

function structuralCardinality(state, metric) {
  if (metric === "distribution_rows") return Array.isArray(state?.distribution_rows) ? state.distribution_rows.reduce((sum, count) => sum + count, 0) : null;
  return state?.[metric];
}

function comparePreviousEvidence(runtime) {
  const currentFingerprint = currentHostFingerprint(runtime);
  runtime.hostFingerprint = currentFingerprint;
  if (!runtime.previousEvidence) {
    runtime.regressionComparison = {compared: false, reason: "previous_evidence_not_provided", table: []};
    return;
  }

  const previousFingerprint = hostFingerprintFromArtifact(runtime.previousEvidence);
  const fingerprintMatches = HOST_FINGERPRINT_FIELDS.every(field => previousFingerprint?.[field] === currentFingerprint[field]);
  if (!fingerprintMatches) {
    runtime.regressionComparison = {
      compared: false,
      reason: "host_fingerprint_mismatch",
      current_host_fingerprint: currentFingerprint,
      previous_host_fingerprint: previousFingerprint,
      table: []
    };
    return;
  }

  const table = [];
  const currentStates = comparableStates(runtime.phases);
  const previousStates = comparableStates(runtime.previousEvidence.phases);
  const domTolerance = runtime.enforcedOrProposedPins.dom_tolerance;
  const cardinalities = ["body_total_nodes", "entity_cards", "cluster_cards", "overflow_cards", "boundary_cards", "distribution_rows", "run_scoped_source_presentations", "arc_links", "member_cards", "ledger_rows"];
  for (const [phase, current] of Object.entries(currentStates)) {
    const previous = previousStates[phase];
    if (!current || !previous) throw failure("previous_evidence_invalid", "Previous evidence lacks a comparable semantic zoom phase", "compare_previous_evidence", {phase}, 2);
    if (!Number.isFinite(previous.zoom_subtree_nodes) || !Number.isFinite(current.zoom_subtree_nodes)) throw failure("previous_evidence_invalid", "Previous evidence lacks a comparable zoom subtree count", "compare_previous_evidence", {phase}, 2);
    table.push({kind: "zoom_subtree_nodes", phase, metric: "zoom_subtree_nodes", previous: previous.zoom_subtree_nodes, current: current.zoom_subtree_nodes, delta: current.zoom_subtree_nodes - previous.zoom_subtree_nodes, allowed_max: previous.zoom_subtree_nodes + domTolerance, pass: current.zoom_subtree_nodes <= previous.zoom_subtree_nodes + domTolerance});
    for (const metric of cardinalities) {
      const previousValue = structuralCardinality(previous, metric);
      const currentValue = structuralCardinality(current, metric);
      if (!Number.isFinite(previousValue) || !Number.isFinite(currentValue)) throw failure("previous_evidence_invalid", "Previous evidence lacks a comparable structural cardinality", "compare_previous_evidence", {phase, metric}, 2);
      table.push({kind: "structural_cardinality", phase, metric, previous: previousValue, current: currentValue, delta: currentValue - previousValue, allowed_max: previousValue, pass: currentValue <= previousValue});
    }
  }
  const previousRender = runtime.previousEvidence.phases?.phase_b_500_initial?.render_ms;
  const currentRender = runtime.phases.phase_b_500_initial.render_ms;
  if (!Number.isFinite(previousRender)) throw failure("previous_evidence_invalid", "Previous evidence lacks render_ms_500", "compare_previous_evidence", {}, 2);
  table.push({kind: "render_ms_500", phase: "phase_b_500_initial", metric: "render_ms", previous: previousRender, current: currentRender, delta: currentRender - previousRender, headroom_factor: CALIBRATION_HEADROOM_FACTOR, allowed_max: previousRender * CALIBRATION_HEADROOM_FACTOR, pass: currentRender <= previousRender * CALIBRATION_HEADROOM_FACTOR});

  runtime.regressionComparison = {
    compared: true,
    reason: null,
    previous_bench_sha: runtime.previousEvidence.bench_sha ?? null,
    current_host_fingerprint: currentFingerprint,
    previous_host_fingerprint: previousFingerprint,
    dom_tolerance: domTolerance,
    render_headroom_factor: CALIBRATION_HEADROOM_FACTOR,
    table
  };
  const regressions = table.filter(row => !row.pass);
  if (regressions.length) throw failure("performance_regression", "Same-host evidence exceeded one or more regression limits", "compare_previous_evidence", {failed: regressions.map(row => `${row.phase}:${row.metric}`)}, 4);
}

function assertGate(runtime) {
  const structural = runtime.budgets.structural;
  const states = [["phase_a_100_initial", runtime.phases.phase_a_100_initial], ["phase_b_500_initial", runtime.phases.phase_b_500_initial], ...Object.entries(runtime.phases.phase_c_500_expansion_walk)];
  for (const [label, snapshot] of states) runtime.assertions.push(...structuralChecks(snapshot, structural, label));
  if (!runtime.options.calibrate) {
    const pins = runtime.budgets.pins;
    const a = runtime.phases.phase_a_100_initial;
    const b = runtime.phases.phase_b_500_initial;
    const c = runtime.phases.phase_c_500_expansion_walk;
    const memberDelta = c.cluster_member_page_2.zoom_subtree_nodes - c.cluster_member_page_1.zoom_subtree_nodes;
    const edgeDelta = c.arc_edge_page_2.zoom_subtree_nodes - c.arc_edge_page_1.zoom_subtree_nodes;
    runtime.assertions.push(
      {id: "B1:same_session_zoom_delta", pass: Math.abs(b.zoom_subtree_nodes - a.zoom_subtree_nodes) <= pins.dom_tolerance, actual: Math.abs(b.zoom_subtree_nodes - a.zoom_subtree_nodes), limit: pins.dom_tolerance},
      {id: "B2:body_total_nodes_500", pass: b.body_total_nodes <= pins.initial_ceiling, actual: b.body_total_nodes, limit: pins.initial_ceiling},
      {id: "B3a:member_additive_step", pass: memberDelta <= pins.member_step_nodes, actual: memberDelta, limit: pins.member_step_nodes},
      {id: "B3a:member_page_2_result", pass: c.cluster_member_page_2.zoom_subtree_nodes <= pins.member_page_2_ceiling, actual: c.cluster_member_page_2.zoom_subtree_nodes, limit: pins.member_page_2_ceiling},
      {id: "B3a:edge_additive_step", pass: edgeDelta <= pins.edge_step_nodes, actual: edgeDelta, limit: pins.edge_step_nodes},
      {id: "B3a:edge_page_2_result", pass: c.arc_edge_page_2.zoom_subtree_nodes <= pins.edge_page_2_ceiling, actual: c.arc_edge_page_2.zoom_subtree_nodes, limit: pins.edge_page_2_ceiling},
      {id: "B3b:overflow_level_1_window", pass: c.overflow_level_1.zoom_subtree_nodes <= pins.overflow_zoom_ceiling, actual: c.overflow_level_1.zoom_subtree_nodes, limit: pins.overflow_zoom_ceiling},
      {id: "B3b:overflow_level_2_window", pass: c.overflow_level_2.zoom_subtree_nodes <= pins.overflow_zoom_ceiling, actual: c.overflow_level_2.zoom_subtree_nodes, limit: pins.overflow_zoom_ceiling},
      {id: "B4:render_ratio", pass: b.render_ms <= pins.k * Math.max(a.render_ms, pins.denom_floor_ms), actual: b.render_ms, limit: pins.k * Math.max(a.render_ms, pins.denom_floor_ms)}
    );
    for (const [label, state] of Object.entries(c)) {
      runtime.assertions.push({id: `B5:${label}`, pass: state.step_latency_ms <= pins.expansion_ratio * b.render_ms, actual: state.step_latency_ms, limit: pins.expansion_ratio * b.render_ms});
      runtime.assertions.push({id: `B5a:${label}`, pass: state.step_latency_ms <= pins[`${label}_step_ms`], actual: state.step_latency_ms, limit: pins[`${label}_step_ms`]});
    }
  }
  const failed = runtime.assertions.filter(assertion => !assertion.pass);
  if (failed.length) throw failure("budget_assertion_failed", "One or more semantic zoom gate assertions failed", "assert_gate", {failed: failed.map(assertion => assertion.id)});
}
async function emitArtifact(runtime) {
  const cpuList = cpus();
  const cleanupGreen = Object.values(runtime.cleanup).every(value => value === true);
  const artifact = {
    schema: "pixir.monitor.semantic_zoom_gate.evidence",
    schema_version: 3,
    ticket: 337,
    ok: runtime.error === null && runtime.assertions.every(assertion => assertion.pass) && cleanupGreen,
    mode: runtime.options.dryRun ? "dry_run" : runtime.options.calibrate ? "calibrate" : "enforce",
    bench_sha: runtime.options.bench_sha,
    host: {os: platform(), os_release: release(), architecture: arch(), cpu_model: cpuList[0]?.model || "unknown", core_count: cpuList.length, memory_bytes: totalmem()},
    host_fingerprint: runtime.hostFingerprint || currentHostFingerprint(runtime),
    chrome: runtime.browserVersion ? {product: runtime.browserVersion.product, protocol_version: runtime.browserVersion.protocolVersion, user_agent: runtime.browserVersion.userAgent, js_version: runtime.browserVersion.jsVersion} : null,
    regression_comparison: runtime.regressionComparison,
    budgets: runtime.budgets,
    phases: runtime.phases,
    negative: {
      refetch_samples: runtime.phases.phase_d_refetch?.refetch_samples || [],
      restoration_outcomes: runtime.phases.phase_e_restoration?.restoration_outcomes || null,
      hostile_findings: runtime.phases.phase_f_hostile?.hostile_findings || null,
      red_proof: runtime.phases.phase_g_red_proof?.red_proof || null
    },
    assertions: runtime.assertions,
    pins: runtime.options.calibrate ? {proposed: runtime.enforcedOrProposedPins || null} : {enforced: runtime.enforcedOrProposedPins || runtime.budgets.pins},
    error: runtime.error,
    cleanup: runtime.cleanup
  };
  const temporary = `${runtime.options.evidence_out}.tmp`;
  await writeFile(temporary, `${JSON.stringify(artifact, null, 2)}\n`, {encoding: "utf8", mode: 0o600});
  await rename(temporary, runtime.options.evidence_out);
  runtime.evidenceWritten = true;
}
async function cleanup(runtime) {
  if (runtime.cleanupComplete) return;
  const timeouts = runtime.budgets.timeouts_ms;
  const monitorResults = [];
  for (const monitor of runtime.monitors) monitorResults.push(await stopChild(monitor, timeouts));
  const otherChildren = runtime.children.filter(child => child !== runtime.browser && !runtime.monitors.includes(child));
  const otherChildResults = [];
  for (const child of otherChildren) otherChildResults.push(await stopChild(child, timeouts));
  if (runtime.cdp) {
    if (runtime.contextId) { try { await runtime.cdp.send("Target.disposeBrowserContext", {browserContextId: runtime.contextId}, null, "dispose_browser_context"); } catch (_error) {} }
    try { await runtime.cdp.send("Browser.close", {}, null, "close_browser"); } catch (_error) {}
    runtime.cdp.close();
  }
  const browserStopped = await stopChild(runtime.browser, timeouts);
  if (runtime.profile) await rm(runtime.profile, {recursive: true, force: true});
  if (runtime.tempRoot) await rm(runtime.tempRoot, {recursive: true, force: true});
  runtime.cleanup = {
    ...runtime.cleanup,
    browser_stopped: browserStopped,
    monitors_stopped: monitorResults.every(Boolean),
    materializers_stopped: otherChildResults.every(Boolean),
    profile_removed: !runtime.profile || !existsSync(runtime.profile),
    fixture_root_removed: !runtime.tempRoot || !existsSync(runtime.tempRoot)
  };
  runtime.cleanupComplete = true;
}

async function loadPreviousEvidence(path) {
  if (!path) return null;
  let artifact;
  try { artifact = JSON.parse(await readFile(path, "utf8")); }
  catch (_error) { throw failure("previous_evidence_invalid", "Previous evidence must be readable JSON", "load_previous_evidence", {}, 2); }
  if (!artifact || artifact.schema !== "pixir.monitor.semantic_zoom_gate.evidence" || typeof artifact.phases !== "object") throw failure("previous_evidence_invalid", "Previous evidence has an incompatible artifact schema", "load_previous_evidence", {}, 2);
  const fingerprint = hostFingerprintFromArtifact(artifact);
  const stringFields = ["os_platform", "os_release", "cpu_model"];
  const numericFields = ["core_count", "total_memory_bucket_gib", "chrome_major_version"];
  const fingerprintValid = HOST_FINGERPRINT_FIELDS.every(field => Object.hasOwn(fingerprint || {}, field)) && stringFields.every(field => typeof fingerprint[field] === "string" && fingerprint[field].length > 0) && numericFields.every(field => Number.isFinite(fingerprint[field]));
  if (!fingerprintValid || artifact.ok !== true || artifact.mode !== "enforce") throw failure("previous_evidence_invalid", "Previous evidence must be a successful enforce artifact with a complete host fingerprint", "load_previous_evidence", {fingerprint_complete: fingerprintValid, ok: artifact?.ok === true, enforce_mode: artifact?.mode === "enforce"}, 2);
  return artifact;
}

async function main(argv) {
  const options = parseArgs(argv);
  const budgets = JSON.parse(await readFile(BUDGETS_PATH, "utf8"));
  const runtime = {options, budgets, phases: {}, assertions: [], cleanup: {}, children: [], monitors: [], error: null, regressionComparison: {compared: false, reason: options.previous_evidence ? "gate_not_run" : "previous_evidence_not_provided", table: []}};
  try {
    await validateInputs(options, budgets);
    runtime.previousEvidence = await loadPreviousEvidence(options.previous_evidence);
    if (options.dryRun) return {runtime, result: {ok: true, dry_run: true, check: "pixir_monitor_semantic_zoom_gate"}};
    runtime.tempRoot = await mkdtemp(join(tmpdir(), "pixir-monitor-semantic-zoom-"));
    runtime.workspaces = {"100": await materialize(runtime, "100"), "500": await materialize(runtime, "500"), redProof: await materialize(runtime, "500", "500-red-proof"), hostile: await materialize(runtime, "hostile")};
    await startBrowser(runtime);
    await phaseA100(runtime);
    await phaseB500(runtime);
    await phaseCExpansion(runtime);
    await phase_d_refetch(runtime);
    await phase_e_restoration(runtime);
    await phase_f_hostile(runtime);
    await phase_g_red_proof(runtime);
    runtime.enforcedOrProposedPins = options.calibrate ? calibrate(runtime) : budgets.pins;
    assertGate(runtime);
    comparePreviousEvidence(runtime);
    return {runtime, result: {ok: true, check: "pixir_monitor_semantic_zoom_gate", mode: options.calibrate ? "calibrate" : "enforce", ticket: 337, phases_added: ["phase_d_refetch", "phase_e_restoration", "phase_f_hostile", "phase_g_red_proof"], regression_compared: runtime.regressionComparison.compared}};
  } catch (error) {
    runtime.error = safeError(error);
    throw Object.assign(error, {runtime});
  }
}

let exitCode = 0;
let output;
let runtime;
try {
  const completed = await main(process.argv.slice(2));
  runtime = completed.runtime;
  await cleanup(runtime);
  const failedCleanup = Object.entries(runtime.cleanup).filter(([_name, value]) => value !== true).map(([name]) => name);
  if (failedCleanup.length) throw failure("cleanup_failed", "One or more gate cleanup operations failed", "cleanup", {failed: failedCleanup});
  await emitArtifact(runtime);
  output = {...completed.result, evidence_written: runtime.evidenceWritten === true};
} catch (error) {
  exitCode = error?.exitCode || 1;
  runtime = error?.runtime || runtime;
  if (runtime) {
    runtime.error = safeError(error);
    try { await cleanup(runtime); } catch (_cleanupError) {}
    try { await emitArtifact(runtime); } catch (_artifactError) {}
  }
  output = {ok: false, error: safeError(error)};
}
process.stdout.write(`${JSON.stringify(output)}\n`);
process.exitCode = exitCode;
