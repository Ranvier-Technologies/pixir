defmodule Pixir.Provider.OutputTruncationTest do
  use ExUnit.Case, async: true

  alias Pixir.Provider.{OutputTruncation, OutputTruncationSummary, ToolCall}

  test "constructors retain only explicit safe bounded terminal tokens" do
    assert OutputTruncation.status(OutputTruncation.not_truncated("x")) == :not_truncated

    assert OutputTruncation.provider_reason(
             OutputTruncation.not_truncated(String.duplicate("a", 64))
           ) ==
             String.duplicate("a", 64)

    for token <- ["", String.duplicate("a", 65), "has space", <<255>>] do
      evidence = OutputTruncation.not_truncated(token)
      assert OutputTruncation.status(evidence) == :unknown
      assert OutputTruncation.reason(evidence) == :invalid_evidence
      assert OutputTruncation.provider_reason(evidence) == nil
      refute inspect(evidence) =~ inspect(token)
    end
  end

  test "positive and unknown enum combinations normalize totally" do
    positive = OutputTruncation.truncated(:provider_output_limit, "max_tokens")
    assert OutputTruncation.truncated?(positive)

    assert OutputTruncation.to_result_map(positive) == %{
             status: :truncated,
             reason: :provider_output_limit,
             provider_reason: "max_tokens"
           }

    for malformed <- [
          %{status: :truncated, reason: :missing_terminal_evidence, provider_reason: "x"},
          %{status: :not_truncated, reason: :provider_output_limit, provider_reason: "x"},
          %{status: :unknown, reason: :provider_output_limit},
          %{status: :truncated, reason: :provider_output_limit},
          %{status: :surprise, provider_reason: "x"}
        ] do
      assert OutputTruncation.reason(OutputTruncation.normalize(malformed)) == :invalid_evidence
    end
  end

  test "atom/string duplicate semantic keys are invalid even when equal" do
    evidence =
      OutputTruncation.normalize(%{
        "status" => "truncated",
        status: :truncated,
        reason: :provider_output_limit,
        provider_reason: "max_tokens"
      })

    assert OutputTruncation.status(evidence) == :unknown
    assert OutputTruncation.reason(evidence) == :invalid_evidence
  end

  test "unknown extra keys are ignored and never echoed" do
    evidence =
      OutputTruncation.normalize(%{
        "status" => "not_truncated",
        "provider_reason" => "finish",
        "secret" => "must-not-echo"
      })

    assert OutputTruncation.status(evidence) == :not_truncated
    refute inspect(evidence) =~ "must-not-echo"
    refute OutputTruncation.summary(evidence) =~ "finish"
    assert byte_size(OutputTruncation.summary(evidence)) <= 160
  end

  test "foreign missing and invalid evidence stay successful uncertainty" do
    assert OutputTruncation.reason(OutputTruncation.from_result(%{}, __MODULE__)) ==
             :provider_did_not_report

    assert OutputTruncation.reason(
             OutputTruncation.from_result(%{output_truncation: %{status: :bad}}, __MODULE__)
           ) == :invalid_evidence

    assert OutputTruncation.status(
             OutputTruncation.from_result(
               %{output_truncation: %{status: :not_truncated, provider_reason: "finish"}},
               __MODULE__
             )
           ) == :not_truncated
  end

  test "legacy Anthropic positive pairs remain compatible but cannot mask invalid top-level evidence" do
    legacy = %{
      provider_metadata: %{"truncated" => true, "stop_reason" => "max_tokens"}
    }

    assert OutputTruncation.truncated?(
             OutputTruncation.from_result(legacy, Pixir.Providers.Anthropic)
           )

    invalid = Map.put(legacy, :output_truncation, %{status: :truncated})

    assert OutputTruncation.reason(
             OutputTruncation.from_result(invalid, Pixir.Providers.Anthropic)
           ) == :invalid_evidence
  end

  test "summary sorts by canonical outer seq/id and keeps the newest 64 positive refs" do
    history =
      for seq <- Enum.reverse(1..65) do
        usage_event(seq, "evt_#{String.pad_leading(Integer.to_string(seq), 3, "0")}")
      end

    summary = OutputTruncationSummary.summarize(history)
    assert summary["counts"]["truncated"] == 65
    assert summary["positive_count"] == 65
    assert summary["positive_refs_truncated"]
    assert hd(summary["positive_refs"])["provider_usage_seq"] == 2
    assert List.last(summary["positive_refs"])["provider_usage_seq"] == 65
  end

  test "hostile inner correlation cannot become positive evidence" do
    event = usage_event(1, "evt_outer")
    hostile = put_in(event, [:data, "output_truncation", "provider_usage_event_id"], "evt_other")

    assert OutputTruncationSummary.project(hostile)["status"] == "unknown"
    assert OutputTruncationSummary.project(hostile)["reason"] == "invalid_evidence"
    assert OutputTruncationSummary.warning(hostile) == nil
  end

  test "summary roles follow the resolved nested map across atom and string keys" do
    rows = [
      {%{
         id: "evt_atom",
         seq: 11,
         data: %{
           output_truncation: %{
             status: "truncated",
             reason: "provider_output_limit",
             provider_reason: "max_tokens",
             provider_usage_event_id: "evt_atom",
             call_role: "final_answer"
           }
         }
       }, "final_answer", "evt_atom", 11},
      {%{
         "id" => "evt_mixed",
         "seq" => 12,
         "data" => %{
           output_truncation: %{
             "status" => "truncated",
             :reason => "provider_output_limit",
             "provider_reason" => "max_tokens",
             :provider_usage_event_id => "evt_mixed",
             "call_role" => "intermediate"
           }
         }
       }, "intermediate", "evt_mixed", 12},
      {%{
         id: "evt_outer_string",
         seq: 13,
         data: %{
           "output_truncation" => %{
             "status" => "truncated",
             "reason" => "provider_output_limit",
             "provider_reason" => "max_tokens",
             "provider_usage_event_id" => "evt_outer_string",
             :call_role => "final_answer"
           }
         }
       }, "final_answer", "evt_outer_string", 13},
      {usage_event(14, "evt_string"), "intermediate", "evt_string", 14}
    ]

    for {event, role, event_id, seq} <- rows do
      projected = OutputTruncationSummary.project(event)

      assert projected["status"] == "truncated"
      assert projected["call_role"] == role
      assert projected["provider_usage_event_id"] == event_id
      assert projected["provider_usage_seq"] == seq

      assert OutputTruncationSummary.warning(event) == %{
               "kind" => "provider_output_truncated",
               "severity" => "warning",
               "provider_usage_event_id" => event_id,
               "provider_usage_seq" => seq,
               "reason" => "provider_output_limit",
               "provider_reason" => "max_tokens",
               "call_role" => role
             }
    end
  end

  test "invalid, missing, non-map, and legacy nested evidence never acquires a role" do
    valid = usage_event(21, "evt_role_gate")

    invalid_events = [
      put_in(valid, [:data, "output_truncation", "call_role"], "tool"),
      put_in(valid, [:data, "output_truncation", "call_role"], :final_answer),
      put_in(valid, [:data, "output_truncation", "provider_usage_event_id"], "evt_other"),
      put_in(valid, [:data, "output_truncation", "status"], "truncated_missing_reason"),
      put_in(valid, [:data, "output_truncation"], []),
      %{
        valid
        | data: %{
            "provider_metadata" => %{"truncated" => true, "stop_reason" => "max_tokens"},
            "call_role" => "final_answer"
          }
      }
    ]

    duplicate_role =
      put_in(valid, [:data, "output_truncation", :call_role], "intermediate")

    for event <- [duplicate_role | invalid_events] do
      projected = OutputTruncationSummary.project(event)
      refute Map.has_key?(projected, "call_role")
      assert OutputTruncationSummary.warning(event) == nil
    end

    legacy = List.last(invalid_events)
    assert OutputTruncationSummary.project(legacy)["status"] == "truncated"
  end

  test "assistant fallback requires valid positive status and both correlation fields" do
    event = assistant_fallback_event()
    assert {:ok, projection, warning} = OutputTruncationSummary.assistant_fallback(event)
    assert projection["provider_usage_event_id"] == "evt_fallback"
    assert projection["provider_usage_seq"] == 12
    assert warning["call_role"] == "final_answer"

    for hostile <- [
          put_in(event, [:data, "metadata", "partial"], true),
          put_in(event, [:data, "metadata", "output_truncation", "provider_usage_seq"], nil),
          put_in(event, [:data, "metadata", "output_truncation", "call_role"], "intermediate"),
          put_in(event, [:data, "metadata", "output_truncation", "status"], "unknown"),
          put_in(
            event,
            [:data, "metadata", "output_truncation", :provider_usage_event_id],
            "evt_fallback"
          )
        ] do
      assert OutputTruncationSummary.assistant_fallback(hostile) == :error
    end
  end

  test "legacy flat positive evidence without call role and unsafe ids never warn" do
    legacy = %{
      id: "evt_legacy",
      session_id: "sid",
      seq: 1,
      type: :provider_usage,
      data: %{"provider_metadata" => %{"truncated" => true, "stop_reason" => "max_tokens"}}
    }

    assert OutputTruncationSummary.project(legacy)["status"] == "truncated"
    assert OutputTruncationSummary.warning(legacy) == nil

    hostile = usage_event(2, "evt\ninjected")
    assert OutputTruncationSummary.warning(hostile) == nil
    assert Pixir.Renderer.render(hostile) == []
    refute inspect(OutputTruncationSummary.project(hostile)) =~ "injected"
  end

  test "historical provider usage is counted as explicit unknown without mutation" do
    event = %{id: "evt_old", session_id: "sid", seq: 7, type: :provider_usage, data: %{}}
    before = event
    summary = OutputTruncationSummary.summarize([event])

    assert summary["counts"]["unknown"] == 1
    assert summary["latest"]["reason"] == "historical_evidence_absent"
    assert event == before
  end

  test "child context suffix exposes only bounded count and neutral enums" do
    warning = child_warning("evt_suffix", 1, "provider_output_limit")

    suffix =
      OutputTruncationSummary.child_context_suffix(%{
        "child_session_id" => "child_suffix",
        "output_warning_count" => 1_000_000,
        "output_warnings" => [warning],
        "output_warnings_truncated" => true,
        "output_warning_reasons" => ["provider_output_limit", "unsafe"]
      })

    assert suffix =~ "call_count=999999+"
    assert suffix =~ "reasons=provider_output_limit"
    refute suffix =~ "unsafe"
    assert byte_size(suffix) <= 192

    assert OutputTruncationSummary.child_context_suffix(%{
             "output_warning_count" => 1,
             "output_warnings" => []
           }) == ""
  end

  test "child aggregate normalization retains canonical first 64 and an honest latest key" do
    warnings =
      for seq <- 1..65 do
        child_warning(
          "evt_#{String.pad_leading(Integer.to_string(seq), 3, "0")}",
          seq,
          "provider_output_limit"
        )
      end

    normalized =
      OutputTruncationSummary.normalize_child_output(%{
        "child_session_id" => "child_suffix",
        "output_warning_count" => 65,
        "output_warnings" => warnings ++ [%{"unsafe" => String.duplicate("x", 10_000)}],
        "output_warnings_truncated" => true,
        "output_warning_reasons" => ["provider_content_filter", "unsafe"],
        "output_truncation" => %{
          "status" => "truncated",
          "reason" => "provider_output_limit",
          "provider_reason" => "max_tokens",
          "provider_usage_event_id" => "evt_final",
          "provider_usage_seq" => 70,
          "call_role" => "final_answer"
        }
      })

    assert normalized["output_warning_count"] == 65
    assert length(normalized["output_warnings"]) == 64
    assert hd(normalized["output_warnings"])["provider_usage_seq"] == 1
    assert List.last(normalized["output_warnings"])["provider_usage_seq"] == 64
    assert normalized["output_latest_warning_order_key"] == {70, "evt_final"}
    assert normalized["output_warnings_truncated"]

    assert normalized["output_warning_reasons"] == [
             "provider_content_filter",
             "provider_output_limit"
           ]

    assert OutputTruncationSummary.child_context_suffix(
             Map.merge(%{"child_session_id" => "child_suffix"}, normalized)
           ) =~
             "reasons=provider_content_filter,provider_output_limit"

    improper_tail =
      warnings
      |> Enum.take(64)
      |> Enum.reverse()
      |> Enum.reduce(:must_not_be_traversed, fn warning, tail -> [warning | tail] end)

    bounded =
      OutputTruncationSummary.normalize_child_output(%{
        "child_session_id" => "child_suffix",
        "output_warning_count" => 64,
        "output_warnings" => improper_tail,
        "output_warnings_truncated" => false
      })

    assert length(bounded["output_warnings"]) == 64

    contradictory =
      OutputTruncationSummary.normalize_child_output(%{
        "output_warning_count" => 1,
        "output_warnings" => [],
        "output_warnings_truncated" => true
      })

    assert contradictory["output_warning_count"] == 0
    assert contradictory["output_warnings"] == []
    refute contradictory["output_warnings_truncated"]
  end

  test "finalized tool calls require bounded identities and a JSON object" do
    assert {:ok, %{args: %{}}} = ToolCall.from_json("c", "read", "{}")

    assert {:ok, %{call_id: call_159}} =
             ToolCall.from_json(String.duplicate("c", 159), "n", "{}")

    assert byte_size(call_159) == 159

    assert {:ok, %{name: name_63}} =
             ToolCall.from_json("c", String.duplicate("n", 63), "{}")

    assert byte_size(name_63) == 63

    assert {:ok, %{call_id: call_id, name: name}} =
             ToolCall.from_json(String.duplicate("c", 160), String.duplicate("n", 64), "{}")

    assert byte_size(call_id) == 160
    assert byte_size(name) == 64

    for args <- [nil, "", "null", "[]", "1", "bad"] do
      assert {:error, %{error: %{kind: :invalid_response}}} =
               ToolCall.from_json("c", "read", args)
    end

    for {field, call_id, name} <- [
          {:call_id, "", "read"},
          {:call_id, String.duplicate("a", 161), "read"},
          {:call_id, "bad/id", "read"},
          {:call_id, "bad\nid", "read"},
          {:name, "call", ""},
          {:name, "call", String.duplicate("a", 65)},
          {:name, "call", "bad name"},
          {:name, "call", "bad/name"},
          {:call_id, <<255>>, "read"},
          {:name, "call", <<255>>}
        ] do
      assert {:error, %{error: %{kind: :invalid_response, details: details}}} =
               ToolCall.from_json(call_id, name, "{}")

      assert details.field == field
      refute inspect(details) =~ "bad name"
    end
  end

  test "Renderer warning is stderr-only and preserves the exact prescribed text" do
    event = usage_event(9, "evt_render")

    assert [{:stderr, warning}] = Pixir.Renderer.render(event)

    assert warning ==
             "warning: provider output was truncated (reason=provider_output_limit, " <>
               "call=evt_render); showing provider text exactly as received\n"
  end

  defp usage_event(seq, id) do
    %{
      id: id,
      session_id: "sid",
      seq: seq,
      type: :provider_usage,
      data: %{
        "output_truncation" => %{
          "status" => "truncated",
          "reason" => "provider_output_limit",
          "provider_reason" => "max_tokens",
          "provider_usage_event_id" => id,
          "call_role" => "intermediate"
        }
      }
    }
  end

  defp assistant_fallback_event do
    %{
      id: "assistant",
      session_id: "sid",
      seq: 13,
      type: :assistant_message,
      data: %{
        "text" => "exact",
        "metadata" => %{
          "output_truncation" => %{
            "status" => "truncated",
            "reason" => "provider_output_limit",
            "provider_reason" => "max_tokens",
            "provider_usage_event_id" => "evt_fallback",
            "provider_usage_seq" => 12,
            "call_role" => "final_answer"
          }
        }
      }
    }
  end

  defp child_warning(id, seq, reason) do
    %{
      "kind" => "provider_output_truncated",
      "severity" => "warning",
      "child_session_id" => "child_suffix",
      "provider_usage_event_id" => id,
      "provider_usage_seq" => seq,
      "call_role" => "final_answer",
      "reason" => reason,
      "provider_reason" => "max_tokens"
    }
  end
end
