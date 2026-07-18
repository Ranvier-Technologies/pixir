Code.require_file("support/semantic_zoom_fixture.ex", __DIR__)

defmodule PixirMonitor.SemanticZoomContractTest do
  use ExUnit.Case, async: true

  alias PixirMonitor.SemanticZoomFixture

  @app_path Path.expand("../priv/static/app.js", __DIR__)
  # Test-only golden: lives under test/fixtures, never in priv/ (priv ships
  # with the escript and priv/presenter/** is preserved byte-exact).
  @golden_path Path.expand("fixtures/semantic-zoom-100.golden.json", __DIR__)

  setup_all do
    app = File.read!(@app_path)
    golden = @golden_path |> File.read!() |> Jason.decode!()
    assert {:ok, projection} = PixirMonitor.Projection.project(SemanticZoomFixture.input())
    {:ok, app: app, golden: golden, projection: projection}
  end

  test "the seeded parent-log fixture projects through the real v1 projector", %{golden: golden, projection: projection} do
    assert projection["schema"] == "pixir.presenter.run"
    assert projection["schema_version"] == 1
    assert projection["run"]["strategy"] == "workflow"
    assert length(projection["units"]) == 100
    assert Enum.map(projection["graph"]["waves"], &length/1) == golden["wave_sizes"]

    assert Enum.any?(projection["graph"]["edges"], fn edge ->
             wave_index(projection["graph"]["waves"], edge["to"]) -
               wave_index(projection["graph"]["waves"], edge["from"]) > 1
           end)
  end

  test "golden entities partition every projected id exactly once with no phantoms", %{golden: golden, projection: projection} do
    window = materialize_window(golden, projection)
    projected_ids = projection["graph"]["waves"] |> List.flatten() |> MapSet.new()
    members = Enum.flat_map(window.entities, & &1.members)

    assert MapSet.new(members) == projected_ids
    assert length(members) == MapSet.size(projected_ids)
    assert Enum.all?(members, &MapSet.member?(projected_ids, &1))
  end

  test "golden arc endpoints exist and level-zero ledgers equal graph edges exactly", %{golden: golden, projection: projection} do
    window = materialize_window(golden, projection)
    entity_keys = MapSet.new(window.entities, & &1.key)

    assert Enum.all?(window.arcs, fn arc ->
             MapSet.member?(entity_keys, arc.from) and MapSet.member?(entity_keys, arc.to)
           end)

    assert Enum.all?(window.arcs, fn arc -> length(arc.edges) == arc.expected_count end)
    assert exact_edge_union?(window.arcs, projection["graph"]["edges"])
  end

  test "discoverability proof self-test goes red when one golden ledger edge is dropped", %{golden: golden, projection: projection} do
    window = materialize_window(golden, projection)
    [first | rest] = window.arcs
    [_dropped | remaining_edges] = first.edges
    corrupted = [%{first | edges: remaining_edges} | rest]

    refute exact_edge_union?(corrupted, projection["graph"]["edges"])
  end

  test "freezes cluster key grammar, slot allocation, and remainder chunking", %{app: app, golden: golden} do
    assert app =~ "const SEMANTIC_ZOOM_MAX_CLUSTERS = 6;"
    assert app =~ "const SEMANTIC_ZOOM_CLUSTER_KEY = /^wave:\\d+:bucket:\\d+$/;"
    assert app =~ "units * buckets[candidate] > array(waves[candidate]).length * buckets[index]"
    assert app =~ "const quotient = Math.floor(ids.length / bucketCount);"
    assert app =~ "const remainder = ids.length % bucketCount;"

    assert Enum.map(hd(golden["windows"])["entities"], &{&1["key"], &1["size"]}) == [
             {"wave:0:bucket:0", 15},
             {"wave:0:bucket:1", 15},
             {"wave:1:bucket:0", 20},
             {"wave:1:bucket:1", 20},
             {"wave:2:bucket:0", 20},
             {"wave:3:bucket:0", 10}
           ]
  end

  test "cluster advisory distribution excludes absent advisories and exposes invalid parsing", %{app: app} do
    units = [
      %{"present" => false, "verdict" => "unknown", "parse_status" => "not_present"},
      %{"present" => true, "verdict" => "pass", "parse_status" => "valid"},
      %{"present" => true, "verdict" => "pass", "parse_status" => "invalid"},
      %{"present" => true, "verdict" => "stop", "parse_status" => "valid"}
    ]

    assert advisory_distribution(units) == %{"invalid" => 1, "pass" => 1, "stop" => 1}
    refute Map.has_key?(advisory_distribution(units), "unknown")
    assert app =~ "unit.advisory.present === true ? (unit.advisory.parse_status === \"invalid\" ? \"invalid\" : unit.advisory.verdict) : null"
  end

  test "aggregate arcs and exact ledgers retain contract identities and page bounds", %{app: app, golden: golden} do
    assert app =~ "const keyName = fromKey + \"=>\" + toKey;"
    assert app =~ "counts: {ready: 0, blocked: 0, unknown: 0}"
    assert app =~ "Aggregate arc "
    assert app =~ "the selected overview arc is only an aggregate"
    assert golden["edge_page_size"] == 100
    assert app =~ "const SEMANTIC_ZOOM_EDGE_PAGE_SIZE = 100;"
    assert app =~ "selectedArc.edges.slice(0, route.edgePage * SEMANTIC_ZOOM_EDGE_PAGE_SIZE)"
    refute app =~ "Accessible dependency list ("
  end

  test "all five zoom fields survive follow, retry, unit, attempt, predecessor, and back links", %{app: app} do
    assert app =~ "semanticZoomRoute(route, {follow: false})"
    assert app =~ "semanticZoomRoute(route, {follow: true})"
    assert app =~ "semanticZoomRoute(currentRoute, {follow: true})"
    assert app =~ "semanticZoomRoute(route, {runId: run.run.id, unitId: unit.logical_id})"
    assert app =~ "semanticZoomRoute(activeRoute, {attemptId: attempt.attempt_id})"
    assert app =~ "semanticZoomRoute(activeRoute, {attemptId: predecessor.attempt_id})"
    assert app =~ "semanticZoomRoute(route, {unitId: null, attemptId: null})"
    for field <- ["zoomStart", "selectedCluster", "selectedArc", "memberPage", "edgePage"], do: assert(app =~ field)
  end

  test "route pages are clamped and stale selections are removed from the canonical hash", %{app: app} do
    assert min(max(1, 999_999), ceil_page(20, 12)) == 2
    refute "wave:99:bucket:0" in ["wave:0:bucket:0"]
    refute "foreign=>arc" in ["wave:0:bucket:0=>wave:1:bucket:0"]
    assert app =~ "Math.ceil(selectedEntityCandidate.members.length / SEMANTIC_ZOOM_MEMBER_PAGE_SIZE)"
    assert app =~ "Math.ceil(selectedArcCandidate.edges.length / SEMANTIC_ZOOM_EDGE_PAGE_SIZE)"
    assert app =~ "Math.min(Math.max(1, route.memberPage), maximumMemberPage)"
    assert app =~ "Math.min(Math.max(1, route.edgePage), maximumEdgePage)"
    assert app =~ "selectedCluster: selectedEntityCandidate ? selectedEntityCandidate.key : null"
    assert app =~ "selectedArc: selectedArcCandidate ? selectedArcCandidate.key : null"
    assert app =~ "history.replaceState(null, \"\", canonicalZoomHash)"
  end

  test "empty waves emit no bucket and malformed edges are confessed or rejected", %{app: app, projection: projection} do
    malformed_waves = [["unit-a"], [], ["unit-b"]]
    assert malformed_waves |> Enum.with_index() |> Enum.reject(fn {wave, _index} -> wave == [] end) |> Enum.map(&elem(&1, 1)) == [0, 2]

    assignment = %{"unit-a" => "wave:0:bucket:0", "unit-b" => "wave:2:bucket:0"}
    malformed_edges = [%{"from" => "missing", "to" => "unit-b", "state" => "ready"}, %{"from" => "unit-a", "to" => "unit-b", "state" => "surprise"}]
    assert malformed_edge_reasons(malformed_edges, assignment) == ["edge_endpoint_outside_entities", "edge_state_invalid"]

    assert app =~ "if (units === 0) continue;"
    assert app =~ "if (waves[waveIndex].length === 0 || !buckets[waveIndex]) continue;"
    assert app =~ "edge_endpoint_outside_entities"
    assert app =~ "edge_state_invalid"
    assert app =~ "excluded from aggregate counts · limited: "

    malformed = put_in(projection, ["graph", "edges", Access.at(0), "state"], "surprise")
    assert {:error, _reason} = PixirMonitor.Projection.Validator.validate(malformed)
  end

  test "limitation-bearing and absent-unit variants keep limitations beside affected counts", %{app: app} do
    assert {:ok, projected_variant} = PixirMonitor.Projection.project(SemanticZoomFixture.limitation_input())
    # The REAL projected limitation names flow end-to-end into the count copy;
    # no synthetic limitation stands in for them.
    assert "child_log_missing" in projected_variant["limitations"]
    [missing | kept] = projected_variant["units"]
    variant = %{projected_variant | "units" => kept}
    member_ids = hd(projected_variant["graph"]["waves"])
    observed = Enum.count(member_ids, fn id -> Enum.any?(variant["units"], &(&1["logical_id"] == id)) end)
    limitations = variant["limitations"] ++ if(missing["logical_id"] in member_ids, do: ["unit_evidence_absent"], else: [])
    count_copy = "#{observed} observed members · limited: #{Enum.join(limitations, ", ")}"

    assert count_copy =~ "limited: child_log_missing"
    assert count_copy =~ "unit_evidence_absent"
    assert app =~ "observed + \" observed member\""
    assert app =~ "limitations.length ? \" · limited: \""
  end

  test "hostile text at 100-unit scale reaches the real projection and remains on inert sinks", %{app: app, golden: golden} do
    assert {:ok, projection} = PixirMonitor.Projection.project(SemanticZoomFixture.hostile_input())
    assert length(projection["units"]) == 100
    assert Enum.any?(projection["units"], &(String.length(&1["logical_id"]) > 256))
    assert Enum.any?(projection["units"], &String.contains?(&1["agent"], "<script>"))
    assert length(materialize_window(golden, projection).entities |> Enum.flat_map(& &1.members)) == 100
    assert app =~ "node.textContent = scalar(value, \"—\")"
    assert app =~ "list.append(untrustedText(\"li\", scalar(edge.from"
    refute app =~ ".innerHTML"
  end

  test "cluster summaries remain separate and overview DOM stays bounded", %{app: app} do
    for dimension <- ["Execution", "Liveness", "Dependency gate", "Model advisory", "Attention"], do: assert(app =~ "[\"#{dimension}\"")
    assert app =~ "Source (run-scoped)"
    assert app =~ "zoom.entities.forEach(function (entity)"
    assert app =~ "zoom.arcs.forEach(function (arc)"
    assert app =~ "if (selectedEntity)"
    assert app =~ "if (selectedArc)"
  end

  defp materialize_window(golden, projection) do
    window = hd(golden["windows"])
    waves = projection["graph"]["waves"]

    entities =
      Enum.map(window["entities"], fn entity ->
        %{key: entity["key"], members: Enum.slice(Enum.at(waves, entity["wave"]), entity["offset"], entity["size"])}
      end)

    assignment = for entity <- entities, id <- entity.members, into: %{}, do: {id, entity.key}

    arcs =
      Enum.map(window["arcs"], fn arc ->
        edges = Enum.filter(projection["graph"]["edges"], &(assignment[&1["from"]] == arc["from"] and assignment[&1["to"]] == arc["to"]))
        %{from: arc["from"], to: arc["to"], expected_count: arc["edge_count"], edges: edges}
      end)

    %{entities: entities, arcs: arcs}
  end

  defp exact_edge_union?(arcs, projected_edges) do
    ledger = arcs |> Enum.flat_map(& &1.edges) |> Enum.map(&edge_tuple/1)
    projected = Enum.map(projected_edges, &edge_tuple/1)
    length(ledger) == length(Enum.uniq(ledger)) and MapSet.new(ledger) == MapSet.new(projected)
  end

  defp edge_tuple(edge), do: {edge["from"], edge["to"], edge["state"]}

  defp advisory_distribution(units) do
    Enum.reduce(units, %{}, fn advisory, counts ->
      value = if advisory["present"], do: if(advisory["parse_status"] == "invalid", do: "invalid", else: advisory["verdict"])
      if value, do: Map.update(counts, value, 1, &(&1 + 1)), else: counts
    end)
  end

  defp malformed_edge_reasons(edges, assignment) do
    Enum.map(edges, fn edge ->
      cond do
        is_nil(assignment[edge["from"]]) or is_nil(assignment[edge["to"]]) -> "edge_endpoint_outside_entities"
        edge["state"] not in ["ready", "blocked", "unknown"] -> "edge_state_invalid"
      end
    end)
  end

  defp ceil_page(size, page_size), do: div(size + page_size - 1, page_size)

  defp wave_index(waves, id), do: Enum.find_index(waves, &Enum.member?(&1, id))
end
