defmodule PixirTest do
  use ExUnit.Case
  doctest Pixir

  test "version matches mix project" do
    assert Pixir.version() == Mix.Project.config()[:version]
  end
end
