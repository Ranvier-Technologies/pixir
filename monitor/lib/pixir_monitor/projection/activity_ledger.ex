defmodule PixirMonitor.Projection.ActivityLedger do
  @moduledoc """
  Bounded, disposable observation-to-observation memory for the polling caller.

  `PixirMonitor.Projection.Builder` is a pure deterministic fold over a single
  bounded input map: it may never compare a projection against a previously
  built one, consult a clock, or retain state between builds. But deciding
  whether durable evidence *advanced* is inherently a statement about two
  successive observations, so somebody has to hold that memory. This module is
  that somebody, and it lives on the polling-caller side of the boundary.

  It records nothing but the durable coordinates the caller already carries —
  the highest observed parent Log `seq` and the latest durable timestamp — keyed
  by run identity. Comparing the current observation against the previously
  recorded one yields the assertion the builder admits as `activity_evidence`.

  Every value here is recomputable and disposable. No projection, execution
  state, gate, advisory, usage, or evidence is stored, and no wall clock is
  consulted: "advanced" is decided from durable Log coordinates alone, never
  from elapsed time. Losing the ledger degrades to `"unknown"`, which folds to
  today's conservative `stale_handle` behavior rather than to a false claim of
  health.

  The ledger is bounded to `@max_entries` run identities. Once full it evicts the
  least recently observed identity rather than growing without limit or refusing
  new ones; an evicted run simply reports `"unknown"` again on its next
  observation, exactly as a run seen for the first time does.
  """
  use GenServer

  @max_entries 512
  @vocabulary ~w(advanced unchanged unknown)

  @doc false
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: name(opts))

  @doc """
  Records this observation of `run_id` and returns the builder's
  `activity_evidence` input for it.

  `as_of_seq` is the highest parent Log sequence in this observation and
  `last_durable_at` the latest durable timestamp. Returns `nil` when the ledger
  is unavailable, which the builder treats as "not asserted".
  """
  @spec observe(String.t(), integer() | nil, String.t() | nil) :: map() | nil
  def observe(run_id, as_of_seq, last_durable_at)
      when is_binary(run_id) and (is_integer(as_of_seq) or is_nil(as_of_seq)) do
    GenServer.call(__MODULE__, {:observe, run_id, as_of_seq, last_durable_at}, 1_000)
  catch
    :exit, _reason -> nil
  end

  def observe(_run_id, _as_of_seq, _last_durable_at), do: nil

  @doc """
  Deterministic comparison of two successive durable observations.

  The durable sequence is authoritative whenever both sides carry one: equal
  sequences are `"unchanged"` even if the timestamps differ, because a Log whose
  `seq` did not move recorded nothing new. The timestamp comparison is only a
  fallback for observations where a sequence is unavailable on either side.
  """
  @spec classify({integer() | nil, String.t() | nil}, {integer() | nil, String.t() | nil} | nil) ::
          String.t()
  def classify(_current, nil), do: "unknown"

  def classify({seq, at}, {prior_seq, prior_at}) do
    cond do
      is_integer(seq) and is_integer(prior_seq) and seq > prior_seq -> "advanced"
      is_integer(seq) and is_integer(prior_seq) and seq < prior_seq -> "unknown"
      is_integer(seq) and is_integer(prior_seq) -> "unchanged"
      is_binary(at) and is_binary(prior_at) and at > prior_at -> "advanced"
      true -> "unknown"
    end
  end

  @doc false
  def vocabulary, do: @vocabulary

  @doc false
  def max_entries, do: @max_entries

  @impl true
  def init(_opts), do: {:ok, %{entries: %{}, tick: 0}}

  @impl true
  def handle_call({:observe, run_id, seq, at}, _from, %{entries: entries, tick: tick}) do
    current = {seq, at}
    prior = with {coordinates, _seen} <- Map.get(entries, run_id), do: coordinates
    durable_evidence = classify(current, prior)

    tick = tick + 1

    entries =
      entries
      |> evict_least_recent(run_id)
      |> Map.put(run_id, {current, tick})

    evidence = %{
      "durable_evidence" => durable_evidence,
      "prior_as_of_seq" => prior && elem(prior, 0),
      "prior_last_durable_at" => prior && elem(prior, 1),
      "basis" => "caller_observation_delta"
    }

    {:reply, evidence, %{entries: entries, tick: tick}}
  end

  # Bounding may not become a permanent ceiling: without eviction, the first
  # `@max_entries` identities would hold the ledger forever and every run started
  # afterwards would report "unknown" for the life of the process, silently
  # reverting the feature. Evicting the least recently observed identity keeps the
  # bound while letting the memory follow the runs actually being polled.
  defp evict_least_recent(entries, run_id) do
    if Map.has_key?(entries, run_id) or map_size(entries) < @max_entries do
      entries
    else
      {oldest, _seen} = Enum.min_by(entries, fn {_id, {_coordinates, seen}} -> seen end)
      Map.delete(entries, oldest)
    end
  end

  defp name(opts), do: Keyword.get(opts, :name, __MODULE__)
end
