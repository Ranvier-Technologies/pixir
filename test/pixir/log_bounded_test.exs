defmodule Pixir.LogBoundedTest do
  use ExUnit.Case, async: false

  alias Pixir.{Event, Log, Paths}

  setup do
    ws = Path.join(System.tmp_dir!(), "pixir-log-bounded-#{System.unique_integer([:positive])}")
    File.mkdir_p!(ws)
    on_exit(fn -> File.rm_rf!(ws) end)
    %{ws: ws, sid: "bounded-session"}
  end

  test "event budget alone selects a prefix and tail from a byte-fitting Log", ctx do
    raw = Enum.map_join(0..9, "\n", &record(ctx.sid, &1))
    write_log(ctx, raw)
    assert {:ok, %{history: history, selection: selection}} = bounded(ctx, max_events: 5)
    assert Enum.map(history, & &1.seq) == [0, 1, 7, 8, 9]
    assert selection["partial"]
    assert selection["tail_first_seq"] == 7
    assert selection["events_retained"] == 5
    assert selection["events_omitted"] == "unknown"
    assert selection["bytes_read"] == byte_size(raw)
    assert selection["bytes_omitted"] > 0
    assert File.read!(Log.path(ctx.sid, workspace: ctx.ws)) == raw
  end

  test "event budget also bounds many small records in byte-limited windows", ctx do
    raw = Enum.map_join(0..999, "\n", &record(ctx.sid, &1)) <> "\n"
    write_log(ctx, raw)

    assert {:ok, %{history: history, selection: selection}} =
             bounded(ctx, max_events: 5, max_log_bytes: 8192)

    assert Enum.map(history, & &1.seq) == [0, 1, 997, 998, 999]
    assert selection["events_retained"] == 5
    assert selection["bytes_read"] == 8192
    assert selection["tail_first_seq"] == 997
  end

  test "under both bounds matches ordinary folds and absent event cap remains unlimited", ctx do
    raw = Enum.map_join(0..9, "\n", &record(ctx.sid, &1))
    write_log(ctx, raw)
    assert {:ok, ordinary} = Log.fold(ctx.sid, workspace: ctx.ws)
    assert {:ok, ^ordinary} = Log.fold_append_order(ctx.sid, workspace: ctx.ws)

    for opts <- [[], [max_events: 10], [max_events: 11]] do
      assert {:ok, %{history: ^ordinary, selection: selection}} = bounded(ctx, opts)
      refute selection["partial"]
      refute Map.has_key?(selection, "tail_first_seq")
      assert selection["bytes_omitted"] == 0
      assert selection["events_omitted"] == 0
    end
  end

  test "zero and one event caps permit complete under-limit cases but never grow a cap", ctx do
    for cap <- [0, 1] do
      write_log(ctx, "\n\n")

      assert {:ok, %{history: [], selection: %{"partial" => false}}} =
               bounded(ctx, max_events: cap)
    end

    write_log(ctx, record(ctx.sid, 0))

    assert {:ok, %{history: [%{seq: 0}], selection: %{"partial" => false}}} =
             bounded(ctx, max_events: 1)

    assert {:error, %{error: %{kind: :log_event_limit}}} = bounded(ctx, max_events: 0)

    raw = Enum.map_join(0..99, "\n", &record(ctx.sid, &1))
    write_log(ctx, raw)

    for cap <- [0, 1], budget <- [1024, byte_size(raw)] do
      assert {:error, %{error: %{kind: :log_event_limit}}} =
               bounded(ctx, max_events: cap, max_log_bytes: budget)
    end
  end

  test "invalid event caps refuse before any physical Log read", ctx do
    write_log(ctx, record(ctx.sid, 0))

    for cap <- [nil, -1, 1.5, "5", :unbounded, false] do
      {result, calls} = trace_reads(fn -> bounded(ctx, max_events: cap) end)
      assert {:error, %{error: %{kind: :log_event_limit}}} = result
      assert calls == []
    end
  end

  test "undersized event caps win before unusable oversized byte windows are read", ctx do
    write_log(ctx, record(ctx.sid, 0, %{"text" => String.duplicate("x", 10_000)}))

    for cap <- [0, 1] do
      {result, calls} = trace_reads(fn -> bounded(ctx, max_events: cap, max_log_bytes: 512) end)
      assert {:error, %{error: %{kind: :log_event_limit, details: %{max_events: ^cap}}}} = result
      assert calls == []
    end
  end

  test "odd event quotas reuse spare capacity in either physical window", ctx do
    middle = String.duplicate("unread", 1000) <> "\n"
    many_first = Enum.map_join(0..9, "\n", &record(ctx.sid, &1)) <> "\n"
    many_last = Enum.map_join(90..99, "\n", &record(ctx.sid, &1)) <> "\n"

    for {prefix, tail, expected} <- [
          {record(ctx.sid, 0) <> "\n", many_last, [0, 96, 97, 98, 99]},
          {many_first, record(ctx.sid, 99) <> "\n", [0, 1, 2, 3, 99]}
        ] do
      write_log(ctx, prefix <> middle <> tail)

      assert {:ok, %{history: history, selection: selection}} =
               bounded(ctx, max_log_bytes: 4096, max_events: 5)

      assert Enum.map(history, & &1.seq) == expected
      assert selection["events_retained"] == 5
      assert selection["bytes_read"] == 4096
    end
  end

  test "event cuts preserve original whitespace blank lines CRLF UTF-8 and complete EOF bytes",
       ctx do
    # Deliberately noncanonical JSON key order and spacing: reencoding is not a
    # valid way to account for these original selected byte segments.
    line = fn seq ->
      ~s( { "seq" : #{seq}, "type":"user_message", "session_id":"#{ctx.sid}", "data":{"text":"é雪"}, "id":"raw-#{seq}" } )
    end

    prefix = "\n\n" <> line.(0) <> "\r\n\n" <> line.(1) <> "\r\n"
    middle = "\n" <> line.(2) <> "\r\n" <> line.(3) <> "\n\n"
    tail = line.(4) <> "\r\n\n" <> line.(5)
    raw = prefix <> middle <> tail
    write_log(ctx, raw)
    assert {:ok, %{history: history, selection: selection}} = bounded(ctx, max_events: 4)
    assert Enum.map(history, & &1.seq) == [0, 1, 4, 5]
    assert selection["tail_first_seq"] == 4
    assert selection["bytes_omitted"] == byte_size(middle)
    assert selection["bytes_read"] == byte_size(raw)
    assert selection["incomplete_trailing_bytes"] == 0
    assert File.read!(Log.path(ctx.sid, workspace: ctx.ws)) == raw
  end

  test "event-capped partial selection preserves unfinished append metadata", ctx do
    lines = for seq <- 0..9, do: record(ctx.sid, seq) <> "\n"
    fragment = ~s({"unfinished":)
    raw = IO.iodata_to_binary(lines) <> fragment
    write_log(ctx, raw)
    assert {:ok, %{history: history, selection: selection}} = bounded(ctx, max_events: 2)
    assert Enum.map(history, & &1.seq) == [0, 9]
    assert selection["partial"]
    assert selection["incomplete_trailing_bytes"] == byte_size(fragment)

    assert selection["bytes_omitted"] ==
             byte_size(raw) - byte_size(hd(lines)) - byte_size(List.last(lines))

    assert selection["events_omitted"] == "unknown"
    assert File.read!(Log.path(ctx.sid, workspace: ctx.ws)) == raw
  end

  test "only selected event-capped records are decoded and retained corruption still fails",
       ctx do
    middle = Enum.map_join(1..10, "\n", &record(ctx.sid, &1)) <> "\n"

    for bad <- [
          "{bad}",
          "[]",
          record(ctx.sid, 99, [], "user_message"),
          record(ctx.sid, 99, %{}, "text_delta")
        ] do
      for raw <- [
            bad <> "\n" <> middle <> record(ctx.sid, 99),
            record(ctx.sid, 0) <> "\n" <> middle <> bad <> "\n"
          ] do
        write_log(ctx, raw)
        assert {:error, %{error: %{kind: :corrupt_log_line}}} = bounded(ctx, max_events: 2)
      end
    end

    write_log(ctx, record(ctx.sid, 0) <> "\n{bad}\n" <> record(ctx.sid, 999))

    assert {:ok, %{history: [%{seq: 0}, %{seq: 999}], selection: selection}} =
             bounded(ctx, max_events: 2)

    assert selection["events_omitted"] == "unknown"
    assert {:error, %{error: %{kind: :corrupt_log_line}}} = bounded(ctx)
  end

  test "event-capped partiality does not sort away invalid selected identity or sequence", ctx do
    for last <- [record(ctx.sid, 0), record(ctx.sid, -1), record("other", 99)] do
      write_log(ctx, record(ctx.sid, 0) <> "\n" <> record(ctx.sid, 1) <> "\n" <> last)
      assert {:error, %{error: %{kind: :invalid_log_selection}}} = bounded(ctx, max_events: 2)
    end

    write_log(ctx, record(ctx.sid, 2) <> "\n" <> record(ctx.sid, 1) <> "\n" <> record(ctx.sid, 0))
    assert {:ok, %{history: [%{seq: 0}, %{seq: 1}, %{seq: 2}]}} = bounded(ctx, max_events: 3)
    assert {:error, %{error: %{kind: :invalid_log_selection}}} = bounded(ctx, max_events: 2)
  end

  test "event cap narrows selection without increasing actual physical reads", ctx do
    raw = Enum.map_join(0..999, "\n", &record(ctx.sid, &1)) <> "\n"
    write_log(ctx, raw)

    for budget <- [8193, byte_size(raw)] do
      {result, calls} = trace_reads(fn -> bounded(ctx, max_log_bytes: budget, max_events: 5) end)
      assert {:ok, %{history: history, selection: selection}} = result
      assert length(history) == 5
      assert selection["partial"]
      assert selection["bytes_read"] == budget
      reads = for {:file, :pread, [_file, offset, bytes]} <- calls, do: {offset, bytes}
      assert length(reads) == length(calls)
      assert length(reads) == if(budget == byte_size(raw), do: 1, else: 2)
      assert Enum.sum(Enum.map(reads, &elem(&1, 1))) == budget
      assert [{0, first_bytes} | rest] = reads
      if rest != [], do: assert(elem(hd(rest), 0) >= first_bytes)
    end

    assert File.read!(Log.path(ctx.sid, workspace: ctx.ws)) == raw
  end

  test "a selected record must belong to the requested Session, including singleton Logs", ctx do
    write_log(ctx, record("another-session", 0))
    assert {:error, %{error: %{kind: :invalid_log_selection}}} = bounded(ctx)
  end

  test "symlinked state ancestors are refused before reading their valid target Log", ctx do
    outside = ctx.ws <> "-outside"
    File.mkdir_p!(outside)
    on_exit(fn -> File.rm_rf!(outside) end)
    File.mkdir_p!(Paths.project_root(ctx.ws))
    raw = record(ctx.sid, 0)
    File.write!(Path.join(outside, ctx.sid <> ".ndjson"), raw)
    File.ln_s!(outside, Paths.sessions_dir(ctx.ws))
    {result, reads} = trace_reads(fn -> bounded(ctx) end)
    assert {:error, %{error: %{kind: :unsafe_state_path}}} = result
    assert reads == []
    assert File.read!(Path.join(outside, ctx.sid <> ".ndjson")) == raw
  end

  test "canonical raw types and complete JSON at EOF match both ordinary folds byte-for-byte",
       ctx do
    raw =
      Event.canonical_types()
      |> Enum.with_index()
      |> Enum.map_join("\n", fn {type, seq} -> record(ctx.sid, seq, %{}, Atom.to_string(type)) end)

    write_log(ctx, raw)
    assert {:ok, ordinary} = Log.fold(ctx.sid, workspace: ctx.ws)
    assert {:ok, ^ordinary} = Log.fold_append_order(ctx.sid, workspace: ctx.ws)
    assert {:ok, %{history: ^ordinary, selection: selection}} = bounded(ctx)
    assert selection["incomplete_trailing_bytes"] == 0
    assert selection["bytes_omitted"] == 0
    assert selection["bytes_read"] == byte_size(raw)
    assert File.read!(Log.path(ctx.sid, workspace: ctx.ws)) == raw
  end

  test "prefix and tail keep complete records, leave the middle unknown and never change bytes",
       ctx do
    lines =
      for seq <- 0..99, do: record(ctx.sid, seq, %{"text" => String.duplicate("é", 20)}) <> "\n"

    raw = IO.iodata_to_binary(lines)
    write_log(ctx, raw)
    budget = 1024
    assert {:ok, %{history: history, selection: selection}} = bounded(ctx, max_log_bytes: budget)
    assert hd(history).seq == 0
    assert List.last(history).seq == 99
    assert selection["partial"]
    assert selection["events_omitted"] == "unknown"
    assert selection["bytes_read"] == budget

    assert selection["bytes_omitted"] ==
             byte_size(raw) -
               Enum.reduce(history, 0, fn event, sum ->
                 sum + byte_size(Enum.at(lines, event.seq))
               end)

    assert File.read!(Log.path(ctx.sid, workspace: ctx.ws)) == raw
  end

  test "missing Logs are explicit errors, while ordinary fold stays empty", ctx do
    assert {:error, %{error: %{kind: :log_not_found}}} = bounded(ctx)
    assert {:ok, []} = Log.fold(ctx.sid, workspace: ctx.ws)
    assert {:ok, []} = Log.fold_append_order(ctx.sid, workspace: ctx.ws)
  end

  test "empty existing Logs have zero read bytes and a complete empty selection", ctx do
    write_log(ctx, "")
    assert {:ok, %{history: [], selection: selection}} = bounded(ctx)
    assert selection["bytes_read"] == 0
    assert selection["bytes_omitted"] == 0
    assert selection["events_omitted"] == 0
    assert selection["read_budget_bytes"] == 8 * 1024 * 1024
  end

  test "all public fold modes refuse invalid Session ids", ctx do
    for sid <- ["../escape", "nested/session", "", "/tmp/log", "bad\\session", nil] do
      for reader <- [&Log.fold/2, &Log.fold_append_order/2, &Log.fold_bounded/2] do
        assert {:error, %{error: %{kind: :invalid_args}}} = reader.(sid, workspace: ctx.ws)
      end
    end
  end

  test "all public fold modes reject final and ancestor symlinks, including dangling links",
       ctx do
    for component <- [:pixir, :sessions, :log], dangling <- [false, true] do
      ws = Path.join(ctx.ws, "#{component}-#{dangling}")
      outside = ws <> "-outside"
      File.mkdir_p!(ws)
      File.mkdir_p!(outside)
      raw = record(ctx.sid, 0)
      target_log = Path.join(outside, ctx.sid <> ".ndjson")
      File.write!(target_log, raw)

      {link, target} =
        case component do
          :pixir ->
            {Paths.project_root(ws), outside}

          :sessions ->
            File.mkdir_p!(Paths.project_root(ws))
            {Paths.sessions_dir(ws), outside}

          :log ->
            Paths.ensure_sessions_dir(ws)
            {Log.path(ctx.sid, workspace: ws), target_log}
        end

      File.ln_s!(if(dangling, do: target <> "-missing", else: target), link)

      for reader <- [&Log.fold/2, &Log.fold_append_order/2, &Log.fold_bounded/2] do
        assert {:error, %{error: %{kind: :unsafe_state_path}}} = reader.(ctx.sid, workspace: ws)
      end

      assert File.read!(target_log) == raw
    end
  end

  test "full bounded selections sort by seq without changing append-order replay", ctx do
    write_log(ctx, record(ctx.sid, 2) <> "\n" <> record(ctx.sid, 0))
    assert {:ok, ordered} = Log.fold(ctx.sid, workspace: ctx.ws)
    assert {:ok, %{history: ^ordered}} = bounded(ctx)
    assert Enum.map(ordered, & &1.seq) == [0, 2]
    assert {:ok, appended} = Log.fold_append_order(ctx.sid, workspace: ctx.ws)
    assert Enum.map(appended, & &1.seq) == [2, 0]
  end

  test "malformed retained JSON and canonical envelope errors remain structured failures", ctx do
    for line <- [
          "{not json}",
          "[]",
          "null",
          record(ctx.sid, 0, [], "user_message"),
          record(ctx.sid, 0, %{}, "text_delta"),
          record(ctx.sid, 0, %{}, "unknown_type")
        ] do
      raw = line <> "\n"
      write_log(ctx, raw)
      assert {:error, %{error: %{kind: :corrupt_log_line}}} = bounded(ctx)
      assert File.read!(Log.path(ctx.sid, workspace: ctx.ws)) == raw
    end
  end

  test "complete invalid envelopes at EOF are not mislabeled unfinished appends", ctx do
    for line <- [
          "[]",
          "null",
          record(ctx.sid, 0, [], "user_message"),
          record(ctx.sid, 0, %{}, "unknown_type")
        ] do
      write_log(ctx, line)
      assert {:error, %{error: %{kind: :corrupt_log_line}}} = bounded(ctx)
    end
  end

  test "unfinished EOF append bytes are reported exactly and left untouched", ctx do
    first = record(ctx.sid, 0) <> "\n"
    trailing = "{\"session_id\":\"unfinished"
    raw = first <> trailing
    write_log(ctx, raw)
    assert {:ok, %{history: [%{seq: 0}], selection: selection}} = bounded(ctx)
    assert selection["incomplete_trailing_bytes"] == byte_size(trailing)
    assert selection["bytes_omitted"] == byte_size(trailing)
    assert selection["events_omitted"] == "unknown"
    refute selection["partial"]
    assert File.read!(Log.path(ctx.sid, workspace: ctx.ws)) == raw
  end

  test "selected seqs must be nonnegative integers and uniquely identify ordered evidence", ctx do
    for raw <- [
          record(ctx.sid, -1),
          record(ctx.sid, nil),
          record(ctx.sid, "1"),
          record(ctx.sid, 0) <> "\n" <> record(ctx.sid, 0),
          record(ctx.sid, 0) <> "\n" <> record("other", 1)
        ] do
      write_log(ctx, raw)
      assert {:error, %{error: %{kind: :invalid_log_selection}}} = bounded(ctx)
    end
  end

  test "invalid byte budgets return structured limits without fallback", ctx do
    write_log(ctx, record(ctx.sid, 0))

    for budget <- [nil, 0, 1, -1, 1.5, "1024"] do
      assert {:error, %{error: %{kind: :log_read_limit}}} = bounded(ctx, max_log_bytes: budget)
    end
  end

  test "one oversized record fails rather than scanning or reading the entire Log", ctx do
    raw = record(ctx.sid, 0, %{"text" => String.duplicate("x", 10_000)}) <> "\n"
    write_log(ctx, raw)
    assert {:error, %{error: %{kind: :log_read_limit}}} = bounded(ctx, max_log_bytes: 512)
    assert File.read!(Log.path(ctx.sid, workspace: ctx.ws)) == raw
  end

  test "partial EOF record needs no LF and reports exact selected bytes", ctx do
    lines = for seq <- 0..99, do: record(ctx.sid, seq)
    raw = Enum.join(lines, "\n")
    write_log(ctx, raw)
    assert {:ok, %{history: history, selection: selection}} = bounded(ctx, max_log_bytes: 1024)
    assert List.last(history).seq == 99
    assert selection["incomplete_trailing_bytes"] == 0

    retained_bytes =
      Enum.reduce(history, 0, fn event, sum ->
        sum + byte_size(Enum.at(lines, event.seq)) + if(event.seq == 99, do: 0, else: 1)
      end)

    assert selection["bytes_omitted"] == byte_size(raw) - retained_bytes
  end

  test "malformed omitted middle is not read or silently called valid", ctx do
    raw =
      record(ctx.sid, 0) <>
        "\n" <> String.duplicate("not-json", 1000) <> "\n" <> record(ctx.sid, 99) <> "\n"

    write_log(ctx, raw)
    assert {:error, %{error: %{kind: :corrupt_log_line}}} = Log.fold(ctx.sid, workspace: ctx.ws)

    assert {:ok, %{history: [%{seq: 0}, %{seq: 99}], selection: selection}} =
             bounded(ctx, max_log_bytes: 1024)

    assert selection["events_omitted"] == "unknown"
    assert selection["partial"]
  end

  test "selected corruption in either window is never hidden by the missing middle", ctx do
    middle = String.duplicate("unread", 1000) <> "\n"

    for raw <- [
          "{bad}\n" <> middle <> record(ctx.sid, 99) <> "\n",
          record(ctx.sid, 0) <> "\n" <> middle <> "{bad}\n"
        ] do
      write_log(ctx, raw)
      assert {:error, %{error: %{kind: :corrupt_log_line}}} = bounded(ctx, max_log_bytes: 1024)
    end
  end

  test "partial selections do not sort away duplicate or reversed cross-window seqs", ctx do
    middle = String.duplicate("unread", 1000) <> "\n"

    for last <- [0, 1] do
      raw = record(ctx.sid, 1) <> "\n" <> middle <> record(ctx.sid, last) <> "\n"
      write_log(ctx, raw)

      assert {:error, %{error: %{kind: :invalid_log_selection}}} =
               bounded(ctx, max_log_bytes: 1024)
    end
  end

  test "actual positional I/O uses exactly the budget and never a full-read fallback", ctx do
    raw = Enum.map_join(0..99, "\n", &record(ctx.sid, &1)) <> "\n"
    write_log(ctx, raw)
    budget = 1025
    {result, calls} = trace_reads(fn -> bounded(ctx, max_log_bytes: budget) end)
    assert {:ok, %{selection: %{"bytes_read" => ^budget}}} = result
    reads = for {:file, :pread, [_file, offset, bytes]} <- calls, do: {offset, bytes}

    assert reads == [
             {0, div(budget, 2)},
             {byte_size(raw) - (budget - div(budget, 2)), budget - div(budget, 2)}
           ]

    assert length(calls) == 2
    assert Enum.sum(Enum.map(reads, &elem(&1, 1))) == budget

    {full, full_calls} = trace_reads(fn -> bounded(ctx, max_log_bytes: byte_size(raw)) end)
    assert {:ok, %{selection: %{"partial" => false}}} = full
    assert [{:file, :pread, [_file, 0, bytes]}] = full_calls
    assert bytes == byte_size(raw)
  end

  test "large single records still use only the two budgeted reads before failing", ctx do
    raw = record(ctx.sid, 0, %{"text" => String.duplicate("x", 10_000)})
    write_log(ctx, raw)
    {result, calls} = trace_reads(fn -> bounded(ctx, max_log_bytes: 512) end)
    assert {:error, %{error: %{kind: :log_read_limit}}} = result
    assert [{:file, :pread, [_file, 0, 256]}, {:file, :pread, [_other_file, offset, 256]}] = calls
    assert offset == byte_size(raw) - 256
  end

  test "window boundaries inside UTF-8 codepoints discard fragments before decoding", ctx do
    raw =
      record(ctx.sid, 0) <>
        "\n" <>
        record(ctx.sid, 1, %{"text" => String.duplicate("é", 5000)}) <> "\n" <> record(ctx.sid, 2)

    write_log(ctx, raw)
    budgets = 512..515
    assert Enum.any?(budgets, fn budget -> :binary.at(raw, div(budget, 2) - 1) == 0xC3 end)

    assert Enum.any?(budgets, fn budget ->
             :binary.at(raw, byte_size(raw) - (budget - div(budget, 2))) == 0xA9
           end)

    for budget <- budgets do
      assert {:ok, %{history: [%{seq: 0}, %{seq: 2}], selection: selection}} =
               bounded(ctx, max_log_bytes: budget)

      assert selection["bytes_read"] == budget
      assert selection["incomplete_trailing_bytes"] == 0
    end

    assert File.read!(Log.path(ctx.sid, workspace: ctx.ws)) == raw
  end

  # These window-boundary cases moved from Monitor's reader ownership tests.
  test "complete JSON at a prefix byte cut is not mistaken for an EOF record", ctx do
    first = record(ctx.sid, 0) <> "\n"
    cut = record(ctx.sid, 1)
    middle = record(ctx.sid, 2, %{"text" => String.duplicate("m", 8000)}) <> "\n"
    raw = first <> cut <> "\n" <> middle <> record(ctx.sid, 3)
    budget = 2 * byte_size(first <> cut)
    write_log(ctx, raw)
    assert {:ok, %{history: history, selection: selection}} = bounded(ctx, max_log_bytes: budget)
    assert Enum.map(history, & &1.seq) == [0, 3]
    assert selection["bytes_read"] == budget
    assert selection["incomplete_trailing_bytes"] == 0
    assert File.read!(Log.path(ctx.sid, workspace: ctx.ws)) == raw
  end

  test "an EOF tail without a known leading record boundary stays unprojectable", ctx do
    raw = record(ctx.sid, 0) <> "\n" <> String.duplicate("m", 8000) <> record(ctx.sid, 2)
    write_log(ctx, raw)
    assert {:error, %{error: %{kind: :log_read_limit}}} = bounded(ctx, max_log_bytes: 1200)
  end

  test "partial unfinished append becomes selectable only after the writer completes it", ctx do
    body = Enum.map_join(0..100, "\n", &record(ctx.sid, &1)) <> "\n"
    tail = record(ctx.sid, 101) <> "\n"
    fragment_size = div(byte_size(tail), 2)
    fragment = binary_part(tail, 0, fragment_size)
    remaining = binary_part(tail, fragment_size, byte_size(tail) - fragment_size)
    write_log(ctx, body <> fragment)
    assert {:ok, %{history: before, selection: selection}} = bounded(ctx, max_log_bytes: 2048)
    assert List.last(before).seq == 100
    assert selection["incomplete_trailing_bytes"] == fragment_size
    assert File.read!(Log.path(ctx.sid, workspace: ctx.ws)) == body <> fragment
    File.write!(Log.path(ctx.sid, workspace: ctx.ws), remaining, [:append])

    assert {:ok, %{history: after_append, selection: after_selection}} =
             bounded(ctx, max_log_bytes: 2048)

    assert List.last(after_append).seq == 101
    assert after_selection["incomplete_trailing_bytes"] == 0
    assert File.read!(Log.path(ctx.sid, workspace: ctx.ws)) == body <> tail
  end

  test "sparse seq endpoints never fabricate an omitted event count", ctx do
    write_log(ctx, Enum.map_join(0..100, "\n", &record(ctx.sid, &1 * 31)) <> "\n")
    assert {:ok, %{selection: selection}} = bounded(ctx, max_log_bytes: 1024)
    assert selection["events_omitted"] == "unknown"
  end

  test "nonregular Log paths fail confinement before reads", ctx do
    Paths.ensure_sessions_dir(ctx.ws)
    File.mkdir!(Log.path(ctx.sid, workspace: ctx.ws))
    assert {:error, %{error: %{kind: :unsafe_state_path}}} = bounded(ctx)
  end

  # Trace the real I/O calls in a single controlled worker, not self-reported
  # metadata or an injected fake reader. No process-wide test concurrency here.
  defp trace_reads(fun) do
    patterns = [{:file, :pread, 3}, {:file, :read, 2}, {:file, :read_file, 1}, {File, :read, 1}]
    owner = self()

    worker =
      spawn(fn ->
        receive do
          :go ->
            send(owner, {:read_result, self(), fun.()})
            receive do: (:stop -> :ok)
        end
      end)

    Enum.each(patterns, &:erlang.trace_pattern(&1, true, [:local]))
    :erlang.trace(worker, true, [:call])

    try do
      send(worker, :go)

      result =
        receive do
          {:read_result, ^worker, result} -> result
        after
          5000 -> flunk("bounded reader did not finish")
        end

      ref = :erlang.trace_delivered(worker)

      receive do
        {:trace_delivered, ^worker, ^ref} -> :ok
      after
        5000 -> flunk("I/O trace did not finish")
      end

      {result, read_calls(worker, [])}
    after
      :erlang.trace(worker, false, [:call])
      Enum.each(patterns, &:erlang.trace_pattern(&1, false, [:local]))
      send(worker, :stop)
    end
  end

  defp read_calls(worker, calls) do
    receive do
      {:trace, ^worker, :call, call} -> read_calls(worker, [call | calls])
    after
      0 -> Enum.reverse(calls)
    end
  end

  defp record(sid, seq, data \\ %{}, type \\ "user_message") do
    Jason.encode!(%{
      "id" => "id-#{seq}",
      "session_id" => sid,
      "seq" => seq,
      "ts" => "2026-09-06T00:00:00Z",
      "type" => type,
      "data" => data
    })
  end

  defp write_log(ctx, raw) do
    Paths.ensure_sessions_dir(ctx.ws)
    File.write!(Log.path(ctx.sid, workspace: ctx.ws), raw)
  end

  defp bounded(ctx, opts \\ []) do
    Log.fold_bounded(ctx.sid, Keyword.put(opts, :workspace, ctx.ws))
  end
end
