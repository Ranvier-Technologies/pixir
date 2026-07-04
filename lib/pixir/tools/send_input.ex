defmodule Pixir.Tools.SendInput do
  @moduledoc "Send follow-up input to an idle Subagent."

  use Pixir.Tool

  alias Pixir.{Subagents, Tool}

  @impl Pixir.Tool
  def __tool__ do
    %{
      name: "send_input",
      description: "Send a follow-up prompt to a known idle Subagent.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "id" => %{"type" => "string", "description" => "Subagent id"},
          "prompt" => %{"type" => "string", "description" => "Follow-up prompt"}
        },
        "required" => ["id", "prompt"]
      }
    }
  end

  @impl Pixir.Tool
  def execute(%{"id" => id, "prompt" => prompt}, context)
      when is_binary(id) and is_binary(prompt) and prompt != "" do
    with {:ok, agent} <-
           Subagents.send_input(context.session_id, id, prompt, workspace: context.workspace) do
      {:ok, %{"output" => "Sent input to #{id}.", "subagent" => agent}}
    end
  end

  def execute(_args, _context),
    do: {:error, Tool.error(:invalid_args, "id and prompt are required", %{})}

  @impl Pixir.Tool
  def dry_run(%{"id" => id, "prompt" => prompt}, _context)
      when is_binary(id) and is_binary(prompt) do
    {:ok, %{"dry_run" => true, "would" => "send_input", "id" => id}}
  end

  def dry_run(_args, _context),
    do: {:error, Tool.error(:invalid_args, "id and prompt are required", %{})}
end
