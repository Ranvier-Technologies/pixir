defmodule PixirMonitor.ExceptionBoundaryTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Source-level boundary pin for #414: no rescue clause in the Monitor's lib
  tree may interpolate `Exception.message/1` into a diagnostics map. The
  reachable HTTP boundary is exercised end-to-end in router_test.exs (raised
  and thrown sources, list and detail routes); the projection/builder/validator
  rescues are defensive nets that cannot be forced deterministically from
  public input (the builder normalizes and confesses malformed input by
  design), so this pin is what keeps the whole family honest against
  reintroduction.
  """

  @lib_root Path.expand("../lib", __DIR__)

  test "no monitor lib source embeds Exception.message into diagnostics" do
    offenders =
      [@lib_root, "**", "*.ex"]
      |> Path.join()
      |> Path.wildcard()
      |> Enum.filter(&(File.read!(&1) =~ "Exception.message("))
      |> Enum.map(&Path.relative_to(&1, @lib_root))

    assert offenders == [],
           "Exception.message/1 must not reach Monitor diagnostics; found in: #{inspect(offenders)}"
  end
end
