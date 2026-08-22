defmodule Pixir.TurnCancelDrainRecoveryTest do
  @moduledoc """
  #462: cancelling a Turn mid-stream must not poison the Session.

  The failure class is a function call the Provider committed and Pixir never persisted.
  The Responses API then rejects the next request with "No tool output found for function
  call <id>" for an id that appears in no Log event, and the follow-up Turn dies.

  Two layers are covered here:

    * **layer 1, drain-to-persistence** — on cancellation the calls the Provider
      committed are in the Session's hands, so they reach the Log even though the Turn
      Task is killed outright;
    * **layer 2, build-time recovery** — a rejection naming an unknown call id is
      classified structurally, healed once with a synthesized cancelled output, and the
      synthesis is durable Log evidence.
  """

  use ExUnit.Case, async: false

  alias Pixir.{Event, Log, Session, SessionSupervisor, Turn}

  # Read from Turn itself, not re-declared: a re-declared literal keeps passing against a
  # stale number if the budget moves, and the ADR 0036 circuit-breaker claim would go
  # unverified. The total number of dangling-call recoveries one Turn may perform across
  # *all* ids — see the attribute's own comment in `Pixir.Turn`.
  @dangling_recovery_budget Turn.dangling_call_recovery_budget()
  # The reproduction recipe's call count. A Log poisoned by a pre-fix binary can be
  # missing this many outputs, so the budget must cover it.
  @reproduction_call_count 7

  setup do
    ws =
      Path.join(
        System.tmp_dir!(),
        "pixir-462-" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
      )

    File.mkdir_p!(ws)
    {:ok, sid, pid} = SessionSupervisor.start_session(workspace: ws, role: :build)
    # `await_tool_call/3` blocks on the Session's own event stream rather than polling.
    :ok = Pixir.Events.subscribe(sid)

    on_exit(fn ->
      if Process.alive?(pid), do: DynamicSupervisor.terminate_child(SessionSupervisor, pid)
      File.rm_rf!(ws)
    end)

    %{ws: ws, sid: sid, ctx: %{session_id: sid, workspace: ws, role: :build}}
  end

  # ── stubs ─────────────────────────────────────────────────────────────────

  # Returns one batch of function calls, then blocks forever. Modelling the *during
  # execution* window: the Provider commits several sequential calls, the Executor works
  # through them one at a time, and the cancel lands while a later call is still only
  # Provider-side. This is a real window, but it is NOT the reproduced one — see the
  # canned-transport test below for the mid-stream window the issue reports.
  defmodule BatchThenBlockProvider do
    def stream(_request, opts) do
      test_pid = Keyword.fetch!(opts, :test_pid)
      calls = Keyword.fetch!(opts, :calls)

      send(test_pid, :provider_round)

      {:ok,
       %{
         text: "",
         reasoning: "",
         function_calls: calls,
         finish_reason: :tool_calls,
         usage_summary: Pixir.Provider.usage_summary(nil)
       }}
    end
  end

  # Pops scripted results, and reports every request's input so a test can assert what
  # the rebuilt request carried.
  defmodule ScriptedProvider do
    def stream(request, opts) do
      agent = Keyword.fetch!(opts, :agent)
      test_pid = Keyword.fetch!(opts, :test_pid)
      send(test_pid, {:request, request})

      case Agent.get_and_update(agent, fn [head | tail] -> {head, tail} end) do
        {:ok, map} when is_map(map) ->
          {:ok, Map.put_new(map, :usage_summary, Pixir.Provider.usage_summary(map[:usage]))}

        other ->
          other
      end
    end
  end

  # Names a DIFFERENT dangling id every round — what the Responses validator really does
  # when several outputs are missing, since it reports one at a time. Defined at module
  # scope like the other stubs: a `defmodule` inside a test body redefines the module on
  # every run, and a redefinition warning is an error under warnings-as-errors.
  defmodule EndlessDistinctDanglingProvider do
    def stream(_request, opts) do
      counter = Keyword.fetch!(opts, :counter)
      test_pid = Keyword.fetch!(opts, :test_pid)
      n = Agent.get_and_update(counter, &{&1, &1 + 1})
      send(test_pid, :provider_round)

      {:error,
       %{
         ok: false,
         error: %{
           kind: :dangling_tool_call,
           message: "No tool output found for function call call_ghost_#{n}.",
           details: %{
             status: 200,
             event_type: "error",
             type: "invalid_request_error",
             code: nil,
             param: "input",
             call_id: "call_ghost_#{n}"
           }
         }
       }}
    end
  end

  defp stop(text),
    do: {:ok, %{text: text, reasoning: "", function_calls: [], finish_reason: :stop}}

  # The exact in-band shape observed in the reproduction: HTTP 200, `event_type: "error"`,
  # `type: "invalid_request_error"`, `param: "input"`, id named in the message.
  defp dangling_call_error(call_id) do
    {:error,
     %{
       ok: false,
       error: %{
         kind: :dangling_tool_call,
         message: "No tool output found for function call #{call_id}.",
         details: %{
           status: 200,
           event_type: "error",
           type: "invalid_request_error",
           code: nil,
           param: "input",
           call_id: call_id
         }
       }
     }}
  end

  # The compound identity a Session really hands out, read from a GENUINELY started
  # Turn's own ctx rather than assembled from literals (#462 CR, #471). The probe Turn is
  # a no-op that returns at once, so the Session is idle again before this returns.
  defp started_turn_identity(sid) do
    test_pid = self()
    {:ok, _ref} = Session.start_turn(sid, fn ctx -> send(test_pid, {:probe_ctx, ctx}) end)

    assert_receive {:probe_ctx,
                    %{
                      session_incarnation: session_incarnation,
                      turn_generation: generation
                    }},
                   5_000

    # The Task ref `start_turn/2` returns belongs to the SESSION, which is the process that
    # awaits the Turn — the test never receives on it. So the wait for the probe Turn to be
    # released is on the Session's own observable state instead.
    wait_until_idle(sid)
    {session_incarnation, generation}
  end

  defp wait_until_idle(sid, attempts \\ 100) do
    cond do
      not match?(%{turn_running?: true}, Session.info(sid)) -> :ok
      attempts > 0 -> Process.sleep(10) && wait_until_idle(sid, attempts - 1)
      true -> flunk("the probe Turn never released the Session")
    end
  end

  defp run_scripted(ctx, prompt, script) do
    {:ok, agent} = Agent.start_link(fn -> script end)

    Turn.run(ctx, prompt,
      provider: ScriptedProvider,
      provider_opts: [agent: agent, test_pid: self()]
    )
  end

  # ── layer 1: drain-to-persistence ─────────────────────────────────────────

  # THE reproduced window. The provider stream has emitted a completed `function_call`
  # output item — the call is committed on the wire, the model will expect an output for
  # it — and the stream is then still open when `session/cancel` arrives. Pre-fix the call
  # lived only in the stream accumulator inside the Turn Task, which
  # `Task.Supervisor.terminate_child/2` kills brutally, so it reached no Log event and the
  # next request omitted its output.
  #
  # This drives the REAL `Pixir.Provider` over a canned transport (not a stub provider
  # module) precisely because a stub cannot reach the stream window: it has already
  # returned by the time the Turn sees anything.
  test "cancelling while the stream is still open persists the call committed on the wire",
       %{sid: sid, ws: ws} do
    auth = start_auth()
    test_pid = self()
    # Built HERE, in the test process: the transport closure captures `self()` so it can
    # announce each committed call back to the test. Building it inside the Turn closure
    # would capture the Turn Task instead and the announcements would go nowhere.
    transport = commit_then_block(["call_midstream"])

    {:ok, _ref} =
      Session.start_turn(sid, fn turn_ctx ->
        send(
          test_pid,
          {:turn_runtime_identity, turn_ctx.session_incarnation, turn_ctx.turn_generation}
        )

        Turn.run(turn_ctx, "run a command",
          provider: Pixir.Provider,
          provider_opts: [
            auth: auth,
            transport: transport,
            max_retries: 0,
            # Keep the stream in-process and open indefinitely: the idle watchdog must
            # not tear it down before the interrupt lands, or the test would be
            # measuring the watchdog rather than the cancel.
            stream_idle_timeout_ms: :infinity
          ]
        )
      end)

    assert_receive {:turn_runtime_identity, session_incarnation, 1}, 5_000
    assert is_reference(session_incarnation)

    # The call is on the wire and the stream has NOT returned. This is the kill window.
    assert_receive {:call_committed_on_the_wire, "call_midstream"}, 5_000

    assert {:ok, pre_history} = Log.fold(sid, workspace: ws)

    refute Enum.any?(pre_history, &(&1.type == :tool_call)),
           "precondition: the call must not be persisted by the Turn yet"

    assert :ok = Session.interrupt(sid)

    assert {:ok, history} = Log.fold(sid, workspace: ws)
    logged = Enum.map(history, &{&1.type, &1.data["call_id"]})

    assert {:tool_call, "call_midstream"} in logged,
           "the call committed mid-stream never reached the Log: #{inspect(logged)}"

    assert {:tool_result, "call_midstream"} in logged,
           "the drained call has no closing tool_result: #{inspect(logged)}"

    drained =
      Enum.find(history, &(&1.type == :tool_call and &1.data["call_id"] == "call_midstream"))

    # `"interrupt"` is load-bearing, not incidental (#462 CR). It is the reason written by
    # the ACCUMULATE-then-interrupt-drain path — the production one: the declaration
    # matched the live Turn's compound runtime identity, was held in `committed_calls`,
    # and was drained when `interrupt/1` killed the Turn. The Session's *straggler* clause
    # writes `"declared_without_turn"` (no Turn), `"stale_turn_generation"` (wrong runtime
    # identity), or `"unstamped_declaration"` (no identity during a live Turn) instead.
    # Seeing one here would mean Turn stopped transporting the process incarnation paired
    # with the numeric generation.
    assert drained.data["drained"]["reason"] == "interrupt"
    assert drained.data["name"] == "bash"

    result =
      Enum.find(history, &(&1.type == :tool_result and &1.data["call_id"] == "call_midstream"))

    assert result.data["ok"] == false
    assert result.data["error"]["kind"] == "orphan_tool_call"

    assert [failure] = Enum.filter(history, &(&1.type == :turn_failed))
    assert failure.data["terminal_status"] == "interrupted"
    assert failure.data["error_kind"] == "interrupted"
    assert failure.data["details"] == %{"scope" => "turn"}

    raw = File.read!(Log.path(sid, workspace: ws))
    decoded = raw |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)

    assert Enum.map(decoded, & &1["type"]) == [
             "user_message",
             "tool_call",
             "tool_result",
             "turn_failed"
           ]

    assert Enum.count(decoded, &(&1["type"] == "turn_failed")) == 1
    assert Enum.at(decoded, 3)["data"]["terminal_status"] == "interrupted"

    refute raw =~ inspect(session_incarnation)
    refute raw =~ "session_incarnation"
    refute raw =~ "turn_identity"
    refute raw =~ "#Reference"
  end

  # #462 round 3: the declare hand-off is a synchronous `GenServer.call`, and against a
  # gone Session `GenServer.call` EXITS with `{:noproc, …}` — it does not return
  # `{:error, map}`. Pre-fix that exit escaped the stream reducer, out of `stream/2`, and
  # killed the Turn: the very outcome the swallow's own comment claimed to avoid. Before
  # this PR nothing in the stream path called the Session synchronously, so a dead Session
  # was harmless mid-stream; the declare made it fatal. It must be a logged, structured
  # failure instead.
  test "a Session gone at declare time does not kill the stream over bookkeeping", %{
    sid: sid,
    ws: ws
  } do
    auth = start_auth()
    # The stream stalls until the test says go, so the declare provably happens with the
    # Session already gone — the exact `:noproc` window.
    transport = commit_on_cue("call_orphaned")

    # #462 CR / #471: the ctx carries the REAL compound runtime identity taken from a ctx
    # `Session.start_turn/2` built, not `nil` and not literals. The Turn cannot itself run
    # *under* `start_turn/2` here, and the reason is worth stating so nobody "fixes" it
    # back: `Session.terminate/2` calls `terminate_active_turn/1`, so the `GenServer.stop`
    # below would kill the Turn Task, and with `stream_idle_timeout_ms: :infinity`
    # `StreamIdle.run/3` streams IN-PROCESS (no `spawn_monitor`) — the open stream would
    # die with the Task before the cue could be consumed. That watchdog-free in-process
    # stream is the very window being reproduced. What this test measures is unaffected
    # either way: the Session is provably GONE when the declare runs, so the declare exits
    # `:noproc` before any identity comparison can happen. The stamp is here so the ctx is
    # production-shaped, not because the outcome turns on its value.
    {session_incarnation, generation} = started_turn_identity(sid)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        turn =
          Task.async(fn ->
            Turn.run(
              %{
                session_id: sid,
                workspace: ws,
                role: :build,
                session_incarnation: session_incarnation,
                turn_generation: generation
              },
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

        send(stream_pid, :commit_now)

        # The declare is the very next thing the reducer does after the item completes, and
        # the transport announces the completed item straight after handing it over. Waiting
        # for that announcement pins the ordering: the declare provably ran against the
        # dead Session before the restart below can win the race.
        assert_receive {:committed_on_the_wire, "call_orphaned"}, 5_000

        # The stream RUNS TO COMPLETION over the dead Session and the Turn comes back with
        # a value. Pre-fix the declare's `GenServer.call` exited `{:noproc, …}` from inside
        # the reducer; StreamIdle caught it and turned the whole stream into a
        # `:transport_process_exited` `:network` error — a bookkeeping failure reported as
        # a retryable transport blip, and the committed call never even reached the
        # accumulator. The Turn is restarted over a live Session so its own terminal record
        # (an unrelated, pre-existing bare-record path) is not what this test measures.
        # This is a SECOND Session process for the same sid; the setup's `on_exit` closed
        # over the ORIGINAL pid and would never reap it. Left running, it outlives the test
        # and dies later inside another test's window (this module is `async: false`),
        # spraying `session_writer_lease_lost` noise into an unrelated capture. Register its
        # own cleanup, tolerating an already-dead process.
        {:ok, ^sid, restarted_pid} = SessionSupervisor.start_session(id: sid, workspace: ws)

        on_exit(fn ->
          if Process.alive?(restarted_pid),
            do: DynamicSupervisor.terminate_child(SessionSupervisor, restarted_pid)
        end)

        result = Task.await(turn, 15_000)

        refute match?({:error, %{error: %{kind: :network}}}, result),
               "the declare failure was reported as a retryable transport error: " <>
                 inspect(result)

        # The stream itself finished: the call was assembled and the Turn moved on to
        # executing it, rather than dying inside the reducer.
        assert {:ok, history} = Log.fold(sid, workspace: ws)

        assert Enum.any?(
                 history,
                 &(&1.type == :tool_call and &1.data["call_id"] == "call_orphaned")
               ),
               "the stream never got past the declare: #{inspect(Enum.map(history, & &1.type))}"
      end)

    assert log =~ "committed tool call could not be declared mid-stream"
  end

  # A Session that dies at declare time with a reason NOT in the swallowed classes
  # (`:noproc`/`:normal`/`:shutdown`/`:timeout`). Registered under the Session's own via
  # name so the Turn's `Session.declare_committed_calls/3` reaches it unchanged; the other
  # calls the Turn makes before the stream are served honestly so the ONLY thing this stub
  # changes is the declare.
  defmodule ExplodingSession do
    use GenServer

    # Started under a supervisor, never directly by the test: this server stops with
    # `:kaboom` by design, and a link straight to the test process would propagate that
    # exit to the test instead of leaving the Turn to observe it. The supervisor restarts
    # it, so the Turn's own terminal record afterwards lands on a live Session.
    def start_link(sid), do: GenServer.start_link(__MODULE__, :ok, name: Pixir.Session.via(sid))

    @impl true
    def init(:ok), do: {:ok, :ok}

    @impl true
    def handle_call({:declare_committed_calls, _calls, _generation}, _from, state),
      do: {:stop, :kaboom, state}

    def handle_call(:history, _from, state), do: {:reply, {:ok, []}, state}
    def handle_call({:record, event}, _from, state), do: {:reply, {:ok, event}, state}
    def handle_call(_other, _from, state), do: {:reply, :ok, state}

    @impl true
    def handle_cast(_msg, state), do: {:noreply, state}
  end

  # #462 round 5: the "unclassified declare exits re-exit" rule was defeated by the layer
  # it re-exited INTO. `safe_declare_committed_call/3` runs inside
  # `Pixir.Provider.StreamIdle.run_stream/3`, whose `catch` maps every throw and exit to
  # `Tool.error(:network, …)` — and `:network` is exactly what `Pixir.Provider.attempt/5`
  # retries. So a real Session fault was reported to the caller as a transport blip AND
  # re-streamed, and the retried stream re-commits the calls the first attempt already
  # committed: the amplifier for the duplicate-declare poison. The failure must be
  # structured and NON-retryable instead.
  test "an unclassified Session failure at declare time is non-retryable, not a network blip",
       %{ws: ws} do
    auth = start_auth()
    sid = Session.gen_id()
    transport = commit_then_complete("call_boom")
    # Supervised, and restarted after it stops: the Turn's terminal `turn_failed` record
    # runs against a live Session so this test measures the declare classification and not
    # the unrelated bare-record path on the terminal write (#470, out of scope here).
    {:ok, sup} =
      Supervisor.start_link(
        [
          %{
            id: :exploding_session,
            start: {ExplodingSession, :start_link, [sid]},
            restart: :permanent
          }
        ],
        strategy: :one_for_one,
        max_restarts: 5,
        max_seconds: 5
      )

    # The alive? guard alone still races the stub's own self-stop: the supervisor can
    # be mid-shutdown when on_exit runs and `Supervisor.stop` then exits `:shutdown`
    # from the teardown itself (observed 1-in-3). Nothing under test depends on
    # teardown; tolerate the race the same way the declare-failure test below does.
    on_exit(fn ->
      try do
        if Process.alive?(sup), do: Supervisor.stop(sup, :normal)
      catch
        # Deliberately tolerant. A narrowed catch (:shutdown/:noproc only) was tried
        # per review and immediately missed a second, NESTED exit shape from
        # GenServer.stop racing :sys.terminate (observed live twice, different
        # shapes). Nothing under test depends on teardown; enumerating exit shapes
        # here is a losing game that only flakes the suite.
        :exit, _ -> :ok
      end
    end)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        # #462 CR / #471: a complete compound runtime identity is stamped. This Session
        # is a stub that cannot serve `start_turn`, so the opaque reference and generation
        # are supplied here; omitting either would make Turn declare under `nil`, and this
        # test would no longer exercise the production hand-off shape it claims to.
        result =
          Turn.run(
            %{
              session_id: sid,
              workspace: ws,
              role: :build,
              session_incarnation: make_ref(),
              turn_generation: 1
            },
            "run it",
            provider: Pixir.Provider,
            provider_opts: [
              auth: auth,
              transport: transport,
              # Retries ALLOWED on purpose: the assertion is that this error is not one of
              # them. Pinning `max_retries: 0` would prove nothing about retryability.
              max_retries: 2,
              sleep: fn _ms -> :ok end,
              stream_idle_timeout_ms: :infinity
            ]
          )

        assert {:error, %{error: %{kind: kind, details: details}}} = result

        refute kind == :network,
               "a Session bookkeeping fault was laundered into a retryable transport error"

        assert kind == :session_record_unavailable
        assert details["call_id"] == "call_boom"

        # #462 CR: the details carry a bounded CLASS, never the exit term. This Session
        # stops with the BARE atom `:kaboom`, which becomes the outermost tag of the
        # `GenServer.call` exit — a tag with no payload, so it is safe to name and is named.
        # (The tuple-tag case, where the classifier must refuse, is pinned by the redaction
        # test below.)
        assert details["failure_class"] == "unclassified_exit:kaboom"
        refute Map.has_key?(details, "reason")

        # Non-retryable per the Provider's own classifier, read from the Provider rather
        # than restated here: a rule copied into the test keeps passing if the rule moves.
        refute Pixir.Provider.retryable_error?(elem(result, 1)),
               "the declare failure classified as retryable: #{inspect(result)}"

        # And the stream really did run ONCE. A retry would re-commit `call_boom` on the
        # wire, which is what the transport announces.
        assert_receive {:call_committed_on_the_wire, "call_boom"}, 5_000
        refute_receive {:call_committed_on_the_wire, "call_boom"}, 300
      end)

    assert log =~ "committed tool call declaration failed with an unclassified Session exit"
  end

  # A Session that explodes on declare like `ExplodingSession`, but which also APPENDS to a
  # real Log, so the durable `turn_failed` this failure produces can be read back off disk.
  # `ExplodingSession` echoes records without persisting them, which is fine for a test
  # about classification and useless for one about what ends up written down.
  defmodule PersistingExplodingSession do
    use GenServer

    def start_link({sid, ws}),
      do: GenServer.start_link(__MODULE__, {sid, ws}, name: Pixir.Session.via(sid))

    @impl true
    def init({sid, ws}), do: {:ok, %{sid: sid, ws: ws, seq: 0}}

    # Stops with a reason that carries a PAYLOAD, the way a real crash inside
    # `handle_call/3` does. What matters for the redaction is not this term but the exit
    # `GenServer.call` synthesizes around it: `{reason, {GenServer, :call, [name, request,
    # timeout]}}`, where `request` is `{:declare_committed_calls, calls, generation}` and
    # `calls` carries the tool ARGUMENTS.
    @impl true
    def handle_call({:declare_committed_calls, _calls, _generation}, _from, state),
      do: {:stop, {:kaboom, %{internal: "session internal state"}}, state}

    def handle_call(:history, _from, %{sid: sid, ws: ws} = state),
      do: {:reply, Pixir.Log.fold(sid, workspace: ws), state}

    def handle_call({:record, event}, _from, %{ws: ws, seq: seq} = state) do
      stamped = %{event | seq: seq}
      {:ok, _} = Pixir.Log.append(stamped, workspace: ws)
      {:reply, {:ok, stamped}, %{state | seq: seq + 1}}
    end

    def handle_call(_other, _from, state), do: {:reply, :ok, state}

    @impl true
    def handle_cast(_msg, state), do: {:noreply, state}
  end

  # #462 CR (redaction). The declare hand-off is a `GenServer.call`, and the exit reason
  # `GenServer.call` raises embeds the REQUEST — `{:declare_committed_calls, [call], gen}`
  # — so the tool call's ARGUMENTS are inside it. `inspect(reason)` therefore put whatever
  # the model asked the tool to do (a shell command, a path, a pasted secret, a URL with a
  # token) onto a Logger metadata line AND, on the unclassified path, into the durable
  # `turn_failed` details, which outlive the process and are read by presenters. Only a
  # bounded failure CLASS may escape.
  #
  # The sentinel is planted in the call's arguments, where a real secret would be, and the
  # assertion is absence — in the captured log, in the structured error the Turn returns,
  # and in the Log on disk.
  test "a declare failure never leaks the tool call's arguments to a log or the Log", %{ws: ws} do
    auth = start_auth()
    sid = Session.gen_id()
    sentinel = "SECRET_ARG_SENTINEL"
    transport = commit_with_args("call_redacted", ~s({"command":"echo #{sentinel}"}))

    {:ok, sup} =
      Supervisor.start_link(
        [
          %{
            id: :persisting_exploding_session,
            start: {PersistingExplodingSession, :start_link, [{sid, ws}]},
            restart: :permanent
          }
        ],
        strategy: :one_for_one,
        max_restarts: 5,
        max_seconds: 5
      )

    # Tolerant teardown: the stub Session stops itself by design, so the supervisor may be
    # mid-restart when `on_exit` runs and `Supervisor.stop/2` then exits `:shutdown` in the
    # *test* process, failing an otherwise-passing test. Nothing under test depends on how
    # this shuts down.
    on_exit(fn ->
      if Process.alive?(sup) do
        try do
          Supervisor.stop(sup, :normal, 5_000)
        catch
          # Same deliberate tolerance as the sibling teardown above.
          :exit, _ -> :ok
        end
      end
    end)

    {result, log} =
      ExUnit.CaptureLog.with_log(fn ->
        Turn.run(
          %{
            session_id: sid,
            workspace: ws,
            role: :build,
            session_incarnation: make_ref(),
            turn_generation: 1
          },
          "run it",
          provider: Pixir.Provider,
          provider_opts: [
            auth: auth,
            transport: transport,
            max_retries: 0,
            sleep: fn _ms -> :ok end,
            stream_idle_timeout_ms: :infinity
          ]
        )
      end)

    # Precondition: the failure under test really is the unclassified declare path. Without
    # this the absence assertions below would pass vacuously on any unrelated outcome.
    assert log =~ "committed tool call declaration failed with an unclassified Session exit"
    assert {:error, %{error: %{kind: :session_record_unavailable, details: details}}} = result
    assert details["call_id"] == "call_redacted"

    # Pixir's OWN log lines. The one line in this capture that does carry the arguments is
    # the OTP crash report the *Session process itself* emits as it dies
    # ("Last message (from …)"), which `:gen_server` writes from inside the dying process
    # and which no code at the declare site can influence; it is excluded by name so this
    # assertion measures what Pixir writes, and only that. Everything Pixir emits about
    # this failure must be argument-free.
    pixir_log_lines =
      log
      |> String.split("\n")
      |> Enum.reject(&(&1 =~ "Last message" or &1 =~ "State:" or &1 =~ "Client " or &1 =~ "**"))
      |> Enum.join("\n")

    refute pixir_log_lines =~ sentinel,
           "the tool call's arguments reached a Pixir log line:\n" <>
             Enum.map_join(String.split(pixir_log_lines, "\n"), "\n", fn l ->
               if l =~ sentinel, do: ">>> " <> l, else: ""
             end)

    # The specific lines this PR added must be clean, checked by name rather than only by
    # the bulk filter above: a filter that grows lax would silently stop testing anything.
    for line <- String.split(log, "\n"),
        line =~ "committed tool call declaration failed with an unclassified Session exit" or
          line =~ "committed tool call could not be declared mid-stream" do
      refute line =~ sentinel, "a #462 declare-failure log line carried the tool arguments"
    end

    refute inspect(result) =~ sentinel,
           "the tool call's arguments reached the structured error the Turn returned"

    # The durable side. `turn_failure_data/2` copies the error's details verbatim into
    # `turn_failed.details`, so a leaked argument would be on disk forever.
    assert {:ok, history} = Log.fold(sid, workspace: ws)

    refute Enum.any?(history, &(Jason.encode!(&1.data) =~ sentinel)),
           "the tool call's arguments reached a durable Log event: " <>
             inspect(Enum.map(history, & &1.type))

    # And what DID escape is a bounded class, not a rendered term. This Session stops with
    # `{:kaboom, %{internal: …}}`, so the exit's outermost tag is a TUPLE, not a bare atom
    # — the classifier refuses to name it and collapses to the generic class. That refusal
    # is the safety property: a tag with a payload is never partially rendered.
    assert details["failure_class"] == "unclassified_exit"
    refute details["failure_class"] =~ "session internal state"

    # The old key is gone, not merely emptied. `"reason"` held `inspect(exit_reason)` and
    # was the leak; a test that only checked its *contents* would pass again the moment
    # anyone reinstated it with a differently-shaped term.
    refute Map.has_key?(details, "reason")
  end

  # The consequence that matters: the next request is one the Provider accepts, because
  # every `function_call` in it carries a matching `function_call_output`.
  test "a Session cancelled mid-stream builds a next request the Provider accepts", %{
    ctx: ctx,
    sid: sid,
    ws: ws
  } do
    auth = start_auth()
    transport = commit_then_block(["call_midstream"])

    {:ok, _ref} =
      Session.start_turn(sid, fn turn_ctx ->
        Turn.run(turn_ctx, "run a command",
          provider: Pixir.Provider,
          provider_opts: [
            auth: auth,
            transport: transport,
            max_retries: 0,
            stream_idle_timeout_ms: :infinity
          ]
        )
      end)

    assert_receive {:call_committed_on_the_wire, "call_midstream"}, 5_000
    assert :ok = Session.interrupt(sid)

    assert {:ok, "recovered"} = run_scripted(ctx, "what happened?", [stop("recovered")])

    assert_receive {:request, %{history: history}}, 2_000
    items = folded_input(history, ws)

    assert Enum.any?(
             items,
             &(&1["type"] == "function_call" and &1["call_id"] == "call_midstream")
           )

    assert Enum.any?(
             items,
             &(&1["type"] == "function_call_output" and &1["call_id"] == "call_midstream")
           ),
           "no output item for the mid-stream call — this is the shape the Provider rejects"

    assert {:ok, _} = Log.fold(sid, workspace: ws)
  end

  # A multi-call batch in the same window: the Provider commits three calls on the wire
  # and the stream stays open. Every one of them is committed provider-side and none has
  # been executed, so all three must survive the kill.
  test "cancelling mid-stream persists every call the Provider committed in the batch", %{
    sid: sid,
    ws: ws
  } do
    auth = start_auth()
    ids = ["call_first", "call_second", "call_third"]
    transport = commit_then_block(ids)

    {:ok, _ref} =
      Session.start_turn(sid, fn turn_ctx ->
        Turn.run(turn_ctx, "run three commands",
          provider: Pixir.Provider,
          provider_opts: [
            auth: auth,
            transport: transport,
            max_retries: 0,
            stream_idle_timeout_ms: :infinity
          ]
        )
      end)

    for call_id <- ids do
      assert_receive {:call_committed_on_the_wire, ^call_id}, 5_000
    end

    assert :ok = Session.interrupt(sid)

    assert {:ok, history} = Log.fold(sid, workspace: ws)
    logged = Enum.map(history, &{&1.type, &1.data["call_id"]})

    # Every committed call reaches the Log with a closing tool_result. Without this the
    # next request omits them and the Provider rejects it.
    for call_id <- ids do
      assert {:tool_call, call_id} in logged,
             "#{call_id} never reached the Log: #{inspect(logged)}"

      assert {:tool_result, call_id} in logged,
             "#{call_id} has no tool_result: #{inspect(logged)}"
    end

    # Declaration order is preserved, so the drained calls replay in wire order.
    drained = Enum.filter(history, &(&1.type == :tool_call and is_map(&1.data["drained"])))
    assert Enum.map(drained, & &1.data["call_id"]) == ids
    assert Enum.all?(drained, &(&1.data["drained"]["reason"] == "interrupt"))

    for call_id <- ids do
      result = Enum.find(history, &(&1.type == :tool_result and &1.data["call_id"] == call_id))
      assert result.data["ok"] == false
      assert result.data["error"]["kind"] == "orphan_tool_call"
      assert result.data["error"]["details"]["reason"] == "interrupt"
    end
  end

  # #462 round 5: the Provider's OWN retry re-emits calls the first attempt already
  # committed. The declare hand-off fires per completed `function_call` output item, so
  # attempt 2 declares `call_retry` a SECOND time against the same live Turn (same
  # generation, so the accumulate clause, not the straggler clause). Pre-fix the
  # accumulate clause appended blindly and the drain's `seen` set was computed once from
  # the Log before the fold, so neither the declaration list nor the drain deduped: the
  # interrupt wrote TWO `tool_call` events for one id and the reconciliation closed it with
  # ONE result. The next request then carried two `function_call` items and one
  # `function_call_output` — precisely the shape the Responses API rejects, and one layer 2
  # REFUSES to heal because `persisted_call_id?/2` is true for the id. Permanent poison,
  # the exact class #462 exists to end.
  test "a provider retry that re-commits a call drains it exactly once", %{
    ctx: ctx,
    sid: sid,
    ws: ws
  } do
    auth = start_auth()
    transport = commit_then_transient_then_recommit("call_retry")

    {:ok, _ref} =
      Session.start_turn(sid, fn turn_ctx ->
        Turn.run(turn_ctx, "run a command",
          provider: Pixir.Provider,
          provider_opts: [
            auth: auth,
            transport: transport,
            # The retry is the point of the test, so it must be allowed to happen.
            max_retries: 1,
            sleep: fn _ms -> :ok end,
            stream_idle_timeout_ms: :infinity
          ]
        )
      end)

    # Both attempts committed the same id on the wire: the double declare has happened.
    assert_receive {:call_committed_on_the_wire, "call_retry", 1}, 5_000
    assert_receive {:call_committed_on_the_wire, "call_retry", 2}, 5_000

    assert :ok = Session.interrupt(sid)

    assert {:ok, history} = Log.fold(sid, workspace: ws)

    calls =
      Enum.filter(history, &(&1.type == :tool_call and &1.data["call_id"] == "call_retry"))

    assert length(calls) == 1,
           "the retried call was persisted #{length(calls)} times: " <>
             inspect(Enum.map(history, &{&1.type, &1.data["call_id"]}))

    results =
      Enum.filter(history, &(&1.type == :tool_result and &1.data["call_id"] == "call_retry"))

    assert length(results) == 1
    assert hd(results).data["error"]["kind"] == "orphan_tool_call"

    # The consequence: the rebuilt request is one the Provider accepts. A second
    # `function_call` with no second output is the rejection shape, and layer 2 cannot heal
    # it because the id IS persisted.
    assert {:ok, "recovered"} = run_scripted(ctx, "what happened?", [stop("recovered")])

    assert_receive {:request, %{history: next_history}}, 2_000
    items = folded_input(next_history, ws)

    function_calls =
      Enum.filter(items, &(&1["type"] == "function_call" and &1["call_id"] == "call_retry"))

    outputs =
      Enum.filter(
        items,
        &(&1["type"] == "function_call_output" and &1["call_id"] == "call_retry")
      )

    assert length(function_calls) == 1,
           "the next request carries #{length(function_calls)} function_call items for one id"

    assert length(outputs) == 1
  end

  # The during-execution window, which the pre-existing orphan reconciliation already
  # covered: a call that WAS persisted before the kill still gets its closing result.
  # Kept as a guard that layer 1 did not regress that path (a stub provider is fine here
  # precisely because this window is reached after `stream/2` has returned).
  test "a call already persisted when the kill lands is still reconciled", %{
    sid: sid,
    ws: ws
  } do
    test_pid = self()

    calls = [%{call_id: "call_ran", name: "bash", args: %{"command" => "sleep 5"}}]

    {:ok, _ref} =
      Session.start_turn(sid, fn turn_ctx ->
        Turn.run(turn_ctx, "one command",
          provider: BatchThenBlockProvider,
          provider_opts: [test_pid: test_pid, calls: calls]
        )
      end)

    assert_receive :provider_round, 2_000
    await_tool_call(sid, ws, "call_ran")
    assert :ok = Session.interrupt(sid)

    assert {:ok, history} = Log.fold(sid, workspace: ws)

    result = Enum.find(history, &(&1.type == :tool_result and &1.data["call_id"] == "call_ran"))
    assert result, "the persisted call was never reconciled"
    assert result.data["error"]["kind"] == "orphan_tool_call"
    assert result.data["error"]["details"]["reason"] == "interrupt"
  end

  # ── layer 2: build-time recovery ──────────────────────────────────────────

  test "a dangling-call rejection is healed once with a synthesized output", %{
    ctx: ctx,
    sid: sid,
    ws: ws
  } do
    script = [dangling_call_error("call_ghost"), stop("recovered")]

    assert {:ok, "recovered"} = run_scripted(ctx, "follow up", script)

    assert {:ok, history} = Log.fold(sid, workspace: ws)

    call = Enum.find(history, &(&1.type == :tool_call and &1.data["call_id"] == "call_ghost"))
    assert call, "the synthesized tool_call is not in the Log"
    assert call.data["synthesized"]["reason"] == "provider_dangling_tool_call"

    result = Enum.find(history, &(&1.type == :tool_result and &1.data["call_id"] == "call_ghost"))
    assert result.data["ok"] == false
    assert result.data["error"]["kind"] == "orphan_tool_call"
    assert result.data["error"]["details"]["reason"] == "provider_dangling_tool_call"

    # Exactly two provider rounds: the rejected one and the single retry.
    assert_receive {:request, _first}, 2_000
    assert_receive {:request, _retry}, 2_000
    refute_receive {:request, _third}, 200

    refute Enum.any?(history, &(&1.type == :turn_failed))
    assert List.last(history).type == :assistant_message
  end

  test "the retried request carries the synthesized output for the named id only", %{
    ctx: ctx,
    ws: ws
  } do
    script = [dangling_call_error("call_ghost"), stop("recovered")]
    assert {:ok, "recovered"} = run_scripted(ctx, "follow up", script)

    assert_receive {:request, _first}, 2_000
    assert_receive {:request, %{history: history}}, 2_000

    outputs =
      for %{"type" => "function_call_output", "call_id" => id} <- folded_input(history, ws),
          do: id

    assert outputs == ["call_ghost"]
  end

  test "a second rejection for the same id surfaces the original provider error", %{
    ctx: ctx,
    sid: sid,
    ws: ws
  } do
    script = [dangling_call_error("call_ghost"), dangling_call_error("call_ghost")]

    assert {:error, %{error: %{kind: :dangling_tool_call} = error}} =
             run_scripted(ctx, "follow up", script)

    # By the structured field, not the message prose: the classifier deliberately treats
    # the prose as untrusted (it gates structurally and only then parses the id), and
    # `details.call_id` is strictly stronger here — it proves WHICH id surfaced, which is
    # the actual claim.
    assert error.details.call_id == "call_ghost"

    assert {:ok, history} = Log.fold(sid, workspace: ws)
    failed = Enum.find(history, &(&1.type == :turn_failed))

    assert failed.data["error_kind"] == "dangling_tool_call"
    assert failed.data["details"]["call_id"] == "call_ghost"
    assert failed.data["details"]["param"] == "input"
    assert failed.data["details"]["type"] == "invalid_request_error"

    # One recovery, not two: only a single synthesized pair for the id.
    synthesized =
      Enum.filter(history, &(&1.type == :tool_call and is_map(&1.data["synthesized"])))

    assert length(synthesized) == 1
  end

  test "a provider naming a fresh dangling id every round exhausts a total budget", %{
    ctx: ctx,
    sid: sid,
    ws: ws
  } do
    # The per-id bound cannot stop a Provider that names a *different* id each round —
    # which is exactly what the Responses validator does when several calls are missing:
    # it reports one at a time. Without a total budget this loops forever, appending two
    # durable events per round.
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    task =
      Task.async(fn ->
        Turn.run(ctx, "follow up",
          provider: EndlessDistinctDanglingProvider,
          provider_opts: [counter: counter, test_pid: self()]
        )
      end)

    assert {:error, %{error: %{kind: :dangling_tool_call} = error}} =
             Task.await(task, 10_000)

    rounds = Agent.get(counter, & &1)

    # The last id the Provider named is surfaced unchanged once the budget is spent —
    # asserted by the structured field, which pins WHICH id came back, not by prose.
    assert error.details.call_id == "call_ghost_#{rounds - 1}"

    assert rounds <= @dangling_recovery_budget + 1, "provider was called #{rounds} times"

    assert {:ok, history} = Log.fold(sid, workspace: ws)

    synthesized =
      Enum.filter(history, &(&1.type == :tool_call and is_map(&1.data["synthesized"])))

    assert length(synthesized) <= @dangling_recovery_budget
    assert Enum.any?(history, &(&1.type == :turn_failed))
  end

  test "the synthesized call renders on the wire as a tool the request actually sends", %{
    ctx: ctx,
    ws: ws
  } do
    script = [dangling_call_error("call_ghost"), stop("recovered")]
    assert {:ok, "recovered"} = run_scripted(ctx, "follow up", script)

    assert_receive {:request, _first}, 2_000
    assert_receive {:request, %{history: history}}, 2_000

    call =
      Enum.find(
        folded_input(history, ws),
        &(&1["type"] == "function_call" and &1["call_id"] == "call_ghost")
      )

    # The Responses API validates an input function_call against that request's own tools
    # array. "unknown" is in no tools array, so the healed request would be rejected a
    # second time; the Log keeps "unknown" but the wire carries a real tool.
    #
    # Pinned exactly, not just "some registered tool": `in names()` passes for any tool, so
    # it would not notice the placeholder moving, and it says nothing about the arguments
    # the healed request actually carries under a schema with required fields.
    assert call["name"] == "read"
    assert call["name"] in Pixir.Tools.Registry.names()
    assert call["arguments"] == "{}"

    assert {:ok, log} = Log.fold(ctx.session_id, workspace: ws)
    logged = Enum.find(log, &(&1.type == :tool_call and &1.data["call_id"] == "call_ghost"))
    assert logged.data["name"] == "unknown"
  end

  # The rename above is scoped to Pixir's OWN synthesized event. A `tool_call` that the
  # model really made — including one naming a tool that does not exist, which
  # `Tools.Executor.run/2` persists verbatim before failing with `:unknown_tool` — must
  # replay with its recorded name. Renaming it would replay a call the model never made,
  # carrying arguments the substituted tool does not accept.
  test "a real tool_call with an unregistered name replays verbatim, not renamed", %{
    ctx: ctx,
    sid: sid,
    ws: ws
  } do
    refute "hallucinated_tool" in Pixir.Tools.Registry.names()

    {:ok, _} =
      Session.record(
        sid,
        Event.tool_call(sid, "call_hallucinated", "hallucinated_tool", %{"foo" => "bar"})
      )

    {:ok, _} =
      Session.record(
        sid,
        Event.tool_result(sid, "call_hallucinated", %{
          "ok" => false,
          "error" => %{"kind" => "unknown_tool", "message" => "no such tool"}
        })
      )

    assert {:ok, "ok"} = run_scripted(ctx, "follow up", [stop("ok")])
    assert_receive {:request, %{history: history}}, 2_000

    call =
      Enum.find(
        folded_input(history, ws),
        &(&1["type"] == "function_call" and &1["call_id"] == "call_hallucinated")
      )

    assert call["name"] == "hallucinated_tool"
    assert call["arguments"] == ~s({"foo":"bar"})
  end

  test "recovery does not fire for a call id the Log already carries", %{
    ctx: ctx,
    sid: sid,
    ws: ws
  } do
    # A persisted tool_call with no result is the *other* class — the existing orphan
    # reconciliation owns it, and layer 2 must not double up on it.
    {:ok, _} = Session.record(sid, Event.tool_call(sid, "call_persisted", "bash", %{}))

    script = [dangling_call_error("call_persisted")]

    assert {:error, %{error: %{kind: :dangling_tool_call}}} =
             run_scripted(ctx, "follow up", script)

    assert {:ok, history} = Log.fold(sid, workspace: ws)
    refute Enum.any?(history, &(&1.type == :tool_call and is_map(&1.data["synthesized"])))
    assert Enum.any?(history, &(&1.type == :turn_failed))
  end

  test "a Log poisoned by a pre-fix binary resumes through layer 2" do
    # This is a COLD READ path: the whole subject is a Log some OTHER (pre-fix) binary
    # wrote. Building it with `Session.record/2` + `Event` constructors would never make
    # the NDJSON round trip, so a deserialization defect in the fold could not fail the one
    # test whose point is reading a foreign Log. The bytes below are written verbatim.
    #
    # The failing baseline shape (`20260801T185322-e38183`): three completed calls, a
    # follow-up user message, and a fourth call that exists only Provider-side.
    {sid, ws} =
      poisoned_log!(
        ~S({"id":"e1","session_id":"SID","seq":0,"ts":"2026-08-01T18:53:22Z","type":"user_message","data":{"text":"run three steps"}}) <>
          "\n" <>
          ~S({"id":"e2","session_id":"SID","seq":1,"ts":"2026-08-01T18:53:23Z","type":"tool_call","data":{"call_id":"call_a","name":"bash","args":{"command":"echo 0"}}}) <>
          "\n" <>
          ~S({"id":"e3","session_id":"SID","seq":2,"ts":"2026-08-01T18:53:24Z","type":"tool_result","data":{"call_id":"call_a","ok":true,"output":"ok"}}) <>
          "\n" <>
          ~S({"id":"e4","session_id":"SID","seq":3,"ts":"2026-08-01T18:53:25Z","type":"tool_call","data":{"call_id":"call_b","name":"bash","args":{"command":"echo 1"}}}) <>
          "\n" <>
          ~S({"id":"e5","session_id":"SID","seq":4,"ts":"2026-08-01T18:53:26Z","type":"tool_result","data":{"call_id":"call_b","ok":true,"output":"ok"}}) <>
          "\n" <>
          ~S({"id":"e6","session_id":"SID","seq":5,"ts":"2026-08-01T18:53:27Z","type":"tool_call","data":{"call_id":"call_c","name":"bash","args":{"command":"echo 2"}}}) <>
          "\n" <>
          ~S({"id":"e7","session_id":"SID","seq":6,"ts":"2026-08-01T18:53:28Z","type":"tool_result","data":{"call_id":"call_c","ok":true,"output":"ok"}}) <>
          "\n"
      )

    ctx = %{session_id: sid, workspace: ws, role: :build}

    # The fold really read the foreign bytes: all three pairs are there, in order.
    assert {:ok, seeded} = Log.fold(sid, workspace: ws)

    assert Enum.map(seeded, &{&1.type, &1.data["call_id"]}) == [
             {:user_message, nil},
             {:tool_call, "call_a"},
             {:tool_result, "call_a"},
             {:tool_call, "call_b"},
             {:tool_result, "call_b"},
             {:tool_call, "call_c"},
             {:tool_result, "call_c"}
           ]

    script = [
      dangling_call_error("call_uTp5vkqm7AYu50YRCLPKhOAM"),
      stop("Steps a, b and c completed before the interruption.")
    ]

    assert {:ok, "Steps a, b and c completed before the interruption."} =
             run_scripted(ctx, "Report which steps completed before the interruption.", script)

    assert {:ok, history} = Log.fold(sid, workspace: ws)
    refute Enum.any?(history, &(&1.type == :turn_failed))

    assert Enum.any?(
             history,
             &(&1.type == :tool_result and
                 &1.data["call_id"] == "call_uTp5vkqm7AYu50YRCLPKhOAM")
           )
  end

  # #462 round 3: the per-Turn budget bounds ONE Turn. A provider naming fresh ids every
  # Turn resets it, so without a Session-scoped ceiling a poisoned Session could append two
  # durable events per recovery forever. The ceiling is read off the Log — the synthesized
  # markers already there — so it needs no state and survives a restart.
  test "a Session whose Log already spent the lifetime ceiling refuses further recovery" do
    # Seed the ceiling's worth of synthesized pairs as raw NDJSON: the ceiling is counted
    # from the Log a resume actually reads, not from live Turn state.
    lines =
      for n <- 1..Turn.dangling_call_session_budget() do
        seq = (n - 1) * 2

        ~s({"id":"c#{seq}","session_id":"SID","seq":#{seq},"ts":"2026-08-01T18:00:00Z","type":"tool_call","data":{"call_id":"call_spent_#{n}","name":"unknown","args":{},"synthesized":{"reason":"provider_dangling_tool_call"}}}) <>
          "\n" <>
          ~s({"id":"r#{seq}","session_id":"SID","seq":#{seq + 1},"ts":"2026-08-01T18:00:01Z","type":"tool_result","data":{"call_id":"call_spent_#{n}","ok":false,"error":{"kind":"orphan_tool_call","message":"did not run","details":{"call_id":"call_spent_#{n}","tool":"unknown","reason":"provider_dangling_tool_call"}}}})
      end

    {sid, ws} = poisoned_log!(Enum.join(lines, "\n") <> "\n")
    ctx = %{session_id: sid, workspace: ws, role: :build}

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        # A brand-new id, so the per-id bound and the fresh per-Turn budget both allow it.
        # Only the Session-lifetime ceiling can stop this.
        assert {:error, %{error: %{kind: :dangling_tool_call} = error}} =
                 run_scripted(ctx, "follow up", [dangling_call_error("call_over_ceiling")])

        assert error.details.call_id == "call_over_ceiling"

        assert {:ok, history} = Log.fold(sid, workspace: ws)

        # No new synthesized pair: the Log grew by the Turn's own events only.
        refute Enum.any?(
                 history,
                 &(&1.type == :tool_call and &1.data["call_id"] == "call_over_ceiling")
               )

        assert Enum.count(history, &(&1.type == :tool_call and is_map(&1.data["synthesized"]))) ==
                 Turn.dangling_call_session_budget()

        # And the refusal is a Turn failure carrying the provider's own error, not a
        # silent no-op.
        assert Enum.any?(history, &(&1.type == :turn_failed))
      end)

    assert log =~ "Session-lifetime budget spent"
  end

  # One under the ceiling still heals: the guard is a ceiling, not an off switch.
  test "a Session one recovery under the lifetime ceiling still heals" do
    lines =
      for n <- 1..(Turn.dangling_call_session_budget() - 1) do
        seq = (n - 1) * 2

        ~s({"id":"c#{seq}","session_id":"SID","seq":#{seq},"ts":"2026-08-01T18:00:00Z","type":"tool_call","data":{"call_id":"call_spent_#{n}","name":"unknown","args":{},"synthesized":{"reason":"provider_dangling_tool_call"}}}) <>
          "\n" <>
          ~s({"id":"r#{seq}","session_id":"SID","seq":#{seq + 1},"ts":"2026-08-01T18:00:01Z","type":"tool_result","data":{"call_id":"call_spent_#{n}","ok":false,"error":{"kind":"orphan_tool_call","message":"did not run","details":{"call_id":"call_spent_#{n}","tool":"unknown","reason":"provider_dangling_tool_call"}}}})
      end

    {sid, ws} = poisoned_log!(Enum.join(lines, "\n") <> "\n")
    ctx = %{session_id: sid, workspace: ws, role: :build}

    script = [dangling_call_error("call_last_allowed"), stop("healed")]
    assert {:ok, "healed"} = run_scripted(ctx, "follow up", script)

    assert {:ok, history} = Log.fold(sid, workspace: ws)
    refute Enum.any?(history, &(&1.type == :turn_failed))

    assert Enum.any?(
             history,
             &(&1.type == :tool_call and &1.data["call_id"] == "call_last_allowed")
           )
  end

  # The budget must cover the issue's own reproduction recipe. The Responses validator
  # names ONE missing output per round, so a Log poisoned with all seven of the recipe's
  # calls costs seven recoveries — more than the round-1 budget of 4 allowed. If the
  # budget were under-sized this Turn would surface the provider error instead of healing.
  test "a Log missing every call of the reproduction recipe still heals in one Turn", %{
    ctx: ctx,
    sid: sid,
    ws: ws
  } do
    ids = for n <- 1..@reproduction_call_count, do: "call_repro_#{n}"
    assert length(ids) <= @dangling_recovery_budget

    script = Enum.map(ids, &dangling_call_error/1) ++ [stop("healed")]

    assert {:ok, "healed"} = run_scripted(ctx, "follow up", script)

    assert {:ok, history} = Log.fold(sid, workspace: ws)
    refute Enum.any?(history, &(&1.type == :turn_failed))

    for call_id <- ids do
      assert Enum.any?(
               history,
               &(&1.type == :tool_result and &1.data["call_id"] == call_id)
             ),
             "#{call_id} was never healed — the budget is under-sized"
    end
  end

  # ── classifier ↔ Turn seam ────────────────────────────────────────────────

  # The layer-2 tests above hand the Turn an already-classified error, and the classifier
  # tests in provider_test.exs check the classification in isolation. Neither notices if
  # the shape drifts between them (`:call_id` moving out of `details`, say). This drives a
  # real SSE chunk through the real Provider into a real Turn, so the two halves are
  # pinned to each other.
  test "a canned SSE rejection travels the real classifier into layer-2 recovery", %{
    ctx: ctx,
    sid: sid,
    ws: ws
  } do
    auth = start_auth()

    rejection =
      sse(%{
        type: "error",
        error: %{
          type: "invalid_request_error",
          code: nil,
          param: "input",
          message: "No tool output found for function call call_seam."
        }
      })

    healed = [
      sse(%{type: "response.output_text.delta", delta: "healed"}),
      sse(%{type: "response.completed"})
    ]

    assert {:ok, "healed"} =
             Turn.run(ctx, "follow up",
               provider: Pixir.Provider,
               provider_opts: [
                 auth: auth,
                 transport: canned_attempts([[rejection], healed]),
                 max_retries: 0
               ]
             )

    assert {:ok, history} = Log.fold(sid, workspace: ws)
    refute Enum.any?(history, &(&1.type == :turn_failed))

    call = Enum.find(history, &(&1.type == :tool_call and &1.data["call_id"] == "call_seam"))
    assert call.data["synthesized"]["reason"] == "provider_dangling_tool_call"
  end

  defmodule NoOAuth do
    def refresh_skew_ms, do: 60_000
  end

  # ── helpers ───────────────────────────────────────────────────────────────

  defp sse(map), do: "data: " <> Jason.encode!(map) <> "\n\n"

  # A canned transport that emits a completed `function_call` output item for each id —
  # the point at which the call is committed on the wire and the model will expect an
  # output for it — announces each one to the test, and then blocks forever with the
  # stream STILL OPEN. That open stream is the reproduced kill window: `Session.interrupt/1`
  # kills the Turn Task here, so anything the Turn has not already handed to the Session
  # dies with the stream accumulator.
  defp commit_then_block(call_ids) do
    test_pid = self()

    fn _http_request, acc, fun ->
      acc = fun.({:status, 200}, acc)

      acc =
        Enum.reduce(call_ids, acc, fn call_id, acc ->
          acc =
            fun.(
              {:data,
               sse(%{
                 type: "response.output_item.done",
                 item: %{
                   type: "function_call",
                   call_id: call_id,
                   name: "bash",
                   arguments: ~s({"command":"echo #{call_id}"})
                 }
               })},
              acc
            )

          send(test_pid, {:call_committed_on_the_wire, call_id})
          acc
        end)

      Process.sleep(:infinity)
      {:ok, acc}
    end
  end

  # Commits `call_id` on the wire and then COMPLETES the stream normally. Unlike
  # `commit_then_block/1` this returns, which is what a test about the stream's own error
  # classification needs: the failure under test comes from the declare, not from the
  # transport, so the transport must not be the thing that ends the stream. Every attempt
  # commits and announces, so a retry is directly observable as a second announcement.
  # Like `commit_then_complete/1`, but the committed call carries CALLER-SUPPLIED
  # arguments, so a redaction test can plant a sentinel where a real secret would be
  # (#462 CR). Everything else — one commit, then a normal stream completion — is the same.
  defp commit_with_args(call_id, arguments) do
    test_pid = self()

    fn _http_request, acc, fun ->
      acc = fun.({:status, 200}, acc)

      acc =
        fun.(
          {:data,
           sse(%{
             type: "response.output_item.done",
             item: %{
               type: "function_call",
               call_id: call_id,
               name: "bash",
               arguments: arguments
             }
           })},
          acc
        )

      send(test_pid, {:call_committed_on_the_wire, call_id})
      {:ok, fun.({:data, sse(%{type: "response.completed"})}, acc)}
    end
  end

  defp commit_then_complete(call_id) do
    test_pid = self()

    fn _http_request, acc, fun ->
      acc = fun.({:status, 200}, acc)

      acc =
        fun.(
          {:data,
           sse(%{
             type: "response.output_item.done",
             item: %{
               type: "function_call",
               call_id: call_id,
               name: "bash",
               arguments: ~s({"command":"echo #{call_id}"})
             }
           })},
          acc
        )

      send(test_pid, {:call_committed_on_the_wire, call_id})
      {:ok, fun.({:data, sse(%{type: "response.completed"})}, acc)}
    end
  end

  # Attempt 1: commit `call_id` on the wire, then fail in-band with a TRANSIENT error, so
  # `Pixir.Provider.attempt/5` retries. Attempt 2: re-commit the SAME id — which is what a
  # retried Responses request really does, the call being part of the model's output — and
  # then block forever with the stream open, so the cancel lands in the same window
  # `commit_then_block/1` models. Each commit is announced with its attempt number so a
  # test can pin that the double declare provably happened before it interrupts.
  defp commit_then_transient_then_recommit(call_id) do
    test_pid = self()
    {:ok, attempts} = Agent.start_link(fn -> 0 end)

    commit = fn acc, fun, n ->
      acc =
        fun.(
          {:data,
           sse(%{
             type: "response.output_item.done",
             item: %{
               type: "function_call",
               call_id: call_id,
               name: "bash",
               arguments: ~s({"command":"echo #{call_id}"})
             }
           })},
          acc
        )

      send(test_pid, {:call_committed_on_the_wire, call_id, n})
      acc
    end

    fn _http_request, acc, fun ->
      n = Agent.get_and_update(attempts, &{&1 + 1, &1 + 1})
      acc = fun.({:status, 200}, acc)
      acc = commit.(acc, fun, n)

      if n == 1 do
        # In-band transient failure: `server_error` is classified `:provider_http_error`
        # with `retryable: true`, so `attempt/5` streams again with the same
        # `on_committed_call` hand-off.
        acc =
          fun.(
            {:data,
             sse(%{
               type: "error",
               error: %{type: "server_error", message: "transient upstream failure"}
             })},
            acc
          )

        {:ok, acc}
      else
        Process.sleep(:infinity)
        {:ok, acc}
      end
    end
  end

  # Write raw NDJSON to a fresh workspace's Log path and start a Session over it: the cold
  # read path a resume really takes. `SID` in the template is replaced with the generated
  # session id so the `session_id` field on every line matches, as a real Log's would.
  defp poisoned_log!(ndjson_template) do
    ws =
      Path.join(
        System.tmp_dir!(),
        "pixir-462-raw-" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
      )

    File.mkdir_p!(ws)
    sid = Session.gen_id()
    log_path = Log.path(sid, workspace: ws)
    File.mkdir_p!(Path.dirname(log_path))
    File.write!(log_path, String.replace(ndjson_template, "SID", sid))

    {:ok, ^sid, pid} = SessionSupervisor.start_session(id: sid, workspace: ws, role: :build)
    :ok = Pixir.Events.subscribe(sid)

    on_exit(fn ->
      if Process.alive?(pid), do: DynamicSupervisor.terminate_child(SessionSupervisor, pid)
      File.rm_rf!(ws)
    end)

    {sid, ws}
  end

  # Like `commit_then_block/1`, but it announces the streaming process and then WAITS for
  # the test's cue before completing the `function_call` output item. That lets a test put
  # something (a Session shutdown) strictly between "stream is live" and "the call is
  # committed and declared", which `commit_then_block/1` cannot: there the declare has
  # already happened by the time the announcement arrives.
  defp commit_on_cue(call_id) do
    test_pid = self()
    {:ok, first?} = Agent.start_link(fn -> true end)

    fn _http_request, acc, fun ->
      acc = fun.({:status, 200}, acc)

      if Agent.get_and_update(first?, &{&1, false}) do
        send(test_pid, {:awaiting_cue, self()})

        receive do
          :commit_now -> :ok
        after
          10_000 -> flunk("the test never cued the commit")
        end

        acc =
          fun.(
            {:data,
             sse(%{
               type: "response.output_item.done",
               item: %{
                 type: "function_call",
                 call_id: call_id,
                 name: "bash",
                 arguments: ~s({"command":"echo #{call_id}"})
               }
             })},
            acc
          )

        # AFTER the reducer returned, so the declare has already been attempted.
        send(test_pid, {:committed_on_the_wire, call_id})

        {:ok, fun.({:data, sse(%{type: "response.completed"})}, acc)}
      else
        # Every later round: a plain stop, so the Turn terminates instead of looping.
        acc = fun.({:data, sse(%{type: "response.output_text.delta", delta: "done"})}, acc)
        {:ok, fun.({:data, sse(%{type: "response.completed"})}, acc)}
      end
    end
  end

  # A throwaway Auth server so tests can drive the REAL `Pixir.Provider` over a canned
  # transport. Each call gets its own name and store so tests stay independent.
  # MUST be called from the test process: it registers an `on_exit` cleanup, and the
  # Auth server is linked to its caller.
  defp start_auth do
    auth = :"auth_462_#{System.unique_integer([:positive])}"
    store = tmp_auth_store("pixir-462-auth-")

    {:ok, _} =
      Pixir.Auth.start_link(
        name: auth,
        store_path: store,
        env_api_key: "sk-test",
        oauth: __MODULE__.NoOAuth
      )

    auth
  end

  defp tmp_auth_store(prefix) do
    directory =
      Path.join(
        System.tmp_dir!(),
        prefix <> Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)
      )

    File.rm_rf!(directory)
    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)
    Path.join(directory, "auth.json")
  end

  defp canned_attempts(attempts) do
    test = self()
    {:ok, agent} = Agent.start_link(fn -> :queue.from_list(attempts) end)

    fn _http_request, acc, fun ->
      send(test, :provider_round)

      chunks =
        Agent.get_and_update(agent, fn queue ->
          case :queue.out(queue) do
            {{:value, chunks}, rest} -> {chunks, rest}
            {:empty, empty} -> raise "no canned provider attempt left: #{inspect(empty)}"
          end
        end)

      acc = fun.({:status, 200}, acc)
      {:ok, Enum.reduce(chunks, acc, fn chunk, a -> fun.({:data, chunk}, a) end)}
    end
  end

  defp folded_input(history, workspace) do
    {:ok, body} = Pixir.Provider.request_body_preview(%{history: history, workspace: workspace})
    body["input"]
  end

  # Message-driven, not timing-driven: the Session publishes every event it stamps, so the
  # test blocks on the `tool_call` itself rather than polling the Log. Subscribe before
  # the Turn starts, and check the Log once in case the event landed pre-subscription.
  defp await_tool_call(sid, ws, call_id) do
    {:ok, history} = Log.fold(sid, workspace: ws)

    unless Enum.any?(history, &(&1.type == :tool_call and &1.data["call_id"] == call_id)) do
      receive do
        {:pixir_event, %{type: :tool_call, data: %{"call_id" => ^call_id}}} -> :ok
        {:pixir_event, _other} -> await_tool_call(sid, ws, call_id)
      after
        2_000 -> flunk("#{call_id} never reached the Log")
      end
    end

    :ok
  end
end
