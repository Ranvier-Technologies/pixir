defmodule Pixir.Tools.Write do
  @moduledoc "Write a file in the Workspace (atomic temp+rename; creates parent dirs)."

  use Pixir.Tool

  alias Pixir.Tool
  alias Pixir.Tools.{AtomicWrite, Workspace}

  @impl Pixir.Tool
  def __tool__ do
    %{
      name: "write",
      description: "Create or overwrite a file in the workspace with the given content.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "path" => %{"type" => "string", "description" => "Workspace-relative file path"},
          "content" => %{"type" => "string", "description" => "Full file content to write"}
        },
        "required" => ["path", "content"]
      }
    }
  end

  @impl Pixir.Tool
  def execute(%{"path" => path, "content" => content}, context) do
    with {:ok, abs} <- Workspace.confine(context.workspace, path) do
      File.mkdir_p!(Path.dirname(abs))

      case AtomicWrite.write(abs, content) do
        {:ok, nil} ->
          {:ok,
           %{
             "output" => "wrote #{byte_size(content)} bytes to #{path}",
             "bytes" => byte_size(content)
           }}

        {:error, reason} ->
          {:error,
           Tool.error(:write_failed, "could not write file", %{path: path, reason: reason})}
      end
    end
  end

  @impl Pixir.Tool
  def dry_run(%{"path" => path, "content" => content}, context) do
    with {:ok, abs} <- Workspace.confine(context.workspace, path) do
      {:ok,
       %{
         "dry_run" => true,
         "would" => "write",
         "path" => path,
         "bytes" => byte_size(content),
         "overwrites" => File.exists?(abs)
       }}
    end
  end
end
