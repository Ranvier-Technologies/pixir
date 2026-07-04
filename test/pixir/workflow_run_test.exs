defmodule Pixir.WorkflowRunTest do
  use ExUnit.Case, async: true

  alias Pixir.WorkflowRun

  test "new/2 owns one normalized workflow execution state" do
    workflow = %{
      id: "wf_demo",
      steps: [
        %{id: "inspect"},
        %{id: "summarize"}
      ]
    }

    assert {:ok, run} = WorkflowRun.new(workflow, started_at_ms: 1_000)

    assert run.workflow_id == "wf_demo"
    assert Enum.map(run.pending, & &1.id) == ["inspect", "summarize"]
    assert run.active == %{}
    assert run.completed == %{}
    assert run.completed_order == []
    assert run.waves == []
    assert run.wave == 0
    assert run.started_at_ms == 1_000
  end

  test "deadline_exceeded?/3 preserves current strict timeout semantics" do
    workflow = %{id: "wf_demo", steps: [], timeout_ms: 50}
    assert {:ok, run} = WorkflowRun.new(workflow, started_at_ms: 100)

    assert {:ok, false} = WorkflowRun.deadline_exceeded?(workflow, run, 150)
    assert {:ok, true} = WorkflowRun.deadline_exceeded?(workflow, run, 151)
  end

  test "invalid workflow run inputs return structured invalid_args" do
    assert {:error, %{error: %{kind: :invalid_args}}} = WorkflowRun.new(%{})

    assert {:ok, run} = WorkflowRun.new(%{id: "wf_demo", steps: []}, started_at_ms: 100)

    assert {:error, %{error: %{kind: :invalid_args}}} =
             WorkflowRun.deadline_exceeded?(%{timeout_ms: 0}, run, 100)

    assert {:error, %{error: %{kind: :invalid_args}}} =
             WorkflowRun.deadline_exceeded?(%{timeout_ms: 50}, run, "150")
  end
end
