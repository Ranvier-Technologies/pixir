defmodule Pixir.Provider.TransportPolicy do
  @moduledoc """
  Runtime Provider transport policy.

  `:auto` prefers a per-key WebSocket connection and falls back to HTTP/SSE for
  transport failures. The fallback reuses the same HTTP request body, so safe
  `prompt_cache_key` metadata survives across transports. `previous_response_id` lives
  only inside the WebSocket connection process and is discarded on fallback.
  """

  alias Pixir.Provider.{Connection, FinchTransport}

  @type policy :: :auto | :websocket | :http_sse

  @spec stream(map(), acc, (term(), acc -> acc), keyword()) ::
          {:ok, acc} | {:error, term()} | {:error, term(), acc}
        when acc: term()
  def stream(http_request, acc, fun, opts \\ []) do
    case policy(opts) do
      :http_sse ->
        run_http(http_request, acc, fun, opts, nil)

      :websocket ->
        run_websocket(http_request, acc, fun, opts)

      :auto ->
        run_auto(http_request, acc, fun, opts)
    end
  end

  defp run_auto(http_request, acc, fun, opts) do
    case run_websocket(http_request, acc, fun, opts) do
      {:ok, _acc} = ok ->
        ok

      {:error, error, acc} ->
        if websocket_transport_error?(error) and fallback_safe?(acc) do
          run_http(http_request, acc, fun, opts, error)
        else
          {:error, error, acc}
        end

      {:error, error} ->
        if websocket_transport_error?(error) do
          run_http(http_request, acc, fun, opts, error)
        else
          {:error, error}
        end
    end
  end

  defp run_websocket(http_request, acc, fun, opts) do
    key = connection_key(opts)
    Connection.stream(key, http_request, acc, fun, opts)
  end

  defp run_http(http_request, acc, fun, opts, fallback_error) do
    transport = Keyword.get(opts, :http_transport, FinchTransport)

    # HTTP/SSE always replays the full request body, never `previous_response_id`.
    # Record that explicitly so absence-of-continuation is durable evidence, not a
    # missing field. On degraded WebSocket fallback the connection-local continuation
    # state is gone with the socket, so the reset reason is "socket_closed".
    metadata =
      %{
        "transport_preference" => Atom.to_string(policy(opts)),
        "active_transport" => "http_sse",
        "used_previous_response_id" => false,
        "continuation_attempted" => false,
        "continuation_reset_reason" => continuation_reset_reason(fallback_error)
      }
      |> maybe_put_fallback(fallback_error)

    acc = fun.({:metadata, metadata}, acc)
    run_transport(transport, http_request, acc, fun)
  end

  defp continuation_reset_reason(nil), do: nil
  defp continuation_reset_reason(_fallback_error), do: "socket_closed"

  defp run_transport(transport, http_request, acc, fun) when is_function(transport, 3),
    do: transport.(http_request, acc, fun)

  defp run_transport(transport, http_request, acc, fun),
    do: transport.stream(http_request, acc, fun)

  defp maybe_put_fallback(metadata, nil), do: metadata

  defp maybe_put_fallback(metadata, error) do
    Map.merge(metadata, %{
      "fallback_reason" => error_kind(error),
      "fallback_message" => error_message(error)
    })
  end

  defp websocket_transport_error?(%{error: %{kind: kind}})
       when kind in [
              :invalid_endpoint,
              :websocket_start_failed,
              :websocket_connect_failed,
              :websocket_handshake_failed,
              :websocket_degraded,
              :websocket_call_timeout,
              :websocket_timeout,
              :websocket_read_failed,
              :websocket_closed,
              :websocket_frame_too_large,
              :websocket_failed
            ],
       do: true

  defp websocket_transport_error?(_error), do: false

  defp fallback_safe?(acc) do
    acc[:text] in [nil, ""] and acc[:reasoning] in [nil, ""] and
      Enum.empty?(acc[:output_items] || []) and is_nil(acc[:usage])
  end

  defp error_kind(%{error: %{kind: kind}}) when is_atom(kind), do: Atom.to_string(kind)
  defp error_kind(_error), do: "websocket_failed"

  defp error_message(_error), do: "WebSocket transport failed."

  defp policy(opts) do
    opts
    |> Keyword.get_lazy(:provider_transport, fn ->
      Application.get_env(:pixir, :provider_transport, :auto)
    end)
    |> normalize_policy()
  end

  defp normalize_policy(policy) when policy in [:auto, :websocket, :http_sse], do: policy
  defp normalize_policy("auto"), do: :auto
  defp normalize_policy("websocket"), do: :websocket
  defp normalize_policy("http_sse"), do: :http_sse
  defp normalize_policy(_other), do: :auto

  defp connection_key(opts) do
    Keyword.get(opts, :provider_connection_key) ||
      Keyword.get(opts, :session_id) ||
      {:caller, self()}
  end
end
