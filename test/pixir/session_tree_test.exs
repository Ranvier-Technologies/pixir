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

  test "a child's own start failure is counted without inventing a descendant", %{
    ws: ws,
    child_sid: child_sid
  } do
    append!(
      ws,
      Event.subagent_event(
        child_sid,
        %{
          "event" => "child_start_failed",
          "lineage" => "child",
          "scope" => "session",
          "source" => "subagent_start",
          "status" => "failed",
          "subagent_id" => "sub_1",
          "parent_session_id" => "root",
          "child_session_id" => child_sid
        },
        seq: 0
      )
    )

    assert {:ok, tree} = SessionTree.project(child_sid, workspace: ws)
    assert tree["event_count"] == 1
    assert tree["subagents"] == []
  end

  test "permission posture stays counted without creating phantom descendants", %{
    ws: ws,
    child_ws: child_ws,
    sid: sid,
    child_sid: child_sid
  } do
    parent_events = [
      raw_event(sid, 0, "subagent_event", permission_posture("sub_parent", "upstream", ws)),
      raw_event(sid, 1, "subagent_event", %{
        "event" => "started",
        "subagent_id" => "sub_1",
        "child_session_id" => child_sid,
        "status" => "running",
        "workspace" => child_ws
      }),
      raw_event(sid, 2, "subagent_event", %{
        "event" => "finished",
        "subagent_id" => "sub_1",
        "child_session_id" => child_sid,
        "status" => "completed",
        "workspace" => child_ws
      })
    ]

    child_events = [
      raw_event(child_sid, 0, "subagent_event", permission_posture("sub_1", sid, child_ws)),
      raw_event(child_sid, 1, "assistant_message", %{"text" => "done"})
    ]

    parent_body = write_raw_log(ws, sid, parent_events)
    child_body = write_raw_log(child_ws, child_sid, child_events)

    assert {:ok, tree} = SessionTree.project(sid, workspace: ws)
    assert [%{"subagent_id" => "sub_1"} = child] = tree["subagents"]
    assert child["events"] == ["started", "finished"]
    assert child["status"] == "completed"
    assert child["session"]["subagents"] == []
    assert tree["event_count"] == 3
    assert tree["event_counts"] == %{"subagent_event" => 3}
    assert child["session"]["event_count"] == 2
    assert child["session"]["event_counts"] == %{"subagent_event" => 1, "assistant_message" => 1}
    assert File.read!(Log.path(sid, workspace: ws)) == parent_body
    assert File.read!(Log.path(child_sid, workspace: child_ws)) == child_body

    # A later projection must still see a genuine nested lifecycle, even when
    # its parent and child Logs also contain their own permission posture.
    grandchild_sid = "grandchild"
    grandchild_ws = Path.join(child_ws, "nested")

    write_raw_log(
      child_ws,
      child_sid,
      child_events ++
        [
          raw_event(child_sid, 2, "subagent_event", %{
            "event" => "started",
            "subagent_id" => "sub_nested",
            "child_session_id" => grandchild_sid,
            "status" => "running",
            "workspace" => grandchild_ws
          })
        ]
    )

    write_raw_log(grandchild_ws, grandchild_sid, [
      raw_event(
        grandchild_sid,
        0,
        "subagent_event",
        permission_posture("sub_nested", child_sid, grandchild_ws)
      )
    ])

    assert {:ok, updated} = SessionTree.project(sid, workspace: ws)
    assert [child] = updated["subagents"]
    assert [grandchild] = child["session"]["subagents"]
    assert grandchild["subagent_id"] == "sub_nested"
    assert grandchild["child_session_id"] == grandchild_sid
    assert grandchild["status"] == "running"
    assert grandchild["session"]["log_exists"] == true
    assert grandchild["session"]["subagents"] == []
    assert grandchild["session"]["event_counts"] == %{"subagent_event" => 1}
  end

  test "child cancellation evidence does not project a self-descendant cycle", %{
    ws: ws,
    child_ws: child_ws,
    sid: sid,
    child_sid: child_sid
  } do
    parent_body =
      write_raw_log(ws, sid, [
        raw_event(sid, 0, "subagent_event", %{
          "event" => "cancelled",
          "subagent_id" => "sub_1",
          "child_session_id" => child_sid,
          "status" => "cancelled",
          "workspace" => child_ws
        })
      ])

    child_body =
      write_raw_log(child_ws, child_sid, [
        raw_event(child_sid, 0, "subagent_event", %{
          "event" => "cancelled_by_parent",
          "lineage" => "child",
          "subagent_id" => "sub_1",
          "child_session_id" => child_sid,
          "parent_session_id" => sid,
          "status" => "cancelled",
          "workspace" => child_ws
        })
      ])

    assert {:ok, tree} = SessionTree.project(sid, workspace: ws)
    assert [child] = tree["subagents"]
    assert child["subagent_id"] == "sub_1"
    assert child["events"] == ["cancelled"]
    assert child["status"] == "cancelled"
    assert child["session"]["subagents"] == []
    refute child["session"]["cycle"]
    assert child["session"]["event_count"] == 1
    assert child["session"]["event_counts"] == %{"subagent_event" => 1}
    assert File.read!(Log.path(sid, workspace: ws)) == parent_body
    assert File.read!(Log.path(child_sid, workspace: child_ws)) == child_body
  end

  test "horizon override metadata stays counted without creating a child", %{ws: ws, sid: sid} do
    body =
      write_raw_log(ws, sid, [
        raw_event(sid, 0, "subagent_event", %{
          "event" => "horizon_override",
          "subagent_id" => "sub_self",
          "workspace" => ws
        })
      ])

    assert {:ok, tree} = SessionTree.project(sid, workspace: ws)
    assert tree["subagents"] == []
    assert tree["event_count"] == 1
    assert tree["event_counts"] == %{"subagent_event" => 1}
    assert File.read!(Log.path(sid, workspace: ws)) == body
  end

  test "non-child cancellation and unknown child-lineage events remain visible", %{
    ws: ws,
    sid: sid
  } do
    write_raw_log(ws, sid, [
      raw_event(sid, 0, "subagent_event", %{
        "event" => "cancelled_by_parent",
        "lineage" => "parent",
        "subagent_id" => "sub_parent_lineage"
      }),
      raw_event(sid, 1, "subagent_event", %{
        "event" => "cancelled_by_parent",
        "subagent_id" => "sub_absent_lineage"
      }),
      raw_event(sid, 2, "subagent_event", %{
        "event" => "cancelled_by_parent",
        "lineage" => nil,
        "subagent_id" => "sub_null_lineage"
      }),
      raw_event(sid, 3, "subagent_event", %{
        "event" => "future_event",
        "lineage" => "child",
        "subagent_id" => "sub_unknown"
      })
    ])

    assert {:ok, tree} = SessionTree.project(sid, workspace: ws)

    assert Enum.map(tree["subagents"], &{&1["subagent_id"], &1["events"]}) == [
             {"sub_parent_lineage", ["cancelled_by_parent"]},
             {"sub_absent_lineage", ["cancelled_by_parent"]},
             {"sub_null_lineage", ["cancelled_by_parent"]},
             {"sub_unknown", ["future_event"]}
           ]

    assert Enum.all?(tree["subagents"], &is_nil(&1["session"]))
  end

  test "keeps queued, incomplete started, and unknown events without child Session ids", %{
    ws: ws,
    sid: sid
  } do
    write_raw_log(ws, sid, [
      raw_event(sid, 0, "subagent_event", %{
        "event" => "queued",
        "subagent_id" => "sub_queued",
        "status" => "queued"
      }),
      raw_event(sid, 1, "subagent_event", %{
        "event" => "started",
        "subagent_id" => "sub_incomplete"
      }),
      raw_event(sid, 2, "subagent_event", %{
        "event" => "future_event",
        "scope" => "session",
        "subagent_id" => "sub_unknown"
      })
    ])

    assert {:ok, tree} = SessionTree.project(sid, workspace: ws)
    assert [queued, incomplete, unknown] = tree["subagents"]
    assert queued["subagent_id"] == "sub_queued"
    assert queued["events"] == ["queued"]
    assert queued["status"] == "queued"
    assert incomplete["subagent_id"] == "sub_incomplete"
    assert incomplete["events"] == ["started"]
    assert unknown["subagent_id"] == "sub_unknown"
    assert unknown["events"] == ["future_event"]
    assert Enum.all?(tree["subagents"], &is_nil(&1["session"]))
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

  test "refuses hostile child Session ids from durable events before recursion", %{
    ws: ws,
    child_ws: child_ws,
    sid: sid
  } do
    hostile = "../../../outside/tree-child;PWN"

    append!(
      ws,
      Event.subagent_event(
        sid,
        %{
          "subagent_id" => "sub_hostile",
          "child_session_id" => hostile,
          "event" => "started",
          "status" => "detached",
          "workspace" => child_ws
        },
        seq: 0
      )
    )

    assert {:error, %{error: %{kind: :invalid_args}} = error} =
             SessionTree.project(sid, workspace: ws)

    refute inspect(error) =~ hostile
    refute File.exists?(Path.join(ws, "outside"))
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

  defp permission_posture(subagent_id, parent_session_id, workspace) do
    %{
      "event" => "permission_posture",
      "scope" => "session",
      "lineage" => "child",
      "source" => "subagent_spawn",
      "subagent_id" => subagent_id,
      "parent_session_id" => parent_session_id,
      "permission_mode" => "read_only",
      "write_policy" => nil,
      "workspace_mode" => "isolated",
      "workspace" => workspace,
      "warm_start" => nil
    }
  end

  defp write_raw_log(workspace, sid, events) do
    path = Log.path(sid, workspace: workspace)
    File.mkdir_p!(Path.dirname(path))
    body = Enum.map_join(events, "", &(Jason.encode!(&1) <> "\n"))
    File.write!(path, body)
    body
  end

  defp raw_event(sid, seq, type, data) do
    %{
      "id" => "#{sid}-#{seq}",
      "session_id" => sid,
      "seq" => seq,
      "ts" => "2026-09-05T00:00:00Z",
      "type" => type,
      "data" => data
    }
  end

  defp append!(workspace, event) do
    assert {:ok, _} = Log.append(event, workspace: workspace)
  end
end
