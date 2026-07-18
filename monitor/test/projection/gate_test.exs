defmodule PixirMonitor.Projection.GateTest do
  @moduledoc "Contract pins for shared Workflow gate normalization."
  use ExUnit.Case, async: true

  alias PixirMonitor.Projection.Gate

  test "preserves only contract-valid checkpoint states" do
    for state <- ~w(checkpoint_ready partial failed held needs_orchestrator not_applicable unknown) do
      assert Gate.state(%{"data" => %{"kind" => "checkpoint_decided", "checkpoint_status" => state}}) ==
               {:ok, state}
    end

    for invalid <- ["", "   ", "ready", "CHECKPOINT_READY", 42, false, %{}] do
      assert Gate.state(%{"data" => %{"kind" => "checkpoint_decided", "checkpoint_status" => invalid}}) ==
               {:ok, "unknown"}
    end
  end

  test "retains structural held semantics only when explicit status is blank" do
    assert Gate.state(%{"data" => %{"kind" => "step_held"}}) == {:ok, "held"}

    assert Gate.state(%{"data" => %{"kind" => "step_held", "checkpoint_status" => nil}}) ==
             {:ok, "held"}

    assert Gate.state(%{"data" => %{"kind" => "step_held", "checkpoint_status" => "  "}}) ==
             {:ok, "held"}

    for invalid <- ["ready", 42, false, %{}] do
      assert Gate.state(%{"data" => %{"kind" => "step_held", "checkpoint_status" => invalid}}) ==
               {:ok, "unknown"}
    end
  end

  test "normalizes malformed event data without raising" do
    for malformed <- ["checkpoint", ["checkpoint"], 42, true, false, nil] do
      assert Gate.state(%{"data" => malformed}) == {:ok, "unknown"}
      assert Gate.dependent_safe(%{"data" => malformed}) == {:ok, nil}
    end

    assert Gate.state("checkpoint") == {:ok, "unknown"}
    assert Gate.dependent_safe("checkpoint") == {:ok, nil}
  end

  test "normalizes dependency safety without allowing non-ready gates to claim true" do
    assert Gate.dependent_safe(%{
             "data" => %{
               "kind" => "checkpoint_decided",
               "checkpoint_status" => "checkpoint_ready",
               "dependent_safe" => true
             }
           }) == {:ok, true}

    assert Gate.dependent_safe(%{
             "data" => %{
               "kind" => "checkpoint_decided",
               "checkpoint_status" => "failed",
               "dependent_safe" => true
             }
           }) == {:ok, false}

    for invalid <- ["yes", 1, [], %{}] do
      assert Gate.dependent_safe(%{"data" => %{"dependent_safe" => invalid}}) ==
               {:ok, nil}
    end
  end
end
