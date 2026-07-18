defmodule Pixir.ProviderTransportPolicyTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Pixir.{Auth, Event, Provider, Tool}
  alias Pixir.Provider.{Connection, TransportError, TransportPolicy}

  setup do
    name = :"auth_#{System.unique_integer([:positive])}"

    path =
      Path.join(System.tmp_dir!(), "pixir-transport-#{System.unique_integer([:positive])}.json")

    {:ok, _} =
      Auth.start_link(
        name: name,
        store_path: path,
        env_api_key: "sk-test",
        oauth: __MODULE__.NoOAuth
      )

    on_exit(fn -> File.rm_rf!(path) end)
    %{auth: name}
  end

  defmodule NoOAuth do
    def refresh_skew_ms, do: 60_000
  end

  defmodule FailingWebSocket do
    def connect(endpoint, _headers, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:websocket_connect, endpoint})

      {:error,
       Tool.error(:websocket_connect_failed, "Could not open TLS connection.", %{
         reason: "synthetic"
       })}
    end

    def stream(_socket, _initial_buffer, _payload, acc, _fun, _opts), do: {:ok, acc, %{}}
    def close(_socket), do: :ok
    def ping(_socket), do: :ok
  end

  defmodule SuccessfulWebSocket do
    def connect(endpoint, _headers, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:websocket_connect, endpoint})
      {:ok, {:fake_socket, Keyword.fetch!(opts, :test_pid)}, "", %{status: 101}}
    end

    def stream(_socket, _initial_buffer, payload, acc, fun, opts) do
      test_pid = Keyword.fetch!(opts, :test_pid)
      ids = Keyword.fetch!(opts, :ids)
      id = Agent.get_and_update(ids, fn [next | rest] -> {next, rest} end)
      send(test_pid, {:websocket_payload, payload})

      acc = fun.({:data, sse(%{type: "response.output_text.delta", delta: "ok"})}, acc)

      acc =
        fun.(
          {:data,
           sse(%{
             type: "response.completed",
             response: %{
               id: id,
               usage: %{input_tokens: 16, input_tokens_details: %{cached_tokens: 0}}
             }
           })},
          acc
        )

      {:ok, acc, %{response_id: id}}
    end

    def close(_socket), do: :ok

    def ping({:fake_socket, test_pid} = _socket) do
      send(test_pid, {:websocket_ping, self()})
      :ok
    end

    defp sse(map), do: "data: " <> Jason.encode!(map) <> "\n\n"
  end

  defmodule EventCaptureWebSocket do
    alias Pixir.Provider.WebSocketClient

    def connect(endpoint, _headers, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:websocket_connect, endpoint})
      {:ok, {:fake_socket, Keyword.fetch!(opts, :test_pid)}, "", %{status: 101}}
    end

    def stream(_socket, _initial_buffer, payload, acc, fun, opts) do
      test_pid = Keyword.fetch!(opts, :test_pid)
      ids = Keyword.fetch!(opts, :ids)
      id = Agent.get_and_update(ids, fn [next | rest] -> {next, rest} end)
      send(test_pid, {:websocket_payload, payload})

      events = [
        %{
          "type" => "response.in_progress",
          "response" => %{"id" => id, "status" => "in_progress"}
        },
        %{"type" => "response.output_text.delta", "response_id" => id, "delta" => "ok"},
        %{
          "type" => "response.completed",
          "response" => %{
            "id" => id,
            "usage" => %{input_tokens: 16, input_tokens_details: %{cached_tokens: 0}}
          }
        }
      ]

      acc =
        Enum.reduce(events, acc, fn event, acc ->
          fun.({:data, "data: " <> Jason.encode!(event) <> "\n\n"}, acc)
        end)

      response =
        Enum.reduce(events, %{response_id: nil}, fn event, resp ->
          case WebSocketClient.response_id_from_event(event) do
            nil -> resp
            captured -> %{resp | response_id: captured}
          end
        end)

      {:ok, acc, response}
    end

    def close(_socket), do: :ok
    def ping(_socket), do: :ok
  end

  defmodule KeepaliveFailingWebSocket do
    def connect(endpoint, _headers, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:websocket_connect, endpoint})
      {:ok, {:fake_socket, Keyword.fetch!(opts, :test_pid)}, "", %{status: 101}}
    end

    def stream(_socket, _initial_buffer, payload, acc, fun, opts) do
      test_pid = Keyword.fetch!(opts, :test_pid)
      ids = Keyword.fetch!(opts, :ids)
      id = Agent.get_and_update(ids, fn [next | rest] -> {next, rest} end)
      send(test_pid, {:websocket_payload, payload})

      acc = fun.({:data, sse(%{type: "response.output_text.delta", delta: "ok"})}, acc)

      acc =
        fun.(
          {:data,
           sse(%{
             type: "response.completed",
             response: %{
               id: id,
               usage: %{input_tokens: 16, input_tokens_details: %{cached_tokens: 0}}
             }
           })},
          acc
        )

      {:ok, acc, %{response_id: id}}
    end

    def close(_socket), do: :ok

    def ping({:fake_socket, test_pid} = _socket) do
      send(test_pid, {:websocket_ping_failed, self()})
      {:error, :closed}
    end

    defp sse(map), do: "data: " <> Jason.encode!(map) <> "\n\n"
  end

  defmodule FailedResponseWebSocket do
    def connect(_endpoint, _headers, opts),
      do: {:ok, {:fake_socket, Keyword.fetch!(opts, :test_pid)}, "", %{status: 101}}

    def stream(_socket, _initial_buffer, _payload, acc, fun, _opts) do
      acc =
        fun.(
          {:data,
           sse(%{
             type: "response.failed",
             response: %{
               error: %{
                 code: "server_error",
                 message: "generation failed",
                 type: "server_error"
               }
             }
           })},
          acc
        )

      {:ok, acc, %{response_id: nil}}
    end

    def close(_socket), do: :ok
    def ping(_socket), do: :ok

    defp sse(map), do: "data: " <> Jason.encode!(map) <> "\n\n"
  end

  defmodule OverflowWebSocket do
    def connect(_endpoint, _headers, opts),
      do: {:ok, {:fake_socket, Keyword.fetch!(opts, :test_pid)}, "", %{status: 101}}

    def stream(_socket, _initial_buffer, _payload, acc, fun, _opts) do
      acc =
        fun.(
          {:data,
           sse(%{
             type: "response.failed",
             response: %{
               error: %{
                 code: "context_length_exceeded",
                 message: "Your input exceeds the context window of this model.",
                 type: "invalid_request_error"
               }
             }
           })},
          acc
        )

      {:ok, acc, %{response_id: nil}}
    end

    def close(_socket), do: :ok
    def ping(_socket), do: :ok

    defp sse(map), do: "data: " <> Jason.encode!(map) <> "\n\n"
  end

  defmodule FlakyContinuationWebSocket do
    # Succeeds or fails per scripted step (`{:ok, id}` | `:closed`), so a test can
    # establish continuation state on call 1 and force a socket loss on call 2.
    def connect(_endpoint, _headers, opts),
      do: {:ok, {:fake_socket, Keyword.fetch!(opts, :test_pid)}, "", %{status: 101}}

    def stream(_socket, _initial_buffer, payload, acc, fun, opts) do
      test_pid = Keyword.fetch!(opts, :test_pid)
      send(test_pid, {:websocket_payload, payload})

      case Agent.get_and_update(Keyword.fetch!(opts, :scripts), fn [next | rest] ->
             {next, rest}
           end) do
        {:ok, id} ->
          acc = fun.({:data, sse(%{type: "response.output_text.delta", delta: "ok"})}, acc)

          acc =
            fun.(
              {:data,
               sse(%{
                 type: "response.completed",
                 response: %{id: id, usage: %{input_tokens: 16}}
               })},
              acc
            )

          {:ok, acc, %{response_id: id}}

        :closed ->
          {:error, Tool.error(:websocket_closed, "Socket closed mid-stream.", %{}), acc}
      end
    end

    def close(_socket), do: :ok
    def ping(_socket), do: :ok

    defp sse(map), do: "data: " <> Jason.encode!(map) <> "\n\n"
  end

  defmodule MissingPreviousResponseWebSocket do
    def connect(_endpoint, _headers, opts),
      do: {:ok, {:fake_socket, Keyword.fetch!(opts, :test_pid)}, "", %{status: 101}}

    def stream(_socket, _initial_buffer, payload, acc, fun, opts) do
      test_pid = Keyword.fetch!(opts, :test_pid)
      send(test_pid, {:websocket_payload, payload})

      case Agent.get_and_update(Keyword.fetch!(opts, :scripts), fn [next | rest] ->
             {next, rest}
           end) do
        {:ok, id, text} ->
          acc = fun.({:data, sse(%{type: "response.output_text.delta", delta: text})}, acc)

          acc =
            fun.(
              {:data,
               sse(%{
                 type: "response.completed",
                 response: %{id: id, usage: %{input_tokens: 16}}
               })},
              acc
            )

          {:ok, acc, %{response_id: id}}

        :previous_response_not_found ->
          acc =
            fun.(
              {:data,
               sse(%{
                 type: "response.failed",
                 response: %{
                   error: %{
                     code: "previous_response_not_found",
                     message: "Previous response with id 'resp_1' not found.",
                     type: "invalid_request_error"
                   }
                 }
               })},
              acc
            )

          {:ok, acc, %{response_id: nil}}
      end
    end

    def close(_socket), do: :ok
    def ping(_socket), do: :ok

    defp sse(map), do: "data: " <> Jason.encode!(map) <> "\n\n"
  end

  defmodule TimeoutAfterPayloadWebSocket do
    def connect(_endpoint, _headers, opts),
      do: {:ok, {:fake_socket, Keyword.fetch!(opts, :test_pid)}, "", %{status: 101}}

    def stream(_socket, _initial_buffer, payload, acc, fun, opts) do
      test_pid = Keyword.fetch!(opts, :test_pid)
      send(test_pid, {:websocket_payload, payload})

      case Agent.get_and_update(Keyword.fetch!(opts, :scripts), fn [next | rest] ->
             {next, rest}
           end) do
        {:ok, id, text} ->
          acc = fun.({:data, sse(%{type: "response.output_text.delta", delta: text})}, acc)

          acc =
            fun.(
              {:data,
               sse(%{
                 type: "response.completed",
                 response: %{id: id, usage: %{input_tokens: 16}}
               })},
              acc
            )

          {:ok, acc, %{response_id: id}}

        :hang ->
          Process.sleep(:infinity)
          {:ok, acc, %{response_id: nil}}
      end
    end

    def close(_socket), do: :ok
    def ping(_socket), do: :ok

    defp sse(map), do: "data: " <> Jason.encode!(map) <> "\n\n"
  end

  defmodule ExplodingWebSocket do
    def connect(_endpoint, _headers, _opts), do: {:ok, :fake_socket, "", %{status: 101}}

    def stream(_socket, _initial_buffer, _payload, _acc, _fun, _opts) do
      raise "synthetic websocket crash"
    end

    def close(_socket), do: :ok
    def ping(_socket), do: :ok
  end

  defmodule HeaderRejectingWebSocket do
    def connect(_endpoint, [{"never-matches", _value}], _opts),
      do: {:ok, :unreachable, "", %{status: 101}}

    def stream(_socket, _initial_buffer, _payload, acc, _fun, _opts), do: {:ok, acc, %{}}
    def close(_socket), do: :ok
    def ping(_socket), do: :ok
  end

  defmodule KillingWebSocket do
    def connect(_endpoint, _headers, _opts), do: {:ok, :fake_socket, "", %{status: 101}}

    def stream(_socket, _initial_buffer, _payload, _acc, _fun, _opts),
      do: Process.exit(self(), :kill)

    def close(_socket), do: :ok
    def ping(_socket), do: :ok
  end

  defmodule CallbackDeltaWebSocket do
    def connect(_endpoint, _headers, opts),
      do: {:ok, {:fake_socket, Keyword.fetch!(opts, :test_pid)}, "", %{status: 101}}

    def stream(_socket, _initial_buffer, payload, acc, fun, opts) do
      test_pid = Keyword.fetch!(opts, :test_pid)
      send(test_pid, {:websocket_payload, payload})
      acc = fun.({:data, sse(%{type: "response.output_text.delta", delta: "partial"})}, acc)
      {:ok, acc, %{response_id: "resp_callback_should_not_store"}}
    end

    def close(_socket), do: :ok
    def ping(_socket), do: :ok

    defp sse(map), do: "data: " <> Jason.encode!(map) <> "\n\n"
  end

  defp http_success_transport(test_pid) do
    fn http_request, acc, fun ->
      send(test_pid, {:http_request, http_request})
      acc = fun.({:status, 200}, acc)
      acc = fun.({:data, sse(%{type: "response.output_text.delta", delta: "http"})}, acc)

      acc =
        fun.(
          {:data, sse(%{type: "response.completed", response: %{usage: %{input_tokens: 8}}})},
          acc
        )

      {:ok, acc}
    end
  end

  defp exploding_http_transport(test_pid) do
    fn _http_request, acc, _fun ->
      send(test_pid, :unexpected_http_fallback)
      {:ok, acc}
    end
  end

  defp sse(map), do: "data: " <> Jason.encode!(map) <> "\n\n"

  defp sensitive_http_request(body) do
    %{
      method: :post,
      url:
        "https://chatgpt.com/backend-api/codex/responses?access_token=query-secret&chatgpt-account-id=acct-query-secret",
      headers: [
        {"content-type", "application/json"},
        {"authorization", "Bearer secret-token"},
        {"chatgpt-account-id", "acct-secret"}
      ],
      body: Jason.encode!(body)
    }
  end

  defp body_with_inputs(texts) do
    %{
      "model" => "gpt-5.5",
      "input" =>
        Enum.map(texts, fn text ->
          %{"role" => "user", "content" => [%{"type" => "input_text", "text" => text}]}
        end)
    }
  end

  test "auto falls back to HTTP/SSE and preserves prompt_cache_key", %{auth: auth} do
    assert {:ok, result} =
             Provider.stream(%{history: [], prompt_cache_key: "px1:test"},
               auth: auth,
               provider_transport: :auto,
               websocket_client: FailingWebSocket,
               websocket_client_opts: [test_pid: self()],
               http_transport: http_success_transport(self()),
               max_retries: 0
             )

    assert result.text == "http"
    assert result.provider_metadata["active_transport"] == "http_sse"
    assert result.provider_metadata["fallback_reason"] == "websocket_connect_failed"

    assert_received {:websocket_connect, "wss://chatgpt.com/backend-api/codex/responses"}
    assert_received {:http_request, %{body: body}}
    assert Jason.decode!(body)["prompt_cache_key"] == "px1:test"
  end

  test "auto retries WebSocket after the degraded window expires", %{auth: auth} do
    key = {:reversible_fallback, make_ref()}

    assert {:ok, first} =
             Provider.stream(%{history: [], prompt_cache_key: "px1:test"},
               auth: auth,
               provider_transport: :auto,
               provider_connection_key: key,
               websocket_client: FailingWebSocket,
               websocket_client_opts: [test_pid: self()],
               websocket_degraded_ms: 1,
               http_transport: http_success_transport(self()),
               max_retries: 0
             )

    assert first.text == "http"
    assert first.provider_metadata["active_transport"] == "http_sse"
    assert first.provider_metadata["fallback_reason"] == "websocket_connect_failed"

    Process.sleep(5)
    {:ok, ids} = Agent.start_link(fn -> ["resp_1"] end)

    assert {:ok, second} =
             Provider.stream(%{history: [], prompt_cache_key: "px1:test"},
               auth: auth,
               provider_transport: :auto,
               provider_connection_key: key,
               websocket_client: SuccessfulWebSocket,
               websocket_client_opts: [test_pid: self(), ids: ids],
               http_transport: exploding_http_transport(self()),
               max_retries: 0
             )

    assert second.text == "ok"
    assert second.provider_metadata["active_transport"] == "websocket"
    assert_received {:websocket_payload, second_payload}
    assert second_payload["prompt_cache_key"] == "px1:test"
    refute_received :unexpected_http_fallback
  end

  test "provider response.failed is not hidden behind HTTP fallback", %{auth: auth} do
    assert {:error, %{error: %{kind: :provider_http_error}}} =
             Provider.stream(%{history: []},
               auth: auth,
               provider_transport: :auto,
               provider_connection_key: {:failed_response, make_ref()},
               websocket_client: FailedResponseWebSocket,
               websocket_client_opts: [test_pid: self()],
               http_transport: exploding_http_transport(self()),
               max_retries: 0
             )

    refute_received :unexpected_http_fallback
  end

  test "in-band overflow rejection over WebSocket gets kind :context_overflow", %{auth: auth} do
    assert {:error, %{error: %{kind: :context_overflow}}} =
             Provider.stream(%{history: []},
               auth: auth,
               provider_transport: :auto,
               provider_connection_key: {:overflow, make_ref()},
               websocket_client: OverflowWebSocket,
               websocket_client_opts: [test_pid: self()],
               http_transport: exploding_http_transport(self()),
               max_retries: 0
             )

    refute_received :unexpected_http_fallback
  end

  test "connection stream call has no hidden absolute deadline by default" do
    assert {:ok, :infinity} =
             Connection.stream_call_timeout(timeout_ms: 30_000, stream_idle_timeout_ms: 180_000)

    assert Connection.stream_call_timeout(websocket_call_timeout_ms: 25) == {:ok, 25}

    assert {:error, %{error: %{kind: :invalid_args}}} =
             Connection.stream_call_timeout(websocket_call_timeout_ms: -1)
  end

  test "a frozen transport policy does not reread application config" do
    traced = self()
    tracer = spawn_link(fn -> forward_application_traces(traced) end)

    :erlang.trace(traced, true, [:call, {:tracer, tracer}])
    assert :erlang.trace_pattern({Application, :get_env, 3}, true, []) == 1

    on_exit(fn ->
      :erlang.trace_pattern({Application, :get_env, 3}, false, [])
      Process.exit(tracer, :kill)
    end)

    request = %{method: :post, url: "https://example.invalid", headers: [], body: "{}"}
    reducer = fn _chunk, acc -> acc end
    http_transport = fn _request, acc, _fun -> {:ok, acc} end

    assert {:ok, %{}} =
             TransportPolicy.stream(request, %{}, reducer,
               provider_transport: :http_sse,
               http_transport: http_transport
             )

    delivered = :erlang.trace_delivered(traced)
    assert_receive {:trace_delivered, ^traced, ^delivered}

    refute_receive {:application_get_env, [:pixir, :provider_transport, :auto]}
  end

  defp forward_application_traces(test) do
    receive do
      {:trace, _pid, :call, {Application, :get_env, args}} ->
        send(test, {:application_get_env, args})
        forward_application_traces(test)

      _message ->
        forward_application_traces(test)
    end
  end

  test "connection status formatter redacts stream requests and provider auth" do
    status =
      Connection.format_status(%{
        state: %{
          key: {:redaction, :status},
          socket: :fake_socket,
          endpoint:
            "wss://HOST-SECRET.invalid/PATH-SECRET?access_token=query-secret&chatgpt-account-id=acct-query-secret",
          headers_fingerprint: "fingerprint",
          previous_response_id: "resp_secret",
          previous_input: [%{"text" => "secret previous input"}],
          previous_model: "gpt-5.5",
          last_continuation_reset_reason: nil,
          degraded_until_ms: 0,
          failures: 0,
          idle_timer: make_ref(),
          keepalive_timer: nil,
          websocket_client: SuccessfulWebSocket
        },
        message:
          {:stream, sensitive_http_request(body_with_inputs(["secret prompt body"])),
           %{text: "secret acc"}, fn _chunk, acc -> acc end,
           [websocket_client_opts: [api_key: "secret option"], on_delta: fn -> :ok end]}
      })

    rendered = inspect(status)
    refute rendered =~ "secret-token"
    refute rendered =~ "Bearer secret"
    refute rendered =~ "acct-secret"
    refute rendered =~ "acct-query-secret"
    refute rendered =~ "query-secret"
    refute rendered =~ "HOST-SECRET"
    refute rendered =~ "PATH-SECRET"
    refute rendered =~ "secret prompt body"
    refute rendered =~ "secret acc"
    refute rendered =~ "resp_secret"
    assert rendered =~ "<redacted>"
    assert rendered =~ "redacted?"
  end

  test "connection client crashes return bounded errors without logging the request" do
    key = {:redacted_crash_report, make_ref()}
    request = sensitive_http_request(body_with_inputs(["secret crash prompt"]))
    parent = self()

    log =
      capture_log(fn ->
        send(
          parent,
          {:exploding_websocket_result,
           Connection.stream(key, request, %{}, fn _chunk, acc -> acc end,
             websocket_client: ExplodingWebSocket
           )}
        )
      end)

    assert_receive {:exploding_websocket_result,
                    {:error,
                     %{error: %{kind: :network, details: %{reason: :transport_failure}}} = error,
                     %{}}}

    refute inspect(error) =~ "synthetic websocket crash"
    refute log =~ "secret-token"
    refute log =~ "Bearer secret"
    refute log =~ "acct-secret"
    refute log =~ "acct-query-secret"
    refute log =~ "query-secret"
    refute log =~ "secret crash prompt"
  end

  test "connection contains function-clause failures from authenticated WebSocket connect" do
    request = sensitive_http_request(body_with_inputs(["secret connect prompt"]))

    assert {:error, %{error: %{kind: :network, details: %{reason: :function_clause}}} = error,
            %{}} =
             Connection.stream(
               {:redacted_connect_failure, make_ref()},
               request,
               %{},
               fn _chunk, acc -> acc end,
               websocket_client: HeaderRejectingWebSocket
             )

    rendered = inspect(error)
    refute rendered =~ "secret-token"
    refute rendered =~ "Bearer secret"
    refute rendered =~ "acct-secret"
    refute rendered =~ "secret connect prompt"
  end

  test "direct Connection callers receive a bounded error when the server dies" do
    request = sensitive_http_request(body_with_inputs(["secret killed prompt"]))

    assert {:error,
            %{error: %{kind: :network, details: %{reason: :transport_process_exited}}} = error,
            %{}} =
             Connection.stream(
               {:killed_connection, make_ref()},
               request,
               %{},
               fn _chunk, acc -> acc end,
               websocket_client: KillingWebSocket
             )

    rendered = inspect(error)
    refute rendered =~ "secret-token"
    refute rendered =~ "Bearer secret"
    refute rendered =~ "acct-secret"
    refute rendered =~ "secret killed prompt"
  end

  test "connection status bounds fabricated non-binary endpoints" do
    status =
      Connection.format_status(%{
        state: %{
          key: :fabricated_endpoint,
          socket: nil,
          endpoint: %{secret: "NON_BINARY_ENDPOINT_SECRET"},
          headers_fingerprint: nil,
          previous_response_id: nil,
          previous_input: [],
          previous_model: nil,
          last_continuation_reset_reason: nil,
          degraded_until_ms: 0,
          failures: 0,
          idle_timer: nil,
          keepalive_timer: nil,
          websocket_client: SuccessfulWebSocket
        }
      })

    rendered = inspect(status)
    assert rendered =~ "<configured_endpoint>"
    refute rendered =~ "NON_BINARY_ENDPOINT_SECRET"
  end

  test "transport projection drops raw WebSocket handshake lines" do
    sentinel = "WEBSOCKET_STATUS_LINE_SECRET"

    projected =
      TransportError.project(
        Tool.error(:websocket_handshake_failed, "raw #{sentinel}", %{
          status: 401,
          status_line: "HTTP/1.1 401 #{sentinel}",
          endpoint: "wss://#{sentinel}.invalid"
        })
      )

    assert %{error: %{kind: :websocket_handshake_failed, details: %{status: 401}}} = projected
    refute inspect(projected) =~ sentinel
  end

  test "transport projection preserves only allowlisted recovery context" do
    sentinel = "UNTRUSTED_RECOVERY_SECRET"

    projected =
      TransportError.project(
        Tool.error(:network, "raw #{sentinel}", %{
          reason: "stream_callback_failed",
          exit_kind: :throw,
          exit_reason: :badarg,
          continuation_reset_reason: "stream_callback_failed",
          next_actions: ["retry_turn", sentinel],
          key: sentinel
        })
      )

    assert %{
             error: %{
               kind: :network,
               details: %{
                 reason: :stream_callback_failed,
                 exit_kind: :throw,
                 exit_reason: :badarg,
                 continuation_reset_reason: "stream_callback_failed",
                 next_actions: ["retry_turn"]
               }
             }
           } = projected

    refute inspect(projected) =~ sentinel
  end

  test "stream callback failure returns structured error and resets continuation" do
    key = {:callback_failure_reset, make_ref()}
    {:ok, ids} = Agent.start_link(fn -> ["resp_1", "resp_2"] end)
    request = sensitive_http_request(body_with_inputs(["first"]))

    assert {:ok, _acc} =
             Connection.stream(key, request, %{}, fn _chunk, acc -> acc end,
               websocket_client: SuccessfulWebSocket,
               websocket_client_opts: [test_pid: self(), ids: ids],
               websocket_degraded_ms: 1
             )

    assert_received {:websocket_payload, first_payload}
    refute Map.has_key?(first_payload, "previous_response_id")

    failing_fun = fn
      {:metadata, _metadata}, acc -> acc
      {:status, _status}, acc -> acc
      {:data, _data}, _acc -> exit({:noproc, {GenServer, :call, [:dead_session]}})
    end

    continued = sensitive_http_request(body_with_inputs(["first", "second"]))

    assert {:error,
            %{
              error: %{
                kind: :network,
                details: %{
                  reason: "stream_callback_failed",
                  exit_kind: :exit,
                  exit_reason: :transport_failure,
                  continuation_reset_reason: "stream_callback_failed"
                }
              }
            }, %{}} =
             Connection.stream(key, continued, %{}, failing_fun,
               websocket_client: CallbackDeltaWebSocket,
               websocket_client_opts: [test_pid: self()],
               websocket_degraded_ms: 1
             )

    assert_received {:websocket_payload, attempted_payload}
    assert attempted_payload["previous_response_id"] == "resp_1"

    Process.sleep(5)

    after_failure = sensitive_http_request(body_with_inputs(["first", "second", "third"]))

    assert {:ok, _acc} =
             Connection.stream(key, after_failure, %{}, fn _chunk, acc -> acc end,
               websocket_client: SuccessfulWebSocket,
               websocket_client_opts: [test_pid: self(), ids: ids],
               websocket_degraded_ms: 1
             )

    assert_received {:websocket_payload, after_failure_payload}
    refute Map.has_key?(after_failure_payload, "previous_response_id")
  end

  test "same WebSocket connection sends late delta with previous_response_id", %{auth: auth} do
    {:ok, ids} = Agent.start_link(fn -> ["resp_1", "resp_2"] end)
    key = {:continuation, make_ref()}

    assert {:ok, %{text: "ok"}} =
             Provider.stream(
               %{
                 history: [Event.user_message("s", "first")],
                 prompt_cache_key: "px1:family"
               },
               auth: auth,
               provider_transport: :websocket,
               provider_connection_key: key,
               websocket_client: SuccessfulWebSocket,
               websocket_client_opts: [test_pid: self(), ids: ids],
               max_retries: 0
             )

    assert_received {:websocket_payload, first_payload}
    refute Map.has_key?(first_payload, "previous_response_id")
    assert first_payload["prompt_cache_key"] == "px1:family"
    assert first_payload["store"] == false

    history = [
      Event.user_message("s", "first"),
      Event.assistant_message("s", "ok"),
      Event.user_message("s", "second")
    ]

    assert {:ok, %{text: "ok"}} =
             Provider.stream(
               %{history: history, prompt_cache_key: "px1:family"},
               auth: auth,
               provider_transport: :websocket,
               provider_connection_key: key,
               websocket_client: SuccessfulWebSocket,
               websocket_client_opts: [test_pid: self(), ids: ids],
               max_retries: 0
             )

    assert_received {:websocket_payload, second_payload}
    assert second_payload["previous_response_id"] == "resp_1"
    assert second_payload["prompt_cache_key"] == "px1:family"
    assert second_payload["store"] == false

    assert [
             %{
               "role" => "user",
               "content" => [%{"type" => "input_text", "text" => "second"}]
             }
           ] = second_payload["input"]
  end

  test "same WebSocket connection sends keepalive between turns", %{auth: auth} do
    {:ok, ids} = Agent.start_link(fn -> ["resp_1", "resp_2"] end)
    key = {:keepalive_continuation, make_ref()}

    assert {:ok, %{text: "ok"}} =
             Provider.stream(
               %{
                 history: [Event.user_message("s", "first")],
                 prompt_cache_key: "px1:family"
               },
               auth: auth,
               provider_transport: :websocket,
               provider_connection_key: key,
               websocket_client: SuccessfulWebSocket,
               websocket_client_opts: [test_pid: self(), ids: ids],
               websocket_keepalive_ms: 10,
               max_retries: 0
             )

    assert_received {:websocket_payload, first_payload}
    refute Map.has_key?(first_payload, "previous_response_id")
    assert_receive {:websocket_ping, _connection_pid}, 200

    history = [
      Event.user_message("s", "first"),
      Event.assistant_message("s", "ok"),
      Event.user_message("s", "second")
    ]

    assert {:ok, %{text: "ok"}} =
             Provider.stream(
               %{history: history, prompt_cache_key: "px1:family"},
               auth: auth,
               provider_transport: :websocket,
               provider_connection_key: key,
               websocket_client: SuccessfulWebSocket,
               websocket_client_opts: [test_pid: self(), ids: ids],
               websocket_keepalive_ms: 10,
               max_retries: 0
             )

    assert_received {:websocket_payload, second_payload}
    assert second_payload["previous_response_id"] == "resp_1"
  end

  test "keepalive failure reports a specific continuation reset reason", %{auth: auth} do
    {:ok, ids} = Agent.start_link(fn -> ["resp_1", "resp_2"] end)
    key = {:keepalive_failure, make_ref()}

    assert {:ok, %{text: "ok"}} =
             Provider.stream(
               %{
                 history: [Event.user_message("s", "first")],
                 prompt_cache_key: "px1:family"
               },
               auth: auth,
               provider_transport: :websocket,
               provider_connection_key: key,
               websocket_client: KeepaliveFailingWebSocket,
               websocket_client_opts: [test_pid: self(), ids: ids],
               websocket_keepalive_ms: 10,
               max_retries: 0
             )

    assert_received {:websocket_payload, first_payload}
    refute Map.has_key?(first_payload, "previous_response_id")
    assert_receive {:websocket_ping_failed, _connection_pid}, 200

    history = [
      Event.user_message("s", "first"),
      Event.assistant_message("s", "ok"),
      Event.user_message("s", "second")
    ]

    assert {:ok, %{text: "ok"} = result} =
             Provider.stream(
               %{history: history, prompt_cache_key: "px1:family"},
               auth: auth,
               provider_transport: :websocket,
               provider_connection_key: key,
               websocket_client: KeepaliveFailingWebSocket,
               websocket_client_opts: [test_pid: self(), ids: ids],
               websocket_keepalive_ms: 10,
               max_retries: 0
             )

    assert_received {:websocket_payload, second_payload}
    refute Map.has_key?(second_payload, "previous_response_id")
    assert result.provider_metadata["continuation_reset_reason"] == "keepalive_failed"
    assert result.provider_metadata["used_previous_response_id"] == false
  end

  test "same connection does not continue across model changes", %{auth: auth} do
    {:ok, ids} = Agent.start_link(fn -> ["resp_1", "resp_2"] end)
    key = {:model_switch, make_ref()}

    assert {:ok, %{text: "ok"}} =
             Provider.stream(
               %{
                 model: "gpt-5.5",
                 history: [Event.user_message("s", "first")]
               },
               auth: auth,
               provider_transport: :websocket,
               provider_connection_key: key,
               websocket_client: SuccessfulWebSocket,
               websocket_client_opts: [test_pid: self(), ids: ids],
               max_retries: 0
             )

    assert_received {:websocket_payload, first_payload}
    assert first_payload["model"] == "gpt-5.5"
    refute Map.has_key?(first_payload, "previous_response_id")

    history = [
      Event.user_message("s", "first"),
      Event.assistant_message("s", "ok"),
      Event.user_message("s", "second")
    ]

    assert {:ok, %{text: "ok"}} =
             Provider.stream(
               %{model: "gpt-5.4", history: history},
               auth: auth,
               provider_transport: :websocket,
               provider_connection_key: key,
               websocket_client: SuccessfulWebSocket,
               websocket_client_opts: [test_pid: self(), ids: ids],
               max_retries: 0
             )

    assert_received {:websocket_payload, second_payload}
    assert second_payload["model"] == "gpt-5.4"
    refute Map.has_key?(second_payload, "previous_response_id")
    assert length(second_payload["input"]) == 3
  end

  test "rotated bearer token preserves websocket continuation on the same socket", %{auth: auth} do
    second_auth = :"auth_#{System.unique_integer([:positive])}"

    second_path =
      Path.join(System.tmp_dir!(), "pixir-transport-#{System.unique_integer([:positive])}.json")

    {:ok, _} =
      Auth.start_link(
        name: second_auth,
        store_path: second_path,
        env_api_key: "sk-test-rotated",
        oauth: __MODULE__.NoOAuth
      )

    on_exit(fn -> File.rm_rf!(second_path) end)

    {:ok, ids} = Agent.start_link(fn -> ["resp_1", "resp_2"] end)
    key = {:header_rotation, make_ref()}

    assert {:ok, %{text: "ok"}} =
             Provider.stream(
               %{history: [Event.user_message("s", "first")]},
               auth: auth,
               provider_transport: :websocket,
               provider_connection_key: key,
               websocket_client: SuccessfulWebSocket,
               websocket_client_opts: [test_pid: self(), ids: ids],
               max_retries: 0
             )

    assert_received {:websocket_connect, _endpoint}
    assert_received {:websocket_payload, first_payload}
    refute Map.has_key?(first_payload, "previous_response_id")

    history = [
      Event.user_message("s", "first"),
      Event.assistant_message("s", "ok"),
      Event.user_message("s", "second")
    ]

    assert {:ok, %{text: "ok"}} =
             Provider.stream(
               %{history: history},
               auth: second_auth,
               provider_transport: :websocket,
               provider_connection_key: key,
               websocket_client: SuccessfulWebSocket,
               websocket_client_opts: [test_pid: self(), ids: ids],
               max_retries: 0
             )

    refute_received {:websocket_connect, _endpoint}
    assert_received {:websocket_payload, second_payload}
    assert second_payload["previous_response_id"] == "resp_1"
    assert [%{"role" => "user"}] = second_payload["input"]
  end

  test "continuation metadata matches the wire payload for fresh and continued calls",
       %{auth: auth} do
    {:ok, ids} = Agent.start_link(fn -> ["resp_1", "resp_2"] end)
    key = {:continuation_evidence, make_ref()}

    assert {:ok, first} =
             Provider.stream(
               %{history: [Event.user_message("s", "first")]},
               auth: auth,
               provider_transport: :websocket,
               provider_connection_key: key,
               websocket_client: SuccessfulWebSocket,
               websocket_client_opts: [test_pid: self(), ids: ids],
               max_retries: 0
             )

    assert_received {:websocket_payload, first_payload}
    refute Map.has_key?(first_payload, "previous_response_id")
    assert first.provider_metadata["active_transport"] == "websocket"
    assert first.provider_metadata["continuation_attempted"] == false
    assert first.provider_metadata["continuation_reset_reason"] == "no_previous_response"
    assert first.provider_metadata["used_previous_response_id"] == false

    history = [
      Event.user_message("s", "first"),
      Event.assistant_message("s", "ok"),
      Event.user_message("s", "second")
    ]

    assert {:ok, second} =
             Provider.stream(
               %{history: history},
               auth: auth,
               provider_transport: :websocket,
               provider_connection_key: key,
               websocket_client: SuccessfulWebSocket,
               websocket_client_opts: [test_pid: self(), ids: ids],
               max_retries: 0
             )

    assert_received {:websocket_payload, second_payload}
    assert second_payload["previous_response_id"] == "resp_1"
    assert [%{"role" => "user"}] = second_payload["input"]
    assert second.provider_metadata["continuation_attempted"] == true
    assert second.provider_metadata["continuation_reset_reason"] == nil
    assert second.provider_metadata["used_previous_response_id"] == true
  end

  test "session_id routes continuation across turns like production Turn opts", %{auth: auth} do
    {:ok, ids} = Agent.start_link(fn -> ["resp_1", "resp_2"] end)
    session_id = "pixir-session-continuation"

    assert {:ok, first} =
             Provider.stream(
               %{history: [Event.user_message(session_id, "first")]},
               auth: auth,
               provider_transport: :websocket,
               session_id: session_id,
               websocket_client: SuccessfulWebSocket,
               websocket_client_opts: [test_pid: self(), ids: ids],
               max_retries: 0
             )

    assert first.provider_metadata["websocket_captured_response_id"] == "resp_1"
    assert first.provider_metadata["websocket_stored_previous_response_id"] == "resp_1"
    assert_received {:websocket_payload, first_payload}
    refute Map.has_key?(first_payload, "previous_response_id")

    history = [
      Event.user_message(session_id, "first"),
      Event.assistant_message(session_id, "ok"),
      Event.user_message(session_id, "second")
    ]

    assert {:ok, second} =
             Provider.stream(
               %{history: history},
               auth: auth,
               provider_transport: :websocket,
               session_id: session_id,
               websocket_client: SuccessfulWebSocket,
               websocket_client_opts: [test_pid: self(), ids: ids],
               max_retries: 0
             )

    assert_received {:websocket_payload, second_payload}
    assert second_payload["previous_response_id"] == "resp_1"
    assert second.provider_metadata["continuation_attempted"] == true
    assert second.provider_metadata["used_previous_response_id"] == true
    assert second.provider_metadata["websocket_stored_previous_response_id"] == "resp_2"
  end

  test "response_id captured from websocket events when stream return omits it", %{auth: auth} do
    {:ok, ids} = Agent.start_link(fn -> ["resp_event_1", "resp_event_2"] end)
    key = {:event_capture_evidence, make_ref()}

    assert {:ok, first} =
             Provider.stream(
               %{history: [Event.user_message("s", "first")]},
               auth: auth,
               provider_transport: :websocket,
               provider_connection_key: key,
               websocket_client: EventCaptureWebSocket,
               websocket_client_opts: [test_pid: self(), ids: ids],
               max_retries: 0
             )

    assert first.provider_metadata["websocket_captured_response_id"] == "resp_event_1"
    assert first.provider_metadata["websocket_stored_previous_response_id"] == "resp_event_1"
    assert_received {:websocket_payload, _first_payload}

    history = [
      Event.user_message("s", "first"),
      Event.assistant_message("s", "ok"),
      Event.user_message("s", "second")
    ]

    assert {:ok, second} =
             Provider.stream(
               %{history: history},
               auth: auth,
               provider_transport: :websocket,
               provider_connection_key: key,
               websocket_client: EventCaptureWebSocket,
               websocket_client_opts: [test_pid: self(), ids: ids],
               max_retries: 0
             )

    assert_received {:websocket_payload, second_payload}
    assert second_payload["previous_response_id"] == "resp_event_1"
    assert second.provider_metadata["used_previous_response_id"] == true
  end

  test "model change records model_changed against the full wire payload", %{auth: auth} do
    {:ok, ids} = Agent.start_link(fn -> ["resp_1", "resp_2"] end)
    key = {:model_changed_evidence, make_ref()}

    assert {:ok, _first} =
             Provider.stream(
               %{model: "gpt-5.5", history: [Event.user_message("s", "first")]},
               auth: auth,
               provider_transport: :websocket,
               provider_connection_key: key,
               websocket_client: SuccessfulWebSocket,
               websocket_client_opts: [test_pid: self(), ids: ids],
               max_retries: 0
             )

    assert_received {:websocket_payload, _first_payload}

    history = [
      Event.user_message("s", "first"),
      Event.assistant_message("s", "ok"),
      Event.user_message("s", "second")
    ]

    assert {:ok, second} =
             Provider.stream(
               %{model: "gpt-5.4", history: history},
               auth: auth,
               provider_transport: :websocket,
               provider_connection_key: key,
               websocket_client: SuccessfulWebSocket,
               websocket_client_opts: [test_pid: self(), ids: ids],
               max_retries: 0
             )

    assert_received {:websocket_payload, second_payload}
    refute Map.has_key?(second_payload, "previous_response_id")
    assert length(second_payload["input"]) == 3
    assert second.provider_metadata["continuation_attempted"] == false
    assert second.provider_metadata["continuation_reset_reason"] == "model_changed"
    assert second.provider_metadata["used_previous_response_id"] == false
  end

  test "prefix mismatch records prefix_mismatch and replays the full input", %{auth: auth} do
    {:ok, ids} = Agent.start_link(fn -> ["resp_1", "resp_2"] end)
    key = {:prefix_mismatch_evidence, make_ref()}

    assert {:ok, _first} =
             Provider.stream(
               %{history: [Event.user_message("s", "first")]},
               auth: auth,
               provider_transport: :websocket,
               provider_connection_key: key,
               websocket_client: SuccessfulWebSocket,
               websocket_client_opts: [test_pid: self(), ids: ids],
               max_retries: 0
             )

    assert_received {:websocket_payload, _first_payload}

    diverged_history = [
      Event.user_message("s", "rewritten"),
      Event.assistant_message("s", "ok"),
      Event.user_message("s", "second")
    ]

    assert {:ok, second} =
             Provider.stream(
               %{history: diverged_history},
               auth: auth,
               provider_transport: :websocket,
               provider_connection_key: key,
               websocket_client: SuccessfulWebSocket,
               websocket_client_opts: [test_pid: self(), ids: ids],
               max_retries: 0
             )

    assert_received {:websocket_payload, second_payload}
    refute Map.has_key?(second_payload, "previous_response_id")
    assert length(second_payload["input"]) == 3
    assert second.provider_metadata["continuation_attempted"] == false
    assert second.provider_metadata["continuation_reset_reason"] == "prefix_mismatch"
    assert second.provider_metadata["used_previous_response_id"] == false
  end

  test "empty continuation delta records empty_delta and sends the full payload",
       %{auth: auth} do
    {:ok, ids} = Agent.start_link(fn -> ["resp_1", "resp_2"] end)
    key = {:empty_delta_evidence, make_ref()}

    assert {:ok, _first} =
             Provider.stream(
               %{history: [Event.user_message("s", "first")]},
               auth: auth,
               provider_transport: :websocket,
               provider_connection_key: key,
               websocket_client: SuccessfulWebSocket,
               websocket_client_opts: [test_pid: self(), ids: ids],
               max_retries: 0
             )

    assert_received {:websocket_payload, _first_payload}

    # The suffix is only the assistant message, which continuation never resends,
    # so the delta is empty and the wire payload must fall back to the full input.
    history = [
      Event.user_message("s", "first"),
      Event.assistant_message("s", "ok")
    ]

    assert {:ok, second} =
             Provider.stream(
               %{history: history},
               auth: auth,
               provider_transport: :websocket,
               provider_connection_key: key,
               websocket_client: SuccessfulWebSocket,
               websocket_client_opts: [test_pid: self(), ids: ids],
               max_retries: 0
             )

    assert_received {:websocket_payload, second_payload}
    refute Map.has_key?(second_payload, "previous_response_id")
    assert length(second_payload["input"]) == 2
    assert second.provider_metadata["continuation_attempted"] == false
    assert second.provider_metadata["continuation_reset_reason"] == "empty_delta"
    assert second.provider_metadata["used_previous_response_id"] == false
  end

  test "http_sse policy records explicit no-continuation transport evidence", %{auth: auth} do
    assert {:ok, result} =
             Provider.stream(
               %{history: [Event.user_message("s", "first")]},
               auth: auth,
               provider_transport: :http_sse,
               http_transport: http_success_transport(self()),
               max_retries: 0
             )

    assert result.text == "http"
    assert result.provider_metadata["transport_preference"] == "http_sse"
    assert result.provider_metadata["active_transport"] == "http_sse"
    assert result.provider_metadata["continuation_attempted"] == false
    assert result.provider_metadata["continuation_reset_reason"] == nil
    assert result.provider_metadata["used_previous_response_id"] == false
    refute Map.has_key?(result.provider_metadata, "fallback_reason")

    assert_received {:http_request, %{body: body}}
    decoded = Jason.decode!(body)
    refute Map.has_key?(decoded, "previous_response_id")
    assert length(decoded["input"]) == 1
  end

  test "degraded fallback to HTTP records socket_closed and no continuation", %{auth: auth} do
    assert {:ok, result} =
             Provider.stream(%{history: [Event.user_message("s", "first")]},
               auth: auth,
               provider_transport: :auto,
               provider_connection_key: {:fallback_evidence, make_ref()},
               websocket_client: FailingWebSocket,
               websocket_client_opts: [test_pid: self()],
               http_transport: http_success_transport(self()),
               max_retries: 0
             )

    assert result.text == "http"
    assert result.provider_metadata["active_transport"] == "http_sse"
    assert result.provider_metadata["fallback_reason"] == "websocket_connect_failed"
    assert result.provider_metadata["continuation_attempted"] == false
    assert result.provider_metadata["continuation_reset_reason"] == "socket_closed"
    assert result.provider_metadata["used_previous_response_id"] == false

    assert_received {:http_request, %{body: body}}
    refute Map.has_key?(Jason.decode!(body), "previous_response_id")
  end

  test "mid-stream socket loss after continuation does not corrupt HTTP fallback evidence",
       %{auth: auth} do
    {:ok, scripts} = Agent.start_link(fn -> [{:ok, "resp_1"}, :closed] end)
    key = {:fidelity_evidence, make_ref()}

    assert {:ok, first} =
             Provider.stream(
               %{history: [Event.user_message("s", "first")]},
               auth: auth,
               provider_transport: :auto,
               provider_connection_key: key,
               websocket_client: FlakyContinuationWebSocket,
               websocket_client_opts: [test_pid: self(), scripts: scripts],
               http_transport: exploding_http_transport(self()),
               max_retries: 0
             )

    assert first.text == "ok"
    assert first.provider_metadata["continuation_attempted"] == false
    assert first.provider_metadata["continuation_reset_reason"] == "no_previous_response"
    assert_received {:websocket_payload, _first_payload}
    refute_received :unexpected_http_fallback

    history = [
      Event.user_message("s", "first"),
      Event.assistant_message("s", "ok"),
      Event.user_message("s", "second")
    ]

    # The WebSocket attempt really sends previous_response_id, then loses the socket.
    # The HTTP fallback replays the full body, so the recorded evidence must say the
    # delivered call did NOT continue — otherwise cache attribution is corrupted.
    assert {:ok, second} =
             Provider.stream(
               %{history: history},
               auth: auth,
               provider_transport: :auto,
               provider_connection_key: key,
               websocket_client: FlakyContinuationWebSocket,
               websocket_client_opts: [test_pid: self(), scripts: scripts],
               http_transport: http_success_transport(self()),
               max_retries: 0
             )

    assert second.text == "http"
    assert_received {:websocket_payload, attempted_payload}
    assert attempted_payload["previous_response_id"] == "resp_1"

    assert_received {:http_request, %{body: body}}
    delivered = Jason.decode!(body)
    refute Map.has_key?(delivered, "previous_response_id")
    assert length(delivered["input"]) == 3

    assert second.provider_metadata["active_transport"] == "http_sse"
    assert second.provider_metadata["fallback_reason"] == "websocket_closed"
    assert second.provider_metadata["continuation_attempted"] == false
    assert second.provider_metadata["continuation_reset_reason"] == "socket_closed"
    assert second.provider_metadata["used_previous_response_id"] == false
  end

  test "missing previous_response_id retries full replay on the same WebSocket", %{auth: auth} do
    {:ok, scripts} =
      Agent.start_link(fn ->
        [
          {:ok, "resp_1", "first"},
          :previous_response_not_found,
          {:ok, "resp_2", "retry"}
        ]
      end)

    key = {:missing_previous_response, make_ref()}

    assert {:ok, first} =
             Provider.stream(
               %{history: [Event.user_message("s", "first")], prompt_cache_key: "px1:family"},
               auth: auth,
               provider_transport: :websocket,
               provider_connection_key: key,
               websocket_client: MissingPreviousResponseWebSocket,
               websocket_client_opts: [test_pid: self(), scripts: scripts],
               max_retries: 0
             )

    assert first.text == "first"
    assert_received {:websocket_payload, first_payload}
    refute Map.has_key?(first_payload, "previous_response_id")

    history = [
      Event.user_message("s", "first"),
      Event.assistant_message("s", "first"),
      Event.user_message("s", "second")
    ]

    assert {:ok, second} =
             Provider.stream(
               %{history: history, prompt_cache_key: "px1:family"},
               auth: auth,
               provider_transport: :websocket,
               provider_connection_key: key,
               websocket_client: MissingPreviousResponseWebSocket,
               websocket_client_opts: [test_pid: self(), scripts: scripts],
               max_retries: 0
             )

    assert second.text == "retry"

    assert_received {:websocket_payload, attempted_payload}
    assert attempted_payload["previous_response_id"] == "resp_1"
    assert attempted_payload["store"] == false

    assert [%{"role" => "user", "content" => [%{"text" => "second"}]}] =
             attempted_payload["input"]

    assert_received {:websocket_payload, retry_payload}
    refute Map.has_key?(retry_payload, "previous_response_id")
    assert length(retry_payload["input"]) == 3
    assert retry_payload["prompt_cache_key"] == "px1:family"
    assert retry_payload["store"] == false

    assert second.provider_metadata["active_transport"] == "websocket"
    assert second.provider_metadata["continuation_attempted"] == false
    assert second.provider_metadata["continuation_reset_reason"] == "previous_response_not_found"
    assert second.provider_metadata["used_previous_response_id"] == false
  end

  test "explicit connection call timeout kills stale continuation and falls back to full replay",
       %{auth: auth} do
    {:ok, scripts} =
      Agent.start_link(fn ->
        [
          {:ok, "resp_1", "first"},
          :hang,
          {:ok, "resp_2", "third"}
        ]
      end)

    key = {:caller_timeout, make_ref()}

    assert {:ok, first} =
             Provider.stream(
               %{history: [Event.user_message("s", "first")]},
               auth: auth,
               provider_transport: :websocket,
               provider_connection_key: key,
               websocket_client: TimeoutAfterPayloadWebSocket,
               websocket_client_opts: [test_pid: self(), scripts: scripts],
               max_retries: 0
             )

    assert first.text == "first"
    assert_received {:websocket_payload, first_payload}
    refute Map.has_key?(first_payload, "previous_response_id")

    continued_history = [
      Event.user_message("s", "first"),
      Event.assistant_message("s", "first"),
      Event.user_message("s", "second")
    ]

    assert {:ok, second} =
             Provider.stream(
               %{history: continued_history},
               auth: auth,
               provider_transport: :auto,
               provider_connection_key: key,
               websocket_client: TimeoutAfterPayloadWebSocket,
               websocket_client_opts: [test_pid: self(), scripts: scripts],
               websocket_call_timeout_ms: 25,
               http_transport: http_success_transport(self()),
               max_retries: 0
             )

    assert second.text == "http"
    assert_received {:websocket_payload, attempted_payload}
    assert attempted_payload["previous_response_id"] == "resp_1"
    assert second.provider_metadata["active_transport"] == "http_sse"
    assert second.provider_metadata["fallback_reason"] == "websocket_call_timeout"
    assert second.provider_metadata["continuation_reset_reason"] == "socket_closed"
    assert second.provider_metadata["used_previous_response_id"] == false

    assert_received {:http_request, %{body: body}}
    delivered = Jason.decode!(body)
    refute Map.has_key?(delivered, "previous_response_id")
    assert length(delivered["input"]) == 3

    Process.sleep(20)

    later_history = continued_history ++ [Event.assistant_message("s", "http")]

    assert {:ok, third} =
             Provider.stream(
               %{history: later_history},
               auth: auth,
               provider_transport: :websocket,
               provider_connection_key: key,
               websocket_client: TimeoutAfterPayloadWebSocket,
               websocket_client_opts: [test_pid: self(), scripts: scripts],
               max_retries: 0
             )

    assert third.text == "third"
    assert_received {:websocket_payload, third_payload}
    refute Map.has_key?(third_payload, "previous_response_id")
    assert length(third_payload["input"]) == 4
    assert third.provider_metadata["continuation_reset_reason"] == "no_previous_response"
    assert third.provider_metadata["used_previous_response_id"] == false
  end

  describe "stream idle timeout" do
    defmodule HungWebSocket do
      def connect(endpoint, _headers, opts) do
        send(Keyword.fetch!(opts, :test_pid), {:websocket_connect, endpoint})
        {:ok, :fake_socket, "", %{status: 101}}
      end

      def stream(_socket, _initial_buffer, payload, acc, fun, opts) do
        send(Keyword.fetch!(opts, :test_pid), {:websocket_payload, payload})
        acc = fun.({:data, sse(%{type: "response.output_text.delta", delta: "partial"})}, acc)
        :timer.sleep(:infinity)
        {:ok, acc, %{}}
      end

      def close(_socket), do: :ok
      def ping(_socket), do: :ok

      defp sse(map), do: "data: " <> Jason.encode!(map) <> "\n\n"
    end

    test "cuts a hung WebSocket stream with a structured error", %{auth: auth} do
      assert {:error,
              %{
                ok: false,
                error: %{
                  kind: :stream_idle_timeout,
                  details: %{
                    timeout_ms: 25,
                    transport: "websocket",
                    next_actions: next_actions
                  }
                }
              }} =
               Provider.stream(%{history: []},
                 auth: auth,
                 provider_transport: :websocket,
                 provider_connection_key: {:test, self()},
                 websocket_client: HungWebSocket,
                 websocket_client_opts: [test_pid: self()],
                 stream_idle_timeout_ms: 25,
                 max_retries: 0
               )

      assert "retry_turn" in next_actions
    end
  end
end
