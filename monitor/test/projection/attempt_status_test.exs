defmodule PixirMonitor.Projection.AttemptStatusTest do
  @moduledoc "Contract pins for canonical durable attempt start status."
  use ExUnit.Case, async: true

  alias PixirMonitor.Projection.AttemptStatus

  test "accepts only canonical open statuses and honest absence" do
    for status <- ~w(queued running unknown) do
      assert AttemptStatus.start_status(%{"status" => status}) == {:ok, status}
    end

    assert AttemptStatus.start_status(%{}) == {:ok, "unknown"}
    assert AttemptStatus.start_status(%{"status" => nil}) == {:ok, "unknown"}
  end

  test "rejects terminal, gate-only, blank, mixed-case, and non-string statuses" do
    invalid =
      ~w(completed failed timed_out cancelled detached closed partial held Completed) ++
        ["completed ", "", "   ", false, 1, [], %{}]

    for status <- invalid do
      assert AttemptStatus.start_status(%{"status" => status}) ==
               {:error, :invalid_open_status}
    end

    assert AttemptStatus.start_status("running") == {:error, :invalid_open_status}
  end
end
