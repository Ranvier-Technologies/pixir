defmodule Pixir.Delegate.OwnerServer do
  @moduledoc """
  Current-runtime owner for one Delegate service run.

  The owner keeps live capability in OTP while this BEAM runtime is alive. It does not
  create a daemon, IPC server, nested Pixir process, or second durable store. Durable
  truth is still the parent Session Log; this process only proves live status and active
  cancellation capability.
  """

  use GenServer

  alias Pixir.Delegate.Owner
  alias Pixir.Subagents

  @active_statuses ~w(queued running)

  @doc "DynamicSupervisor child spec."
  def child_spec(opts) do
    %{
      id: {__MODULE__, make_ref()},
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary,
      shutdown: 5_000
    }
  end

  @doc "Start a Delegate owner."
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc "Return the start payload produced during owner initialization."
  def start_payload(pid), do: GenServer.call(pid, :start_payload)

  @doc "Return live owner state."
  def owner_state(pid, timeout \\ 5_000), do: GenServer.call(pid, :owner_state, timeout)

  @doc "Cancel live children through the owner."
  def cancel(pid, opts \\ []), do: GenServer.call(pid, {:cancel, opts}, 30_000)

  @impl true
  def init(opts) do
    request = Keyword.fetch!(opts, :request)
    spec = Keyword.fetch!(opts, :spec)
    spec_meta = Keyword.fetch!(opts, :spec_meta)
    runner = Keyword.get(opts, :runner, Pixir.Delegate.Runner)
    runtime_opts = Keyword.get(opts, :runtime_opts, [])

    case runner.start(request, spec, spec_meta, runtime_opts) do
      {:ok, context} ->
        case register(context.handle) do
          :ok ->
            {:ok,
             %{
               handle: context.handle,
               parent_session_id: context.parent_session_id,
               workspace: context.runtime.workspace,
               runtime: context.runtime,
               agents: context.agents,
               start_payload: context.payload
             }}

          {:error, error} ->
            {:stop, {:shutdown, error}}
        end

      {:error, error} ->
        {:stop, {:shutdown, error}}
    end
  end

  @impl true
  def handle_call(:start_payload, _from, state), do: {:reply, {:ok, state.start_payload}, state}

  def handle_call(:owner_state, _from, state) do
    {:reply, {:ok, owner_state_payload(state)}, state}
  end

  def handle_call({:cancel, opts}, _from, state) do
    workspace = Keyword.get(opts, :workspace, state.workspace)

    case list_children(state.parent_session_id, workspace) do
      {:ok, manager_children} ->
        cancellable = Enum.filter(manager_children, &(child_status(&1) in @active_statuses))
        {cancelled, errors} = close_children(state.parent_session_id, cancellable, workspace)

        {:reply,
         {:ok,
          %{
            "manager_children" => manager_children,
            "cancelled_children" => cancelled,
            "errors" => errors,
            "owner" => owner_state_payload(state)
          }}, state}

      {:error, error} ->
        {:reply, {:error, normalize_error(error)}, state}
    end
  end

  defp register(handle) do
    with {:ok, _} <-
           Registry.register(Pixir.Delegate.OwnerRegistry, handle["delegate_id"], handle),
         {:ok, _} <-
           Registry.register(Pixir.Delegate.OwnerRegistry, handle["parent_session_id"], handle) do
      :ok
    else
      {:error, reason} ->
        {:error,
         %{
           "ok" => false,
           "status" => "rejected",
           "kind" => "delegate_owner_registration_failed",
           "message" => "Delegate owner handle could not be registered",
           "details" => %{
             "delegate_id" => handle["delegate_id"],
             "parent_session_id" => handle["parent_session_id"],
             "reason" => inspect(reason),
             "next_actions" => ["inspect_delegate_owner_registry", "retry_delegate_start"]
           }
         }}
    end
  end

  defp owner_state_payload(state) do
    case Owner.live_owner_state(state.handle, %{
           "planned_child_count" => state.runtime.planned_child_count,
           "started_child_count" => length(state.agents),
           "workspace" => state.workspace,
           "runtime_residency" => runtime_residency()
         }) do
      {:ok, owner_state} -> owner_state
      {:error, error} -> error
    end
  end

  defp list_children(parent_session_id, workspace) do
    case Subagents.list(parent_session_id, workspace: workspace) do
      {:ok, manager_children} ->
        {:ok, manager_children}

      {:error, error} ->
        {:error, normalize_error(error)}

      other ->
        {:error,
         %{
           "ok" => false,
           "status" => "rejected",
           "kind" => "owner_unavailable",
           "message" => "Delegate owner could not list Subagents",
           "details" => %{
             "reason" => inspect(other),
             "next_actions" => ["retry_cancel_with_backoff", "inspect_subagent_manager"]
           }
         }}
    end
  catch
    :exit, reason ->
      {:error,
       %{
         "ok" => false,
         "status" => "rejected",
         "kind" => "owner_unavailable",
         "message" => "Delegate owner could not list Subagents",
         "details" => %{
           "reason" => inspect(reason),
           "next_actions" => ["retry_cancel_with_backoff", "inspect_subagent_manager"]
         }
       }}
  end

  defp close_children(parent_session_id, children, workspace) do
    Enum.reduce(children, {[], []}, fn child, {closed, errors} ->
      id = child["subagent_id"] || child["id"]

      case close_child(parent_session_id, id, workspace) do
        {:ok, updated} -> {[updated | closed], errors}
        {:error, error} -> {closed, [error | errors]}
      end
    end)
    |> then(fn {closed, errors} -> {Enum.reverse(closed), Enum.reverse(errors)} end)
  end

  defp close_child(parent_session_id, id, workspace) do
    case Subagents.close(parent_session_id, id, workspace: workspace) do
      {:ok, updated} ->
        {:ok, updated}

      {:error, error} ->
        {:error, normalize_error(error)}

      other ->
        {:error,
         %{
           "ok" => false,
           "status" => "rejected",
           "kind" => "cancel_failed",
           "message" => "Subagent close returned an unexpected response",
           "details" => %{"subagent_id" => id, "response" => inspect(other)}
         }}
    end
  catch
    :exit, reason ->
      {:error,
       %{
         "ok" => false,
         "status" => "rejected",
         "kind" => "owner_unavailable",
         "message" => "Delegate owner could not close a Subagent",
         "details" => %{
           "subagent_id" => id,
           "reason" => inspect(reason),
           "next_actions" => ["retry_cancel_with_backoff", "inspect_subagent_manager"]
         }
       }}
  end

  defp normalize_error(%{ok: false, error: %{kind: kind, message: message} = error}) do
    %{
      "ok" => false,
      "status" => "rejected",
      "kind" => to_string(kind),
      "message" => message,
      "details" => stringify_keys(Map.get(error, :details, %{}))
    }
  end

  defp normalize_error(%{"ok" => false} = error), do: error

  defp normalize_error(error) do
    %{
      "ok" => false,
      "status" => "rejected",
      "kind" => "owner_unavailable",
      "message" => "Delegate owner operation failed",
      "details" => %{"reason" => inspect(error)}
    }
  end

  defp stringify_keys(%{} = map),
    do: Map.new(map, fn {key, value} -> {to_string(key), stringify_keys(value)} end)

  defp stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)
  defp stringify_keys(value), do: value

  defp child_status(child), do: child["status"] || child[:status] || "unknown"

  defp runtime_residency do
    %{
      "model" => "current_beam_runtime",
      "survives_cli_process_exit" => false,
      "cross_invocation_owner" => false,
      "daemon_or_ipc" => false
    }
  end
end
