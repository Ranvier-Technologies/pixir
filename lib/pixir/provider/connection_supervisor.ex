defmodule Pixir.Provider.ConnectionSupervisor do
  @moduledoc """
  Dynamic supervisor for Provider WebSocket connections.

  Connections are keyed by Session/Subagent/caller identity. They hold only ephemeral
  transport optimization state; Pixir's Log remains the durable source of truth.
  """

  use DynamicSupervisor

  alias Pixir.Provider.Connection

  @registry Pixir.Provider.ConnectionRegistry

  def start_link(opts \\ []) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts), do: DynamicSupervisor.init(strategy: :one_for_one)

  @spec ensure_started(term()) :: {:ok, pid()} | {:error, term()}
  def ensure_started(key) do
    case Registry.lookup(@registry, key) do
      [{pid, _}] ->
        {:ok, pid}

      [] ->
        spec = {Connection, key: key}

        case DynamicSupervisor.start_child(__MODULE__, spec) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
          {:error, _} = error -> error
        end
    end
  end
end
