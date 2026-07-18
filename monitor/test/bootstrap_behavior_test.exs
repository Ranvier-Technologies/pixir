defmodule PixirMonitor.BootstrapBehaviorTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Drives the REAL inline bootstrap source in node:vm instead of pinning its
  text: absent capability, rejected capability (the server folds expired and
  already-used into one invalid_launch 401 on purpose, so the client renders
  one honest category for both), non-launch rejections (403/413/500), network
  failure, and a Trusted Types throw. Each scenario asserts the rendered
  status copy, the base-URL history replacement, the rejected-promise
  contract app.js relies on, and that the launch token never reaches the
  rendered text.
  """

  @checker Path.join(__DIR__, "support/bootstrap_behavior_check.mjs")
  @node System.find_executable("node")
  # Mirrors the presenter UI seam tier: a missing node skips LOCALLY but must
  # fail LOUDLY in CI, where this tier is deliberately mandatory.
  @node_skip (cond do
                is_binary(@node) -> false
                System.get_env("CI") in ["true", "1"] -> false
                true -> "requires Node.js"
              end)

  @tag skip: @node_skip
  @tag timeout: 60_000
  test "bootstrap failures reach distinct terminal copy per category, without token echo" do
    assert is_binary(@node),
           "the CI runner lost node: the bootstrap behavior tier must not silently skip in CI"

    assert {:ok, source} = PixirMonitor.Bootstrap.source()

    source_path =
      Path.join(
        System.tmp_dir!(),
        "pixir-monitor-bootstrap-source-#{System.unique_integer([:positive])}.js"
      )

    File.write!(source_path, source)
    on_exit(fn -> File.rm(source_path) end)

    {output, status} =
      System.cmd(@node, [@checker, "--source", source_path, "--json"], stderr_to_stdout: true)

    assert status == 0, "bootstrap behavior check failed: #{output}"
    result = output |> String.split("\n", trim: true) |> List.last() |> Jason.decode!()

    assert result["ok"] == true
    assert result["check"] == "pixir_monitor_bootstrap_behavior"
    assert result["executed_in"] == "node_vm"

    assert result["scenarios"] == [
             "absent_fragment_401",
             "rejected_capability_401",
             "empty_fragment_401",
             "forbidden_403",
             "body_too_large_413",
             "server_error_500",
             "network_failure",
             "trusted_types_throw",
             "asset_load_failure"
           ]

    # The invalid/expired/one-use copy is reserved for rejected capabilities
    # (including the empty "#launch=" token); a failing app.js asset gets its
    # own terminal copy on a FULFILLED promise; everything else lands on the
    # absent or generic category.
    assert result["copies"] == [
             "absent",
             "rejected",
             "rejected",
             "generic",
             "generic",
             "generic",
             "generic",
             "generic",
             "asset"
           ]
  end
end
