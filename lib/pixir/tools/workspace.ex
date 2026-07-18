defmodule Pixir.Tools.Workspace do
  @moduledoc """
  Workspace confinement (CONTEXT.md): the v0.1 safety floor. File Tools resolve a
  user/model-supplied path against the Workspace root and refuse anything that escapes
  it. Containment is lexical, accepts the root itself, and treats `/` as containing all
  absolute descendants. Symlink resolution is deliberately out of scope for v0.1.
  """

  alias Pixir.Tool

  @doc """
  Resolve `path` (relative or absolute) against `workspace`, confined to it. Returns
  `{:ok, absolute_path}` or a structured `:outside_workspace` error.
  """
  @spec confine(String.t(), String.t()) :: {:ok, String.t()} | {:error, map()}
  def confine(workspace, path) when is_binary(workspace) and is_binary(path) do
    root = Path.expand(workspace)
    abs = Path.expand(path, root)

    if contains?(root, abs) do
      {:ok, abs}
    else
      {:error, Tool.error(:outside_workspace, "path escapes the workspace", %{path: path})}
    end
  end

  @doc "Whether `path` resolves to the Workspace root or one of its descendants."
  @spec contains?(String.t(), String.t()) :: boolean()
  def contains?(workspace, path) when is_binary(workspace) and is_binary(path) do
    root = Path.expand(workspace)
    abs = Path.expand(path, root)

    root == "/" or abs == root or String.starts_with?(abs, root <> "/")
  end
end
