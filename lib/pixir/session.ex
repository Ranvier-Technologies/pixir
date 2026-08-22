defmodule Pixir.Session do
  @moduledoc """
  The unit of agency (ADR 0001): a single GenServer that owns one conversation —
  its `:role` (the Agent configuration), its monotonic `seq` counter, and the append
  to its **Log**. There is exactly one Session process per `session_id`, registered in
  `Pixir.Sessions.Registry`.

  ## Recording events

  Canonical events go through `record/2`, which runs the load-bearing sequence inside
  the GenServer (so it is serialized): **stamp `seq` → append to the Log → publish on
  the bus**. The Log is the source of truth, so an event that fails to persist is not
  published. Ephemeral events go through `emit/2` (publish only — no `seq`, no Log).

  ## Turns as supervised Tasks

  A **Turn** runs in a Task under `Pixir.TurnSupervisor`, monitored (not linked) by the
  Session. `interrupt/1` fences that logical Turn by terminating its Task, draining known
  committed calls, reconciling persisted orphans, and durably recording audit-only
  interruption evidence. The reusable Session itself stays alive. This local fence makes
  no claim about remote Provider billing/emission or host processes that already escaped
  the Turn Task. The Turn body is a 1-arity function given a context map
  (`%{session_id, workspace, role, fork_root_session_id}`); the real tool-loop plugs in here.

  ## Resume

  On `init/1` the Session folds its existing Log to seed `seq` (so new canonical events
  continue the sequence). History itself is always re-derived from the Log on demand
  (`history/1`), never held as authoritative state (ADR 0003). A Session also acquires
  a filesystem-backed writer lease so a second OS process cannot become a competing Log
  writer while this process is alive.
  """

  use GenServer

  require Logger

  alias Pixir.{Event, Events, Fork, Log, SessionId, SessionLease}

  @registry Pixir.Sessions.Registry
  @turn_supervisor Pixir.TurnSupervisor

  @type role :: atom()
  @type turn_identity :: {reference(), pos_integer()}
  @type ctx :: %{
          session_id: String.t(),
          workspace: String.t(),
          role: role(),
          fork_root_session_id: String.t(),
          session_incarnation: reference(),
          turn_generation: pos_integer()
        }

  # ── child / lifecycle ───────────────────────────────────────────────────

  @doc "`{:via, Registry, …}` name for a Session id."
  def via(session_id), do: {:via, Registry, {@registry, session_id}}

  def child_spec(opts) do
    %{
      id: {__MODULE__, Keyword.fetch!(opts, :id)},
      start: {__MODULE__, :start_link, [opts]},
      restart: :transient,
      shutdown: 5_000,
      type: :worker
    }
  end

  def start_link(opts) do
    id = Keyword.fetch!(opts, :id)

    with :ok <- SessionId.validate(id) do
      GenServer.start_link(__MODULE__, opts, name: via(id))
    end
  end

  @doc "Generate a sortable, filename-safe Session id."
  @spec gen_id() :: String.t()
  def gen_id do
    ts = DateTime.utc_now() |> Calendar.strftime("%Y%m%dT%H%M%S")
    ts <> "-" <> Base.encode16(:crypto.strong_rand_bytes(3), case: :lower)
  end

  # ── public API ────────────────────────────────────────────────────────────

  @doc "Snapshot of Session metadata (id, workspace, role, next seq, turn state)."
  @spec info(String.t()) :: map() | {:error, map()}
  def info(session_id), do: call_session(session_id, :info)

  @doc "Reconstruct History by folding the Log (the source of truth)."
  @spec history(String.t()) :: {:ok, Log.history()} | {:error, map()}
  def history(session_id), do: call_session(session_id, :history)

  @doc """
  Record a canonical Event: stamp `seq`, append to the Log, then publish. Returns the
  stamped Event, or a structured error if it was not canonical / failed to persist.
  """
  @spec record(String.t(), Event.t()) :: {:ok, Event.t()} | {:error, map()}
  def record(session_id, event), do: call_session(session_id, {:record, event})

  @doc "Publish an ephemeral Event (live display only; never persisted)."
  @spec emit(String.t(), Event.t()) :: :ok | {:error, map()}
  def emit(session_id, event), do: cast_session(session_id, {:emit, event})

  @doc """
  Start a Turn: run `turn_fun.(ctx)` in a supervised Task. Returns `{:ok, ref}` or
  `{:error, :busy}` if a Turn is already running. If the previous Turn left orphan
  tool calls in the Log, Pixir first records fallback `tool_result` events so Provider
  replay stays valid.
  """
  @spec start_turn(String.t(), (ctx() -> any())) ::
          {:ok, reference()} | {:error, :busy} | {:error, map()}
  def start_turn(session_id, turn_fun) when is_function(turn_fun, 1),
    do: call_session(session_id, {:start_turn, turn_fun})

  @declare_timeout_ms 30_000

  @doc """
  Declare the function calls the Provider committed for the current Turn, before the
  Executor starts running them (#462, layer 1).

  `interrupt/1` kills the Turn Task outright, so no Turn-side cleanup can be trusted to
  run. A call the Provider already committed but Pixir has not yet persisted would then
  exist only provider-side, and the next Turn's request would omit its output — which
  the Responses API rejects with "No tool output found for function call <id>". Holding
  the committed set in the Session (which survives the kill) lets `interrupt/1` drain it
  to the Log before the Turn closes.

  Entries are `%{call_id, name, args}` maps. Recording the real `tool_call` clears its
  id, so only genuinely un-persisted calls are ever drained. The set is Turn-scoped: it
  is cleared when the Turn ends (and drained when the Turn is killed or crashes), so a
  declaration the Executor never reached cannot leak into a later interrupt. A
  declaration that lands with no Turn running is drained on the spot rather than
  accumulated: the streaming runner outlives the Turn it belonged to, so a late
  declaration is real evidence with no Turn left to own it.

  `turn_identity` is the caller's compound runtime TURN IDENTITY, not merely a claim
  that some Turn is running (#462 round 3, #471). Keying the drain on turn STATE alone
  (nil vs alive) is not enough: the surviving runner of a killed Turn can declare while
  a NEW Turn is already alive, and a state-only check accumulates that straggler into the
  successor, which then drops it at its own clean end — the same silent evidence loss one
  Turn over. A numeric generation alone is also insufficient because `turn_generation`
  restarts when the transient Session process restarts. Each actual Session process mints
  an opaque runtime incarnation and pairs it with the Turn's generation. The Turn stamps
  every declaration with that pair, so even generation one from a prior incarnation is a
  straggler. Passing `nil` means "no identity claimed"; during a live Turn it is drained
  under the honest `unstamped_declaration` classification rather than accumulated.

  The incarnation token is runtime-only. It is never written to an Event, the Log, or
  Pixir-authored Logger output.

  This call carries its own generous timeout rather than the `GenServer.call/2` default
  of 5 s (#462 round 3). The Session serializes Log appends and `Log.fold/2` history
  folds, so a big Log can hold this call for longer than the default while nothing is
  actually wrong — and a mid-stream timeout is worse than a slow one: the caller lives
  inside the provider stream reducer, where an escaping exit is classified `:network`
  and IS provider-retryable, so a stalled fold would re-stream the request.
  """
  @spec declare_committed_calls(String.t(), [map()], turn_identity() | nil) ::
          :ok | {:error, map()}
  def declare_committed_calls(session_id, calls, turn_identity \\ nil) when is_list(calls),
    do:
      call_session(
        session_id,
        {:declare_committed_calls, calls, turn_identity},
        @declare_timeout_ms
      )

  @doc """
  Fence the active logical Turn while keeping its Session reusable.

  Success is returned only after the Turn Task is terminated, known committed calls are
  drained/reconciled, and a bounded audit-only `turn_failed` interruption Event is durable.
  This does not claim remote Provider billing/emission or escaped host-process quiescence.
  """
  @spec interrupt(String.t()) :: :ok | {:error, :no_turn} | {:error, map()}
  def interrupt(session_id), do: call_session(session_id, :interrupt)

  @doc "Whether a Turn is currently running."
  @spec turn_running?(String.t(), timeout()) :: boolean() | {:error, map()}
  def turn_running?(session_id, timeout \\ 5_000),
    do: call_session(session_id, :turn_running?, timeout)

  @doc """
  Hysteresis gate for context-pressure warnings (ADR 0020): returns `{:ok, :warn}`
  the first time a `(latest checkpoint to_seq, tier)` pair is seen and
  `{:ok, :already_warned}` afterwards — no warning spam on consecutive turns for
  the same pair. A new compaction checkpoint (different `to_seq`) or a different
  tier re-arms the gate. State is ephemeral process state by design: it is never
  logged, and re-warning after a Session restart is acceptable.
  """
  @spec register_pressure_warning(String.t(), integer() | nil, String.t()) ::
          {:ok, :warn | :already_warned}
  def register_pressure_warning(session_id, checkpoint_to_seq, tier) when is_binary(tier) do
    call_session(session_id, {:register_pressure_warning, checkpoint_to_seq, tier})
  end

  defp call_session(session_id, message, timeout \\ 5_000) do
    with :ok <- SessionId.validate(session_id) do
      GenServer.call(via(session_id), message, timeout)
    end
  end

  defp cast_session(session_id, message) do
    with :ok <- SessionId.validate(session_id) do
      GenServer.cast(via(session_id), message)
    end
  end

  # ── callbacks ───────────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    id = Keyword.fetch!(opts, :id)
    workspace = Keyword.get(opts, :workspace) || File.cwd!()
    role = Keyword.get(opts, :role, :build)

    with :ok <- SessionId.validate(id) do
      init_valid_session(id, workspace, role, opts)
    else
      {:error, error} -> {:stop, {:invalid_session_id, error}}
    end
  end

  defp init_valid_session(id, workspace, role, opts) do
    case Log.exists(id, workspace: workspace) do
      {:ok, _exists?} -> acquire_and_fold(id, workspace, role, opts)
      {:error, error} -> {:stop, {:corrupt_log, error}}
    end
  end

  defp acquire_and_fold(id, workspace, role, opts) do
    case SessionLease.acquire(id,
           workspace: workspace,
           force_release?: Keyword.get(opts, :force_release_writer_lease?, false),
           force_release_reason: Keyword.get(opts, :force_release_reason)
         ) do
      {:ok, writer_lease} ->
        case Log.fold(id, workspace: workspace) do
          {:ok, history} ->
            state =
              %{
                id: id,
                workspace: workspace,
                role: role,
                seq: next_seq(history),
                fork_root_session_id: Fork.fork_root_session_id(history, id),
                # #471: an opaque capability minted once per actual Session process.
                # It is paired with `turn_generation` for declaration matching and is
                # deliberately absent from `info`, Events, Log data, and Pixir-authored
                # Logger output.
                session_incarnation: make_ref(),
                turn: nil,
                # #462 round 3: monotonic Turn generation within this process incarnation.
                # It lives above `turn` on purpose so a generation is not reused until a
                # transient Session restart; the incarnation capability disambiguates that
                # restart boundary (#471).
                turn_generation: 0,
                committed_calls: [],
                pressure_warnings: MapSet.new(),
                writer_lease: writer_lease,
                writer_lease_timer_ref: nil,
                writer_lease_error: nil
              }
              |> schedule_writer_lease_heartbeat()

            {:ok, state}

          {:error, error} ->
            # OTP does not invoke terminate/2 when init/1 stops before a state exists.
            # This explicit cleanup owns the acquire-then-fold failure seam.
            _ = SessionLease.release(writer_lease)
            {:stop, {:corrupt_log, error}}
        end

      {:error, error} ->
        {:stop, {:session_writer_lease, error}}
    end
  end

  @impl true
  def terminate(_reason, state) do
    terminate_active_turn(Map.get(state, :turn))

    if Map.get(state, :writer_lease_timer_ref),
      do: Process.cancel_timer(state.writer_lease_timer_ref)

    SessionLease.release(Map.get(state, :writer_lease))
    :ok
  end

  @impl true
  def handle_call(:info, _from, state) do
    {:reply,
     %{
       id: state.id,
       workspace: state.workspace,
       role: state.role,
       seq: state.seq,
       fork_root_session_id: state.fork_root_session_id,
       turn_running?: state.turn != nil,
       writer_lease: writer_lease_info(state)
     }, state}
  end

  def handle_call(:history, _from, state) do
    {:reply, Log.fold(state.id, workspace: state.workspace), state}
  end

  def handle_call({:record, event}, _from, state) do
    case record_event(state, event) do
      {:ok, stamped, next_state} ->
        {:reply, {:ok, stamped}, forget_committed_call(next_state, stamped)}

      {:error, _} = error ->
        {:reply, error, state}
    end
  end

  # The declaration belongs to the Turn that is actually running: accumulate it, to be
  # drained if that Turn is killed or crashes and cleared if it ends cleanly. The match is
  # on the compound runtime IDENTITY, not on `turn` being non-nil and not on the numeric
  # generation alone — see the straggler clause below.
  #
  # #462 round 5: a call id already declared for THIS generation is ignored, not appended.
  # The Provider retries transient failures itself (`Pixir.Provider.attempt/5`) with the
  # same `on_committed_call` hand-off, and a retried Responses request re-emits the
  # `function_call` output items the first attempt already committed. Appending blindly
  # made `committed_calls` hold the same id twice, the interrupt drain then wrote two
  # `tool_call` events for it, and the single reconciled `tool_result` left the next
  # request with two `function_call` items and one output — the shape the API rejects, and
  # one layer 2 will not heal because `persisted_call_id?/2` is already true for that id.
  # Permanent poison, built by the fix meant to prevent it.
  #
  # De-duplication is by call_id ALONE: an id the Provider has committed identifies one
  # call, and re-declaring it can only be the same call arriving twice. Comparing the whole
  # entry instead would let a retry whose arguments re-serialized differently slip a second
  # declaration through.
  def handle_call(
        {:declare_committed_calls, calls, turn_identity},
        _from,
        %{turn: %{identity: turn_identity}} = state
      )
      when not is_nil(turn_identity) do
    declared = Enum.flat_map(calls, &normalize_committed_call/1)
    known = MapSet.new(state.committed_calls, & &1.call_id)

    fresh =
      declared
      |> Enum.reject(&MapSet.member?(known, &1.call_id))
      |> Enum.uniq_by(& &1.call_id)

    {:reply, :ok, %{state | committed_calls: state.committed_calls ++ fresh}}
  end

  # #462 round 3: a STRAGGLER — a declaration whose Turn is no longer the running one.
  # The default StreamIdle topology runs the stream in an unlinked `spawn_monitor` child,
  # so `interrupt/1` kills the Turn Task but not the runner: the runner can complete one
  # more `function_call` output item and declare it AFTER the interrupt drain has run.
  #
  # Two shapes reach here, and both are the same bug. With NO Turn running, accumulating
  # would lose it — `interrupt` with no turn never drains, and `start_turn` used to reset
  # the list. With a NEW Turn already running, keying on turn state alone would attribute
  # a dead Turn's evidence to its successor, which then drops it at its own clean end:
  # the same loss, one Turn over, and the reason the gate is identity and not state.
  # Either way it is real evidence with no live Turn to own it, so it is drained on the
  # spot under its own reason, and the next `start_turn`/`interrupt` reconciliation closes
  # it like any other drained call. On the Open Responses backend (no layer 2) losing it
  # instead would be permanent poison.
  def handle_call({:declare_committed_calls, calls, turn_identity}, _from, state) do
    declared = Enum.flat_map(calls, &normalize_committed_call/1)
    reason = straggler_drain_reason(state.turn, turn_identity)

    # The straggler is drained through a state whose `committed_calls` holds ONLY the
    # straggler, then the live Turn's own accumulated set is restored. A live successor
    # may be holding declarations of its own; draining over them would persist another
    # Turn's un-reached calls as evidence, and clearing them would be the very loss this
    # clause exists to stop. `drain_committed_calls/2` empties the list on entry, so both
    # branches restore explicitly rather than relying on what it left behind.
    live = state.committed_calls

    case drain_committed_calls(%{state | committed_calls: declared}, reason) do
      {:ok, drained_state} ->
        {:reply, :ok, %{drained_state | committed_calls: live}}

      # The Log itself is failing, so durable evidence is impossible. Loud and named, and
      # the straggler is dropped rather than carried into an unrelated later Turn.
      {:error, error, failed_state} ->
        Logger.error("#462 drain of a straggling committed-call declaration failed",
          session_id: failed_state.id,
          drain_reason: reason,
          undrained_call_ids: Enum.map(declared, & &1.call_id),
          error: inspect(error)
        )

        {:reply, :ok, %{failed_state | committed_calls: live}}
    end
  end

  def handle_call({:start_turn, turn_fun}, _from, %{turn: nil} = state) do
    # #462 round 3: DRAIN leftover declarations, never reset them. Resetting silently
    # un-protects a call the Provider committed — the exact evidence loss layer 1 exists
    # to stop. Draining before the reconciliation below is what makes one pass enough.
    with {:ok, state} <- drain_committed_calls(state, "before_start_turn"),
         {:ok, state} <- reconcile_pending_tool_calls(state, "before_start_turn") do
      # #462 round 3 / #471: a fresh compound runtime TURN IDENTITY per Turn. The
      # generation remains in `ctx` as a compatibility field; declaration matching pairs
      # it with the process-local incarnation so generation one is never mistaken for
      # generation one from a restarted Session process.
      generation = state.turn_generation + 1
      identity = {state.session_incarnation, generation}

      ctx = %{
        session_id: state.id,
        workspace: state.workspace,
        role: state.role,
        fork_root_session_id: state.fork_root_session_id,
        session_incarnation: state.session_incarnation,
        turn_generation: generation
      }

      task = Task.Supervisor.async_nolink(@turn_supervisor, fn -> turn_fun.(ctx) end)

      # `committed_calls` is already `[]` — the drain above emptied it. Stated, not reset,
      # so a future edit cannot reintroduce the drop this drain replaced.
      {:reply, {:ok, task.ref},
       %{
         state
         | turn: %{ref: task.ref, pid: task.pid, generation: generation, identity: identity},
           turn_generation: generation,
           committed_calls: []
       }}
    else
      {:error, error, state} ->
        {:reply, {:error, error}, state}
    end
  end

  def handle_call({:start_turn, _turn_fun}, _from, state) do
    {:reply, {:error, :busy}, state}
  end

  def handle_call(:interrupt, _from, %{turn: %{ref: ref, pid: pid}} = state) do
    Process.demonitor(ref, [:flush])
    _ = Task.Supervisor.terminate_child(@turn_supervisor, pid)

    with {:ok, state} <- drain_committed_calls(%{state | turn: nil}, "interrupt"),
         {:ok, state} <- reconcile_pending_tool_calls(state, "interrupt"),
         {:ok, state} <- record_interruption_failure(state) do
      Events.publish(Event.status(state.id, "interrupted"))
      {:reply, :ok, state}
    else
      {:error, error, state} -> {:reply, {:error, error}, state}
    end
  end

  # No Turn running: there is no live Turn whose committed calls could still be
  # un-persisted, so this path reconciles persisted orphans only and never drains
  # declarations (#462). A stray SIGINT at the prompt must not fabricate a tool_call.
  def handle_call(:interrupt, _from, state) do
    case reconcile_pending_tool_calls(state, "interrupt_no_turn") do
      {:ok, state} -> {:reply, {:error, :no_turn}, state}
      {:error, error, state} -> {:reply, {:error, error}, state}
    end
  end

  def handle_call(:turn_running?, _from, state), do: {:reply, state.turn != nil, state}

  def handle_call({:register_pressure_warning, checkpoint_to_seq, tier}, _from, state) do
    key = {checkpoint_to_seq, tier}

    if MapSet.member?(state.pressure_warnings, key) do
      {:reply, {:ok, :already_warned}, state}
    else
      {:reply, {:ok, :warn},
       %{state | pressure_warnings: MapSet.put(state.pressure_warnings, key)}}
    end
  end

  @impl true
  def handle_cast({:emit, event}, state) do
    Events.publish(%{event | session_id: state.id})
    {:noreply, state}
  end

  # Turn Task finished normally: `{ref, result}` then demonitor+flush the :DOWN.
  @impl true
  def handle_info({ref, _result}, %{turn: %{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    # #462: a Turn that returned did its own reconciliation; any declaration the Executor
    # never reached (a strike-2 write denial or a terminal tool error abandons the rest of
    # the batch) belongs to that Turn alone. Carrying it forward would let a later
    # interrupt — including one with no Turn running — drain it as fabricated evidence.
    {:noreply, %{state | turn: nil, committed_calls: []}}
  end

  # Turn Task crashed (or was killed before we flushed): clear it. The declarations are
  # drained here rather than dropped — a crash between commit and persist is the very
  # window layer 1 exists to close, and `interrupt/1` demonitors before terminating, so
  # this clause never races the interrupt drain.
  #
  # Scoped to the drain only. Reconciling persisted orphans here too would be a behavior
  # change beyond #462: those orphans already have a home (the next `start_turn`/
  # `interrupt` reconciles them), and closing them at crash time under a new reason string
  # would push an unannounced value into a `reason` vocabulary Monitor and ACP read. The
  # drained calls this clause writes are themselves left pending on purpose — the very
  # next `start_turn` closes them through the existing `before_start_turn` reconciliation,
  # using the reason vocabulary that already exists.
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{turn: %{ref: ref}} = state) do
    state = %{state | turn: nil}
    # Captured before the drain: `drain_committed_calls/2` clears the list on entry, so the
    # failure branch would otherwise report nothing.
    declared_ids = Enum.map(state.committed_calls, & &1.call_id)

    case drain_committed_calls(state, "turn_crashed") do
      {:ok, state} ->
        {:noreply, state}

      # A Log-append failure here loses the evidence layer 1 exists to preserve, and the
      # crash path has no caller to return the error to. Durable evidence is impossible
      # (the Log is precisely what is failing), so this is at minimum loud, and it names
      # the ids so the loss is diagnosable.
      {:error, error, state} ->
        Logger.error("#462 drain of Provider-committed calls failed after a Turn crash",
          session_id: state.id,
          undrained_call_ids: declared_ids,
          error: inspect(error)
        )

        {:noreply, %{state | committed_calls: []}}
    end
  end

  def handle_info(:writer_lease_heartbeat, state) do
    case SessionLease.heartbeat(state.writer_lease) do
      {:ok, writer_lease} ->
        {:noreply,
         %{state | writer_lease: writer_lease, writer_lease_timer_ref: nil}
         |> schedule_writer_lease_heartbeat()}

      {:error, error} ->
        Events.publish(Event.status(state.id, "session_writer_lease_lost"))

        {:stop, {:shutdown, {:session_writer_lease_lost, error}},
         %{state | writer_lease_error: error, writer_lease_timer_ref: nil}}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ── internals ─────────────────────────────────────────────────────────────

  defp record_event(state, event) do
    stamped = Event.with_seq(%{event | session_id: state.id}, state.seq)

    case Log.append(stamped, workspace: state.workspace, writer_lease: state.writer_lease) do
      {:ok, _} ->
        Events.publish(stamped)
        {:ok, stamped, %{state | seq: state.seq + 1}}

      {:error, _} = error ->
        error
    end
  end

  # Module-owned and deliberately context-free: interruption evidence must never project a
  # Provider payload, tool arguments, a Task exit reason, or the opaque Session incarnation.
  # It is appended only after drain/reconciliation, so `interrupt/1` returning `:ok` is a
  # durable logical-Turn fence rather than merely a request to kill a Task.
  defp record_interruption_failure(state) do
    data = %{
      "terminal_status" => "interrupted",
      "error_kind" => "interrupted",
      "error_message" => "Turn was interrupted before completion.",
      "details" => %{"scope" => "turn"}
    }

    case record_event(state, Event.turn_failed(state.id, data)) do
      {:ok, _event, state} -> {:ok, state}
      {:error, error} -> {:error, error, state}
    end
  end

  # #462 layer 1: persist every Provider-committed call the killed Turn never recorded,
  # in declaration order, as a `tool_call` the ordinary orphan reconciliation below then
  # closes. Draining before reconciling is what makes one pass enough.
  # A straggler that lands while a live Turn is running is a DIFFERENT diagnosis from one
  # that lands into an idle Session: the first means a dead Turn's runner outlived its Turn
  # and spoke over a SUCCESSOR, the second that it spoke into the gap. Both are drained on
  # the spot; the distinct reason keeps them apart in the Log, which is the only place this
  # is observable at all.
  defp straggler_drain_reason(nil, _turn_identity), do: "declared_without_turn"
  defp straggler_drain_reason(%{}, nil), do: "unstamped_declaration"
  defp straggler_drain_reason(%{}, _turn_identity), do: "stale_turn_generation"

  defp drain_committed_calls(%{committed_calls: []} = state, _reason), do: {:ok, state}

  defp drain_committed_calls(%{committed_calls: calls} = state, reason) do
    state = %{state | committed_calls: []}

    case Log.fold(state.id, workspace: state.workspace) do
      {:ok, history} ->
        seen = history |> known_call_ids() |> MapSet.new()

        # #462 round 5: `seen` is the Log as it was BEFORE this drain, so a `reject` run
        # once over the batch cannot stop a duplicate that arrives inside the batch itself
        # — the second copy would be tested against a set that predates the first copy's
        # append. Two independent guards close that, and both are kept because they fail
        # differently: `uniq_by` collapses duplicates in the declaration list (first
        # declaration wins, so wire order is preserved), and the skip test moved INSIDE the
        # fold, over a `seen` grown after each successful append, keeps the check honest
        # about what this drain has already written. The declare clause above also refuses
        # same-id re-declares; a drain trusting only that would re-open this the moment any
        # other caller assembled the list.
        calls
        |> Enum.uniq_by(& &1.call_id)
        |> Enum.reduce_while({:ok, state, seen}, fn call, {:ok, state, seen} ->
          if MapSet.member?(seen, call.call_id) do
            {:cont, {:ok, state, seen}}
          else
            event =
              Event.new(state.id, :tool_call, %{
                "call_id" => call.call_id,
                "name" => call.name,
                "args" => call.args,
                "drained" => %{"reason" => reason}
              })

            case record_event(state, event) do
              {:ok, _event, next_state} ->
                {:cont, {:ok, next_state, MapSet.put(seen, call.call_id)}}

              {:error, error} ->
                {:halt, {:error, error, state}}
            end
          end
        end)
        |> case do
          {:ok, state, _seen} -> {:ok, state}
          {:error, error, state} -> {:error, error, state}
        end

      {:error, error} ->
        {:error, error, state}
    end
  end

  # Every call id the Log MENTIONS, closed or not — "seen", not "pending". The drain must
  # skip a call the Executor already recorded whether or not it also has a result;
  # `pending_tool_calls/1` a few lines below is the genuinely-pending set and means the
  # opposite thing.
  defp known_call_ids(history) do
    Enum.flat_map(history, fn
      %{type: type, data: %{"call_id" => call_id}} when type in [:tool_call, :tool_result] ->
        [call_id]

      _event ->
        []
    end)
  end

  defp forget_committed_call(%{committed_calls: []} = state, _event), do: state

  defp forget_committed_call(state, %{type: :tool_call, data: %{"call_id" => call_id}}),
    do: %{state | committed_calls: Enum.reject(state.committed_calls, &(&1.call_id == call_id))}

  defp forget_committed_call(state, _event), do: state

  defp normalize_committed_call(%{call_id: call_id, name: name, args: args})
       when is_binary(call_id) and is_binary(name) and is_map(args),
       do: [%{call_id: call_id, name: name, args: args}]

  # Dropped evidence must be visible (ADR 0007). A malformed entry vanishing silently
  # un-protects that call — #462's own failure mode one layer down — so it is named,
  # exactly as `Pixir.Turn.walk_output_items/3` names an unrecognized output item.
  defp normalize_committed_call(call) do
    # The bounded facts are inlined in the MESSAGE, not left in metadata: the default
    # console formatter drops metadata, and evidence a reader never sees is not visible
    # evidence. Values are never rendered because tool arguments may carry secrets.
    Logger.warning(
      "#462 dropped a malformed Provider-committed call declaration: " <>
        malformed_committed_call_facts(call)
    )

    []
  end

  # Only the keys a well-formed declaration could carry are ever rendered; every
  # other key is COUNTED, never printed, because a malformed entry's keys are as
  # untrusted as its values (a map-shaped key can embed argument material, and
  # `inspect/2` would render it).
  @known_committed_call_keys [:call_id, :name, :args, "call_id", "name", "args"]

  defp malformed_committed_call_facts(call) when is_map(call) do
    {known, unknown} = call |> Map.keys() |> Enum.split_with(&(&1 in @known_committed_call_keys))

    facts =
      "keys=" <>
        inspect(Enum.sort_by(known, &to_string/1)) <> " unknown_keys=#{length(unknown)}"

    call_id =
      case call do
        %{call_id: call_id} when is_binary(call_id) -> call_id
        %{"call_id" => call_id} when is_binary(call_id) -> call_id
        _other -> nil
      end

    if call_id do
      facts <> " call_id=" <> inspect(binary_part(call_id, 0, min(byte_size(call_id), 40)))
    else
      facts
    end
  end

  defp malformed_committed_call_facts(call) when is_binary(call), do: "type=binary"
  defp malformed_committed_call_facts(call) when is_boolean(call), do: "type=boolean"
  defp malformed_committed_call_facts(call) when is_atom(call), do: "type=atom"
  defp malformed_committed_call_facts(call) when is_integer(call), do: "type=integer"
  defp malformed_committed_call_facts(call) when is_float(call), do: "type=float"
  defp malformed_committed_call_facts(call) when is_list(call), do: "type=list"
  defp malformed_committed_call_facts(call) when is_tuple(call), do: "type=tuple"
  defp malformed_committed_call_facts(_call), do: "type=other"

  defp reconcile_pending_tool_calls(state, reason) do
    case Log.fold(state.id, workspace: state.workspace) do
      {:ok, history} ->
        history
        |> pending_tool_calls()
        |> Enum.sort_by(fn {call_id, _event} -> call_id end)
        |> Enum.reduce_while({:ok, state}, fn {_call_id, call}, {:ok, state} ->
          event =
            Event.tool_result(state.id, call.data["call_id"], %{
              "ok" => false,
              "error" => %{
                "kind" => "orphan_tool_call",
                "message" => "Pixir reconciled a tool_call that had no persisted tool_result",
                "details" => %{
                  "call_id" => call.data["call_id"],
                  "tool" => call.data["name"],
                  "reason" => reason
                }
              }
            })

          case record_event(state, event) do
            {:ok, _event, next_state} -> {:cont, {:ok, next_state}}
            {:error, error} -> {:halt, {:error, error, state}}
          end
        end)

      {:error, error} ->
        {:error, error, state}
    end
  end

  defp pending_tool_calls(history) do
    Enum.reduce(history, %{}, fn
      %{type: :tool_call, data: %{"call_id" => call_id}} = event, acc ->
        Map.put(acc, call_id, event)

      %{type: :tool_result, data: %{"call_id" => call_id}}, acc ->
        Map.delete(acc, call_id)

      _event, acc ->
        acc
    end)
  end

  defp next_seq([]), do: 0

  defp next_seq(history) do
    case List.last(history) do
      %{seq: seq} when is_integer(seq) -> seq + 1
      _ -> length(history)
    end
  end

  defp schedule_writer_lease_heartbeat(%{writer_lease: %{} = writer_lease} = state) do
    interval = writer_lease["heartbeat_interval_ms"] || 1_000

    %{
      state
      | writer_lease_timer_ref: Process.send_after(self(), :writer_lease_heartbeat, interval)
    }
  end

  defp writer_lease_info(state) do
    %{
      "state" => if(state.writer_lease_error, do: "lost", else: "held"),
      "holder_id" => get_in(state.writer_lease, ["holder_id"]),
      "lease_path" => get_in(state.writer_lease, ["lease_path"]),
      "last_error" => state.writer_lease_error
    }
  end

  defp terminate_active_turn(%{pid: pid}) when is_pid(pid) do
    _ = Task.Supervisor.terminate_child(@turn_supervisor, pid)
    :ok
  end

  defp terminate_active_turn(_turn), do: :ok
end
