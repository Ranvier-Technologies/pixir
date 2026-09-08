defmodule Pixir.HomeIsolationPinTest do
  use ExUnit.Case, async: true

  setup do
    root =
      Path.join(System.tmp_dir!(), "pixir-bootstrap-probe-#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    File.write!(Path.join(root, "config.json"), "operator sentinel")
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  test "the actual suite bootstrap isolates the ambient home and cleans up after the suite", %{
    root: root
  } do
    {output, exit_code} = probe(Path.expand("test/test_helper.exs"), root)
    assert exit_code == 0, output

    isolated =
      output
      |> String.split("\n")
      |> Enum.find_value(fn line ->
        if String.starts_with?(line, "ISOLATED="),
          do: String.replace_prefix(line, "ISOLATED=", "")
      end)

    assert is_binary(isolated)
    refute File.exists?(isolated)
    assert File.read!(Path.join(root, "config.json")) == "operator sentinel"
  end

  test "a commented-out installation fails the same behavior probe", %{root: root} do
    mutant = Path.join(root, "mutant_helper.exs")
    File.write!(mutant, "ExUnit.start()\n# Pixir.Test.HomeIsolation.install!()\n")
    {_output, exit_code} = probe(mutant, root)
    assert exit_code == 31
  end

  defp probe(helper, ambient) do
    script = ~S"""
    [helper] = System.argv()
    ambient = System.fetch_env!("PIXIR_HOME")
    Code.require_file(helper)
    isolated = System.fetch_env!("PIXIR_HOME")
    unless isolated != ambient and File.dir?(isolated) and not File.exists?(Path.join(isolated, "config.json")), do: System.halt(31)
    IO.puts("ISOLATED=" <> isolated)
    """

    System.cmd(
      System.find_executable("elixir"),
      ["-r", Path.expand("test/support/home_isolation.ex"), "-e", script, "--", helper],
      env: [{"PIXIR_HOME", ambient}],
      stderr_to_stdout: true
    )
  end
end
