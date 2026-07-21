defmodule PixirMonitor.InvalidationHub do
  @moduledoc """
  Fans out bounded `projection_changed` identifiers without storing projections.

  Each subscriber has at most one delivered and one coalesced hint. Frames contain no
  execution, gate, advisory, usage, evidence, mutation, or snapshot fields. Source
  availability transitions use the reserved `workspace:availability` projection id;
  its colon deliberately keeps it outside the canonical Session-id grammar while the
  frozen SSE frame shape remains unchanged.
  """
  use GenServer

  @max_subscribers 64
  @max_projection_id_bytes Pixir.SessionId.max_bytes()
  @source_projection_id "workspace:availability"

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  def subscribe, do: GenServer.call(__MODULE__, {:subscribe, self()})
  def unsubscribe, do: GenServer.cast(__MODULE__, {:unsubscribe, self()})
  def ack, do: GenServer.cast(__MODULE__, {:ack, self()})

  @doc "Signals every active SSE subscriber to close its stream."
  @spec close_all_subscribers() :: :ok
  def close_all_subscribers, do: GenServer.call(__MODULE__, :close_all_subscribers, 1_000)

  @doc "Emits a workspace-labelled ordinary invalidation for a source availability transition."
  @spec source_changed(String.t()) :: :ok | {:error, map()}
  def source_changed(workspace), do: projection_changed(workspace, @source_projection_id)

  @spec projection_changed(String.t()) :: :ok | {:error, map()}
  def projection_changed(id) when is_binary(id) and byte_size(id) <= @max_projection_id_bytes do
    case PixirMonitor.WorkspaceSet.mode() do
      {:ok, :single} -> GenServer.call(__MODULE__, {:publish, nil, id})
      {:ok, :workspace_set} -> {:error, %{kind: "workspace_required", message: "Workspace-set invalidations require a workspace key"}}
    end
  end

  def projection_changed(_id),
    do: {:error, %{kind: "invalid_projection_id", message: "Projection id exceeds the bounded contract", details: %{max_bytes: @max_projection_id_bytes}}}

  @spec projection_changed(String.t(), String.t()) :: :ok | {:error, map()}
  def projection_changed(workspace, id)
      when is_binary(workspace) and is_binary(id) and byte_size(id) <= @max_projection_id_bytes do
    case PixirMonitor.WorkspaceSet.validate_key(workspace) do
      :ok -> GenServer.call(__MODULE__, {:publish, workspace, id})
      {:error, _} = error -> error
    end
  end

  def projection_changed(_workspace, _id),
    do: {:error, %{kind: "invalid_projection_id", message: "Projection id exceeds the bounded contract", details: %{max_bytes: @max_projection_id_bytes}}}

  @doc false
  def frame(sequence, projection_id) when is_integer(sequence) and is_binary(projection_id) do
    bytes = Jason.encode!(%{type: "projection_changed", projection_id: projection_id})
    "id: #{sequence}\nevent: projection_changed\ndata: #{bytes}\n\n"
  end

  @doc false
  def frame(sequence, workspace, projection_id)
      when is_integer(sequence) and is_binary(workspace) and is_binary(projection_id) do
    bytes = Jason.encode!(%{type: "projection_changed", workspace: workspace, projection_id: projection_id})
    "id: #{sequence}\nevent: projection_changed\ndata: #{bytes}\n\n"
  end

  @impl true
  def init(_opts), do: {:ok, %{sequence: 0, subscribers: %{}}}

  @impl true
  def handle_call(:close_all_subscribers, _from, state) do
    Enum.each(Map.keys(state.subscribers), &send(&1, :pixir_sse_close))
    {:reply, :ok, state}
  end

  # The drain flag is set BEFORE close_all_subscribers is called and this
  # GenServer handles messages serially, so any subscribe arriving after the
  # close fan-out observes draining and is rejected — no subscriber can slip in
  # unclosed during shutdown. A restarted drainer clears the flag in init/1,
  # re-admitting subscriptions.
  def handle_call({:subscribe, pid}, _from, state) do
    if PixirMonitor.SseDrainer.draining?() do
      {:reply, {:error, %{kind: "shutting_down", message: "Monitor is stopping"}}, state}
    else
      subscribe_reply(pid, state)
    end
  end

  def handle_call({:publish, workspace, id}, _from, state) do
    sequence = state.sequence + 1
    hint = {sequence, workspace, id}

    subscribers =
      Map.new(state.subscribers, fn {pid, subscriber} ->
        if subscriber.pending do
          {pid, %{subscriber | queued: hint}}
        else
          send(pid, {:projection_changed, sequence, workspace, id})
          {pid, %{subscriber | pending: true}}
        end
      end)

    {:reply, :ok, %{state | sequence: sequence, subscribers: subscribers}}
  end

  @impl true
  def handle_cast({:ack, pid}, state) do
    case state.subscribers[pid] do
      nil ->
        {:noreply, state}

      %{queued: {sequence, workspace, id}} = subscriber ->
        send(pid, {:projection_changed, sequence, workspace, id})
        {:noreply, put_in(state.subscribers[pid], %{subscriber | pending: true, queued: nil})}

      subscriber ->
        {:noreply, put_in(state.subscribers[pid], %{subscriber | pending: false})}
    end
  end

  def handle_cast({:unsubscribe, pid}, state), do: {:noreply, drop(pid, state)}

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state), do: {:noreply, drop(pid, state)}

  defp subscribe_reply(pid, %{subscribers: subscribers} = state) when is_map_key(subscribers, pid) do
    {:reply, {:ok, state.sequence}, state}
  end

  defp subscribe_reply(pid, state) when map_size(state.subscribers) < @max_subscribers do
    ref = Process.monitor(pid)
    subscriber = %{ref: ref, pending: false, queued: nil}
    {:reply, {:ok, state.sequence}, put_in(state.subscribers[pid], subscriber)}
  end

  defp subscribe_reply(_pid, state),
    do: {:reply, {:error, %{kind: "subscriber_limit", message: "SSE subscriber limit reached", details: %{limit: @max_subscribers}}}, state}

  defp drop(pid, state) do
    case Map.pop(state.subscribers, pid) do
      {nil, _} ->
        state

      {%{ref: ref}, subscribers} ->
        Process.demonitor(ref, [:flush])
        %{state | subscribers: subscribers}
    end
  end
end
