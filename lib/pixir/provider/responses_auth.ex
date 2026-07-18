defmodule Pixir.Provider.ResponsesAuth do
  @moduledoc """
  Resolves ephemeral request authentication for one Responses Provider attempt.

  The opaque value owns only the already-resolved headers for that attempt. It is
  deliberately unsuitable for persistence or diagnostics: `Inspect` and `summary/1`
  expose the policy and ordered header names, never credential values. Backend/route
  binding is delegated to `Pixir.Provider.ResponsesRouting` before any credential
  source is read.

  A caller should resolve a fresh value for each outer Provider attempt and reuse that
  value for any transport fallback within the attempt. This keeps token rotation
  request-scoped without allowing routing or backend policy to drift.
  """

  alias Pixir.Providers.{ResolvedProviderRequest, ResponsesBackend}
  alias Pixir.Tool

  @routing_module Pixir.Provider.ResponsesRouting
  @max_bearer_bytes 8_192
  @max_header_value_bytes 16_384
  @allowed_header_names ["authorization", "chatgpt-account-id"]

  @typedoc "Opaque, ephemeral authentication resolved for one Provider attempt."
  @opaque t :: %__MODULE__{
            policy: :chatgpt_oauth_or_api_key | :none | {:bearer_env, String.t()},
            headers: [{String.t(), String.t()}]
          }

  @enforce_keys [:policy, :headers]
  defstruct @enforce_keys

  @doc "Resolve request-scoped auth after validating the frozen route/backend binding."
  @spec resolve(ResolvedProviderRequest.t(), term(), keyword()) ::
          {:ok, t()} | {:error, map()}
  def resolve(resolved_provider_request, responses_routing, provider_opts \\ [])

  def resolve(%ResolvedProviderRequest{} = resolved, routing, provider_opts)
      when is_list(provider_opts) do
    backend = ResolvedProviderRequest.responses_backend(resolved)

    with :ok <- validate_binding(routing, backend) do
      resolve_policy(ResponsesBackend.auth_policy(backend), routing, provider_opts)
    end
  rescue
    _error -> invalid_config(:invalid_auth_context)
  catch
    _kind, _reason -> invalid_config(:invalid_auth_context)
  end

  def resolve(_resolved_provider_request, _responses_routing, _provider_opts),
    do: invalid_config(:invalid_auth_context)

  @doc "Return the resolved lowercase request headers."
  @spec headers(t()) :: [{String.t(), String.t()}]
  def headers(%__MODULE__{headers: headers}), do: headers

  @doc "Return a total, redacted diagnostic projection."
  @spec summary(term()) :: map() | :invalid
  def summary(%__MODULE__{policy: policy, headers: headers}) do
    with {:ok, policy_summary} <- policy_summary(policy),
         :ok <- validate_headers(headers) do
      %{
        "policy" => policy_summary,
        "header_names" => Enum.map(headers, &elem(&1, 0))
      }
    else
      _ -> :invalid
    end
  rescue
    _error -> :invalid
  catch
    _kind, _reason -> :invalid
  end

  def summary(_auth), do: :invalid

  defp resolve_policy(:none, _routing, _provider_opts),
    do: {:ok, %__MODULE__{policy: :none, headers: []}}

  defp resolve_policy({:bearer_env, env_var} = policy, routing, provider_opts) do
    with {:ok, origin} <- route_origin(routing),
         :ok <- authorize_plain_http(origin, :bearer_env),
         {:ok, token} <- read_bearer(env_var, provider_opts) do
      {:ok,
       %__MODULE__{
         policy: policy,
         headers: [{"authorization", "Bearer " <> token}]
       }}
    end
  end

  defp resolve_policy(:chatgpt_oauth_or_api_key = policy, routing, provider_opts) do
    with {:ok, origin} <- route_origin(routing),
         {:ok, source} <- route_source(routing),
         :ok <- require_explicit_legacy_auth(source, origin, provider_opts),
         {:ok, headers} <- request_chatgpt_headers(provider_opts),
         :ok <- validate_headers(headers),
         :ok <- authorize_legacy_headers(source, origin, headers) do
      {:ok, %__MODULE__{policy: policy, headers: headers}}
    end
  end

  defp resolve_policy(_policy, _routing, _provider_opts),
    do: invalid_config(:unsupported_auth_policy)

  # Keep the dependency remote so this module can compile while the independently
  # owned routing tranche is still being authored.
  defp validate_binding(routing, backend),
    do: apply(@routing_module, :validate_binding, [routing, backend])

  defp route_source(routing) do
    case apply(@routing_module, :source, [routing]) do
      source when source in [:default, :legacy_base_url, :base_url, :responses_url] ->
        {:ok, source}

      _other ->
        invalid_config(:invalid_route)
    end
  end

  defp route_origin(routing) do
    case apply(@routing_module, :http_url, [routing]) do
      url when is_binary(url) -> parse_origin(url)
      _other -> invalid_config(:invalid_route)
    end
  end

  defp parse_origin(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host, port: port}
      when scheme in ["http", "https"] and is_binary(host) and host != "" and
             is_integer(port) ->
        {:ok, %{scheme: scheme, host: host, port: port}}

      _other ->
        invalid_config(:invalid_route)
    end
  rescue
    _error -> invalid_config(:invalid_route)
  end

  defp request_chatgpt_headers(provider_opts) do
    auth = Keyword.get(provider_opts, :auth, Pixir.Auth)
    Pixir.Auth.request_headers(auth)
  end

  defp read_bearer(env_var, provider_opts) do
    env_reader = Keyword.get(provider_opts, :env_reader, &System.get_env/1)

    value =
      if is_function(env_reader, 1),
        do: env_reader.(env_var),
        else: nil

    if valid_bearer?(value) do
      {:ok, value}
    else
      not_authenticated(env_var, :invalid_or_missing_bearer)
    end
  rescue
    _error -> not_authenticated(env_var, :credential_read_failed)
  catch
    _kind, _reason -> not_authenticated(env_var, :credential_read_failed)
  end

  defp valid_bearer?(value) when is_binary(value) do
    byte_size(value) in 1..@max_bearer_bytes and String.valid?(value) and
      Regex.match?(~r/\A[A-Za-z0-9\-._~+\/]+={0,}\z/, value)
  end

  defp valid_bearer?(_value), do: false

  defp validate_headers(headers) when is_list(headers) and length(headers) <= 2 do
    with true <- Enum.all?(headers, &valid_header?/1),
         names <- Enum.map(headers, &elem(&1, 0)),
         true <- Enum.uniq(names) == names,
         true <- Enum.all?(names, &(&1 in @allowed_header_names)),
         true <- valid_header_relationship?(names) do
      :ok
    else
      _ -> invalid_headers()
    end
  end

  defp validate_headers(_headers), do: invalid_headers()

  defp valid_header?({name, value}) when is_binary(name) and is_binary(value) do
    name in @allowed_header_names and safe_header_value?(value)
  end

  defp valid_header?(_header), do: false

  defp safe_header_value?(value) do
    byte_size(value) in 1..@max_header_value_bytes and String.valid?(value) and
      not Regex.match?(~r/[\x00-\x1f\x7f]/u, value)
  end

  defp valid_header_relationship?(names),
    do: "chatgpt-account-id" not in names or "authorization" in names

  defp require_explicit_legacy_auth(:legacy_base_url, origin, provider_opts) do
    if canonical_chatgpt_origin?(origin) or Keyword.has_key?(provider_opts, :auth),
      do: :ok,
      else: invalid_config(:explicit_auth_required)
  end

  defp require_explicit_legacy_auth(_source, _origin, _provider_opts), do: :ok

  defp authorize_legacy_headers(:legacy_base_url, origin, headers) do
    names = Enum.map(headers, &elem(&1, 0))

    cond do
      canonical_chatgpt_origin?(origin) ->
        :ok

      "chatgpt-account-id" in names ->
        invalid_config(:account_id_for_noncanonical_origin)

      "authorization" in names ->
        authorize_plain_http(origin, :explicit_legacy_auth)

      true ->
        :ok
    end
  end

  defp authorize_legacy_headers(_source, _origin, _headers), do: :ok

  defp authorize_plain_http(%{scheme: "https"}, _policy), do: :ok

  defp authorize_plain_http(%{scheme: "http", host: host}, policy) do
    if literal_loopback?(host) do
      :ok
    else
      {:error,
       Tool.error(
         :insecure_auth_transport,
         "Authorization credentials require HTTPS or a literal loopback host.",
         %{
           policy: policy,
           scheme: "http",
           reason: :non_loopback_plain_http
         }
       )}
    end
  end

  defp canonical_chatgpt_origin?(%{scheme: "https", host: "chatgpt.com", port: 443}),
    do: true

  defp canonical_chatgpt_origin?(_origin), do: false

  defp literal_loopback?("localhost"), do: true
  defp literal_loopback?("::1"), do: true

  defp literal_loopback?(host) do
    case String.split(host, ".") do
      ["127", second, third, fourth] ->
        Enum.all?([second, third, fourth], &canonical_ipv4_octet?/1)

      _other ->
        false
    end
  end

  defp canonical_ipv4_octet?(octet) do
    with true <- Regex.match?(~r/\A(?:0|[1-9][0-9]{0,2})\z/, octet),
         {value, ""} <- Integer.parse(octet),
         true <- value in 0..255 do
      true
    else
      _ -> false
    end
  end

  defp policy_summary(:none), do: {:ok, "none"}
  defp policy_summary(:chatgpt_oauth_or_api_key), do: {:ok, "chatgpt_oauth_or_api_key"}

  defp policy_summary({:bearer_env, env_var}) when is_binary(env_var),
    do: {:ok, %{"kind" => "bearer_env", "env_var" => env_var}}

  defp policy_summary(_policy), do: :error

  defp invalid_headers, do: invalid_config(:invalid_auth_headers)

  defp invalid_config(reason) do
    {:error,
     Tool.error(
       :invalid_config,
       "Responses authentication policy is invalid.",
       %{field: :responses_auth, reason: reason}
     )}
  end

  defp not_authenticated(env_var, reason) do
    {:error,
     Tool.error(
       :not_authenticated,
       "The configured bearer credential is unavailable or invalid.",
       %{
         env_var: env_var,
         policy: :bearer_env,
         reason: reason,
         next_action: :set_valid_environment_variable
       }
     )}
  end
end

defimpl Inspect, for: Pixir.Provider.ResponsesAuth do
  import Inspect.Algebra

  def inspect(auth, opts) do
    concat([
      "#ResponsesAuth<",
      to_doc(Pixir.Provider.ResponsesAuth.summary(auth), opts),
      ">"
    ])
  end
end
