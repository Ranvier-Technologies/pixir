defmodule Pixir.SessionLeaseTest do
  use ExUnit.Case, async: true

  alias Pixir.{Event, Log, Paths, SessionLease}

  setup do
    ws =
      Path.join(
        System.tmp_dir!(),
        "pixir-session-lease-" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
      )

    File.mkdir_p!(ws)
    on_exit(fn -> File.rm_rf!(ws) end)
    %{ws: ws, sid: "sess-lease"}
  end

  test "one active writer lease blocks competing acquire and raw appends", %{ws: ws, sid: sid} do
    assert {:ok, lease} = SessionLease.acquire(sid, workspace: ws)

    assert {:error, %{error: %{kind: :session_writer_active}}} =
             SessionLease.acquire(sid, workspace: ws)

    event = Event.user_message(sid, "raw append") |> Event.with_seq(0)

    assert {:error, %{error: %{kind: :session_writer_active}}} =
             Log.append(event, workspace: ws)

    assert {:ok, ^event} = Log.append(event, workspace: ws, writer_lease: lease)

    SessionLease.release(lease)

    next_event = Event.assistant_message(sid, "cold append") |> Event.with_seq(1)
    assert {:ok, ^next_event} = Log.append(next_event, workspace: ws)
  end

  test "atomic acquire admits exactly one live holder under contention", %{ws: ws, sid: sid} do
    results =
      1..8
      |> Task.async_stream(fn _ -> SessionLease.acquire(sid, workspace: ws) end,
        max_concurrency: 8,
        timeout: 2_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    {ok, errors} = Enum.split_with(results, &match?({:ok, _lease}, &1))

    assert [_one] = ok

    assert Enum.all?(errors, fn
             {:error, %{error: %{kind: kind}}}
             when kind in [:session_writer_active, :session_writer_ambiguous] ->
               true

             _other ->
               false
           end)

    {:ok, lease} = hd(ok)
    SessionLease.release(lease)
  end

  test "force release refuses active leases", %{ws: ws, sid: sid} do
    assert {:ok, lease} = SessionLease.acquire(sid, workspace: ws)

    assert {:error, %{error: %{kind: :session_writer_active}}} =
             SessionLease.force_release(sid, workspace: ws, reason: "test_active_refusal")

    assert File.exists?(lease["lease_path"])
    SessionLease.release(lease)
  end

  test "force release records stale lease diagnostics before removing the lease", %{
    ws: ws,
    sid: sid
  } do
    assert {:ok, lease} = SessionLease.acquire(sid, workspace: ws)

    stale =
      lease
      |> Map.put("heartbeat_at_ms", System.system_time(:millisecond) - 60_000)
      |> Map.put("heartbeat_at", "2026-01-01T00:00:00Z")
      |> Map.put("stale_after_ms", 1)

    File.write!(lease["lease_path"], Jason.encode!(stale))

    assert {:ok, %{"state" => "stale"}} = SessionLease.status(sid, workspace: ws)

    assert {:ok,
            %{
              "released" => true,
              "release_record_path" => release_record_path,
              "state_before" => %{"state" => "stale"}
            }} =
             SessionLease.force_release(sid,
               workspace: ws,
               reason: "test_stale_release"
             )

    refute File.exists?(lease["lease_path"])
    assert File.exists?(release_record_path)

    assert %{"kind" => "session_writer_lease_forced_release", "reason" => "test_stale_release"} =
             release_record_path |> File.read!() |> Jason.decode!()
  end

  test "force release can remove ambiguous lease evidence with a diagnostic record", %{
    ws: ws,
    sid: sid
  } do
    Paths.ensure_session_leases_dir(ws)
    path = Paths.session_lease(sid, ws)
    File.write!(path, "{")

    assert {:ok, %{"state" => "ambiguous"}} = SessionLease.status(sid, workspace: ws)

    assert {:ok,
            %{
              "released" => true,
              "release_record_path" => release_record_path,
              "state_before" => %{"state" => "ambiguous"}
            }} =
             SessionLease.force_release(sid,
               workspace: ws,
               reason: "test_ambiguous_release"
             )

    refute File.exists?(path)
    assert File.exists?(release_record_path)
  end

  test "lease operations reject symlinked state ancestors and final files", %{ws: ws, sid: sid} do
    outside = ws <> "-outside"
    File.mkdir_p!(outside)
    on_exit(fn -> File.rm_rf!(outside) end)
    sentinel = Path.join(outside, "sentinel")
    File.write!(sentinel, "unchanged")

    File.mkdir_p!(Paths.project_root(ws))
    File.ln_s!(outside, Paths.session_leases_dir(ws))

    assert {:error, %{error: %{kind: :unsafe_state_path}}} =
             SessionLease.acquire(sid, workspace: ws)

    assert {:error, %{error: %{kind: :unsafe_state_path}}} =
             SessionLease.status(sid, workspace: ws)

    File.rm!(Paths.session_leases_dir(ws))
    Paths.ensure_session_leases_dir(ws)
    lease_path = Paths.session_lease(sid, ws)
    File.ln_s!(sentinel, lease_path)

    assert {:error, %{error: %{kind: :unsafe_state_path}}} =
             SessionLease.acquire(sid, workspace: ws)

    assert {:error, %{error: %{kind: :unsafe_state_path}}} =
             SessionLease.release(%{
               "session_id" => sid,
               "workspace" => ws,
               "holder_id" => "holder"
             })

    assert File.read!(sentinel) == "unchanged"
  end

  test "unsafe releases directory preserves the original stale lease", %{ws: ws, sid: sid} do
    outside = ws <> "-release-outside"
    File.mkdir_p!(outside)
    on_exit(fn -> File.rm_rf!(outside) end)
    assert {:ok, lease} = SessionLease.acquire(sid, workspace: ws)

    stale =
      lease
      |> Map.put("heartbeat_at_ms", System.system_time(:millisecond) - 60_000)
      |> Map.put("stale_after_ms", 1)

    File.write!(lease["lease_path"], Jason.encode!(stale))
    File.ln_s!(outside, Paths.session_lease_releases_dir(ws))

    assert {:error, %{error: %{kind: :unsafe_state_path}}} =
             SessionLease.force_release(sid, workspace: ws, reason: "must_preserve_lease")

    assert File.exists?(lease["lease_path"])
    assert File.ls!(outside) == []
  end

  test "forced-release filename is bounded while JSON preserves a 235-byte id", %{ws: ws} do
    sid = "a" <> String.duplicate("b", 234)
    assert {:ok, lease} = SessionLease.acquire(sid, workspace: ws)

    stale =
      lease
      |> Map.put("heartbeat_at_ms", System.system_time(:millisecond) - 60_000)
      |> Map.put("stale_after_ms", 1)

    File.write!(lease["lease_path"], Jason.encode!(stale))

    assert {:ok, %{"release_record_path" => release_path}} =
             SessionLease.force_release(sid, workspace: ws, reason: "bounded_name")

    assert byte_size(Path.basename(release_path)) < 255
    assert %{"session_id" => ^sid} = release_path |> File.read!() |> Jason.decode!()
  end

  test "non-string workspace in untrusted lease JSON is classified ambiguous", %{ws: ws, sid: sid} do
    Paths.ensure_session_leases_dir(ws)

    File.write!(
      Paths.session_lease(sid, ws),
      Jason.encode!(%{
        "version" => 1,
        "purpose" => "session_writer",
        "session_id" => sid,
        "workspace" => 123,
        "holder_id" => "holder",
        "heartbeat_at_ms" => System.system_time(:millisecond)
      })
    )

    assert {:ok, %{"state" => "ambiguous"}} = SessionLease.status(sid, workspace: ws)

    assert {:error, %{error: %{kind: :session_writer_ambiguous}}} =
             SessionLease.acquire(sid, workspace: ws)
  end
end
