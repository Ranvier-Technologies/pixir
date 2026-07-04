defmodule Pixir.Tools.CloseAgent do
  @moduledoc "Close or cancel a Subagent thread."

  use Pixir.Tool

  alias Pixir.{Subagents, Tool}

  @impl Pixir.Tool
  def __tool__ do
    %{
      name: "close_agent",
      description:
        "Cancel a running Subagent thread, returning Cancelled; close queued or terminal Subagents as cleanup.",
      parameters: %{
        "type" => "object",
        "properties" => %{"id" => %{"type" => "string", "description" => "Subagent id"}},
        "required" => ["id"]
      }
    }
  end

  @impl Pixir.Tool
  def execute(%{"id" => id}, context) when is_binary(id) do
    with {:ok, agent} <- Subagents.close(context.session_id, id, workspace: context.workspace) do
      {:ok, %{"output" => close_output(agent), "subagent" => agent}}
    end
  end

  def execute(_args, _context),
    do: {:error, Tool.error(:invalid_args, "id is required", %{})}

  @impl Pixir.Tool
  def dry_run(%{"id" => id}, _context) when is_binary(id) do
    {:ok, %{"dry_run" => true, "would" => "close_agent", "id" => id}}
  end

  def dry_run(_args, _context),
    do: {:error, Tool.error(:invalid_args, "id is required", %{})}

  defp close_output(%{"id" => id, "status" => "cancelled"}),
    do: "Cancelled #{id}."

  defp close_output(%{"id" => id}), do: "Closed #{id}."
end
