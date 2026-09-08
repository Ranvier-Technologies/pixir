defmodule Pixir.ConversationTest do
  use ExUnit.Case, async: false

  alias Pixir.{Conversation, Event, Log, Paths, Subagents}
  alias Pixir.Tools.CommandBoundary

  # Minimal provider stub: pops scripted results, streams text deltas (like TurnTest's).
  defmodule StubProvider do
    def stream(_request, opts) do
      agent = Keyword.fetch!(opts, :agent)
      on_delta = Keyword.get(opts, :on_delta, fn _ -> :ok end)

      result =
        agent
        |> Agent.get_and_update(fn [head | tail] -> {head, tail} end)
        |> ensure_usage()

      if match?({:ok, %{function_calls: [_ | _]}}, result) do
        Process.sleep(Keyword.get(opts, :startup_delay_ms, 0))
      end

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

  defp bash_call(command, timeout_ms) do
    {:ok,
     %{
       text: "",
       reasoning: "",
       function_calls: [
         %{
           call_id: "call_sleep",
           name: "bash",
           args: %{"command" => command, "timeout_ms" => timeout_ms}
         }
       ],
       finish_reason: :tool_calls,
       usage: %{
         "input_tokens" => 42,
         "input_tokens_details" => %{"cached_tokens" => 16},
         "output_tokens" => 7,
         "output_tokens_details" => %{"reasoning_tokens" => 3},
         "total_tokens" => 49
       }
     }}
  end

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

    assert Enum.map(history, & &1.type) == [
             :subagent_event,
             :user_message,
             :provider_usage,
             :assistant_message
           ]

    # A minted root records its permission posture as the Log's first event.
    assert [posture | _rest] = history
    assert posture.seq == 0
    assert posture.data["event"] == "permission_posture"
    assert posture.data["lineage"] == "root"
    assert posture.data["source"] == "root_session_start"

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
             :subagent_event,
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

  test "await extends while a silent bash process is alive within its tool cap", %{ws: ws} do
    {:ok, sid} = Conversation.start(workspace: ws)
    on_exit(fn -> Pixir.SessionSupervisor.stop_session(sid) end)
    release = Path.join(ws, "release-quiet-tool")
    command = "while [ ! -f release-quiet-tool ]; do sleep 0.01; done"
    {:ok, agent} = Agent.start_link(fn -> [bash_call(command, 15_000), stop("finished")] end)
    :ok = Conversation.subscribe(sid)

    {:ok, _ref} =
      Conversation.send(sid, "run a quiet command",
        provider: StubProvider,
        provider_opts: [agent: agent, startup_delay_ms: 750]
      )

    # Setup may take longer than the idle interval. Start measuring the actual
    # silent-tool condition only after its real process is registered.
    await_tool_registration(sid, System.monotonic_time(:millisecond) + 5_000)
    checks = :counters.new(1, [])

    assert :done =
             Conversation.await(sid,
               idle_timeout: 150,
               subagent_liveness?: false,
               tool_liveness_check: fn checked_sid ->
                 presence = CommandBoundary.presenter_liveness(checked_sid)

                 if match?({:live, _}, presence) do
                   :counters.add(checks, 1, 1)
                   # Only the second real idle-expiry observation releases the
                   # command. Removing the extension makes this test time out.
                   if :counters.get(checks, 1) == 2, do: File.write!(release, "release")
                 end

                 presence
               end
             )

    assert :counters.get(checks, 1) >= 2
  end

  defp await_tool_registration(sid, deadline) do
    case CommandBoundary.presenter_liveness(sid) do
      {:live, _} ->
        :ok

      :dead ->
        assert System.monotonic_time(:millisecond) < deadline, "quiet tool was never registered"
        Process.sleep(10)
        await_tool_registration(sid, deadline)
    end
  end

  @tag timeout: 15_000
  test "await still times out for a genuinely idle session", %{ws: ws} do
    {:ok, sid} = Conversation.start(workspace: ws)
    on_exit(fn -> Pixir.SessionSupervisor.stop_session(sid) end)
    :ok = Conversation.subscribe(sid)
    checks = :counters.new(1, [])

    started_at = System.monotonic_time(:millisecond)

    assert :timeout =
             Conversation.await(sid,
               idle_timeout: 30,
               cleanup_timeout: 0,
               subagent_liveness?: false,
               tool_liveness_check: fn checked_sid ->
                 # Deterministically model a descheduled expiry check. This is
                 # test-only scheduling pressure, not a runtime timeout change.
                 gate = make_ref()
                 Process.send_after(self(), {:resume_idle_check, gate}, 550)

                 assert_receive {:resume_idle_check, ^gate}, 5_000
                 :counters.add(checks, 1, 1)
                 assert :dead = CommandBoundary.presenter_liveness(checked_sid)
                 :dead
               end
             )

    elapsed_ms = System.monotonic_time(:millisecond) - started_at

    assert elapsed_ms >= 30 + 550
    # A premature timeout (skipping presence) or spurious extension must fail,
    # even though scheduler latency no longer has a 500ms performance budget.
    assert :counters.get(checks, 1) == 1
  end

  @tag timeout: 15_000
  test "await stops extending at the in-flight tool cap", %{ws: ws} do
    {:ok, sid} = Conversation.start(workspace: ws)
    on_exit(fn -> Pixir.SessionSupervisor.stop_session(sid) end)
    :ok = Conversation.subscribe(sid)
    boundary = start_supervised!({CommandBoundary, name: nil})
    parent = self()
    bash = System.find_executable("bash") || "/bin/bash"

    holder =
      Task.async(fn ->
        CommandBoundary.with_slot(
          "bash",
          [
            boundary: boundary,
            limits: %{
              "max_concurrent" => 1,
              "queue_limit" => 0,
              "queue_timeout_ms" => 50
            }
          ],
          fn lease ->
            # The process cannot finish on its own while the cap is observed.
            port =
              Port.open(
                {:spawn_executable, bash},
                [:binary, :exit_status, {:args, ["-c", "read -r release"]}]
              )

            :ok = CommandBoundary.register_process(lease, sid, port, 15_000, 0)
            send(parent, {:tool_registered, port, lease})

            receive do
              :release_tool ->
                if Port.info(port), do: Port.close(port)
                :released
            after
              10_000 -> flunk("await never stopped at the tool cap")
            end
          end
        )
      end)

    assert_receive {:tool_registered, port, lease}, 5_000
    assert Port.info(port)
    checks = :counters.new(1, [])

    started_at = System.monotonic_time(:millisecond)

    assert :timeout =
             Conversation.await(sid,
               idle_timeout: 40,
               cleanup_timeout: 0,
               subagent_liveness?: false,
               tool_liveness_check: fn checked_sid ->
                 :counters.add(checks, 1, 1)
                 presence = CommandBoundary.presenter_liveness(checked_sid, boundary: boundary)

                 if :counters.get(checks, 1) == 1 do
                   # Observe a real live process before arming the short cap.
                   # Setup/descheduling cannot erase the initial live proof.
                   assert {:live, _} = presence
                   armed_at = System.monotonic_time(:millisecond)
                   :ok = CommandBoundary.register_process(lease, sid, port, 90, 0)
                   send(self(), {:observed_tool_cap_start, armed_at})
                 end

                 send(self(), {:observed_tool_presence, presence})
                 presence
               end
             )

    elapsed_ms = System.monotonic_time(:millisecond) - started_at
    assert elapsed_ms >= 40 + 90
    assert_received {:observed_tool_cap_start, armed_at}
    assert System.monotonic_time(:millisecond) - armed_at >= 90
    assert_received {:observed_tool_presence, {:live, remaining_ms}}
    assert remaining_ms in 0..15_000
    assert_received {:observed_tool_presence, :dead}
    assert :counters.get(checks, 1) >= 2
    assert Port.info(port)

    send(holder.pid, :release_tool)
    assert :released = Task.await(holder, 5_000)
  end

  @tag timeout: 15_000
  test "await rejects a leaked closed tool port before a far-future cap", %{ws: ws} do
    {:ok, sid} = Conversation.start(workspace: ws)
    on_exit(fn -> Pixir.SessionSupervisor.stop_session(sid) end)
    :ok = Conversation.subscribe(sid)
    boundary = start_supervised!({CommandBoundary, name: nil})
    parent = self()
    bash = System.find_executable("bash") || "/bin/bash"

    holder =
      Task.async(fn ->
        CommandBoundary.with_slot(
          "bash",
          [
            boundary: boundary,
            limits: %{
              "max_concurrent" => 1,
              "queue_limit" => 0,
              "queue_timeout_ms" => 50
            }
          ],
          fn lease ->
            port =
              Port.open(
                {:spawn_executable, bash},
                [:binary, :exit_status, {:args, ["-c", "read -r release"]}]
              )

            try do
              :ok = CommandBoundary.register_process(lease, sid, port, 10_000, 1_000)
              send(parent, {:leaked_tool_registered, port, lease})

              receive do
                :close_tool ->
                  Port.close(port)
                  send(parent, {:leaked_tool_closed, port})
              end

              receive do
                :release_tool -> :released
              end
            after
              if Port.info(port), do: Port.close(port)
            end
          end
        )
      end)

    try do
      assert_receive {:leaked_tool_registered, port, lease}, 5_000
      checks = :counters.new(1, [])
      started_at = System.monotonic_time(:millisecond)

      assert :timeout =
               Conversation.await(sid,
                 idle_timeout: 30,
                 cleanup_timeout: 0,
                 subagent_liveness?: false,
                 tool_liveness_check: fn checked_sid ->
                   :counters.add(checks, 1, 1)
                   assert :counters.get(checks, 1) == 1
                   gate = make_ref()
                   Process.send_after(self(), {:resume_closed_tool_check, gate}, 550)
                   assert_receive {:resume_closed_tool_check, ^gate}, 5_000

                   # Arm the far-future cap after scheduler pressure, and prove
                   # this very registration is live before its owner closes it.
                   :ok = CommandBoundary.register_process(lease, sid, port, 10_000, 1_000)

                   assert {:live, _remaining_ms} =
                            CommandBoundary.presenter_liveness(checked_sid, boundary: boundary)

                   send(holder.pid, :close_tool)
                   assert_receive {:leaked_tool_closed, ^port}, 5_000
                   assert Port.info(port) == nil
                   assert Process.alive?(holder.pid)

                   assert {:ok, %{"active_count" => 1}} =
                            CommandBoundary.snapshot(boundary: boundary)

                   # The lease and cap survive: only the real port's death can
                   # explain this result. An always-dead presence stub fails above.
                   assert :dead =
                            CommandBoundary.presenter_liveness(checked_sid, boundary: boundary)
                 end
               )

      assert System.monotonic_time(:millisecond) - started_at >= 30 + 550
      # Skipping presence or extending for the stale lease must both fail.
      assert :counters.get(checks, 1) == 1
      assert Process.alive?(holder.pid)
      assert Port.info(port) == nil
      send(holder.pid, :release_tool)
      assert :released = Task.await(holder, 5_000)
    after
      Task.shutdown(holder, :brutal_kill)
    end
  end

  test "await drains a terminal event queued during a false expiry presence check", %{ws: ws} do
    {:ok, sid} = Conversation.start(workspace: ws)
    :ok = Conversation.subscribe(sid)

    liveness_check = fn checked_sid ->
      send(self(), {:pixir_event, Event.status(checked_sid, "done")})
      false
    end

    assert :done =
             Conversation.await(sid,
               idle_timeout: 10,
               subagent_liveness_check: liveness_check
             )
  end

  test "idle_timeout zero never consults or extends for subagent presence", %{ws: ws} do
    {:ok, sid} = Conversation.start(workspace: ws)
    :ok = Conversation.subscribe(sid)
    test_pid = self()

    liveness_check = fn _sid ->
      send(test_pid, :zero_timeout_presence_check)
      true
    end

    assert :timeout =
             Conversation.await(sid,
               idle_timeout: 0,
               subagent_liveness_check: liveness_check
             )

    refute_received :zero_timeout_presence_check
  end

  @tag timeout: 15_000
  test "a timed-out child stops extending the parent idle deadline", %{ws: ws} do
    {:ok, sid} = Conversation.start(workspace: ws)
    on_exit(fn -> Pixir.SessionSupervisor.stop_session(sid) end)
    :ok = Conversation.subscribe(sid)

    assert {:ok, agent} =
             Subagents.spawn_agent(
               sid,
               %{
                 "task" => "block until child timeout",
                 "workspace_mode" => "shared",
                 "timeout_ms" => 120
               },
               workspace: ws,
               provider: BlockingProvider,
               permission_mode: :read_only
             )

    on_exit(fn ->
      try do
        _ = Subagents.close(sid, agent["id"], workspace: ws)
      after
        Pixir.SessionSupervisor.stop_session(agent["child_session_id"])
      end
    end)

    # Synchronize on the real lifecycle, not on how much of the child's 120ms
    # budget remains when spawn returns or the parent gets scheduled again.
    assert {:ok, [%{"id" => child_id, "status" => "timed_out"}]} =
             Subagents.wait(sid, [agent["id"]], 5_000, workspace: ws)

    assert child_id == agent["id"]
    checks = :counters.new(1, [])
    parent = self()
    started_at = System.monotonic_time(:millisecond)

    assert :timeout =
             Conversation.await(sid,
               idle_timeout: 40,
               cleanup_timeout: 0,
               tool_liveness?: false,
               on_event: fn event ->
                 if event.type == :subagent_event and event.data["event"] == "timed_out" do
                   send(parent, {:await_observed_child_timeout, event})
                 end
               end,
               subagent_liveness_check: fn checked_sid ->
                 :counters.add(checks, 1, 1)
                 # Fail immediately if an expired child buys another interval.
                 assert :counters.get(checks, 1) == 1
                 gate = make_ref()
                 Process.send_after(self(), {:resume_child_check, gate}, 550)
                 assert_receive {:resume_child_check, ^gate}, 5_000

                 assert {:ok, %{"presenter_liveness_count" => count}} =
                          Subagents.diagnostics(checked_sid, workspace: ws)

                 assert count == 0
                 count > 0
               end
             )

    assert System.monotonic_time(:millisecond) - started_at >= 40 + 550
    # A skipped check cannot masquerade as correctly rejecting expired presence.
    assert :counters.get(checks, 1) == 1
    assert_received {:await_observed_child_timeout, timeout_event}
    assert timeout_event.data["subagent_id"] == agent["id"]
    assert {:ok, history} = Conversation.history(sid)
    assert timeout_event in history
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
