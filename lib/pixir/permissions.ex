defmodule Pixir.Permissions do
  @moduledoc """
  Permission policy (ADR 0006). Pure decision function — the Executor consults it and,
  for `:ask`, calls a front-end-supplied *asker*.

  Modes:

    * `:auto` (default) — everything is allowed; no prompts. The blessed common path.
    * `:ask` — only genuinely risky operations prompt. `read` never asks; `bash`
      commands on a conservative safe-list auto-run; `write` and non-safe `bash` ask.
    * `:read_only` — mutating tools are denied; reads and safe commands run.

  Workspace confinement is enforced elsewhere (the tools) and is the real floor in every
  mode — this layer is a convenience gate on top.
  """

  @type mode :: :auto | :ask | :read_only
  @type decision :: :allow | :deny | {:ask, String.t()}

  # Read-only shell commands that are safe to auto-run even under :ask. A command is
  # only safe if its executable is here AND it has no chaining/redirection/substitution.
  # Wrapper commands such as `env` must wrap another safe command; `find` is safe only
  # when it does not use mutating predicates.
  @safe_commands ~w(ls cat pwd echo grep rg find head tail wc which whoami date env true
                    git ripgrep tree stat file dirname basename realpath sort uniq diff)

  @shell_metachars ["\n", "\r", "&&", "||", ";", "|", "&", ">", "<", "`", "$(", ">>"]

  # Subcommands that make otherwise-safe binaries (e.g. git) mutating.
  @unsafe_git_subcommands ~w(push commit merge rebase reset checkout clean rm mv add tag fetch pull)
  @mutating_find_predicates ~w(-delete -exec -execdir -ok -okdir)

  @doc "All valid permission modes."
  @spec modes() :: [mode()]
  def modes, do: [:auto, :ask, :read_only]

  @doc "Decide whether a tool call may run under `mode`."
  @spec decide(mode(), String.t(), map()) :: decision()
  def decide(:auto, _tool, _args), do: :allow

  def decide(:read_only, tool, args) do
    if mutating?(tool, args), do: :deny, else: :allow
  end

  def decide(:ask, tool, args) do
    if mutating?(tool, args), do: {:ask, reason(tool)}, else: :allow
  end

  @doc "Whether a tool call mutates state (and so is gated outside `:auto`)."
  @spec mutating?(String.t(), map()) :: boolean()
  def mutating?("read", _args), do: false
  def mutating?("skills_list", _args), do: false
  def mutating?("skill_view", _args), do: false
  def mutating?("wait_agent", _args), do: false
  def mutating?("list_agents", _args), do: false
  def mutating?("run_workflow", _args), do: true
  def mutating?("spawn_agent", _args), do: true
  def mutating?("send_input", _args), do: true
  def mutating?("close_agent", _args), do: true
  # `update_plan` only publishes an ephemeral plan Event (no files, no commands),
  # so it is allowed even in `:read_only`/plan mode — it IS plan mode's tool.
  def mutating?("update_plan", _args), do: false
  def mutating?("write", _args), do: true
  def mutating?("bash", %{"command" => command}), do: not safe_command?(command)
  def mutating?(_tool, _args), do: true

  @doc """
  Whether a shell command is read-only and safe to auto-run: command executable
  on the safe-list, no shell metacharacters, no parent-directory path references,
  no mutating `git` subcommand, and no mutating `find` predicate.
  """
  @spec safe_command?(String.t()) :: boolean()
  def safe_command?(command) when is_binary(command) do
    trimmed = String.trim(command)
    tokens = String.split(trimmed, ~r/\s+/, trim: true)

    with [_first | _rest] <- tokens,
         false <- Enum.any?(@shell_metachars, &String.contains?(trimmed, &1)),
         false <- Enum.any?(tokens, &parent_directory_token?/1),
         true <- safe_invocation?(tokens) do
      true
    else
      _ -> false
    end
  end

  def safe_command?(_command), do: false

  @doc "Classify whether a shell token contains a parent-directory path segment."
  @spec classify_parent_directory_token(term()) :: {:ok, boolean()}
  def classify_parent_directory_token(token), do: {:ok, parent_directory_token?(token)}

  @doc """
  Return the first shell token that resolves outside `workspace`.

  This is a conservative workspace-confinement tripwire for shell-shaped commands. It
  catches explicit parent-directory references, absolute paths outside the workspace,
  home/env-home references, and relative paths whose deepest existing prefix resolves
  outside the workspace. It is not a full shell parser; callers should still keep shell
  execution behind their normal permission and command-boundary gates.
  """
  @spec outside_workspace_shell_token(term(), String.t()) :: {:ok, String.t() | nil}
  def outside_workspace_shell_token(command, workspace)
      when is_binary(command) and is_binary(workspace) do
    token =
      command
      |> shell_path_candidates()
      |> Enum.find(&outside_workspace_token?(&1, workspace))

    {:ok, token}
  end

  def outside_workspace_shell_token(_command, _workspace), do: {:ok, nil}

  @doc "Whether a `find` token is a mutating predicate such as `-delete` or `-exec`."
  @spec mutating_find_predicate?(term()) :: boolean()
  def mutating_find_predicate?(token) when is_binary(token) do
    token
    |> strip_shell_quotes()
    |> then(&(&1 in @mutating_find_predicates))
  end

  def mutating_find_predicate?(_token), do: false

  @doc "Strip simple single/double quote wrapping from a shell token."
  @spec strip_shell_quotes(String.t()) :: String.t()
  def strip_shell_quotes(token) when is_binary(token) do
    token
    |> String.trim("'")
    |> String.trim("\"")
  end

  # ── internals ─────────────────────────────────────────────────────────────

  defp safe_invocation?(["env" | rest]), do: env_safe?(rest)
  defp safe_invocation?(["find" | rest]), do: find_safe?(rest)

  defp safe_invocation?([first | rest]) do
    first in @safe_commands and git_safe?(first, rest)
  end

  defp safe_invocation?(_tokens), do: false

  defp env_safe?([]), do: true

  defp env_safe?(tokens) do
    case env_wrapped_command(tokens) do
      [] -> true
      wrapped -> safe_invocation?(wrapped)
    end
  end

  defp env_wrapped_command([token | rest]) do
    cond do
      env_assignment?(token) -> env_wrapped_command(rest)
      env_option?(token) -> env_wrapped_command(rest)
      true -> [token | rest]
    end
  end

  defp env_wrapped_command([]), do: []

  defp env_assignment?(token), do: Regex.match?(~r/^[A-Za-z_][A-Za-z0-9_]*=.*/, token)
  defp env_option?(<<"-", _rest::binary>>), do: true
  defp env_option?(_token), do: false

  defp find_safe?(tokens) do
    not Enum.any?(tokens, &mutating_find_predicate?/1)
  end

  defp git_safe?("git", [sub | _]), do: sub not in @unsafe_git_subcommands
  defp git_safe?("git", []), do: true
  defp git_safe?(_first, _rest), do: true

  defp parent_directory_token?(token) when is_binary(token) do
    token
    |> String.replace(~r/['"]/, "")
    |> String.split("/", trim: false)
    |> Enum.any?(&(&1 == ".."))
  end

  defp parent_directory_token?(_token), do: false

  defp shell_path_candidates(command) do
    command
    |> String.split(~r/[\s<>()|;&>]+/, trim: true)
    |> Enum.flat_map(&String.split(&1, "=", parts: 2, trim: true))
  end

  defp outside_workspace_token?(token, workspace) when is_binary(token) do
    token = strip_shell_quotes(token)

    cond do
      token == "" ->
        false

      parent_directory_token?(token) ->
        true

      home_path_token?(token) ->
        true

      Path.type(token) == :absolute ->
        outside_workspace_path?(token, workspace)

      relative_filesystem_token?(token) ->
        outside_workspace_existing_path?(token, workspace)

      true ->
        false
    end
  end

  defp outside_workspace_token?(_token, _workspace), do: false

  defp home_path_token?(token) do
    token == "~" or
      token == "$HOME" or
      token == "${HOME}" or
      String.starts_with?(token, "~/") or
      String.starts_with?(token, "$HOME/") or
      String.starts_with?(token, "${HOME}/")
  end

  defp relative_filesystem_token?(<<"-", _rest::binary>>), do: false

  defp relative_filesystem_token?(token) do
    not String.starts_with?(token, "$")
  end

  defp outside_workspace_existing_path?(token, workspace) do
    path = Path.expand(token, workspace)
    root = canonical_existing_or_expanded(workspace)

    case resolve_deepest_existing_prefix(path) do
      {:ok, prefix} -> not path_inside?(normalize_path(prefix), root)
      {:error, _reason} -> false
    end
  end

  defp outside_workspace_path?(path, workspace) do
    root = canonical_existing_or_expanded(workspace)
    target = canonical_existing_or_expanded(path)
    not path_inside?(target, root)
  end

  defp canonical_existing_or_expanded(path) do
    case resolve_existing_path(path) do
      {:ok, realpath} -> normalize_path(realpath)
      {:error, _reason} -> path |> Path.expand() |> normalize_path()
    end
  end

  defp resolve_existing_path(path, depth \\ 0)

  defp resolve_existing_path(_path, depth) when depth > 40, do: {:error, :too_many_symlinks}

  defp resolve_existing_path(path, depth) do
    path = Path.expand(path)

    case Path.split(path) do
      ["/" | parts] -> resolve_existing_parts("/", parts, depth)
      parts -> resolve_existing_parts("/", parts, depth)
    end
  end

  defp resolve_existing_parts(current, [], _depth), do: {:ok, current}

  defp resolve_existing_parts(current, [part | rest], depth) do
    next = Path.join(current, part)

    case :file.read_link_info(String.to_charlist(next)) do
      {:ok, info} when elem(info, 2) == :symlink ->
        with {:ok, target_chars} <- :file.read_link(String.to_charlist(next)) do
          target = List.to_string(target_chars)

          resolved =
            if Path.type(target) == :absolute do
              target
            else
              Path.expand(target, current)
            end

          remaining = Path.join([resolved | rest])
          resolve_existing_path(remaining, depth + 1)
        end

      {:ok, _info} ->
        resolve_existing_parts(next, rest, depth)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp resolve_deepest_existing_prefix(path, depth \\ 0)

  defp resolve_deepest_existing_prefix(_path, depth) when depth > 40,
    do: {:error, :too_many_symlinks}

  defp resolve_deepest_existing_prefix(path, depth) do
    path = Path.expand(path)

    case Path.split(path) do
      ["/" | parts] -> resolve_deepest_existing_prefix_parts("/", parts, depth)
      parts -> resolve_deepest_existing_prefix_parts("/", parts, depth)
    end
  end

  defp resolve_deepest_existing_prefix_parts(current, [], _depth), do: {:ok, current}

  defp resolve_deepest_existing_prefix_parts(current, [part | rest], depth) do
    next = Path.join(current, part)

    case :file.read_link_info(String.to_charlist(next)) do
      {:ok, info} when elem(info, 2) == :symlink ->
        with {:ok, target_chars} <- :file.read_link(String.to_charlist(next)) do
          target = List.to_string(target_chars)

          resolved =
            if Path.type(target) == :absolute do
              target
            else
              Path.expand(target, current)
            end

          remaining = Path.join([resolved | rest])
          resolve_deepest_existing_prefix(remaining, depth + 1)
        end

      {:ok, _info} ->
        resolve_deepest_existing_prefix_parts(next, rest, depth)

      {:error, _reason} ->
        {:ok, current}
    end
  end

  defp normalize_path(path) do
    path
    |> Path.expand()
    |> String.trim_trailing("/")
    |> then(fn
      "" -> "/"
      normalized -> normalized
    end)
  end

  defp path_inside?(target, root) do
    root == "/" or target == root or String.starts_with?(target, root <> "/")
  end

  defp reason("write"), do: "write a file"
  defp reason("bash"), do: "run a shell command"
  defp reason("spawn_agent"), do: "spawn a subagent"
  defp reason("send_input"), do: "send input to a subagent"
  defp reason("close_agent"), do: "close a subagent"
  defp reason("run_workflow"), do: "run a workflow"
  defp reason(tool), do: "run #{tool}"
end
