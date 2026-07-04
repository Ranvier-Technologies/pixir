defmodule Pixir.ReplayInspectorTest do
  use ExUnit.Case, async: true

  alias Pixir.{Event, Log, ReplayInspector}

  test "reports balanced function calls for paired tool history" do
    ws = tmp_ws()
    sid = "inspect-balanced"

    append_all(ws, sid, [
      Event.user_message(sid, "run"),
      Event.tool_call(sid, "call_ok", "bash", %{"command" => "pwd"}),
      Event.tool_result(sid, "call_ok", %{"ok" => true, "output" => "/tmp"}),
      Event.assistant_message(sid, "done")
    ])

    on_exit(fn -> File.rm_rf!(ws) end)

    assert {:ok, result} = ReplayInspector.inspect(sid, workspace: ws)
    assert result["events"]["tool_calls"] == 1
    assert result["events"]["tool_results"] == 1
    assert result["provider_input"]["function_calls"] == 1
    assert result["provider_input"]["function_call_outputs"] == 1
    assert result["provider_input"]["missing_output_ids"] == []
    assert result["provider_input"]["extra_output_ids"] == []
    assert result["provider_input"]["synthetic_orphan_closures"] == []
    assert result["provider_input"]["balanced"] == true
  end

  test "reports synthetic orphan closures inserted by provider replay" do
    ws = tmp_ws()
    sid = "inspect-orphan"

    append_all(ws, sid, [
      Event.user_message(sid, "run"),
      Event.tool_call(sid, "call_orphan", "bash", %{"command" => "grep x"}),
      Event.user_message(sid, "continue")
    ])

    on_exit(fn -> File.rm_rf!(ws) end)

    assert {:ok, result} = ReplayInspector.inspect(sid, workspace: ws)
    assert result["events"]["tool_calls"] == 1
    assert result["events"]["tool_results"] == 0
    assert result["provider_input"]["function_calls"] == 1
    assert result["provider_input"]["function_call_outputs"] == 1
    assert result["provider_input"]["balanced"] == true

    assert [
             %{
               "call_id" => "call_orphan",
               "kind" => "orphan_tool_call",
               "tool" => "bash"
             }
           ] = result["provider_input"]["synthetic_orphan_closures"]
  end

  test "reports audit-only turn evidence excluded from provider replay" do
    ws = tmp_ws()
    sid = "inspect-audit-only-turn-evidence"

    append_all(ws, sid, [
      Event.user_message(sid, "run"),
      Event.provider_usage(sid, %{
        "model" => "gpt-5.5",
        "call_index" => 0,
        "usage_summary" => %{"input_tokens" => 12, "cached_tokens" => 0}
      }),
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
        "error_message" => "provider stream exited",
        "details" => %{"partial_text_length" => 14}
      }),
      Event.user_message(sid, "continue")
    ])

    on_exit(fn -> File.rm_rf!(ws) end)

    assert {:ok, result} = ReplayInspector.inspect(sid, workspace: ws)

    assert result["events"]["assistant_messages"] == 1
    assert result["events"]["partial_assistant_messages"] == 1
    assert result["events"]["turn_failed"] == 1
    assert result["events"]["provider_usage"] == 1

    assert result["provider_input"]["assistant_messages"] == 0

    assert result["replay_contract"] == %{
             "audit_only_events_excluded" => 3,
             "clean_assistant_messages_replayed" => 0,
             "partial_assistant_messages_excluded" => 1,
             "provider_usage_events_excluded" => 1,
             "turn_failed_events_excluded" => 1
           }
  end

  test "after_seq inspects replay state after a given event seq" do
    ws = tmp_ws()
    sid = "inspect-after-seq"

    append_all(ws, sid, [
      Event.user_message(sid, "run"),
      Event.tool_call(sid, "call_ok", "bash", %{"command" => "pwd"}),
      Event.tool_result(sid, "call_ok", %{"ok" => true, "output" => "/tmp"}),
      Event.user_message(sid, "next"),
      Event.tool_call(sid, "call_later", "bash", %{"command" => "date"})
    ])

    on_exit(fn -> File.rm_rf!(ws) end)

    assert {:ok, result} = ReplayInspector.inspect(sid, workspace: ws, after_seq: 2)
    assert result["after_seq"] == 2
    assert result["events"]["inspected_count"] == 3
    assert result["events"]["to_seq"] == 2
    assert result["events"]["tool_calls"] == 1
    assert result["provider_input"]["synthetic_orphan_closures"] == []
  end

  defp tmp_ws do
    ws =
      Path.join(System.tmp_dir!(), "pixir-replay-inspector-#{System.unique_integer([:positive])}")

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
end
