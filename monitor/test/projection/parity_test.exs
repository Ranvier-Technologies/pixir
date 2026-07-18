defmodule PixirMonitor.ProjectionParityTest do
  @moduledoc """
  Contract parity coverage for every frozen Presenter fixture and its golden output.
  """
  use ExUnit.Case, async: false

  @package Path.expand("../../priv/presenter", __DIR__)
  @scenarios ~w(
    evidence-mirror-canonical-conflict
    f4-advisory-retry-reconstructed
    held-missing-child-log
    invalid-model-advisory
    live-runtime-only-no-log
    mixed-running-current
    partial-write-indeterminate
    resume-reused-child-session
    stale-running-no-owner
    timeout-needs-orchestrator
    virtual-diff-unapplied
    wave1-parallel-audit-reconstructed
    wave3-transport-failure-reconstructed
  )

  setup do
    previous = Application.get_env(:pixir_monitor, :projection_projected_at)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:pixir_monitor, :projection_projected_at, previous),
        else: Application.delete_env(:pixir_monitor, :projection_projected_at)
    end)
  end

  for scenario <- @scenarios do
    @scenario scenario
    test "projects #{scenario} exactly and validates the result" do
      input = decode!("fixtures/inputs/#{@scenario}.json")
      golden = decode!("fixtures/golden/#{@scenario}.json")
      Application.put_env(:pixir_monitor, :projection_projected_at, golden["projected_at"])

      assert {:ok, projection} = PixirMonitor.Projection.project(input)
      assert :ok = PixirMonitor.Projection.Validator.validate(projection)
      assert projection == golden
    end
  end

  test "projection is derived from evidence rather than scenario identity" do
    fixture = decode!("fixtures/inputs/f4-advisory-retry-reconstructed.json")
    changed = put_in(fixture, ["inputs", "parent_log", Access.at(11), "data", "status"], "failed")

    assert {:ok, original} = PixirMonitor.Projection.project(fixture)
    assert {:ok, mutated} = PixirMonitor.Projection.project(changed)
    assert original["execution"] != mutated["execution"]
    assert mutated["execution"]["state"] == "failed"
  end

  test "rejects an impossible retry target instead of normalizing corrupt evidence" do
    fixture = decode!("fixtures/inputs/f4-advisory-retry-reconstructed.json")
    changed = put_in(fixture, ["inputs", "parent_log", Access.at(5), "data", "failed_child_session_id"], "child-other")

    assert {:error, %{kind: "attempt_retry_target_unresolved"}} =
             PixirMonitor.Projection.project(changed)
  end

  defp decode!(relative) do
    @package |> Path.join(relative) |> File.read!() |> Jason.decode!()
  end
end
