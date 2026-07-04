defmodule Pixir.Provider.StreamIdle do
  @moduledoc """
  Per-chunk idle watchdog for Provider streams.

  A hung SSE or WebSocket stream is cut when no activity arrives within
  `stream_idle_timeout_ms`. HTTP/SSE transports run behind a spawned runner so the
  caller can enforce the window; WebSocket clients also reset the deadline on every
  received frame (including control frames) via `:stream_activity`.
  """

  alias Pixir.{Config, Tool}

  @default_idle_ms 180_000

  @doc false
  @spec idle_timeout_ms(keyword()) :: non_neg_integer() | :infinity
  def idle_timeout_ms(opts) do
    Keyword.get_lazy(opts, :stream_idle_timeout_ms, fn -> Config.stream_idle_timeout_ms() end)
  end

  @doc false
  @spec default_idle_ms() :: pos_integer()
  def default_idle_ms, do: @default_idle_ms

  @doc false
  @spec error(non_neg_integer(), String.t()) :: map()
  def error(timeout_ms, transport) do
    Tool.error(
      :stream_idle_timeout,
      "Provider stream stalled waiting for the next chunk.",
      %{
        timeout_ms: timeout_ms,
        transport: transport,
        next_actions: ["retry_turn", "check_network_or_provider_status"]
      }
    )
  end

  @doc """
  Run `stream_fn` behind a per-chunk idle watchdog.

  `stream_fn` receives an activity callback that transports must invoke whenever
  they receive a chunk/frame (HTTP via the wrapped reducer; WebSocket via
  `:stream_activity` in opts).
  """
  @spec run(((-> :ok) -> term()), keyword(), String.t()) :: term()
  def run(stream_fn, opts, transport_label) when is_function(stream_fn, 1) do
    case idle_timeout_ms(opts) do
      timeout when timeout in [:infinity, 0] ->
        stream_fn.(fn -> :ok end)

      idle_ms ->
        run_monitored(stream_fn, idle_ms, transport_label)
    end
  end

  defp run_monitored(stream_fn, idle_ms, transport_label) do
    caller = self()
    ref = make_ref()
    activity = fn -> send(caller, {ref, :activity}) end

    {pid, mon} =
      spawn_monitor(fn ->
        send(caller, {ref, :done, stream_fn.(activity)})
      end)

    watch(ref, idle_ms, transport_label, mon, pid)
  end

  defp watch(ref, idle_ms, transport_label, mon, pid) do
    receive do
      {^ref, :activity} ->
        watch(ref, idle_ms, transport_label, mon, pid)

      {^ref, :done, result} ->
        Process.demonitor(mon, [:flush])
        result

      {:DOWN, ^mon, :process, ^pid, reason} ->
        Process.demonitor(mon, [:flush])

        {:error,
         Tool.error(:network, "Provider stream process exited.", %{
           reason: inspect(reason),
           transport: transport_label
         })}
    after
      idle_ms ->
        Process.exit(pid, :kill)
        Process.demonitor(mon, [:flush])
        {:error, error(idle_ms, transport_label)}
    end
  end

  @doc false
  @spec notify(keyword()) :: :ok
  def notify(opts) do
    case Keyword.get(opts, :stream_activity) do
      fun when is_function(fun, 0) -> fun.()
      _ -> :ok
    end
  end

  @doc false
  @spec transport_label(keyword()) :: String.t()
  def transport_label(opts) do
    cond do
      Keyword.has_key?(opts, :transport) ->
        "http_sse"

      Keyword.get(opts, :provider_transport) == :websocket ->
        "websocket"

      Keyword.get(opts, :provider_transport) == :http_sse ->
        "http_sse"

      true ->
        "auto"
    end
  end
end
