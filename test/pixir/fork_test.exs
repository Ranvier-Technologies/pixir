defmodule Pixir.ForkTest do
  use ExUnit.Case, async: false

  alias Pixir.{
    Compaction,
    Event,
    Fork,
    Log,
    Paths,
    Session,
    SessionResources,
    SessionSupervisor,
    Subagents,
    Tool
  }

  alias Pixir.Subagents.WarmStart

  setup do
    ws = Path.join(System.tmp_dir!(), "pixir-fork-#{System.unique_integer([:positive])}")
    File.mkdir_p!(ws)
    on_exit(fn -> File.rm_rf!(ws) end)
    {:ok, ws: ws}
  end

  defp seed_parent(ws, _sid, events) do
    events
    |> Enum.with_index()
    |> Enum.each(fn {event, seq} ->
      assert {:ok, _} = Log.append(Event.with_seq(event, seq), workspace: ws)
    end)
  end

  test "dry_run plans full prefix and excludes provider_usage", %{ws: ws} do
    parent = "parent-1"

    seed_parent(ws, parent, [
      Event.user_message(parent, "one"),
      Event.assistant_message(parent, "two"),
      Event.provider_usage(parent, %{"usage_summary" => %{"total_tokens" => 3}}),
      Event.user_message(parent, "three")
    ])

    assert {:ok, plan} = Fork.dry_run(parent, workspace: ws, dry_run: true)

    assert plan["ok"] == true
    assert plan["recorded"] == false
    assert plan["parent_session_id"] == parent
    assert plan["to_seq"] == 3
    assert plan["event_count"] == 3
    assert plan["fork_root_session_id"] == parent
    assert plan["would_record_branch_summary"] == false
    assert plan["dry_run"] == true
    refute Log.exists?(plan["child_session_id"], workspace: ws)
    refute :history_compaction in Fork.replay_types()
  end

  test "dry_run preserves workflow_event evidence in the fork prefix", %{ws: ws} do
    parent = "parent-workflow"

    seed_parent(ws, parent, [
      Event.user_message(parent, "run workflow"),
      Event.workflow_event(parent, %{
        "kind" => "workflow_started",
        "workflow_id" => "wf",
        "workflow_name" => "Workflow"
      }),
      Event.workflow_event(parent, %{
        "kind" => "checkpoint_decided",
        "workflow_id" => "wf",
        "step_id" => "inspect",
        "checkpoint_status" => "checkpoint_ready",
        "dependent_safe" => true
      })
    ])

    assert {:ok, plan} = Fork.dry_run(parent, workspace: ws, dry_run: true)

    assert plan["event_count"] == 3
    assert :workflow_event in Fork.replay_types()

    assert {:ok, _result} = Fork.fork(parent, workspace: ws, child_session_id: "child-workflow")
    assert {:ok, history} = Log.fold("child-workflow", workspace: ws)

    assert history
           |> Enum.filter(&(&1.type == :workflow_event))
           |> Enum.map(& &1.data["kind"]) == [
             "workflow_started",
             "checkpoint_decided"
           ]
  end

  test "dry_run inherits fork_root_session_id from parent session_fork", %{ws: ws} do
    root = "root-parent"
    parent = "forked-parent"

    seed_parent(ws, parent, [
      Event.session_fork(parent, %{
        "parent_session_id" => root,
        "fork_root_session_id" => root,
        "forked_to_seq" => 5,
        "parent_workspace" => ws,
        "child_workspace" => ws,
        "replay_event_count" => 2,
        "strategy" => "replay_v1"
      }),
      Event.user_message(parent, "continued")
    ])

    assert {:ok, plan} = Fork.dry_run(parent, workspace: ws)
    assert plan["fork_root_session_id"] == root
  end

  test "fork writes child log with session_fork at seq 0 and replayed prefix", %{ws: ws} do
    parent = "parent-write"

    seed_parent(ws, parent, [
      Event.user_message(parent, "hello"),
      Event.assistant_message(parent, "world"),
      Event.tool_call(parent, "call-1", "read", %{"path" => "a.txt"})
    ])

    assert {:ok, plan} = Fork.fork(parent, workspace: ws, child_session_id: "child-fixed")
    child = plan["child_session_id"]
    assert child == "child-fixed"
    assert plan["recorded"] == true

    assert {:ok, history} = Log.fold(child, workspace: ws)

    assert [%{type: :session_fork, seq: 0, data: fork_data} | replayed] = history
    assert fork_data["parent_session_id"] == parent
    assert fork_data["fork_root_session_id"] == parent
    assert fork_data["forked_to_seq"] == 2
    assert fork_data["replay_event_count"] == 3
    assert length(replayed) == 3
    assert Enum.all?(replayed, &(&1.session_id == child))
    assert Enum.map(replayed, & &1.seq) == [1, 2, 3]

    assert {:ok, parent_history} = Log.fold(parent, workspace: ws)
    assert length(parent_history) == 3
  end

  test "forking a warm Log preserves its boundary-scoped current posture", %{ws: ws} do
    warm_parent = "parent-warm-boundary"
    seed = "seed-warm-boundary"

    seed_parent(ws, warm_parent, [
      Event.session_fork(warm_parent, %{
        "parent_session_id" => seed,
        "fork_root_session_id" => seed,
        "replay_event_count" => 2,
        "strategy" => "replay_v1",
        "source" => "delegate_warm_start"
      }),
      Event.subagent_event(warm_parent, %{
        "event" => "permission_posture",
        "scope" => "session",
        "lineage" => "root",
        "source" => "root_session_start",
        "permission_mode" => "auto",
        "write_policy" => nil,
        "workspace_mode" => "shared",
        "workspace" => ws
      }),
      Event.user_message(warm_parent, "historical seed context"),
      Event.new(warm_parent, :user_message, %{
        "text" => WarmStart.boundary_text(seed),
        "lineage_boundary" => true,
        "author" => "runtime",
        "marker_kind" => WarmStart.boundary_marker_kind(),
        "seed_session_id" => seed,
        "fork_root_session_id" => seed,
        "replay_event_count" => 2
      }),
      Event.subagent_event(warm_parent, %{
        "event" => "permission_posture",
        "scope" => "session",
        "lineage" => "child",
        "source" => "subagent_spawn",
        "subagent_id" => "sub_warm_parent",
        "parent_session_id" => "parent_of_warm_parent",
        "permission_mode" => "read_only",
        "write_policy" => nil,
        "workspace_mode" => "shared",
        "workspace" => ws,
        "warm_start" => %{
          "warm_started" => true,
          "seed_session_id" => seed,
          "fork_root_session_id" => seed,
          "replay_event_count" => 2,
          "strategy" => "replay_v1",
          "boundary_marker_kind" => WarmStart.boundary_marker_kind()
        }
      }),
      Event.user_message(warm_parent, "current warm work")
    ])

    child = "child-of-warm-boundary"
    assert {:ok, _} = Fork.fork(warm_parent, workspace: ws, child_session_id: child)
    assert {:ok, history} = Log.fold(child, workspace: ws)

    boundary_index = Enum.find_index(history, &(&1.data["lineage_boundary"] == true))
    assert is_integer(boundary_index)

    fork_proof = List.first(history).data["warm_lineage"]
    assert fork_proof["version"] == 1
    assert fork_proof["boundary_index"] == boundary_index
    assert fork_proof["posture_index"] == boundary_index + 1
    assert fork_proof["boundary_event_id"] == Enum.at(history, boundary_index).id

    posture = Enum.at(history, boundary_index + 1)
    assert %{type: :subagent_event, data: %{"event" => "permission_posture"}} = posture
    assert fork_proof["posture_event_id"] == posture.id

    assert {:ok, posture} = Subagents.resume_posture(child, workspace: ws)
    assert posture.lineage == :child
    assert posture.permission_mode == :read_only

    grandchild = "grandchild-of-warm-boundary"
    assert {:ok, _} = Fork.fork(child, workspace: ws, child_session_id: grandchild)
    assert {:ok, grandchild_history} = Log.fold(grandchild, workspace: ws)

    grandchild_boundary_index =
      Enum.find_index(grandchild_history, &(&1.data["lineage_boundary"] == true))

    assert is_integer(grandchild_boundary_index)
    grandchild_proof = List.first(grandchild_history).data["warm_lineage"]
    assert grandchild_proof["boundary_index"] == grandchild_boundary_index
    assert grandchild_proof["posture_index"] == grandchild_boundary_index + 1

    assert grandchild_proof["boundary_event_id"] ==
             Enum.at(grandchild_history, grandchild_boundary_index).id

    assert grandchild_proof["posture_event_id"] ==
             Enum.at(grandchild_history, grandchild_boundary_index + 1).id

    refute grandchild_proof["boundary_event_id"] == fork_proof["boundary_event_id"]
    refute grandchild_proof["posture_event_id"] == fork_proof["posture_event_id"]

    assert {:ok, grandchild_posture} = Subagents.resume_posture(grandchild, workspace: ws)
    assert grandchild_posture.lineage == :child
    assert grandchild_posture.permission_mode == :read_only

    truncated_child = "child-of-warm-boundary-truncated"

    assert {:ok, _} =
             Fork.fork(warm_parent,
               workspace: ws,
               child_session_id: truncated_child,
               to_seq: 3
             )

    assert {:ok, truncated_history} = Log.fold(truncated_child, workspace: ws)
    truncated_proof = List.first(truncated_history).data["warm_lineage"]
    assert truncated_proof["boundary_event_id"] == Enum.at(truncated_history, 3).id
    assert truncated_proof["posture_event_id"] == nil

    assert {:error, %{error: %{kind: :resume_policy_unavailable, details: details}}} =
             Subagents.resume_posture(truncated_child, workspace: ws)

    assert details["reason"] == "missing_current_posture"

    forged_posture =
      truncated_child
      |> Event.subagent_event(Enum.at(history, boundary_index + 1).data, id: nil)
      |> Event.with_seq(4)

    assert forged_posture.id == nil
    assert {:ok, _} = Log.append(forged_posture, workspace: ws)

    assert {:error, %{error: %{kind: :resume_policy_unavailable, details: forged_details}}} =
             Subagents.resume_posture(truncated_child, workspace: ws)

    assert forged_details["reason"] == "missing_current_posture"

    boundary_only_grandchild = "grandchild-of-warm-boundary-truncated"

    assert {:ok, _} =
             Fork.fork(truncated_child,
               workspace: ws,
               child_session_id: boundary_only_grandchild
             )

    assert {:ok, boundary_only_history} = Log.fold(boundary_only_grandchild, workspace: ws)
    boundary_only_proof = List.first(boundary_only_history).data["warm_lineage"]

    boundary_only_index =
      Enum.find_index(boundary_only_history, &(&1.data["lineage_boundary"] == true))

    assert is_integer(boundary_only_index)
    assert boundary_only_proof["boundary_index"] == boundary_only_index
    assert boundary_only_proof["posture_index"] == boundary_only_index + 1

    assert boundary_only_proof["boundary_event_id"] ==
             Enum.at(boundary_only_history, boundary_only_index).id

    assert boundary_only_proof["posture_event_id"] == nil

    assert {:error, %{error: %{kind: :resume_policy_unavailable, details: inherited_details}}} =
             Subagents.resume_posture(boundary_only_grandchild, workspace: ws)

    assert inherited_details["reason"] == "missing_current_posture"
  end

  test "fork respects --to-seq boundary", %{ws: ws} do
    parent = "parent-boundary"

    seed_parent(ws, parent, [
      Event.user_message(parent, "one"),
      Event.assistant_message(parent, "two"),
      Event.user_message(parent, "three")
    ])

    assert {:ok, plan} =
             Fork.fork(parent, workspace: ws, to_seq: 1, child_session_id: "child-boundary")

    assert plan["event_count"] == 2
    assert {:ok, history} = Log.fold("child-boundary", workspace: ws)
    assert length(history) == 3
    assert Enum.at(history, 2).data["text"] == "two"
  end

  test "child Session loads fork_root_session_id from session_fork on init", %{ws: ws} do
    root = "cache-root"
    parent = "cache-parent"

    seed_parent(ws, root, [
      Event.user_message(root, "root"),
      Event.assistant_message(root, "ok")
    ])

    assert {:ok, _} =
             Fork.fork(root, workspace: ws, child_session_id: parent, to_seq: 1)

    {:ok, child_sid, child_pid} =
      SessionSupervisor.start_session(id: parent, workspace: ws, role: :build)

    on_exit(fn ->
      if Process.alive?(child_pid),
        do: DynamicSupervisor.terminate_child(SessionSupervisor, child_pid)
    end)

    assert %{fork_root_session_id: ^root} = Session.info(child_sid)
  end

  test "fork excludes history_compaction and provider_history keeps replayed tail", %{ws: ws} do
    parent = "parent-compaction"

    seed_parent(ws, parent, [
      Event.user_message(parent, "old"),
      Event.assistant_message(parent, "older"),
      Event.history_compaction(parent, %{
        "range" => %{"from_seq" => 0, "to_seq" => 1},
        "summary" => "old summary",
        "strategy" => "deterministic_operational_summary_v1",
        "source_event_count" => 2,
        "tail_event_count" => 1
      }),
      Event.user_message(parent, "recent"),
      Event.provider_usage(parent, %{"usage_summary" => %{"total_tokens" => 3}})
    ])

    assert {:ok, plan} = Fork.dry_run(parent, workspace: ws)
    assert plan["event_count"] == 3
    assert plan["to_seq"] == 3

    assert {:ok, _} =
             Fork.fork(parent, workspace: ws, child_session_id: "child-compaction")

    assert {:ok, history} = Log.fold("child-compaction", workspace: ws)
    refute Enum.any?(history, &(&1.type == :history_compaction))

    assert Enum.any?(history, fn event ->
             event.type == :user_message and event.data["text"] == "recent"
           end)

    assert Enum.any?(Compaction.provider_history(history), fn event ->
             event.type == :user_message and event.data["text"] == "recent"
           end)
  end

  test "fork copies referenced session resource payloads into the child store", %{ws: ws} do
    parent = "parent-resources"
    child = "child-resources"
    bytes = "payload bytes"
    encoded = Base.encode64(bytes)

    {:ok, [descriptor]} =
      SessionResources.ingest_attachments(
        parent,
        [
          %{
            "type" => "image",
            "name" => "screen.png",
            "mimeType" => "image/png",
            "dataUrl" => "data:image/png;base64,#{encoded}"
          }
        ],
        workspace: ws
      )

    seed_parent(ws, parent, [
      Event.user_message(parent, "inspect this", resources: [descriptor]),
      Event.assistant_message(parent, "ok")
    ])

    assert {:ok, _} = Fork.fork(parent, workspace: ws, child_session_id: child)

    assert {:ok, data_url} = SessionResources.data_url(child, descriptor, workspace: ws)
    assert data_url == "data:image/png;base64,#{encoded}"

    assert {:ok, child_history} = Log.fold(child, workspace: ws)
    replayed_message = Enum.find(child_history, &(&1.data["text"] == "inspect this"))
    assert replayed_message.data["resources"] == [descriptor]

    [replayed_descriptor] = replayed_message.data["resources"]
    assert replayed_descriptor["store_ref"] =~ "session://#{parent}/resources/"
  end

  test "fork compensates a partial resource copy at a deterministic failpoint", %{ws: ws} do
    parent = "parent-resource-copy-failure"
    child = "child-resource-copy-failure"

    {:ok, descriptors} =
      SessionResources.ingest_attachments(
        parent,
        Enum.map(["first", "second"], fn bytes ->
          %{
            "type" => "image",
            "name" => "#{bytes}.png",
            "mimeType" => "image/png",
            "dataUrl" => "data:image/png;base64,#{Base.encode64(bytes)}"
          }
        end),
        workspace: ws
      )

    [first, _second] = descriptors

    seed_parent(ws, parent, [
      Event.user_message(parent, "inspect both", resources: descriptors)
    ])

    fail_second_copy = fn
      %{index: 1} -> {:error, :injected_copy_failure}
      %{index: 0} -> :ok
    end

    assert {:error, %{error: %{kind: :write_failed}}} =
             Fork.fork(parent,
               workspace: ws,
               child_session_id: child,
               resource_copy_failpoint: fail_second_copy
             )

    {:ok, copied_path} = SessionResources.resource_path(child, first, ws)
    refute File.exists?(copied_path)
    assert_child_resource_dirs_absent(ws, child)
    assert {:ok, false} = Log.exists(child, workspace: ws)
  end

  test "fork compensates finalized resources when child Log creation returns an error", %{
    ws: ws
  } do
    parent = "parent-resource-log-failure"
    child = "child-resource-log-failure"
    bytes = "bytes finalized before Log creation"

    {:ok, [descriptor]} =
      SessionResources.ingest_attachments(
        parent,
        [
          %{
            "type" => "image",
            "name" => "finalized.png",
            "mimeType" => "image/png",
            "dataUrl" => "data:image/png;base64,#{Base.encode64(bytes)}"
          }
        ],
        workspace: ws
      )

    seed_parent(ws, parent, [
      Event.user_message(parent, "inspect", resources: [descriptor])
    ])

    test_pid = self()

    log_create_failpoint = fn ^child, _events, log_opts ->
      final = Paths.session_resources_dir(child, Keyword.fetch!(log_opts, :workspace))
      send(test_pid, {:log_create_saw_final_resources, File.dir?(final)})
      {:error, Tool.error(:log_write_failed, "injected Log.create_session failure", %{})}
    end

    assert {:error, %{error: %{kind: :log_write_failed}}} =
             Fork.fork(parent,
               workspace: ws,
               child_session_id: child,
               log_create_fun: log_create_failpoint
             )

    assert_received {:log_create_saw_final_resources, true}
    assert_child_resource_dirs_absent(ws, child)
    assert {:ok, false} = Log.exists(child, workspace: ws)
  end

  test "plan rejects non-binary parent_session_id", %{ws: ws} do
    assert {:error, %{ok: false, error: %{kind: :invalid_args}}} =
             Fork.plan(123, workspace: ws)
  end

  test "dry_run with summarize reports branch summary plan fields", %{ws: ws} do
    parent = "parent-sum-plan"

    seed_parent(ws, parent, [
      Event.user_message(parent, "hi"),
      Event.assistant_message(parent, "hello")
    ])

    assert {:ok, plan} = Fork.dry_run(parent, workspace: ws, summarize: true)

    assert plan["would_record_branch_summary"] == true
    assert plan["branch_summary_strategy"] == "deterministic_operational_summary_v1"
    refute Log.exists?(plan["child_session_id"], workspace: ws)
  end

  test "fork with --summarize records branch_summary after replayed prefix", %{ws: ws} do
    parent = "parent-sum-write"

    seed_parent(ws, parent, [
      Event.user_message(parent, "one"),
      Event.assistant_message(parent, "two"),
      Event.tool_call(parent, "call-1", "read", %{"path" => "a.txt"})
    ])

    assert {:ok, plan} =
             Fork.fork(parent, workspace: ws, summarize: true, child_session_id: "child-sum")

    assert plan["would_record_branch_summary"] == true
    assert {:ok, history} = Log.fold("child-sum", workspace: ws)

    assert [%{type: :session_fork, seq: 0} | rest] = history
    assert length(rest) == 4

    assert [
             %{type: :user_message, seq: 1},
             %{type: :assistant_message, seq: 2},
             %{type: :tool_call, seq: 3},
             %{type: :branch_summary, seq: 4, data: summary_data}
           ] = rest

    assert summary_data["strategy"] == "deterministic_operational_summary_v1"
    assert summary_data["parent_session_id"] == parent
    assert summary_data["forked_to_seq"] == 2
    assert summary_data["source_event_count"] == 3
    assert summary_data["summary"] =~ "Forked 3 replayed events"
    assert summary_data["limitations"] != []
  end

  defp assert_child_resource_dirs_absent(workspace, child_session_id) do
    final = Paths.session_resources_dir(child_session_id, workspace)
    refute File.exists?(final)
    assert Path.wildcard(final <> ".staging*") == []
  end
end
