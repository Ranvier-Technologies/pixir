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

  Dry-run output is bounded and capability-free. Real serve passes launch material only
  through the in-memory runtime handoff and never prints it. FIFO readiness contains
  only the non-secret pipe path and is emitted on stderr, leaving stdout's final serving
  contract unchanged. Errors are structured as `kind`, `message`, `details`, and
  `next_actions`; JSON error output carries all four fields, while human-readable error
  output prints `kind` and `message` only.
  """

  @help """
  pixir-monitor — loopback-only read-only Pixir presenter

  Usage:
    pixir-monitor serve [--workspace PATH] [--dry-run] [--json] [--launch-mode darwin|fifo]
    pixir-monitor serve --workspace KEY=PATH --workspace KEY=PATH [--dry-run] [--json]
    pixir-monitor serve --help
    pixir-monitor self-check [--json]
    pixir-monitor --help

  Options:
    --launch-mode MODE  Launch handoff mode. Default: darwin (macOS automatic
                        browser launch). Use fifo for a portable, bounded external
                        reader handoff on systems with named-pipe support.
    --workspace VALUE   One plain PATH keeps single-workspace mode. Exactly two
                        KEY=PATH declarations enter Workspace Overview mode;
                        keys use [A-Za-z0-9][A-Za-z0-9_-]* and declaration order
                        is preserved. No discovery or browser path selection.
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

  @doc "Resolves either the byte-compatible single source or exactly two keyed sources."
  @spec resolve_workspace_config(nil | [String.t()] | String.t()) ::
          {:ok, {:single, map()} | {:workspace_set, [map()]}} | {:error, map()}
  def resolve_workspace_config(nil) do
    with {:ok, workspace} <- resolve_workspace(nil), do: {:ok, {:single, workspace}}
  end

  def resolve_workspace_config(value) when is_binary(value), do: resolve_workspace_config([value])

  def resolve_workspace_config(values) when is_list(values) do
    keyed = Enum.map(values, &String.contains?(&1, "="))

    cond do
      length(values) >= 3 ->
        declaration_error("workspace_declaration_too_many", "Workspace set v1 accepts exactly two declarations")

      length(values) == 1 and hd(keyed) ->
        declaration_error("workspace_declaration_single_keyed", "A keyed declaration requires exactly one sibling")

      length(values) == 1 ->
        with {:ok, workspace} <- resolve_workspace(hd(values)), do: {:ok, {:single, workspace}}

      length(values) == 2 and Enum.any?(keyed) and not Enum.all?(keyed) ->
        declaration_error("workspace_declaration_mixed", "Keyed and plain declarations cannot be mixed")

      length(values) == 2 and Enum.all?(keyed) ->
        resolve_keyed_workspaces(values)

      length(values) == 2 ->
        declaration_error("workspace_declaration_unkeyed_pair", "Two workspace declarations must both use KEY=PATH")

      true ->
        declaration_error("workspace_declaration_mixed", "Workspace set mode requires keyed declarations")
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

      declarations |> Enum.map(& &1.key) |> Enum.uniq() |> length() != 2 ->
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

  defp declaration_error(kind, message) do
    {:error, %{kind: kind, message: message, details: %{}, next_actions: ["Declare one plain --workspace PATH or exactly two --workspace KEY=PATH values"]}}
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
      bind: %{address: "127.0.0.1", port: 0, port_strategy: "ephemeral"},
      source: "filesystem_logs",
      renderer: "spa_sse",
      security: %{exact_host: true, one_use_launch_ttl_seconds: 30, no_store: true, mutation_control_plane: false},
      next_action: "Run pixir-monitor serve"
    }
  end

  defp serve(json?, workspace_arg, launch_mode) do
    with :ok <- load_monitor_application(),
         {:ok, config} <- resolve_workspace_config(workspace_arg),
         :ok <- install_workspace(config),
         {:ok, _apps} <- Application.ensure_all_started(:pixir_monitor),
         :ok <- launch(launch_mode, json?) do
      if json?, do: IO.puts(Jason.encode!(%{ok: true, status: "serving"})), else: IO.puts("Pixir Monitor is serving on loopback. Close with Ctrl-C.")
      Process.sleep(:infinity)
    else
      {:error, error} ->
        emit_error(normalize_error(error), json?)
        {:error, 1}
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

  # Keep the default path as the pre-existing Darwin runtime call. FIFO mode is
  # deliberately separate so it cannot invoke osascript or alter default behavior.
  defp launch("darwin", _json?), do: PixirMonitor.Runtime.launch_browser()

  defp launch("fifo", json?) do
    with {:ok, port} <- PixirMonitor.PortRegistry.wait(15_000),
         {:ok, prepared} <- PixirMonitor.FifoHandoff.prepare() do
      emit_fifo_readiness(prepared.fifo, json?)

      case PixirMonitor.FifoHandoff.handoff(prepared, fn ->
             PixirMonitor.Runtime.issue_launch_url(port)
           end) do
        {:ok, warning} ->
          emit_fifo_warning(warning, json?)
          :ok

        result ->
          result
      end
    end
  end

  defp emit_fifo_readiness(fifo, true) do
    IO.puts(:stderr, Jason.encode!(%{ok: true, status: "ready", launch_mode: "fifo", fifo_path: fifo}))
  end

  defp emit_fifo_readiness(fifo, false) do
    IO.puts(:stderr, "Pixir Monitor FIFO ready: #{fifo}")
  end

  defp emit_fifo_warning(warning, true) do
    IO.puts(:stderr, Jason.encode!(%{ok: true, status: "warning", warning: warning}))
  end

  defp emit_fifo_warning(warning, false) do
    IO.puts(:stderr, "Warning [#{warning.kind}]: #{warning.message}")
  end

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
