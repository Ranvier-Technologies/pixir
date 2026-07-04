defmodule Pixir.CLI do
  @moduledoc """
  Escript entry point — one-shot, print-first (ADR 0001). Commands:

      pixir login              Browser OAuth (device-code fallback) → ~/.pixir/auth.json
      pixir doctor             Run local first-run diagnostics (no network)
      pixir tree <id>          Project a Session/Subagent tree from local Logs
      pixir compact <id>       Record a durable History compaction checkpoint
      pixir fork <id>          Create a child Session from a parent History prefix
      pixir inspect-replay <id> Inspect Provider replay input without network
      pixir delegate           Validate or run a Delegate CLI spec
      pixir "prompt"           Run one Turn in the current directory, stream to stdout
      pixir [--json] [--bash-timeout-ms N] --write-policy <policy.json> "prompt"
                               Run a bounded-write headless Turn with JSON output
      pixir resume <id> "..."  Continue a persisted Session
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
    Fork,
    Log,
    Permissions,
    Permissions.WritePolicy,
    ReplayInspector,
    RecoveryCommands,
    Renderer,
    SessionDiagnostics,
    SessionTree
  }

  alias Pixir.CLI.Sigint

  @write_policy_unsupported_commands ~w(
    login doctor diagnose tree compact fork inspect-replay delegate acp help version --version -v -h --help
  )
  @bash_timeout_unsupported_commands @write_policy_unsupported_commands

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
    if help?(rest), do: resume_help(), else: resume(mode, rest, runtime)
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
        bash_timeout_ms: nil
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

  defp extract_runtime_options(argv, acc), do: {:ok, argv, acc}

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
        "usage" => "pixir [--json] [--bash-timeout-ms N] \"prompt\"",
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

  defp one_shot(_mode, {:error, error}, runtime) do
    print_runtime_error(error, runtime.json?)
    {:error, 1}
  end

  defp one_shot(mode, {:ok, prompt}, runtime) do
    turn_opts = cli_turn_opts()

    with {:ok, policy_opts} <- prepare_runtime_policy(runtime),
         :ok <- ensure_policy_mode(mode, policy_opts, runtime),
         :ok <- ensure_interactive_ask(mode),
         :ok <- require_auth(turn_opts),
         {:ok, sid} <- start_session([], mode) do
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
         :ok <- require_auth(turn_opts),
         {:ok, prompt} <- read_prompt(resume_opts.prompt_args),
         {:ok, started_id} <- start_session(resume_start_opts(resume_opts), mode),
         :ok <- ensure_resume_id(started_id, resume_opts.id) do
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
      force_release_reason: nil
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

  defp parse_resume_args([arg | prompt_args], acc) when is_binary(arg) do
    if String.starts_with?(arg, "-") do
      {:error,
       Pixir.Tool.error(:invalid_args, "unsupported resume option", %{
         option: arg,
         accepted_options: ["--force-release-writer-lease", "--force-release-reason"]
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
  defp start_session(opts, _mode) do
    case Conversation.start(Keyword.put(opts, :workspace, File.cwd!())) do
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
      |> Keyword.drop([:skip_auth?, :idle_timeout, :json?])
      |> Keyword.merge(permission_mode: mode, asker: asker)

    {:ok, _ref} = Conversation.send(session_id, prompt, turn_opts)

    # One-shot final-report contract (ADR 0005): the streamed accumulator lets the
    # final assistant_message flush any text the transport never delivered as deltas,
    # and lets `:done` without a final report exit as an honest incomplete outcome.
    {:ok, report} = Agent.start_link(fn -> %{streamed: [], final: :none} end)

    sigint_trap =
      case Sigint.install(session_id) do
        {:ok, trap} -> trap
        :unsupported -> nil
      end

    try do
      on_event = fn event ->
        track_final_report(event, report)
        unless json?, do: render_event(event)
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
  defp track_final_report(%{type: :status, data: %{"status" => "thinking"}}, report),
    do: Agent.update(report, &%{&1 | streamed: []})

  defp track_final_report(%{type: :text_delta, data: %{"chunk" => chunk}}, report),
    do: Agent.update(report, fn state -> %{state | streamed: [chunk | state.streamed]} end)

  defp track_final_report(%{type: :assistant_message, data: data}, report) do
    text = Map.get(data, "text", "")

    streamed =
      Agent.get_and_update(report, fn state ->
        {IO.iodata_to_binary(Enum.reverse(state.streamed)), %{state | final: text}}
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

    :ok
  end

  defp track_final_report(_event, _report), do: :ok

  # A `:done` Turn without a non-empty final assistant message is an incomplete
  # outcome (exit 6, matching the Delegate contract), never a silent success.
  defp finish_one_shot(session_id, %{final: final}, true) do
    if is_binary(final) and String.trim(final) != "" do
      IO.puts(
        Jason.encode!(one_shot_payload(session_id, "completed", true, %{"output" => final}))
      )

      :ok
    else
      IO.puts(
        Jason.encode!(
          one_shot_payload(session_id, "incomplete", false, %{
            "message" => "completed without a final assistant message"
          })
        )
      )

      {:error, 6}
    end
  end

  defp finish_one_shot(session_id, %{final: final}, _json?) do
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

  defp runtime_turn_opts(%{bash_timeout_ms: timeout_ms}) when is_integer(timeout_ms),
    do: [bash_timeout_ms: timeout_ms, bash_timeout_source: "cli"]

  defp runtime_turn_opts(_runtime), do: []

  defp ensure_policy_mode(_mode, [], _runtime), do: :ok

  defp ensure_policy_mode(:auto, _policy_opts, _runtime), do: :ok

  defp ensure_policy_mode(mode, _policy_opts, _runtime) do
    {:error,
     Pixir.Tool.error(:invalid_args, "--write-policy requires auto permission mode", %{
       "mode" => Atom.to_string(mode),
       "next_actions" => ["remove_--ask_or_--read-only", "run_policy_in_auto_mode"]
     })}
  end

  defp require_auth(opts) do
    if Keyword.get(opts, :skip_auth?, false) or Auth.authenticated?() do
      :ok
    else
      print_error_msg("not signed in — run `pixir login` or set OPENAI_API_KEY")
      {:error, 1}
    end
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
       when kind in [:permission_denied, :write_policy_denied, :outside_workspace],
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

  defp halt(:ok), do: System.halt(0)
  defp halt({:error, code}), do: System.halt(code)

  # ── help text ─────────────────────────────────────────────────────────────

  defp usage do
    IO.puts("""
    pixir #{Pixir.version()} — OTP-native coding agent

    Usage:
      pixir "prompt"            Run one Turn in the current directory
      pixir [--json] [--bash-timeout-ms N] --write-policy <policy.json> "prompt"
                                Run a bounded-write headless Turn
      pixir resume <id> "..."   Continue a persisted Session
      pixir resume --force-release-writer-lease <id> "..."
                                Resume after explicitly releasing stale writer evidence
      pixir [--json] [--bash-timeout-ms N] --write-policy <policy.json> resume <id> "..."
                                Continue with the same bounded-write guard
      pixir login               Sign in (browser OAuth; device-code fallback)
      pixir doctor [--json]     Run local first-run diagnostics (no network)
      pixir diagnose session <id> [--json]
      pixir tree <id> [--json]  Project a Session/Subagent tree from local Logs
      pixir compact <id>        Record a durable History compaction checkpoint
      pixir fork <id>           Create a child Session from a parent History prefix
      pixir inspect-replay <id> Inspect Provider replay input without network
      pixir delegate --spec <path|-> --dry-run [--json]
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
      --json                    For one-shot/resume, suppress streaming presenter
                                output and emit one final JSON envelope on stdout
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
    pixir delegate --spec <path|-> [--dry-run] [--json] [--contract-version 1]
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
    pixir resume [--force-release-writer-lease] [--force-release-reason TEXT] <id> "prompt"
    — continue a persisted Session.

    The Session id is printed (on stderr) at the end of each run. Sessions live in
    .pixir/sessions/<id>.ndjson in the directory where they were created.

    --force-release-writer-lease is a break-glass option for stale or ambiguous Session
    writer lease evidence. Active leases are refused. A diagnostic release record is
    written under .pixir/session_leases/releases/ before Pixir starts a new writer.
    """)

    :ok
  end
end
