defmodule Pixir.Log.BoundedReader do
  @moduledoc false

  # Internal positional-window engine. Pixir.Log owns the checked file handle,
  # canonical decoder, and requested Session identity. No Presenter dependency.
  @spec read(
          term(),
          non_neg_integer(),
          pos_integer(),
          (binary() -> term()),
          non_neg_integer() | nil
        ) :: {:ok, map()} | {:error, map()}
  def read(file, size, budget, decode, max_events \\ nil)

  def read(file, size, budget, decode, max_events) when size <= budget do
    with {:ok, bytes} <- read_at(file, 0, size),
         {complete, trailing} = complete_at_eof(bytes),
         {:ok, prefix, tail, partial} <- select_complete(complete, max_events) do
      finish(size, size, budget, prefix, tail, trailing, decode, partial)
    end
  end

  # Any byte-oversized selection needs both ends. Refuse an impossible event
  # budget before window contents can misclassify it as a byte-limit failure.
  def read(_file, size, budget, _decode, cap)
      when size > budget and is_integer(cap) and cap < 2,
      do: event_limit(cap)

  def read(file, size, budget, decode, max_events) do
    prefix_budget = div(budget, 2)
    tail_budget = budget - prefix_budget

    with {:ok, prefix_window} <- read_at(file, 0, prefix_budget),
         {:ok, tail_window} <- read_at(file, size - tail_budget, tail_budget),
         {prefix, _} = complete_prefix(prefix_window),
         tail_aligned = after_first_newline(tail_window),
         {tail, trailing} = complete_at_eof(tail_aligned),
         true <- prefix != "" and tail != "",
         {:ok, prefix, tail} <- select_windows(prefix, tail, max_events) do
      finish(size, budget, budget, prefix, tail, trailing, decode, true)
    else
      false -> failure(:log_read_limit, %{bytes: size})
      {:error, _} = error -> error
    end
  end

  defp finish(size, read, budget, prefix, tail, trailing, decode, partial) do
    with {:ok, first} <- decode.(prefix),
         {:ok, last} <- decode.(tail),
         true <- not partial or (first != [] and last != []),
         events = if(partial, do: first ++ last, else: Enum.sort_by(first, & &1.seq)),
         :ok <- selected_order(events) do
      selection = metadata(size, read, budget, prefix, tail, trailing, events, partial)

      selection =
        if partial, do: Map.put(selection, "tail_first_seq", hd(last).seq), else: selection

      {:ok, %{history: events, selection: selection}}
    else
      false -> failure(:log_read_limit, %{bytes: size})
      {:error, _} = error -> error
    end
  end

  defp select_complete(bytes, nil), do: {:ok, bytes, "", false}

  defp select_complete(bytes, cap) do
    spans = record_spans(bytes)
    count = length(spans)

    cond do
      count <= cap ->
        {:ok, bytes, "", false}

      cap < 2 ->
        event_limit(cap)

      true ->
        first = div(cap, 2)
        last = cap - first
        {:ok, take_prefix(bytes, spans, first, count), take_tail(bytes, spans, last, count), true}
    end
  end

  defp select_windows(prefix, tail, nil), do: {:ok, prefix, tail}
  defp select_windows(_prefix, _tail, cap) when cap < 2, do: event_limit(cap)

  defp select_windows(prefix, tail, cap) do
    first_spans = record_spans(prefix)
    last_spans = record_spans(tail)
    first_count = length(first_spans)
    last_count = length(last_spans)

    # Give the tail the odd slot, then reuse either end's unused quota. Physical
    # byte windows remain unchanged; this pass only narrows their selected cuts.
    first = min(first_count, div(cap, 2))
    last = min(last_count, cap - first)
    first = min(first_count, cap - last)

    {:ok, take_prefix(prefix, first_spans, first, first_count),
     take_tail(tail, last_spans, last, last_count)}
  end

  # Raw nonempty NDJSON lines are a conservative record budget, not certified
  # canonical Events. Match Log's decoder's empty-LF handling; retain all original
  # whitespace/CRLF/UTF-8 bytes inside each cut. Never decode the omitted middle or
  # reencode Events to estimate byte lengths. This pass is linear in bounded bytes.
  defp record_spans(bytes) do
    {reversed, start} =
      Enum.reduce(:binary.matches(bytes, "\n"), {[], 0}, fn {index, 1}, {spans, start} ->
        spans = if index > start, do: [{start, index + 1} | spans], else: spans
        {spans, index + 1}
      end)

    reversed =
      if start < byte_size(bytes), do: [{start, byte_size(bytes)} | reversed], else: reversed

    Enum.reverse(reversed)
  end

  defp take_prefix(bytes, _spans, count, count), do: bytes
  defp take_prefix(_bytes, _spans, 0, _count), do: ""

  defp take_prefix(bytes, spans, keep, _count) do
    {_start, stop} = Enum.at(spans, keep - 1)
    binary_part(bytes, 0, stop)
  end

  defp take_tail(bytes, _spans, count, count), do: bytes
  defp take_tail(_bytes, _spans, 0, _count), do: ""

  defp take_tail(bytes, spans, keep, count) do
    {start, _stop} = Enum.at(spans, count - keep)
    binary_part(bytes, start, byte_size(bytes) - start)
  end

  defp event_limit(cap),
    do:
      failure(:log_event_limit, %{
        max_events: cap,
        reason: "two_ended_selection_requires_two_events"
      })

  defp selected_order(events) do
    ordered =
      events
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.all?(fn [a, b] -> a.seq < b.seq end)

    if ordered,
      do: :ok,
      else: failure(:invalid_log_selection, %{reason: "invalid_selected_sequence"})
  end

  defp read_at(_file, _offset, 0), do: {:ok, ""}

  defp read_at(file, offset, bytes) do
    case :file.pread(file, offset, bytes) do
      {:ok, value} when byte_size(value) == bytes -> {:ok, value}
      _ -> failure(:log_read_failed, %{reason: "log_changed_during_read"})
    end
  end

  defp complete_prefix(bytes) do
    case :binary.matches(bytes, "\n") |> List.last() do
      {index, 1} -> {binary_part(bytes, 0, index + 1), byte_size(bytes) - index - 1}
      nil -> {"", byte_size(bytes)}
    end
  end

  # Syntactic completeness at the observed EOF is not envelope validity. Complete
  # JSON without LF still goes through Log's decoder; unfinished append bytes are
  # explicitly omitted. Never apply this to a prefix cut or unaligned tail start.
  defp complete_at_eof(bytes) do
    {complete, trailing} = complete_prefix(bytes)

    if trailing == 0 do
      {complete, 0}
    else
      final_record = binary_part(bytes, byte_size(complete), trailing)

      case Jason.decode(final_record) do
        {:ok, _value} -> {bytes, 0}
        {:error, _reason} -> {complete, trailing}
      end
    end
  end

  defp after_first_newline(bytes) do
    case :binary.match(bytes, "\n") do
      {index, 1} -> binary_part(bytes, index + 1, byte_size(bytes) - index - 1)
      :nomatch -> ""
    end
  end

  defp metadata(size, read, budget, prefix, tail, trailing, events, partial) do
    %{
      "partial" => partial,
      "bytes" => size,
      "bytes_read" => read,
      "read_budget_bytes" => budget,
      "bytes_omitted" => size - byte_size(prefix) - byte_size(tail),
      "events_retained" => length(events),
      "events_omitted" => if(partial or trailing > 0, do: "unknown", else: 0),
      "incomplete_trailing_bytes" => trailing
    }
  end

  defp failure(kind, details) do
    {:error,
     %{
       ok: false,
       error: %{
         kind: kind,
         message: "could not safely select bounded session log",
         details: details
       }
     }}
  end
end
