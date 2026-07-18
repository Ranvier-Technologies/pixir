defmodule Pixir.Providers.ResolvedProviderRequestTest do
  use ExUnit.Case, async: false

  alias Pixir.Providers.{Registry, ResolvedProviderRequest, ResponsesBackend}

  defmodule LegacyCustomProvider do
    def stream(_request, _opts), do: {:error, :not_called}
  end

  defmodule CertifiedResponsesProvider do
    def stream(request, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:certified_custom_stream, request, opts})
      {:ok, :custom_provider_result}
    end

    def responses_backend_compatible?, do: true
  end

  setup do
    prior_model = Application.get_env(:pixir, :model)
    prior_env = System.get_env("PIXIR_MODEL")
    Application.delete_env(:pixir, :model)
    System.delete_env("PIXIR_MODEL")

    on_exit(fn ->
      if prior_model,
        do: Application.put_env(:pixir, :model, prior_model),
        else: Application.delete_env(:pixir, :model)

      if prior_env,
        do: System.put_env("PIXIR_MODEL", prior_env),
        else: System.delete_env("PIXIR_MODEL")
    end)

    :ok
  end

  test "default and Claude selections are atomic and backend-applicable only to Responses" do
    assert {:ok, gpt} = resolve(%{"model" => "gpt-5.5"})
    assert ResolvedProviderRequest.provider(gpt) == Pixir.Provider
    assert ResolvedProviderRequest.model(gpt) == "gpt-5.5"
    assert ResolvedProviderRequest.dialect(gpt) == :responses
    assert ResponsesBackend.mode(ResolvedProviderRequest.responses_backend(gpt)) == :chatgpt_codex

    assert {:ok, claude} = resolve(%{"model" => "claude-fable-5"})
    assert ResolvedProviderRequest.provider(claude) == Pixir.Providers.Anthropic
    assert ResolvedProviderRequest.model(claude) == "claude-fable-5"
    assert ResolvedProviderRequest.dialect(claude) == :anthropic
    assert ResolvedProviderRequest.responses_backend(claude) == :not_applicable
  end

  test "snapshot loader is called once and its seam never survives" do
    {:ok, calls} = Agent.start_link(fn -> 0 end)

    loader = fn opts ->
      invocation = Agent.get_and_update(calls, &{&1, &1 + 1})
      refute Keyword.has_key?(opts, :request_snapshot_loader)

      if invocation == 0 do
        {:ok,
         %{
           present?: true,
           origin: :file,
           document:
             Jason.encode!(%{
               "model" => "gpt-5.4-mini",
               "responses_backend" => open_profile()
             })
         }}
      else
        flunk("request snapshot loader was invoked more than once")
      end
    end

    assert {:ok, resolved} =
             Registry.resolve_request(selection(), request_snapshot_loader: loader)

    assert Agent.get(calls, & &1) == 1
    assert ResolvedProviderRequest.model(resolved) == "gpt-5.4-mini"

    assert ResponsesBackend.mode(ResolvedProviderRequest.responses_backend(resolved)) ==
             :open_responses

    projection = inspect(resolved)
    refute projection =~ "request_snapshot_loader"
    refute projection =~ "#Function"
    refute projection =~ "vendor.example"
  end

  test "request model wins opts model while explicit profiles select Responses" do
    assert {:ok, resolved} =
             Registry.resolve_request(
               selection(%{
                 request: %{model: "gpt-request"},
                 provider_opts: [model: "gpt-opts", responses_backend: open_profile()]
               }),
               raw_config: %{"model" => "claude-fable-5"}
             )

    assert ResolvedProviderRequest.model(resolved) == "gpt-request"
    assert ResolvedProviderRequest.provider(resolved) == Pixir.Provider
    assert ResolvedProviderRequest.source_evidence(resolved).model == :request
    assert ResolvedProviderRequest.source_evidence(resolved).responses_backend == :provider_opts
  end

  test "request model authority rejects atom/string dual keys including equal and nil forms" do
    for request <- [
          %{"model" => "claude-sonnet-5", model: "gpt-5.5"},
          %{"model" => "gpt-5.5", model: "gpt-5.5"},
          %{"model" => "claude-sonnet-5", model: nil},
          %{"model" => nil, model: "claude-sonnet-5"}
        ] do
      assert {:error,
              %{
                error: %{
                  kind: :invalid_config,
                  details: %{field: :model, reason: :invalid_type}
                }
              }} =
               Registry.resolve_request(selection(%{request: request}), raw_config: %{})
    end
  end

  test "explicit models require valid UTF-8 while valid Unicode ids remain accepted" do
    invalid = <<255>>

    invalid_selections = [
      selection(%{request: %{model: invalid}}),
      selection(%{request: %{"model" => invalid}}),
      selection(%{provider_opts: [model: invalid]})
    ]

    for invalid_selection <- invalid_selections do
      assert {:error,
              %{
                error: %{
                  kind: :invalid_config,
                  details: %{field: :model, reason: :invalid_type}
                }
              }} = Registry.resolve_request(invalid_selection, raw_config: %{})
    end

    assert {:ok, unicode} =
             Registry.resolve_request(
               selection(%{request: %{model: "modelo-ñ"}}),
               raw_config: %{}
             )

    assert ResolvedProviderRequest.model(unicode) == "modelo-ñ"
  end

  test "explicit request and Provider-option models use the same trimmed routing identity" do
    for selection <- [
          selection(%{request: %{model: "  claude-opus-4-8  "}}),
          selection(%{provider_opts: [model: "  claude-opus-4-8  "]})
        ] do
      assert {:ok, resolved} = Registry.resolve_request(selection, raw_config: %{})
      assert ResolvedProviderRequest.model(resolved) == "claude-opus-4-8"
      assert ResolvedProviderRequest.provider(resolved) == Pixir.Providers.Anthropic
      assert ResolvedProviderRequest.dialect(resolved) == :anthropic
    end
  end

  test "selection maps reject atom/string authority collisions" do
    base = selection()

    collisions = [
      Map.put(base, "provider_intent", {:explicit, Pixir.Provider}),
      Map.put(base, "request", %{model: "gpt-string"}),
      Map.put(base, "provider_opts", model: "gpt-string")
    ]

    for collision <- collisions do
      assert {:error,
              %{
                error: %{
                  kind: :invalid_config,
                  details: %{reason: :invalid_resolved_request}
                }
              }} = Registry.resolve_request(collision, raw_config: %{})
    end
  end

  test "selection rejects struct-shaped request documents" do
    for request <- [URI.parse("https://selection.example"), DateTime.utc_now(), MapSet.new()] do
      assert {:error,
              %{
                error: %{
                  kind: :invalid_config,
                  details: %{reason: :invalid_resolved_request}
                }
              }} =
               Registry.resolve_request(selection(%{request: request}), raw_config: %{})
    end
  end

  test "known Provider summaries stay truthful without loading arbitrary modules" do
    assert {:ok, resolved} = resolve(%{"model" => "claude-fable-5"})
    assert ResolvedProviderRequest.safe_summary(resolved).provider == Pixir.Providers.Anthropic
  end

  test "absent-profile custom providers receive only the legacy operational opts" do
    legacy = [agent: self(), marker: {:kept, 1}]

    assert {:ok, resolved} =
             Registry.resolve_request(
               selection(%{
                 provider_intent: {:explicit, LegacyCustomProvider},
                 provider_opts: legacy
               }),
               raw_config: %{"model" => "gpt-5.4-mini"}
             )

    assert ResolvedProviderRequest.dialect(resolved) == :custom
    assert ResolvedProviderRequest.responses_backend(resolved) == :not_applicable

    assert ResolvedProviderRequest.attach_to_provider_opts(resolved, legacy) ===
             [stream_idle_timeout_ms: 180_000, max_retries: 2] ++ legacy
  end

  test "attachment consumes Config ingress seams for custom and Anthropic providers" do
    assert {:ok, custom} =
             Registry.resolve_request(
               selection(%{provider_intent: {:explicit, LegacyCustomProvider}}),
               raw_config: %{"model" => "gpt-5.4-mini"}
             )

    assert {:ok, anthropic} =
             Registry.resolve_request(
               selection(),
               raw_config: %{"model" => "claude-fable-5"}
             )

    ingress = [
      marker: :kept,
      config_path: "/tmp/must-not-survive",
      raw_config: %{"secret" => "must-not-survive"},
      request_snapshot_loader: fn _ -> :must_not_survive end
    ]

    for resolved <- [custom, anthropic] do
      attached = ResolvedProviderRequest.attach_to_provider_opts(resolved, ingress)
      assert attached[:marker] == :kept

      refute Enum.any?(
               [:config_path, :raw_config, :request_snapshot_loader],
               &Keyword.has_key?(attached, &1)
             )
    end
  end

  test "child Turns inherit operational defaults but own backend resolution" do
    assert {:ok, parent} =
             Registry.resolve_request(
               selection(),
               raw_config: %{"model" => "gpt-parent"}
             )

    parent_opts =
      ResolvedProviderRequest.attach_to_provider_opts(parent,
        marker: :kept,
        request_snapshot_loader: fn _ -> :must_not_survive end
      )

    child_opts = ResolvedProviderRequest.for_child_turn(parent_opts)

    assert child_opts[:marker] == :kept
    assert child_opts[:model] == "gpt-parent"
    assert child_opts[:max_retries] == 2
    assert child_opts[:stream_idle_timeout_ms] == 180_000

    refute Enum.any?(
             [
               :resolved_provider_request,
               :responses_backend,
               :config_path,
               :raw_config,
               :request_snapshot_loader
             ],
             &Keyword.has_key?(child_opts, &1)
           )

    refute Enum.any?(child_opts, fn {_key, value} -> is_function(value) end)

    assert {:ok, staged_child} =
             Registry.resolve_request(
               selection(%{provider_opts: child_opts}),
               raw_config: %{
                 "responses_backend" => open_profile()
               }
             )

    assert ResponsesBackend.mode(ResolvedProviderRequest.responses_backend(staged_child)) ==
             :open_responses

    assert :ok =
             staged_child
             |> ResolvedProviderRequest.responses_backend()
             |> ResponsesBackend.activation_status()

    assert {:ok, default_child} =
             Registry.resolve_request(
               selection(%{provider_opts: child_opts}),
               raw_config: %{}
             )

    assert ResolvedProviderRequest.provider(default_child) == Pixir.Provider
    assert ResolvedProviderRequest.model(default_child) == "gpt-parent"

    assert ResponsesBackend.mode(ResolvedProviderRequest.responses_backend(default_child)) ==
             :chatgpt_codex
  end

  test "provider defaults retain legacy precedence and stay private" do
    raw = %{
      "max_retries" => 8,
      "stream_idle_timeout_ms" => 45_000,
      "reasoning" => %{"effort" => "low"},
      "text" => %{"verbosity" => "high"},
      "web_search" => %{"enabled" => true}
    }

    assert {:ok, resolved} =
             Registry.resolve_request(
               selection(%{
                 provider_opts: [
                   max_retries: 1,
                   reasoning_effort: "xhigh",
                   model: "caller-model"
                 ]
               }),
               raw_config: raw
             )

    attached = ResolvedProviderRequest.attach_to_provider_opts(resolved, marker: :kept)
    assert ResolvedProviderRequest.provider_defaults_valid?(resolved)
    assert attached[:max_retries] == 8
    assert attached[:stream_idle_timeout_ms] == 45_000
    assert attached[:reasoning_effort] == "low"
    assert attached[:text_verbosity] == "high"
    assert attached[:web_search] == %{"enabled" => true}
    assert attached[:model] == "caller-model"
    refute Keyword.has_key?(attached, :provider_defaults)

    explicit =
      ResolvedProviderRequest.attach_to_provider_opts(resolved,
        max_retries: 1,
        stream_idle_timeout_ms: 99,
        reasoning_effort: "xhigh",
        text_verbosity: "medium",
        web_search: false,
        model: "must-not-win"
      )

    assert explicit[:max_retries] == 1
    assert explicit[:stream_idle_timeout_ms] == 99
    assert explicit[:reasoning_effort] == "xhigh"
    assert explicit[:text_verbosity] == "medium"
    assert explicit[:web_search] == false
    assert explicit[:model] == "caller-model"

    projection = inspect(resolved)
    refute projection =~ "provider_defaults"
    refute projection =~ "45000"
  end

  test "certified custom providers accept only open profiles" do
    assert {:ok, resolved} =
             Registry.resolve_request(
               selection(%{
                 provider_intent: {:explicit, CertifiedResponsesProvider},
                 request: %{model: "vendor-model"},
                 provider_opts: [responses_backend: open_profile()]
               }),
               raw_config: %{}
             )

    attached = ResolvedProviderRequest.attach_to_provider_opts(resolved, marker: :kept)
    assert attached[:marker] == :kept
    assert attached[:model] == "vendor-model"
    assert attached[:resolved_provider_request] === resolved

    backend = ResolvedProviderRequest.responses_backend(resolved)
    assert ResponsesBackend.activation_status(backend) == :ok
    assert ResponsesBackend.request_extensions(backend) == MapSet.new()

    provider = ResolvedProviderRequest.provider(resolved)

    assert {:ok, :custom_provider_result} =
             provider.stream(:opaque_custom_request, Keyword.put(attached, :test_pid, self()))

    assert_received {:certified_custom_stream, :opaque_custom_request, custom_opts}
    assert custom_opts[:responses_backend] === backend
    refute_received {:open_request, _pixir_request}

    assert {:error,
            %{error: %{kind: :invalid_config, details: %{reason: :incompatible_provider}}}} =
             Registry.resolve_request(
               selection(%{
                 provider_intent: {:explicit, CertifiedResponsesProvider},
                 provider_opts: [responses_backend: %{"mode" => "chatgpt_codex"}]
               }),
               raw_config: %{}
             )
  end

  test "certified custom Responses providers must explicitly acknowledge Claude models" do
    base = %{
      provider_intent: {:explicit, CertifiedResponsesProvider},
      request: %{},
      provider_opts: [responses_backend: open_profile()]
    }

    assert {:error, %{error: %{kind: :invalid_config, details: %{reason: :model_conflict}}}} =
             Registry.resolve_request(
               selection(base),
               raw_config: %{"model" => "claude-fable-5"}
             )

    for {request, provider_opts, source} <- [
          {%{model: "claude-fable-5"}, base.provider_opts, :request},
          {%{}, [model: "claude-fable-5"] ++ base.provider_opts, :provider_opts}
        ] do
      assert {:ok, resolved} =
               Registry.resolve_request(
                 selection(%{
                   base
                   | request: request,
                     provider_opts: provider_opts
                 }),
                 raw_config: %{}
               )

      assert ResolvedProviderRequest.provider(resolved) == CertifiedResponsesProvider
      assert ResolvedProviderRequest.model(resolved) == "claude-fable-5"
      assert ResolvedProviderRequest.source_evidence(resolved).model == source
    end
  end

  test "uncertified and Anthropic Providers reject explicit Responses profiles" do
    for provider <- [LegacyCustomProvider, Pixir.Providers.Anthropic] do
      assert {:error,
              %{error: %{kind: :invalid_config, details: %{reason: :incompatible_provider}}}} =
               Registry.resolve_request(
                 selection(%{
                   provider_intent: {:explicit, provider},
                   provider_opts: [responses_backend: open_profile()]
                 }),
                 raw_config: %{}
               )
    end
  end

  test "a Config-derived Claude model cannot be smuggled through an explicit Responses Provider" do
    assert {:error, %{error: %{kind: :invalid_config, details: %{reason: :model_conflict}}}} =
             Registry.resolve_request(
               selection(%{
                 provider_intent: {:direct, Pixir.Provider},
                 provider_opts: [responses_backend: open_profile()]
               }),
               raw_config: %{"model" => "claude-fable-5"}
             )

    assert {:ok, explicit} =
             Registry.resolve_request(
               selection(%{
                 provider_intent: {:direct, Pixir.Provider},
                 request: %{model: "claude-fable-5"},
                 provider_opts: [responses_backend: open_profile()]
               }),
               raw_config: %{}
             )

    assert ResolvedProviderRequest.model(explicit) == "claude-fable-5"
  end

  test "absent-profile direct Pixir.Provider remains an explicit legacy Claude override" do
    assert {:ok, resolved} =
             Registry.resolve_request(
               selection(%{provider_intent: {:direct, Pixir.Provider}}),
               raw_config: %{"model" => "claude-fable-5"}
             )

    assert ResolvedProviderRequest.provider(resolved) == Pixir.Provider
    assert ResolvedProviderRequest.model(resolved) == "claude-fable-5"

    assert ResponsesBackend.mode(ResolvedProviderRequest.responses_backend(resolved)) ==
             :chatgpt_codex
  end

  defp resolve(raw), do: Registry.resolve_request(selection(), raw_config: raw)

  defp selection(overrides \\ %{}) do
    Map.merge(%{provider_intent: :auto, request: %{}, provider_opts: []}, overrides)
  end

  defp open_profile do
    %{
      "mode" => "open_responses",
      "responses_url" => "https://vendor.example/v1/responses",
      "auth" => %{"policy" => "none"}
    }
  end
end
