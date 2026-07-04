defmodule Pixir.Agents do
  @moduledoc """
  Built-in and custom Subagent role discovery (ADR 0011).

  Agent configs are lightweight TOML-like files. Pixir parses the subset needed for
  role selection: `name`, `description`, `developer_instructions`, and optional
  `model`, `model_reasoning_effort`, and `sandbox_mode`.
  """

  alias Pixir.{Paths, Tool}

  @subagent_result_contract """
  Return a bounded result with evidence and limitations. If the task is partial,
  blocked, or needs parent input, say that explicitly and include the safest next
  action. Include checkpoint_status: checkpoint_ready when the result is safe for
  the parent to consume; use checkpoint_status: partial, failed, or
  needs_orchestrator when dependents should not unblock without parent judgment.
  Do not spawn more Subagents unless the delegated task explicitly asks for recursive
  delegation. Prefer reducing scope and reporting useful evidence over waiting
  silently.
  """

  @built_ins [
    %{
      name: "default",
      description: "General-purpose fallback Subagent.",
      developer_instructions:
        "Work on the delegated task and return a concise result.\n\n" <>
          @subagent_result_contract,
      source: "built-in",
      scope: "built-in",
      path: "built-in:default",
      precedence: 100
    },
    %{
      name: "worker",
      description: "Execution-focused Subagent for implementation and fixes.",
      developer_instructions:
        "Implement or fix the delegated task. Keep changes scoped and report the final result.\n\n" <>
          @subagent_result_contract,
      source: "built-in",
      scope: "built-in",
      path: "built-in:worker",
      precedence: 100
    },
    %{
      name: "explorer",
      description: "Read-heavy Subagent for codebase exploration and evidence gathering.",
      developer_instructions:
        "Explore the delegated question. Prefer read-only investigation and concise evidence.\n\n" <>
          @subagent_result_contract,
      sandbox_mode: "read-only",
      source: "built-in",
      scope: "built-in",
      path: "built-in:explorer",
      precedence: 100
    }
  ]

  @doc "List agents with deterministic precedence and duplicate warnings."
  @spec discover(String.t(), keyword()) :: {:ok, %{agents: [map()], warnings: [map()]}}
  def discover(workspace \\ File.cwd!(), opts \\ []) do
    configs =
      workspace
      |> roots(opts)
      |> Enum.flat_map(&load_root/1)

    {:ok, resolve(configs ++ @built_ins)}
  end

  @doc "Resolve a single agent by name."
  @spec get(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, map()}
  def get(name, workspace \\ File.cwd!(), opts \\ []) when is_binary(name) do
    with {:ok, %{agents: agents}} <- discover(workspace, opts) do
      case Enum.find(agents, &(&1.name == name)) do
        nil ->
          {:error,
           Tool.error(:not_found, "agent not found", %{
             name: name,
             known: Enum.map(agents, & &1.name)
           })}

        agent ->
          {:ok, agent}
      end
    end
  end

  defp roots(workspace, opts) do
    case Keyword.get(opts, :roots) do
      roots when is_list(roots) ->
        Enum.map(roots, &normalize_root/1)

      _ ->
        repo = repo_root(workspace)
        user_home = Keyword.get(opts, :user_home) || System.get_env("HOME") || System.user_home!()

        [
          %{scope: "repo-pixir", path: Path.join(repo, ".pixir/agents"), precedence: 0},
          %{scope: "repo-codex", path: Path.join(repo, ".codex/agents"), precedence: 1},
          %{scope: "user-pixir", path: Path.join(Paths.global_root(), "agents"), precedence: 2},
          %{scope: "user-codex", path: Path.join(user_home, ".codex/agents"), precedence: 3}
        ]
        |> Enum.map(&normalize_root/1)
    end
  end

  defp normalize_root(%{scope: scope, path: path} = root) do
    %{
      scope: scope,
      source: scope,
      path: Path.expand(path),
      precedence: Map.fetch!(root, :precedence)
    }
  end

  defp normalize_root({scope, path, precedence}),
    do: normalize_root(%{scope: to_string(scope), path: path, precedence: precedence})

  defp load_root(root) do
    case File.ls(root.path) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&String.ends_with?(&1, ".toml"))
        |> Enum.sort()
        |> Enum.flat_map(&load_file(root, &1))

      {:error, _} ->
        []
    end
  end

  defp load_file(root, entry) do
    path = Path.join(root.path, entry)

    with {:ok, content} <- File.read(path),
         {:ok, parsed} <- parse_config(content),
         true <- valid_config?(parsed) do
      [
        parsed
        |> Map.put_new(:sandbox_mode, nil)
        |> Map.merge(%{
          scope: root.scope,
          source: root.source,
          path: path,
          precedence: root.precedence
        })
      ]
    else
      _ -> []
    end
  end

  defp parse_config(content) do
    parsed =
      content
      |> String.split("\n")
      |> parse_lines(%{})

    {:ok, parsed}
  end

  defp parse_lines([], acc), do: acc

  defp parse_lines([line | rest], acc) do
    trimmed = line |> strip_comment() |> String.trim()

    case Regex.run(~r/^(\w+)\s*=\s*\"\"\"\s*$/, trimmed) do
      [_, key] ->
        {value_lines, rest} = Enum.split_while(rest, &(String.trim(&1) != "\"\"\""))

        rest =
          case rest do
            [_closing | rest] -> rest
            [] -> []
          end

        value = value_lines |> Enum.join("\n") |> String.trim()
        parse_lines(rest, put_value(acc, key, value))

      _ ->
        parse_lines(rest, parse_line(line, acc))
    end
  end

  defp parse_line(line, acc) do
    line = line |> strip_comment() |> String.trim()

    case String.split(line, "=", parts: 2) do
      [key, value] ->
        put_value(acc, String.trim(key), parse_value(value))

      _ ->
        acc
    end
  end

  defp parse_value(value) do
    value = String.trim(value)

    cond do
      String.starts_with?(value, "\"") and String.ends_with?(value, "\"") ->
        value |> String.trim("\"") |> String.replace("\\\"", "\"") |> String.replace("\\\\", "\\")

      true ->
        value
    end
  end

  defp strip_comment(line), do: line |> String.split("#", parts: 2) |> hd()

  defp put_value(acc, "name", value), do: Map.put(acc, :name, value)
  defp put_value(acc, "description", value), do: Map.put(acc, :description, value)

  defp put_value(acc, "developer_instructions", value),
    do: Map.put(acc, :developer_instructions, value)

  defp put_value(acc, "model", value), do: Map.put(acc, :model, value)

  defp put_value(acc, "model_reasoning_effort", value),
    do: Map.put(acc, :model_reasoning_effort, value)

  defp put_value(acc, "sandbox_mode", value), do: Map.put(acc, :sandbox_mode, value)
  defp put_value(acc, _key, _value), do: acc

  defp valid_config?(%{name: name, description: desc, developer_instructions: instr})
       when is_binary(name) and name != "" and is_binary(desc) and desc != "" and
              is_binary(instr) and instr != "",
       do: true

  defp valid_config?(_), do: false

  defp resolve(candidates) do
    candidates
    |> Enum.group_by(& &1.name)
    |> Enum.map(fn {name, matches} ->
      sorted = Enum.sort_by(matches, &{&1.precedence, &1.path})
      [selected | shadowed] = sorted

      warning =
        if shadowed == [] do
          nil
        else
          %{
            "name" => name,
            "selected" => selected.path,
            "shadowed" => Enum.map(shadowed, & &1.path)
          }
        end

      {Map.drop(selected, [:precedence]), warning}
    end)
    |> Enum.sort_by(fn {agent, _warning} -> agent.name end)
    |> Enum.unzip()
    |> then(fn {agents, warnings} ->
      %{agents: agents, warnings: Enum.reject(warnings, &is_nil/1)}
    end)
  end

  defp repo_root(workspace) do
    workspace = Path.expand(workspace)

    workspace
    |> Stream.iterate(&Path.dirname/1)
    |> Enum.reduce_while(nil, fn dir, _ ->
      cond do
        File.dir?(Path.join(dir, ".git")) -> {:halt, dir}
        dir == Path.dirname(dir) -> {:halt, workspace}
        true -> {:cont, nil}
      end
    end)
  end
end
