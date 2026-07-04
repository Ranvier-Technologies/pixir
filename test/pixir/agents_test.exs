defmodule Pixir.AgentsTest do
  use ExUnit.Case, async: true

  alias Pixir.Agents

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "pixir-agents-" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
      )

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    roots = [
      {"repo-pixir", Path.join(root, "repo-pixir"), 0},
      {"repo-codex", Path.join(root, "repo-codex"), 1},
      {"user-pixir", Path.join(root, "user-pixir"), 2}
    ]

    %{root: root, roots: roots, opts: [roots: roots]}
  end

  test "includes built-ins and loads custom agents", %{roots: roots, opts: opts} do
    write_agent(Enum.at(roots, 0) |> elem(1), "reviewer", "Review things", "Find bugs.")

    assert {:ok, %{agents: agents}} = Agents.discover(File.cwd!(), opts)
    assert Enum.find(agents, &(&1.name == "default"))
    assert Enum.find(agents, &(&1.name == "worker"))
    assert Enum.find(agents, &(&1.name == "explorer"))

    default = Enum.find(agents, &(&1.name == "default"))
    assert default.developer_instructions =~ "Return a bounded result with evidence"
    assert default.developer_instructions =~ "checkpoint_status: checkpoint_ready"
    assert default.developer_instructions =~ "Do not spawn more Subagents unless"

    reviewer = Enum.find(agents, &(&1.name == "reviewer"))
    assert reviewer.description == "Review things"
    assert reviewer.developer_instructions == "Find bugs."
  end

  test "custom agents override lower precedence configs and built-ins with warnings", %{
    roots: roots,
    opts: opts
  } do
    write_agent(Enum.at(roots, 0) |> elem(1), "explorer", "Repo explorer", "Repo instructions.")
    write_agent(Enum.at(roots, 1) |> elem(1), "explorer", "Codex explorer", "Codex instructions.")

    assert {:ok, %{agents: agents, warnings: warnings}} = Agents.discover(File.cwd!(), opts)
    explorer = Enum.find(agents, &(&1.name == "explorer"))
    assert explorer.description == "Repo explorer"
    assert Enum.any?(warnings, &(&1["name"] == "explorer"))
  end

  defp write_agent(root, name, description, instructions) do
    File.mkdir_p!(root)

    File.write!(Path.join(root, "#{name}.toml"), """
    name = "#{name}"
    description = "#{description}"
    developer_instructions = \"\"\"
    #{instructions}
    \"\"\"
    """)
  end
end
