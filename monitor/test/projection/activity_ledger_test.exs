defmodule PixirMonitor.ProjectionActivityLedgerTest do
  @moduledoc """
  The polling caller's observation-to-observation memory (#440).

  This is the only component permitted to hold state across observations, and
  it may only hold durable Log coordinates. Nothing here consults a clock.
  """
  use ExUnit.Case, async: true

  alias PixirMonitor.Projection.ActivityLedger

  describe "classify/2" do
    test "a first observation cannot assert advancement" do
      assert ActivityLedger.classify({7, "2026-07-31T09:00:00Z"}, nil) == "unknown"
    end

    test "a higher durable sequence is advancement" do
      assert ActivityLedger.classify({8, "2026-07-31T09:01:00Z"}, {7, "2026-07-31T09:00:00Z"}) ==
               "advanced"
    end

    test "an identical durable sequence is not advancement" do
      assert ActivityLedger.classify({7, "2026-07-31T09:00:00Z"}, {7, "2026-07-31T09:00:00Z"}) ==
               "unchanged"
    end

    test "an identical durable sequence is unchanged even when the timestamp moved" do
      assert ActivityLedger.classify({7, "2026-07-31T09:01:00Z"}, {7, "2026-07-31T09:00:00Z"}) ==
               "unchanged"
    end

    test "a regressed durable sequence asserts nothing rather than claiming health" do
      assert ActivityLedger.classify({6, "2026-07-31T09:01:00Z"}, {7, "2026-07-31T09:00:00Z"}) ==
               "unknown"
    end

    test "a later durable timestamp advances when no sequence is available" do
      assert ActivityLedger.classify({nil, "2026-07-31T09:01:00Z"}, {nil, "2026-07-31T09:00:00Z"}) ==
               "advanced"
    end

    test "absent coordinates on either side assert nothing" do
      assert ActivityLedger.classify({nil, nil}, {nil, nil}) == "unknown"
      assert ActivityLedger.classify({3, nil}, {nil, nil}) == "unknown"
    end

    test "every classification is inside the admitted vocabulary" do
      cases = [
        {{8, "b"}, {7, "a"}},
        {{7, "a"}, {7, "a"}},
        {{6, "b"}, {7, "a"}},
        {{nil, nil}, {nil, nil}},
        {{1, "a"}, nil}
      ]

      for {current, prior} <- cases do
        assert ActivityLedger.classify(current, prior) in ActivityLedger.vocabulary()
      end
    end
  end

  describe "observe/3" do
    test "successive observations of one run identity assert advancement only when it advanced" do
      run = "run-ledger-" <> Integer.to_string(System.unique_integer([:positive]))

      first = ActivityLedger.observe(run, 0, "2026-07-31T09:00:00Z")
      assert first["durable_evidence"] == "unknown"
      assert first["prior_as_of_seq"] == nil
      assert first["basis"] == "caller_observation_delta"

      second = ActivityLedger.observe(run, 1, "2026-07-31T09:00:10Z")
      assert second["durable_evidence"] == "advanced"
      assert second["prior_as_of_seq"] == 0
      assert second["prior_last_durable_at"] == "2026-07-31T09:00:00Z"

      third = ActivityLedger.observe(run, 1, "2026-07-31T09:00:10Z")
      assert third["durable_evidence"] == "unchanged"
    end

    test "run identities do not contaminate each other" do
      a = "run-ledger-a-" <> Integer.to_string(System.unique_integer([:positive]))
      b = "run-ledger-b-" <> Integer.to_string(System.unique_integer([:positive]))

      ActivityLedger.observe(a, 5, "2026-07-31T09:00:00Z")
      assert ActivityLedger.observe(b, 5, "2026-07-31T09:00:00Z")["durable_evidence"] == "unknown"
      assert ActivityLedger.observe(a, 6, "2026-07-31T09:00:05Z")["durable_evidence"] == "advanced"
    end

    test "a non-binary run identity asserts nothing" do
      assert ActivityLedger.observe(:not_a_run, 1, "2026-07-31T09:00:00Z") == nil
    end

    # The bound must not become a permanent ceiling: a long-lived Monitor that has
    # seen more identities than the ledger holds must still be able to assert
    # advancement for the runs it is actually polling now.
    test "a run observed after the bound is exceeded can still assert advancement" do
      {:ok, ledger} = start_supervised({ActivityLedger, name: :"ledger_#{System.unique_integer([:positive])}"})
      max = ActivityLedger.max_entries()

      for i <- 1..max do
        GenServer.call(ledger, {:observe, "filler-#{i}", i, "2026-07-31T09:00:00Z"})
      end

      run = "run-after-bound"
      first = GenServer.call(ledger, {:observe, run, 1, "2026-07-31T09:00:00Z"})
      assert first["durable_evidence"] == "unknown"

      second = GenServer.call(ledger, {:observe, run, 2, "2026-07-31T09:00:10Z"})
      assert second["durable_evidence"] == "advanced"
      assert second["prior_as_of_seq"] == 1
    end
  end
end
