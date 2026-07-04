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
  Session. `interrupt/1` kills that Task — the load-bearing invariant that makes a Turn
  cleanly cancellable without taking the Session down. The Turn body is a 1-arity
  function given a context map (`%{session_id, workspace, role, fork_root_session_id}`);
  the real tool-loop (build step 7) plugs in here.

  ## Resume

  On `init/1` the Session folds its existing Log to seed `seq` (so new canonical events
  continue the sequence). History itself is always re-derived from the Log on demand
  (`history/1`), never held as authoritative state (ADR 0003). A Session also acquires
  a filesystem-backed writer lease so a second OS process cannot become a competing Log
  writer while this process is alive.
  """

  use GenServer

  alias Pixir.{Event, Events, Fork, Log, SessionLease}

  @registry Pixir.Sessions.Registry
  @turn_supervisor Pixir.TurnSupervisor

  @type role :: atom()
  @type ctx :: %{
          session_id: String.t(),
          workspace: String.t(),
          role: role(),
          fork_root_session_id: String.t()
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
    GenServer.start_link(__MODULE__, opts, name: via(id))
  end

  @doc "Generate a sortable, filename-safe Session id."
  @spec gen_id() :: String.t()
  def gen_id do
    ts = DateTime.utc_now() |> Calendar.strftime("%Y%m%dT%H%M%S")
    ts <> "-" <> Base.encode16(:crypto.strong_rand_bytes(3), case: :lower)
  end

  # ── public API ────────────────────────────────────────────────────────────

  @doc "Snapshot of Session metadata (id, workspace, role, next seq, turn state)."
  @spec info(String.t()) :: map()
  def info(session_id), do: GenServer.call(via(session_id), :info)

  @doc "Reconstruct History by folding the Log (the source of truth)."
  @spec history(String.t()) :: {:ok, Log.history()} | {:error, map()}
  def history(session_id), do: GenServer.call(via(session_id), :history)

  @doc """
  Record a canonical Event: stamp `seq`, append to the Log, then publish. Returns the
  stamped Event, or a structured error if it was not canonical / failed to persist.
  """
  @spec record(String.t(), Event.t()) :: {:ok, Event.t()} | {:error, map()}
  def record(session_id, event), do: GenServer.call(via(session_id), {:record, event})

  @doc "Publish an ephemeral Event (live display only; never persisted)."
  @spec emit(String.t(), Event.t()) :: :ok
  def emit(session_id, event), do: GenServer.cast(via(session_id), {:emit, event})

  @doc """
  Start a Turn: run `turn_fun.(ctx)` in a supervised Task. Returns `{:ok, ref}` or
  `{:error, :busy}` if a Turn is already running. If the previous Turn left orphan
  tool calls in the Log, Pixir first records fallback `tool_result` events so Provider
  replay stays valid.
  """
  @spec start_turn(String.t(), (ctx() -> any())) ::
          {:ok, reference()} | {:error, :busy} | {:error, map()}
  def start_turn(session_id, turn_fun) when is_function(turn_fun, 1),
    do: GenServer.call(via(session_id), {:start_turn, turn_fun})

  @doc "Kill the currently running Turn's Task, if any."
  @spec interrupt(String.t()) :: :ok | {:error, :no_turn} | {:error, map()}
  def interrupt(session_id), do: GenServer.call(via(session_id), :interrupt)

  @doc "Whether a Turn is currently running."
  @spec turn_running?(String.t()) :: boolean()
  def turn_running?(session_id), do: GenServer.call(via(session_id), :turn_running?)

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
    GenServer.call(via(session_id), {:register_pressure_warning, checkpoint_to_seq, tier})
  end

  # ── callbacks ───────────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    id = Keyword.fetch!(opts, :id)
    workspace = Keyword.get(opts, :workspace) || File.cwd!()
    role = Keyword.get(opts, :role, :build)

    with {:writer_lease, {:ok, writer_lease}} <-
           {:writer_lease,
            SessionLease.acquire(id,
              workspace: workspace,
              force_release?: Keyword.get(opts, :force_release_writer_lease?, false),
              force_release_reason: Keyword.get(opts, :force_release_reason)
            )},
         {:log, {:ok, history}} <- {:log, Log.fold(id, workspace: workspace)} do
      state =
        %{
          id: id,
          workspace: workspace,
          role: role,
          seq: next_seq(history),
          fork_root_session_id: Fork.fork_root_session_id(history, id),
          turn: nil,
          pressure_warnings: MapSet.new(),
          writer_lease: writer_lease,
          writer_lease_timer_ref: nil,
          writer_lease_error: nil
        }
        |> schedule_writer_lease_heartbeat()

      {:ok, state}
    else
      {:writer_lease, {:error, err}} ->
        {:stop, {:session_writer_lease, err}}

      {:log, {:error, err}} ->
        {:stop, {:corrupt_log, err}}
    end
  end

  @impl true
  def terminate(_reason, state) do
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
      {:ok, stamped, next_state} -> {:reply, {:ok, stamped}, next_state}
      {:error, _} = error -> {:reply, error, state}
    end
  end

  def handle_call({:start_turn, turn_fun}, _from, %{turn: nil} = state) do
    case reconcile_pending_tool_calls(state, "before_start_turn") do
      {:ok, state} ->
        ctx = %{
          session_id: state.id,
          workspace: state.workspace,
          role: state.role,
          fork_root_session_id: state.fork_root_session_id
        }

        task = Task.Supervisor.async_nolink(@turn_supervisor, fn -> turn_fun.(ctx) end)
        {:reply, {:ok, task.ref}, %{state | turn: %{ref: task.ref, pid: task.pid}}}

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
    Events.publish(Event.status(state.id, "interrupted"))

    case reconcile_pending_tool_calls(%{state | turn: nil}, "interrupt") do
      {:ok, state} -> {:reply, :ok, state}
      {:error, error, state} -> {:reply, {:error, error}, state}
    end
  end

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
    {:noreply, %{state | turn: nil}}
  end

  # Turn Task crashed (or was killed before we flushed): clear it.
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{turn: %{ref: ref}} = state) do
    {:noreply, %{state | turn: nil}}
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
end
