defmodule Pixir.Delegate.DaemonClientTest do
  use ExUnit.Case, async: false

  alias Pixir.Delegate.{DaemonClient, DaemonEndpoint, DaemonServer, Handle, OwnerSupervisor}

  defmodule FakeAsync do
    def start(request, spec, spec_meta, opts) do
      {:ok,
       %{
         "ok" => true,
         "status" => "running",
         "kind" => "delegate_start",
         "delegate_id" => "dlg1_fake",
         "parent_session_id" => "parent-from-daemon",
         "workspace" => request.workspace,
         "spec_task" => spec["task"],
         "planned_child_count" => spec_meta["planned_child_count"],
         "runtime_opts_seen" => Keyword.get(opts, :runtime_opts),
         "owner" => %{"state" => "live_delegate_owner"},
         "host_boundary" => %{
           "external_process_spawns" => 0,
           "nested_pixir_processes" => 0,
           "shell_polling" => false
         }
       }}
    end

    def status(handle, opts) do
      {:ok,
       %{
         "ok" => false,
         "status" => "running",
         "kind" => "delegate_status",
         "delegate_id" => handle,
         "workspace" => Keyword.fetch!(opts, :workspace),
         "owner" => %{"state" => "live_delegate_owner"},
         "host_boundary" => %{"external_process_spawns" => 0, "shell_polling" => false}
       }}
    end

    def attach(handle, opts) do
      parent_session_id =
        case Pixir.Delegate.Handle.resolve(handle) do
          {:ok, %{"parent_session_id" => parent_session_id}} when is_binary(parent_session_id) ->
            if String.valid?(parent_session_id), do: parent_session_id, else: "parent-from-daemon"

          {:error, _error} ->
            "parent-from-daemon"

          _other ->
            "parent-from-daemon"
        end

      {:ok,
       %{
         "ok" => true,
         "status" => "running",
         "complete" => false,
         "kind" => "delegate_attach",
         "delegate_id" => handle,
         "parent_session_id" => parent_session_id,
         "workspace" => Keyword.fetch!(opts, :workspace),
         "attach" => %{"mode" => "one_shot_snapshot", "streaming" => false},
         "owner" => %{"state" => "live_delegate_owner", "reachable" => true},
         "host_boundary" => %{"external_process_spawns" => 0, "shell_polling" => false}
       }}
    end

    def cancel(handle, opts) do
      {:ok,
       %{
         "ok" => true,
         "status" => "cancelled",
         "kind" => "delegate_cancel",
         "delegate_id" => handle,
         "workspace" => Keyword.fetch!(opts, :workspace),
         "cancelled_child_count" => 1,
         "owner" => %{"state" => "live_delegate_owner"},
         "host_boundary" => %{"external_process_spawns" => 0, "shell_polling" => false}
       }}
    end
  end

  defmodule EventedAsync do
    def attach(handle, opts) do
      count = :persistent_term.get({__MODULE__, :attach_calls}, 0) + 1
      :persistent_term.put({__MODULE__, :attach_calls}, count)

      parent_session_id =
        case Pixir.Delegate.Handle.resolve(handle) do
          {:ok, %{"parent_session_id" => parent_session_id}} -> parent_session_id
          {:error, _error} -> "parent-evented"
        end

      status = if count >= 2, do: "completed", else: "running"

      {:ok,
       %{
         "ok" => true,
         "status" => status,
         "complete" => status == "completed",
         "kind" => "delegate_attach",
         "delegate_id" => handle,
         "parent_session_id" => parent_session_id,
         "workspace" => Keyword.fetch!(opts, :workspace),
         "counts" => %{"total" => 1, status => 1},
         "attach" => %{"mode" => "one_shot_snapshot", "streaming" => false},
         "owner" => %{"state" => "live_delegate_owner", "reachable" => true},
         "host_boundary" => %{"external_process_spawns" => 0, "shell_polling" => false}
       }}
    end
  end

  defmodule OwnerRunner do
    def start(request, spec, _spec_meta, _opts) do
      parent_session_id = spec["parent_session_id"]
      {:ok, handle} = Handle.build(parent_session_id)

      {:ok,
       %{
         handle: handle,
         parent_session_id: parent_session_id,
         runtime: %{
           workspace: request.workspace,
           planned_child_count: 1,
           timeout_ms: 1_000,
           max_threads: 1,
           max_depth: 1,
           mode: "read_only",
           workspace_mode: "shared"
         },
         agents: [],
         payload: %{
           "ok" => true,
           "status" => "running",
           "kind" => "delegate_start",
           "delegate_id" => handle["delegate_id"],
           "parent_session_id" => parent_session_id,
           "handle" => handle,
           "owner" => %{"state" => "live_delegate_owner"},
           "service_state" => "live_delegate_owner"
         }
       }}
    end
  end

  setup do
    ws =
      Path.join(
        System.tmp_dir!(),
        "pixir-delegate-daemon-" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
      )

    File.mkdir_p!(ws)
    on_exit(fn -> File.rm_rf!(ws) end)
    %{ws: ws}
  end

  test "daemon client routes start status cancel through loopback IPC", %{ws: ws} do
    assert {:ok, pid} = DaemonServer.start_link(workspace: ws, async: FakeAsync)

    on_exit(fn ->
      stop_daemon(pid)
    end)

    assert {:ok,
            %{
              "kind" => "delegate_start",
              "status" => "running",
              "workspace" => ^ws,
              "spec_task" => "inspect",
              "planned_child_count" => 1,
              "daemon" => %{
                "workspace" => ^ws,
                "manual_foreground" => true,
                "endpoint_file" => endpoint_file
              },
              "runtime_residency" => %{
                "model" => "daemon_ipc",
                "survives_cli_process_exit" => true,
                "cross_invocation_owner" => true
              },
              "owner" => %{
                "state" => "live_delegate_owner",
                "runtime_residency" => %{"model" => "daemon_ipc"}
              },
              "host_boundary" => %{
                "daemon_ipc" => true,
                "resident_pixir_daemon" => true,
                "nested_pixir_processes" => 0,
                "shell_polling" => false
              }
            }} =
             DaemonClient.call(
               "delegate_start",
               %{
                 "request" => %{"json?" => true, "contract_version" => 1},
                 "spec" => %{"task" => "inspect"},
                 "spec_meta" => %{"planned_child_count" => 1}
               },
               workspace: ws
             )

    assert {:ok, ^endpoint_file} = DaemonEndpoint.path(ws)

    assert {:ok,
            %{
              "kind" => "delegate_status",
              "delegate_id" => "dlg1_fake",
              "runtime_residency" => %{"model" => "daemon_ipc"}
            }} = DaemonClient.call("delegate_status", %{"handle" => "dlg1_fake"}, workspace: ws)

    assert {:ok,
            %{
              "kind" => "delegate_attach",
              "delegate_id" => "dlg1_fake",
              "attach" => %{"mode" => "one_shot_snapshot", "streaming" => false},
              "runtime_residency" => %{"model" => "daemon_ipc"}
            }} = DaemonClient.call("delegate_attach", %{"handle" => "dlg1_fake"}, workspace: ws)

    assert {:ok,
            %{
              "kind" => "delegate_cancel",
              "status" => "cancelled",
              "cancelled_child_count" => 1,
              "runtime_residency" => %{"model" => "daemon_ipc"}
            }} = DaemonClient.call("delegate_cancel", %{"handle" => "dlg1_fake"}, workspace: ws)

    assert {:ok, %{"kind" => "delegate_daemon", "status" => "stopped"}} =
             DaemonClient.stop(workspace: ws)

    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 1_000
    assert {:ok, endpoint_path} = DaemonEndpoint.path(ws)
    refute File.exists?(endpoint_path)
  end

  test "daemon status reports absent endpoint without failing the status command", %{ws: ws} do
    assert {:ok,
            %{
              "kind" => "delegate_daemon",
              "ok" => true,
              "status" => "absent",
              "daemon" => %{
                "state" => "absent",
                "reachable" => false,
                "endpoint_file" => endpoint_file
              },
              "next_actions" => next_actions
            }} = DaemonClient.status(workspace: ws)

    assert endpoint_file =~ ".pixir/delegate/daemon.json"
    assert "start_pixir_delegate_daemon_--foreground_--json" in next_actions
  end

  test "daemon status and stop clean up proven stale endpoint metadata", %{ws: ws} do
    stale_endpoint = stale_endpoint(ws)
    assert {:ok, endpoint_path} = DaemonEndpoint.write(ws, stale_endpoint)

    assert {:ok,
            %{
              "kind" => "delegate_daemon",
              "status" => "stale_endpoint",
              "details" => %{
                "daemon_error" => %{
                  "details" => %{
                    "stale_endpoint" => true,
                    "stale_endpoint_cleanup" => %{"status" => "deleted"}
                  }
                }
              }
            }} = DaemonClient.status(workspace: ws)

    refute File.exists?(endpoint_path)

    assert {:ok, _endpoint_path} = DaemonEndpoint.write(ws, stale_endpoint(ws))

    assert {:ok,
            %{
              "kind" => "delegate_daemon",
              "ok" => true,
              "status" => "stale_endpoint",
              "details" => %{
                "daemon_error" => %{
                  "details" => %{
                    "stale_endpoint" => true,
                    "stale_endpoint_cleanup" => %{"status" => "deleted"}
                  }
                }
              }
            }} = DaemonClient.stop(workspace: ws)

    refute File.exists?(endpoint_path)
  end

  test "daemon status preserves endpoint metadata after post-connect IPC failure", %{ws: ws} do
    assert {:ok, endpoint_path, closer_pid} = closing_socket_endpoint(ws)

    on_exit(fn ->
      if Process.alive?(closer_pid), do: Process.exit(closer_pid, :kill)
    end)

    assert {:ok,
            %{
              "kind" => "delegate_daemon",
              "ok" => false,
              "status" => "unavailable",
              "details" => %{
                "daemon_error" => %{
                  "details" => %{
                    "stale_endpoint" => false,
                    "endpoint_file" => ^endpoint_path
                  }
                }
              }
            }} = DaemonClient.status(workspace: ws)

    assert File.exists?(endpoint_path)
  end

  test "daemon status reports active owner counts for this workspace", %{ws: ws} do
    sid = "daemon-owner-parent-" <> Base.encode16(:crypto.strong_rand_bytes(3), case: :lower)

    assert {:ok, %{"delegate_id" => delegate_id}} =
             OwnerSupervisor.start_delegate(
               %{workspace: ws, timeout_ms: nil},
               %{"parent_session_id" => sid},
               %{"strategy" => "subagents", "planned_child_count" => 1},
               runner: OwnerRunner
             )

    assert {:ok, handle} = Handle.resolve(delegate_id)

    on_exit(fn ->
      case OwnerSupervisor.lookup(handle) do
        {:ok, pid} -> Process.exit(pid, :normal)
        {:error, :not_found} -> :ok
      end
    end)

    assert {:ok, pid} = DaemonServer.start_link(workspace: ws, async: FakeAsync)

    on_exit(fn ->
      stop_daemon(pid)
    end)

    assert {:ok,
            %{
              "kind" => "delegate_daemon",
              "status" => "running",
              "owners" => %{
                "active_owner_count" => 1,
                "delegate_ids" => [^delegate_id],
                "parent_session_ids" => [^sid]
              }
            }} = DaemonClient.status(workspace: ws)
  end

  test "follow streams frames without blocking daemon status cancel or stop", %{ws: ws} do
    assert {:ok, handle} = Handle.build("parent-follow")
    delegate_id = handle["delegate_id"]
    parent = self()

    assert {:ok, pid} =
             DaemonServer.start_link(workspace: ws, async: FakeAsync, follow_heartbeat_ms: 10)

    on_exit(fn ->
      stop_daemon(pid)
    end)

    follow_task =
      Task.async(fn ->
        DaemonClient.follow(
          "delegate_attach_follow",
          %{"handle" => delegate_id, "wait_horizon_ms" => 50},
          fn frame -> send(parent, {:follow_frame, frame}) end,
          workspace: ws
        )
      end)

    assert_receive {:follow_frame,
                    %{
                      "type" => "delegate_progress",
                      "sequence" => 1,
                      "delegate_id" => ^delegate_id,
                      "parent_session_id" => "parent-follow",
                      "source" => "live_owner_stream",
                      "owner_backed" => true
                    }},
                   1_000

    assert {:ok,
            %{
              "kind" => "delegate_status",
              "delegate_id" => ^delegate_id,
              "runtime_residency" => %{"model" => "daemon_ipc"}
            }} = DaemonClient.call("delegate_status", %{"handle" => delegate_id}, workspace: ws)

    assert {:ok,
            %{
              "kind" => "delegate_cancel",
              "status" => "cancelled",
              "runtime_residency" => %{"model" => "daemon_ipc"}
            }} = DaemonClient.call("delegate_cancel", %{"handle" => delegate_id}, workspace: ws)

    assert {:ok, %{"kind" => "delegate_daemon", "status" => "stopped"}} =
             DaemonClient.stop(workspace: ws)

    assert {:ok,
            %{
              "kind" => "delegate_attach",
              "delegate_id" => ^delegate_id,
              "parent_session_id" => "parent-follow",
              "attach" => %{
                "mode" => "owner_pushed_follow",
                "streaming" => true,
                "source" => "live_owner_stream"
              },
              "progress" => %{
                "follow_requested" => true,
                "followed" => true,
                "follow_transport" => "daemon_stream",
                "wait_horizon_exhausted" => true,
                "owner_backed" => true,
                "source" => "live_owner_stream"
              }
            }} = Task.await(follow_task, 1_000)
  end

  test "follow emits terminal frame when a subagent event arrives before heartbeat", %{ws: ws} do
    :persistent_term.put({EventedAsync, :attach_calls}, 0)

    on_exit(fn ->
      :persistent_term.erase({EventedAsync, :attach_calls})
    end)

    assert {:ok, handle} = Handle.build("parent-evented")
    delegate_id = handle["delegate_id"]
    parent = self()

    assert {:ok, pid} =
             DaemonServer.start_link(
               workspace: ws,
               async: EventedAsync,
               follow_heartbeat_ms: 5_000
             )

    on_exit(fn ->
      stop_daemon(pid)
    end)

    follow_task =
      Task.async(fn ->
        DaemonClient.follow(
          "delegate_attach_follow",
          %{"handle" => delegate_id, "wait_horizon_ms" => 1_000},
          fn frame -> send(parent, {:evented_follow_frame, frame}) end,
          workspace: ws
        )
      end)

    assert_receive {:evented_follow_frame,
                    %{
                      "type" => "delegate_progress",
                      "sequence" => 1,
                      "status" => "running"
                    }},
                   1_000

    Pixir.Events.publish(
      Pixir.Event.subagent_event("parent-evented", %{
        "event" => "finished",
        "status" => "completed",
        "subagent_id" => "sub_evented",
        "child_session_id" => "child-evented"
      })
    )

    assert_receive {:evented_follow_frame,
                    %{
                      "type" => "delegate_terminal",
                      "sequence" => 2,
                      "status" => "completed",
                      "source" => "live_owner_stream"
                    }},
                   500

    assert {:ok,
            %{
              "status" => "completed",
              "complete" => true,
              "progress" => %{
                "frame_count" => 2,
                "wait_horizon_exhausted" => false,
                "terminal_observed" => true
              }
            }} = Task.await(follow_task, 1_000)

    assert :persistent_term.get({EventedAsync, :attach_calls}) == 2
  end

  test "missing endpoint is a fallback-capable daemon_unavailable error", %{ws: ws} do
    assert {:error,
            %{
              "kind" => "daemon_unavailable",
              "details" => %{"fallback_allowed" => true}
            } = error} =
             DaemonClient.call("delegate_status", %{"handle" => "dlg1_fake"}, workspace: ws)

    assert get_in(error, ["details", "fallback_allowed"])
  end

  test "malformed delegate_start IPC returns structured protocol error", %{ws: ws} do
    assert {:ok, pid} = DaemonServer.start_link(workspace: ws, async: FakeAsync)

    on_exit(fn ->
      stop_daemon(pid)
    end)

    assert {:error,
            %{
              "kind" => "daemon_protocol_error",
              "details" => %{"fallback_allowed" => false, "field" => "request"}
            }} =
             DaemonClient.call(
               "delegate_start",
               %{"request" => [], "spec" => %{}, "spec_meta" => %{}},
               workspace: ws
             )
  end

  test "daemon client returns structured error when workspace is missing" do
    assert {:error,
            %{
              "kind" => "invalid_args",
              "message" => "workspace is required for Delegate daemon IPC"
            }} = DaemonClient.status()
  end

  test "endpoint diagnostics redact token and delete only owned endpoint", %{ws: ws} do
    assert {:ok, endpoint_path} = DaemonEndpoint.path(ws)
    File.mkdir_p!(Path.dirname(endpoint_path))

    File.write!(
      endpoint_path,
      Jason.encode!(%{"token" => "secret-token", "workspace" => ws, "host" => 123})
    )

    assert {:error,
            %{
              "kind" => "daemon_endpoint_invalid",
              "details" => %{"endpoint" => endpoint_diagnostic}
            }} = DaemonEndpoint.read(ws)

    refute endpoint_diagnostic =~ "secret-token"
    assert endpoint_diagnostic =~ "[REDACTED]"

    old_endpoint = %{
      "token" => "old-token",
      "port" => 1,
      "pid" => "old",
      "started_at" => "old"
    }

    new_endpoint = %{
      "token" => "new-token",
      "port" => 2,
      "pid" => "new",
      "started_at" => "new"
    }

    File.write!(endpoint_path, Jason.encode!(new_endpoint))
    assert {:ok, :skipped} = DaemonEndpoint.delete_if_owner(ws, old_endpoint)
    assert File.exists?(endpoint_path)
    assert {:ok, :deleted} = DaemonEndpoint.delete_if_owner(ws, new_endpoint)
    refute File.exists?(endpoint_path)

    File.write!(endpoint_path, Jason.encode!(%{}))
    assert {:ok, :skipped} = DaemonEndpoint.delete_if_owner(ws, %{})
    assert File.exists?(endpoint_path)
  end

  test "daemon client does not expose raw invalid responses", %{ws: ws} do
    with_raw_endpoint(ws, %{"token" => "secret-response-token"}, fn ->
      assert {:error,
              %{
                "kind" => "daemon_protocol_error",
                "details" => %{"response_shape" => %{"keys" => keys}}
              } = error} = DaemonClient.call("daemon_status", %{}, workspace: ws)

      error_text = inspect(error)
      refute error_text =~ "secret-response-token"
      refute error_text =~ "response\" =>"
      assert "token" in keys
    end)
  end

  test "daemon client returns structured error when request cannot be encoded", %{ws: ws} do
    with_raw_endpoint(ws, %{"ipc_ok" => true, "payload" => %{}}, fn ->
      assert {:error,
              %{
                "kind" => "daemon_protocol_error",
                "details" => %{"fallback_allowed" => false}
              }} = DaemonClient.call("daemon_status", %{"bad" => self()}, workspace: ws)
    end)
  end

  defp with_raw_endpoint(ws, response, fun) do
    assert {:ok, endpoint_path} = DaemonEndpoint.path(ws)

    assert {:ok, listen} =
             :gen_tcp.listen(0, [:binary, packet: 4, active: false, ip: {127, 0, 0, 1}])

    assert {:ok, port} = :inet.port(listen)

    server =
      Task.async(fn ->
        with {:ok, socket} <- :gen_tcp.accept(listen, 1_000) do
          _ = :gen_tcp.recv(socket, 0, 1_000)
          _ = :gen_tcp.send(socket, Jason.encode!(response))
          _ = :gen_tcp.close(socket)
        end
      end)

    File.mkdir_p!(Path.dirname(endpoint_path))

    File.write!(
      endpoint_path,
      Jason.encode!(%{
        "host" => "127.0.0.1",
        "port" => port,
        "token" => "endpoint-token",
        "workspace" => ws
      })
    )

    try do
      fun.()
    after
      :gen_tcp.close(listen)
      _ = Task.await(server, 1_500)
    end
  end

  defp stale_endpoint(ws) do
    port = unused_loopback_port()

    %{
      "contract_version" => 1,
      "host" => "127.0.0.1",
      "port" => port,
      "token" => "stale-token",
      "workspace" => ws,
      "pid" => "stale-pid",
      "started_at" => "2026-07-03T00:00:00Z"
    }
  end

  defp unused_loopback_port do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, packet: 4, active: false, ip: {127, 0, 0, 1}])

    {:ok, port} = :inet.port(listener)
    :ok = :gen_tcp.close(listener)
    port
  end

  defp closing_socket_endpoint(ws) do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, packet: 4, active: false, ip: {127, 0, 0, 1}])

    {:ok, {_host, port}} = :inet.sockname(listener)

    endpoint = %{
      "contract_version" => 1,
      "host" => "127.0.0.1",
      "port" => port,
      "token" => "closing-token",
      "workspace" => ws,
      "pid" => "closing-socket-pid",
      "started_at" => "2026-07-03T00:00:00Z"
    }

    {:ok, endpoint_path} = DaemonEndpoint.write(ws, endpoint)

    closer_pid =
      spawn(fn ->
        case :gen_tcp.accept(listener, 1_000) do
          {:ok, socket} -> :gen_tcp.close(socket)
          {:error, _reason} -> :ok
        end

        :gen_tcp.close(listener)
      end)

    {:ok, endpoint_path, closer_pid}
  end

  defp stop_daemon(pid) do
    if Process.alive?(pid) do
      GenServer.stop(pid, :normal, 1_000)
    end
  catch
    :exit, _reason -> :ok
  end
end
