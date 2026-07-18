defmodule Pixir.ACP.TranslateTest do
  use ExUnit.Case, async: true

  alias Pixir.{Event, ACP.Translate}

  @sid "acp-session-1"

  describe "update/2 streaming" do
    test "text_delta -> agent_message_chunk" do
      e = Event.text_delta("pix", "hello")

      assert %{
               "sessionId" => @sid,
               "update" => %{
                 "sessionUpdate" => "agent_message_chunk",
                 "content" => %{"type" => "text", "text" => "hello"}
               }
             } = Translate.update(e, @sid)
    end

    test "reasoning_delta -> agent_thought_chunk" do
      e = Event.reasoning_delta("pix", "thinking")

      assert %{"update" => %{"sessionUpdate" => "agent_thought_chunk"} = u} =
               Translate.update(e, @sid)

      assert u["content"] == %{"type" => "text", "text" => "thinking"}
    end
  end

  describe "update/2 tool_call" do
    test "maps fields and a path-based title" do
      e = Event.tool_call("pix", "c1", "read", %{"path" => "a.txt"})

      assert %{"update" => u} = Translate.update(e, @sid, workspace: "/workspace")
      assert u["sessionUpdate"] == "tool_call"
      assert u["toolCallId"] == "c1"
      assert u["title"] == "read a.txt"
      assert u["kind"] == "read"
      assert u["status"] == "in_progress"
      assert u["locations"] == [%{"path" => "/workspace/a.txt"}]
    end

    test "adds locations only for file tools with paths inside the session workspace" do
      for {tool, kind} <- [{"read", "read"}, {"write", "edit"}, {"edit", "edit"}] do
        event = Event.tool_call("pix", "c-#{tool}", tool, %{"path" => "lib/pixir.ex"})

        assert %{"update" => update} = Translate.update(event, @sid, workspace: "/workspace")
        assert update["kind"] == kind
        assert update["locations"] == [%{"path" => "/workspace/lib/pixir.ex"}]
      end

      outside = Event.tool_call("pix", "c-out", "read", %{"path" => "../secret.txt"})

      assert %{"update" => outside_update} =
               Translate.update(outside, @sid, workspace: "/workspace")

      refute Map.has_key?(outside_update, "locations")

      sibling =
        Event.tool_call("pix", "c-sibling", "read", %{"path" => "/workspace-other/secret.txt"})

      assert %{"update" => sibling_update} =
               Translate.update(sibling, @sid, workspace: "/workspace")

      refute Map.has_key?(sibling_update, "locations")

      without_workspace = Event.tool_call("pix", "c-noworkspace", "read", %{"path" => "a.txt"})
      assert %{"update" => no_workspace_update} = Translate.update(without_workspace, @sid)
      refute Map.has_key?(no_workspace_update, "locations")
    end

    test "bash uses the command in the title" do
      e = Event.tool_call("pix", "c2", "bash", %{"command" => "ls -la"})

      assert %{"update" => %{"title" => "bash: ls -la", "kind" => "execute"} = update} =
               Translate.update(e, @sid)

      refute Map.has_key?(update, "locations")
    end

    test "falls back to the tool name when no useful args" do
      e = Event.tool_call("pix", "c3", "read", %{})
      assert %{"update" => %{"title" => "read"}} = Translate.update(e, @sid)
    end

    test "adds Pixir semantic metadata for subagent and workflow tools" do
      spawn = Event.tool_call("pix", "c4", "spawn_agent", %{"task" => "Inspect docs"})
      workflow = Event.tool_call("pix", "c5", "run_workflow", %{"steps" => []})

      assert %{"update" => %{"rawInput" => spawn_input}} = Translate.update(spawn, @sid)
      assert get_in(spawn_input, ["_meta", "pixir", "presentation", "type"]) == "subagent_tool"
      assert get_in(spawn_input, ["_meta", "pixir", "presentation", "tool"]) == "spawn_agent"
      assert spawn_input["args"]["task"] == "Inspect docs"

      assert %{"update" => %{"rawInput" => workflow_input}} = Translate.update(workflow, @sid)
      assert get_in(workflow_input, ["_meta", "pixir", "presentation", "type"]) == "workflow_tool"
      assert get_in(workflow_input, ["_meta", "pixir", "presentation", "tool"]) == "run_workflow"
    end

    test "classifies additional read and execute tools" do
      assert Translate.kind("resource_view") == "read"
      assert Translate.kind("run_workflow") == "execute"
      assert Translate.kind("unknown_tool") == "other"
    end
  end

  describe "update/2 tool_result" do
    test "ok result -> completed with output content" do
      e = Event.tool_result("pix", "c1", %{"ok" => true, "output" => "hello from file"})

      assert %{"update" => u} = Translate.update(e, @sid)
      assert u["sessionUpdate"] == "tool_call_update"
      assert u["toolCallId"] == "c1"
      assert u["status"] == "completed"

      assert u["content"] == [
               %{
                 "type" => "content",
                 "content" => %{"type" => "text", "text" => "hello from file"}
               }
             ]
    end

    test "bash nonzero exit (ok:false with output) -> failed" do
      e = Event.tool_result("pix", "c2", %{"ok" => false, "output" => "exit 1\nstderr"})

      assert %{"update" => %{"status" => "failed", "content" => content}} =
               Translate.update(e, @sid)

      assert [%{"content" => %{"text" => "exit 1\nstderr"}}] = content
    end

    test "structured error (ok:false) renders kind: message" do
      e =
        Event.tool_result("pix", "c3", %{
          "ok" => false,
          "error" => %{"kind" => "io_error", "message" => "no such file"}
        })

      assert %{"update" => %{"status" => "failed", "content" => content}} =
               Translate.update(e, @sid)

      assert [%{"content" => %{"text" => "io_error: no such file"}}] = content
    end

    test "adds Pixir semantic metadata for subagent and workflow results" do
      subagent =
        Event.tool_result("pix", "c4", %{
          "ok" => true,
          "output" => "Spawned sub_1.",
          "subagent" => %{"id" => "sub_1", "status" => "running"}
        })

      workflow =
        Event.tool_result("pix", "c5", %{
          "ok" => true,
          "output" => "Workflow complete.",
          "workflow" => %{"workflow_id" => "wf_1"}
        })

      assert %{"update" => %{"rawOutput" => subagent_output}} = Translate.update(subagent, @sid)

      assert get_in(subagent_output, ["_meta", "pixir", "presentation", "type"]) ==
               "subagent_tool_result"

      assert subagent_output["subagent"]["id"] == "sub_1"

      assert %{"update" => %{"rawOutput" => workflow_output}} = Translate.update(workflow, @sid)

      assert get_in(workflow_output, ["_meta", "pixir", "presentation", "type"]) ==
               "workflow_tool_result"

      assert workflow_output["workflow"]["workflow_id"] == "wf_1"
    end
  end

  describe "update/2 subagent_event" do
    test "started subagent lifecycle becomes a stable in-progress ACP tool item" do
      event =
        Event.subagent_event("pix", %{
          "event" => "started",
          "subagent_id" => "sub_123",
          "child_session_id" => "child_1",
          "agent" => "explorer",
          "task" => "Inspect docs",
          "status" => "running"
        })

      assert %{"sessionId" => @sid, "update" => update} = Translate.update(event, @sid)
      assert update["sessionUpdate"] == "tool_call"
      assert update["toolCallId"] == "pixir:#{@sid}:subagent:sub_123"
      assert update["title"] == "Subagent sub_123 (explorer)"
      assert update["kind"] == "other"
      assert update["status"] == "in_progress"
      assert [%{"content" => %{"text" => "running: Inspect docs"}}] = update["content"]

      assert get_in(update, ["rawInput", "_meta", "pixir", "presentation", "type"]) ==
               "subagent_lifecycle"

      assert get_in(update, ["rawInput", "subagent", "status"]) == "running"
    end

    test "later non-terminal subagent lifecycle updates the stable ACP tool item" do
      event =
        Event.subagent_event("pix", %{
          "event" => "input",
          "subagent_id" => "sub_123",
          "agent" => "explorer",
          "task" => "Inspect docs again",
          "status" => "running"
        })

      assert %{"update" => update} = Translate.update(event, @sid, subagent_seen?: true)
      assert update["sessionUpdate"] == "tool_call_update"
      assert update["toolCallId"] == "pixir:#{@sid}:subagent:sub_123"
      assert update["status"] == "in_progress"

      assert get_in(update, ["rawOutput", "_meta", "pixir", "presentation", "type"]) ==
               "subagent_lifecycle"

      assert get_in(update, ["rawOutput", "subagent", "event"]) == "input"
    end

    test "finished subagent lifecycle becomes a completed ACP tool update with exact Pixir status" do
      event =
        Event.subagent_event("pix", %{
          "event" => "finished",
          "subagent_id" => "sub_123",
          "agent" => "explorer",
          "status" => "completed",
          "summary" => "Done"
        })

      assert %{"update" => update} = Translate.update(event, @sid)
      assert update["sessionUpdate"] == "tool_call_update"
      assert update["toolCallId"] == "pixir:#{@sid}:subagent:sub_123"
      assert update["status"] == "completed"
      assert get_in(update, ["rawOutput", "subagent", "status"]) == "completed"
      assert [%{"content" => %{"text" => "completed: Done"}}] = update["content"]
    end

    test "failed subagent lifecycle preserves the Pixir status in rawOutput" do
      event =
        Event.subagent_event("pix", %{
          "event" => "timed_out",
          "subagent_id" => "sub_456",
          "agent" => "worker",
          "status" => "timed_out",
          "summary" => "timeout"
        })

      assert %{"update" => update} = Translate.update(event, @sid)
      assert update["sessionUpdate"] == "tool_call_update"
      assert update["status"] == "failed"
      assert get_in(update, ["rawOutput", "subagent", "status"]) == "timed_out"
    end
  end

  describe "update/2 plan (D.1)" do
    test "maps a plan event to a plan session/update with normalized entries" do
      entries = [
        %{"content" => "read the file", "priority" => "high", "status" => "pending"},
        %{"content" => "edit it", "priority" => "low", "status" => "in_progress"}
      ]

      assert %{"sessionId" => @sid, "update" => update} =
               Translate.update(Event.plan("pix", entries), @sid)

      assert update["sessionUpdate"] == "plan"
      assert update["entries"] == entries
    end

    test "clamps unknown priority/status to valid literals and fills empty content" do
      entries = [%{"content" => "  ", "priority" => "URGENT", "status" => "bogus"}]

      assert %{"update" => %{"entries" => [entry]}} =
               Translate.update(Event.plan("pix", entries), @sid)

      assert entry["priority"] == "medium"
      assert entry["status"] == "pending"
      assert entry["content"] == "(untitled step)"
    end

    test "tolerates atom-keyed entries from the bus" do
      entries = [%{content: "do x", priority: "high", status: "completed"}]

      assert %{"update" => %{"entries" => [entry]}} =
               Translate.update(Event.plan("pix", entries), @sid)

      assert entry == %{"content" => "do x", "priority" => "high", "status" => "completed"}
    end
  end

  describe "update/2 returns nil for non-presentation events" do
    test "assistant_message, status, user_message, reasoning, permission_decision -> nil" do
      assert Translate.update(Event.assistant_message("pix", "final"), @sid) == nil
      assert Translate.update(Event.status("pix", "done"), @sid) == nil
      assert Translate.update(Event.user_message("pix", "hi"), @sid) == nil
      assert Translate.update(Event.reasoning("pix", %{"id" => "rs"}, "m"), @sid) == nil
      assert Translate.update(Event.subagent_event("pix", %{"event" => "finished"}), @sid) == nil
      assert Translate.update(Event.permission_decision("pix", "c", :allow), @sid) == nil
    end
  end

  describe "replay/2 load transcript" do
    test "replays canonical user and assistant messages as transcript chunks" do
      assert %{"sessionId" => @sid, "update" => user_update} =
               Translate.replay(Event.user_message("pix", "hello"), @sid)

      assert user_update == %{
               "sessionUpdate" => "user_message_chunk",
               "content" => %{"type" => "text", "text" => "hello"}
             }

      assert %{"update" => assistant_update} =
               Translate.replay(Event.assistant_message("pix", "hi back"), @sid)

      assert assistant_update == %{
               "sessionUpdate" => "agent_message_chunk",
               "content" => %{"type" => "text", "text" => "hi back"}
             }
    end

    test "omits partial assistant evidence from clean transcript replay" do
      event =
        Event.assistant_message("pix", "partial answer",
          metadata: %{
            "partial" => true,
            "terminal_status" => "provider_error",
            "error_kind" => "network"
          }
        )

      assert Translate.replay(event, @sid) == nil
    end

    test "replays tool events with the live tool mapping" do
      call = Event.tool_call("pix", "c1", "bash", %{"command" => "mix test"})
      result = Event.tool_result("pix", "c1", %{"ok" => false, "output" => "failed"})

      assert Translate.replay(call, @sid) == Translate.update(call, @sid)
      assert Translate.replay(result, @sid) == Translate.update(result, @sid)
    end

    test "replays subagent lifecycle with the live presentation mapping" do
      event =
        Event.subagent_event("pix", %{
          "event" => "finished",
          "subagent_id" => "sub_123",
          "status" => "completed",
          "summary" => "Done"
        })

      assert Translate.replay(event, @sid) == Translate.update(event, @sid)
    end

    test "omits non-transcript events" do
      assert Translate.replay(Event.reasoning("pix", %{"id" => "rs"}, "m"), @sid) == nil
      assert Translate.replay(Event.skill_activation("pix", %{"name" => "sample"}), @sid) == nil
      assert Translate.replay(Event.subagent_event("pix", %{"event" => "finished"}), @sid) == nil
      assert Translate.replay(Event.permission_decision("pix", "c", :allow), @sid) == nil
      assert Translate.replay(Event.status("pix", "done"), @sid) == nil
      assert Translate.replay(Event.plan("pix", [%{"content" => "do x"}]), @sid) == nil
      assert Translate.replay(Event.turn_failed("pix", %{"error_kind" => "network"}), @sid) == nil
    end
  end

  describe "message_chunk/2 (fallback)" do
    test "wraps text as one agent_message_chunk" do
      assert %{
               "sessionId" => @sid,
               "update" => %{
                 "sessionUpdate" => "agent_message_chunk",
                 "content" => %{"type" => "text", "text" => "capped"}
               }
             } = Translate.message_chunk("capped", @sid)
    end
  end

  describe "kind/1" do
    test "maps the registry names" do
      assert Translate.kind("read") == "read"
      assert Translate.kind("write") == "edit"
      assert Translate.kind("edit") == "edit"
      assert Translate.kind("bash") == "execute"
      assert Translate.kind("wait_agent") == "read"
      assert Translate.kind("list_agents") == "read"
      assert Translate.kind("spawn_agent") == "execute"
      assert Translate.kind("send_input") == "execute"
      assert Translate.kind("close_agent") == "execute"
      assert Translate.kind("anything") == "other"
    end
  end

  describe "stop_reason/2" do
    test "done -> end_turn" do
      assert Translate.stop_reason(:done, false) == "end_turn"
    end

    test "error -> end_turn (reported as content, not a protocol error)" do
      assert Translate.stop_reason(:error, false) == "end_turn"
    end

    test "timeout -> end_turn" do
      assert Translate.stop_reason(:timeout, false) == "end_turn"
    end

    test "interrupted -> cancelled" do
      assert Translate.stop_reason(:interrupted, false) == "cancelled"
    end

    test "cancel_requested wins the race over any terminal outcome" do
      assert Translate.stop_reason(:done, true) == "cancelled"
      assert Translate.stop_reason(:error, true) == "cancelled"
    end
  end

  describe "permission_request/2 (A.2)" do
    test "builds the request params with allow_once/reject_once options" do
      request = %{
        tool: "write",
        args: %{"path" => "a.txt"},
        reason: "write a file",
        call_id: "c1"
      }

      params = Translate.permission_request(request, @sid)

      assert params["sessionId"] == @sid
      assert params["toolCall"]["toolCallId"] == "c1"
      assert params["toolCall"]["title"] == "write a.txt"
      assert params["toolCall"]["kind"] == "edit"

      kinds = Enum.map(params["options"], & &1["kind"])
      assert kinds == ["allow_once", "reject_once"]
      ids = Enum.map(params["options"], & &1["optionId"])
      assert ids == ["allow", "reject"]
    end
  end

  describe "permission_outcome/1 (A.2)" do
    test "selected allow -> :allow" do
      ok = {:ok, %{"outcome" => %{"outcome" => "selected", "optionId" => "allow"}}}
      assert Translate.permission_outcome(ok) == :allow
    end

    test "selected reject -> {:deny, _}" do
      ok = {:ok, %{"outcome" => %{"outcome" => "selected", "optionId" => "reject"}}}
      assert {:deny, _} = Translate.permission_outcome(ok)
    end

    test "cancelled -> {:deny, \"cancelled\"}" do
      assert Translate.permission_outcome({:ok, %{"outcome" => %{"outcome" => "cancelled"}}}) ==
               {:deny, "cancelled"}
    end

    test "an error or malformed response defaults to deny" do
      assert {:deny, _} = Translate.permission_outcome({:error, :boom})
      assert {:deny, _} = Translate.permission_outcome({:ok, %{"unexpected" => true}})
    end
  end

  describe "Provider-output warning extension" do
    test "uses session_info_update _meta without collapsing ACP and Pixir identities" do
      pixir_sid = "pixir-canonical-session"
      id = "evt_warning"

      event = %{
        Event.provider_usage(
          pixir_sid,
          %{
            "output_truncation" => %{
              "status" => "truncated",
              "reason" => "provider_output_limit",
              "provider_reason" => "max_tokens",
              "provider_usage_event_id" => id,
              "call_role" => "final_answer"
            }
          },
          id: id
        )
        | seq: 12
      }

      assert %{
               "sessionId" => @sid,
               "update" => %{
                 "sessionUpdate" => "session_info_update",
                 "_meta" => %{
                   "pixir" => %{
                     "schemaVersion" => 1,
                     "presentation" => %{"type" => "provider_output_warning"},
                     "warning" => warning
                   }
                 }
               }
             } = Translate.update(event, @sid)

      assert @sid != pixir_sid
      assert warning["providerUsageEventId"] == id
      assert warning["providerUsageSeq"] == 12
      assert warning["callRole"] == "final_answer"
      refute Map.has_key?(warning, "content")
    end

    test "unknown evidence does not fabricate an ACP warning" do
      id = "evt_unknown"

      event = %{
        Event.provider_usage(
          "pixir",
          %{
            "output_truncation" => %{
              "status" => "unknown",
              "reason" => "missing_terminal_evidence",
              "provider_usage_event_id" => id,
              "call_role" => "final_answer"
            }
          },
          id: id
        )
        | seq: 1
      }

      assert Translate.update(event, @sid) == nil
    end
  end
end
