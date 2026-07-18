defmodule Pixir.Tools.WorkspaceTest do
  use ExUnit.Case, async: true

  alias Pixir.Tools.Workspace
  alias Pixir.VirtualOverlay

  test "root Workspace accepts itself, relative children, and absolute descendants" do
    assert {:ok, "/"} = Workspace.confine("/", "/")
    assert {:ok, "/tmp"} = Workspace.confine("/", "tmp")

    assert {:ok, "/tmp/pixir-root-child"} =
             Workspace.confine("/", "/tmp/pixir-root-child")
  end

  test "non-root Workspace still rejects parent escapes and sibling prefixes" do
    root = Path.join(System.tmp_dir!(), "pixir-workspace-root")

    assert {:ok, ^root} = Workspace.confine(root, root)
    assert {:ok, path} = Workspace.confine(root, "child/file")
    assert String.starts_with?(path, root <> "/")

    assert {:error, %{error: %{kind: :outside_workspace}}} =
             Workspace.confine(root, "../escape")

    assert {:error, %{error: %{kind: :outside_workspace}}} =
             Workspace.confine(root, root <> "-sibling/file")
  end

  test "VirtualOverlay can import a relative descendant when the Workspace is root" do
    path =
      Path.join(
        System.tmp_dir!(),
        "pixir-root-overlay-" <> Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)
      )

    File.write!(path, "root-child")
    on_exit(fn -> File.rm(path) end)
    canonical_path = resolve_existing_symlinks(path)
    relative = String.trim_leading(canonical_path, "/")

    assert {:ok, artifact} =
             VirtualOverlay.run("/", %{"read_set" => [relative], "commands" => []})

    assert artifact["import"]["file_count"] == 1
  end

  defp resolve_existing_symlinks(path), do: resolve_existing_symlinks(path, 0)

  defp resolve_existing_symlinks(path, depth) when depth < 16 do
    path = Path.expand(path)
    ["/" | components] = Path.split(path)
    resolve_components("/", components, depth)
  end

  defp resolve_components(current, [], _depth), do: current

  defp resolve_components(current, [component | rest], depth) do
    candidate = Path.join(current, component)

    case File.lstat(candidate) do
      {:ok, %{type: :symlink}} ->
        target = File.read_link!(candidate) |> Path.expand(current)
        resolve_existing_symlinks(Path.join([target | rest]), depth + 1)

      {:ok, _stat} ->
        resolve_components(candidate, rest, depth)
    end
  end
end
