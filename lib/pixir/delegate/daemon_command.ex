defmodule Pixir.Delegate.DaemonCommand do
  @moduledoc """
  CLI-facing command helpers for the manual Delegate daemon.

  The foreground command has a slightly different lifecycle from normal Delegate
  commands: it must print startup evidence and then keep the BEAM runtime alive. To keep
  `Pixir.CLI` rendering disciplined, this module returns a payload map that may include
  an internal `:after_render` callback. The public return shape still follows the
  project contract: `{:ok, term} | {:error, term}`.
  """

  alias Pixir.Delegate.{DaemonClient, DaemonServer}

  @doc "Start, inspect, or stop the workspace-local Delegate daemon."
  @spec run(String.t(), keyword()) :: {:ok, map()} | {:error, map()}
  def run("foreground", opts) do
    with {:ok, workspace} <- fetch_workspace(opts) do
      server = Keyword.get(opts, :server, DaemonServer)

      case server.start_link(workspace: workspace) do
        {:ok, pid} ->
          with {:ok, payload} <- server.started_payload(pid) do
            {:ok, Map.put(payload, :after_render, fn -> server.await_stop(pid) end)}
          end

        {:error, {:shutdown, %{"ok" => false} = error}} ->
          {:error, error}

        {:error, reason} ->
          {:error,
           error_payload("daemon_start_failed", "Delegate daemon could not be started", %{
             "reason" => inspect(reason),
             "next_actions" => ["retry_delegate_daemon", "inspect_workspace_permissions"]
           })}
      end
    end
  end

  def run("status", opts) do
    with {:ok, workspace} <- fetch_workspace(opts) do
      client = Keyword.get(opts, :client, DaemonClient)
      client.status(workspace: workspace)
    end
  end

  def run("stop", opts) do
    with {:ok, workspace} <- fetch_workspace(opts) do
      client = Keyword.get(opts, :client, DaemonClient)
      client.stop(workspace: workspace)
    end
  end

  def run(action, _opts) do
    {:error,
     error_payload("invalid_args", "delegate daemon action is unsupported", %{
       "action" => action,
       "accepted_actions" => ["foreground", "status", "stop"],
       "usage" => "pixir delegate daemon --foreground|--status|--stop [--json]"
     })}
  end

  defp fetch_workspace(opts) do
    case Keyword.get(opts, :workspace) do
      workspace when is_binary(workspace) and workspace != "" ->
        {:ok, Path.expand(workspace)}

      nil ->
        {:error,
         error_payload("invalid_args", "workspace is required for Delegate daemon command", %{
           "next_actions" => ["run_from_a_workspace"]
         })}

      workspace ->
        {:error,
         error_payload("invalid_args", "workspace must be a string path", %{
           "observed" => inspect(workspace),
           "next_actions" => ["run_from_a_workspace"]
         })}
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
