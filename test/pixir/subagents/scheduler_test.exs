defmodule Pixir.Subagents.SchedulerTest do
  use ExUnit.Case, async: true

  alias Pixir.Subagents.Scheduler

  test "can_start?/2 counts only running agents against max_threads" do
    agents = [
      %{id: "a", status: "running"},
      %{id: "b", status: "queued"},
      %{id: "c", status: "completed"},
      %{id: "d", status: "timed_out"}
    ]

    assert {:ok, 1} = Scheduler.running_count(agents)
    assert {:ok, true} = Scheduler.can_start?(agents, 2)
    assert {:ok, false} = Scheduler.can_start?(agents, 1)
  end

  test "next_startable/1 preserves queued order and the queued agent limit" do
    agents = [
      %{id: "running", status: "running", max_threads: 1},
      %{id: "first", status: "queued", max_threads: 2},
      %{id: "second", status: "queued", max_threads: 2}
    ]

    assert {:ok, %{id: "first"}} = Scheduler.next_startable(agents)

    saturated = [
      %{id: "running", status: "running", max_threads: 1},
      %{id: "first", status: "queued", max_threads: 1},
      %{id: "second", status: "queued", max_threads: 2}
    ]

    assert {:ok, nil} = Scheduler.next_startable(saturated)
  end

  test "next_startable/1 returns nil without queued capacity" do
    assert {:ok, nil} =
             Scheduler.next_startable([%{id: "a", status: "completed", max_threads: 1}])

    assert {:error, %{error: %{kind: :invalid_args}}} = Scheduler.next_startable(:not_agents)
    assert {:error, %{error: %{kind: :invalid_args}}} = Scheduler.can_start?(:not_agents, 1)
    assert {:error, %{error: %{kind: :invalid_args}}} = Scheduler.can_start?([], 0)

    assert {:error, %{error: %{kind: :invalid_args}}} =
             Scheduler.next_startable([%{id: "a", status: "queued"}])
  end
end
