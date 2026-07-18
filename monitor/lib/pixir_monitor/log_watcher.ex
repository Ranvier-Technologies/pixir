defmodule PixirMonitor.LogWatcher do
  @moduledoc """
  Polls bounded Session Log metadata and emits disposable invalidation hints.

  It reads only directory entries and regular-file metadata; it never reads Log bytes,
  folds events, or stores presenter projections. Each workspace fingerprint keeps the
  directory availability (`:available`, `:missing`, or `:unreadable`) separate from
  the bounded Log map, so an observed empty directory is not conflated with a source
  that could not be listed.

  Polling detects filesystem metadata and, in workspace-set mode, availability
  transitions only. Single-workspace availability transitions remain silent to
  preserve that frozen surface; extending them is a follow-up. Projection failures
  whose metadata is unchanged recover on the next authoritative scoped HTTP fetch:
  that fetch performs a fresh directory classification and projection read. Thus
  recovery is bounded by one explicit retry/refetch observation, not by a clock
  threshold or an unbounded cached failure.
  """
  use GenServer

  @poll_ms 500
  @default_max_logs 512

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc false
  @spec refresh() :: {:ok, :refreshed}
  def refresh, do: GenServer.call(__MODULE__, :refresh)

  @impl true
  def init(opts) do
    interval = Keyword.get(opts, :poll_ms, @poll_ms)
    send(self(), :poll)
    {:ok, %{fingerprints: nil, interval: interval}}
  end

  @impl true
  def handle_call(:refresh, _from, state) do
    state = refresh_state(state)
    {:reply, {:ok, :refreshed}, state}
  end

  @impl true
  def handle_info(:poll, state) do
    state = refresh_state(state)
    Process.send_after(self(), :poll, state.interval)
    {:noreply, state}
  end

  defp refresh_state(state) do
    fingerprints = snapshots()

    if is_map(state.fingerprints) do
      Enum.each(fingerprints, fn {workspace, current} ->
        previous = Map.get(state.fingerprints, workspace, missing_snapshot())

        changed_ids(previous.files, current.files)
        |> Enum.each(fn id -> publish(workspace, id) end)

        if previous.availability != current.availability do
          publish_availability(workspace)
        end
      end)
    end

    %{state | fingerprints: fingerprints}
  end

  defp snapshots do
    case PixirMonitor.WorkspaceSet.mode() do
      {:ok, :workspace_set} ->
        case PixirMonitor.WorkspaceSet.configured() do
          {:ok, sources} -> Map.new(sources, fn source -> {source.key, snapshot(source.path)} end)
          {:error, _} -> %{}
        end

      {:ok, :single} ->
        opts = Application.get_env(:pixir_monitor, :projection_source, [])
        %{nil => snapshot(Keyword.get(opts, :workspace, File.cwd!()))}
    end
  end

  defp snapshot(workspace) do
    opts = Application.get_env(:pixir_monitor, :projection_source, [])
    max_logs = Keyword.get(opts, :max_logs, @default_max_logs)
    directory = Path.join([workspace, ".pixir", "sessions"])

    case File.ls(directory) do
      {:ok, names} ->
        files =
          names
          |> Enum.filter(&String.ends_with?(&1, ".ndjson"))
          |> Enum.flat_map(&metadata(directory, &1))
          |> Enum.sort_by(fn {_id, fingerprint} -> fingerprint end, :desc)
          |> Enum.take(max_logs)
          |> Map.new()

        %{availability: :available, files: files}

      {:error, :enoent} ->
        missing_snapshot()

      {:error, _reason} ->
        %{availability: :unreadable, files: %{}}
    end
  end

  defp missing_snapshot, do: %{availability: :missing, files: %{}}

  defp metadata(directory, name) do
    case File.lstat(Path.join(directory, name), time: :posix) do
      {:ok, %File.Stat{type: :regular, size: size, mtime: mtime}} ->
        [{String.trim_trailing(name, ".ndjson"), {mtime, size}}]

      _ ->
        []
    end
  end

  defp publish(nil, id), do: PixirMonitor.InvalidationHub.projection_changed(id)
  defp publish(workspace, id), do: PixirMonitor.InvalidationHub.projection_changed(workspace, id)

  defp publish_availability(nil), do: :ok
  defp publish_availability(workspace), do: PixirMonitor.InvalidationHub.source_changed(workspace)

  defp changed_ids(previous, current) do
    (Map.keys(previous) ++ Map.keys(current))
    |> Enum.uniq()
    |> Enum.filter(&(Map.get(previous, &1) != Map.get(current, &1)))
  end
end
