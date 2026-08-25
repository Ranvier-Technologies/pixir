defmodule Pixir.Tools.Bash do
  @moduledoc """
  Run a shell command with the Workspace as the working directory.

  Before crossing into host process execution, `execute/2` acquires a bounded
  host-command lease from `Pixir.Tools.CommandBoundary` (ADR 0027). This keeps OS
  process fanout separate from BEAM-local Subagent/Workflow fanout.

  Runs via a `Port` so a hung command can be **killed on timeout**. A portable
  Perl wrapper makes the spawned OS pid a process-group leader before it execs
  `bash`; Pixir then signals the whole group with SIGTERM and escalates it to
  SIGKILL after a short grace period before closing the port. An unlinked reaper
  monitors the collecting process and performs the same group cleanup if that
  process is brutally killed before it can return. A final direct-child sweep is
  belt-and-suspenders cleanup. Pending port messages are drained after close so
  repeated timeouts do not dirty the caller mailbox. Deliberately double-forked
  daemons that leave the process group are a residual out of scope.
  The timeout is an open knob: an agent-supplied `timeout_ms` replaces
  `context.bash_timeout_ms` or `config :pixir, :bash_timeout_ms` (default 120s),
  but is always capped by `bash_timeout_max_ms` (default 600s). Host-command
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
          "command" => %{"type" => "string", "description" => "The shell command to run"},
          "timeout_ms" => %{
            "type" => "integer",
            "minimum" => 1,
            "description" =>
              "Kill the command after this many milliseconds. Default 120000; requests are clamped to the operator's bash_timeout_max_ms (600000 unless configured). Raise it for legitimately long commands like test suites or installs."
          }
        },
        "required" => ["command"]
      }
    }
  end

  @impl Pixir.Tool
  def execute(%{"command" => command} = args, context) do
    with {:ok, timeout} <- timeout_info(args, context),
         :ok <- reject_outside_workspace_references(command, context.workspace),
         {:ok, perl} <- perl_executable(context) do
      case CommandBoundary.with_slot("bash", boundary_opts(context), fn lease ->
             {run(command, context.workspace, timeout.effective_ms, perl), lease.host_command}
           end) do
        {{:done, output, exit_code}, host_command} ->
          {:ok,
           %{
             "output" => Tool.truncate(output),
             "exit_code" => exit_code,
             "ok" => exit_code == 0,
             "timeout" => success_timeout_metadata(timeout),
             "host_command" => host_command
           }}

        {{:timeout, partial, os_pid, kill_escalation}, host_command} ->
          {:error,
           Tool.error(
             :timeout,
             "command timed out after #{timeout.effective_ms}ms and was killed",
             %{
               "host_command" => host_command,
               "milliseconds" => timeout.effective_ms,
               "timeout" => timeout_metadata(timeout, os_pid, kill_escalation),
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
  def dry_run(%{"command" => command} = args, _context) do
    with :ok <- validate_agent_timeout(args) do
      {:ok, %{"dry_run" => true, "would" => "run", "command" => command}}
    end
  end

  # ── internals ─────────────────────────────────────────────────────────────

  defp run(command, workspace, timeout, perl) do
    port =
      Port.open(
        {:spawn_executable, perl},
        [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          :hide,
          {:args, ["-e", process_group_wrapper(), "--", bash(), command]},
          {:cd, workspace}
        ]
      )

    os_pid =
      case Port.info(port, :os_pid) do
        {:os_pid, pid} -> pid
        nil -> nil
      end

    reaper = start_reaper(self(), os_pid)
    result = collect(port, "", timeout, os_pid)
    cancel_reaper(reaper)
    result
  end

  defp collect(port, acc, timeout, os_pid) do
    receive do
      {^port, {:data, data}} -> collect(port, acc <> data, timeout, os_pid)
      {^port, {:exit_status, code}} -> {:done, acc, code}
    after
      timeout ->
        kill_escalation = terminate_process_group(os_pid)
        close_port(port)
        drain_port_messages(port)
        {:timeout, acc, os_pid, kill_escalation}
    end
  end

  defp terminate_process_group(os_pid) when is_integer(os_pid) do
    # The "--" separator is load-bearing: BSD kill accepts the bare negative
    # form, while procps-ng 4.x misparses it (exiting 1 refusing delivery, or
    # 0 without delivering, depending on version). BusyBox kill misparses the
    # "--" itself, which breaks the alive-check there instead (#594).
    group = "-#{os_pid}"
    best_effort_signal("kill", ["-TERM", "--", group])
    Process.sleep(200)

    escalation =
      if os_process_group_alive?(os_pid) do
        best_effort_signal("kill", ["-KILL", "--", group])
        "sigkill"
      else
        "sigterm"
      end

    best_effort_signal("pkill", ["-KILL", "-P", Integer.to_string(os_pid)])
    escalation
  end

  defp terminate_process_group(nil), do: "sigterm"

  defp start_reaper(owner, os_pid) do
    spawn(fn ->
      monitor = Process.monitor(owner)

      receive do
        {:cancel, from, ref} ->
          Process.demonitor(monitor, [:flush])
          send(from, {ref, :reaper_cancelled})

        {:DOWN, ^monitor, :process, ^owner, _reason} ->
          terminate_process_group(os_pid)
      end
    end)
  end

  defp cancel_reaper(reaper) do
    ref = make_ref()
    send(reaper, {:cancel, self(), ref})

    receive do
      {^ref, :reaper_cancelled} -> :ok
    after
      1_000 ->
        Process.exit(reaper, :kill)
        :ok
    end
  end

  defp best_effort_signal(command, args) do
    case System.find_executable(command) do
      nil -> :ok
      executable -> System.cmd(executable, args, stderr_to_stdout: true)
    end

    :ok
  rescue
    _error -> :ok
  catch
    _kind, _reason -> :ok
  end

  defp os_process_group_alive?(os_pid) do
    case System.find_executable("kill") do
      nil ->
        false

      executable ->
        match?(
          {_output, 0},
          System.cmd(executable, ["-0", "--", "-#{os_pid}"], stderr_to_stdout: true)
        )
    end
  rescue
    _error -> false
  catch
    _kind, _reason -> false
  end

  defp port_open?(port), do: Port.info(port) != nil

  defp close_port(port) do
    if port_open?(port), do: Port.close(port)
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp drain_port_messages(port) do
    receive do
      {^port, {:exit_status, _code}} -> drain_port_messages(port)
      {^port, {:data, _data}} -> drain_port_messages(port)
    after
      0 -> :ok
    end
  end

  defp perl_executable(context) do
    resolver = Map.get(context, :bash_executable_resolver, &System.find_executable/1)

    case resolver.("perl") do
      path when is_binary(path) and path != "" ->
        if File.regular?(path), do: {:ok, path}, else: missing_perl_error()

      _missing ->
        missing_perl_error()
    end
  rescue
    _error -> missing_perl_error()
  end

  defp missing_perl_error do
    {:error,
     Tool.error(:command_failed, "required bash dependency is unavailable", %{
       "dependency" => "perl",
       "required_for" => "process-group kill",
       "next_actions" => [
         "install perl and ensure it is available on PATH",
         "ask the operator to restore the perl executable"
       ]
     })}
  end

  defp process_group_wrapper do
    "my ($bash, $command) = @ARGV; setpgrp(0, 0); " <>
      "getpgrp(0) == $$ or die \"setpgrp failed: $!\"; " <>
      "exec {$bash} $bash, '-c', $command; die \"exec failed: $!\";"
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

  defp timeout_info(args, context) do
    with :ok <- validate_agent_timeout(args) do
      config = Config.load()["effective"]
      cap = config["bash_timeout_max_ms"]
      context_requested = positive_timeout(Map.get(context, :bash_timeout_ms))

      case Map.fetch(args, "timeout_ms") do
        {:ok, requested} ->
          effective = min(requested, cap)

          {:ok,
           %{
             agent_supplied?: true,
             requested_ms: requested,
             legacy_requested_ms: requested,
             configured_ms: requested,
             effective_ms: effective,
             max_ms: cap,
             source: "model",
             capped?: effective != requested,
             clamped?: effective != requested
           }}

        :error ->
          source =
            if context_requested,
              do: Map.get(context, :bash_timeout_source) || "context",
              else: "config"

          configured = context_requested || config["bash_timeout_ms"]
          effective = min(configured, cap)

          {:ok,
           %{
             agent_supplied?: false,
             requested_ms: nil,
             legacy_requested_ms: context_requested,
             configured_ms: configured,
             effective_ms: effective,
             max_ms: cap,
             source: source,
             capped?: effective != configured,
             clamped?: effective != configured
           }}
      end
    end
  end

  defp validate_agent_timeout(args) do
    case Map.fetch(args, "timeout_ms") do
      :error ->
        :ok

      {:ok, value} when is_integer(value) and value > 0 ->
        :ok

      {:ok, value} ->
        {:error,
         Tool.error(:invalid_args, "timeout_ms must be a positive integer", %{
           "field" => "timeout_ms",
           "received" => inspect(value)
         })}
    end
  end

  defp positive_timeout(value) when is_integer(value) and value > 0, do: value
  defp positive_timeout(_value), do: nil

  defp success_timeout_metadata(%{agent_supplied?: false} = timeout) do
    %{
      "requested_ms" => timeout.legacy_requested_ms,
      "configured_ms" => timeout.configured_ms,
      "effective_ms" => timeout.effective_ms,
      "max_ms" => timeout.max_ms,
      "source" => timeout.source,
      "capped" => timeout.capped?
    }
  end

  defp success_timeout_metadata(timeout) do
    timeout
    |> success_timeout_metadata_without_agent_flag()
    |> Map.put("clamped", timeout.clamped?)
  end

  defp success_timeout_metadata_without_agent_flag(timeout) do
    %{
      "requested_ms" => timeout.requested_ms,
      "configured_ms" => timeout.configured_ms,
      "effective_ms" => timeout.effective_ms,
      "max_ms" => timeout.max_ms,
      "source" => timeout.source,
      "capped" => timeout.capped?
    }
  end

  defp timeout_metadata(timeout, os_pid, kill_escalation) do
    timeout
    |> success_timeout_metadata_without_agent_flag()
    |> Map.merge(%{
      "clamped" => timeout.clamped?,
      "os_pid" => os_pid,
      "kill_escalation" => kill_escalation
    })
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
