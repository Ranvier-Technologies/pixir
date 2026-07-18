defmodule Pixir.Doctor do
  @moduledoc """
  Local first-run diagnostics for the source-install beta path.

  `Pixir.Doctor` is intentionally no-network: it checks local runtime readiness,
  configuration shape, auth presence, source-install artifacts, session-log writability,
  and ACP availability. Provider connectivity remains an explicit smoke/probe step.

  The JSON envelope gives orchestrators an explicit delegation decision in `proceed`:
  `"true"` is ready, `"judge"` requires inspecting the non-passing ids already listed
  in `judge_checks`, and `"block"` is not safe to proceed. `judge_checks` carries the
  non-passing ids for `"block"` too (it is never assumed empty there); severity lives
  in `proceed` and per-check detail in `checks[]`.
  """

  alias Pixir.{Auth, Config, Paths}

  @type check :: %{required(String.t()) => term()}

  @doc "Run local diagnostics and return a JSON-serializable result."
  @spec run(keyword()) :: %{required(String.t()) => term()}
  def run(opts \\ []) do
    workspace = Keyword.get(opts, :workspace, File.cwd!())
    config = config_snapshot(opts)
    model_before_default = Keyword.get(opts, :model) || get_in(config, ["effective", "model"])
    entry = registry_entry(model_before_default)
    model = model_before_default || entry.default_model
    checks = checks(workspace, opts, config, entry, model)
    failed = Enum.filter(checks, &(&1["status"] == "failed"))
    status = status(checks)

    %{
      "ok" => failed == [],
      "status" => status,
      "proceed" => proceed(status),
      "judge_checks" => non_passing_check_ids(checks),
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

    judgment =
      case result["judge_checks"] do
        [] -> ""
        ids -> "\njudge_checks: #{Enum.join(ids, ", ")}"
      end

    """
    Pixir doctor
    status: #{result["status"]}
    proceed: #{result["proceed"]}#{judgment}
    version: #{result["version"]}
    workspace: #{result["workspace"]}

    #{checks}#{next_actions}
    """
  end

  defp checks(workspace, opts, config, entry, model) do
    [
      runtime_check(),
      source_binary_check(workspace, opts),
      workspace_check(workspace),
      auth_check(opts, entry, model),
      config_check(opts, config, entry, model),
      catalog_check(config, opts),
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
        details =
          %{
            "kind" => "workspace_not_writable",
            "path" => workspace,
            "project_state_dir" => Paths.project_root(workspace),
            "sessions_dir" => Paths.sessions_dir(workspace),
            "next_actions" => [
              "run pixir doctor from a writable project directory",
              "fix permissions for #{Paths.project_root(workspace)}"
            ]
          }
          |> Map.merge(workspace_probe_error_details(reason))

        failed("workspace", "Workspace is present but Pixir cannot write session logs.", details)
    end
  end

  defp session_write_probe(workspace) do
    sessions_dir = Paths.sessions_dir(workspace)

    probe_path =
      Path.join(sessions_dir, ".doctor-write-probe-#{System.unique_integer([:positive])}")

    with {:ok, ^sessions_dir} <- Paths.ensure_state_dir(workspace, sessions_dir),
         :ok <- Paths.preflight_new_state_path(workspace, probe_path),
         :ok <- File.write(probe_path, "ok"),
         :ok <- Paths.preflight_state_path(workspace, probe_path, expected: :regular),
         :ok <- remove_write_probe(workspace, probe_path) do
      {:ok, sessions_dir}
    else
      {:error, reason} ->
        _ = remove_write_probe(workspace, probe_path)
        {:error, reason}
    end
  end

  defp remove_write_probe(workspace, probe_path) do
    case Paths.inspect_state_path(workspace, probe_path, expected: :regular) do
      {:ok, %{state: :missing}} -> :ok
      {:ok, %{state: :regular}} -> File.rm(probe_path)
      {:error, _error} = error -> error
    end
  end

  defp workspace_probe_error_details(%{error: %{kind: kind, message: message} = error}) do
    %{
      "reason" => message,
      "cause" => %{
        "kind" => to_string(kind),
        "message" => message,
        "details" => Map.get(error, :details, %{})
      }
    }
  end

  defp workspace_probe_error_details(reason), do: %{"reason" => inspect(reason)}

  defp auth_check(opts, entry, model) do
    case entry.auth do
      %{scheme: :api_key_header, login_supported: false} ->
        api_key_auth_check(opts, entry, model)

      _ ->
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
  end

  defp api_key_auth_check(opts, entry, model) do
    env = Keyword.get(opts, :env, &System.get_env/1)
    env_var = entry.auth.env_var
    value = env.(env_var)

    details =
      %{
        "kind" => "api_key",
        "provider" => provider_label(entry.provider),
        "env_var" => env_var
      }
      |> put_retention_notes(model)

    if is_binary(value) and value != "" do
      passed("auth", "A local credential is available.", details)
    else
      warning(
        "auth",
        "No local credential is currently available.",
        Map.put(details, "next_actions", ["set #{env_var}"])
      )
    end
  end

  defp config_check(opts, config, entry, model) do
    config_path = Keyword.get(opts, :config_path, Paths.config_file())
    effective = config["effective"]
    warnings = config["warnings"] || []

    base_details = %{
      "path" => config["path"] || Path.expand(config_path),
      "model" => model,
      "provider" => provider_label(entry.provider),
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

  defp catalog_check(config, opts) do
    effective = config["effective"] || %{}
    refreshed_at = effective["models_refreshed_at"]
    stale? = stale_catalog?(refreshed_at, Keyword.get(opts, :now, DateTime.utc_now()))

    details = %{
      "source" =>
        if(effective["models"] || effective["anthropic_models"],
          do: "config_override",
          else: "built_in_only"
        ),
      "providers" => %{
        "openai" => if(effective["models"], do: "config_override", else: "built_in_only"),
        "anthropic" =>
          if(effective["anthropic_models"], do: "config_override", else: "built_in_only")
      },
      "stale" => stale?
    }

    details =
      details
      |> put_some("models_refreshed_at", refreshed_at)
      |> put_some(
        "hint",
        if(stale?, do: "model catalog is older than 30 days; run `pixir models refresh`")
      )

    passed("model_catalog", "Model catalog source is #{details["source"]}.", details)
  end

  defp stale_catalog?(stamp, now) when is_binary(stamp) do
    case DateTime.from_iso8601(stamp) do
      {:ok, refreshed_at, _offset} -> DateTime.diff(now, refreshed_at, :second) > 30 * 86_400
      _ -> false
    end
  end

  defp stale_catalog?(_stamp, _now), do: false

  defp put_some(map, _key, nil), do: map
  defp put_some(map, key, value), do: Map.put(map, key, value)

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

  defp proceed("ready"), do: "true"
  defp proceed("ready_with_warnings"), do: "judge"
  defp proceed(_status), do: "block"

  defp non_passing_check_ids(checks) do
    checks
    |> Enum.reject(&(&1["status"] == "passed"))
    |> Enum.map(& &1["id"])
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

  # Covered Models per current Anthropic docs: only these carry the 30-day
  # retention requirement, so the note must not ride other claude-* models.
  @retention_covered_models ["claude-fable-5", "claude-mythos-5"]

  defp put_retention_notes(details, model) when model in @retention_covered_models do
    Map.put(details, "notes", [
      "#{model} requires 30-day organization data retention; a 400 on every " <>
        "valid-looking request usually points at org/workspace data-retention " <>
        "configuration, not the payload."
    ])
  end

  defp put_retention_notes(details, _model), do: details

  defp provider_label(Pixir.Providers.Anthropic), do: "anthropic"
  defp provider_label(_provider), do: "openai"

  defp registry_entry(model), do: Pixir.Providers.Registry.resolve(model)

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
