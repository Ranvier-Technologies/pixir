defmodule Pixir.Tools.Read do
  @moduledoc "Read a file from the Workspace (read-only; output is token-bounded)."

  use Pixir.Tool

  alias Pixir.Tool
  alias Pixir.Tools.Workspace

  @impl Pixir.Tool
  def __tool__ do
    %{
      name: "read",
      description: "Read the contents of a file in the workspace.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "path" => %{"type" => "string", "description" => "Workspace-relative file path"}
        },
        "required" => ["path"]
      }
    }
  end

  @impl Pixir.Tool
  def execute(%{"path" => path}, context) do
    with {:ok, abs} <- Workspace.confine(context.workspace, path) do
      case File.read(abs) do
        {:ok, contents} ->
          {:ok, %{"output" => Tool.truncate(contents)}}

        {:error, :enoent} ->
          {:error, Tool.error(:not_found, "file not found", %{path: path})}

        {:error, reason} ->
          {:error, Tool.error(:read_failed, "could not read file", %{path: path, reason: reason})}
      end
    end
  end

  @impl Pixir.Tool
  def dry_run(%{"path" => path}, context) do
    with {:ok, abs} <- Workspace.confine(context.workspace, path) do
      {:ok,
       %{"dry_run" => true, "would" => "read", "path" => path, "exists" => File.exists?(abs)}}
    end
  end
end
