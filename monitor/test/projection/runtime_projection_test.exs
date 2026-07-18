defmodule PixirMonitor.RuntimeProjectionTest do
  @moduledoc """
  Runtime-shaped projection coverage for canonical parent lineage classification.
  """
  use ExUnit.Case, async: true

  test "queued canonical parent lifecycle projects a nonterminal subagent run" do
    input =
      runtime_input("parent-queued", [
        subagent_event("parent-queued", 0, "queued", "queued", "sub-queued", "child-queued")
      ])

    assert {:ok, projection} = PixirMonitor.Projection.project(input)
    assert projection["run"]["strategy"] == "subagents"

    assert projection["execution"] == %{
             "state" => "queued",
             "terminal" => false,
             "basis" => "subagent_event_fold",
             "evidence_refs" => ["e-parent-0"]
           }
  end

  test "malformed live runtime observed_at is confessed, never served raw" do
    # liveness.observed_at is input-reachable ONLY through the live branch of
    # liveness/4 (runtime diagnostics raw passthrough); terminal units are
    # producer-controlled (structural nil). This is the positive coverage for
    # the datetime normalization layer at both the run and unit levels.
    input =
      runtime_input("parent-live", [
        subagent_event("parent-live", 0, "queued", "queued", "sub-live", "child-live")
      ])
      |> put_in(["inputs", "owner_state"], %{"reachable" => true})
      |> put_in(["inputs", "runtime_diagnostics"], %{
        "parent_session_id" => "parent-live",
        "observed_at" => "2026-07-15 23:59:59Z",
        "runtime_gaps" => [],
        "subagents" => []
      })

    assert {:ok, projection} = PixirMonitor.Projection.project(input)

    assert projection["liveness"]["state"] == "live"
    assert projection["liveness"]["observed_at"] == nil
    assert "malformed_timestamp:observed_at:2026-07-15 23:59:59Z" in projection["limitations"]

    [unit] = projection["units"]
    assert unit["liveness"]["state"] == "live"
    assert unit["liveness"]["observed_at"] == nil
    assert "malformed_timestamp:observed_at:2026-07-15 23:59:59Z" in unit["limitations"]
  end

  test "advisory confession cites the projected attempt, never an older one" do
    # Two attempts: the OLDER terminal summary declares an out-of-vocabulary
    # verdict; the NEWER one is advisory-present but declares no verdict at
    # all. advisory/2 projects from the newer attempt, so no confession may
    # cite the older attempt's raw verdict (the drift CodeRabbit flagged on
    # the event-scan implementation).
    older = %{"verdict" => "future_advisory_verdict"}
    newer = %{"summary" => "routine completion"}

    input =
      runtime_input("parent-advisory-drift", [
        subagent_event("parent-advisory-drift", 0, "started", "running", "sub-adv", "child-one"),
        "parent-advisory-drift"
        |> subagent_event(1, "finished", "completed", "sub-adv", "child-one")
        |> put_in(["data", "summary"], Jason.encode!(older)),
        subagent_event("parent-advisory-drift", 2, "started", "running", "sub-adv", "child-two"),
        "parent-advisory-drift"
        |> subagent_event(3, "finished", "completed", "sub-adv", "child-two")
        |> put_in(["data", "summary"], Jason.encode!(newer))
      ])

    assert {:ok, projection} = PixirMonitor.Projection.project(input)

    [unit] = projection["units"]
    assert unit["advisory"]["present"] == true
    assert unit["advisory"]["verdict"] == "unknown"
    refute Map.has_key?(unit["advisory"], "_raw_verdict")

    refute Enum.any?(
             unit["limitations"],
             &String.starts_with?(&1, "unknown_enum:verdict")
           )
  end

  test "classification stays the verdict authority; raw only confesses" do
    # mergeable:false must win over a contradicting in-vocabulary declared
    # verdict: the raw value may never rewrite the classified projection, and
    # an in-vocabulary raw earns no confession (Grok round on PR #407).
    summary = %{"verdict" => "pass", "mergeable" => false}

    input =
      runtime_input("parent-verdict-authority", [
        subagent_event("parent-verdict-authority", 0, "started", "running", "sub-va", "child-va"),
        "parent-verdict-authority"
        |> subagent_event(1, "finished", "completed", "sub-va", "child-va")
        |> put_in(["data", "summary"], Jason.encode!(summary))
      ])

    assert {:ok, projection} = PixirMonitor.Projection.project(input)

    [unit] = projection["units"]
    assert unit["advisory"]["verdict"] == "stop"
    assert unit["advisory"]["mergeable"] == false
    assert "advisory_stop" in unit["attention"]["reasons"]

    refute Enum.any?(
             unit["limitations"],
             &String.starts_with?(&1, "unknown_enum:verdict")
           )
  end

  test "an overridden out-of-vocabulary raw verdict earns no confession" do
    # unknown_enum:field means the field fail-closed to "unknown". When the
    # classifier reaches a real verdict from stronger signals (mergeable),
    # the out-of-vocabulary raw caused no loss, so confessing it would break
    # that invariant (Grok r2 on PR #407). The confession fires only when the
    # classified verdict itself is "unknown" (pinned by the honesty fixture).
    summary = %{"verdict" => "future_advisory_verdict", "mergeable" => false}

    input =
      runtime_input("parent-overridden-verdict", [
        subagent_event("parent-overridden-verdict", 0, "started", "running", "sub-ov", "child-ov"),
        "parent-overridden-verdict"
        |> subagent_event(1, "finished", "completed", "sub-ov", "child-ov")
        |> put_in(["data", "summary"], Jason.encode!(summary))
      ])

    assert {:ok, projection} = PixirMonitor.Projection.project(input)

    [unit] = projection["units"]
    assert unit["advisory"]["verdict"] == "stop"

    refute Enum.any?(
             unit["limitations"],
             &String.starts_with?(&1, "unknown_enum:verdict")
           )
  end

  test "an explicit null start status stays repaired, never re-injected raw" do
    # AttemptStatus.start_status/1 repairs an explicit null to "unknown"; the
    # opened attempt row must carry the repaired value (a raw nil would break
    # the schema's attempt.status enum — Grok round on PR #407).
    input =
      runtime_input("parent-null-status", [
        "parent-null-status"
        |> subagent_event(0, "started", "running", "sub-null", "child-null")
        |> put_in(["data", "status"], nil)
      ])

    assert {:ok, projection} = PixirMonitor.Projection.project(input)

    [unit] = projection["units"]
    [attempt] = unit["attempts"]
    assert attempt["status"] == "unknown"
  end

  test "permission posture alone does not fabricate a subagent run" do
    input =
      runtime_input("child-posture", [
        subagent_event(
          "child-posture",
          0,
          "permission_posture",
          "read_only",
          "posture-marker",
          "child-posture"
        )
      ])

    assert {:ok, projection} = PixirMonitor.Projection.project(input)
    assert projection["run"]["strategy"] == "unknown"
    assert projection["execution"]["state"] == "unknown"
    assert projection["units"] == []
  end

  defp runtime_input(parent_session_id, events) do
    %{
      "projected_at" => "2026-07-10T21:00:00Z",
      "observed_at" => "2026-07-10T21:00:00Z",
      "inputs" => %{
        "terminal_envelope" => nil,
        "delegate_snapshot" => nil,
        "parent_log" => events,
        "parent_log_origin" => "workspace_log",
        "child_logs" => %{},
        "runtime_diagnostics" => nil,
        "owner_state" => %{"state" => "snapshot_only", "reachable" => false},
        "evidence_mirror" => nil
      },
      "completeness" => %{
        "parent_log" => "complete_through_observed_at",
        "child_logs" => "present_empty"
      },
      "parent_session_id" => parent_session_id
    }
  end

  defp subagent_event(session_id, seq, lifecycle, status, subagent_id, child_session_id) do
    %{
      "session_id" => session_id,
      "seq" => seq,
      "ts" => "2026-07-10T21:00:00Z",
      "type" => "subagent_event",
      "data" => %{
        "event" => lifecycle,
        "status" => status,
        "subagent_id" => subagent_id,
        "child_session_id" => child_session_id
      }
    }
  end
end
