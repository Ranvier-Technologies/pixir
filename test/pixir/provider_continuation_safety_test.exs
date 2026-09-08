defmodule Pixir.ProviderContinuationSafetyTest do
  use ExUnit.Case, async: false

  alias Pixir.{Auth, Event, Provider}
  alias Pixir.Provider.Connection

  defmodule NoOAuth do
    def refresh_skew_ms, do: 60_000
  end

  defmodule ScriptedSocket do
    def connect(_endpoint, _headers, opts) do
      socket = {:fixture, Keyword.fetch!(opts, :test_pid), make_ref()}
      send(Keyword.fetch!(opts, :test_pid), {:connected, socket})
      {:ok, socket, "", %{status: 101}}
    end

    def stream(socket, _buffer, payload, acc, fun, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:wire, socket, payload, opts[:timeout_ms]})

      {events, id} =
        Agent.get_and_update(Keyword.fetch!(opts, :scripts), fn
          [next | rest] -> {next, rest}
          [] -> {{[], nil}, []}
        end)

      next =
        Enum.reduce(events, acc, fn event, state ->
          fun.({:data, "data: " <> Jason.encode!(event) <> "\n\n"}, state)
        end)

      send(Keyword.fetch!(opts, :test_pid), {:reduced, next})

      case id do
        {:transport_error, error} -> {:error, error, next}
        _ -> {:ok, next, %{response_id: id}}
      end
    end

    def close({:fixture, pid, _} = socket), do: send(pid, {:closed, socket})
    def ping(_socket), do: :ok
  end

  defp success(id) do
    {[
       %{
         "type" => "response.completed",
         "response" => %{"id" => id, "usage" => %{"input_tokens" => 16}}
       }
     ], id}
  end

  defp rejected(id, envelope),
    do: rejected(id, envelope, "previous_response_not_found", "Previous response not found")

  defp rejected(id, envelope, code, message) do
    error = %{"code" => code, "type" => "invalid_request_error", "message" => message}

    case envelope do
      "error" ->
        %{"type" => "error", "error" => error}

      "response.failed" ->
        %{"type" => "response.failed", "response" => %{"id" => id, "error" => error}}
    end
  end

  defp committed(id),
    do: %{
      "type" => "response.output_item.done",
      "item" => %{
        "type" => "function_call",
        "call_id" => id,
        "name" => "read",
        "arguments" => "{}"
      }
    }

  defp scenario(rest, retry_opts, transport \\ :websocket) do
    auth_name = :"ws_safety_auth_#{System.unique_integer([:positive])}"

    fixture_dir =
      Path.join(
        System.tmp_dir!(),
        "pixir-ws-safety-" <> Base.encode16(:crypto.strong_rand_bytes(8))
      )

    File.mkdir_p!(fixture_dir)
    on_exit(fn -> File.rm_rf!(fixture_dir) end)

    start_supervised!(
      {Auth,
       name: auth_name,
       store_path: Path.join(fixture_dir, "auth.json"),
       env_api_key: "sk-test",
       oauth: NoOAuth}
    )

    scripts = start_supervised!({Agent, fn -> [success("resp_prime") | rest] end})
    key = {:ws_safety, make_ref()}
    test_pid = self()

    opts =
      [
        auth: auth_name,
        provider_transport: transport,
        provider_connection_key: key,
        websocket_client: ScriptedSocket,
        websocket_client_opts: [test_pid: self(), scripts: scripts],
        http_transport: fn _, acc, _ ->
          send(test_pid, :unexpected_http)
          {:ok, acc}
        end,
        on_committed_call: fn call ->
          send(test_pid, {:committed, call.call_id})
          :ok
        end,
        on_compaction_item: fn item ->
          send(test_pid, {:compacted, item})
          :ok
        end,
        on_delta: fn delta ->
          send(test_pid, {:delta, delta})
          :ok
        end,
        sleep: fn _ -> send(test_pid, :unexpected_retry) end,
        timeout_ms: 30_000
      ] ++ retry_opts

    on_exit(fn ->
      case Registry.lookup(Pixir.Provider.ConnectionRegistry, key) do
        [{pid, _}] -> if Process.alive?(pid), do: GenServer.stop(pid, :normal)
        [] -> :ok
      end
    end)

    assert {:ok, _} =
             Provider.stream(
               %{history: [Event.user_message("s", "first")], prompt_cache_key: "px1:ws-safety"},
               opts
             )

    assert_receive {:connected, socket}
    assert_receive {:wire, ^socket, _, _}
    assert_receive {:reduced, _}

    request = %{
      history: [
        Event.user_message("s", "first"),
        Event.assistant_message("s", ""),
        Event.user_message("s", "second")
      ],
      prompt_cache_key: "px1:ws-safety"
    }

    {opts, request, key, socket}
  end

  for envelope <- ["error", "response.failed"],
      retries <- [:disabled, :ordinary],
      progress <- [
        :text,
        :empty_text,
        :reasoning,
        :reasoning_item,
        :compaction,
        :hosted_activity,
        :hosted_item,
        :usage,
        :pending_call,
        :arguments
      ] do
    @progress progress
    @envelope envelope
    @retry_opts if(retries == :disabled, do: [max_retries: 0], else: [])

    test "#{progress} before #{envelope} with #{retries} retries is not clean recovery" do
      event = progress_event(@progress)

      {opts, request, key, socket} =
        scenario(
          [
            {[event, rejected(nil, @envelope)], nil},
            {[committed("must_not_commit")], "resp_unexpected"}
          ],
          @retry_opts,
          :auto
        )

      assert {:error,
              %{
                error: %{
                  kind: :provider_http_error,
                  details: %{code: "previous_response_not_found"}
                }
              }} = Provider.stream(request, opts)

      assert_receive {:wire, ^socket, attempted, _}
      assert attempted["previous_response_id"] == "resp_prime"
      assert_receive {:reduced, partial}
      assert_progress(@progress, partial)
      assert_receive {:closed, ^socket}
      assert :sys.get_state(Connection.via(key)).previous_response_id == nil
      refute_received {:wire, _, _, _}
      refute_received {:committed, _}
      refute_received {:delta, _}
      refute_received {:compacted, _}
      refute_received :unexpected_retry
      refute_received :unexpected_http
    end
  end

  for envelope <- ["error", "response.failed"] do
    @envelope envelope

    test "transient #{envelope} after progress cannot reenter the outer default retry loop" do
      rejection = rejected(nil, @envelope, "server_error", "Original transient provider error")

      {opts, request, _key, socket} =
        scenario(
          [
            {[committed("call_once"), rejection], nil},
            success("must_not_replay")
          ],
          [],
          :auto
        )

      assert {:error,
              %{
                error: %{
                  kind: :provider_http_error,
                  details: %{code: "server_error", retryable: true}
                }
              }} = Provider.stream(request, opts)

      assert_receive {:committed, "call_once"}
      assert_receive {:wire, ^socket, _, _}
      refute_received {:wire, _, _, _}
      refute_received :unexpected_retry
      refute_received :unexpected_http
    end

    test "transient full-replay #{envelope} failure retains its error without a third request" do
      rejection = rejected("resp_failed", @envelope, "server_error", "Full replay failed")

      {opts, request, key, socket} =
        scenario(
          [
            {[rejected(nil, @envelope)], nil},
            {[rejection], "resp_failed"},
            success("must_not_replay")
          ],
          [],
          :auto
        )

      assert {:error,
              %{
                error: %{
                  kind: :provider_http_error,
                  details: %{code: "server_error", retryable: true}
                }
              }} = Provider.stream(request, opts)

      state = :sys.get_state(Connection.via(key))
      assert state.previous_response_id == nil
      assert state.previous_input == nil
      assert state.failures == 1
      assert_receive {:wire, ^socket, _, _}
      assert_receive {:wire, ^socket, _, _}
      refute_received {:wire, _, _, _}
      refute_received :unexpected_retry
      refute_received :unexpected_http
    end

    test "exact #{envelope} code without an actual continuation never replays" do
      {opts, request, key, socket} =
        scenario(
          [
            {[rejected("resp_failed", @envelope)], "resp_failed"},
            success("must_not_replay")
          ],
          [],
          :auto
        )

      request = %{request | history: [Event.user_message("s", "new prefix")]}

      assert {:error, %{error: %{details: %{code: "previous_response_not_found"}}}} =
               Provider.stream(request, opts)

      assert_receive {:wire, ^socket, payload, _}
      refute Map.has_key?(payload, "previous_response_id")
      assert :sys.get_state(Connection.via(key)).previous_response_id == nil
      refute_received {:wire, _, _, _}
      refute_received :unexpected_retry
      refute_received :unexpected_http
    end

    test "#{envelope} type or legacy message alone is not an exact code" do
      error = %{
        "type" => "previous_response_not_found",
        "message" => "previous response not found",
        "param" => "previous_response_id"
      }

      event =
        if @envelope == "error",
          do: %{"type" => "error", "error" => error},
          else: %{"type" => "response.failed", "response" => %{"error" => error}}

      {opts, request, _key, socket} =
        scenario([{[event], nil}, success("must_not_replay")], [], :auto)

      assert {:error, %{error: %{details: %{code: nil}}}} = Provider.stream(request, opts)
      assert_receive {:wire, ^socket, _, _}
      refute_received {:wire, _, _, _}
      refute_received :unexpected_retry
      refute_received :unexpected_http
    end
  end

  for retries <- [:disabled, :ordinary] do
    @retry_opts if(retries == :disabled, do: [max_retries: 0], else: [])
    test "usage in the failed envelope with #{retries} retries prevents replay" do
      event =
        put_in(rejected(nil, "response.failed"), ["response", "usage"], %{"input_tokens" => 12})

      {opts, request, _key, socket} =
        scenario([{[event], nil}, success("must_not_replay")], @retry_opts, :auto)

      assert {:error, %{error: %{details: %{code: "previous_response_not_found"}}}} =
               Provider.stream(request, opts)

      assert_receive {:reduced, partial}
      assert partial.usage == %{"input_tokens" => 12}
      assert_receive {:wire, ^socket, _, _}
      refute_received {:wire, _, _, _}
      refute_received :unexpected_retry
      refute_received :unexpected_http
    end
  end

  for callback <- [:on_delta, :on_committed_call, :on_compaction_item] do
    @callback_name callback
    test "#{callback} effect followed by an exit is not replayed by default retries" do
      event =
        case @callback_name do
          :on_delta -> progress_event(:text)
          :on_committed_call -> committed("call_once")
          :on_compaction_item -> progress_event(:compaction)
        end

      {opts, request, key, socket} =
        scenario([{[event], nil}, success("must_not_replay")], [], :auto)

      test_pid = self()

      opts =
        Keyword.put(opts, @callback_name, fn _ ->
          send(test_pid, :callback_effect)
          exit(:synthetic_callback_exit)
        end)

      assert {:error, %{error: %{kind: :network, details: %{reason: :stream_callback_failed}}}} =
               Provider.stream(request, opts)

      assert_receive :callback_effect
      assert_receive {:wire, ^socket, _, _}
      assert :sys.get_state(Connection.via(key)).previous_response_id == nil
      refute_received :callback_effect
      refute_received {:wire, _, _, _}
      refute_received :unexpected_retry
      refute_received :unexpected_http
    end
  end

  for progress <- [:empty_text, :hosted_activity, :compaction],
      kind <- [:websocket_closed, :network] do
    @progress progress
    @error_kind kind
    test "#{kind} after #{progress} cannot fall back or reenter default retries" do
      error = Pixir.Tool.error(@error_kind, "Synthetic transport failure", %{})

      {opts, request, _key, socket} =
        scenario(
          [
            {[progress_event(@progress)], {:transport_error, error}},
            success("must_not_replay")
          ],
          [],
          :auto
        )

      assert {:error, %{error: %{kind: @error_kind}}} = Provider.stream(request, opts)
      assert_receive {:reduced, partial}
      assert_progress(@progress, partial)
      assert_receive {:wire, ^socket, _, _}
      refute_received {:wire, _, _, _}
      refute_received :unexpected_retry
      refute_received :unexpected_http
      refute_received {:delta, _}
      refute_received {:compacted, _}
    end
  end

  test "an exhausted original deadline does not grant recovery another millisecond" do
    {opts, request, key, socket} =
      scenario(
        [
          {[rejected(nil, "error")], nil},
          success("must_not_replay")
        ],
        [],
        :auto
      )

    opts = Keyword.put(opts, :timeout_ms, 0)

    assert {:error, %{error: %{details: %{code: "previous_response_not_found"}}}} =
             Provider.stream(request, opts)

    assert_receive {:wire, ^socket, _, 0}
    assert :sys.get_state(Connection.via(key)).previous_response_id == nil
    refute_received {:wire, _, _, _}
    refute_received :unexpected_retry
    refute_received :unexpected_http
  end

  test "failed replay without an error object is still not semantic success" do
    failed = %{
      "type" => "response.failed",
      "response" => %{"id" => "resp_failed", "status" => "failed"}
    }

    {opts, request, key, socket} =
      scenario(
        [
          {[rejected(nil, "error")], nil},
          {[failed], "resp_failed"}
        ],
        [],
        :auto
      )

    assert {:error,
            %{error: %{kind: :provider_http_error, details: %{event_type: "response.failed"}}}} =
             Provider.stream(request, opts)

    assert :sys.get_state(Connection.via(key)).previous_response_id == nil
    assert_receive {:wire, ^socket, _, _}
    assert_receive {:wire, ^socket, _, _}
    refute_received {:wire, _, _, _}
    refute_received :unexpected_retry
    refute_received :unexpected_http
  end

  test "transport failure after the one clean reset cannot fall back or retry again" do
    error = Pixir.Tool.error(:websocket_closed, "Synthetic socket close", %{})

    {opts, request, _key, socket} =
      scenario(
        [
          {[rejected(nil, "error")], nil},
          {[], {:transport_error, error}}
        ],
        [],
        :auto
      )

    assert {:error, %{error: %{kind: :websocket_closed}}} = Provider.stream(request, opts)
    assert_receive {:wire, ^socket, _, _}
    assert_receive {:wire, ^socket, _, _}
    refute_received {:wire, _, _, _}
    refute_received :unexpected_retry
    refute_received :unexpected_http
  end

  test "successful incomplete replay preserves neutral output truncation and continuation" do
    item = progress_event(:compaction)

    incomplete = %{
      "type" => "response.incomplete",
      "response" => %{
        "id" => "resp_incomplete",
        "status" => "incomplete",
        "incomplete_details" => %{"reason" => "max_output_tokens"}
      }
    }

    {opts, request, key, socket} =
      scenario(
        [
          {[rejected(nil, "error")], nil},
          {[item, incomplete], "resp_incomplete"}
        ],
        [],
        :auto
      )

    assert {:ok, result} = Provider.stream(request, opts)
    assert result.compaction_item == item["item"]
    assert_receive {:compacted, _}

    assert Pixir.Provider.OutputTruncation.to_result_map(result.output_truncation) == %{
             status: :truncated,
             reason: :provider_output_limit,
             provider_reason: "max_output_tokens"
           }

    assert :sys.get_state(Connection.via(key)).previous_response_id == "resp_incomplete"
    assert_receive {:wire, ^socket, _, _}
    assert_receive {:wire, ^socket, _, _}
    refute_received {:compacted, _}
    refute_received {:wire, _, _, _}
  end

  defp progress_event(:text), do: %{"type" => "response.output_text.delta", "delta" => "partial"}
  defp progress_event(:empty_text), do: %{"type" => "response.output_text.delta", "delta" => ""}

  defp progress_event(:reasoning),
    do: %{"type" => "response.reasoning_summary_text.delta", "delta" => "thinking"}

  defp progress_event(:reasoning_item),
    do: %{
      "type" => "response.output_item.done",
      "item" => %{"type" => "reasoning", "id" => "rs_partial", "encrypted_content" => "opaque"}
    }

  defp progress_event(:compaction),
    do: %{
      "type" => "response.output_item.done",
      "item" => %{"type" => "compaction", "id" => "cmp_partial", "encrypted_content" => "opaque"}
    }

  defp progress_event(:hosted_activity),
    do: %{"type" => "response.web_search_call.in_progress", "item_id" => "ws_partial"}

  defp progress_event(:hosted_item),
    do: %{
      "type" => "response.output_item.done",
      "item" => %{
        "type" => "web_search_call",
        "id" => "ws_partial",
        "status" => "completed",
        "action" => %{"type" => "search", "query" => "fixture"}
      }
    }

  defp progress_event(:usage),
    do: %{
      "type" => "response.completed",
      "response" => %{"id" => "resp_usage", "usage" => %{"input_tokens" => 10}}
    }

  defp progress_event(:pending_call),
    do: %{
      "type" => "response.output_item.added",
      "item" => %{
        "type" => "function_call",
        "call_id" => "pending",
        "name" => "read",
        "arguments" => ""
      }
    }

  defp progress_event(:arguments),
    do: %{
      "type" => "response.function_call_arguments.delta",
      "item_id" => "fc_pending",
      "delta" => "{"
    }

  defp assert_progress(progress, partial) do
    assert partial.replay_safe? == false

    case progress do
      :text ->
        assert partial.text == "partial"
        assert_receive {:delta, {:text_delta, "partial"}}

      :empty_text ->
        assert partial.text == ""
        assert_receive {:delta, {:text_delta, ""}}

      :reasoning ->
        assert partial.reasoning == "thinking"
        assert_receive {:delta, {:reasoning_delta, "thinking"}}

      :reasoning_item ->
        assert [{:reasoning, _}] = partial.output_items

      :compaction ->
        assert partial.compaction_item["id"] == "cmp_partial"
        assert_receive {:compacted, _}

      :hosted_activity ->
        assert [_] = partial.provider_hosted_tools["web_search"]["events"]

      :hosted_item ->
        assert [{:provider_hosted_tool, _}] = partial.output_items

      :usage ->
        assert partial.usage == %{"input_tokens" => 10}

      :pending_call ->
        assert partial.output_items == []

      :arguments ->
        assert partial.output_items == []
    end
  end

  for envelope <- ["error", "response.failed"], retries <- [:disabled, :ordinary] do
    @envelope envelope
    @retry_opts if(retries == :disabled, do: [max_retries: 0], else: [])

    test "clean #{@envelope} reset with #{retries} retries replays exactly once on the same socket" do
      {opts, request, _key, socket} =
        scenario([{[rejected(nil, @envelope)], nil}, success("resp_recovered")], @retry_opts)

      assert {:ok, result} = Provider.stream(request, opts)
      assert_receive {:wire, ^socket, attempted, timeout}
      assert attempted["previous_response_id"] == "resp_prime"
      assert_receive {:wire, ^socket, replay, remaining}
      refute Map.has_key?(replay, "previous_response_id")
      assert length(replay["input"]) == 3
      assert replay["store"] == false
      assert replay["prompt_cache_key"] == "px1:ws-safety"
      assert remaining > 0 and remaining <= timeout

      assert result.provider_metadata["continuation_reset_reason"] ==
               "previous_response_not_found"

      refute_received {:wire, _, _, _}
      refute_received :unexpected_retry
      refute_received :unexpected_http
      refute_received {:closed, _}
    end

    test "failed full replay #{@envelope} with #{retries} retries cannot install resp_failed" do
      {opts, request, key, socket} =
        scenario(
          [
            {[rejected(nil, @envelope)], nil},
            {[rejected("resp_failed", @envelope)], "resp_failed"}
          ],
          @retry_opts,
          :auto
        )

      assert {:error,
              %{
                error: %{
                  kind: :provider_http_error,
                  details: %{code: "previous_response_not_found", event_type: @envelope}
                }
              }} = Provider.stream(request, opts)

      state = :sys.get_state(Connection.via(key))
      assert state.previous_response_id == nil
      assert state.previous_input == nil
      assert state.socket == nil
      assert state.failures == 1
      assert_receive {:closed, ^socket}
      assert_receive {:wire, ^socket, _, _}
      assert_receive {:wire, ^socket, replay, _}
      refute Map.has_key?(replay, "previous_response_id")
      refute_received {:wire, _, _, _}
      refute_received :unexpected_retry
      refute_received :unexpected_http
    end

    test "committed declaration before #{@envelope} with #{retries} retries prevents a second commitment" do
      {done, id} = success("resp_replayed")

      {opts, request, _key, socket} =
        scenario(
          [
            {[committed("call_before_error"), rejected(nil, @envelope)], nil},
            {[committed("call_after_replay") | done], id}
          ],
          @retry_opts,
          :auto
        )

      assert {:error, %{error: %{kind: :provider_http_error}}} = Provider.stream(request, opts)
      assert_receive {:committed, "call_before_error"}
      assert_receive {:reduced, partial}
      assert [{:function_call, %{call_id: "call_before_error"}}] = partial.output_items
      assert_receive {:wire, ^socket, _, _}
      refute_received {:wire, _, _, _}
      refute_received {:committed, _}
      refute_received :unexpected_retry
      refute_received :unexpected_http
    end

    test "unrelated #{@envelope} text with #{retries} retries never authorizes replay" do
      error =
        rejected(
          nil,
          @envelope,
          "policy_blocked",
          "Policy notice: previous response not found is not retryable"
        )

      {opts, request, _key, socket} =
        scenario([{[error], nil}, success("resp_unexpected")], @retry_opts, :auto)

      assert {:error, %{error: %{kind: :provider_http_error, details: %{code: "policy_blocked"}}}} =
               Provider.stream(request, opts)

      assert_receive {:wire, ^socket, _, _}
      refute_received {:wire, _, _, _}
      refute_received :unexpected_retry
      refute_received :unexpected_http
    end
  end
end
