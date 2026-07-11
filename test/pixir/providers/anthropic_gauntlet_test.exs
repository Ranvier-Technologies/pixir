defmodule Pixir.Providers.AnthropicGauntletTest do
  # End-to-end no-network regression pins for the Anthropic arc. These proofs use
  # SessionSupervisor-backed Turn.run paths, so they are serialized like the
  # AnthropicTurnProofTest seam they mirror.
  use ExUnit.Case, async: false

  alias Pixir.{Event, Log, Session, SessionSupervisor, Turn}
  alias Pixir.Providers.Anthropic
  alias Pixir.Providers.ErrBody

  defmodule RequestCaptureProvider do
    def stream(request, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:provider_request, request})

      {:ok,
       %{
         text: "stub ok",
         reasoning: "",
         function_calls: [],
         finish_reason: :stop,
         usage_summary: Pixir.Provider.usage_summary(nil)
       }}
    end
  end

  setup do
    ws =
      Path.join(
        System.tmp_dir!(),
        "pixir-anthropic-gauntlet-" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
      )

    File.mkdir_p!(ws)
    {:ok, sid, pid} = SessionSupervisor.start_session(workspace: ws, role: :build)

    skills_root = Path.join(ws, "isolated-skills")
    File.mkdir_p!(skills_root)

    on_exit(fn ->
      if Process.alive?(pid), do: DynamicSupervisor.terminate_child(SessionSupervisor, pid)
      File.rm_rf!(ws)
    end)

    %{
      ws: ws,
      sid: sid,
      ctx: %{session_id: sid, workspace: ws, role: :build},
      skills_root: skills_root,
      skills_opts: [roots: [{"repo", skills_root}]]
    }
  end

  defp sse(map), do: "data: " <> Jason.encode!(map) <> "\n\n"

  defp capture_transport(chunks, test_pid \\ self()) do
    fn http_request, acc, fun ->
      send(test_pid, {:anthropic_body, Jason.decode!(http_request.body)})
      acc = fun.({:status, 200}, acc)

      Enum.reduce(chunks, acc, fn chunk, a -> fun.({:data, chunk}, a) end)
      |> then(&{:ok, &1})
    end
  end

  defp sequence_transport(chunks_by_request, test_pid \\ self()) do
    counter = :counters.new(1, [])

    fn http_request, acc, fun ->
      send(test_pid, {:anthropic_body, Jason.decode!(http_request.body)})
      request_index = :counters.get(counter, 1)
      :counters.add(counter, 1, 1)

      # A gauntlet must flunk on unexpected extra requests (a retry or duplicate
      # loop iteration), never silently replay the last fixture.
      chunks =
        Enum.at(chunks_by_request, request_index) ||
          raise "unexpected Anthropic request ##{request_index + 1}: only #{length(chunks_by_request)} canned responses were scripted"

      acc = fun.({:status, 200}, acc)

      Enum.reduce(chunks, acc, fn chunk, a -> fun.({:data, chunk}, a) end)
      |> then(&{:ok, &1})
    end
  end

  defp error_transport(status, body, headers \\ [], test_pid \\ self()) do
    fn http_request, acc, fun ->
      send(test_pid, {:anthropic_body, Jason.decode!(http_request.body)})
      acc = fun.({:status, status}, acc)
      acc = fun.({:headers, headers}, acc)
      acc = fun.({:data, body}, acc)
      {:ok, acc}
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

  defp cache_usage_chunks(text \\ "cache ok") do
    [
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
      sse(%{type: "content_block_start", index: 0, content_block: %{type: "text", text: ""}}),
      sse(%{type: "content_block_delta", index: 0, delta: %{type: "text_delta", text: text}}),
      sse(%{
        type: "message_delta",
        delta: %{stop_reason: "end_turn"},
        usage: %{output_tokens: 50}
      }),
      sse(%{type: "message_stop"})
    ]
  end

  defp tool_use_chunks(call_id, path) do
    [
      sse(%{
        type: "message_start",
        message: %{model: "claude-fable-5", usage: %{input_tokens: 7, output_tokens: 0}}
      }),
      sse(%{
        type: "content_block_start",
        index: 0,
        content_block: %{type: "tool_use", id: call_id, name: "read", input: %{}}
      }),
      sse(%{
        type: "content_block_delta",
        index: 0,
        delta: %{type: "input_json_delta", partial_json: Jason.encode!(%{path: path})}
      }),
      sse(%{type: "content_block_stop", index: 0}),
      sse(%{type: "message_delta", delta: %{stop_reason: "tool_use"}}),
      sse(%{type: "message_stop"})
    ]
  end

  defp thinking_tool_use_chunks(call_id \\ "toolu_replay", path \\ "a.txt") do
    [
      sse(%{
        type: "message_start",
        message: %{model: "claude-fable-5", usage: %{input_tokens: 7, output_tokens: 0}}
      }),
      sse(%{
        type: "content_block_start",
        index: 0,
        content_block: %{type: "thinking", thinking: "", signature: "sig-"}
      }),
      sse(%{
        type: "content_block_delta",
        index: 0,
        delta: %{type: "thinking_delta", thinking: "plan"}
      }),
      sse(%{
        type: "content_block_delta",
        index: 0,
        delta: %{type: "signature_delta", signature: "final"}
      }),
      sse(%{type: "content_block_stop", index: 0}),
      sse(%{
        type: "content_block_start",
        index: 1,
        content_block: %{type: "tool_use", id: call_id, name: "read", input: %{}}
      }),
      sse(%{
        type: "content_block_delta",
        index: 1,
        delta: %{type: "input_json_delta", partial_json: Jason.encode!(%{path: path})}
      }),
      sse(%{type: "content_block_stop", index: 1}),
      sse(%{type: "message_delta", delta: %{stop_reason: "tool_use"}}),
      sse(%{type: "message_stop"})
    ]
  end

  defp anthropic_request(overrides \\ %{}) do
    Map.merge(
      %{
        model: "claude-fable-5",
        messages: [%{"role" => "user", "content" => [%{"type" => "text", "text" => "hello"}]}]
      },
      overrides
    )
  end

  defp write_skill(root, name) do
    dir = Path.join(root, name)
    File.mkdir_p!(dir)

    File.write!(
      Path.join(dir, "SKILL.md"),
      "# #{name}\n\nUse when testing the Anthropic gauntlet skill routing seam.\n"
    )
  end

  defp receive_body do
    receive do
      {:anthropic_body, body} -> body
    after
      500 -> flunk("expected captured Anthropic request body")
    end
  end

  defp detail(details, key) do
    string_key = Atom.to_string(key)

    cond do
      Map.has_key?(details, key) -> Map.fetch!(details, key)
      Map.has_key?(details, string_key) -> Map.fetch!(details, string_key)
      true -> nil
    end
  end

  defp compaction_data(from_seq, to_seq, summary) do
    %{
      "range" => %{"from_seq" => from_seq, "to_seq" => to_seq},
      "source_event_count" => to_seq - from_seq + 1,
      "strategy" => "deterministic_operational_summary_v1",
      "summary" => summary,
      "files_touched" => [],
      "open_tasks" => [],
      "limitations" => []
    }
  end

  defp assistant_message_with_tool_use(body, call_id) do
    Enum.find(body["messages"], fn message ->
      message["role"] == "assistant" and
        Enum.any?(message["content"] || [], &(&1["type"] == "tool_use" and &1["id"] == call_id))
    end)
  end

  test "pin 1 request body: Turn.run emits pa1 system blocks, B1 cache_control, and fenced late context",
       %{ctx: ctx, ws: ws, skills_root: skills_root, skills_opts: skills_opts} do
    write_skill(skills_root, "repo-skill")

    assert {:ok, "ok"} =
             Turn.run(ctx, "use the repo skill",
               provider: Anthropic,
               provider_opts: [
                 model: "claude-fable-5",
                 transport: capture_transport(ok_chunks()),
                 api_key: "sk-ant-test"
               ],
               skills_opts: skills_opts,
               agent_instructions: "Stay scoped."
             )

    body = receive_body()

    assert body["model"] == "claude-fable-5"
    assert [layer0 | _] = body["system"]
    assert layer0["text"] =~ "You are Pixir"
    refute layer0["text"] =~ "repo-skill"
    refute layer0["text"] =~ "Use when testing the Anthropic gauntlet skill routing seam."

    # B1 is the metadata-only routing index (name/when_to_use/location); the
    # skill's body text is never rendered here (progressive disclosure). F13's
    # meaningful check is the refute above: the skill name must not reach the
    # byte-stable layer0, while the routing metadata lives in the cacheable B1.
    system_b1 = List.last(body["system"])
    assert system_b1["text"] =~ "repo-skill"
    assert system_b1["cache_control"] == %{"type" => "ephemeral"}

    latest_user = List.last(body["messages"])
    assert latest_user["role"] == "user"
    assert [fence_block, prompt_block | _] = latest_user["content"]
    assert fence_block["text"] =~ "<<<PIXIR_PA1_LATE_CONTEXT:AUTHORITY>>>"
    assert fence_block["text"] =~ ~s(Developer context: the workspace root is "#{ws}")
    assert fence_block["text"] =~ "Subagent role instructions:\nStay scoped."
    assert prompt_block["text"] == "use the repo skill"
  end

  test "pin 2 registry routing: claude model selects Anthropic, explicit stub provider stays OpenAI-shaped",
       %{ctx: ctx, skills_opts: skills_opts} do
    assert {:ok, "routed"} =
             Turn.run(ctx, "registry route",
               provider_opts: [
                 model: "claude-fable-5",
                 transport: capture_transport(ok_chunks("routed")),
                 api_key: "sk-ant-test"
               ],
               skills_opts: skills_opts
             )

    anthropic_body = receive_body()
    assert anthropic_body["model"] == "claude-fable-5"
    assert is_list(anthropic_body["system"])
    assert Enum.any?(anthropic_body["tools"], &is_map(&1["input_schema"]))

    assert {:ok, "stub ok"} =
             Turn.run(ctx, "stub route",
               provider: RequestCaptureProvider,
               provider_opts: [test_pid: self(), model: "claude-fable-5"]
             )

    assert_receive {:provider_request, request}
    refute Map.has_key?(request, :prompt_mode)
    refute Map.has_key?(request, :skills_index)
    refute Map.has_key?(request, :agent_instructions)
    refute Map.has_key?(request, :previous_turn_boundary_seq)
    assert request.tools == Pixir.Tools.Registry.responses_specs()
  end

  test "pin 3 thinking replay: Anthropic thinking re-injects verbatim before tool_use and OpenAI reasoning drops",
       %{ctx: ctx, sid: sid, ws: ws, skills_opts: skills_opts} do
    File.write!(Path.join(ws, "a.txt"), "file text")

    assert {:ok, "turn A final"} =
             Turn.run(ctx, "read with thinking",
               provider: Anthropic,
               provider_opts: [
                 model: "claude-fable-5",
                 transport:
                   sequence_transport([thinking_tool_use_chunks(), ok_chunks("turn A final")]),
                 api_key: "sk-ant-test"
               ],
               skills_opts: skills_opts
             )

    _turn_a_first = receive_body()
    _turn_a_second = receive_body()

    assert {:ok, _} =
             Session.record(
               sid,
               Event.reasoning(
                 sid,
                 %{"type" => "reasoning", "id" => "rs_openai", "encrypted_content" => "opaque"},
                 "gpt-5"
               )
             )

    assert {:ok, "turn B final"} =
             Turn.run(ctx, "next question",
               provider: Anthropic,
               provider_opts: [
                 model: "claude-fable-5",
                 transport: capture_transport(ok_chunks("turn B final")),
                 api_key: "sk-ant-test"
               ],
               skills_opts: skills_opts
             )

    turn_b_body = receive_body()
    refute_receive {:anthropic_body, _}, 100
    assistant = assistant_message_with_tool_use(turn_b_body, "toolu_replay")

    assert assistant["content"] == [
             %{"type" => "thinking", "thinking" => "plan", "signature" => "sig-final"},
             %{
               "type" => "tool_use",
               "id" => "toolu_replay",
               "name" => "read",
               "input" => %{"path" => "a.txt"}
             }
           ]

    refute inspect(turn_b_body) =~ "rs_openai"

    # The foreign reasoning must not surface as ANY thinking block either —
    # only the Anthropic-dialect one above replays.
    foreign_thinking =
      for message <- turn_b_body["messages"],
          block <- message["content"] || [],
          block["type"] == "thinking",
          block["signature"] != "sig-final",
          do: block

    assert foreign_thinking == []
  end

  test "pin 4 tool loop: executor result folds into one user tool_result message and tools carry input_schema",
       %{ctx: ctx, ws: ws, skills_opts: skills_opts} do
    File.write!(Path.join(ws, "a.txt"), "hello from file")

    assert {:ok, "done"} =
             Turn.run(ctx, "what is in a.txt?",
               provider: Anthropic,
               provider_opts: [
                 model: "claude-fable-5",
                 transport:
                   sequence_transport([tool_use_chunks("toolu_read", "a.txt"), ok_chunks("done")]),
                 api_key: "sk-ant-test"
               ],
               skills_opts: skills_opts
             )

    first_body = receive_body()
    second_body = receive_body()
    refute_receive {:anthropic_body, _}, 100

    read_tool = Enum.find(first_body["tools"], &(&1["name"] == "read"))
    assert is_map(read_tool["input_schema"])

    assistant = assistant_message_with_tool_use(second_body, "toolu_read")

    assert [
             %{
               "type" => "tool_use",
               "id" => "toolu_read",
               "name" => "read",
               "input" => %{"path" => "a.txt"}
             }
           ] = assistant["content"]

    tool_result_messages =
      Enum.filter(second_body["messages"], fn message ->
        message["role"] == "user" and
          Enum.any?(message["content"] || [], &(&1["type"] == "tool_result"))
      end)

    # pa1 anchors volatile late context on the LATEST user-role message,
    # whatever it is (P3 contract) — mid-tool-loop that is the tool_result
    # group, so the fence leads and the grouped result follows.
    assert [
             %{
               "content" => [
                 %{"type" => "text", "text" => fence_text},
                 %{
                   "type" => "tool_result",
                   "tool_use_id" => "toolu_read",
                   "content" => "hello from file"
                 }
               ]
             }
           ] = tool_result_messages

    assert fence_text =~ "<<<PIXIR_PA1_LATE_CONTEXT:AUTHORITY>>>"
  end

  test "pin 5 cache evidence: provider_usage records Anthropic cache tokens and pa1 prompt contract metadata",
       %{ctx: ctx, sid: sid, ws: ws, skills_opts: skills_opts} do
    assert {:ok, "cache ok"} =
             Turn.run(ctx, "cache evidence",
               provider: Anthropic,
               provider_opts: [
                 model: "claude-fable-5",
                 transport: capture_transport(cache_usage_chunks()),
                 api_key: "sk-ant-test"
               ],
               skills_opts: skills_opts
             )

    _body = receive_body()

    assert {:ok, history} = Log.fold(sid, workspace: ws)
    usage = Enum.find(history, &(&1.type == :provider_usage))

    assert usage.data["usage_summary"]["cache"]["creation_tokens"] == 200
    assert usage.data["usage_summary"]["cache"]["read_tokens"] == 700
    assert usage.data["prompt_contract_version"] == "pa1"
    refute Map.has_key?(usage.data, "prompt_cache_key")

    # Turn merges the provider result's provider_metadata FLAT into the event
    # data (the P4 reconcile lesson): prompt_contract sits at the top level.
    assert contract = usage.data["prompt_contract"]
    assert contract["prompt_contract_version"] == "pa1"
    assert "B1" in contract["breakpoints"]
    assert is_binary(contract["layer0_hash"])
  end

  test "pin 6 compaction interplay: Turn.run drops compacted events, leads with summary, and anchors current user late context",
       %{ctx: ctx, sid: sid, skills_opts: skills_opts} do
    assert {:ok, _} = Session.record(sid, Event.user_message(sid, "compacted-away question"))
    assert {:ok, _} = Session.record(sid, Event.assistant_message(sid, "compacted-away answer"))

    assert {:ok, _} =
             Session.record(
               sid,
               Event.history_compaction(
                 sid,
                 compaction_data(0, 1, "summary of the compacted prior turn")
               )
             )

    assert {:ok, "ok"} =
             Turn.run(ctx, "current question",
               provider: Anthropic,
               provider_opts: [
                 model: "claude-fable-5",
                 transport: capture_transport(ok_chunks()),
                 api_key: "sk-ant-test"
               ],
               skills_opts: skills_opts
             )

    body = receive_body()
    body_text = inspect(body)
    refute body_text =~ "compacted-away question"
    refute body_text =~ "compacted-away answer"

    [summary_message | _] = body["messages"]
    assert summary_message["role"] == "user"

    assert summary_message["content"] |> hd() |> Map.fetch!("text") =~
             "summary of the compacted prior turn"

    latest_user = List.last(body["messages"])
    assert latest_user["role"] == "user"
    assert [fence_block, current_block | _] = latest_user["content"]
    assert fence_block["text"] =~ "<<<PIXIR_PA1_LATE_CONTEXT:AUTHORITY>>>"
    assert current_block["text"] == "current question"
  end

  test "pin 7 error taxonomy sweep: rate limit, context overflow, overload, and oversized bodies classify safely" do
    rate_limit_body = Jason.encode!(%{error: %{type: "rate_limit_error", message: "slow down"}})

    assert {:error, %{error: %{kind: :rate_limited, details: rate_limited}}} =
             Anthropic.stream(anthropic_request(),
               api_key: "sk-ant-test",
               transport: error_transport(429, rate_limit_body, [{"retry-after", "0"}]),
               max_retries: 0
             )

    assert detail(rate_limited, :retryable) == true

    overflow_body =
      Jason.encode!(%{
        error: %{
          type: "invalid_request_error",
          message: "prompt is too long; context window overflow; maximum context length exceeded"
        }
      })

    assert {:error, %{error: %{kind: :context_overflow, details: overflow}}} =
             Anthropic.stream(anthropic_request(),
               api_key: "sk-ant-test",
               transport: error_transport(400, overflow_body),
               max_retries: 0
             )

    assert detail(overflow, :retryable) == false

    overloaded_body = Jason.encode!(%{error: %{type: "overloaded_error", message: "overloaded"}})

    assert {:error, %{error: %{kind: :provider_http_error, details: overloaded}}} =
             Anthropic.stream(anthropic_request(),
               api_key: "sk-ant-test",
               transport: error_transport(529, overloaded_body),
               max_retries: 0
             )

    assert detail(overloaded, :status) == 529
    assert detail(overloaded, :retryable) == true

    oversized_body = String.duplicate("x", ErrBody.max_bytes() + 100)

    assert {:error, %{error: %{kind: :provider_http_error, details: oversized}}} =
             Anthropic.stream(anthropic_request(),
               api_key: "sk-ant-test",
               transport: error_transport(500, oversized_body),
               max_retries: 0
             )

    assert detail(oversized, :err_body_truncated) == true
  end

  test "pin 8 fail-closed knobs: Anthropic rejects provider-hosted web_search and hosted tool specs",
       %{ctx: ctx, skills_opts: skills_opts} do
    assert {:error, %{error: %{kind: :invalid_args, details: web_search}}} =
             Turn.run(ctx, "search the web",
               provider: Anthropic,
               provider_opts: [
                 model: "claude-fable-5",
                 web_search: true,
                 transport: capture_transport(ok_chunks()),
                 api_key: "sk-ant-test"
               ],
               skills_opts: skills_opts
             )

    assert detail(web_search, :unsupported_capability) == "provider_hosted_web_search"

    assert {:error, %{error: %{kind: :invalid_args, details: hosted_tool}}} =
             Anthropic.stream(
               anthropic_request(%{tools: [%{"type" => "web_search_preview", "name" => "web"}]}),
               api_key: "sk-ant-test",
               transport: capture_transport(ok_chunks())
             )

    assert detail(hosted_tool, :unsupported_capability) == "provider_hosted_tools"
  end
end
