defmodule PixirMonitor.Projection.PartialChildEvidenceTest do
  use ExUnit.Case, async: false

  alias PixirMonitor.Projection
  alias PixirMonitor.Projection.{Source.Filesystem, Validator}

  setup do
    workspace = Path.join(System.tmp_dir!(), "monitor-partial-child-#{System.unique_integer([:positive, :monotonic])}")
    sessions = Path.join([workspace, ".pixir", "sessions"])
    File.mkdir_p!(sessions)
    on_exit(fn -> File.rm_rf!(workspace) end)
    %{workspace: workspace, sessions: sessions, opts: [workspace: workspace, max_log_bytes: 4096]}
  end

  test "bounded child prefix and tail remain inspectable without complete usage or guessed attempt windows", c do
    write(c, "parent", parent())
    bytes = write(c, "child", oversized_child())
    assert {:ok, input} = Filesystem.fetch_input("parent", c.opts)
    assert input["completeness"]["parent_log"] == "complete_through_observed_at"
    assert input["completeness"]["child_logs"] == "partial_prefix_tail"
    events = input["inputs"]["child_logs"]["child"]
    assert is_list(events)
    assert Enum.any?(events, &(&1["seq"] == 1))
    assert Enum.any?(events, &(&1["seq"] == 101))
    selection = input["inputs"]["child_log_selections"]["child"]
    assert selection["partial"]
    assert selection["bytes_read"] <= 4096
    assert input["inputs"]["runtime_diagnostics"] == nil
    assert {:ok, projection} = Projection.project(input)
    assert :ok = Validator.validate(projection)
    [unit] = projection["units"]
    [attempt] = unit["attempts"]
    assert attempt["ordinal"] == 0
    assert attempt["status"] == "completed"
    assert attempt["error_kind"] == nil
    assert attempt["child_event_window"]["basis"] == "unknown"
    assert attempt["child_event_window"]["evidence_refs"] == []
    refute Map.has_key?(attempt, "usage")

    for usage <- [unit["usage"], projection["usage"]] do
      refute usage["complete"]
      assert usage["source"] == "incomplete"
      assert usage["calls"] == 2
      assert "usage_attribution_ambiguous" in usage["limitations"]
      assert "usage_incomplete_partial_child_log" in usage["limitations"]
    end

    assert projection["execution"]["state"] == "completed"
    assert unit["gate"]["state"] == "not_applicable"
    assert unit["mutation"]["status"] == "partial"
    assert unit["mutation"]["observed_paths"] == ["lib/retained.ex"]
    assert unit["mutation"]["observed_semantics"] == "at_least"
    assert "mutation_evidence_incomplete" in unit["mutation"]["limitations"]
    assert Enum.any?(projection["source"]["limitations"], &String.contains?(&1, "Partial child Log child"))
    refute "child_log_missing" in projection["source"]["limitations"]
    assert Enum.any?(projection["evidence"], &(&1["session_id"] == "child" and &1["seq"] == 1))
    assert Enum.any?(projection["evidence"], &(&1["session_id"] == "child" and &1["seq"] == 102 and String.contains?(&1["description"], "later_failure")))
    refute Enum.any?(projection["evidence"], &String.contains?(&1["description"], "epoch provider"))
    assert File.read!(Path.join(c.sessions, "child.ndjson")) == bytes
  end

  test "no retained usage or writes or later activity cannot prove none", c do
    write(c, "parent", parent())
    write(c, "child", [event("child", 0, "user_message")] ++ fillers("child") ++ [event("child", 101, "user_message")])
    assert {:ok, input} = Filesystem.fetch_input("parent", c.opts)
    assert {:ok, projection} = Projection.project(input)
    [unit] = projection["units"]
    assert unit["usage"]["calls"] == 0
    refute unit["usage"]["complete"]
    assert unit["mutation"]["status"] == "indeterminate"
    assert unit["mutation"]["basis"] == "no_child_evidence_available"
    assert projection["mutation"]["status"] == "indeterminate"
    assert projection["post_terminal_child_activity"]["state"] == "undetermined"
    assert projection["post_terminal_child_activity"]["event_count"] == nil
    assert :ok = Validator.validate(projection)
  end

  test "reused child with omitted user anchors does not borrow a later error or usage", c do
    write(c, "parent", parent() ++ [lifecycle(2, "input", "running"), lifecycle(3, "finished", "completed")])
    write(c, "child", oversized_child())
    assert {:ok, input} = Filesystem.fetch_input("parent", c.opts)
    assert {:ok, projection} = Projection.project(input)
    [unit] = projection["units"]
    assert Enum.map(unit["attempts"], & &1["ordinal"]) == [0, 1]

    for attempt <- unit["attempts"] do
      assert attempt["child_event_window"]["basis"] == "unknown"
      assert attempt["child_event_window"]["from_seq"] == nil
      assert attempt["error_kind"] == nil
      refute Map.has_key?(attempt, "usage")
      refute Enum.any?(attempt["evidence_refs"], &String.starts_with?(&1, "e-child-"))
    end

    assert unit["usage"]["calls"] == 2
    assert projection["usage"]["calls"] == 2
    assert :ok = Validator.validate(projection)
  end

  test "complete child retains complete usage and whole-session attempt attribution", c do
    write(c, "parent", parent())
    write(c, "child", [event("child", 0, "user_message"), usage(1)])
    assert {:ok, input} = Filesystem.fetch_input("parent", c.opts)
    assert input["completeness"]["child_logs"] == "complete_through_observed_at"
    assert {:ok, projection} = Projection.project(input)
    [unit] = projection["units"]
    assert hd(unit["attempts"])["child_event_window"]["basis"] == "whole_child_log_single_attempt"
    assert projection["usage"]["complete"]
    assert projection["usage"]["calls"] == 1
    assert projection["post_terminal_child_activity"]["state"] == "none"
    assert :ok = Validator.validate(projection)
  end

  test "partial parent plus partial child keeps PR624 lineage unavailable and child evidence inspectable", c do
    write(c, "parent", [lifecycle(0, "started", "running")] ++ fillers("parent") ++ [lifecycle(101, "finished", "completed")])
    write(c, "child", oversized_child())
    assert {:ok, input} = Filesystem.fetch_input("parent", c.opts)
    assert input["inputs"]["parent_log_selection"]["partial"]
    assert input["inputs"]["child_log_selections"]["child"]["partial"]
    assert input["completeness"]["child_logs"] == "partial_prefix_tail"
    assert {:ok, projection} = Projection.project(input)
    refute projection["usage"]["complete"]
    assert projection["execution"]["state"] == "unknown"
    assert Enum.any?(projection["evidence"], &(&1["session_id"] == "child" and &1["seq"] == 102))
    assert :ok = Validator.validate(projection)
  end

  test "malformed retained child record remains unavailable, not a silently cleaned sample", c do
    write(c, "parent", parent())
    bytes = write(c, "child", oversized_child())
    corrupt = "not-json\n" <> bytes
    File.write!(Path.join(c.sessions, "child.ndjson"), corrupt)
    assert {:ok, input} = Filesystem.fetch_input("parent", c.opts)
    assert input["inputs"]["child_logs"]["child"] == nil
    assert input["inputs"]["runtime_diagnostics"] == nil
    assert input["completeness"]["child_logs"] == "explicitly_missing"
    assert {:ok, projection} = Projection.project(input)
    assert "child_log_missing" in projection["source"]["limitations"]
    refute projection["usage"]["complete"]
    assert File.read!(Path.join(c.sessions, "child.ndjson")) == corrupt
  end

  test "a child with no selectable complete record preserves the unavailable fallback", c do
    write(c, "parent", parent())
    bytes = write(c, "child", [event("child", 0, "user_message", %{"text" => String.duplicate("x", 12_000)})])
    assert {:ok, input} = Filesystem.fetch_input("parent", c.opts)
    # Core rejects this selection rather than manufacturing a successful empty
    # history; Monitor must not hide that failure behind partial metadata.
    assert input["inputs"]["child_logs"]["child"] == nil
    assert input["completeness"]["child_logs"] == "explicitly_missing"
    assert {:ok, projection} = Projection.project(input)
    refute projection["usage"]["complete"]
    assert projection["post_terminal_child_activity"]["event_count"] == nil
    assert "child_log_missing" in projection["source"]["limitations"]
    assert File.read!(Path.join(c.sessions, "child.ndjson")) == bytes
  end

  test "an explicitly empty selected sample never means a complete empty child Log", c do
    write(c, "parent", parent())
    write(c, "child", oversized_child())
    assert {:ok, input} = Filesystem.fetch_input("parent", c.opts)
    # Exercise the consumer's zero-retained boundary independently of Core's
    # current no-selectable-record rejection, without altering any Log bytes.
    input = input |> put_in(["inputs", "child_logs", "child"], []) |> put_in(["inputs", "child_log_selections", "child", "events_retained"], 0)
    assert {:ok, projection} = Projection.project(input)
    [unit] = projection["units"]
    refute unit["usage"]["complete"]
    refute Map.has_key?(hd(unit["attempts"]), "usage")
    assert unit["mutation"]["status"] == "indeterminate"
    assert projection["post_terminal_child_activity"]["event_count"] == nil
    assert projection["post_terminal_child_activity"]["state"] == "undetermined"
    refute "child_log_missing" in projection["source"]["limitations"]
    assert :ok = Validator.validate(projection)
  end

  test "retained post-terminal samples remain evidence but are not exact activity or unit usage", c do
    write(c, "parent", parent())
    later = usage(103) |> Map.put("ts", "2026-09-06T01:00:00Z")
    write(c, "child", oversized_child() ++ [later])
    assert {:ok, input} = Filesystem.fetch_input("parent", c.opts)
    assert {:ok, projection} = Projection.project(input)
    assert projection["usage"]["calls"] == 2
    assert projection["post_terminal_child_activity"]["state"] == "undetermined"
    assert projection["post_terminal_child_activity"]["event_count"] == nil
    assert projection["post_terminal_child_activity"]["evidence_refs"] != []
    assert Enum.any?(projection["limitations"], &String.starts_with?(&1, "Partial child Log activity:"))
    assert Enum.any?(projection["evidence"], &(&1["session_id"] == "child" and &1["seq"] == 103))
    assert :ok = Validator.validate(projection)
  end

  test "write calls and results on opposite sides of the gap do not prove a write", c do
    write(c, "parent", parent())

    events =
      [event("child", 0, "tool_call", %{"call_id" => "reused", "name" => "write", "args" => %{"path" => "lib/uncertain.ex"}})] ++
        fillers("child") ++ [event("child", 101, "tool_result", %{"call_id" => "reused", "ok" => true})]

    write(c, "child", events)
    assert {:ok, input} = Filesystem.fetch_input("parent", c.opts)
    assert {:ok, projection} = Projection.project(input)
    assert projection["mutation"]["observed_paths"] == []
    assert projection["mutation"]["status"] == "indeterminate"
    assert Enum.any?(projection["evidence"], &(&1["session_id"] == "child" and &1["seq"] == 0))
    assert Enum.any?(projection["evidence"], &(&1["session_id"] == "child" and &1["seq"] == 101))
    assert :ok = Validator.validate(projection)
  end

  test "a retained write denial remains positive policy evidence, not a mutation", c do
    write(c, "parent", parent())

    denial =
      event("child", 101, "permission_decision", %{
        "gate" => "write_policy",
        "decision" => "deny",
        "normalized_path" => "lib/denied.ex",
        "matched_rule" => "no_allow_match",
        "policy_id" => "p",
        "policy_hash" => "sha256:p",
        "tool" => "write"
      })

    write(c, "child", [event("child", 0, "user_message")] ++ fillers("child") ++ [denial])
    assert {:ok, input} = Filesystem.fetch_input("parent", c.opts)
    assert {:ok, projection} = Projection.project(input)
    assert projection["mutation"]["status"] == "indeterminate"
    assert [deny] = projection["mutation"]["write_denials"]
    assert deny["normalized_path"] == "lib/denied.ex"
    assert deny["evidence_refs"] != []
    assert :ok = Validator.validate(projection)
  end

  test "partial primary evidence wins over a complete mirror and missing primary retains verified fallback", c do
    write(c, "parent", parent())
    write(c, "child", oversized_child())
    assert {:ok, input} = Filesystem.fetch_input("parent", c.opts)
    mirror = %{"logs" => [%{"role" => "child", "session_id" => "child", "status" => "verified_copy", "reported_source_sha256" => "same", "reported_mirror_sha256" => "same", "events" => [usage(500)]}]}
    input = put_in(input, ["inputs", "evidence_mirror"], mirror)
    assert {:ok, partial} = Projection.project(input)
    assert partial["usage"]["calls"] == 2
    refute partial["usage"]["complete"]
    refute Enum.any?(partial["evidence"], &(&1["seq"] == 500))

    missing = input |> put_in(["inputs", "child_logs", "child"], nil) |> put_in(["completeness", "child_logs"], "complete")
    assert {:ok, from_mirror} = Projection.project(missing)
    assert from_mirror["usage"]["complete"]
    assert from_mirror["usage"]["calls"] == 1
    refute "child_log_partial" in from_mirror["source"]["limitations"]
    assert :ok = Validator.validate(from_mirror)
  end

  test "run usage counts a sampled child identity once even when multiple units reference it", c do
    other = Enum.map(parent(), fn row -> row |> Map.update!("seq", &(&1 + 2)) |> put_in(["data", "subagent_id"], "other-worker") end)
    write(c, "parent", parent() ++ other)
    write(c, "child", oversized_child())
    assert {:ok, input} = Filesystem.fetch_input("parent", c.opts)
    assert {:ok, projection} = Projection.project(input)
    assert length(projection["units"]) == 2
    assert Enum.all?(projection["units"], &(&1["usage"]["calls"] == 2 and not &1["usage"]["complete"]))
    assert projection["usage"]["calls"] == 2
    assert hd(projection["usage"]["groups"])["total_tokens"] == 20
    assert :ok = Validator.validate(projection)
  end

  test "a partial child with only queued parent lineage cannot certify zero complete usage", c do
    write(c, "parent", [lifecycle(0, "queued", "queued")])
    write(c, "child", oversized_child())
    assert {:ok, input} = Filesystem.fetch_input("parent", c.opts)
    assert {:ok, projection} = Projection.project(input)
    [unit] = projection["units"]
    assert unit["attempts"] == []
    refute unit["usage"]["complete"]
    refute projection["usage"]["complete"]
    assert projection["execution"]["state"] == "queued"
    assert :ok = Validator.validate(projection)
  end

  test "partial child bypasses Manager diagnostics and full Log folds", c do
    write(c, "parent", parent())
    write(c, "child", oversized_child())
    owner = self()
    tracer = spawn(fn -> relay_calls(owner) end)
    :erlang.trace_pattern({Pixir.Subagents, :diagnostics, 2}, true, [:local])
    :erlang.trace_pattern({Pixir.Log, :fold, 2}, true, [:local])
    :erlang.trace(self(), true, [:call, {:tracer, tracer}])

    try do
      assert {:ok, input} = Filesystem.fetch_input("parent", c.opts)
      assert input["inputs"]["runtime_diagnostics"] == nil
      refute_receive {:observed_call, {Pixir.Subagents, :diagnostics, _}}
      refute_receive {:observed_call, {Pixir.Log, :fold, _}}

      # Positive control: a complete disposable child preserves diagnostics and
      # proves that the tracer really observes this call path.
      write(c, "child", [event("child", 0, "user_message")])
      assert {:ok, complete} = Filesystem.fetch_input("parent", c.opts)
      assert is_map(complete["inputs"]["runtime_diagnostics"])
      assert_receive {:observed_call, {Pixir.Subagents, :diagnostics, _}}
    after
      :erlang.trace(self(), false, [:call])
      :erlang.trace_pattern({Pixir.Subagents, :diagnostics, 2}, false, [:local])
      :erlang.trace_pattern({Pixir.Log, :fold, 2}, false, [:local])
      send(tracer, :stop)
    end
  end

  defp relay_calls(owner) do
    receive do
      {:trace, _, :call, call} ->
        send(owner, {:observed_call, call})
        relay_calls(owner)

      :stop ->
        :ok
    end
  end

  defp parent, do: [lifecycle(0, "started", "running"), lifecycle(1, "finished", "completed")]

  defp lifecycle(seq, kind, status),
    do:
      event(
        "parent",
        seq,
        "subagent_event",
        %{"event" => kind, "status" => status, "subagent_id" => "worker", "child_session_id" => "child", "workspace_mode" => "shared", "posture" => "writer"},
        "2026-09-06T00:00:10Z"
      )

  defp event(sid, seq, type, data \\ %{}, ts \\ "2026-09-06T00:00:01Z"), do: %{"id" => "#{sid}-#{seq}", "session_id" => sid, "seq" => seq, "ts" => ts, "type" => type, "data" => data}
  defp usage(seq), do: event("child", seq, "provider_usage", %{"provider" => "test", "model" => "test-model", "usage_summary" => %{"input_tokens" => 7, "output_tokens" => 3, "total_tokens" => 10}})
  defp fillers(sid), do: Enum.map(4..100, &event(sid, &1, "user_message", %{"text" => String.duplicate("x", 400)}))

  defp oversized_child do
    [
      event("child", 0, "user_message"),
      usage(1),
      event("child", 2, "tool_call", %{"call_id" => "write-1", "name" => "write", "args" => %{"path" => "lib/retained.ex"}}),
      event("child", 3, "tool_result", %{"call_id" => "write-1", "ok" => true})
    ] ++ fillers("child") ++ [usage(101), event("child", 102, "turn_failed", %{"error_kind" => "later_failure"})]
  end

  defp write(c, sid, events) do
    bytes = Enum.map_join(events, "", &(Jason.encode!(&1) <> "\n"))
    File.write!(Path.join(c.sessions, "#{sid}.ndjson"), bytes)
    bytes
  end
end
