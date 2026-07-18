defmodule Pixir.Providers.ResolvedProviderRequest do
  @moduledoc """
  Immutable Provider, model, dialect, capability, and backend selection for one request.

  Construction belongs to `Pixir.Providers.Registry.resolve_request/2`. The struct is
  opaque so callers cannot fabricate partial selections; Providers consume it through
  accessors and `attach_to_provider_opts/2`.
  """

  alias Pixir.Providers.ResponsesBackend
  alias Pixir.Provider.HostedTools

  @config_ingress_keys [:config_path, :raw_config, :request_snapshot_loader]

  @opaque t :: %__MODULE__{
            provider: module(),
            model: String.t(),
            dialect: :responses | :anthropic | :custom,
            capabilities: map(),
            responses_backend: ResponsesBackend.t() | :not_applicable,
            provider_defaults: map(),
            source_evidence: map()
          }

  @enforce_keys [
    :provider,
    :model,
    :dialect,
    :capabilities,
    :responses_backend,
    :provider_defaults,
    :source_evidence
  ]
  defstruct @enforce_keys

  @doc false
  def new(attrs) when is_map(attrs), do: struct!(__MODULE__, attrs)

  def provider(%__MODULE__{provider: value}), do: value
  def model(%__MODULE__{model: value}), do: value
  def dialect(%__MODULE__{dialect: value}), do: value
  def capabilities(%__MODULE__{capabilities: value}), do: value
  def responses_backend(%__MODULE__{responses_backend: value}), do: value
  def source_evidence(%__MODULE__{source_evidence: value}), do: value

  @doc false
  def provider_defaults_valid?(%__MODULE__{
        provider_defaults:
          %{
            max_retries: max_retries,
            stream_idle_timeout_ms: idle_ms,
            reasoning_effort: reasoning_effort,
            text_verbosity: text_verbosity,
            web_search: web_search
          } = defaults
      }) do
    map_size(defaults) == 5 and is_integer(max_retries) and max_retries >= 0 and
      is_integer(idle_ms) and idle_ms >= 0 and
      reasoning_effort in [nil, "low", "medium", "high", "xhigh"] and
      text_verbosity in [nil, "low", "medium", "high"] and
      valid_web_search_default?(web_search)
  end

  def provider_defaults_valid?(_resolved), do: false

  @doc false
  def capabilities_valid?(%__MODULE__{dialect: dialect, capabilities: capabilities})
      when dialect in [:responses, :custom] do
    capabilities == %{
      reasoning_dialect: nil,
      prompt_cache: :prompt_cache_key,
      prompt_contract_version: nil,
      tool_dialect: :responses,
      hosted_tools: true
    }
  end

  def capabilities_valid?(%__MODULE__{dialect: :anthropic, capabilities: capabilities}) do
    capabilities == %{
      reasoning_dialect: "anthropic",
      prompt_cache: :cache_control,
      prompt_contract_version: "pa1",
      tool_dialect: :anthropic,
      hosted_tools: false
    }
  end

  def capabilities_valid?(_resolved), do: false

  @doc false
  def source_evidence_valid?(%__MODULE__{
        source_evidence:
          %{
            provider: provider,
            model: model,
            responses_backend: responses_backend
          } = evidence
      }) do
    map_size(evidence) == 3 and provider in [:model, :explicit, :direct] and
      model in [:request, :provider_opts, :application, :env, :file, :default] and
      responses_backend in [:absent, :default, :config, :provider_opts]
  end

  def source_evidence_valid?(_resolved), do: false

  @doc "Attach only the selection fields the chosen Provider is allowed to consume."
  @spec attach_to_provider_opts(t(), keyword()) :: keyword()
  def attach_to_provider_opts(%__MODULE__{provider: Pixir.Provider} = resolved, opts) do
    opts
    |> strip_config_ingress()
    |> attach_provider_defaults(resolved.provider_defaults)
    |> Keyword.put(:model, resolved.model)
    |> Keyword.put(:responses_backend, resolved.responses_backend)
    |> Keyword.put(:resolved_provider_request, resolved)
  end

  def attach_to_provider_opts(%__MODULE__{dialect: :anthropic} = resolved, opts),
    do:
      opts
      |> strip_config_ingress()
      |> attach_provider_defaults(resolved.provider_defaults)
      |> Keyword.put(:model, resolved.model)

  def attach_to_provider_opts(
        %__MODULE__{dialect: :custom, responses_backend: :not_applicable} = resolved,
        opts
      ),
      do:
        opts
        |> strip_config_ingress()
        |> attach_provider_defaults(resolved.provider_defaults)

  def attach_to_provider_opts(%__MODULE__{dialect: :custom} = resolved, opts) do
    opts
    |> strip_config_ingress()
    |> attach_provider_defaults(resolved.provider_defaults)
    |> Keyword.put(:model, resolved.model)
    |> Keyword.put(:responses_backend, resolved.responses_backend)
    |> Keyword.put(:resolved_provider_request, resolved)
  end

  @doc false
  def for_child_turn(provider_opts) when is_list(provider_opts) do
    provider_opts
    |> strip_config_ingress()
    |> Keyword.drop([:resolved_provider_request, :responses_backend])
  end

  @doc false
  def safe_summary(%__MODULE__{} = resolved) do
    %{
      provider: safe_provider(resolved.provider),
      model: safe_model(resolved.model),
      dialect: safe_dialect(resolved.dialect),
      capabilities: safe_capabilities(resolved),
      responses_backend: safe_backend_summary(resolved.responses_backend),
      source_evidence: safe_source_evidence(resolved)
    }
  end

  defp attach_provider_defaults(opts, defaults) do
    opts
    |> Keyword.put_new(:max_retries, defaults.max_retries)
    |> Keyword.put_new(:stream_idle_timeout_ms, defaults.stream_idle_timeout_ms)
    |> put_optional(:reasoning_effort, defaults.reasoning_effort)
    |> put_optional(:text_verbosity, defaults.text_verbosity)
    |> put_optional(:web_search, defaults.web_search)
  end

  defp put_optional(opts, _key, nil), do: opts
  defp put_optional(opts, key, value), do: Keyword.put_new(opts, key, value)

  defp strip_config_ingress(opts), do: Keyword.drop(opts, @config_ingress_keys)

  defp safe_source_evidence(resolved) do
    if source_evidence_valid?(resolved), do: resolved.source_evidence, else: :invalid
  end

  defp safe_capabilities(resolved) do
    if capabilities_valid?(resolved), do: resolved.capabilities, else: :invalid
  end

  defp safe_backend_summary(:not_applicable), do: :not_applicable

  defp safe_backend_summary(%ResponsesBackend{} = backend) do
    if ResponsesBackend.valid?(backend), do: ResponsesBackend.summary(backend), else: :invalid
  end

  defp safe_backend_summary(_backend), do: :invalid

  defp safe_provider(Pixir.Provider), do: Pixir.Provider
  defp safe_provider(Pixir.Providers.Anthropic), do: Pixir.Providers.Anthropic

  defp safe_provider(provider) when is_atom(provider) and provider not in [nil, true, false] do
    if function_exported?(provider, :stream, 2), do: provider, else: :invalid
  end

  defp safe_provider(_provider), do: :invalid

  defp safe_model(model) when is_binary(model) do
    if String.valid?(model) and String.trim(model) != "", do: model, else: :invalid
  end

  defp safe_model(_model), do: :invalid

  defp safe_dialect(dialect) when dialect in [:responses, :anthropic, :custom], do: dialect
  defp safe_dialect(_dialect), do: :invalid

  defp valid_web_search_default?(nil), do: true

  defp valid_web_search_default?(web_search) when is_map(web_search) do
    allowed = HostedTools.web_search_config_fields()

    Enum.all?(Map.keys(web_search), &(is_binary(&1) and &1 in allowed)) and
      Map.get(web_search, "enabled") != false and json_safe_config_term?(web_search) and
      json_encodable?(web_search) and match?({:ok, _tool}, HostedTools.web_search(web_search))
  end

  defp valid_web_search_default?(_web_search), do: false

  defp json_safe_config_term?(value)
       when is_nil(value) or is_boolean(value) or is_number(value),
       do: true

  defp json_safe_config_term?(value) when is_binary(value), do: String.valid?(value)

  defp json_safe_config_term?([]), do: true

  defp json_safe_config_term?([head | tail]),
    do: json_safe_config_term?(head) and json_safe_config_term?(tail)

  defp json_safe_config_term?(value) when is_struct(value), do: false

  defp json_safe_config_term?(value) when is_map(value) do
    Enum.all?(value, fn {key, nested} ->
      is_binary(key) and String.valid?(key) and json_safe_config_term?(nested)
    end)
  end

  defp json_safe_config_term?(_value), do: false

  defp json_encodable?(value) do
    match?({:ok, _json}, Jason.encode(value))
  rescue
    _error -> false
  catch
    _kind, _reason -> false
  end
end

defimpl Inspect, for: Pixir.Providers.ResolvedProviderRequest do
  import Inspect.Algebra

  def inspect(resolved, opts) do
    concat([
      "#ResolvedProviderRequest<",
      to_doc(Pixir.Providers.ResolvedProviderRequest.safe_summary(resolved), opts),
      ">"
    ])
  end
end
