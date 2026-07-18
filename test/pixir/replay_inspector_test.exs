defmodule Pixir.ReplayInspectorTest do
  use ExUnit.Case, async: true

  alias Pixir.{Event, Log, Provider, ReplayInspector}

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

  test "reports scoped 63/64/65 truncation evidence with the shared most-recent window" do
    ws = tmp_ws()
    sid = "inspect-output-truncation-window"

    events =
      for index <- 0..64 do
        id = "evt_#{String.pad_leading(Integer.to_string(index), 3, "0")}"

        Event.provider_usage(
          sid,
          %{
            "output_truncation" => %{
              "status" => "truncated",
              "reason" => "provider_output_limit",
              "provider_reason" => "max_tokens",
              "provider_usage_event_id" => id,
              "call_role" => if(index == 64, do: "final_answer", else: "intermediate")
            }
          },
          id: id
        )
      end

    append_all(ws, sid, events)
    on_exit(fn -> File.rm_rf!(ws) end)

    for {after_seq, expected_count, expected_truncated} <- [
          {62, 63, false},
          {63, 64, false},
          {64, 65, true}
        ] do
      assert {:ok, result} =
               ReplayInspector.inspect(sid, workspace: ws, after_seq: after_seq)

      summary = result["output_truncation"]
      assert summary["counts"]["truncated"] == expected_count
      assert summary["positive_count"] == expected_count
      assert length(summary["positive_refs"]) == min(expected_count, 64)
      assert summary["positive_refs_truncated"] == expected_truncated
      assert summary["latest"]["provider_usage_seq"] == after_seq
    end

    assert {:ok, full} = ReplayInspector.inspect(sid, workspace: ws)
    refs = full["output_truncation"]["positive_refs"]
    assert hd(refs)["provider_usage_seq"] == 1
    assert List.last(refs)["provider_usage_seq"] == 64
    assert full["replay_contract"]["provider_usage_events_excluded"] == 65
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

  test "implicit models resolve centrally while malformed profiles fail and open profiles preview" do
    ws = tmp_ws()
    sid = "inspect-profile-preflight"
    append_all(ws, sid, [Event.user_message(sid, "inspect")])
    on_exit(fn -> File.rm_rf!(ws) end)

    assert {:ok, result} =
             ReplayInspector.inspect(sid,
               workspace: ws,
               raw_config: %{"model" => "gpt-5.4-mini"}
             )

    assert result["ok"]

    assert {:error, %{error: %{kind: :invalid_config, details: %{reason: :unknown_mode}}}} =
             ReplayInspector.inspect(sid,
               workspace: ws,
               raw_config: %{"responses_backend" => %{"mode" => "future"}}
             )

    assert {:ok, open_result} =
             ReplayInspector.inspect(sid,
               workspace: ws,
               raw_config: %{
                 "responses_backend" => %{
                   "mode" => "open_responses",
                   "responses_url" => "https://private.example/v1/responses",
                   "auth" => %{"policy" => "none"}
                 }
               }
             )

    assert open_result["ok"]
    refute inspect(open_result) =~ "private.example"
  end

  test "explicit model values are preserved once for canonical validation" do
    ws = tmp_ws()
    sid = "inspect-explicit-model-validation"
    append_all(ws, sid, [Event.user_message(sid, "inspect")])
    on_exit(fn -> File.rm_rf!(ws) end)

    for model <- [123, "", "   "] do
      assert {:error,
              %{
                error: %{
                  kind: :invalid_config,
                  details: %{field: :model, reason: :invalid_type}
                }
              }} = ReplayInspector.inspect(sid, workspace: ws, model: model)
    end

    assert {:ok, implicit} =
             ReplayInspector.inspect(sid,
               workspace: ws,
               model: nil,
               raw_config: %{"model" => "gpt-5.4-mini"}
             )

    assert implicit["ok"]

    assert {:ok, explicit} =
             ReplayInspector.inspect(sid,
               workspace: ws,
               model: "gpt-explicit",
               raw_config: %{"model" => "must-not-win"}
             )

    assert explicit["ok"]
  end

  test "preview ingress receives explicit models once and omits nil or implicit models" do
    ws = tmp_ws()
    sid = "inspect-preview-model-evidence"
    append_all(ws, sid, [Event.user_message(sid, "inspect")])
    on_exit(fn -> File.rm_rf!(ws) end)

    Code.ensure_loaded!(Provider)
    traced = self()
    tracer = spawn_link(fn -> forward_preview_traces(traced) end)
    :erlang.trace(traced, true, [:call, {:tracer, tracer}])
    assert :erlang.trace_pattern({Provider, :request_body_preview, 2}, true, []) == 1

    on_exit(fn ->
      :erlang.trace_pattern({Provider, :request_body_preview, 2}, false, [])
      Process.exit(tracer, :kill)
    end)

    assert {:ok, _report} =
             ReplayInspector.inspect(sid,
               workspace: ws,
               model: "gpt-explicit",
               raw_config: %{"model" => "gpt-configured"}
             )

    assert_receive {:captured_preview_trace,
                    {:trace, _pid, :call,
                     {Provider, :request_body_preview, [explicit_request, explicit_opts]}}}

    assert explicit_request.model == "gpt-explicit"
    refute Keyword.has_key?(explicit_opts, :model)

    implicit_calls =
      for model_opts <- [[], [model: nil]] do
        assert {:ok, _report} =
                 ReplayInspector.inspect(
                   sid,
                   [workspace: ws, raw_config: %{"model" => "gpt-configured"}] ++ model_opts
                 )

        assert_receive {:captured_preview_trace,
                        {:trace, _pid, :call, {Provider, :request_body_preview, [request, opts]}}}

        refute Map.has_key?(request, :model)
        refute Keyword.has_key?(opts, :model)
        {request, opts}
      end

    :erlang.trace(traced, false, [:call])
    :erlang.trace_pattern({Provider, :request_body_preview, 2}, false, [])

    assert {:ok, explicit_body} =
             Provider.request_body_preview(explicit_request, explicit_opts)

    assert explicit_body["model"] == "gpt-explicit"

    for {request, opts} <- implicit_calls do
      assert {:ok, body} = Provider.request_body_preview(request, opts)
      assert body["model"] == "gpt-configured"
    end
  end

  defp forward_preview_traces(test) do
    receive do
      message ->
        send(test, {:captured_preview_trace, message})
        forward_preview_traces(test)
    end
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
