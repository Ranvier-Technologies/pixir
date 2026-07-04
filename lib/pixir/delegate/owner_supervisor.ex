defmodule Pixir.Delegate.OwnerSupervisor do
  @moduledoc """
  Dynamic supervisor and lookup surface for live Delegate owners.

  Delegate owner residency is intentionally scoped to the current BEAM runtime in this
  slice. The registry lets `start`, `status`, and `cancel` find live capability while
  the runtime is alive; durable Session Logs remain the source of truth after restart or
  escript exit.
  """

  use DynamicSupervisor

  alias Pixir.Delegate.OwnerServer

  @registry Pixir.Delegate.OwnerRegistry

  @doc "Application child spec."
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor,
      restart: :permanent,
      shutdown: 5_000
    }
  end

  @doc "Start the Delegate owner supervisor."
  def start_link(opts \\ []), do: DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts), do: DynamicSupervisor.init(strategy: :one_for_one)

  @doc "Start a live owner for a validated Delegate spec."
  @spec start_delegate(map(), map(), map(), keyword()) :: {:ok, map()} | {:error, map()}
  def start_delegate(request, spec, spec_meta, opts \\ []) do
    child_opts = [
      request: request,
      spec: spec,
      spec_meta: spec_meta,
      runner: Keyword.get(opts, :runner, Pixir.Delegate.Runner),
      runtime_opts: Keyword.get(opts, :runtime_opts, [])
    ]

    case DynamicSupervisor.start_child(__MODULE__, {OwnerServer, child_opts}) do
      {:ok, pid} ->
        OwnerServer.start_payload(pid)

      {:error, {:already_started, pid}} ->
        OwnerServer.start_payload(pid)

      {:error, {:shutdown, %{"ok" => false} = error}} ->
        {:error, error}

      {:error, reason} ->
        {:error,
         %{
           "ok" => false,
           "status" => "rejected",
           "kind" => "owner_unavailable",
           "message" => "Delegate owner could not be started",
           "details" => %{
             "reason" => inspect(reason),
             "next_actions" => ["inspect_delegate_owner_supervisor", "retry_delegate_start"]
           }
         }}
    end
  end

  @doc "Return live owner state when the current runtime owns the handle."
  @spec owner_state(map()) :: {:ok, map()} | {:error, :not_found}
  def owner_state(handle) when is_map(handle) do
    with {:ok, pid} <- lookup(handle) do
      case safe_owner_call(fn -> OwnerServer.owner_state(pid) end) do
        {:ok, owner_state} -> {:ok, owner_state}
        {:error, _reason} -> {:error, :not_found}
      end
    end
  end

  def owner_state(_handle), do: {:error, :not_found}

  @doc "Cancel live Delegate work through the owner when reachable."
  @spec cancel(map(), keyword()) :: {:ok, map()} | {:error, :not_found | map()}
  def cancel(handle, opts \\ [])

  def cancel(handle, opts) when is_map(handle) do
    with {:ok, pid} <- lookup(handle) do
      safe_owner_call(fn -> OwnerServer.cancel(pid, opts) end)
    end
  end

  def cancel(_handle, _opts), do: {:error, :not_found}

  @doc "Lookup a Delegate owner by delegate id or parent Session id."
  @spec lookup(map()) :: {:ok, pid()} | {:error, :not_found}
  def lookup(handle) when is_map(handle) do
    keys =
      [handle["delegate_id"], handle["parent_session_id"]]
      |> Enum.reject(&is_nil/1)

    Enum.find_value(keys, {:error, :not_found}, fn key ->
      case Registry.lookup(@registry, key) do
        [{pid, _meta} | _] -> {:ok, pid}
        [] -> nil
      end
    end)
  end

  def lookup(_handle), do: {:error, :not_found}

  defp safe_owner_call(fun) do
    fun.()
  catch
    :exit, _reason -> {:error, :not_found}
  end
end
