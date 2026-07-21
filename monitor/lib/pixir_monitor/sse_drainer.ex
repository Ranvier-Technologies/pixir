defmodule PixirMonitor.SseDrainer do
  @moduledoc false
  use GenServer

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Reports whether the Monitor API is draining for shutdown."
  @spec draining?() :: boolean()
  def draining?, do: :persistent_term.get({__MODULE__, :draining}, false)

  @doc false
  @spec init(keyword()) :: {:ok, map()}
  @impl true
  def init(_opts) do
    :persistent_term.put({__MODULE__, :draining}, false)
    Process.flag(:trap_exit, true)
    {:ok, %{}}
  end

  @doc false
  @spec terminate(term(), map()) :: :ok
  @impl true
  def terminate(_reason, _state) do
    :persistent_term.put({__MODULE__, :draining}, true)

    if Process.whereis(PixirMonitor.InvalidationHub) do
      PixirMonitor.InvalidationHub.close_all_subscribers()
    end

    :ok
  catch
    _kind, _reason -> :ok
  end
end
