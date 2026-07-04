defmodule Pixir.Delegate.DaemonServer do
  @moduledoc """
  Manual foreground Delegate daemon with bounded local IPC.

  This GenServer is the first cross-invocation residency boundary for Delegate service
  mode. A human or supervising caller starts one foreground Pixir process for a
  workspace; short-lived CLI clients then use loopback IPC to ask that process to run
  `delegate start/status/attach/cancel` against live OTP owners.

  The daemon is intentionally not a production service manager. It does not auto-start,
  install launchd state, create a second durable store, or spawn one OS process per
  child. The endpoint file is only live capability metadata. The Session Log remains
  durable truth.
  """

  use GenServer

  alias Pixir.Events
  alias Pixir.Delegate.{Async, DaemonEndpoint, Handle, OwnerServer, Progress}

  @host {127, 0, 0, 1}
  @host_string "127.0.0.1"
  @recv_timeout_ms 15_000
  @call_timeout_ms 120_000
  @follow_heartbeat_ms 30_000
  @owner_state_timeout_ms 1_000
  @max_payload_bytes 1_000_000

  @doc "Start a Delegate daemon server for a workspace."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc "Return daemon startup metadata safe for stdout."
  @spec started_payload(pid()) :: {:ok, map()} | {:error, map()}
  def started_payload(pid), do: GenServer.call(pid, :started_payload)

  @doc "Block until the daemon process exits."
  @spec await_stop(pid()) :: {:ok, :stopped}
  def await_stop(pid) do
    ref = Process.monitor(pid)

    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} -> {:ok, :stopped}
    end
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    workspace = opts |> Keyword.fetch!(:workspace) |> Path.expand()
    async = Keyword.get(opts, :async, Async)
    token = Keyword.get_lazy(opts, :token, &random_token/0)

    with {:ok, listener} <-
           :gen_tcp.listen(0, [
             :binary,
             packet: 4,
             active: false,
             ip: @host,
             reuseaddr: true
           ]),
         {:ok, {@host, port}} <- :inet.sockname(listener) do
      endpoint = endpoint(workspace, port, token)

      case DaemonEndpoint.write(workspace, endpoint) do
        {:ok, _path} ->
          server = self()
          accept_pid = spawn(fn -> accept_loop(listener, server) end)

          {:ok,
           %{
             workspace: workspace,
             async: async,
             token: token,
             listener: listener,
             accept_pid: accept_pid,
             endpoint: endpoint,
             started_at: endpoint["started_at"],
             follow_heartbeat_ms: Keyword.get(opts, :follow_heartbeat_ms, @follow_heartbeat_ms)
           }}

        {:error, error} ->
          :gen_tcp.close(listener)
          {:stop, {:shutdown, error}}
      end
    else
      {:error, reason} ->
        {:stop,
         {:shutdown,
          error_payload("daemon_listen_failed", "Delegate daemon could not listen on loopback", %{
            "reason" => inspect(reason),
            "next_actions" => ["retry_delegate_daemon", "check_loopback_network_policy"]
          })}}
    end
  end

  @impl true
  def terminate(_reason, state) do
    _ = :gen_tcp.close(state.listener)
    _ = Process.exit(state.accept_pid, :normal)
    _ = DaemonEndpoint.delete_if_owner(state.workspace, state.endpoint)
    :ok
  end

  @impl true
  def handle_call(:started_payload, _from, state) do
    {:reply, {:ok, daemon_payload("running", state)}, state}
  end

  def handle_call({:ipc_request, request}, _from, state) do
    case validate_request(request, state) do
      :ok ->
        dispatch_request(request, state)

      {:error, error} ->
        {:reply, ipc_error(error), state}
    end
  end

  def handle_call({:ipc_follow_context, request}, _from, state) do
    reply =
      with :ok <- validate_request(request, state),
           {:ok, context} <- follow_context(request, state) do
        {:ok, context}
      else
        {:error, error} -> {:error, error}
      end

    {:reply, reply, state}
  end

  defp dispatch_request(%{"action" => "delegate_start", "body" => body}, state)
       when is_map(body) and is_binary(state.workspace) do
    request = Map.get(body, "request", %{})
    spec = Map.get(body, "spec", %{})
    spec_meta = Map.get(body, "spec_meta", %{})
    runtime_opts = Map.get(body, "runtime_opts", [])

    reply =
      with :ok <- require_map("request", request),
           :ok <- require_map("spec", spec),
           :ok <- require_map("spec_meta", spec_meta),
           :ok <- require_list("runtime_opts", runtime_opts) do
        request = request_from_wire(request, state.workspace)

        case apply(state.async, :start, [
               request,
               spec,
               spec_meta,
               [workspace: state.workspace, runtime_opts: runtime_opts]
             ]) do
          {:ok, payload} -> ipc_ok(annotate_daemon_payload(payload, state))
          {:error, error} -> ipc_error(error)
        end
      else
        {:error, error} -> ipc_error(error)
      end

    {:reply, reply, state}
  end

  defp dispatch_request(%{"action" => "delegate_start"}, state) do
    {:reply, ipc_error(protocol_error("delegate_start body must be an object")), state}
  end

  defp dispatch_request(%{"action" => "delegate_status", "body" => %{"handle" => handle}}, state) do
    reply =
      case apply(state.async, :status, [handle, [workspace: state.workspace]]) do
        {:ok, payload} -> ipc_ok(annotate_daemon_payload(payload, state))
        {:error, error} -> ipc_error(error)
      end

    {:reply, reply, state}
  end

  defp dispatch_request(%{"action" => "delegate_attach", "body" => %{"handle" => handle}}, state) do
    reply =
      case apply(state.async, :attach, [handle, [workspace: state.workspace]]) do
        {:ok, payload} -> ipc_ok(annotate_daemon_payload(payload, state))
        {:error, error} -> ipc_error(error)
      end

    {:reply, reply, state}
  end

  defp dispatch_request(%{"action" => "delegate_attach_follow"}, state) do
    {:reply, ipc_error(protocol_error("delegate_attach_follow must use streaming IPC")), state}
  end

  defp dispatch_request(%{"action" => "delegate_cancel", "body" => %{"handle" => handle}}, state) do
    reply =
      case apply(state.async, :cancel, [handle, [workspace: state.workspace]]) do
        {:ok, payload} -> ipc_ok(annotate_daemon_payload(payload, state))
        {:error, error} -> ipc_error(error)
      end

    {:reply, reply, state}
  end

  defp dispatch_request(%{"action" => "daemon_status"}, state) do
    {:reply, ipc_ok(daemon_payload("running", state)), state}
  end

  defp dispatch_request(%{"action" => "daemon_stop"}, state) do
    send(self(), :stop_after_reply)
    {:reply, ipc_ok(daemon_payload("stopped", state)), state}
  end

  defp dispatch_request(%{"action" => action}, state) do
    error =
      error_payload("daemon_unsupported_action", "Delegate daemon action is unsupported", %{
        "action" => action,
        "accepted_actions" => [
          "delegate_start",
          "delegate_status",
          "delegate_attach",
          "delegate_cancel",
          "daemon_status",
          "daemon_stop"
        ]
      })

    {:reply, ipc_error(error), state}
  end

  @impl true
  def handle_info(:stop_after_reply, state), do: {:stop, :normal, state}

  defp validate_request(%{"token" => token, "workspace" => workspace}, state) do
    cond do
      token != state.token ->
        {:error,
         error_payload("daemon_auth_failed", "Delegate daemon token did not match", %{
           "fallback_allowed" => false,
           "next_actions" => ["delete_stale_endpoint", "restart_delegate_daemon"]
         })}

      not is_binary(workspace) ->
        {:error, protocol_error("workspace must be a string")}

      Path.expand(workspace) != state.workspace ->
        {:error,
         error_payload(
           "daemon_workspace_mismatch",
           "Delegate daemon belongs to another workspace",
           %{
             "requested_workspace" => Path.expand(workspace),
             "daemon_workspace" => state.workspace,
             "fallback_allowed" => false,
             "next_actions" => [
               "run_from_the_daemon_workspace",
               "start_a_daemon_for_this_workspace"
             ]
           }
         )}

      true ->
        :ok
    end
  end

  defp validate_request(_request, _state) do
    {:error,
     error_payload("daemon_protocol_error", "Delegate daemon request is missing auth fields", %{
       "fallback_allowed" => false,
       "next_actions" => ["upgrade_pixir_client_and_daemon_together"]
     })}
  end

  defp request_from_wire(request, workspace) when is_map(request) do
    %{
      workspace: workspace,
      dry_run?: false,
      fail_on_incomplete?: false,
      json?: Map.get(request, "json?", true),
      output_dir: nil,
      progress: nil,
      quiet?: false,
      spec_source: Map.get(request, "spec_source"),
      timeout_ms: Map.get(request, "timeout_ms"),
      contract_version: Map.get(request, "contract_version", 1)
    }
  end

  defp follow_context(
         %{
           "action" => "delegate_attach_follow",
           "body" => %{"handle" => handle, "wait_horizon_ms" => wait_horizon_ms}
         },
         state
       )
       when is_binary(handle) and is_integer(wait_horizon_ms) and wait_horizon_ms > 0 do
    with {:ok, resolved} <- Handle.resolve(handle),
         :ok <- validate_follow_handle(resolved) do
      {:ok,
       %{
         async: state.async,
         workspace: state.workspace,
         handle: resolved,
         wait_horizon_ms: wait_horizon_ms,
         follow_heartbeat_ms: state.follow_heartbeat_ms,
         daemon: public_daemon_metadata(state),
         runtime_residency: runtime_residency(state)
       }}
    end
  end

  defp follow_context(%{"action" => "delegate_attach_follow"}, _state) do
    {:error,
     protocol_error("delegate_attach_follow requires handle and positive wait_horizon_ms", %{
       "accepted_body" => %{
         "handle" => "delegate_id_or_parent_session_id",
         "wait_horizon_ms" => 1
       },
       "fallback_allowed" => true
     })}
  end

  defp follow_context(%{"action" => action}, _state) do
    {:error,
     error_payload("daemon_unsupported_action", "Delegate daemon follow action is unsupported", %{
       "action" => action,
       "fallback_allowed" => true,
       "accepted_actions" => ["delegate_attach_follow"]
     })}
  end

  defp validate_follow_handle(%{"parent_session_id" => parent_session_id})
       when is_binary(parent_session_id) do
    if parent_session_id != "" and String.valid?(parent_session_id) do
      :ok
    else
      {:error, invalid_follow_handle(parent_session_id)}
    end
  end

  defp validate_follow_handle(_handle), do: {:error, invalid_follow_handle(nil)}

  defp invalid_follow_handle(parent_session_id) do
    error_payload(
      "invalid_delegate_handle",
      "Delegate follow requires a valid parent Session id",
      %{
        "parent_session_id" => inspect(parent_session_id),
        "fallback_allowed" => false,
        "next_actions" => ["use_parent_session_id_from_delegate_output", "rerun_delegate_start"]
      }
    )
  end

  defp require_map(_field, value) when is_map(value), do: :ok

  defp require_map(field, value),
    do:
      {:error,
       protocol_error("delegate_start #{field} must be an object", %{
         "field" => field,
         "observed" => inspect(value)
       })}

  defp require_list(_field, value) when is_list(value), do: :ok

  defp require_list(field, value),
    do:
      {:error,
       protocol_error("delegate_start #{field} must be a list", %{
         "field" => field,
         "observed" => inspect(value)
       })}

  defp annotate_daemon_payload(
         payload,
         %{endpoint: _endpoint, started_at: _started_at, workspace: _workspace} = state
       )
       when is_map(payload) do
    runtime_residency = runtime_residency(state)

    payload
    |> Map.put("daemon", public_daemon_metadata(state))
    |> Map.put("runtime_residency", runtime_residency)
    |> put_in(["owner", "runtime_residency"], runtime_residency)
    |> put_daemon_host_boundary()
  end

  defp annotate_daemon_payload(payload, %{daemon: daemon, runtime_residency: runtime_residency})
       when is_map(payload) do
    payload
    |> Map.put("daemon", daemon)
    |> Map.put("runtime_residency", runtime_residency)
    |> put_in(["owner", "runtime_residency"], runtime_residency)
    |> put_daemon_host_boundary()
  end

  defp put_daemon_host_boundary(payload) do
    update_in(payload, ["host_boundary"], fn
      %{} = boundary ->
        Map.merge(boundary, %{
          "daemon_ipc" => true,
          "resident_pixir_daemon" => true,
          "nested_pixir_processes" => 0,
          "shell_polling" => false,
          "external_process_spawns_scope" => "delegate_daemon_entrypoint_only_not_child_tools",
          "measurement" => "static_contract_assertion_not_global_host_metric"
        })

      _other ->
        %{
          "external_process_spawns" => 0,
          "external_process_spawns_scope" => "delegate_daemon_entrypoint_only_not_child_tools",
          "measurement" => "static_contract_assertion_not_global_host_metric",
          "nested_pixir_processes" => 0,
          "shell_polling" => false,
          "daemon_ipc" => true,
          "resident_pixir_daemon" => true,
          "rule" => "treat every external process spawn as a scarce observable boundary crossing"
        }
    end)
  end

  defp daemon_payload(status, state) do
    %{
      "ok" => true,
      "status" => status,
      "kind" => "delegate_daemon",
      "workspace" => state.workspace,
      "summary" => daemon_summary(status),
      "daemon" => public_daemon_metadata(state),
      "owners" => daemon_owner_summary(state),
      "runtime_residency" => runtime_residency(state),
      "host_boundary" => %{
        "external_process_spawns" => 0,
        "external_process_spawns_scope" => "delegate_daemon_entrypoint_only_not_child_tools",
        "measurement" => "static_contract_assertion_not_global_host_metric",
        "nested_pixir_processes" => 0,
        "shell_polling" => false,
        "daemon_ipc" => true,
        "resident_pixir_daemon" => true,
        "rule" => "one manual resident Pixir process per workspace; no process-per-child fanout"
      },
      "next_actions" => daemon_next_actions(status)
    }
  end

  defp daemon_summary("running"),
    do: "Delegate daemon is running for this workspace."

  defp daemon_summary("stopped"),
    do: "Delegate daemon stopped for this workspace."

  defp daemon_next_actions("running"),
    do: [
      "run_pixir_delegate_start_from_another_shell",
      "run_pixir_delegate_status_or_cancel_with_the_returned_delegate_id"
    ]

  defp daemon_next_actions("stopped"), do: ["restart_delegate_daemon_when_needed"]

  defp public_daemon_metadata(state) do
    %{
      "host" => @host_string,
      "port" => state.endpoint["port"],
      "pid" => System.pid(),
      "workspace" => state.workspace,
      "started_at" => state.started_at,
      "endpoint_file" => endpoint_file(state.workspace),
      "manual_foreground" => true
    }
  end

  defp daemon_owner_summary(state) do
    case live_owner_states() do
      {:ok, owners} ->
        owners =
          Enum.filter(owners, fn owner ->
            owner["workspace"] == state.workspace
          end)

        %{
          "active_owner_count" => length(owners),
          "delegate_ids" => owners |> Enum.map(& &1["delegate_id"]) |> Enum.reject(&is_nil/1),
          "parent_session_ids" =>
            owners |> Enum.map(& &1["parent_session_id"]) |> Enum.reject(&is_nil/1)
        }

      {:error, error} ->
        %{
          "active_owner_count" => nil,
          "delegate_ids" => [],
          "parent_session_ids" => [],
          "error" => error
        }
    end
  end

  defp live_owner_states do
    owners =
      Pixir.Delegate.OwnerSupervisor
      |> DynamicSupervisor.which_children()
      |> Enum.flat_map(fn
        {_id, pid, _type, _modules} when is_pid(pid) ->
          case safe_owner_state(pid) do
            {:ok, owner} -> [{pid, owner}]
            {:error, _error} -> []
          end

        _other ->
          []
      end)
      |> Enum.uniq_by(fn {pid, _owner} -> pid end)
      |> Enum.map(fn {_pid, owner} -> owner end)

    {:ok, owners}
  catch
    :exit, reason ->
      {:error, %{"kind" => "owner_registry_unavailable", "reason" => inspect(reason)}}
  end

  defp safe_owner_state(pid) do
    OwnerServer.owner_state(pid, @owner_state_timeout_ms)
  catch
    :exit, reason ->
      {:error, %{"kind" => "owner_state_unavailable", "reason" => inspect(reason)}}
  end

  defp endpoint_file(workspace) do
    case DaemonEndpoint.path(workspace) do
      {:ok, path} -> path
      {:error, _error} -> nil
    end
  end

  defp runtime_residency(state) do
    %{
      "model" => "daemon_ipc",
      "survives_cli_process_exit" => true,
      "cross_invocation_owner" => true,
      "daemon_or_ipc" => true,
      "workspace" => state.workspace,
      "manual_foreground" => true
    }
  end

  defp endpoint(workspace, port, token) do
    %{
      "contract_version" => 1,
      "host" => @host_string,
      "port" => port,
      "token" => token,
      "workspace" => workspace,
      "pid" => System.pid(),
      "started_at" => now()
    }
  end

  defp accept_loop(listener, server) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        handler =
          spawn(fn ->
            receive do
              {:serve_socket, accepted_socket} -> serve_socket(accepted_socket, server)
            end
          end)

        :ok = :gen_tcp.controlling_process(socket, handler)
        send(handler, {:serve_socket, socket})
        accept_loop(listener, server)

      {:error, :closed} ->
        :ok

      {:error, _reason} ->
        :ok
    end
  end

  defp serve_socket(socket, server) do
    case read_socket_request(socket) do
      {:ok, %{"action" => "delegate_attach_follow"} = request} ->
        serve_follow_socket(socket, server, request)

      {:ok, request} ->
        response = GenServer.call(server, {:ipc_request, request}, @call_timeout_ms)
        _ = send_packet(socket, response)
        _ = :gen_tcp.close(socket)
        :ok

      {:error, response} ->
        _ = send_packet(socket, response)
        _ = :gen_tcp.close(socket)
        :ok
    end
  catch
    :exit, reason ->
      _ =
        send_packet(
          socket,
          ipc_error(
            error_payload("daemon_unavailable", "Delegate daemon request failed", %{
              "reason" => inspect(reason),
              "fallback_allowed" => true
            })
          )
        )

      _ = :gen_tcp.close(socket)
      :ok
  end

  defp read_socket_request(socket) do
    with {:ok, raw} <- :gen_tcp.recv(socket, 0, @recv_timeout_ms),
         :ok <- check_payload_size(raw),
         {:ok, request} <- Jason.decode(raw) do
      {:ok, request}
    else
      {:error, %Jason.DecodeError{} = error} ->
        {:error,
         ipc_error(
           error_payload("daemon_protocol_error", "Delegate daemon request was invalid JSON", %{
             "decode_error" => Exception.message(error)
           })
         )}

      {:error, error} when is_map(error) ->
        {:error, ipc_error(error)}

      {:error, reason} ->
        {:error,
         ipc_error(
           error_payload("daemon_transport_error", "Delegate daemon socket read failed", %{
             "reason" => inspect(reason)
           })
         )}
    end
  end

  defp serve_follow_socket(socket, server, request) do
    case GenServer.call(server, {:ipc_follow_context, request}, @call_timeout_ms) do
      {:ok, context} ->
        run_follow_socket(socket, context)

      {:error, error} ->
        _ = send_packet(socket, ipc_error(error))
        _ = :gen_tcp.close(socket)
        :ok
    end
  end

  defp run_follow_socket(socket, context) do
    parent_session_id = context.handle["parent_session_id"]
    :ok = Events.subscribe(parent_session_id, only: [:subagent_event])

    try do
      case follow_attach(context) do
        {:ok, payload} ->
          payload = annotate_daemon_payload(payload, context)
          source = Progress.source(payload, streaming?: live_owner?(payload))
          frame = Progress.frame(payload, 1, source: source)

          with :ok <- send_frame(socket, frame) do
            follow_loop(socket, context, payload, 1, 0, System.monotonic_time(:millisecond))
          end

        {:error, error} ->
          _ = send_packet(socket, ipc_error(error))
          :ok
      end
    after
      _ = Events.unsubscribe(parent_session_id)
      _ = :gen_tcp.close(socket)
    end
  end

  defp follow_loop(socket, context, payload, frame_count, error_count, started_at) do
    elapsed = System.monotonic_time(:millisecond) - started_at
    remaining = max(context.wait_horizon_ms - elapsed, 0)

    cond do
      Progress.terminal?(payload) ->
        send_final_follow_payload(socket, payload, context, frame_count, error_count, false)

      not live_owner?(payload) ->
        send_final_follow_payload(socket, payload, context, frame_count, error_count, false)

      remaining <= 0 ->
        send_final_follow_payload(socket, payload, context, frame_count, error_count, true)

      true ->
        timeout_ms = min(remaining, context.follow_heartbeat_ms)

        receive do
          {:pixir_event, %{type: :subagent_event}} ->
            emit_follow_snapshot(socket, context, frame_count, error_count, started_at, false)
        after
          timeout_ms ->
            emit_follow_snapshot(socket, context, frame_count, error_count, started_at, true)
        end
    end
  end

  defp emit_follow_snapshot(socket, context, frame_count, error_count, started_at, heartbeat?) do
    case follow_attach(context) do
      {:ok, payload} ->
        payload = annotate_daemon_payload(payload, context)
        sequence = frame_count + 1
        source = Progress.source(payload, streaming?: live_owner?(payload))
        frame = Progress.frame(payload, sequence, source: source, heartbeat?: heartbeat?)

        with :ok <- send_frame(socket, frame) do
          follow_loop(socket, context, payload, sequence, error_count, started_at)
        end

      {:error, error} ->
        sequence = frame_count + 1
        frame = Progress.error_frame(error, sequence, context.handle)
        _ = send_frame(socket, frame)

        fallback =
          error
          |> Map.put_new("summary", "delegate follow lost live owner; returned progress error.")
          |> Map.put_new("delegate_id", context.handle["delegate_id"])
          |> Map.put_new("parent_session_id", context.handle["parent_session_id"])
          |> Map.put_new("status", "partial")
          |> Map.put_new("complete", false)
          |> Map.put_new("service_state", "owner_unavailable")

        send_final_follow_payload(socket, fallback, context, sequence, error_count + 1, false)
    end
  end

  defp follow_attach(context) do
    case apply(context.async, :attach, [
           context.handle["delegate_id"],
           [workspace: context.workspace]
         ]) do
      {:ok, payload} -> {:ok, payload}
      {:error, error} -> {:error, normalize_error(error)}
    end
  end

  defp send_final_follow_payload(socket, payload, context, frame_count, error_count, horizon?) do
    source = Progress.source(payload, streaming?: live_owner?(payload))

    payload =
      payload
      |> mark_follow_attach(source)
      |> Progress.annotate(%{
        "frame_count" => frame_count,
        "follow_requested" => true,
        "followed" => true,
        "follow_transport" => "daemon_stream",
        "wait_horizon_ms" => context.wait_horizon_ms,
        "wait_horizon_exhausted" => horizon?,
        "terminal_observed" => Progress.terminal?(payload),
        "follow_error_count" => error_count,
        "source" => source,
        "owner_backed" => Progress.owner_backed_source?(source)
      })

    _ = send_packet(socket, ipc_ok(payload))
    :ok
  end

  defp mark_follow_attach(payload, "live_owner_stream") do
    update_in(payload, ["attach"], fn
      %{} = attach ->
        attach
        |> Map.put("mode", "owner_pushed_follow")
        |> Map.put("streaming", true)
        |> Map.put("source", "live_owner_stream")

      _other ->
        %{"mode" => "owner_pushed_follow", "streaming" => true, "source" => "live_owner_stream"}
    end)
  end

  defp mark_follow_attach(payload, source) do
    update_in(payload, ["attach"], fn
      %{} = attach -> Map.put(attach, "source", source)
      _other -> %{"streaming" => false, "source" => source}
    end)
  end

  defp live_owner?(payload) do
    get_in(payload, ["owner", "state"]) == "live_delegate_owner" and
      get_in(payload, ["owner", "reachable"]) != false
  end

  defp send_frame(socket, frame),
    do: send_packet(socket, %{"ipc_frame" => true, "frame" => frame})

  defp send_packet(socket, packet), do: :gen_tcp.send(socket, Jason.encode!(packet))

  defp check_payload_size(raw) when byte_size(raw) <= @max_payload_bytes, do: :ok

  defp check_payload_size(raw) do
    {:error,
     error_payload(
       "daemon_payload_too_large",
       "Delegate daemon request exceeded max payload bytes",
       %{
         "bytes" => byte_size(raw),
         "max_bytes" => @max_payload_bytes,
         "fallback_allowed" => false
       }
     )}
  end

  defp ipc_ok(payload), do: %{"ipc_ok" => true, "payload" => payload}
  defp ipc_error(error), do: %{"ipc_ok" => false, "error" => normalize_error(error)}

  defp normalize_error(%{"ok" => false} = error), do: error

  defp normalize_error(error) when is_map(error) do
    error
    |> Map.put_new("ok", false)
    |> Map.put_new("status", "rejected")
    |> Map.put_new("kind", "daemon_error")
    |> Map.put_new("message", "Delegate daemon request failed")
    |> Map.put_new("details", %{})
  end

  defp normalize_error(error) do
    error_payload("daemon_error", "Delegate daemon request failed", %{"reason" => inspect(error)})
  end

  defp error_payload(kind, message, details) do
    %{
      "ok" => false,
      "status" => "rejected",
      "kind" => kind,
      "message" => message,
      "details" => details
    }
  end

  defp protocol_error(message, details \\ %{}) do
    error_payload(
      "daemon_protocol_error",
      "Delegate daemon request is invalid: #{message}",
      Map.merge(%{"fallback_allowed" => false}, details)
    )
  end

  defp random_token, do: 32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
end
