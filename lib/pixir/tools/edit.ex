defmodule Pixir.Tools.Edit do
  @moduledoc """
  Replace an exact string in a Workspace file (atomic temp+rename). By default
  `old_string` must occur exactly once — ambiguous edits fail rather than guess; pass
  `replace_all` to replace every occurrence.
  """

  use Pixir.Tool

  alias Pixir.Tool
  alias Pixir.Tools.Workspace

  @impl Pixir.Tool
  def __tool__ do
    %{
      name: "edit",
      description:
        "Replace an exact string in a file. By default old_string must occur exactly once " <>
          "(otherwise it errors — add surrounding context or set replace_all).",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "path" => %{"type" => "string", "description" => "Workspace-relative file path"},
          "old_string" => %{"type" => "string", "description" => "Exact text to replace"},
          "new_string" => %{"type" => "string", "description" => "Replacement text"},
          "replace_all" => %{
            "type" => "boolean",
            "description" => "Replace all occurrences (default false)"
          }
        },
        "required" => ["path", "old_string", "new_string"]
      }
    }
  end

  @impl Pixir.Tool
  def execute(%{"path" => path, "old_string" => old, "new_string" => new} = args, context) do
    replace_all = Map.get(args, "replace_all", false)

    with {:ok, abs} <- Workspace.confine(context.workspace, path),
         {:ok, content} <- read(abs, path),
         {:ok, count} <- check(content, old, replace_all, path) do
      updated =
        if replace_all,
          do: String.replace(content, old, new),
          else: String.replace(content, old, new, global: false)

      write(abs, updated, path, count)
    end
  end

  @impl Pixir.Tool
  def dry_run(%{"path" => path, "old_string" => old} = args, context) do
    replace_all = Map.get(args, "replace_all", false)

    with {:ok, abs} <- Workspace.confine(context.workspace, path),
         {:ok, content} <- read(abs, path),
         {:ok, count} <- check(content, old, replace_all, path) do
      {:ok, %{"dry_run" => true, "would" => "edit", "path" => path, "replacements" => count}}
    end
  end

  # ── internals ─────────────────────────────────────────────────────────────

  defp read(abs, path) do
    case File.read(abs) do
      {:ok, content} ->
        {:ok, content}

      {:error, :enoent} ->
        {:error, Tool.error(:not_found, "file not found", %{path: path})}

      {:error, reason} ->
        {:error, Tool.error(:read_failed, "could not read file", %{path: path, reason: reason})}
    end
  end

  # Validate the match and return how many replacements will happen.
  defp check(_content, "", _replace_all, path),
    do: {:error, Tool.error(:invalid_args, "old_string must not be empty", %{path: path})}

  defp check(content, old, replace_all, path) do
    case occurrences(content, old) do
      0 ->
        {:error, Tool.error(:no_match, "old_string not found in file", %{path: path})}

      n when n > 1 and not replace_all ->
        {:error,
         Tool.error(
           :not_unique,
           "old_string occurs #{n} times; add context or set replace_all",
           %{path: path, occurrences: n}
         )}

      n ->
        {:ok, if(replace_all, do: n, else: 1)}
    end
  end

  defp occurrences(content, old), do: length(String.split(content, old)) - 1

  defp write(abs, content, path, count) do
    tmp = abs <> ".pixir-tmp"

    with :ok <- File.write(tmp, content),
         :ok <- File.rename(tmp, abs) do
      {:ok, %{"output" => "edited #{path} (#{count} replacement(s))", "replacements" => count}}
    else
      {:error, reason} ->
        _ = File.rm(tmp)
        {:error, Tool.error(:write_failed, "could not write file", %{path: path, reason: reason})}
    end
  end
end
