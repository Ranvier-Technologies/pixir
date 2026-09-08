defmodule Pixir.Conversation do
  @moduledoc """
  The UI-agnostic multi-turn **driver** (ADR 0008): the conversational loop over
  `Session`/`Turn`/`Events`, with no presentation. Every front-end — the terminal CLI,
  a future HTTP/WebSocket tier, an editor extension, or an embedding Elixir app — drives
  Pixir through this module.

  It is a **stateless functional module**, not a process: the `Session` GenServer already
  owns turn state, History, `seq`, and interrupt (ADR 0001). Per-client state (a socket,
  a pending permission reply) belongs to the transport tier, never here.

  ## Shape

      {:ok, sid} = Conversation.start(workspace: ".")      # new Session
      {:ok, sid} = Conversation.start(id: sid)             # resume / reattach
      {:ok, ref} = Conversation.send(sid, "do the thing")  # run one Turn (non-blocking)

  **Observation is the `Events` bus** (ADR 0004), full stop — this module invents no new
  streaming abstraction. An out-of-process UI subscribes via `Pixir.Events.subscribe/1`
  and forwards each `{:pixir_event, event}` over its transport as JSON. For *in-process*
  callers (tests, an optional terminal presenter) `await/2` consumes the bus until the
  Turn reaches a terminal status, with an optional `on_event` callback.

  **Permissions stay injectable** (ADR 0006): pass an `:asker` function through `send/3`;
  this module implements no prompting. Async, remote permission decisions are a
  transport-tier concern (an asker that blocks the Turn while round-tripping over a
  socket).
  """

  alias Pixir.{Event, Events, Log, Session, SessionId, SessionSupervisor, Subagents, Turn}
  alias Pixir.Permissions.WritePolicy
  alias Pixir.Tools.CommandBoundary

  @minimum_liveness_wait_ms 1

  @type session_id :: String.t()

  @doc """
  Start a conversation, returning its Session id.

    * no `:id` — mint a **new** Session.
    * `:id` — **resume** a persisted Session (or idempotently reattach if it is already
      running). A missing Log is a structured `:not_found` error; a corrupt Log surfaces
      as a structured error rather than crashing the caller.

  Options: `:id`, `:workspace` (default cwd), `:role` (default `:build`),
  `:permission_mode` (default `:auto`) and `:write_policy` (default nil) — recorded as
  the new root Session's durable permission posture — plus
  `:force_release_writer_lease?` and `:force_release_reason`.
  """
  @spec start(keyword()) :: {:ok, session_id()} | {:error, map()}
  def start(opts \\ []) do
    workspace = Keyword.get(opts, :workspace, File.cwd!())
    role = Keyword.get(opts, :role, :build)
    start_opts = writer_lease_opts(opts)

    case Keyword.get(opts, :id) do
      nil ->
        start_new(workspace, role, start_opts, opts)

      id ->
        with :ok <- SessionId.validate(id) do
          resume(id, workspace, role, start_opts)
        end
    end
  end

  defp start_new(workspace, role, start_opts, opts) do
    case do_start([workspace: workspace, role: role] ++ start_opts, nil) do
      {:ok, id} ->
        case persist_root_posture(id, workspace, opts) do
          :ok ->
            {:ok, id}

          {:error, error} ->
            # A root whose posture failed to persist must not survive: it would
            # be exactly the unresumable no-posture write-capable Log this
            # evidence exists to prevent.
            SessionSupervisor.stop_session(id)
            {:error, unwrap_start_error(error)}
        end

      other ->
        other
    end
  end

  # Every operator-owned root Session records its permission posture as its
  # first durable event (seq 0, lineage "root") so a cold resume restores the
  # recorded capability ceiling instead of failing closed on write-capable
  # history. Spawned children record theirs in the Subagent Manager with
  # lineage "child"; `Subagents.resume_posture/2` only trusts a root marker in
  # root position (nothing before it except fork lineage metadata), so this
  # event cannot be retrofitted onto a legacy child Log.
  defp persist_root_posture(session_id, workspace, opts) do
    mode = Keyword.get(opts, :permission_mode, :auto)

    data = %{
      "event" => "permission_posture",
      "scope" => "session",
      "lineage" => "root",
      "source" => "root_session_start",
      "permission_mode" => Atom.to_string(mode),
      "write_policy" => WritePolicy.metadata(Keyword.get(opts, :write_policy)),
      "workspace_mode" => "shared",
      "workspace" => workspace
    }

    case Session.record(session_id, Event.subagent_event(session_id, data)) do
      {:ok, _event} -> :ok
      {:error, _error} = error -> error
    end
  end

  defp resume(id, workspace, role, start_opts) do
    case Log.exists(id, workspace: workspace) do
      {:ok, true} ->
        do_start([id: id, workspace: workspace, role: role] ++ start_opts, id)

      {:ok, false} ->
        {:error,
         error(
           :not_found,
           "no session #{id} in this workspace (looked in .pixir/sessions/)",
           %{id: id}
         )}

      {:error, _error} = error ->
        error
    end
  end

  defp writer_lease_opts(opts) do
    opts
    |> Keyword.take([:force_release_writer_lease?, :force_release_reason])
    |> Enum.reject(fn {_key, value} -> is_nil(value) or value == false end)
  end

  defp do_start(start_opts, expected_id) do
    case SessionSupervisor.start_session(start_opts) do
      {:ok, id, _pid} when expected_id in [nil, id] ->
        {:ok, id}

      {:error, reason} ->
        # A failed History fold arrives wrapped (e.g. `{:corrupt_log, structured}`);
        # surface the inner structured error (ADR 0008).
        {:error, unwrap_start_error(reason)}
    end
  end

  defp unwrap_start_error({:shutdown, reason}), do: unwrap_start_error(reason)
  defp unwrap_start_error({:failed_to_start_child, _id, reason}), do: unwrap_start_error(reason)
  defp unwrap_start_error({_tag, %{ok: false} = structured}), do: structured
  defp unwrap_start_error(%{ok: false} = structured), do: structured

  defp unwrap_start_error(other),
    do: error(:session_start_failed, "could not start session", %{reason: inspect(other)})

  @doc """
  Run one Turn for `prompt` in the Session. Non-blocking — returns `{:ok, ref}` once the
  Turn task is started (`{:error, :busy}` if a Turn is already running). Observe progress
  via the bus, or block with `await/2`.

  Options are passed to `Turn.run/3`: `:permission_mode` (default `:auto`), `:asker`
  (default deny), `:provider`, `:provider_opts`, `:dry_run`, `:max_iterations`.
  """
  @spec send(session_id(), String.t(), keyword()) :: {:ok, reference()} | {:error, :busy}
  def send(session_id, prompt, opts \\ []) when is_binary(prompt) do
    Session.start_turn(session_id, fn ctx -> Turn.run(ctx, prompt, opts) end)
  end

  @doc """
  Block until the current Turn reaches a terminal status, consuming bus events. The
  caller must already be subscribed (`Pixir.Events.subscribe/1`) — typically call
  `subscribe`, then `send`, then `await`.

  Returns `:done | :error | :interrupted | :timeout`. `interrupted` is terminal (ADR
  0008 — the Renderer's old loop hung on it). After a terminal event, `await/2` gives
  the Session process a short grace period to clear its active Turn, so callers can
  safely send the next prompt without seeing a transient `:busy`.

  Options: `:on_event` (a 1-arity callback invoked per event, for in-process rendering),
  `:idle_timeout` (ms, default 120_000), `:subagent_liveness?` and `:tool_liveness?`
  (both default `true`; internal red-proof seams), and `:cleanup_timeout` (ms, default
  1_000). When a positive idle deadline expires, bounded live presence extends the
  deadline: either an attached non-terminal Subagent with a live timeout cap, or an
  in-flight Tool whose spawned process is alive and still within that Tool's execution
  cap plus cleanup grace. Tool-backed extensions wait for at most the smaller of the
  presenter idle interval and that remaining Tool cap, with a 1ms floor for a live
  boundary-edge observation. Retry-queued children may instead rely on the active
  `wait_agent` timer that is already bounding their parent wait.
  """
  @spec await(session_id(), keyword()) :: :done | :error | :interrupted | :timeout
  def await(session_id, opts \\ []) do
    on_event = Keyword.get(opts, :on_event, fn _ -> :ok end)
    timeout = Keyword.get(opts, :idle_timeout, 120_000)

    liveness = %{
      subagent?: Keyword.get(opts, :subagent_liveness?, true),
      subagent_check:
        Keyword.get(opts, :subagent_liveness_check, &subagent_presenter_liveness?/1),
      tool?: Keyword.get(opts, :tool_liveness?, true),
      tool_check: Keyword.get(opts, :tool_liveness_check, &CommandBoundary.presenter_liveness/1)
    }

    cleanup_timeout = Keyword.get(opts, :cleanup_timeout, 1_000)

    case consume(session_id, on_event, timeout, liveness) do
      :timeout -> :timeout
      outcome -> await_turn_cleanup(session_id, outcome, cleanup_timeout)
    end
  end

  defp consume(session_id, on_event, timeout, liveness) do
    deadline = idle_deadline(timeout)

    consume_until(session_id, on_event, timeout, deadline, liveness)
  end

  defp consume_until(session_id, on_event, timeout, deadline, liveness) do
    receive do
      {:pixir_event, event} ->
        handle_await_event(event, session_id, on_event, timeout, liveness)
    after
      remaining_timeout(deadline) ->
        handle_idle_expiry(session_id, on_event, timeout, liveness)
    end
  end

  defp handle_await_event(event, session_id, on_event, timeout, liveness) do
    on_event.(event)

    case terminal(event) do
      nil ->
        consume_until(session_id, on_event, timeout, idle_deadline(timeout), liveness)

      outcome ->
        outcome
    end
  end

  defp handle_idle_expiry(_session_id, _on_event, timeout, _liveness)
       when timeout <= 0,
       do: :timeout

  defp handle_idle_expiry(session_id, on_event, timeout, liveness) do
    case presenter_extension_ms(session_id, liveness, timeout) do
      extension_ms when is_integer(extension_ms) ->
        consume_until(session_id, on_event, timeout, idle_deadline(extension_ms), liveness)

      nil ->
        drain_after_presence_check(session_id, on_event, timeout, liveness)
    end
  end

  defp drain_after_presence_check(session_id, on_event, timeout, liveness) do
    receive do
      {:pixir_event, event} ->
        handle_await_event(event, session_id, on_event, timeout, liveness)
    after
      0 -> :timeout
    end
  end

  defp idle_deadline(timeout), do: System.monotonic_time(:millisecond) + max(timeout, 0)

  defp remaining_timeout(deadline),
    do: max(deadline - System.monotonic_time(:millisecond), 0)

  defp presenter_extension_ms(session_id, liveness, idle_timeout) do
    cond do
      liveness.subagent? and liveness.subagent_check.(session_id) ->
        idle_timeout

      liveness.tool? ->
        tool_extension_ms(liveness.tool_check.(session_id), idle_timeout)

      true ->
        nil
    end
  end

  defp tool_extension_ms({:live, remaining_ms}, idle_timeout)
       when is_integer(remaining_ms) and remaining_ms >= 0 do
    min(idle_timeout, max(remaining_ms, @minimum_liveness_wait_ms))
  end

  # Boolean support keeps the internal injection seam backwards-compatible; the
  # production CommandBoundary returns the remaining bounded cap.
  defp tool_extension_ms(true, idle_timeout), do: idle_timeout
  defp tool_extension_ms(_presence, _idle_timeout), do: nil

  defp subagent_presenter_liveness?(session_id) do
    diagnostics_opts =
      case Session.info(session_id) do
        %{workspace: workspace} when is_binary(workspace) and workspace != "" ->
          [workspace: workspace]

        _other ->
          []
      end

    case Subagents.diagnostics(session_id, diagnostics_opts) do
      {:ok, %{"presenter_liveness_count" => count}} when is_integer(count) and count > 0 ->
        true

      _other ->
        false
    end
  catch
    :exit, _reason -> false
  end

  defp terminal(%{type: :status, data: %{"status" => "done"}}), do: :done
  defp terminal(%{type: :status, data: %{"status" => "error"}}), do: :error
  defp terminal(%{type: :status, data: %{"status" => "interrupted"}}), do: :interrupted
  defp terminal(_event), do: nil

  defp await_turn_cleanup(session_id, outcome, timeout) do
    deadline = System.monotonic_time(:millisecond) + max(timeout, 0)
    do_await_turn_cleanup(session_id, outcome, deadline)
  end

  defp do_await_turn_cleanup(session_id, outcome, deadline) do
    if Session.turn_running?(session_id) do
      if System.monotonic_time(:millisecond) >= deadline do
        outcome
      else
        Process.sleep(5)
        do_await_turn_cleanup(session_id, outcome, deadline)
      end
    else
      outcome
    end
  catch
    :exit, _reason -> outcome
  end

  @doc "Subscribe the calling process to the Session's event bus (pass-through)."
  @spec subscribe(session_id()) :: :ok | {:error, map()}
  def subscribe(session_id), do: Events.subscribe(session_id)

  @doc "Symmetric teardown for subscribe/1; effect-only per the rule-5 exception."
  @spec unsubscribe(session_id()) :: :ok
  def unsubscribe(session_id), do: Events.unsubscribe(session_id)

  @doc "Interrupt the running Turn, if any (pass-through to `Session`)."
  @spec interrupt(session_id()) :: :ok | {:error, :no_turn}
  def interrupt(session_id), do: Session.interrupt(session_id)

  @doc "The Session's History, folded from the Log (pass-through to `Session`)."
  @spec history(session_id()) :: {:ok, Log.history()} | {:error, map()}
  def history(session_id), do: Session.history(session_id)

  defp error(kind, message, details),
    do: %{ok: false, error: %{kind: kind, message: message, details: details}}
end
