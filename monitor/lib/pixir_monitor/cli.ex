defmodule PixirMonitor.CLI do
  @moduledoc """
  Operator CLI for planning, self-checking, or starting the local monitor.

  Commands are `serve` (optionally `--dry-run`), `self-check`, and `--help`;
  `serve` and `self-check` accept a `--json` variant, help output is always plain
  text. Serve defaults to the existing Darwin browser launch. The explicit
  `--launch-mode fifo` alternative creates and announces a private named pipe,
  waits boundedly for an external reader, and issues the one-use capability only
  after that reader has connected. The projection workspace is resolved at
  invocation time with pinned precedence (`--workspace`, then runtime config,
  then the invocation working directory), validated as an existing readable
  directory, and never baked in at build time — see `resolve_workspace/1`.

  The launch handoff is auxiliary, never a serving precondition: `serve` reaches and
  keeps its serving state whatever the handoff does, and `PixirMonitor.LaunchSurface`
  degrades and re-arms beside it. Only application load, workspace resolution, and
  application start (which owns port binding) still exit nonzero.

  Dry-run output is bounded and capability-free. Real serve passes launch material only
  through the in-memory runtime handoff and never prints it. FIFO readiness contains
  only the non-secret pipe path and is emitted on stderr — once per arm, so the newest
  readiness frame always names the currently valid pipe — leaving stdout's serving
  contract as a single line, now carrying a bounded `launch` outcome field. Errors are
  structured as `kind`, `message`, `details`, and `next_actions`; JSON error output
  carries all four fields, while human-readable error output prints `kind` and
  `message` only.
  """

  # Strictly above the 5_000 ms bounded launcher in PixirMonitor.Runtime, whose
  # reap path can add a further System.cmd, so a slow-but-healthy darwin launch
  # is reported as its real outcome instead of launch_surface_unavailable.
  @launch_outcome_timeout_ms 30_000

  @help """
  pixir-monitor — loopback-only read-only Pixir presenter

  Usage:
    pixir-monitor serve [--workspace PATH] [--dry-run] [--json] [--launch-mode darwin|fifo]
    pixir-monitor serve --workspace KEY=PATH --workspace KEY=PATH [...] [--dry-run] [--json]
    pixir-monitor serve --help
    pixir-monitor self-check [--json]
    pixir-monitor --help

  Options:
    --launch-mode MODE  Launch handoff mode. Default: darwin (macOS automatic
                        browser launch). Use fifo for a portable, bounded external
                        reader handoff on systems with named-pipe support.

                        A launch handoff never gates serving. In fifo mode a late
                        reader, a closed reader, or an expired reader window emits
                        one launch_degraded frame and the monitor re-arms a fresh
                        FIFO, announcing the new path in a readiness frame; a
                        supervisor should key on the newest readiness frame
                        (event launch_ready, status ready) for the currently valid
                        fifo_path. Re-arm is bounded; on exhaustion the monitor
                        emits launch_surface_exhausted and keeps serving without a
                        FIFO. In darwin mode the launcher outcome is reported in
                        the serving frame's launch field, and SIGUSR2 re-enters:
                        it mints a fresh one-use capability and launches again
                        without restarting the monitor.
    --workspace VALUE   One plain PATH keeps single-workspace mode. From 2 to 8
                        KEY=PATH declarations enter Workspace Overview mode;
                        keys use [A-Za-z0-9][A-Za-z0-9_-]* and declaration order
                        is preserved. A 9th declaration is a serve-time error,
                        never a truncation. No discovery or browser path
                        selection.
                        Resolution precedence: --workspace, then runtime config
                        (:pixir_monitor, :projection_source, :workspace), then the
                        current working directory of this serve invocation.
                        The workspace is never baked in at build time.
  """

  def main(args) do
    case run(args) do
      {:ok, 0} = result -> result
      {_tag, status} -> System.halt(status)
    end
  end

  @doc false
  def run(args) do
    case parse(args) do
      :help ->
        IO.write(@help)
        {:ok, 0}

      {:dry_run, json?, workspace_arg, launch_mode} ->
        dry_run(json?, workspace_arg, launch_mode)

      {:serve, json?, workspace_arg, launch_mode} ->
        serve(json?, workspace_arg, launch_mode)

      {:self_check, json?} ->
        self_check(json?)

      {:error, error, json?} ->
        emit_error(error, json?)
        {:error, 1}
    end
  end

  defp parse([arg]) when arg in ["--help", "-h", "help"], do: :help

  defp parse(["serve" | rest]) do
    if Enum.any?(rest, &(&1 in ["--help", "-h"])) do
      :help
    else
      case OptionParser.parse(rest,
             strict: [dry_run: :boolean, json: :boolean, workspace: :keep, launch_mode: :string]
           ) do
        {opts, [], []} ->
          json? = Keyword.get(opts, :json, false)
          workspaces = Keyword.get_values(opts, :workspace)
          workspace = if workspaces == [], do: nil, else: workspaces
          launch_mode = Keyword.get(opts, :launch_mode, "darwin")

          if launch_mode in ["darwin", "fifo"] do
            if Keyword.get(opts, :dry_run, false),
              do: {:dry_run, json?, workspace, launch_mode},
              else: {:serve, json?, workspace, launch_mode}
          else
            unsupported_launch_mode(launch_mode, json?)
          end

        {_opts, rest_args, invalid} ->
          invalid_arguments(Enum.map(invalid, fn {flag, _} -> flag end) ++ rest_args, "--json" in rest)
      end
    end
  end

  defp parse(["self-check"]), do: {:self_check, false}
  defp parse(["self-check", "--json"]), do: {:self_check, true}

  defp parse(args), do: invalid_arguments(args, "--json" in args)

  defp invalid_arguments(args, json?) do
    {:error, %{kind: "invalid_arguments", message: "Unsupported arguments", details: %{arguments: Enum.take(args, 16)}, next_actions: ["Run pixir-monitor --help"]}, json?}
  end

  defp unsupported_launch_mode(mode, json?) do
    {:error,
     %{
       kind: "unsupported_launch_mode",
       message: "Unsupported launch mode",
       details: %{launch_mode: String.slice(mode, 0, 64), supported: ["darwin", "fifo"]},
       next_actions: ["Use --launch-mode darwin or --launch-mode fifo"]
     }, json?}
  end

  @doc """
  Resolves the projection workspace at invocation time.

  Precedence: explicit CLI `--workspace`, then runtime config
  (`:pixir_monitor, :projection_source, :workspace`), then the invocation-time
  current working directory. The result is canonical (absolute, expanded) and
  validated to be an existing readable directory.
  """
  def resolve_workspace(cli_workspace) do
    configured = Application.get_env(:pixir_monitor, :projection_source, [])[:workspace]

    {path, origin} =
      cond do
        is_binary(cli_workspace) -> {cli_workspace, "cli"}
        is_binary(configured) -> {configured, "runtime_config"}
        true -> {File.cwd!(), "invocation_cwd"}
      end

    expanded = Path.expand(path)

    case File.stat(expanded) do
      {:ok, %File.Stat{type: :directory, access: access}} when access in [:read, :read_write] ->
        case File.ls(expanded) do
          {:ok, _entries} ->
            {:ok, %{path: expanded, origin: origin}}

          {:error, reason} ->
            workspace_error("workspace_unreadable", "Workspace directory is not readable", expanded, origin, reason)
        end

      {:ok, %File.Stat{type: :directory}} ->
        workspace_error("workspace_unreadable", "Workspace directory is not readable", expanded, origin)

      {:ok, %File.Stat{}} ->
        workspace_error("workspace_not_directory", "Workspace path is not a directory", expanded, origin)

      {:error, reason} ->
        workspace_error("workspace_missing", "Workspace directory cannot be accessed", expanded, origin, reason)
    end
  end

  @doc """
  Resolves either the byte-compatible single source or a bounded set of keyed sources.

  Workspace-set mode is entered by between `WorkspaceSet.min_sources/0` and
  `WorkspaceSet.max_sources/0` keyed declarations. Exceeding the upper bound is
  a serve-time error carrying `workspace_declaration_too_many`; declarations are
  never truncated, reordered, or dropped.
  """
  @spec resolve_workspace_config(nil | [String.t()] | String.t()) ::
          {:ok, {:single, map()} | {:workspace_set, [map()]}} | {:error, map()}
  def resolve_workspace_config(nil) do
    with {:ok, workspace} <- resolve_workspace(nil), do: {:ok, {:single, workspace}}
  end

  def resolve_workspace_config(value) when is_binary(value), do: resolve_workspace_config([value])

  def resolve_workspace_config([]) do
    declaration_error("workspace_declaration_empty", "A workspace declaration list cannot be empty")
  end

  def resolve_workspace_config(values) when is_list(values) do
    keyed = Enum.map(values, &String.contains?(&1, "="))
    count = length(values)
    max = PixirMonitor.WorkspaceSet.max_sources()

    cond do
      count == 1 and hd(keyed) ->
        declaration_error("workspace_declaration_single_keyed", "A keyed declaration requires at least one sibling")

      count == 1 ->
        with {:ok, workspace} <- resolve_workspace(hd(values)), do: {:ok, {:single, workspace}}

      count >= 2 and Enum.any?(keyed) and not Enum.all?(keyed) ->
        declaration_error("workspace_declaration_mixed", "Keyed and plain declarations cannot be mixed")

      count >= 2 and not Enum.any?(keyed) ->
        declaration_error(
          "workspace_declaration_unkeyed_pair",
          "Multiple workspace declarations must all use KEY=PATH"
        )

      count > max ->
        declaration_error(
          "workspace_declaration_too_many",
          "Workspace set accepts at most #{max} declarations",
          %{max_workspaces: max, declared: count}
        )

      true ->
        resolve_keyed_workspaces(values)
    end
  end

  defp resolve_keyed_workspaces(values) do
    declarations =
      Enum.map(values, fn value ->
        [key, path] = String.split(value, "=", parts: 2)
        %{key: key, path: path}
      end)

    cond do
      Enum.any?(declarations, &(&1.path == "")) ->
        declaration_error("workspace_declaration_empty_path", "A keyed workspace path cannot be empty")

      Enum.any?(declarations, &(PixirMonitor.WorkspaceSet.validate_key(&1.key) != :ok)) ->
        declaration_error("workspace_declaration_invalid_key", "Workspace key does not match the safe-component grammar")

      declarations |> Enum.map(& &1.key) |> Enum.uniq() |> length() != length(declarations) ->
        declaration_error("workspace_declaration_duplicate_key", "Workspace keys must be unique")

      true ->
        Enum.reduce_while(declarations, {:ok, []}, fn declaration, {:ok, acc} ->
          case resolve_workspace(declaration.path) do
            {:ok, workspace} -> {:cont, {:ok, acc ++ [%{key: declaration.key, path: workspace.path, origin: "cli"}]}}
            {:error, error} -> {:halt, {:error, error}}
          end
        end)
        |> case do
          {:ok, sources} -> {:ok, {:workspace_set, sources}}
          {:error, _} = error -> error
        end
    end
  end

  defp declaration_error(kind, message, details \\ %{}) do
    min = PixirMonitor.WorkspaceSet.min_sources()
    max = PixirMonitor.WorkspaceSet.max_sources()

    {:error,
     %{
       kind: kind,
       message: message,
       details: details,
       next_actions: ["Declare one plain --workspace PATH or #{min} to #{max} --workspace KEY=PATH values"]
     }}
  end

  defp workspace_error(kind, message, path, origin, reason \\ nil) do
    details = %{workspace: path, origin: origin}
    details = if reason, do: Map.put(details, :reason, inspect(reason)), else: details

    {:error, %{kind: kind, message: message, details: details, next_actions: ["Pass --workspace <existing readable directory> to pixir-monitor serve, or run serve from inside the workspace"]}}
  end

  defp dry_run(json?, workspace_arg, launch_mode) do
    case load_monitor_application() do
      :ok ->
        dry_run_loaded(json?, workspace_arg, launch_mode)

      {:error, error} ->
        emit_error(error, json?)
        {:error, 1}
    end
  end

  defp dry_run_loaded(json?, workspace_arg, launch_mode) do
    case resolve_workspace_config(workspace_arg) do
      {:ok, config} ->
        emit_plan(plan(config, launch_mode), json?)
        {:ok, 0}

      {:error, error} ->
        emit_error(error, json?)
        {:error, 1}
    end
  end

  defp plan({:single, workspace}, launch_mode) do
    base_plan(launch_mode)
    |> Map.put(:mode, "single_workspace")
    |> Map.put(:workspace, workspace)
  end

  defp plan({:workspace_set, sources}, launch_mode) do
    base_plan(launch_mode)
    |> Map.put(:mode, "workspace_set")
    |> Map.put(:workspaces, Enum.map(sources, &%{key: &1.key, path: &1.path, origin: &1.origin}))
  end

  defp base_plan(launch_mode) do
    %{
      ok: true,
      action: "serve",
      dry_run: true,
      launch_mode: launch_mode,
      launch_surface: %{
        degrades_instead_of_exiting: true,
        rearm_limit: PixirMonitor.LaunchSurface.rearm_limit(),
        reentry: PixirMonitor.LaunchSurface.reentry_mechanism(),
        readiness_event: "launch_ready"
      },
      bind: %{address: "127.0.0.1", port: 0, port_strategy: "ephemeral"},
      source: "filesystem_logs",
      renderer: "spa_sse",
      security: %{exact_host: true, one_use_launch_ttl_seconds: 30, no_store: true, mutation_control_plane: false},
      next_action: "Run pixir-monitor serve"
    }
  end

  # The launch handoff is auxiliary: only application load, workspace resolution,
  # and application start (which owns port binding) are serving preconditions and
  # may exit 1. Once those hold, the launch surface is started beside the serving
  # process and every handoff outcome degrades into a reported frame instead of
  # ending a monitor whose listener and projection are already healthy.
  defp serve(json?, workspace_arg, launch_mode) do
    with :ok <- load_monitor_application(),
         {:ok, config} <- resolve_workspace_config(workspace_arg),
         :ok <- install_workspace(config),
         {:ok, _apps} <- Application.ensure_all_started(:pixir_monitor) do
      launch = start_launch_surface(launch_mode, json?)
      emit_serving(launch, json?)
      block_forever()
    else
      {:error, error} ->
        emit_error(normalize_error(error), json?)
        {:error, 1}
    end
  end

  defp emit_serving(launch, true), do: IO.puts(Jason.encode!(%{ok: true, status: "serving", launch: launch}))

  defp emit_serving(launch, false) do
    IO.puts("Pixir Monitor is serving on loopback. Close with Ctrl-C.")
    IO.puts("  launch: #{launch.launch_mode} (#{launch.status})")
  end

  defp block_forever do
    case Application.fetch_env(:pixir_monitor, :serve_blocker) do
      {:ok, blocker} when is_function(blocker, 0) -> blocker.()
      _ -> Process.sleep(:infinity)
    end
  end

  # The surface starts unlinked and its own exits never propagate to the serving
  # process: an auxiliary handoff must not be able to take serving down. It is
  # named so the operator (and shutdown) can reach exactly one launch surface.
  defp start_launch_surface(launch_mode, json?) do
    emit = &emit_launch_frame(&1, json?)

    opts = [
      name: PixirMonitor.LaunchSurface,
      launch_mode: launch_mode,
      emit: emit,
      install_reentry_trap: launch_mode == "darwin",
      port: launch_port(launch_mode)
    ]

    case PixirMonitor.LaunchSurface.start_unlinked(opts) do
      {:ok, surface} ->
        # Above the bounded launcher in PixirMonitor.Runtime: darwin fires it
        # inline during handle_continue, so a 5_000 ms call timeout would race
        # the same 5_000 ms launcher bound and report launch_surface_unavailable
        # for a healthy surface that is about to report `failed`.
        Map.merge(%{launch_mode: launch_mode}, PixirMonitor.LaunchSurface.outcome(surface, @launch_outcome_timeout_ms))

      _other ->
        %{launch_mode: launch_mode, status: "not_attempted", kind: "launch_surface_unavailable"}
    end
  catch
    :exit, _reason -> %{launch_mode: launch_mode, status: "not_attempted", kind: "launch_surface_unavailable"}
  end

  # FIFO mode arms asynchronously, so it does not wait on the port here; darwin
  # fires its launcher during init and needs the discovered listener port.
  defp launch_port("fifo"), do: nil

  defp launch_port(_darwin) do
    case PixirMonitor.PortRegistry.wait(15_000) do
      {:ok, port} -> port
      {:error, _} -> nil
    end
  end

  # The escript deliberately declares `app: nil`, so load the application spec
  # before installing invocation-time environment. Otherwise the later implicit
  # load can replace `--workspace` with the compiled application environment.
  defp load_monitor_application do
    case Application.load(:pixir_monitor) do
      :ok ->
        :ok

      {:error, {:already_loaded, :pixir_monitor}} ->
        :ok

      {:error, reason} ->
        {:error,
         %{
           kind: "application_load_failed",
           message: "Pixir Monitor application configuration could not be loaded",
           details: %{reason: inspect(reason, limit: 10, printable_limit: 200)},
           next_actions: ["Rebuild the pixir-monitor escript and retry"]
         }}
    end
  end

  # Launch-surface frames stay on stderr so stdout keeps carrying exactly one
  # serving contract line. The readiness frame keeps its historical
  # `status: "ready"` on the wire so an existing supervisor still finds the FIFO
  # path, and it is now re-emitted on every re-arm with the newly valid path; the
  # surface-level event name travels beside it as `event`.
  defp emit_launch_frame(frame, true) do
    IO.puts(:stderr, Jason.encode!(wire_frame(frame)))
  end

  defp emit_launch_frame(%{status: "launch_ready", fifo_path: fifo}, false) do
    IO.puts(:stderr, "Pixir Monitor FIFO ready: #{fifo}")
  end

  defp emit_launch_frame(%{status: "launch_degraded"} = frame, false) do
    IO.puts(:stderr, "Launch handoff degraded [#{frame.kind}]: re-arming the launch surface")
  end

  defp emit_launch_frame(%{status: "launch_surface_exhausted"} = frame, false) do
    IO.puts(:stderr, "Launch surface exhausted after #{frame.rearm_limit} re-arms; serving continues without a FIFO")
  end

  defp emit_launch_frame(frame, false) do
    IO.puts(:stderr, "Launch [#{frame.status}]")
  end

  defp wire_frame(%{status: "launch_ready"} = frame), do: frame |> Map.put(:event, "launch_ready") |> Map.put(:status, "ready")
  defp wire_frame(frame), do: Map.put(frame, :event, frame.status)

  defp install_workspace({:single, %{path: path}}) do
    Application.delete_env(:pixir_monitor, :workspace_set)

    opts =
      Application.get_env(:pixir_monitor, :projection_source, [])
      |> Keyword.put(:workspace, path)

    Application.put_env(:pixir_monitor, :projection_source, opts)
    :ok
  end

  defp install_workspace({:workspace_set, sources}) do
    Application.put_env(:pixir_monitor, :workspace_set, Enum.map(sources, &Map.take(&1, [:key, :path])))
    :ok
  end

  defp self_check(json?) do
    result =
      case Application.fetch_env(:pixir_monitor, :self_check_runner) do
        {:ok, runner} -> runner.run()
        :error -> PixirMonitor.SelfCheck.run()
      end

    case result do
      {:ok, result} ->
        emit(result, json?)
        {:ok, 0}

      {:error, error} ->
        emit_error(normalize_error(error), json?)
        {:error, 1}
    end
  end

  defp emit_plan(value, true), do: emit(value, true)

  defp emit_plan(value, false) do
    IO.puts("Pixir Monitor dry-run")

    case value.mode do
      "single_workspace" -> IO.puts("  workspace: #{value.workspace.path} (#{value.workspace.origin})")
      "workspace_set" -> Enum.each(value.workspaces, &IO.puts("  workspace #{&1.key}: #{&1.path} (#{&1.origin})"))
    end

    IO.puts("  bind: #{value.bind.address}:ephemeral")
    IO.puts("  launch mode: #{value.launch_mode}")
    IO.puts("  launch handoff: degrades and re-arms; it never ends serving")
    IO.puts("  re-arm limit: #{value.launch_surface.rearm_limit}")
    IO.puts("  re-entry: #{value.launch_surface.reentry}")
    IO.puts("  source: append-only filesystem Logs")
    IO.puts("  mode: read-only SPA with bounded SSE hints")
    IO.puts("  next: #{value.next_action}")
  end

  defp emit(value, true), do: IO.puts(Jason.encode!(value))

  defp emit(value, false) do
    IO.puts("Pixir Monitor self-check passed")
    IO.puts("  listener: #{value.listener}")
    IO.puts("  bootstrap: #{value.bootstrap}")
    IO.puts("  assets: #{Enum.join(value.assets, ", ")}")
    IO.puts("  Runs API: #{value.runs_schema} v#{value.runs_schema_version}")
  end

  defp emit_error(error, true), do: IO.puts(:stderr, Jason.encode!(%{ok: false, error: error}))
  defp emit_error(error, false), do: IO.puts(:stderr, "Error [#{error.kind}]: #{error.message}")

  defp normalize_error(%{kind: _, message: _} = error), do: Map.put_new(error, :next_actions, ["Retry after inspecting local diagnostics"])

  defp normalize_error(reason),
    do: %{kind: "serve_failed", message: "Monitor failed to start", details: %{reason: inspect(reason, limit: 10, printable_limit: 200)}, next_actions: ["Retry after inspecting local diagnostics"]}
end
