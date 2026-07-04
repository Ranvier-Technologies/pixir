defmodule Mix.Tasks.Pixir.Smoke.E2eTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Pixir.Smoke.E2e, as: SmokeTask

  test "--help exits before running the live smoke" do
    output =
      capture_io(fn ->
        assert catch_exit(SmokeTask.run(["--help"])) == :normal
      end)

    assert output =~ "mix pixir.smoke.e2e"
    assert output =~ "--probe-model"
  end

  test "--json --help is machine-readable" do
    payload =
      capture_io(fn ->
        assert catch_exit(SmokeTask.run(["--json", "--help"])) == :normal
      end)
      |> Jason.decode!()

    assert payload["ok"] == true
    assert payload["command"] == "mix pixir.smoke.e2e"
    assert payload["network"] == true
    assert "--help" in payload["options"]
  end
end
