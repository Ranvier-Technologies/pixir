defmodule Pixir.Providers.AnthropicUsageProvenanceTest do
  use ExUnit.Case, async: false

  alias Pixir.{Events, Log, SessionSupervisor, Turn}
  alias Pixir.Provider.ContextWindow
  alias Pixir.Providers.Anthropic

  setup do
    Pixir.Test.OperatorState.isolate_pixir_home!()

    workspace =
      Path.join(System.tmp_dir!(), "anthropic-usage-#{System.unique_integer([:positive])}")

    File.mkdir_p!(workspace)
    {:ok, sid, pid} = SessionSupervisor.start_session(workspace: workspace, role: :build)
    :ok = Events.subscribe(sid, only: [:context_pressure])

    on_exit(fn ->
      if Process.alive?(pid), do: DynamicSupervisor.terminate_child(SessionSupervisor, pid)
      File.rm_rf!(workspace)
    end)

    %{sid: sid, workspace: workspace}
  end

  for {label, usage, reason, count} <- [
        {"omitted", :omitted, "usage_missing", 0},
        {"empty", %{}, "usage_missing", 0},
        {"invalid", %{"input_tokens" => "bad"}, "usage_invalid", 0},
        {"string", %{"input_tokens" => "0"}, "usage_invalid", 0},
        {"float", %{"input_tokens" => 1.5}, "usage_invalid", 0},
        {"negative", %{"input_tokens" => -1}, "usage_invalid", -1},
        {"zero", %{"input_tokens" => 0}, nil, 0},
        {"observed", %{"input_tokens" => 42}, nil, 42}
      ] do
    test "#{label} evidence remains honest through Anthropic, Turn and the Log", ctx do
      check_evidence(ctx, unquote(Macro.escape(usage)), unquote(reason), unquote(count))
    end
  end

  defp check_evidence(ctx, usage, reason, count) do
    message = if usage == :omitted, do: %{}, else: %{"usage" => usage}

    chunks = [
      %{"type" => "message_start", "message" => message},
      %{
        "type" => "content_block_start",
        "index" => 0,
        "content_block" => %{"type" => "text", "text" => ""}
      },
      %{
        "type" => "content_block_delta",
        "index" => 0,
        "delta" => %{"type" => "text_delta", "text" => "ok"}
      },
      %{
        "type" => "message_delta",
        "delta" => %{"stop_reason" => "end_turn"},
        "usage" => %{"output_tokens" => 1}
      },
      %{"type" => "message_stop"}
    ]

    transport = fn _, acc, fun ->
      acc = fun.({:status, 200}, acc)

      {:ok,
       Enum.reduce(chunks, acc, fn chunk, state ->
         fun.({:data, "data: " <> Jason.encode!(chunk) <> "\n\n"}, state)
       end)}
    end

    assert {:ok, "ok"} =
             Turn.run(%{session_id: ctx.sid, workspace: ctx.workspace, role: :build}, "check",
               provider: Anthropic,
               model: "claude-fable-5",
               skills_opts: [roots: []],
               provider_opts: [api_key: "sk-ant-test", transport: transport]
             )

    assert {:ok, history} = Log.fold(ctx.sid, workspace: ctx.workspace)
    data = Enum.find(history, &(&1.type == :provider_usage)).data
    assert data["usage_summary"]["input_tokens"] == count
    assert {:ok, assessment} = ContextWindow.assess(data["usage_summary"], "claude-fable-5")

    if reason do
      assert data["context_pressure_available"] == false
      assert data["context_pressure_reason"] == reason
      assert assessment["reason"] == reason
      refute assessment["available"]
      refute_received {:pixir_event, %{type: :context_pressure}}
    else
      assert data["context_pressure_available"] == true
      assert assessment["input_tokens"] == count
      assert_received {:pixir_event, %{type: :context_pressure}}
    end
  end
end
