# proc-pressure Tier 1, BEAM arms: in-VM worker creation tax.
# Run: elixir --erl "+S 1:1" proc-pressure-tier1-beam.exs pinned
#      elixir proc-pressure-tier1-beam.exs unpinned
# No network, no quota. spawn_monitor of a no-op, awaiting DOWN.

label = List.first(System.argv()) || "unpinned"
reps = String.to_integer(System.get_env("REP", "10"))
ladder = [100, 1_000, 10_000, 100_000]

seq = fn n ->
  for _ <- 1..n do
    {pid, ref} = spawn_monitor(fn -> :ok end)
    receive do
      {:DOWN, ^ref, :process, ^pid, _} -> :ok
    end
  end
end

par = fn n ->
  refs = for _ <- 1..n, do: spawn_monitor(fn -> :ok end)

  Enum.each(refs, fn {pid, ref} ->
    receive do
      {:DOWN, ^ref, :process, ^pid, _} -> :ok
    end
  end)
end

bench = fn mode_name, fun ->
  for n <- ladder do
    fun.(n)

    vals =
      for _ <- 1..reps do
        {us, _} = :timer.tc(fn -> fun.(n) end)
        us / n
      end

    sorted = Enum.sort(vals)
    # true median: even-length lists average the two middle values
    # (fixed 2026-07-07; earlier revisions took the upper value)
    len = length(sorted)

    median =
      (Enum.at(sorted, div(len - 1, 2)) + Enum.at(sorted, div(len, 2))) / 2

    row = %{
      arm: "beam_spawn_monitor",
      mode: mode_name,
      schedulers: label,
      n: n,
      reps: reps,
      per_worker_us_median: Float.round(median, 3),
      per_worker_us_min: Float.round(Enum.min(vals), 3),
      per_worker_us_max: Float.round(Enum.max(vals), 3),
      cache_state: "warm"
    }

    IO.puts(Jason.encode!(row))
  end
end

# Jason may not be available outside a Mix project; fall back to manual JSON.
encode = fn row ->
  fields =
    row
    |> Enum.map(fn {k, v} ->
      value = if is_binary(v), do: ~s("#{v}"), else: to_string(v)
      ~s("#{k}":#{value})
    end)
    |> Enum.join(",")

  "{" <> fields <> "}"
end

bench_manual = fn mode_name, fun ->
  for n <- ladder do
    fun.(n)

    vals =
      for _ <- 1..reps do
        {us, _} = :timer.tc(fn -> fun.(n) end)
        us / n
      end

    sorted = Enum.sort(vals)
    # true median: even-length lists average the two middle values
    # (fixed 2026-07-07; earlier revisions took the upper value)
    len = length(sorted)

    median =
      (Enum.at(sorted, div(len - 1, 2)) + Enum.at(sorted, div(len, 2))) / 2

    row = [
      arm: "beam_spawn_monitor",
      mode: mode_name,
      schedulers: label,
      n: n,
      reps: reps,
      per_worker_us_median: Float.round(median, 3),
      per_worker_us_min: Float.round(Enum.min(vals), 3),
      per_worker_us_max: Float.round(Enum.max(vals), 3),
      cache_state: "warm"
    ]

    IO.puts(encode.(row))
  end
end

_ = bench
bench_manual.("seq", seq)
bench_manual.("par", par)
