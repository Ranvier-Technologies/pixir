defmodule Pixir.Providers.AnthropicFoldTest do
  # Pure projection/fold coverage: no shared global state, safe to parallelize.
  # The Turn.run proofs live in Pixir.Providers.AnthropicTurnProofTest below
  # (async: false) because they use SessionSupervisor-backed sessions.
  use ExUnit.Case, async: true

  alias Pixir.Providers.Anthropic
  alias Pixir.Providers.Anthropic.Tools, as: AnthropicTools

  defp sse(map), do: "data: " <> Jason.encode!(map) <> "\n\n"

  defp capture_transport(chunks, test_pid \\ self()) do
    fn http_request, acc, fun ->
      send(test_pid, {:anthropic_body, Jason.decode!(http_request.body)})
      acc = fun.({:status, 200}, acc)

      Enum.reduce(chunks, acc, fn chunk, a -> fun.({:data, chunk}, a) end)
      |> then(&{:ok, &1})
    end
  end

  defp ok_chunks(text \\ "ok") do
    [
      sse(%{
        type: "message_start",
        message: %{model: "claude-fable-5", usage: %{input_tokens: 1, output_tokens: 0}}
      }),
      sse(%{type: "content_block_start", index: 0, content_block: %{type: "text", text: ""}}),
      sse(%{type: "content_block_delta", index: 0, delta: %{type: "text_delta", text: text}}),
      sse(%{
        type: "message_delta",
        delta: %{stop_reason: "end_turn"},
        usage: %{output_tokens: 1}
      }),
      sse(%{type: "message_stop"})
    ]
  end

  defp raw(line), do: Jason.decode!(line)

  describe "tool projection" do
    test "projects Responses function tools to Anthropic shape preserving order" do
      tools = [
        %{
          "type" => "function",
          "name" => "b",
          "description" => "B",
          "parameters" => %{"type" => "object"}
        },
        %{
          "type" => "function",
          "name" => "a",
          "description" => "A",
          "parameters" => %{"type" => "object", "properties" => %{}}
        }
      ]

      assert {:ok,
              [
                %{"name" => "b", "description" => "B", "input_schema" => %{"type" => "object"}},
                %{
                  "name" => "a",
                  "description" => "A",
                  "input_schema" => %{"type" => "object", "properties" => %{}}
                }
              ]} = AnthropicTools.project(tools)
    end

    test "rejects hosted or unknown entries fail-closed" do
      assert {:error,
              %{
                error: %{
                  kind: :invalid_args,
                  details: %{field: :tools, unsupported_capability: "provider_hosted_tools"}
                }
              }} = AnthropicTools.project([%{"type" => "web_search_preview", "name" => "web"}])
    end
  end

  describe "history fold request shape" do
    test "folds text messages from raw NDJSON history" do
      history = [
        raw(~s({"type":"user_message","data":{"text":"hello"}})),
        raw(~s({"type":"assistant_message","data":{"text":"hi"}}))
      ]

      assert {:ok, _} =
               Anthropic.stream(%{history: history},
                 api_key: "sk-ant-test",
                 model: "claude-fable-5",
                 transport: capture_transport(ok_chunks())
               )

      assert_received {:anthropic_body, body}

      assert body["messages"] == [
               %{"role" => "user", "content" => [%{"type" => "text", "text" => "hello"}]},
               %{"role" => "assistant", "content" => [%{"type" => "text", "text" => "hi"}]}
             ]
    end

    test "folds a tool call and its result as assistant tool_use then grouped user tool_result" do
      history = [
        raw(~s({"type":"user_message","data":{"text":"read it"}})),
        raw(~s({"type":"provider_usage","data":{"model":"claude-fable-5"}})),
        raw(
          ~s({"type":"tool_call","data":{"call_id":"toolu_1","name":"read","args":{"path":"a.txt"}}})
        ),
        raw(
          ~s({"type":"tool_result","data":{"call_id":"toolu_1","ok":true,"output":"file text"}})
        )
      ]

      assert {:ok, _} =
               Anthropic.stream(%{history: history},
                 api_key: "sk-ant-test",
                 model: "claude-fable-5",
                 transport: capture_transport(ok_chunks())
               )

      assert_received {:anthropic_body, body}

      assert body["messages"] == [
               %{"role" => "user", "content" => [%{"type" => "text", "text" => "read it"}]},
               %{
                 "role" => "assistant",
                 "content" => [
                   %{
                     "type" => "tool_use",
                     "id" => "toolu_1",
                     "name" => "read",
                     "input" => %{"path" => "a.txt"}
                   }
                 ]
               },
               %{
                 "role" => "user",
                 "content" => [
                   %{
                     "type" => "tool_result",
                     "tool_use_id" => "toolu_1",
                     "content" => "file text"
                   }
                 ]
               }
             ]
    end

    test "groups parallel tool results into one following user message and maps errors" do
      history = [
        raw(~s({"type":"user_message","data":{"text":"do both"}})),
        raw(
          ~s({"type":"tool_call","data":{"call_id":"toolu_1","name":"read","args":{"path":"a.txt"}}})
        ),
        raw(
          ~s({"type":"tool_call","data":{"call_id":"toolu_2","name":"bash","args":{"command":"false"}}})
        ),
        raw(~s({"type":"tool_result","data":{"call_id":"toolu_1","ok":true,"output":"A"}})),
        raw(
          ~s({"type":"tool_result","data":{"call_id":"toolu_2","ok":false,"error":{"kind":"bash_disabled","message":"no shell"}}})
        )
      ]

      assert {:ok, _} =
               Anthropic.stream(%{history: history},
                 api_key: "sk-ant-test",
                 model: "claude-fable-5",
                 transport: capture_transport(ok_chunks())
               )

      assert_received {:anthropic_body, body}
      [_, assistant, user_results] = body["messages"]
      assert length(assistant["content"]) == 2
      assert user_results["role"] == "user"
      assert [ok, err] = user_results["content"]
      assert ok == %{"type" => "tool_result", "tool_use_id" => "toolu_1", "content" => "A"}
      assert err["tool_use_id"] == "toolu_2"
      # Content mirrors the OpenAI fold's tool_output_text: the full result JSON
      # minus call_id; is_error is the Anthropic-only addition.
      assert Jason.decode!(err["content"]) == %{
               "ok" => false,
               "error" => %{"kind" => "bash_disabled", "message" => "no shell"}
             }

      assert err["is_error"] == true
    end

    test "explicit messages take precedence over history" do
      history = [raw(~s({"type":"user_message","data":{"text":"from history"}}))]
      messages = [%{"role" => "user", "content" => [%{"type" => "text", "text" => "explicit"}]}]

      assert {:ok, _} =
               Anthropic.stream(%{history: history, messages: messages},
                 api_key: "sk-ant-test",
                 model: "claude-fable-5",
                 transport: capture_transport(ok_chunks())
               )

      assert_received {:anthropic_body, body}
      assert body["messages"] == messages
    end

    test "re-injects anthropic-dialect thinking verbatim next to tool_use; drops foreign reasoning" do
      thinking = %{
        "type" => "thinking",
        "thinking" => "let me look",
        "signature" => "sig+/= untouched"
      }

      history = [
        raw(~s({"type":"user_message","data":{"text":"read it"}})),
        raw(
          ~s({"type":"reasoning","data":{"dialect":"anthropic","model":"claude-fable-5","item":{"type":"thinking","thinking":"let me look","signature":"sig+/= untouched"}}})
        ),
        raw(
          ~s({"type":"reasoning","data":{"model":"claude-fable-5","item":{"type":"reasoning","id":"rs_old","encrypted_content":"abc"}}})
        ),
        raw(
          ~s({"type":"reasoning","data":{"dialect":"anthropic","model":"claude-other","item":{"type":"thinking","thinking":"stale","signature":"x"}}})
        ),
        raw(
          ~s({"type":"tool_call","data":{"call_id":"toolu_1","name":"read","args":{"path":"a.txt"}}})
        ),
        raw(~s({"type":"tool_result","data":{"call_id":"toolu_1","ok":true,"output":"A"}}))
      ]

      assert {:ok, _} =
               Anthropic.stream(%{history: history},
                 api_key: "sk-ant-test",
                 model: "claude-fable-5",
                 transport: capture_transport(ok_chunks())
               )

      assert_received {:anthropic_body, body}
      [_user, assistant, _results] = body["messages"]

      # The matching-dialect block re-injects byte-identically in captured order
      # BEFORE its tool_use; the dialect-less OpenAI event and the cross-model
      # block both drop.
      assert assistant["content"] == [
               thinking,
               %{
                 "type" => "tool_use",
                 "id" => "toolu_1",
                 "name" => "read",
                 "input" => %{"path" => "a.txt"}
               }
             ]
    end
  end
