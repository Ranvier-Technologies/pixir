defmodule Pixir.Delegate.AsyncTest do
  use ExUnit.Case, async: true

  import Pixir.Test.RawLogHelpers

  alias Pixir.{Delegate.Async, Event, Log}
  alias Pixir.Delegate.Handle

  setup do
    ws =
      Path.join(
        System.tmp_dir!(),
        "pixir-delegate-async-" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
      )

    File.mkdir_p!(ws)
    on_exit(fn -> File.rm_rf!(ws) end)

    %{ws: ws, sid: "delegate-async-parent"}
  end

  test "cancel closes only active Manager children and keeps host boundary zero", %{
    ws: ws,
    sid: sid
  } do
    append!(
      ws,
      Event.subagent_event(
        sid,
        %{
          "subagent_id" => "sub_live",
          "child_session_id" => "child-live",
          "event" => "started",
          "status" => "running",
          "agent" => "explorer",
          "task" => "inspect",
          "workspace" => ws
        },
        seq: 0
      )
    )

    list_subagents = fn ^sid, opts ->
      assert opts[:workspace] == ws

      {:ok,
       [
         %{
           "id" => "sub_live",
           "child_session_id" => "child-live",
           "status" => "running",
           "agent" => "explorer",
           "task" => "inspect"
         }
       ]}
    end

    close_subagent = fn ^sid, "sub_live", opts ->
      assert opts[:workspace] == ws

      {:ok,
       %{
         "id" => "sub_live",
         "child_session_id" => "child-live",
         "status" => "cancelled",
         "agent" => "explorer",
         "task" => "inspect",
         "summary" => "cancelled"
       }}
    end

    assert {:ok,
            %{
              "ok" => true,
              "status" => "cancelled",
              "kind" => "delegate_cancel",
              "service_state" => "live_manager_handles",
              "owner" => %{"state" => "live_manager_handles", "reachable" => true},
              "cancelled_child_count" => 1,
              "durable_status_before" => "running",
              "cancelled_children" => [%{"subagent_id" => "sub_live", "status" => "cancelled"}],
              "host_boundary" => %{
                "external_process_spawns" => 0,
                "shell_polling" => false
              }
            }} =
             Async.cancel(sid,
               workspace: ws,
               list_subagents: list_subagents,
               close_subagent: close_subagent
             )
  end

  test "status accepts a delegate_id handle and keeps parent session id visible", %{
    ws: ws,
    sid: sid
  } do
    write_raw_log(ws, sid, [
      raw_event(sid, 0, "subagent_event", %{
        "subagent_id" => "sub_done",
        "child_session_id" => "child-done",
        "event" => "finished",
        "status" => "completed",
        "agent" => "explorer",
        "task" => "inspect",
        "workspace" => ws
      })
    ])

    assert {:ok, %{"delegate_id" => delegate_id}} = Handle.build(sid)

    assert {:ok,
            %{
              "ok" => true,
              "status" => "completed",
              "kind" => "delegate_status",
              "delegate_id" => ^delegate_id,
              "parent_session_id" => ^sid,
              "session_id" => ^sid,
              "handle" => %{"input_kind" => "delegate_id"},
              "owner" => %{"state" => "snapshot_only", "reachable" => false},
              "service_state" => "snapshot_only"
            }} = Async.status(delegate_id, workspace: ws)
  end

  test "status distinguishes stale durable running children from completed status", %{
    ws: ws,
    sid: sid
  } do
    write_raw_log(ws, sid, [
      raw_event(
        sid,
        0,
        "subagent_event",
        %{
          "subagent_id" => "sub_stale",
          "child_session_id" => "child-stale",
          "event" => "started",
          "status" => "running",
          "agent" => "explorer",
          "task" => "inspect",
          "workspace" => ws
        }
      )
    ])

    assert {:ok,
            %{
              "ok" => false,
              "status" => "running",
              "kind" => "delegate_status",
              "service_state" => "snapshot_only",
              "counts" => %{"active" => 1, "running" => 1, "total" => 1},
              "retry_after_ms" => retry_after_ms,
              "next_actions" => next_actions
            }} = Async.status(sid, workspace: ws)

    assert retry_after_ms > 0
    assert "check_status_later_with_backoff" in next_actions
  end

  test "attach returns a bounded durable snapshot without Manager or host execution", %{
    ws: ws,
    sid: sid
  } do
    write_raw_log(ws, sid, [
      raw_event(sid, 0, "subagent_event", %{
        "subagent_id" => "sub_running",
        "child_session_id" => "child-running",
        "event" => "started",
        "status" => "running",
        "agent" => "explorer",
        "task" => "inspect",
        "workspace" => ws
      })
    ])

    assert {:ok, %{"delegate_id" => delegate_id}} = Handle.build(sid)

    assert {:ok,
            %{
              "ok" => true,
              "status" => "running",
              "kind" => "delegate_attach",
              "delegate_id" => ^delegate_id,
              "parent_session_id" => ^sid,
              "handle" => %{"input_kind" => "delegate_id"},
              "service_state" => "snapshot_only",
              "complete" => false,
              "attach" => %{
                "mode" => "one_shot_snapshot",
                "streaming" => false,
                "source" => "durable_session_log",
                "service_state" => "snapshot_only"
              },
              "host_boundary" => %{
                "external_process_spawns" => 0,
                "shell_polling" => false
              },
              "next_actions" => next_actions
            }} = Async.attach(delegate_id, workspace: ws)

    assert "check_status_later_with_backoff" in next_actions
  end

  test "cancel reports stale durable running child when Manager has no handle", %{
    ws: ws,
    sid: sid
  } do
    write_raw_log(ws, sid, [
      raw_event(sid, 0, "subagent_event", %{
        "subagent_id" => "sub_stale",
        "child_session_id" => "child-stale",
        "event" => "started",
        "status" => "running",
        "agent" => "explorer",
        "task" => "inspect",
        "workspace" => ws
      })
    ])

    assert {:ok, %{"delegate_id" => delegate_id}} = Handle.build(sid)

    list_subagents = fn ^sid, opts ->
      assert opts[:workspace] == ws
      {:ok, []}
    end

    close_subagent = fn _sid, _id, _opts -> flunk("stale child must not be closed") end

    assert {:ok,
            %{
              "ok" => false,
              "status" => "partial",
              "kind" => "delegate_cancel",
              "delegate_id" => ^delegate_id,
              "parent_session_id" => ^sid,
              "handle" => %{"input_kind" => "delegate_id"},
              "service_state" => "stale_handle",
              "owner" => %{"state" => "stale_handle", "reachable" => false},
              "cancelled_child_count" => 0,
              "manager_child_counts_before" => %{"total" => 0},
              "stale_live_children" => [%{"subagent_id" => "sub_stale", "status" => "running"}],
              "errors" => [%{"kind" => "stale_handle"}]
            }} =
             Async.cancel(delegate_id,
               workspace: ws,
               list_subagents: list_subagents,
               close_subagent: close_subagent
             )
  end

  test "cancel catches Manager close exits and reports partial with terminal children", %{
    ws: ws,
    sid: sid
  } do
    append!(
      ws,
      Event.subagent_event(
        sid,
        %{
          "subagent_id" => "sub_live",
          "child_session_id" => "child-live",
          "event" => "started",
          "status" => "running",
          "agent" => "explorer",
          "task" => "inspect",
          "workspace" => ws
        },
        seq: 0
      )
    )

    append!(
      ws,
      Event.subagent_event(
        sid,
        %{
          "subagent_id" => "sub_done",
          "child_session_id" => "child-done",
          "event" => "finished",
          "status" => "completed",
          "agent" => "explorer",
          "task" => "already done",
          "workspace" => ws
        },
        seq: 1
      )
    )

    list_subagents = fn ^sid, opts ->
      assert opts[:workspace] == ws

      {:ok,
       [
         %{"id" => "sub_live", "status" => "running", "child_session_id" => "child-live"},
         %{"id" => "sub_done", "status" => "completed", "child_session_id" => "child-done"}
       ]}
    end

    close_subagent = fn ^sid, "sub_live", opts ->
      assert opts[:workspace] == ws
      exit({:timeout, {GenServer, :call, []}})
    end

    assert {:ok,
            %{
              "ok" => false,
              "status" => "partial",
              "kind" => "delegate_cancel",
              "service_state" => "live_manager_handles",
              "owner" => %{"state" => "live_manager_handles", "reachable" => true},
              "cancelled_child_count" => 0,
              "manager_child_counts_before" => %{"running" => 1, "completed" => 1},
              "not_cancellable_children" => [%{"subagent_id" => "sub_done"}],
              "errors" => [%{"kind" => "timeout"}]
            }} =
             Async.cancel(sid,
               workspace: ws,
               list_subagents: list_subagents,
               close_subagent: close_subagent
             )
  end

  defp append!(workspace, event) do
    assert {:ok, _} = Log.append(event, workspace: workspace)
  end
end
