defmodule PixirMonitor.UIContractTest do
  use ExUnit.Case, async: true

  @js Path.expand("../../priv/static/app.js", __DIR__)
  @css Path.expand("../../priv/static/app.css", __DIR__)
  @fixture_root Path.expand("../../priv/presenter/fixtures", __DIR__)

  setup_all do
    {:ok, js: File.read!(@js), css: File.read!(@css)}
  end

  test "all thirteen golden projections have a deterministic Runs row and group" do
    manifest = Jason.decode!(File.read!(Path.join(@fixture_root, "manifest.json")))
    assert length(manifest["scenarios"]) == 13

    rows =
      Enum.map(manifest["scenarios"], fn %{"id" => id} ->
        projection = Jason.decode!(File.read!(Path.join([@fixture_root, "golden", id <> ".json"])))
        assert projection["schema"] == "pixir.presenter.run"
        assert projection["schema_version"] == 1
        assert is_binary(projection["run"]["id"])
        assert is_boolean(projection["execution"]["terminal"])
        assert is_integer(projection["counts"]["attention_units"])
        assert projection["source"]["mode"] in ["live", "mixed", "reconstructed"]

        %{
          id: projection["run"]["id"],
          title: projection["run"]["title"],
          strategy: projection["run"]["strategy"],
          execution: projection["execution"]["state"],
          liveness: projection["liveness"]["state"],
          source: projection["source"]["mode"],
          group: group(projection)
        }
      end)

    assert Enum.count(rows, &(&1.group == "Needs attention")) == 10
    assert Enum.count(rows, &(&1.group == "Recent")) == 3
    assert Enum.any?(rows, &(&1.group == "Recent" and &1.strategy == "workflow"))
  end

  test "F4 Workflow and Unit flows keep execution, gate, advisory, attempts, and usage separate", %{js: js} do
    f4 = golden("f4-advisory-retry-reconstructed")
    review = Enum.find(f4["units"], &(&1["label"] == "review"))

    assert review["execution"]["state"] == "completed"
    assert review["gate"]["state"] == "checkpoint_ready"
    assert review["advisory"]["declared_gate"] == "partial"
    assert review["advisory"]["verdict"] == "stop"
    assert Enum.map(review["attempts"], & &1["ordinal"]) == [0, 1]
    assert Enum.map(review["attempts"], & &1["child_session_id"]) == ["child-f4-a", "child-f4-b"]
    assert review["usage"]["calls"] == 2

    # Six per the frozen #363/#336 contract: execution, liveness, gate, advisory,
    # run-scoped source, attention. The rail renders exactly six cards.
    assert js =~ "Six independent truth dimensions"
    assert js =~ "Advisory does not control the runtime gate."
    assert js =~ "attempt.ordinal + 1"
    assert js =~ "\"Provisional\""
    assert js =~ "Attempt activity via evidence references"
    assert js =~ "Evidence-derived usage"
  end

  test "fan-out is a parent/sibling tree and never derives dependency edges", %{js: js} do
    assert js =~ "Parent and sibling fan-out"
    assert js =~ "No dependency edges are inferred for fan-out runs."
    assert js =~ "if (run.run.strategy === \"workflow\") {"
    # Semantic zoom (#336/#348) bounds inside workflowGraph; the dispatch passes
    # the full run and the cluster contract owns the bounds.
    assert js =~ "root.append(workflowGraph(run, route));"
    assert js =~ "root.append(fanoutTree(run, route));"
    # Fan-out receives the full observed inventory (honest counts per #338/#364);
    # DOM stays bounded per group by FANOUT_GROUP_MEMBER_PAGE_SIZE, not by unit paging.
    refute js =~ "fanoutTree(boundedRun"
  end

  test "run titles and unit labels use visible-control text sinks", %{js: js} do
    assert js =~ "function untrustedText(tag, value, className)"
    assert js =~ "const shown = visible(value)"
    # Row links build through routeHash, which scopes to the routed workspace
    # in set mode and stays #/runs/<id> in single mode.
    assert js =~ ~s|nameCell.append(projectedLink(name, routeHash({runId: row.id|
    assert js =~ "titleRow.append(projectedHeading(1, scalar(run.run.title, run.run.id)))"

    assert js =~
             ~s|header.append(projectedLink(unit.label, semanticZoomRoute(route, {runId: run.run.id, unitId: unit.logical_id})|

    assert js =~ "unitTitle.append(projectedHeading(1, unit.label))"
    assert js =~ ~s|root.append(projectedLink("← " + scalar(run.run.title, run.run.id)|
    refute js =~ "root.append(heading(1, scalar(run.run.title, run.run.id)))"
    refute js =~ "root.append(heading(1, unit.label))"
  end

  test "renderer uses text sinks, bounded pages and visibly marks control evidence", %{js: js, css: css} do
    refute js =~ "inner" <> "HTML"
    refute js =~ "insertAdjacent" <> "HTML"
    refute js =~ "DOMParser"
    refute js =~ "document.write"
    assert js =~ "node.textContent ="
    assert js =~ "replaceChildren"
    assert js =~ "Object.create(null)"
    assert js =~ "runs: 50, units: 100, attempts: 20, evidence: 100, field: 32768"
    assert js =~ "⟦ESC⟧"
    assert js =~ "⟦C0 U+"
    assert js =~ "⟦U+"
    assert css =~ "unicode-bidi: plaintext"
    assert css =~ ".truncation"
  end

  test "hostile model strings and URL-shaped strings have no executable rendering surface", %{js: js} do
    vectors = [
      "<script>alert(1)</script>",
      "<img src=x onerror=alert(1)>",
      "<svg onload=alert(1)>",
      "javascript:alert(1)",
      "data:text/html,boom",
      "file:///etc/passwd",
      "//evil.test/path",
      "https://user:pass@evil.test/"
    ]

    assert Enum.all?(vectors, &is_binary/1)
    assert js =~ "projected-text"
    refute js =~ "createElement(\"a\")"
    refute js =~ "linkify"
    refute js =~ "markdown"
    refute js =~ "location.href ="
  end

  test "clipboard rules require explicit copy, review, and escaped-only evidence", %{js: js} do
    assert js =~ "action.presentation !== \"copy_only\""
    assert js =~ "action.effect === \"mutating\""
    assert js =~ "hasReviewCodepoint(command)"
    assert js =~ "hasDangerousShell(command)"
    assert js =~ "Copy safely escaped evidence"
    refute js =~ "Review raw copy"
    refute js =~ "Confirm raw bytes copy"
    refute js =~ "Raw command bytes"
    refute js =~ "raw bytes copied"
    assert js =~ ~s|navigator.clipboard.writeText(escapedEvidence(scalar(value, "")))|
    refute js =~ "navigator.clipboard.writeText(value)"
    assert js =~ "Clipboard permission denied. Nothing was copied."
    refute js =~ "exec" <> "Command"
  end

  test "SSE remains non-normative and every anomaly causes authoritative refetch", %{js: js} do
    for reason <- [
          "valid invalidation",
          "malformed invalidation",
          "duplicate invalidation",
          "reordered invalidation",
          "invalidation gap",
          "stream error",
          "stream reconnect"
        ] do
      assert js =~ reason
    end

    assert js =~ "expectedGeneration !== state.generation"
    refute js =~ "fetch(\"/api/events\")"
    assert js =~ "new EventSource(\"/api/events\", {withCredentials: true})"
    assert js =~ "cache: \"no-store\""
    assert js =~ "refresh(reason)"
  end

  test "keyboard, focus, viewport, disclosures, live region, and provenance are explicit", %{js: js, css: css} do
    assert js =~ "data-focus-key"
    assert js =~ "captureView()"
    assert js =~ "window.scrollTo"
    assert js =~ "data-disclosure-key"
    assert js =~ "setAttribute(\"aria-live\", \"polite\")"
    assert js =~ ".dataset.provenance"
    assert js =~ ".dataset.authority"
    assert css =~ ":focus-visible"
    assert css =~ ".sr-only"
  end

  test "bundle has same-origin read-only transport and no remote or mutation request surface", %{js: js, css: css} do
    assert js =~ "method: \"GET\""
    assert js =~ "credentials: \"same-origin\""
    refute js =~ ~r/fetch\([^\n]*method:\s*"(?:POST|PUT|PATCH|DELETE)"/
    refute js =~ ~r{https?://}
    refute css =~ ~r{https?://}
    refute js =~ "serviceWorker"
    refute js =~ "WebSocket("
    refute js =~ "telemetry"
    refute js =~ "file:"
  end

  test "v1.1 repair contracts preserve parent-only grouping and safe read-only interactions", %{js: js, css: css} do
    assert js =~ "Attention observed: "
    assert js =~ "parent Log only"
    assert js =~ "FILTER_VOCABULARIES"
    assert js =~ "execution: [\"planned\", \"queued\""
    refute js =~ "const values = name === \"attention\""
    assert js =~ "allOption.value = \"\""
    assert js =~ "FILTER_VOCABULARIES[name].includes(value)"
    assert js =~ "const rows = grouped[group].slice(0, budget)"
    assert js =~ "runs:" <> "\" + group.toLowerCase()"
    assert js =~ "Gate\", \"Advisory"
    assert js =~ "runTable(rows, grouped[group].length, group, matches, groupFocusKey)"
    assert js =~ "labeledMarker(count + \" \""
    assert js =~ "residual + \" unrecognized\""
    assert js =~ "MARKER_TONES.has(tone) ? tone : \"unknown\""
    assert js =~ "[\"stop\", \"needs_review\", \"pass\", \"unknown\", \"invalid\"]"
    assert js =~ "marker(unit.liveness && unit.liveness.state"
    assert js =~ "predecessor_attempt_id"
    assert js =~ "state.pendingAttemptScroll = predecessor.attempt_id"
    assert js =~ "target.scrollIntoView({behavior: \"smooth\", block: \"nearest\"})"
    assert js =~ "selectedAttemptPage"
    assert js =~ "Order: chronological (oldest first)"
    assert js =~ "usage:attempt:"
    assert js =~ "run-overview:"
    # Dependency copy moved per the semantic-zoom contract: unit inspector field
    # plus exact-edge ledger rows carrying every edge state.
    assert js =~ "\"Depends on\""
    assert js =~ ~s|scalar(edge.from, "Unknown") + " → " + scalar(edge.to, "Unknown") + " — " + titleCase(edge.state)|
    assert js =~ "copyProjectedValue"
    assert js =~ "hasReviewCodepoint(raw)"
    assert js =~ "Review \" + label + \" before copying"
    assert js =~ "hints only"
    assert js =~ "streamState: \"connecting\""
    refute js =~ "authoritative refetch in progress"
    assert css =~ ".sse-health"
    assert css =~ ".attention-reasons"
    assert js =~ "const scroll = el(\"div\", \"table-scroll\")"
    assert css =~ ".runs-table { min-width: 72rem; }"
    assert css =~ ".runs-table th:first-child, .runs-table td:first-child { min-width: 14rem; }"
    refute js =~ "inner" <> "HTML"
  end

  test "list activity honesty: filters and groups match list-scope liveness", %{js: js} do
    # Regression pin for #346: list rows emit only "unobserved" for
    # nonterminal runs and "not_applicable" for terminal runs. Filters and
    # rendered groups must not offer states or sections that list data cannot
    # reach.
    assert js =~ ~s|liveness: ["unobserved", "not_applicable"]|
    assert js =~ ~s|["Needs attention", "Recent"].forEach(function (group)|
    refute js =~ ~s|["Needs attention", "Active", "Recent"]|
    refute js =~ ~s|return "Active"|
    assert js =~ "Activity evidence unavailable at list scope (parent Log only). Detail may load owner diagnostics."
    assert js =~ "Terminal per parent Log; liveness does not apply."
    assert js =~ "Owner handle is stale; last observed evidence no longer confirms activity."
    assert js =~ "row and detail liveness can legitimately differ"
    assert js =~ "livenessCellNote(row.liveness && row.liveness.state)"
    assert js =~ ~s|marker(row.liveness && row.liveness.state, "liveness", row.liveness && row.liveness.basis)|
    # No liveness synthesis from clocks, SSE stream state, or timestamps. The
    # browser clock has exactly one use: relativeLabel's display-only "≈ ago"
    # convenience for complete boundaries, which never touches liveness.
    assert length(String.split(js, "Date.now")) == 2
    {relative_label_at, _} = :binary.match(js, "function relativeLabel")
    {date_now_at, _} = :binary.match(js, "Date.now")
    assert date_now_at > relative_label_at
    refute js =~ ~r/liveness[^\n]*Date\.now/
    refute js =~ ~r/Date\.now[^\n]*liveness/
    refute js =~ ~r/liveness[^\n]*streamState/
    refute js =~ ~r/streamState[^\n]*liveness/
  end

  test "temporal ordering: sort vocabulary lives in the hash route and composes with filters, groups, and pagination", %{js: js} do
    assert js =~ ~s|const SORT_VOCABULARY = Object.freeze(["recency_desc", "recency_asc", "duration_desc", "duration_asc"]);|
    assert js =~ ~s|const DEFAULT_SORT = "recency_desc";|
    assert js =~ "const sort = SORT_VOCABULARY.includes(requestedSort) ? requestedSort : DEFAULT_SORT;"
    assert js =~ ~s|params.set("sort", route.sort)|
    assert js =~ "const sorted = filtered.slice().sort(runsComparator(route.sort || DEFAULT_SORT));"
    assert js =~ "const searched = sorted.filter"
    assert js =~ ~s|routeHash({view: "runs", filters: route.filters, sort: route.sort, q: route.q})|
    assert js =~ ~s|routeHash({view: "runs", filters: next, sort: route.sort, q: route.q})|
    assert js =~ "sortVocabulary: SORT_VOCABULARY"
  end

  test "temporal ordering: pinned total order places incomplete, unknown, and malformed after complete with id ties", %{js: js} do
    assert js =~ "const COMPLETENESS_RANK = Object.freeze({complete: 0, incomplete: 1, unknown: 2, malformed: 3});"
    assert js =~ "incomplete, then unknown, then malformed; exact ties break by ascending run id."
    assert js =~ "return leftId < rightId ? -1 : leftId > rightId ? 1 : 0;"
    assert js =~ ~s|sort === "recency_asc" ? instant : -instant|
    assert js =~ ~s|sort === "duration_asc" ? ms : -ms|
  end

  test "temporal ordering: durations are visually distinct and no boundary is manufactured from clocks or liveness", %{js: js, css: css} do
    assert js =~ ~s|"duration duration-completeness-" + scalar(duration.completeness, "unknown")|
    assert js =~ ~s|return "Incomplete · no end boundary";|
    assert js =~ ~s|return "Malformed timestamp";|

    for completeness <- ~w(complete incomplete unknown malformed) do
      assert css =~ ".duration-completeness-#{completeness}"
    end

    # Relative labels are display conveniences: the projected absolute value stays
    # rendered, and a non-complete boundary never gains a browser-clock value.
    assert js =~ ~s|untrustedText("span", scalar(latest.value, "Unknown"), "absolute-ts")|
    assert js =~ ~s|if (boundary.completeness !== "complete") return null;|
    assert css =~ ".relative-label"
  end

  test "runs search is hash-routed, composes with filters, and confesses its searched domain", %{js: js} do
    # Labeled control and hash-routed query (survives refresh/back/forward).
    assert js =~ ~s|form.setAttribute("aria-label", "Run search")|
    assert js =~ ~s|text("label", "Search runs")|
    assert js =~ ~s|const rawQuery = params.get("q")|
    assert js =~ ~s|params.set("q", Array.from(String(route.q)).slice(0, LIMITS.query).join(""))|
    assert js =~ "field: 32768, query: 256"

    # Composition: filters first, then search, then grouping and per-group pages.
    assert js =~ "const match = searchMatch(row, route.q)"
    assert js =~ ~s|grouped[group] = searched.filter(function (row) { return groupFor(row) === group; })|
    assert js =~ ~s|routeHash({view: "runs", filters: route.filters, sort: route.sort, q: route.q})|
    assert js =~ ~s|location.hash = routeHash({view: "runs", filters: next, sort: route.sort, q: route.q})|

    # Exact parent-observed child Session id resolution; no child Log scan, no index.
    assert js =~ ~s|scalar(candidate.session_id, "") === query|
    {child_find, _} = :binary.match(js, ~s|const child = array(row.children).find|)
    {run_substring, _} = :binary.match(js, ~s{scalar(row.id, "").toLowerCase().includes(needle) || scalar(row.title, "").toLowerCase().includes(needle)})
    assert child_find < run_substring
    assert js =~ "Matched via parent-observed child Session "
    assert js =~ "owning logical unit not identified in parent evidence"
    assert js =~ "child Logs are never scanned and no index is persisted"

    # Searched-domain honesty: selected rows, total projected rows, truncation status.
    assert js =~ ~s| matched " + searched.length + " of " + filtered.length + " filter-selected rows. " + scanned|
    assert js =~ "No runs match this search in the selected inventory. Query "
    assert js =~ ~s| was compared against " + filtered.length + " filter-selected of " + all.length + " projected run rows. " + scanned + |
    assert js =~ "no match here is not evidence of absence"

    # Hostile query text stays literal through visible-control text sinks.
    assert js =~ ~s|untrustedText("span", "Search “" + activeQuery + "”")|
    assert js =~ ~s|untrustedText("span", "“" + activeQuery + "”")|
    refute js =~ "inner" <> "HTML"
  end

  defp golden(id) do
    [@fixture_root, "golden", id <> ".json"]
    |> Path.join()
    |> File.read!()
    |> Jason.decode!()
  end

  defp group(projection) do
    if projection["counts"]["attention_units"] > 0, do: "Needs attention", else: "Recent"
  end

  test "recency sorting preserves sub-millisecond timestamp order before run ids", %{js: js} do
    assert js =~ ~S{return utcSecond + "." + (match[1] || "").padEnd(9, "0").slice(0, 9) + "Z";}

    assert js =~
             ~S|return {rank: 0, value: sort === "recency_asc" ? instant : -instant, normalized: normalizedInstant(latest.value, instant)};|

    assert js =~ ~S|if (left.normalized !== right.normalized) {|
    assert js =~ ~S|if (sort === "recency_desc") return left.normalized > right.normalized ? -1 : 1;|
    assert js =~ ~S|return left.normalized < right.normalized ? -1 : 1;|
  end
end
