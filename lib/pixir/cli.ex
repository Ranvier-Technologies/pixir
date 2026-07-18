defmodule Pixir.CLI do
  @moduledoc """
  Escript entry point — one-shot, print-first (ADR 0001). Commands:

      pixir login              Browser OAuth (device-code fallback) → ~/.pixir/auth.json
      pixir doctor             Run local first-run diagnostics (no network)
      pixir models             Show local provider model catalogs (no network)
      pixir models refresh     Explicitly refresh supported provider catalogs
      pixir gc                 Plan isolated Subagent workspace reclamation
      pixir tree <id>          Project a Session/Subagent tree from local Logs
      pixir compact <id>       Record a durable History compaction checkpoint
      pixir fork <id>          Create a child Session from a parent History prefix
      pixir inspect-replay <id> Inspect Provider replay input without network
      pixir delegate           Validate or run a Delegate CLI spec
      pixir [--web-search] [--attach PATH] "prompt"           Run one Turn in the current directory, stream to stdout
      pixir [--json] [--attach PATH] [--bash-timeout-ms N] --write-policy <policy.json> "prompt"
                               Run a bounded-write headless Turn with JSON output
      pixir resume <id> [--web-search] [--attach PATH] "..."  Continue a persisted Session
      pixir acp                Speak Agent Client Protocol over stdio (ADR 0009)
      pixir help               Show help

  Channel discipline (ADR 0005): the model's answer goes to **stdout**; prompts,
  activity, diagnostics, and the resumable session id go to **stderr**. A prompt may be
  passed as an argument or piped on **stdin**. Exit code is non-zero on error.
  `--ask` is intentionally interactive-only; headless orchestrators should use
  `--read-only`, explicit auto-mode approval, or a bounded write policy instead of
  silently denying every write prompt. `--write-policy` and `--bash-timeout-ms` are
  one-shot/resume runtime options: write policy requires auto mode, carries bounded
  write/edit allowlists into Subagents and Workflows, disables mutating shell commands
  in v1, and can pair with `--json` for one final machine-readable stdout envelope.
  """

  alias Pixir.{
    Auth,
    Compaction,
    Config,
    Conversation,
    Delegate,
    Doctor,
    Event,
    Fork,
    Log,
    ModelsRefresh,
    Permissions,
    Permissions.WritePolicy,
    ReplayInspector,
    RecoveryCommands,
    Renderer,
    SessionDiagnostics,
    SessionSupervisor,
    SessionTree,
    Session,
    Subagents
  }

  alias Pixir.CLI.Sigint
  alias Pixir.Subagents.GC

  @write_policy_unsupported_commands ~w(
    login doctor models gc diagnose tree compact fork inspect-replay delegate acp help version --version -v -h --help
  )
  @bash_timeout_unsupported_commands @write_policy_unsupported_commands
  @attach_unsupported_commands @write_policy_unsupported_commands
  @web_search_unsupported_commands @write_policy_unsupported_commands

  @spec main([String.t()]) :: no_return()
  def main(argv) do
    {:ok, _} = Application.ensure_all_started(:pixir)
    {mode, positional} = extract_mode(argv)
    positional |> route(mode) |> halt()
  end

  @doc false
  @spec permission_mode_from_argv([String.t()]) :: Permissions.mode()
  def permission_mode_from_argv(argv), do: elem(extract_mode(argv), 0)

  @doc "Pure-ish router (permission mode defaults to config or `:auto`). IO happens inside."
  @spec route([String.t()], Permissions.mode()) :: :ok | {:error, non_neg_integer()}
  def route(argv, mode \\ :auto)

  def route(argv, mode) when is_list(argv) do
    case extract_runtime_options(argv) do
      {:ok, positional, runtime} ->
        route_command(positional, mode, runtime)

      {:error, error, json?} ->
        print_runtime_error_exit(error, json?)
    end
  end

  defp route_command([], _mode, _runtime), do: usage()
  defp route_command(["help" | _], _mode, _runtime), do: usage()
  defp route_command([flag | _], _mode, _runtime) when flag in ["-h", "--help"], do: usage()

  defp route_command([command | _rest], _mode, %{write_policy_path: path} = runtime)
       when is_binary(path) and command in @write_policy_unsupported_commands do
    Pixir.Tool.error(:invalid_args, "--write-policy only applies to one-shot or resume", %{
      "command" => command,
      "usage" => "pixir [--json] --write-policy <policy.json> \"prompt\"",
      "next_actions" => ["move_--write-policy_to_prompt_or_resume", "remove_--write-policy"]
    })
    |> print_runtime_error(runtime.json?)

    {:error, 2}
  end

  defp route_command([command | _rest], _mode, %{bash_timeout_ms: timeout} = runtime)
       when is_integer(timeout) and command in @bash_timeout_unsupported_commands do
    Pixir.Tool.error(:invalid_args, "--bash-timeout-ms only applies to one-shot or resume", %{
      "command" => command,
      "usage" => "pixir [--json] [--bash-timeout-ms N] \"prompt\"",
      "next_actions" => ["move_--bash-timeout-ms_to_prompt_or_resume", "remove_--bash-timeout-ms"]
    })
    |> print_runtime_error(runtime.json?)

    {:error, 2}
  end

  defp route_command([command | _rest], _mode, %{attach_paths: paths} = runtime)
       when is_list(paths) and paths != [] and command in @attach_unsupported_commands do
    Pixir.Tool.error(:invalid_args, "--attach only applies to one-shot or resume", %{
      "command" => command,
      "usage" => "pixir [--json] [--attach PATH] \"prompt\"",
      "next_actions" => ["move_--attach_to_prompt_or_resume", "remove_--attach"]
    })
    |> print_runtime_error(runtime.json?)

    {:error, 2}
  end

  defp route_command([command | _rest], _mode, %{web_search?: true} = runtime)
       when command in @web_search_unsupported_commands do
    Pixir.Tool.error(:invalid_args, "--web-search only applies to one-shot or resume", %{
      "command" => command,
      "usage" => "pixir [--json] [--web-search] \"prompt\"",
      "next_actions" => ["move_--web-search_to_prompt_or_resume", "remove_--web-search"]
    })
    |> print_runtime_error(runtime.json?)

    {:error, 2}
  end

  defp route_command(["login" | rest], _mode, _runtime) do
    cond do
      help?(rest) -> login_help()
      "--device-code" in rest -> login_device_code()
      true -> login()
    end
  end

  defp route_command(["doctor" | rest], _mode, _runtime) do
    cond do
      help?(rest) -> doctor_help()
      invalid_doctor_args?(rest) -> print_error_return("usage: pixir doctor [--json]", 2)
      true -> doctor("--json" in rest)
    end
  end

  defp route_command(["models" | rest], _mode, runtime) do
    if help?(rest), do: models_help(), else: models(rest, runtime.json?)
  end

  defp route_command(["gc" | rest], _mode, runtime) do
    if help?(rest), do: gc_help(), else: gc(rest, runtime.json?)
  end

  defp route_command(["diagnose" | rest], _mode, _runtime) do
    if help?(rest), do: diagnose_help(), else: diagnose(rest)
  end

  defp route_command(["tree" | rest], _mode, _runtime) do
    if help?(rest), do: tree_help(), else: tree(rest)
  end

  defp route_command(["compact" | rest], _mode, _runtime) do
    if help?(rest), do: compact_help(), else: compact(rest)
  end

  defp route_command(["fork" | rest], _mode, _runtime) do
    if help?(rest), do: fork_help(), else: fork(rest)
  end

  defp route_command(["inspect-replay" | rest], _mode, _runtime) do
    if help?(rest), do: inspect_replay_help(), else: inspect_replay(rest)
  end

  defp route_command(["delegate" | rest], _mode, _runtime) do
    if help?(rest) or rest == ["help"], do: delegate_help(), else: delegate(rest)
  end

  defp route_command(["resume" | rest], mode, runtime) do
    cond do
      help?(rest) ->
        resume_help()

      true ->
        case extract_resume_attachments(rest, runtime) do
          {:ok, rest, runtime} -> resume(mode, rest, runtime)
          {:error, error} -> print_runtime_error_exit(error, runtime.json?)
        end
    end
  end

  # ACP agent transport (ADR 0009): speak Agent Client Protocol over stdio. The Server
  # redirects Logger to stderr and owns stdout (JSON-RPC only); this blocks until EOF.
  defp route_command(["acp" | _rest], _mode, _runtime), do: Pixir.ACP.Server.run()

  # Print the version and exit (epic B.2). A non-ACP invocation, so plain stdout
  # is fine. The T3 Code liveness probe spawns `pixir --version` to distinguish
  # "installed" from "binary missing" and to populate the reported version.
  defp route_command([flag | _], _mode, _runtime) when flag in ["--version", "-v", "version"] do
    IO.puts(Pixir.version())
    :ok
  end

  defp route_command([prompt | rest], mode, runtime) do
    if help?(rest), do: usage(), else: one_shot(mode, read_prompt([prompt | rest]), runtime)
  end

  defp extract_resume_attachments([session_id | rest], runtime) do
    extract_resume_attachments(rest, runtime, [session_id])
  end

  defp extract_resume_attachments(rest, runtime), do: {:ok, rest, runtime}

  defp extract_resume_attachments(["--attach", path | rest], runtime, acc)
       when is_binary(path) and path != "" do
    runtime = %{runtime | attach_paths: runtime.attach_paths ++ [path]}
    extract_resume_attachments(rest, runtime, acc)
  end

  defp extract_resume_attachments(["--attach" | _rest], _runtime, _acc) do
    {:error,
     Pixir.Tool.error(:invalid_args, "--attach requires a path", %{
       "usage" => "pixir resume <session-id> [--attach PATH] \"prompt\"",
       "next_actions" => ["provide_attachment_path", "remove_--attach"]
     })}
  end

  # Post-session-id flags must be consumed here or they leak into the prompt
  # text: the generic clause below accumulates unrecognized args as positional.
  defp extract_resume_attachments(["--web-search" | rest], runtime, acc),
    do: extract_resume_attachments(rest, %{runtime | web_search?: true}, acc)

  defp extract_resume_attachments([arg | rest], runtime, acc),
    do: extract_resume_attachments(rest, runtime, acc ++ [arg])

  defp extract_resume_attachments([], runtime, acc), do: {:ok, acc, runtime}

  # Permission mode comes from flags; default :auto (YOLO, ADR 0006). Flags are
  # stripped so the remainder is the command + prompt.
  defp extract_mode(argv) do
    mode =
      cond do
        "--read-only" in argv -> :read_only
        "--ask" in argv -> :ask
        true -> Config.permission_default()
      end

    {mode, argv -- ["--ask", "--read-only", "--yolo"]}
  end

  defp extract_runtime_options(argv),
    do:
      extract_runtime_options(argv, %{
        json?: "--json" in argv,
        write_policy_path: nil,
        bash_timeout_ms: nil,
        web_search?: false,
        attach_paths: []
      })

  defp extract_runtime_options(["--json" | rest], acc),
    do: extract_runtime_options(rest, %{acc | json?: true})

  defp extract_runtime_options(["--write-policy", path | rest], acc)
       when is_binary(path) and path != "",
       do: extract_runtime_options(rest, %{acc | write_policy_path: path})

  defp extract_runtime_options(["--write-policy" | _rest], acc) do
    {:error,
     Pixir.Tool.error(:invalid_args, "--write-policy requires a policy JSON path", %{
       "usage" => "pixir [--json] --write-policy <policy.json> \"prompt\"",
       "next_actions" => ["provide_write_policy_path", "remove_--write-policy"]
     }), acc.json?}
  end

  defp extract_runtime_options(["--bash-timeout-ms", value | rest], acc) do
    case parse_bash_timeout_ms(value) do
      {:ok, timeout_ms} ->
        extract_runtime_options(rest, %{acc | bash_timeout_ms: timeout_ms})

      {:error, error} ->
        {:error, error, acc.json?}
    end
  end

  defp extract_runtime_options(["--bash-timeout-ms" | _rest], acc) do
    {:error,
     Pixir.Tool.error(:invalid_args, "--bash-timeout-ms requires positive milliseconds", %{
       "usage" => "pixir [--json] [--bash-timeout-ms N] \"prompt\"",
       "next_actions" => ["provide_positive_milliseconds", "remove_--bash-timeout-ms"]
     }), acc.json?}
  end

  defp extract_runtime_options(["--web-search" | rest], acc),
    do: extract_runtime_options(rest, %{acc | web_search?: true})

  defp extract_runtime_options(["--attach", path | rest], acc)
       when is_binary(path) and path != "",
       do: extract_runtime_options(rest, %{acc | attach_paths: acc.attach_paths ++ [path]})

  defp extract_runtime_options(["--attach" | _rest], acc) do
    {:error,
     Pixir.Tool.error(:invalid_args, "--attach requires a path", %{
       "usage" => "pixir [--json] [--attach PATH] \"prompt\"",
       "next_actions" => ["provide_attachment_path", "remove_--attach"]
     }), acc.json?}
  end

  defp extract_runtime_options(argv, acc), do: {:ok, argv, acc}

  defp cli_attachments(%{attach_paths: paths}) when is_list(paths) do
    Enum.map(paths, fn path ->
      uri =
        if String.starts_with?(path, "file://") do
          path
        else
          # Percent-encoded so ingestion's URI.decode round-trips reserved characters.
          encoded =
            path
            |> Path.expand(File.cwd!())
            |> URI.encode(&(&1 == ?/ or URI.char_unreserved?(&1)))

          "file://" <> encoded
        end

      name =
        case URI.parse(uri) do
          %{path: parsed_path} when is_binary(parsed_path) ->
            decode_basename(Path.basename(parsed_path))

          _parsed ->
            Path.basename(path)
        end

      %{"type" => "resource_link", "uri" => uri, "name" => name}
    end)
  end

  defp decode_basename(name) do
    URI.decode(name)
  rescue
    ArgumentError -> name
  end

  defp parse_bash_timeout_ms(value) do
    max_ms = Config.bash_timeout_max_ms()

    with {timeout_ms, ""} <- Integer.parse(value),
         true <- timeout_ms > 0,
         true <- timeout_ms <= max_ms do
      {:ok, timeout_ms}
    else
      _ -> {:error, bash_timeout_error(value, max_ms)}
    end
  end

  defp bash_timeout_error(value, max_ms) do
    Pixir.Tool.error(
      :invalid_args,
      "--bash-timeout-ms must be a positive integer within the configured cap",
      %{
        "value" => value,
        "max_timeout_ms" => max_ms,
        "usage" => "pixir [--json] [--attach PATH] [--bash-timeout-ms N] \"prompt\"",
        "next_actions" => [
          "choose_a_positive_integer_no_larger_than_bash_timeout_max_ms",
          "increase_bash_timeout_max_ms_in_config_if_needed",
          "remove_--bash-timeout-ms"
        ]
      }
    )
  end

  # ── commands ────────────────────────────────────────────────────────────

  defp login do
    result =
      Auth.login(%{
        on_authorize: fn %{authorize_url: url} ->
          IO.puts("Opening your browser to sign in with ChatGPT…")
          IO.puts("If it does not open automatically, visit:\n  #{url}\n")
          open_browser(url)
          IO.puts(:stderr, "Waiting for browser authorization…")
        end,
        on_device_code: &print_device_code_instructions/1,
        on_fallback: fn message ->
          IO.puts(:stderr, "Browser login unavailable (#{message}); using device-code…")
        end
      })

    finish_login(result)
  end

  defp login_device_code do
    result = Auth.login_device_code(&print_device_code_instructions/1)
    finish_login(result)
  end

  defp print_device_code_instructions(info) do
    IO.puts("To sign in, open:\n  #{info.verification_uri}")
    IO.puts("and enter the code:\n  #{info.user_code}\n")

    IO.puts(
      :stderr,
      "Waiting for authorization (expires in #{div(info.expires_in, 60)} min)…"
    )
  end

  defp finish_login(result) do
    case result do
      {:ok, status} ->
        IO.puts("Signed in (#{status.kind}).")
        :ok

      {:error, error} ->
        print_error(error)
        {:error, 1}
    end
  end

  defp open_browser(url) when is_binary(url) do
    cmd =
      case :os.type() do
        {:unix, :darwin} -> {"open", [url]}
        {:unix, _} -> {"xdg-open", [url]}
        {:win32, _} -> {"cmd", ["/c", "start", "", url]}
      end

    {exe, args} = cmd
    _ = System.cmd(exe, args, stderr_to_stdout: true)
    :ok
  end

  defp models_help do
    IO.puts("""
    Inspect or explicitly refresh provider model catalogs.

    Usage:
      pixir models [--json]
      pixir models refresh [--json]

    `pixir models` is local-only and never calls the network. It prints each provider's
    effective catalog, whether it came from built-ins or config.json, and the last
    refresh timestamp when available. `refresh` calls only model-list endpoints whose
    active authentication kind Pixir supports, preserves failed/skipped provider lists,
    and atomically updates ~/.pixir/config.json for successful providers.
    """)

    :ok
  end

  # The global runtime parser already consumed --json into `json?`; strip the
  # literal flag before matching subcommand shapes (same fix as `gc`).
  defp models(rest, json?) when is_list(rest) do
    case Enum.reject(rest, &(&1 == "--json")) do
      [] -> show_models(json?)
      ["refresh"] -> refresh_models(json?)
      args -> invalid_models_args(args, json?)
    end
  end

  defp invalid_models_args(args, true) do
    IO.puts(
      Jason.encode!(%{
        "ok" => false,
        "status" => "invalid_args",
        "kind" => "models_invalid_args",
        "details" => %{
          "args" => args,
          "usage" => "pixir models [refresh] [--json]"
        },
        "next_actions" => ["remove_unsupported_models_arguments"]
      })
    )

    {:error, 2}
  end

  defp invalid_models_args(_args, false),
    do: print_error_return("usage: pixir models [refresh] [--json]", 2)

  defp show_models(json?) do
    case ModelsRefresh.catalog(models_refresh_opts()) do
      {:ok, catalog} ->
        envelope =
          Map.merge(catalog, %{"ok" => true, "status" => "ok", "kind" => "models_catalog"})

        if json?, do: IO.puts(Jason.encode!(envelope)), else: render_models_catalog(catalog)
        :ok

      {:error, error} ->
        print_runtime_error(error, json?)
        {:error, 1}
    end
  end

  defp refresh_models(json?) do
    case ModelsRefresh.refresh(models_refresh_opts()) do
      {:ok, result} ->
        envelope =
          Map.merge(result, %{"ok" => true, "status" => "completed", "kind" => "models_refresh"})

        if json?, do: IO.puts(Jason.encode!(envelope)), else: render_models_refresh(result)
        :ok

      {:error, error} ->
        print_runtime_error(error, json?)
        {:error, 1}
    end
  end

  defp render_models_catalog(catalog) do
    IO.puts("Pixir models")

    Enum.each(["openai", "anthropic"], fn provider ->
      entry = catalog["providers"][provider]
      IO.puts("#{provider} (source: #{entry["source"]})")
      Enum.each(entry["models"], &IO.puts("  #{&1}"))
    end)

    if stamp = catalog["models_refreshed_at"], do: IO.puts("refreshed at: #{stamp}")
  end

  defp render_models_refresh(result) do
    IO.puts("Pixir models refresh")

    Enum.each(["openai", "anthropic"], fn provider ->
      entry = result["providers"][provider]

      case entry["status"] do
        "refreshed" ->
          IO.puts("#{provider}: refreshed")
          IO.puts("  added: #{Enum.join(entry["added"], ", ")}")
          IO.puts("  removed: #{Enum.join(entry["removed"], ", ")}")

        status ->
          reason = entry["reason"] || entry["kind"] || "unknown"
          IO.puts("#{provider}: #{status} (#{reason})")
      end
    end)

    IO.puts("config written: #{result["wrote_config"]}")
    IO.puts("refreshed at: #{result["refreshed_at"]}")
  end

  defp models_refresh_opts do
    cli_turn_opts()
    |> Keyword.get(:models_refresh_opts, [])
  end

  defp gc_help do
    IO.puts("""
    Reclaim terminal isolated Subagent workspace snapshots while preserving child Logs.

    Usage:
      pixir gc --json
      pixir gc --apply --json

    The default is an effect-free plan. --apply deletes only entries proven terminal by
    parent Session Logs. Every *.ndjson below any .pixir/sessions path remains byte-intact
    at its original path.
    """)

    :ok
  end

  defp gc(rest, json?) do
    rest = Enum.reject(rest, &(&1 == "--json"))

    result =
      case rest do
        [] -> GC.plan(workspace: File.cwd!())
        ["--apply"] -> GC.apply(workspace: File.cwd!())
        _other -> {:invalid_args, gc_invalid_args_envelope(rest)}
      end

    case result do
      {:ok, envelope} ->
        print_gc(envelope, json?)
        :ok

      {:error, envelope} ->
        print_gc(envelope, json?)
        {:error, 1}

      {:invalid_args, envelope} ->
        print_gc(envelope, json?)
        {:error, 2}
    end
  end

  defp gc_invalid_args_envelope(args) do
    %{
      "ok" => false,
      "status" => "invalid_args",
      "kind" => "subagent_gc_invalid_args",
      "details" => %{"args" => args, "usage" => "pixir gc [--apply] [--json]"},
      "next_actions" => ["remove_unsupported_gc_arguments"]
    }
  end

  defp print_gc(envelope, true), do: IO.puts(Jason.encode!(envelope))

  defp print_gc(envelope, false) do
    IO.puts("Pixir gc")
    IO.puts("status: #{envelope["status"]}")
    IO.puts("kind: #{envelope["kind"]}")

    if totals = envelope["totals"] do
      IO.puts("reclaimable bytes: #{totals["reclaimable_bytes"]}")
      IO.puts("preserved log bytes: #{totals["preserved_logs_bytes"]}")
    end
  end

  defp doctor(json?) do
    result = Doctor.run()

    if json? do
      IO.puts(Jason.encode!(result))
    else
      IO.puts(Doctor.render(result))
    end

    if result["ok"], do: :ok, else: {:error, 1}
  end

  defp diagnose(["session" | rest]) do
    case parse_diagnose_session_args(rest) do
      {:ok, session_id, json?} ->
        session_id
        |> SessionDiagnostics.run(workspace: File.cwd!())
        |> render_diagnose_session_result(json?)

      {:error, message} ->
        print_error_msg(message)
        {:error, 2}
    end
  end

  defp diagnose(_args) do
    print_error_msg("usage: pixir diagnose session <session_id> [--json]")
    {:error, 2}
  end

  defp parse_diagnose_session_args(args) do
    allowed_flags = ["--json"]

    cond do
      Enum.any?(args, &(String.starts_with?(&1, "-") and &1 not in allowed_flags)) ->
        {:error, "usage: pixir diagnose session <session_id> [--json]"}

      true ->
        json? = "--json" in args
        positional = args -- allowed_flags

        case positional do
          [session_id] -> {:ok, session_id, json?}
          _ -> {:error, "usage: pixir diagnose session <session_id> [--json]"}
        end
    end
  end

  defp render_diagnose_session_result({:ok, result}, json?) do
    if json? do
      IO.puts(Jason.encode!(json_ready(result)))
    else
      render_diagnose_session(result)
    end

    if result["ok"], do: :ok, else: {:error, 1}
  end

  defp render_diagnose_session_result({:error, error}, json?) do
    if json?, do: IO.puts(Jason.encode!(json_ready(error))), else: print_error(error)
    error_exit(error)
  end

  defp render_diagnose_session(result) do
    checks =
      result["checks"]
      |> Enum.map_join("\n", fn check ->
        "[#{check["status"]}] #{check["id"]}: #{check["message"]}"
      end)

    IO.puts("""
    Pixir session diagnosis
    status: #{result["status"]}
    session: #{result["session_id"]}
    workspace: #{result["workspace"]}

    #{checks}
    """)
  end

  defp tree(args) do
    case parse_tree_args(args) do
      {:ok, session_id, json?} ->
        render_tree(session_id, json?)

      {:error, message} ->
        print_error_msg(message)
        {:error, 2}
    end
  end

  defp parse_tree_args(args) do
    allowed_flags = ["--json"]

    cond do
      Enum.any?(args, &(String.starts_with?(&1, "-") and &1 not in allowed_flags)) ->
        {:error, "usage: pixir tree <session_id> [--json]"}

      true ->
        json? = "--json" in args
        positional = args -- allowed_flags

        case positional do
          [session_id] -> {:ok, session_id, json?}
          _ -> {:error, "usage: pixir tree <session_id> [--json]"}
        end
    end
  end

  defp render_tree(session_id, json?) do
    case SessionTree.project(session_id, workspace: File.cwd!()) do
      {:ok, tree} ->
        if json? do
          IO.puts(Jason.encode!(%{"ok" => true, "tree" => tree}))
        else
          IO.write(SessionTree.render(tree))
        end

        :ok

      {:error, error} ->
        if json?, do: IO.puts(Jason.encode!(json_ready(error))), else: print_error(error)
        error_exit(error)
    end
  end

  defp fork(args) do
    case parse_fork_args(args) do
      {:ok, parent_session_id, opts, json?} ->
        workspace = File.cwd!()

        result =
          if Keyword.get(opts, :dry_run, false) do
            Fork.dry_run(
              parent_session_id,
              Keyword.merge(opts, workspace: workspace, dry_run: true)
            )
          else
            Fork.fork(parent_session_id, opts ++ [workspace: workspace])
          end

        render_fork_result(result, json?)

      {:error, message} ->
        print_error_msg(message)
        {:error, 2}
    end
  end

  defp parse_fork_args(args) do
    parse_fork_args(args, %{
      json?: false,
      dry_run?: false,
      summarize?: false,
      to_seq: nil,
      positional: []
    })
  end

  defp parse_fork_args([], acc) do
    case Enum.reverse(acc.positional) do
      [parent_session_id] ->
        opts =
          []
          |> maybe_put(:dry_run, acc.dry_run?)
          |> maybe_put(:summarize, acc.summarize?)
          |> maybe_put(:to_seq, acc.to_seq)

        {:ok, parent_session_id, opts, acc.json?}

      _ ->
        {:error, "usage: pixir fork <session_id> [--to-seq N] [--summarize] [--dry-run] [--json]"}
    end
  end

  defp parse_fork_args(["--json" | rest], acc),
    do: parse_fork_args(rest, %{acc | json?: true})

  defp parse_fork_args(["--dry-run" | rest], acc),
    do: parse_fork_args(rest, %{acc | dry_run?: true})

  defp parse_fork_args(["--summarize" | rest], acc),
    do: parse_fork_args(rest, %{acc | summarize?: true})

  defp parse_fork_args(["--to-seq", value | rest], acc) do
    case Integer.parse(value) do
      {to_seq, ""} when to_seq >= 0 ->
        parse_fork_args(rest, %{acc | to_seq: to_seq})

      _ ->
        {:error, "--to-seq must be a non-negative integer"}
    end
  end

  defp parse_fork_args([flag | _rest], _acc) when flag in ["--to-seq"],
    do: {:error, "--to-seq requires a non-negative integer value"}

  defp parse_fork_args([flag | _rest], _acc) when binary_part(flag, 0, 1) == "-",
    do: {:error, "usage: pixir fork <session_id> [--to-seq N] [--summarize] [--dry-run] [--json]"}

  defp parse_fork_args([arg | rest], acc),
    do: parse_fork_args(rest, %{acc | positional: [arg | acc.positional]})

  defp maybe_put(opts, _key, false), do: opts
  defp maybe_put(opts, key, true), do: Keyword.put(opts, key, true)
  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp render_fork_result({:ok, result}, json?) do
    if json? do
      IO.puts(Jason.encode!(json_ready(result)))
    else
      render_fork(result)
    end

    :ok
  end

  defp render_fork_result({:error, error}, json?) do
    if json?, do: IO.puts(Jason.encode!(json_ready(error))), else: print_error(error)
    error_exit(error)
  end

  defp render_fork(%{"recorded" => false} = result) do
    IO.puts(
      "Fork plan for #{result["parent_session_id"]}: would create child #{result["child_session_id"]} " <>
        "with #{result["event_count"]} replayed events through seq #{result["to_seq"]}."
    )

    :ok
  end

  defp render_fork(%{"recorded" => true} = result) do
    IO.puts(
      "Forked #{result["parent_session_id"]} → #{result["child_session_id"]} " <>
        "(#{result["event_count"]} events through seq #{result["to_seq"]})."
    )

    IO.puts(:stderr, result["resume_command"])
    :ok
  end

  defp compact(args) do
    case parse_compact_args(args) do
      {:ok, session_id, opts, json?} ->
        result =
          if Keyword.get(opts, :dry_run, false) do
            Compaction.dry_run(session_id, Keyword.put(opts, :workspace, File.cwd!()))
          else
            Compaction.compact(session_id, Keyword.put(opts, :workspace, File.cwd!()))
          end

        render_compaction_result(result, json?)

      {:error, message} ->
        print_error_msg(message)
        {:error, 2}
    end
  end

  defp parse_compact_args(args) do
    parse_compact_args(args, %{json?: false, dry_run?: false, tail_events: nil, positional: []})
  end

  defp parse_compact_args([], acc) do
    case Enum.reverse(acc.positional) do
      [session_id] ->
        opts = [dry_run: acc.dry_run?]

        opts =
          if acc.tail_events, do: Keyword.put(opts, :tail_events, acc.tail_events), else: opts

        {:ok, session_id, opts, acc.json?}

      _ ->
        {:error, "usage: pixir compact <session_id> [--dry-run] [--json] [--tail-events N]"}
    end
  end

  defp parse_compact_args(["--json" | rest], acc),
    do: parse_compact_args(rest, %{acc | json?: true})

  defp parse_compact_args(["--dry-run" | rest], acc),
    do: parse_compact_args(rest, %{acc | dry_run?: true})

  defp parse_compact_args(["--tail-events", value | rest], acc) do
    case Integer.parse(value) do
      {tail_events, ""} when tail_events > 0 ->
        parse_compact_args(rest, %{acc | tail_events: tail_events})

      _ ->
        {:error, "--tail-events must be a positive integer"}
    end
  end

  defp parse_compact_args([flag | _rest], _acc) when flag in ["--tail-events"],
    do: {:error, "--tail-events requires a positive integer value"}

  defp parse_compact_args([flag | _rest], _acc) when binary_part(flag, 0, 1) == "-",
    do: {:error, "usage: pixir compact <session_id> [--dry-run] [--json] [--tail-events N]"}

  defp parse_compact_args([arg | rest], acc),
    do: parse_compact_args(rest, %{acc | positional: [arg | acc.positional]})

  defp render_compaction_result({:ok, result}, json?) do
    if json? do
      IO.puts(Jason.encode!(json_ready(result)))
    else
      render_compaction(result)
    end

    :ok
  end

  defp render_compaction_result({:error, error}, json?) do
    if json?, do: IO.puts(Jason.encode!(json_ready(error))), else: print_error(error)
    error_exit(error)
  end

  defp render_compaction(%{"compactable" => false} = result) do
    IO.puts("Nothing to compact: #{result["reason"] || "no compactable history"}")
  end

  defp render_compaction(%{"recorded" => true} = result) do
    range = result["event"]["range"]

    IO.puts(
      "Recorded compaction checkpoint at seq #{result["compaction_seq"]} for seq #{range["from_seq"]}..#{range["to_seq"]}."
    )
  end

  defp render_compaction(%{"compactable" => true} = result) do
    range = result["event"]["range"]

    IO.puts(
      "Would compact #{result["would_compact_events"]} events, seq #{range["from_seq"]}..#{range["to_seq"]}."
    )
  end

  defp inspect_replay(args) do
    case parse_inspect_replay_args(args) do
      {:ok, session_id, opts, json?} ->
        session_id
        |> ReplayInspector.inspect(Keyword.put(opts, :workspace, File.cwd!()))
        |> render_inspect_replay_result(json?)

      {:error, message} ->
        print_error_msg(message)
        {:error, 2}
    end
  end

  defp parse_inspect_replay_args(args) do
    parse_inspect_replay_args(args, %{json?: false, after_seq: nil, positional: []})
  end

  defp parse_inspect_replay_args([], acc) do
    case Enum.reverse(acc.positional) do
      [session_id] ->
        opts =
          if is_nil(acc.after_seq), do: [], else: [after_seq: acc.after_seq]

        {:ok, session_id, opts, acc.json?}

      _ ->
        {:error, "usage: pixir inspect-replay <session_id> [--after-seq N] [--json]"}
    end
  end

  defp parse_inspect_replay_args(["--json" | rest], acc),
    do: parse_inspect_replay_args(rest, %{acc | json?: true})

  defp parse_inspect_replay_args(["--after-seq", value | rest], acc) do
    case Integer.parse(value) do
      {after_seq, ""} when after_seq >= 0 ->
        parse_inspect_replay_args(rest, %{acc | after_seq: after_seq})

      _ ->
        {:error, "--after-seq must be a non-negative integer"}
    end
  end

  defp parse_inspect_replay_args([flag | _rest], _acc) when flag in ["--after-seq"],
    do: {:error, "--after-seq requires a non-negative integer value"}

  defp parse_inspect_replay_args([flag | _rest], _acc) when binary_part(flag, 0, 1) == "-",
    do: {:error, "usage: pixir inspect-replay <session_id> [--after-seq N] [--json]"}

  defp parse_inspect_replay_args([arg | rest], acc),
    do: parse_inspect_replay_args(rest, %{acc | positional: [arg | acc.positional]})

  defp render_inspect_replay_result({:ok, result}, json?) do
    if json? do
      IO.puts(Jason.encode!(json_ready(result)))
    else
      render_inspect_replay(result)
    end

    :ok
  end

  defp render_inspect_replay_result({:error, error}, json?) do
    if json?, do: IO.puts(Jason.encode!(json_ready(error))), else: print_error(error)
    error_exit(error)
  end

  defp render_inspect_replay(result) do
    events = result["events"]
    input = result["provider_input"]
    continuation = result["continuation"]

    IO.puts("Replay inspection for #{result["session_id"]}")

    IO.puts(
      "Events: #{events["inspected_count"]}/#{events["full_count"]}, seq #{events["from_seq"]}..#{events["to_seq"]}"
    )

    IO.puts(
      "Provider input: #{input["function_calls"]} function_call, " <>
        "#{input["function_call_outputs"]} function_call_output, balanced=#{input["balanced"]}"
    )

    if input["synthetic_orphan_closures"] != [] do
      IO.puts("Synthetic orphan closures:")

      Enum.each(input["synthetic_orphan_closures"], fn orphan ->
        IO.puts("  - #{orphan["call_id"]} (#{orphan["tool"] || "unknown"})")
      end)
    end

    if continuation["present"] do
      IO.puts(
        "Continuation: seq #{continuation["seq"]}, transport=#{continuation["active_transport"]}, " <>
          "attempted=#{continuation["continuation_attempted"]}, " <>
          "reset=#{continuation["continuation_reset_reason"] || "none"}"
      )
    else
      IO.puts("Continuation: none")
    end
  end

  defp delegate(args) do
    args
    |> Delegate.run_cli(workspace: File.cwd!(), runtime_opts: cli_turn_opts())
    |> render_delegate_result()
  end

  defp render_delegate_result({status, result}) when status in [:ok, :error] do
    if result.json? do
      IO.puts(Jason.encode!(result.payload))
    else
      render_delegate_text(status, result)
      print_delegate_recovery_hints(result.payload)
    end

    if after_render = Map.get(result, :after_render) do
      after_render.()
    end

    case {status, result.exit_code} do
      {:ok, 0} -> :ok
      _ -> {:error, result.exit_code}
    end
  end

  defp render_delegate_text(:ok, result), do: IO.puts(result.text)
  defp render_delegate_text(:error, result), do: print_error_msg(result.text)

  # Same mode contract as one-shot recovery: in --json mode guidance lives in the
  # envelope (children[].resume_command) and stderr stays silent; without --json,
  # each non-completed child prints its ready-made resume command on stderr.
  defp print_delegate_recovery_hints(%{"children" => children}) when is_list(children) do
    Enum.each(children, fn child ->
      with %{"resume_command" => cmd, "child_session_id" => sid, "status" => child_status}
           when is_binary(cmd) <- child do
        IO.puts(:stderr, "child #{sid} #{child_status}  (resume with: #{cmd})")
      end
    end)
  end

  defp print_delegate_recovery_hints(_payload), do: :ok

  defp one_shot(_mode, {:error, error}, runtime) do
    print_runtime_error(error, runtime.json?)
    {:error, 1}
  end

  defp one_shot(mode, {:ok, prompt}, runtime) do
    turn_opts = cli_turn_opts()

    with {:ok, policy_opts} <- prepare_runtime_policy(runtime),
         :ok <- ensure_policy_mode(mode, policy_opts, runtime),
         :ok <- ensure_interactive_ask(mode),
         {:ok, sid} <- start_session([], mode, policy_opts) do
      run_turn(
        sid,
        prompt,
        mode,
        Keyword.merge(
          turn_opts,
          policy_opts ++ runtime_turn_opts(runtime) ++ [json?: runtime.json?]
        )
      )
    else
      {:error, code} when is_integer(code) -> {:error, code}
      {:error, error} -> print_runtime_error_exit(error, runtime.json?)
    end
  end

  defp resume(mode, args, runtime) do
    turn_opts = cli_turn_opts()

    with {:ok, policy_opts} <- prepare_runtime_policy(runtime),
         :ok <- ensure_policy_mode(mode, policy_opts, runtime),
         :ok <- ensure_interactive_ask(mode),
         {:ok, resume_opts} <- parse_resume_args(args),
         {:ok, mode, policy_opts, attestation} <-
           restore_resume_posture(resume_opts, mode, policy_opts),
         :ok <- ensure_interactive_ask(mode),
         {:ok, prompt} <- read_prompt(resume_opts.prompt_args),
         {:ok, started_id} <- start_session(resume_start_opts(resume_opts), mode, policy_opts),
         :ok <- ensure_resume_id(started_id, resume_opts.id),
         :ok <- persist_legacy_root_attestation(attestation, resume_opts.id) do
      run_turn(
        resume_opts.id,
        prompt,
        mode,
        Keyword.merge(
          turn_opts,
          policy_opts ++ runtime_turn_opts(runtime) ++ [json?: runtime.json?]
        )
      )
    else
      {:error, code} when is_integer(code) -> {:error, code}
      {:error, error} -> print_runtime_error_exit(error, runtime.json?)
    end
  end

  defp parse_resume_args(args) do
    parse_resume_args(args, %{
      force_release_writer_lease?: false,
      force_release_reason: nil,
      assume_legacy_root?: false,
      legacy_root_reason: nil
    })
  end

  defp parse_resume_args([], _acc),
    do: {:error, Pixir.Tool.error(:invalid_args, "usage: pixir resume <id> \"prompt\"", %{})}

  defp parse_resume_args(["--force-release-writer-lease" | rest], acc),
    do: parse_resume_args(rest, %{acc | force_release_writer_lease?: true})

  defp parse_resume_args(["--force-release-reason", reason | rest], acc)
       when is_binary(reason) and reason != "",
       do: parse_resume_args(rest, %{acc | force_release_reason: reason})

  defp parse_resume_args(["--force-release-reason" | _rest], _acc),
    do:
      {:error,
       Pixir.Tool.error(:invalid_args, "--force-release-reason requires text", %{
         usage:
           "pixir resume [--force-release-writer-lease] [--force-release-reason TEXT] <id> \"prompt\""
       })}

  defp parse_resume_args(["--assume-legacy-root" | rest], acc),
    do: parse_resume_args(rest, %{acc | assume_legacy_root?: true})

  # The reason is a durable confession: whitespace is not a reason. The trimmed
  # text is what the attestation persists.
  defp parse_resume_args(["--legacy-root-reason", reason | rest], acc) when is_binary(reason) do
    case String.trim(reason) do
      "" ->
        {:error,
         Pixir.Tool.error(:invalid_args, "--legacy-root-reason requires text", %{
           usage: "pixir resume --assume-legacy-root --legacy-root-reason TEXT <id> \"prompt\""
         })}

      trimmed ->
        parse_resume_args(rest, %{acc | legacy_root_reason: trimmed})
    end
  end

  defp parse_resume_args(["--legacy-root-reason" | _rest], _acc),
    do:
      {:error,
       Pixir.Tool.error(:invalid_args, "--legacy-root-reason requires text", %{
         usage: "pixir resume --assume-legacy-root --legacy-root-reason TEXT <id> \"prompt\""
       })}

  defp parse_resume_args([arg | prompt_args], acc) when is_binary(arg) do
    if String.starts_with?(arg, "-") do
      {:error,
       Pixir.Tool.error(:invalid_args, "unsupported resume option", %{
         accepted_options: [
           "--force-release-writer-lease",
           "--force-release-reason",
           "--assume-legacy-root",
           "--legacy-root-reason"
         ]
       })}
    else
      validate_resume_args(
        acc
        |> Map.put(:id, arg)
        |> Map.put(:prompt_args, prompt_args)
      )
    end
  end

  defp validate_resume_args(%{force_release_writer_lease?: false, force_release_reason: reason})
       when is_binary(reason) do
    {:error,
     Pixir.Tool.error(
       :invalid_args,
       "--force-release-reason requires --force-release-writer-lease",
       %{
         next_actions: ["add_--force-release-writer-lease", "remove_--force-release-reason"]
       }
     )}
  end

  # The attestation is a durable confession: a nonempty operator reason is part
  # of the contract, not decoration — the flag pair travels together.
  defp validate_resume_args(%{assume_legacy_root?: true, legacy_root_reason: nil}) do
    {:error,
     Pixir.Tool.error(
       :invalid_args,
       "--assume-legacy-root requires --legacy-root-reason TEXT",
       %{
         next_actions: ["add_--legacy-root-reason_with_why_this_log_is_yours"]
       }
     )}
  end

  defp validate_resume_args(%{assume_legacy_root?: false, legacy_root_reason: reason})
       when is_binary(reason) do
    {:error,
     Pixir.Tool.error(
       :invalid_args,
       "--legacy-root-reason requires --assume-legacy-root",
       %{
         next_actions: ["add_--assume-legacy-root", "remove_--legacy-root-reason"]
       }
     )}
  end

  defp validate_resume_args(args), do: {:ok, args}

  defp resume_start_opts(resume_opts) do
    [
      id: resume_opts.id,
      force_release_writer_lease?: resume_opts.force_release_writer_lease?,
      force_release_reason: resume_opts.force_release_reason
    ]
  end

  defp ensure_resume_id(expected_id, expected_id), do: :ok

  defp ensure_resume_id(started_id, expected_id) do
    {:error,
     Pixir.Tool.error(:session_start_failed, "resumed Session id did not match requested id", %{
       started_id: started_id,
       expected_id: expected_id
     })}
  end

  # Start (or resume) via the driver, which centralizes the resume robustness
  # (session-exists guard, corrupt-log-as-structured-error). `:not_found` exits 2.
  # New root Sessions record mode + write policy as their durable posture; on a
  # resume (`:id` present) the driver ignores these and the durable posture wins.
  defp start_session(opts, mode, policy_opts) do
    start_opts =
      opts
      |> Keyword.put(:workspace, File.cwd!())
      |> Keyword.put(:permission_mode, mode)
      |> Keyword.put(:write_policy, Keyword.get(policy_opts, :write_policy))

    case Conversation.start(start_opts) do
      {:ok, _id} = ok -> ok
      {:error, %{error: %{kind: :not_found}} = err} -> print_error_return(err, 2)
      {:error, _} = err -> err
    end
  end

  # Subscribe, run the Turn through the driver, render bus events until terminal.
  # SIGINT is trapped at this Presenter boundary (ADR 0017): forward to
  # `Conversation.interrupt/1` while a Turn runs, exit without spurious Log events
  # when idle.
  defp run_turn(session_id, prompt, mode, turn_opts) do
    :ok = Conversation.subscribe(session_id)
    json? = Keyword.get(turn_opts, :json?, false)
    asker = if mode == :ask, do: &terminal_asker/1, else: fn _request -> :deny end
    await_opts = await_opts(turn_opts)

    turn_opts =
      turn_opts
      |> fold_web_search_flag()
      |> Keyword.drop([:skip_auth?, :idle_timeout, :json?])
      |> Keyword.merge(permission_mode: mode, asker: asker)

    {:ok, _ref} = Conversation.send(session_id, prompt, turn_opts)

    # One-shot final-report contract (ADR 0005): the streamed accumulator lets the
    # final assistant_message flush any text the transport never delivered as deltas,
    # and lets `:done` without a final report exit as an honest incomplete outcome.
    {:ok, report} =
      Agent.start_link(fn ->
        %{
          streamed: [],
          final: :none,
          output_truncation: nil,
          warnings: [],
          warning_count: 0,
          warning_keys: MapSet.new(),
          latest_warning_order_key: nil
        }
      end)

    sigint_trap =
      case Sigint.install(session_id) do
        {:ok, trap} -> trap
        :unsupported -> nil
      end

    try do
      on_event = fn event ->
        presentation = track_final_report(event, report)
        unless json?, do: render_tracked_event(event, presentation)
      end

      case Conversation.await(session_id, Keyword.put(await_opts, :on_event, on_event)) do
        :timeout ->
          finish_abnormal_one_shot(session_id, "timed_out", 124, json?)
          {:error, 124}

        :interrupted ->
          finish_abnormal_one_shot(session_id, "interrupted", 130, json?)
          {:error, 130}

        :error ->
          exit_code = failure_exit_code(session_id)
          finish_abnormal_one_shot(session_id, "error", exit_code, json?)
          {:error, exit_code}

        :done ->
          finish_one_shot(session_id, Agent.get(report, & &1), json?)
      end
    after
      if sigint_trap, do: Sigint.remove(sigint_trap)
      Agent.stop(report)
    end
  end

  # Only the timeout knob is a CLI/await concern; everything else in cli_turn_opts
  # belongs to the Turn.
  defp await_opts(turn_opts) do
    case Keyword.get(turn_opts, :idle_timeout) do
      timeout when is_integer(timeout) and timeout > 0 -> [idle_timeout: timeout]
      _ -> []
    end
  end

  # Each provider call starts at a status "thinking", so the streamed accumulator
  # resets per call and the final assistant_message compares against its own deltas.
  defp track_final_report(%{type: :status, data: %{"status" => "thinking"}}, report) do
    Agent.update(report, &%{&1 | streamed: []})
    :render
  end

  defp track_final_report(%{type: :text_delta, data: %{"chunk" => chunk}}, report) do
    Agent.update(report, fn state -> %{state | streamed: [chunk | state.streamed]} end)
    :render
  end

  defp track_final_report(%{type: :provider_usage} = event, report) do
    projection = Pixir.Provider.OutputTruncationSummary.project(event)
    warning = Pixir.Provider.OutputTruncationSummary.warning(event)

    Agent.get_and_update(report, fn state ->
      state =
        if projection["call_role"] == "final_answer" do
          %{state | output_truncation: projection}
        else
          state
        end

      case warning do
        nil ->
          {:render, state}

        warning ->
          {emit?, next} = track_cli_warning(state, event.session_id, warning)
          {if(emit?, do: :render, else: :suppress), next}
      end
    end)
  end

  defp track_final_report(%{type: :assistant_message, data: data} = event, report) do
    text = Map.get(data, "text", "")

    {streamed, presentation} =
      Agent.get_and_update(report, fn state ->
        streamed = IO.iodata_to_binary(Enum.reverse(state.streamed))
        state = %{state | final: text}

        case Pixir.Provider.OutputTruncationSummary.assistant_fallback(event) do
          {:ok, projection, warning} ->
            state = %{state | output_truncation: projection}
            {emit?, state} = track_cli_warning(state, event.session_id, warning)
            {{streamed, if(emit?, do: {:fallback_warning, warning}, else: :render)}, state}

          :error ->
            {{streamed, :render}, state}
        end
      end)

    # Channel discipline: the model's answer belongs on stdout even when the transport
    # delivered it only in the final message. Flush the unstreamed suffix before the
    # Renderer writes the closing newline; when the deltas mismatch the final text
    # (e.g. transport replay/duplication), the final message is authoritative — emit
    # it in full on its own line rather than dropping the report.
    cond do
      text == "" or text == streamed ->
        :ok

      String.starts_with?(text, streamed) ->
        IO.write(binary_part(text, byte_size(streamed), byte_size(text) - byte_size(streamed)))

      true ->
        IO.write(["\n", text])
    end

    presentation
  end

  defp track_final_report(_event, _report), do: :render

  defp track_cli_warning(state, session_id, warning) do
    key = {session_id, warning["provider_usage_event_id"]}
    order_key = {warning["provider_usage_seq"], warning["provider_usage_event_id"]}

    cond do
      MapSet.member?(state.warning_keys, key) ->
        {false, state}

      not is_nil(state.latest_warning_order_key) and order_key <= state.latest_warning_order_key ->
        {false, state}

      MapSet.size(state.warning_keys) < 256 ->
        {true,
         %{
           state
           | warnings: state.warnings ++ [warning],
             warning_count: state.warning_count + 1,
             warning_keys: MapSet.put(state.warning_keys, key),
             latest_warning_order_key: order_key
         }}

      true ->
        {false,
         %{
           state
           | warning_count: state.warning_count + 1,
             latest_warning_order_key: order_key
         }}
    end
  end

  defp render_tracked_event(_event, :suppress), do: :ok

  defp render_tracked_event(event, {:fallback_warning, warning}) do
    Renderer.write({:stderr, Renderer.output_truncation_warning(warning)})
    render_event(event)
  end

  defp render_tracked_event(event, :render), do: render_event(event)

  # A `:done` Turn without a non-empty final assistant message is an incomplete
  # outcome (exit 6, matching the Delegate contract), never a silent success.
  defp finish_one_shot(session_id, %{final: final} = report, true) do
    evidence = output_truncation_report(report)

    if is_binary(final) and String.trim(final) != "" do
      IO.puts(
        Jason.encode!(
          one_shot_payload(
            session_id,
            "completed",
            true,
            Map.put(evidence, "output", final)
          )
        )
      )

      :ok
    else
      IO.puts(
        Jason.encode!(
          one_shot_payload(
            session_id,
            "incomplete",
            false,
            %{
              "message" => "completed without a final assistant message"
            }
            |> Map.merge(evidence)
          )
        )
      )

      {:error, 6}
    end
  end

  defp finish_one_shot(session_id, %{final: final} = report, _json?) do
    maybe_render_suppression(report)

    if is_binary(final) and String.trim(final) != "" do
      print_session_resume_hint(session_id)
      :ok
    else
      IO.puts(:stderr, "\n[completed without a final assistant message]")
      IO.puts(:stderr, "inspect evidence with: #{diagnose_command(session_id)}")
      print_session_resume_hint(session_id)
      {:error, 6}
    end
  end

  defp output_truncation_report(report) do
    %{
      "output_truncation" => report.output_truncation,
      "warning_count" => report.warning_count,
      "warnings_truncated" => report.warning_count > length(report.warnings),
      "warnings" => report.warnings
    }
  end

  defp maybe_render_suppression(report) do
    if report.warning_count > length(report.warnings) do
      IO.write(
        :stderr,
        Renderer.output_truncation_suppression(report.warning_count, length(report.warnings))
      )
    end
  end

  defp finish_abnormal_one_shot(session_id, "timed_out", exit_code, true) do
    payload =
      session_id
      |> one_shot_payload(
        "timed_out",
        false,
        Map.put(latest_turn_failure(session_id), "recovery", timeout_recovery(session_id))
      )
      |> Map.put("exit_code", exit_code)

    IO.puts(Jason.encode!(json_ready(payload)))
  end

  defp finish_abnormal_one_shot(session_id, status, exit_code, true) do
    payload =
      session_id
      |> one_shot_payload(status, false, latest_turn_failure(session_id))
      |> Map.put("exit_code", exit_code)

    IO.puts(Jason.encode!(json_ready(payload)))
  end

  defp finish_abnormal_one_shot(session_id, "timed_out", _exit_code, _json?) do
    IO.puts(:stderr, "\n[timed out waiting for the model]")
    IO.puts(:stderr, "inspect evidence with: #{diagnose_command(session_id)}")
    print_session_resume_hint(session_id)
  end

  defp finish_abnormal_one_shot(session_id, "interrupted", _exit_code, _json?) do
    IO.puts(:stderr, "\n[interrupted]")
    print_session_resume_hint(session_id)
  end

  defp finish_abnormal_one_shot(session_id, _status, _exit_code, _json?) do
    print_session_resume_hint(session_id)
  end

  defp one_shot_payload(session_id, status, ok?, extra) do
    %{
      "ok" => ok?,
      "status" => status,
      "kind" => "one_shot_turn",
      "session_id" => session_id,
      "resume_command" => resume_command(session_id),
      "diagnostics" => %{
        "diagnose_command" => diagnose_command(session_id)
      }
    }
    |> Map.merge(extra)
  end

  defp timeout_recovery(session_id) do
    %{
      "classification" => "presenter_idle_timeout",
      "diagnose_command" => diagnose_command(session_id),
      "resume_command" => resume_command(session_id),
      "auto_retry" => %{
        "safe" => false,
        "reason" => "the presenter stopped waiting before Pixir could prove the Turn completed"
      },
      "next_actions" => [
        "inspect diagnostics before resuming write-capable work",
        "resume manually with the provided command if the Log shows no unsafe duplicate side effects",
        "avoid launching a second executor until the previous session state is understood"
      ]
    }
  end

  defp latest_turn_failure(session_id) do
    case Log.fold(session_id, workspace: File.cwd!()) do
      {:ok, history} ->
        history
        |> Enum.reverse()
        |> Enum.find(&(&1.type == :turn_failed))
        |> case do
          nil -> %{"message" => "turn failed before producing a final answer"}
          event -> Map.get(event, :data, %{})
        end

      {:error, error} ->
        %{"message" => "turn failed before producing a final answer", "diagnostic_error" => error}
    end
  end

  defp failure_exit_code(session_id) do
    case latest_turn_failure(session_id) do
      %{"error_kind" => "write_policy_denied"} -> 3
      %{"error_kind" => "permission_denied"} -> 3
      %{"error_kind" => "outside_workspace"} -> 3
      %{"error_kind" => "bash_disabled"} -> 3
      _ -> 1
    end
  end

  defp print_session_resume_hint(session_id) do
    IO.puts(
      :stderr,
      "\nsession #{session_id}  (resume with: #{resume_command(session_id)})"
    )
  end

  defp diagnose_command(session_id), do: recovery_commands(session_id)["diagnose_command"]
  defp resume_command(session_id), do: recovery_commands(session_id)["resume_command"]

  defp recovery_commands(session_id) do
    {:ok, commands} = RecoveryCommands.commands(session_id)
    commands
  end

  defp render_event(event), do: Enum.each(Renderer.render(event), &Renderer.write/1)

  # ── helpers ─────────────────────────────────────────────────────────────

  defp cli_turn_opts do
    Application.get_env(:pixir, :cli_turn_opts, [])
  end

  defp prepare_runtime_policy(%{write_policy_path: nil}), do: {:ok, []}

  defp prepare_runtime_policy(%{write_policy_path: path}) do
    case WritePolicy.from_file(path, File.cwd!()) do
      {:ok, policy} -> {:ok, [write_policy: policy]}
      {:error, error} -> {:error, error}
    end
  end

  defp restore_resume_posture(resume_opts, requested_mode, policy_opts) do
    requested_policy = Keyword.get(policy_opts, :write_policy)

    case Subagents.resume_posture(resume_opts.id, workspace: File.cwd!()) do
      {:ok, _durable_posture} when resume_opts.assume_legacy_root? ->
        {:error,
         Pixir.Tool.error(
           :invalid_args,
           "--assume-legacy-root does not apply: this Log resumes without an override",
           %{"next_actions" => ["resume_without_--assume-legacy-root"]}
         )}

      {:ok, durable_posture} ->
        with {:ok, effective_posture} <-
               Subagents.restrict_resume_posture(
                 durable_posture,
                 requested_mode,
                 requested_policy
               ) do
          opts =
            if effective_posture.write_policy,
              do: [write_policy: effective_posture.write_policy],
              else: []

          {:ok, effective_posture.permission_mode, opts, nil}
        end

      {:error, %{error: %{kind: :resume_policy_unavailable, details: %{"reason" => "missing"}}}} =
          missing_error ->
        attest_legacy_root(
          resume_opts,
          requested_mode,
          requested_policy,
          policy_opts,
          missing_error
        )

      {:error, _error} = error ->
        error
    end
  end

  # `missing` is the ONE overrideable posture failure (a readable Log that
  # predates posture evidence). Lineage is unprovable from the Log alone — this
  # could be a legacy bounded child — so the attestation can never grant
  # unbounded auto: read_only, ask, or auto with an explicit bounded policy.
  defp attest_legacy_root(%{assume_legacy_root?: false}, _mode, _policy, _opts, missing_error),
    do: missing_error

  defp attest_legacy_root(_resume_opts, :auto, nil, _policy_opts, _missing_error) do
    {:error,
     Pixir.Tool.error(
       :invalid_args,
       "--assume-legacy-root cannot grant unbounded auto: legacy lineage is ambiguous and the Log could be a bounded child",
       %{"next_actions" => ["add_--read-only_or_--ask_or_an_explicit_bounded_--write-policy"]}
     )}
  end

  defp attest_legacy_root(resume_opts, mode, policy, policy_opts, _missing_error) do
    attestation = %{
      "event" => "permission_posture",
      "scope" => "session",
      "lineage" => "root",
      "source" => "operator_attested_legacy_root",
      "attestation_reason" => resume_opts.legacy_root_reason,
      "prior_classification" => "missing",
      "permission_mode" => Atom.to_string(mode),
      "write_policy" => WritePolicy.metadata(policy),
      "workspace_mode" => "shared",
      "workspace" => File.cwd!()
    }

    {:ok, mode, policy_opts, attestation}
  end

  defp persist_legacy_root_attestation(nil, _session_id), do: :ok

  defp persist_legacy_root_attestation(attestation, session_id) do
    recorder =
      Application.get_env(:pixir, :cli_attestation_recorder, &Session.record/2)

    case recorder.(session_id, Event.subagent_event(session_id, attestation)) do
      {:ok, _event} ->
        :ok

      {:error, _error} = error ->
        # The Session started before this append; a failed attestation must not
        # leave a live writer behind (same contract as the ACP fail-closed path
        # and Conversation.start_new's posture failure).
        SessionSupervisor.stop_session(session_id)
        error
    end
  end

  defp runtime_turn_opts(runtime) do
    bash_opts =
      case runtime do
        %{bash_timeout_ms: timeout_ms} when is_integer(timeout_ms) ->
          [bash_timeout_ms: timeout_ms, bash_timeout_source: "cli"]

        _runtime ->
          []
      end

    bash_opts ++ attachment_turn_opts(runtime) ++ web_search_turn_opts(runtime)
  end

  defp attachment_turn_opts(%{attach_paths: [_ | _]} = runtime),
    do: [attachments: cli_attachments(runtime)]

  defp attachment_turn_opts(_runtime), do: []

  defp web_search_turn_opts(%{web_search?: true}), do: [web_search?: true]
  defp web_search_turn_opts(_runtime), do: []

  # The --web-search flag folds into provider_opts at the one site shared by
  # one-shot and resume, so it can never clobber a provider_opts list injected
  # through the cli_turn_opts seam.
  defp fold_web_search_flag(turn_opts) do
    case Keyword.pop(turn_opts, :web_search?) do
      {true, rest} ->
        Keyword.update(rest, :provider_opts, [web_search: %{"enabled" => true}], fn opts ->
          Keyword.put_new(opts, :web_search, %{"enabled" => true})
        end)

      {_absent, rest} ->
        rest
    end
  end

  defp ensure_policy_mode(_mode, [], _runtime), do: :ok

  defp ensure_policy_mode(:auto, _policy_opts, _runtime), do: :ok

  defp ensure_policy_mode(mode, _policy_opts, _runtime) do
    {:error,
     Pixir.Tool.error(:invalid_args, "--write-policy requires auto permission mode", %{
       "mode" => Atom.to_string(mode),
       "next_actions" => ["remove_--ask_or_--read-only", "run_policy_in_auto_mode"]
     })}
  end

  defp ensure_interactive_ask(:ask) do
    if cli_interactive?() do
      :ok
    else
      print_error(headless_ask_error())
      {:error, 3}
    end
  end

  defp ensure_interactive_ask(_mode), do: :ok

  defp headless_ask_error do
    Pixir.Tool.error(
      :permission_denied,
      "--ask requires an interactive TTY; use --read-only, explicit auto-mode approval, or a bounded write policy for headless orchestration",
      %{
        mode: "ask",
        requires_tty: true,
        next_actions: [
          "rerun from an interactive terminal if per-action approval is required",
          "use --read-only for read-only delegation",
          "use explicit auto-mode approval only inside an isolated workspace or future bounded write policy"
        ]
      }
    )
  end

  defp cli_interactive? do
    case Application.get_env(:pixir, :cli_interactive?) do
      fun when is_function(fun, 0) -> fun.() == true
      value when is_boolean(value) -> value
      _ -> stdio_terminal?()
    end
  end

  defp stdio_terminal? do
    case :io.getopts(:standard_io) do
      opts when is_list(opts) -> Keyword.get(opts, :terminal, false) == true
      _other -> false
    end
  rescue
    _ -> false
  catch
    _, _ -> false
  end

  # Prompt from argv (joined) or, if absent/`-`, from stdin.
  defp read_prompt(args) do
    case Enum.join(args, " ") |> String.trim() do
      "" -> read_stdin()
      "-" -> read_stdin()
      prompt -> {:ok, prompt}
    end
  end

  defp read_stdin do
    case IO.read(:stdio, :eof) do
      :eof ->
        {:error, Pixir.Tool.error(:no_prompt, "no prompt given (pass an argument or pipe stdin)")}

      {:error, reason} ->
        {:error, Pixir.Tool.error(:stdin_error, "could not read stdin", %{reason: reason})}

      data ->
        resolve_stdin(String.trim(data))
    end
  end

  defp resolve_stdin(""),
    do: {:error, Pixir.Tool.error(:no_prompt, "no prompt given (pass an argument or pipe stdin)")}

  defp resolve_stdin(text), do: {:ok, text}

  defp help?(args), do: Enum.any?(args, &(&1 in ["-h", "--help"]))

  defp invalid_doctor_args?(args), do: Enum.any?(args, &(&1 not in ["--json"]))

  # Interactive asker for `--ask` (ADR 0006): prompt on stderr, read y/N from stdin.
  defp terminal_asker(%{tool: tool, args: args, reason: reason}) do
    IO.write(:stderr, "\nAllow Pixir to #{reason}?  (#{tool} #{inspect(args)})\n  [y/N] ")

    case IO.gets("") do
      response when is_binary(response) ->
        if String.trim(response) in ["y", "Y", "yes"], do: :allow, else: :deny

      _ ->
        :deny
    end
  end

  defp print_error(%{error: %{kind: kind, message: message}}),
    do: print_error_msg("#{kind}: #{message}")

  defp print_error(other), do: print_error_msg(inspect(other))

  defp print_runtime_error(error, true) do
    IO.puts(Jason.encode!(json_ready(error)))
    true
  end

  defp print_runtime_error(error, _json?), do: print_error(error)

  defp print_runtime_error_exit(error, json?) do
    print_runtime_error(error, json?)
    error_exit(error)
  end

  defp print_error_return(error, code) when is_map(error) do
    print_error(error)
    {:error, code}
  end

  defp print_error_return(message, code) when is_binary(message) do
    print_error_msg(message)
    {:error, code}
  end

  defp error_exit(%{error: %{kind: :not_found}}), do: {:error, 2}

  defp error_exit(%{error: %{kind: kind}}) when kind in [:invalid_args, :unknown_tool],
    do: {:error, 2}

  defp error_exit(%{error: %{kind: kind}})
       when kind in [:permission_denied, :write_policy_denied, :outside_workspace, :bash_disabled],
       do: {:error, 3}

  defp error_exit(%{error: %{kind: kind}})
       when kind in [
              :session_writer_active,
              :session_writer_stale,
              :session_writer_ambiguous,
              :session_writer_lost
            ],
       do: {:error, 5}

  defp error_exit(_error), do: {:error, 1}

  defp json_ready(%{} = map) do
    Map.new(map, fn {key, value} -> {json_ready(key), json_ready(value)} end)
  end

  defp json_ready(list) when is_list(list), do: Enum.map(list, &json_ready/1)
  defp json_ready(value) when is_boolean(value) or is_nil(value), do: value
  defp json_ready(atom) when is_atom(atom), do: Atom.to_string(atom)
  defp json_ready(other), do: other

  defp print_error_msg(message) do
    IO.puts(:stderr, "error: #{message}")
    true
  end

  defp halt(:ok), do: halt_with_cleanup(0)
  defp halt({:error, code}), do: halt_with_cleanup(code)

  defp halt_with_cleanup(code) do
    case stop_sessions_before_halt() do
      {:ok, _summary} ->
        :ok

      {:error, error} ->
        IO.puts(:stderr, "warning: Session cleanup before exit failed: #{inspect(error)}")
    end

    cli_halt_fun().(code)
  end

  defp stop_sessions_before_halt do
    try do
      SessionSupervisor.stop_all_sessions()
    rescue
      exception ->
        {:error,
         %{
           ok: false,
           error: %{
             kind: :session_shutdown_failed,
             message: "Session cleanup before exit raised",
             details: %{exception: Exception.message(exception)}
           }
         }}
    catch
      kind, reason ->
        {:error,
         %{
           ok: false,
           error: %{
             kind: :session_shutdown_failed,
             message: "Session cleanup before exit exited",
             details: %{kind: kind, reason: inspect(reason)}
           }
         }}
    end
  end

  defp cli_halt_fun do
    Application.get_env(:pixir, :cli_halt_fun, &System.halt/1)
  end

  # ── help text ─────────────────────────────────────────────────────────────

  defp usage do
    IO.puts("""
    pixir #{Pixir.version()} — OTP-native coding agent

    Usage:
      pixir "prompt"            Run one Turn in the current directory
      pixir [--json] [--attach PATH] [--bash-timeout-ms N] --write-policy <policy.json> "prompt"
                                Run a bounded-write headless Turn
      pixir resume <id> "..."   Continue a persisted Session
      pixir resume --force-release-writer-lease <id> "..."
                                Resume after explicitly releasing stale writer evidence
      pixir resume --assume-legacy-root --legacy-root-reason TEXT <id> "..."
                                Recover a pre-posture Log (never as unbounded auto)
      pixir [--json] [--bash-timeout-ms N] --write-policy <policy.json> resume <id> "..."
                                Continue with the same bounded-write guard
      pixir login               Sign in (browser OAuth; device-code fallback)
      pixir doctor [--json]     Run local first-run diagnostics (no network)
      pixir models [--json]     Show current provider catalogs (no network)
      pixir models refresh [--json]
                                Explicitly refresh supported provider catalogs
      pixir gc [--apply] [--json]
                                Plan or apply isolated Subagent reclamation
      pixir diagnose session <id> [--json]
      pixir tree <id> [--json]  Project a Session/Subagent tree from local Logs
      pixir compact <id>        Record a durable History compaction checkpoint
      pixir fork <id>           Create a child Session from a parent History prefix
      pixir inspect-replay <id> Inspect Provider replay input without network
      pixir delegate --spec <path|-> [--dry-run] [--json] [--contract-version 1] [--timeout-ms N]
      pixir delegate start --spec <path|-> [--json] [--contract-version 1] [--timeout-ms N]
      pixir delegate status <delegate_id|parent_session_id> [--json] [--contract-version 1]
      pixir delegate attach <delegate_id|parent_session_id> [--json] [--contract-version 1] [--progress=stderr-jsonl] [--wait-horizon-ms N]
      pixir delegate cancel <delegate_id|parent_session_id> [--json] [--contract-version 1]
      pixir delegate daemon --foreground|--status|--stop [--json] [--contract-version 1]
      pixir acp                 Speak Agent Client Protocol over stdio (for ACP clients)
      pixir --version           Print the version and exit
      pixir help                Show this help

    Permission flags (default is auto — tools run without prompts):
      --ask                     Prompt before writes / unsafe shell commands
                                (requires an interactive TTY; headless runs fail fast)
      --read-only               Refuse mutating tools (reads + safe commands only)
      --write-policy <json>     Bounded headless write/edit allowlist for one-shot
                                and resume; requires auto mode and disables mutating
                                bash in v1

    Runtime output:
      --json                    Emit machine-readable output for models, gc; for one-shot/resume,
                                suppress streaming presenter output and emit one final
                                JSON envelope on stdout
      --bash-timeout-ms <ms>    Override bash tool timeout for this one-shot/resume
                                run, bounded by config bash_timeout_max_ms

    A prompt may be passed as an argument or piped on stdin. The model's answer is
    written to stdout; activity and the resumable session id go to stderr. One-shot
    exit codes: 0 answer delivered; 1 turn error; 6 turn completed without a final
    assistant message; 124 idle timeout; 130 interrupted. Abnormal exits print the
    exact resume command on stderr.
    """)

    :ok
  end

  defp doctor_help do
    IO.puts("""
    pixir doctor [--json] — run local first-run diagnostics.

    This command does not call the model or the network. It checks the source-install
    binary, workspace/session-log writability, local credential presence, config.json
    shape, and ACP command availability. It may create .pixir/sessions and remove a
    temporary probe file. Use --json for machine-readable output.

    The JSON envelope carries "proceed" for automation: "true" (delegate freely),
    "judge" (ready with warnings — read "judge_checks" for the non-ok check ids
    and decide), or "block" (do not delegate).
    """)

    :ok
  end

  defp diagnose_help do
    IO.puts("""
    pixir diagnose session <session_id> [--json]

    Run read-only Doctor+ diagnostics for a persisted Session Log. This command does
    not call auth, the network, or the model. It combines Log pairing, Provider replay
    inspection, Workflow event/checkpoint diagnostics, Session tree projection, and
    latest provider_usage metadata. Use --json for machine-readable output.
    """)

    :ok
  end

  defp tree_help do
    IO.puts("""
    pixir tree <session_id> [--json] — project a Session/Subagent tree from local Logs.

    This command is read-only and does not call the model or the network. It folds the
    root Session Log, follows durable subagent_event child references, discovers fork
    children from session_fork lineage metadata, and reports missing child Logs honestly
    instead of treating them as runtime state. Use --json for machine-readable output.
    """)

    :ok
  end

  defp compact_help do
    IO.puts("""
    pixir compact <session_id> [--dry-run] [--json] [--tail-events N]

    Record a durable history_compaction checkpoint for a local Session Log. The full
    NDJSON Log is not deleted or rewritten; Provider replay uses the latest checkpoint
    plus the recent uncompressed tail. Use --dry-run to inspect the plan without
    appending an event, --json for machine-readable output, and --tail-events to keep a
    larger or smaller recent tail.
    """)

    :ok
  end

  defp fork_help do
    IO.puts("""
    pixir fork <session_id> [--to-seq N] [--summarize] [--dry-run] [--json]

    Create a new child Session from a parent History prefix in the same workspace.
    resume continues the same Session Log; fork creates a new Session Log and diverges;
    compact keeps the same Session and records a lossy checkpoint for Provider replay.

    Default --to-seq is the full replayable parent prefix. Use --dry-run to inspect the
    plan without writing the child Log and --json for machine-readable output.
    --summarize records a deterministic branch_summary Event after the replayed prefix.
    """)

    :ok
  end

  defp inspect_replay_help do
    IO.puts("""
    pixir inspect-replay <session_id> [--after-seq N] [--json]

    Reconstruct the Provider replay input from a local Session Log without calling auth,
    the network, or the model. --after-seq N means "inspect the replay state after Event
    seq N" and includes events with seq <= N. Use --json for machine-readable output.
    """)

    :ok
  end

  defp delegate_help do
    IO.puts("""
    pixir delegate --spec <path|-> [--dry-run] [--json] [--contract-version 1] [--timeout-ms N]
    pixir delegate start --spec <path|-> [--json] [--contract-version 1] [--timeout-ms N]
    pixir delegate status <delegate_id|parent_session_id> [--json] [--contract-version 1]
    pixir delegate attach <delegate_id|parent_session_id> [--json] [--contract-version 1] [--progress=stderr-jsonl] [--wait-horizon-ms N]
    pixir delegate cancel <delegate_id|parent_session_id> [--json] [--contract-version 1]
    pixir delegate daemon --foreground|--status|--stop [--json] [--contract-version 1]

    Validate or run the Delegate CLI I/O Contract v1 for Codex/GPT-first callers. The
    runtime path is attached-first: it reads one JSON spec from a file or stdin and
    emits one final result envelope. --dry-run validates strategy/limits without
    provider, Subagent, Workflow, host command, or artifact execution.

    The first runtime path supports strategy="subagents". strategy="workflow" remains
    dry-run-valid but returns a structured unsupported runtime result without --dry-run.
    Use --json for machine-readable stdout. attach --progress=stderr-jsonl emits bounded
    progress frames to stderr while stdout remains one final JSON envelope; add
    --wait-horizon-ms N to follow a live owner for a bounded horizon. status reads
    durable Session Log evidence by Delegate id or parent Session id without network or
    host execution; attach remains snapshot-first and reports whether frames came from
    a live owner or durable fallback. start requires a reachable manual foreground
    daemon so returned running work survives the short-lived CLI process. status,
    attach, and cancel use the daemon when reachable, otherwise they fall back to
    durable Log snapshots or honest owner-unavailable state. The daemon is manual and
    workspace-local; full streaming attach remains future work.
    """)

    :ok
  end

  defp login_help do
    IO.puts("""
    pixir login — sign in with ChatGPT (Codex) via browser OAuth.

    Opens (or prints) an authorize URL and listens on 127.0.0.1:1455 for the
    callback. The credential is saved to ~/.pixir/auth.json (auto-refreshed).

    If the callback port is unavailable, pixir falls back to device-code OAuth.
    Use `pixir login --device-code` to skip the browser flow.

    Alternatively, set OPENAI_API_KEY to use a pay-per-token key instead.
    """)

    :ok
  end

  defp resume_help do
    IO.puts("""
    pixir resume [--force-release-writer-lease] [--force-release-reason TEXT]
                 [--assume-legacy-root --legacy-root-reason TEXT] <id> "prompt"
    — continue a persisted Session.

    The Session id is printed (on stderr) at the end of each run. Sessions live in
    .pixir/sessions/<id>.ndjson in the directory where they were created.

    --force-release-writer-lease is a break-glass option for stale or ambiguous Session
    writer lease evidence. Active leases are refused. A diagnostic release record is
    written under .pixir/session_leases/releases/ before Pixir starts a new writer.

    --assume-legacy-root recovers a Log that predates permission-posture evidence and
    fails closed with reason "missing" (write-capable history, no posture). It requires
    a nonempty --legacy-root-reason and an explicit posture: --read-only, --ask, or
    --write-policy FILE. It can never grant unbounded auto — from the Log alone a
    legacy root and a legacy bounded child are indistinguishable. The attestation is
    persisted to the Log, so later resumes need no override.
    """)

    :ok
  end
end
