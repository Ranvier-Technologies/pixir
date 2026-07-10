defmodule Pixir.VirtualOverlayTest do
  use ExUnit.Case, async: true

  alias Pixir.VirtualOverlay

  setup do
    ws = Path.join(System.tmp_dir!(), "pixir-virtual-overlay-test-#{System.unique_integer()}")
    File.rm_rf!(ws)
    File.mkdir_p!(Path.join(ws, "lib"))
    File.mkdir_p!(Path.join(ws, "data"))

    on_exit(fn -> File.rm_rf!(ws) end)

    %{ws: ws}
  end

  test "validates bounded read_set structure without rendering caller payloads" do
    assert :ok = VirtualOverlay.validate_read_set(["mix.exs", "lib/pixir/*.ex"])
    assert {:error, :read_set_required} = VirtualOverlay.validate_read_set([])

    assert {:error, %{kind: :invalid_read_set_entry, index: 1}} =
             VirtualOverlay.validate_read_set(["mix.exs", " "])

    # Every canonical spelling of the whole-workspace glob is unbounded;
    # directory- and extension-bounded patterns stay legal.
    for unbounded <- ["**/*", "./**/*", "**", "./**", "**/**", " **/* "] do
      assert {:error, %{kind: :unbounded_read_set, index: 0}} =
               VirtualOverlay.validate_read_set([unbounded]),
             "expected #{inspect(unbounded)} to be rejected as unbounded"
    end

    assert :ok = VirtualOverlay.validate_read_set(["**/*.ex"])
    assert :ok = VirtualOverlay.validate_read_set(["lib/**/*"])
  end

  test "run rejects whole-workspace globs at the execution boundary", %{ws: ws} do
    File.write!(Path.join(ws, "lib/example.txt"), "hello\n")

    assert {:error, %{ok: false, error: %{kind: :invalid_args, details: details}}} =
             VirtualOverlay.run(ws, %{
               "read_set" => ["lib/example.txt", "./**/*"],
               "commands" => ["true"]
             })

    assert details["field"] == "read_set"
    assert details["index"] == 1
    assert details["value"] == "./**/*"
  end

  test "imports a bounded read_set, runs virtual commands, and emits virtual_diff", %{ws: ws} do
    File.write!(Path.join(ws, "lib/example.txt"), "hello world\n")
    File.write!(Path.join(ws, "data/sample.json"), ~s({"name":"pixir"}))
    File.write!(Path.join(ws, "before.txt"), "one\n")
    File.write!(Path.join(ws, "after.txt"), "two\n")

    original_parent = File.read!(Path.join(ws, "lib/example.txt"))

    assert {:ok, artifact} =
             VirtualOverlay.run(ws, %{
               "read_set" => ["lib/example.txt", "data/sample.json", "before.txt", "after.txt"],
               "commands" => [
                 "find . -type f | sort",
                 "grep hello lib/example.txt",
                 "sed -i 's/hello/hola/' lib/example.txt",
                 "jq -r .name data/sample.json",
                 "diff before.txt after.txt"
               ]
             })

    assert artifact["kind"] == "virtual_diff"
    assert artifact["workspace_strategy"] == "virtual_overlay"
    assert artifact["workspace_fidelity"] == "virtual_shell_no_host_binaries"
    assert artifact["parent_workspace"]["mutation"] == "none"
    assert artifact["apply"]["status"] == "not_applied"
    assert artifact["import"]["file_count"] == 4
    assert artifact["import"]["byte_count"] > 0

    assert Enum.map(artifact["commands"], & &1["display"]) == [
             "find . -type f | sort",
             "grep hello lib/example.txt",
             "sed -i 's/hello/hola/' lib/example.txt",
             "jq -r .name data/sample.json",
             "diff before.txt after.txt"
           ]

    assert Enum.all?(artifact["commands"], &is_integer(get_in(&1, ["stats", "steps"])))
    assert Enum.at(artifact["commands"], 0)["stdout"] =~ "lib/example.txt"
    assert Enum.at(artifact["commands"], 1)["stdout"] =~ "hello world"
    assert Enum.at(artifact["commands"], 3)["stdout"] =~ "pixir"
    assert Enum.at(artifact["commands"], 4)["exit_code"] == 1
    assert Enum.at(artifact["commands"], 4)["stdout"] =~ "-one"
    assert Enum.at(artifact["commands"], 4)["stdout"] =~ "+two"

    change = Enum.find(artifact["changes"], &(&1["path"] == "lib/example.txt"))
    assert change["operation"] == "modify"
    assert change["diff"]["text"] =~ "-hello world"
    assert change["diff"]["text"] =~ "+hola world"
    assert artifact["summary"]["files_modified"] >= 1
    assert artifact["summary"]["diff_bytes"] > 0

    assert File.read!(Path.join(ws, "lib/example.txt")) == original_parent
  end

  test "supports glob imports and reports unmatched glob caveats", %{ws: ws} do
    File.write!(Path.join(ws, "lib/a.txt"), "a\n")
    File.write!(Path.join(ws, "lib/b.txt"), "b\n")

    assert {:ok, artifact} =
             VirtualOverlay.run(ws, %{
               "read_set" => ["lib/*.txt", "missing/*.txt"],
               "commands" => ["cat lib/a.txt lib/b.txt"]
             })

    assert artifact["import"]["file_count"] == 2
    assert [%{"kind" => "read_set_no_matches", "path" => "missing/*.txt"}] = artifact["caveats"]
    assert hd(artifact["commands"])["stdout"] == "a\nb\n"
  end

  test "rejects glob matches that resolve outside the parent workspace", %{ws: ws} do
    outside_dir =
      Path.join(System.tmp_dir!(), "pixir-virtual-overlay-outside-#{System.unique_integer()}")

    File.rm_rf!(outside_dir)
    File.mkdir_p!(outside_dir)
    outside_file = Path.join(outside_dir, "secret.txt")
    File.write!(outside_file, "secret\n")
    File.ln_s!(outside_file, Path.join(ws, "lib/escape.txt"))

    on_exit(fn -> File.rm_rf!(outside_dir) end)

    assert {:error, %{error: %{kind: :outside_workspace, details: details}}} =
             VirtualOverlay.run(ws, %{
               "read_set" => ["lib/*.txt"],
               "commands" => []
             })

    assert details["path"] == "lib/escape.txt"
    refute Map.has_key?(details, :path)
  end

  test "rejects glob matches under symlinked parent directories", %{ws: ws} do
    outside_dir =
      Path.join(
        System.tmp_dir!(),
        "pixir-virtual-overlay-outside-parent-#{System.unique_integer()}"
      )

    File.rm_rf!(outside_dir)
    File.mkdir_p!(Path.join(outside_dir, "sub"))
    File.write!(Path.join(outside_dir, "sub/secret.txt"), "secret\n")
    File.ln_s!(outside_dir, Path.join(ws, "linked"))

    on_exit(fn -> File.rm_rf!(outside_dir) end)

    assert {:error, %{error: %{kind: :outside_workspace, details: details}}} =
             VirtualOverlay.run(ws, %{
               "read_set" => ["linked/sub/*.txt"],
               "commands" => []
             })

    assert details["path"] == "linked/sub/secret.txt"
    refute Map.has_key?(details, :path)
  end

  test "marks binary or non-text virtual changes as unsupported", %{ws: ws} do
    File.write!(Path.join(ws, "data/blob.bin"), <<255, 0, 1>>)

    assert {:ok, artifact} =
             VirtualOverlay.run(ws, %{
               "read_set" => ["data/blob.bin"],
               "commands" => ["echo replaced > data/blob.bin"]
             })

    assert [change] = artifact["changes"]
    assert change["path"] == "data/blob.bin"
    assert change["operation"] == "modify"
    assert change["caveats"] == ["binary_or_non_text_change_unsupported"]
    refute Map.has_key?(change, "diff")
    assert artifact["summary"]["files_unsupported"] == 1
  end

  test "rejects imports outside the parent workspace", %{ws: ws} do
    assert {:error, %{error: %{kind: :outside_workspace, details: details}}} =
             VirtualOverlay.run(ws, %{
               "read_set" => ["../outside.txt"],
               "commands" => []
             })

    assert details["path"] == "../outside.txt"
    refute Map.has_key?(details, :path)
  end

  test "enforces import and command limits", %{ws: ws} do
    File.write!(Path.join(ws, "lib/example.txt"), "hello")

    assert {:error, %{error: %{kind: :invalid_args, details: details}}} =
             VirtualOverlay.run(ws, %{
               "read_set" => ["lib/example.txt"],
               "commands" => ["echo 1", "echo 2"],
               "limits" => %{"max_virtual_commands" => 1}
             })

    assert details["max_virtual_commands"] == 1

    assert {:error, %{error: %{kind: :invalid_args, details: details}}} =
             VirtualOverlay.run(ws, %{
               "read_set" => ["lib/example.txt"],
               "commands" => [],
               "limits" => %{"max_import_bytes" => 1}
             })

    assert details["max_import_bytes"] == 1

    assert {:error, %{error: %{kind: :invalid_args, details: details}}} =
             VirtualOverlay.run(ws, %{
               "read_set" => ["lib/example.txt"],
               "commands" => [],
               "limits" => %{"not_a_limit" => 1}
             })

    assert details["field"] == "not_a_limit"

    assert {:error, %{error: %{kind: :invalid_args, details: details}}} =
             VirtualOverlay.run(ws, %{
               "read_set" => ["lib/example.txt"],
               "commands" => [],
               "limits" => "not a map"
             })

    assert details["field"] == "limits"
  end

  test "truncates virtual command output on valid utf8 boundaries", %{ws: ws} do
    File.write!(Path.join(ws, "lib/utf8.txt"), "ééé\n")

    assert {:ok, artifact} =
             VirtualOverlay.run(ws, %{
               "read_set" => ["lib/utf8.txt"],
               "commands" => ["cat lib/utf8.txt"],
               "limits" => %{"max_output_bytes" => 3}
             })

    stdout = hd(artifact["commands"])["stdout"]

    assert stdout == "é"
    assert String.valid?(stdout)
    assert byte_size(stdout) <= 3
  end

  test "does not introduce host-boundary calls in the runner source" do
    source = File.read!("lib/pixir/virtual_overlay.ex")

    refute source =~ "System.cmd"
    refute source =~ "Port.open"
    refute source =~ ":os.cmd"
    refute source =~ "System.find_executable"
    refute source =~ "CommandBoundary"
    refute source =~ "/bin/bash"
    refute source =~ "/bin/sh"
    refute source =~ ~r/\bgit\b/
    refute source =~ ~r/\bnode\b/
  end
end
