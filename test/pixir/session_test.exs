defmodule Pixir.SessionTest do
  use ExUnit.Case, async: false

  alias Pixir.{Event, Events, Log, Paths, Session, SessionSupervisor}

  setup do
    ws =
      Path.join(
        System.tmp_dir!(),
        "pixir-sess-" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
      )

    File.mkdir_p!(ws)

    {:ok, sid, pid} = SessionSupervisor.start_session(workspace: ws, role: :build)

    on_exit(fn ->
      if Process.alive?(pid), do: DynamicSupervisor.terminate_child(SessionSupervisor, pid)
      File.rm_rf!(ws)
    end)

    %{ws: ws, sid: sid}
  end

  test "stop_session reports stopped versus already not running", %{sid: sid} do
    assert {:ok, :stopped} = SessionSupervisor.stop_session(sid)
    assert {:ok, :not_running} = SessionSupervisor.stop_session(sid)
  end

  test "records canonical events with monotonic seq and persists to the Log", %{ws: ws, sid: sid} do
    assert {:ok, %{seq: 0, type: :user_message}} =
             Session.record(sid, Event.user_message(sid, "hello"))

    assert {:ok, %{seq: 1, type: :assistant_message}} =
             Session.record(sid, Event.assistant_message(sid, "hi"))

    assert {:ok, [a, b]} = Log.fold(sid, workspace: ws)
    assert a.data["text"] == "hello"
    assert b.data["text"] == "hi"
    assert %{seq: 2} = Session.info(sid)
  end

  test "live Session writer lease blocks direct raw Log appends", %{ws: ws, sid: sid} do
    assert %{writer_lease: %{"state" => "held", "holder_id" => holder_id}} = Session.info(sid)
    assert is_binary(holder_id)

    raw = Event.user_message(sid, "raw competing writer") |> Event.with_seq(0)

    assert {:error, %{error: %{kind: :session_writer_active, details: details}}} =
             Log.append(raw, workspace: ws)

    assert details["lease"]["state"] == "active"

    assert {:ok, %{seq: 0, type: :user_message}} =
             Session.record(sid, Event.user_message(sid, "through owner"))

    assert {:ok, [event]} = Log.fold(sid, workspace: ws)
    assert event.data["text"] == "through owner"
  end

  test "Session stops when its writer lease heartbeat is lost", %{ws: ws, sid: sid} do
    [{pid, _}] = Registry.lookup(Pixir.Sessions.Registry, sid)
    :ok = Events.subscribe(sid)
    ref = Process.monitor(pid)

    File.rm!(Paths.session_lease(sid, ws))
    send(pid, :writer_lease_heartbeat)

    assert_receive {:pixir_event,
                    %{type: :status, data: %{"status" => "session_writer_lease_lost"}}}

    assert_receive {:DOWN, ^ref, :process, ^pid,
                    {:shutdown,
                     {:session_writer_lease_lost, %{error: %{kind: :session_writer_lost}}}}}
  end

  test "record publishes on the bus to subscribers", %{sid: sid} do
    :ok = Events.subscribe(sid)
    {:ok, ev} = Session.record(sid, Event.user_message(sid, "ping"))
    assert_receive {:pixir_event, ^ev}
  end

  test "register_pressure_warning warns once per (checkpoint, tier) and re-arms on change", %{
    sid: sid
  } do
    # First sighting of a (checkpoint range, tier) pair warns …
    assert {:ok, :warn} = Session.register_pressure_warning(sid, nil, "warning")
    # … consecutive sightings of the same pair are suppressed (no per-turn spam).
    assert {:ok, :already_warned} = Session.register_pressure_warning(sid, nil, "warning")
    assert {:ok, :already_warned} = Session.register_pressure_warning(sid, nil, "warning")

    # A higher tier re-arms the gate for the same range …
    assert {:ok, :warn} = Session.register_pressure_warning(sid, nil, "critical")
    # … and a new compaction checkpoint (different to_seq) re-arms the same tier.
    assert {:ok, :warn} = Session.register_pressure_warning(sid, 12, "warning")
    assert {:ok, :already_warned} = Session.register_pressure_warning(sid, 12, "warning")
  end

  test "pressure-warning hysteresis is ephemeral process state: a restart re-arms it", %{
    ws: ws,
    sid: sid
  } do
    assert {:ok, :warn} = Session.register_pressure_warning(sid, nil, "warning")
    assert {:ok, :already_warned} = Session.register_pressure_warning(sid, nil, "warning")

    # Restart the Session process (the Log is empty but durable state is unaffected).
    [{pid, _}] = Registry.lookup(Pixir.Sessions.Registry, sid)
    :ok = DynamicSupervisor.terminate_child(SessionSupervisor, pid)
    {:ok, ^sid, restarted_pid} = SessionSupervisor.start_session(id: sid, workspace: ws)

    on_exit(fn ->
      if Process.alive?(restarted_pid),
        do: DynamicSupervisor.terminate_child(SessionSupervisor, restarted_pid)
    end)

    # Re-warning after a process restart is acceptable by design (ADR 0020).
    assert {:ok, :warn} = Session.register_pressure_warning(sid, nil, "warning")
  end

  test "emit publishes an ephemeral event but does not persist it", %{ws: ws, sid: sid} do
    :ok = Events.subscribe(sid)
    :ok = Session.emit(sid, Event.text_delta(sid, "partial"))

    assert_receive {:pixir_event, %{type: :text_delta, data: %{"chunk" => "partial"}}}
    assert {:ok, []} = Log.fold(sid, workspace: ws)
  end

  test "a Turn runs in a Task and can record events", %{sid: sid} do
    :ok = Events.subscribe(sid)
    refute Session.turn_running?(sid)

    {:ok, _ref} =
      Session.start_turn(sid, fn ctx ->
        Session.record(ctx.session_id, Event.assistant_message(ctx.session_id, "from turn"))
      end)

    assert_receive {:pixir_event, %{type: :assistant_message, data: %{"text" => "from turn"}}}
    # Task completion is async; the Session clears it shortly after.
    Process.sleep(20)
    refute Session.turn_running?(sid)
  end

  test "interrupt kills the running Turn before its later effects land", %{ws: ws, sid: sid} do
    test_pid = self()

    {:ok, _ref} =
      Session.start_turn(sid, fn ctx ->
        send(test_pid, :turn_started)
        Process.sleep(300)
        # Should never run — the Task is killed first.
        Session.record(ctx.session_id, Event.assistant_message(ctx.session_id, "too late"))
      end)

    assert_receive :turn_started, 500
    assert Session.turn_running?(sid)

    assert :ok = Session.interrupt(sid)
    refute Session.turn_running?(sid)

    Process.sleep(350)
    assert {:ok, []} = Log.fold(sid, workspace: ws)
  end

  test "starting a second Turn while one runs returns :busy", %{sid: sid} do
    {:ok, _} = Session.start_turn(sid, fn _ctx -> Process.sleep(200) end)
    assert {:error, :busy} = Session.start_turn(sid, fn _ctx -> :ok end)
    Session.interrupt(sid)
  end

  test "start_turn reconciles a pending tool_call before the next Turn", %{ws: ws, sid: sid} do
    {:ok, %{seq: 0}} =
      Session.record(sid, Event.tool_call(sid, "call_orphan", "run_workflow", %{}))

    {:ok, _ref} =
      Session.start_turn(sid, fn ctx ->
        Session.record(ctx.session_id, Event.assistant_message(ctx.session_id, "next turn"))
      end)

    assert history =
             wait_until(fn ->
               with {:ok, history} <- Log.fold(sid, workspace: ws),
                    true <-
                      Enum.map(history, & &1.type) == [
                        :tool_call,
                        :tool_result,
                        :assistant_message
                      ] do
                 history
               else
                 _ -> false
               end
             end)

    assert Enum.map(history, & &1.type) == [:tool_call, :tool_result, :assistant_message]
    assert Enum.map(history, & &1.seq) == [0, 1, 2]

    assert %{
             data: %{
               "call_id" => "call_orphan",
               "ok" => false,
               "error" => %{
                 "kind" => "orphan_tool_call",
                 "details" => %{"reason" => "before_start_turn"}
               }
             }
           } = Enum.at(history, 1)
  end

  test "interrupt with no active Turn reconciles pending tool_calls", %{ws: ws, sid: sid} do
    {:ok, %{seq: 0}} = Session.record(sid, Event.tool_call(sid, "call_pending", "bash", %{}))

    assert {:error, :no_turn} = Session.interrupt(sid)

    assert {:ok, history} = Log.fold(sid, workspace: ws)
    assert Enum.map(history, & &1.type) == [:tool_call, :tool_result]

    assert %{
             data: %{
               "call_id" => "call_pending",
               "ok" => false,
               "error" => %{
                 "kind" => "orphan_tool_call",
                 "details" => %{"reason" => "interrupt_no_turn"}
               }
             }
           } = List.last(history)
  end

  test "interrupt of active Turn reconciles tool_calls recorded before cancellation", %{
    ws: ws,
    sid: sid
  } do
    test_pid = self()

    {:ok, _ref} =
      Session.start_turn(sid, fn ctx ->
        Session.record(
          ctx.session_id,
          Event.tool_call(ctx.session_id, "call_active", "bash", %{})
        )

        send(test_pid, :tool_call_recorded)
        Process.sleep(300)
      end)

    assert_receive :tool_call_recorded, 500
    assert :ok = Session.interrupt(sid)

    assert {:ok, history} = Log.fold(sid, workspace: ws)
    assert Enum.map(history, & &1.type) == [:tool_call, :tool_result]

    assert %{
             data: %{
               "call_id" => "call_active",
               "error" => %{"kind" => "orphan_tool_call", "details" => %{"reason" => "interrupt"}}
             }
           } = List.last(history)
  end

  # #462 layer 1. The failing reproduction is a call the Provider committed and the
  # Turn was killed before the Executor could record it: it exists provider-side and in
  # no Log event, so the next Turn's request omits its output and the Provider rejects
  # the whole request. The Turn Task cannot clean this up (interrupt kills it outright),
  # so the Session drains what the Turn declared before executing.
  test "interrupt drains a Provider-committed call the Turn never persisted", %{
    ws: ws,
    sid: sid
  } do
    test_pid = self()

    {:ok, _ref} =
      Session.start_turn(sid, fn ctx ->
        :ok =
          Session.declare_committed_calls(
            ctx.session_id,
            [%{call_id: "call_committed", name: "bash", args: %{"command" => "sleep 4"}}],
            ctx.turn_generation
          )

        send(test_pid, :calls_declared)
        # The kill lands here — before the Executor records the `tool_call`.
        Process.sleep(1_000)
      end)

    assert_receive :calls_declared, 1_000
    assert :ok = Session.interrupt(sid)

    assert {:ok, history} = Log.fold(sid, workspace: ws)
    assert Enum.map(history, & &1.type) == [:tool_call, :tool_result]

    assert %{
             data: %{
               "call_id" => "call_committed",
               "name" => "bash",
               "args" => %{"command" => "sleep 4"},
               "drained" => %{"reason" => "interrupt"}
             }
           } = Enum.at(history, 0)

    assert %{
             data: %{
               "call_id" => "call_committed",
               "ok" => false,
               "error" => %{"kind" => "orphan_tool_call", "details" => %{"reason" => "interrupt"}}
             }
           } = Enum.at(history, 1)
  end

  test "a declared call already recorded by the Executor is not drained twice", %{
    ws: ws,
    sid: sid
  } do
    test_pid = self()

    {:ok, _ref} =
      Session.start_turn(sid, fn ctx ->
        sid = ctx.session_id

        :ok =
          Session.declare_committed_calls(
            sid,
            [
              %{call_id: "call_ran", name: "bash", args: %{}},
              %{call_id: "call_never_ran", name: "bash", args: %{}}
            ],
            ctx.turn_generation
          )

        {:ok, _} = Session.record(sid, Event.tool_call(sid, "call_ran", "bash", %{}))
        {:ok, _} = Session.record(sid, Event.tool_result(sid, "call_ran", %{"ok" => true}))

        send(test_pid, :first_call_done)
        Process.sleep(1_000)
      end)

    assert_receive :first_call_done, 1_000
    assert :ok = Session.interrupt(sid)

    assert {:ok, history} = Log.fold(sid, workspace: ws)

    assert Enum.map(history, &{&1.type, &1.data["call_id"]}) == [
             {:tool_call, "call_ran"},
             {:tool_result, "call_ran"},
             {:tool_call, "call_never_ran"},
             {:tool_result, "call_never_ran"}
           ]

    # The completed call keeps its real result; only the un-persisted one is drained.
    assert %{data: %{"ok" => true}} = Enum.at(history, 1)
    assert %{data: %{"drained" => %{"reason" => "interrupt"}}} = Enum.at(history, 2)
  end

  # #462 round 5, surface (a): the same id declared twice for the SAME generation. This is
  # the Provider's own transient retry re-emitting a `function_call` the first attempt
  # already committed — a real, routine path, not a hypothetical. Without the guard the
  # drain writes two `tool_call` events for one id and the single reconciled result leaves
  # the next request in the exact shape the Responses API rejects, which layer 2 refuses to
  # heal because the id IS persisted.
  test "the same call declared twice in one Turn is drained once", %{ws: ws, sid: sid} do
    test_pid = self()

    {:ok, _ref} =
      Session.start_turn(sid, fn ctx ->
        for _attempt <- 1..2 do
          :ok =
            Session.declare_committed_calls(
              ctx.session_id,
              [%{call_id: "call_retried", name: "bash", args: %{}}],
              ctx.turn_generation
            )
        end

        send(test_pid, :declared_twice)
        Process.sleep(1_000)
      end)

    assert_receive :declared_twice, 1_000
    assert :ok = Session.interrupt(sid)

    assert {:ok, history} = Log.fold(sid, workspace: ws)

    assert Enum.map(history, &{&1.type, &1.data["call_id"]}) == [
             {:tool_call, "call_retried"},
             {:tool_result, "call_retried"}
           ]
  end

  # #462 round 5, surface (b): the duplicate inside a SINGLE declaration list. The drain's
  # `seen` set is read from the Log before any of this batch is appended, so it can never
  # see the batch's own first copy; the dedupe has to live in the batch handling itself.
  test "a duplicate id inside one declaration batch is drained once", %{ws: ws, sid: sid} do
    test_pid = self()

    {:ok, _ref} =
      Session.start_turn(sid, fn ctx ->
        :ok =
          Session.declare_committed_calls(
            ctx.session_id,
            [
              %{call_id: "call_dup", name: "bash", args: %{}},
              %{call_id: "call_dup", name: "bash", args: %{}},
              %{call_id: "call_other", name: "bash", args: %{}}
            ],
            ctx.turn_generation
          )

        send(test_pid, :declared)
        Process.sleep(1_000)
      end)

    assert_receive :declared, 1_000
    assert :ok = Session.interrupt(sid)

    assert {:ok, history} = Log.fold(sid, workspace: ws)

    assert Enum.map(history, &{&1.type, &1.data["call_id"]}) == [
             {:tool_call, "call_dup"},
             {:tool_call, "call_other"},
             {:tool_result, "call_dup"},
             {:tool_result, "call_other"}
           ]
  end

  test "committed-call declarations do not survive into the next Turn", %{ws: ws, sid: sid} do
    test_pid = self()

    {:ok, _ref} =
      Session.start_turn(sid, fn ctx ->
        :ok =
          Session.declare_committed_calls(
            ctx.session_id,
            [%{call_id: "call_stale", name: "bash", args: %{}}],
            ctx.turn_generation
          )

        send(test_pid, :declared)
        :done
      end)

    assert_receive :declared, 1_000
    # Let the Turn Task finish cleanly so the Session clears its turn state. A fixed sleep
    # would let a loaded box reach `start_turn` while the Turn is still running, and the
    # `{:ok, _ref}` below would fail on `{:error, :busy}`.
    wait_until(fn -> not Session.turn_running?(sid) end)

    {:ok, _ref} = Session.start_turn(sid, fn _ctx -> Process.sleep(1_000) end)
    assert :ok = Session.interrupt(sid)

    assert {:ok, history} = Log.fold(sid, workspace: ws)
    assert history == []
  end

  test "committed-call declarations do not outlive their Turn", %{ws: ws, sid: sid} do
    test_pid = self()

    # A Turn that declares a call and then ends *without* the Executor ever recording it:
    # the shape of a write-policy strike-2 denial or a terminal tool error abandoning the
    # rest of an already-declared batch. The declaration belongs to that Turn only.
    {:ok, _ref} =
      Session.start_turn(sid, fn ctx ->
        :ok =
          Session.declare_committed_calls(
            ctx.session_id,
            [%{call_id: "call_abandoned", name: "bash", args: %{}}],
            ctx.turn_generation
          )

        send(test_pid, :declared)
        :done
      end)

    assert_receive :declared, 1_000
    wait_until(fn -> not Session.turn_running?(sid) end)

    assert {:ok, []} = Log.fold(sid, workspace: ws)

    # A stray interrupt with no Turn running (SIGINT at the prompt, an ACP session/cancel
    # race) must not drain a Turn that already ended cleanly.
    assert {:error, :no_turn} = Session.interrupt(sid)
    assert {:ok, []} = Log.fold(sid, workspace: ws)
  end

  test "a crashed Turn's committed-call declarations are drained, not dropped", %{
    ws: ws,
    sid: sid
  } do
    test_pid = self()

    ExUnit.CaptureLog.capture_log(fn ->
      {:ok, _ref} =
        Session.start_turn(sid, fn ctx ->
          :ok =
            Session.declare_committed_calls(
              ctx.session_id,
              [%{call_id: "call_crashed", name: "bash", args: %{"command" => "echo hi"}}],
              ctx.turn_generation
            )

          send(test_pid, :declared)
          raise "turn blew up"
        end)

      assert_receive :declared, 1_000
      wait_until(fn -> not Session.turn_running?(sid) end)
    end)

    assert {:ok, history} = Log.fold(sid, workspace: ws)
    logged = Enum.map(history, &{&1.type, &1.data["call_id"]})

    # The declaration survives the crash: this is the evidence layer 1 exists to preserve.
    assert {:tool_call, "call_crashed"} in logged

    call = Enum.find(history, &(&1.type == :tool_call))
    assert call.data["drained"]["reason"] == "turn_crashed"

    # The crash handler drains but deliberately does NOT reconcile — closing persisted
    # orphans at crash time would push a new `reason` value into a vocabulary Monitor and
    # ACP read, which is out of #462's scope. The drained call is left pending on purpose.
    assert {:tool_result, "call_crashed"} not in logged

    # And the drain empties the set: a later interrupt cannot replay it as a second
    # fabricated tool_call. That interrupt DOES reconcile the pending call, through the
    # pre-existing no-Turn path and its existing reason vocabulary — no new reason string
    # is introduced anywhere, which is the point of keeping the crash handler drain-only.
    assert {:error, :no_turn} = Session.interrupt(sid)

    assert {:ok, healed} = Log.fold(sid, workspace: ws)

    result =
      Enum.find(healed, &(&1.type == :tool_result and &1.data["call_id"] == "call_crashed"))

    assert result, "the drained call was never closed by the existing reconciliation"
    assert result.data["ok"] == false
    assert result.data["error"]["kind"] == "orphan_tool_call"
    assert result.data["error"]["details"]["reason"] == "interrupt_no_turn"

    # Exactly one tool_call for the id: the drain did not duplicate it.
    assert Enum.count(healed, &(&1.type == :tool_call and &1.data["call_id"] == "call_crashed")) ==
             1
  end

  # Dropped evidence must be visible (ADR 0007): a malformed declaration silently
  # un-protects that call, which is #462's own failure mode one layer down.
  test "a malformed committed-call declaration is named, not silently dropped", %{
    ws: ws,
    sid: sid
  } do
    test_pid = self()

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        {:ok, _ref} =
          Session.start_turn(sid, fn ctx ->
            :ok =
              Session.declare_committed_calls(
                ctx.session_id,
                [
                  %{call_id: "call_ok", name: "bash", args: %{}},
                  # No `args`: fails the guard.
                  %{call_id: "call_bad", name: "bash"}
                ],
                ctx.turn_generation
              )

            send(test_pid, :declared)
            Process.sleep(1_000)
          end)

        assert_receive :declared, 1_000
        assert :ok = Session.interrupt(sid)
      end)

    assert log =~ "dropped a malformed Provider-committed call declaration"
    assert log =~ "call_bad"

    # The well-formed sibling is unaffected: one bad entry does not poison the batch.
    assert {:ok, history} = Log.fold(sid, workspace: ws)
    logged = Enum.map(history, &{&1.type, &1.data["call_id"]})
    assert {:tool_call, "call_ok"} in logged
    refute {:tool_call, "call_bad"} in logged
  end

  # #462 round 3: the declare-after-drain race. `interrupt/1` drains, sets `turn: nil` and
  # kills the Turn Task, but the streaming runner is unlinked from the Turn on the default
  # StreamIdle topology (`spawn_monitor`), so it survives the kill and can declare a call
  # AFTER the drain has already run. Pre-fix that declaration landed in `committed_calls`
  # with no Turn to own it: `interrupt` with no turn never drains, and the next
  # `start_turn` reset the list to `[]`. The call was silently lost — precisely #462's
  # failure class, and on the Open Responses backend (no layer 2) permanent poison.
  test "a declaration landing after the interrupt drain is persisted, not accumulated", %{
    ws: ws,
    sid: sid
  } do
    test_pid = self()

    {:ok, _ref} =
      Session.start_turn(sid, fn ctx ->
        send(test_pid, {:turn_ctx, ctx})
        Process.sleep(5_000)
      end)

    assert_receive {:turn_ctx, ctx}, 1_000
    assert :ok = Session.interrupt(sid)
    refute Session.turn_running?(sid)

    # The surviving stream runner declares its call now, after the drain, stamped with the
    # generation of the Turn it belonged to — the identity its handler closure captured.
    assert :ok =
             Session.declare_committed_calls(
               sid,
               [%{call_id: "call_late", name: "bash", args: %{"command" => "echo late"}}],
               ctx.turn_generation
             )

    assert {:ok, history} = Log.fold(sid, workspace: ws)
    logged = Enum.map(history, &{&1.type, &1.data["call_id"]})

    assert {:tool_call, "call_late"} in logged,
           "the late declaration never reached the Log: #{inspect(logged)}"

    late = Enum.find(history, &(&1.type == :tool_call and &1.data["call_id"] == "call_late"))
    assert late.data["drained"]["reason"] == "declared_without_turn"
    assert late.data["name"] == "bash"

    # And it is closed by the ordinary reconciliation on the next start_turn, so the next
    # request carries a matching output rather than a bare dangling function_call.
    {:ok, _ref} = Session.start_turn(sid, fn _ctx -> :done end)
    wait_until(fn -> not Session.turn_running?(sid) end)

    assert {:ok, healed} = Log.fold(sid, workspace: ws)

    result = Enum.find(healed, &(&1.type == :tool_result and &1.data["call_id"] == "call_late"))
    assert result, "the late-drained call was never reconciled"
    assert result.data["error"]["kind"] == "orphan_tool_call"

    # Exactly one tool_call for the id: draining at declare time did not duplicate it.
    assert Enum.count(healed, &(&1.type == :tool_call and &1.data["call_id"] == "call_late")) == 1
  end

  # #462 round 3, the second half of the same race: the late declaration lands while a NEW
  # Turn is already alive. Keying the drain on turn STATE (nil vs alive) is not enough —
  # a killed Turn's surviving runner declaring into a live successor matched the accumulate
  # clause, was attributed to that successor, and was dropped at ITS clean end. Same silent
  # evidence loss, one Turn over. Declarations must carry TURN IDENTITY, not a claim that
  # some Turn is running.
  test "a late declaration from a killed Turn is drained, not attributed to the live Turn", %{
    ws: ws,
    sid: sid
  } do
    test_pid = self()

    # Turn A starts and captures its generation, exactly as the committed-call handler
    # closure does at Turn start.
    {:ok, _ref} =
      Session.start_turn(sid, fn ctx ->
        send(test_pid, {:turn_a, ctx.turn_generation})
        Process.sleep(5_000)
      end)

    assert_receive {:turn_a, gen_a}, 1_000

    # A is interrupted: the drain runs and the Task dies, but A's stream runner survives it
    # (unlinked `spawn_monitor` on the default StreamIdle topology).
    assert :ok = Session.interrupt(sid)
    refute Session.turn_running?(sid)

    # Turn B starts and is alive when A's straggler finally lands.
    {:ok, _ref} =
      Session.start_turn(sid, fn ctx ->
        send(test_pid, {:turn_b, ctx.turn_generation, self()})

        receive do
          :finish_b -> :done
        after
          5_000 -> :timeout
        end
      end)

    assert_receive {:turn_b, gen_b, turn_b_pid}, 1_000
    assert gen_b != gen_a, "start_turn must issue a fresh generation per Turn"

    # A's late declaration, stamped with A's generation, arriving while B is alive.
    assert :ok =
             Session.declare_committed_calls(
               sid,
               [%{call_id: "call_a_straggler", name: "bash", args: %{"command" => "echo a"}}],
               gen_a
             )

    # B's own declaration, stamped with B's generation: unaffected, still accumulated.
    assert :ok =
             Session.declare_committed_calls(
               sid,
               [%{call_id: "call_live_b", name: "bash", args: %{"command" => "echo b"}}],
               gen_b
             )

    # A's call is durable evidence NOW, under its own reason, while B still runs.
    assert {:ok, mid} = Log.fold(sid, workspace: ws)

    stale = Enum.find(mid, &(&1.type == :tool_call and &1.data["call_id"] == "call_a_straggler"))

    assert stale,
           "A's late declaration never reached the Log: #{inspect(Enum.map(mid, &{&1.type, &1.data["call_id"]}))}"

    assert stale.data["drained"]["reason"] == "stale_turn_generation"
    assert stale.data["name"] == "bash"
    assert stale.data["args"] == %{"command" => "echo a"}

    # B's declaration is still held by the live Turn, not drained as a straggler and not
    # destroyed by A's drain running over it.
    refute Enum.any?(mid, &(&1.type == :tool_call and &1.data["call_id"] == "call_live_b")),
           "B's live declaration was drained while B was still running"

    # B ends cleanly: its own un-reached declaration clears rather than being fabricated,
    # and the straggler it never owned stays exactly one tool_call.
    send(turn_b_pid, :finish_b)
    wait_until(fn -> not Session.turn_running?(sid) end)

    assert {:ok, history} = Log.fold(sid, workspace: ws)

    refute Enum.any?(history, &(&1.type == :tool_call and &1.data["call_id"] == "call_live_b")),
           "B's un-reached declaration must clear at B's clean end, not be fabricated"

    assert Enum.count(
             history,
             &(&1.type == :tool_call and &1.data["call_id"] == "call_a_straggler")
           ) == 1
  end

  # Control for the clause above: a declaration carrying the LIVE Turn's own generation
  # still accumulates (it is not drained on the spot) and still clears at that Turn's clean
  # end. The identity gate must not turn every ordinary declaration into a straggler.
  test "a live Turn's own declarations accumulate and clear at its clean end", %{
    ws: ws,
    sid: sid
  } do
    test_pid = self()

    {:ok, _ref} =
      Session.start_turn(sid, fn ctx ->
        :ok =
          Session.declare_committed_calls(
            ctx.session_id,
            [%{call_id: "call_same_gen", name: "bash", args: %{}}],
            ctx.turn_generation
          )

        send(test_pid, {:declared, self()})

        receive do
          :finish -> :done
        after
          5_000 -> :timeout
        end
      end)

    assert_receive {:declared, turn_pid}, 1_000

    # Accumulated, not drained: nothing in the Log while the Turn is alive.
    assert {:ok, mid} = Log.fold(sid, workspace: ws)

    refute Enum.any?(mid, &(&1.type == :tool_call and &1.data["call_id"] == "call_same_gen")),
           "a same-generation declaration was drained instead of accumulated"

    send(turn_pid, :finish)
    wait_until(fn -> not Session.turn_running?(sid) end)

    assert {:ok, history} = Log.fold(sid, workspace: ws)

    refute Enum.any?(history, &(&1.type == :tool_call and &1.data["call_id"] == "call_same_gen")),
           "a declaration the Executor never reached must clear at the Turn's clean end"
  end

  # The second end of the same race: whatever route leaves declarations behind (a crash
  # drain whose Log append failed, a future caller), `start_turn` must DRAIN them, not
  # reset the list to `[]`. Resetting is the silent evidence loss #462 exists to stop.
  test "start_turn drains leftover declarations instead of dropping them", %{ws: ws, sid: sid} do
    # Deliberately white-box, and deliberately kept as an INVARIANT PIN rather than
    # converted to a real route (#462 round 3 adjudication). No route reaches `start_turn`
    # with a non-empty `committed_calls` today: every exit clears or drains it — a clean
    # Turn end clears, a crash and an interrupt drain, the straggler clause drains on the
    # spot and restores only the live Turn's set, and `drain_committed_calls/2` empties the
    # list on entry so even its failure branches leave `[]`. That is the point. The
    # invariant under test is `start_turn` NEVER DROPS what it finds, whatever put it
    # there, so this test must plant the state directly: driving it through a real route
    # would make the test pass for a reason other than the one being pinned, and would
    # silently stop testing anything the day the routes change. This is the guard against
    # a future route reintroducing the reset that #462 removed.
    :sys.replace_state(Session.via(sid), fn state ->
      %{state | committed_calls: [%{call_id: "call_leftover", name: "bash", args: %{}}]}
    end)

    {:ok, _ref} = Session.start_turn(sid, fn _ctx -> :done end)
    wait_until(fn -> not Session.turn_running?(sid) end)

    assert {:ok, history} = Log.fold(sid, workspace: ws)
    logged = Enum.map(history, &{&1.type, &1.data["call_id"]})

    assert {:tool_call, "call_leftover"} in logged,
           "start_turn dropped a leftover declaration: #{inspect(logged)}"

    leftover =
      Enum.find(history, &(&1.type == :tool_call and &1.data["call_id"] == "call_leftover"))

    assert leftover.data["drained"]["reason"] == "before_start_turn"

    # Drained BEFORE the reconciliation that same start_turn runs, so one pass closes it.
    result =
      Enum.find(history, &(&1.type == :tool_result and &1.data["call_id"] == "call_leftover"))

    assert result, "the leftover was drained but never reconciled in the same start_turn"
    assert result.data["error"]["kind"] == "orphan_tool_call"
  end

  test "resume: a fresh Session over an existing Log continues the seq", %{ws: ws, sid: sid} do
    {:ok, _} = Session.record(sid, Event.user_message(sid, "first"))
    {:ok, _} = Session.record(sid, Event.assistant_message(sid, "second"))

    # Stop the live Session, then start a cold one over the same id + workspace.
    :ok = GenServer.stop(Session.via(sid))
    {:ok, ^sid, _pid} = SessionSupervisor.start_session(id: sid, workspace: ws)
    assert %{seq: 2} = Session.info(sid)

    {:ok, %{seq: 2}} = Session.record(sid, Event.user_message(sid, "third"))
    assert {:ok, history} = Log.fold(sid, workspace: ws)
    assert length(history) == 3
    assert Enum.map(history, & &1.seq) == [0, 1, 2]
  end

  defp wait_until(fun, timeout_ms \\ 1_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    wait_until(fun, deadline, nil)
  end

  defp wait_until(fun, deadline, _last) do
    case fun.() do
      false ->
        if System.monotonic_time(:millisecond) > deadline do
          flunk("condition was not met before timeout")
        else
          Process.sleep(10)
          wait_until(fun, deadline, false)
        end

      result ->
        result
    end
  end
end
