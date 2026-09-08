defmodule Pixir.ReasoningEffortTest do
  use ExUnit.Case, async: true

  alias Pixir.ReasoningEffort
  alias Pixir.Providers.{Registry, ResponsesBackend}

  test "runtime admission uses the caller's raw Config intent" do
    opts = [model: "gpt-6-astra", raw_config: %{"reasoning" => %{"effort" => "max"}}]
    assert {:ok, "max"} = ReasoningEffort.validate_runtime(Pixir.Provider, opts)
  end

  test "runtime admission uses the caller's raw Config backend before granting max" do
    raw = %{
      "responses_backend" => %{
        "mode" => "open_responses",
        "responses_url" => "https://example.invalid/v1/responses",
        "auth" => %{"policy" => "none"}
      }
    }

    opts = [model: "gpt-6-astra", reasoning_effort: "max", raw_config: raw]

    assert {:error,
            %{error: %{kind: :invalid_config, details: %{reason: :unsupported_reasoning_effort}}}} =
             ReasoningEffort.validate_runtime(Pixir.Provider, opts)
  end

  test "runtime admission uses the caller's config_path intent" do
    path =
      Path.join(
        System.tmp_dir!(),
        "pixir-reasoning-effort-#{System.unique_integer([:positive])}.json"
      )

    File.write!(path, Jason.encode!(%{"reasoning" => %{"effort" => "max"}}))
    on_exit(fn -> File.rm(path) end)

    assert {:ok, "max"} =
             ReasoningEffort.validate_runtime(Pixir.Provider,
               model: "gpt-6-astra",
               config_path: path
             )
  end

  test "runtime admission invokes the caller's snapshot loader once and explicit overrides win" do
    test = self()

    loader = fn opts ->
      send(test, {:runtime_snapshot_loader, opts})

      {:ok,
       %{
         present?: true,
         origin: :file,
         document:
           Jason.encode!(%{
             "model" => "gpt-5.5",
             "reasoning" => %{"effort" => "max"},
             "responses_backend" => %{
               "mode" => "open_responses",
               "responses_url" => "https://example.invalid/v1/responses",
               "auth" => %{"policy" => "none"}
             }
           })
       }}
    end

    assert {:ok, "high"} =
             ReasoningEffort.validate_runtime(Pixir.Provider,
               model: "gpt-6-astra",
               reasoning_effort: "high",
               responses_backend: %{"mode" => "chatgpt_codex"},
               request_snapshot_loader: loader
             )

    assert_receive {:runtime_snapshot_loader, loader_opts}
    refute Keyword.has_key?(loader_opts, :request_snapshot_loader)
    refute_receive {:runtime_snapshot_loader, _}
  end

  test "known intent is distinct from supported capability" do
    assert {:ok, ~w(low medium high xhigh max)} = ReasoningEffort.known_ids()
    assert {:ok, ~w(low medium high xhigh)} = ReasoningEffort.legacy_ids()
    assert ReasoningEffort.known?("max")
    refute ReasoningEffort.known?("ultra")
    assert {:ok, "max"} = ReasoningEffort.normalize(" max ")
    assert {:ok, "max"} = ReasoningEffort.normalize(:max)
    assert {:ok, nil} = ReasoningEffort.normalize(nil)
    assert {:ok, nil} = ReasoningEffort.normalize("default")
    assert {:error, %{error: %{kind: :invalid_config}}} = ReasoningEffort.normalize("ultra")
  end

  test "max is exact-model, provider, backend, and route aware" do
    backend = ResponsesBackend.default()
    assert ReasoningEffort.max_supported?("gpt-6-astra", Pixir.Provider, backend)

    for model <- ["gpt-5.5", "gpt-6-astra-preview", "unknown", nil] do
      refute ReasoningEffort.max_supported?(model, Pixir.Provider, backend)
    end

    refute ReasoningEffort.max_supported?("gpt-6-astra", Pixir.Providers.Anthropic, backend)
    refute ReasoningEffort.max_supported?("gpt-6-astra", Pixir.Provider, :not_applicable)

    refute ReasoningEffort.max_supported?("gpt-6-astra", Pixir.Provider, backend,
             base_url: "https://example.invalid"
           )

    assert {:ok, open} =
             ResponsesBackend.resolve(%{
               "mode" => "open_responses",
               "responses_url" => "https://api.openai.com/v1/responses",
               "auth" => %{"policy" => "none"}
             })

    refute ReasoningEffort.max_supported?("gpt-6-astra", Pixir.Provider, open)
  end

  test "validation uses the immutable effective selection" do
    for {model, expected} <- [
          {"gpt-6-astra", :ok},
          {"gpt-5.5", :error},
          {"claude-fable-5", :error}
        ] do
      assert {:ok, resolved} =
               Registry.resolve_request(
                 %{provider_intent: :auto, request: %{model: model}, provider_opts: []},
                 raw_config: %{}
               )

      assert elem(ReasoningEffort.validate("max", resolved), 0) == expected
      assert {:ok, "high"} = ReasoningEffort.validate("high", resolved)
      assert {:ok, nil} = ReasoningEffort.validate("default", resolved)
    end
  end
end
