defmodule Pixir.Provider.Connection do
  @moduledoc """
  Per-key WebSocket connection process for the Responses Provider.

  The process owns connection-local optimization state: socket, latest
  `previous_response_id`, prompt input prefix, keepalive timers, and temporary
  degraded/backoff state. It does not own Session History. If continuation state is
  missing or invalid, the caller can still replay from Pixir's Log over HTTP/SSE or a
  fresh WebSocket. The default idle window is deliberately agent-scale so ordinary
  pauses between Turns do not erase same-socket continuation evidence. Long provider
  streams are governed by stream watchdogs, not by a short caller-side
  `GenServer.call` deadline.
  """

  use GenServer

  alias Pixir.Provider.WebSocketClient
  alias Pixir.Tool

  @registry Pixir.Provider.ConnectionRegistry
  @default_timeout_ms 30_000
  @default_degraded_ms 5_000
  @default_idle_ms 30 * 60 * 1_000
  @default_keepalive_ms 25_000
  @callback_failure_tag {__MODULE__, :stream_callback_failed}

  def child_spec(opts) do
    key = Keyword.fetch!(opts, :key)

    %{
      id: {__MODULE__, key},
      start: {__MODULE__, :start_link, [opts]},
      restart: :transient,
      shutdown: 5_000,
      type: :worker
    }
  end

  def start_link(opts) do
    key = Keyword.fetch!(opts, :key)
    GenServer.start_link(__MODULE__, opts, name: via(key))
  end

  def via(key), do: {:via, Registry, {@registry, key}}

  @spec stream(term(), map(), acc, (term(), acc -> acc), keyword()) ::
          {:ok, acc} | {:error, map(), acc}
        when acc: term()
  def stream(key, http_request, acc, fun, opts \\ []) do
    case Pixir.Provider.ConnectionSupervisor.ensure_started(key) do
      {:ok, pid} ->
        case stream_call_timeout(opts) do
          {:ok, call_timeout} ->
            try do
              GenServer.call(pid, {:stream, http_request, acc, fun, opts}, call_timeout)
            catch
              :exit, {:timeout, _reason} ->
                Process.exit(pid, :kill)

                error =
                  Tool.error(
                    :websocket_call_timeout,
                    "WebSocket connection process did not complete the provider stream in time.",
                    %{
                      timeout_ms: call_timeout,
                      key: inspect(key),
                      continuation_reset_reason: "caller_timeout",
                      next_actions: ["retry_turn", "fall_back_to_full_replay"]
                    }
                  )

                {:error, error, acc}
            end

          {:error, error} ->
            {:error, error, acc}
        end

      {:error, reason} ->
        error =
          Tool.error(:websocket_start_failed, "WebSocket connection process could not start.", %{
            reason: inspect(reason),
            key: inspect(key)
          })

        {:error, error, acc}
    end
  end

  @doc false
  @spec stream_call_timeout(keyword()) :: {:ok, timeout()} | {:error, map()}
  def stream_call_timeout(opts) do
    timeout = Keyword.get(opts, :websocket_call_timeout_ms, :infinity)

    if timeout == :infinity or (is_integer(timeout) and timeout >= 0) do
      {:ok, timeout}
    else
      {:error,
       Tool.error(:invalid_args, "websocket_call_timeout_ms must be a valid timeout.", %{
         value: inspect(timeout),
         expected: "non_negative_integer_or_infinity"
       })}
    end
  end

  @impl true
  def init(opts) do
    {:ok,
     %{
       key: Keyword.fetch!(opts, :key),
       socket: nil,
       initial_buffer: "",
       endpoint: nil,
       headers_fingerprint: nil,
       previous_response_id: nil,
       previous_input: nil,
       previous_model: nil,
       last_continuation_reset_reason: nil,
       degraded_until_ms: 0,
       failures: 0,
       idle_timer: nil,
       keepalive_timer: nil,
       websocket_client: WebSocketClient
     }}
  end

  @impl true
  def format_status(status) when is_map(status) do
    status
    |> Map.update(:state, nil, &redact_status_state/1)
    |> Map.update(:message, nil, &redact_status_message/1)
  end

  @impl true
  def format_status(_reason, [_pdict, state]) do
    [data: [{"State", redact_status_state(state)}]]
  end

  @impl true
  def handle_call({:stream, http_request, acc, fun, opts}, _from, state) do
    now = monotonic_ms()

    cond do
      state.degraded_until_ms != 0 and state.degraded_until_ms > now ->
        error =
          Tool.error(:websocket_degraded, "WebSocket is temporarily degraded.", %{
            retry_after_ms: state.degraded_until_ms - now,
            key: inspect(state.key)
          })

        {:reply, {:error, error, acc}, state}

      true ->
        reply_stream(http_request, acc, fun, opts, state)
    end
  end

  defp reply_stream(http_request, acc, fun, opts, state) do
    client = Keyword.get(opts, :websocket_client, WebSocketClient)
    client_opts = Keyword.get(opts, :websocket_client_opts, [])
    timeout_ms = Keyword.get(opts, :timeout_ms, @default_timeout_ms)
    client_opts = Keyword.put_new(client_opts, :timeout_ms, timeout_ms)

    client_opts =
      case Keyword.get(opts, :stream_activity) do
        fun when is_function(fun, 0) -> Keyword.put(client_opts, :stream_activity, fun)
        _ -> client_opts
      end

    client_opts =
      case Keyword.get(opts, :stream_idle_timeout_ms) do
        nil -> client_opts
        idle_ms -> Keyword.put(client_opts, :stream_idle_timeout_ms, idle_ms)
      end

    stream_started_ms = monotonic_ms()

    with {:ok, state} <- ensure_connected(state, client, http_request, client_opts),
         {:ok, full_payload, wire_payload, continuation} <- build_payload(http_request, state) do
      case stream_wire_payload(
             state,
             client,
             wire_payload,
             full_payload,
             continuation,
             acc,
             fun,
             client_opts,
             opts
           ) do
        {:ok, acc, response, state} ->
          next_state = successful_state(state, full_payload, response, opts)

          case emit_completion_metadata(next_state, response, acc, fun) do
            {:ok, acc} ->
              {:reply, {:ok, acc}, next_state}

            {:error, error, acc} ->
              next_state = mark_degraded(next_state, client, error, opts)
              {:reply, {:error, error, acc}, next_state}
          end

        {:continuation_not_found, state} ->
          state = reset_continuation(state, "previous_response_not_found")
          retry_client_opts = client_opts_with_remaining_timeout(client_opts, stream_started_ms)

          case stream_wire_payload(
                 state,
                 client,
                 full_payload,
                 full_payload,
                 continuation_metadata(false, "previous_response_not_found"),
                 acc,
                 fun,
                 retry_client_opts,
                 opts
               ) do
            {:ok, acc, response, state} ->
              next_state = successful_state(state, full_payload, response, opts)

              case emit_completion_metadata(next_state, response, acc, fun) do
                {:ok, acc} ->
                  {:reply, {:ok, acc}, next_state}

                {:error, error, acc} ->
                  next_state = mark_degraded(next_state, client, error, opts)
                  {:reply, {:error, error, acc}, next_state}
              end

            {:error, error, acc, state} ->
              next_state = mark_degraded(state, client, error, opts)
              {:reply, {:error, error, acc}, next_state}

            {:continuation_not_found, state} ->
              error =
                Tool.error(
                  :provider_http_error,
                  "Provider rejected previous_response_id even after full replay retry.",
                  %{reason: "previous_response_not_found"}
                )

              next_state = mark_degraded(state, client, error, opts)
              {:reply, {:error, error, acc}, next_state}
          end

        {:error, error, acc, state} ->
          next_state = mark_degraded(state, client, error, opts)
          {:reply, {:error, error, acc}, next_state}
      end
    else
      {:error, error} ->
        next_state = mark_degraded(state, client, error, opts)
        {:reply, {:error, error, acc}, next_state}
    end
  end

  defp stream_wire_payload(
         state,
         client,
         wire_payload,
         _full_payload,
         continuation,
         acc,
         fun,
         client_opts,
         _opts
       ) do
    metadata =
      transport_metadata(
        "websocket",
        Map.merge(continuation, %{
          "used_previous_response_id" => Map.has_key?(wire_payload, "previous_response_id"),
          "websocket_key" => inspect(state.key),
          "websocket_stored_previous_response_id" => state.previous_response_id
        })
      )

    guarded_fun = guarded_stream_fun(fun)

    try do
      acc =
        acc
        |> then(&guarded_fun.({:metadata, metadata}, &1))
        |> then(&guarded_fun.({:status, 200}, &1))

      case client.stream(
             state.socket,
             state.initial_buffer,
             wire_payload,
             acc,
             guarded_fun,
             client_opts
           ) do
        {:ok, acc, response} ->
          if Map.has_key?(wire_payload, "previous_response_id") and
               previous_response_not_found?(acc) do
            {:continuation_not_found, %{state | initial_buffer: ""}}
          else
            {:ok, acc, response, %{state | initial_buffer: ""}}
          end

        {:error, error, acc} ->
          {:error, error, acc, state}
      end
    catch
      {@callback_failure_tag, error, failed_acc} ->
        {:error, error, failed_acc, %{state | initial_buffer: ""}}
    end
  end

  defp emit_completion_metadata(state, response, acc, fun) do
    fun = guarded_stream_fun(fun)

    {:ok,
     fun.(
       {:metadata,
        %{
          "websocket_captured_response_id" => response_id_from_stream(response),
          "websocket_stored_previous_response_id" => state.previous_response_id
        }},
       acc
     )}
  catch
    {@callback_failure_tag, error, failed_acc} ->
      {:error, error, failed_acc}
  end

  defp guarded_stream_fun(fun) do
    fn chunk, acc ->
      try do
        fun.(chunk, acc)
      catch
        kind, reason ->
          throw({@callback_failure_tag, stream_callback_error(kind, reason), acc})
      end
    end
  end

  defp stream_callback_error(kind, reason) do
    Tool.error(
      :network,
      "Provider stream callback failed before the stream completed.",
      %{
        reason: "stream_callback_failed",
        exit_kind: inspect(kind),
        exit_reason: safe_inspect(reason),
        continuation_reset_reason: "stream_callback_failed",
        next_actions: ["retry_turn", "inspect_session_lifecycle", "fall_back_to_full_replay"]
      }
    )
  end

  defp successful_state(state, full_payload, response, opts) do
    captured_id = response_id_from_stream(response)

    %{
      state
      | initial_buffer: "",
        previous_response_id: captured_id || state.previous_response_id,
        previous_input: full_payload["input"] || [],
        previous_model: full_payload["model"],
        last_continuation_reset_reason: nil,
        degraded_until_ms: 0,
        failures: 0
    }
    |> schedule_keepalive(opts)
    |> schedule_idle_close(opts)
  end

  defp response_id_from_stream(response) when is_map(response) do
    Map.get(response, :response_id) || Map.get(response, "response_id")
  end

  defp response_id_from_stream(_response), do: nil

  @impl true
  def handle_info(:idle_close, state) do
    close_socket(state)
    {:stop, :normal, %{state | socket: nil, idle_timer: nil, keepalive_timer: nil}}
  end

  @impl true
  def handle_info(:keepalive_ping, %{socket: nil} = state) do
    {:noreply, %{state | keepalive_timer: nil}}
  end

  def handle_info(:keepalive_ping, state) do
    case state.websocket_client.ping(state.socket) do
      :ok ->
        {:noreply, schedule_keepalive(%{state | keepalive_timer: nil}, [])}

      {:error, _reason} ->
        close_socket(state)

        {:noreply,
         state
         |> reset_continuation("keepalive_failed")
         |> Map.merge(%{
           socket: nil,
           initial_buffer: "",
           endpoint: nil,
           headers_fingerprint: nil,
           keepalive_timer: nil
         })}
    end
  end

  @impl true
  def terminate(_reason, state) do
    close_socket(state)
    :ok
  end

  defp ensure_connected(state, client, http_request, opts) do
    endpoint = websocket_endpoint(http_request.url)
    headers_fingerprint = stable_fingerprint(http_request.headers)

    if connected_to?(state, endpoint, headers_fingerprint) do
      {:ok, state}
    else
      reconnect(state, client, endpoint, http_request.headers, headers_fingerprint, opts)
    end
  end

  defp connected_to?(state, endpoint, headers_fingerprint) do
    not is_nil(state.socket) and state.endpoint == endpoint and
      state.headers_fingerprint == headers_fingerprint
  end

  defp reconnect(state, client, endpoint, headers, headers_fingerprint, opts) do
    state =
      state
      |> cancel_idle_timer()
      |> cancel_keepalive_timer()

    close_socket(state)

    case client.connect(endpoint, headers, opts) do
      {:ok, socket, initial_buffer, _handshake} ->
        {:ok,
         state
         |> reset_continuation(reconnect_reset_reason(state, endpoint, headers_fingerprint))
         |> Map.merge(%{
           socket: socket,
           initial_buffer: initial_buffer,
           endpoint: endpoint,
           headers_fingerprint: headers_fingerprint,
           idle_timer: nil,
           keepalive_timer: nil,
           websocket_client: client
         })}

      {:error, error} ->
        {:error, error}
    end
  end

  defp build_payload(%{body: body}, state) do
    with {:ok, decoded} when is_map(decoded) <- Jason.decode(IO.iodata_to_binary(body)) do
      full =
        decoded
        |> Map.delete("stream")
        |> Map.put("type", "response.create")
        |> Map.put("store", false)

      {wire, continuation} = maybe_continue(full, state)
      {:ok, full, wire, continuation}
    else
      _ ->
        {:error,
         Tool.error(:invalid_provider_request, "Could not decode Provider request body.", %{})}
    end
  end

  # Returns `{wire_payload, continuation_metadata}`. The metadata is evidence about the
  # ACTUAL wire payload: `"continuation_attempted"` is true only when the wire payload
  # really carries `previous_response_id` with a delta input. Any reset to the full
  # payload records why in `"continuation_reset_reason"` (string-keyed, ADR 0019).
  defp maybe_continue(full, %{
         previous_response_id: id,
         previous_input: previous,
         previous_model: model
       })
       when is_binary(id) and is_list(previous) do
    current = full["input"] || []

    case {full["model"] == model, suffix_after_prefix(current, previous)} do
      {false, _} ->
        {full, continuation_metadata(false, "model_changed")}

      {true, :error} ->
        {full, continuation_metadata(false, "prefix_mismatch")}

      {true, {:ok, suffix}} ->
        delta = continuation_delta(suffix)

        if delta == [] do
          {full, continuation_metadata(false, "empty_delta")}
        else
          wire =
            full
            |> Map.put("input", delta)
            |> Map.put("previous_response_id", id)

          {wire, continuation_metadata(true, nil)}
        end
    end
  end

  defp maybe_continue(full, %{last_continuation_reset_reason: reason}) when is_binary(reason),
    do: {full, continuation_metadata(false, reason)}

  defp maybe_continue(full, _state),
    do: {full, continuation_metadata(false, "no_previous_response")}

  defp continuation_metadata(attempted?, reset_reason) do
    %{
      "continuation_attempted" => attempted?,
      "continuation_reset_reason" => reset_reason
    }
  end

  defp previous_response_not_found?(%{stream_error: %{error: error}}) when is_map(error) do
    details =
      case Map.get(error, :details) || Map.get(error, "details") do
        details when is_map(details) -> details
        _ -> %{}
      end

    [
      error[:code],
      error["code"],
      error[:type],
      error["type"],
      error[:message],
      error["message"],
      details[:code],
      details["code"],
      details[:type],
      details["type"]
    ]
    |> Enum.any?(fn
      value when is_binary(value) ->
        value =~ ~r/previous[ _-]?response.*not[ _-]?found/i

      _ ->
        false
    end)
  end

  defp previous_response_not_found?(_acc), do: false

  defp client_opts_with_remaining_timeout(client_opts, started_ms) do
    timeout_ms = Keyword.get(client_opts, :timeout_ms, @default_timeout_ms)
    elapsed_ms = max(0, monotonic_ms() - started_ms)
    remaining_ms = max(1, timeout_ms - elapsed_ms)
    Keyword.put(client_opts, :timeout_ms, remaining_ms)
  end

  defp suffix_after_prefix(current, previous) when length(current) >= length(previous) do
    {prefix, suffix} = Enum.split(current, length(previous))
    if prefix == previous, do: {:ok, suffix}, else: :error
  end

  defp suffix_after_prefix(_current, _previous), do: :error

  defp continuation_delta(suffix) do
    Enum.reject(suffix, fn
      %{"type" => "function_call"} -> true
      %{"type" => "reasoning"} -> true
      %{"type" => "message", "role" => "assistant"} -> true
      _ -> false
    end)
  end

  defp mark_degraded(state, client, error, opts) do
    close_socket(%{state | websocket_client: client})

    degraded_ms = Keyword.get(opts, :websocket_degraded_ms, @default_degraded_ms)
    reset_reason = continuation_reset_reason_from_error(error)

    %{
      state
      | socket: nil,
        initial_buffer: "",
        endpoint: nil,
        headers_fingerprint: nil,
        previous_model: nil,
        keepalive_timer: nil,
        degraded_until_ms: monotonic_ms() + degraded_ms,
        failures: state.failures + 1
    }
    |> reset_continuation(reset_reason)
    |> cancel_idle_timer()
    |> cancel_keepalive_timer()
    |> maybe_keep_previous_input(error)
  end

  defp continuation_reset_reason_from_error(%{error: %{details: details}}) when is_map(details) do
    Map.get(details, :continuation_reset_reason) ||
      Map.get(details, "continuation_reset_reason") ||
      "websocket_failed"
  end

  defp continuation_reset_reason_from_error(_error), do: "websocket_failed"

  defp reconnect_reset_reason(%{previous_response_id: nil}, _endpoint, _headers_fingerprint),
    do: nil

  defp reconnect_reset_reason(state, endpoint, headers_fingerprint) do
    cond do
      state.endpoint != endpoint -> "endpoint_changed"
      state.headers_fingerprint != headers_fingerprint -> "headers_changed"
      true -> "websocket_reconnected"
    end
  end

  defp reset_continuation(state, nil), do: state

  defp reset_continuation(state, reason) do
    %{
      state
      | previous_response_id: nil,
        previous_input: nil,
        previous_model: nil,
        last_continuation_reset_reason: reason
    }
  end

  defp schedule_idle_close(state, opts) do
    state = cancel_idle_timer(state)
    idle_ms = Keyword.get(opts, :websocket_idle_ms, @default_idle_ms)

    if is_integer(idle_ms) and idle_ms > 0 do
      %{state | idle_timer: Process.send_after(self(), :idle_close, idle_ms)}
    else
      state
    end
  end

  defp cancel_idle_timer(%{idle_timer: nil} = state), do: state

  defp cancel_idle_timer(%{idle_timer: ref} = state) do
    Process.cancel_timer(ref)
    %{state | idle_timer: nil}
  end

  defp schedule_keepalive(state, opts) do
    state = cancel_keepalive_timer(state)
    keepalive_ms = Keyword.get(opts, :websocket_keepalive_ms, @default_keepalive_ms)

    if is_integer(keepalive_ms) and keepalive_ms > 0 do
      %{state | keepalive_timer: Process.send_after(self(), :keepalive_ping, keepalive_ms)}
    else
      state
    end
  end

  defp cancel_keepalive_timer(%{keepalive_timer: nil} = state), do: state

  defp cancel_keepalive_timer(%{keepalive_timer: ref} = state) do
    Process.cancel_timer(ref)
    %{state | keepalive_timer: nil}
  end

  defp maybe_keep_previous_input(state, _error), do: state

  defp close_socket(%{socket: nil}), do: :ok

  defp close_socket(%{websocket_client: client, socket: socket}) do
    _ = client.close(socket)
    :ok
  end

  defp websocket_endpoint(http_url) do
    uri = URI.parse(http_url)
    scheme = if uri.scheme == "http", do: "ws", else: "wss"
    URI.to_string(%{uri | scheme: scheme})
  end

  defp transport_metadata(active_transport, extra) do
    Map.merge(
      %{
        "transport_preference" => "websocket",
        "active_transport" => active_transport
      },
      extra
    )
  end

  defp monotonic_ms, do: System.monotonic_time(:millisecond)

  defp stable_fingerprint(headers) do
    headers
    |> Enum.map(&normalize_header_fingerprint/1)
    |> Enum.sort()
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  # OAuth access tokens rotate between Turns; fingerprinting the bearer value would
  # force a reconnect and discard connection-local continuation state.
  defp normalize_header_fingerprint({"authorization", _value}),
    do: {"authorization", "<bearer>"}

  defp normalize_header_fingerprint({"Authorization", _value}),
    do: {"authorization", "<bearer>"}

  defp normalize_header_fingerprint({name, value}),
    do: {String.downcase(to_string(name)), to_string(value)}

  defp redact_status_state(%{} = state) do
    %{
      key: safe_inspect(Map.get(state, :key)),
      socket_present?: not is_nil(Map.get(state, :socket)),
      endpoint: safe_endpoint(Map.get(state, :endpoint)),
      headers_fingerprint_present?: not is_nil(Map.get(state, :headers_fingerprint)),
      previous_response_id: response_id_presence(Map.get(state, :previous_response_id)),
      previous_input_count: count_list(Map.get(state, :previous_input)),
      previous_model: Map.get(state, :previous_model),
      last_continuation_reset_reason: Map.get(state, :last_continuation_reset_reason),
      degraded?: degraded?(state),
      failures: Map.get(state, :failures, 0),
      idle_timer_present?: not is_nil(Map.get(state, :idle_timer)),
      keepalive_timer_present?: not is_nil(Map.get(state, :keepalive_timer)),
      websocket_client: safe_inspect(Map.get(state, :websocket_client))
    }
  end

  defp redact_status_state(state), do: safe_inspect(state)

  defp redact_status_message({:stream, http_request, _acc, fun, opts}) do
    %{
      type: :stream,
      http_request: redact_http_request(http_request),
      acc: :redacted,
      callback: function_summary(fun),
      opts: redact_opts(opts)
    }
  end

  defp redact_status_message(message), do: safe_inspect(message)

  defp redact_http_request(%{} = request) do
    %{
      method: Map.get(request, :method),
      url: safe_endpoint(Map.get(request, :url)),
      headers: redact_headers(Map.get(request, :headers, [])),
      body: body_summary(Map.get(request, :body))
    }
  end

  defp redact_http_request(request), do: safe_inspect(request)

  defp redact_headers(headers) when is_list(headers) do
    Enum.map(headers, fn
      {name, value} ->
        name = to_string(name)
        value = if sensitive_header?(name), do: "<redacted>", else: safe_inspect(value)
        {name, value}

      header ->
        safe_inspect(header)
    end)
  end

  defp redact_headers(headers), do: safe_inspect(headers)

  defp sensitive_header?(name) do
    name
    |> String.downcase()
    |> then(&(&1 in ["authorization", "chatgpt-account-id", "cookie", "set-cookie", "x-api-key"]))
  end

  defp body_summary(nil), do: nil

  defp body_summary(body) do
    binary = IO.iodata_to_binary(body)
    %{redacted?: true, bytes: byte_size(binary)}
  rescue
    _ -> %{redacted?: true, bytes: :unknown}
  end

  defp redact_opts(opts) when is_list(opts) do
    opts
    |> Keyword.keys()
    |> Enum.uniq()
    |> Enum.map(&to_string/1)
    |> Enum.sort()
  end

  defp redact_opts(opts), do: safe_inspect(opts)

  defp function_summary(fun) when is_function(fun), do: "#Function<redacted>"
  defp function_summary(other), do: safe_inspect(other)

  defp response_id_presence(nil), do: nil
  defp response_id_presence(id) when is_binary(id), do: "<response_id_present>"
  defp response_id_presence(_id), do: "<non_string_response_id_present>"

  defp count_list(list) when is_list(list), do: length(list)
  defp count_list(_other), do: nil

  defp degraded?(%{degraded_until_ms: degraded_until_ms})
       when is_integer(degraded_until_ms) and degraded_until_ms > 0 do
    degraded_until_ms > monotonic_ms()
  end

  defp degraded?(_state), do: false

  defp safe_endpoint(endpoint) when is_binary(endpoint) do
    endpoint
    |> String.replace(~r/(authorization|access_token|api_key|token)=([^&]+)/i, "\\1=<redacted>")
    |> String.replace(~r/(chatgpt-account-id)=([^&]+)/i, "\\1=<redacted>")
  end

  defp safe_endpoint(endpoint), do: endpoint

  defp safe_inspect(value) do
    value
    |> inspect(limit: 20, printable_limit: 240)
    |> redact_text()
    |> truncate(300)
  end

  defp redact_text(text) do
    text
    |> String.replace(~r/Bearer\s+[A-Za-z0-9._~+\/=-]+/, "Bearer <redacted>")
    |> String.replace(
      ~r/(authorization|access_token|api_key|token|chatgpt-account-id)([\"'\s:=]+)([^,\"'\s}\]]+)/i,
      "\\1\\2<redacted>"
    )
  end

  defp truncate(text, max) when byte_size(text) <= max, do: text
  defp truncate(text, max), do: binary_part(text, 0, max) <> "...[truncated]"
end
