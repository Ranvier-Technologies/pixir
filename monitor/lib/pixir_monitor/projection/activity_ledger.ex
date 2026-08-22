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
  by source-scoped run identity. Comparing the current observation against the
  previously recorded one yields the assertion the builder admits as
  `activity_evidence`.

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

  @type identity :: String.t() | {:workspace, String.t(), String.t()}

  @doc false
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: name(opts))

  @doc """
  Records this observation of a run identity and returns the builder's
  `activity_evidence` input for it.

  The default ledger remains available through `observe/3`. `observe/4` accepts
  an explicit registered name or pid, which lets callers use a disposable
  ledger without coupling to application supervision. A filesystem source uses
  `{:workspace, stable_workspace, run_id}` as its identity so equal run ids from
  different roots never share observation history.

  `as_of_seq` is the highest parent Log sequence in this observation and
  `last_durable_at` the latest durable timestamp. Returns `{:error, :unavailable}`
  when the ledger is missing, stopped, or does not reply before the bounded call
  timeout. Callers that supply optional Builder input may translate that closed
  failure to `nil` ("not asserted"). Invalid observations return
  `{:error, :invalid_observation}`.
  """
  @spec observe(identity(), integer() | nil, String.t() | nil) ::
          {:ok, map()} | {:error, :invalid_observation | :unavailable}
  def observe(identity, as_of_seq, last_durable_at),
    do: observe(__MODULE__, identity, as_of_seq, last_durable_at)

  @spec observe(GenServer.server(), identity(), integer() | nil, String.t() | nil) ::
          {:ok, map()} | {:error, :invalid_observation | :unavailable}
  def observe(server, identity, as_of_seq, last_durable_at)
      when (is_binary(identity) or
              (is_tuple(identity) and tuple_size(identity) == 3 and elem(identity, 0) == :workspace and
                 is_binary(elem(identity, 1)) and is_binary(elem(identity, 2)))) and
             (is_integer(as_of_seq) or is_nil(as_of_seq)) do
    if valid_server?(server) do
      {:ok, GenServer.call(server, {:observe, identity, as_of_seq, last_durable_at}, 1_000)}
    else
      {:error, :invalid_observation}
    end
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  def observe(_server, _identity, _as_of_seq, _last_durable_at),
    do: {:error, :invalid_observation}

  @doc """
  Deterministic comparison of two successive durable observations.

  The durable sequence is authoritative whenever both sides carry one: equal
  sequences are `"unchanged"` even if the timestamps differ, because a Log whose
  `seq` did not move recorded nothing new. The timestamp comparison is only a
  fallback for observations where a sequence is unavailable on either side.
  Valid ISO-8601 values are compared as instants; malformed evidence asserts
  nothing.
  """
  @spec classify({integer() | nil, String.t() | nil}, {integer() | nil, String.t() | nil} | nil) ::
          String.t()
  def classify(_current, nil), do: "unknown"

  def classify({seq, at}, {prior_seq, prior_at}) do
    cond do
      is_integer(seq) and is_integer(prior_seq) and seq > prior_seq -> "advanced"
      is_integer(seq) and is_integer(prior_seq) and seq < prior_seq -> "unknown"
      is_integer(seq) and is_integer(prior_seq) -> "unchanged"
      true -> classify_instants(at, prior_at)
    end
  end

  @doc false
  def vocabulary, do: @vocabulary

  @doc false
  def max_entries, do: @max_entries

  @impl true
  def init(_opts), do: {:ok, %{entries: %{}, tick: 0}}

  @impl true
  def handle_call({:observe, identity, seq, at}, _from, %{entries: entries, tick: tick}) do
    current = {seq, at}
    prior = with {coordinates, _seen} <- Map.get(entries, identity), do: coordinates
    durable_evidence = classify(current, prior)

    tick = tick + 1

    entries =
      entries
      |> evict_least_recent(identity)
      |> Map.put(identity, {current, tick})

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
  defp evict_least_recent(entries, identity) do
    if Map.has_key?(entries, identity) or map_size(entries) < @max_entries do
      entries
    else
      {oldest, _seen} = Enum.min_by(entries, fn {_identity, {_coordinates, seen}} -> seen end)
      Map.delete(entries, oldest)
    end
  end

  defp classify_instants(at, prior_at) when is_binary(at) and is_binary(prior_at) do
    with {:ok, current, _offset} <- DateTime.from_iso8601(at),
         {:ok, prior, _offset} <- DateTime.from_iso8601(prior_at) do
      case DateTime.compare(current, prior) do
        :gt -> "advanced"
        :eq -> "unchanged"
        :lt -> "unknown"
      end
    else
      _ -> "unknown"
    end
  end

  defp classify_instants(_at, _prior_at), do: "unknown"

  defp valid_server?(server) when is_atom(server) or is_pid(server), do: true
  defp valid_server?({:global, _name}), do: true

  defp valid_server?({:via, module, _name}) when is_atom(module) do
    Code.ensure_loaded?(module) and
      Enum.all?(
        [register_name: 2, unregister_name: 1, whereis_name: 1, send: 2],
        fn {callback, arity} -> function_exported?(module, callback, arity) end
      )
  end

  defp valid_server?(_server), do: false

  defp name(opts), do: Keyword.get(opts, :name, __MODULE__)
end
