defmodule Pixir.Providers.AnthropicTest do
  use ExUnit.Case, async: false

  alias Pixir.Providers.Anthropic

  defp canned(chunks, status \\ 200, headers \\ []) do
    test = self()

    fn http_request, acc, fun ->
      send(test, {:request, http_request})
      acc = fun.({:status, status}, acc)
      acc = fun.({:headers, headers}, acc)
      acc = Enum.reduce(chunks, acc, fn chunk, a -> fun.({:data, chunk}, a) end)
      {:ok, acc}
    end
  end

  defp canned_attempts(attempts) do
    test = self()
    {:ok, agent} = Agent.start_link(fn -> :queue.from_list(attempts) end)

    fn http_request, acc, fun ->
      send(test, {:request, http_request})

      {chunks, status} =
        Agent.get_and_update(agent, fn queue ->
          case :queue.out(queue) do
            {{:value, attempt}, rest} -> {attempt, rest}
            {:empty, empty} -> raise "no canned Anthropic attempt left: #{inspect(empty)}"
          end
        end)

      acc = fun.({:status, status}, acc)
      acc = fun.({:headers, []}, acc)
      acc = Enum.reduce(chunks, acc, fn chunk, current -> fun.({:data, chunk}, current) end)
      {:ok, acc}
    end
  end

  defp error_body_cases do
    cap = Pixir.Providers.ErrBody.max_bytes()

    [
      {"under", [String.duplicate("u", cap - 1)], false},
      {"exact", [String.duplicate("e", cap)], false},
      {"exact_chunked", [String.duplicate("c", div(cap, 2)), String.duplicate("d", div(cap, 2))],
       false},
      {"exact_then_empty", [String.duplicate("z", cap), ""], false},
      {"exact_then_one", [String.duplicate("y", cap), "x"], true},
      {"over_then_empty", [String.duplicate("p", cap - 1), "qr", ""], true},
      {"over_chunked", [String.duplicate("p", cap - 1), "qr", "later"], true}
    ]
  end

  defp exact_error_json(type, bytes) do
    base = Jason.encode!(%{error: %{type: type, message: ""}})

    body =
      Jason.encode!(%{
        error: %{type: type, message: String.duplicate("m", bytes - byte_size(base))}
      })

    true = byte_size(body) == bytes
    body
  end

  defp sse(event, map), do: "event: #{event}\ndata: " <> Jason.encode!(map) <> "\n\n"
  defp sse(map), do: "data: " <> Jason.encode!(map) <> "\n\n"

  defp request(overrides \\ %{}) do
    Map.merge(
      %{
        model: "claude-fable-5",
        messages: [%{"role" => "user", "content" => "hello"}]
      },
      overrides
    )
  end

  defp fold_raw_history!(session_id, raw_ndjson) do
    workspace =
      Path.join(
        System.tmp_dir!(),
        "pixir-anthropic-history-" <>
          Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
      )

    log_path = Pixir.Log.path(session_id, workspace: workspace)
    File.mkdir_p!(Path.dirname(log_path))
    File.write!(log_path, raw_ndjson)
    on_exit(fn -> File.rm_rf!(workspace) end)

    assert {:ok, history} = Pixir.Log.fold(session_id, workspace: workspace)
    history
  end

  defp flat_blocks(messages), do: Enum.flat_map(messages, &List.wrap(&1["content"]))

  test "pa1 request path emits cache-controlled system, breakpoints, and fenced late context" do
    chunks = [sse(%{type: "message_delta", delta: %{stop_reason: "end_turn"}})]

    history = [
      %{"seq" => 1, "type" => "user_message", "data" => %{"text" => "prior question"}},
      %{"seq" => 2, "type" => "assistant_message", "data" => %{"text" => "prior answer"}},
      %{"seq" => 3, "type" => "user_message", "data" => %{"text" => "current question"}}
    ]

    assert {:ok, result} =
             Anthropic.stream(
               request(%{
                 history: history,
                 prompt_mode: :build,
                 previous_turn_boundary_seq: 2,
                 skills_index: "Skills index:\n- sample",
                 developer_context: "Developer context text",
                 agent_instructions: "Stay scoped."
               })
               |> Map.delete(:messages),
               api_key: "sk-ant-test",
               transport: canned(chunks)
             )

    assert_received {:request, http_request}
    body = Jason.decode!(http_request.body)

    assert [_, system_b1] = body["system"]
    assert system_b1["text"] == "Skills index:\n- sample"
    assert system_b1["cache_control"] == %{"type" => "ephemeral"}

    assert {:ok, expected} =
             Pixir.Providers.Anthropic.Prompt.build(%{
               mode: :build,
               skills_index: "Skills index:\n- sample",
               messages: [
                 %{
                   "role" => "user",
                   "content" => [%{"type" => "text", "text" => "prior question"}]
                 },
                 %{
                   "role" => "assistant",
                   "content" => [%{"type" => "text", "text" => "prior answer"}]
                 },
                 %{
                   "role" => "user",
                   "content" => [%{"type" => "text", "text" => "current question"}]
                 }
               ],
               late_context:
                 "Developer context text\n\nSubagent role instructions:\nStay scoped.",
               prev_turn_boundary: 2
             })

    assert body["messages"] == expected.messages

    assert body["messages"] |> List.last() |> Map.fetch!("content") |> hd() |> Map.fetch!("text") =~
             "<<<PIXIR_PA1_LATE_CONTEXT:AUTHORITY>>>\nDeveloper context text"

    assert body["messages"] |> List.last() |> Map.fetch!("content") |> hd() |> Map.fetch!("text") =~
             "Subagent role instructions:\nStay scoped."

    assert expected.contract["breakpoints"] == ["B1", "B2"]
    assert result.provider_metadata["prompt_contract"] == expected.contract
  end

  test "legacy Anthropic request without prompt_mode keeps system_prompt passthrough" do
    chunks = [sse(%{type: "message_delta", delta: %{stop_reason: "end_turn"}})]

    assert {:ok, result} =
             Anthropic.stream(request(%{system_prompt: "legacy system"}),
               api_key: "sk-ant-test",
               transport: canned(chunks)
             )

    assert_received {:request, http_request}
    body = Jason.decode!(http_request.body)
    assert body["system"] == "legacy system"
    refute inspect(body["system"]) =~ "cache_control"
    refute Map.has_key?(result.provider_metadata, "prompt_contract")
  end

  test "replays a skill_view result before its deferred activation" do
    chunks = [sse(%{type: "message_delta", delta: %{stop_reason: "end_turn"}})]

    activation = %{
      "name" => "diagnose",
      "source" => "repo",
      "scope" => "repo",
      "path" => "/skills/diagnose/SKILL.md",
      "content_hash" => "anthropic-activation-hash",
      "content" => "# Anthropic activation"
    }

    history = [
      %{"type" => "user_message", "data" => %{"text" => "diagnose this"}},
      %{
        "type" => "tool_call",
        "data" => %{
          "call_id" => "call_skill",
          "name" => "skill_view",
          "args" => %{"name" => "diagnose"}
        }
      },
      %{"type" => "skill_activation", "data" => activation},
      %{
        "type" => "tool_result",
        "data" => %{
          "call_id" => "call_skill",
          "ok" => true,
          "output" => "# Anthropic activation"
        }
      }
    ]

    assert {:ok, _result} =
             Anthropic.stream(
               request(%{history: history}) |> Map.delete(:messages),
               api_key: "sk-ant-test",
               transport: canned(chunks)
             )

    assert_received {:request, http_request}
    messages = Jason.decode!(http_request.body)["messages"]
    blocks = Enum.flat_map(messages, & &1["content"])

    tool_use_index = Enum.find_index(blocks, &(&1["type"] == "tool_use"))
    tool_result_index = Enum.find_index(blocks, &(&1["type"] == "tool_result"))

    activation_index =
      Enum.find_index(blocks, fn block ->
        block["type"] == "text" and block["text"] == Pixir.Skills.render_activation(activation)
      end)

    assert is_integer(tool_use_index)
    assert is_integer(tool_result_index)
    assert is_integer(activation_index)
    assert tool_use_index < tool_result_index
    assert tool_result_index < activation_index

    result_block = Enum.at(blocks, tool_result_index)
    assert result_block["tool_use_id"] == "call_skill"
    assert result_block["content"] == "# Anthropic activation"
    refute result_block["is_error"]
  end

  test "pairs one matching skill_view while an unrelated call remains pending" do
    chunks = [sse(%{type: "message_delta", delta: %{stop_reason: "end_turn"}})]

    activation = %{
      "name" => "diagnose",
      "source" => "repo",
      "scope" => "repo",
      "path" => "/skills/diagnose/SKILL.md",
      "content_hash" => "anthropic-concurrent-hash",
      "content" => "# Anthropic concurrent activation"
    }

    raw_ndjson =
      ~S({"id":"e1","session_id":"anthropic-raw-concurrent","seq":1,"ts":"2026-07-05T00:00:01Z","type":"tool_call","data":{"call_id":"call_read","name":"read","args":{"path":"README.md"}}}) <>
        "\n" <>
        ~S({"id":"e2","session_id":"anthropic-raw-concurrent","seq":2,"ts":"2026-07-05T00:00:02Z","type":"tool_call","data":{"call_id":"call_skill","name":"skill_view","args":{"name":"diagnose","path":"SKILL.md"}}}) <>
        "\n" <>
        ~S({"id":"e3","session_id":"anthropic-raw-concurrent","seq":3,"ts":"2026-07-05T00:00:03Z","type":"skill_activation","data":{"name":"diagnose","source":"repo","scope":"repo","path":"/skills/diagnose/SKILL.md","content_hash":"anthropic-concurrent-hash","content":"# Anthropic concurrent activation"}}) <>
        "\n" <>
        ~S({"id":"e4","session_id":"anthropic-raw-concurrent","seq":4,"ts":"2026-07-05T00:00:04Z","type":"tool_result","data":{"call_id":"call_read","ok":true,"output":"read body"}}) <>
        "\n" <>
        ~S({"id":"e5","session_id":"anthropic-raw-concurrent","seq":5,"ts":"2026-07-05T00:00:05Z","type":"tool_result","data":{"call_id":"call_skill","ok":true,"output":"skill body"}}) <>
        "\n"

    history = fold_raw_history!("anthropic-raw-concurrent", raw_ndjson)

    assert {:ok, _result} =
             Anthropic.stream(
               request(%{history: history}) |> Map.delete(:messages),
               api_key: "sk-ant-test",
               transport: canned(chunks)
             )

    assert_received {:request, http_request}
    blocks = http_request.body |> Jason.decode!() |> Map.fetch!("messages") |> flat_blocks()

    assert Enum.map(Enum.filter(blocks, &(&1["type"] == "tool_use")), & &1["id"]) == [
             "call_read",
             "call_skill"
           ]

    assert Enum.filter(blocks, &(&1["type"] == "tool_result")) == [
             %{"type" => "tool_result", "tool_use_id" => "call_read", "content" => "read body"},
             %{
               "type" => "tool_result",
               "tool_use_id" => "call_skill",
               "content" => "skill body"
             }
           ]

    assert Enum.any?(blocks, fn block ->
             block["type"] == "text" and
               block["text"] == Pixir.Skills.render_activation(activation)
           end)

    refute inspect(blocks) =~ "orphan_tool_call"
  end

  test "two matching skill_view calls remain ambiguous and use orphan repair" do
    chunks = [sse(%{type: "message_delta", delta: %{stop_reason: "end_turn"}})]

    raw_ndjson =
      ~S({"id":"e1","session_id":"anthropic-raw-ambiguous","seq":1,"ts":"2026-07-05T00:00:01Z","type":"tool_call","data":{"call_id":"call_skill_a","name":"skill_view","args":{"name":"diagnose","path":"SKILL.md"}}}) <>
        "\n" <>
        ~S({"id":"e2","session_id":"anthropic-raw-ambiguous","seq":2,"ts":"2026-07-05T00:00:02Z","type":"tool_call","data":{"call_id":"call_skill_b","name":"skill_view","args":{"name":"diagnose","path":"SKILL.md"}}}) <>
        "\n" <>
        ~S({"id":"e3","session_id":"anthropic-raw-ambiguous","seq":3,"ts":"2026-07-05T00:00:03Z","type":"skill_activation","data":{"name":"diagnose","source":"repo","scope":"repo","path":"/skills/diagnose/SKILL.md","content_hash":"anthropic-ambiguous-hash","content":"# Anthropic ambiguous activation"}}) <>
        "\n" <>
        ~S({"id":"e4","session_id":"anthropic-raw-ambiguous","seq":4,"ts":"2026-07-05T00:00:04Z","type":"tool_result","data":{"call_id":"call_skill_a","ok":true,"output":"skill a body"}}) <>
        "\n" <>
        ~S({"id":"e5","session_id":"anthropic-raw-ambiguous","seq":5,"ts":"2026-07-05T00:00:05Z","type":"tool_result","data":{"call_id":"call_skill_b","ok":true,"output":"skill b body"}}) <>
        "\n"

    history = fold_raw_history!("anthropic-raw-ambiguous", raw_ndjson)

    assert {:ok, _result} =
             Anthropic.stream(
               request(%{history: history}) |> Map.delete(:messages),
               api_key: "sk-ant-test",
               transport: canned(chunks)
             )

    assert_received {:request, http_request}
    blocks = http_request.body |> Jason.decode!() |> Map.fetch!("messages") |> flat_blocks()

    orphan_results =
      Enum.filter(blocks, fn block ->
        block["type"] == "tool_result" and block["is_error"] == true and
          match?(
            %{"error" => %{"kind" => "orphan_tool_call"}},
            Jason.decode!(block["content"])
          )
      end)

    assert Enum.map(orphan_results, & &1["tool_use_id"]) == ["call_skill_a", "call_skill_b"]
  end

  test "an unrelated result does not close a deferred skill activation early" do
    chunks = [sse(%{type: "message_delta", delta: %{stop_reason: "end_turn"}})]

    activation = %{
      "name" => "diagnose",
      "source" => "repo",
      "scope" => "repo",
      "path" => "/skills/diagnose/SKILL.md",
      "content_hash" => "anthropic-deferred-hash",
      "content" => "# Anthropic deferred activation"
    }

    raw_ndjson =
      ~S({"id":"e1","session_id":"anthropic-raw-deferred","seq":1,"ts":"2026-07-05T00:00:01Z","type":"tool_call","data":{"call_id":"call_read","name":"read","args":{"path":"README.md"}}}) <>
        "\n" <>
        ~S({"id":"e2","session_id":"anthropic-raw-deferred","seq":2,"ts":"2026-07-05T00:00:02Z","type":"tool_call","data":{"call_id":"call_skill","name":"skill_view","args":{"name":"diagnose","path":"SKILL.md"}}}) <>
        "\n" <>
        ~S({"id":"e3","session_id":"anthropic-raw-deferred","seq":3,"ts":"2026-07-05T00:00:03Z","type":"skill_activation","data":{"name":"diagnose","source":"repo","scope":"repo","path":"/skills/diagnose/SKILL.md","content_hash":"anthropic-deferred-hash","content":"# Anthropic deferred activation"}}) <>
        "\n" <>
        ~S({"id":"e4","session_id":"anthropic-raw-deferred","seq":4,"ts":"2026-07-05T00:00:04Z","type":"tool_result","data":{"call_id":"call_read","ok":true,"output":"read body"}}) <>
        "\n"

    history = fold_raw_history!("anthropic-raw-deferred", raw_ndjson)

    assert {:ok, _result} =
             Anthropic.stream(
               request(%{history: history}) |> Map.delete(:messages),
               api_key: "sk-ant-test",
               transport: canned(chunks)
             )

    assert_received {:request, http_request}
    blocks = http_request.body |> Jason.decode!() |> Map.fetch!("messages") |> flat_blocks()

    read_result_index =
      Enum.find_index(blocks, &(&1["type"] == "tool_result" and &1["tool_use_id"] == "call_read"))

    skill_orphan_index =
      Enum.find_index(blocks, fn block ->
        block["type"] == "tool_result" and block["tool_use_id"] == "call_skill" and
          block["is_error"] == true
      end)

    activation_index =
      Enum.find_index(blocks, fn block ->
        block["type"] == "text" and
          block["text"] == Pixir.Skills.render_activation(activation)
      end)

    assert is_integer(read_result_index)
    assert is_integer(skill_orphan_index)
    assert is_integer(activation_index)
    assert read_result_index < skill_orphan_index
    assert skill_orphan_index < activation_index
    refute Enum.at(blocks, read_result_index)["is_error"]
  end

  test "pa1 provider_metadata carries prompt contract evidence" do
    chunks = [sse(%{type: "message_delta", delta: %{stop_reason: "end_turn"}})]

    assert {:ok, result} =
             Anthropic.stream(
               request(%{prompt_mode: :plan, previous_turn_boundary_seq: 0}),
               api_key: "sk-ant-test",
               transport: canned(chunks)
             )

    contract = result.provider_metadata["prompt_contract"]
    assert contract["prompt_contract_version"] == "pa1"
    assert is_list(contract["breakpoints"])
    assert is_binary(contract["layer0_hash"])
  end

  test "pa1 omits late context block when developer context and agent instructions are absent" do
    chunks = [sse(%{type: "message_delta", delta: %{stop_reason: "end_turn"}})]

    assert {:ok, _result} =
             Anthropic.stream(request(%{prompt_mode: :build, previous_turn_boundary_seq: 0}),
               api_key: "sk-ant-test",
               transport: canned(chunks)
             )

    assert_received {:request, http_request}
    body = Jason.decode!(http_request.body)
    [message] = body["messages"]
    assert message["content"] == [%{"type" => "text", "text" => "hello"}]
  end

  test "text-only happy path assembles text, emits deltas, and summarizes zero cache" do
    parent = self()

    chunks = [
      sse("message_start", %{
        type: "message_start",
        message: %{
          model: "claude-fable-5",
          usage: %{input_tokens: 10, output_tokens: 0}
        }
      }),
      sse("content_block_start", %{
        type: "content_block_start",
        index: 0,
        content_block: %{type: "text", text: ""}
      }),
      sse("content_block_delta", %{
        type: "content_block_delta",
        index: 0,
        delta: %{type: "text_delta", text: nil}
      }),
      sse("content_block_delta", %{
        type: "content_block_delta",
        index: 0,
        delta: %{type: "text_delta"}
      }),
      sse("content_block_delta", %{
        type: "content_block_delta",
        index: 0,
        delta: %{type: "text_delta", text: "Hello"}
      }),
      sse("content_block_delta", %{
        type: "content_block_delta",
        index: 0,
        delta: %{type: "text_delta", text: ", world"}
      }),
      sse("message_delta", %{
        type: "message_delta",
        delta: %{stop_reason: "end_turn"},
        usage: %{output_tokens: 3}
      }),
      sse("message_stop", %{type: "message_stop"})
    ]

    assert {:ok, result} =
             Anthropic.stream(request(),
               api_key: "sk-ant-test",
               transport: canned(chunks),
               on_delta: fn delta -> send(parent, {:delta, delta}) end
             )

    assert result.text == "Hello, world"
    assert result.finish_reason == :stop
    assert result.function_calls == []
    assert result.reasoning_items == []
    assert result.usage_summary["input_tokens"] == 10
    assert result.usage_summary["output_tokens"] == 3
    assert result.usage_summary["total_tokens"] == 13
    assert result.usage_summary["cache"] == %{"creation_tokens" => 0, "read_tokens" => 0}
    assert result.usage_summary["cached_tokens"] == 0
    assert result.usage_summary["cache_hit_rate"] == 0
    assert result.provider_metadata["active_transport"] == "http_sse"
    assert result.provider_metadata["transport_preference"] == "auto"

    assert_received {:delta, {:text_delta, "Hello"}}
    assert_received {:delta, {:text_delta, ", world"}}
  end

  test "non-object SSE containers fail safely without retries or raw-value echo" do
    malformed_values = [[], "secret-do-not-echo", 7, true, false]

    cases = [
      {:payload, fn value -> sse(value) end},
      {:message,
       fn value ->
         sse("message_start", %{type: "message_start", message: value})
       end},
      {:content_block,
       fn value ->
         sse("content_block_start", %{
           type: "content_block_start",
           index: 0,
           content_block: value
         })
       end},
      {:delta,
       fn value ->
         sse("content_block_delta", %{
           type: "content_block_delta",
           index: 0,
           delta: value
         })
       end}
    ]

    for {field, build_chunk} <- cases, value <- malformed_values do
      {:ok, attempts} = Agent.start_link(fn -> 0 end)
      parent = self()

      transport = fn _request, acc, fun ->
        Agent.update(attempts, &(&1 + 1))
        acc = fun.({:status, 200}, acc)
        acc = fun.({:data, build_chunk.(value)}, acc)

        terminal =
          sse("message_delta", %{type: "message_delta", delta: %{stop_reason: "end_turn"}})

        {:ok, fun.({:data, terminal}, acc)}
      end

      assert {:error,
              %{
                error: %{
                  kind: :invalid_response,
                  details: %{field: ^field, reason: :non_object, retryable: false}
                }
              } = error} =
               Anthropic.stream(request(),
                 api_key: "sk-ant-test",
                 transport: transport,
                 max_retries: 2,
                 sleep: fn _ -> flunk("invalid_response must not retry") end,
                 on_delta: fn delta -> send(parent, {:unexpected_delta, delta}) end
               )

      assert Agent.get(attempts, & &1) == 1
      refute inspect(error) =~ "secret-do-not-echo"
      refute_received {:unexpected_delta, _delta}
    end
  end

  test "non-binary content deltas fail safely without fallback, retry, or mutation" do
    malformed_values = [[], %{"secret" => "do-not-echo"}, 7, true, false]

    thinking_start =
      sse("content_block_start", %{
        type: "content_block_start",
        index: 0,
        content_block: %{type: "thinking", thinking: "", signature: ""}
      })

    tool_start =
      sse("content_block_start", %{
        type: "content_block_start",
        index: 0,
        content_block: %{type: "tool_use", id: "toolu_safe", name: "read", input: %{}}
      })

    cases = [
      {:text,
       fn value ->
         {[],
          sse("content_block_delta", %{
            type: "content_block_delta",
            index: 0,
            delta: %{type: "text_delta", text: value}
          })}
       end},
      {:thinking,
       fn value ->
         {[thinking_start],
          sse("content_block_delta", %{
            type: "content_block_delta",
            index: 0,
            delta: %{type: "thinking_delta", thinking: value, text: "unsafe-fallback"}
          })}
       end},
      {:text,
       fn value ->
         {[thinking_start],
          sse("content_block_delta", %{
            type: "content_block_delta",
            index: 0,
            delta: %{type: "thinking_delta", thinking: nil, text: value}
          })}
       end},
      {:signature,
       fn value ->
         {[thinking_start],
          sse("content_block_delta", %{
            type: "content_block_delta",
            index: 0,
            delta: %{type: "signature_delta", signature: value}
          })}
       end},
      {:partial_json,
       fn value ->
         {[tool_start],
          sse("content_block_delta", %{
            type: "content_block_delta",
            index: 0,
            delta: %{type: "input_json_delta", partial_json: value}
          })}
       end}
    ]

    for {field, build_chunks} <- cases, value <- malformed_values do
      {:ok, attempts} = Agent.start_link(fn -> 0 end)
      parent = self()
      {prefix, invalid_delta} = build_chunks.(value)

      transport = fn _request, acc, fun ->
        Agent.update(attempts, &(&1 + 1))
        acc = fun.({:status, 200}, acc)
        acc = Enum.reduce(prefix, acc, fn chunk, current -> fun.({:data, chunk}, current) end)
        acc = fun.({:data, invalid_delta}, acc)

        acc =
          fun.({:data, sse("content_block_stop", %{type: "content_block_stop", index: 0})}, acc)

        terminal =
          sse("message_delta", %{type: "message_delta", delta: %{stop_reason: "end_turn"}})

        {:ok, fun.({:data, terminal}, acc)}
      end

      assert {:error,
              %{
                error: %{
                  kind: :invalid_response,
                  details: %{field: ^field, reason: :non_binary, retryable: false}
                }
              } = error} =
               Anthropic.stream(request(),
                 api_key: "sk-ant-test",
                 transport: transport,
                 max_retries: 2,
                 sleep: fn _ -> flunk("invalid_response must not retry") end,
                 on_delta: fn delta -> send(parent, {:unexpected_delta, delta}) end
               )

      assert Agent.get(attempts, & &1) == 1
      refute inspect(error) =~ "do-not-echo"
      refute inspect(error) =~ "unsafe-fallback"
      refute_received {:unexpected_delta, _delta}
    end

    for {field, build_block} <- [
          {:thinking, fn value -> %{type: "thinking", thinking: value, signature: ""} end},
          {:signature, fn value -> %{type: "thinking", thinking: "", signature: value} end}
        ],
        value <- malformed_values do
      {:ok, attempts} = Agent.start_link(fn -> 0 end)

      transport = fn _request, acc, fun ->
        Agent.update(attempts, &(&1 + 1))
        acc = fun.({:status, 200}, acc)

        start =
          sse("content_block_start", %{
            type: "content_block_start",
            index: 0,
            content_block: build_block.(value)
          })

        acc = fun.({:data, start}, acc)

        terminal =
          sse("message_delta", %{type: "message_delta", delta: %{stop_reason: "end_turn"}})

        {:ok, fun.({:data, terminal}, acc)}
      end

      assert {:error,
              %{
                error: %{
                  kind: :invalid_response,
                  details: %{field: ^field, reason: :non_binary, retryable: false}
                }
              } = error} =
               Anthropic.stream(request(),
                 api_key: "sk-ant-test",
                 transport: transport,
                 max_retries: 2,
                 sleep: fn _ -> flunk("invalid_response must not retry") end
               )

      assert Agent.get(attempts, & &1) == 1
      refute inspect(error) =~ "do-not-echo"
    end
  end

  test "binary content deltas preserve valid bytes exactly" do
    parent = self()
    text = "text\n雪\0"
    thinking = "thinking\n雪\0"
    signature = "signature\n雪\0"
    argument = "argument\n雪\0"
    partial_json = Jason.encode!(%{"path" => argument})

    chunks = [
      sse("content_block_start", %{
        type: "content_block_start",
        index: 0,
        content_block: %{type: "text", text: ""}
      }),
      sse("content_block_delta", %{
        type: "content_block_delta",
        index: 0,
        delta: %{type: "text_delta", text: text}
      }),
      sse("content_block_start", %{
        type: "content_block_start",
        index: 1,
        content_block: %{type: "thinking", thinking: "prefix-", signature: "prefix-"}
      }),
      sse("content_block_delta", %{
        type: "content_block_delta",
        index: 1,
        delta: %{type: "thinking_delta", thinking: nil, text: "fallback-"}
      }),
      sse("content_block_delta", %{
        type: "content_block_delta",
        index: 1,
        delta: %{type: "thinking_delta", thinking: thinking, text: "unused-fallback"}
      }),
      sse("content_block_delta", %{
        type: "content_block_delta",
        index: 1,
        delta: %{type: "signature_delta", signature: nil}
      }),
      sse("content_block_delta", %{
        type: "content_block_delta",
        index: 1,
        delta: %{type: "signature_delta", signature: signature}
      }),
      sse("content_block_stop", %{type: "content_block_stop", index: 1}),
      sse("content_block_start", %{
        type: "content_block_start",
        index: 2,
        content_block: %{type: "tool_use", id: "toolu_bytes", name: "read", input: %{}}
      }),
      sse("content_block_delta", %{
        type: "content_block_delta",
        index: 2,
        delta: %{type: "input_json_delta", partial_json: nil}
      }),
      sse("content_block_delta", %{
        type: "content_block_delta",
        index: 2,
        delta: %{type: "input_json_delta", partial_json: partial_json}
      }),
      sse("content_block_stop", %{type: "content_block_stop", index: 2}),
      sse("message_delta", %{type: "message_delta", delta: %{stop_reason: "end_turn"}})
    ]

    assert {:ok, result} =
             Anthropic.stream(request(),
               api_key: "sk-ant-test",
               transport: canned(chunks),
               on_delta: fn delta -> send(parent, {:delta, delta}) end
             )

    assert result.text == text
    assert result.reasoning == "fallback-" <> thinking

    assert [
             %{
               "thinking" => "prefix-fallback-" <> ^thinking,
               "signature" => "prefix-" <> ^signature
             }
           ] =
             result.reasoning_items

    assert [%{call_id: "toolu_bytes", name: "read", args: %{"path" => ^argument}}] =
             result.function_calls

    assert_received {:delta, {:text_delta, ^text}}
    assert_received {:delta, {:reasoning_delta, "fallback-"}}
    assert_received {:delta, {:reasoning_delta, ^thinking}}
  end

  test "max_tokens stop returns partial text with truncation evidence" do
    chunks = [
      sse("content_block_start", %{
        type: "content_block_start",
        index: 0,
        content_block: %{type: "text", text: ""}
      }),
      sse("content_block_delta", %{
        type: "content_block_delta",
        index: 0,
        delta: %{type: "text_delta", text: "partial answer"}
      }),
      sse("message_delta", %{
        type: "message_delta",
        delta: %{stop_reason: "max_tokens"}
      }),
      sse("message_stop", %{type: "message_stop"})
    ]

    assert {:ok, result} =
             Anthropic.stream(request(), api_key: "sk-ant-test", transport: canned(chunks))

    assert result.text == "partial answer"
    assert result.finish_reason == :stop
    assert result.provider_metadata["stop_reason"] == "max_tokens"
    assert result.provider_metadata["truncated"] == true
  end

  test "thinking and tool_use blocks retain streamed order and derive flat lists" do
    chunks = [
      sse("message_start", %{
        type: "message_start",
        message: %{model: "claude-fable-5", usage: %{input_tokens: 7}}
      }),
      sse("content_block_start", %{
        type: "content_block_start",
        index: 0,
        content_block: %{type: "thinking", thinking: "", signature: "sig-"}
      }),
      sse("content_block_delta", %{
        type: "content_block_delta",
        index: 0,
        delta: %{type: "thinking_delta", thinking: "plan"}
      }),
      sse("content_block_delta", %{
        type: "content_block_delta",
        index: 0,
        delta: %{type: "signature_delta", signature: "final"}
      }),
      sse("content_block_stop", %{type: "content_block_stop", index: 0}),
      sse("content_block_start", %{
        type: "content_block_start",
        index: 1,
        content_block: %{type: "tool_use", id: "toolu_1", name: "read", input: %{}}
      }),
      sse("content_block_delta", %{
        type: "content_block_delta",
        index: 1,
        delta: %{type: "input_json_delta", partial_json: ~s({"path":)}
      }),
      sse("content_block_delta", %{
        type: "content_block_delta",
        index: 1,
        delta: %{type: "input_json_delta", partial_json: ~s("a.txt"})}
      }),
      sse("content_block_stop", %{type: "content_block_stop", index: 1}),
      sse("message_delta", %{type: "message_delta", delta: %{stop_reason: "tool_use"}}),
      sse("message_stop", %{type: "message_stop"})
    ]

    assert {:ok, result} =
             Anthropic.stream(request(), api_key: "sk-ant-test", transport: canned(chunks))

    assert [
             {:reasoning,
              %{"type" => "thinking", "thinking" => "plan", "signature" => "sig-final"}},
             {:function_call, %{call_id: "toolu_1", name: "read", args: %{"path" => "a.txt"}}}
           ] = result.output_items

    assert result.reasoning_items == [
             %{"type" => "thinking", "thinking" => "plan", "signature" => "sig-final"}
           ]

    assert result.function_calls == [
             %{call_id: "toolu_1", name: "read", args: %{"path" => "a.txt"}}
           ]

    assert result.finish_reason == :tool_calls
  end

  test "output_items preserve tool thinking tool arrival order" do
    chunks = [
      sse("content_block_start", %{
        type: "content_block_start",
        index: 0,
        content_block: %{type: "tool_use", id: "toolu_1", name: "read", input: %{}}
      }),
      sse("content_block_delta", %{
        type: "content_block_delta",
        index: 0,
        delta: %{type: "input_json_delta", partial_json: ~s({"path":"a.txt"})}
      }),
      sse("content_block_stop", %{type: "content_block_stop", index: 0}),
      sse("content_block_start", %{
        type: "content_block_start",
        index: 1,
        content_block: %{type: "thinking", thinking: "", signature: "sig"}
      }),
      sse("content_block_delta", %{
        type: "content_block_delta",
        index: 1,
        delta: %{type: "thinking_delta", thinking: "think"}
      }),
      sse("content_block_stop", %{type: "content_block_stop", index: 1}),
      sse("content_block_start", %{
        type: "content_block_start",
        index: 2,
        content_block: %{type: "tool_use", id: "toolu_2", name: "write", input: %{}}
      }),
      sse("content_block_delta", %{
        type: "content_block_delta",
        index: 2,
        delta: %{type: "input_json_delta", partial_json: ~s({"path":"b.txt"})}
      }),
      sse("content_block_stop", %{type: "content_block_stop", index: 2}),
      sse("message_delta", %{type: "message_delta", delta: %{stop_reason: "tool_use"}})
    ]

    assert {:ok, result} =
             Anthropic.stream(request(), api_key: "sk-ant-test", transport: canned(chunks))

    assert [
             {:function_call, %{call_id: "toolu_1", name: "read", args: %{"path" => "a.txt"}}},
             {:reasoning, %{"type" => "thinking", "thinking" => "think", "signature" => "sig"}},
             {:function_call, %{call_id: "toolu_2", name: "write", args: %{"path" => "b.txt"}}}
           ] = result.output_items
  end

  test "usage summary reports cache fields, cached tokens, and read-only hit rate" do
    chunks = [
      sse(%{
        type: "message_start",
        message: %{
          model: "claude-fable-5",
          usage: %{
            input_tokens: 100,
            output_tokens: 0,
            cache_creation_input_tokens: 200,
            cache_read_input_tokens: 700
          }
        }
      }),
      sse(%{
        type: "message_delta",
        delta: %{stop_reason: "end_turn"},
        usage: %{output_tokens: 50}
      }),
      sse(%{type: "message_stop"})
    ]

    assert {:ok, result} =
             Anthropic.stream(request(), api_key: "sk-ant-test", transport: canned(chunks))

    assert result.usage_summary == %{
             "input_tokens" => 100,
             "output_tokens" => 50,
             "total_tokens" => 1050,
             "model" => "claude-fable-5",
             "cache" => %{"creation_tokens" => 200, "read_tokens" => 700},
             "cached_tokens" => 700,
             "cache_hit_rate" => 0.7
           }
  end

  test "refusal stop reason returns terminal provider_refusal with stop_details" do
    test = self()

    transport = fn http_request, acc, fun ->
      send(test, {:request, http_request})
      acc = fun.({:status, 200}, acc)

      acc =
        fun.(
          {:data,
           sse(%{
             type: "message_delta",
             delta: %{
               stop_reason: "refusal",
               stop_details: %{reason: "safety", policy: "test"}
             }
           })},
          acc
        )

      {:ok, acc}
    end

    assert {:error,
            %{
              error: %{
                kind: :provider_refusal,
                details: %{
                  stop_details: %{"reason" => "safety", "policy" => "test"},
                  retryable: false
                }
              }
            }} =
             Anthropic.stream(request(),
               api_key: "sk-ant-test",
               transport: transport,
               max_retries: 2
             )

    assert_received {:request, _}
    refute_received {:request, _}
  end

  test "429 with retry-after retries once and then succeeds" do
    test = self()
    counter = :counters.new(1, [])

    transport = fn http_request, acc, fun ->
      send(test, {:request, http_request})

      attempt = :counters.get(counter, 1)
      :counters.add(counter, 1, 1)

      case attempt do
        0 ->
          acc = fun.({:status, 429}, acc)
          acc = fun.({:headers, [{"retry-after", "0"}]}, acc)

          acc =
            fun.(
              {:data, Jason.encode!(%{error: %{type: "rate_limit_error", message: "slow down"}})},
              acc
            )

          {:ok, acc}

        _ ->
          acc = fun.({:status, 200}, acc)

          acc =
            fun.({:data, sse(%{type: "message_delta", delta: %{stop_reason: "end_turn"}})}, acc)

          {:ok, acc}
      end
    end

    assert {:ok, result} =
             Anthropic.stream(request(),
               api_key: "sk-ant-test",
               transport: transport,
               sleep: fn ms -> send(test, {:sleep, ms}) end
             )

    assert result.finish_reason == :stop
    assert result.provider_metadata["retry_count"] == 1
    assert_received {:sleep, 0}
    assert_received {:request, _}
    assert_received {:request, _}
  end

  test "529 overloaded classifies as retryable provider_http_error" do
    body = Jason.encode!(%{error: %{type: "overloaded_error", message: "overloaded"}})

    assert {:error,
            %{
              error: %{
                kind: :provider_http_error,
                details: %{status: 529, type: "overloaded_error", retryable: true}
              }
            }} =
             Anthropic.stream(request(),
               api_key: "sk-ant-test",
               transport: canned([body], 529),
               max_retries: 0
             )
  end

  test "http status classification covers the retryable and terminal buckets" do
    for {status, type, retryable} <- [
          {500, "api_error", true},
          {401, "authentication_error", false},
          {403, "permission_error", false},
          {404, "not_found_error", false}
        ] do
      body = Jason.encode!(%{error: %{type: type, message: "status #{status}"}})

      assert {:error,
              %{
                error: %{
                  kind: :provider_http_error,
                  details: %{status: ^status, type: ^type, retryable: ^retryable}
                }
              }} =
               Anthropic.stream(request(),
                 api_key: "sk-ant-test",
                 transport: canned([body], status),
                 max_retries: 0
               )
    end
  end

  test "oversized non-2xx error body is capped and marked truncated" do
    payload = String.duplicate("x", Pixir.Providers.ErrBody.max_bytes() * 2)
    body = Jason.encode!(%{error: %{type: "api_error", message: payload}})

    assert {:error,
            %{
              error: %{
                kind: :provider_http_error,
                message: message,
                details: details
              }
            }} =
             Anthropic.stream(request(),
               api_key: "sk-ant-test",
               transport: canned([body], 500),
               max_retries: 0
             )

    assert details.err_body_truncated == true
    refute message =~ payload
    refute inspect(details) =~ payload
  end

  test "small non-2xx error body does not carry truncation marker" do
    body = Jason.encode!(%{error: %{type: "api_error", message: "small failure"}})

    assert {:error,
            %{
              error: %{
                kind: :provider_http_error,
                details: details
              }
            }} =
             Anthropic.stream(request(),
               api_key: "sk-ant-test",
               transport: canned([body], 500),
               max_retries: 0
             )

    refute Map.has_key?(details, :err_body_truncated)
  end

  test "non-2xx error-body provenance is exact across cap and chunk boundaries" do
    for {name, chunks, expected_truncated} <- error_body_cases() do
      assert {:error,
              %{
                error: %{
                  kind: :provider_http_error,
                  details: %{status: 500, retryable: true} = details
                }
              }} =
               Anthropic.stream(request(),
                 api_key: "sk-ant-test",
                 transport: canned(chunks, 500),
                 max_retries: 0
               ),
             name

      assert Map.has_key?(details, :err_body_truncated) == expected_truncated, name
      refute Map.has_key?(details, :body), name

      if expected_truncated do
        assert details.err_body_truncated == true, name
      end
    end
  end

  test "retry starts a fresh error-body capture" do
    cap = Pixir.Providers.ErrBody.max_bytes()
    overflow = exact_error_json("api_error", cap + 1)
    exact = exact_error_json("invalid_request_error", cap)

    assert {:error,
            %{
              error: %{
                kind: :provider_http_error,
                details:
                  %{
                    status: 400,
                    type: "invalid_request_error",
                    retryable: false
                  } = details
              }
            }} =
             Anthropic.stream(request(),
               api_key: "sk-ant-test",
               transport: canned_attempts([{[overflow], 500}, {[exact], 400}]),
               max_retries: 1,
               sleep: fn _ -> :ok end
             )

    refute Map.has_key?(details, :err_body_truncated)
    refute Map.has_key?(details, :body)
    assert_received {:request, _}
    assert_received {:request, _}
    refute_received {:request, _}
  end

  test "terminal 400 does not retry and preserves anthropic error.type" do
    body = Jason.encode!(%{error: %{type: "invalid_request_error", message: "bad request"}})

    assert {:error,
            %{
              error: %{
                kind: :provider_http_error,
                details: %{status: 400, type: "invalid_request_error", retryable: false}
              }
            }} =
             Anthropic.stream(request(), api_key: "sk-ant-test", transport: canned([body], 400))

    assert_received {:request, _}
    refute_received {:request, _}
  end

  test "rejects Provider-hosted web_search honestly" do
    assert {:error,
            %{
              error: %{
                kind: :invalid_args,
                details: %{
                  field: :web_search,
                  unsupported_capability: "provider_hosted_web_search"
                }
              }
            }} =
             Anthropic.stream(request(%{web_search: %{"enabled" => true}}),
               api_key: "sk-ant-test",
               transport: canned([])
             )
  end

  test "rejects non-empty Provider-hosted tools honestly" do
    assert {:error,
            %{
              error: %{
                kind: :invalid_args,
                details: %{field: :hosted_tools, unsupported_capability: "provider_hosted_tools"}
              }
            }} =
             Anthropic.stream(request(%{hosted_tools: [%{"type" => "web_search"}]}),
               api_key: "sk-ant-test",
               transport: canned([])
             )
  end

  test "missing API key names ANTHROPIC_API_KEY" do
    assert {:error,
            %{
              error: %{
                kind: :not_authenticated,
                details: %{env: "ANTHROPIC_API_KEY"}
              }
            }} = Anthropic.stream(request(), api_key: "", transport: canned([]))
  end

  test "malformed tool_use partial_json returns invalid_response at block stop" do
    chunks = [
      sse("content_block_start", %{
        type: "content_block_start",
        index: 0,
        content_block: %{type: "tool_use", id: "toolu_bad", name: "read", input: %{}}
      }),
      sse("content_block_delta", %{
        type: "content_block_delta",
        index: 0,
        delta: %{type: "input_json_delta", partial_json: ~s({"path":)}
      }),
      sse("content_block_stop", %{type: "content_block_stop", index: 0})
    ]

    assert {:error, %{error: %{kind: :invalid_response}}} =
             Anthropic.stream(request(), api_key: "sk-ant-test", transport: canned(chunks))
  end

  test "400 prompt too long invalid_request_error classifies as non-retryable context_overflow" do
    body =
      Jason.encode!(%{
        error: %{
          type: "invalid_request_error",
          message: "prompt is too long: 1000001 tokens exceed the model limit"
        }
      })

    assert {:error,
            %{
              error: %{
                kind: :context_overflow,
                details: %{status: 400, type: "invalid_request_error", retryable: false}
              }
            }} =
             Anthropic.stream(request(),
               api_key: "sk-ant-test",
               transport: canned([body], 400),
               max_retries: 2
             )
  end

  test "retry-after is capped at thirty seconds" do
    test = self()
    counter = :counters.new(1, [])

    transport = fn http_request, acc, fun ->
      send(test, {:request, http_request})
      attempt = :counters.get(counter, 1)
      :counters.add(counter, 1, 1)

      case attempt do
        0 ->
          acc = fun.({:status, 429}, acc)
          acc = fun.({:headers, [{"retry-after", "3600"}]}, acc)

          acc =
            fun.(
              {:data, Jason.encode!(%{error: %{type: "rate_limit_error", message: "slow down"}})},
              acc
            )

          {:ok, acc}

        _ ->
          acc = fun.({:status, 200}, acc)

          acc =
            fun.({:data, sse(%{type: "message_delta", delta: %{stop_reason: "end_turn"}})}, acc)

          {:ok, acc}
      end
    end

    assert {:ok, _result} =
             Anthropic.stream(request(),
               api_key: "sk-ant-test",
               transport: transport,
               sleep: fn ms -> send(test, {:sleep, ms}) end
             )

    assert_received {:sleep, 30_000}
  end

  test "max_tokens stop with completed tool_use finalizes tool_calls with truncation evidence" do
    chunks = [
      sse("content_block_start", %{
        type: "content_block_start",
        index: 0,
        content_block: %{type: "tool_use", id: "toolu_1", name: "read", input: %{}}
      }),
      sse("content_block_delta", %{
        type: "content_block_delta",
        index: 0,
        delta: %{type: "input_json_delta", partial_json: ~s({"path":"a.txt"})}
      }),
      sse("content_block_stop", %{type: "content_block_stop", index: 0}),
      sse("message_delta", %{type: "message_delta", delta: %{stop_reason: "max_tokens"}})
    ]

    assert {:ok, result} =
             Anthropic.stream(request(), api_key: "sk-ant-test", transport: canned(chunks))

    assert result.finish_reason == :tool_calls

    assert result.function_calls == [
             %{call_id: "toolu_1", name: "read", args: %{"path" => "a.txt"}}
           ]

    assert result.provider_metadata["stop_reason"] == "max_tokens"
    assert result.provider_metadata["truncated"] == true
  end

  test "websocket transport requested fails closed before any HTTP attempt" do
    test = self()

    transport = fn _http_request, acc, _fun ->
      send(test, :http_attempted)
      {:ok, acc}
    end

    assert {:error,
            %{
              error: %{
                kind: :unsupported_transport,
                details: %{requested: :websocket}
              }
            }} =
             Anthropic.stream(request(),
               api_key: "sk-ant-test",
               provider_transport: :websocket,
               transport: transport
             )

    refute_received :http_attempted
  end

  test "struct-shaped request documents fail closed at the public boundary" do
    for request <- [URI.parse("https://anthropic.example"), DateTime.utc_now(), MapSet.new()] do
      assert {:error,
              %{
                error: %{
                  kind: :invalid_args,
                  details: %{expected: "plain_map"}
                }
              }} = Anthropic.stream(request, max_retries: 0)
    end
  end

  test "hostile Anthropic body fields fail closed before credential assembly or transport" do
    previous_api_key = System.get_env("ANTHROPIC_API_KEY")
    System.delete_env("ANTHROPIC_API_KEY")

    on_exit(fn ->
      if previous_api_key,
        do: System.put_env("ANTHROPIC_API_KEY", previous_api_key),
        else: System.delete_env("ANTHROPIC_API_KEY")
    end)

    sentinel = "https://user:password@ANTHROPIC_BODY_SECRET.example/path"
    uri = URI.parse(sentinel)

    malformed = [
      request(%{
        messages: nil,
        history: [%{type: :user_message, data: %{"text" => uri}}]
      }),
      request(%{messages: nil, history: [Pixir.Event.user_message("s", "hi") | :improper]}),
      request(%{
        messages: nil,
        history: [
          Map.put(Pixir.Event.user_message("s", "hi"), :data, %{
            "text" => ["a" | :improper]
          })
        ]
      }),
      request(%{tools: [%{"name" => "x", "input_schema" => uri}]}),
      request(%{tools: [%{"name" => "x", "input_schema" => %{}} | :improper]}),
      request(%{messages: [%{"role" => "user", "content" => uri}]}),
      request(%{messages: [%{"role" => "user", "content" => "hi"} | :improper]}),
      request(%{system: [%{"type" => "text", "text" => uri}]}),
      request(%{reasoning_effort: uri}),
      request(%{prompt_mode: uri}),
      request(%{previous_turn_boundary_seq: uri}),
      request(%{
        prompt_mode: :build,
        messages: [%{"role" => "user", "content" => %{"unexpected" => "map"}}]
      }),
      request(%{model: <<255>>})
    ]

    for hostile_request <- malformed do
      assert {:error, %{error: %{kind: :invalid_args}} = error} =
               Anthropic.stream(hostile_request,
                 max_retries: 0,
                 transport: fn _request, _acc, _fun -> flunk("transport must not run") end
               )

      refute inspect(error) =~ "ANTHROPIC_BODY_SECRET"
      refute inspect(error) =~ "user:password"
      assert {:ok, _json} = Jason.encode(error)
    end
  end

  test "Anthropic body-field authority collisions fail closed" do
    for field <- [
          :model,
          :messages,
          :history,
          :system,
          :system_prompt,
          :tools,
          :developer_context,
          :agent_instructions,
          :skills_index,
          :prompt_mode,
          :previous_turn_boundary_seq,
          :max_tokens,
          :reasoning_effort,
          :web_search,
          :hosted_tools,
          :output_schema
        ] do
      hostile_request =
        request()
        |> Map.put(field, "atom")
        |> Map.put(Atom.to_string(field), "string")

      assert {:error,
              %{
                error: %{
                  kind: :invalid_args,
                  details: %{field: ^field, reason: "normalized_key_collision"}
                }
              }} = Anthropic.stream(hostile_request, max_retries: 0)
    end
  end

  test "idle timeout cuts a stalled stream with StreamIdle error shape" do
    transport = fn _http_request, acc, _fun ->
      Process.sleep(:infinity)
      {:ok, acc}
    end

    assert {:error,
            %{
              error: %{
                kind: :stream_idle_timeout,
                details: %{timeout_ms: 1, transport: "http_sse"}
              }
            }} =
             Anthropic.stream(request(),
               api_key: "sk-ant-test",
               transport: transport,
               stream_idle_timeout_ms: 1,
               max_retries: 0
             )
  end

  test "non-structured transport failures cannot echo the Anthropic API key" do
    sentinel = "ANTHROPIC_SECRET_TRANSPORT_SENTINEL"
    transport = fn request, acc, _fun -> {:error, {:echo, request}, acc} end

    assert {:error,
            %{
              error: %{
                kind: :network,
                details: %{reason: :transport_failure}
              }
            } = error} =
             Anthropic.stream(request(),
               api_key: sentinel,
               transport: transport,
               max_retries: 0
             )

    refute inspect(error) =~ sentinel
  end

  test "structured transport failures cannot echo the Anthropic API key" do
    sentinel = "ANTHROPIC_SECRET_STRUCTURED_TRANSPORT_SENTINEL"
    {:ok, attempts} = Agent.start_link(fn -> 0 end)

    transport = fn request, acc, _fun ->
      Agent.update(attempts, &(&1 + 1))

      error =
        Pixir.Tool.error(:provider_http_error, "transport echoed #{sentinel}", %{
          request: request
        })

      {:error, error, acc}
    end

    assert {:error,
            %{
              error: %{
                kind: :provider_http_error,
                message: "Provider transport returned an error.",
                details: %{}
              }
            } = error} =
             Anthropic.stream(request(),
               api_key: sentinel,
               transport: transport,
               max_retries: 2,
               sleep: fn _ -> :ok end
             )

    refute inspect(error) =~ sentinel
    assert Agent.get(attempts, & &1) == 1
  end

  test "explicit snapshotted retries do not eagerly reread Config" do
    chunks = [sse(%{type: "message_delta", delta: %{stop_reason: "end_turn"}})]
    tracer = spawn_link(fn -> trace_counter(0) end)

    Code.ensure_loaded!(Pixir.Config)
    assert 1 = :erlang.trace_pattern({Pixir.Config, :max_retries, 0}, true, [:local])
    assert 1 = :erlang.trace(self(), true, [:call, {:tracer, tracer}])

    try do
      assert {:ok, _result} =
               Anthropic.stream(request(),
                 api_key: "sk-ant-test",
                 transport: canned(chunks),
                 max_retries: 0
               )

      assert trace_count(self(), tracer) == 0

      assert {:ok, _result} =
               Anthropic.stream(request(),
                 api_key: "sk-ant-test",
                 transport: canned(chunks)
               )

      assert trace_count(self(), tracer) == 1
    after
      :erlang.trace(self(), false, [:call])
      :erlang.trace_pattern({Pixir.Config, :max_retries, 0}, false, [:local])
      send(tracer, :stop)
    end
  end

  test "reasoning_effort maps to output_config and rejected OpenAI-shaped keys are absent" do
    chunks = [sse(%{type: "message_delta", delta: %{stop_reason: "end_turn"}})]

    assert {:ok, _result} =
             Anthropic.stream(
               request(%{
                 system: [%{"type" => "text", "text" => "sys"}],
                 tools: [%{"name" => "read", "description" => "read", "input_schema" => %{}}],
                 reasoning_effort: :high,
                 thinking: %{type: "enabled"},
                 temperature: 0.1,
                 top_p: 0.2,
                 top_k: 5,
                 text_verbosity: "low",
                 prompt_cache_key: "unsafe",
                 prompt_cache_retention: "24h"
               }),
               api_key: "sk-ant-test",
               base_url: "https://anthropic.test",
               transport: canned(chunks)
             )

    assert_received {:request,
                     %{url: "https://anthropic.test/v1/messages", body: body, headers: headers}}

    decoded = Jason.decode!(body)

    assert decoded["stream"] == true
    assert decoded["max_tokens"] == 32_000
    assert decoded["output_config"] == %{"effort" => "high"}
    assert decoded["system"] == [%{"type" => "text", "text" => "sys"}]

    assert decoded["tools"] == [
             %{"name" => "read", "description" => "read", "input_schema" => %{}}
           ]

    assert {"x-api-key", "sk-ant-test"} in headers
    assert {"anthropic-version", "2023-06-01"} in headers

    refute Enum.any?(headers, fn {name, _value} ->
             String.downcase(to_string(name)) in ["authorization", "chatgpt-account-id"]
           end)

    refute Map.has_key?(decoded, "thinking")
    refute Map.has_key?(decoded, "temperature")
    refute Map.has_key?(decoded, "top_p")
    refute Map.has_key?(decoded, "top_k")
    refute Map.has_key?(decoded, "text")
    refute Map.has_key?(decoded, "text_verbosity")
    refute Map.has_key?(decoded, "prompt_cache_key")
    refute Map.has_key?(decoded, "prompt_cache_retention")
  end

  defp trace_count(tracee, tracer) do
    delivery_ref = :erlang.trace_delivered(tracee)
    assert_receive {:trace_delivered, ^tracee, ^delivery_ref}, 1_000

    snapshot_ref = make_ref()
    send(tracer, {:snapshot, self(), snapshot_ref})
    assert_receive {:trace_count, ^snapshot_ref, count}, 1_000
    count
  end

  defp trace_counter(count) do
    receive do
      {:trace, _pid, :call, {Pixir.Config, :max_retries, []}} ->
        trace_counter(count + 1)

      {:snapshot, caller, ref} ->
        send(caller, {:trace_count, ref, count})
        trace_counter(count)

      :stop ->
        :ok
    end
  end
end
