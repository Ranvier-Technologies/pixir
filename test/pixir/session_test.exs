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
