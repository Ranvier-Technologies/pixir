defmodule Pixir.SessionSupervisor do
  @moduledoc """
  `DynamicSupervisor` of `Pixir.Session` processes (ADR 0001). A Session is started
  on demand — for a new conversation or to `resume` a persisted one — and is
  `:transient`, so it stays down once it finishes cleanly. The CLI may also ask this
  supervisor to stop all currently running Sessions during process shutdown so
  filesystem writer leases are released before the OS process exits.
  """

  use DynamicSupervisor

  alias Pixir.Session

  def start_link(init_arg) do
    DynamicSupervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @doc """
  Start a Session. Accepts `:id` (generated if absent), `:workspace`, `:role`,
  `:force_release_writer_lease?`, and `:force_release_reason`. Forced lease release is
  a break-glass resume path for stale/ambiguous writer evidence; active leases are
  refused. Returns `{:ok, session_id, pid}` so the caller always learns the id.
  """
  @spec start_session(keyword()) :: {:ok, String.t(), pid()} | {:error, term()}
  def start_session(opts \\ []) do
    opts = Keyword.put_new_lazy(opts, :id, &Session.gen_id/0)
    id = Keyword.fetch!(opts, :id)

    case DynamicSupervisor.start_child(__MODULE__, {Session, opts}) do
      {:ok, pid} -> {:ok, id, pid}
      {:error, {:already_started, pid}} -> {:ok, id, pid}
      {:error, _} = err -> err
    end
  end

  @doc """
  Stop one live Session by id.

  Presenter/Manager cleanup for fail-closed error paths that started a Session and
  then refused it (e.g. a failed resume-posture restore): the process must not
  survive its own rejection as an untracked live writer. A Session that is not
  running is a no-op success.
  """
  @spec stop_session(String.t()) :: {:ok, :stopped | :not_running}
  def stop_session(session_id) when is_binary(session_id) do
    case Registry.lookup(Pixir.Sessions.Registry, session_id) do
      [{pid, _value}] ->
        case DynamicSupervisor.terminate_child(__MODULE__, pid) do
          :ok -> {:ok, :stopped}
          {:error, :not_found} -> {:ok, :not_running}
        end

      [] ->
        {:ok, :not_running}
    end
  end

  @doc """
  Stop every live Session owned by this runtime.

  This is a CLI shutdown helper, not a stale-writer recovery path: it only terminates
  processes that are currently supervised in this BEAM instance. Stale lease files
  left by crashed or killed processes remain fail-closed for explicit resume handling.
  """
  @spec stop_all_sessions() :: {:ok, map()} | {:error, map()}
  def stop_all_sessions do
    case Process.whereis(__MODULE__) do
      nil ->
        {:ok, %{stopped: 0, already_gone: 0}}

      _pid ->
        __MODULE__
        |> DynamicSupervisor.which_children()
        |> stop_children()
        |> stop_result()
    end
  end

  defp stop_children([]), do: %{stopped: 0, already_gone: 0, errors: []}

  defp stop_children(children) do
    # `DynamicSupervisor.terminate_child/2` is handled by the supervisor process
    # itself, so wrapping calls in Tasks would only parallelize waiting callers while
    # making shutdown accounting less honest. Keep this small CLI-exit sweep
    # sequential and measured instead.
    Enum.reduce(children, %{stopped: 0, already_gone: 0, errors: []}, &stop_child/2)
  end

  defp stop_child({_id, pid, _type, _modules}, acc) when is_pid(pid) do
    case DynamicSupervisor.terminate_child(__MODULE__, pid) do
      :ok ->
        %{acc | stopped: acc.stopped + 1}

      {:error, :not_found} ->
        %{acc | already_gone: acc.already_gone + 1}

      {:error, reason} ->
        %{acc | errors: [%{pid: inspect(pid), reason: inspect(reason)} | acc.errors]}
    end
  end

  defp stop_child({_id, _non_pid_state, _type, _modules}, acc),
    do: %{acc | already_gone: acc.already_gone + 1}

  defp stop_result(%{errors: []} = result), do: {:ok, Map.delete(result, :errors)}

  defp stop_result(result) do
    {:error,
     %{
       ok: false,
       error: %{
         kind: :session_shutdown_failed,
         message: "could not stop all live Sessions",
         details: %{errors: Enum.reverse(result.errors)}
       }
     }}
  end
end
