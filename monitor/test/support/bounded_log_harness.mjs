import fs from "node:fs";
import vm from "node:vm";
import assert from "node:assert/strict";

class Node {
  constructor(tag = "div") { this.tagName = tag; this.children = []; this.dataset = {}; this.textContent = ""; this.classList = {add() {}}; }
  append(...nodes) { this.children.push(...nodes); }
  get childNodes() { return this.children; }
  setAttribute() {}
  hasAttribute() { return false; }
  addEventListener() {}
  querySelector(tag) {
    for (const child of this.children) {
      if (child.tagName === tag) return child;
      const found = child.querySelector && child.querySelector(tag);
      if (found) return found;
    }
    return null;
  }
}
const document = {getElementById: () => new Node(), querySelector: () => new Node(), createElement: tag => new Node(tag), addEventListener() {}};
const window = {addEventListener() {}, __pixirBootstrap: {then() { return {catch() {}}; }}};
const context = vm.createContext({window, document, URLSearchParams, location: {hash: "#/runs"}, console});
// Expose the actual served renderers inside this VM; no copied implementation.
const source = fs.readFileSync(process.argv[2], "utf8")
  .replace("window.PixirMonitorUI =", "window.__boundedViews = {runTable, truthRail, unitSummary, renderUnit, attemptCard, usagePanel, mutationPanel, limitationsPanel, state}; window.PixirMonitorUI =")
  .replace("function replaceContent(node, announcement) {", "function replaceContent(node, announcement) { window.__boundedContent = {node, announcement}; return;");
vm.runInContext(source, context);
const ui = window.PixirMonitorUI;
assert.equal(typeof ui.boundedLogNote, "function", "served bundle must provide the actual rendering function");
const selection = "parent_log_prefix_tail:bytes_omitted=9000000;events_omitted=unknown;events_retained=12;bytes_read=8388608";
const row = {id: "partial-parent", children: [{session_id: "retained-child", unit_id: "retained-unit"}], counts: {attention_units: 0}, source: {mode: "reconstructed", limitations: [selection, "partial_counts_lower_bounds"]}};
const detail = {source: {limitations: [selection, "partial_counts_lower_bounds"]}};
for (const projection of [row, detail]) {
  const node = ui.boundedLogNote(projection);
  assert.ok(node);
  assert.match(node.textContent, /prefix.*tail/i);
  assert.match(node.textContent, /9000000 bytes omitted/);
  assert.match(node.textContent, /omitted events unknown/i);
  assert.match(node.textContent, /lower bounds/);
  assert.match(node.textContent, /missing middle/i);
}
assert.equal(ui.boundedLogNote({source: {limitations: []}}), null);
const route = ui.parseRoute("#/runs");
const listView = window.__boundedViews.runTable([row], 1, "Recent", {}, "test", route);
const detailView = window.__boundedViews.truthRail(detail, route);
const renderedText = node => node.textContent + node.children.map(renderedText).join(" ");
for (const view of [listView, detailView]) {
  assert.match(renderedText(view), /Partial parent Log — prefix \+ tail only/);
  assert.match(renderedText(view), /omitted events unknown/);
  assert.match(renderedText(view), /lower bounds, not complete totals/);
}
const candidates = ui.resolveParentObservedChild("retained-child", [row]);
assert.equal(candidates.length, 1);
assert.equal(candidates[0].runId, "partial-parent");
assert.equal(candidates[0].unitId, "retained-unit");
assert.equal(ui.resolveParentObservedChild("missing-middle-child", [row]).length, 0);

const partialUnit = {logical_id: "retained-unit", label: "Observed worker", materialization: "durable", execution_kind: "subagent", attempts: [], limitations: ["attempt_lineage_unavailable"], execution: {state: "unknown"}};
const partialRun = {run: {id: "partial-parent"}, source: detail.source, units: [partialUnit], evidence: []};
const unitRoute = ui.parseRoute("#/runs/partial-parent/units/retained-unit");
const unitCard = window.__boundedViews.unitSummary(partialRun, partialUnit, unitRoute);
assert.match(renderedText(unitCard), /0 retained.*total unknown/);
window.__boundedViews.state.detail = partialRun;
context.location.hash = "#/runs/partial-parent/units/retained-unit";
window.__boundedViews.renderUnit();
assert.match(renderedText(window.__boundedContent.node), /Earlier attempt lineage is unavailable/);
assert.doesNotMatch(renderedText(window.__boundedContent.node), /engine-only unit has no Subagent attempts/);
assert.match(window.__boundedContent.announcement, /retained attempts.*total unknown/);
partialUnit.limitations = [];
window.__boundedViews.renderUnit();
assert.match(renderedText(window.__boundedContent.node), /engine-only unit has no Subagent attempts/);
// Partial children use the existing general limitation surfaces, not the
// parent-only boundedLogNote parser. Exercise actual served renderers.
const childNote = "Partial child Log child — prefix + tail only; missing middle; 4096 bytes read within the per-Log read bound; 8 events retained; total events unknown. Retained counts and paths are lower bounds, not complete totals.";
const childDetail = {
  source: {mode: "reconstructed", durable_origin: "workspace_log", freshness: "terminal", limitations: ["child_log_partial", childNote]},
  limitations: [childNote],
  usage: {source: "incomplete", complete: false, calls: 2, groups: [], limitations: [childNote, "usage_attribution_ambiguous"]},
  mutation: {status: "indeterminate", observed_semantics: "unknown", observed_paths: [], basis: "no_child_evidence_available", write_denials: [], limitations: [childNote, "mutation_evidence_incomplete"]}
};
assert.equal(ui.boundedLogNote(childDetail), null, "partial child must not masquerade as partial parent history");
for (const view of [
  window.__boundedViews.truthRail(childDetail, route),
  window.__boundedViews.limitationsPanel(childDetail.limitations),
  window.__boundedViews.usagePanel(childDetail.usage, "partial-child-usage"),
  window.__boundedViews.mutationPanel(childDetail.mutation)
]) {
  assert.match(renderedText(view), /Partial child Log child/i);
  assert.match(renderedText(view), /prefix \+ tail only/i);
  assert.match(renderedText(view), /4096 bytes read.*per-Log read bound/i);
  assert.match(renderedText(view), /total events unknown/i);
  assert.match(renderedText(view), /lower bounds, not complete totals/i);
}
const usageView = renderedText(window.__boundedViews.usagePanel(childDetail.usage, "partial-child-usage"));
assert.match(usageView, /Evidence incomplete/);
assert.doesNotMatch(usageView, /Evidence complete/);
assert.match(usageView, /Usage attribution ambiguous/i);
const unknownUsageAttempt = {attempt_id: "known-prefix", ordinal: 0, materialization: "durable", status_basis: "parent_log", relation: "fresh", status: "completed", child_event_window: {basis: "unknown"}, evidence_refs: [], limitations: []};
const unknownUsageCard = window.__boundedViews.attemptCard(partialRun, partialUnit, unknownUsageAttempt, false);
assert.match(renderedText(unknownUsageCard), /usage.*unavailable/i);
assert.doesNotMatch(renderedText(unknownUsageCard), /Evidence complete|0 durable provider call/);
const explicitZeroCard = window.__boundedViews.attemptCard(partialRun, partialUnit, {...unknownUsageAttempt, usage: {complete: true, calls: 0, groups: [], source: "provider_usage_fold", limitations: []}}, false);
assert.match(renderedText(explicitZeroCard), /Evidence complete/);
assert.match(renderedText(explicitZeroCard), /0 durable provider call/);
console.log("bounded log UI contract passed");
