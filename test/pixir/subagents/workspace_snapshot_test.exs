defmodule Pixir.Subagents.WorkspaceSnapshotTest do
  use ExUnit.Case, async: false

  alias Pixir.Subagents.WorkspaceSnapshot

  @default_excluded ~w(.git .pixir _build deps node_modules dist .astro .vercel .next .turbo coverage .cache)

  setup do
    base =
      Path.join(
        System.tmp_dir!(),
        "pixir-snapshot-policy-#{System.unique_integer([:positive])}"
      )

    src = Path.join(base, "src")
    dest = Path.join(base, "dest")
    File.mkdir_p!(src)
    File.mkdir_p!(dest)
    on_exit(fn -> File.rm_rf(base) end)

    %{src: src, dest: dest}
  end

  defp seed(src) do
    File.mkdir_p!(Path.join(src, "lib"))
    File.write!(Path.join([src, "lib", "app.ex"]), "code")
    File.mkdir_p!(Path.join([src, "node_modules", "pkg"]))
    File.write!(Path.join([src, "node_modules", "pkg", "ignored.js"]), "ignored")
    File.mkdir_p!(Path.join([src, "outputs", "bench"]))
    File.write!(Path.join([src, "outputs", "bench", "runs.jsonl"]), "bulk")
  end

  defp put_subagents_env(value) do
    previous = Application.fetch_env(:pixir, :subagents)
    Application.put_env(:pixir, :subagents, value)

    on_exit(fn ->
      case previous do
        {:ok, prior} -> Application.put_env(:pixir, :subagents, prior)
        :error -> Application.delete_env(:pixir, :subagents)
      end
    end)
  end

  test "default policy confesses the effective exclusion list", %{src: src, dest: dest} do
    seed(src)

    assert {:ok, metadata} = WorkspaceSnapshot.copy(src, dest)
    assert metadata["excluded_dir_names"] == Enum.sort(@default_excluded)
    assert File.exists?(Path.join([dest, "outputs", "bench", "runs.jsonl"]))
    refute File.exists?(Path.join(dest, "node_modules"))
  end

  test "copy option exclusions extend the defaults without replacing them", %{
    src: src,
    dest: dest
  } do
    seed(src)

    assert {:ok, metadata} = WorkspaceSnapshot.copy(src, dest, excluded_dir_names: ["outputs"])

    assert File.exists?(Path.join([dest, "lib", "app.ex"]))
    refute File.exists?(Path.join(dest, "outputs"))
    refute File.exists?(Path.join(dest, "node_modules"))

    assert metadata["skipped_dirs_by_name"]["outputs"] == 1
    assert metadata["skipped_dirs_by_name"]["node_modules"] == 1
    assert metadata["excluded_dir_names"] == Enum.sort(["outputs" | @default_excluded])
    assert metadata["snapshot_policy"] == "recursive_denylist_v1"
  end

  test "application env exclusions apply and compose with copy options", %{
    src: src,
    dest: dest
  } do
    seed(src)
    File.mkdir_p!(Path.join(src, "envdir"))
    File.write!(Path.join([src, "envdir", "cached"]), "cached")

    put_subagents_env(snapshot_excluded_dir_names: ["envdir"])

    assert {:ok, metadata} = WorkspaceSnapshot.copy(src, dest, excluded_dir_names: ["outputs"])

    refute File.exists?(Path.join(dest, "envdir"))
    refute File.exists?(Path.join(dest, "outputs"))
    refute File.exists?(Path.join(dest, "node_modules"))
    assert File.exists?(Path.join([dest, "lib", "app.ex"]))

    assert metadata["excluded_dir_names"] ==
             Enum.sort(["envdir", "outputs" | @default_excluded])
  end

  test "exclusions are matched by basename at any depth and counted per hit", %{
    src: src,
    dest: dest
  } do
    File.mkdir_p!(Path.join([src, "site", "outputs", "deep"]))
    File.write!(Path.join([src, "site", "outputs", "deep", "artifact"]), "bulk")
    File.mkdir_p!(Path.join([src, "site", "src"]))
    File.write!(Path.join([src, "site", "src", "app.js"]), "source")
    File.mkdir_p!(Path.join(src, "outputs"))
    File.write!(Path.join([src, "outputs", "top-level"]), "bulk")

    assert {:ok, metadata} = WorkspaceSnapshot.copy(src, dest, excluded_dir_names: ["outputs"])

    refute File.exists?(Path.join([dest, "site", "outputs"]))
    refute File.exists?(Path.join(dest, "outputs"))
    assert File.exists?(Path.join([dest, "site", "src", "app.js"]))
    assert metadata["skipped_dirs_by_name"]["outputs"] == 2
  end

  test "symlinks stay lstat-skipped under a custom exclusion policy", %{src: src, dest: dest} do
    seed(src)

    outside =
      Path.join(System.tmp_dir!(), "pixir-snapshot-outside-#{System.unique_integer([:positive])}")

    File.write!(outside, "outside")
    on_exit(fn -> File.rm_rf(outside) end)

    link = Path.join(src, "outside-link")
    symlink_created? = File.ln_s(outside, link) == :ok

    assert {:ok, metadata} = WorkspaceSnapshot.copy(src, dest, excluded_dir_names: ["outputs"])

    refute File.exists?(Path.join(dest, "outputs"))
    assert metadata["skipped_dirs_by_name"]["outputs"] == 1

    if symlink_created? do
      assert metadata["symlinks_skipped"] == 1
      refute File.exists?(Path.join(dest, "outside-link"))
    end
  end

  test "invalid exclusion names return structured errors", %{src: src, dest: dest} do
    seed(src)

    for bad <- ["with/separator", "", ".", "..", :atom_name, 42] do
      assert {:error, details} = WorkspaceSnapshot.copy(src, dest, excluded_dir_names: [bad])
      assert details["reason"] == "snapshot_invalid_excluded_dir_names"
      assert details["snapshot_policy"] == "recursive_denylist_v1"
      assert "use_basename_only_snapshot_excluded_dir_names" in details["next_actions"]
    end

    assert {:error, details} =
             WorkspaceSnapshot.copy(src, dest, excluded_dir_names: "not-a-list")

    assert details["reason"] == "snapshot_invalid_excluded_dir_names"
  end

  test "invalid application env exclusions fail closed with a structured error", %{
    src: src,
    dest: dest
  } do
    seed(src)

    put_subagents_env(snapshot_excluded_dir_names: ["nested/path"])

    assert {:error, details} = WorkspaceSnapshot.copy(src, dest)
    assert details["reason"] == "snapshot_invalid_excluded_dir_names"
  end

  test "a non-keyword subagents application env fails closed", %{src: src, dest: dest} do
    seed(src)

    put_subagents_env(%{snapshot_excluded_dir_names: ["envdir"]})

    assert {:error, details} = WorkspaceSnapshot.copy(src, dest)
    assert details["reason"] == "snapshot_invalid_subagents_env"

    assert "use_a_keyword_list_for_the_pixir_subagents_application_env" in details["next_actions"]
  end

  test "validation failures claim no effective exclusion list; runtime failures confess it", %{
    src: src,
    dest: dest
  } do
    seed(src)

    assert {:error, invalid} =
             WorkspaceSnapshot.copy(src, dest, excluded_dir_names: ["nested/path"])

    assert invalid["reason"] == "snapshot_invalid_excluded_dir_names"
    refute Map.has_key?(invalid, "excluded_dir_names")

    assert {:error, runtime} =
             WorkspaceSnapshot.copy(src, dest,
               excluded_dir_names: ["outputs"],
               limits: [max_file_bytes: 1]
             )

    assert runtime["reason"] == "snapshot_max_file_bytes_exceeded"
    assert runtime["excluded_dir_names"] == Enum.sort(["outputs" | @default_excluded])
  end

  test "limits validation errors win over exclusion validation errors", %{src: src, dest: dest} do
    seed(src)

    assert {:error, details} =
             WorkspaceSnapshot.copy(src, dest,
               limits: [max_files: 0],
               excluded_dir_names: ["nested/path"]
             )

    assert details["reason"] == "snapshot_invalid_limit"
  end

  test "the denylist is directory-only: a file with an excluded name is copied", %{
    src: src,
    dest: dest
  } do
    File.write!(Path.join(src, "reports"), "a file, not a directory")

    assert {:ok, metadata} = WorkspaceSnapshot.copy(src, dest, excluded_dir_names: ["reports"])

    assert File.read!(Path.join(dest, "reports")) == "a file, not a directory"
    refute Map.has_key?(metadata["skipped_dirs_by_name"], "reports")
  end

  test "duplicate names across layers dedupe into one effective entry", %{src: src, dest: dest} do
    seed(src)

    put_subagents_env(snapshot_excluded_dir_names: ["outputs"])

    assert {:ok, metadata} =
             WorkspaceSnapshot.copy(src, dest, excluded_dir_names: ["outputs", "outputs", ".git"])

    assert metadata["excluded_dir_names"] == Enum.sort(["outputs" | @default_excluded])
  end
end
