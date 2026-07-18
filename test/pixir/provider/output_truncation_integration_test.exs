defmodule Pixir.Provider.OutputTruncationIntegrationTest do
  use ExUnit.Case, async: false

  alias Pixir.{Auth, Event, Provider}
  alias Pixir.Provider.{OutputTruncation, WebSocketClient}
  alias Pixir.Providers.Anthropic

  setup do
    suffix = System.unique_integer([:positive])
    name = String.to_atom("truncation_auth_#{suffix}")
    path = Path.join(System.tmp_dir!(), "pixir-truncation-auth-#{suffix}.json")
    {:ok, pid} = Auth.start_link(name: name, store_path: path, env_api_key: "fixture-token")

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
      File.rm_rf!(path)
    end)

    %{auth: name}
  end

  test "Responses maps every accepted completed/incomplete terminal without cap inference", %{
    auth: auth
  } do
    rows = [
      {%{type: "response.completed", response: %{usage: usage()}}, :not_truncated, nil},
      {incomplete("max_output_tokens"), :truncated, :provider_output_limit},
      {incomplete("max_tokens"), :truncated, :provider_output_limit},
      {incomplete("content_filter"), :truncated, :provider_content_filter},
      {incomplete(nil), :unknown, :missing_terminal_evidence},
      {incomplete("future_reason"), :unknown, :unrecognized_terminal_reason},
      {%{
         type: "response.completed",
         response: %{
           status: "incomplete",
           incomplete_details: %{reason: "max_output_tokens"},
           usage: usage()
         }
       }, :truncated, :provider_output_limit}
    ]

    Enum.each(rows, fn {terminal, status, reason} ->
      {:ok, result} =
        Provider.stream(request(),
          auth: auth,
          transport: canned([sse(terminal)]),
          max_retries: 0
        )

      assert OutputTruncation.status(result.output_truncation) == status
      assert OutputTruncation.reason(result.output_truncation) == reason
    end)

    # Usage exactly at an arbitrary requested cap does not alter completed evidence.
    {:ok, completed} =
      Provider.stream(request(),
        auth: auth,
        transport:
          canned([
            sse(%{type: "response.output_text.delta", delta: "12345"}),
            sse(%{type: "response.completed", response: %{usage: usage(5)}})
          ]),
        max_retries: 0
      )

    assert OutputTruncation.status(completed.output_truncation) == :not_truncated
  end

  test "Responses 2xx close without lifecycle terminal is explicit uncertainty", %{auth: auth} do
    {:ok, result} =
      Provider.stream(request(),
        auth: auth,
        transport: canned([sse(%{type: "response.output_text.delta", delta: "exact"})]),
        max_retries: 0
      )

    assert result.text == "exact"
    assert OutputTruncation.status(result.output_truncation) == :unknown
    assert OutputTruncation.reason(result.output_truncation) == :missing_terminal_evidence
  end

  test "Responses rejects malformed incomplete_details as successful invalid uncertainty", %{
    auth: auth
  } do
    malformed = [[], "bad-details", 7, true, false]

    for details <- malformed,
        event <- [
          %{
            type: "response.incomplete",
            response: %{status: "incomplete", incomplete_details: details}
          },
          %{
            type: "response.completed",
            response: %{status: "incomplete", incomplete_details: details}
          },
          %{
            type: "response.completed",
            response: %{status: "completed", incomplete_details: details}
          },
          %{
            type: "response.incomplete",
            incomplete_details: details,
            response: %{status: "incomplete"}
          },
          %{
            type: "response.completed",
            incomplete_details: details,
            response: %{status: "completed"}
          }
        ] do
      assert {:ok, result} =
               Provider.stream(request(),
                 auth: auth,
                 transport: canned([sse(event)]),
                 max_retries: 0
               )

      assert OutputTruncation.status(result.output_truncation) == :unknown
      assert OutputTruncation.reason(result.output_truncation) == :invalid_evidence
    end

    nested_malformed = %{
      type: "response.incomplete",
      incomplete_details: %{reason: "max_tokens"},
      response: %{status: "incomplete", incomplete_details: "nested-bad"}
    }

    assert {:ok, nested_result} =
             Provider.stream(request(),
               auth: auth,
               transport: canned([sse(nested_malformed)]),
               max_retries: 0
             )

    assert OutputTruncation.reason(nested_result.output_truncation) == :invalid_evidence
  end

  test "Responses completed distinguishes absent nil empty valid and malformed details", %{
    auth: auth
  } do
    rows = [
      {%{type: "response.completed", response: %{status: "completed"}}, :not_truncated, nil},
      {%{
         type: "response.completed",
         response: %{status: "completed", incomplete_details: nil}
       }, :not_truncated, nil},
      {%{
         type: "response.completed",
         response: %{status: "completed", incomplete_details: %{}}
       }, :unknown, :missing_terminal_evidence},
      {%{
         type: "response.completed",
         response: %{
           status: "completed",
           incomplete_details: %{reason: "max_output_tokens"}
         }
       }, :truncated, :provider_output_limit},
      {%{
         type: "response.incomplete",
         response: %{status: "incomplete", incomplete_details: %{reason: "content_filter"}}
       }, :truncated, :provider_content_filter}
    ]

    for {event, status, reason} <- rows do
      assert {:ok, result} =
               Provider.stream(request(),
                 auth: auth,
                 transport: canned([sse(event)]),
                 max_retries: 0
               )

      assert OutputTruncation.status(result.output_truncation) == status
      assert OutputTruncation.reason(result.output_truncation) == reason
    end
  end

  test "Responses non-map terminal response is invalid uncertainty without retry", %{auth: auth} do
    for response <- [[], "bad-response", 7, true, false],
        type <- ["response.completed", "response.incomplete"] do
      {:ok, attempts} = Agent.start_link(fn -> 0 end)

      transport = fn _request, acc, fun ->
        Agent.update(attempts, &(&1 + 1))
        acc = fun.({:status, 200}, acc)

        event = %{"type" => type, "response" => response, "usage" => usage()}
        {:ok, fun.({:data, sse(event)}, acc)}
      end

      assert {:ok, result} =
               Provider.stream(request(),
                 auth: auth,
                 transport: transport,
                 max_retries: 2,
                 sleep: fn _ -> flunk("successful invalid evidence must not retry") end
               )

      assert Agent.get(attempts, & &1) == 1
      assert OutputTruncation.status(result.output_truncation) == :unknown
      assert OutputTruncation.reason(result.output_truncation) == :invalid_evidence
      assert result.usage["input_tokens"] == 3
    end
  end

  test "Anthropic non-map message delta is invalid uncertainty without retry or fallback" do
    for delta <- [[], "bad-delta", 7, true, false] do
      {:ok, attempts} = Agent.start_link(fn -> 0 end)

      transport = fn _request, acc, fun ->
        Agent.update(attempts, &(&1 + 1))
        acc = fun.({:status, 200}, acc)

        chunk =
          anthropic_sse("message_delta", %{
            type: "message_delta",
            delta: delta,
            stop_reason: "max_tokens",
            usage: %{input_tokens: 3, output_tokens: 2}
          })

        {:ok, fun.({:data, chunk}, acc)}
      end

      assert {:ok, result} =
               Anthropic.stream(anthropic_request(),
                 api_key: "fixture-token",
                 transport: transport,
                 max_retries: 2,
                 sleep: fn _ -> flunk("successful invalid evidence must not retry") end
               )

      assert Agent.get(attempts, & &1) == 1
      assert OutputTruncation.status(result.output_truncation) == :unknown
      assert OutputTruncation.reason(result.output_truncation) == :invalid_evidence
      refute result.provider_metadata["unmapped_stop_reason"] == "max_tokens"
    end

    retained_invalid_transport = fn _request, acc, fun ->
      acc = fun.({:status, 200}, acc)

      malformed =
        anthropic_sse("message_delta", %{
          type: "message_delta",
          delta: [],
          stop_reason: "max_tokens"
        })

      acc = fun.({:data, malformed}, acc)
      {:ok, fun.({:data, anthropic_delta("end_turn")}, acc)}
    end

    assert {:ok, retained_invalid} =
             Anthropic.stream(anthropic_request(),
               api_key: "fixture-token",
               transport: retained_invalid_transport,
               max_retries: 2
             )

    assert OutputTruncation.reason(retained_invalid.output_truncation) == :invalid_evidence

    nil_transport = fn _request, acc, fun ->
      acc = fun.({:status, 200}, acc)

      chunk =
        anthropic_sse("message_delta", %{
          type: "message_delta",
          delta: nil,
          stop_reason: "max_tokens"
        })

      {:ok, fun.({:data, chunk}, acc)}
    end

    assert {:ok, nil_result} =
             Anthropic.stream(anthropic_request(),
               api_key: "fixture-token",
               transport: nil_transport,
               max_retries: 2
             )

    assert OutputTruncation.status(nil_result.output_truncation) == :truncated
    assert OutputTruncation.reason(nil_result.output_truncation) == :provider_output_limit
  end

  test "Anthropic malformed usage is ignored without retrying terminal evidence" do
    malformed_values = [[], "bad-value", 7, true, false]

    for delta <- malformed_values, usage <- malformed_values do
      {:ok, attempts} = Agent.start_link(fn -> 0 end)

      transport = fn _request, acc, fun ->
        Agent.update(attempts, &(&1 + 1))
        acc = fun.({:status, 200}, acc)

        chunk =
          anthropic_sse("message_delta", %{
            type: "message_delta",
            delta: delta,
            stop_reason: "max_tokens",
            usage: usage
          })

        {:ok, fun.({:data, chunk}, acc)}
      end

      assert {:ok, result} =
               Anthropic.stream(anthropic_request(),
                 api_key: "fixture-token",
                 transport: transport,
                 max_retries: 2,
                 sleep: fn _ -> flunk("malformed usage must not trigger a retry") end
               )

      assert Agent.get(attempts, & &1) == 1
      assert OutputTruncation.status(result.output_truncation) == :unknown
      assert OutputTruncation.reason(result.output_truncation) == :invalid_evidence
      refute result.provider_metadata["unmapped_stop_reason"] == "max_tokens"
    end

    for usage <- malformed_values do
      {:ok, attempts} = Agent.start_link(fn -> 0 end)

      transport = fn _request, acc, fun ->
        Agent.update(attempts, &(&1 + 1))
        acc = fun.({:status, 200}, acc)

        chunk =
          anthropic_sse("message_delta", %{
            type: "message_delta",
            delta: %{stop_reason: "end_turn", usage: %{input_tokens: 99}},
            usage: usage
          })

        {:ok, fun.({:data, chunk}, acc)}
      end

      assert {:ok, result} =
               Anthropic.stream(anthropic_request(),
                 api_key: "fixture-token",
                 transport: transport,
                 max_retries: 2,
                 sleep: fn _ -> flunk("malformed usage must not trigger a retry") end
               )

      assert Agent.get(attempts, & &1) == 1
      assert OutputTruncation.status(result.output_truncation) == :not_truncated
      assert is_nil(OutputTruncation.reason(result.output_truncation))
      assert is_nil(result.usage)
    end

    for usage <- malformed_values do
      {:ok, attempts} = Agent.start_link(fn -> 0 end)

      transport = fn _request, acc, fun ->
        Agent.update(attempts, &(&1 + 1))
        acc = fun.({:status, 200}, acc)

        start =
          anthropic_sse("message_start", %{
            type: "message_start",
            message: %{usage: usage},
            usage: %{input_tokens: 99}
          })

        acc = fun.({:data, start}, acc)
        {:ok, fun.({:data, anthropic_delta("end_turn")}, acc)}
      end

      assert {:ok, result} =
               Anthropic.stream(anthropic_request(),
                 api_key: "fixture-token",
                 transport: transport,
                 max_retries: 2,
                 sleep: fn _ -> flunk("malformed usage must not trigger a retry") end
               )

      assert Agent.get(attempts, & &1) == 1
      assert OutputTruncation.status(result.output_truncation) == :not_truncated
      assert is_nil(result.usage)
    end
  end

  test "built-in unmapped terminal token boundaries never echo unsafe evidence", %{auth: auth} do
    for {token, reason, retained?} <- [
          {"x", :unrecognized_terminal_reason, true},
          {String.duplicate("a", 64), :unrecognized_terminal_reason, true},
          {"", :invalid_evidence, false},
          {String.duplicate("a", 65), :invalid_evidence, false},
          {"bad token", :invalid_evidence, false}
        ] do
      {:ok, result} =
        Provider.stream(request(),
          auth: auth,
          transport: canned([sse(incomplete(token))]),
          max_retries: 0
        )

      assert OutputTruncation.reason(result.output_truncation) == reason

      if retained? do
        assert OutputTruncation.provider_reason(result.output_truncation) == token
      else
        assert OutputTruncation.provider_reason(result.output_truncation) == nil
        refute inspect(result.output_truncation) =~ inspect(token)
      end
    end
  end

  test "Responses rejects conflicting terminals and finalized malformed calls before execution",
       %{
         auth: auth
       } do
    assert {:error, %{error: %{kind: :invalid_response}}} =
             Provider.stream(request(),
               auth: auth,
               transport:
                 canned([
                   sse(%{type: "response.completed", response: %{usage: usage()}}),
                   sse(incomplete("max_tokens"))
                 ]),
               max_retries: 0
             )

    for arguments <- [nil, "", "null", "[]", "bad"] do
      assert {:error, %{error: %{kind: :invalid_response}}} =
               Provider.stream(request(),
                 auth: auth,
                 transport:
                   canned([
                     sse(%{
                       type: "response.output_item.done",
                       item: %{
                         type: "function_call",
                         call_id: "call_1",
                         name: "read",
                         arguments: arguments
                       }
                     }),
                     sse(%{type: "response.completed", response: %{usage: usage()}})
                   ]),
                 max_retries: 0
               )
    end
  end

  test "already-buffered WebSocket terminal conflict reaches the Responses reducer", %{auth: auth} do
    completed = Jason.encode!(%{type: "response.completed", response: %{usage: usage()}})
    incomplete = Jason.encode!(incomplete("max_tokens"))
    split = div(byte_size(incomplete), 3)
    <<first::binary-size(^split), rest::binary>> = incomplete
    <<second::binary-size(^split), third::binary>> = rest

    buffer =
      server_text_frame(completed) <>
        server_frame(0x1, false, first) <>
        server_frame(0x9, true, "ping") <>
        server_frame(0x0, false, second) <>
        server_frame(0xA, true, "pong") <>
        server_frame(0x0, true, third)

    transport = fn _request, acc, fun ->
      acc = fun.({:status, 200}, acc)
      {:ok, WebSocketClient.fold_buffered_terminal_frames(buffer, acc, fun)}
    end

    assert {:error, %{error: %{kind: :invalid_response}}} =
             Provider.stream(request(), auth: auth, transport: transport, max_retries: 0)

    single = server_text_frame(completed)

    single_transport = fn _request, acc, fun ->
      acc = fun.({:status, 200}, acc)
      {:ok, WebSocketClient.fold_buffered_terminal_frames(single, acc, fun)}
    end

    assert {:ok, result} =
             Provider.stream(request(), auth: auth, transport: single_transport, max_retries: 0)

    assert OutputTruncation.status(result.output_truncation) == :not_truncated
  end

  test "Anthropic maps terminal vocabulary and preserves complete-call operation" do
    for {stop_reason, status, reason, finish} <- [
          {"end_turn", :not_truncated, nil, :stop},
          {"stop_sequence", :not_truncated, nil, :stop},
          {"max_tokens", :truncated, :provider_output_limit, :stop},
          {"model_context_window_exceeded", :truncated, :provider_context_window_limit, :stop},
          {"pause_turn", :unknown, :unrecognized_terminal_reason, :stop},
          {nil, :unknown, :missing_terminal_evidence, :stop}
        ] do
      chunks = if stop_reason, do: [anthropic_delta(stop_reason)], else: []

      {:ok, result} =
        Anthropic.stream(anthropic_request(),
          api_key: "fixture-token",
          transport: canned(chunks),
          max_retries: 0
        )

      assert OutputTruncation.status(result.output_truncation) == status
      assert OutputTruncation.reason(result.output_truncation) == reason
      assert result.finish_reason == finish
    end

    {:ok, result} =
      Anthropic.stream(anthropic_request(),
        api_key: "fixture-token",
        transport:
          canned([
            anthropic_sse("content_block_start", %{
              type: "content_block_start",
              index: 0,
              content_block: %{type: "tool_use", id: "call_1", name: "read", input: %{}}
            }),
            anthropic_sse("content_block_stop", %{type: "content_block_stop", index: 0}),
            anthropic_delta("model_context_window_exceeded")
          ]),
        max_retries: 0
      )

    assert result.finish_reason == :tool_calls
    assert [%{call_id: "call_1", args: %{}}] = result.function_calls
  end

  test "Anthropic unmapped token boundaries never leak unsafe stop reasons" do
    for {token, expected_reason, retained?} <- [
          {"x", :unrecognized_terminal_reason, true},
          {String.duplicate("a", 64), :unrecognized_terminal_reason, true},
          {String.duplicate("a", 65), :invalid_evidence, false},
          {"unsafe token", :invalid_evidence, false},
          {"unsafe/control\nline", :invalid_evidence, false}
        ] do
      {:ok, result} =
        Anthropic.stream(anthropic_request(),
          api_key: "fixture-token",
          transport: canned([anthropic_delta(token)]),
          max_retries: 0
        )

      assert OutputTruncation.reason(result.output_truncation) == expected_reason

      if retained? do
        assert result.provider_metadata["unmapped_stop_reason"] == token
      else
        refute Map.has_key?(result.provider_metadata, "unmapped_stop_reason")
        refute inspect(result) =~ token
      end
    end
  end

  test "Anthropic tool_use is complete and truncated complete+partial mixtures omit unfinished calls" do
    complete_start =
      anthropic_sse("content_block_start", %{
        type: "content_block_start",
        index: 0,
        content_block: %{type: "tool_use", id: "call_complete", name: "read", input: %{}}
      })

    partial_start =
      anthropic_sse("content_block_start", %{
        type: "content_block_start",
        index: 1,
        content_block: %{type: "tool_use", id: "call_partial", name: "write", input: %{}}
      })

    for {stop_reason, expected_status} <- [
          {"tool_use", :not_truncated},
          {"max_tokens", :truncated},
          {"model_context_window_exceeded", :truncated}
        ] do
      {:ok, result} =
        Anthropic.stream(anthropic_request(),
          api_key: "fixture-token",
          transport:
            canned([
              complete_start,
              anthropic_sse("content_block_stop", %{type: "content_block_stop", index: 0}),
              partial_start,
              anthropic_delta(stop_reason)
            ]),
          max_retries: 0
        )

      assert result.finish_reason == :tool_calls
      assert Enum.map(result.function_calls, & &1.call_id) == ["call_complete"]
      assert OutputTruncation.status(result.output_truncation) == expected_status
    end
  end

  test "Anthropic refusal remains an error without successful neutral evidence" do
    assert {:error, %{error: %{kind: :provider_refusal}}} =
             Anthropic.stream(anthropic_request(),
               api_key: "fixture-token",
               transport: canned([anthropic_delta("refusal")]),
               max_retries: 0
             )
  end

  test "both Provider folds refuse contradictory count-only child warning suffixes" do
    terminal =
      Event.subagent_event("sid", %{
        "event" => "finished",
        "subagent_id" => "sub_count_only",
        "child_session_id" => "child_count_only",
        "agent" => "default",
        "status" => "completed",
        "summary" => "exact summary",
        "output_warning_count" => 1,
        "output_warnings" => [],
        "output_warnings_truncated" => false
      })

    openai_request = %{request() | history: [terminal]}
    assert {:ok, body} = Provider.request_body_preview(openai_request)
    refute Jason.encode!(body) =~ "Pixir output warning"

    parent = self()

    transport = fn request, acc, fun ->
      send(parent, {:anthropic_request, request})
      acc = fun.({:status, 200}, acc)
      {:ok, fun.({:data, anthropic_delta("end_turn")}, acc)}
    end

    assert {:ok, _result} =
             Anthropic.stream(%{anthropic_request() | history: [terminal]},
               api_key: "fixture-token",
               transport: transport,
               max_retries: 0
             )

    assert_received {:anthropic_request, request}
    refute inspect(request) =~ "Pixir output warning"
  end

  defp request do
    %{
      model: "gpt-5.5",
      system_prompt: "system",
      developer_context: "context",
      history: [Event.user_message("sid", "hello")],
      tools: []
    }
  end

  defp anthropic_request do
    %{
      model: "claude-fable-5",
      system_prompt: "system",
      history: [Event.user_message("sid", "hello")],
      tools: []
    }
  end

  defp incomplete(reason) do
    details = if is_nil(reason), do: %{}, else: %{reason: reason}

    %{
      type: "response.incomplete",
      response: %{status: "incomplete", incomplete_details: details, usage: usage()}
    }
  end

  defp usage(output_tokens \\ 2) do
    %{input_tokens: 3, output_tokens: output_tokens, total_tokens: 3 + output_tokens}
  end

  defp canned(chunks) do
    fn _request, acc, fun ->
      acc = fun.({:status, 200}, acc)
      acc = Enum.reduce(chunks, acc, fn chunk, current -> fun.({:data, chunk}, current) end)
      {:ok, acc}
    end
  end

  defp sse(event), do: "data: " <> Jason.encode!(event) <> "\n\n"

  defp anthropic_delta(reason) do
    anthropic_sse("message_delta", %{
      type: "message_delta",
      delta: %{stop_reason: reason}
    })
  end

  defp anthropic_sse(name, event),
    do: "event: #{name}\ndata: " <> Jason.encode!(event) <> "\n\n"

  defp server_text_frame(payload) when byte_size(payload) < 126,
    do: server_frame(0x1, true, payload)

  defp server_text_frame(payload) when byte_size(payload) < 65_536,
    do: server_frame(0x1, true, payload)

  defp server_frame(opcode, fin, payload) do
    first = if fin, do: 0x80 + opcode, else: opcode
    length = byte_size(payload)

    header =
      if length < 126,
        do: <<first, length>>,
        else: <<first, 126, length::16>>

    header <> payload
  end
end
