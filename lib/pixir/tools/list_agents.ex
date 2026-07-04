defmodule Pixir.Tools.ListAgents do
  @moduledoc "List Subagents for the current parent Session."

  use Pixir.Tool

  alias Pixir.Subagents

  @impl Pixir.Tool
  def __tool__ do
    %{
      name: "list_agents",
      description: "List Subagents spawned by this Session with compact status metadata.",
      parameters: %{"type" => "object", "properties" => %{}, "required" => []}
    }
  end

  @impl Pixir.Tool
  def execute(_args, context) do
    with {:ok, agents} <- Subagents.list(context.session_id, workspace: context.workspace) do
      {:ok, %{"output" => Subagents.summarize(agents), "subagents" => agents}}
    end
  end

  @impl Pixir.Tool
  def dry_run(_args, _context) do
    {:ok, %{"dry_run" => true, "would" => "list_agents"}}
  end
end
