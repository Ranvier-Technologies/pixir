defmodule Pixir.Delegate.CriticalPathTest do
  use ExUnit.Case, async: true

  alias Pixir.Delegate.CriticalPath

  describe "estimate_subagents/3" do
    test "uses ceil task waves times the resolved uniform child budget" do
      assert {:ok,
              %{
                estimated_critical_path_ms: 180_000,
                waves: 3,
                suggested_timeout_ms: 180_000
              }} = CriticalPath.estimate_subagents(5, 2, 60_000)

      assert {:ok, %{estimated_critical_path_ms: 60_000, waves: 1}} =
               CriticalPath.estimate_subagents(2, 2, 60_000)
    end
  end

  describe "estimate_workflow/3" do
    test "sums the maximum effective step budget in each dependency wave" do
      steps = [
        %{"id" => "a", "timeout_ms" => 10_000},
        %{"id" => "b", "timeout_ms" => 30_000},
        %{"id" => "c", "timeout_ms" => 7_000},
        %{"id" => "d", "timeout_ms" => 20_000}
      ]

      assert {:ok,
              %{
                estimated_critical_path_ms: 57_000,
                waves: 3,
                suggested_timeout_ms: 57_000
              }} = CriticalPath.estimate_workflow(steps, [[0, 1], [2], [3]], 120_000)
    end

    test "uses the workflow default for omitted step budgets" do
      steps = [
        %{"id" => "explicit", "timeout_ms" => 15_000},
        %{"id" => "defaulted"}
      ]

      assert {:ok,
              %{
                estimated_critical_path_ms: 135_000,
                waves: 2,
                suggested_timeout_ms: 135_000
              }} = CriticalPath.estimate_workflow(steps, [[0], [1]], 120_000)
    end

    test "uses the runtime child default for omitted step budgets across a longer workflow horizon" do
      steps = [
        %{"id" => "first"},
        %{"id" => "second"}
      ]

      assert {:ok,
              %{
                estimated_critical_path_ms: 240_000,
                waves: 2,
                suggested_timeout_ms: 240_000,
                wave_budgets_ms: [120_000, 120_000]
              }} = CriticalPath.estimate_workflow(steps, [[0], [1]], 240_000)
    end

    test "caps omitted runtime-default budgets while suggesting the uncapped fixed point" do
      steps = [
        %{"id" => "first"},
        %{"id" => "second"}
      ]

      assert {:ok,
              %{
                estimated_critical_path_ms: 180_000,
                waves: 2,
                suggested_timeout_ms: 240_000,
                wave_budgets_ms: [90_000, 90_000]
              }} = CriticalPath.estimate_workflow(steps, [[0], [1]], 90_000)
    end

    test "caps explicit step budgets while suggesting the minimum sufficient fixed point" do
      steps = [
        %{"id" => "capped", "timeout_ms" => 200_000},
        %{"id" => "within-cap", "timeout_ms" => 80_000}
      ]

      assert {:ok,
              %{
                estimated_critical_path_ms: 180_000,
                waves: 2,
                suggested_timeout_ms: 280_000,
                wave_budgets_ms: [100_000, 80_000]
              }} = CriticalPath.estimate_workflow(steps, [[0], [1]], 100_000)
    end

    test "chooses the lowest source step index when wave maxima tie" do
      steps = [
        %{"id" => "first", "timeout_ms" => 40_000},
        %{"id" => "second", "timeout_ms" => 40_000}
      ]

      assert {:ok, %{json_pointer: "/steps/0/timeout_ms"}} =
               CriticalPath.estimate_workflow(steps, [[1, 0]], 120_000)
    end
  end

  describe "capped_step_budgets/3" do
    test "names every explicitly declared step budget the declared workflow timeout caps" do
      steps = [
        %{"id" => "long", "timeout_ms" => 1_800_000},
        %{"id" => "short", "timeout_ms" => 60_000},
        %{"id" => "also-long", "timeout_ms" => 900_000}
      ]

      assert [first, second] = CriticalPath.capped_step_budgets(steps, 600_000, true)

      assert %{
               "step_index" => 0,
               "step_id" => "long",
               "json_pointer" => "/steps/0/timeout_ms",
               "path" => ["steps", 0, "timeout_ms"],
               "declared_step_timeout_ms" => 1_800_000,
               "declared_workflow_timeout_ms" => 600_000,
               "effective_step_timeout_ms" => 600_000,
               "message" => message
             } = first

      assert message ==
               "step budget 1800000 ms is capped by workflow timeout 600000 ms and will be cancelled at 600000 ms"

      assert %{"step_index" => 2, "declared_step_timeout_ms" => 900_000} = second
    end

    test "does not fire for omitted step budgets or budgets within the declared timeout" do
      steps = [
        %{"id" => "omitted"},
        %{"id" => "equal", "timeout_ms" => 600_000},
        %{"id" => "shorter", "timeout_ms" => 60_000}
      ]

      assert [] == CriticalPath.capped_step_budgets(steps, 600_000, true)
    end

    test "does not fire when the workflow timeout was defaulted rather than declared" do
      steps = [%{"id" => "long", "timeout_ms" => 1_800_000}]

      assert [] == CriticalPath.capped_step_budgets(steps, 600_000, false)
    end

    test "rebases the emitted location onto the submitted nested workflow.steps path" do
      steps = [
        %{"id" => "short", "timeout_ms" => 60_000},
        %{"id" => "long", "timeout_ms" => 1_800_000}
      ]

      assert [entry] =
               CriticalPath.capped_step_budgets(steps, 600_000, true, ["workflow", "steps"])

      assert %{
               "step_index" => 1,
               "json_pointer" => "/workflow/steps/1/timeout_ms",
               "path" => ["workflow", "steps", 1, "timeout_ms"]
             } = entry
    end
  end

  describe "capped_step_budget_warning/1" do
    test "carries both recovery directions and the runtime retry token" do
      entries =
        CriticalPath.capped_step_budgets(
          [%{"id" => "long", "timeout_ms" => 1_800_000}],
          600_000,
          true
        )

      assert %{
               "kind" => "step_budget_capped_by_workflow_timeout",
               "declared_workflow_timeout_ms" => 600_000,
               "steps" => ^entries,
               "next_actions" => next_actions,
               "summary" => summary
             } = CriticalPath.capped_step_budget_warning(entries)

      assert "increase_workflow_timeout_to_cover_declared_step_timeouts" in next_actions
      assert "reduce_workflow_step_timeouts" in next_actions
      assert "retry_workflow_with_larger_timeout" in next_actions

      assert summary =~
               "step budget 1800000 ms is capped by workflow timeout 600000 ms and will be cancelled at 600000 ms"
    end

    test "returns nil when no step budget is capped" do
      assert is_nil(CriticalPath.capped_step_budget_warning([]))
    end
  end

  describe "rejection/1" do
    test "uses workflow-specific recovery actions and human-readable wave arithmetic" do
      rejection =
        CriticalPath.rejection(%{
          "strategy" => "workflow",
          "effective_timeout_ms" => 120_000,
          "estimated_critical_path_ms" => 240_000,
          "waves" => 2,
          "suggested_timeout_ms" => 240_000,
          "wave_budgets_ms" => [120_000, 120_000]
        })

      assert rejection["message"] ==
               "120000ms + 120000ms = 240000ms > 120000ms horizon"

      next_actions = rejection["details"]["next_actions"]

      assert "increase_delegate_timeout_to_suggested_timeout_ms" in next_actions
      assert "rerun_with_--allow-short-horizon" in next_actions
      assert Enum.any?(next_actions, &String.contains?(&1, "workflow"))
      refute "reduce_delegate_task_count" in next_actions
      refute "increase_subagents_max_threads" in next_actions
    end

    test "classifies recovery from explicit caller and workflow binding evidence" do
      rejection =
        CriticalPath.rejection(%{
          "strategy" => "workflow",
          "caller_horizon_ms" => 90_000,
          "declared_workflow_timeout_ms" => 100_000,
          "declared_workflow_timeout_explicit" => true,
          "effective_timeout_ms" => 90_000,
          "estimated_critical_path_ms" => 180_000,
          "waves" => 2,
          "suggested_timeout_ms" => 280_000,
          "wave_budgets_ms" => [90_000, 90_000]
        })

      next_actions = rejection["details"]["next_actions"]

      assert "increase_delegate_and_workflow_timeouts_to_suggested_timeout_ms" in next_actions
      refute "increase_delegate_timeout_to_suggested_timeout_ms" in next_actions
      refute "increase_workflow_timeout_to_suggested_timeout_ms" in next_actions
      assert "reduce_workflow_dependency_waves" in next_actions
      assert "reduce_workflow_step_timeouts" in next_actions
      assert "rerun_with_--allow-short-horizon" in next_actions
    end

    test "classifies an explicit wait horizon as an independent recovery knob" do
      rejection =
        CriticalPath.rejection(%{
          "strategy" => "subagents",
          "delegate_timeout_ms" => 150_000,
          "wait_horizon_ms" => 100_000,
          "wait_horizon_explicit" => true,
          "effective_timeout_ms" => 100_000,
          "estimated_critical_path_ms" => 120_000,
          "waves" => 1,
          "suggested_timeout_ms" => 120_000,
          "per_wave_budget_ms" => 120_000,
          "wave_budgets_ms" => [120_000]
        })

      assert rejection["message"] ==
               "1 waves x 120000ms per wave = 120000ms > 100000ms horizon"

      next_actions = rejection["details"]["next_actions"]

      assert "increase_wait_horizon_to_suggested_timeout_ms" in next_actions
      refute "increase_delegate_timeout_to_suggested_timeout_ms" in next_actions
    end

    test "workflow recovery combines explicit short wait and workflow horizons" do
      rejection =
        CriticalPath.rejection(%{
          "strategy" => "workflow",
          "caller_horizon_ms" => 100_000,
          "wait_horizon_explicit" => true,
          "declared_workflow_timeout_ms" => 100_000,
          "declared_workflow_timeout_explicit" => true,
          "effective_timeout_ms" => 100_000,
          "estimated_critical_path_ms" => 200_000,
          "waves" => 2,
          "suggested_timeout_ms" => 240_000,
          "wave_budgets_ms" => [100_000, 100_000]
        })

      next_actions = rejection["details"]["next_actions"]

      assert "increase_wait_horizon_and_workflow_timeouts_to_suggested_timeout_ms" in next_actions
      refute "increase_delegate_and_workflow_timeouts_to_suggested_timeout_ms" in next_actions
      refute "increase_wait_horizon_to_suggested_timeout_ms" in next_actions
      refute "increase_workflow_timeout_to_suggested_timeout_ms" in next_actions
    end

    test "non-explicit workflow timeout combines an explicit short wait with its delegate source" do
      rejection =
        CriticalPath.rejection(%{
          "strategy" => "workflow",
          "caller_horizon_ms" => 100_000,
          "wait_horizon_explicit" => true,
          "declared_workflow_timeout_ms" => 150_000,
          "declared_workflow_timeout_explicit" => false,
          "effective_timeout_ms" => 100_000,
          "estimated_critical_path_ms" => 200_000,
          "waves" => 2,
          "suggested_timeout_ms" => 240_000,
          "wave_budgets_ms" => [100_000, 100_000]
        })

      assert [
               "increase_wait_horizon_and_delegate_timeout_to_suggested_timeout_ms",
               "reduce_workflow_dependency_waves",
               "reduce_workflow_step_timeouts",
               "rerun_with_--allow-short-horizon"
             ] == rejection["details"]["next_actions"]
    end

    test "non-explicit workflow timeout prescribes only delegate repair when wait is sufficient" do
      rejection =
        CriticalPath.rejection(%{
          "strategy" => "workflow",
          "caller_horizon_ms" => 240_000,
          "wait_horizon_explicit" => true,
          "declared_workflow_timeout_ms" => 150_000,
          "declared_workflow_timeout_explicit" => false,
          "effective_timeout_ms" => 150_000,
          "estimated_critical_path_ms" => 240_000,
          "waves" => 2,
          "suggested_timeout_ms" => 240_000,
          "wave_budgets_ms" => [120_000, 120_000]
        })

      assert [
               "increase_delegate_timeout_to_suggested_timeout_ms",
               "reduce_workflow_dependency_waves",
               "reduce_workflow_step_timeouts",
               "rerun_with_--allow-short-horizon"
             ] == rejection["details"]["next_actions"]
    end
  end
end
