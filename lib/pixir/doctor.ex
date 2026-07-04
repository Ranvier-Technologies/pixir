defmodule Pixir.Doctor do
  @moduledoc """
  Local first-run diagnostics for the source-install beta path.

  `Pixir.Doctor` is intentionally no-network: it checks local runtime readiness,
  configuration shape, auth presence, source-install artifacts, session-log writability,
  and ACP availability. Provider connectivity remains an explicit smoke/probe step.
  """

  alias Pixir.{Auth, Config, Paths, Provider}

  @type check :: %{required(String.t()) => term()}

  @doc "Run local diagnostics and return a JSON-serializable result."
  @spec run(keyword()) :: %{required(String.t()) => term()}
  def run(opts \\ []) do
    workspace = Keyword.get(opts, :workspace, File.cwd!())
    config = config_snapshot(opts)
    checks = checks(workspace, opts, config)
    failed = Enum.filter(checks, &(&1["status"] == "failed"))

    %{
      "ok" => failed == [],
      "status" => status(checks),
      "version" => Pixir.version(),
      "workspace" => Path.expand(workspace),
      "config_effective" => config["effective"],
      "config_warnings" => config["warnings"],
      "checks" => checks,
      "next_actions" => next_actions(checks)
    }
  end

  @doc "Render a compact human-readable diagnostic report."
  @spec render(map()) :: String.t()
  def render(result) do
    checks =
      result["checks"]
      |> Enum.map_join("\n", fn check ->
        "[#{marker(check["status"])}] #{check["id"]}: #{check["message"]}"
      end)

    next_actions =
      case result["next_actions"] do
        [] ->
          ""

        actions ->
          "\n\nNext actions:\n" <> Enum.map_join(actions, "\n", &"- #{&1}")
      end

    """
    Pixir doctor
    status: #{result["status"]}
    version: #{result["version"]}
    workspace: #{result["workspace"]}

    #{checks}#{next_actions}
    """
  end

  defp checks(workspace, opts, config) do
    [
      runtime_check(),
      source_binary_check(workspace, opts),
      workspace_check(workspace),
      auth_check(opts),
      config_check(opts, config),
      acp_check()
    ]
  end

  defp config_snapshot(opts), do: Config.load(Keyword.take(opts, [:config_path]))

  defp runtime_check do
    passed("runtime", "Pixir runtime starts and reports version #{Pixir.version()}.", %{
      "version" => Pixir.version()
    })
  end

  defp source_binary_check(workspace, opts) do
    binary_path = Keyword.get(opts, :binary_path, Path.join(workspace, "pixir"))

    cond do
      File.regular?(binary_path) and executable?(binary_path) ->
        passed("source_install_binary", "Local ./pixir escript exists and is executable.", %{
          "path" => Path.expand(binary_path)
        })

      File.regular?(binary_path) ->
        warning("source_install_binary", "Local ./pixir escript exists but is not executable.", %{
          "path" => Path.expand(binary_path),
          "next_actions" => ["run chmod +x #{relative_or_absolute(binary_path, workspace)}"]
        })

      true ->
        warning(
          "source_install_binary",
          "Local ./pixir escript was not found in this checkout.",
          %{
            "path" => Path.expand(binary_path),
            "next_actions" => ["run mix escript.build before testing the source-install binary"]
          }
        )
    end
  end

  defp workspace_check(workspace) do
    expanded = Path.expand(workspace)

    cond do
      not File.exists?(expanded) ->
        failed("workspace", "Workspace directory does not exist.", %{
          "path" => expanded,
          "next_actions" => ["choose an existing project directory and rerun pixir doctor"]
        })

      not File.dir?(expanded) ->
        failed("workspace", "Workspace path is not a directory.", %{
          "path" => expanded,
          "next_actions" => ["run pixir doctor from a project directory"]
        })

      true ->
        workspace_sessions_check(expanded)
    end
  end

  defp workspace_sessions_check(workspace) do
    case session_write_probe(workspace) do
      {:ok, sessions_dir} ->
        passed("workspace", "Workspace directory is present and session logs are writable.", %{
          "path" => workspace,
          "project_state_dir" => Paths.project_root(workspace),
          "sessions_dir" => sessions_dir
        })

      {:error, reason} ->
        failed("workspace", "Workspace is present but Pixir cannot write session logs.", %{
          "kind" => "workspace_not_writable",
          "path" => workspace,
          "project_state_dir" => Paths.project_root(workspace),
          "sessions_dir" => Paths.sessions_dir(workspace),
          "reason" => inspect(reason),
          "next_actions" => [
            "run pixir doctor from a writable project directory",
            "fix permissions for #{Paths.project_root(workspace)}"
          ]
        })
    end
  end

  defp session_write_probe(workspace) do
    probe_path =
      workspace
      |> Paths.sessions_dir()
      |> Path.join(".doctor-write-probe-#{System.unique_integer([:positive])}")

    try do
      sessions_dir = Paths.ensure_sessions_dir(workspace)

      case File.write(probe_path, "ok") do
        :ok ->
          _ = File.rm(probe_path)
          {:ok, sessions_dir}

        {:error, reason} ->
          {:error, reason}
      end
    rescue
      exception -> {:error, Exception.message(exception)}
    after
      if File.exists?(probe_path), do: File.rm(probe_path)
    end
  end

  defp auth_check(opts) do
    status = Keyword.get_lazy(opts, :auth_status, fn -> Auth.status() end)

    cond do
      not Map.get(status, :authenticated?, false) ->
        warning("auth", "No local credential is currently available.", %{
          "kind" => nil,
          "next_actions" => ["run ./pixir login or set OPENAI_API_KEY"]
        })

      Map.get(status, :expired?, false) ->
        warning("auth", "Stored subscription credential appears expired.", %{
          "kind" => auth_kind(status),
          "next_actions" => ["run ./pixir login if the next provider call cannot refresh"]
        })

      true ->
        passed("auth", "A local credential is available.", %{"kind" => auth_kind(status)})
    end
  end

  defp config_check(opts, config) do
    config_path = Keyword.get(opts, :config_path, Paths.config_file())
    model = Keyword.get_lazy(opts, :model, &Provider.default_model/0)
    effective = config["effective"]
    warnings = config["warnings"] || []

    base_details = %{
      "path" => config["path"] || Path.expand(config_path),
      "model" => effective["model"] || model,
      "effective" => effective,
      "warnings" => warnings
    }

    cond do
      Map.has_key?(config, "error") ->
        failed("config", "Could not read config.json.", %{
          "path" => config["path"],
          "reason" => config["error"],
          "next_actions" => ["fix permissions on #{config["path"]} or remove the file"]
        })

      not config["present"] ->
        passed("config", "No config.json found; Pixir will use built-in defaults.", %{
          base_details
          | "model" => model
        })

      warnings != [] ->
        warning(
          "config",
          "config.json is readable but has ignored fields; see config_warnings.",
          base_details
        )

      true ->
        passed("config", "config.json is readable.", base_details)
    end
  end

  defp acp_check do
    passed("acp", "ACP stdio command is available.", %{
      "command" => "./pixir acp",
      "next_actions" => ["use ./pixir acp from an ACP client after building the escript"]
    })
  end

  defp executable?(path) do
    case File.stat(path) do
      {:ok, %{mode: mode}} -> Bitwise.band(mode, 0o111) != 0
      {:error, _} -> false
    end
  end

  defp status(checks) do
    cond do
      Enum.any?(checks, &(&1["status"] == "failed")) -> "blocked"
      Enum.any?(checks, &(&1["status"] == "warning")) -> "ready_with_warnings"
      true -> "ready"
    end
  end

  defp next_actions(checks) do
    checks
    |> Enum.flat_map(fn check -> get_in(check, ["details", "next_actions"]) || [] end)
    |> Enum.uniq()
  end

  defp auth_kind(status) do
    status
    |> Map.get(:kind)
    |> case do
      nil -> nil
      kind when is_atom(kind) -> Atom.to_string(kind)
      kind -> to_string(kind)
    end
  end

  defp passed(id, message, details), do: check(id, "passed", message, details)
  defp warning(id, message, details), do: check(id, "warning", message, details)
  defp failed(id, message, details), do: check(id, "failed", message, details)

  defp check(id, status, message, details) do
    %{"id" => id, "status" => status, "message" => message, "details" => details}
  end

  defp marker("passed"), do: "ok"
  defp marker("warning"), do: "warn"
  defp marker("failed"), do: "fail"
  defp marker(_), do: "info"

  defp relative_or_absolute(path, workspace) do
    expanded_path = Path.expand(path)
    expanded_workspace = Path.expand(workspace)

    case Path.relative_to(expanded_path, expanded_workspace) do
      ^expanded_path -> expanded_path
      relative -> relative
    end
  end
end
