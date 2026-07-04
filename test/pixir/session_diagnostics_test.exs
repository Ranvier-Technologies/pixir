defmodule Pixir.SessionDiagnosticsTest do
  use ExUnit.Case, async: false

  alias Pixir.{Event, Log, SessionDiagnostics}

  test "reports a ready session with paired tools and replay" do
    ws = tmp_ws()
    sid = "diagnose-ready"

    append_all(ws, sid, [
      Event.user_message(sid, "run"),
      Event.tool_call(sid, "call_ok", "bash", %{"command" => "pwd"}),
      Event.tool_result(sid, "call_ok", %{"ok" => true, "output" => "/tmp"}),
      Event.provider_usage(sid, %{
        "model" => "gpt-5.5",
        "active_transport" => "websocket",
        "continuation_attempted" => true,
        "continuation_reset_reason" => nil,
        "used_previous_response_id" => true,
        "usage_summary" => %{"total_tokens" => 42}
      }),
      Event.assistant_message(sid, "done")
    ])

    on_exit(fn -> File.rm_rf!(ws) end)

    assert {:ok, result} = SessionDiagnostics.run(sid, workspace: ws)
    assert result["ok"] == true
    assert result["status"] == "ready"
    assert result["replay"]["balanced"] == true
    assert result["provider_usage"]["count"] == 1
    assert result["provider_usage"]["latest"]["active_transport"] == "websocket"
  end

  test "warns when provider replay needs a synthetic orphan closure" do
    ws = tmp_ws()
    sid = "diagnose-orphan"

    append_all(ws, sid, [
      Event.user_message(sid, "run"),
      Event.tool_call(sid, "call_orphan", "bash", %{"command" => "grep x"}),
      Event.tool_result(sid, "call_orphan", %{
        "ok" => false,
        "error" => %{
          "kind" => "orphan_tool_call",
          "message" => "Pixir reconciled a tool_call that had no persisted tool_result",
          "details" => %{"call_id" => "call_orphan", "tool" => "bash"}
        }
      }),
      Event.user_message(sid, "continue")
    ])

    on_exit(fn -> File.rm_rf!(ws) end)

    assert {:ok, result} = SessionDiagnostics.run(sid, workspace: ws)
    assert result["ok"] == true
    assert result["status"] == "ready_with_warnings"

    assert %{"status" => "warning"} =
             Enum.find(result["checks"], &(&1["id"] == "provider_replay"))
  end

  test "warns when a tool-active turn has no assistant message before the next user turn" do
    ws = tmp_ws()
    sid = "diagnose-missing-assistant"

    append_all(ws, sid, [
      Event.user_message(sid, "run"),
      Event.tool_call(sid, "call_ok", "bash", %{"command" => "pwd"}),
      Event.tool_result(sid, "call_ok", %{"ok" => true, "output" => "/tmp"}),
      Event.provider_usage(sid, %{
        "model" => "gpt-5.5",
        "active_transport" => "websocket",
        "continuation_attempted" => true,
        "continuation_reset_reason" => nil,
        "used_previous_response_id" => true,
        "usage_summary" => %{"total_tokens" => 42}
      }),
      Event.user_message(sid, "are you there?")
    ])

    on_exit(fn -> File.rm_rf!(ws) end)

    assert {:ok, result} = SessionDiagnostics.run(sid, workspace: ws)
    assert result["ok"] == true
    assert result["status"] == "ready_with_warnings"

    assert %{"status" => "warning", "details" => %{"turns" => [turn]}} =
             Enum.find(result["checks"], &(&1["id"] == "turn_completion"))

    assert turn["user_seq"] == 0
    assert turn["next_user_seq"] == 4
    assert turn["tool_calls"] == 1
    assert turn["tool_results"] == 1
    assert turn["provider_calls"] == 1
  end

  test "warns when parent wait_agent results lack structured or repaired outcomes" do
    ws = tmp_ws()
    sid = "diagnose-parent-wait"

    append_all(ws, sid, [
      Event.user_message(sid, "wait for children"),
      Event.tool_call(sid, "call_wait_legacy", "wait_agent", %{"ids" => ["sub_1"]}),
      Event.tool_result(sid, "call_wait_legacy", %{
        "ok" => true,
        "output" => "wait_agent completed: 1 subagents.",
        "subagents" => [%{"id" => "sub_1", "status" => "completed"}]
      }),
      Event.tool_call(sid, "call_wait_repaired", "wait_agent", %{"ids" => ["sub_2"]}),
      Event.tool_result(sid, "call_wait_repaired", %{
        "ok" => false,
        "error" => %{
          "kind" => "orphan_tool_call",
          "message" => "Pixir reconciled a tool_call that had no persisted tool_result",
          "details" => %{"call_id" => "call_wait_repaired", "tool" => "wait_agent"}
        }
      }),
      Event.turn_failed(sid, %{
        "terminal_status" => "tool_error",
        "error_kind" => "tool",
        "error_message" => "wait_agent result was incomplete",
        "details" => %{}
      })
    ])

    on_exit(fn -> File.rm_rf!(ws) end)

    assert {:ok, result} = SessionDiagnostics.run(sid, workspace: ws)

    assert %{
             "status" => "warning",
             "details" => %{
               "classification" => "parent_wait_inconsistent_result",
               "issues" => issues
             }
           } = Enum.find(result["checks"], &(&1["id"] == "parent_waits"))

    assert Enum.any?(issues, &(&1["kind"] == "missing_structured_wait_outcome"))
    assert Enum.any?(issues, &(&1["kind"] == "synthetic_wait_agent_result"))
    assert "rerun wait_agent when the outcome is missing or incomplete" in result["next_actions"]
  end

  test "accounts for a failed turn with durable failure evidence" do
    ws = tmp_ws()
    sid = "diagnose-turn-failed"

    append_all(ws, sid, [
      Event.user_message(sid, "run"),
      Event.provider_usage(sid, %{
        "model" => "gpt-5.5",
        "active_transport" => "websocket",
        "continuation_attempted" => true,
        "continuation_reset_reason" => nil,
        "used_previous_response_id" => false,
        "usage_summary" => %{"total_tokens" => 42}
      }),
      Event.turn_failed(sid, %{
        "terminal_status" => "provider_error",
        "error_kind" => "network",
        "error_message" => "The provider stream exited before Pixir received a final answer.",
        "details" => %{"transport" => "websocket"}
      }),
      Event.user_message(sid, "continue")
    ])

    on_exit(fn -> File.rm_rf!(ws) end)

    assert {:ok, result} = SessionDiagnostics.run(sid, workspace: ws)
    assert result["ok"] == true
    assert result["status"] == "ready_with_warnings"

    assert %{"status" => "passed"} =
             Enum.find(result["checks"], &(&1["id"] == "turn_completion"))

    assert %{
             "status" => "warning",
             "details" => %{
               "classification" => "durable_turn_failure_evidence",
               "failures" => [failure]
             }
           } = Enum.find(result["checks"], &(&1["id"] == "turn_failure_evidence"))

    assert failure["terminal_status"] == "provider_error"
    assert failure["error_kind"] == "network"
    assert failure["has_details"] == true
  end

  test "classifies provider stream idle timeouts with recovery guidance" do
    ws = tmp_ws()
    sid = "diagnose-stream-idle-timeout"

    append_all(ws, sid, [
      Event.user_message(sid, "run"),
      Event.turn_failed(sid, %{
        "terminal_status" => "provider_error",
        "error_kind" => "stream_idle_timeout",
        "error_message" => "Provider stream stalled waiting for the next chunk.",
        "details" => %{
          "timeout_ms" => 180_000,
          "transport" => "websocket",
          "recovery" => %{
            "classification" => "provider_stream_idle_timeout",
            "diagnose_command" => "pixir diagnose session #{sid} --json",
            "resume_command" => "pixir resume #{sid} \"continue safely\"",
            "auto_retry" => %{"safe" => false}
          }
        }
      })
    ])

    on_exit(fn -> File.rm_rf!(ws) end)

    assert {:ok, result} = SessionDiagnostics.run(sid, workspace: ws)

    assert %{
             "status" => "warning",
             "details" => %{
               "classification" => "provider_stream_idle_timeout",
               "failures" => [failure],
               "next_actions" => next_actions
             }
           } = Enum.find(result["checks"], &(&1["id"] == "turn_failure_evidence"))

    assert failure["error_kind"] == "stream_idle_timeout"
    assert failure["recovery"]["classification"] == "provider_stream_idle_timeout"
    assert failure["recovery"]["auto_retry"]["safe"] == false

    assert "do not auto-replay ambiguous idle-timeout Turns until a resume policy is explicitly chosen" in next_actions
  end

  test "classifies provider missing-output errors by local call id evidence" do
    ws = tmp_ws()
    sid = "diagnose-missing-output-classification"

    append_all(ws, sid, [
      Event.user_message(sid, "run"),
      Event.tool_call(sid, "call_seen", "bash", %{"command" => "pwd"}),
      Event.tool_result(sid, "call_seen", %{"ok" => true, "output" => "/tmp"}),
      Event.provider_usage(sid, %{
        "model" => "gpt-5.5",
        "active_transport" => "websocket",
        "continuation_attempted" => true,
        "continuation_reset_reason" => nil,
        "used_previous_response_id" => true,
        "usage_summary" => %{"total_tokens" => 42}
      }),
      Event.turn_failed(sid, %{
        "terminal_status" => "provider_error",
        "error_kind" => "provider_http_error",
        "error_message" => "No tool output found for function call call_remote_only.",
        "details" => %{"status" => 200, "type" => "invalid_request_error"}
      }),
      Event.tool_call(sid, "call_local_missing", "bash", %{"command" => "date"}),
      Event.turn_failed(sid, %{
        "terminal_status" => "provider_error",
        "error_kind" => "provider_http_error",
        "error_message" => "No tool output found for function call call_local_missing.",
        "details" => %{"status" => 200, "type" => "invalid_request_error"}
      }),
      Event.tool_call(sid, "call_paired", "bash", %{"command" => "echo ok"}),
      Event.tool_result(sid, "call_paired", %{"ok" => true, "output" => "ok\n"}),
      Event.turn_failed(sid, %{
        "terminal_status" => "provider_error",
        "error_kind" => "provider_http_error",
        "error_message" => "No tool output found for function call call_paired.",
        "details" => %{"status" => 200, "type" => "invalid_request_error"}
      })
    ])

    on_exit(fn -> File.rm_rf!(ws) end)

    assert {:ok, result} = SessionDiagnostics.run(sid, workspace: ws)

    assert %{
             "status" => "warning",
             "details" => %{
               "classification" => "remote_continuation_desync",
               "failures" => failures,
               "next_actions" => next_actions
             }
           } = Enum.find(result["checks"], &(&1["id"] == "turn_failure_evidence"))

    remote = Enum.find(failures, &(&1["seq"] == 4))
    local = Enum.find(failures, &(&1["seq"] == 6))
    paired = Enum.find(failures, &(&1["seq"] == 9))

    assert remote["provider_missing_output"] == %{
             "call_id" => "call_remote_only",
             "classification" => "remote_continuation_desync",
             "known_local_tool_call" => false,
             "known_local_tool_result" => false
           }

    assert local["provider_missing_output"] == %{
             "call_id" => "call_local_missing",
             "classification" => "local_missing_tool_output",
             "known_local_tool_call" => true,
             "known_local_tool_result" => false
           }

    assert paired["provider_missing_output"] == %{
             "call_id" => "call_paired",
             "classification" => "provider_rejected_known_paired_call",
             "known_local_tool_call" => true,
             "known_local_tool_result" => true
           }

    assert "treat the missing call_id as provider-side continuation evidence, not local Log corruption" in next_actions
  end

  test "summarizes completed workflow events and checkpoint v2 artifact refs" do
    ws = tmp_ws()
    sid = "diagnose-workflow-complete"

    write_raw_log(ws, sid, [
      raw_event(sid, 0, "user_message", %{"text" => "run workflow"}),
      raw_event(sid, 1, "workflow_event", %{
        "kind" => "workflow_started",
        "workflow_id" => "wf_virtual",
        "workflow_name" => "Virtual workflow",
        "graph" => %{"step_count" => 1}
      }),
      raw_event(sid, 2, "workflow_event", %{
        "kind" => "step_scheduled",
        "workflow_id" => "wf_virtual",
        "workflow_name" => "Virtual workflow",
        "step_id" => "scratch",
        "workspace_mode" => "virtual_overlay",
        "execution_kind" => "virtual_overlay"
      }),
      raw_event(sid, 3, "workflow_event", %{
        "kind" => "checkpoint_decided",
        "workflow_id" => "wf_virtual",
        "workflow_name" => "Virtual workflow",
        "step_id" => "scratch",
        "checkpoint_status" => "checkpoint_ready",
        "dependent_safe" => true,
        "workspace_mode" => "virtual_overlay",
        "execution_kind" => "virtual_overlay",
        "checkpoint" => %{
          "status" => "checkpoint_ready",
          "version" => 2,
          "summary" => "virtual diff ready",
          "known_limitations" => ["virtual_diff_not_applied"],
          "typed_schema_ids" => ["workflow_checkpoint.v1"],
          "artifact_refs" => [
            %{
              "schema_id" => "artifact_ref.v1",
              "kind" => "virtual_diff",
              "provenance" => "artifact",
              "hash" => "sha256:abc",
              "workspace_strategy" => "virtual_overlay",
              "validation" => %{"status" => "valid"}
            }
          ]
        }
      }),
      raw_event(sid, 4, "workflow_event", %{
        "kind" => "workflow_finished",
        "workflow_id" => "wf_virtual",
        "workflow_name" => "Virtual workflow",
        "status" => "completed",
        "ok" => true,
        "safe_next_actions" => []
      }),
      raw_event(sid, 5, "assistant_message", %{"text" => "done", "metadata" => %{}})
    ])

    on_exit(fn -> File.rm_rf!(ws) end)

    assert {:ok, result} = SessionDiagnostics.run(sid, workspace: ws)
    assert result["ok"] == true

    assert %{"status" => "passed"} =
             Enum.find(result["checks"], &(&1["id"] == "workflow_events"))

    assert %{"status" => "passed"} =
             Enum.find(result["checks"], &(&1["id"] == "workflow_checkpoints"))

    assert %{"count" => 1, "runs" => [run]} = result["workflows"]
    assert run["workflow_id"] == "wf_virtual"
    assert run["workflow_name"] == "Virtual workflow"
    assert run["started"] == true
    assert run["finished"] == true
    assert run["status"] == "completed"
    assert run["ok"] == true
    assert run["step_counts"]["scheduled"] == 1
    assert run["step_counts"]["checkpoint_decided"] == 1
    assert run["step_counts"]["dependent_safe"] == 1
    assert run["typed_schema_ids"] == ["workflow_checkpoint.v1"]
    assert [%{"kind" => "virtual_diff", "hash" => "sha256:abc"}] = run["artifact_refs"]
    assert run["gaps"] == []
  end

  test "summarizes timeout-held workflow steps without dependency-hold false positives" do
    ws = tmp_ws()
    sid = "diagnose-workflow-timeout-held"

    write_raw_log(ws, sid, [
      raw_event(sid, 0, "user_message", %{"text" => "run workflow"}),
      raw_event(sid, 1, "workflow_event", %{
        "kind" => "workflow_started",
        "workflow_id" => "wf_timeout",
        "workflow_name" => "Timeout workflow"
      }),
      raw_event(sid, 2, "workflow_event", %{
        "kind" => "step_held",
        "workflow_id" => "wf_timeout",
        "workflow_name" => "Timeout workflow",
        "step_id" => "pending_reader",
        "checkpoint_status" => "held",
        "dependent_safe" => false,
        "reason" => "workflow_timeout",
        "workspace_mode" => "shared",
        "execution_kind" => "subagent"
      }),
      raw_event(sid, 3, "workflow_event", %{
        "kind" => "checkpoint_decided",
        "workflow_id" => "wf_timeout",
        "workflow_name" => "Timeout workflow",
        "step_id" => "pending_reader",
        "checkpoint_status" => "held",
        "dependent_safe" => false,
        "workspace_mode" => "shared",
        "execution_kind" => "subagent",
        "checkpoint" => %{
          "status" => "held",
          "version" => 2,
          "summary" => "Held: workflow_timeout.",
          "known_limitations" => ["workflow_timeout"],
          "typed_schema_ids" => ["workflow_checkpoint.v1"],
          "artifact_refs" => []
        }
      }),
      raw_event(sid, 4, "workflow_event", %{
        "kind" => "workflow_finished",
        "workflow_id" => "wf_timeout",
        "workflow_name" => "Timeout workflow",
        "status" => "partial",
        "ok" => false,
        "safe_next_actions" => ["retry_workflow_with_larger_timeout"]
      })
    ])

    on_exit(fn -> File.rm_rf!(ws) end)

    assert {:ok, result} = SessionDiagnostics.run(sid, workspace: ws)

    assert %{"status" => "passed"} =
             Enum.find(result["checks"], &(&1["id"] == "workflow_events"))

    assert %{"status" => "passed"} =
             Enum.find(result["checks"], &(&1["id"] == "workflow_checkpoints"))

    assert %{"runs" => [run]} = result["workflows"]
    assert run["status"] == "partial"
    assert run["checkpoint_status_counts"] == %{"held" => 1}
    assert [%{"step_id" => "pending_reader", "reason" => "workflow_timeout"}] = run["held_steps"]
    assert run["safe_next_actions"] == ["retry_workflow_with_larger_timeout"]
    assert run["gaps"] == []
  end

  test "warns when workflow event spine or checkpoint typed evidence is incomplete" do
    ws = tmp_ws()
    sid = "diagnose-workflow-gaps"

    write_raw_log(ws, sid, [
      raw_event(sid, 0, "user_message", %{"text" => "run workflow"}),
      raw_event(sid, 1, "workflow_event", %{
        "kind" => "workflow_started",
        "workflow_id" => "wf_gap",
        "workflow_name" => "Gap workflow"
      }),
      raw_event(sid, 2, "workflow_event", %{
        "kind" => "checkpoint_decided",
        "workflow_id" => "wf_gap",
        "workflow_name" => "Gap workflow",
        "step_id" => "scratch",
        "checkpoint_status" => "checkpoint_ready",
        "dependent_safe" => true,
        "workspace_mode" => "virtual_overlay",
        "execution_kind" => "virtual_overlay",
        "checkpoint" => %{
          "status" => "checkpoint_ready",
          "version" => 2,
          "summary" => "virtual diff ready",
          "known_limitations" => [],
          "typed_schema_ids" => [],
          "artifact_refs" => [
            %{
              "schema_id" => "artifact_ref.v1",
              "kind" => "virtual_diff",
              "provenance" => "artifact"
            }
          ]
        }
      })
    ])

    on_exit(fn -> File.rm_rf!(ws) end)

    assert {:ok, result} = SessionDiagnostics.run(sid, workspace: ws)
    assert result["status"] == "ready_with_warnings"

    assert %{"status" => "warning", "details" => %{"gaps" => event_gaps}} =
             Enum.find(result["checks"], &(&1["id"] == "workflow_events"))

    assert Enum.any?(event_gaps, &(&1["kind"] == "missing_workflow_finished"))

    assert %{"status" => "warning", "details" => %{"gaps" => checkpoint_gaps}} =
             Enum.find(result["checks"], &(&1["id"] == "workflow_checkpoints"))

    assert Enum.any?(checkpoint_gaps, &(&1["kind"] == "missing_workflow_checkpoint_schema"))
    assert Enum.any?(checkpoint_gaps, &(&1["kind"] == "missing_artifact_ref_hash"))

    assert "inspect checkpoint_decided events for missing typed_schema_ids or artifact refs" in result[
             "next_actions"
           ]
  end

  test "warns explicitly when a partial assistant message was preserved after provider error" do
    ws = tmp_ws()
    sid = "diagnose-partial-assistant"

    append_all(ws, sid, [
      Event.user_message(sid, "run"),
      Event.assistant_message(sid, "partial answer",
        metadata: %{
          "partial" => true,
          "terminal_status" => "provider_error",
          "error_kind" => "network"
        }
      )
    ])

    on_exit(fn -> File.rm_rf!(ws) end)

    assert {:ok, result} = SessionDiagnostics.run(sid, workspace: ws)
    assert result["ok"] == true
    assert result["status"] == "ready_with_warnings"

    assert %{
             "status" => "warning",
             "details" => %{
               "classification" => "partial_assistant_preserved_after_provider_error",
               "messages" => [message]
             }
           } = Enum.find(result["checks"], &(&1["id"] == "assistant_canonicalization"))

    assert message["error_kind"] == "network"
    assert message["terminal_status"] == "provider_error"
    assert message["text_length"] == 14
  end

  test "reports terminal failure evidence alongside preserved partial assistant text" do
    ws = tmp_ws()
    sid = "diagnose-partial-assistant-with-failure"

    append_all(ws, sid, [
      Event.user_message(sid, "run"),
      Event.assistant_message(sid, "partial answer",
        metadata: %{
          "partial" => true,
          "terminal_status" => "provider_error",
          "error_kind" => "network"
        }
      ),
      Event.turn_failed(sid, %{
        "terminal_status" => "provider_error",
        "error_kind" => "network",
        "error_message" => "The provider stream exited before Pixir received a final answer.",
        "details" => %{"transport" => "websocket", "partial_text_length" => 14}
      })
    ])

    on_exit(fn -> File.rm_rf!(ws) end)

    assert {:ok, result} = SessionDiagnostics.run(sid, workspace: ws)
    assert result["ok"] == true
    assert result["status"] == "ready_with_warnings"

    assert %{
             "status" => "warning",
             "details" => %{
               "classification" => "partial_assistant_preserved_after_provider_error"
             }
           } = Enum.find(result["checks"], &(&1["id"] == "assistant_canonicalization"))

    assert %{
             "status" => "warning",
             "details" => %{
               "classification" => "durable_turn_failure_evidence",
               "failures" => [failure]
             }
           } = Enum.find(result["checks"], &(&1["id"] == "turn_failure_evidence"))

    assert failure["terminal_status"] == "provider_error"
    assert failure["error_kind"] == "network"
    assert failure["has_details"] == true
  end

  test "warns with actionable subagent timeout evidence" do
    ws = tmp_ws()
    sid = "diagnose-subagent-timeout"

    append_all(ws, sid, [
      Event.user_message(sid, "delegate"),
      Event.subagent_event(sid, %{
        "event" => "timed_out",
        "subagent_id" => "sub_1",
        "child_session_id" => "child_1",
        "agent" => "explorer",
        "task" => "inspect slow repo",
        "depth" => 1,
        "status" => "timed_out",
        "workspace" => ws,
        "child_log_path" => Path.join([ws, ".pixir", "sessions", "child_1.ndjson"]),
        "summary" => "Timed out after 52ms (configured timeout 50ms).",
        "timeout_ms" => 50,
        "deadline_at" => "2026-06-28T22:00:00Z",
        "elapsed_ms" => 52,
        "reason" => "timeout",
        "next_actions" => [
          "inspect_child_session_log",
          "retry_subagent_with_larger_timeout"
        ]
      })
    ])

    on_exit(fn -> File.rm_rf!(ws) end)

    assert {:ok, result} = SessionDiagnostics.run(sid, workspace: ws)
    assert result["ok"] == true
    assert result["status"] == "ready_with_warnings"

    assert %{
             "status" => "warning",
             "details" => %{
               "classification" => "subagent_timeout_evidence",
               "timeouts" => [timeout]
             }
           } = Enum.find(result["checks"], &(&1["id"] == "subagent_timeouts"))

    assert timeout["subagent_id"] == "sub_1"
    assert timeout["child_session_id"] == "child_1"
    assert timeout["child_log_path"] =~ ".pixir/sessions/child_1.ndjson"
    assert timeout["agent"] == "explorer"
    assert timeout["reason"] == "timeout"
    assert timeout["timeout_ms"] == 50
    assert timeout["deadline_at"] == "2026-06-28T22:00:00Z"
    assert timeout["elapsed_ms"] == 52
    assert timeout["missing_fields"] == []
    assert "inspect_child_session_log" in timeout["next_actions"]
  end

  test "warns when subagent timeout evidence is missing core identity or status fields" do
    ws = tmp_ws()
    sid = "diagnose-incomplete-subagent-timeout"

    append_all(ws, sid, [
      Event.user_message(sid, "delegate"),
      Event.subagent_event(sid, %{
        "event" => "timed_out",
        "subagent_id" => "sub_1",
        "agent" => "explorer",
        "timeout_ms" => 50,
        "elapsed_ms" => 52,
        "reason" => "timeout",
        "next_actions" => ["inspect_child_session_log"]
      })
    ])

    on_exit(fn -> File.rm_rf!(ws) end)

    assert {:ok, result} = SessionDiagnostics.run(sid, workspace: ws)

    assert %{
             "status" => "warning",
             "details" => %{
               "classification" => "subagent_timeout_incomplete_evidence",
               "timeouts" => [timeout]
             }
           } = Enum.find(result["checks"], &(&1["id"] == "subagent_timeouts"))

    assert "child_session_id" in timeout["missing_fields"]
    assert "child_log_path" in timeout["missing_fields"]
    assert "status" in timeout["missing_fields"]
  end

  test "classifies failed subagent terminal state evidence" do
    ws = tmp_ws()
    sid = "diagnose-failed-subagent"
    child_sid = "failed-child"
    child_ws = Path.join([ws, ".pixir", "subagents", "sub_failed", "workspace"])
    File.mkdir_p!(child_ws)

    append_all(ws, sid, [
      Event.user_message(sid, "delegate"),
      Event.subagent_event(sid, %{
        "event" => "started",
        "subagent_id" => "sub_failed",
        "child_session_id" => child_sid,
        "agent" => "explorer",
        "task" => "inspect repo",
        "depth" => 1,
        "status" => "running",
        "workspace" => child_ws
      }),
      Event.subagent_event(sid, %{
        "event" => "failed",
        "subagent_id" => "sub_failed",
        "child_session_id" => child_sid,
        "agent" => "explorer",
        "task" => "inspect repo",
        "depth" => 1,
        "status" => "failed",
        "workspace" => child_ws,
        "summary" => "Subagent failed before completion.",
        "elapsed_ms" => 118,
        "reason" => "provider_error",
        "next_actions" => ["inspect_child_session_log", "reduce_task_scope"]
      })
    ])

    append_all(child_ws, child_sid, [
      Event.user_message(child_sid, "inspect repo"),
      Event.turn_failed(child_sid, %{
        "terminal_status" => "provider_error",
        "error_kind" => "network",
        "error_message" => "provider stream exited",
        "details" => %{"transport" => "test"}
      })
    ])

    on_exit(fn -> File.rm_rf!(ws) end)

    assert {:ok, result} = SessionDiagnostics.run(sid, workspace: ws)

    assert %{
             "status" => "warning",
             "details" => %{
               "classification" => "subagent_terminal_state_evidence",
               "notable" => [state]
             }
           } = Enum.find(result["checks"], &(&1["id"] == "subagent_terminal_states"))

    assert state["subagent_id"] == "sub_failed"
    assert state["status"] == "failed"
    assert state["classification"] == "failed"
    assert state["reason"] == "provider_error"
    assert state["elapsed_ms"] == 118
    assert state["missing_fields"] == []
    assert "inspect_child_session_log" in state["next_actions"]
  end

  test "warns when running subagent child logs are stale" do
    ws = tmp_ws()
    sid = "diagnose-stale-running-subagent"
    child_sid = "stale-child"
    child_ws = Path.join([ws, ".pixir", "subagents", "sub_stale", "workspace"])
    File.mkdir_p!(child_ws)

    old_ts = "2026-06-23T11:50:00Z"
    now = ~U[2026-06-23 12:00:00Z]

    append_all(ws, sid, [
      Event.user_message(sid, "delegate"),
      Event.subagent_event(sid, %{
        "event" => "started",
        "subagent_id" => "sub_stale",
        "child_session_id" => child_sid,
        "agent" => "explorer",
        "task" => "inspect repo",
        "depth" => 1,
        "status" => "running",
        "workspace" => child_ws,
        "next_actions" => ["wait_again"]
      })
    ])

    append_all(child_ws, child_sid, [
      Event.user_message(child_sid, "inspect repo", ts: old_ts)
    ])

    on_exit(fn -> File.rm_rf!(ws) end)

    assert {:ok, result} =
             SessionDiagnostics.run(sid,
               workspace: ws,
               now: now,
               stale_after_ms: 300_000
             )

    assert %{
             "status" => "warning",
             "details" => %{
               "classification" => "stale_running_or_queued_subagent",
               "subagents" => [stale]
             }
           } = Enum.find(result["checks"], &(&1["id"] == "subagent_staleness"))

    assert stale["subagent_id"] == "sub_stale"
    assert stale["child_session_id"] == child_sid
    assert stale["child_log_path"] =~ ".pixir/sessions/#{child_sid}.ndjson"
    assert stale["status"] == "running"
    assert stale["age_ms"] == 600_000
    assert stale["child_last_event_ts"] == old_ts
    assert "inspect each child_session_id log" in result["next_actions"]
  end

  test "warns when durable open subagents are absent from the Manager runtime" do
    ws = tmp_ws()
    sid = "diagnose-manager-runtime-gap"
    child_sid = "runtime-gap-child"
    child_ws = Path.join([ws, ".pixir", "subagents", "sub_runtime_gap", "workspace"])
    File.mkdir_p!(child_ws)

    write_raw_log(ws, sid, [
      raw_event(sid, 0, "user_message", %{"text" => "delegate"}),
      raw_event(sid, 1, "subagent_event", %{
        "event" => "started",
        "subagent_id" => "sub_runtime_gap",
        "child_session_id" => child_sid,
        "agent" => "explorer",
        "task" => "inspect repo",
        "depth" => 1,
        "status" => "running",
        "workspace" => child_ws,
        "next_actions" => ["wait_again"]
      })
    ])

    write_raw_log(child_ws, child_sid, [
      raw_event(child_sid, 0, "user_message", %{"text" => "inspect repo"})
    ])

    on_exit(fn -> File.rm_rf!(ws) end)

    assert {:ok, result} = SessionDiagnostics.run(sid, workspace: ws)

    assert result["subagents_runtime"]["available"] == true
    assert result["subagents_runtime"]["known_subagent_count"] == 0

    assert %{
             "status" => "warning",
             "details" => %{
               "classification" => "subagent_manager_runtime_gap",
               "runtime_gaps" => [],
               "missing_runtime_open_subagents" => [missing]
             }
           } = Enum.find(result["checks"], &(&1["id"] == "subagent_manager_runtime"))

    assert missing["subagent_id"] == "sub_runtime_gap"
    assert missing["child_session_id"] == child_sid
    assert missing["status"] == "running"
    assert missing["child_log_path"] =~ ".pixir/sessions/#{child_sid}.ndjson"
    assert "run pixir tree for the parent Session" in result["next_actions"]
  end

  test "does not compare nested subagents against the root Manager runtime" do
    ws = tmp_ws()
    sid = "diagnose-manager-direct-only"
    child_sid = "direct-child"
    grandchild_sid = "nested-child"
    child_ws = Path.join([ws, ".pixir", "subagents", "sub_direct", "workspace"])
    grandchild_ws = Path.join([child_ws, ".pixir", "subagents", "sub_nested", "workspace"])
    File.mkdir_p!(grandchild_ws)

    write_raw_log(ws, sid, [
      raw_event(sid, 0, "user_message", %{"text" => "delegate"}),
      raw_event(sid, 1, "subagent_event", %{
        "event" => "finished",
        "subagent_id" => "sub_direct",
        "child_session_id" => child_sid,
        "agent" => "explorer",
        "task" => "inspect repo",
        "depth" => 1,
        "status" => "completed",
        "workspace" => child_ws,
        "summary" => "done"
      })
    ])

    write_raw_log(child_ws, child_sid, [
      raw_event(child_sid, 0, "user_message", %{"text" => "delegate nested"}),
      raw_event(child_sid, 1, "subagent_event", %{
        "event" => "started",
        "subagent_id" => "sub_nested",
        "child_session_id" => grandchild_sid,
        "agent" => "explorer",
        "task" => "inspect nested",
        "depth" => 2,
        "status" => "running",
        "workspace" => grandchild_ws
      })
    ])

    on_exit(fn -> File.rm_rf!(ws) end)

    assert {:ok, result} = SessionDiagnostics.run(sid, workspace: ws)

    assert %{"status" => "passed"} =
             Enum.find(result["checks"], &(&1["id"] == "subagent_manager_runtime"))
  end

  defp tmp_ws do
    ws =
      Path.join(
        System.tmp_dir!(),
        "pixir-session-diagnostics-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(ws)
    ws
  end

  defp append_all(ws, sid, events) do
    events
    |> Enum.with_index()
    |> Enum.each(fn {event, seq} ->
      assert {:ok, _} = Log.append(Event.with_seq(event, seq), workspace: ws)
    end)

    sid
  end

  defp write_raw_log(ws, sid, events) do
    path = Log.path(sid, workspace: ws)
    File.mkdir_p!(Path.dirname(path))

    body =
      events
      |> Enum.map_join("", &(Jason.encode!(&1) <> "\n"))

    File.write!(path, body)
    sid
  end

  defp raw_event(sid, seq, type, data) do
    %{
      "id" => "#{sid}-#{seq}",
      "session_id" => sid,
      "seq" => seq,
      "ts" => "2026-06-29T00:00:00Z",
      "type" => type,
      "data" => data
    }
  end
end
