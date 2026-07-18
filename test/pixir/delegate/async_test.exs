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

  test "status, attach, and cancel normalize invalid Session handles without echo", %{ws: ws} do
    hostile = " valid "
    encoded_hostile = "dlg1_" <> Base.url_encode64("../../../outside;PWN", padding: false)

    for handle <- [hostile, encoded_hostile],
        command <- [&Async.status/2, &Async.attach/2, &Async.cancel/2] do
      assert {:error, %{"kind" => "invalid_args"} = error} = command.(handle, workspace: ws)
      refute inspect(error) =~ hostile
      refute inspect(error) =~ "PWN"
    end
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

  test "durable status and attach preserve task indexes independent of subagent id sorting", %{
    ws: ws,
    sid: sid
  } do
    write_raw_log(ws, sid, [
      raw_event(sid, 0, "subagent_event", %{
        "subagent_id" => "sub_a",
        "child_session_id" => "child-b",
        "event" => "started",
        "status" => "running",
        "agent" => "explorer",
        "task" => "second task",
        "workspace" => ws,
        "index" => 1
      }),
      raw_event(sid, 1, "subagent_event", %{
        "subagent_id" => "sub_z",
        "child_session_id" => "child-a",
        "event" => "started",
        "status" => "completed",
        "agent" => "explorer",
        "task" => "first task",
        "workspace" => ws,
        "index" => 0
      })
    ])

    assert {:ok, status} = Async.status(sid, workspace: ws)
    assert Enum.map(status["children"], & &1["subagent_id"]) == ["sub_z", "sub_a"]
    assert Enum.map(status["children"], & &1["index"]) == [0, 1]

    assert {:ok, attach} = Async.attach(sid, workspace: ws)
    assert Enum.map(attach["children"], & &1["index"]) == [0, 1]
  end

  test "durable ordering sorts valid indexes and preserves invalid/missing envelope order", %{
    ws: ws,
    sid: sid
  } do
    rows = [
      {"sub_missing_first", "child_missing_first", nil},
      {"sub_index_two_b", "child_b", 2},
      {"sub_invalid", "child_invalid", -1},
      {"sub_index_one", "child_one", 1},
      {"sub_index_two_a", "child_a", 2},
      {"sub_missing_last", "child_missing_last", nil}
    ]

    events =
      rows
      |> Enum.with_index()
      |> Enum.map(fn {{subagent_id, child_sid, index}, seq} ->
        data = %{
          "subagent_id" => subagent_id,
          "child_session_id" => child_sid,
          "event" => "started",
          "status" => "running",
          "agent" => "explorer",
          "task" => subagent_id,
          "workspace" => ws
        }

        data = if is_nil(index), do: data, else: Map.put(data, "index", index)
        raw_event(sid, seq, "subagent_event", data)
      end)

    write_raw_log(ws, sid, events)
    assert {:ok, status} = Async.status(sid, workspace: ws)

    assert Enum.map(status["children"], & &1["subagent_id"]) == [
             "sub_index_one",
             "sub_index_two_a",
             "sub_index_two_b",
             "sub_missing_first",
             "sub_invalid",
             "sub_missing_last"
           ]
  end

  test "durable status and attach preserve child output-truncation evidence", %{ws: ws, sid: sid} do
    warning = %{
      "kind" => "provider_output_truncated",
      "severity" => "warning",
      "child_session_id" => "child-truncated",
      "provider_usage_event_id" => "evt_child",
      "provider_usage_seq" => 4,
      "reason" => "provider_output_limit",
      "provider_reason" => "max_tokens",
      "call_role" => "final_answer"
    }

    write_raw_log(ws, sid, [
      raw_event(sid, 0, "subagent_event", %{
        "subagent_id" => "sub_truncated",
        "child_session_id" => "child-truncated",
        "event" => "finished",
        "status" => "completed",
        "agent" => "explorer",
        "task" => "inspect",
        "summary" => "exact child summary",
        "workspace" => ws,
        "output_truncation" => %{
          "status" => "truncated",
          "reason" => "provider_output_limit",
          "provider_reason" => "max_tokens",
          "provider_usage_event_id" => "evt_child",
          "provider_usage_seq" => 4,
          "call_role" => "final_answer"
        },
        "output_warning_count" => 1,
        "output_warnings" => [warning],
        "output_warnings_truncated" => false
      })
    ])

    for {:ok, payload} <- [Async.status(sid, workspace: ws), Async.attach(sid, workspace: ws)] do
      assert [child] = payload["children"]
      assert child["summary"] == "exact child summary"
      assert child["output_truncation"]["status"] == "truncated"
      assert child["output_warning_count"] == 1
      assert child["output_warnings"] == [warning]
      assert child["output_warnings_truncated"] == false
    end
  end

  test "durable ingress bounds oversized warning arrays before status and attach", %{
    ws: ws,
    sid: sid
  } do
    child_sid = "child_oversized"

    warnings =
      for seq <- 1..1_000 do
        %{
          "kind" => "provider_output_truncated",
          "severity" => "warning",
          "child_session_id" => child_sid,
          "provider_usage_event_id" => "evt_#{seq}",
          "provider_usage_seq" => seq,
          "reason" => "provider_output_limit",
          "provider_reason" => "max_tokens",
          "call_role" => "intermediate"
        }
      end

    write_raw_log(ws, sid, [
      raw_event(sid, 0, "subagent_event", %{
        "subagent_id" => "sub_oversized",
        "child_session_id" => child_sid,
        "event" => "finished",
        "status" => "completed",
        "agent" => "explorer",
        "task" => "inspect",
        "summary" => "exact",
        "workspace" => ws,
        "output_warning_count" => 1_000,
        "output_warnings" => warnings,
        "output_warning_reasons" => [
          "provider_output_limit",
          "provider_content_filter",
          "unsafe"
        ],
        "output_warnings_truncated" => true,
        "output_truncation" => %{
          "status" => "truncated",
          "reason" => "provider_output_limit",
          "provider_reason" => "max_tokens",
          "provider_usage_event_id" => "evt_invalid_role",
          "provider_usage_seq" => 1_001,
          "call_role" => "intermediate"
        }
      })
    ])

    for {:ok, payload} <- [Async.status(sid, workspace: ws), Async.attach(sid, workspace: ws)] do
      assert [child] = payload["children"]
      assert child["output_warning_count"] == 1_000
      assert length(child["output_warnings"]) == 64
      assert hd(child["output_warnings"])["provider_usage_seq"] == 1
      assert List.last(child["output_warnings"])["provider_usage_seq"] == 64
      assert child["output_warnings_truncated"]

      assert child["output_warning_reasons"] == [
               "provider_content_filter",
               "provider_output_limit"
             ]

      assert child["output_truncation"]["status"] == "unknown"
    end
  end

  test "status and attach keep the validated reason from a suppressed 65th warning", %{
    ws: ws,
    sid: sid
  } do
    child_sid = "child_reason_65"

    warnings =
      for seq <- 1..64 do
        %{
          "child_session_id" => child_sid,
          "provider_usage_event_id" => "evt_reason_#{seq}",
          "provider_usage_seq" => seq,
          "reason" => "provider_output_limit",
          "provider_reason" => "max_tokens",
          "call_role" => "intermediate"
        }
      end

    write_raw_log(ws, sid, [
      raw_event(sid, 0, "subagent_event", %{
        "subagent_id" => "sub_reason_65",
        "child_session_id" => child_sid,
        "event" => "finished",
        "status" => "completed",
        "agent" => "explorer",
        "task" => "inspect",
        "summary" => "exact",
        "workspace" => ws,
        "output_warning_count" => 65,
        "output_warnings" => warnings,
        "output_warning_reasons" => [
          "provider_output_limit",
          "provider_content_filter"
        ],
        "output_warnings_truncated" => true
      })
    ])

    for {:ok, payload} <- [Async.status(sid, workspace: ws), Async.attach(sid, workspace: ws)] do
      assert [child] = payload["children"]
      assert child["output_warning_count"] == 65
      assert length(child["output_warnings"]) == 64

      assert child["output_warning_reasons"] == [
               "provider_content_filter",
               "provider_output_limit"
             ]
    end
  end

  test "cancel payloads preserve indexes for cancelled and stale live children", %{
    ws: ws,
    sid: sid
  } do
    write_raw_log(ws, sid, [
      raw_event(sid, 0, "subagent_event", %{
        "subagent_id" => "sub_cancel",
        "child_session_id" => "child-cancel",
        "event" => "started",
        "status" => "running",
        "agent" => "explorer",
        "task" => "cancel me",
        "workspace" => ws,
        "index" => 0
      }),
      raw_event(sid, 1, "subagent_event", %{
        "subagent_id" => "sub_stale",
        "child_session_id" => "child-stale",
        "event" => "started",
        "status" => "running",
        "agent" => "explorer",
        "task" => "stale",
        "workspace" => ws,
        "index" => 1
      })
    ])

    list_subagents = fn ^sid, opts ->
      assert opts[:workspace] == ws

      {:ok,
       [
         %{
           "id" => "sub_cancel",
           "index" => 0,
           "child_session_id" => "child-cancel",
           "status" => "running",
           "agent" => "explorer",
           "task" => "cancel me"
         }
       ]}
    end

    close_subagent = fn ^sid, "sub_cancel", opts ->
      assert opts[:workspace] == ws

      {:ok,
       %{
         "id" => "sub_cancel",
         "index" => 0,
         "child_session_id" => "child-cancel",
         "status" => "cancelled",
         "agent" => "explorer",
         "task" => "cancel me"
       }}
    end

    assert {:ok, payload} =
             Async.cancel(sid,
               workspace: ws,
               list_subagents: list_subagents,
               close_subagent: close_subagent
             )

    assert [%{"subagent_id" => "sub_cancel", "index" => 0}] = payload["cancelled_children"]
    assert [%{"subagent_id" => "sub_stale", "index" => 1}] = payload["stale_live_children"]
  end

  defp append!(workspace, event) do
    assert {:ok, _} = Log.append(event, workspace: workspace)
  end
end
