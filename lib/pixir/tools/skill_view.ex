defmodule Pixir.Tools.SkillView do
  @moduledoc "Load a selected Skill file and record main `SKILL.md` activations."

  use Pixir.Tool

  alias Pixir.{Event, Session, Skills, Tool}

  @impl Pixir.Tool
  def __tool__ do
    %{
      name: "skill_view",
      description:
        "Read a selected Skill's SKILL.md or a supporting file from registered Skill roots. Viewing SKILL.md records a durable Skill Activation.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "name" => %{"type" => "string", "description" => "Skill name"},
          "path" => %{
            "type" => "string",
            "description" => "Skill-relative file path, default SKILL.md"
          }
        },
        "required" => ["name"]
      }
    }
  end

  @impl Pixir.Tool
  def execute(%{"name" => name} = args, context) do
    path = Map.get(args, "path", "SKILL.md")

    with :ok <- validate_name(name),
         :ok <- validate_path(path),
         {:ok, %{skill: skill, path: rel_path, content: content}} <-
           Skills.view(name, path, context.workspace, Map.get(context, :skills_opts, [])),
         {:ok, activated?} <- maybe_record_activation(skill, rel_path, content, context) do
      {:ok,
       %{
         "output" => Tool.truncate(content),
         "name" => skill.name,
         "path" => rel_path,
         "scope" => skill.scope,
         "source" => skill.source,
         "content_hash" => hash_if_main(rel_path, content),
         "activated" => activated?
       }}
    end
  end

  def execute(_args, _context),
    do: {:error, Tool.error(:invalid_args, "name is required", %{})}

  @impl Pixir.Tool
  def dry_run(%{"name" => name} = args, context) do
    path = Map.get(args, "path", "SKILL.md")

    with :ok <- validate_name(name),
         :ok <- validate_path(path),
         {:ok, %{skill: skill, path: rel_path}} <-
           Skills.view(name, path, context.workspace, Map.get(context, :skills_opts, [])) do
      {:ok,
       %{
         "dry_run" => true,
         "would" => "view_skill",
         "name" => skill.name,
         "path" => rel_path,
         "would_activate" => Skills.main_file?(rel_path)
       }}
    end
  end

  def dry_run(_args, _context),
    do: {:error, Tool.error(:invalid_args, "name is required", %{})}

  defp validate_name(name) when is_binary(name), do: :ok
  defp validate_name(_name), do: {:error, Tool.error(:invalid_args, "name must be a string", %{})}

  defp validate_path(path) when is_binary(path), do: :ok
  defp validate_path(_path), do: {:error, Tool.error(:invalid_args, "path must be a string", %{})}

  defp maybe_record_activation(skill, rel_path, content, context) do
    if Skills.main_file?(rel_path) do
      data = Skills.activation_data(skill, content, "model")

      case safe_record(context.session_id, Event.skill_activation(context.session_id, data)) do
        {:ok, _event} ->
          {:ok, true}

        {:error, error} ->
          {:error, error}
      end
    else
      {:ok, false}
    end
  end

  defp safe_record(session_id, event) do
    Session.record(session_id, event)
  catch
    :exit, reason ->
      {:error,
       Tool.error(:log_write_failed, "could not record skill activation", %{
         reason: inspect(reason)
       })}
  end

  defp hash_if_main(path, content) do
    if Skills.main_file?(path) do
      :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
    end
  end
end
