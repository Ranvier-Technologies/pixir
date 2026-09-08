defmodule Pixir.BuildInfoTest do
  use ExUnit.Case, async: false

  alias Pixir.BuildInfo

  test "compiled identity is safe and attributes this runtime" do
    assert {:ok, info} = BuildInfo.get()
    assert info["version"] == Pixir.version()
    assert info["os_pid"] == System.pid()
    assert info["runtime_elixir"] == System.version()
    assert info["runtime_otp"] == System.otp_release()
    assert info["compile_elixir"] == System.version()
    assert info["compile_otp"] == System.otp_release()

    assert info["source_revision"] == "unknown" or
             info["source_revision"] =~ ~r/\A[0-9a-f]{40,64}\z/

    assert info["source_dirty"] in [true, false, "unknown"]

    assert info["source_fingerprint"] == "unknown" or
             info["source_fingerprint"] =~ ~r/\A[0-9a-f]{64}\z/

    refute Jason.encode!(info) =~ File.cwd!()
    assert BuildInfo.__mix_recompile__?()
  end

  @tag timeout: 120_000
  test "rebuilds capture commits and dirty-to-dirty edits while resident code stays compiled" do
    root = fixture()
    git!(root, ["init", "--quiet"])
    git!(root, ["add", "."])
    git!(root, ["commit", "--quiet", "-m", "initial"])
    revision = git!(root, ["rev-parse", "HEAD"]) |> String.trim()
    clean = build(root)
    assert clean["source_revision"] == revision
    assert clean["source_dirty"] == false

    File.write!(Path.join(root, "lib/change.ex"), "defmodule Change, do: def(value, do: 1)\n")
    dirty = build(root)
    assert dirty["source_dirty"] == true
    assert dirty["source_revision"] == revision
    refute dirty["source_fingerprint"] == clean["source_fingerprint"]

    File.write!(Path.join(root, "lib/change.ex"), "defmodule Change, do: def(value, do: 2)\n")
    dirtier = build(root)
    assert dirtier["source_dirty"] == true
    refute dirtier["source_fingerprint"] == dirty["source_fingerprint"]

    git!(root, ["add", "."])
    git!(root, ["commit", "--quiet", "-m", "next"])
    committed = build(root)
    assert committed["source_dirty"] == false
    refute committed["source_revision"] == revision

    # A linked worktree has a .git file, not a .git directory.
    worktree = root <> "-linked"
    on_exit(fn -> File.rm_rf!(worktree) end)
    git!(root, ["worktree", "add", "--quiet", "--detach", worktree])
    linked = build(worktree)
    assert linked["source_revision"] == committed["source_revision"]
    assert linked["source_dirty"] == false

    # In a fresh process, mutate source and move CWD after loading the artifact.
    script = """
    {:ok, before} = Pixir.BuildInfo.get()
    File.write!("lib/change.ex", "changed after loading")
    File.cd!(System.tmp_dir!())
    {:ok, after_change} = Pixir.BuildInfo.get()
    if before != after_change, do: raise("resident artifact was relabelled")
    IO.puts("BUILD_INFO=" <> Base.encode64(:erlang.term_to_binary(after_change)))
    """

    resident = build(worktree, script)
    assert resident["source_dirty"] == false
    assert resident["source_revision"] == committed["source_revision"]
  end

  @tag timeout: 60_000
  test "source archives and missing git are explicitly unknown" do
    root = fixture()
    info = build(root)
    assert info["version"] == "9.8.7"
    assert info["source_revision"] == "unknown"
    assert info["source_dirty"] == "unknown"

    # Compilation without a git executable, in an isolated VM, must still succeed.
    script = """
    System.put_env("PATH", "")
    Code.compiler_options(ignore_module_conflict: true)
    Code.compile_file("lib/pixir/build_info.ex")
    {:ok, info} = Pixir.BuildInfo.get()
    IO.puts("BUILD_INFO=" <> Base.encode64(:erlang.term_to_binary(info)))
    """

    git!(root, ["init", "--quiet"])
    missing_git = build(root, script)
    assert missing_git["source_revision"] == "unknown"
    assert missing_git["source_dirty"] == "unknown"
  end

  defp fixture do
    root = Path.join(System.tmp_dir!(), "pixir-build-info-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "lib/pixir"))
    on_exit(fn -> File.rm_rf!(root) end)

    File.cp!(
      Path.expand("../../lib/pixir/build_info.ex", __DIR__),
      Path.join(root, "lib/pixir/build_info.ex")
    )

    File.write!(Path.join(root, ".gitignore"), "/_build/\n")

    File.write!(Path.join(root, "mix.exs"), """
    defmodule BuildFixture.MixProject do
      use Mix.Project
      def project, do: [app: :build_fixture, version: "9.8.7", deps: []]
    end
    """)

    root
  end

  defp build(
         root,
         script \\ "{:ok, info} = Pixir.BuildInfo.get(); IO.puts(\"BUILD_INFO=\" <> Base.encode64(:erlang.term_to_binary(info)))"
       ) do
    {output, status} =
      System.cmd(System.find_executable("mix"), ["run", "--no-start", "-e", script],
        cd: root,
        stderr_to_stdout: true,
        env: [{"ERL_FLAGS", "+S 2:2"}]
      )

    assert status == 0, output
    encoded = output |> String.split("\n") |> Enum.find(&String.starts_with?(&1, "BUILD_INFO="))
    assert encoded, output

    encoded
    |> String.replace_prefix("BUILD_INFO=", "")
    |> Base.decode64!()
    |> :erlang.binary_to_term([:safe])
  end

  defp git!(root, args) do
    {output, status} =
      System.cmd(
        "git",
        [
          "-c",
          "user.name=Build Test",
          "-c",
          "user.email=build@example.invalid",
          "-c",
          "commit.gpgsign=false",
          "-C",
          root | args
        ],
        stderr_to_stdout: true
      )

    assert status == 0, output
    output
  end
end
