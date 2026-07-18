defmodule PixirMonitor.ProjectionBuilderRepairTest do
  @moduledoc "Synthetic non-golden regressions for parallel and scoped projection repair."
  use ExUnit.Case, async: true

  test "detail execution aggregates latest lifecycle state per Subagent" do
    parent = [
      lifecycle(0, "sub-a", "child-a", "started", "running"),
      lifecycle(1, "sub-b", "child-b", "started", "running"),
      lifecycle(2, "sub-a", "child-a", "finished", "completed")
    ]

    assert {:ok, projection} = PixirMonitor.Projection.Builder.build(input(parent))
    assert projection["execution"]["state"] == "running"
    assert projection["execution"]["terminal"] == false
    assert projection["counts"]["running_units"] == 1
    assert projection["counts"]["completed_units"] == 1
    assert projection["execution"]["evidence_refs"] == ["e-parent-2", "e-parent-1"]
  end

  test "single invalid advisory preserves the frozen run-global evidence id" do
    parent = [
      lifecycle(0, "sub-a", "child-a", "started", "running"),
      lifecycle(1, "sub-a", "child-a", "finished", "completed", "{truncated")
    ]

    assert {:ok, projection} = PixirMonitor.Projection.Builder.build(input(parent))
    assert Enum.any?(projection["evidence"], &(&1["id"] == "e-model-invalid"))
  end

  test "invalid advisory evidence identifiers are scoped to their Subagent units" do
    parent = [
      lifecycle(0, "sub-a", "child-a", "started", "running"),
      lifecycle(1, "sub-a", "child-a", "finished", "completed", "{truncated"),
      lifecycle(2, "sub-b", "child-b", "started", "running"),
      lifecycle(3, "sub-b", "child-b", "finished", "completed", "{also-truncated")
    ]

    assert {:ok, projection} = PixirMonitor.Projection.Builder.build(input(parent))

    invalid_ids =
      projection["evidence"]
      |> Enum.filter(&(&1["source_kind"] == "model_summary"))
      |> Enum.map(& &1["id"])
      |> Enum.sort()

    assert invalid_ids == ["e-model-invalid-sub-a", "e-model-invalid-sub-b"]
  end

  test "single unapplied artifact preserves the frozen run-global evidence id" do
    graph = [%{"id" => "a", "execution_kind" => "virtual_overlay", "depends_on" => []}]

    parent = [
      workflow_event(0, "workflow_started", %{"workflow_id" => "wf", "graph" => %{"steps" => graph}}),
      workflow_event(1, "checkpoint_decided", checkpoint("a", "hash-a"))
    ]

    assert {:ok, projection} = PixirMonitor.Projection.Builder.build(input(parent))
    assert Enum.any?(projection["evidence"], &(&1["id"] == "e-artifact-repair"))
  end

  test "artifact evidence identifiers are scoped to producer units" do
    graph = [
      %{"id" => "a", "execution_kind" => "virtual_overlay", "depends_on" => []},
      %{"id" => "b", "execution_kind" => "virtual_overlay", "depends_on" => []}
    ]

    parent = [
      workflow_event(0, "workflow_started", %{"workflow_id" => "wf", "graph" => %{"steps" => graph}}),
      workflow_event(1, "checkpoint_decided", checkpoint("a", "hash-a")),
      workflow_event(2, "checkpoint_decided", checkpoint("b", "hash-b"))
    ]

    assert {:ok, projection} = PixirMonitor.Projection.Builder.build(input(parent))

    artifact_ids =
      projection["evidence"]
      |> Enum.filter(&(&1["source_kind"] == "artifact"))
      |> Enum.map(& &1["id"])
      |> Enum.sort()

    assert artifact_ids == ["e-artifact-repair-a", "e-artifact-repair-b"]
  end

  test "multiple unapplied artifacts from one unit gain stable unique hash suffixes" do
    graph = [%{"id" => "a", "execution_kind" => "virtual_overlay", "depends_on" => []}]

    artifact = fn hash ->
      %{
        "kind" => "virtual_diff",
        "version" => 1,
        "hash" => hash,
        "workspace_strategy" => "virtual_overlay"
      }
    end

    checkpoint =
      checkpoint("a", "hash-a")
      |> put_in(["checkpoint", "artifact_refs"], [artifact.("hash-a"), artifact.("hash-b")])

    parent = [
      workflow_event(0, "workflow_started", %{"workflow_id" => "wf", "graph" => %{"steps" => graph}}),
      workflow_event(1, "checkpoint_decided", checkpoint)
    ]

    assert {:ok, first} = PixirMonitor.Projection.Builder.build(input(parent))
    assert {:ok, second} = PixirMonitor.Projection.Builder.build(input(parent))

    artifact_ids =
      first["evidence"]
      |> Enum.filter(&(&1["source_kind"] == "artifact"))
      |> Enum.map(& &1["id"])
      |> Enum.sort()

    assert length(artifact_ids) == 2
    assert Enum.uniq(artifact_ids) == artifact_ids
    assert Enum.all?(artifact_ids, &String.starts_with?(&1, "e-artifact-repair-"))
    refute "e-artifact-repair" in artifact_ids

    second_artifact_ids =
      second["evidence"]
      |> Enum.filter(&(&1["source_kind"] == "artifact"))
      |> Enum.map(& &1["id"])
      |> Enum.sort()

    assert artifact_ids == second_artifact_ids

    [unit] = first["units"]

    unit_artifact_ids =
      unit["artifacts"]
      |> Enum.flat_map(& &1["evidence_refs"])
      |> Enum.reject(&(&1 == "e-parent-1"))
      |> Enum.sort()

    assert unit_artifact_ids == artifact_ids
  end

  test "repeated-session wording does not leak to an unaffected sibling" do
    parent = [
      lifecycle(0, "sub-a", "shared-a", "started", "running", nil, "alpha"),
      lifecycle(1, "sub-a", "shared-a", "finished", "completed", nil, "alpha"),
      lifecycle(2, "sub-a", "shared-a", "input", "running", nil, "alpha"),
      lifecycle(3, "sub-a", "shared-a", "finished", "completed", nil, "alpha"),
      lifecycle(4, "sub-b", "child-b", "started", "running", nil, "beta"),
      lifecycle(5, "sub-b", "child-b", "finished", "completed", nil, "beta")
    ]

    assert {:ok, projection} = PixirMonitor.Projection.Builder.build(input(parent))
    sibling = Enum.find(projection["evidence"], &(&1["id"] == "e-parent-5"))
    assert sibling["description"] == "Beta attempt completed."
  end

  test "trusted projection inputs fail closed on conflicting Workflow identities" do
    graph = [
      %{"id" => "a", "depends_on" => []},
      %{"id" => "b", "depends_on" => []}
    ]

    started =
      lifecycle(2, "sub-shared", "child-shared", "started", "running")

    finished =
      lifecycle(3, "sub-shared", "child-shared", "finished", "completed")

    parent = [
      workflow_event(0, "workflow_started", %{"workflow_id" => "wf-conflict", "graph" => %{"steps" => graph}}),
      workflow_event(1, "checkpoint_decided", %{
        "step_id" => "a",
        "child_session_id" => "child-shared",
        "checkpoint_status" => "checkpoint_ready"
      }),
      started,
      finished,
      workflow_event(4, "checkpoint_decided", %{
        "step_id" => "b",
        "child_session_id" => "child-shared",
        "checkpoint_status" => "failed"
      })
    ]

    assert {:error, %{kind: "run_workflow_identity_conflict"}} =
             PixirMonitor.Projection.Builder.build(input(parent))

    subagent_rebind = [
      workflow_event(0, "workflow_started", %{"workflow_id" => "wf-conflict", "graph" => %{"steps" => graph}}),
      lifecycle(1, "sub-shared", "child-a", "started", "running")
      |> put_in(["data", "delegation_context"], %{"step_id" => "a"}),
      lifecycle(2, "sub-shared", "child-a", "finished", "completed")
      |> put_in(["data", "delegation_context"], %{"step_id" => "a"}),
      lifecycle(3, "sub-shared", "child-b", "started", "running")
      |> put_in(["data", "delegation_context"], %{"step_id" => "b"}),
      lifecycle(4, "sub-shared", "child-b", "finished", "completed")
      |> put_in(["data", "delegation_context"], %{"step_id" => "b"})
    ]

    assert {:error, %{kind: "run_workflow_identity_conflict"}} =
             PixirMonitor.Projection.Builder.build(input(subagent_rebind))

    nil_subagent_child_rebind = [
      workflow_event(0, "workflow_started", %{
        "workflow_id" => "wf-conflict",
        "graph" => %{"steps" => graph}
      }),
      lifecycle(1, nil, "child-shared", "started", "running")
      |> put_in(["data", "delegation_context"], %{"step_id" => "a"}),
      lifecycle(2, nil, "child-shared", "finished", "completed")
      |> put_in(["data", "delegation_context"], %{"step_id" => "a"}),
      lifecycle(3, nil, "child-shared", "started", "running")
      |> put_in(["data", "delegation_context"], %{"step_id" => "b"}),
      lifecycle(4, nil, "child-shared", "finished", "completed")
      |> put_in(["data", "delegation_context"], %{"step_id" => "b"})
    ]

    assert {:error, %{kind: "run_workflow_identity_conflict"}} =
             PixirMonitor.Projection.Builder.build(input(nil_subagent_child_rebind))
  end

  test "trusted projection inputs reject concurrent or terminal-status attempt starts" do
    graph = [%{"id" => "work", "depends_on" => []}]

    workflow =
      workflow_event(0, "workflow_started", %{
        "workflow_id" => "wf-attempt-start",
        "graph" => %{"steps" => graph}
      })

    started = fn seq, subagent, child, status ->
      lifecycle(seq, subagent, child, "started", status)
      |> put_in(["data", "delegation_context"], %{"step_id" => "work"})
    end

    assert {:error, %{kind: "attempt_unit_overlap"}} =
             PixirMonitor.Projection.Builder.build(
               input([
                 workflow,
                 started.(1, "sub-a", "child-a", "running"),
                 started.(2, "sub-b", "child-b", "running")
               ])
             )

    for status <- ["completed", "Completed", "completed ", "partial", "held", "", false] do
      assert {:error, %{kind: "attempt_start_status_invalid"}} =
               PixirMonitor.Projection.Builder.build(input([workflow, started.(1, "sub-a", "child-a", status)]))
    end
  end

  test "trusted projection inputs reject cyclic Workflow graphs" do
    parent = [
      workflow_event(0, "workflow_started", %{
        "workflow_id" => "wf-cycle",
        "graph" => %{
          "steps" => [
            %{"id" => "a", "depends_on" => ["b"]},
            %{"id" => "b", "depends_on" => ["a"]}
          ]
        }
      })
    ]

    assert {:error, %{kind: "run_graph_identity_invalid"}} =
             PixirMonitor.Projection.Builder.build(input(parent))
  end

  test "trusted projection inputs reject delimiter-bearing unit components" do
    workflow = [
      workflow_event(0, "workflow_started", %{
        "workflow_id" => "wf-safe",
        "graph" => %{"steps" => [%{"id" => "review:main", "depends_on" => []}]}
      })
    ]

    assert {:error, %{kind: "run_graph_identity_invalid"}} =
             PixirMonitor.Projection.Builder.build(input(workflow))

    fanout = [
      lifecycle(0, "agent:one", "child-one", "started", "running"),
      lifecycle(1, "agent:one", "child-one", "finished", "completed")
    ]

    assert {:error, %{kind: "run_unit_identity_invalid"}} =
             PixirMonitor.Projection.Builder.build(input(fanout))
  end

  test "trusted fan-out inputs reject lifecycle rows without Subagent identities" do
    anonymous = [
      lifecycle(0, nil, "child-anonymous", "started", "running"),
      lifecycle(1, nil, "child-anonymous", "finished", "completed")
    ]

    assert {:error, %{kind: "run_execution_identity_unresolved"}} =
             PixirMonitor.Projection.Builder.build(input(anonymous))

    assert {:error, %{kind: "run_execution_identity_unresolved"}} =
             PixirMonitor.Projection.project(input(anonymous))

    mixed = [
      lifecycle(0, "named", "child-named", "started", "running"),
      lifecycle(1, nil, "child-anonymous", "started", "running")
    ]

    assert {:error, %{kind: "run_execution_identity_unresolved"}} =
             PixirMonitor.Projection.Builder.build(input(mixed))
  end

  test "trusted fan-out inputs reject constraining gates without a Workflow graph" do
    lifecycle = lifecycle(0, "named", "child-named", "started", "running")

    gates = [
      workflow_event(1, "checkpoint_decided", %{
        "step_id" => "ghost",
        "checkpoint_status" => "failed"
      }),
      workflow_event(1, "checkpoint_decided", %{
        "step_id" => "ghost",
        "checkpoint_status" => "partial"
      }),
      workflow_event(1, "checkpoint_decided", %{
        "step_id" => "ghost",
        "checkpoint_status" => "needs_orchestrator"
      }),
      workflow_event(1, "step_held", %{"step_id" => "ghost"})
    ]

    for gate <- gates do
      assert {:error, %{kind: "run_gate_identity_unresolved"}} =
               PixirMonitor.Projection.Builder.build(input([lifecycle, gate]))

      assert {:error, %{kind: "run_gate_identity_unresolved"}} =
               PixirMonitor.Projection.project(input([lifecycle, gate]))
    end

    ready =
      workflow_event(1, "checkpoint_decided", %{
        "step_id" => "ghost",
        "checkpoint_status" => "checkpoint_ready"
      })

    assert {:ok, _projection} =
             PixirMonitor.Projection.Builder.build(input([lifecycle, ready]))
  end

  test "trusted Workflow inputs reject unbound lifecycle and constraining gates" do
    workflow =
      workflow_event(0, "workflow_started", %{
        "workflow_id" => "wf-bindings",
        "graph" => %{"steps" => [%{"id" => "review", "depends_on" => []}]}
      })

    unbound_lifecycle = [
      workflow,
      lifecycle(1, "worker", "child-worker", "started", "running"),
      lifecycle(2, "worker", "child-worker", "finished", "completed")
    ]

    assert {:error, %{kind: "run_execution_identity_unresolved"}} =
             PixirMonitor.Projection.Builder.build(input(unbound_lifecycle))

    assert {:error, %{kind: "run_execution_identity_unresolved"}} =
             PixirMonitor.Projection.project(input(unbound_lifecycle))

    rogue_child_reuse = [
      workflow,
      lifecycle(1, nil, "child-shared", "started", "running")
      |> put_in(["data", "delegation_context"], %{"step_id" => "review"}),
      lifecycle(2, nil, "child-shared", "finished", "completed")
      |> put_in(["data", "delegation_context"], %{"step_id" => "review"}),
      lifecycle(3, nil, "child-shared", "started", "running")
      |> put_in(["data", "delegation_context"], %{"step_id" => "ghost"})
    ]

    assert {:error, %{kind: "run_execution_identity_unresolved"}} =
             PixirMonitor.Projection.Builder.build(input(rogue_child_reuse))

    rogue_gate = [
      workflow,
      workflow_event(1, "checkpoint_decided", %{
        "step_id" => "ghost",
        "checkpoint_status" => "failed"
      })
    ]

    assert {:error, %{kind: "run_gate_identity_unresolved"}} =
             PixirMonitor.Projection.Builder.build(input(rogue_gate))
  end

  test "trusted projection inputs reject unsafe logical-id containers" do
    unsafe_workflow = [
      workflow_event(0, "workflow_started", %{
        "workflow_id" => "wf:unsafe",
        "graph" => %{"steps" => [%{"id" => "review", "depends_on" => []}]}
      })
    ]

    assert {:error, %{kind: "run_graph_identity_invalid"}} =
             PixirMonitor.Projection.Builder.build(input(unsafe_workflow))

    unsafe_run = put_in(input([]), ["inputs", "terminal_envelope", "delegate_id"], "dlg:unsafe")

    assert {:error, %{kind: "run_identity_invalid"}} =
             PixirMonitor.Projection.Builder.build(unsafe_run)

    dotted_run = put_in(input([]), ["inputs", "terminal_envelope", "delegate_id"], "dlg.with.dots")

    assert {:ok, _projection} =
             PixirMonitor.Projection.Builder.build(dotted_run)
  end

  defp input(parent) do
    %{
      "projected_at" => "2026-07-11T00:00:00Z",
      "inputs" => %{
        "terminal_envelope" => %{
          "delegate_id" => "dlg-repair",
          "parent_session_id" => "parent",
          "mode" => "read_only",
          "strategy" => "subagents",
          "status" => "running"
        },
        "delegate_snapshot" => nil,
        "parent_log" => parent,
        "parent_log_origin" => "fixture",
        "child_logs" => %{},
        "runtime_diagnostics" => nil,
        "owner_state" => %{"state" => "snapshot_only", "reachable" => false},
        "evidence_mirror" => nil
      },
      "completeness" => %{"parent_log" => "complete", "child_logs" => "explicitly_missing"}
    }
  end

  defp workflow_event(seq, kind, data) do
    %{
      "seq" => seq,
      "ts" => "2026-07-11T00:00:0#{seq}Z",
      "type" => "workflow_event",
      "session_id" => "parent",
      "data" => Map.put(data, "kind", kind)
    }
  end

  defp checkpoint(step_id, hash) do
    %{
      "step_id" => step_id,
      "checkpoint_status" => "checkpoint_ready",
      "dependent_safe" => true,
      "checkpoint" => %{
        "artifact_refs" => [
          %{
            "kind" => "virtual_diff",
            "version" => 1,
            "hash" => hash,
            "workspace_strategy" => "virtual_overlay"
          }
        ]
      }
    }
  end

  defp lifecycle(seq, subagent_id, child_id, event, status, summary \\ nil, agent \\ "worker") do
    data = %{
      "event" => event,
      "status" => status,
      "subagent_id" => subagent_id,
      "child_session_id" => child_id,
      "agent" => agent,
      "workspace_mode" => "shared",
      "posture" => "read_only"
    }

    data = if is_binary(summary), do: Map.put(data, "summary", summary), else: data

    %{
      "seq" => seq,
      "ts" => "2026-07-11T00:00:0#{seq}Z",
      "type" => "subagent_event",
      "session_id" => "parent",
      "data" => data
    }
  end
end
