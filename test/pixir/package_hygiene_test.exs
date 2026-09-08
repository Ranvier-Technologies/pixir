defmodule Pixir.PackageHygieneTest do
  use ExUnit.Case, async: true

  test "published package files do not advertise the private development repository" do
    files = Mix.Project.config() |> Keyword.fetch!(:package) |> Keyword.fetch!(:files)
    assert files != []

    leaks =
      Enum.filter(files, fn file ->
        File.read!(file) =~ "Ranvier-Technologies/pixir-harness"
      end)

    assert leaks == [], "Private repository reference in package files: #{inspect(leaks)}"
  end
end
