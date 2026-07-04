defmodule Pixir.Tools.CommandBoundary do
  @moduledoc """
  Bounded host-command boundary for local Tool execution (ADR 0027).

  This process is deliberately smaller than a product `CommandBroker`: it only
  accounts for external process capacity, bounded queueing, and read-only runtime
  snapshots. Tool lifecycle, permissions, and canonical `tool_call`/`tool_result`
  Events remain owned by `Pixir.Tools.Executor`.
  """

  use GenServer

  alias Pixir.{Config, Tool}

  @server __MODULE__
  @boundary "host_command"

  @type lease :: %{id: reference(), host_command: map()}
  @type limits :: %{
          max_concurrent: pos_integer(),
          queue_limit: non_neg_integer(),
          queue_timeout_ms: non_neg_integer()
        }

  @doc "Application child spec."
  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :id, __MODULE__),
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent,
      shutdown: 5_000
    }
  end

  @doc "Start a command boundary. Omitting `:name` starts the application singleton."
  def start_link(opts \\ []) do
    server_opts =
      case Keyword.fetch(opts, :name) do
        {:ok, nil} -> []
        {:ok, name} -> [name: name]
        :error -> [name: @server]
      end

    GenServer.start_link(__MODULE__, opts, server_opts)
  end

  @doc """
  Acquire a host-command slot, run `fun`, and release the slot in all normal
  return/raise/throw/exit paths.
  """
  @spec with_slot(String.t(), keyword(), (lease() -> term()) | (-> term())) ::
          term() | {:error, map()}
  def with_slot(tool, opts, fun)
      when is_binary(tool) and is_list(opts) and is_function(fun) do
    boundary = Keyword.get(opts, :boundary, @server)

    with {:ok, limits} <- limits(Keyword.get(opts, :limits)),
         {:ok, lease} <- acquire(boundary, tool, limits) do
      try do
        run_fun(fun, lease)
      after
        release(boundary, lease)
      end
    end
  end

  defp run_fun(fun, lease) when is_function(fun, 1), do: fun.(lease)
  defp run_fun(fun, _lease) when is_function(fun, 0), do: fun.()

  @doc "Return a read-only snapshot of host-command pressure."
  @spec snapshot(keyword()) :: {:ok, map()} | {:error, map()}
  def snapshot(opts \\ []) do
    boundary = Keyword.get(opts, :boundary, @server)

    with {:ok, limits} <- limits(Keyword.get(opts, :limits)) do
      GenServer.call(boundary, {:snapshot, limits})
    end
  catch
    :exit, {:noproc, _} ->
      {:error,
       Tool.error(:read_failed, "host command boundary is unavailable", %{
         "boundary" => @boundary,
         "next_actions" => ["start_or_restart_pixir"]
       })}
  end

  @doc "Normalize user/app config into command-boundary limits."
  @spec limits(map() | keyword() | nil) :: {:ok, limits()} | {:error, map()}
  def limits(nil) do
    with {:ok, host_commands} <- Config.host_commands() do
      limits(host_commands)
    end
  end

  def limits(%{} = raw) do
    with {:ok, max_concurrent} <- positive(raw, "max_concurrent"),
         {:ok, queue_limit} <- non_negative(raw, "queue_limit"),
         {:ok, queue_timeout_ms} <- non_negative(raw, "queue_timeout_ms") do
      {:ok,
       %{
         max_concurrent: max_concurrent,
         queue_limit: queue_limit,
         queue_timeout_ms: queue_timeout_ms
       }}
    end
  end

  def limits(raw) when is_list(raw) do
    raw
    |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)
    |> limits()
  rescue
    _ -> invalid_limits()
  end

  def limits(_raw), do: invalid_limits()

  @impl true
  def init(_opts) do
    {:ok, %{active: %{}, queue: :queue.new(), waiters: %{}}}
  end

  @impl true
  def handle_call({:acquire, request}, from, state) do
    cond do
      active_count(state) < request.limits.max_concurrent ->
        {lease, state} = grant(request, from, state)
        {:reply, {:ok, lease}, state}

      queue_depth(state) < request.limits.queue_limit ->
        state = enqueue(request, from, state)
        {:noreply, state}

      true ->
        {:reply, {:error, backpressure("queue_full", request, state, 0)}, state}
    end
  end

  def handle_call({:snapshot, limits}, _from, state) do
    {:reply, {:ok, public_snapshot(state, limits)}, state}
  end

  @impl true
  def handle_cast({:release, id}, state) do
    {:noreply, state |> release_active(id) |> drain_waiters()}
  end

  @impl true
  def handle_info({:queue_timeout, id}, state) do
    case Map.pop(state.waiters, id) do
      {nil, _waiters} ->
        {:noreply, state}

      {waiter, waiters} ->
        Process.demonitor(waiter.monitor_ref, [:flush])
        queued_ms = monotonic_ms() - waiter.enqueued_at_ms

        GenServer.reply(
          waiter.from,
          {:error, backpressure("queue_timeout", waiter, state, queued_ms)}
        )

        {:noreply, %{state | waiters: waiters, queue: :queue.delete(id, state.queue)}}
    end
  end

  def handle_info({:DOWN, monitor_ref, :process, _pid, _reason}, state) do
    state =
      case find_active_by_monitor(state, monitor_ref) do
        nil ->
          remove_waiter_by_monitor(state, monitor_ref)

        id ->
          state |> release_active(id) |> drain_waiters()
      end

    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp acquire(boundary, tool, limits) do
    request = %{
      id: make_ref(),
      tool: tool,
      limits: limits,
      enqueued_at_ms: monotonic_ms()
    }

    GenServer.call(boundary, {:acquire, request}, limits.queue_timeout_ms + 1_000)
  catch
    :exit, {:noproc, _} ->
      {:error,
       Tool.error(:command_failed, "host command boundary is unavailable", %{
         "boundary" => @boundary,
         "tool" => tool,
         "next_actions" => ["start_or_restart_pixir"]
       })}

    :exit, {:timeout, _} ->
      {:error,
       Tool.error(:timeout, "host command boundary did not respond", %{
         "boundary" => @boundary,
         "tool" => tool,
         "timeout_ms" => limits.queue_timeout_ms + 1_000,
         "next_actions" => ["retry_command", "inspect_host_command_boundary_snapshot"]
       })}
  end

  defp release(boundary, %{id: id}) do
    GenServer.cast(boundary, {:release, id})
  catch
    :exit, _ -> :ok
  end

  defp grant(request, from, state) do
    now = monotonic_ms()
    queued_ms = max(now - request.enqueued_at_ms, 0)
    monitor_ref = Process.monitor(elem(from, 0))

    host_command = %{
      "boundary" => @boundary,
      "tool" => request.tool,
      "queued_ms" => queued_ms,
      "active_count_at_start" => active_count(state) + 1,
      "max_concurrent" => request.limits.max_concurrent,
      "queue_depth_at_start" => queue_depth(state),
      "queue_limit" => request.limits.queue_limit
    }

    lease = %{id: request.id, host_command: host_command}

    active =
      Map.put(state.active, request.id, %{
        monitor_ref: monitor_ref,
        tool: request.tool,
        started_at_ms: now,
        limits: request.limits
      })

    {lease, %{state | active: active}}
  end

  defp enqueue(request, from, state) do
    monitor_ref = Process.monitor(elem(from, 0))

    timer_ref =
      Process.send_after(self(), {:queue_timeout, request.id}, request.limits.queue_timeout_ms)

    waiter =
      request
      |> Map.put(:from, from)
      |> Map.put(:monitor_ref, monitor_ref)
      |> Map.put(:timer_ref, timer_ref)

    %{
      state
      | queue: :queue.in(request.id, state.queue),
        waiters: Map.put(state.waiters, request.id, waiter)
    }
  end

  defp release_active(state, id) do
    case Map.pop(state.active, id) do
      {nil, _active} ->
        state

      {active, active_map} ->
        Process.demonitor(active.monitor_ref, [:flush])
        %{state | active: active_map}
    end
  end

  defp drain_waiters(state) do
    case next_waiter(state) do
      {nil, state} ->
        state

      {waiter, state} ->
        Process.cancel_timer(waiter.timer_ref)
        Process.demonitor(waiter.monitor_ref, [:flush])
        {lease, state} = grant(waiter, waiter.from, state)
        GenServer.reply(waiter.from, {:ok, lease})
        drain_waiters(state)
    end
  end

  defp next_waiter(state) do
    case :queue.out(state.queue) do
      {{:value, id}, queue} ->
        case Map.pop(state.waiters, id) do
          {nil, waiters} ->
            next_waiter(%{state | queue: queue, waiters: waiters})

          {waiter, waiters} ->
            if active_count(state) < waiter.limits.max_concurrent do
              {waiter, %{state | queue: queue, waiters: waiters}}
            else
              {nil,
               %{state | queue: :queue.in_r(id, queue), waiters: Map.put(waiters, id, waiter)}}
            end
        end

      {:empty, _queue} ->
        {nil, state}
    end
  end

  defp find_active_by_monitor(state, monitor_ref) do
    state.active
    |> Enum.find_value(fn {id, active} ->
      if active.monitor_ref == monitor_ref, do: id
    end)
  end

  defp remove_waiter_by_monitor(state, monitor_ref) do
    case Enum.find(state.waiters, fn {_id, waiter} -> waiter.monitor_ref == monitor_ref end) do
      nil ->
        state

      {id, waiter} ->
        Process.cancel_timer(waiter.timer_ref)
        %{state | waiters: Map.delete(state.waiters, id), queue: :queue.delete(id, state.queue)}
    end
  end

  defp public_snapshot(state, limits) do
    active = active_count(state)
    queued = queue_depth(state)

    %{
      "boundary" => @boundary,
      "active_count" => active,
      "max_concurrent" => limits.max_concurrent,
      "queue_depth" => queued,
      "queue_limit" => limits.queue_limit,
      "queue_timeout_ms" => limits.queue_timeout_ms,
      "pressure_state" => pressure_state(active, queued, limits)
    }
  end

  defp pressure_state(active, queued, limits) do
    cond do
      active >= limits.max_concurrent and queued >= limits.queue_limit -> "saturated"
      active >= limits.max_concurrent -> "at_capacity"
      queued > 0 -> "queued"
      true -> "available"
    end
  end

  defp backpressure(reason, request, state, queued_ms) do
    Tool.error(:backpressure, "host command boundary is under pressure", %{
      "boundary" => @boundary,
      "tool" => request.tool,
      "active_count" => active_count(state),
      "max_concurrent" => request.limits.max_concurrent,
      "queue_depth" => queue_depth(state),
      "queue_limit" => request.limits.queue_limit,
      "queued_ms" => queued_ms,
      "reason" => reason,
      "next_actions" => [
        "retry_after_current_host_commands_finish",
        "reduce_parallel_shell_commands",
        "inspect_host_command_boundary_snapshot"
      ]
    })
  end

  defp active_count(state), do: map_size(state.active)
  defp queue_depth(state), do: map_size(state.waiters)
  defp monotonic_ms, do: System.monotonic_time(:millisecond)

  defp positive(raw, key) do
    case Map.get(raw, key) do
      value when is_integer(value) and value > 0 -> {:ok, value}
      value -> {:error, invalid_limit(key, value, "positive integer")}
    end
  end

  defp non_negative(raw, key) do
    case Map.get(raw, key) do
      value when is_integer(value) and value >= 0 -> {:ok, value}
      value -> {:error, invalid_limit(key, value, "non-negative integer")}
    end
  end

  defp invalid_limit(key, value, expected) do
    Tool.error(:invalid_args, "invalid host command limit", %{
      "field" => key,
      "value" => inspect(value),
      "expected" => expected
    })
  end

  defp invalid_limits do
    {:error, Tool.error(:invalid_args, "host command limits must be an object", %{})}
  end
end
