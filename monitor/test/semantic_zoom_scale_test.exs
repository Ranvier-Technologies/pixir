Code.require_file("support/semantic_zoom_fixture.ex", __DIR__)
Code.require_file("support/semantic_zoom_read_model.ex", __DIR__)

defmodule PixirMonitor.SemanticZoomScaleTest do
  use ExUnit.Case, async: true

  alias PixirMonitor.Projection.Builder
  alias PixirMonitor.SemanticZoomFixture

  @projection_source_max_events 20_000
  @truth_dimensions ~w(execution liveness gate advisory attention)

  setup_all do
    input = SemanticZoomFixture.input_500()
    assert {:ok, projection} = Builder.build(input)
    {:ok, input: input, projection: projection}
  end

  test "500-unit parent-log fixture stays below the projection ingestion bound", %{
    input: input,
    projection: projection
  } do
    parent_log = get_in(input, ["inputs", "parent_log"])

    assert length(parent_log) == 3 * length(projection["units"]) + 1
    assert length(parent_log) == 1_501
    assert length(parent_log) < @projection_source_max_events
  end

  test "real projection has the normative waves, cluster keys, and terminal chunks", %{
    projection: projection
  } do
    waves = projection["graph"]["waves"]

    assert length(projection["units"]) == 500
    assert Enum.map(waves, &length/1) == List.duplicate(36, 12) ++ [34, 34]

    assert entity_keys(materialize_window(projection, 0)) ==
             Enum.map(0..5, &"wave:#{&1}:bucket:0") ++ ["overflow:waves:6-13"]

    assert entity_keys(materialize_window(projection, 6)) ==
             ["boundary:upstream:waves:0-5"] ++
               Enum.map(6..11, &"wave:#{&1}:bucket:0") ++
               ["overflow:waves:12-13"]

    level_two = materialize_window(projection, 12)

    assert entity_keys(level_two) == [
             "boundary:upstream:waves:0-11",
             "wave:12:bucket:0",
             "wave:12:bucket:1",
             "wave:12:bucket:2",
             "wave:13:bucket:0",
             "wave:13:bucket:1",
             "wave:13:bucket:2"
           ]

    terminal_sizes =
      level_two.entities
      |> Enum.reject(&(&1.kind == :boundary))
      |> Enum.map(&length(&1.members))

    assert terminal_sizes == [12, 11, 11, 12, 11, 11]
  end

  test "level-zero ledgers equal graph edges exactly and exercise every arc class", %{
    projection: projection
  } do
    window = materialize_window(projection, 0)
    arcs = materialize_arcs(window, projection["graph"]["edges"])

    assert length(projection["graph"]["edges"]) == 928
    assert exact_edge_union?(window, arcs, projection["graph"]["edges"])

    assert arc_counts(arcs) == %{
             {"overflow:waves:6-13", "overflow:waves:6-13"} => 496,
             {"wave:0:bucket:0", "wave:1:bucket:0"} => 72,
             {"wave:1:bucket:0", "wave:2:bucket:0"} => 72,
             {"wave:2:bucket:0", "wave:3:bucket:0"} => 72,
             {"wave:3:bucket:0", "wave:4:bucket:0"} => 72,
             {"wave:4:bucket:0", "wave:5:bucket:0"} => 72,
             {"wave:5:bucket:0", "overflow:waves:6-13"} => 72
           }

    assert Enum.any?(arcs, fn arc ->
             String.starts_with?(arc.from, "wave:") and String.starts_with?(arc.to, "wave:")
           end)

    assert Enum.any?(arcs, fn arc ->
             String.starts_with?(arc.from, "wave:") and arc.to == "overflow:waves:6-13"
           end)

    assert Enum.any?(arcs, &(&1.from == "overflow:waves:6-13" and &1.to == &1.from))

    assert Enum.all?(arcs, fn arc ->
             states = MapSet.new(arc.edges, & &1["state"])
             MapSet.member?(states, "ready") and MapSet.member?(states, "blocked")
           end)

    bogus = [
      %{
        from: "wave:0:bucket:0",
        to: "wave:1:bucket:0",
        edges: projection["graph"]["edges"]
      }
    ]

    refute exact_edge_union?(window, bogus, projection["graph"]["edges"])

    non_entity = [
      %{
        from: "WRONG",
        to: "ALSO_WRONG",
        edges: projection["graph"]["edges"]
      }
    ]

    refute exact_edge_union?(window, non_entity, projection["graph"]["edges"])
  end

  test "deeper windows aggregate every upstream edge onto the boundary", %{
    projection: projection
  } do
    for start <- [6, 12] do
      window = materialize_window(projection, start)
      arcs = materialize_arcs(window, projection["graph"]["edges"])
      boundary = "boundary:upstream:waves:0-#{start - 1}"

      assert exact_edge_union?(window, arcs, projection["graph"]["edges"])
      assert Enum.any?(arcs, &(&1.from == boundary or &1.to == boundary))
      refute Enum.any?(arcs, &(is_nil(&1.from) or is_nil(&1.to)))
    end
  end

  test "every cluster distribution accounts for every member independently", %{
    projection: projection
  } do
    units = Map.new(projection["units"], &{&1["logical_id"], &1})

    for start <- [0, 6, 12], entity <- materialize_window(projection, start).entities do
      members = Enum.map(entity.members, &Map.fetch!(units, &1))

      for dimension <- @truth_dimensions do
        distribution = Enum.frequencies_by(members, &dimension_value(&1, dimension))
        assert distribution |> Map.values() |> Enum.sum() == length(entity.members)
      end
    end
  end

  test "route-only read-model derivation cannot alter per-unit truth", %{
    projection: projection
  } do
    routes = [
      %{zoom_start: 0, selected_cluster: "wave:0:bucket:0", selected_arc: nil, member_page: 1, edge_page: 1},
      %{zoom_start: 6, selected_cluster: "overflow:waves:12-13", selected_arc: "wave:6:bucket:0=>wave:7:bucket:0", member_page: 3, edge_page: 2},
      %{zoom_start: 12, selected_cluster: "wave:13:bucket:2", selected_arc: nil, member_page: 1, edge_page: 1}
    ]

    snapshots = Enum.map(routes, &read_model(projection, &1).truth_digest)
    assert Enum.uniq(snapshots) == [projection_truth_digest(projection)]
  end

  test "builder-derived dependency edges pin the currently reachable two-state reality", %{
    projection: projection
  } do
    states = projection["graph"]["edges"] |> Enum.map(& &1["state"]) |> MapSet.new()

    assert states == MapSet.new(["ready", "blocked"])
    refute MapSet.member?(states, "unknown")
  end

  defp read_model(projection, route) do
    window = materialize_window(projection, route.zoom_start)

    %{
      route: route,
      window: window,
      truth_digest: window_truth_digest(projection, window)
    }
  end

  defp window_truth_digest(projection, window) do
    units = Map.new(projection["units"], &{&1["logical_id"], &1})

    ordered_members =
      Enum.flat_map(window.entities, fn entity ->
        entity.members
        |> Enum.chunk_every(12)
        |> List.flatten()
      end)

    %{
      ordered_members: ordered_members,
      truth:
        Map.new(ordered_members, fn logical_id ->
          {logical_id, units |> Map.fetch!(logical_id) |> Map.take(@truth_dimensions)}
        end)
    }
  end

  defp projection_truth_digest(projection) do
    ordered_members = projection["graph"]["waves"] |> List.flatten()

    %{
      ordered_members: ordered_members,
      truth: truth_snapshot(projection)
    }
  end

  defp truth_snapshot(projection) do
    Map.new(projection["units"], fn unit ->
      truth = Map.take(unit, @truth_dimensions)
      {unit["logical_id"], truth}
    end)
  end

  defp dimension_value(unit, "execution"), do: unit["execution"]["state"]
  defp dimension_value(unit, "liveness"), do: unit["liveness"]["state"]
  defp dimension_value(unit, "gate"), do: unit["gate"]["state"]

  defp dimension_value(unit, "advisory") do
    advisory = unit["advisory"]
    {advisory["present"], advisory["verdict"], advisory["parse_status"]}
  end

  defp dimension_value(unit, "attention"), do: unit["attention"]["required"]

  defp materialize_window(projection, start),
    do: PixirMonitor.SemanticZoomReadModel.materialize_window(projection, start)

  defp materialize_arcs(window, projected_edges),
    do: PixirMonitor.SemanticZoomReadModel.materialize_arcs(window, projected_edges)

  defp exact_edge_union?(window, arcs, projected_edges),
    do:
      PixirMonitor.SemanticZoomReadModel.exact_edge_union?(
        window,
        arcs,
        projected_edges
      )

  defp arc_counts(arcs) do
    Map.new(arcs, fn arc -> {{arc.from, arc.to}, length(arc.edges)} end)
  end

  defp entity_keys(window), do: PixirMonitor.SemanticZoomReadModel.entity_keys(window)
end
