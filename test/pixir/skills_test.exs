defmodule Pixir.SkillsTest do
  use ExUnit.Case, async: true

  alias Pixir.Skills

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "pixir-skills-" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
      )

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    roots = [
      %{scope: "repo", path: Path.join(root, "repo")},
      %{scope: "user", path: Path.join(root, "user")},
      %{scope: "pixir-global", path: Path.join(root, "global")}
    ]

    %{root: root, roots: roots, opts: [roots: roots]}
  end

  test "discovers skills and resolves collisions by repo > user > Pixir-global", %{
    roots: roots,
    opts: opts
  } do
    write_skill(Enum.at(roots, 0).path, "collision", "Repo skill", "repo body")
    write_skill(Enum.at(roots, 1).path, "collision", "User skill", "user body")
    write_skill(Enum.at(roots, 2).path, "global-only", "Global skill", "global body")

    assert {:ok, %{skills: skills, warnings: [warning]}} = Skills.discover(File.cwd!(), opts)

    assert Enum.map(skills, & &1.name) == ["collision", "global-only"]
    assert Enum.find(skills, &(&1.name == "collision")).scope == "repo"
    assert warning["name"] == "collision"
    assert warning["selected"] == "repo:collision/SKILL.md"
    assert warning["shadowed"] == ["user:collision/SKILL.md"]
  end

  test "view reads main and supporting files without allowing traversal", %{
    roots: roots,
    opts: opts
  } do
    write_skill(Enum.at(roots, 0).path, "docs", "Docs skill", "main body")

    assert {:ok, %{path: "SKILL.md", content: main}} =
             Skills.view("docs", "SKILL.md", File.cwd!(), opts)

    assert main =~ "Docs skill"

    assert {:ok, %{path: "references/note.md", content: "note for docs\n"}} =
             Skills.view("docs", "references/note.md", File.cwd!(), opts)

    assert {:error, %{error: %{kind: :outside_workspace}}} =
             Skills.view("docs", "../escape.md", File.cwd!(), opts)
  end

  test "discovers and instantiates skill-backed workflow templates", %{
    roots: roots,
    opts: opts
  } do
    dir = write_skill(Enum.at(roots, 0).path, "planner", "Planner skill", "main body")

    write_workflow_template(dir, "readonly_review", %{
      "id" => "readonly_review",
      "name" => "Read-only review",
      "description" => "Two explorers and one synthesis step",
      "parameters" => %{
        "topic" => %{"type" => "string", "required" => true}
      },
      "workflow" => %{
        "id" => "review_{{topic}}",
        "name" => "Review {{topic}}",
        "max_concurrency" => 2,
        "steps" => [
          %{"id" => "inspect_a", "task" => "Inspect {{topic}}", "agent" => "explorer"},
          %{"id" => "inspect_b", "task" => "Inspect {{topic}} again", "agent" => "explorer"},
          %{
            "id" => "synthesize",
            "task" => "Synthesize {{topic}}",
            "agent" => "explorer",
            "depends_on" => ["inspect_a", "inspect_b"]
          }
        ]
      }
    })

    assert {:ok, %{templates: [template], warnings: []}} =
             Skills.workflow_templates(File.cwd!(), opts)

    assert template.template_id == "planner/readonly_review"
    assert template.version == 1
    assert template.short_path == "repo:planner/workflows/readonly_review.json"

    assert {:ok, %{template: metadata, workflow: workflow}} =
             Skills.instantiate_workflow_template(
               "planner/readonly_review",
               %{"topic" => "repository"},
               File.cwd!(),
               opts
             )

    assert metadata["template_id"] == "planner/readonly_review"
    assert metadata["version"] == 1
    assert workflow["id"] == "review_repository"
    assert workflow["name"] == "Review repository"
    assert workflow["steps"] |> hd() |> Map.fetch!("task") == "Inspect repository"
  end

  test "workflow template arguments return structured invalid_args", %{
    roots: roots,
    opts: opts
  } do
    dir = write_skill(Enum.at(roots, 0).path, "planner", "Planner skill", "main body")

    write_workflow_template(dir, "needs_topic", %{
      "id" => "needs_topic",
      "parameters" => %{"topic" => %{"type" => "string", "required" => true}},
      "workflow" => %{"steps" => [%{"id" => "a", "task" => "{{topic}}"}]}
    })

    assert {:error, %{error: %{kind: :invalid_args, details: %{argument: "topic"}}}} =
             Skills.instantiate_workflow_template(
               "planner/needs_topic",
               %{},
               File.cwd!(),
               opts
             )
  end

  test "referenced invalid workflow templates return structured invalid_args", %{
    roots: roots,
    opts: opts
  } do
    dir = write_skill(Enum.at(roots, 0).path, "planner", "Planner skill", "main body")
    write_workflow_template(dir, "bad", %{"id" => "bad", "workflow" => []})

    assert {:error, %{error: %{kind: :invalid_args, details: %{warning: warning}}}} =
             Skills.instantiate_workflow_template("planner/bad", %{}, File.cwd!(), opts)

    assert warning["kind"] == "invalid_workflow_template"
    assert warning["details"]["id"] == "bad"
  end

  test "unsupported workflow template versions return structured invalid_args", %{
    roots: roots,
    opts: opts
  } do
    dir = write_skill(Enum.at(roots, 0).path, "planner", "Planner skill", "main body")

    write_workflow_template(dir, "future", %{
      "id" => "future",
      "version" => 2,
      "workflow" => %{"steps" => [%{"id" => "a", "task" => "inspect"}]}
    })

    assert {:error, %{error: %{kind: :invalid_args, details: %{warning: warning}}}} =
             Skills.instantiate_workflow_template("planner/future", %{}, File.cwd!(), opts)

    assert warning["kind"] == "invalid_workflow_template"
    assert warning["details"]["id"] == "future"
    assert warning["details"]["version"] == 2
    assert warning["details"]["supported"] == [1]
  end

  test "explicit invocation parser handles dollar and leading slash syntax" do
    assert Skills.invoked_names("Use $alpha and $beta-1 please") == ["alpha", "beta-1"]
    assert Skills.invoked_names("/alpha run with these args") == ["alpha"]
    assert Skills.invoked_names("path /tmp/file is not a slash skill") == []
  end

  test "render_index is Pi-style bounded skill metadata only", %{roots: roots, opts: opts} do
    skill_dir = write_skill(Enum.at(roots, 0).path, "collision", "Repo skill", "repo body")
    write_skill(Enum.at(roots, 1).path, "collision", "User skill", "user body")
    write_workflow_template(skill_dir, "hidden", %{"id" => "hidden", "workflow" => %{}})

    index = Skills.render_index(File.cwd!(), opts)

    assert index =~ "<available_skills>"
    assert index =~ "collision"
    assert index =~ "routing metadata"
    assert index =~ "Do not list or summarize Skills unless the user asks"
    assert index =~ "<when_to_use>Repo skill</when_to_use>"
    assert index =~ "<location>repo:collision/SKILL.md</location>"
    refute index =~ "Warning: duplicate Skill"
    refute index =~ "hidden"
    refute index =~ "workflow"
  end

  test "render_index orders visible skills deterministically", %{roots: roots, opts: opts} do
    write_skill(Enum.at(roots, 0).path, "zeta", "Zeta skill", "zeta body")
    write_skill(Enum.at(roots, 0).path, "alpha", "Alpha skill", "alpha body")

    index = Skills.render_index(File.cwd!(), opts)

    assert String.split(index, "<name>alpha</name>") |> length() == 2
    assert String.split(index, "<name>zeta</name>") |> length() == 2
    assert :binary.match(index, "<name>alpha</name>") < :binary.match(index, "<name>zeta</name>")
    assert Skills.index_hash(File.cwd!(), opts) == Skills.index_hash(File.cwd!(), opts)
  end

  defp write_skill(root, name, description, body) do
    dir = Path.join(root, name)
    File.mkdir_p!(Path.join(dir, "references"))

    File.write!(Path.join(dir, "SKILL.md"), """
    ---
    name: #{name}
    description: #{description}
    ---

    # #{description}

    #{body}
    """)

    File.write!(Path.join(dir, "references/note.md"), "note for #{name}\n")
    dir
  end

  defp write_workflow_template(skill_dir, name, payload) do
    dir = Path.join(skill_dir, "workflows")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "#{name}.json"), Jason.encode!(payload, pretty: true))
  end
end
