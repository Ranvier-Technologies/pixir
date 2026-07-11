defmodule Pixir.LogTest do
  use ExUnit.Case, async: true

  alias Pixir.{Event, Log}

  setup do
    ws =
      Path.join(
        System.tmp_dir!(),
        "pixir-log-" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
      )

    File.mkdir_p!(ws)
    on_exit(fn -> File.rm_rf!(ws) end)
    %{ws: ws, sid: "sess-1"}
  end

  test "fold of a missing log is empty history", %{ws: ws, sid: sid} do
    refute Log.exists?(sid, workspace: ws)
    assert {:ok, []} = Log.fold(sid, workspace: ws)
  end

  test "append writes NDJSON and round-trips identically through fold", %{ws: ws, sid: sid} do
    u = Event.user_message(sid, "hello") |> Event.with_seq(0)
    a = Event.assistant_message(sid, "hi there") |> Event.with_seq(1)

    assert {:ok, ^u} = Log.append(u, workspace: ws)
    assert {:ok, ^a} = Log.append(a, workspace: ws)

    # one JSON object per line
    raw = File.read!(Log.path(sid, workspace: ws))
    assert raw |> String.split("\n", trim: true) |> length() == 2

    assert {:ok, [^u, ^a]} = Log.fold(sid, workspace: ws)
  end

  test "tool_call / tool_result data survives round-trip with string keys", %{ws: ws, sid: sid} do
    call = Event.tool_call(sid, "c1", "read", %{"path" => "a.txt"}) |> Event.with_seq(0)

    res =
      Event.tool_result(sid, "c1", %{"ok" => true, "output" => "contents"}) |> Event.with_seq(1)

    {:ok, _} = Log.append(call, workspace: ws)
    {:ok, _} = Log.append(res, workspace: ws)

    assert {:ok, [folded_call, folded_res]} = Log.fold(sid, workspace: ws)
    assert folded_call == call
    assert folded_res == res
    assert folded_call.data["args"] == %{"path" => "a.txt"}
  end

  test "fold orders by seq even if appended out of order", %{ws: ws, sid: sid} do
    second = Event.user_message(sid, "second") |> Event.with_seq(2)
    first = Event.user_message(sid, "first") |> Event.with_seq(1)

    {:ok, _} = Log.append(second, workspace: ws)
    {:ok, _} = Log.append(first, workspace: ws)

    assert {:ok, [a, b]} = Log.fold(sid, workspace: ws)
    assert a.data["text"] == "first"
    assert b.data["text"] == "second"

    assert {:ok, [appended_first, appended_second]} =
             Log.fold_append_order(sid, workspace: ws)

    assert appended_first.data["text"] == "second"
    assert appended_second.data["text"] == "first"
  end

  test "appending an ephemeral event is refused with a structured error", %{ws: ws, sid: sid} do
    delta = Event.text_delta(sid, "partial")

    assert {:error, %{ok: false, error: %{kind: :ephemeral_not_loggable}}} =
             Log.append(delta, workspace: ws)

    refute Log.exists?(sid, workspace: ws)
  end

  test "create_session writes atomically and refuses when the log already exists", %{
    ws: ws,
    sid: sid
  } do
    u = Event.user_message(sid, "hello") |> Event.with_seq(0)
    a = Event.assistant_message(sid, "hi there") |> Event.with_seq(1)

    assert {:ok, [^u, ^a]} = Log.create_session(sid, [u, a], workspace: ws)
    assert {:ok, [^u, ^a]} = Log.fold(sid, workspace: ws)

    assert {:error, %{ok: false, error: %{kind: :already_exists}}} =
             Log.create_session(sid, [u], workspace: ws)
  end

  test "append reports encode failures instead of crashing", %{ws: ws, sid: sid} do
    event =
      Event.tool_result(sid, "call_bad", %{
        "ok" => true,
        "output" => <<0xF0, 0x9F>>
      })

    assert {:error, %{ok: false, error: %{kind: :log_encode_failed, details: details}}} =
             Log.append(event, workspace: ws)

    assert details.type == :tool_result
    refute Log.exists?(sid, workspace: ws)
  end

  test "fold reports a corrupt line as a structured error", %{ws: ws, sid: sid} do
    Pixir.Paths.ensure_sessions_dir(ws)
    File.write!(Log.path(sid, workspace: ws), "{not json}\n")

    assert {:error, %{ok: false, error: %{kind: :corrupt_log_line}}} =
             Log.fold(sid, workspace: ws)
  end

  # Regression: `decode_type` must validate against the declared canonical set, not via
  # `String.to_existing_atom`. On a cold `resume` process the writer side never runs, so
  # those atoms may not yet exist in the VM — which crashed every real resume. We decode
  # raw NDJSON (built by hand, NOT via the Event.* constructors) to mimic that cold path.
  test "fold decodes every canonical type from raw NDJSON without prior atom load",
       %{ws: ws, sid: sid} do
    Pixir.Paths.ensure_sessions_dir(ws)

    raw =
      Event.canonical_types()
      |> Enum.with_index()
      |> Enum.map_join("\n", fn {type, i} ->
        Jason.encode!(%{
          "id" => "id-#{i}",
          "session_id" => sid,
          "seq" => i,
          "ts" => "2026-05-29T00:00:00Z",
          "type" => Atom.to_string(type),
          "data" => %{}
        })
      end)

    File.write!(Log.path(sid, workspace: ws), raw <> "\n")

    assert {:ok, events} = Log.fold(sid, workspace: ws)
    assert Enum.map(events, & &1.type) == Event.canonical_types()
  end

  test "fold reports a genuinely unknown event type as a structured error", %{ws: ws, sid: sid} do
    Pixir.Paths.ensure_sessions_dir(ws)

    line =
      Jason.encode!(%{
        "id" => "x",
        "session_id" => sid,
        "seq" => 0,
        "ts" => "2026-05-29T00:00:00Z",
        "type" => "definitely_not_a_real_event_type",
        "data" => %{}
      })

    File.write!(Log.path(sid, workspace: ws), line <> "\n")

    assert {:error, %{ok: false, error: %{kind: :corrupt_log_line, details: %{reason: reason}}}} =
             Log.fold(sid, workspace: ws)

    assert reason == {:unknown_event_type, "definitely_not_a_real_event_type"}
  end
end
