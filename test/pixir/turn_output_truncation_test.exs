defmodule Pixir.TurnOutputTruncationTest do
  use ExUnit.Case, async: false

  alias Pixir.{Event, Session, SessionSupervisor, Turn}

  defmodule ScriptedProvider do
    def stream(_request, opts) do
      agent = Keyword.fetch!(opts, :script_agent)
      result = Agent.get_and_update(agent, fn [head | tail] -> {head, tail} end)
      {:ok, result}
    end
  end

  setup do
    workspace =
      Path.join(
        System.tmp_dir!(),
        "pixir-turn-truncation-" <>
          Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
      )

    File.mkdir_p!(workspace)
    File.write!(Path.join(workspace, "fixture.txt"), "fixture\n")
    {:ok, session_id, pid} = SessionSupervisor.start_session(workspace: workspace, role: :build)

    on_exit(fn ->
      if Process.alive?(pid), do: DynamicSupervisor.terminate_child(SessionSupervisor, pid)
      File.rm_rf!(workspace)
    end)

    %{ctx: %{session_id: session_id, workspace: workspace, role: :build}}
  end

  test "every successful call records authoritative correlated evidence after hostile metadata",
       %{
         ctx: ctx
       } do
    call = %{call_id: "call_1", name: "read", args: %{"path" => "fixture.txt"}}

    first =
      result("", :tool_calls, truncated())
      |> Map.put(:function_calls, [call])
      |> Map.put(:output_items, [{:function_call, call}])
      |> Map.put(:provider_metadata, %{
        "output_truncation" => %{"status" => "not_truncated", "provider_reason" => "hostile"}
      })

    second = result("exact final bytes", :stop, not_truncated())
    {:ok, script_agent} = Agent.start_link(fn -> [first, second] end)

    assert {:ok, "exact final bytes"} =
             Turn.run(ctx, "read",
               provider: ScriptedProvider,
               provider_opts: [script_agent: script_agent]
             )

    assert {:ok, history} = Session.history(ctx.session_id)
    usages = Enum.filter(history, &(&1.type == :provider_usage))
    assert length(usages) == 2

    [first_usage, final_usage] = usages
    first_evidence = first_usage.data["output_truncation"]
    final_evidence = final_usage.data["output_truncation"]

    assert first_evidence["status"] == "truncated"
    assert first_evidence["call_role"] == "intermediate"
    assert first_evidence["provider_usage_event_id"] == first_usage.id
    refute Map.has_key?(first_evidence, "provider_usage_seq")

    assert final_evidence["status"] == "not_truncated"
    assert final_evidence["call_role"] == "final_answer"
    assert final_evidence["provider_usage_event_id"] == final_usage.id

    assert [%{data: %{"text" => "exact final bytes"} = assistant}] =
             Enum.filter(history, &(&1.type == :assistant_message))

    refute Map.has_key?(assistant, "metadata")
  end

  test "only final positive evidence is copied with stamped seq and never partial", %{ctx: ctx} do
    {:ok, script_agent} =
      Agent.start_link(fn -> [result("cut but successful", :stop, truncated())] end)

    assert {:ok, "cut but successful"} =
             Turn.run(ctx, "answer",
               provider: ScriptedProvider,
               provider_opts: [script_agent: script_agent]
             )

    assert {:ok, history} = Session.history(ctx.session_id)
    usage = Enum.find(history, &(&1.type == :provider_usage))
    assistant = Enum.find(history, &(&1.type == :assistant_message))
    canonical = usage.data["output_truncation"]
    fallback = assistant.data["metadata"]["output_truncation"]

    assert Map.drop(fallback, ["provider_usage_seq"]) == canonical
    assert fallback["provider_usage_seq"] == usage.seq
    assert fallback["provider_usage_event_id"] == usage.id
    refute assistant.data["metadata"]["partial"]
    assert assistant.data["text"] == "cut but successful"
  end

  test "foreign missing and tokenless evidence become unknown without failing the Turn", %{
    ctx: ctx
  } do
    for evidence <- [:missing, %{status: :not_truncated}] do
      result = result("ok", :stop, not_truncated())

      result =
        if evidence == :missing,
          do: Map.delete(result, :output_truncation),
          else: Map.put(result, :output_truncation, evidence)

      {:ok, script_agent} = Agent.start_link(fn -> [result] end)

      assert {:ok, "ok"} =
               Turn.run(ctx, "next",
                 provider: ScriptedProvider,
                 provider_opts: [script_agent: script_agent]
               )
    end

    assert {:ok, history} = Session.history(ctx.session_id)
    usages = Enum.filter(history, &(&1.type == :provider_usage))
    assert Enum.at(usages, -2).data["output_truncation"]["reason"] == "provider_did_not_report"
    assert List.last(usages).data["output_truncation"]["reason"] == "invalid_evidence"
  end

  test "unsafe Anthropic unmapped stop reason never reaches the durable Turn Log", %{ctx: ctx} do
    unsafe = String.duplicate("LEAK", 17)

    transport = fn _request, acc, fun ->
      acc = fun.({:status, 200}, acc)

      chunk =
        "event: message_delta\ndata: " <>
          Jason.encode!(%{type: "message_delta", delta: %{stop_reason: unsafe}}) <> "\n\n"

      {:ok, fun.({:data, chunk}, acc)}
    end

    assert {:ok, ""} =
             Turn.run(ctx, "answer",
               provider: Pixir.Providers.Anthropic,
               provider_opts: [api_key: "fixture-token", transport: transport, max_retries: 0]
             )

    assert {:ok, history} = Session.history(ctx.session_id)
    encoded = Jason.encode!(Enum.map(history, & &1.data))
    refute encoded =~ unsafe

    usage = Enum.find(history, &(&1.type == :provider_usage))
    assert usage.data["output_truncation"]["reason"] == "invalid_evidence"
    refute Map.has_key?(usage.data["provider_metadata"] || %{}, "unmapped_stop_reason")
  end

  test "clean truncated assistant text replays while provider usage remains audit-only" do
    history = [
      Event.user_message("sid", "question"),
      Event.provider_usage(
        "sid",
        %{
          "output_truncation" => %{
            "status" => "truncated",
            "reason" => "provider_output_limit",
            "provider_reason" => "max_tokens",
            "provider_usage_event_id" => "evt_usage",
            "call_role" => "final_answer"
          }
        },
        id: "evt_usage",
        seq: 1
      ),
      Event.assistant_message("sid", "exact replay text",
        metadata: %{
          "output_truncation" => %{
            "status" => "truncated",
            "reason" => "provider_output_limit",
            "provider_reason" => "max_tokens",
            "provider_usage_event_id" => "evt_usage",
            "provider_usage_seq" => 1,
            "call_role" => "final_answer"
          }
        }
      )
    ]

    assert {:ok, body} =
             Pixir.Provider.request_body_preview(%{
               model: "gpt-5.5",
               system_prompt: "system",
               developer_context: "context",
               history: history,
               tools: []
             })

    encoded = Jason.encode!(body["input"])
    assert encoded =~ "exact replay text"
    refute encoded =~ "provider_output_limit"
  end

  defp result(text, finish_reason, evidence) do
    %{
      text: text,
      reasoning: "",
      reasoning_items: [],
      function_calls: [],
      output_items: [],
      usage: %{},
      usage_summary: Pixir.Provider.usage_summary(%{}),
      provider_metadata: %{},
      finish_reason: finish_reason,
      output_truncation: evidence
    }
  end

  defp truncated do
    %{status: :truncated, reason: :provider_output_limit, provider_reason: "fixture_limit"}
  end

  defp not_truncated do
    %{status: :not_truncated, provider_reason: "fixture_done"}
  end
end
