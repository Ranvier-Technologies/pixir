defmodule Pixir.ReasoningEffort do
  @moduledoc """
  Shared reasoning-effort vocabulary and conservative capability policy.

  The established low/medium/high/xhigh behavior is unchanged. `max` is an
  explicit intent, never an omission: only exact `gpt-6-astra` through Pixir's
  ChatGPT/Codex Responses backend supports it. Strict `open_responses` retains
  its existing no-reasoning boundary, even at an official OpenAI endpoint.
  Unknown models, custom providers, and legacy nonstandard routes gain no max
  capability by inference. This describes local admission, not live acceptance.
  """

  alias Pixir.Providers.{ResolvedProviderRequest, ResponsesBackend}

  @config_ingress_keys [:config_path, :raw_config, :request_snapshot_loader]
  @legacy ~w(low medium high xhigh)
  @known @legacy ++ ["max"]
  @legacy_openai_routes [
    "https://chatgpt.com/backend-api",
    "https://chatgpt.com/backend-api/codex",
    "https://chatgpt.com/backend-api/codex/responses"
  ]

  @doc "The established model-independent vocabulary (legacy Config API backing)."
  def legacy_ids, do: {:ok, @legacy}

  @doc "Known intent ids; capability must still be checked against the effective selection."
  def known_ids, do: {:ok, @known}

  @doc "Parse a known effort; nil/default explicitly mean omission."
  def normalize(nil), do: {:ok, nil}
  def normalize(value) when is_atom(value), do: normalize(Atom.to_string(value))

  def normalize(value) when is_binary(value) do
    value = if String.valid?(value), do: String.trim(value), else: :invalid

    cond do
      value == "default" -> {:ok, nil}
      value in @known -> {:ok, value}
      true -> invalid(:invalid_reasoning_effort)
    end
  end

  def normalize(_value), do: invalid(:invalid_reasoning_effort)

  @doc "Whether a value is a known explicit effort, independently of capability."
  def known?(value), do: value in @known

  @doc "Effort choices for one frozen effective Provider selection."
  def choices(%ResolvedProviderRequest{} = resolved, opts \\ []) do
    choices_for(
      ResolvedProviderRequest.model(resolved),
      ResolvedProviderRequest.provider(resolved),
      ResolvedProviderRequest.responses_backend(resolved),
      opts
    )
  end

  @doc "Effort choices without performing Config or Registry reads."
  def choices_for(model, provider, backend, opts \\ []) do
    if max_supported?(model, provider, backend, opts),
      do: {:ok, @known},
      else: {:ok, @legacy}
  end

  @doc "Validate max against the effective selection, retaining legacy non-max behavior."
  def validate(value, %ResolvedProviderRequest{} = resolved, opts \\ []) do
    with {:ok, effort} <- normalize(value),
         {:ok, choices} <- choices(resolved, opts) do
      if is_nil(effort) or effort in choices,
        do: {:ok, effort},
        else: invalid(:unsupported_reasoning_effort)
    end
  end

  @doc "Validate child runtime intent after spec/opts precedence, using the same selection as Turn."
  def validate_runtime(provider, provider_opts) do
    config_opts = Keyword.take(provider_opts, @config_ingress_keys)
    request_opts = Keyword.drop(provider_opts, @config_ingress_keys)

    selection = %{
      provider_intent: {:explicit, provider},
      request: %{},
      provider_opts: request_opts
    }

    with {:ok, resolved} <- Pixir.Providers.Registry.resolve_request(selection, config_opts),
         effective_opts <-
           ResolvedProviderRequest.attach_to_provider_opts(resolved, request_opts) do
      validate(Keyword.get(effective_opts, :reasoning_effort), resolved, effective_opts)
    end
  end

  @doc "True only for the explicitly supported Astra Responses path."
  def max_supported?(model, provider, backend, opts \\ [])

  def max_supported?("gpt-6-astra", Pixir.Provider, %ResponsesBackend{} = backend, opts) do
    ResponsesBackend.valid?(backend) and ResponsesBackend.mode(backend) == :chatgpt_codex and
      supported_route?(Keyword.get(opts, :base_url))
  end

  def max_supported?(_model, _provider, _backend, _opts), do: false

  defp supported_route?(nil), do: true

  defp supported_route?(url) when is_binary(url),
    do: String.trim_trailing(url, "/") in @legacy_openai_routes

  defp supported_route?(_url), do: false

  defp invalid(reason) do
    {:error,
     Pixir.Tool.error(
       :invalid_config,
       "Reasoning effort is invalid for the selected model/backend.",
       %{
         field: :reasoning_effort,
         reason: reason,
         next_actions: ["choose_a_supported_effort_or_compatible_model_and_backend"]
       }
     )}
  end
end
