defmodule Pixir.Providers.ResponsesBackend do
  @moduledoc """
  Opaque policy for the Responses dialect backend selected for one request.

  The value contains selection policy, not credentials. Diagnostic and `Inspect`
  projections deliberately expose only `summary/1`; endpoint values and future
  secret-bearing fields never leave the request-selection boundary.
  """

  alias Pixir.Tool

  @typedoc "Opaque Responses backend selection."
  @opaque t :: %__MODULE__{
            mode: :chatgpt_codex | :open_responses,
            source: :default | :config | :provider_opts,
            endpoint: :default | {:base_url | :responses_url, String.t()},
            auth_policy: :chatgpt_oauth_or_api_key | :none | {:bearer_env, String.t()},
            transports: [:websocket | :http_sse],
            request_extensions: MapSet.t(atom())
          }

  @enforce_keys [
    :mode,
    :source,
    :endpoint,
    :auth_policy,
    :transports,
    :request_extensions
  ]
  defstruct @enforce_keys

  @chatgpt_extensions MapSet.new([
                        :prompt_cache_key,
                        :reasoning_encrypted_content,
                        :hosted_tool_includes
                      ])
  @extension_ids MapSet.new([
                   :prompt_cache_key,
                   :prompt_cache_retention,
                   :reasoning_encrypted_content,
                   :hosted_tool_includes
                 ])

  @doc "Default ChatGPT/Codex backend policy used by the legacy Responses path."
  @spec default() :: t()
  def default do
    %__MODULE__{
      mode: :chatgpt_codex,
      source: :default,
      endpoint: :default,
      auth_policy: :chatgpt_oauth_or_api_key,
      transports: [:websocket, :http_sse],
      request_extensions: @chatgpt_extensions
    }
  end

  @doc "Validate and normalize an explicit backend descriptor."
  @spec resolve(term(), keyword()) :: {:ok, t()} | {:error, map()}
  def resolve(value, opts \\ [])

  def resolve(%__MODULE__{} = backend, _opts) do
    if valid?(backend),
      do: {:ok, backend},
      else: invalid(:responses_backend, :invalid_type)
  end

  def resolve(value, opts) do
    source = Keyword.get(opts, :source, :config)

    with true <- source in [:default, :config, :provider_opts],
         {:ok, profile} <- normalize_object(value, :responses_backend),
         {:ok, mode} <- required_mode(profile) do
      resolve_mode(mode, profile, source)
    else
      false -> invalid(:responses_backend, :invalid_type)
      {:error, _} = error -> error
    end
  end

  @doc "Selected backend mode."
  def mode(%__MODULE__{mode: value}), do: value

  @doc "Selection source."
  def source(%__MODULE__{source: value}), do: value

  @doc "Whether the backend came from an explicit descriptor."
  def explicit?(%__MODULE__{source: source}), do: source != :default

  @doc "Endpoint descriptor. The endpoint value is request-internal and must not be logged."
  def endpoint(%__MODULE__{endpoint: value}), do: value

  @doc "Credential policy descriptor. No credential value is stored here."
  def auth_policy(%__MODULE__{auth_policy: value}), do: value

  @doc "Ordered transport capabilities."
  def transports(%__MODULE__{transports: value}), do: value

  @doc "Typed optional request-extension capabilities."
  def request_extensions(%__MODULE__{request_extensions: value}), do: value

  @doc false
  def valid?(%__MODULE__{mode: :chatgpt_codex} = backend) do
    backend.source in [:default, :config, :provider_opts] and backend.endpoint == :default and
      backend.auth_policy == :chatgpt_oauth_or_api_key and
      backend.transports == [:websocket, :http_sse] and
      backend.request_extensions == @chatgpt_extensions
  end

  def valid?(%__MODULE__{mode: :open_responses} = backend) do
    backend.source in [:config, :provider_opts] and valid_stored_endpoint?(backend.endpoint) and
      valid_stored_auth?(backend.auth_policy) and backend.transports == [:http_sse] and
      backend.request_extensions == MapSet.new()
  end

  def valid?(_backend), do: false

  @doc "Total, redacted, JSON-friendly diagnostic projection."
  @spec summary(term()) :: map() | :invalid
  def summary(%__MODULE__{} = backend) do
    if valid?(backend), do: summary_valid(backend), else: :invalid
  rescue
    _error -> :invalid
  catch
    _kind, _reason -> :invalid
  end

  def summary(_backend), do: :invalid

  defp summary_valid(%__MODULE__{} = backend) do
    %{
      "mode" => Atom.to_string(backend.mode),
      "source" => Atom.to_string(backend.source),
      "endpoint_kind" => endpoint_kind(backend.endpoint),
      "auth_policy" => auth_summary(backend.auth_policy),
      "transports" => Enum.map(backend.transports, &Atom.to_string/1),
      "request_extensions" =>
        backend.request_extensions
        |> MapSet.intersection(@extension_ids)
        |> Enum.sort()
        |> Enum.map(&Atom.to_string/1)
    }
  end

  @doc "Total, redacted projection for diagnostic and `Inspect` boundaries."
  @spec safe_summary(term()) :: map() | :invalid
  def safe_summary(backend), do: summary(backend)

  @doc "Return whether production use is active for this staged backend."
  @spec activation_status(t()) :: :ok | {:error, map()}
  def activation_status(%__MODULE__{} = backend) do
    case {valid?(backend), backend.mode} do
      {true, :chatgpt_codex} ->
        :ok

      {true, :open_responses} ->
        :ok

      _ ->
        invalid(:responses_backend, :invalid_type)
    end
  end

  def activation_status(_backend), do: invalid(:responses_backend, :invalid_type)

  defp resolve_mode("chatgpt_codex", profile, source) do
    with :ok <- only_fields(profile, ["mode"]) do
      {:ok,
       %__MODULE__{
         mode: :chatgpt_codex,
         source: source,
         endpoint: :default,
         auth_policy: :chatgpt_oauth_or_api_key,
         transports: [:websocket, :http_sse],
         request_extensions: @chatgpt_extensions
       }}
    end
  end

  defp resolve_mode("open_responses", profile, source)
       when source in [:config, :provider_opts] do
    with :ok <- only_fields(profile, ["mode", "base_url", "responses_url", "auth"]),
         {:ok, endpoint} <- open_endpoint(profile),
         {:ok, auth_policy} <- open_auth(profile) do
      {:ok,
       %__MODULE__{
         mode: :open_responses,
         source: source,
         endpoint: endpoint,
         auth_policy: auth_policy,
         transports: [:http_sse],
         request_extensions: MapSet.new()
       }}
    end
  end

  defp resolve_mode("open_responses", _profile, _source),
    do: invalid(:responses_backend, :invalid_type)

  defp resolve_mode(_mode, _profile, _source), do: invalid(:mode, :unknown_mode)

  defp required_mode(profile) do
    case Map.fetch(profile, "mode") do
      {:ok, mode} when is_binary(mode) -> {:ok, mode}
      {:ok, _other} -> invalid(:mode, :invalid_type)
      :error -> invalid(:mode, :missing_mode)
    end
  end

  defp open_endpoint(profile) do
    base = Map.fetch(profile, "base_url")
    exact = Map.fetch(profile, "responses_url")

    case {base, exact} do
      {:error, :error} -> invalid(:endpoint, :missing_endpoint)
      {{:ok, _}, {:ok, _}} -> invalid(:endpoint, :conflicting_endpoints)
      {{:ok, value}, :error} -> validate_endpoint(:base_url, value)
      {:error, {:ok, value}} -> validate_endpoint(:responses_url, value)
    end
  end

  defp validate_endpoint(kind, value) when not is_binary(value),
    do: invalid(kind, :invalid_endpoint)

  defp validate_endpoint(kind, value) do
    with true <- String.valid?(value),
         size when size in 1..2048 <- byte_size(value),
         true <- value == String.trim(value),
         false <- Regex.match?(~r/[\x00-\x20\x7f\\]/u, value),
         %URI{} = uri <- URI.parse(value),
         true <- uri.scheme in ["http", "https"],
         true <- binary_part(value, 0, byte_size(uri.scheme)) == uri.scheme,
         true <- is_binary(uri.host) and uri.host != "",
         nil <- uri.userinfo,
         nil <- uri.query,
         nil <- uri.fragment,
         :ok <- validate_authority(value),
         :ok <- validate_host(uri.host, value),
         :ok <- validate_port(uri, value),
         :ok <- validate_path(uri.path || ""),
         :ok <- validate_endpoint_path(kind, uri.path || "") do
      {:ok, {kind, value}}
    else
      _ -> invalid(kind, :invalid_endpoint)
    end
  rescue
    _error -> invalid(kind, :invalid_endpoint)
  end

  defp validate_authority(value) do
    authority =
      value
      |> String.split("//", parts: 2)
      |> List.last()
      |> String.split(["/", "?", "#"], parts: 2)
      |> hd()

    cond do
      String.contains?(authority, "%") -> :error
      String.contains?(authority, "@") -> :error
      true -> :ok
    end
  end

  defp validate_host(host, original) do
    authority =
      original
      |> String.split("//", parts: 2)
      |> List.last()
      |> String.split("/", parts: 2)
      |> hd()

    cond do
      String.starts_with?(authority, "[") -> validate_ipv6_authority(authority)
      host == "localhost" -> :ok
      canonical_ipv4?(host) -> :ok
      ambiguous_hex_numeric_host?(host) -> :error
      numeric_host?(host) -> :error
      valid_dns_host?(host) -> :ok
      true -> :error
    end
  end

  defp validate_ipv6_authority(authority) do
    case Regex.run(~r/^\[([^\]]+)\](?::[^:]*)?$/, authority) do
      [_, host] ->
        if String.contains?(host, "%") do
          :error
        else
          case :inet.parse_address(String.to_charlist(host)) do
            {:ok, tuple} when tuple_size(tuple) == 8 -> :ok
            _ -> :error
          end
        end

      _ ->
        :error
    end
  end

  defp canonical_ipv4?(host) do
    parts = String.split(host, ".")

    length(parts) == 4 and
      Enum.all?(parts, fn part ->
        case Integer.parse(part) do
          {value, ""} when value in 0..255 -> part == Integer.to_string(value)
          _ -> false
        end
      end)
  end

  defp numeric_host?(host), do: Regex.match?(~r/^\d+(?:\.\d+)*$/, host)

  defp ambiguous_hex_numeric_host?(host) do
    components = String.split(host, ".")

    Enum.any?(components, &Regex.match?(~r/^0[xX][0-9A-Fa-f]+$/, &1)) and
      Enum.all?(components, fn component ->
        Regex.match?(~r/^[0-9]+$/, component) or
          Regex.match?(~r/^0[xX][0-9A-Fa-f]+$/, component)
      end)
  end

  defp valid_dns_host?(host) do
    byte_size(host) <= 253 and not String.ends_with?(host, ".") and
      Enum.all?(String.split(host, "."), fn label ->
        byte_size(label) in 1..63 and
          Regex.match?(~r/^[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?$/, label)
      end)
  end

  defp validate_port(%URI{port: port}, original) do
    authority =
      original
      |> String.split("//", parts: 2)
      |> List.last()
      |> String.split("/", parts: 2)
      |> hd()

    case explicit_port(authority) do
      :absent ->
        :ok

      {:present, digits} ->
        with true <- digits != "" and Regex.match?(~r/^[0-9]+$/, digits),
             {parsed, ""} <- Integer.parse(digits),
             true <- parsed in 1..65_535,
             true <- digits == Integer.to_string(parsed),
             true <- port == parsed do
          :ok
        else
          _ -> :error
        end

      :error ->
        :error
    end
  end

  defp explicit_port("[" <> _ = authority) do
    case Regex.run(~r/^\[[^\]]+\](?::(.*))?$/, authority) do
      [_whole] -> :absent
      [_whole, digits] -> {:present, digits}
      _ -> :error
    end
  end

  defp explicit_port(authority) do
    case String.split(authority, ":", parts: 2) do
      [_host] -> :absent
      [_host, digits] -> {:present, digits}
      _ -> :error
    end
  end

  defp validate_path(path) do
    if valid_percent_escapes?(path), do: :ok, else: :error
  end

  defp valid_percent_escapes?(<<>>), do: true

  defp valid_percent_escapes?(<<"%", a, b, rest::binary>>) do
    if hex?(a) and hex?(b) and not decoded_control?(a, b),
      do: valid_percent_escapes?(rest),
      else: false
  end

  defp valid_percent_escapes?(<<"%", _rest::binary>>), do: false
  defp valid_percent_escapes?(<<_byte, rest::binary>>), do: valid_percent_escapes?(rest)

  defp hex?(byte), do: byte in ?0..?9 or byte in ?A..?F or byte in ?a..?f

  defp decoded_control?(a, b) do
    {value, ""} = Integer.parse(<<a, b>>, 16)
    value < 0x20 or value == 0x7F
  end

  defp validate_endpoint_path(:base_url, path) when path in ["", "/"], do: :ok

  defp validate_endpoint_path(:responses_url, path)
       when is_binary(path) and path not in ["", "/"], do: :ok

  defp validate_endpoint_path(_kind, _path), do: :error

  defp valid_stored_endpoint?({kind, value}) when kind in [:base_url, :responses_url],
    do: match?({:ok, {^kind, ^value}}, validate_endpoint(kind, value))

  defp valid_stored_endpoint?(_endpoint), do: false

  defp valid_stored_auth?(:none), do: true

  defp valid_stored_auth?({:bearer_env, env_var}) when is_binary(env_var),
    do:
      byte_size(env_var) in 1..128 and
        Regex.match?(~r/^[A-Z_][A-Z0-9_]*$/, env_var)

  defp valid_stored_auth?(_auth), do: false

  defp open_auth(profile) do
    case Map.fetch(profile, "auth") do
      :error -> invalid(:auth, :missing_auth)
      {:ok, value} -> resolve_open_auth(value)
    end
  end

  defp resolve_open_auth(value) do
    with {:ok, auth} <- normalize_object(value, :auth),
         {:ok, policy} <- fetch_binary(auth, "policy", :policy) do
      case policy do
        "none" ->
          with :ok <- only_fields(auth, ["policy"], :auth), do: {:ok, :none}

        "bearer_env" ->
          with :ok <- only_fields(auth, ["policy", "env_var"], :auth),
               {:ok, env_var} <- fetch_env_name(auth),
               true <-
                 byte_size(env_var) in 1..128 and Regex.match?(~r/^[A-Z_][A-Z0-9_]*$/, env_var) do
            {:ok, {:bearer_env, env_var}}
          else
            {:error, _} = error -> error
            _ -> invalid(:auth, :invalid_env_name)
          end

        _ ->
          invalid(:policy, :unsupported_auth_policy)
      end
    end
  end

  defp fetch_binary(map, key, field) do
    case Map.fetch(map, key) do
      {:ok, value} when is_binary(value) -> {:ok, value}
      {:ok, _value} -> invalid(field, :invalid_type)
      :error -> invalid(field, :invalid_auth)
    end
  end

  defp fetch_env_name(auth) do
    case Map.fetch(auth, "env_var") do
      {:ok, value} when is_binary(value) -> {:ok, value}
      _ -> invalid(:auth, :invalid_env_name)
    end
  end

  defp normalize_object(value, field) when is_map(value) and not is_struct(value) do
    Enum.reduce_while(value, {:ok, %{}}, fn {key, nested}, {:ok, acc} ->
      case normalize_key(key) do
        {:ok, normalized_key} ->
          if Map.has_key?(acc, normalized_key) do
            {:halt, invalid(field, :unknown_field)}
          else
            case normalize_nested(nested, nested_field(normalized_key, field)) do
              {:ok, normalized_value} ->
                {:cont, {:ok, Map.put(acc, normalized_key, normalized_value)}}

              {:error, _} = error ->
                {:halt, error}
            end
          end

        :error ->
          {:halt, invalid(field, :unknown_field)}
      end
    end)
  end

  defp normalize_object(_value, field), do: invalid(field, :invalid_type)

  defp normalize_nested(value, field) when is_map(value) and not is_struct(value),
    do: normalize_object(value, field)

  defp normalize_nested(value, field) when is_struct(value), do: invalid(field, :invalid_type)
  defp normalize_nested(value, _field), do: {:ok, value}

  defp nested_field("auth", _parent), do: :auth
  defp nested_field(_key, parent), do: parent

  defp normalize_key(key) when is_binary(key), do: {:ok, key}
  defp normalize_key(key) when is_atom(key), do: {:ok, Atom.to_string(key)}
  defp normalize_key(_key), do: :error

  defp only_fields(map, allowed, field \\ :responses_backend) do
    if Enum.all?(Map.keys(map), &(&1 in allowed)),
      do: :ok,
      else: invalid(field, :unknown_field)
  end

  defp endpoint_kind(:default), do: "default"
  defp endpoint_kind({kind, _value}), do: Atom.to_string(kind)

  defp auth_summary(:chatgpt_oauth_or_api_key), do: %{"policy" => "chatgpt_oauth_or_api_key"}
  defp auth_summary(:none), do: %{"policy" => "none"}

  defp auth_summary({:bearer_env, env_var}),
    do: %{"policy" => "bearer_env", "env_var" => env_var}

  defp invalid(field, reason) do
    {:error,
     Tool.error(:invalid_config, "The Responses backend configuration is invalid.", %{
       field: field,
       reason: reason
     })}
  end
end

defimpl Inspect, for: Pixir.Providers.ResponsesBackend do
  import Inspect.Algebra

  def inspect(backend, opts) do
    concat([
      "#ResponsesBackend<",
      to_doc(Pixir.Providers.ResponsesBackend.safe_summary(backend), opts),
      ">"
    ])
  end
end
