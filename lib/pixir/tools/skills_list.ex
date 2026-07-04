defmodule Pixir.Tools.SkillsList do
  @moduledoc "List registered Skills with bounded metadata (ADR 0010)."

  use Pixir.Tool

  alias Pixir.{Skills, Tool}

  @impl Pixir.Tool
  def __tool__ do
    %{
      name: "skills_list",
      description:
        "List available agent Skills by name, description, scope, and short path. Does not load full Skill instructions or supporting resources.",
      parameters: %{
        "type" => "object",
        "properties" => %{},
        "required" => []
      }
    }
  end

  @impl Pixir.Tool
  def execute(_args, context) do
    {:ok, result} = Skills.discover(context.workspace, Map.get(context, :skills_opts, []))
    payload = %{skills: result.skills, warnings: result.warnings}

    {:ok,
     %{
       "output" => Tool.truncate(Jason.encode!(stringify(payload), pretty: true)),
       "skills" => Enum.map(result.skills, &skill_metadata/1),
       "warnings" => result.warnings
     }}
  end

  @impl Pixir.Tool
  def dry_run(_args, context) do
    {:ok, %{skills: skills}} =
      Skills.discover(context.workspace, Map.get(context, :skills_opts, []))

    {:ok, %{"dry_run" => true, "would" => "list_skills", "skills" => length(skills)}}
  end

  defp skill_metadata(skill) do
    %{
      "name" => skill.name,
      "description" => skill.description,
      "scope" => skill.scope,
      "source" => skill.source,
      "path" => skill.path,
      "short_path" => skill.short_path
    }
  end

  defp stringify(%{skills: skills, warnings: warnings}) do
    %{"skills" => Enum.map(skills, &skill_metadata/1), "warnings" => warnings}
  end
end
