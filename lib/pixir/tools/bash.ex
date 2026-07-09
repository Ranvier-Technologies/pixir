defmodule Pixir.Tools.Bash do
  @moduledoc """
  Run a shell command with the Workspace as the working directory.

  Before crossing into host process execution, `execute/2` acquires a bounded
  host-command lease from `Pixir.Tools.CommandBoundary` (ADR 0027). This keeps OS
  process fanout separate from BEAM-local Subagent/Workflow fanout.

  Runs via a `Port` so a hung command can be **killed on timeout** (closing the port
  terminates the spawned process — no orphan), unlike a blocking `System.cmd/3`. The
  timeout is an open knob: `context.bash_timeout_ms` or `config :pixir, :bash_timeout_ms`
  (default 120s), capped by `bash_timeout_max_ms` (default 600s). Host-command
  concurrency and queueing use `host_commands` config.

  v0.1 safety confines the cwd and rejects shell tokens that visibly resolve outside
  the workspace — parent-directory references, absolute paths, home/env-home paths, and
  existing symlink-prefix escapes — before crossing the host boundary. Only RHS values
  of leading POSIX environment assignments before a simple command are ignored; literal
  path arguments, redirection targets, and non-leading `NAME=VALUE` values are still
  checked. The accepted residual vector `VAR=/outside cmd $VAR` can expand at runtime,
  because this is a conservative tripwire, not a full shell parser or sandbox. The
  permission gate (ADR 0006) is still the higher-level guard: under `:ask`, non-safe
  commands prompt; under `:read_only` they are refused.
  """

  use Pixir.Tool

  alias Pixir.{Config, Permissions, Tool}
  alias Pixir.Tools.CommandBoundary

  @impl Pixir.Tool
  def __tool__ do
    %{
      name: "bash",
      description: "Run a shell command (bash -c) with the workspace as the working directory.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "command" => %{"type" => "string", "description" => "The shell command to run"}
        },
        "required" => ["command"]
      }
    }
  end

  @impl Pixir.Tool
  def execute(%{"command" => command}, context) do
    timeout = timeout_info(context)

    with :ok <- reject_outside_workspace_references(command, context.workspace) do
      case CommandBoundary.with_slot("bash", boundary_opts(context), fn lease ->
             {run(command, context.workspace, timeout.effective_ms), lease.host_command}
           end) do
        {{:done, output, exit_code}, host_command} ->
          {:ok,
           %{
             "output" => Tool.truncate(output),
             "exit_code" => exit_code,
             "ok" => exit_code == 0,
             "timeout" => timeout_metadata(timeout),
             "host_command" => host_command
           }}

        {{:timeout, partial}, host_command} ->
          {:error,
           Tool.error(
             :timeout,
             "command timed out after #{div(timeout.effective_ms, 1000)}s and was killed",
             %{
               "host_command" => host_command,
               "seconds" => div(timeout.effective_ms, 1000),
               "timeout" => timeout_metadata(timeout),
               "partial_output" => Tool.truncate(partial)
             }
           )}

        {:error, %{error: %{kind: _kind}}} = error ->
          error
      end
    end
  rescue
    e ->
      {:error,
       Tool.error(:command_failed, "could not run command", %{reason: Exception.message(e)})}
  end

  @impl Pixir.Tool
  def dry_run(%{"command" => command}, _context) do
    {:ok, %{"dry_run" => true, "would" => "run", "command" => command}}
  end

  # ── internals ─────────────────────────────────────────────────────────────

  defp run(command, workspace, timeout) do
    port =
      Port.open(
        {:spawn_executable, bash()},
        [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          :hide,
          {:args, ["-c", command]},
          {:cd, workspace}
        ]
      )

    collect(port, "", timeout)
  end

  defp collect(port, acc, timeout) do
    receive do
      {^port, {:data, data}} -> collect(port, acc <> data, timeout)
      {^port, {:exit_status, code}} -> {:done, acc, code}
    after
      timeout ->
        # Closing the port terminates the spawned OS process (no orphan).
        if Port.info(port), do: Port.close(port)
        {:timeout, acc}
    end
  end

  defp bash, do: System.find_executable("bash") || "/bin/bash"

  defp reject_outside_workspace_references(command, workspace) do
    case Permissions.outside_workspace_shell_token(command, workspace) do
      {:ok, nil} ->
        :ok

      {:ok, token} ->
        {:error,
         Tool.error(
           :outside_workspace,
           "bash command references a path outside the workspace",
           %{
             "tool" => "bash",
             "token" => token,
             "requested_command" => command,
             "matched_rule" => "outside_workspace",
             "next_actions" => [
               "use_workspace_relative_paths",
               "use_pixir_read_tool_for_file_access",
               "run_pixir_from_the_intended_workspace_root"
             ]
           }
         )}
    end
  end

  defp timeout_info(context) do
    requested = positive_timeout(Map.get(context, :bash_timeout_ms))

    source = if requested, do: Map.get(context, :bash_timeout_source) || "context", else: "config"

    config = Config.load()["effective"]
    configured = requested || config["bash_timeout_ms"]
    cap = config["bash_timeout_max_ms"]
    effective = min(configured, cap)

    %{
      requested_ms: requested,
      configured_ms: configured,
      effective_ms: effective,
      max_ms: cap,
      source: source,
      capped?: effective != configured
    }
  end

  defp positive_timeout(value) when is_integer(value) and value > 0, do: value
  defp positive_timeout(_value), do: nil

  defp timeout_metadata(timeout) do
    %{
      "requested_ms" => timeout.requested_ms,
      "configured_ms" => timeout.configured_ms,
      "effective_ms" => timeout.effective_ms,
      "max_ms" => timeout.max_ms,
      "source" => timeout.source,
      "capped" => timeout.capped?
    }
  end

  defp boundary_opts(context) do
    [
      boundary:
        Map.get(context, :host_command_boundary) ||
          Map.get(context, :command_boundary) ||
          CommandBoundary,
      limits: Map.get(context, :host_command_limits)
    ]
  end
end
