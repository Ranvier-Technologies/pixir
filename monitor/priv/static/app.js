"use strict";

(function () {
  const LIMITS = Object.freeze({runs: 50, units: 100, attempts: 20, evidence: 100, field: 32768, query: 256});
  const FILTER_VOCABULARIES = Object.freeze({
    strategy: ["workflow", "subagents", "unknown"],
    execution: ["planned", "queued", "running", "completed", "partial", "failed", "timed_out", "cancelled", "detached", "closed", "held", "unknown"],
    liveness: ["unobserved", "not_applicable"],
    source: ["live", "reconstructed", "mixed"],
    attention: ["yes", "no"]
  });
  // Attention honesty contract: labels state the parent-observed evidence basis.
  // No label ever claims global health, and no synthetic unknown bucket exists
  // for the attention dimension anywhere in this bundle.
  const FILTER_LABELS = Object.freeze({
    attention: Object.freeze({
      label: "Attention (parent-observed)",
      options: Object.freeze({yes: "Parent-observed attention", no: "No parent-observed attention"})
    })
  });
  // Attention pagination contract: while the bounded inventory keeps the attention
  // group at or below this declared cap, every attention row is rendered. Above the
  // cap the DOM stays bounded with exact shown/total counts and an explicit
  // show-next control. Attention is never hidden behind healthy-row pagination.
  const ATTENTION_RENDER_ALL_CAP = 200;
  function attentionRowBudget(total, page, cap) {
    const bound = Number.isSafeInteger(cap) && cap > 0 ? cap : ATTENTION_RENDER_ALL_CAP;
    const safeTotal = Number.isSafeInteger(total) && total > 0 ? total : 0;
    const safePage = Number.isSafeInteger(page) && page > 0 ? page : 1;
    if (safeTotal <= bound) return safeTotal;
    return Math.min(safeTotal, safePage * LIMITS.runs);
  }
  const SORT_VOCABULARY = Object.freeze(["recency_desc", "recency_asc", "duration_desc", "duration_asc"]);
  const DEFAULT_SORT = "recency_desc";
  const SORT_LABELS = Object.freeze({
    recency_desc: "Newest activity first (default)",
    recency_asc: "Oldest activity first",
    duration_desc: "Longest duration first",
    duration_asc: "Shortest duration first"
  });
  const COMPLETENESS_RANK = Object.freeze({complete: 0, incomplete: 1, unknown: 2, malformed: 3});
  const MARKER_TONES = new Set([
    "planned", "queued", "running", "completed", "partial", "failed", "timed_out", "cancelled", "detached", "closed", "held", "unknown",
    "live", "stale_handle", "owner_unavailable", "unobserved", "not_applicable", "reconstructed", "mixed", "workflow", "subagents",
    "needs_orchestrator", "checkpoint_ready", "ready", "stop", "needs_review", "pass", "invalid", "workspace_applied", "indeterminate", "not_applied", "current"
  ]);
  const app = document.getElementById("app");
  const status = document.getElementById("status");
  const shell = document.querySelector("body > main");
  function readShellConfig() {
    if (!shell.hasAttribute("data-workspace-set")) return null;
    let value;
    try { value = JSON.parse(shell.getAttribute("data-workspace-set")); } catch (_error) { throw new Error("workspace set shell config is malformed"); }
    const exact = value && !Array.isArray(value) && Object.keys(value).sort().join(",") === "mode,workspaces";
    const keys = exact && Array.isArray(value.workspaces) ? value.workspaces : [];
    const validKeys = keys.length === 2 && new Set(keys).size === 2 && keys.every(function (key) { return typeof key === "string" && key.length <= 256 && /^[A-Za-z0-9][A-Za-z0-9_-]*$/.test(key); });
    if (!exact || value.mode !== "workspace_set" || !validKeys) throw new Error("workspace set shell config has an invalid shape");
    return Object.freeze({mode: value.mode, workspaces: Object.freeze(keys.slice())});
  }
  let shellConfig = null;
  let shellConfigError = null;
  try { shellConfig = readShellConfig(); } catch (error) { shellConfigError = error; }
  function workspaceSetMode() { return shellConfig !== null; }
  function clientIdentity(route) {
    const current = route || parseRoute(location.hash);
    if (!workspaceSetMode() || !current.workspace) return "";
    return current.workspace + ":" + (current.runId ? current.runId + ":" : "");
  }
  function clientStateKey(value, route) { return clientIdentity(route) + value; }
  function scopedStore() {
    const target = Object.create(null);
    return new Proxy(target, {
      get: function (store, property) { return typeof property === "string" ? store[clientStateKey(property)] : store[property]; },
      set: function (store, property, value) { store[typeof property === "string" ? clientStateKey(property) : property] = value; return true; },
      deleteProperty: function (store, property) { return delete store[typeof property === "string" ? clientStateKey(property) : property]; }
    });
  }
  const workspaceSnapshots = Object.create(null);
  const state = {
    generation: 0,
    list: null,
    detail: null,
    detailId: null,
    detailWorkspace: null,
    routeRunId: null,
    routeWorkspace: null,
    lastEventId: null,
    streamState: "connecting",
    refreshInFlight: null,
    refreshPendingReason: null,
    sourceRequestGeneration: Object.create(null),
    lastAuthoritativeRefetchAt: null,
    activityOrder: scopedStore(),
    pages: scopedStore(),
    restore: null,
    pendingAttemptScroll: null,
    detailConflict: false,
    forceRefetch: false
  };
  const SUPERSEDED = Symbol("superseded");

  function array(value) { return Array.isArray(value) ? value : []; }
  function scalar(value, fallback) { return value === null || value === undefined ? fallback : String(value); }
  function diagnosticToken(value, fallback) {
    const token = scalar(value, "");
    return /^[a-z0-9_]{1,64}$/.test(token) ? token : fallback;
  }
  function projectionFailure(phase, kind, status) {
    const failure = new Error("projection client failure");
    failure.name = "ProjectionFailure";
    failure.phase = diagnosticToken(phase, "render");
    failure.kind = diagnosticToken(kind, "projection_failure");
    failure.status = Number.isSafeInteger(status) && status >= 100 && status <= 599 ? status : null;
    failure.structured = false;
    return failure;
  }
  function normalizeProjectionFailure(error) {
    if (error && error.name === "ProjectionFailure") return error;
    return projectionFailure("render", "projection_render_failed");
  }
  function projectionFailureMessage(failure) {
    if (failure.phase === "decode") return "The projection response could not be decoded.";
    if (failure.phase === "render") return "The fetched projection could not be displayed.";
    return "The authoritative projection could not be fetched.";
  }
  function projectionFailureStatus(failure) {
    if (failure.phase === "decode") return "Snapshot response invalid; relaunch or wait for convergence.";
    if (failure.phase === "render") return "Snapshot loaded but could not be displayed.";
    return "Snapshot unavailable; relaunch or wait for convergence.";
  }
  function applyFailureDiagnostic(root, failure) {
    root.dataset.errorPhase = failure.phase;
    root.dataset.errorKind = failure.kind;
    if (failure.status !== null) root.dataset.httpStatus = String(failure.status);
    return root;
  }
  function el(tag, className) {
    const node = document.createElement(tag);
    if (className) node.className = className;
    return node;
  }
  function text(tag, value, className) {
    const node = el(tag, className);
    node.textContent = scalar(value, "—");
    return node;
  }
  function untrustedText(tag, value, className) {
    const shown = visible(value);
    const node = text(tag, shown.text, className);
    node.classList.add("projected-text");
    node.setAttribute("dir", "auto");
    return node;
  }
  function projectedLink(value, hash, focusKey) {
    const node = untrustedText("a", value);
    node.href = hash;
    if (focusKey) key(node, focusKey);
    return node;
  }
  function projectedHeading(level, value) { return untrustedText("h" + level, value); }
  function setText(node, value) { node.textContent = scalar(value, "—"); }
  function key(node, value) { node.dataset.focusKey = clientStateKey(value); return node; }
  function scopedDisclosureValue(value, route) {
    const prefix = clientIdentity(route);
    return prefix && !value.startsWith(prefix) ? prefix + value : value;
  }
  function setDisclosureKey(node, value) { node.dataset.disclosureKey = scopedDisclosureValue(value); return node; }
  /**
   * Projects untrusted text for display: control, escape, and bidirectional
   * codepoints become visible tokens, and output is bounded to 32 KiB of the
   * source. Every projected string passes through here; hostile bytes never
   * reach a live sink.
   * @param {*} value Projected string (any type; coerced via scalar).
   * @returns {{text: string, truncated: boolean, rawLength: number}}
   */
  function visible(value) {
    const raw = scalar(value, "");
    let out = "";
    let truncated = false;
    let consumed = 0;
    for (const character of raw) {
      const cp = character.codePointAt(0);
      let token = character;
      if (cp === 0x1b) token = "⟦ESC⟧";
      else if (cp === 0x7f) token = "⟦DEL⟧";
      else if (cp < 0x20) token = "⟦C0 U+" + cp.toString(16).toUpperCase().padStart(4, "0") + "⟧";
      else if ((cp >= 0x80 && cp <= 0x9f) || (cp >= 0x2028 && cp <= 0x202e) || (cp >= 0x2066 && cp <= 0x2069) || cp === 0x061c || cp === 0x200e || cp === 0x200f) token = "⟦U+" + cp.toString(16).toUpperCase().padStart(4, "0") + "⟧";
      if (consumed + token.length > LIMITS.field) { truncated = true; break; }
      out += token;
      consumed += token.length;
    }
    return {text: out, truncated: truncated, rawLength: raw.length};
  }
  function projected(parent, tag, value, className) {
    const shown = visible(value);
    const node = untrustedText(tag, value, className);
    parent.append(node);
    if (shown.truncated) parent.append(text("span", "Visible preview limited to 32 KiB (" + shown.rawLength + " source characters).", "truncation"));
    return node;
  }
  function titleCase(value) { return scalar(value, "unknown").replaceAll("_", " "); }
  function markerTone(value) { const tone = scalar(value, "unknown"); return MARKER_TONES.has(tone) ? tone : "unknown"; }
  function marker(value, dimension, basis) {
    return labeledMarker(titleCase(value), value, dimension, basis);
  }
  function labeledMarker(label, tone, dimension, basis) {
    const node = text("span", label, "marker marker-" + markerTone(tone));
    node.dataset.dimension = dimension;
    if (basis) node.dataset.provenance = basis;
    return node;
  }
  function field(label, value) {
    const wrap = el("div", "field");
    wrap.append(text("dt", label));
    projected(wrap, "dd", value);
    return wrap;
  }
  function heading(level, value) { return text("h" + level, value); }
  function button(label, handler, className) {
    const node = text("button", label, className);
    node.type = "button";
    node.addEventListener("click", handler);
    return node;
  }
  function link(label, hash, focusKey) {
    const node = text("a", label);
    node.href = hash;
    if (focusKey) key(node, focusKey);
    return node;
  }
  function empty(message) { return text("p", message, "empty-state"); }

  /**
   * Parses the hash route. All view state lives in the hash — filters (validated
   * against FILTER_VOCABULARIES), sort (validated against SORT_VOCABULARY, else
   * the default), a length-bounded search query, and the explicit follow flag —
   * so it survives refresh, back/forward, and relaunch.
   * @param {string} hash location.hash, with or without the leading "#".
   * @returns {{view: string, runId: (string|undefined), unitId: (string|undefined), attemptId: (string|null|undefined), filters: Object, sort: string, q: string, follow: boolean}}
   */
  function parseRoute(hash) {
    const raw = scalar(hash, "").replace(/^#/, "");
    const parts = raw.split("?");
    const path = parts[0] || (workspaceSetMode() ? "/workspaces" : "/runs");
    const params = new URLSearchParams(parts[1] || "");
    const segments = path.split("/").filter(Boolean).map(function (part) {
      try { return decodeURIComponent(part); } catch (_error) { return null; }
    });
    const filters = Object.create(null);
    ["strategy", "execution", "liveness", "source", "attention"].forEach(function (name) {
      const value = params.get(name);
      if (value && FILTER_VOCABULARIES[name].includes(value)) filters[name] = value;
    });
    const requestedSort = params.get("sort");
    const sort = SORT_VOCABULARY.includes(requestedSort) ? requestedSort : DEFAULT_SORT;
    const rawQuery = params.get("q");
    const q = rawQuery ? Array.from(String(rawQuery)).slice(0, LIMITS.query).join("") : "";
    const follow = params.get("follow") === "1";
    const zoomStart = /^\d+$/.test(params.get("zoom") || "") ? Number(params.get("zoom")) : 0;
    const selectedCluster = params.get("cluster") || null;
    const selectedArc = params.get("arc") || null;
    const memberPage = /^\d+$/.test(params.get("members") || "") ? Math.max(1, Number(params.get("members"))) : 1;
    const edgePage = /^\d+$/.test(params.get("edges") || "") ? Math.max(1, Number(params.get("edges"))) : 1;
    const zoom = {zoomStart: zoomStart, selectedCluster: selectedCluster, selectedArc: selectedArc, memberPage: memberPage, edgePage: edgePage};
    if (segments.some(function (segment) { return segment === null; })) return Object.assign({view: "invalid", filters: filters, sort: sort, q: q, follow: false}, zoom);
    let workspace;
    let routeSegments = segments;
    if (workspaceSetMode()) {
      if (segments.length === 1 && segments[0] === "workspaces") return Object.assign({view: "workspaces", filters: filters, sort: sort, q: q, follow: false}, zoom);
      if (segments[0] !== "workspaces" || !shellConfig.workspaces.includes(segments[1]) || segments[2] !== "runs") return Object.assign({view: "workspaces", filters: filters, sort: sort, q: q, follow: false}, zoom);
      workspace = segments[1];
      routeSegments = segments.slice(2);
    }
    if (routeSegments[0] !== "runs") return Object.assign({view: "runs", workspace: workspace, filters: filters, sort: sort, q: q, follow: false}, zoom);
    if (routeSegments.length >= 4 && routeSegments[2] === "units") return Object.assign({view: "unit", workspace: workspace, runId: routeSegments[1], unitId: routeSegments[3], attemptId: params.get("attempt"), filters: filters, sort: sort, q: q, follow: follow}, zoom);
    if (routeSegments.length >= 2) return Object.assign({view: "detail", workspace: workspace, runId: routeSegments[1], filters: filters, sort: sort, q: q, follow: follow}, zoom);
    return Object.assign({view: "runs", workspace: workspace, filters: filters, sort: sort, q: q, follow: false}, zoom);
  }
  /**
   * Canonicalizes already-parsed route state into a hash. Inputs are trusted to
   * be pre-validated (parseRoute output or a route built from it): filters must
   * already match the vocabularies, and no validation happens here. Only
   * non-default state is serialized — the default sort, empty query, and
   * follow=false stay out of the hash; attemptId serializes as the attempt
   * param, and follow is only meaningful on run routes.
   * @param {Object} route Pre-validated route state in canonical order: filters, sort, q, follow (plus runId/unitId/attemptId for detail routes).
   * @returns {string} Hash beginning with "#/runs".
   */
  function routeHash(route) {
    let path = workspaceSetMode() ? "#/workspaces/" + encodeURIComponent(route.workspace || parseRoute(location.hash).workspace || shellConfig.workspaces[0]) + "/runs" : "#/runs";
    if (route.runId) path += "/" + encodeURIComponent(route.runId);
    if (route.unitId) path += "/units/" + encodeURIComponent(route.unitId);
    const params = new URLSearchParams();
    const filters = route.filters || Object.create(null);
    Object.keys(filters).sort().forEach(function (name) { if (filters[name]) params.set(name, filters[name]); });
    if (route.sort && route.sort !== DEFAULT_SORT && SORT_VOCABULARY.includes(route.sort)) params.set("sort", route.sort);
    if (route.q) params.set("q", Array.from(String(route.q)).slice(0, LIMITS.query).join(""));
    if (route.attemptId) params.set("attempt", route.attemptId);
    if (route.runId && Number.isSafeInteger(route.zoomStart) && route.zoomStart > 0) params.set("zoom", String(route.zoomStart));
    if (route.runId && route.selectedCluster) params.set("cluster", route.selectedCluster);
    if (route.runId && route.selectedArc) params.set("arc", route.selectedArc);
    if (route.runId && Number.isSafeInteger(route.memberPage) && route.memberPage > 1) params.set("members", String(route.memberPage));
    if (route.runId && Number.isSafeInteger(route.edgePage) && route.edgePage > 1) params.set("edges", String(route.edgePage));
    if (route.runId && route.follow === true) params.set("follow", "1");
    const query = params.toString();
    return path + (query ? "?" + query : "");
  }

  // Tab/focus model (pinned minimum): every interactive element is a native
  // control (a, button, select, summary) in DOM order — filters first, then the
  // attention group, then remaining groups; continuation buttons carry
  // data-focus-key ("continuation:" + pageKey) so focus survives re-render, and
  // :focus-visible outlines stay enabled at every viewport width.
  function captureView() {
    const active = document.activeElement;
    const open = [];
    const route = arguments.length ? {runId: arguments[0], workspace: arguments[1]} : parseRoute(location.hash);
    document.querySelectorAll("details[data-disclosure-key]").forEach(function (node) { if (node.open) open.push(scopedDisclosureValue(node.dataset.disclosureKey, route)); });
    return {scrollX: window.scrollX, scrollY: window.scrollY, focus: active && active.dataset ? active.dataset.focusKey || null : null, open: open, runId: route.runId || null, workspace: route.workspace || null};
  }
  function restoreView(saved) {
    if (!saved) return;
    array(saved.open).forEach(function (id) {
      const node = Array.from(document.querySelectorAll("details[data-disclosure-key]")).find(function (candidate) { return scopedDisclosureValue(candidate.dataset.disclosureKey) === id; });
      if (node) node.open = true;
    });
    if (saved.focus) {
      const focusNode = Array.from(document.querySelectorAll("[data-focus-key]")).find(function (candidate) { return candidate.dataset.focusKey === saved.focus || candidate.dataset.focusKey === clientStateKey(saved.focus); });
      if (focusNode) focusNode.focus({preventScroll: true});
    }
    window.scrollTo(saved.scrollX || 0, saved.scrollY || 0);
  }
  function replaceContent(node, announcement) {
    const saved = state.restore || captureView();
    state.restore = null;
    delete app.dataset.errorPhase;
    delete app.dataset.errorKind;
    const route = parseRoute(location.hash);
    const held = route.workspace && workspaceSnapshots[route.workspace];
    const heldError = held && (route.view === "runs" ? held.listError : held.detailError);
    const heldPayload = held && (route.view === "runs" ? held.list : held.detailId === route.runId ? held.detail : null);
    if (heldPayload && heldError && route.view !== "workspaces") {
      const disclosure = el("div", "stale-disclosure");
      const heldObservedAt = route.view === "runs" ? held.listObservedAt : held.detailObservedAt;
      disclosure.append(untrustedText("strong", "Stale source snapshot · received " + scalar(heldObservedAt, "unknown") + " · refresh failure " + heldError.kind));
      disclosure.append(text("p", route.view === "runs" ? "Held data is not current. Retry refetches only this authoritative source." : "Held data is not current. Return to the runs list to retry this source.", "provenance"));
      if (route.view === "runs") disclosure.append(key(button("Retry this source", function () {
        refetchWorkspaceList(route.workspace, "source retry");
      }, "source-retry"), "runs-source-retry:" + route.workspace));
      node.prepend(disclosure);
    }
    app.replaceChildren(node);
    restoreView(saved);
    announce(announcement);
  }
  function announce(message) {
    let region = document.getElementById("pixir-live-region");
    if (!region) {
      region = text("div", "", "sr-only");
      region.id = "pixir-live-region";
      region.setAttribute("role", "status");
      region.setAttribute("aria-live", "polite");
      region.setAttribute("aria-atomic", "true");
      document.body.append(region);
    }
    setText(region, message || "Projection updated.");
  }

  function setStatus(message) {
    setText(status, message);
    let pill = document.getElementById("sse-health");
    if (!pill) { pill = el("span", "sse-health"); pill.id = "sse-health"; status.insertAdjacentElement("afterend", pill); }
    pill.className = "sse-health sse-" + state.streamState;
    const refetch = state.lastAuthoritativeRefetchAt ? state.lastAuthoritativeRefetchAt.toISOString().replace(/\.\d{3}Z$/, "Z") : "not yet";
    const health = state.streamState === "connected" ? "SSE connected · hints only · coalesced" : state.streamState === "down" ? "SSE down · hints only · authoritative snapshots remain available" : "SSE connecting · hints only · authoritative snapshots remain available";
    setText(pill, health + " · last successful authoritative refetch " + refetch);
  }

  function parseInstant(value) {
    if (typeof value !== "string" || !value) return null;
    const ms = Date.parse(value);
    return Number.isFinite(ms) ? ms : null;
  }
  function normalizedInstant(value, ms) {
    const match = typeof value === "string" ? value.match(/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.(\d+))?(?:Z|[+-]\d{2}:\d{2})$/) : null;
    if (!match || ms === null) return "";
    const utcSecond = new Date(Math.floor(ms / 1000) * 1000).toISOString().slice(0, 19);
    return utcSecond + "." + (match[1] || "").padEnd(9, "0").slice(0, 9) + "Z";
  }
  /**
   * Reads one field of the frozen temporal schema from a list row. Each boundary
   * is {value, basis, completeness} with completeness one of complete,
   * incomplete, unknown, or malformed; a missing boundary is honestly "unknown"
   * and is never manufactured from the browser clock or stream receipt. Rows
   * predating the schema fall back to the legacy latest_at string.
   * @param {Object} row Projected list row.
   * @param {string} name "started_at" | "ended_at" | "latest_at" | "duration".
   * @returns {Object} Boundary or duration map, never null.
   */
  function temporalField(row, name) {
    const temporal = row && row.temporal;
    const value = temporal && typeof temporal === "object" ? temporal[name] : null;
    if (value && typeof value === "object") return value;
    if (name === "latest_at") {
      const legacy = row && typeof row.latest_at === "string" && row.latest_at ? row.latest_at : null;
      if (legacy === null) return {value: null, basis: null, completeness: "unknown"};
      return {value: legacy, basis: "max_parent_event_ts", completeness: parseInstant(legacy) === null ? "malformed" : "complete"};
    }
    if (name === "duration") return {ms: null, basis: "boundary_difference", completeness: "unknown"};
    return {value: null, basis: null, completeness: "unknown"};
  }
  function completenessRank(completeness) {
    return COMPLETENESS_RANK[completeness] === undefined ? COMPLETENESS_RANK.unknown : COMPLETENESS_RANK[completeness];
  }
  // Pinned total order per sort: complete values first in the sort direction, then
  // incomplete, then unknown, then malformed; exact ties break by ascending run id.
  function sortRank(row, sort) {
    if (sort === "duration_desc" || sort === "duration_asc") {
      const duration = temporalField(row, "duration");
      const ms = duration.completeness === "complete" && typeof duration.ms === "number" && Number.isFinite(duration.ms) ? duration.ms : null;
      if (ms === null) return {rank: Math.max(completenessRank(duration.completeness), 1), value: 0};
      return {rank: 0, value: sort === "duration_asc" ? ms : -ms};
    }
    const latest = temporalField(row, "latest_at");
    const instant = latest.completeness === "complete" ? parseInstant(latest.value) : null;
    if (instant === null) return {rank: Math.max(completenessRank(latest.completeness), 1), value: 0};
    return {rank: 0, value: sort === "recency_asc" ? instant : -instant, normalized: normalizedInstant(latest.value, instant)};
  }
  /**
   * Comparator factory for the pinned total order of a sort vocabulary entry:
   * complete values first in the sort direction, then incomplete, then unknown,
   * then malformed; sub-millisecond recency ties use the normalized instant and
   * exact ties break by ascending run id.
   * @param {string} sort Entry of SORT_VOCABULARY.
   * @returns {function(Object, Object): number}
   */
  function runsComparator(sort) {
    return function (a, b) {
      const left = sortRank(a, sort);
      const right = sortRank(b, sort);
      if (left.rank !== right.rank) return left.rank - right.rank;
      if (left.value !== right.value) return left.value < right.value ? -1 : 1;
      if (left.normalized !== right.normalized) {
        if (sort === "recency_desc") return left.normalized > right.normalized ? -1 : 1;
        return left.normalized < right.normalized ? -1 : 1;
      }
      const leftId = scalar(a && a.id, "");
      const rightId = scalar(b && b.id, "");
      return leftId < rightId ? -1 : leftId > rightId ? 1 : 0;
    };
  }
  function formatDurationMs(ms) {
    const total = Math.max(Math.floor(ms / 1000), 0);
    const hours = Math.floor(total / 3600);
    const minutes = Math.floor((total % 3600) / 60);
    const seconds = total % 60;
    if (hours > 0) return hours + " h " + minutes + " m";
    if (minutes > 0) return minutes + " m " + seconds + " s";
    return seconds + " s";
  }
  /**
   * Human label for a duration map. Only a complete duration renders a value;
   * incomplete and malformed durations confess themselves instead of guessing.
   * @param {Object} duration Duration map from temporalField.
   * @returns {string}
   */
  function durationLabel(duration) {
    if (duration.completeness === "complete" && typeof duration.ms === "number" && Number.isFinite(duration.ms)) return formatDurationMs(duration.ms);
    if (duration.completeness === "incomplete") return "Incomplete · no end boundary";
    if (duration.completeness === "malformed") return "Malformed timestamp";
    return "Unknown";
  }
  // Display convenience only: the projected absolute timestamp always stays visible
  // and no missing boundary is ever backfilled from the browser clock.
  function relativeLabel(boundary) {
    if (boundary.completeness !== "complete") return null;
    const instant = parseInstant(boundary.value);
    if (instant === null) return null;
    const deltaSeconds = Math.round((Date.now() - instant) / 1000);
    if (deltaSeconds < 0) return "≈ in the future by local clock";
    if (deltaSeconds < 60) return "≈ " + deltaSeconds + " s ago";
    if (deltaSeconds < 3600) return "≈ " + Math.floor(deltaSeconds / 60) + " m ago";
    if (deltaSeconds < 86400) return "≈ " + Math.floor(deltaSeconds / 3600) + " h ago";
    return "≈ " + Math.floor(deltaSeconds / 86400) + " d ago";
  }
  function rowValue(row, keyName) {
    if (keyName === "strategy") return row.strategy;
    if (keyName === "execution") return row.execution && row.execution.state;
    if (keyName === "liveness") return row.liveness && row.liveness.state;
    if (keyName === "source") return row.source && row.source.mode;
    if (keyName === "attention") return row.counts && row.counts.attention_units > 0 ? "yes" : "no";
    return null;
  }
  /**
   * Assigns a list row to a rendered group. Grouping is parent-observed
   * attention or nothing: list scope carries no activity evidence, so no group
   * may claim liveness.
   * @param {Object} row Projected list row.
   * @returns {string} Group heading.
   */
  function groupFor(row) {
    if (row && row.counts && row.counts.attention_units > 0) return "Needs attention";
    return "Recent";
  }
  /**
   * Visible basis note for a liveness state at list scope. List rows reread the
   * parent Log only, so a nonterminal row is "unobserved" (evidence unavailable,
   * not a health claim) and a terminal row needs no activity state; detail scope
   * may load owner diagnostics and legitimately differ.
   * @param {string} livenessState Projected liveness state.
   * @returns {?string} Note text, or null when the state carries none.
   */
  function livenessCellNote(livenessState) {
    if (livenessState === "unobserved") return "Activity evidence unavailable at list scope (parent Log only). Detail may load owner diagnostics.";
    if (livenessState === "stale_handle") return "Owner handle is stale; last observed evidence no longer confirms activity.";
    if (livenessState === "not_applicable") return "Terminal per parent Log; liveness does not apply.";
    return null;
  }
  function listRows(payload) {
    if (payload && Array.isArray(payload.runs)) return payload.runs;
    return Array.isArray(payload) ? payload : [];
  }
  function filtersPanel(route) {
    const form = el("form", "filters");
    form.setAttribute("aria-label", "Run filters");
    ["strategy", "execution", "liveness", "source", "attention"].forEach(function (name) {
      const naming = FILTER_LABELS[name];
      const label = text("label", naming ? naming.label : titleCase(name));
      const select = el("select");
      select.name = name;
      key(select, "filter-" + name);
      const allOption = text("option", "All"); allOption.value = ""; select.append(allOption);
      const values = FILTER_VOCABULARIES[name];
      values.forEach(function (value) { const option = text("option", naming && naming.options[value] ? naming.options[value] : titleCase(value)); option.value = value; if (route.filters[name] === value) option.selected = true; select.append(option); });
      select.addEventListener("change", function () {
        const next = Object.create(null);
        Object.keys(route.filters).forEach(function (keyName) { next[keyName] = route.filters[keyName]; });
        if (select.value) next[name] = select.value; else delete next[name];
        location.hash = routeHash({view: "runs", filters: next, sort: route.sort, q: route.q});
      });
      label.append(select);
      form.append(label);
    });
    const sortLabel = text("label", "Sort");
    const sortSelect = el("select");
    sortSelect.name = "sort";
    key(sortSelect, "sort-order");
    SORT_VOCABULARY.forEach(function (value) { const option = text("option", SORT_LABELS[value]); option.value = value; if ((route.sort || DEFAULT_SORT) === value) option.selected = true; sortSelect.append(option); });
    sortSelect.addEventListener("change", function () { location.hash = routeHash({view: "runs", filters: route.filters, sort: sortSelect.value, q: route.q}); });
    sortLabel.append(sortSelect);
    form.append(sortLabel);
    form.append(button("Clear filters", function () { location.hash = routeHash({view: "runs", filters: Object.create(null), sort: route.sort, q: route.q}); }, "secondary"));
    return form;
  }
  /**
   * Matches one row against the search query. An exact parent-observed child
   * Session id wins before run id/title substrings so the provenance of the
   * match is honest; child Logs are never scanned and no index is persisted.
   * @param {Object} row Projected list row.
   * @param {*} rawQuery Route query (bounded upstream by LIMITS.query).
   * @returns {{matched: boolean, via: (string|null), child: (Object|undefined)}}
   */
  function searchMatch(row, rawQuery) {
    const query = scalar(rawQuery, "").trim();
    if (!query) return {matched: true, via: null};
    const needle = query.toLowerCase();
    const child = array(row.children).find(function (candidate) { return scalar(candidate.session_id, "") === query; });
    if (child) return {matched: true, via: "child_session", child: child};
    if (scalar(row.id, "").toLowerCase().includes(needle) || scalar(row.title, "").toLowerCase().includes(needle)) return {matched: true, via: "run"};
    return {matched: false, via: null};
  }
  function searchPanel(route) {
    const form = el("form", "filters search-panel");
    form.setAttribute("aria-label", "Run search");
    const label = text("label", "Search runs");
    const input = el("input");
    input.type = "search";
    input.name = "q";
    input.maxLength = LIMITS.query;
    input.value = scalar(route.q, "");
    input.placeholder = "Run id, projected title, or exact child Session id";
    key(input, "search-q");
    label.append(input);
    form.append(label);
    form.append(button("Search", function () { location.hash = routeHash({view: "runs", filters: route.filters, sort: route.sort, q: input.value}); }, "primary"));
    if (route.q) form.append(button("Clear search", function () { location.hash = routeHash({view: "runs", filters: route.filters, sort: route.sort, q: ""}); }, "secondary"));
    form.addEventListener("submit", function (event) { event.preventDefault(); location.hash = routeHash({view: "runs", filters: route.filters, sort: route.sort, q: input.value}); });
    form.append(text("p", "Search scans only the selected inventory of parent Session Logs already projected above. Child Session ids match exactly when parent-observed; child Logs are never scanned and no index is persisted.", "provenance"));
    return form;
  }
  function distributionMarkers(counts, order, aliases, dimension, basis) {
    const wrap = el("div", "marker-distribution");
    const recognized = new Set(order);
    order.forEach(function (name) {
      const count = Number(counts && counts[name]) || 0;
      if (count > 0) wrap.append(labeledMarker(count + " " + ((aliases && aliases[name]) || titleCase(name)), name, dimension, basis));
    });
    const residual = Object.keys(counts && typeof counts === "object" ? counts : {}).reduce(function (total, name) {
      if (recognized.has(name)) return total;
      const count = Number(counts[name]);
      return Number.isFinite(count) && count > 0 ? total + Math.floor(count) : total;
    }, 0);
    if (residual > 0) wrap.append(labeledMarker(residual + " unrecognized", "unknown", dimension, basis));
    return wrap;
  }
  function cellLabel(node, name) { node.dataset.cellLabel = name; return node; }
  /**
   * Renders one group of run rows as a table. Cells carry data-cell-label so
   * narrow viewports can stack them with their column names; search matches via
   * a child Session annotate the run cell with their provenance; temporal cells
   * render the projected absolute value with its completeness confessed.
   * @param {Array<Object>} rows Rows already filtered, sorted, searched, and budgeted.
   * @param {number} total Total rows in the group before pagination.
   * @param {string} group Group heading.
   * @param {Object} matches Search matches keyed by run id.
   * @param {string} focusKey Focus key for the group heading (survives re-render).
   * @returns {HTMLElement}
   */
  function runTable(rows, total, group, matches, focusKey) {
    const section = el("section", "run-group");
    const attentionGroup = group === "Needs attention";
    const groupHeading = heading(2, attentionGroup ? "Needs attention · " + total + " parent-observed" : group + " · " + total);
    key(groupHeading, focusKey); groupHeading.tabIndex = -1; section.append(groupHeading);
    if (!rows.length) {
      section.append(empty(attentionGroup ? "No parent-observed attention. Absence of attention rows is a parent-Log observation, not a global health claim." : "No runs in this group."));
      return section;
    }
    const table = el("table", "runs-table");
    const caption = text("caption", group + " runs"); caption.className = "sr-only"; table.append(caption);
    const head = el("thead"); const hr = el("tr");
    ["Run", "Strategy", "Execution", "Liveness", "Gate", "Advisory", "Source", "Units", "Mutation", "Duration", "Latest"].forEach(function (name) { hr.append(text("th", name)); });
    head.append(hr); table.append(head);
    const body = el("tbody");
    rows.forEach(function (row) {
      const tr = el("tr");
      if (row.counts && row.counts.attention_units > 0) tr.className = "attention-row";
      const name = scalar(row.title, row.id || "Unnamed run");
      const nameCell = el("td"); nameCell.append(projectedLink(name, routeHash({runId: row.id, filters: parseRoute(location.hash).filters, sort: parseRoute(location.hash).sort, q: parseRoute(location.hash).q}), "run-" + row.id));
      nameCell.append(text("span", "Attention observed: " + scalar(row.counts && row.counts.attention_units, 0) + " · parent Log only", "attention-basis"));
      if (array(row.attention && row.attention.reasons).length) nameCell.append(untrustedText("span", "△ " + row.attention.reasons.map(titleCase).join(" · "), "attention-reasons"));
      const match = matches && matches[row.id];
      if (match && match.via === "child_session") {
        const matchedUnit = match.child && match.child.unit_id;
        const currentRoute = parseRoute(location.hash);
        const matchTarget = matchedUnit ? routeHash({runId: row.id, unitId: matchedUnit, filters: currentRoute.filters, sort: currentRoute.sort, q: currentRoute.q}) : routeHash({runId: row.id, filters: currentRoute.filters, sort: currentRoute.sort, q: currentRoute.q});
        const matchLabel = "Matched via parent-observed child Session " + scalar(match.child && match.child.session_id, "unknown") + (matchedUnit ? " → logical unit " + matchedUnit : " (owning logical unit not identified in parent evidence)");
        const matchNote = el("span", "child-match provenance");
        matchNote.append(projectedLink(matchLabel, matchTarget, "child-match-" + row.id));
        nameCell.append(matchNote);
      }
      tr.append(cellLabel(nameCell, "Run"));
      const strategy = el("td"); strategy.append(marker(row.strategy, "strategy")); tr.append(cellLabel(strategy, "Strategy"));
      const execution = el("td"); execution.append(marker(row.execution && row.execution.state, "execution")); tr.append(cellLabel(execution, "Execution"));
      const liveness = el("td"); liveness.append(marker(row.liveness && row.liveness.state, "liveness", row.liveness && row.liveness.basis));
      const livenessNote = livenessCellNote(row.liveness && row.liveness.state);
      if (livenessNote) liveness.append(text("span", livenessNote, "liveness-basis"));
      tr.append(cellLabel(liveness, "Liveness"));
      const gateCell = el("td");
      const gateMarkers = distributionMarkers(row.gate_counts, ["needs_orchestrator", "failed", "held", "partial", "unknown", "checkpoint_ready", "not_applicable"], {checkpoint_ready: "ready"}, "gate distribution", "parent_log_only");
      if (!gateMarkers.childNodes.length) gateCell.append(text("span", "—")); else gateCell.append(gateMarkers); tr.append(cellLabel(gateCell, "Gate"));
      const advisoryCell = el("td");
      const advisoryMarkers = distributionMarkers(row.advisory_counts, ["stop", "needs_review", "pass", "unknown", "invalid"], null, "advisory distribution", "parent_log_only");
      if (!advisoryMarkers.childNodes.length) advisoryCell.append(text("span", "—")); else advisoryCell.append(advisoryMarkers); tr.append(cellLabel(advisoryCell, "Advisory"));
      const source = el("td"); source.append(marker(row.source && row.source.mode, "source")); tr.append(cellLabel(source, "Source"));
      tr.append(cellLabel(text("td", scalar(row.counts && row.counts.completed_units, "0") + "/" + scalar(row.counts && row.counts.planned_units, "?")), "Units"));
      tr.append(cellLabel(text("td", titleCase(row.mutation && row.mutation.status)), "Mutation"));
      const duration = temporalField(row, "duration");
      const durationCell = el("td");
      const durationNode = text("span", durationLabel(duration), "duration duration-completeness-" + scalar(duration.completeness, "unknown"));
      durationNode.dataset.provenance = scalar(duration.basis, "boundary_difference");
      durationNode.dataset.completeness = scalar(duration.completeness, "unknown");
      durationCell.append(durationNode);
      tr.append(cellLabel(durationCell, "Duration"));
      const latest = temporalField(row, "latest_at");
      const latestCell = el("td");
      latestCell.append(untrustedText("span", scalar(latest.value, "Unknown"), "absolute-ts"));
      const relative = relativeLabel(latest);
      if (relative) latestCell.append(text("span", relative, "relative-label"));
      if (latest.completeness === "malformed") latestCell.append(text("span", "Malformed timestamp", "relative-label duration-completeness-malformed"));
      tr.append(cellLabel(latestCell, "Latest"));
      body.append(tr);
    });
    table.append(body);
    const scroll = el("div", "table-scroll"); scroll.append(table); section.append(scroll);
    return section;
  }
  function inventoryNotice(payload) {
    const inventory = payload && payload.inventory;
    const limitations = array(inventory && inventory.limitations);
    if (!inventory || (inventory.truncated !== true && !limitations.length)) return null;
    const section = el("section", "inventory-notice");
    section.setAttribute("role", "status");
    section.append(heading(2, inventory.truncated === true ? "Run inventory truncated" : "Run inventory limited"));
    section.append(text("p", "Newest " + scalar(inventory.selected, "?") + " of " + scalar(inventory.total, "?") + " Session Logs selected."));
    if (limitations.length) {
      const list = el("ul", "inventory-limitations");
      limitations.forEach(function (limitation) {
        const item = el("li");
        item.append(untrustedText("strong", limitation && limitation.kind));
        item.append(untrustedText("p", limitation && limitation.message));
        const details = limitation && limitation.details;
        if (details && typeof details === "object" && !Array.isArray(details)) {
          const facts = el("dl", "inventory-limitation-details");
          [["Maximum Logs", details.max_logs], ["Total Logs", details.total], ["Selected Logs", details.selected], ["Projected Runs", details.projected_runs], ["Non-run Session Logs", details.non_parent_logs], ["Unprojected Selected Logs", details.dropped_logs]].forEach(function (entry) {
            if (entry[1] !== null && entry[1] !== undefined) facts.append(field(entry[0], entry[1]));
          });
          const errorKinds = details.error_kinds;
          if (errorKinds && typeof errorKinds === "object" && !Array.isArray(errorKinds)) {
            const labels = Object.keys(errorKinds).sort().map(function (kind) { return kind + ": " + scalar(errorKinds[kind], 0); });
            if (labels.length) facts.append(field("Error kinds", labels.join(" · ")));
          }
          item.append(facts);
        }
        list.append(item);
      });
      section.append(list);
    }
    return section;
  }
  /**
   * Renders the Runs view from route state alone. The pipeline is pinned:
   * filter, then sort (pinned total order), then search, then group, then
   * per-group pagination — with the attention group budgeted by
   * attentionRowBudget so parent-observed attention is never hidden behind
   * healthy-row pagination. Every scanned-domain fact is confessed inline.
   * @returns {void}
   */
  function renderRuns() {
    const route = parseRoute(location.hash);
    const all = listRows(state.list);
    const filtered = all.filter(function (row) {
      return Object.keys(route.filters).every(function (name) { return String(rowValue(row, name)) === route.filters[name]; });
    });
    const sorted = filtered.slice().sort(runsComparator(route.sort || DEFAULT_SORT));
    const activeQuery = scalar(route.q, "").trim();
    const matches = Object.create(null);
    const searched = sorted.filter(function (row) {
      const match = searchMatch(row, route.q);
      if (match.matched) matches[row.id] = match;
      return match.matched;
    });
    const grouped = Object.create(null);
    ["Needs attention", "Recent"].forEach(function (group) { grouped[group] = searched.filter(function (row) { return groupFor(row) === group; }); });
    const root = el("div", "view runs-view");
    root.append(heading(1, "Runs"));
    root.append(text("p", "Authoritative, recomputable projections. The monitor is read-only.", "lede"));
    root.append(text("p", "List rows are reconstructed from the parent Log only and carry no activity observation. Opening a run may load additional evidence (owner diagnostics), so row and detail liveness can legitimately differ.", "lede provenance"));
    root.append(filtersPanel(route));
    root.append(searchPanel(route));
    const inventoryFacts = state.list && state.list.inventory;
    const scanned = "Scanned inventory: " + scalar(inventoryFacts && inventoryFacts.selected, 0) + " selected of " + scalar(inventoryFacts && inventoryFacts.total, 0) + " Session Logs · projected runs: " + scalar(inventoryFacts && inventoryFacts.projected_runs, all.length) + " · non-run Logs: " + scalar(inventoryFacts && inventoryFacts.non_parent_logs, 0) + " · unprojected selected Logs: " + scalar(inventoryFacts && inventoryFacts.dropped_logs, 0) + " · truncated: " + (inventoryFacts && inventoryFacts.truncated === true ? "yes" : "no") + ".";
    root.append(text("p", scanned, "inventory-summary provenance"));
    if (activeQuery) {
      const summary = el("p", "search-summary provenance");
      summary.append(untrustedText("span", "Search “" + activeQuery + "”"));
      summary.append(text("span", " matched " + searched.length + " of " + filtered.length + " filter-selected rows. " + scanned));
      root.append(summary);
    }
    const inventory = inventoryNotice(state.list); if (inventory) root.append(inventory);
    if (!all.length) root.append(empty("No authoritative run projections are currently available. " + scanned));
    else if (!filtered.length) root.append(empty("No runs match the selected filters. " + scanned));
    else if (!searched.length) {
      const emptySearch = el("p", "empty-state");
      emptySearch.append(text("span", "No runs match this search in the selected inventory. Query "));
      emptySearch.append(untrustedText("span", "“" + activeQuery + "”"));
      emptySearch.append(text("span", " was compared against " + filtered.length + " filter-selected of " + all.length + " projected run rows. " + scanned + " Runs outside the selected inventory were not searched; no match here is not evidence of absence."));
      root.append(emptySearch);
    } else ["Needs attention", "Recent"].forEach(function (group) {
      const pageKey = "runs:" + group.toLowerCase().replace(" ", "-") + ":" + routeHash({view: "runs", filters: route.filters, sort: route.sort, q: route.q});
      const page = state.pages[pageKey] || 1;
      const budget = group === "Needs attention" ? attentionRowBudget(grouped[group].length, page, ATTENTION_RENDER_ALL_CAP) : page * LIMITS.runs;
      const rows = grouped[group].slice(0, budget);
      const groupFocusKey = "run-group:" + pageKey;
      const section = runTable(rows, grouped[group].length, group, matches, groupFocusKey);
      if (rows.length < grouped[group].length) {
        const nextPage = page + 1;
        const nextBudget = group === "Needs attention" ? attentionRowBudget(grouped[group].length, nextPage, ATTENTION_RENDER_ALL_CAP) : nextPage * LIMITS.runs;
        const nextReveal = Math.min(nextBudget, grouped[group].length) - rows.length;
        section.append(key(button("Show next " + nextReveal + " " + group + " runs (" + rows.length + " of " + grouped[group].length + " shown, " + (grouped[group].length - rows.length) + " remaining)", function () {
          state.pages[pageKey] = nextPage;
          if (nextBudget >= grouped[group].length) { state.restore = captureView(); state.restore.focus = groupFocusKey; }
          renderCurrentGuarded();
        }, "continuation"), "continuation:" + pageKey));
      }
      root.append(section);
    });
    replaceContent(root, "Runs updated. " + searched.length + " visible.");
    setStatus("Read-only · authoritative snapshots · " + all.length + " runs");
  }

  function truthCard(label, dimension, value, basis, extra) {
    const card = el("section", "truth-card");
    card.dataset.truthDimension = dimension;
    card.append(heading(3, label));
    card.append(marker(value, dimension, basis));
    if (basis) card.append(text("p", "Basis: " + titleCase(basis), "provenance"));
    if (extra) card.append(text("p", extra, "truth-extra"));
    return card;
  }
  function distributionCard(label, dimension, counts, order, aliases, basis, extra) {
    const card = el("section", "truth-card"); card.dataset.truthDimension = dimension; card.append(heading(3, label));
    const wrap = distributionMarkers(counts, order, aliases, dimension + " distribution", basis);
    if (!wrap.childNodes.length) wrap.append(labeledMarker("0 observed", "unknown", dimension + " distribution", basis));
    card.append(wrap); if (basis) card.append(text("p", "Basis: " + titleCase(basis), "provenance")); if (extra) card.append(text("p", extra, "truth-extra")); return card;
  }
  function stateCounts(units, reader, invalidReader) {
    const counts = Object.create(null); array(units).forEach(function (unit) { const invalid = invalidReader && invalidReader(unit); const value = invalid ? "invalid" : reader(unit); if (value) counts[value] = (counts[value] || 0) + 1; }); return counts;
  }
  function runOverview(run) {
    const panel = el("dl", "run-overview");
    [["Run id", run.run && run.run.id], ["Delegate id", run.run && run.run.delegate_id], ["Parent Session", run.run && run.run.parent_session_id], ["Workflow id", run.run && run.run.workflow_id], ["Projected at", run.projected_at], ["As of parent seq", run.source && run.source.as_of_seq], ["Planned units", run.counts && run.counts.planned_units], ["Observed units", run.counts && run.counts.observed_units], ["Running units", run.counts && run.counts.running_units], ["Completed units", run.counts && run.counts.completed_units], ["Attention units", run.counts && run.counts.attention_units]].forEach(function (entry) { panel.append(field(entry[0], entry[1])); });
    return panel;
  }
  function truthRail(run) {
    const rail = el("div", "truth-rail");
    rail.setAttribute("aria-label", "Six independent truth dimensions");
    rail.append(truthCard("Execution", "execution", run.execution && run.execution.state, run.execution && run.execution.basis));
    rail.append(truthCard("Liveness", "liveness", run.liveness && run.liveness.state, run.liveness && run.liveness.basis, run.liveness && run.liveness.reachable === true ? "Reachable now" : "Not currently reachable"));
    const gateCounts = stateCounts(run.units, function (unit) { return unit.gate && unit.gate.state; });
    const advisoryCounts = stateCounts(run.units, function (unit) { return unit.advisory && unit.advisory.present === true ? unit.advisory.verdict : null; }, function (unit) { return unit.advisory && unit.advisory.present === true && unit.advisory.parse_status === "invalid"; });
    rail.append(distributionCard("Dependency gate", "gate", gateCounts, ["needs_orchestrator", "failed", "held", "partial", "unknown", "checkpoint_ready", "not_applicable"], {checkpoint_ready: "ready"}, "unit checkpoint fold"));
    rail.append(distributionCard("Model advisory", "advisory", advisoryCounts, ["stop", "needs_review", "pass", "unknown", "invalid"], null, "model declared", "Advisory does not control the runtime gate."));
    rail.append(truthCard("Source (run-scoped)", "source", run.source && run.source.mode, run.source && run.source.durable_origin, "Freshness: " + titleCase(run.source && run.source.freshness) + "; limitations: " + (array(run.source && run.source.limitations).map(titleCase).join(", ") || "none observed")));
    const attentionCounts = stateCounts(run.units, function (unit) { return unit.attention && unit.attention.required === true ? "yes" : "no"; });
    rail.append(distributionCard("Attention (parent-observed)", "attention", attentionCounts, ["yes", "no"], {yes: "required", no: "not required"}, "parent log"));
    return rail;
  }
  function mutationPanel(mutation) {
    const section = el("section", "mutation-panel");
    section.append(heading(2, "Mutation observation"));
    section.append(marker(mutation && mutation.status, "mutation", mutation && mutation.observed_semantics));
    section.append(text("p", "Observed semantics: " + titleCase(mutation && mutation.observed_semantics), "provenance"));
    const paths = array(mutation && mutation.observed_paths);
    if (paths.length) { const list = el("ul"); paths.slice(0, LIMITS.evidence).forEach(function (path) { const item = el("li"); projected(item, "code", path); list.append(item); }); section.append(list); }
    array(mutation && mutation.limitations).forEach(function (item) { section.append(untrustedText("p", titleCase(item), "limitation")); });
    return section;
  }
  function unitSummary(run, unit, route, summaryFocusKey) {
    const article = el("article", "unit-card");
    article.dataset.unitId = unit.logical_id;
    const header = el("header");
    header.append(projectedLink(unit.label, semanticZoomRoute(route, {runId: run.run.id, unitId: unit.logical_id}), summaryFocusKey || "unit-" + unit.logical_id));
    header.append(marker(unit.execution && unit.execution.state, "execution", unit.execution && unit.execution.basis));
    header.append(marker(unit.liveness && unit.liveness.state, "liveness", unit.liveness && unit.liveness.basis));
    header.append(marker(unit.gate && unit.gate.state, "gate", unit.gate && unit.gate.basis));
    if (unit.advisory && unit.advisory.present) header.append(marker(unit.advisory.verdict, "advisory", "model_declared"));
    article.append(header);
    const meta = el("dl", "unit-meta");
    meta.append(field("Agent", unit.agent)); meta.append(field("Workspace", unit.workspace_mode)); meta.append(field("Attempts", array(unit.attempts).length));
    article.append(meta);
    if (unit.attention && unit.attention.required) {
      const attention = el("div", "attention"); attention.append(text("strong", "Needs attention · parent-observed"));
      attention.append(untrustedText("span", array(unit.attention.reasons).map(titleCase).join(" · ")));
      article.append(attention);
    }
    if (unit.advisory && unit.advisory.present) {
      const advisory = el("div", "advisory-panel"); advisory.append(text("strong", "Model advisory (not a runtime gate)"));
      projected(advisory, "p", unit.advisory.summary || unit.advisory.raw_excerpt || "No summary");
      article.append(advisory);
    }
    return article;
  }
  const SEMANTIC_ZOOM_MAX_CLUSTERS = 6;
  const SEMANTIC_ZOOM_MEMBER_PAGE_SIZE = 12;
  const SEMANTIC_ZOOM_EDGE_PAGE_SIZE = 100;
  const SEMANTIC_ZOOM_CLUSTER_KEY = /^wave:\d+:bucket:\d+$/;

  function semanticZoomRoute(route, changes) {
    return routeHash(Object.assign({}, route, changes));
  }

  function semanticZoomBuckets(waves, start) {
    const count = waves.length - start;
    const buckets = Object.create(null);
    if (count > SEMANTIC_ZOOM_MAX_CLUSTERS) {
      for (let index = start; index < start + SEMANTIC_ZOOM_MAX_CLUSTERS; index += 1) if (array(waves[index]).length > 0) buckets[index] = 1;
      return buckets;
    }
    for (let index = start; index < waves.length; index += 1) if (array(waves[index]).length > 0) buckets[index] = 1;
    for (let slot = 0; slot < SEMANTIC_ZOOM_MAX_CLUSTERS - count; slot += 1) {
      let candidate = null;
      for (let index = start; index < waves.length; index += 1) {
        const units = array(waves[index]).length;
        if (units === 0) continue;
        if (buckets[index] >= units) continue;
        if (candidate === null || units * buckets[candidate] > array(waves[candidate]).length * buckets[index]) candidate = index;
      }
      if (candidate === null) break;
      buckets[candidate] += 1;
    }
    return buckets;
  }

  function semanticZoomChunks(ids, bucketCount) {
    const chunks = [];
    const quotient = Math.floor(ids.length / bucketCount);
    const remainder = ids.length % bucketCount;
    let offset = 0;
    for (let ordinal = 0; ordinal < bucketCount; ordinal += 1) {
      const size = quotient + (ordinal < remainder ? 1 : 0);
      chunks.push(ids.slice(offset, offset + size));
      offset += size;
    }
    return chunks;
  }

  function deriveSemanticZoom(graph, start) {
    const waves = array(graph && graph.waves).map(array);
    const safeStart = Number.isSafeInteger(start) && start >= 0 && start < waves.length ? start : 0;
    const buckets = semanticZoomBuckets(waves, safeStart);
    const entities = [];
    const assignment = Object.create(null);
    const unitOrder = Object.create(null);
    if (safeStart > 0) {
      const keyName = "boundary:upstream:waves:0-" + (safeStart - 1);
      const members = waves.slice(0, safeStart).flat();
      entities.push({key: keyName, kind: "boundary", members: members, label: "Upstream boundary · Waves 1–" + safeStart});
      members.forEach(function (id) { assignment[id] = keyName; });
    }
    const visibleEnd = waves.length - safeStart > SEMANTIC_ZOOM_MAX_CLUSTERS ? safeStart + SEMANTIC_ZOOM_MAX_CLUSTERS : waves.length;
    for (let waveIndex = safeStart; waveIndex < visibleEnd; waveIndex += 1) {
      if (waves[waveIndex].length === 0 || !buckets[waveIndex]) continue;
      semanticZoomChunks(waves[waveIndex], buckets[waveIndex]).forEach(function (members, ordinal) {
        const keyName = "wave:" + waveIndex + ":bucket:" + ordinal;
        const entity = {key: keyName, kind: "cluster", waveIndex: waveIndex, ordinal: ordinal, members: members, label: "Wave " + (waveIndex + 1) + " · bucket " + (ordinal + 1)};
        entities.push(entity);
        members.forEach(function (id) { assignment[id] = keyName; });
      });
    }
    if (visibleEnd < waves.length) {
      const keyName = "overflow:waves:" + visibleEnd + "-" + (waves.length - 1);
      const members = waves.slice(visibleEnd).flat();
      if (members.length > 0) {
        entities.push({key: keyName, kind: "overflow", start: visibleEnd, end: waves.length - 1, members: members, label: "More waves " + (visibleEnd + 1) + "–" + waves.length});
        members.forEach(function (id) { assignment[id] = keyName; });
      }
    }
    waves.forEach(function (wave, waveIndex) {
      const visible = entities.filter(function (entity) { return entity.kind === "cluster" && entity.waveIndex === waveIndex; });
      wave.forEach(function (id) {
        const entity = visible.find(function (item) { return item.members.includes(id); });
        unitOrder[id] = [waveIndex, entity ? entity.ordinal : 0, scalar(id, "")];
      });
    });
    const entityOrder = Object.create(null); entities.forEach(function (entity, index) { entityOrder[entity.key] = index; });
    const arcMap = Object.create(null);
    const droppedEdges = [];
    array(graph && graph.edges).forEach(function (edge) {
      const fromKey = assignment[edge.from]; const toKey = assignment[edge.to];
      if (!fromKey || !toKey) { droppedEdges.push({edge: edge, reason: "edge_endpoint_outside_entities"}); return; }
      if (!["ready", "blocked", "unknown"].includes(edge.state)) { droppedEdges.push({edge: edge, reason: "edge_state_invalid"}); return; }
      const keyName = fromKey + "=>" + toKey;
      if (!arcMap[keyName]) arcMap[keyName] = {key: keyName, from: fromKey, to: toKey, counts: {ready: 0, blocked: 0, unknown: 0}, edges: []};
      const arc = arcMap[keyName];
      arc.counts[edge.state] += 1; arc.edges.push(edge);
    });
    function compareUnit(left, right) {
      const a = unitOrder[left] || [Number.MAX_SAFE_INTEGER, 0, scalar(left, "")];
      const b = unitOrder[right] || [Number.MAX_SAFE_INTEGER, 0, scalar(right, "")];
      return a[0] - b[0] || a[1] - b[1] || a[2].localeCompare(b[2]);
    }
    const arcs = Object.keys(arcMap).map(function (keyName) { return arcMap[keyName]; });
    arcs.forEach(function (arc) { arc.edges.sort(function (a, b) { return compareUnit(a.from, b.from) || compareUnit(a.to, b.to); }); });
    arcs.sort(function (a, b) { return entityOrder[a.from] - entityOrder[b.from] || entityOrder[a.to] - entityOrder[b.to]; });
    return {start: safeStart, waves: waves, entities: entities, arcs: arcs, droppedEdges: droppedEdges, compareUnit: compareUnit};
  }

  function semanticZoomLimitations(run, entity, lookup) {
    const values = array(run.limitations).map(function (value) { return scalar(value, "unknown_limitation"); });
    entity.members.forEach(function (id) { if (!lookup[id]) values.push("unit_evidence_absent"); });
    return Array.from(new Set(values));
  }

  function semanticZoomDistribution(members, lookup, reader) {
    const counts = Object.create(null);
    members.forEach(function (id) { if (lookup[id]) { const value = reader(lookup[id]); if (value) counts[value] = (counts[value] || 0) + 1; } });
    return counts;
  }

  function semanticZoomSummary(run, entity, lookup) {
    const summary = el("div", "cluster-summary");
    const observed = entity.members.filter(function (id) { return Boolean(lookup[id]); }).length;
    const limitations = semanticZoomLimitations(run, entity, lookup);
    summary.append(text("p", observed + " observed member" + (observed === 1 ? "" : "s") + (limitations.length ? " · limited: " + limitations.map(titleCase).join(", ") : ""), limitations.length ? "limitation" : "provenance"));
    const dimensions = [
      ["Execution", "execution", function (unit) { return unit.execution && unit.execution.state; }],
      ["Liveness", "liveness", function (unit) { return unit.liveness && unit.liveness.state; }],
      ["Dependency gate", "gate", function (unit) { return unit.gate && unit.gate.state; }],
      ["Model advisory", "advisory", function (unit) { return unit.advisory && unit.advisory.present === true ? (unit.advisory.parse_status === "invalid" ? "invalid" : unit.advisory.verdict) : null; }],
      ["Attention", "attention", function (unit) { return unit.attention && unit.attention.required === true ? "yes" : "no"; }]
    ];
    dimensions.forEach(function (dimension) {
      const row = el("p", "cluster-distribution"); row.dataset.truthDimension = dimension[1]; row.append(text("strong", dimension[0] + ": "));
      const counts = semanticZoomDistribution(entity.members, lookup, dimension[2]);
      const values = Object.keys(counts).sort();
      row.append(text("span", values.length ? values.map(function (value) { return titleCase(value) + " " + counts[value]; }).join(" · ") : "0 observed"));
      summary.append(row);
    });
    return summary;
  }

  function workflowGraph(run, route) {
    const section = el("section", "graph-panel semantic-zoom"); section.append(heading(2, "Dependency DAG · semantic zoom"));
    const graph = run.graph;
    if (!graph || !array(graph.waves).length) { section.append(empty("No Workflow dependency graph is projected.")); return section; }
    const lookup = Object.create(null); array(run.units).forEach(function (unit) { lookup[unit.logical_id] = unit; });
    const zoom = deriveSemanticZoom(graph, route.zoomStart);
    const selectedEntityCandidate = zoom.entities.find(function (entity) { return entity.kind === "cluster" && entity.key === route.selectedCluster && SEMANTIC_ZOOM_CLUSTER_KEY.test(entity.key); }) || null;
    const selectedArcCandidate = zoom.arcs.find(function (arc) { return arc.key === route.selectedArc; }) || null;
    const maximumMemberPage = selectedEntityCandidate ? Math.max(1, Math.ceil(selectedEntityCandidate.members.length / SEMANTIC_ZOOM_MEMBER_PAGE_SIZE)) : 1;
    const maximumEdgePage = selectedArcCandidate ? Math.max(1, Math.ceil(selectedArcCandidate.edges.length / SEMANTIC_ZOOM_EDGE_PAGE_SIZE)) : 1;
    const normalizedZoomRoute = Object.assign({}, route, {
      selectedCluster: selectedEntityCandidate ? selectedEntityCandidate.key : null,
      selectedArc: selectedArcCandidate ? selectedArcCandidate.key : null,
      memberPage: Math.min(Math.max(1, route.memberPage), maximumMemberPage),
      edgePage: Math.min(Math.max(1, route.edgePage), maximumEdgePage)
    });
    const canonicalZoomHash = semanticZoomRoute(normalizedZoomRoute, {});
    if (location.hash !== canonicalZoomHash) history.replaceState(null, "", canonicalZoomHash);
    route = normalizedZoomRoute;
    section.dataset.zoomStart = String(zoom.start);
    section.append(text("p", "Source (run-scoped) · " + titleCase(run.source && run.source.mode) + " · origin " + titleCase(run.source && run.source.durable_origin) + " · freshness " + titleCase(run.source && run.source.freshness) + " · limitations " + (array(run.source && run.source.limitations).map(titleCase).join(", ") || "none observed"), "provenance"));
    if (zoom.start > 0) section.append(link("← Previous zoom window", semanticZoomRoute(route, {zoomStart: Math.max(0, zoom.start - SEMANTIC_ZOOM_MAX_CLUSTERS), selectedCluster: null, selectedArc: null, memberPage: 1, edgePage: 1}), "zoom-back"));
    const overview = el("div", "cluster-overview"); overview.setAttribute("aria-label", "Workflow cluster overview");
    zoom.entities.forEach(function (entity) {
      const card = el("article", "cluster-card cluster-" + entity.kind); card.dataset.clusterKey = entity.key;
      card.append(heading(3, entity.label)); card.append(text("code", entity.key, "cluster-key")); card.append(semanticZoomSummary(run, entity, lookup));
      if (entity.kind === "overflow") {
        card.append(key(link("Open next zoom level", semanticZoomRoute(route, {zoomStart: entity.start, selectedCluster: null, selectedArc: null, memberPage: 1, edgePage: 1}), "overflow:" + entity.key), "overflow:" + entity.key));
      } else if (entity.kind === "cluster") {
        card.append(key(link("Inspect observed members", semanticZoomRoute(route, {selectedCluster: entity.key, selectedArc: null, memberPage: 1, edgePage: 1}), "cluster:" + entity.key), "cluster:" + entity.key));
      } else card.append(text("p", "Crosses the current zoom boundary.", "provenance"));
      overview.append(card);
    });
    section.append(overview);
    const arcs = el("section", "aggregate-arcs"); arcs.append(heading(3, "Aggregate dependency arcs"));
    if (!zoom.arcs.length) arcs.append(empty("No aggregate arcs are observed in this window."));
    zoom.arcs.forEach(function (arc) {
      const total = arc.counts.ready + arc.counts.blocked + arc.counts.unknown;
      const affected = array(run.limitations).length > 0 || arc.edges.some(function (edge) { return !lookup[edge.from] || !lookup[edge.to]; });
      const label = "Aggregate arc " + arc.from + " → " + arc.to + " · " + total + " observed edges · ready " + arc.counts.ready + " · blocked " + arc.counts.blocked + " · unknown " + arc.counts.unknown + (affected ? " · limited: projected graph or unit completeness" : "");
      arcs.append(key(link(label, semanticZoomRoute(route, {selectedArc: arc.key, selectedCluster: null, edgePage: 1, memberPage: 1}), "arc:" + arc.key), "arc:" + arc.key));
    });
    if (zoom.droppedEdges.length) arcs.append(text("p", zoom.droppedEdges.length + " projected edge" + (zoom.droppedEdges.length === 1 ? " was" : "s were") + " excluded from aggregate counts · limited: " + Array.from(new Set(zoom.droppedEdges.map(function (item) { return titleCase(item.reason); }))).join(", "), "limitation"));
    section.append(arcs);
    const selectedEntity = selectedEntityCandidate;
    if (selectedEntity) {
      const inspector = el("section", "cluster-inspector"); inspector.append(heading(3, "Selected cluster · " + selectedEntity.label));
      const members = selectedEntity.members.slice().sort(zoom.compareUnit);
      const visibleMembers = members.slice(0, route.memberPage * SEMANTIC_ZOOM_MEMBER_PAGE_SIZE);
      visibleMembers.forEach(function (id) {
        if (lookup[id]) inspector.append(unitSummary(run, lookup[id], route, "member:" + selectedEntity.key + ":" + id));
        else inspector.append(untrustedText("p", id + " · unit evidence absent", "limitation"));
      });
      if (visibleMembers.length < members.length) inspector.append(key(link("Show next " + Math.min(SEMANTIC_ZOOM_MEMBER_PAGE_SIZE, members.length - visibleMembers.length) + " members (" + visibleMembers.length + " of " + members.length + " shown)", semanticZoomRoute(route, {memberPage: route.memberPage + 1}), "members-next:" + selectedEntity.key), "members-next:" + selectedEntity.key));
      section.append(inspector);
    }
    const selectedArc = selectedArcCandidate;
    if (selectedArc) {
      const ledger = el("section", "exact-edge-ledger"); ledger.append(heading(3, "Exact-edge ledger for selected aggregate arc"));
      ledger.append(text("p", "These rows are exact projected dependencies; the selected overview arc is only an aggregate.", "provenance"));
      const visibleEdges = selectedArc.edges.slice(0, route.edgePage * SEMANTIC_ZOOM_EDGE_PAGE_SIZE);
      const list = el("ol"); visibleEdges.forEach(function (edge) { list.append(untrustedText("li", scalar(edge.from, "Unknown") + " → " + scalar(edge.to, "Unknown") + " — " + titleCase(edge.state))); }); ledger.append(list);
      if (visibleEdges.length < selectedArc.edges.length) ledger.append(key(link("Show next " + Math.min(SEMANTIC_ZOOM_EDGE_PAGE_SIZE, selectedArc.edges.length - visibleEdges.length) + " exact edges (" + visibleEdges.length + " of " + selectedArc.edges.length + " shown)", semanticZoomRoute(route, {edgePage: route.edgePage + 1}), "edges-next:" + selectedArc.key), "edges-next:" + selectedArc.key));
      section.append(ledger);
    }
    return section;
  }
  const FANOUT_GROUP_MEMBER_PAGE_SIZE = 12;
  const FANOUT_ATTENTION_FAMILY_ORDER = Object.freeze(["execution", "advisory", "liveness", "mutation", "virtual_diff", "evidence"]);
  const FANOUT_EXECUTION_STATE_ORDER = Object.freeze(["failed", "timed_out", "cancelled", "detached", "partial", "held", "unknown", "running", "queued", "planned", "completed", "closed"]);
  const FANOUT_ATTENTION_REASON_FAMILY = Object.freeze({
    execution_failed: "execution",
    execution_timed_out: "execution",
    execution_cancelled: "execution",
    execution_detached: "execution",
    execution_partial: "execution",
    execution_held: "execution",
    execution_unknown: "execution",
    advisory_stop: "advisory",
    advisory_needs_review: "advisory",
    advisory_gate_disagreement: "advisory",
    advisory_unparseable: "advisory",
    nonterminal_stale_handle: "liveness",
    nonterminal_owner_unavailable: "liveness",
    nonterminal_liveness_unknown: "liveness",
    terminal_ambiguous_close: "liveness",
    mutation_partial: "mutation",
    mutation_indeterminate: "mutation",
    mutation_unknown: "mutation",
    virtual_diff_unapplied: "virtual_diff",
    virtual_diff_apply_failed: "virtual_diff",
    virtual_diff_correlation_unknown: "virtual_diff",
    canonical_source_conflict: "evidence",
    durable_log_unavailable: "evidence",
    child_log_missing: "evidence",
    attempt_index_conflict: "evidence"
  });

  function fanoutReasonFamily(reason) {
    if (Object.prototype.hasOwnProperty.call(FANOUT_ATTENTION_REASON_FAMILY, reason)) return FANOUT_ATTENTION_REASON_FAMILY[reason];
    if (reason.startsWith("execution_")) return "execution";
    if (reason.startsWith("advisory_")) return "advisory";
    if (reason.startsWith("nonterminal_") || reason.startsWith("terminal_")) return "liveness";
    if (reason.startsWith("mutation_")) return "mutation";
    if (reason.startsWith("virtual_diff_")) return "virtual_diff";
    // Evidence reasons are exact-map-only: their four frozen tokens intentionally
    // share no trustworthy prefix. Future evidence-like tokens stay unmapped and
    // visible rather than being guessed into the evidence family.
    return null;
  }

  function fanoutGrouping(run) {
    const attentionGroups = Object.create(null);
    const executionGroups = Object.create(null);
    const unmappedGroup = {key: "attention:unmapped", family: "unmapped", members: [], occurrences: 0, reasons: Object.create(null)};
    FANOUT_ATTENTION_FAMILY_ORDER.forEach(function (family) { attentionGroups[family] = {key: "attention:" + family, family: family, members: [], occurrences: 0, reasons: Object.create(null)}; });
    FANOUT_EXECUTION_STATE_ORDER.forEach(function (execution) { executionGroups[execution] = {key: "execution:" + execution, execution: execution, members: []}; });
    const attentionUnits = [];
    const unmapped = [];
    let attentionOccurrences = 0;
    array(run.units).forEach(function (unit) {
      const attentionRequired = unit.attention && unit.attention.required;
      if (attentionRequired === false) {
        const execution = scalar(unit.execution && unit.execution.state, "unknown");
        const target = executionGroups[execution] || executionGroups.unknown;
        target.members.push(unit);
        return;
      }
      attentionUnits.push(unit);
      if (attentionRequired !== true) {
        unmapped.push({unit: unit, reason: "attention_requirement_unavailable"});
        unmappedGroup.members.push(unit);
        return;
      }
      const families = new Set();
      const unitUnmappedReasons = [];
      const reasons = Array.from(new Set(array(unit.attention && unit.attention.reasons).map(function (reason) { return scalar(reason, "unknown"); })));
      attentionOccurrences += reasons.length;
      reasons.forEach(function (reason) {
        const family = fanoutReasonFamily(reason);
        if (!family) {
          unmapped.push({unit: unit, reason: reason});
          unitUnmappedReasons.push(reason);
          return;
        }
        const group = attentionGroups[family];
        group.occurrences += 1;
        group.reasons[reason] = (group.reasons[reason] || 0) + 1;
        families.add(family);
      });
      FANOUT_ATTENTION_FAMILY_ORDER.forEach(function (family) { if (families.has(family)) attentionGroups[family].members.push(unit); });
      if (families.size === 0) {
        unmappedGroup.members.push(unit);
        unitUnmappedReasons.forEach(function (reason) {
          unmappedGroup.occurrences += 1;
          unmappedGroup.reasons[reason] = (unmappedGroup.reasons[reason] || 0) + 1;
        });
      }
    });
    const attention = FANOUT_ATTENTION_FAMILY_ORDER.map(function (family) { return attentionGroups[family]; }).filter(function (group) { return group.members.length > 0; });
    if (unmappedGroup.members.length > 0) attention.push(unmappedGroup);
    return {
      attentionSiblingCount: attentionUnits.length,
      attentionOccurrences: attentionOccurrences,
      attention: attention,
      execution: FANOUT_EXECUTION_STATE_ORDER.map(function (execution) { return executionGroups[execution]; }).filter(function (group) { return group.members.length > 0; }),
      unmapped: unmapped
    };
  }

  function fanoutGroupLimitations(run, members, group) {
    const values = [];
    array(run.limitations).concat(array(run.source && run.source.limitations)).forEach(function (value) { values.push(scalar(value, "unknown_source_limitation")); });
    array(members).forEach(function (unit) {
      array(unit.limitations).forEach(function (value) { values.push(scalar(value, "unknown_unit_limitation")); });
      if (group && group.family === "evidence" && array(unit.attention && unit.attention.reasons).includes("child_log_missing")) values.push("child_log_missing");
    });
    return Array.from(new Set(values));
  }

  function fanoutAttemptLinks(run, unit, route, groupKey) {
    const attempts = array(unit.attempts);
    if (!attempts.length) return null;
    const nav = el("nav", "attempt-lineage-links");
    nav.setAttribute("aria-label", "Attempt lineage for " + visible(unit.label).text);
    nav.append(text("span", "Attempts: ", "provenance"));
    attempts.forEach(function (attempt, index) {
      const label = attempt.ordinal === null || attempt.ordinal === undefined ? "Provisional" : "Attempt " + (attempt.ordinal + 1);
      nav.append(link(label, routeHash({runId: run.run.id, unitId: unit.logical_id, attemptId: attempt.attempt_id, filters: route.filters, sort: route.sort, q: route.q, follow: route.follow}), "attempt-summary-" + unit.logical_id + "-" + index + ":" + groupKey));
    });
    return nav;
  }

  function fanoutGroup(run, route, group, region) {
    const details = el("details", "fanout-group fanout-group-" + region);
    const pageKey = "fanout:" + encodeURIComponent(run.run.id) + ":" + group.key;
    setDisclosureKey(details, "fanout-group:" + run.run.id + ":" + group.key);
    const summary = key(el("summary"), "fanout-group-summary:" + pageKey);
    const countText = region === "attention" ? titleCase(group.family) + " · " + group.members.length + " siblings · " + group.occurrences + " reason occurrences" : titleCase(group.execution) + " · " + group.members.length + " siblings";
    summary.append(text("span", countText));
    const limitations = fanoutGroupLimitations(run, group.members, group);
    if (limitations.length) summary.append(untrustedText("span", "Observed count limited: " + limitations.map(titleCase).join(" · "), "limitation group-count-limitation"));
    details.append(summary);
    if (region === "attention") {
      const reasonEntries = Object.keys(group.reasons).sort();
      const reasonPageKey = pageKey + ":reasons";
      const reasonPage = state.pages[reasonPageKey] || 1;
      const shownReasons = reasonEntries.slice(0, reasonPage * FANOUT_GROUP_MEMBER_PAGE_SIZE);
      const reasonList = el("ul", "fanout-reason-counts");
      shownReasons.forEach(function (reason) { reasonList.append(untrustedText("li", reason + " · " + group.reasons[reason] + " occurrences")); });
      details.append(reasonList);
      if (shownReasons.length < reasonEntries.length) {
        const remainingReasons = reasonEntries.length - shownReasons.length;
        const revealReasons = Math.min(FANOUT_GROUP_MEMBER_PAGE_SIZE, remainingReasons);
        details.append(key(button("+" + remainingReasons + " more distinct reasons · show next " + revealReasons + " (" + shownReasons.length + " of " + reasonEntries.length + " distinct reasons shown; " + group.occurrences + " observed occurrences total)", function () {
          state.pages[reasonPageKey] = reasonPage + 1;
          details.open = true;
          state.restore = captureView();
          if (shownReasons.length + revealReasons >= reasonEntries.length) state.restore.focus = "fanout-group-summary:" + pageKey;
          renderCurrentGuarded();
        }, "continuation"), "continuation:" + reasonPageKey));
      }
    }
    const page = state.pages[pageKey] || 1;
    const shown = group.members.slice(0, page * FANOUT_GROUP_MEMBER_PAGE_SIZE);
    const list = el("ul", "fanout-tree");
    shown.forEach(function (unit) {
      const item = el("li");
      item.append(unitSummary(run, unit, route, "unit-" + unit.logical_id + ":" + group.key));
      const attempts = fanoutAttemptLinks(run, unit, route, group.key); if (attempts) item.append(attempts);
      list.append(item);
    });
    details.append(list);
    if (shown.length < group.members.length) {
      const remaining = group.members.length - shown.length;
      const reveal = Math.min(FANOUT_GROUP_MEMBER_PAGE_SIZE, remaining);
      details.append(key(button("+" + remaining + " more · show next " + reveal + " (" + shown.length + " of " + group.members.length + " observed siblings shown)", function () {
        state.pages[pageKey] = page + 1;
        details.open = true;
        state.restore = captureView();
        if (shown.length + reveal >= group.members.length) state.restore.focus = "fanout-group-summary:" + pageKey;
        renderCurrentGuarded();
      }, "continuation"), "continuation:" + pageKey));
    }
    return details;
  }

  function fanoutTree(run, route) {
    const section = el("section", "fanout-panel"); section.append(heading(2, "Parent and sibling fan-out"));
    section.append(untrustedText("p", "Parent Session: " + scalar(run.run.parent_session_id, "Unknown"), "tree-parent"));
    section.append(text("p", "Sibling membership only. No dependency edges are inferred for fan-out runs.", "provenance"));
    const grouping = fanoutGrouping(run);
    const attention = el("section", "fanout-region fanout-attention-region");
    attention.append(heading(3, "Attention · " + grouping.attentionSiblingCount + " siblings need attention (" + grouping.attentionOccurrences + " reason occurrences)"));
    const attentionCountLimitations = fanoutGroupLimitations(run, [], null);
    if (attentionCountLimitations.length) attention.append(untrustedText("span", "Observed count limited: " + attentionCountLimitations.map(titleCase).join(" · "), "limitation group-count-limitation"));
    if (grouping.unmapped.length) {
      const unmappedReasonCounts = Object.create(null);
      grouping.unmapped.forEach(function (item) { unmappedReasonCounts[item.reason] = (unmappedReasonCounts[item.reason] || 0) + 1; });
      const unmappedReasonSummary = Object.keys(unmappedReasonCounts).sort().map(function (reason) { return reason + " · " + unmappedReasonCounts[reason] + " occurrences"; });
      attention.append(untrustedText("p", "Unmapped observed attention reasons (never dropped; mixed-family siblings stay in their mapped groups): " + unmappedReasonSummary.join(" · "), "limitation group-count-limitation"));
    }
    if (!grouping.attention.length) attention.append(empty("No parent-observed attention groups."));
    grouping.attention.forEach(function (group) { attention.append(fanoutGroup(run, route, group, "attention")); });
    section.append(attention);
    const executionRegion = el("section", "fanout-region fanout-execution-region");
    executionRegion.append(heading(3, "No parent-observed attention required"));
    if (!grouping.execution.length) executionRegion.append(empty("No siblings without parent-observed attention."));
    grouping.execution.forEach(function (group) { executionRegion.append(fanoutGroup(run, route, group, "execution")); });
    section.append(executionRegion);
    return section;
  }
  function evidenceDrawer(run, refs, disclosureKey) {
    const selected = refs ? array(run.evidence).filter(function (evidence) { return refs.includes(evidence.id); }) : array(run.evidence);
    const details = setDisclosureKey(el("details", "evidence-drawer"), disclosureKey || "evidence");
    details.append(text("summary", "Evidence (" + selected.length + ")"));
    const pageKey = "evidence:" + encodeURIComponent(run.run.id) + ":" + encodeURIComponent(disclosureKey || "all"); const page = state.pages[pageKey] || 1; const shown = selected.slice(0, page * LIMITS.evidence);
    const list = el("ol");
    shown.forEach(function (evidence) {
      const item = el("li", "evidence-row"); item.dataset.authority = evidence.authority;
      item.append(untrustedText("strong", evidence.id)); item.append(marker(evidence.authority, "authority", evidence.source_kind));
      projected(item, "p", evidence.description);
      item.append(untrustedText("small", scalar(evidence.session_id, "No Session") + " · seq " + scalar(evidence.seq, "—") + " · " + titleCase(evidence.source_kind), "provenance"));
      list.append(item);
    });
    details.append(list);
    if (shown.length < selected.length) details.append(key(button("Show next 100 evidence rows", function () { state.pages[pageKey] = page + 1; details.open = true; renderCurrentGuarded(); }, "continuation"), "continuation:" + pageKey));
    return details;
  }
  function limitationsPanel(values) {
    const section = el("section", "limitations-panel"); section.append(heading(2, "Limitations"));
    const items = array(values); if (!items.length) section.append(empty("No projected limitations."));
    else { const list = el("ul"); items.forEach(function (item) { list.append(untrustedText("li", titleCase(item), "limitation")); }); section.append(list); }
    return section;
  }
  /**
   * Renders the follow panel for a run detail. Follow is explicit route state —
   * a selection-stability policy that keeps the same logical run selected across
   * authoritative refetches. It never silently switches runs; terminal and
   * degraded conditions are surfaced as labeled markers, and identity loss
   * degrades deterministically via renderFollowDegraded.
   * @param {Object} run Projected run detail.
   * @param {Object} route Parsed route carrying the follow flag.
   * @returns {HTMLElement}
   */
  function followToggle(run, route) {
    const wrap = el("section", "follow-panel");
    wrap.dataset.followState = route.follow === true ? "following" : "not_following";
    wrap.setAttribute("role", "status");
    if (route.follow === true) {
      wrap.append(text("strong", "Following this run"));
      wrap.append(text("p", "Follow keeps this logical run selected across authoritative refetches. It never silently switches runs.", "provenance"));
      if (run.execution && run.execution.terminal === true) wrap.append(labeledMarker("Followed run reached a terminal state: " + titleCase(run.execution.state), run.execution.state, "follow execution", run.execution.basis));
      const liveness = run.liveness && run.liveness.state;
      if (liveness === "owner_unavailable" || liveness === "stale_handle") wrap.append(labeledMarker("Followed run is " + titleCase(liveness), liveness, "follow liveness", run.liveness && run.liveness.basis));
      wrap.append(link("Unfollow", semanticZoomRoute(route, {follow: false}), "follow-off"));
    } else {
      wrap.append(link("Follow this run", semanticZoomRoute(route, {follow: true}), "follow-on"));
    }
    return wrap;
  }
  function renderFollowErrorView(route, options, failure) {
    const root = el("div", "view error-view " + options.className);
    if (failure) applyFailureDiagnostic(root, failure);
    root.dataset.followState = options.followState;
    root.append(heading(1, options.title));
    root.append(untrustedText("p", options.message, "empty-state"));
    root.append(text("p", options.provenance, "provenance"));
    if (route.runId) {
      const canonical = semanticZoomRoute(route, {follow: true});
      root.append(button(options.retryLabel, function () {
        const currentRoute = parseRoute(location.hash);
        const currentCanonical = currentRoute.runId ? semanticZoomRoute(currentRoute, {follow: true}) : canonical;
        if (currentRoute.runId && location.hash !== currentCanonical) { state.forceRefetch = true; location.hash = currentCanonical; } else refreshSingleFlight(options.retryReason);
      }, "follow-retry"));
    }
    root.append(button("Refetch authoritative snapshot", function () { refreshSingleFlight(options.retryReason); }, "continuation"));
    root.append(link("Unfollow and return to Runs", semanticZoomRoute(route, {runId: null, unitId: null, attemptId: null, follow: false}), "return-runs"));
    replaceContent(root, options.announcement);
    setStatus(options.status);
  }
  function renderFollowDegraded(route, message, failure) {
    renderFollowErrorView(route, {
      className: "follow-degraded",
      followState: "degraded",
      title: "Follow degraded",
      message: message,
      provenance: "The followed run is not projected in the authoritative snapshot. Follow never silently switches to another run; it degrades here deterministically.",
      retryLabel: "Retry followed run",
      retryReason: "follow retry",
      announcement: "Follow degraded. " + message,
      status: "Follow degraded · followed identity unavailable · authoritative snapshots remain available"
    }, failure);
  }
  function renderFollowUnitUnavailable(route, message, failure) {
    renderFollowErrorView(route, {
      className: "follow-unit-unavailable",
      followState: "unit_unavailable",
      title: "Unit unavailable while following",
      message: message,
      provenance: "The followed run identity is still projected. Only this logical unit is absent within the followed run; Follow did not switch or lose the run.",
      retryLabel: "Retry followed unit",
      retryReason: "follow unit retry",
      announcement: "Followed run remains selected; the logical Unit is unavailable. " + message,
      status: "Followed run present · logical unit unavailable · authoritative snapshots remain available"
    }, failure);
  }
  function renderFollowSnapshotUnavailable(route, message, failure) {
    const cachedIdentity = state.detailId === route.runId && (!workspaceSetMode() || state.detailWorkspace === route.workspace);
    const unstructured404 = failure && failure.phase === "fetch" && failure.status === 404 && failure.structured !== true;
    const structuredNonLoss404 = failure && failure.phase === "fetch" && failure.status === 404 && failure.structured === true && failure.kind !== "run_not_found";
    const transientFetch = failure && failure.phase === "fetch" && failure.status !== 404;
    const decodeFailure = failure && failure.phase === "decode";
    const preservedIdentityFailure = cachedIdentity && (transientFetch || decodeFailure);
    const unavailableProvenance = unstructured404 ? "The authoritative response was not a structured run-not-found signal. Any cached Follow snapshot for this followed run was discarded; this response did not confirm identity and Follow did not infer loss." : structuredNonLoss404 ? "The authoritative response was structured but did not confirm run-not-found. Any cached Follow snapshot for this followed run was discarded; this response did not confirm identity and Follow did not infer identity loss." : preservedIdentityFailure ? "The latest authoritative response could not be used. The followed identity was last confirmed for this run; Follow did not infer identity loss." : route.unitId ? "The authoritative snapshot could not confirm either the followed run or this logical Unit. Follow did not switch or infer identity loss." : "The authoritative snapshot could not confirm the followed run. Follow did not switch or infer identity loss.";
    const unavailableStatus = preservedIdentityFailure ? "Follow refetch failed · identity last confirmed · authoritative snapshots remain available" : "Follow snapshot unavailable · identity not confirmed · authoritative snapshots remain available";
    renderFollowErrorView(route, {
      className: "follow-snapshot-unavailable",
      followState: "snapshot_unavailable",
      title: "Follow snapshot unavailable",
      message: message,
      provenance: unavailableProvenance,
      retryLabel: route.unitId ? "Retry followed unit" : "Retry followed run",
      retryReason: "follow snapshot retry",
      announcement: "Follow snapshot unavailable. " + message,
      status: unavailableStatus
    }, failure);
  }
  function renderFollowIdentityConflict(route, message, failure) {
    renderFollowErrorView(route, {
      className: "follow-identity-conflict",
      followState: "identity_conflict",
      title: "Follow identity conflict",
      message: message,
      provenance: "The authoritative snapshot contradicted the followed run identity. Follow did not switch runs or infer that the followed identity disappeared.",
      retryLabel: route.unitId ? "Retry followed unit" : "Retry followed run",
      retryReason: "follow identity conflict retry",
      announcement: "Follow identity conflict. " + message,
      status: "Follow identity conflict · followed identity not confirmed · authoritative snapshots remain available"
    }, failure);
  }
  function renderFollowRenderFailure(route, message, failure) {
    renderFollowErrorView(route, {
      className: "follow-render-failure",
      followState: "render_failure",
      title: "Follow display failed",
      message: message,
      provenance: "The followed identity was last confirmed by an authoritative snapshot, but this view could not display it. Follow did not switch or infer identity loss.",
      retryLabel: route.unitId ? "Retry followed unit" : "Retry followed run",
      retryReason: "follow display retry",
      announcement: "Follow display failed. " + message,
      status: "Follow display failed · followed identity last confirmed · authoritative snapshots remain available"
    }, failure);
  }
  function renderDetail() {
    const run = state.detail; const route = parseRoute(location.hash);
    if (!run || !run.run || typeof run.run.id !== "string" || !run.run.id) return route.follow === true ? renderFollowSnapshotUnavailable(route, "Run projection is unavailable.") : renderUnavailable("Run projection is unavailable.");
    if (route.runId !== run.run.id) return route.follow === true ? renderFollowIdentityConflict(route, "The authoritative snapshot returned a different run identity than the one being followed.") : renderUnavailable("The requested run no longer matches this projection.");
    const root = el("div", "view detail-view");
    root.append(link("← Runs", semanticZoomRoute(route, {runId: null, unitId: null, attemptId: null, follow: false}), "back-runs"));
    const titleRow = el("div", "title-with-copy"); titleRow.append(projectedHeading(1, scalar(run.run.title, run.run.id))); titleRow.append(copyValueButton(run.run.id, "run id")); root.append(titleRow);
    root.append(followToggle(run, route));
    root.append(untrustedText("p", titleCase(run.run.strategy) + " · " + titleCase(run.run.mode) + " · projection " + scalar(run.projection_id, "unknown"), "lede"));
    root.append(truthRail(run)); root.append(mutationPanel(run.mutation));
    const overview = setDisclosureKey(el("details", "overview-disclosure"), "run-overview:" + run.run.id); overview.append(text("summary", "Run identifiers and counts")); overview.append(runOverview(run)); root.append(overview);
    if (run.run.strategy === "workflow") {
      root.append(workflowGraph(run, route));
    } else {
      root.append(fanoutTree(run, route));
    }
    root.append(usagePanel(run.usage, "usage:run:" + run.run.id)); root.append(actionsPanel(run.safe_actions, "run", run.run.id));
    root.append(limitationsPanel(run.limitations)); root.append(evidenceDrawer(run, null, "run-evidence"));
    replaceContent(root, (run.run.strategy === "workflow" ? "Workflow" : "Subagent fan-out") + " run updated.");
    setStatus("Read-only · " + titleCase(run.source && run.source.mode) + " projection · as of seq " + scalar(run.source && run.source.as_of_seq, "unknown"));
  }

  function usagePanel(usage, disclosureKey) {
    const section = setDisclosureKey(el("details", "usage-panel"), disclosureKey);
    section.append(text("summary", "Evidence-derived usage · " + scalar(usage && usage.calls, 0) + " calls · " + (usage && usage.complete ? "Complete" : "Incomplete")));
    section.append(text("p", scalar(usage && usage.calls, 0) + " durable provider call(s) · " + (usage && usage.complete ? "complete at observed boundary" : "incomplete") + " · source " + titleCase(usage && usage.source), "provenance"));
    const groups = array(usage && usage.groups);
    if (!groups.length) section.append(empty("No attributable provider usage groups."));
    else {
      const table = el("table"); const head = el("thead"); const tr = el("tr");
      ["Provider / model", "Calls", "Input", "Output", "Reasoning", "Total", "Cached", "Cache create", "Cache read"].forEach(function (name) { tr.append(text("th", name)); }); head.append(tr); table.append(head);
      const body = el("tbody"); groups.forEach(function (group) { const row = el("tr"); row.append(untrustedText("td", scalar(group.provider, "unknown") + " / " + scalar(group.model, "unknown"))); ["calls", "input_tokens", "output_tokens", "reasoning_tokens", "total_tokens", "cached_tokens", "cache_creation_tokens", "cache_read_tokens"].forEach(function (name) { row.append(text("td", scalar(group[name], 0))); }); body.append(row); }); table.append(body); section.append(table);
    }
    array(usage && usage.limitations).forEach(function (item) { section.append(untrustedText("p", titleCase(item), "limitation")); });
    return section;
  }
  function activityFor(run, attempt) {
    const refs = array(attempt.evidence_refs);
    return array(run.evidence).filter(function (evidence) { return refs.includes(evidence.id); });
  }
  function attemptCard(run, unit, attempt, selected) {
    const card = el("article", "attempt-card"); card.dataset.attemptId = attempt.attempt_id;
    if (selected) card.classList.add("selected");
    const ordinal = attempt.ordinal === null || attempt.ordinal === undefined ? "Provisional" : "Attempt " + (attempt.ordinal + 1);
    const header = el("header"); header.append(heading(3, ordinal)); header.append(marker(attempt.status, "attempt execution", attempt.status_basis)); header.append(text("span", titleCase(attempt.relation), "relation"));
    const activeRoute = parseRoute(location.hash);
    header.append(link("Select", semanticZoomRoute(activeRoute, {attemptId: attempt.attempt_id}), "attempt-" + attempt.attempt_id));
    card.append(header);
    const facts = el("dl", "attempt-facts");
    const childField = field("Child Session", attempt.child_session_id); childField.querySelector("dd").append(copyValueButton(attempt.child_session_id, "child Session id")); facts.append(childField);
    if (attempt.predecessor_attempt_id) {
      const predecessor = array(unit.attempts).find(function (candidate) { return candidate.attempt_id === attempt.predecessor_attempt_id; });
      if (predecessor) {
        const predecessorFact = el("div", "field"); predecessorFact.append(text("dt", "Predecessor"));
        const predecessorLabel = predecessor.ordinal === null || predecessor.ordinal === undefined ? "Provisional" : "Attempt " + (predecessor.ordinal + 1);
        const predecessorLink = projectedLink("↩ " + predecessorLabel + " · " + scalar(predecessor.child_session_id, "Unknown child"), semanticZoomRoute(activeRoute, {attemptId: predecessor.attempt_id}), "predecessor-" + predecessor.attempt_id);
        predecessorLink.addEventListener("click", function () { state.pendingAttemptScroll = predecessor.attempt_id; });
        predecessorFact.append(predecessorLink); facts.append(predecessorFact);
      }
    }
    facts.append(field("Started", attempt.started_at)); facts.append(field("Ended", attempt.ended_at)); facts.append(field("Error", attempt.error_kind)); facts.append(field("Materialization", attempt.materialization)); facts.append(field("Window basis", attempt.child_event_window && attempt.child_event_window.basis)); facts.append(field("From seq", attempt.child_event_window && attempt.child_event_window.from_seq)); facts.append(field("To seq exclusive", attempt.child_event_window && attempt.child_event_window.to_seq_exclusive)); card.append(facts);
    if (attempt.summary) projected(card, "p", attempt.summary, "attempt-summary");
    card.append(usagePanel(attempt.usage || {source: "none", complete: true, calls: 0, groups: [], limitations: []}, "usage:attempt:" + attempt.attempt_id));
    const activity = setDisclosureKey(el("details", "activity-drawer"), "activity:" + attempt.attempt_id); activity.append(text("summary", "Attempt activity via evidence references (" + activityFor(run, attempt).length + ")"));
    const allActivity = activityFor(run, attempt); const activityPageKey = "activity:" + encodeURIComponent(run.run.id) + ":" + encodeURIComponent(unit.logical_id) + ":" + encodeURIComponent(attempt.attempt_id); const activityPage = state.pages[activityPageKey] || 1;
    const newestFirst = state.activityOrder[activityPageKey] === "newest";
    activity.append(button(newestFirst ? "Order: newest first" : "Order: chronological (oldest first)", function () { state.activityOrder[activityPageKey] = newestFirst ? "chronological" : "newest"; state.pages[activityPageKey] = 1; renderCurrentGuarded(); }, "activity-order"));
    const orderedActivity = newestFirst ? allActivity.slice().reverse() : allActivity;
    const visibleActivity = orderedActivity.slice(0, activityPage * LIMITS.evidence);
    const activityTable = el("table", "activity-table"); const activityHead = el("thead"); const activityHeader = el("tr"); ["Authority", "Source kind", "Session", "Seq", "Description"].forEach(function (name) { activityHeader.append(text("th", name)); }); activityHead.append(activityHeader); activityTable.append(activityHead);
    const activityBody = el("tbody"); visibleActivity.forEach(function (evidence) { const row = el("tr"); row.append(text("td", titleCase(evidence.authority))); row.append(text("td", titleCase(evidence.source_kind))); row.append(untrustedText("td", evidence.session_id)); row.append(text("td", scalar(evidence.seq, "—"))); row.append(untrustedText("td", evidence.description)); activityBody.append(row); }); activityTable.append(activityBody); activity.append(activityTable);
    if (visibleActivity.length < allActivity.length) activity.append(key(button("Show next 100 activity rows", function () { state.pages[activityPageKey] = activityPage + 1; activity.open = true; renderCurrentGuarded(); }, "continuation"), "continuation:" + activityPageKey));
    card.append(activity);
    array(attempt.limitations).forEach(function (item) { card.append(untrustedText("p", titleCase(item), "limitation")); });
    return card;
  }
  function hasDangerousShell(command) { return /(?:[|;&`<>]|\$\(|\$\{|\n|\r)/u.test(command); }
  function hasReviewCodepoint(command) {
    return /^[\s]|[\s]$/u.test(command) || /[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f-\u009f\u061c\u200e\u200f\u2028-\u202e\u2066-\u2069]/u.test(command);
  }
  /**
   * Classifies a projected safe action's command for the copy affordance. The
   * monitor never executes commands; classification only decides whether a copy
   * needs explicit byte review first (mutating effect, control or whitespace
   * codepoints, or shell syntax).
   * @param {Object} action Projected safe action.
   * @returns {{copyable: boolean, review: boolean, reason: string}}
   */
  function classifyCommand(action) {
    const command = action && typeof action.command === "string" ? action.command : "";
    if (!command || !action || action.presentation !== "copy_only") return {copyable: false, review: false, reason: "not_copyable"};
    if (action.effect === "mutating") return {copyable: true, review: true, reason: "mutating"};
    if (hasReviewCodepoint(command)) return {copyable: true, review: true, reason: "controls_or_whitespace"};
    if (hasDangerousShell(command)) return {copyable: true, review: true, reason: "shell_syntax"};
    return {copyable: true, review: false, reason: "simple"};
  }
  /**
   * Escapes evidence text for the clipboard: newlines, carriage returns, and
   * tabs become their two-character escapes, and every other control or
   * bidirectional codepoint becomes a visible Unicode escape. This is the only
   * transform between projected text and the single clipboard sink.
   * @param {string} raw Projected evidence text.
   * @returns {string} Escaped text safe to paste anywhere.
   */
  function escapedEvidence(raw) {
    let result = "";
    for (const character of raw) {
      const cp = character.codePointAt(0);
      if (cp === 0x0a) result += "\\n"; else if (cp === 0x0d) result += "\\r"; else if (cp === 0x09) result += "\\t";
      else if (cp < 0x20 || (cp >= 0x7f && cp <= 0x9f) || (cp >= 0x2028 && cp <= 0x202e) || (cp >= 0x2066 && cp <= 0x2069) || cp === 0x061c || cp === 0x200e || cp === 0x200f) result += "\\u{" + cp.toString(16).toUpperCase() + "}";
      else result += character;
    }
    return result;
  }
  // Clipboard contract (FROZEN for v1.x): escaped-only. Every copy affordance routes
  // through writeClipboard, which applies escapedEvidence at the single sink. No raw-byte
  // copy path exists anywhere in this bundle; hostile text stays literal on screen.
  function writeClipboard(value, onDone, successMessage) {
    if (!navigator.clipboard || typeof navigator.clipboard.writeText !== "function") { announce("Clipboard unavailable. Nothing was copied."); return; }
    navigator.clipboard.writeText(escapedEvidence(scalar(value, ""))).then(function () { announce(successMessage || "Safely escaped command evidence copied without an added newline."); if (onDone) onDone(); }).catch(function () { announce("Clipboard permission denied. Nothing was copied."); });
  }
  function copyProjectedValue(value, label) {
    const raw = scalar(value, "");
    if (!raw) { announce(label + " is unavailable. Nothing was copied."); return; }
    if (hasReviewCodepoint(raw)) reviewProjectedValueModal(raw, label);
    else writeClipboard(raw, null, label + " safely escaped evidence copied without an added newline.");
  }
  function copyValueButton(value, label) {
    const node = button("⧉", function () { copyProjectedValue(value, label); }, "copy-id-button");
    node.setAttribute("aria-label", "Copy " + label); return node;
  }
  function reviewModal(action) {
    const dialog = el("dialog", "review-dialog"); dialog.setAttribute("aria-labelledby", "review-title");
    dialog.append(heading(2, "Review command before copying")); dialog.lastChild.id = "review-title";
    dialog.append(text("p", "Reason: " + titleCase(classifyCommand(action).reason) + ". This monitor never executes commands."));
    projected(dialog, "pre", action.command, "command-review");
    const actions = el("div", "dialog-actions");
    actions.append(button("Cancel", function () { dialog.close(); dialog.remove(); }, "secondary"));
    actions.append(button("Copy safely escaped evidence", function () { writeClipboard(action.command, function () { dialog.close(); dialog.remove(); }, "Safely escaped command evidence copied without an added newline."); }, "primary"));
    dialog.append(text("p", "Escaped-only clipboard is frozen for v1.x. No raw-byte copy exists.", "provenance"));
    dialog.append(actions); document.body.append(dialog); dialog.showModal();
  }
  function reviewProjectedValueModal(value, label) {
    const dialog = el("dialog", "review-dialog"); dialog.setAttribute("aria-labelledby", "projected-review-title");
    dialog.append(heading(2, "Review " + label + " before copying")); dialog.lastChild.id = "projected-review-title";
    dialog.append(text("p", "Projected identifiers with controls or surrounding whitespace require explicit byte review."));
    projected(dialog, "pre", value, "command-review");
    const actions = el("div", "dialog-actions");
    actions.append(button("Cancel", function () { dialog.close(); dialog.remove(); }, "secondary"));
    actions.append(button("Copy safely escaped evidence", function () { writeClipboard(value, function () { dialog.close(); dialog.remove(); }, label + " safely escaped evidence copied without an added newline."); }, "primary"));
    dialog.append(text("p", "Escaped-only clipboard is frozen for v1.x. No raw-byte copy exists.", "provenance"));
    dialog.append(actions); document.body.append(dialog); dialog.showModal();
  }
  function artifactPanel(artifacts) {
    const section = el("section", "artifacts-panel"); section.append(heading(2, "Artifacts"));
    const values = array(artifacts); if (!values.length) { section.append(empty("No projected artifacts.")); return section; }
    const list = el("ul"); values.slice(0, LIMITS.evidence).forEach(function (artifact) {
      const item = el("li", "artifact-row"); item.append(untrustedText("strong", titleCase(artifact.kind))); item.append(marker(artifact.status, "artifact", artifact.correlation));
      const facts = el("dl", "artifact-facts"); [
        ["Version", artifact.version], ["Hash", artifact.hash], ["Workspace strategy", artifact.workspace_strategy],
        ["Producer unit", artifact.producer_unit_id], ["Source artifact hash", artifact.source_artifact_hash],
        ["Application state", artifact.application_state], ["Applied by unit", artifact.applied_by_unit_id], ["Correlation", artifact.correlation]
      ].forEach(function (entry) { facts.append(field(entry[0], entry[1])); }); item.append(facts); list.append(item);
    }); section.append(list); return section;
  }
  function actionsPanel(actions, contextKind, contextId) {
    const section = el("section", "actions-panel"); section.append(heading(2, "Structured safe actions"));
    const values = array(actions);
    if (!values.length) {
      const kind = scalar(contextKind, "surface");
      section.append(untrustedText("p", "No registered safe actions for " + kind + " " + scalar(contextId, "unknown") + ".", "limitation"));
      section.append(text("p", "This " + kind + " exposes no executable affordance. Registered copy_only actions are the only executable affordance the monitor ever offers.", "provenance"));
      return section;
    }
    const list = el("ul"); values.forEach(function (action) {
      const item = el("li", "action-row"); item.append(untrustedText("strong", titleCase(action.id))); item.append(text("span", titleCase(action.effect) + " · " + titleCase(action.kind) + " · from " + titleCase(action.source_field), "provenance"));
      const classification = classifyCommand(action);
      if (classification.copyable) {
        projected(item, "code", action.command);
        item.append(button(classification.review ? "Review to copy" : "Copy command", function () { if (classification.review) reviewModal(action); else writeClipboard(action.command); }, "copy-button"));
      } else item.append(text("p", "Informational guidance only. No executable control is exposed."));
      list.append(item);
    }); section.append(list); return section;
  }
  function renderUnit() {
    const run = state.detail; const route = parseRoute(location.hash);
    if (!run || !run.run || typeof run.run.id !== "string" || !run.run.id) return route.follow === true ? renderFollowSnapshotUnavailable(route, "Run projection is unavailable.") : renderUnavailable("Run projection is unavailable.");
    if (route.runId !== run.run.id) return route.follow === true ? renderFollowIdentityConflict(route, "The authoritative snapshot returned a different run identity than the one being followed.") : renderUnavailable("The requested run no longer matches this projection.");
    const unit = array(run.units).find(function (candidate) { return candidate.logical_id === route.unitId; });
    if (!unit) return route.follow === true ? renderFollowUnitUnavailable(route, "This logical unit is absent within the followed run's last authoritative snapshot or its provisional deep link was invalidated.") : renderUnavailable("This logical unit is absent or its provisional deep link was invalidated.");
    const root = el("div", "view unit-view"); root.append(projectedLink("← " + scalar(run.run.title, run.run.id), semanticZoomRoute(route, {unitId: null, attemptId: null}), "back-run"));
    root.append(followToggle(run, route));
    const unitTitle = el("div", "title-with-copy"); unitTitle.append(projectedHeading(1, unit.label)); unitTitle.append(copyValueButton(unit.logical_id, "logical id")); root.append(unitTitle); root.append(untrustedText("p", "Logical unit · " + unit.logical_id, "lede"));
    const unitOverview = el("dl", "run-overview"); [["Agent", unit.agent], ["Kind", unit.unit_kind], ["Execution kind", unit.execution_kind], ["Workspace", unit.workspace_mode], ["Posture", unit.posture], ["Materialization", unit.materialization], ["Depends on", array(unit.depends_on).join(", ") || "None"]].forEach(function (entry) { unitOverview.append(field(entry[0], entry[1])); }); root.append(unitOverview);
    const dimensions = el("div", "unit-dimensions"); dimensions.append(truthCard("Execution", "execution", unit.execution && unit.execution.state, unit.execution && unit.execution.basis)); dimensions.append(truthCard("Liveness", "liveness", unit.liveness && unit.liveness.state, unit.liveness && unit.liveness.basis)); dimensions.append(truthCard("Runtime gate", "gate", unit.gate && unit.gate.state, unit.gate && unit.gate.basis)); dimensions.append(truthCard("Model advisory", "advisory", unit.advisory && unit.advisory.verdict, "model declared", "Declared gate: " + scalar(unit.advisory && unit.advisory.declared_gate, "none"))); root.append(dimensions);
    if (unit.advisory && unit.advisory.present) { const advisory = el("section", "advisory-panel"); advisory.append(heading(2, "Model-authored advisory")); advisory.append(text("p", "This content is advisory and cannot alter the runtime gate.", "provenance")); projected(advisory, "p", unit.advisory.summary || unit.advisory.raw_excerpt || "No summary"); root.append(advisory); }
    const lineage = el("section", "lineage"); lineage.append(heading(2, "Attempt lineage")); const attempts = array(unit.attempts); const attemptPageKey = "attempts:" + encodeURIComponent(run.run.id) + ":" + encodeURIComponent(unit.logical_id); const selectedAttemptIndex = attempts.findIndex(function (attempt) { return attempt.attempt_id === route.attemptId; }); const projectedAttemptId = selectedAttemptIndex >= 0 ? route.attemptId : null; const selectedAttemptPage = selectedAttemptIndex < 0 ? 1 : Math.floor(selectedAttemptIndex / LIMITS.attempts) + 1; const page = Math.max(state.pages[attemptPageKey] || 1, selectedAttemptPage); const shown = attempts.slice(0, page * LIMITS.attempts);
    if (!shown.length) lineage.append(empty("This engine-only unit has no Subagent attempts."));
    shown.forEach(function (attempt) { lineage.append(attemptCard(run, unit, attempt, route.attemptId === attempt.attempt_id)); });
    if (shown.length < attempts.length) lineage.append(key(button("Show next 20 attempts", function () { state.pages[attemptPageKey] = page + 1; renderCurrentGuarded(); }, "continuation"), "continuation:" + attemptPageKey)); root.append(lineage);
    root.append(usagePanel(unit.usage, "usage:unit:" + unit.logical_id)); root.append(artifactPanel(unit.artifacts)); root.append(mutationPanel(unit.mutation)); root.append(actionsPanel(unit.safe_actions, "logical unit", unit.logical_id + (projectedAttemptId ? " · attempt " + projectedAttemptId : ""))); root.append(limitationsPanel(unit.limitations)); root.append(evidenceDrawer(run, unit.evidence_refs, "unit-evidence:" + unit.logical_id));
    replaceContent(root, "Unit inspector updated. " + attempts.length + " attempts.");
    if (state.pendingAttemptScroll && state.pendingAttemptScroll === route.attemptId) {
      const pending = state.pendingAttemptScroll; state.pendingAttemptScroll = null;
      requestAnimationFrame(function () {
        const target = Array.from(document.querySelectorAll("[data-attempt-id]")).find(function (candidate) { return candidate.dataset.attemptId === pending; });
        if (target) target.scrollIntoView({behavior: "smooth", block: "nearest"});
      });
    }
    setStatus("Read-only · unit inspector · ordinal attempts are displayed one-based");
  }
  function renderWorkspaceOverview() {
    const root = el("div", "view workspace-overview");
    root.append(heading(1, "Workspace Overview"));
    root.append(text("p", "Two explicitly configured local sources. Counts are observed per source; no set-level total is calculated.", "lede"));
    shellConfig.workspaces.forEach(function (workspace) {
      const held = workspaceSnapshots[workspace] || {};
      const section = el("section", "workspace-source");
      section.dataset.workspace = workspace;
      section.append(untrustedText("h2", workspace));
      const condition = el("div", "source-condition");
      condition.append(text("h3", "Source condition"));
      if (held.listError) {
        const degradation = el("div", "source-degradation");
        const notices = el("div", "source-degradation-notices");
        notices.append(untrustedText("p", "Source unreachable · " + held.listError.kind, "source-error"));
        if (held.list) notices.append(untrustedText("p", "Stale snapshot held · received " + held.listObservedAt + " · refresh failure " + held.listError.kind, "stale-disclosure"));
        else notices.append(text("p", "Unavailable. No observed count is held; retry the authoritative source.", "source-error"));
        degradation.append(notices);
        degradation.append(key(button("Retry this source", function () { refetchWorkspaceList(workspace, "source retry"); }, "source-retry"), "source-retry:" + workspace));
        condition.append(degradation);
      }
      if (held.list) {
        const envelope = held.list;
        const inventory = envelope.snapshot && envelope.snapshot.inventory || {};
        const provenance = envelope.source && envelope.source.sessions_directory;
        const receiptLabel = held.listError ? "last-observed " : "observed-at ";
        const receiptBoundary = receiptLabel + scalar(held.listObservedAt, "unknown");
        condition.append(untrustedText("p", "Authoritative scoped snapshot · " + receiptBoundary, "provenance"));
        const stats = el("p", "source-stats");
        const observedStat = el("span", "source-stat");
        observedStat.append(text("span", "Observed Session Logs: "));
        observedStat.append(untrustedText("strong", scalar(inventory.total, "unknown"), "source-stat-value"));
        stats.append(observedStat);
        stats.append(text("span", " · ", "source-stat-separator"));
        const selectedStat = el("span", "source-stat");
        selectedStat.append(text("span", "selected "));
        selectedStat.append(untrustedText("strong", scalar(inventory.selected, "unknown"), "source-stat-value"));
        stats.append(selectedStat);
        stats.append(text("span", " · ", "source-stat-separator"));
        const truncatedStat = el("span", "source-stat");
        truncatedStat.append(text("span", "truncated "));
        truncatedStat.append(untrustedText("strong", scalar(inventory.truncated, "unknown"), "source-stat-value"));
        stats.append(truncatedStat);
        stats.append(untrustedText("span", " · " + receiptBoundary, "source-stat-receipt"));
        condition.append(stats);
        const evidence = setDisclosureKey(el("details", "source-evidence"), "source-evidence:" + workspace);
        evidence.append(key(text("summary", "Evidence details"), "source-evidence:" + workspace));
        evidence.append(untrustedText("p", "Sessions directory provenance: " + provenance + " · " + receiptBoundary));
        evidence.append(untrustedText("p", "Inventory bases: projected_runs " + scalar(inventory.projected_runs, "unknown") + " · non_parent_logs " + scalar(inventory.non_parent_logs, "unknown") + " · dropped_logs " + scalar(inventory.dropped_logs, "unknown") + " · " + receiptBoundary));
        array(inventory.limitations).forEach(function (limitation) {
          condition.append(untrustedText("p", "Observed count limited: " + scalar(limitation.kind, "unknown_limitation") + " · " + receiptBoundary, "limitation"));
          const details = limitation && limitation.details && typeof limitation.details === "object" && !Array.isArray(limitation.details) ? limitation.details : {};
          const detailKeys = Object.keys(details).filter(function (name) { return name !== "error_kinds"; }).sort();
          if (detailKeys.length) evidence.append(untrustedText("p", "Limitation details: " + detailKeys.map(function (name) { return name + " " + scalar(details[name], "unknown"); }).join(" · ") + " · " + receiptBoundary, "limitation"));
          const errorKinds = details.error_kinds && typeof details.error_kinds === "object" && !Array.isArray(details.error_kinds) ? details.error_kinds : {};
          const errorKindKeys = Object.keys(errorKinds).sort();
          if (errorKindKeys.length) evidence.append(untrustedText("p", "Error kinds: " + errorKindKeys.map(function (kind) { return kind + " " + scalar(errorKinds[kind], "unknown"); }).join(" · ") + " · " + receiptBoundary, "limitation"));
        });
        condition.append(evidence);
      }
      section.append(condition);
      const attention = el("div", "source-attention");
      attention.append(text("h3", "Parent-observed attention"));
      const rows = held.list && held.list.snapshot ? array(held.list.snapshot.runs) : [];
      const attentionRows = rows.filter(function (row) { return row.attention && row.attention.required === true; });
      if (held.list) {
        if (!attentionRows.length) attention.append(empty("No parent-observed attention in the held snapshot."));
        attentionRows.forEach(function (row) { const id = row.run && row.run.id || row.id; attention.append(projectedLink(row.run && row.run.title || id, routeHash({workspace: workspace, runId: id, filters: {}, sort: DEFAULT_SORT}), "workspace-attention:" + workspace + ":" + id)); });
      } else attention.append(text("p", "Attention and remaining runs are unavailable because no source snapshot is held.", "empty-state source-regions-unavailable"));
      section.append(attention);
      const rest = el("div", "source-runs");
      rest.append(text("h3", "Remaining observed runs"));
      if (held.list) {
        const remainingRows = rows.filter(function (row) { return !(row.attention && row.attention.required === true); });
        if (!remainingRows.length) rest.append(empty("No remaining observed runs in the held snapshot."));
        else {
          const remaining = setDisclosureKey(el("details", "remaining-runs-disclosure"), "remaining-runs:" + workspace);
          remaining.append(key(text("summary", "View all remaining runs"), "remaining-runs:" + workspace));
          const remainingList = el("div", "remaining-runs-list");
          remainingRows.forEach(function (row) { const id = row.run && row.run.id || row.id; remainingList.append(projectedLink(row.run && row.run.title || id, routeHash({workspace: workspace, runId: id, filters: {}, sort: DEFAULT_SORT}), "workspace-run:" + workspace + ":" + id)); });
          remaining.append(remainingList);
          rest.append(remaining);
        }
      }
      section.append(rest);
      root.append(section);
    });
    replaceContent(root, "Workspace Overview updated. Two source sections remain in declaration order.");
    setStatus("Read-only Workspace Overview · per-source authority and freshness");
  }

  function renderUnavailable(message, failure) { const root = el("div", "view error-view"); if (failure) applyFailureDiagnostic(root, failure); root.append(heading(1, "Projection unavailable")); root.append(text("p", message, "empty-state")); root.append(link(workspaceSetMode() ? "Return to Workspace Overview" : "Return to Runs", workspaceSetMode() ? "#/workspaces" : "#/runs", "return-runs")); replaceContent(root, message); setStatus(failure ? projectionFailureStatus(failure) : "Requested projection unavailable; return to Runs or relaunch."); }
  function renderCurrent() { const route = parseRoute(location.hash); if (route.view === "workspaces") renderWorkspaceOverview(); else if (route.view === "runs") renderRuns(); else if (route.view === "unit") renderUnit(); else if (route.view === "invalid") renderUnavailable("The requested route is invalid or could not be decoded."); else renderDetail(); }
  function renderProjectionFailure(error) {
    const route = parseRoute(location.hash);
    const failure = normalizeProjectionFailure(error);
    const message = projectionFailureMessage(failure);
    const authorityUnavailable = route.runId && (failure.phase === "fetch" || failure.phase === "decode");
    const identityLoss = route.runId && failure.phase === "fetch" && failure.status === 404 && failure.structured === true && failure.kind === "run_not_found";
    const identityConflict = route.follow === true && route.runId && state.detailConflict === true && state.detail && state.detail.run && state.detail.run.id !== route.runId;
    if (authorityUnavailable) {
      state.detail = null;
      state.detailConflict = false;
    }
    if (identityLoss) state.detailId = null;
    if (identityLoss && route.follow === true) renderFollowDegraded(route, "The followed run is not projected in the authoritative snapshot.", failure);
    else if (identityConflict && failure.phase === "render") {
      try { renderFollowIdentityConflict(route, "The authoritative snapshot returned a different run identity than the one being followed.", failure); }
      finally { state.detail = null; state.detailConflict = false; }
    }
    else if (route.follow === true && route.runId && failure.phase === "render" && state.detailId === route.runId && (!workspaceSetMode() || state.detailWorkspace === route.workspace)) {
      try { renderFollowRenderFailure(route, message, failure); }
      finally { state.detail = null; state.detailConflict = false; }
    }
    else if (route.follow === true && route.runId) renderFollowSnapshotUnavailable(route, message, failure);
    else if (failure.phase === "render") {
      try { renderUnavailable(message, failure); }
      finally { state.detail = null; state.detailConflict = false; }
    }
    else renderUnavailable(message, failure);
  }
  function renderProjectionFailureSafely(error) {
    try { renderProjectionFailure(error); }
    catch (_renderError) {
      try {
        const primaryFailure = normalizeProjectionFailure(error);
        app.dataset.errorPhase = primaryFailure.phase;
        app.dataset.errorKind = "projection_failure_renderer_failed";
        app.textContent = "Projection unavailable. " + projectionFailureMessage(primaryFailure);
        status.textContent = projectionFailureStatus(primaryFailure);
      } catch (_fallbackError) {}
    }
  }
  function renderCurrentGuarded() {
    try { renderCurrent(); }
    catch (error) { renderProjectionFailureSafely(error); }
  }

  function exactObjectKeys(value, required, allowed) {
    if (!value || typeof value !== "object" || Array.isArray(value)) return false;
    const keys = Object.keys(value);
    return required.every(function (name) { return Object.prototype.hasOwnProperty.call(value, name); }) && keys.every(function (name) { return allowed.includes(name); });
  }
  function validScopedEnvelope(envelope, workspace, scope) {
    const envelopeKeys = ["snapshot", "source", "workspace"];
    if (!exactObjectKeys(envelope, envelopeKeys, envelopeKeys) || envelope.workspace !== workspace) return false;
    if (!exactObjectKeys(envelope.source, ["sessions_directory"], ["sessions_directory"]) || !["observed", "absent"].includes(envelope.source.sessions_directory)) return false;
    const snapshot = envelope.snapshot;
    if (scope === "list") {
      const snapshotKeys = ["inventory", "runs", "schema", "schema_version"];
      if (!exactObjectKeys(snapshot, snapshotKeys, snapshotKeys) || snapshot.schema !== "pixir.monitor.runs" || snapshot.schema_version !== 1 || !Array.isArray(snapshot.runs) || !snapshot.runs.every(function (row) { return row && typeof row === "object" && !Array.isArray(row) && typeof row.id === "string" && row.id.length > 0; })) return false;
      const inventoryRequired = ["limitations", "selected", "total", "truncated"];
      const inventoryAllowed = inventoryRequired.concat(["dropped_logs", "non_parent_logs", "projected_runs"]);
      const inventory = snapshot.inventory;
      if (!exactObjectKeys(inventory, inventoryRequired, inventoryAllowed) || !Number.isSafeInteger(inventory.total) || inventory.total < 0 || !Number.isSafeInteger(inventory.selected) || inventory.selected < 0 || typeof inventory.truncated !== "boolean" || !Array.isArray(inventory.limitations) || !inventory.limitations.every(function (item) { return item && typeof item === "object" && !Array.isArray(item); })) return false;
      return ["dropped_logs", "non_parent_logs", "projected_runs"].every(function (name) { return inventory[name] === undefined || Number.isSafeInteger(inventory[name]) && inventory[name] >= 0; });
    }
    const detailKeys = ["counts", "evidence", "execution", "graph", "limitations", "liveness", "mutation", "projected_at", "projection_id", "run", "safe_actions", "schema", "schema_version", "source", "units", "usage"];
    if (!exactObjectKeys(snapshot, detailKeys, detailKeys) || snapshot.schema !== "pixir.presenter.run" || snapshot.schema_version !== 1) return false;
    return typeof snapshot.projection_id === "string" && snapshot.projection_id.length > 0 && typeof snapshot.projected_at === "string" && snapshot.run && typeof snapshot.run === "object" && !Array.isArray(snapshot.run) && typeof snapshot.run.id === "string" && snapshot.run.id.length > 0 && Array.isArray(snapshot.units) && Array.isArray(snapshot.safe_actions) && Array.isArray(snapshot.evidence) && Array.isArray(snapshot.limitations);
  }
  function validateScopedEnvelope(envelope, workspace, scope) {
    if (!validScopedEnvelope(envelope, workspace, scope)) throw projectionFailure("decode", "scoped_envelope_invalid", 200);
    return envelope;
  }

  async function fetchJSON(path, expectedGeneration) {
    try {
      let response;
      try {
        response = await fetch(path, {method: "GET", credentials: "same-origin", cache: "no-store", headers: {accept: "application/json"}});
      } catch (_error) {
        throw projectionFailure("fetch", "projection_request_failed");
      }
      if (!response.ok) {
        let value = null;
        try { value = await response.json(); } catch (_error) {}
        const serverKind = diagnosticToken(value && value.error && value.error.kind, "projection_http_failed");
        const failure = projectionFailure("fetch", serverKind, response.status);
        failure.structured = Boolean(value && value.error && typeof value.error === "object" && !Array.isArray(value.error));
        throw failure;
      }
      let value;
      try {
        value = await response.json();
      } catch (_error) {
        throw projectionFailure("decode", "projection_response_invalid", response.status);
      }
      if (value === null) throw projectionFailure("decode", "projection_response_invalid", response.status);
      if (expectedGeneration !== null && expectedGeneration !== state.generation) return SUPERSEDED;
      return value;
    } catch (error) {
      if (expectedGeneration !== null && expectedGeneration !== state.generation) return SUPERSEDED;
      throw error;
    }
  }
  async function refresh(reason) {
    state.restore = captureView();
    const current = ++state.generation;
    const route = parseRoute(location.hash);
    state.routeRunId = route.runId || null;
    state.routeWorkspace = route.workspace || null;

    if (workspaceSetMode()) {
      if (route.view === "invalid") {
        renderCurrent();
        return;
      }
      if (route.view === "workspaces") {
        await Promise.all(shellConfig.workspaces.map(function (workspace) { return refetchWorkspaceList(workspace, null); }));
        if (current === state.generation) renderWorkspaceOverview();
        return;
      }

      const workspace = route.workspace;
      if (route.view === "runs") {
        await refetchWorkspaceList(workspace, null);
        return;
      }
      try {
        const suffix = "/" + encodeURIComponent(route.runId);
        const fetchedEnvelope = await fetchJSON("/api/workspaces/" + encodeURIComponent(workspace) + "/runs" + suffix, current);
        if (fetchedEnvelope === SUPERSEDED || current !== state.generation) return;
        const envelope = validateScopedEnvelope(fetchedEnvelope, workspace, "detail");
        const receivedAt = new Date().toISOString();
        const snapshot = envelope && envelope.snapshot;
        const detailIdentityConfirmed = Boolean(envelope && envelope.workspace === workspace && snapshot && snapshot.run && snapshot.run.id === route.runId);
        state.detailConflict = !detailIdentityConfirmed;
        state.detail = snapshot || null;
        state.detailId = detailIdentityConfirmed ? route.runId : null;
        state.detailWorkspace = detailIdentityConfirmed ? workspace : null;
        if (detailIdentityConfirmed) {
          workspaceSnapshots[workspace] = Object.assign({}, workspaceSnapshots[workspace] || {}, {detail: snapshot, detailId: route.runId, detailObservedAt: receivedAt, detailError: null});
          state.lastAuthoritativeRefetchAt = new Date();
        }
        let rendered = false;
        try {
          renderCurrent();
          rendered = true;
        } finally {
          if (rendered && route.view !== "runs" && state.detailConflict) { state.detail = null; state.detailWorkspace = null; state.detailConflict = false; }
        }
      } catch (error) {
        if (current !== state.generation) return;
        const failure = normalizeProjectionFailure(error);
        const failureState = {detailError: {kind: failure.kind}};
        workspaceSnapshots[workspace] = Object.assign({}, workspaceSnapshots[workspace] || {}, failureState);
        const currentSnapshot = workspaceSnapshots[workspace] || {};
        if (currentSnapshot.detail && currentSnapshot.detailId === route.runId) { state.detail = currentSnapshot.detail; state.detailId = currentSnapshot.detailId; state.detailWorkspace = workspace; state.detailConflict = false; renderCurrent(); }
        else renderProjectionFailureSafely(failure);
      }
      return;
    }

    let payload = null;
    let detailIdentityConfirmed = true;
    if (route.view === "invalid") {
      renderCurrent();
      return;
    } else if (route.view === "runs") {
      state.detail = null; state.detailId = null; state.detailConflict = false;
      payload = await fetchJSON("/api/runs", current); if (payload === SUPERSEDED || current !== state.generation) return; state.list = payload; state.detail = null; state.detailId = null; state.detailConflict = false;
    } else {
      payload = await fetchJSON("/api/runs/" + encodeURIComponent(route.runId), current); if (payload === SUPERSEDED || current !== state.generation) return; detailIdentityConfirmed = Boolean(payload && payload.run && payload.run.id === route.runId); state.detailConflict = !detailIdentityConfirmed; state.detail = payload; state.detailId = detailIdentityConfirmed ? route.runId : null;
    }
    const identityConfirmed = route.view === "runs" || (payload && payload.run && payload.run.id === route.runId);
    if (identityConfirmed) state.lastAuthoritativeRefetchAt = new Date();
    let rendered = false;
    try {
      renderCurrent();
      rendered = true;
    } finally {
      if (rendered && route.view !== "runs" && !detailIdentityConfirmed) { state.detail = null; state.detailConflict = false; }
    }
    setStatus(status.textContent);
    if (reason && !app.querySelector(".error-view[data-follow-state]")) announce("Projection refetched after " + reason + ".");
  }
  /**
   * Coalesces authoritative refetches into a single in-flight request. A reason
   * arriving mid-flight is remembered and replayed once, so bursts of
   * invalidations, navigations, and retries collapse without dropping the last
   * cause. Browser state is disposable; the refetch is always authoritative.
   * @param {string} reason Cause announced to assistive tech after the refetch.
   * @returns {Promise} The shared in-flight request.
   */
  function refreshSingleFlight(reason) {
    state.refreshPendingReason = reason;
    if (state.refreshInFlight) return state.refreshInFlight;
    const currentReason = state.refreshPendingReason;
    state.refreshPendingReason = null;
    const request = refresh(currentReason).catch(renderProjectionFailureSafely).finally(function () {
      if (state.refreshInFlight === request) state.refreshInFlight = null;
      if (state.refreshPendingReason !== null) refreshSingleFlight(state.refreshPendingReason);
    });
    state.refreshInFlight = request;
    return request;
  }
  /**
   * Validates one stream event against the bounded invalidation contract: a
   * non-negative integer sequence id and a body of exactly
   * {type: "projection_changed", projection_id}. Invalidations are metadata
   * hints only — they never carry snapshots and never mutate view state; any
   * anomaly still resolves to an authoritative refetch.
   * @param {MessageEvent} event Server-sent invalidation event.
   * @returns {{valid: boolean, sequence: (number|null)}}
   */
  function validInvalidation(event) {
    if (!/^[0-9]+$/.test(event.lastEventId || "")) return {valid: false, sequence: null};
    const sequence = Number(event.lastEventId); if (!Number.isSafeInteger(sequence) || sequence < 0) return {valid: false, sequence: null};
    try {
      const body = JSON.parse(event.data);
      const expectedKeys = workspaceSetMode() ? "projection_id,type,workspace" : "projection_id,type";
      const workspaceValid = !workspaceSetMode() || (body && typeof body.workspace === "string" && shellConfig.workspaces.includes(body.workspace));
      if (!body || Array.isArray(body) || body.type !== "projection_changed" || typeof body.projection_id !== "string" || !body.projection_id || !workspaceValid || Object.keys(body).sort().join(",") !== expectedKeys) return {valid: false, sequence: sequence, workspace: null};
      return {valid: true, sequence: sequence, workspace: workspaceSetMode() ? body.workspace : null};
    } catch (_error) { return {valid: false, sequence: sequence}; }
  }
  function refetchWorkspaceList(workspace, reason) {
    const requestGeneration = (state.sourceRequestGeneration[workspace] || 0) + 1;
    let latestFailure = null;
    state.sourceRequestGeneration[workspace] = requestGeneration;
    // Workspace snapshot authority is source-scoped, not route-scoped. Passing
    // null keeps global navigation generations from superseding this request;
    // requestGeneration remains the sole commit arbiter for this workspace.
    return fetchJSON("/api/workspaces/" + encodeURIComponent(workspace) + "/runs", null).then(function (fetchedEnvelope) {
      // Per-source latest-result-wins arbitration: stale completions are discarded silently.
      if (fetchedEnvelope === SUPERSEDED || state.sourceRequestGeneration[workspace] !== requestGeneration) return;
      const envelope = validateScopedEnvelope(fetchedEnvelope, workspace, "list");
      workspaceSnapshots[workspace] = Object.assign({}, workspaceSnapshots[workspace] || {}, {list: envelope, listObservedAt: new Date().toISOString(), listError: null});
      state.lastAuthoritativeRefetchAt = new Date();
    }).catch(function (error) {
      if (state.sourceRequestGeneration[workspace] !== requestGeneration) return;
      const failure = normalizeProjectionFailure(error);
      latestFailure = failure;
      workspaceSnapshots[workspace] = Object.assign({}, workspaceSnapshots[workspace] || {}, {listError: {kind: failure.kind}});
    }).finally(function () {
      if (state.sourceRequestGeneration[workspace] !== requestGeneration) return;
      const route = parseRoute(location.hash);
      if (route.view === "workspaces") renderWorkspaceOverview();
      else if (route.view === "runs" && route.workspace === workspace) {
        const currentSnapshot = workspaceSnapshots[workspace] || {};
        if (currentSnapshot.list) {
          state.list = currentSnapshot.list.snapshot;
          renderCurrentGuarded();
        } else if (currentSnapshot.listError && latestFailure) renderProjectionFailureSafely(latestFailure);
      }
      if (reason) announce("Workspace source refetched after " + reason + ".");
    });
  }
  function handleInvalidation(event) {
    const parsed = validInvalidation(event); let reason = "valid invalidation";
    if (!parsed.valid) reason = "malformed invalidation";
    else if (state.lastEventId !== null && parsed.sequence === state.lastEventId) reason = "duplicate invalidation";
    else if (state.lastEventId !== null && parsed.sequence < state.lastEventId) reason = "reordered invalidation";
    else if (state.lastEventId !== null && parsed.sequence !== state.lastEventId + 1) reason = "invalidation gap";
    const anomaly = reason !== "valid invalidation";
    // Invalid payloads are still refetch triggers, but their numeric ids are
    // not trusted as the cursor for later valid invalidations.
    if (parsed.valid && parsed.sequence !== null) state.lastEventId = state.lastEventId === null ? parsed.sequence : Math.max(state.lastEventId, parsed.sequence);
    if (!workspaceSetMode()) refreshSingleFlight(reason);
    else if (anomaly) {
      const route = parseRoute(location.hash);
      Promise.all(shellConfig.workspaces.map(function (workspace) { return refetchWorkspaceList(workspace, reason); })).then(function () {
        if (route.workspace && route.view !== "workspaces" && route.view !== "runs") refreshSingleFlight(reason + " deep-view revalidation");
      });
    }
    else {
      const route = parseRoute(location.hash);
      const listRefresh = refetchWorkspaceList(parsed.workspace, reason);
      if (route.workspace === parsed.workspace && route.view !== "workspaces" && route.view !== "runs") {
        listRefresh.then(function () { refreshSingleFlight(reason + " detail revalidation"); });
      }
    }
  }
  function connect() {
    const source = new EventSource("/api/events", {withCredentials: true});
    source.addEventListener("projection_changed", handleInvalidation);
    source.onopen = function () { const reconnecting = state.streamState === "down"; if (reconnecting) state.lastEventId = null; state.streamState = "connected"; setStatus(status.textContent); if (reconnecting) refreshSingleFlight("stream reconnect"); };
    source.onerror = function () { const alreadyDown = state.streamState === "down"; state.streamState = "down"; setStatus(status.textContent); if (!alreadyDown) refreshSingleFlight("stream error"); };
  }
  function routeChanged() {
    state.generation += 1;
    if (state.refreshInFlight) state.refreshPendingReason = "navigation";
    const savedRestore = history.state && history.state.pixirView ? history.state.pixirView : captureView(state.routeRunId, state.routeWorkspace);
    const route = parseRoute(location.hash);
    const nextRouteRunId = route.runId || null;
    const nextRouteWorkspace = route.workspace || null;
    const runChanged = state.routeRunId !== nextRouteRunId || state.routeWorkspace !== nextRouteWorkspace;
    state.routeRunId = nextRouteRunId;
    state.routeWorkspace = nextRouteWorkspace;
    state.restore = savedRestore && savedRestore.runId === nextRouteRunId && (savedRestore.workspace || null) === nextRouteWorkspace ? savedRestore : null;
    const forceRefetch = state.forceRefetch;
    state.forceRefetch = false;
    if (runChanged) {
      state.list = null;
      state.detail = null;
      state.detailId = null;
      state.detailWorkspace = null;
      state.detailConflict = false;
      state.pendingAttemptScroll = null;
      delete app.dataset.errorPhase;
      delete app.dataset.errorKind;
      app.replaceChildren();
      setStatus("Awaiting authoritative projection…");
    }
    if (route.view === "invalid") renderCurrentGuarded();
    else if (route.view === "workspaces") {
      state.detail = null; state.detailId = null; state.detailConflict = false;
      if (shellConfig.workspaces.every(function (workspace) { return workspaceSnapshots[workspace] && (workspaceSnapshots[workspace].list || workspaceSnapshots[workspace].listError); })) {
        renderCurrentGuarded();
        if (runChanged) refreshSingleFlight("navigation");
      }
      else refreshSingleFlight("navigation");
    }
    else if (route.view === "runs") {
      state.detail = null; state.detailId = null; state.detailConflict = false;
      const routedList = workspaceSetMode() && workspaceSnapshots[route.workspace] && workspaceSnapshots[route.workspace].list;
      if (workspaceSetMode()) state.list = routedList ? routedList.snapshot : null;
      if (forceRefetch) refreshSingleFlight("follow retry");
      else if (state.list) renderCurrentGuarded();
      else refreshSingleFlight("navigation");
    }
    else {
      const matchingDetail = route.runId && state.detail && state.detailId === route.runId && (!workspaceSetMode() || state.detailWorkspace === route.workspace) && state.detail.run && state.detail.run.id === route.runId;
      const staleRoute = route.runId && (state.detailId && route.runId !== state.detailId || workspaceSetMode() && state.detailWorkspace && route.workspace !== state.detailWorkspace);
      const staleDetail = staleRoute || (route.runId && state.detail && !matchingDetail);
      const staleFollowView = route.runId && app.querySelector(".error-view[data-follow-state]") && (!matchingDetail || runChanged);
      const preserveSameRunFollowIdentity = route.follow === true && !runChanged && !state.detail && state.detailId === route.runId;
      if (staleDetail || staleFollowView) {
        // A route change must not leave the prior run painted while the new
        // authoritative request is in flight. The empty render is neutral;
        // only a matching authoritative payload can restore the detail view.
        state.detail = null;
        state.detailWorkspace = null;
        state.detailConflict = false;
        state.detailId = preserveSameRunFollowIdentity ? route.runId : null;
        delete app.dataset.errorPhase;
        delete app.dataset.errorKind;
        app.replaceChildren();
        setStatus("Awaiting authoritative projection…");
      }
      if (forceRefetch) refreshSingleFlight("follow retry");
      else if (matchingDetail) renderCurrentGuarded();
      else refreshSingleFlight("navigation");
    }
  }
  window.addEventListener("hashchange", routeChanged);
  document.addEventListener("click", function (event) {
    const anchor = event.target && event.target.closest ? event.target.closest("a") : null;
    if (anchor && anchor.getAttribute("href") && anchor.getAttribute("href").startsWith("#")) history.replaceState({pixirView: captureView()}, "", location.href);
  });
  window.addEventListener("pagehide", function () { history.replaceState({pixirView: captureView()}, "", location.href); });

  window.PixirMonitorUI = Object.freeze({parseRoute: parseRoute, routeHash: routeHash, clientStateKey: clientStateKey, visible: visible, classifyCommand: classifyCommand, escapedEvidence: escapedEvidence, validInvalidation: validInvalidation, limits: LIMITS, sortVocabulary: SORT_VOCABULARY, defaultSort: DEFAULT_SORT, runsComparator: runsComparator, temporalField: temporalField, durationLabel: durationLabel, attentionRenderAllCap: ATTENTION_RENDER_ALL_CAP, attentionRowBudget: attentionRowBudget});
  // Pre-load failure UX belongs solely to the shell bootstrap (PixirMonitor.Bootstrap):
  // this script loads only after the bootstrap promise fulfills, so rejection is unreachable here.
  window.__pixirBootstrap.then(function () {
    if (shellConfigError) {
      state.streamState = "down";
      app.textContent = "Workspace Overview could not start: malformed shell configuration.";
      setStatus("Workspace Overview boot error · relaunch required");
      return;
    }
    if (!location.hash || location.hash === "#") history.replaceState(null, "", workspaceSetMode() ? "#/workspaces" : "#/runs");
    refreshSingleFlight("initial load");
    connect();
  }).catch(function () {
    // Only a synchronous throw in the continuation above can land here; bootstrap
    // rejection cannot (see the ownership comment on the attachment). Report the
    // failure honestly instead of attributing it to launch expiry.
    state.streamState = "down";
    setStatus("Monitor initialization failed. Reload the page, or run pixir-monitor serve again for a fresh session.");
  });
}());
