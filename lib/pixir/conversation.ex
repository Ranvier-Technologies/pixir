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

  alias Pixir.{Events, Log, Session, SessionSupervisor, Turn}

  @type session_id :: String.t()

  @doc """
  Start a conversation, returning its Session id.

    * no `:id` — mint a **new** Session.
    * `:id` — **resume** a persisted Session (or idempotently reattach if it is already
      running). A missing Log is a structured `:not_found` error; a corrupt Log surfaces
      as a structured error rather than crashing the caller.

  Options: `:id`, `:workspace` (default cwd), `:role` (default `:build`),
  `:force_release_writer_lease?`, and `:force_release_reason`.
  """
  @spec start(keyword()) :: {:ok, session_id()} | {:error, map()}
  def start(opts \\ []) do
    workspace = Keyword.get(opts, :workspace, File.cwd!())
    role = Keyword.get(opts, :role, :build)
    start_opts = writer_lease_opts(opts)

    case Keyword.get(opts, :id) do
      nil -> do_start([workspace: workspace, role: role] ++ start_opts, nil)
      id -> resume(id, workspace, role, start_opts)
    end
  end

  defp resume(id, workspace, role, start_opts) do
    if Log.exists?(id, workspace: workspace) do
      do_start([id: id, workspace: workspace, role: role] ++ start_opts, id)
    else
      {:error,
       error(:not_found, "no session #{id} in this workspace (looked in .pixir/sessions/)", %{
         id: id
       })}
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
  `:idle_timeout` (ms, default 120_000), and `:cleanup_timeout` (ms, default 1_000).
  """
  @spec await(session_id(), keyword()) :: :done | :error | :interrupted | :timeout
  def await(session_id, opts \\ []) do
    on_event = Keyword.get(opts, :on_event, fn _ -> :ok end)
    timeout = Keyword.get(opts, :idle_timeout, 120_000)
    cleanup_timeout = Keyword.get(opts, :cleanup_timeout, 1_000)

    case consume(on_event, timeout) do
      :timeout -> :timeout
      outcome -> await_turn_cleanup(session_id, outcome, cleanup_timeout)
    end
  end

  defp consume(on_event, timeout) do
    receive do
      {:pixir_event, event} ->
        on_event.(event)

        case terminal(event) do
          nil -> consume(on_event, timeout)
          outcome -> outcome
        end
    after
      timeout -> :timeout
    end
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
  @spec subscribe(session_id()) :: :ok
  def subscribe(session_id), do: Events.subscribe(session_id)

  @doc "Interrupt the running Turn, if any (pass-through to `Session`)."
  @spec interrupt(session_id()) :: :ok | {:error, :no_turn}
  def interrupt(session_id), do: Session.interrupt(session_id)

  @doc "The Session's History, folded from the Log (pass-through to `Session`)."
  @spec history(session_id()) :: {:ok, Log.history()} | {:error, map()}
  def history(session_id), do: Session.history(session_id)

  defp error(kind, message, details),
    do: %{ok: false, error: %{kind: kind, message: message, details: details}}
end
