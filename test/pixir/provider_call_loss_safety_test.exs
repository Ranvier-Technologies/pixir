defmodule Pixir.ProviderCallLossSafetyTest do
  use ExUnit.Case, async: false

  alias Pixir.{Auth, Event, Provider}
  alias Pixir.Provider.TransportPolicy

  defmodule NoOAuth do
    def refresh_skew_ms, do: 60_000
  end

  defmodule HoldingSocket do
    def connect(_endpoint, _headers, opts) do
      {:ok, {:fixture, Keyword.fetch!(opts, :test_pid)}, "", %{status: 101}}
    end

    def stream(_socket, _buffer, _payload, acc, fun, opts) do
      test_pid = Keyword.fetch!(opts, :test_pid)
      attempt = Agent.get_and_update(Keyword.fetch!(opts, :attempts), &{&1, &1 + 1})
      send(test_pid, {:wire, self()})
      event = Keyword.fetch!(opts, :event)
      next = fun.({:data, "data: " <> Jason.encode!(event) <> "\n\n"}, acc)
      send(test_pid, {:reduced, next})

      # The test observes the callback/reducer before killing this process, or
      # leaves it waiting until the explicit caller deadline expires. Unexpected
      # retries complete so a broken guard fails on replay evidence, not a hang.
      if attempt == 0 do
        receive do
          :finish -> {:ok, next, %{response_id: "must_not_complete"}}
        end
      else
        completed = %{"type" => "response.completed", "response" => %{"id" => "replayed"}}
        next = fun.({:data, "data: " <> Jason.encode!(completed) <> "\n\n"}, next)
        {:ok, next, %{response_id: "replayed"}}
      end
    end

    def close(_socket), do: :ok
    def ping(_socket), do: :ok
  end

  setup do
    auth_name = :"call_loss_auth_#{System.unique_integer([:positive])}"
    dir = Path.join(System.tmp_dir!(), "pixir-call-loss-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    start_supervised!(
      {Auth,
       name: auth_name,
       store_path: Path.join(dir, "auth.json"),
       env_api_key: "sk-test",
       oauth: NoOAuth}
    )

    %{auth: auth_name}
  end

  for loss <- [:timeout, :process_exit], progress <- [:text, :committed_call] do
    @loss loss
    @progress progress
    test "#{loss} after #{progress} preserves the original error without replay", %{auth: auth} do
      test_pid = self()
      opts = socket_opts(@loss, @progress)

      task =
        Task.async(fn ->
          Provider.stream(
            %{history: [Event.user_message("s", "first")]},
            opts ++
              [
                auth: auth,
                on_delta: fn delta -> send(test_pid, {:delta, delta}) end,
                on_committed_call: fn call ->
                  send(test_pid, {:committed, call.call_id})
                  :ok
                end,
                sleep: fn _ -> send(test_pid, :unexpected_retry) end
              ]
          )
        end)

      assert_receive {:wire, connection}, 1_000
      assert_receive {:reduced, partial}, 1_000

      case @progress do
        :text ->
          assert partial.text == "visible once"
          assert_receive {:delta, {:text_delta, "visible once"}}

        :committed_call ->
          assert_receive {:committed, "call_once"}
          assert partial.replay_safe? == false
      end

      lose_connection(@loss, connection)
      result = Task.await(task, 3_000)
      assert_original_error(result, @loss)
      refute_received {:wire, _}
      refute_received {:delta, _}
      refute_received {:committed, _}
      refute_received :unexpected_http
      refute_received :unexpected_retry
    end
  end

  for loss <- [:timeout, :process_exit], accumulator <- [:map, :keyword] do
    @loss loss
    @accumulator accumulator
    test "#{loss} marks a generic #{accumulator} accumulator replay unsafe" do
      test_pid = self()
      opts = socket_opts(@loss, :text)
      initial = if @accumulator == :map, do: %{custom: :preserved}, else: [custom: :preserved]

      task =
        Task.async(fn ->
          TransportPolicy.stream(
            %{url: "https://example.test/responses", headers: [], body: ~s({"input":[]})},
            initial,
            fn
              {:data, _}, acc ->
                send(test_pid, :generic_effect)
                acc

              _, acc ->
                acc
            end,
            opts
          )
        end)

      assert_receive {:wire, connection}, 1_000
      assert_receive :generic_effect, 1_000
      assert_receive {:reduced, _}, 1_000
      lose_connection(@loss, connection)
      assert {:error, error, acc} = Task.await(task, 3_000)
      assert_original_error({:error, error}, @loss)
      assert acc[:custom] == :preserved
      assert acc[:replay_safe?] == false
      refute TransportPolicy.replay_safe?(acc)
      refute_received :generic_effect
      refute_received :unexpected_http
    end
  end

  defp socket_opts(loss, progress) do
    test_pid = self()
    key = {:call_loss, make_ref()}
    attempts = start_supervised!({Agent, fn -> 0 end})

    on_exit(fn ->
      case Registry.lookup(Pixir.Provider.ConnectionRegistry, key) do
        [{pid, _}] -> if Process.alive?(pid), do: GenServer.stop(pid, :normal)
        [] -> :ok
      end
    end)

    [
      provider_transport: :auto,
      provider_connection_key: key,
      websocket_client: HoldingSocket,
      websocket_client_opts: [
        test_pid: test_pid,
        event: progress_event(progress),
        attempts: attempts
      ],
      websocket_call_timeout_ms: if(loss == :timeout, do: 500, else: :infinity),
      http_transport: fn _, acc, _ ->
        send(test_pid, :unexpected_http)
        {:ok, acc}
      end
    ]
  end

  defp lose_connection(:timeout, _connection), do: :ok
  defp lose_connection(:process_exit, connection), do: Process.exit(connection, :kill)

  defp assert_original_error(result, :timeout) do
    assert {:error,
            %{
              error: %{
                kind: :websocket_call_timeout,
                details: %{
                  timeout_ms: 500,
                  continuation_reset_reason: "caller_timeout",
                  next_actions: ["inspect_session_lifecycle"]
                }
              }
            }} = result
  end

  defp assert_original_error(result, :process_exit) do
    assert {:error, %{error: %{kind: :network, details: %{reason: :transport_process_exited}}}} =
             result
  end

  defp progress_event(:text),
    do: %{"type" => "response.output_text.delta", "delta" => "visible once"}

  defp progress_event(:committed_call),
    do: %{
      "type" => "response.output_item.done",
      "item" => %{
        "type" => "function_call",
        "call_id" => "call_once",
        "name" => "read",
        "arguments" => "{}"
      }
    }
end
