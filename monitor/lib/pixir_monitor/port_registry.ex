defmodule PixirMonitor.PortRegistry do
  @moduledoc """
  Tracks Bandit's actual ephemeral listener port across Endpoint restarts.

  Stale application state is cleared at initialization and termination. Discovery is
  bounded per cycle, exposes exhaustion as structured state, and periodically probes
  without producing retry-log floods.
  """
  use GenServer

  @poll_ms 10
  @verify_ms 250
  @max_attempts 500

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @spec active_port() :: {:ok, pos_integer()} | {:error, map()}
  def active_port do
    case Application.get_env(:pixir_monitor, :active_port) do
      port when is_integer(port) and port > 0 -> {:ok, port}
      _ -> unavailable()
    end
  end

  @spec wait(non_neg_integer()) :: {:ok, pos_integer()} | {:error, map()}
  def wait(timeout_ms \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    wait_until(deadline)
  end

  @impl true
  def init(_opts) do
    clear()
    send(self(), :probe)
    {:ok, %{attempts: 0, status: :discovering, port: nil}}
  end

  @impl true
  def terminate(_reason, _state), do: clear()

  @impl true
  def handle_info(:probe, state) do
    case discover() do
      {:ok, port} ->
        Application.put_env(:pixir_monitor, :active_port, port, persistent: false)
        Application.put_env(:pixir_monitor, :port_discovery_status, :ready, persistent: false)
        Process.send_after(self(), :probe, @verify_ms)
        {:noreply, %{attempts: 0, status: :ready, port: port}}

      :retry when state.attempts + 1 >= @max_attempts ->
        if state.port, do: clear_port()
        Application.put_env(:pixir_monitor, :port_discovery_status, :exhausted, persistent: false)
        Process.send_after(self(), :probe, @verify_ms)
        {:noreply, %{attempts: 0, status: :exhausted, port: nil}}

      :retry ->
        if state.port, do: clear_port()
        Process.send_after(self(), :probe, @poll_ms)
        {:noreply, %{state | attempts: state.attempts + 1, status: :discovering, port: nil}}
    end
  end

  defp discover do
    case Bandit.PhoenixAdapter.server_info(PixirMonitor.Endpoint, :http) do
      {:ok, %{port: port}} when is_integer(port) and port > 0 -> {:ok, port}
      {:ok, {_address, port}} when is_integer(port) and port > 0 -> {:ok, port}
      _ -> :retry
    end
  rescue
    _ -> :retry
  catch
    _, _ -> :retry
  end

  defp wait_until(deadline) do
    case active_port() do
      {:ok, port} ->
        {:ok, port}

      {:error, _} = error ->
        if System.monotonic_time(:millisecond) >= deadline do
          error
        else
          Process.sleep(@poll_ms)
          wait_until(deadline)
        end
    end
  end

  defp unavailable do
    status = Application.get_env(:pixir_monitor, :port_discovery_status, :discovering)
    {:error, %{kind: "port_unavailable", message: "Monitor listener port is not available", details: %{discovery: to_string(status)}}}
  end

  defp clear do
    clear_port()
    Application.put_env(:pixir_monitor, :port_discovery_status, :discovering, persistent: false)
  end

  defp clear_port, do: Application.delete_env(:pixir_monitor, :active_port, persistent: false)
end
