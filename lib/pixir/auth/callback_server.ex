defmodule Pixir.Auth.CallbackServer do
  @moduledoc """
  Short-lived localhost HTTP server for the Codex browser OAuth callback (ADR 0002).

  Binds `127.0.0.1:1455` by default, accepts a single `/auth/callback` request, validates
  the OAuth `state`, and returns the authorization `code`. The registered redirect URI
  uses `localhost` (Pi/Codex convention) even though the listener binds to loopback.
  """

  @default_host "127.0.0.1"
  @default_port 1455
  @callback_path "/auth/callback"
  @redirect_uri "http://localhost:1455/auth/callback"
  @default_timeout_ms 15 * 60 * 1000

  @type listen_socket :: port()

  @doc "Registered OAuth redirect URI for the browser flow."
  @spec redirect_uri() :: String.t()
  def redirect_uri, do: @redirect_uri

  @doc "Start listening for one browser callback. Accepts `:host`, `:port` (testing)."
  @spec listen(keyword()) :: {:ok, listen_socket()} | {:error, map()}
  def listen(opts \\ []) do
    host = Keyword.get(opts, :host, @default_host)
    port = Keyword.get(opts, :port, @default_port)

    case :gen_tcp.listen(port, [:binary, active: false, reuseaddr: true, ip: parse_ip(host)]) do
      {:ok, socket} ->
        {:ok, socket}

      {:error, :eaddrinuse} ->
        {:error,
         err(
           :callback_port_unavailable,
           "could not bind #{host}:#{port} for the OAuth callback",
           %{host: host, port: port},
           ["run `pixir login --device-code` for headless sign-in"]
         )}

      {:error, reason} ->
        {:error,
         err(
           :callback_server_failed,
           "could not start the OAuth callback server",
           %{reason: inspect(reason), host: host, port: port},
           ["retry `pixir login` or use `pixir login --device-code`"]
         )}
    end
  end

  @doc """
  Accept one callback connection and return the authorization code.

  Options: `:state` (required), `:timeout_ms` (default 15 min).
  """
  @spec wait_for_callback(listen_socket(), keyword()) :: {:ok, String.t()} | {:error, map()}
  def wait_for_callback(socket, opts) when is_port(socket) do
    state = Keyword.fetch!(opts, :state)
    timeout_ms = Keyword.get(opts, :timeout_ms, @default_timeout_ms)

    case :gen_tcp.accept(socket, timeout_ms) do
      {:ok, client} ->
        try do
          handle_client(client, state)
        after
          :gen_tcp.close(client)
        end

      {:error, :timeout} ->
        {:error,
         err(
           :timeout,
           "browser login timed out waiting for authorization",
           %{timeout_ms: timeout_ms},
           ["retry `pixir login` or use `pixir login --device-code`"]
         )}

      {:error, reason} ->
        {:error,
         err(
           :callback_server_failed,
           "OAuth callback accept failed",
           %{reason: inspect(reason)},
           ["retry `pixir login`"]
         )}
    end
  end

  @doc "Close the listen socket."
  @spec close(listen_socket()) :: :ok
  def close(socket) when is_port(socket) do
    :gen_tcp.close(socket)
    :ok
  end

  # ── internals ─────────────────────────────────────────────────────────────

  defp handle_client(socket, expected_state) do
    with {:ok, request} <- :gen_tcp.recv(socket, 0, 5_000),
         {:ok, path, query} <- parse_request(request),
         :ok <- ensure_callback_path(path),
         {:ok, code} <- validate_callback(query, expected_state) do
      send_response(socket, 200, success_html())
      {:ok, code}
    else
      {:error, %{error: %{kind: :oauth_denied}} = err} ->
        send_response(socket, 200, error_html(err.error.message))
        {:error, err}

      {:error, %{error: %{kind: :oauth_cancelled}} = err} ->
        send_response(socket, 200, error_html(err.error.message))
        {:error, err}

      {:error, _} = err ->
        send_response(socket, 400, error_html("Sign-in could not be completed."))
        err
    end
  end

  defp parse_request(request) when is_binary(request) do
    case String.split(request, "\r\n", parts: 2) do
      [request_line, _rest] ->
        case String.split(request_line, " ", parts: 3) do
          ["GET", raw_path, _version] ->
            uri = URI.parse(raw_path)
            {:ok, uri.path || "/", decode_query(uri.query)}

          _ ->
            {:error,
             err(:invalid_request, "unsupported HTTP request", %{}, ["retry `pixir login`"])}
        end

      _ ->
        {:error, err(:invalid_request, "malformed HTTP request", %{}, ["retry `pixir login`"])}
    end
  end

  defp ensure_callback_path(@callback_path), do: :ok

  defp ensure_callback_path(path),
    do:
      {:error,
       err(:invalid_request, "unexpected callback path", %{path: path}, ["retry `pixir login`"])}

  defp validate_callback(query, expected_state) do
    cond do
      query["state"] != expected_state ->
        {:error,
         err(:invalid_state, "OAuth state mismatch", %{}, ["retry `pixir login` from the start"])}

      query["error"] == "access_denied" ->
        {:error,
         err(
           :oauth_denied,
           "sign-in was denied or cancelled in the browser",
           %{error: query["error"], error_description: query["error_description"]},
           ["retry `pixir login` or use `pixir login --device-code`"]
         )}

      query["error"] != nil ->
        {:error,
         err(
           :oauth_cancelled,
           "sign-in failed in the browser",
           %{error: query["error"], error_description: query["error_description"]},
           ["retry `pixir login`"]
         )}

      is_binary(query["code"]) and query["code"] != "" ->
        {:ok, query["code"]}

      true ->
        {:error,
         err(
           :missing_authorization_code,
           "authorization code missing from callback",
           %{},
           ["retry `pixir login`"]
         )}
    end
  end

  defp decode_query(nil), do: %{}

  defp decode_query(query) do
    query
    |> URI.decode_query()
    |> Map.new(fn {k, v} -> {k, v} end)
  end

  defp send_response(socket, status, body) do
    reason = status_reason(status)
    headers = response_headers(byte_size(body))

    response =
      "HTTP/1.1 #{status} #{reason}\r\n#{headers}\r\n#{body}"

    :gen_tcp.send(socket, response)
  end

  defp response_headers(length) do
    """
    Content-Type: text/html; charset=utf-8\r
    Content-Length: #{length}\r
    Connection: close\r
    """
    |> String.trim_trailing()
  end

  defp status_reason(200), do: "OK"
  defp status_reason(400), do: "Bad Request"
  defp status_reason(_), do: "OK"

  defp success_html do
    "<!DOCTYPE html><html><body><p>Signed in with ChatGPT. You can close this window.</p></body></html>"
  end

  defp error_html(message) do
    "<!DOCTYPE html><html><body><p>#{escape_html(message)}</p></body></html>"
  end

  defp escape_html(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
  end

  defp parse_ip(host) when is_binary(host) do
    host
    |> String.to_charlist()
    |> :inet.parse_address()
    |> case do
      {:ok, tuple} -> tuple
      {:error, _} -> {127, 0, 0, 1}
    end
  end

  defp err(kind, message, details, next_actions) do
    %{
      ok: false,
      error: %{
        kind: kind,
        message: message,
        details: details,
        next_actions: next_actions
      }
    }
  end
end