end

defmodule Pixir.Providers.AnthropicTurnProofTest do
  # Session-backed Turn.run proofs: shared SessionSupervisor state, so this
  # module stays serialized per the test conventions.
  use ExUnit.Case, async: false

  alias Pixir.{Log, SessionSupervisor, Turn}
  alias Pixir.Providers.Anthropic

  defp sse(map), do: "data: " <> Jason.encode!(map) <> "\n\n"

  defp capture_transport(chunks, test_pid \\ self()) do
    fn http_request, acc, fun ->
      send(test_pid, {:anthropic_body, Jason.decode!(http_request.body)})
      acc = fun.({:status, 200}, acc)

      Enum.reduce(chunks, acc, fn chunk, a -> fun.({:data, chunk}, a) end)
      |> then(&{:ok, &1})
    end
  end

  defp ok_chunks(text) do
    [
      sse(%{
        type: "message_start",
        message: %{model: "claude-fable-5", usage: %{input_tokens: 1, output_tokens: 0}}
      }),
      sse(%{type: "content_block_start", index: 0, content_block: %{type: "text", text: ""}}),
      sse(%{type: "content_block_delta", index: 0, delta: %{type: "text_delta", text: text}}),
      sse(%{
        type: "message_delta",
        delta: %{stop_reason: "end_turn"},
        usage: %{output_tokens: 1}
      }),
      sse(%{type: "message_stop"})
    ]
  end

  setup do
    ws =
      Path.join(
        System.tmp_dir!(),
        "pixir-anthropic-turn-" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
      )

    File.mkdir_p!(ws)
    {:ok, sid, pid} = SessionSupervisor.start_session(workspace: ws, role: :build)

    on_exit(fn ->
      if Process.alive?(pid), do: DynamicSupervisor.terminate_child(SessionSupervisor, pid)
      File.rm_rf!(ws)
    end)

    %{ws: ws, sid: sid, ctx: %{session_id: sid, workspace: ws, role: :build}}
  end

  test "text-only Turn.run records pa1 usage without prompt_cache_key", %{
    ctx: ctx,
    sid: sid,
    ws: ws
  } do
    assert {:ok, "hello"} =
             Turn.run(ctx, "say hello",
               provider: Anthropic,
               provider_opts: [
                 api_key: "sk-ant-test",
                 model: "claude-fable-5",
                 transport: capture_transport(ok_chunks("hello"))
               ]
             )

    assert {:ok, history} = Log.fold(sid, workspace: ws)
    usage = Enum.find(history, &(&1.type == :provider_usage))
    assert usage.data["prompt_contract_version"] == "pa1"
    refute Map.has_key?(usage.data, "prompt_cache_key")
  end

  test "claude model id routes Turn to the Anthropic provider through the registry", %{
    ctx: ctx,
    sid: sid,
    ws: ws
  } do
    assert {:ok, "routed"} =
             Turn.run(ctx, "say routed",
               provider_opts: [
                 api_key: "sk-ant-test",
                 model: "claude-fable-5",
                 transport: capture_transport(ok_chunks("routed"))
               ]
             )

    assert_receive {:anthropic_body, body}
    assert body["model"] == "claude-fable-5"

    assert {:ok, history} = Log.fold(sid, workspace: ws)
    usage = Enum.find(history, &(&1.type == :provider_usage))
    assert usage.data["prompt_contract_version"] == "pa1"
    refute Map.has_key?(usage.data, "prompt_cache_key")
  end

  test "tool Turn.run preserves tool_use plus grouped tool_result continuity", %{
    ctx: ctx,
    sid: sid,
    ws: ws
  } do
    File.write!(Path.join(ws, "a.txt"), "hello from file")
    test = self()
    counter = :counters.new(1, [])

    transport = fn http_request, acc, fun ->
      send(test, {:anthropic_body, Jason.decode!(http_request.body)})
      attempt = :counters.get(counter, 1)
      :counters.add(counter, 1, 1)
      acc = fun.({:status, 200}, acc)

      chunks =
        if attempt == 0 do
          [
            sse(%{
              type: "message_start",
              message: %{model: "claude-fable-5", usage: %{input_tokens: 1}}
            }),
            sse(%{
              type: "content_block_start",
              index: 0,
              content_block: %{type: "thinking", thinking: "", signature: ""}
            }),
            sse(%{
              type: "content_block_delta",
              index: 0,
              delta: %{type: "thinking_delta", thinking: "check the file"}
            }),
            sse(%{
              type: "content_block_delta",
              index: 0,
              delta: %{type: "signature_delta", signature: "sig-proof"}
            }),
            sse(%{type: "content_block_stop", index: 0}),
            sse(%{
              type: "content_block_start",
              index: 1,
              content_block: %{type: "tool_use", id: "toolu_read", name: "read", input: %{}}
            }),
            sse(%{
              type: "content_block_delta",
              index: 1,
              delta: %{type: "input_json_delta", partial_json: ~s({"path":"a.txt"})}
            }),
            sse(%{type: "content_block_stop", index: 1}),
            sse(%{
              type: "message_delta",
              delta: %{stop_reason: "tool_use"},
              usage: %{output_tokens: 1}
            }),
            sse(%{type: "message_stop"})
          ]
        else
          ok_chunks("done")
        end

      Enum.reduce(chunks, acc, fn chunk, a -> fun.({:data, chunk}, a) end)
      |> then(&{:ok, &1})
    end

    assert {:ok, "done"} =
             Turn.run(ctx, "read a.txt",
               provider: Anthropic,
               provider_opts: [
                 api_key: "sk-ant-test",
                 model: "claude-fable-5",
                 transport: transport
               ]
             )

    assert_received {:anthropic_body, _first_body}
    assert_received {:anthropic_body, second_body}

    assert Enum.any?(second_body["messages"], fn message ->
             message["role"] == "assistant" and
               Enum.any?(
                 message["content"],
                 &(&1["type"] == "tool_use" and &1["id"] == "toolu_read")
               )
           end)

    assert Enum.any?(second_body["messages"], fn message ->
             message["role"] == "user" and
               Enum.any?(
                 message["content"],
                 &(&1["type"] == "tool_result" and &1["tool_use_id"] == "toolu_read" and
                     &1["content"] == "hello from file")
               )
           end)

    thinking_block = %{
      "type" => "thinking",
      "thinking" => "check the file",
      "signature" => "sig-proof"
    }

    # End-to-end dialect stamping (ADR 0037 D5): the persisted reasoning event
    # carries the Anthropic dialect and the verbatim block.
    assert {:ok, history} = Log.fold(sid, workspace: ws)
    reasoning = Enum.find(history, &(&1.type == :reasoning))
    assert reasoning.data["dialect"] == "anthropic"
    assert reasoning.data["model"] == "claude-fable-5"
    assert reasoning.data["item"] == thinking_block

    # And the second request re-injects it byte-identically BEFORE its tool_use.
    assistant =
      Enum.find(second_body["messages"], fn message ->
        message["role"] == "assistant" and
          Enum.any?(message["content"], &(&1["type"] == "tool_use"))
      end)

    assert [^thinking_block, %{"type" => "tool_use", "id" => "toolu_read"} = _tool_use] =
             assistant["content"]
  end
end
