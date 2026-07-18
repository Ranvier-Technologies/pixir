defmodule Pixir.Provider.ResponsesRouting do
  @moduledoc """
  Opaque, request-scoped routing policy for the Responses Provider.

  Routing is resolved once from an already selected `ResponsesBackend` plus the
  Provider's programmatic options. The value keeps the exact validated HTTP endpoint
  private while exposing only redacted summaries and transport capabilities. It never
  selects credentials and never activates a staged backend.

  A legacy injected `:transport` is treated as an HTTP/SSE seam. The resolved policy
  records both the requested and effective transports so Provider integration can pass
  one frozen decision to `TransportPolicy` without rereading application config.
  """

  alias Pixir.Providers.ResponsesBackend
  alias Pixir.Tool

  @default_http_url "https://chatgpt.com/backend-api/codex/responses"
  @default_websocket_url "wss://chatgpt.com/backend-api/codex/responses"
  @transport_ids [:auto, :websocket, :http_sse]

  @typedoc "Opaque Responses route and transport decision."
  @opaque t :: %__MODULE__{
            url: String.t(),
            websocket_url: String.t() | nil,
            requested_transport: :auto | :websocket | :http_sse,
            effective_transport: :auto | :websocket | :http_sse,
            allowed_transports: [:websocket | :http_sse],
            source: :default | :legacy_base_url | :base_url | :responses_url,
            backend_binding: binary(),
            route_integrity: binary()
          }

  @enforce_keys [
    :url,
    :websocket_url,
    :requested_transport,
    :effective_transport,
    :allowed_transports,
    :source,
    :backend_binding,
    :route_integrity
  ]
  defstruct @enforce_keys

  @doc "Resolve one final Responses route and effective transport policy."
  @spec resolve(ResponsesBackend.t(), keyword()) :: {:ok, t()} | {:error, map()}
  def resolve(backend, provider_opts \\ [])

  def resolve(%ResponsesBackend{} = backend, provider_opts) when is_list(provider_opts) do
    with true <- Keyword.keyword?(provider_opts),
         true <- ResponsesBackend.valid?(backend),
         :ok <- reject_explicit_legacy_conflict(backend, provider_opts),
         {:ok, url, websocket_url, source} <- resolve_urls(backend, provider_opts),
         {:ok, requested} <- requested_transport(backend, provider_opts),
         {:ok, effective} <- effective_transport(backend, requested, provider_opts) do
      backend_binding = backend_binding(backend)
      allowed_transports = ResponsesBackend.transports(backend)

      attrs = %{
        url: url,
        websocket_url: websocket_url,
        requested_transport: requested,
        effective_transport: effective,
        allowed_transports: allowed_transports,
        source: source,
        backend_binding: backend_binding
      }

      {:ok, struct!(__MODULE__, Map.put(attrs, :route_integrity, route_integrity(attrs)))}
    else
      false -> invalid_args(:invalid_routing_input)
      {:error, _error} = error -> error
    end
  rescue
    _error -> invalid_args(:invalid_routing_input)
  catch
    _kind, _reason -> invalid_args(:invalid_routing_input)
  end

  def resolve(_backend, _provider_opts), do: invalid_args(:invalid_routing_input)

  @doc "Validated final HTTP(S) Responses URL. Keep this request-internal."
  @spec http_url(t()) :: String.t()
  def http_url(%__MODULE__{url: value}), do: value

  @doc "Resolved ChatGPT WebSocket URL, or `nil` for an HTTP/SSE-only backend."
  @spec websocket_url(t()) :: String.t() | nil
  def websocket_url(%__MODULE__{websocket_url: value}), do: value

  @doc "Transport requested before capability and injected-seam resolution."
  @spec requested_transport(t()) :: :auto | :websocket | :http_sse
  def requested_transport(%__MODULE__{requested_transport: value}), do: value

  @doc "Transport policy to execute for this frozen route."
  @spec effective_transport(t()) :: :auto | :websocket | :http_sse
  def effective_transport(%__MODULE__{effective_transport: value}), do: value

  @doc "Ordered transport capability set advertised by the selected backend."
  @spec allowed_transports(t()) :: [:websocket | :http_sse]
  def allowed_transports(%__MODULE__{allowed_transports: value}), do: value

  @doc "Safe provenance of the final route."
  @spec source(t()) :: :default | :legacy_base_url | :base_url | :responses_url
  def source(%__MODULE__{source: value}), do: value

  @doc "Attach the opaque route and its effective transport to Provider options."
  @spec apply_to_opts(t(), keyword()) :: keyword()
  def apply_to_opts(%__MODULE__{} = routing, opts) when is_list(opts) do
    opts
    |> Keyword.put(:provider_transport, routing.effective_transport)
    |> Keyword.put(:responses_routing, routing)
  end

  @doc "Redacted, JSON-friendly routing projection."
  @spec summary(term()) :: map() | :invalid
  def summary(%__MODULE__{} = routing) do
    if valid?(routing) do
      %{
        "requested_transport" => Atom.to_string(routing.requested_transport),
        "effective_transport" => Atom.to_string(routing.effective_transport),
        "allowed_transports" => Enum.map(routing.allowed_transports, &Atom.to_string/1),
        "source" => Atom.to_string(routing.source),
        "websocket_available" => is_binary(routing.websocket_url)
      }
    else
      :invalid
    end
  rescue
    _error -> :invalid
  catch
    _kind, _reason -> :invalid
  end

  def summary(_routing), do: :invalid

  @doc "Verify that an opaque route remains bound to the selected backend."
  @spec validate_binding(t(), ResponsesBackend.t()) :: :ok | {:error, map()}
  def validate_binding(%__MODULE__{} = routing, %ResponsesBackend{} = backend) do
    if valid?(routing) and ResponsesBackend.valid?(backend) and
         secure_compare(routing.backend_binding, backend_binding(backend)) do
      :ok
    else
      binding_error()
    end
  rescue
    _error -> binding_error()
  catch
    _kind, _reason -> binding_error()
  end

  def validate_binding(_routing, _backend), do: binding_error()

  @doc false
  def valid?(%__MODULE__{} = routing) do
    routing.source in [:default, :legacy_base_url, :base_url, :responses_url] and
      routing.requested_transport in @transport_ids and
      routing.effective_transport in @transport_ids and
      valid_allowed_transports?(routing.allowed_transports) and
      routing.effective_transport in effective_capabilities(routing.allowed_transports) and
      valid_final_url?(routing.url) and valid_websocket_url?(routing) and
      valid_digest?(routing.backend_binding) and valid_digest?(routing.route_integrity) and
      secure_compare(routing.route_integrity, route_integrity(Map.from_struct(routing)))
  end

  def valid?(_routing), do: false

  defp reject_explicit_legacy_conflict(backend, provider_opts) do
    if ResponsesBackend.explicit?(backend) and Keyword.has_key?(provider_opts, :base_url) do
      invalid_config(:base_url, :conflicting_legacy_option)
    else
      :ok
    end
  end

  defp resolve_urls(backend, provider_opts) do
    case {ResponsesBackend.mode(backend), ResponsesBackend.endpoint(backend)} do
      {:chatgpt_codex, :default} ->
        resolve_chatgpt_urls(backend, provider_opts)

      {:open_responses, {:base_url, base_url}} ->
        final = String.trim_trailing(base_url, "/") <> "/v1/responses"
        if valid_final_url?(final), do: {:ok, final, nil, :base_url}, else: endpoint_error()

      {:open_responses, {:responses_url, responses_url}} ->
        if valid_final_url?(responses_url),
          do: {:ok, responses_url, nil, :responses_url},
          else: endpoint_error()

      _other ->
        invalid_args(:invalid_routing_input)
    end
  end

  defp resolve_chatgpt_urls(backend, provider_opts) do
    case {ResponsesBackend.explicit?(backend), Keyword.fetch(provider_opts, :base_url)} do
      {false, {:ok, base_url}} when is_binary(base_url) ->
        final = legacy_responses_url(base_url)

        if valid_final_url?(final) do
          {:ok, final, to_websocket_url(final), :legacy_base_url}
        else
          endpoint_error()
        end

      {false, {:ok, _invalid}} ->
        endpoint_error()

      {_explicit, :error} ->
        {:ok, @default_http_url, @default_websocket_url, :default}

      {true, {:ok, _value}} ->
        invalid_config(:base_url, :conflicting_legacy_option)
    end
  end

  defp legacy_responses_url(base_url) do
    normalized = String.trim_trailing(base_url, "/")

    cond do
      String.ends_with?(normalized, "/codex/responses") -> normalized
      String.ends_with?(normalized, "/codex") -> normalized <> "/responses"
      true -> normalized <> "/codex/responses"
    end
  end

  defp requested_transport(backend, provider_opts) do
    raw =
      Keyword.get_lazy(provider_opts, :provider_transport, fn ->
        Application.get_env(:pixir, :provider_transport, :auto)
      end)

    case normalize_transport(raw) do
      {:ok, requested} ->
        {:ok, requested}

      :error ->
        if ResponsesBackend.explicit?(backend),
          do: invalid_config(:provider_transport, :invalid_transport),
          else: {:ok, :auto}
    end
  end

  defp normalize_transport(value) when value in @transport_ids, do: {:ok, value}
  defp normalize_transport("auto"), do: {:ok, :auto}
  defp normalize_transport("websocket"), do: {:ok, :websocket}
  defp normalize_transport("http_sse"), do: {:ok, :http_sse}
  defp normalize_transport(_value), do: :error

  defp effective_transport(backend, requested, provider_opts) do
    allowed = ResponsesBackend.transports(backend)

    with :ok <- ensure_capability(requested, allowed),
         :ok <- ensure_injected_transport_compatibility(requested, provider_opts) do
      cond do
        Keyword.has_key?(provider_opts, :transport) ->
          {:ok, :http_sse}

        ResponsesBackend.mode(backend) == :open_responses and requested == :auto ->
          {:ok, :http_sse}

        true ->
          {:ok, requested}
      end
    end
  end

  defp ensure_capability(:auto, _allowed), do: :ok

  defp ensure_capability(requested, allowed) do
    if requested in allowed do
      :ok
    else
      {:error,
       Tool.error(
         :unsupported_transport,
         "The selected backend does not support the transport.",
         %{
           requested_transport: requested,
           allowed_transports: allowed,
           reason: :unsupported_transport
         }
       )}
    end
  end

  defp ensure_injected_transport_compatibility(requested, provider_opts) do
    case Keyword.fetch(provider_opts, :transport) do
      :error ->
        :ok

      {:ok, _transport} when requested == :websocket ->
        {:error,
         Tool.error(:invalid_args, "The injected transport is an HTTP/SSE-only seam.", %{
           field: :transport,
           reason: :incompatible_transport_seam
         })}

      {:ok, transport} ->
        if valid_transport_seam?(transport) do
          :ok
        else
          {:error,
           Tool.error(:invalid_args, "The injected HTTP/SSE transport seam is invalid.", %{
             field: :transport,
             reason: :invalid_transport_seam
           })}
        end
    end
  end

  defp valid_transport_seam?(transport) when is_function(transport, 3), do: true

  defp valid_transport_seam?(transport)
       when is_atom(transport) and transport not in [nil, true, false] do
    Code.ensure_loaded?(transport) and function_exported?(transport, :stream, 3)
  rescue
    _error -> false
  catch
    _kind, _reason -> false
  end

  defp valid_transport_seam?(_transport), do: false

  defp valid_allowed_transports?([:websocket, :http_sse]), do: true
  defp valid_allowed_transports?([:http_sse]), do: true
  defp valid_allowed_transports?(_allowed), do: false

  defp effective_capabilities([:websocket, :http_sse]), do: @transport_ids
  defp effective_capabilities([:http_sse]), do: [:http_sse]
  defp effective_capabilities(_allowed), do: []

  defp valid_websocket_url?(%__MODULE__{
         allowed_transports: [:websocket, :http_sse],
         websocket_url: url
       }),
       do: valid_final_websocket_url?(url)

  defp valid_websocket_url?(%__MODULE__{allowed_transports: [:http_sse], websocket_url: nil}),
    do: true

  defp valid_websocket_url?(_routing), do: false

  defp valid_final_url?(value) when is_binary(value) do
    profile = %{
      "mode" => "open_responses",
      "responses_url" => value,
      "auth" => %{"policy" => "none"}
    }

    match?({:ok, %ResponsesBackend{}}, ResponsesBackend.resolve(profile))
  rescue
    _error -> false
  end

  defp valid_final_url?(_value), do: false

  defp valid_final_websocket_url?(value) when is_binary(value) do
    case URI.parse(value) do
      %URI{scheme: "ws"} = uri ->
        valid_final_url?(URI.to_string(%{uri | scheme: "http"}))

      %URI{scheme: "wss"} = uri ->
        valid_final_url?(URI.to_string(%{uri | scheme: "https"}))

      _other ->
        false
    end
  rescue
    _error -> false
  end

  defp valid_final_websocket_url?(_value), do: false

  defp to_websocket_url(http_url) do
    uri = URI.parse(http_url)
    scheme = if uri.scheme == "http", do: "ws", else: "wss"
    URI.to_string(%{uri | scheme: scheme})
  end

  defp backend_binding(backend) do
    :crypto.hash(:sha256, :erlang.term_to_binary(backend, [:deterministic]))
  end

  defp route_integrity(attrs) do
    stable =
      Map.take(attrs, [
        :url,
        :websocket_url,
        :requested_transport,
        :effective_transport,
        :allowed_transports,
        :source,
        :backend_binding
      ])

    :crypto.hash(:sha256, :erlang.term_to_binary(stable, [:deterministic]))
  end

  defp valid_digest?(value), do: is_binary(value) and byte_size(value) == 32

  defp secure_compare(left, right)
       when is_binary(left) and is_binary(right) and byte_size(left) == byte_size(right) do
    left
    |> :crypto.exor(right)
    |> :binary.bin_to_list()
    |> Enum.reduce(0, &Bitwise.bor/2)
    |> Kernel.==(0)
  end

  defp secure_compare(_left, _right), do: false

  defp invalid_args(reason) do
    {:error,
     Tool.error(
       :invalid_args,
       "Responses routing requires a valid backend and keyword options.",
       %{
         reason: reason
       }
     )}
  end

  defp invalid_config(field, reason) do
    {:error,
     Tool.error(:invalid_config, "The Responses routing configuration is invalid.", %{
       field: field,
       reason: reason
     })}
  end

  defp endpoint_error, do: invalid_config(:endpoint, :invalid_endpoint)

  defp binding_error do
    {:error,
     Tool.error(:invalid_config, "The Responses route does not match the selected backend.", %{
       field: :responses_routing,
       reason: :backend_mismatch
     })}
  end
end

defimpl Inspect, for: Pixir.Provider.ResponsesRouting do
  import Inspect.Algebra

  def inspect(routing, opts) do
    concat([
      "#ResponsesRouting<",
      to_doc(Pixir.Provider.ResponsesRouting.summary(routing), opts),
      ">"
    ])
  end
end
