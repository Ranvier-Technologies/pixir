defmodule Pixir.ConversationTest do
  use ExUnit.Case, async: false

  alias Pixir.{Conversation, Event, Log, Paths}

  # Minimal provider stub: pops scripted results, streams text deltas (like TurnTest's).
  defmodule StubProvider do
    def stream(_request, opts) do
      agent = Keyword.fetch!(opts, :agent)
      on_delta = Keyword.get(opts, :on_delta, fn _ -> :ok end)

      result =
        agent
        |> Agent.get_and_update(fn [head | tail] -> {head, tail} end)
        |> ensure_usage()

      case result do
        {:ok, %{text: text}} when text != "" -> on_delta.({:text_delta, text})
        _ -> :ok
      end

      result
    end

    defp ensure_usage({:ok, result}) when is_map(result) do
      result = Map.put_new(result, :usage, usage())
      # Real providers own their usage_summary (ADR 0037 D7); the stub models that.
      {:ok, Map.put_new(result, :usage_summary, Pixir.Provider.usage_summary(result[:usage]))}
    end

    defp ensure_usage(result), do: result

    defp usage do
      %{
        "input_tokens" => 42,
        "input_tokens_details" => %{"cached_tokens" => 16},
        "output_tokens" => 7,
        "output_tokens_details" => %{"reasoning_tokens" => 3},
        "total_tokens" => 49
      }
    end
  end

  # A provider that blocks long enough to be interrupted mid-turn.
  defmodule BlockingProvider do
    def stream(_request, _opts) do
      Process.sleep(10_000)
      {:ok, %{text: "never", reasoning: "", function_calls: [], finish_reason: :stop}}
    end
  end

  defp stop(text),
    do:
      {:ok,
       %{
         text: text,
         reasoning: "",
         function_calls: [],
         finish_reason: :stop,
         usage: %{
           "input_tokens" => 42,
           "input_tokens_details" => %{"cached_tokens" => 16},
           "output_tokens" => 7,
           "output_tokens_details" => %{"reasoning_tokens" => 3},
           "total_tokens" => 49
         }
       }}

  setup do
    ws =
      Path.join(
        System.tmp_dir!(),
        "pixir-conv-" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
      )

    File.mkdir_p!(ws)
    on_exit(fn -> File.rm_rf!(ws) end)
    %{ws: ws}
  end

  # Run one turn via the driver with a scripted provider, returning the await outcome.
  defp send_and_await(sid, prompt, script) do
    {:ok, agent} = Agent.start_link(fn -> script end)
    :ok = Conversation.subscribe(sid)

    {:ok, _ref} =
      Conversation.send(sid, prompt, provider: StubProvider, provider_opts: [agent: agent])

    Conversation.await(sid, idle_timeout: 2_000)
  end

  test "start mints a new session and a turn runs end to end", %{ws: ws} do
    assert {:ok, sid} = Conversation.start(workspace: ws)
    assert is_binary(sid)

    assert :done = send_and_await(sid, "hello", [stop("hi there")])

    assert {:ok, history} = Conversation.history(sid)
    assert Enum.map(history, & &1.type) == [:user_message, :provider_usage, :assistant_message]

    usage = Enum.find(history, &(&1.type == :provider_usage))
    assert usage.data["usage_available"] == true
    assert usage.data["usage_summary"]["cached_tokens"] == 16
  end

  test "start with :id resumes a persisted session and continues its History", %{ws: ws} do
    {:ok, sid} = Conversation.start(workspace: ws)
    assert :done = send_and_await(sid, "first", [stop("one")])

    # A fresh start with the same id reattaches; History carries forward.
    assert {:ok, ^sid} = Conversation.start(id: sid, workspace: ws)
    assert :done = send_and_await(sid, "second", [stop("two")])

    assert {:ok, history} = Conversation.history(sid)

    assert Enum.map(history, & &1.type) == [
             :user_message,
             :provider_usage,
             :assistant_message,
             :user_message,
             :provider_usage,
             :assistant_message
           ]
  end

  test "resume requires explicit forced release for stale Session writer leases", %{ws: ws} do
    sid = "stale-writer-session"
    event = Event.user_message(sid, "existing") |> Event.with_seq(0)
    assert {:ok, ^event} = Log.append(event, workspace: ws)

    lease_path = Paths.session_lease(sid, ws)
    Paths.ensure_session_leases_dir(ws)

    File.write!(
      lease_path,
      Jason.encode!(%{
        "version" => 1,
        "purpose" => "session_writer",
        "session_id" => sid,
        "workspace" => Path.expand(ws),
        "lease_path" => lease_path,
        "holder_id" => "stale_holder",
        "heartbeat_at_ms" => System.system_time(:millisecond) - 60_000,
        "heartbeat_at" => "2026-01-01T00:00:00Z",
        "stale_after_ms" => 1
      })
    )

    assert {:error, %{error: %{kind: :session_writer_stale}}} =
             Conversation.start(id: sid, workspace: ws)

    assert {:ok, ^sid} =
             Conversation.start(
               id: sid,
               workspace: ws,
               force_release_writer_lease?: true,
               force_release_reason: "conversation_test"
             )

    on_exit(fn ->
      case Registry.lookup(Pixir.Sessions.Registry, sid) do
        [{pid, _}] -> DynamicSupervisor.terminate_child(Pixir.SessionSupervisor, pid)
        [] -> :ok
      end
    end)

    assert [release_record] =
             Path.wildcard(Path.join([ws, ".pixir", "session_leases", "releases", "*.json"]))

    assert %{"kind" => "session_writer_lease_forced_release"} =
             release_record |> File.read!() |> Jason.decode!()
  end

  test "start with a missing :id is a structured not_found error", %{ws: ws} do
    assert {:error, %{ok: false, error: %{kind: :not_found, details: %{id: "nope-123"}}}} =
             Conversation.start(id: "nope-123", workspace: ws)
  end

  test "start surfaces a corrupt log as a structured error, not a crash", %{ws: ws} do
    Pixir.Paths.ensure_sessions_dir(ws)
    File.write!(Log.path("badsess", workspace: ws), "{not json}\n")

    assert {:error, %{ok: false, error: %{kind: kind}}} =
             Conversation.start(id: "badsess", workspace: ws)

    assert kind in [:corrupt_log_line, :session_start_failed]
  end

  test "await treats an interrupted turn as terminal (ADR 0008)", %{ws: ws} do
    {:ok, sid} = Conversation.start(workspace: ws)
    :ok = Conversation.subscribe(sid)

    {:ok, _ref} = Conversation.send(sid, "loop", provider: BlockingProvider)
    # Give the turn a moment to start, then interrupt.
    Process.sleep(100)
    :ok = Conversation.interrupt(sid)

    assert :interrupted = Conversation.await(sid, idle_timeout: 2_000)
  end
end
