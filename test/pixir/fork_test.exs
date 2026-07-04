defmodule Pixir.ForkTest do
  use ExUnit.Case, async: false

  alias Pixir.{Compaction, Event, Fork, Log, Session, SessionResources, SessionSupervisor}

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
end
