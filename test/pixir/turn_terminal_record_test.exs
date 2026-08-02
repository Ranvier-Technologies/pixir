defmodule Pixir.TurnTerminalRecordTest do
  @moduledoc """
  #470: a terminal record must never out-crash the Turn it is reporting.

  `finish_provider_error/3` (and its `finish_configuration_error/2` /
  `finish_tool_error/2` siblings) recorded `turn_failed` with a bare
  `Session.record/2`. Against a Session that died mid-Turn, that `GenServer.call`
  exits `:noproc` instead of returning `{:error, map}`, so the Turn Task died in
  its own terminal path without ever returning the structured error it was built
  to report. The tests here pin the honest degraded behavior: the ORIGINAL
  provider error comes back as a value, and the unrecordable evidence is logged
  with a bounded failure class.
  """

  use ExUnit.Case, async: false

  alias Pixir.{Session, SessionSupervisor, Turn}

  setup do
    ws =
      Path.join(
        System.tmp_dir!(),
        "pixir-470-" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
      )

    File.mkdir_p!(ws)
    {:ok, sid, pid} = SessionSupervisor.start_session(workspace: ws, role: :build)

    on_exit(fn ->
      if Process.alive?(pid), do: DynamicSupervisor.terminate_child(SessionSupervisor, pid)
      File.rm_rf!(ws)
    end)

    %{ws: ws, sid: sid}
  end

  # A transport that announces itself, then blocks until the test says go, then fails
  # the request in-band (`invalid_request_error` over HTTP 200, no `param` gate, so it
  # classifies as a plain non-retryable `:provider_http_error`). The cue is what lets
  # the test kill the Session strictly BETWEEN the Turn's opening `user_message`
  # record (which needs a live Session) and the terminal `turn_failed` record under
  # test. With `emit_text: true` a text delta goes out before the block, driving the
  # partial-text branch of `finish_provider_error/3`.
  defp fail_on_cue(opts \\ []) do
    test_pid = self()
    emit_text? = Keyword.get(opts, :emit_text, false)

    fn _http_request, acc, fun ->
      acc = fun.({:status, 200}, acc)

      acc =
        if emit_text? do
          fun.({:data, sse(%{type: "response.output_text.delta", delta: "partial answer"})}, acc)
        else
          acc
        end

      send(test_pid, {:awaiting_cue, self()})

      receive do
        :fail_now -> :ok
      end

      acc =
        fun.(
          {:data,
           sse(%{
             type: "error",
             error: %{
               type: "invalid_request_error",
               code: nil,
               message: "the request was rejected terminally"
             }
           })},
          acc
        )

      {:ok, acc}
    end
  end

  defp sse(map), do: "data: " <> Jason.encode!(map) <> "\n\n"

  defmodule NoOAuth do
    def refresh_skew_ms, do: 60_000
  end

  defp start_auth(ws) do
    auth = :"auth_470_#{System.unique_integer([:positive])}"

    {:ok, _} =
      Pixir.Auth.start_link(
        name: auth,
        store_path: Path.join(ws, "#{auth}.json"),
        env_api_key: "sk-test",
        oauth: NoOAuth
      )

    auth
  end

  defp run_dead_session_turn(sid, ws, transport) do
    auth = start_auth(ws)

    turn =
      Task.async(fn ->
        Turn.run(
          # The Session is provably dead when the terminal record runs, so the
          # generation is inert here; it is stamped so the ctx stays
          # production-shaped (nil would mean "no identity claimed").
          %{session_id: sid, workspace: ws, role: :build, turn_generation: 1},
          "run it",
          provider: Pixir.Provider,
          provider_opts: [
            auth: auth,
            transport: transport,
            max_retries: 0,
            stream_idle_timeout_ms: :infinity
          ]
        )
      end)

    assert_receive {:awaiting_cue, stream_pid}, 5_000

    :ok = GenServer.stop(Session.via(sid), :normal)
    assert GenServer.whereis(Session.via(sid)) == nil

    send(stream_pid, :fail_now)
    Task.await(turn, 15_000)
  end

  test "a terminal provider error against a dead Session returns the error, not an exit",
       %{sid: sid, ws: ws} do
    log =
      ExUnit.CaptureLog.capture_log(fn ->
        result = run_dead_session_turn(sid, ws, fail_on_cue())

        assert {:error, %{error: %{kind: :provider_http_error}}} = result
      end)

    assert log =~ "terminal turn_failed could not be recorded"
  end

  test "the partial-text branch degrades both records and still returns the error",
       %{sid: sid, ws: ws} do
    log =
      ExUnit.CaptureLog.capture_log(fn ->
        result = run_dead_session_turn(sid, ws, fail_on_cue(emit_text: true))

        assert {:error, %{error: %{kind: :provider_http_error}}} = result
      end)

    assert log =~ "partial assistant text could not be recorded on a failed turn"
    assert log =~ "terminal turn_failed could not be recorded"
  end

  # A Session that behaves normally except for the terminal record: a `turn_failed`
  # `{:record, _}` is swallowed without a reply, so the caller's `GenServer.call`
  # runs into its 5s timeout — the stalled-but-alive shape, as opposed to the dead
  # `:noproc` shape the tests above pin.
  defmodule StallOnTurnFailedSession do
    use GenServer

    def start_link(sid),
      do: GenServer.start_link(__MODULE__, sid, name: Pixir.Session.via(sid))

    @impl true
    def init(sid), do: {:ok, sid}

    @impl true
    def handle_call({:record, %{type: :turn_failed}}, _from, state), do: {:noreply, state}
    def handle_call({:record, event}, _from, state), do: {:reply, {:ok, event}, state}
    def handle_call(:history, _from, state), do: {:reply, {:ok, []}, state}
    def handle_call(_other, _from, state), do: {:reply, :ok, state}

    @impl true
    def handle_cast(_msg, state), do: {:noreply, state}
  end

  @tag timeout: 30_000
  test "a record that stalls past the call timeout degrades instead of exiting",
       %{sid: sid, ws: ws} do
    # Replace the real Session with the stalling stub under the same via-name.
    :ok = GenServer.stop(Session.via(sid), :normal)
    assert GenServer.whereis(Session.via(sid)) == nil
    start_supervised!({StallOnTurnFailedSession, sid})

    auth = start_auth(ws)
    test_pid = self()

    failing_transport = fn _http_request, acc, fun ->
      send(test_pid, :transport_ran)
      acc = fun.({:status, 400}, acc)
      acc = fun.({:data, ~s({"error":{"type":"invalid_request_error","message":"nope"}})}, acc)
      {:ok, acc}
    end

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        result =
          Turn.run(
            %{session_id: sid, workspace: ws, role: :build, turn_generation: 1},
            "run it",
            provider: Pixir.Provider,
            provider_opts: [auth: auth, transport: failing_transport, max_retries: 0]
          )

        assert_received :transport_ran
        assert {:error, %{error: %{kind: :provider_http_error}}} = result
      end)

    assert log =~ "terminal turn_failed could not be recorded"
  end
end
