defmodule Pixir.ACP.Protocol do
  @moduledoc """
  JSON-RPC 2.0 framing over `Jason`, newline-delimited (ndjson), for the ACP agent
  transport (ADR 0009). Pure functions, no IO: one decoded ndjson line becomes a tagged
  term; result/error/notification maps become a JSON string (the caller appends `"\\n"`).

  There is deliberately no JSON-RPC dependency — the wire shape is small and hand-built
  over `Jason` (one JSON object per line). stdout carries only these encoded strings;
  every diagnostic goes to stderr (ADR 0005 channel discipline).
  """

  # JSON-RPC 2.0 error codes (the only ones Pixir emits — reserved for protocol faults).
  @parse_error -32_700
  @invalid_request -32_600
  @method_not_found -32_601
  @invalid_params -32_602
  @internal_error -32_603

  @type id :: integer() | String.t()
  @type method :: String.t()
  @type params :: map()
  @type rpc_error :: {atom(), integer(), String.t()}

  @type decoded ::
          {:request, id(), method(), params()}
          | {:notification, method(), params()}
          | {:response, id(), term()}
          | {:response_error, id(), term()}
          | {:error, rpc_error()}
          | {:ignore, id() | nil}

  @doc "JSON-RPC code for a method-not-found fault."
  @spec method_not_found() :: integer()
  def method_not_found, do: @method_not_found

  @doc "JSON-RPC code for an invalid-params fault."
  @spec invalid_params() :: integer()
  def invalid_params, do: @invalid_params

  @doc "JSON-RPC code for an internal-error fault."
  @spec internal_error() :: integer()
  def internal_error, do: @internal_error

  @doc """
  Decode one ndjson line into a tagged term:

    * `{:request, id, method, params}` — has both `"id"` and `"method"`.
    * `{:notification, method, params}` — has `"method"` and no `"id"`.
    * `{:error, {kind, code, message}}` — malformed JSON or a non-2.0 envelope.
    * `{:ignore, id}` — a valid envelope an agent never acts on (e.g. a response).

  `params` defaults to `%{}` when absent.
  """
  @spec decode(binary()) :: decoded()
  def decode(line) when is_binary(line) do
    case Jason.decode(line) do
      {:ok, %{} = obj} -> classify(obj)
      {:ok, _other} -> {:error, {:invalid_request, @invalid_request, "Invalid Request"}}
      {:error, _} -> {:error, {:parse, @parse_error, "Parse error"}}
    end
  end

  defp classify(%{"jsonrpc" => "2.0"} = obj) do
    id = Map.get(obj, "id")
    method = Map.get(obj, "method")
    params = Map.get(obj, "params", %{})

    cond do
      # A request/notification with non-object `params` (e.g. `null`, `[]`) is
      # malformed. Reject it here rather than forwarding a non-map downstream —
      # the handlers call `Map.get/2` on params, so a list/scalar would raise
      # and take the stdio transport down.
      is_binary(method) and not is_map(params) ->
        {:error, {:invalid_request, @invalid_request, "Invalid Request"}}

      valid_id?(id) and is_binary(method) ->
        {:request, id, method, params}

      # No usable id + a method ⇒ a notification. This covers both an absent id
      # and a blank-string id: effect-acp (T3 Code's ACP client) serializes the
      # `session/cancel` notification with `"id":""`, which must NOT be taken as
      # a request — otherwise it falls through to -32601 and never interrupts.
      not valid_id?(id) and is_binary(method) ->
        {:notification, method, params}

      # A RESPONSE to an outbound request Pixir originated (has a usable id, no
      # method, and a `result` or `error`). Correlated against `pending_requests`
      # in the Server — this is what unblocks an in-flight `session/request_permission`
      # (A.2). An error response carries the JSON-RPC error object.
      valid_id?(id) and is_nil(method) and Map.has_key?(obj, "error") ->
        {:response_error, id, Map.get(obj, "error")}

      valid_id?(id) and is_nil(method) and Map.has_key?(obj, "result") ->
        {:response, id, Map.get(obj, "result")}

      # Anything else (e.g. an id-less response, or an envelope an agent never
      # acts on).
      true ->
        {:ignore, id}
    end
  end

  defp classify(_obj), do: {:error, {:invalid_request, @invalid_request, "Invalid Request"}}

  # A usable JSON-RPC id is an integer or a NON-empty string. A blank string is
  # not a routable id (see classify/1).
  defp valid_id?(id) when is_integer(id), do: true
  defp valid_id?(id) when is_binary(id), do: String.trim(id) != ""
  defp valid_id?(_id), do: false

  @doc "Encode a successful response (`id` + `result`) as a JSON string (no newline)."
  @spec result(id(), map()) :: String.t()
  def result(id, result) when is_map(result) do
    Jason.encode!(%{"jsonrpc" => "2.0", "id" => id, "result" => result})
  end

  @doc """
  Encode an error response as a JSON string (no newline). `data` is omitted unless
  non-nil. `id` may be `nil` (e.g. an unrecoverable parse error).
  """
  @spec error(id() | nil, integer(), String.t(), map() | nil) :: String.t()
  def error(id, code, message, data \\ nil) when is_integer(code) and is_binary(message) do
    err = %{"code" => code, "message" => message}
    err = if is_nil(data), do: err, else: Map.put(err, "data", data)
    Jason.encode!(%{"jsonrpc" => "2.0", "id" => id, "error" => err})
  end

  @doc "Encode a notification (`method` + `params`, no `id`) as a JSON string (no newline)."
  @spec notification(method(), params()) :: String.t()
  def notification(method, params) when is_binary(method) and is_map(params) do
    Jason.encode!(%{"jsonrpc" => "2.0", "method" => method, "params" => params})
  end

  @doc """
  Encode an OUTBOUND request (agent→client) as a JSON string (no newline). Unlike
  every other encoder here, this one originates a request expecting a response —
  used for `session/request_permission` (A.2). The Server correlates the eventual
  `{:response, id, _}` against the `id` written here.
  """
  @spec request(id(), method(), params()) :: String.t()
  def request(id, method, params) when is_binary(method) and is_map(params) do
    if valid_id?(id) do
      Jason.encode!(%{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params})
    else
      raise ArgumentError, "request id must be an integer or non-empty string"
    end
  end
end
