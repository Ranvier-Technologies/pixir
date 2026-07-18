unless Code.ensure_loaded?(PixirMonitor.FixtureWorkspace) do
  Code.require_file("support/fixture_workspace.ex", __DIR__)
end

unless Code.ensure_loaded?(PixirMonitor.InventoryFixture) do
  Code.require_file("support/inventory_fixture.ex", __DIR__)
end

Code.require_file("support/semantic_zoom_fixture.ex", __DIR__)
Code.require_file("support/semantic_zoom_read_model.ex", __DIR__)

defmodule PixirMonitor.SemanticZoomHonestyTest do
  use ExUnit.Case, async: true

  alias PixirMonitor.Projection.Builder
  alias PixirMonitor.SemanticZoomFixture
  alias PixirMonitor.SemanticZoomReadModel

  test "run-detail limitation stays beside every level-zero cluster and arc count" do
    assert {:ok, projection} = Builder.build(SemanticZoomFixture.limitation_input_500())
    assert "child_log_missing" in projection["limitations"]
    assert "child_log_missing" in projection["source"]["limitations"]

    windows = Enum.map([0, 6, 12], &SemanticZoomReadModel.materialize_window(projection, &1))

    assert Enum.map(windows, &SemanticZoomReadModel.entity_keys/1) == [
             Enum.map(0..5, &"wave:#{&1}:bucket:0") ++ ["overflow:waves:6-13"],
             ["boundary:upstream:waves:0-5"] ++
               Enum.map(6..11, &"wave:#{&1}:bucket:0") ++
               ["overflow:waves:12-13"],
             [
               "boundary:upstream:waves:0-11",
               "wave:12:bucket:0",
               "wave:12:bucket:1",
               "wave:12:bucket:2",
               "wave:13:bucket:0",
               "wave:13:bucket:1",
               "wave:13:bucket:2"
             ]
           ]

    level_zero = hd(windows)

    assert Enum.all?(windows, fn window ->
             Enum.all?(window.entities, &("child_log_missing" in &1.limitations))
           end)

    arcs_by_window =
      Enum.map(windows, fn window ->
        SemanticZoomReadModel.materialize_arcs(window, projection["graph"]["edges"])
      end)

    assert Enum.sum(Enum.map(level_zero.entities, &length(&1.members))) == 500
    assert Enum.sum(Enum.map(hd(arcs_by_window), &length(&1.edges))) == 928

    assert Enum.all?(arcs_by_window, fn arcs ->
             Enum.all?(arcs, fn arc ->
               "child_log_missing" in SemanticZoomReadModel.arc_limitations(projection, arc)
             end)
           end)

    [missing | kept] = projection["units"]
    absent_projection = %{projection | "limitations" => [], "units" => kept}
    absent_window = SemanticZoomReadModel.materialize_window(absent_projection, 0)

    affected =
      Enum.find(absent_window.entities, fn entity ->
        missing["logical_id"] in entity.members
      end)

    assert affected.limitations == ["unit_evidence_absent"]

    absent_arc =
      absent_window
      |> SemanticZoomReadModel.materialize_arcs(absent_projection["graph"]["edges"])
      |> Enum.find(fn arc ->
        Enum.any?(arc.edges, fn edge ->
          edge["from"] == missing["logical_id"] or edge["to"] == missing["logical_id"]
        end)
      end)

    assert SemanticZoomReadModel.arc_limitations(absent_projection, absent_arc) == [
             "unit_evidence_absent"
           ]
  end

  @tag :tmp_dir
  test "run inventory truncation remains list-scoped and never marks run detail", %{
    tmp_dir: tmp_dir
  } do
    ids = PixirMonitor.InventoryFixture.materialize_many!(tmp_dir, 0..512)

    assert {:ok, %{"rows" => rows, "metadata" => metadata}} =
             PixirMonitor.Projection.Source.Filesystem.list_runs(workspace: tmp_dir)

    assert length(rows) == 512
    assert metadata["total"] == 513
    assert metadata["selected"] == 512
    assert metadata["truncated"] == true
    assert [%{"kind" => "run_inventory_truncated"}] = metadata["limitations"]

    detail_id = hd(ids)

    assert {:ok, detail_input} =
             PixirMonitor.Projection.Source.Filesystem.fetch_input(detail_id,
               workspace: tmp_dir
             )

    assert {:ok, projection} = Builder.build(detail_input)
    refute contains_value?(projection, "run_inventory_truncated")

    assert {:ok, limited_projection} =
             Builder.build(SemanticZoomFixture.limitation_input_500())

    refute contains_value?(limited_projection, "run_inventory_truncated")
  end

  @tag :tmp_dir
  test "fixture materialization refuses to overwrite an existing Session Log", %{
    tmp_dir: tmp_dir
  } do
    input = PixirMonitor.InventoryFixture.input(0)
    session_id = PixirMonitor.FixtureWorkspace.materialize!(input, tmp_dir)

    assert_raise ArgumentError,
                 "refusing to overwrite existing append-only Session Log: #{session_id}.ndjson",
                 fn -> PixirMonitor.FixtureWorkspace.materialize!(input, tmp_dir) end
  end

  test "malformed timestamps and unknown enums do not order or unbound the read model" do
    assert {:ok, clean} = Builder.build(SemanticZoomFixture.input_500())
    assert {:ok, malformed} = Builder.build(SemanticZoomFixture.malformed_input_500())

    clean_windows = Enum.map([0, 6, 12], &SemanticZoomReadModel.materialize_window(clean, &1))
    malformed_windows = Enum.map([0, 6, 12], &SemanticZoomReadModel.materialize_window(malformed, &1))

    assert Enum.map(malformed_windows, &SemanticZoomReadModel.entity_keys/1) ==
             Enum.map(clean_windows, &SemanticZoomReadModel.entity_keys/1)

    assert Enum.map(malformed_windows, &display_order/1) ==
             Enum.map(clean_windows, &display_order/1)

    assert malformed["run"]["strategy"] == "unknown"
    assert malformed["run"]["mode"] == "unknown"
    assert "unknown_enum:strategy:future_strategy" in malformed["limitations"]
    assert "unknown_enum:mode:future_mode" in malformed["limitations"]

    assert malformed["execution"]["state"] == "unknown"

    assert "unknown_enum:state:future_execution_state" in malformed["limitations"]

    assert malformed["source"]["live_observed_at"] == nil

    assert "malformed_timestamp:live_observed_at:2026-07-15 23:59:59Z" in malformed["source"]["limitations"]

    assert malformed["liveness"]["observed_at"] == nil

    assert "malformed_timestamp:observed_at:2026-07-15 23:59:59Z" in malformed["limitations"]

    target = Enum.find(malformed["units"], &(&1["label"] == "wave-0-unit-00"))

    # The unit's execution state folds from attempt lifecycle events, which
    # repair validates structurally: with no normalizable channel, the unit
    # completes normally and carries no execution confession.
    assert target["execution"]["state"] == "completed"
    assert target["gate"]["state"] == "unknown"
    # gate.state is producer-controlled-by-fold: Gate.state/1 fail-closes the
    # event fold into the vocabulary (list/detail contract in source_test), so
    # the seeded out-of-vocabulary checkpoint_status maps to unknown WITHOUT a
    # confession and never reaches the Validator raw.
    assert target["gate"]["state"] == "unknown"
    refute Enum.any?(target["limitations"], &String.starts_with?(&1, "unknown_enum:state:future_gate"))
    assert target["advisory"]["verdict"] == "unknown"

    assert "unknown_enum:verdict:future_advisory_verdict" in target["limitations"]

    # liveness.observed_at on a TERMINAL unit is producer-controlled: liveness/4
    # sets it to nil structurally on the terminal branches, so the seeded
    # malformed runtime observed_at can never reach the unit and no confession
    # appears. The live-unit reachability of this field is covered in
    # runtime_projection_test.exs.
    assert target["liveness"]["observed_at"] == nil

    refute Enum.any?(
             target["limitations"],
             &String.starts_with?(&1, "malformed_timestamp:observed_at")
           )

    [target_attempt] = target["attempts"]
    assert target_attempt["status"] == "completed"

    # attempt.status is repair-guaranteed at BOTH entry points (start and
    # terminal lifecycle events reject invalid statuses structurally), so no
    # normalization layer exists for it, no confession can appear, and the
    # untouched lifecycle completes normally.
    refute Enum.any?(target_attempt["limitations"], &String.contains?(&1, "future_attempt_status"))

    [target_artifact] = target["artifacts"]
    assert target_artifact["status"] == "unknown"
    assert target_artifact["application_state"] == "unknown"
    assert "unknown_enum:status:future_artifact_state" in target["limitations"]

    assert "unknown_enum:application_state:future_artifact_state" in target["limitations"]

    malformed_units =
      Enum.filter(malformed["units"], fn unit ->
        "unknown_enum:execution_kind:future_execution_kind" in unit["limitations"]
      end)

    assert length(malformed_units) == 13

    assert Enum.all?(malformed_units, fn unit ->
             unit["execution_kind"] == "unknown" and
               unit["workspace_mode"] == "unknown" and
               unit["posture"] == "unknown" and
               "unknown_enum:execution_kind:future_execution_kind" in unit["limitations"] and
               "unknown_enum:workspace_mode:future_workspace_mode" in unit["limitations"] and
               "unknown_enum:posture:future_posture" in unit["limitations"]
           end)

    assert Enum.all?(malformed_units, fn unit ->
             [attempt] = unit["attempts"]
             raw_timestamp = "malformed-timestamp-for-#{unit["label"]}"

             is_nil(attempt["started_at"]) and
               is_nil(attempt["ended_at"]) and
               "malformed_timestamp:started_at:#{raw_timestamp}" in attempt["limitations"] and
               "malformed_timestamp:ended_at:#{raw_timestamp}" in attempt["limitations"]
           end)

    # The exact expected maximum, computed independently of the Builder: the
    # canonical encoding of the latest schema-shaped (T-separated, parseable)
    # event timestamp in the malformed fixture. A wrong-but-parseable winner
    # cannot hide behind a merely-parseable assertion.
    expected_last_durable_at =
      SemanticZoomFixture.malformed_input_500()
      |> get_in(["inputs", "parent_log"])
      |> Enum.map(& &1["ts"])
      |> Enum.filter(fn ts ->
        is_binary(ts) and String.contains?(ts, "T") and
          match?({:ok, _, _}, DateTime.from_iso8601(ts))
      end)
      |> Enum.map(fn ts ->
        {:ok, datetime, _offset} = DateTime.from_iso8601(ts)
        datetime
      end)
      |> Enum.max(DateTime)
      |> DateTime.to_iso8601()

    assert malformed["source"]["last_durable_at"] == expected_last_durable_at

    assert "malformed_event_timestamps:39" in malformed["source"]["limitations"]
    assert PixirMonitor.Projection.Validator.validate(malformed) == :ok
  end

  test "hostile scale payloads survive verbatim through the projection" do
    assert {:ok, projection} = Builder.build(SemanticZoomFixture.hostile_input_500())
    assert length(projection["units"]) == 500

    replacement = String.duplicate("A", 256)
    long_id = "workflow:semantic-zoom-500:step:" <> replacement
    unit = Enum.find(projection["units"], &(&1["logical_id"] == long_id))

    assert unit["label"] == replacement
    assert Enum.any?(projection["graph"]["waves"], &(long_id in &1))

    assert Enum.any?(projection["graph"]["edges"], fn edge ->
             edge["from"] == long_id or edge["to"] == long_id
           end)

    agents = Enum.map(projection["units"], & &1["agent"])
    assert "<script>alert('semantic zoom')</script>" in agents
    assert "&lt;hostile&gt;&amp;&#x202E;" in agents
    assert "right-to-left-override:\u202Epayload" in agents

    capped = Enum.find(agents, &String.starts_with?(&1, "cap:"))
    assert byte_size(capped) == 32_768

    window = SemanticZoomReadModel.materialize_window(projection, 0)
    arcs = SemanticZoomReadModel.materialize_arcs(window, projection["graph"]["edges"])

    assert SemanticZoomReadModel.exact_edge_union?(
             window,
             arcs,
             projection["graph"]["edges"]
           )
  end

  test "read-model zoom start clamps to zero outside the JS bounds" do
    projection = degenerate_projection([["unit-a"], ["unit-b"]])
    zero = SemanticZoomReadModel.materialize_window(projection, 0)

    for invalid_start <- [-1, 2, 99] do
      assert SemanticZoomReadModel.materialize_window(projection, invalid_start) == zero
    end
  end

  test "read-model derivation skips but charges an empty middle wave like JS" do
    projection =
      degenerate_projection([
        ["unit-a", "unit-b", "unit-c", "unit-d"],
        [],
        ["unit-e", "unit-f", "unit-g", "unit-h"]
      ])

    window = SemanticZoomReadModel.materialize_window(projection, 0)

    assert SemanticZoomReadModel.entity_keys(window) == [
             "wave:0:bucket:0",
             "wave:0:bucket:1",
             "wave:0:bucket:2",
             "wave:2:bucket:0",
             "wave:2:bucket:1"
           ]
  end

  test "read-model bucket allocation stops when every wave is saturated" do
    projection = degenerate_projection([["unit-a", "unit-b"]])
    window = SemanticZoomReadModel.materialize_window(projection, 0)

    assert SemanticZoomReadModel.entity_keys(window) == [
             "wave:0:bucket:0",
             "wave:0:bucket:1"
           ]

    assert Enum.map(window.entities, &length(&1.members)) == [1, 1]
  end

  test "all 500-unit variants are byte-identical across constructions" do
    constructors = [
      &SemanticZoomFixture.hostile_input_500/0,
      &SemanticZoomFixture.malformed_input_500/0,
      &SemanticZoomFixture.limitation_input_500/0
    ]

    for constructor <- constructors do
      assert :erlang.term_to_binary(constructor.()) ==
               :erlang.term_to_binary(constructor.())
    end
  end

  defp degenerate_projection(waves) do
    units =
      waves
      |> List.flatten()
      |> Enum.map(&%{"logical_id" => &1})

    %{
      "graph" => %{"waves" => waves, "edges" => []},
      "limitations" => [],
      "units" => units
    }
  end

  defp display_order(window) do
    Enum.map(window.entities, & &1.members)
  end

  defp contains_value?(value, target) when is_map(value) do
    Enum.any?(value, fn {key, item} ->
      contains_value?(key, target) or contains_value?(item, target)
    end)
  end

  defp contains_value?(value, target) when is_list(value),
    do: Enum.any?(value, &contains_value?(&1, target))

  defp contains_value?(target, target), do: true
  defp contains_value?(_value, _target), do: false
end
