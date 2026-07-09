defmodule Pixir.SessionTreeTest do
  use ExUnit.Case, async: true

  alias Pixir.{Event, Fork, Log, SessionTree}

  setup do
    ws =
      Path.join(
        System.tmp_dir!(),
        "pixir-session-tree-" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
      )

    child_ws = Path.join([ws, ".pixir", "subagents", "sub_1", "workspace"])
    File.mkdir_p!(child_ws)

    on_exit(fn -> File.rm_rf!(ws) end)

    %{ws: ws, child_ws: child_ws, sid: "root", child_sid: "child-1"}
  end

  test "projects root and child Sessions from durable subagent events", %{
    ws: ws,
    child_ws: child_ws,
    sid: sid,
    child_sid: child_sid
  } do
    append!(ws, Event.user_message(sid, "start", seq: 0))

    append!(
      ws,
      Event.subagent_event(
        sid,
        %{
          "subagent_id" => "sub_1",
          "child_session_id" => child_sid,
          "event" => "started",
          "status" => "running",
          "agent" => "explorer",
          "task" => "inspect logs",
          "workspace" => child_ws,
          "index" => 7
        },
        seq: 1
      )
    )

    append!(
      ws,
      Event.subagent_event(
        sid,
        %{
          "subagent_id" => "sub_1",
          "child_session_id" => child_sid,
          "event" => "finished",
          "status" => "completed",
          "agent" => "explorer",
          "summary" => "found one child",
          "workspace" => child_ws,
          "index" => 7,
          "elapsed_ms" => 42,
          "reason" => "finished",
          "next_actions" => ["inspect_child_session_log"]
        },
        seq: 2
      )
    )

    append!(child_ws, Event.user_message(child_sid, "child start", seq: 0))
    append!(child_ws, Event.assistant_message(child_sid, "child done", seq: 1))

    assert {:ok, tree} = SessionTree.project(sid, workspace: ws)
    assert tree["session_id"] == sid
    assert tree["event_count"] == 3
    assert tree["event_counts"] == %{"subagent_event" => 2, "user_message" => 1}

    assert [subagent] = tree["subagents"]
    assert subagent["subagent_id"] == "sub_1"
    assert subagent["child_session_id"] == child_sid
    assert subagent["session_id"] == child_sid
    assert subagent["status"] == "completed"
    assert subagent["index"] == 7
    assert subagent["events"] == ["started", "finished"]
    assert subagent["summary"] == "found one child"
    assert subagent["elapsed_ms"] == 42
    assert subagent["reason"] == "finished"
    assert subagent["next_actions"] == ["inspect_child_session_log"]

    assert subagent["session"]["session_id"] == child_sid
    assert subagent["session"]["log_exists"] == true
    assert subagent["session"]["event_count"] == 2
  end

  test "represents missing child logs honestly without failing the root projection", %{
    ws: ws,
    child_ws: child_ws,
    sid: sid,
    child_sid: child_sid
  } do
    append!(
      ws,
      Event.subagent_event(
        sid,
        %{
          "subagent_id" => "sub_missing",
          "child_session_id" => child_sid,
          "event" => "started",
          "status" => "detached",
          "workspace" => child_ws
        },
        seq: 0
      )
    )

    assert {:ok, tree} = SessionTree.project(sid, workspace: ws)
    assert [subagent] = tree["subagents"]
    assert subagent["session"]["session_id"] == child_sid
    assert subagent["session"]["log_exists"] == false
    assert subagent["session"]["subagents"] == []
    assert subagent["session"]["forks"] == []
  end

  test "missing root Session is a structured not_found error", %{ws: ws} do
    assert {:error, %{ok: false, error: %{kind: :not_found, details: details}}} =
             SessionTree.project("missing", workspace: ws)

    assert details.session_id == "missing"
    assert details.log_path =~ ".pixir/sessions/missing.ndjson"
  end

  test "projects fork children discovered from session_fork lineage metadata", %{ws: ws} do
    parent = "tree-parent"
    child = "tree-child"

    append!(ws, Event.user_message(parent, "hello", seq: 0))
    append!(ws, Event.assistant_message(parent, "world", seq: 1))

    assert {:ok, _} = Fork.fork(parent, workspace: ws, child_session_id: child, to_seq: 1)

    assert {:ok, tree} = SessionTree.project(parent, workspace: ws)
    assert tree["forks"] != []

    assert [fork] = tree["forks"]
    assert fork["child_session_id"] == child
    assert fork["parent_session_id"] == parent
    assert fork["fork_root_session_id"] == parent
    assert fork["forked_to_seq"] == 1
    assert fork["replay_event_count"] == 2
    assert fork["strategy"] == "replay_v1"
    assert fork["branch_summary"] == %{"present" => false}

    assert fork["session"]["session_id"] == child
    assert fork["session"]["log_exists"] == true
    assert fork["session"]["event_counts"]["session_fork"] == 1
  end

  test "reports branch_summary presence honestly on fork children", %{ws: ws} do
    parent = "tree-parent-summary"
    child = "tree-child-summary"

    append!(ws, Event.user_message(parent, "hello", seq: 0))

    assert {:ok, _} = Fork.fork(parent, workspace: ws, child_session_id: child)

    append!(
      ws,
      Event.branch_summary(child, %{
        "summary" => "lossy fork context",
        "strategy" => "deterministic_operational_summary_v1",
        "limitations" => ["test fixture"]
      })
      |> Event.with_seq(99)
    )

    assert {:ok, tree} = SessionTree.project(parent, workspace: ws)
    assert [fork] = tree["forks"]

    assert fork["branch_summary"] == %{
             "present" => true,
             "strategy" => "deterministic_operational_summary_v1",
             "limitations" => ["test fixture"]
           }
  end

  test "render emits fork lineage in the text tree", %{ws: ws} do
    parent = "tree-parent-render"
    child = "tree-child-render"

    append!(ws, Event.user_message(parent, "hello", seq: 0))
    assert {:ok, _} = Fork.fork(parent, workspace: ws, child_session_id: child, to_seq: 0)

    assert {:ok, tree} = SessionTree.project(parent, workspace: ws)
    text = SessionTree.render(tree)

    assert text =~ "fork #{child}"
    assert text =~ "forked_to_seq=0"
    assert text =~ "fork_root: #{parent}"
    assert text =~ "branch_summary: none"
  end

  test "render emits a compact text tree", %{ws: ws, child_ws: child_ws, sid: sid} do
    append!(
      ws,
      Event.subagent_event(
        sid,
        %{
          "subagent_id" => "sub_1",
          "child_session_id" => "child-1",
          "event" => "finished",
          "status" => "completed",
          "agent" => "explorer",
          "task" => "inspect logs",
          "workspace" => child_ws,
          "index" => 2
        },
        seq: 0
      )
    )

    assert {:ok, tree} = SessionTree.project(sid, workspace: ws)
    text = SessionTree.render(tree)

    assert text =~ "session root"
    assert text =~ "subagent sub_1"
    assert text =~ "(explorer)"
    assert text =~ "child_session: child-1"
    assert text =~ "index: 2"
    assert text =~ "task: inspect logs"
  end

  defp append!(workspace, event) do
    assert {:ok, _} = Log.append(event, workspace: workspace)
  end
end
