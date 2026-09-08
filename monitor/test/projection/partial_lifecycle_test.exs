defmodule PixirMonitor.Projection.PartialLifecycleTest do
  use ExUnit.Case, async: false

  alias PixirMonitor.Projection
  alias PixirMonitor.Projection.{Source.Filesystem, Validator}

  setup do
    workspace = Path.join(System.tmp_dir!(), "monitor-partial-lifecycle-#{System.unique_integer([:positive, :monotonic])}")
    sessions = Path.join([workspace, ".pixir", "sessions"])
    File.mkdir_p!(sessions)
    on_exit(fn -> File.rm_rf!(workspace) end)
    %{workspace: workspace, sessions: sessions, opts: [workspace: workspace, max_log_bytes: 8192]}
  end

  test "omitted start leaves terminal evidence, not an invented durable attempt", ctx do
    bounded(ctx, [], [life(101, "finished", "completed")], [life(50, "started", "running")])
    {input, projection} = success(ctx)
    [unit] = projection["units"]
    assert unit["attempts"] == []
    assert "e-parent-101" in unit["evidence_refs"]
    assert "attempt_lineage_unavailable" in unit["limitations"]
    refute Enum.any?(input["inputs"]["parent_log"], &(get_in(&1, ["data", "event"]) == "started"))
    assert Enum.any?(projection["evidence"], &(&1["id"] == "e-parent-101"))
    assert {:ok, %{"rows" => [row]}} = Filesystem.list_runs(ctx.opts)
    assert Enum.any?(row["children"], &(&1["session_id"] == "child-a"))
  end

  test "orphan retry and subsequent tail pair do not infer ordinals or predecessor", ctx do
    retry = life(101, "retrying", "running") |> put_in(["data", "failed_child_session_id"], "child-a")
    bounded(ctx, [], [retry, life(102, "started", "running", "child-b"), life(103, "finished", "completed", "child-b")], [life(50, "started", "running")])
    {_input, projection} = success(ctx)
    [unit] = projection["units"]
    assert unit["attempts"] == []
    assert Enum.all?([101, 102, 103], &("e-parent-#{&1}" in unit["evidence_refs"]))
    prose = Jason.encode!(projection["evidence"])
    refute prose =~ "First"
    refute prose =~ "Second"
    refute prose =~ "Provisional"
  end

  test "prefix active attempt is not carried through the gap to a new tail attempt", ctx do
    bounded(ctx, [life(1, "started", "running")], [life(101, "started", "running", "child-b"), life(102, "finished", "completed", "child-b")])
    {_input, projection} = success(ctx)
    [unit] = projection["units"]
    [attempt] = unit["attempts"]
    assert attempt["ordinal"] == 0
    assert attempt["child_session_id"] == "child-a"
    assert attempt["status"] == "unknown"
    assert attempt["ended_at"] == nil
    assert attempt["predecessor_attempt_id"] == nil
    assert "attempt_continuity_unknown" in attempt["limitations"]
    refute "e-parent-102" in attempt["evidence_refs"]
    assert "e-parent-102" in unit["evidence_refs"]
  end

  test "prefix attempts do not borrow error or evidence from a later child epoch", ctx do
    bounded(ctx, [life(1, "started", "running"), life(2, "finished", "completed")], [life(101, "finished", "completed", "child-b")])

    child = [
      %{"id" => "later-user", "session_id" => "child-a", "seq" => 0, "ts" => "2026-09-06T00:10:00Z", "type" => "user_message", "data" => %{"text" => "later resumed epoch"}},
      %{"id" => "later-failure", "session_id" => "child-a", "seq" => 1, "ts" => "2026-09-06T00:10:01Z", "type" => "turn_failed", "data" => %{"error_kind" => "later_epoch_failure"}}
    ]

    File.write!(Path.join(ctx.sessions, "child-a.ndjson"), Enum.map_join(child, "", &(Jason.encode!(&1) <> "\n")))
    {_input, projection} = success(ctx)
    [attempt] = hd(projection["units"])["attempts"]
    assert attempt["error_kind"] == nil
    refute Enum.any?(attempt["evidence_refs"], &String.starts_with?(&1, "e-child-"))
    assert attempt["child_event_window"]["basis"] == "unknown"
  end

  test "known prefix pair remains observable without complete unit or usage claims", ctx do
    bounded(ctx, [life(1, "started", "running"), life(2, "finished", "completed")], [life(101, "finished", "completed", "child-b")])
    {_input, projection} = success(ctx)
    [attempt] = hd(projection["units"])["attempts"]
    assert attempt["ordinal"] == 0
    assert attempt["status"] == "completed"
    assert attempt["started_at"] != nil
  end

  test "a second unmatched close in contiguous tail is refused, including retry", ctx do
    for kind <- ["finished", "retrying"] do
      bounded(ctx, [], [life(101, "finished", "completed"), life(102, kind, "completed")])
      refusal(ctx)
    end
  end

  test "malformed and overlapping contiguous tail remain refused", ctx do
    for tail <- [
          [life(101, "finished", "bogus")],
          [life(101, "retrying", "bogus")],
          [life(101, "queued", "bogus")],
          [life(101, "finished", "completed", "../unsafe")],
          [life(101, "finished", "completed", nil)],
          [life(101, "started", "completed")],
          [life(101, "started", "running"), life(102, "started", "running", "child-b")],
          [life(101, "started", "running"), life(102, "finished", "completed", "child-b")],
          [put_in(life(101, "finished", "completed"), ["data", "subagent_id"], "unsafe:id")]
        ] do
      bounded(ctx, [], tail)
      refusal(ctx)
    end
  end

  test "a prefix open attempt loses continuity even with no lifecycle in the tail", ctx do
    bounded(ctx, [life(1, "started", "running")], [event(101, "user_message", %{"text" => "tail observation"})])
    {_input, projection} = success(ctx)
    [attempt] = hd(projection["units"])["attempts"]
    assert attempt["status"] == "unknown"
    assert attempt["ended_at"] == nil
    assert "attempt_continuity_unknown" in attempt["limitations"]
  end

  test "known tail close cannot borrow prefix linkage for a second close", ctx do
    bounded(ctx, [life(1, "started", "running")], [life(101, "finished", "completed", "child-b"), life(102, "finished", "completed")])
    refusal(ctx)
  end

  test "partiality does not excuse an unmatched close in the complete prefix", ctx do
    bounded(ctx, [life(1, "finished", "completed")], [life(101, "started", "running")])
    refusal(ctx)
  end

  test "child observations remain discoverable without complete attempt attribution", ctx do
    bounded(ctx, [], [life(101, "finished", "completed"), life(102, "started", "running", "child-b")])

    children =
      for child <- ["child-a", "child-b"] do
        path = Path.join(ctx.sessions, "#{child}.ndjson")

        events = [
          event(0, "subagent_event", %{"event" => "permission_posture", "parent_session_id" => "parent"}),
          event(1, "provider_usage", %{"usage_summary" => %{"input_tokens" => 12, "output_tokens" => 3}})
        ]

        bytes = Enum.map_join(events, "", &(Jason.encode!(Map.put(&1, "session_id", child)) <> "\n"))
        File.write!(path, bytes)
        {path, bytes}
      end

    {input, projection} = success(ctx)
    assert input["completeness"]["parent_log"] == "partial_prefix_tail"
    assert input["completeness"]["child_logs"] == "complete_through_observed_at"
    refute "child_log_missing" in projection["source"]["limitations"]
    assert {:ok, %{"rows" => [row]}} = Filesystem.list_runs(ctx.opts)
    assert Enum.sort(Enum.map(row["children"], & &1["session_id"])) == ["child-a", "child-b"]
    assert hd(projection["units"])["attempts"] == []

    for child <- ["child-a", "child-b"] do
      assert {:error, %{kind: "run_not_found", details: details}} = Filesystem.fetch_input(child, ctx.opts)
      refute Map.has_key?(details, :parent_unprojected_reason)
    end

    refute Jason.encode!(projection["evidence"]) =~ "First"
    for {path, bytes} <- children, do: assert(File.read!(path) == bytes)
  end

  test "unsafe workflow identity conflicts remain errors across the gap", ctx do
    workflow = event(1, "workflow_event", %{"kind" => "workflow_started", "workflow_id" => "wf", "graph" => %{"steps" => [%{"id" => "a"}, %{"id" => "b"}]}})

    tail = [
      put_in(life(101, "finished", "completed"), ["data", "delegation_context"], %{"step_id" => "a"}),
      put_in(life(102, "started", "running", "child-b"), ["data", "delegation_context"], %{"step_id" => "b"})
    ]

    bounded(ctx, [workflow], tail)
    refusal(ctx)
  end

  test "different Subagents cannot overlap in the same retained Workflow unit", ctx do
    workflow = event(1, "workflow_event", %{"kind" => "workflow_started", "workflow_id" => "wf", "graph" => %{"steps" => [%{"id" => "a"}]}})

    tail = [
      put_in(life(101, "started", "running"), ["data", "delegation_context"], %{"step_id" => "a"}),
      life(102, "started", "running", "child-b")
      |> put_in(["data", "subagent_id"], "sub-b")
      |> put_in(["data", "delegation_context"], %{"step_id" => "a"})
    ]

    bounded(ctx, [workflow], tail)
    refusal(ctx)
  end

  test "sequence skips do not grant unknown predecessors without the bounded selection", ctx do
    bounded(ctx, [], [life(101, "finished", "completed")])
    input = raw_input(ctx)
    assert {:ok, _projection} = Projection.project(input)

    assert {:error, %{kind: "attempt_terminal_target_unresolved"}} =
             input |> put_in(["inputs", "parent_log_selection", "partial"], false) |> Projection.project()
  end

  test "complete Logs retain strict unmatched retry and terminal refusal", ctx do
    for kind <- ["finished", "retrying"] do
      events = [queued(), life(1, kind, "completed")]
      write_parent(ctx, events)
      refusal(ctx)
    end
  end

  defp success(ctx) do
    path = Path.join(ctx.sessions, "parent.ndjson")
    before = File.read!(path)
    assert {:ok, %{"rows" => [row], "metadata" => metadata}} = Filesystem.list_runs(ctx.opts)
    assert metadata["dropped_logs"] == 0
    assert row["execution"] == %{"state" => "unknown", "terminal" => false}
    assert {:ok, input} = Filesystem.fetch_input("parent", ctx.opts)
    assert input["inputs"]["parent_log_selection"]["partial"]
    assert {:ok, projection} = Projection.project(input)
    assert {:ok, independently_projected} = Projection.project(raw_input(ctx))
    assert input["inputs"]["parent_log"] == raw_input(ctx)["inputs"]["parent_log"]

    lineage = fn projection ->
      Enum.map(projection["units"], fn unit -> Enum.map(unit["attempts"], &Map.take(&1, ~w(attempt_id ordinal status started_at ended_at predecessor_attempt_id evidence_refs))) end)
    end

    assert lineage.(independently_projected) == lineage.(projection)
    assert :ok = Validator.validate(independently_projected)
    assert :ok = Validator.validate(projection)
    assert projection["execution"]["state"] == "unknown"
    refute projection["execution"]["terminal"]
    refute projection["usage"]["complete"]
    assert projection["post_terminal_child_activity"]["state"] == "undetermined"

    for unit <- projection["units"] do
      assert unit["execution"]["state"] == "unknown"
      refute unit["usage"]["complete"]
      assert Enum.all?(unit["attempts"], &(is_integer(&1["ordinal"]) and &1["materialization"] == "durable"))
    end

    assert File.read!(path) == before
    {input, projection}
  end

  defp refusal(ctx) do
    before = File.read!(Path.join(ctx.sessions, "parent.ndjson"))
    assert {:ok, %{"rows" => [], "metadata" => metadata}} = Filesystem.list_runs(ctx.opts)
    assert metadata["dropped_logs"] == 1
    assert {:error, _} = Filesystem.fetch_input("parent", ctx.opts)
    assert {:error, %{kind: kind}} = Projection.project(raw_input(ctx))

    assert kind in ~w(attempt_terminal_target_unresolved attempt_retry_target_unresolved attempt_start_status_invalid attempt_terminal_status_invalid attempt_unit_overlap attempt_status_invalid attempt_child_identity_invalid run_unit_identity_invalid run_workflow_identity_conflict)

    assert File.read!(Path.join(ctx.sessions, "parent.ndjson")) == before
  end

  defp raw_input(ctx) do
    assert {:ok, %{history: history, selection: selection}} = Pixir.Log.fold_bounded("parent", ctx.opts)
    events = Enum.map(history, fn e -> %{"seq" => e.seq, "ts" => e.ts, "session_id" => e.session_id, "type" => Atom.to_string(e.type), "data" => e.data} end)

    %{
      "inputs" => %{
        "terminal_envelope" => nil,
        "delegate_snapshot" => nil,
        "parent_log" => events,
        "parent_log_selection" => selection,
        "parent_log_origin" => "workspace_log",
        "child_logs" => %{},
        "runtime_diagnostics" => nil,
        "owner_state" => nil,
        "evidence_mirror" => nil
      }
    }
  end

  defp bounded(ctx, prefix, tail, middle \\ []) do
    middle = Map.new(middle, &{&1["seq"], &1})
    fillers = Enum.map(3..100, fn seq -> Map.get(middle, seq, event(seq, "user_message", %{"text" => String.duplicate("x", 1000)})) end)
    write_parent(ctx, [queued()] ++ prefix ++ fillers ++ tail)
    assert {:ok, %{history: history, selection: selection}} = Pixir.Log.fold_bounded("parent", ctx.opts)
    assert selection["partial"]
    assert selection["tail_first_seq"] > 50
    assert Enum.all?(tail, fn e -> Enum.any?(history, &(&1.seq == e["seq"])) end)
    refute Enum.any?(history, &(&1.seq == 50))
  end

  defp write_parent(ctx, events) do
    File.write!(Path.join(ctx.sessions, "parent.ndjson"), Enum.map_join(events, "", &(Jason.encode!(&1) <> "\n")))
  end

  defp queued, do: life(0, "queued", "queued")
  defp life(seq, kind, status, child \\ "child-a"), do: event(seq, "subagent_event", %{"event" => kind, "status" => status, "subagent_id" => "sub-a", "child_session_id" => child})
  defp event(seq, type, data), do: %{"id" => "event-#{seq}", "session_id" => "parent", "seq" => seq, "ts" => "2026-09-06T00:00:00Z", "type" => type, "data" => data}
end
