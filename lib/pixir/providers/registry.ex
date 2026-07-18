defmodule Pixir.Providers.Registry do
  @moduledoc """
  Provider catalog and routing metadata for Pixir provider dialects.
  """

  alias Pixir.Config
  alias Pixir.Providers.Anthropic
  alias Pixir.Providers.{ResolvedProviderRequest, ResponsesBackend}

  @type entry :: %{
          provider: module(),
          default_model: String.t(),
          models: [map()],
          auth: %{
            env_var: String.t(),
            scheme: :oauth_or_api_key | :api_key_header,
            login_supported: boolean()
          },
          capabilities: %{
            reasoning_dialect: nil | String.t(),
            prompt_cache: :prompt_cache_key | :cache_control,
            prompt_contract_version: nil | String.t(),
            tool_dialect: :responses | :anthropic,
            hosted_tools: boolean()
          }
        }

  @anthropic_models [
    %{"id" => "claude-fable-5", "name" => "claude-fable-5", "default" => false},
    %{"id" => "claude-opus-4-8", "name" => "claude-opus-4-8", "default" => false},
    %{"id" => "claude-sonnet-5", "name" => "claude-sonnet-5", "default" => false},
    %{
      "id" => "claude-haiku-4-5-20251001",
      "name" => "claude-haiku-4-5-20251001",
      "default" => false
    }
  ]

  @doc "Resolve a model id to the provider entry that owns its dialect."
  @spec resolve(String.t() | nil) :: entry()
  def resolve("claude-" <> _), do: anthropic_entry()
  def resolve(_model), do: openai_entry()

  @doc "Resolve a provider module to its registry entry. Unknown modules use OpenAI defaults."
  @spec entry_for(module()) :: entry()
  def entry_for(Pixir.Provider), do: openai_entry()
  def entry_for(Anthropic), do: anthropic_entry()
  def entry_for(_provider), do: openai_entry()

  @doc "Resolve one immutable Provider request selection from one Config snapshot."
  @spec resolve_request(map(), keyword()) ::
          {:ok, ResolvedProviderRequest.t()} | {:error, map()}
  def resolve_request(selection, config_opts \\ [])

  def resolve_request(selection, config_opts) when is_map(selection) do
    with {:ok, provider_intent} <- selection_field(selection, :provider_intent),
         {:ok, request} <- selection_map(selection, :request),
         {:ok, provider_opts} <- selection_keyword(selection, :provider_opts),
         {:ok, snapshot} <- Config.request_snapshot(config_opts),
         {:ok, backend_selection} <- effective_backend(provider_opts, snapshot.responses_backend),
         {:ok, model, model_source} <- effective_model(request, provider_opts, snapshot),
         {:ok, provider, intent_source} <-
           effective_provider(provider_intent, model, backend_selection),
         {:ok, dialect} <- provider_dialect(provider),
         {:ok, backend} <-
           applicable_backend(
             provider,
             dialect,
             model,
             model_source,
             provider_intent,
             backend_selection
           ) do
      {:ok,
       ResolvedProviderRequest.new(%{
         provider: provider,
         model: model,
         dialect: dialect,
         capabilities: capabilities(provider, dialect),
         responses_backend: backend,
         provider_defaults: snapshot.provider_defaults,
         source_evidence: %{
           provider: intent_source,
           model: model_source,
           responses_backend: backend_source(backend_selection)
         }
       })}
    end
  end

  def resolve_request(_selection, _config_opts),
    do: invalid(:resolved_provider_request, :invalid_resolved_request)

  @doc "Merged provider model catalog advertised by ACP."
  @spec models(keyword()) :: [map()]
  def models(opts \\ []), do: openai_entry(opts).models ++ anthropic_entry(opts).models

  # Raw built-in Anthropic slugs, without the default insertion the entry's
  # catalog shaping applies. The refresh diff base needs the unshaped source.
  @doc false
  @spec anthropic_built_in_models() :: [String.t()]
  def anthropic_built_in_models, do: Enum.map(@anthropic_models, & &1["id"])

  @doc "Whether `model_id` is in the merged provider catalog."
  @spec model_supported?(String.t()) :: boolean()
  def model_supported?(model_id) when is_binary(model_id) do
    Enum.any?(models(), &(&1["id"] == model_id))
  end

  def model_supported?(_model_id), do: false

  defp openai_entry, do: openai_entry([])

  defp openai_entry(opts) do
    %{
      provider: Pixir.Provider,
      default_model: Pixir.Provider.default_model(),
      models: Pixir.Provider.models(opts),
      auth: %{
        env_var: "OPENAI_API_KEY",
        scheme: :oauth_or_api_key,
        login_supported: true
      },
      capabilities: %{
        reasoning_dialect: nil,
        prompt_cache: :prompt_cache_key,
        prompt_contract_version: nil,
        tool_dialect: :responses,
        hosted_tools: true
      }
    }
  end

  defp anthropic_entry, do: anthropic_entry([])

  defp anthropic_entry(opts) do
    default = "claude-fable-5"

    models =
      opts
      |> Config.file_anthropic_models()
      |> Kernel.||(Enum.map(@anthropic_models, & &1["id"]))
      |> List.insert_at(0, default)
      |> Enum.uniq()
      # Never flagged as the picker default: the merged ACP catalog advertises
      # exactly one default, the OpenAI entry's session default model.
      |> Enum.map(fn slug -> %{"id" => slug, "name" => slug, "default" => false} end)

    %{
      provider: Anthropic,
      default_model: default,
      models: models,
      auth: %{
        env_var: "ANTHROPIC_API_KEY",
        scheme: :api_key_header,
        login_supported: false
      },
      capabilities: %{
        reasoning_dialect: "anthropic",
        prompt_cache: :cache_control,
        prompt_contract_version: Anthropic.Prompt.prompt_contract_version(),
        tool_dialect: :anthropic,
        hosted_tools: false
      }
    }
  end

  defp selection_field(selection, key) do
    case fetch_selection(selection, key) do
      {:ok, :auto} ->
        {:ok, :auto}

      {:ok, {intent, provider}} when intent in [:explicit, :direct] ->
        if provider_callable?(provider),
          do: {:ok, {intent, provider}},
          else: invalid(:provider, :invalid_resolved_request)

      _ ->
        invalid(:provider, :invalid_resolved_request)
    end
  end

  defp provider_callable?(provider)
       when is_atom(provider) and provider not in [nil, true, false] do
    Code.ensure_loaded?(provider) and function_exported?(provider, :stream, 2)
  rescue
    _error -> false
  catch
    _kind, _reason -> false
  end

  defp provider_callable?(_provider), do: false

  defp selection_map(selection, key) do
    case fetch_selection(selection, key) do
      {:ok, value} when is_map(value) and not is_struct(value) -> {:ok, value}
      _ -> invalid(:resolved_provider_request, :invalid_resolved_request)
    end
  end

  defp selection_keyword(selection, key) do
    case fetch_selection(selection, key) do
      {:ok, value} when is_list(value) ->
        if Keyword.keyword?(value),
          do: {:ok, value},
          else: invalid(:resolved_provider_request, :invalid_resolved_request)

      _ ->
        invalid(:resolved_provider_request, :invalid_resolved_request)
    end
  end

  defp fetch_selection(selection, key) do
    string_key = Atom.to_string(key)

    case {Map.fetch(selection, key), Map.fetch(selection, string_key)} do
      {{:ok, _atom_value}, {:ok, _string_value}} -> :error
      {{:ok, value}, :error} -> {:ok, value}
      {:error, {:ok, value}} -> {:ok, value}
      {:error, :error} -> :error
    end
  end

  defp effective_backend(provider_opts, config_backend) do
    case Keyword.fetch(provider_opts, :responses_backend) do
      {:ok, value} ->
        case ResponsesBackend.resolve(value, source: :provider_opts) do
          {:ok, backend} -> {:ok, {:explicit, backend}}
          {:error, _} = error -> error
        end

      :error ->
        case config_backend do
          :absent -> {:ok, :absent}
          %ResponsesBackend{} = backend -> {:ok, {:explicit, backend}}
          _ -> invalid(:responses_backend, :invalid_type)
        end
    end
  end

  defp effective_model(request, provider_opts, snapshot) do
    request_model = explicit_model(request)
    opts_model = explicit_keyword_model(provider_opts)

    case {request_model, opts_model} do
      {{:invalid, _}, _} -> invalid(:model, :invalid_type)
      {_, {:invalid, _}} -> invalid(:model, :invalid_type)
      {{:ok, model}, _} -> {:ok, model, :request}
      {:absent, {:ok, model}} -> {:ok, model, :provider_opts}
      {:absent, :absent} -> {:ok, snapshot.model, snapshot.model_source}
    end
  end

  defp explicit_model(request) do
    case {Map.fetch(request, :model), Map.fetch(request, "model")} do
      {{:ok, _atom_model}, {:ok, _string_model}} -> {:invalid, :normalized_key_collision}
      {{:ok, model}, :error} -> normalize_explicit_model(model)
      {:error, {:ok, model}} -> normalize_explicit_model(model)
      {:error, :error} -> :absent
    end
  end

  defp explicit_keyword_model(opts) do
    case Keyword.fetch(opts, :model) do
      {:ok, model} -> normalize_explicit_model(model)
      :error -> :absent
    end
  end

  defp normalize_explicit_model(nil), do: :absent

  defp normalize_explicit_model(model) when is_binary(model) do
    if String.valid?(model) do
      case String.trim(model) do
        "" -> {:invalid, model}
        trimmed -> {:ok, trimmed}
      end
    else
      {:invalid, model}
    end
  end

  defp normalize_explicit_model(model), do: {:invalid, model}

  defp effective_provider(:auto, "claude-" <> _rest, :absent),
    do: {:ok, Anthropic, :model}

  defp effective_provider(:auto, "claude-" <> _rest, {:explicit, _backend}),
    do: invalid(:provider, :provider_conflict)

  defp effective_provider(:auto, _model, _backend), do: {:ok, Pixir.Provider, :model}
  defp effective_provider({:explicit, provider}, _model, _backend), do: {:ok, provider, :explicit}
  defp effective_provider({:direct, provider}, _model, _backend), do: {:ok, provider, :direct}

  defp provider_dialect(Pixir.Provider), do: {:ok, :responses}
  defp provider_dialect(Anthropic), do: {:ok, :anthropic}
  defp provider_dialect(provider) when is_atom(provider), do: {:ok, :custom}

  defp applicable_backend(
         Pixir.Provider,
         :responses,
         "claude-" <> _rest,
         model_source,
         _intent,
         {:explicit, _backend}
       )
       when model_source not in [:request, :provider_opts],
       do: invalid(:model, :model_conflict)

  defp applicable_backend(Pixir.Provider, :responses, _model, _model_source, _intent, :absent),
    do: {:ok, ResponsesBackend.default()}

  defp applicable_backend(
         Pixir.Provider,
         :responses,
         _model,
         _model_source,
         _intent,
         {:explicit, backend}
       ),
       do: {:ok, backend}

  defp applicable_backend(Anthropic, :anthropic, _model, _model_source, _intent, :absent),
    do: {:ok, :not_applicable}

  defp applicable_backend(
         Anthropic,
         :anthropic,
         _model,
         _model_source,
         _intent,
         {:explicit, _backend}
       ),
       do: invalid(:provider, :incompatible_provider)

  defp applicable_backend(_provider, :custom, _model, _model_source, _intent, :absent),
    do: {:ok, :not_applicable}

  defp applicable_backend(
         _provider,
         :custom,
         "claude-" <> _rest,
         model_source,
         _intent,
         {:explicit, _backend}
       )
       when model_source not in [:request, :provider_opts],
       do: invalid(:model, :model_conflict)

  defp applicable_backend(
         provider,
         :custom,
         _model,
         _model_source,
         _intent,
         {:explicit, backend}
       ) do
    cond do
      ResponsesBackend.mode(backend) == :chatgpt_codex ->
        invalid(:provider, :incompatible_provider)

      responses_compatible?(provider) ->
        {:ok, backend}

      true ->
        invalid(:provider, :incompatible_provider)
    end
  end

  defp responses_compatible?(provider) do
    Code.ensure_loaded?(provider) and
      function_exported?(provider, :responses_backend_compatible?, 0) and
      provider.responses_backend_compatible?() == true
  rescue
    _error -> false
  catch
    _kind, _reason -> false
  end

  defp capabilities(Pixir.Provider, :responses), do: responses_capabilities()
  defp capabilities(Anthropic, :anthropic), do: anthropic_capabilities()

  defp capabilities(_provider, :custom), do: responses_capabilities()

  defp responses_capabilities do
    %{
      reasoning_dialect: nil,
      prompt_cache: :prompt_cache_key,
      prompt_contract_version: nil,
      tool_dialect: :responses,
      hosted_tools: true
    }
  end

  defp anthropic_capabilities do
    %{
      reasoning_dialect: "anthropic",
      prompt_cache: :cache_control,
      prompt_contract_version: Anthropic.Prompt.prompt_contract_version(),
      tool_dialect: :anthropic,
      hosted_tools: false
    }
  end

  defp backend_source(:absent), do: :absent
  defp backend_source({:explicit, backend}), do: ResponsesBackend.source(backend)

  defp invalid(field, reason) do
    {:error,
     Pixir.Tool.error(:invalid_config, "The Provider request selection is invalid.", %{
       field: field,
       reason: reason
     })}
  end
end
