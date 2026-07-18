defmodule Pixir.Provider.WebSocketClient do
  @moduledoc """
  Minimal Responses WebSocket client used by the production Provider connection.

  The client intentionally emits the data-only SSE-shaped chunks that the default
  ChatGPT/Codex reducer already knows how to fold. This keeps that model-event parser in
  one place while the connection process owns socket lifetime and continuation state.
  Profiles that require a named `event:` field must not enable this transport until the
  adapter projects the JSON `type` into a matching event name; the initial strict
  `open_responses` profile is therefore gated to HTTP/SSE by `ResponsesBackend`.
  """

  import Bitwise, only: [|||: 2]

  alias Pixir.Provider.{StreamIdle, TransportError}
  alias Pixir.Tool

  @user_agent "pixir-websocket/0.1"
  @max_frame_bytes 16_000_000

  @type socket :: term()
  @type handshake :: %{status: integer() | nil, status_line: String.t()}

  @spec connect(String.t(), [{String.t(), String.t()}], keyword()) ::
          {:ok, socket(), binary(), handshake()} | {:error, map()}
  def connect(endpoint, headers, opts \\ []) do
    timeout_ms = Keyword.get(opts, :timeout_ms, 30_000)

    with {:ok, uri} <- parse_endpoint(endpoint),
         :ok <- Application.ensure_all_started(:ssl) |> normalize_started(),
         {:ok, socket} <- ssl_connect(uri, timeout_ms) do
      case websocket_handshake(socket, uri, headers, timeout_ms) do
        {:ok, handshake, rest} ->
          if handshake.status == 101 do
            {:ok, socket, rest, handshake}
          else
            close(socket)

            {:error,
             Tool.error(:websocket_handshake_failed, "WebSocket handshake did not upgrade.", %{
               status: handshake.status,
               endpoint: safe_endpoint(endpoint)
             })}
          end

        {:error, _} = error ->
          close(socket)
          error
      end
    end
  end

  @spec stream(socket(), binary(), map(), acc, (term(), acc -> acc), keyword()) ::
          {:ok, acc, map()} | {:error, map(), acc}
        when acc: term()
  def stream(socket, initial_buffer, payload, acc, fun, opts \\ []) do
    timeout_ms = Keyword.get(opts, :timeout_ms, 30_000)

    with :ok <- send_json(socket, payload),
         {:ok, acc, response} <-
           read_response(socket, initial_buffer, timeout_ms, acc, fun, opts) do
      {:ok, acc, response}
    else
      {:error, %{error: %{kind: _}} = error, acc} ->
        {:error, error, acc}

      {:error, %{error: %{kind: _}} = error} ->
        {:error, error, acc}

      {:error, reason} ->
        {:error,
         Tool.error(:websocket_failed, "WebSocket request failed.", %{
           reason: TransportError.reason(reason)
         }), acc}
    end
  end

  @spec close(socket() | nil) :: {:ok, :noop | :closed} | {:error, term()}
  def close(nil), do: {:ok, :noop}

  def close(socket) do
    case :ssl.close(socket) do
      :ok -> {:ok, :closed}
      {:error, reason} -> {:error, reason}
    end
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  @spec ping(socket()) :: :ok | {:error, term()}
  def ping(socket) do
    with :ok <- :ssl.send(socket, ping_frame("")) do
      drain_idle_control_frames(socket, "", System.monotonic_time(:millisecond) + 50)
    end
  end

  defp websocket_handshake(socket, uri, headers, timeout_ms) do
    with {:ok, request_headers} <- handshake_headers(uri, headers),
         :ok <- :ssl.send(socket, request_headers),
         {:ok, handshake, rest} <- read_handshake(socket, timeout_ms) do
      {:ok, handshake, rest}
    else
      {:error, reason} ->
        {:error,
         Tool.error(:websocket_handshake_failed, "WebSocket handshake failed.", %{
           reason: TransportError.reason(reason),
           endpoint: safe_endpoint(URI.to_string(uri))
         })}
    end
  end

  defp normalize_started({:ok, _apps}), do: :ok
  defp normalize_started({:error, _} = error), do: error

  defp parse_endpoint(endpoint) when is_binary(endpoint) do
    uri = URI.parse(endpoint)

    cond do
      uri.scheme != "wss" ->
        {:error,
         Tool.error(:invalid_endpoint, "WebSocket endpoint must use wss://.", %{
           endpoint: safe_endpoint(endpoint)
         })}

      not is_binary(uri.host) ->
        {:error,
         Tool.error(:invalid_endpoint, "WebSocket endpoint must include a host.", %{
           endpoint: safe_endpoint(endpoint)
         })}

      true ->
        {:ok, %{uri | port: uri.port || 443, path: uri.path || "/"}}
    end
  end

  defp ssl_connect(uri, timeout_ms) do
    host = String.to_charlist(uri.host)

    :ssl.connect(
      host,
      uri.port,
      [
        :binary,
        active: false,
        verify: :verify_peer,
        cacerts: :public_key.cacerts_get(),
        server_name_indication: host,
        customize_hostname_check: [
          match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
        ]
      ],
      timeout_ms
    )
    |> case do
      {:ok, socket} ->
        {:ok, socket}

      {:error, reason} ->
        {:error,
         Tool.error(:websocket_connect_failed, "Could not open TLS connection.", %{
           reason: TransportError.reason(reason),
           endpoint: safe_endpoint(URI.to_string(uri))
         })}
    end
  end

  defp handshake_headers(uri, headers) do
    key = :crypto.strong_rand_bytes(16) |> Base.encode64()
    path = endpoint_path(uri)

    request_headers =
      [
        {"Host", host_header(uri)},
        {"Connection", "Upgrade"},
        {"Upgrade", "websocket"},
        {"Sec-WebSocket-Key", key},
        {"Sec-WebSocket-Version", "13"},
        {"openai-beta", "responses=experimental"},
        {"originator", "pixir"},
        {"User-Agent", @user_agent}
      ] ++ normalize_headers(headers)

    request =
      [
        "GET #{path} HTTP/1.1"
        | Enum.map(request_headers, fn {name, value} -> "#{name}: #{value}" end)
      ]
      |> Enum.join("\r\n")

    {:ok, request <> "\r\n\r\n"}
  end

  defp normalize_headers(headers) do
    headers
    |> Enum.reject(fn {name, _value} ->
      String.downcase(to_string(name)) in ["content-type", "accept"]
    end)
    |> Enum.map(fn
      {"authorization", value} -> {"Authorization", value}
      {name, value} -> {name, value}
    end)
  end

  defp endpoint_path(%URI{path: path, query: nil}), do: path || "/"
  defp endpoint_path(%URI{path: path, query: query}), do: (path || "/") <> "?" <> query

  defp host_header(%URI{host: host, port: 443}), do: host
  defp host_header(%URI{host: host, port: port}), do: "#{host}:#{port}"

  defp read_handshake(socket, timeout_ms), do: read_handshake(socket, "", timeout_ms)

  defp read_handshake(socket, buffer, timeout_ms) do
    case String.split(buffer, "\r\n\r\n", parts: 2) do
      [headers, rest] when headers != buffer ->
        {:ok, parse_handshake(headers), rest}

      _ ->
        case :ssl.recv(socket, 0, timeout_ms) do
          {:ok, data} -> read_handshake(socket, buffer <> data, timeout_ms)
          {:error, reason} -> {:error, {:handshake_read_failed, reason}}
        end
    end
  end

  defp parse_handshake(headers) do
    [status_line | _] = String.split(headers, "\r\n")

    status =
      case Regex.run(~r/^HTTP\/\S+\s+(\d+)/, status_line) do
        [_, code] -> String.to_integer(code)
        _ -> nil
      end

    %{status: status, status_line: status_line}
  end

  defp send_json(socket, payload) do
    payload
    |> Jason.encode!()
    |> text_frame()
    |> then(&:ssl.send(socket, &1))
  end

  defp text_frame(text) when is_binary(text) do
    payload = IO.iodata_to_binary(text)
    mask = :crypto.strong_rand_bytes(4)
    header = frame_header(0x81, byte_size(payload), true)
    [header, mask, mask_payload(payload, mask)]
  end

  defp frame_header(opcode, length, masked?) do
    mask_bit = if masked?, do: 0x80, else: 0

    cond do
      length < 126 -> <<opcode, mask_bit ||| length>>
      length < 65_536 -> <<opcode, mask_bit ||| 126, length::16>>
      true -> <<opcode, mask_bit ||| 127, length::64>>
    end
  end

  defp mask_payload(payload, <<a, b, c, d>>) do
    payload
    |> :binary.bin_to_list()
    |> Enum.with_index()
    |> Enum.map(fn {byte, index} ->
      Bitwise.bxor(byte, elem({a, b, c, d}, rem(index, 4)))
    end)
    |> IO.iodata_to_binary()
  end

  defp read_response(socket, initial_buffer, timeout_ms, acc, fun, opts) do
    idle_ms = stream_idle_timeout_ms(opts, timeout_ms)
    idle_deadline = System.monotonic_time(:millisecond) + idle_ms

    read_response_loop(socket, initial_buffer, idle_deadline, idle_ms, acc, fun, opts, %{
      response_id: nil,
      fragment_opcode: nil,
      fragment_payload: ""
    })
  end

  defp read_response_loop(socket, buffer, idle_deadline, idle_ms, acc, fun, opts, response) do
    case next_frame(buffer) do
      {:ok, frame, rest} ->
        StreamIdle.notify(opts)
        idle_deadline = System.monotonic_time(:millisecond) + idle_ms

        case handle_frame(socket, frame, acc, fun, response) do
          {:continue, acc, response} ->
            read_response_loop(socket, rest, idle_deadline, idle_ms, acc, fun, opts, response)

          {:done, acc, response} ->
            # The terminal frame owns this receive boundary. Fold only complete frames already
            # present in `rest`; never perform an arbitrary post-terminal recv on the reusable
            # connection. HTTP/SSE transports may already have delivered a complete body.
            control_fun = fn
              %{opcode: 0x9, payload: payload} -> :ssl.send(socket, pong_frame(payload))
              _frame -> :ok
            end

            {:ok, fold_buffered_terminal_frames(rest, acc, fun, control_fun), response}

          {:error, error, acc} ->
            {:error, error, acc}
        end

      {:error, error} ->
        {:error, error, acc}

      :more ->
        timeout = max(idle_deadline - System.monotonic_time(:millisecond), 0)

        if timeout == 0 do
          {:error, StreamIdle.error(idle_ms, "websocket"), acc}
        else
          case :ssl.recv(socket, 0, timeout) do
            {:ok, data} ->
              read_response_loop(
                socket,
                buffer <> data,
                idle_deadline,
                idle_ms,
                acc,
                fun,
                opts,
                response
              )

            {:error, reason} ->
              {:error,
               Tool.error(:websocket_read_failed, "Could not read WebSocket frame.", %{
                 reason: TransportError.reason(reason)
               }), acc}
          end
        end
    end
  end

  defp stream_idle_timeout_ms(opts, fallback_timeout_ms) do
    case StreamIdle.idle_timeout_ms(opts) do
      timeout when timeout in [:infinity, 0] -> fallback_timeout_ms
      idle_ms -> idle_ms
    end
  end

  defp next_frame(buffer) when byte_size(buffer) < 2, do: :more

  defp next_frame(<<first, second, rest::binary>> = buffer) do
    fin = Bitwise.band(first, 0x80) != 0
    opcode = Bitwise.band(first, 0x0F)
    masked? = Bitwise.band(second, 0x80) != 0
    base_len = Bitwise.band(second, 0x7F)

    with {:ok, len, rest} <- frame_length(base_len, rest),
         {:ok, mask, payload_and_rest} <- frame_mask(masked?, rest),
         true <- byte_size(payload_and_rest) >= len do
      <<payload::binary-size(^len), remaining::binary>> = payload_and_rest
      payload = if masked?, do: mask_payload(payload, mask), else: payload
      {:ok, %{fin: fin, opcode: opcode, payload: payload}, remaining}
    else
      false -> :more
      :more -> :more
      {:error, reason} -> {:error, reason}
    end
  rescue
    _error in [ArgumentError, MatchError, FunctionClauseError] ->
      {:ok, %{fin: true, opcode: 0x8, payload: buffer}, ""}
  end

  defp frame_length(len, rest) when len < 126, do: {:ok, len, rest}
  defp frame_length(126, <<len::16, rest::binary>>), do: {:ok, len, rest}
  defp frame_length(126, _rest), do: :more

  defp frame_length(127, <<len::64, rest::binary>>) when len <= @max_frame_bytes,
    do: {:ok, len, rest}

  defp frame_length(127, <<len::64, _rest::binary>>),
    do:
      {:error,
       Tool.error(:websocket_frame_too_large, "WebSocket frame is too large.", %{bytes: len})}

  defp frame_length(127, _rest), do: :more

  defp frame_mask(false, rest), do: {:ok, <<>>, rest}
  defp frame_mask(true, <<mask::binary-size(4), rest::binary>>), do: {:ok, mask, rest}
  defp frame_mask(true, _rest), do: :more

  defp handle_frame(_socket, %{opcode: 0x1, fin: false, payload: payload}, acc, _fun, response) do
    {:continue, acc, %{response | fragment_opcode: 0x1, fragment_payload: payload}}
  end

  defp handle_frame(_socket, %{opcode: 0x1, fin: true, payload: payload}, acc, fun, response) do
    process_text_payload(payload, acc, fun, clear_fragment(response))
  end

  defp handle_frame(_socket, %{opcode: 0x0, fin: false, payload: payload}, acc, _fun, response) do
    case response do
      %{fragment_opcode: 0x1, fragment_payload: existing} ->
        {:continue, acc, %{response | fragment_payload: existing <> payload}}

      _ ->
        {:error,
         Tool.error(
           :websocket_failed,
           "Received a continuation frame without a text frame.",
           %{}
         ), acc}
    end
  end

  defp handle_frame(_socket, %{opcode: 0x0, fin: true, payload: payload}, acc, fun, response) do
    case response do
      %{fragment_opcode: 0x1, fragment_payload: existing} ->
        process_text_payload(existing <> payload, acc, fun, clear_fragment(response))

      _ ->
        {:error,
         Tool.error(
           :websocket_failed,
           "Received a continuation frame without a text frame.",
           %{}
         ), acc}
    end
  end

  defp handle_frame(socket, %{opcode: 0x9, payload: payload}, acc, _fun, response) do
    :ok = :ssl.send(socket, pong_frame(payload))
    {:continue, acc, response}
  end

  defp handle_frame(_socket, %{opcode: 0x8}, acc, _fun, _response) do
    {:error, Tool.error(:websocket_closed, "WebSocket closed before response.completed.", %{}),
     acc}
  end

  defp handle_frame(_socket, _frame, acc, _fun, response), do: {:continue, acc, response}

  defp clear_fragment(response), do: %{response | fragment_opcode: nil, fragment_payload: ""}

  defp drain_idle_control_frames(socket, buffer, deadline) do
    case next_frame(buffer) do
      {:ok, %{opcode: 0x9, payload: payload}, rest} ->
        with :ok <- :ssl.send(socket, pong_frame(payload)) do
          drain_idle_control_frames(socket, rest, deadline)
        end

      {:ok, %{opcode: 0xA}, rest} ->
        drain_idle_control_frames(socket, rest, deadline)

      {:ok, %{opcode: 0x8}, _rest} ->
        {:error, :websocket_closed}

      {:ok, %{opcode: opcode}, _rest} ->
        {:error, {:unexpected_idle_frame, opcode}}

      {:error, error} ->
        {:error, error}

      :more ->
        timeout = max(deadline - System.monotonic_time(:millisecond), 0)

        case :ssl.recv(socket, 0, timeout) do
          {:ok, data} -> drain_idle_control_frames(socket, buffer <> data, deadline)
          {:error, :timeout} -> :ok
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp process_text_payload(payload, acc, fun, response) do
    case Jason.decode(payload) do
      {:ok, %{"type" => type} = event} ->
        acc = fun.({:data, "data: " <> Jason.encode!(event) <> "\n\n"}, acc)
        response = maybe_capture_response_id(event, response)

        if terminal_event?(type) do
          {:done, acc, response}
        else
          {:continue, acc, response}
        end

      _ ->
        {:continue, acc, response}
    end
  end

  @doc false
  @spec fold_buffered_terminal_frames(binary(), acc, (term(), acc -> acc)) :: acc
        when acc: term()
  def fold_buffered_terminal_frames(buffer, acc, fun) when is_binary(buffer) do
    fold_buffered_terminal_frames(buffer, acc, fun, fn _frame -> :ok end)
  end

  @doc false
  def fold_buffered_terminal_frames(buffer, acc, fun, control_fun) when is_binary(buffer) do
    fold_buffered_terminal_frames(buffer, acc, fun, control_fun, nil, "")
  end

  defp fold_buffered_terminal_frames(
         buffer,
         acc,
         fun,
         control_fun,
         fragment_opcode,
         fragment_payload
       ) do
    case next_frame(buffer) do
      {:ok, %{opcode: 0x1, fin: true, payload: payload}, rest} ->
        acc = feed_buffered_terminal(payload, acc, fun)

        fold_buffered_terminal_frames(rest, acc, fun, control_fun, nil, "")

      {:ok, %{opcode: 0x1, fin: false, payload: payload}, rest} ->
        fold_buffered_terminal_frames(rest, acc, fun, control_fun, 0x1, payload)

      {:ok, %{opcode: 0x0, fin: false, payload: payload}, rest}
      when fragment_opcode == 0x1 ->
        fold_buffered_terminal_frames(
          rest,
          acc,
          fun,
          control_fun,
          0x1,
          fragment_payload <> payload
        )

      {:ok, %{opcode: 0x0, fin: true, payload: payload}, rest}
      when fragment_opcode == 0x1 ->
        acc = feed_buffered_terminal(fragment_payload <> payload, acc, fun)
        fold_buffered_terminal_frames(rest, acc, fun, control_fun, nil, "")

      {:ok, %{opcode: opcode} = frame, rest} when opcode in [0x9, 0xA] ->
        _ = control_fun.(frame)

        fold_buffered_terminal_frames(
          rest,
          acc,
          fun,
          control_fun,
          fragment_opcode,
          fragment_payload
        )

      {:ok, _frame, rest} ->
        fold_buffered_terminal_frames(
          rest,
          acc,
          fun,
          control_fun,
          fragment_opcode,
          fragment_payload
        )

      _ ->
        acc
    end
  end

  defp feed_buffered_terminal(payload, acc, fun) do
    case Jason.decode(payload) do
      {:ok, %{"type" => type} = event} ->
        if terminal_event?(type) do
          fun.({:data, "data: " <> Jason.encode!(event) <> "\n\n"}, acc)
        else
          acc
        end

      _ ->
        acc
    end
  end

  @doc false
  @spec terminal_event?(term()) :: boolean()
  def terminal_event?(type),
    do: type in ["response.completed", "response.incomplete", "response.failed", "error"]

  @doc false
  @spec response_id_from_event(map()) :: String.t() | nil
  def response_id_from_event(%{"response" => %{"id" => id}}) when is_binary(id),
    do: valid_response_id(id)

  def response_id_from_event(%{"response_id" => id}) when is_binary(id),
    do: valid_response_id(id)

  def response_id_from_event(%{"type" => "response." <> _rest, "id" => id}) when is_binary(id),
    do: valid_response_id(id)

  def response_id_from_event(%{"type" => "response.in_progress", "response" => response})
      when is_map(response) do
    response
    |> Map.get("id")
    |> valid_response_id()
  end

  def response_id_from_event(_event), do: nil

  defp maybe_capture_response_id(event, response) do
    case response_id_from_event(event) do
      nil -> response
      id -> %{response | response_id: id}
    end
  end

  defp valid_response_id("resp_" <> _ = id), do: id
  defp valid_response_id(_id), do: nil

  defp pong_frame(payload) do
    mask = :crypto.strong_rand_bytes(4)
    [frame_header(0x8A, byte_size(payload), true), mask, mask_payload(payload, mask)]
  end

  defp ping_frame(payload) do
    mask = :crypto.strong_rand_bytes(4)
    [frame_header(0x89, byte_size(payload), true), mask, mask_payload(payload, mask)]
  end

  defp safe_endpoint(endpoint) when is_binary(endpoint) do
    case URI.parse(endpoint).scheme do
      scheme when scheme in ["http", "https", "ws", "wss"] -> "<#{scheme}_endpoint>"
      _scheme -> "<configured_endpoint>"
    end
  rescue
    _error -> "<configured_endpoint>"
  end

  defp safe_endpoint(_endpoint), do: "<configured_endpoint>"
end
