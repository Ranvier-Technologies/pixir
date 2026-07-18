defmodule PixirMonitor.WorkspaceSetDegradationTransientProvider do
  @moduledoc false

  @behaviour PixirMonitor.Projection.Source.InputProvider

  @impl true
  def list_runs(opts) do
    workspace = Keyword.fetch!(opts, :workspace)

    if Application.get_env(:pixir_monitor, :degradation_fail_workspace) == workspace do
      Application.delete_env(:pixir_monitor, :degradation_fail_workspace)

      {:error,
       %{
         kind: "temporary_projection_failure",
         message: "Injected projection read failure",
         details: %{}
       }}
    else
      PixirMonitor.Projection.Source.Filesystem.list_runs(opts)
    end
  end

  @impl true
  def fetch_input(id, opts), do: PixirMonitor.Projection.Source.Filesystem.fetch_input(id, opts)
end

defmodule PixirMonitor.WorkspaceSetDegradationTest do
  use ExUnit.Case, async: false

  import Plug.Conn, only: [get_resp_header: 2, put_req_header: 3]
  import Plug.Test, only: [conn: 3]

  @host "127.0.0.1:41092"
  @origin "http://127.0.0.1:41092"
  @running_as_root System.cmd("id", ["-u"]) == {"0\n", 0}

  setup do
    previous = %{
      workspace_set: Application.get_env(:pixir_monitor, :workspace_set),
      run_source: Application.get_env(:pixir_monitor, :run_source),
      projection_source: Application.get_env(:pixir_monitor, :projection_source),
      projection_input_provider: Application.get_env(:pixir_monitor, :projection_input_provider),
      degradation_fail_workspace: Application.get_env(:pixir_monitor, :degradation_fail_workspace),
      active_port: Application.get_env(:pixir_monitor, :active_port)
    }

    root = Path.join(System.tmp_dir!(), "pixir-workspace-degradation-#{System.unique_integer([:positive])}")
    left = Path.join(root, "left-root")
    right = Path.join(root, "right-root")
    File.mkdir_p!(left)
    File.mkdir_p!(right)

    Application.put_env(:pixir_monitor, :workspace_set, [
      %{key: "left", path: left},
      %{key: "right", path: right}
    ])

    Application.put_env(:pixir_monitor, :run_source, PixirMonitor.Projection.Source)
    Application.put_env(:pixir_monitor, :projection_input_provider, PixirMonitor.Projection.Source.Filesystem)

    Application.put_env(:pixir_monitor, :projection_source,
      max_logs: 512,
      max_log_bytes: 8_388_608,
      max_events: 20_000
    )

    Application.put_env(:pixir_monitor, :active_port, 41_092)
    create_real_run(right, "healthy-right")
    {:ok, :refreshed} = PixirMonitor.LogWatcher.refresh()
    {:ok, _sequence} = PixirMonitor.InvalidationHub.subscribe()
    cookie = session_cookie()

    on_exit(fn ->
      PixirMonitor.InvalidationHub.unsubscribe()
      File.chmod(Path.join([left, ".pixir", "sessions"]), 0o700)
      File.rm_rf!(root)
      Enum.each(previous, fn {key, value} -> restore_env(key, value) end)
    end)

    {:ok, left: left, right: right, cookie: cookie}
  end

  test "single-workspace mode keeps sessions-directory availability transitions silent", %{left: left} do
    Application.delete_env(:pixir_monitor, :workspace_set)

    opts =
      Application.get_env(:pixir_monitor, :projection_source, [])
      |> Keyword.put(:workspace, left)

    Application.put_env(:pixir_monitor, :projection_source, opts)
    {:ok, :refreshed} = PixirMonitor.LogWatcher.refresh()
    drain_invalidations()

    File.mkdir_p!(Path.join([left, ".pixir", "sessions"]))
    {:ok, :refreshed} = PixirMonitor.LogWatcher.refresh()

    refute_receive {:projection_changed, _sequence, _workspace, _projection_id}
    refute Pixir.SessionId.valid?("workspace:availability")
  end

  test "removing and restoring a nonempty source preserves its sibling and emits source-keyed invalidations", %{
    left: left,
    cookie: cookie
  } do
    create_real_run(left, "affected-left")
    assert_available_pair(cookie, "affected-left")
    {:ok, :refreshed} = PixirMonitor.LogWatcher.refresh()
    drain_invalidations()

    sessions = Path.join([left, ".pixir", "sessions"])
    backup = File.read!(Path.join(sessions, "affected-left.ndjson"))
    File.rm_rf!(sessions)

    assert %{"source" => %{"sessions_directory" => "absent"}, "snapshot" => snapshot} =
             response_json(request(cookie, "/api/workspaces/left/runs"), 200)

    assert snapshot["runs"] == []
    assert_healthy_route(cookie)
    {:ok, :refreshed} = PixirMonitor.LogWatcher.refresh()
    assert_file_then_availability_invalidations("left", "affected-left")

    File.mkdir_p!(sessions)
    File.write!(Path.join(sessions, "affected-left.ndjson"), backup)

    assert_available_pair(cookie, "affected-left")
    {:ok, :refreshed} = PixirMonitor.LogWatcher.refresh()
    assert_file_then_availability_invalidations("left", "affected-left")
  end

  test "a missing empty source becomes an observed zero and returns to missing with source invalidations", %{
    left: left,
    cookie: cookie
  } do
    sessions = Path.join([left, ".pixir", "sessions"])

    assert %{"source" => %{"sessions_directory" => "absent"}, "snapshot" => snapshot} =
             response_json(request(cookie, "/api/workspaces/left/runs"), 200)

    assert snapshot["inventory"]["total"] == 0
    assert_healthy_route(cookie)
    {:ok, :refreshed} = PixirMonitor.LogWatcher.refresh()
    drain_invalidations()

    File.mkdir_p!(sessions)
    assert_empty_observed(cookie)
    assert_healthy_route(cookie)
    {:ok, :refreshed} = PixirMonitor.LogWatcher.refresh()
    assert_availability_invalidation("left")

    File.rmdir!(sessions)

    assert response_json(request(cookie, "/api/workspaces/left/runs"), 200)["source"] ==
             %{"sessions_directory" => "absent"}

    assert_healthy_route(cookie)
    {:ok, :refreshed} = PixirMonitor.LogWatcher.refresh()
    assert_availability_invalidation("left")
  end

  test "a non-directory sessions path is unreadable and restores deterministically", %{
    left: left,
    cookie: cookie
  } do
    sessions = Path.join([left, ".pixir", "sessions"])
    File.mkdir_p!(sessions)
    assert_empty_observed(cookie)
    assert_healthy_route(cookie)
    {:ok, :refreshed} = PixirMonitor.LogWatcher.refresh()
    drain_invalidations()

    File.rmdir!(sessions)
    File.write!(sessions, "not a directory")
    assert {:error, :enotdir} = File.ls(sessions)
    assert_workspace_unavailable(cookie, "left")
    assert_healthy_route(cookie)
    {:ok, :refreshed} = PixirMonitor.LogWatcher.refresh()
    assert_availability_invalidation("left")

    File.rm!(sessions)
    File.mkdir_p!(sessions)
    assert_empty_observed(cookie)
    assert_healthy_route(cookie)
    {:ok, :refreshed} = PixirMonitor.LogWatcher.refresh()
    assert_availability_invalidation("left")
  end

  @tag skip:
         if(@running_as_root,
           do: "chmod cannot make a sessions directory unreadable when tests run as root",
           else: false
         )
  test "a permission-denied empty source restores with an invalidation despite unchanged empty file identity", %{
    left: left,
    cookie: cookie
  } do
    sessions = Path.join([left, ".pixir", "sessions"])
    File.mkdir_p!(sessions)
    assert_empty_observed(cookie)
    assert_healthy_route(cookie)
    {:ok, :refreshed} = PixirMonitor.LogWatcher.refresh()
    drain_invalidations()

    assert :ok = File.chmod(sessions, 0o000)
    assert {:error, _reason} = File.ls(sessions)
    assert_workspace_unavailable(cookie, "left")
    assert_healthy_route(cookie)
    {:ok, :refreshed} = PixirMonitor.LogWatcher.refresh()
    assert_availability_invalidation("left")

    assert :ok = File.chmod(sessions, 0o700)
    assert_empty_observed(cookie)
    assert_healthy_route(cookie)
    {:ok, :refreshed} = PixirMonitor.LogWatcher.refresh()
    assert_availability_invalidation("left")
  end

  test "a corrupt selected log confesses projection incompleteness until repaired while its sibling serves", %{
    left: left,
    cookie: cookie
  } do
    create_real_run(left, "affected-left")
    sessions = Path.join([left, ".pixir", "sessions"])
    path = Path.join(sessions, "affected-left.ndjson")
    valid = File.read!(path)
    File.write!(path, "{corrupt\n")

    left_body = response_json(request(cookie, "/api/workspaces/left/runs"), 200)
    assert limitation_kinds(left_body) == ["run_projection_incomplete"]
    assert_healthy_route(cookie)
    {:ok, :refreshed} = PixirMonitor.LogWatcher.refresh()
    assert_source_invalidation("left")

    File.write!(path, valid)
    assert_available_pair(cookie, "affected-left")
    {:ok, :refreshed} = PixirMonitor.LogWatcher.refresh()
    assert_source_invalidation("left")
  end

  test "a metadata-stable temporary projection failure recovers on the next fresh scoped fetch", %{
    left: left,
    cookie: cookie
  } do
    create_real_run(left, "affected-left")
    {:ok, :refreshed} = PixirMonitor.LogWatcher.refresh()
    drain_invalidations()
    sessions = Path.join([left, ".pixir", "sessions"])
    before = directory_fingerprints(sessions)

    Application.put_env(
      :pixir_monitor,
      :projection_input_provider,
      PixirMonitor.WorkspaceSetDegradationTransientProvider
    )

    Application.put_env(:pixir_monitor, :degradation_fail_workspace, left)
    assert_workspace_unavailable(cookie, "left")
    assert_healthy_route(cookie)
    assert directory_fingerprints(sessions) == before

    assert_available_pair(cookie, "affected-left")
    assert directory_fingerprints(sessions) == before
    refute_receive {:projection_changed, _sequence, _workspace, _id}
  end

  defp assert_available_pair(cookie, affected_id) do
    left = response_json(request(cookie, "/api/workspaces/left/runs"), 200)
    assert left["source"]["sessions_directory"] == "observed"
    assert Enum.map(left["snapshot"]["runs"], & &1["id"]) == [affected_id]
    assert_healthy_route(cookie)
  end

  defp assert_empty_observed(cookie) do
    body = response_json(request(cookie, "/api/workspaces/left/runs"), 200)
    assert body["source"] == %{"sessions_directory" => "observed"}
    assert body["snapshot"]["inventory"]["total"] == 0
    assert body["snapshot"]["runs"] == []
  end

  defp assert_healthy_route(cookie) do
    list = response_json(request(cookie, "/api/workspaces/right/runs"), 200)
    assert Enum.map(list["snapshot"]["runs"], & &1["id"]) == ["healthy-right"]

    detail = response_json(request(cookie, "/api/workspaces/right/runs/healthy-right"), 200)
    assert detail["workspace"] == "right"
    assert detail["snapshot"]["run"]["id"] == "healthy-right"
  end

  defp assert_workspace_unavailable(cookie, workspace) do
    body = response_json(request(cookie, "/api/workspaces/#{workspace}/runs"), 503)
    assert body["error"]["kind"] == "workspace_unavailable"
    assert body["error"]["details"]["workspace"] == workspace
  end

  defp limitation_kinds(body) do
    Enum.map(body["snapshot"]["inventory"]["limitations"], & &1["kind"])
  end

  defp directory_fingerprints(directory) do
    directory
    |> File.ls!()
    |> Enum.sort()
    |> Map.new(fn name ->
      {:ok, stat} = File.lstat(Path.join(directory, name), time: :posix)
      {name, {stat.mtime, stat.size}}
    end)
  end

  defp assert_file_then_availability_invalidations(workspace, id) do
    assert_receive {:projection_changed, _sequence, ^workspace, ^id}
    PixirMonitor.InvalidationHub.ack()
    {:ok, _sequence} = PixirMonitor.InvalidationHub.subscribe()
    assert_receive {:projection_changed, _sequence, ^workspace, "workspace:availability"}
    PixirMonitor.InvalidationHub.ack()
    drain_invalidations()
  end

  defp assert_source_invalidation(workspace) do
    assert_receive {:projection_changed, _sequence, ^workspace, _projection_id}
    PixirMonitor.InvalidationHub.ack()
    drain_invalidations()
  end

  defp assert_availability_invalidation(workspace) do
    assert_receive {:projection_changed, _sequence, ^workspace, "workspace:availability"}
    PixirMonitor.InvalidationHub.ack()
    drain_invalidations()
  end

  defp drain_invalidations do
    {:ok, _sequence} = PixirMonitor.InvalidationHub.subscribe()

    receive do
      {:projection_changed, _sequence, _workspace, _id} ->
        PixirMonitor.InvalidationHub.ack()
        drain_invalidations()
    after
      0 -> :ok
    end
  end

  defp create_real_run(workspace, id) do
    event =
      Pixir.Event.new(
        id,
        :subagent_event,
        %{
          "event" => "queued",
          "status" => "queued",
          "subagent_id" => "subagent-1",
          "child_session_id" => "child-1",
          "agent" => "default"
        },
        seq: 0,
        ts: "2026-01-01T00:00:00Z"
      )

    assert {:ok, [_]} = Pixir.Log.create_session(id, [event], workspace: workspace)
  end

  defp session_cookie do
    {:ok, launch} = PixirMonitor.Vault.issue_launch()

    accepted =
      request(
        :post,
        "/bootstrap",
        [
          {"origin", @origin},
          {"sec-fetch-site", "same-origin"},
          {"content-type", "application/json"}
        ],
        Jason.encode!(%{launch: launch})
      )

    accepted
    |> get_resp_header("set-cookie")
    |> List.first()
    |> String.split(";", parts: 2)
    |> hd()
  end

  defp request(cookie, path),
    do: request(:get, path, [{"cookie", cookie}, {"sec-fetch-site", "same-origin"}])

  defp request(method, path, headers, body \\ "") do
    uri = URI.parse("http://#{@host}")

    Enum.reduce(headers, %{conn(method, path, body) | host: uri.host, port: uri.port}, fn {key, value}, acc ->
      put_req_header(acc, key, value)
    end)
    |> PixirMonitor.Router.call([])
  end

  defp response_json(response, status) do
    assert response.status == status
    Jason.decode!(response.resp_body)
  end

  defp restore_env(key, nil), do: Application.delete_env(:pixir_monitor, key)
  defp restore_env(key, value), do: Application.put_env(:pixir_monitor, key, value)
end
