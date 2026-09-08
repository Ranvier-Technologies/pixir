defmodule Pixir.ProviderUsageProvenanceTest do
  use ExUnit.Case, async: false

  alias Pixir.{Auth, Events, Log, Provider, SessionSupervisor, Turn}
  alias Pixir.Provider.ContextWindow

  defmodule NoOAuth do
    def refresh_skew_ms, do: 60_000
  end

  setup do
    Pixir.Test.OperatorState.isolate_pixir_home!()

    workspace =
      Path.join(System.tmp_dir!(), "pixir-usage-provenance-#{System.unique_integer([:positive])}")

    File.mkdir_p!(workspace)
    auth = :"usage_provenance_auth_#{System.unique_integer([:positive])}"

    start_supervised!(
      {Auth,
       name: auth,
       store_path: Path.join(workspace, "auth.json"),
       env_api_key: "sk-test-provenance",
       oauth: NoOAuth}
    )

    {:ok, sid, pid} = SessionSupervisor.start_session(workspace: workspace, role: :build)
    :ok = Events.subscribe(sid, only: [:context_pressure])

    on_exit(fn ->
      if Process.alive?(pid), do: DynamicSupervisor.terminate_child(SessionSupervisor, pid)
      File.rm_rf!(workspace)
    end)

    %{
      sid: sid,
      auth: auth,
      workspace: workspace,
      ctx: %{session_id: sid, workspace: workspace, role: :build}
    }
  end

  for {label, usage, expected_reason, normalized} <- [
        {"omitted", :omitted, "usage_missing", 0},
        {"empty", %{}, "usage_missing", 0},
        {"null input", %{"input_tokens" => nil}, "usage_missing", 0},
        {"malformed input", %{"input_tokens" => "bad"}, "usage_invalid", 0},
        {"numeric string", %{"input_tokens" => "245000"}, "usage_invalid", 245_000},
        {"float", %{"input_tokens" => 1.5}, "usage_invalid", 2},
        {"negative", %{"input_tokens" => -1}, "usage_invalid", -1},
        {"boolean", %{"input_tokens" => false}, "usage_invalid", 0},
        {"integer zero", %{"input_tokens" => 0}, nil, 0},
        {"legacy zero", %{"prompt_tokens" => 0}, nil, 0},
        {"observed warning", %{"input_tokens" => 220_000}, nil, 220_000}
      ] do
    test "real Provider to Turn preserves #{label} pressure evidence", context do
      assert_pressure(
        context,
        unquote(Macro.escape(usage)),
        unquote(expected_reason),
        unquote(normalized)
      )
    end
  end

  defp assert_pressure(context, usage, reason, normalized) do
    assert {:ok, "ok"} =
             Turn.run(context.ctx, "check usage",
               provider: Provider,
               model: "gpt-5.5",
               provider_opts: [
                 auth: context.auth,
                 provider_transport: :http_sse,
                 transport: canned(usage)
               ]
             )

    # Read durable NDJSON rather than trusting the in-memory result or event constructor.
    assert {:ok, history} = Log.fold(context.sid, workspace: context.workspace)
    event = Enum.find(history, &(&1.type == :provider_usage))
    assert event
    data = event.data
    assert data["usage_summary"]["input_tokens"] == normalized
    assert data["usage_available"] == (usage != :omitted)
    assert data["model"] == "gpt-5.5"

    assert {:ok, replay_assessment} =
             ContextWindow.assess(data["usage_summary"], data["model"])

    if reason do
      assert data["context_pressure_available"] == false
      assert data["context_pressure_reason"] == reason
      refute Map.has_key?(data, "context_pressure_ratio")
      assert replay_assessment["available"] == false
      assert replay_assessment["reason"] == reason
      refute_received {:pixir_event, %{type: :context_pressure}}
    else
      assert data["context_pressure_available"] == true
      assert data["context_pressure_input_tokens"] == normalized
      assert replay_assessment["available"] == true
      assert replay_assessment["input_tokens"] == normalized

      assert_received {:pixir_event,
                       %{type: :context_pressure, data: %{"presentation" => "snapshot"}}}

      if normalized == 220_000 do
        assert data["context_pressure_tier"] == "warning"

        assert_received {:pixir_event,
                         %{type: :context_pressure, data: %{"presentation" => "notice"}}}
      else
        assert data["context_pressure_tier"] == "none"
        refute_received {:pixir_event, %{type: :context_pressure}}
      end
    end
  end

  test "normalization preserves accounting but cannot promote invalid evidence" do
    for key <- [:input_tokens, "input_tokens", :prompt_tokens, "prompt_tokens"],
        value <- ["bad", "0", 1.5, -1, false] do
      summary = Provider.usage_summary(%{key => value})

      assert {:ok, %{"available" => false, "reason" => "usage_invalid"}} =
               ContextWindow.assess(summary, "gpt-5.5")
    end

    for usage <- [nil, %{}] do
      assert {:ok, %{"available" => false, "reason" => "usage_missing"}} =
               ContextWindow.assess(Provider.usage_summary(usage), "gpt-5.5")
    end

    for key <- [:input_tokens, "input_tokens", :prompt_tokens, "prompt_tokens"] do
      assert {:ok, %{"available" => true, "input_tokens" => 0}} =
               ContextWindow.assess(Provider.usage_summary(%{key => 0}), "gpt-5.5")
    end
  end

  test "unnormalized foreign summaries and unknown capacity remain honest" do
    for summary <- [%{}, nil, %{"input_tokens" => "0"}, %{input_tokens: 1.5}] do
      assert {:ok, %{"available" => false}} = ContextWindow.assess(summary, "gpt-5.5")
    end

    assert {:ok, %{"available" => false, "reason" => "context_window_unknown"}} =
             ContextWindow.assess(Provider.usage_summary(nil), "gpt-6-astra")
  end

  defp canned(usage) do
    response = if usage == :omitted, do: %{}, else: %{"usage" => usage}

    chunks = [
      %{"type" => "response.output_text.delta", "delta" => "ok"},
      %{"type" => "response.completed", "response" => response}
    ]

    fn request, acc, callback ->
      assert {"authorization", "Bearer sk-test-provenance"} in request.headers
      acc = callback.({:status, 200}, acc)

      acc =
        Enum.reduce(chunks, acc, fn chunk, acc ->
          callback.({:data, "data: " <> Jason.encode!(chunk) <> "\n\n"}, acc)
        end)

      {:ok, acc}
    end
  end
end
