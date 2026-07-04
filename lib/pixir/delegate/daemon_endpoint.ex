defmodule Pixir.Delegate.DaemonEndpoint do
  @moduledoc """
  Workspace-local endpoint metadata for the Delegate daemon.

  The endpoint file is live capability metadata, not durable truth. It lets a
  short-lived `pixir delegate` client discover a manually started local daemon for the
  same workspace. The append-only Session Log remains authoritative for Delegate work;
  this file only describes how to reach the resident owner runtime while it is alive.
  """

  @relative_path [".pixir", "delegate", "daemon.json"]
  @owner_keys ["token", "port", "pid", "started_at"]

  @doc "Return the workspace-local daemon endpoint file path."
  @spec path(String.t()) :: {:ok, String.t()} | {:error, map()}
  def path(workspace) when is_binary(workspace),
    do: {:ok, Path.join([Path.expand(workspace) | @relative_path])}

  def path(_workspace),
    do:
      {:error,
       error_payload("invalid_args", "workspace must be a string path", %{
         "next_actions" => ["provide_workspace_path"]
       })}

  @doc "Write endpoint metadata with owner-only permissions when supported."
  @spec write(String.t(), map()) :: {:ok, String.t()} | {:error, map()}
  def write(workspace, endpoint) when is_binary(workspace) and is_map(endpoint) do
    with {:ok, path} <- path(workspace),
         :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(path, Jason.encode!(endpoint, pretty: true)),
         :ok <- chmod_private(path) do
      {:ok, path}
    else
      {:error, reason} ->
        {:error,
         error_payload(
           "daemon_endpoint_write_failed",
           "could not write Delegate daemon endpoint",
           %{
             "workspace" => workspace,
             "reason" => inspect(reason),
             "next_actions" => ["check_workspace_permissions", "restart_delegate_daemon"]
           }
         )}
    end
  end

  @doc "Read workspace-local endpoint metadata."
  @spec read(String.t()) :: {:ok, map()} | {:error, map()}
  def read(workspace) when is_binary(workspace) do
    {:ok, path} = path(workspace)

    with {:ok, raw} <- File.read(path),
         {:ok, endpoint} <- Jason.decode(raw),
         :ok <- validate_endpoint(endpoint) do
      {:ok, Map.put(endpoint, "endpoint_file", path)}
    else
      {:error, :enoent} ->
        {:error,
         error_payload("daemon_unavailable", "Delegate daemon endpoint was not found", %{
           "endpoint_file" => path,
           "fallback_allowed" => true,
           "next_actions" => [
             "start_pixir_delegate_daemon_for_delegate_start",
             "use_status_or_attach_snapshot_fallback_when_observing_existing_delegate"
           ]
         })}

      {:error, %Jason.DecodeError{} = error} ->
        {:error,
         error_payload(
           "daemon_endpoint_invalid",
           "Delegate daemon endpoint is not valid JSON",
           %{
             "endpoint_file" => path,
             "decode_error" => Exception.message(error),
             "fallback_allowed" => true,
             "next_actions" => ["delete_stale_endpoint", "restart_delegate_daemon"]
           }
         )}

      {:error, %{"ok" => false} = error} ->
        {:error, error}

      {:error, reason} ->
        {:error,
         error_payload("daemon_unavailable", "Delegate daemon endpoint could not be read", %{
           "endpoint_file" => path,
           "reason" => inspect(reason),
           "fallback_allowed" => true,
           "next_actions" => ["check_workspace_permissions", "restart_delegate_daemon"]
         })}
    end
  end

  @doc "Delete endpoint metadata if present."
  @spec delete(String.t()) :: {:ok, :deleted | :missing} | {:error, map()}
  def delete(workspace) when is_binary(workspace) do
    with {:ok, path} <- path(workspace) do
      case File.rm(path) do
        :ok -> {:ok, :deleted}
        {:error, :enoent} -> {:ok, :missing}
        {:error, reason} -> endpoint_delete_error(path, reason)
      end
    end
  end

  @doc "Delete endpoint metadata only when it still belongs to the given endpoint."
  @spec delete_if_owner(String.t(), map()) ::
          {:ok, :deleted | :missing | :skipped} | {:error, map()}
  def delete_if_owner(workspace, endpoint) when is_binary(workspace) and is_map(endpoint) do
    with {:ok, path} <- path(workspace) do
      case File.read(path) do
        {:ok, raw} ->
          with {:ok, current} <- Jason.decode(raw) do
            if same_owner?(current, endpoint) do
              case File.rm(path) do
                :ok -> {:ok, :deleted}
                {:error, :enoent} -> {:ok, :missing}
                {:error, reason} -> endpoint_delete_error(path, reason)
              end
            else
              {:ok, :skipped}
            end
          else
            {:error, _error} -> {:ok, :skipped}
          end

        {:error, :enoent} ->
          {:ok, :missing}

        {:error, reason} ->
          endpoint_delete_error(path, reason)
      end
    end
  end

  defp validate_endpoint(%{
         "host" => host,
         "port" => port,
         "token" => token,
         "workspace" => workspace
       })
       when is_binary(host) and is_integer(port) and port > 0 and is_binary(token) and
              is_binary(workspace),
       do: :ok

  defp validate_endpoint(endpoint) do
    {:error,
     error_payload("daemon_endpoint_invalid", "Delegate daemon endpoint has an invalid shape", %{
       "endpoint" => inspect(redact_endpoint(endpoint)),
       "fallback_allowed" => true,
       "next_actions" => ["delete_stale_endpoint", "restart_delegate_daemon"]
     })}
  end

  defp same_owner?(current, endpoint) do
    Enum.all?(@owner_keys, fn key ->
      owner_value?(current, key) and owner_value?(endpoint, key) and current[key] == endpoint[key]
    end)
  end

  defp owner_value?(map, key), do: Map.has_key?(map, key) and not is_nil(map[key])

  defp redact_endpoint(endpoint) when is_map(endpoint),
    do: Map.replace(endpoint, "token", "[REDACTED]")

  defp redact_endpoint(endpoint), do: endpoint

  defp endpoint_delete_error(path, reason) do
    {:error,
     error_payload(
       "daemon_endpoint_delete_failed",
       "could not delete Delegate daemon endpoint",
       %{
         "path" => path,
         "reason" => inspect(reason),
         "next_actions" => ["check_workspace_permissions", "delete_stale_endpoint_manually"]
       }
     )}
  end

  defp chmod_private(path) do
    case File.chmod(path, 0o600) do
      :ok -> :ok
      {:error, :einval} -> :ok
      {:error, :enotsup} -> :ok
      {:error, reason} -> {:error, reason}
    end
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
end
