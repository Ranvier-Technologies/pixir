defmodule Pixir.Delegate.DaemonClient do
  @moduledoc """
  Short-lived CLI client for the workspace-local Delegate daemon.

  This module owns the IPC attempt from ordinary `pixir delegate` commands into a
  manually started foreground daemon. It treats stale endpoint files and closed sockets
  as fallback-capable daemon unavailability, while authentication or workspace mismatch
  remain explicit structured errors.
  """

  alias Pixir.Delegate.DaemonEndpoint

  @connect_timeout_ms 1_000
  @recv_timeout_ms 120_000

  @doc "Call the workspace-local daemon."
  @spec call(String.t(), map(), keyword()) :: {:ok, map()} | {:error, map()}
  def call(action, body, opts \\ []) when is_binary(action) and is_map(body) do
    with {:ok, workspace} <- fetch_workspace(opts),
         {:ok, endpoint} <- DaemonEndpoint.read(workspace),
         :ok <- validate_workspace(endpoint, workspace) do
      case connect(endpoint) do
        {:ok, socket} ->
          try do
            socket
            |> call_socket(endpoint, action, body, workspace)
            |> normalize_socket_result(workspace, endpoint)
          after
            close(socket)
          end

        {:error, %{"ok" => false} = error} ->
          {:error, error}

        {:error, reason} ->
          normalize_pre_connect_result({:error, reason}, workspace, endpoint)
      end
    else
      {:error, %{"ok" => false} = error} ->
        {:error, error}

      {:error, reason} ->
        {:error,
         error_payload("daemon_unavailable", "Delegate daemon was not reachable", %{
           "reason" => inspect(reason),
           "fallback_allowed" => true,
           "next_actions" => ["delete_stale_endpoint", "restart_delegate_daemon"]
         })}
    end
  end

  @doc """
  Follow a daemon stream, emitting progress frames until a final payload arrives.

  The daemon sends zero or more `%{"ipc_frame" => true}` packets followed by the normal
  `%{"ipc_ok" => true, "payload" => ...}` response. The callback receives decoded
  frame maps in-order and should keep side effects bounded to presentation.
  """
  @spec follow(String.t(), map(), (map() -> term()), keyword()) :: {:ok, map()} | {:error, map()}
  def follow(action, body, emit_frame, opts \\ [])
      when is_binary(action) and is_map(body) and is_function(emit_frame, 1) do
    with {:ok, workspace} <- fetch_workspace(opts),
         {:ok, endpoint} <- DaemonEndpoint.read(workspace),
         :ok <- validate_workspace(endpoint, workspace) do
      case connect(endpoint) do
        {:ok, socket} ->
          try do
            socket
            |> follow_socket(endpoint, action, body, workspace, emit_frame)
            |> normalize_socket_result(workspace, endpoint)
          after
            close(socket)
          end

        {:error, %{"ok" => false} = error} ->
          {:error, error}

        {:error, reason} ->
          normalize_pre_connect_result({:error, reason}, workspace, endpoint)
      end
    else
      {:error, %{"ok" => false} = error} ->
        {:error, error}

      {:error, reason} ->
        {:error,
         error_payload("daemon_unavailable", "Delegate daemon follow was not reachable", %{
           "reason" => inspect(reason),
           "fallback_allowed" => true,
           "next_actions" => ["delete_stale_endpoint", "restart_delegate_daemon"]
         })}
    end
  end

  @doc "Return daemon status through IPC."
  @spec status(keyword()) :: {:ok, map()} | {:error, map()}
  def status(opts \\ []) do
    with {:ok, workspace} <- fetch_workspace(opts) do
      case call("daemon_status", %{}, opts) do
        {:ok, payload} ->
          {:ok, payload}

        {:error, %{"ok" => false} = error} ->
          {:ok, daemon_state_payload("status", workspace, error)}
      end
    end
  end

  @doc "Ask the daemon to stop."
  @spec stop(keyword()) :: {:ok, map()} | {:error, map()}
  def stop(opts \\ []) do
    with {:ok, workspace} <- fetch_workspace(opts) do
      case call("daemon_stop", %{}, opts) do
        {:ok, payload} ->
          {:ok, payload}

        {:error, %{"ok" => false} = error} ->
          if fallback_allowed?(error) do
            {:ok, daemon_state_payload("stop", workspace, error)}
          else
            {:error, error}
          end
      end
    end
  end

  defp fetch_workspace(opts) do
    case Keyword.get(opts, :workspace) do
      workspace when is_binary(workspace) and workspace != "" ->
        {:ok, Path.expand(workspace)}

      nil ->
        {:error,
         error_payload("invalid_args", "workspace is required for Delegate daemon IPC", %{
           "next_actions" => ["run_from_a_workspace", "pass_workspace_to_daemon_client"]
         })}

      workspace ->
        {:error,
         error_payload("invalid_args", "workspace must be a string path", %{
           "observed" => inspect(workspace),
           "next_actions" => ["pass_workspace_to_daemon_client"]
         })}
    end
  end

  defp call_socket(socket, endpoint, action, body, workspace) do
    with :ok <- send_request(socket, endpoint, action, body, workspace),
         {:ok, response} <- recv_response(socket) do
      unwrap_response(response)
    end
  end

  defp follow_socket(socket, endpoint, action, body, workspace, emit_frame) do
    with :ok <- send_request(socket, endpoint, action, body, workspace) do
      recv_follow(socket, emit_frame)
    end
  end

  defp normalize_socket_result({:ok, payload}), do: {:ok, payload}

  defp normalize_socket_result({:error, %{"ok" => false} = error}, _workspace, _endpoint),
    do: {:error, error}

  defp normalize_socket_result({:error, reason}, _workspace, endpoint) do
    {:error,
     error_payload("daemon_unavailable", "Delegate daemon IPC failed after connecting", %{
       "reason" => inspect(reason),
       "endpoint_file" => endpoint["endpoint_file"],
       "fallback_allowed" => true,
       "stale_endpoint" => false,
       "next_actions" => ["retry_delegate_daemon_request", "inspect_delegate_daemon_status"]
     })}
  end

  defp normalize_socket_result(result, _workspace, _endpoint), do: normalize_socket_result(result)

  defp normalize_pre_connect_result({:error, %{"ok" => false} = error}, _workspace, _endpoint),
    do: {:error, error}

  defp normalize_pre_connect_result({:error, reason}, workspace, endpoint) do
    {:error,
     error_payload("daemon_unavailable", "Delegate daemon endpoint was stale or unreachable", %{
       "reason" => inspect(reason),
       "endpoint_file" => endpoint["endpoint_file"],
       "fallback_allowed" => true,
       "stale_endpoint" => true,
       "stale_endpoint_cleanup" => cleanup_stale_endpoint(workspace, endpoint),
       "next_actions" => ["restart_delegate_daemon"]
     })}
  end

  defp validate_workspace(%{"workspace" => endpoint_workspace}, workspace)
       when is_binary(endpoint_workspace) do
    if Path.expand(endpoint_workspace) == workspace do
      :ok
    else
      {:error,
       error_payload(
         "daemon_workspace_mismatch",
         "Delegate daemon endpoint is for another workspace",
         %{
           "endpoint_workspace" => Path.expand(endpoint_workspace),
           "requested_workspace" => workspace,
           "fallback_allowed" => false,
           "next_actions" => [
             "run_from_the_daemon_workspace",
             "start_a_daemon_for_this_workspace"
           ]
         }
       )}
    end
  end

  defp validate_workspace(_endpoint, _workspace), do: :ok

  defp connect(%{"host" => "127.0.0.1", "port" => port}) when is_integer(port) do
    :gen_tcp.connect(
      {127, 0, 0, 1},
      port,
      [:binary, packet: 4, active: false],
      @connect_timeout_ms
    )
  end

  defp connect(endpoint) do
    {:error,
     error_payload(
       "daemon_endpoint_invalid",
       "Delegate daemon endpoint has unsupported host/port",
       %{
         "endpoint" => Map.take(endpoint, ["host", "port", "endpoint_file"]),
         "fallback_allowed" => true,
         "next_actions" => ["delete_stale_endpoint", "restart_delegate_daemon"]
       }
     )}
  end

  defp send_request(socket, endpoint, action, body, workspace) do
    request = %{
      "token" => endpoint["token"],
      "workspace" => workspace,
      "action" => action,
      "body" => body
    }

    case Jason.encode(request) do
      {:ok, encoded} ->
        case :gen_tcp.send(socket, encoded) do
          :ok -> :ok
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error,
         error_payload(
           "daemon_protocol_error",
           "Delegate daemon request could not be encoded as JSON",
           %{
             "encode_error" => Exception.message(reason),
             "fallback_allowed" => false,
             "next_actions" => ["inspect_delegate_daemon_request"]
           }
         )}
    end
  end

  defp recv_response(socket) do
    with {:ok, raw} <- :gen_tcp.recv(socket, 0, @recv_timeout_ms),
         {:ok, response} <- Jason.decode(raw) do
      {:ok, response}
    else
      {:error, %Jason.DecodeError{} = error} ->
        {:error,
         error_payload("daemon_protocol_error", "Delegate daemon response was invalid JSON", %{
           "decode_error" => Exception.message(error),
           "fallback_allowed" => true,
           "next_actions" => ["restart_delegate_daemon"]
         })}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp recv_follow(socket, emit_frame) do
    with {:ok, response} <- recv_response(socket) do
      unwrap_follow_response(response, socket, emit_frame)
    end
  end

  defp unwrap_response(%{"ipc_ok" => true, "payload" => payload}) when is_map(payload),
    do: {:ok, payload}

  defp unwrap_response(%{"ipc_ok" => false, "error" => %{"ok" => false} = error}),
    do: {:error, error}

  defp unwrap_response(response) do
    {:error,
     error_payload("daemon_protocol_error", "Delegate daemon response has an invalid shape", %{
       "response_shape" => response_shape(response),
       "fallback_allowed" => true,
       "next_actions" => ["restart_delegate_daemon"]
     })}
  end

  defp unwrap_follow_response(%{"ipc_frame" => true, "frame" => frame}, socket, emit_frame)
       when is_map(frame) do
    emit_frame.(frame)
    recv_follow(socket, emit_frame)
  end

  defp unwrap_follow_response(%{"ipc_frame" => true} = response, _socket, _emit_frame) do
    {:error,
     error_payload(
       "daemon_protocol_error",
       "Delegate daemon follow frame has an invalid shape",
       %{
         "response_shape" => response_shape(response),
         "fallback_allowed" => true,
         "next_actions" => ["restart_delegate_daemon"]
       }
     )}
  end

  defp unwrap_follow_response(response, _socket, _emit_frame), do: unwrap_response(response)

  defp response_shape(%{} = map) do
    %{
      "type" => "map",
      "keys" => map |> Map.keys() |> Enum.map(&to_string/1) |> Enum.sort()
    }
  end

  defp response_shape(list) when is_list(list), do: %{"type" => "list", "length" => length(list)}
  defp response_shape(value), do: %{"type" => inspect_type(value)}

  defp inspect_type(value) when is_binary(value), do: "string"
  defp inspect_type(value) when is_boolean(value), do: "boolean"
  defp inspect_type(value) when is_integer(value), do: "integer"
  defp inspect_type(value) when is_float(value), do: "float"
  defp inspect_type(nil), do: "nil"
  defp inspect_type(_value), do: "other"

  defp close(socket) do
    _ = :gen_tcp.close(socket)
    :ok
  end

  defp daemon_state_payload(action, workspace, error) do
    state = daemon_state_from_error(error)

    %{
      "ok" => state in ["absent", "stale_endpoint"],
      "status" => state,
      "kind" => "delegate_daemon",
      "workspace" => workspace,
      "summary" => daemon_state_summary(action, state),
      "daemon" => %{
        "state" => state,
        "reachable" => false,
        "endpoint_file" => get_in(error, ["details", "endpoint_file"])
      },
      "details" => %{
        "action" => action,
        "daemon_error" => error,
        "fallback_allowed" => fallback_allowed?(error)
      },
      "next_actions" => daemon_state_next_actions(action, state, error)
    }
  end

  defp daemon_state_from_error(%{"kind" => "daemon_unavailable", "details" => details})
       when is_map(details) do
    cond do
      details["stale_endpoint"] == true -> "stale_endpoint"
      details["stale_endpoint"] == false -> "unavailable"
      is_binary(details["endpoint_file"]) -> "absent"
      true -> "unavailable"
    end
  end

  defp daemon_state_from_error(%{"kind" => "daemon_endpoint_invalid"}), do: "invalid_endpoint"
  defp daemon_state_from_error(%{"kind" => "daemon_workspace_mismatch"}), do: "workspace_mismatch"
  defp daemon_state_from_error(%{"kind" => "daemon_auth_failed"}), do: "auth_failed"
  defp daemon_state_from_error(_error), do: "unavailable"

  defp daemon_state_summary("stop", "absent"),
    do: "No Delegate daemon endpoint was present; nothing needed to be stopped."

  defp daemon_state_summary("stop", "stale_endpoint"),
    do: "Stale Delegate daemon endpoint was cleaned up; no live daemon was stopped."

  defp daemon_state_summary(_action, "absent"),
    do: "Delegate daemon is absent for this workspace."

  defp daemon_state_summary(_action, "stale_endpoint"),
    do: "Delegate daemon endpoint was stale and is not reachable."

  defp daemon_state_summary(_action, "invalid_endpoint"),
    do: "Delegate daemon endpoint exists but has an invalid shape."

  defp daemon_state_summary(_action, "workspace_mismatch"),
    do: "Delegate daemon endpoint belongs to another workspace."

  defp daemon_state_summary(_action, "auth_failed"),
    do: "Delegate daemon endpoint was reachable but authentication failed."

  defp daemon_state_summary(_action, _state), do: "Delegate daemon was not reachable."

  defp daemon_state_next_actions("stop", "absent", _error),
    do: ["start_delegate_daemon_when_needed"]

  defp daemon_state_next_actions("stop", "stale_endpoint", _error),
    do: ["restart_delegate_daemon_when_needed"]

  defp daemon_state_next_actions(_action, "absent", _error),
    do: ["start_pixir_delegate_daemon_--foreground_--json"]

  defp daemon_state_next_actions(_action, "stale_endpoint", _error),
    do: ["restart_delegate_daemon"]

  defp daemon_state_next_actions(_action, _state, error),
    do: get_in(error, ["details", "next_actions"]) || ["inspect_delegate_daemon"]

  defp cleanup_stale_endpoint(workspace, endpoint) do
    case DaemonEndpoint.delete_if_owner(workspace, endpoint) do
      {:ok, status} ->
        %{"status" => to_string(status)}

      {:error, %{"ok" => false} = error} ->
        %{
          "status" => "failed",
          "error" => Map.take(error, ["kind", "message", "details"])
        }
    end
  end

  defp fallback_allowed?(%{"details" => %{"fallback_allowed" => allowed}}), do: allowed == true
  defp fallback_allowed?(_error), do: false

  defp error_payload(kind, message, details) do
    %{
      "ok" => false,
      "status" => "rejected",
      "kind" => kind,
      "message" => message,
      "details" => details
    }
  end
end
