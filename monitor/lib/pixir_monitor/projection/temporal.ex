defmodule PixirMonitor.Projection.Temporal do
  @moduledoc """
  Frozen temporal schema and deterministic ordering for the Runs inventory.

  Every list row carries a `"temporal"` map with exactly three boundary fields
  (`"started_at"`, `"ended_at"`, `"latest_at"`) and one derived `"duration"`.
  Each boundary is `%{"value", "basis", "completeness"}` where completeness is one
  of `complete | incomplete | unknown | malformed`:

    * `complete` — an ISO 8601 timestamp parsed from parent Log evidence.
    * `malformed` — evidence supplied a timestamp string that does not parse.
    * `unknown` — no parent Log evidence names the boundary. The boundary is
      never manufactured from wall clock, browser time, liveness, terminal
      execution state, or SSE receipt.

  Evidence bases are pinned names:

    * `started_at` — `"workflow_started_event_ts"` or `"first_subagent_lifecycle_ts"`.
    * `ended_at` — `"workflow_finished_event_ts"` or `"terminal_subagent_lifecycle_ts"`
      (the max timestamp across lifecycle-terminal subagent events, present only
      when every observed subagent lifecycle is itself terminal).
    * `latest_at` — `"max_parent_event_ts"`.
    * `duration` — `"boundary_difference"`; `complete` only when both boundaries
      are complete, `incomplete` when the start is complete but the end is
      unknown, `malformed` if either boundary is malformed, otherwise `unknown`.

  Default sort is `recency_desc`: newest `latest_at` first. All sorts are total
  orders: complete values order first by the sort direction, then incomplete,
  then unknown, then malformed; exact ties break by ascending run id.
  """

  @completeness ~w(complete incomplete unknown malformed)
  @sorts ~w(recency_desc recency_asc duration_desc duration_asc)
  @default_sort "recency_desc"

  @doc "Pinned completeness vocabulary for temporal boundaries and durations."
  @spec completeness_vocabulary() :: [String.t()]
  def completeness_vocabulary, do: @completeness

  @doc "Pinned sort vocabulary accepted by the Runs hash route."
  @spec sort_vocabulary() :: [String.t()]
  def sort_vocabulary, do: @sorts

  @doc "The pinned default sort, `recency_desc`."
  @spec default_sort() :: String.t()
  def default_sort, do: @default_sort

  @doc """
  Selects the timestamp representing the latest parseable instant.

  Malformed and nil entries lose to parseable timestamps; an empty list returns nil.
  """
  @spec max_instant([term()]) :: String.t() | nil
  def max_instant(values) do
    Enum.max_by(values, &max_instant_key/1, fn -> nil end)
  end

  @doc """
  Builds the frozen temporal map for one Runs list row from parent Log evidence.

  `workflow` / `finish` are the parent `workflow_started` / `workflow_finished`
  events (or nil), `subs` the subagent lifecycle events, `latest_at` the raw max
  parent event timestamp, and `all_terminal?` whether every folded subagent
  lifecycle is terminal.
  """
  @spec row_temporal(map() | nil, map() | nil, [map()], String.t() | nil, boolean()) :: map()
  def row_temporal(workflow, finish, subs, latest_at, all_terminal?) do
    started = started_boundary(workflow, subs)
    ended = ended_boundary(finish, subs, all_terminal?)

    %{
      "started_at" => started,
      "ended_at" => ended,
      "latest_at" => boundary(latest_at, "max_parent_event_ts"),
      "duration" => duration(started, ended)
    }
  end

  defp started_boundary(%{"ts" => ts}, _subs) when is_binary(ts),
    do: boundary(ts, "workflow_started_event_ts")

  defp started_boundary(_workflow, subs) do
    subs
    |> Enum.map(& &1["ts"])
    |> Enum.filter(&is_binary/1)
    |> case do
      [] -> boundary(nil, nil)
      timestamps -> boundary(Enum.min_by(timestamps, &sortable_instant/1), "first_subagent_lifecycle_ts")
    end
  end

  defp ended_boundary(%{"ts" => ts}, _subs, _all_terminal?) when is_binary(ts),
    do: boundary(ts, "workflow_finished_event_ts")

  defp ended_boundary(_finish, subs, true) do
    subs
    |> Enum.map(& &1["ts"])
    |> Enum.filter(&is_binary/1)
    |> case do
      [] -> boundary(nil, nil)
      timestamps -> boundary(Enum.max_by(timestamps, &max_instant_key/1), "terminal_subagent_lifecycle_ts")
    end
  end

  defp ended_boundary(_finish, _subs, _all_terminal?), do: boundary(nil, nil)

  defp boundary(nil, _basis), do: %{"value" => nil, "basis" => nil, "completeness" => "unknown"}

  defp boundary(value, basis) when is_binary(value) do
    case parse(value) do
      {:ok, _unix} -> %{"value" => value, "basis" => basis, "completeness" => "complete"}
      :error -> %{"value" => value, "basis" => basis, "completeness" => "malformed"}
    end
  end

  defp boundary(_value, basis), do: %{"value" => nil, "basis" => basis, "completeness" => "malformed"}

  defp duration(started, ended) do
    cond do
      started["completeness"] == "malformed" or ended["completeness"] == "malformed" ->
        %{"ms" => nil, "basis" => "boundary_difference", "completeness" => "malformed"}

      started["completeness"] == "complete" and ended["completeness"] == "complete" ->
        {:ok, from} = parse(started["value"])
        {:ok, to} = parse(ended["value"])

        if to < from do
          %{"ms" => nil, "basis" => "boundary_difference", "completeness" => "malformed"}
        else
          %{"ms" => div(to - from, 1000), "basis" => "boundary_difference", "completeness" => "complete"}
        end

      started["completeness"] == "complete" ->
        %{"ms" => nil, "basis" => "boundary_difference", "completeness" => "incomplete"}

      true ->
        %{"ms" => nil, "basis" => "boundary_difference", "completeness" => "unknown"}
    end
  end

  @doc """
  Deterministic ascending sort key for `recency_desc` (the pinned default order):
  complete timestamps newest-first, then unknown, then malformed; ties by id.
  """
  @spec recency_desc_key(map()) :: tuple()
  def recency_desc_key(row) do
    temporal = row["temporal"] || %{}
    latest = temporal["latest_at"] || legacy_latest(row)

    case {latest["completeness"], parse(latest["value"])} do
      {"complete", {:ok, unix}} -> {0, -unix, row["id"]}
      {"malformed", _} -> {2, 0, row["id"]}
      _ -> {1, 0, row["id"]}
    end
  end

  defp legacy_latest(row), do: boundary(row["latest_at"], "max_parent_event_ts")

  defp max_instant_key(value) do
    case parse(value) do
      {:ok, unix} -> {1, unix, value}
      :error when is_binary(value) -> {0, 0, value}
      :error -> {0, 0, ""}
    end
  end

  defp sortable_instant(value) do
    case parse(value) do
      {:ok, unix} -> {0, unix, value}
      :error -> {1, 0, value}
    end
  end

  defp parse(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> {:ok, DateTime.to_unix(datetime, :microsecond)}
      _ -> :error
    end
  end

  defp parse(_value), do: :error
end
