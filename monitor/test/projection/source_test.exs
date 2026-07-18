defmodule PixirMonitor.ProjectionSourceTest do
  @moduledoc """
  Runtime RunSource contract coverage through an injected bounded input provider.
  """
  use ExUnit.Case, async: false

  defmodule Provider do
    @moduledoc "Injected provider proving that HTTP run ids never become workspace paths."
    @behaviour PixirMonitor.Projection.Source.InputProvider

    @impl true
    def list_runs(_opts), do: {:ok, [row()]}

    @impl true
    def fetch_input("run-1", _opts), do: {:error, %{kind: "fixture_only", message: "detail intentionally unavailable", details: %{}}}
    def fetch_input(id, _opts), do: {:error, %{kind: "unexpected_id", message: "unexpected id", details: %{id: id}}}

    defp row do
      %{
        "id" => "run-1",
        "title" => "Run one",
        "strategy" => "subagents",
        "execution" => %{"state" => "running", "terminal" => false},
        "liveness" => %{"state" => "unobserved", "reachable" => false, "basis" => "parent_log_only"},
        "source" => %{"mode" => "reconstructed", "freshness" => "unknown"},
        "counts" => %{"planned_units" => 1, "completed_units" => 0, "attention_units" => 0},
        "attention" => %{"basis" => "parent_log_only", "reasons" => []},
        "gate_counts" => %{},
        "advisory_counts" => %{},
        "mutation" => %{"status" => "unknown", "observed_semantics" => "unknown"},
        "latest_at" => "2026-07-10T00:00:00Z"
      }
    end
  end

  setup do
    old_provider = Application.get_env(:pixir_monitor, :projection_input_provider)
    old_source = Application.get_env(:pixir_monitor, :projection_source)
    Application.put_env(:pixir_monitor, :projection_input_provider, Provider)
    Application.put_env(:pixir_monitor, :projection_source, workspace: "/server-owned")

    on_exit(fn ->
      restore(:projection_input_provider, old_provider)
      restore(:projection_source, old_source)
    end)
  end

  test "returns the frozen list envelope and parent-derived row" do
    assert {:ok, %{"schema" => "pixir.monitor.runs", "schema_version" => 1, "runs" => [row]}} =
             PixirMonitor.Projection.Source.list_runs()

    assert row["id"] == "run-1"
    assert row["counts"]["attention_units"] == 0
    assert row["attention"] == %{"basis" => "parent_log_only", "reasons" => []}
  end

  test "workspace failures disclose only the basename while logging the absolute path locally" do
    configured =
      Path.join(
        System.tmp_dir!(),
        "pixir-monitor-missing/workspace-#{System.unique_integer([:positive, :monotonic])}"
      )

    expanded = Path.expand(configured)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:error,
                %{
                  kind: "workspace_unavailable",
                  message: "Configured monitor workspace cannot be read",
                  details: %{workspace_basename: basename, reason: "enoent"}
                } = error} =
                 PixirMonitor.Projection.Source.Filesystem.list_runs(workspace: configured)

        assert basename == Path.basename(expanded)

        encoded = Jason.encode!(error)
        refute encoded =~ expanded
        refute encoded =~ "/"
        refute Map.has_key?(error.details, :workspace)
      end)

    assert log =~ expanded
  end

  test "workspace-is-a-file failures also disclose only the basename" do
    configured =
      Path.join(
        System.tmp_dir!(),
        "pixir-monitor-not-a-dir-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.write!(configured, "not a directory")
    on_exit(fn -> File.rm_rf!(configured) end)

    expanded = Path.expand(configured)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:error,
                %{
                  kind: "workspace_unavailable",
                  message: "Configured monitor workspace is not a directory",
                  details: %{workspace_basename: basename}
                } = error} =
                 PixirMonitor.Projection.Source.Filesystem.list_runs(workspace: configured)

        assert basename == Path.basename(expanded)

        encoded = Jason.encode!(error)
        refute encoded =~ expanded
        refute encoded =~ "/"
        refute Map.has_key?(error.details, :workspace)
      end)

    assert log =~ expanded
  end

  test "corrupt log failures expose only a bounded error kind and log the full local error" do
    workspace =
      Path.join(
        System.tmp_dir!(),
        "pixir-monitor-corrupt-log-#{System.unique_integer([:positive, :monotonic])}"
      )

    expanded = Path.expand(workspace)
    sessions = Path.join([expanded, ".pixir", "sessions"])
    log_path = Path.join(sessions, "corrupt-run.ndjson")
    File.mkdir_p!(sessions)
    File.write!(log_path, "not-json\n")
    on_exit(fn -> File.rm_rf!(workspace) end)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:error,
                %{
                  kind: "run_log_failed",
                  message: "Session Log could not be folded",
                  details: %{run_id: "corrupt-run", reason: "corrupt_log_line"}
                } = error} =
                 PixirMonitor.Projection.Source.Filesystem.fetch_input("corrupt-run", workspace: workspace)

        encoded = Jason.encode!(error)
        refute encoded =~ expanded
        refute encoded =~ sessions
      end)

    assert log =~ log_path
  end

  test "filesystem inventory omits posture-only children and counts real parent lifecycle" do
    workspace =
      Path.join(
        System.tmp_dir!(),
        "pixir-monitor-source-#{System.unique_integer([:positive, :monotonic])}"
      )

    sessions = Path.join([workspace, ".pixir", "sessions"])
    File.mkdir_p!(sessions)
    on_exit(fn -> File.rm_rf!(workspace) end)

    write_log(sessions, "child-session", [
      event("child-session", "child-session", 0, "2026-07-10T00:00:00Z", "permission_posture", "read_only", nil)
    ])

    write_log(sessions, "parent-session", [
      event("parent-session", "child-real", 0, "2026-07-10T00:00:01Z", "started", "running", "sub-real"),
      event("parent-session", "child-real", 1, "2026-07-10T00:00:02Z", "finished", "completed", "sub-real")
    ])

    write_log(sessions, "queued-parent", [
      event("queued-parent", "child-queued", 0, "2026-07-10T00:00:03Z", "queued", "queued", "sub-queued")
    ])

    assert {:ok, %{"rows" => rows, "metadata" => metadata}} =
             PixirMonitor.Projection.Source.Filesystem.list_runs(workspace: workspace)

    assert metadata == %{
             "total" => 3,
             "selected" => 3,
             "projected_runs" => 2,
             "non_parent_logs" => 1,
             "dropped_logs" => 0,
             "truncated" => false,
             "limitations" => []
           }

    assert rows |> Enum.map(& &1["id"]) |> Enum.sort() == ["parent-session", "queued-parent"]

    rows_by_id = Map.new(rows, &{&1["id"], &1})
    row = rows_by_id["parent-session"]

    assert row["execution"] == %{"state" => "completed", "terminal" => true}

    assert row["counts"] == %{
             "planned_units" => 1,
             "completed_units" => 1,
             "attention_units" => 0
           }

    queued = rows_by_id["queued-parent"]
    assert queued["execution"] == %{"state" => "queued", "terminal" => false}

    assert queued["counts"] == %{
             "planned_units" => 1,
             "completed_units" => 0,
             "attention_units" => 0
           }
  end

  test "list and detail agree on an out-of-vocabulary workflow finish status" do
    # The detail Builder normalizes a raw workflow_finished status outside the
    # served vocabulary to "unknown" with a confession; the list fold must
    # fail-close the SAME raw value the same way, or the two surfaces disagree
    # on the state of one run (Grok round on PR #407).
    workspace =
      Path.join(
        System.tmp_dir!(),
        "pixir-monitor-source-#{System.unique_integer([:positive, :monotonic])}"
      )

    sessions = Path.join([workspace, ".pixir", "sessions"])
    File.mkdir_p!(sessions)
    on_exit(fn -> File.rm_rf!(workspace) end)

    write_log(sessions, "future-finish", [
      workflow_event("future-finish", 0, "2026-07-10T00:00:00Z", "workflow_started", %{
        "workflow_id" => "wf-future-finish",
        "workflow_name" => "Future finish",
        "graph" => %{"steps" => [%{"id" => "only-step"}]}
      }),
      "future-finish"
      |> event("child-future", 1, "2026-07-10T00:00:01Z", "started", "running", "sub-future")
      |> put_in(["data", "delegation_context"], %{"step_id" => "only-step"}),
      "future-finish"
      |> event("child-future", 2, "2026-07-10T00:00:02Z", "finished", "completed", "sub-future")
      |> put_in(["data", "delegation_context"], %{"step_id" => "only-step"}),
      workflow_event("future-finish", 3, "2026-07-10T00:00:03Z", "workflow_finished", %{
        "workflow_id" => "wf-future-finish",
        "status" => "future_execution_state"
      })
    ])

    assert {:ok, %{"rows" => [row]}} =
             PixirMonitor.Projection.Source.Filesystem.list_runs(workspace: workspace)

    assert row["execution"] == %{"state" => "unknown", "terminal" => false}

    assert {:ok, detail_input} =
             PixirMonitor.Projection.Source.Filesystem.fetch_input("future-finish",
               workspace: workspace
             )

    assert {:ok, detail} = PixirMonitor.Projection.Builder.build(detail_input)
    assert detail["execution"]["state"] == "unknown"
    assert detail["execution"]["terminal"] == false
    assert "unknown_enum:state:future_execution_state" in detail["limitations"]
  end

  test "list liveness is honest: nonterminal rows are unobserved, terminal rows not_applicable, never unknown" do
    # Regression pin for #346: this nonterminal fixture previously projected
    # liveness state "unknown", which the UI grouped under an unreachable
    # "Active" bucket (Active requires state "live"). List scope reads the
    # parent Log only, so the honest state is "unobserved" with its basis.
    workspace =
      Path.join(
        System.tmp_dir!(),
        "pixir-monitor-source-liveness-honesty-#{System.unique_integer([:positive, :monotonic])}"
      )

    sessions = Path.join([workspace, ".pixir", "sessions"])
    File.mkdir_p!(sessions)
    on_exit(fn -> File.rm_rf!(workspace) end)

    write_log(sessions, "running-parent", [
      event("running-parent", "child-running", 0, "2026-07-10T00:00:00Z", "started", "running", "sub-running")
    ])

    write_log(sessions, "done-parent", [
      event("done-parent", "child-done", 0, "2026-07-10T00:00:01Z", "started", "running", "sub-done"),
      event("done-parent", "child-done", 1, "2026-07-10T00:00:02Z", "finished", "completed", "sub-done")
    ])

    assert {:ok, %{"rows" => rows}} =
             PixirMonitor.Projection.Source.Filesystem.list_runs(workspace: workspace)

    rows_by_id = Map.new(rows, &{&1["id"], &1})

    nonterminal = rows_by_id["running-parent"]
    assert nonterminal["execution"]["terminal"] == false

    assert nonterminal["liveness"] == %{
             "state" => "unobserved",
             "reachable" => false,
             "basis" => "parent_log_only"
           }

    terminal = rows_by_id["done-parent"]
    assert terminal["execution"]["terminal"] == true

    assert terminal["liveness"] == %{
             "state" => "not_applicable",
             "reachable" => false,
             "basis" => "parent_log_only"
           }

    # The list never claims live activity and never emits the old "unknown"
    # state that fed the unreachable Active classification.
    for row <- rows do
      refute row["liveness"]["state"] in ["live", "unknown"]
      # Mirrors app.js groupFor: Active requires nonterminal + live + basis.
      active? =
        row["execution"]["terminal"] == false and row["liveness"]["state"] == "live" and
          is_binary(row["liveness"]["basis"])

      refute active?
    end
  end

  test "latest_at follows chronological order across mixed UTC offsets" do
    workspace =
      Path.join(
        System.tmp_dir!(),
        "pixir-monitor-source-mixed-offsets-#{System.unique_integer([:positive, :monotonic])}"
      )

    sessions = Path.join([workspace, ".pixir", "sessions"])
    File.mkdir_p!(sessions)
    on_exit(fn -> File.rm_rf!(workspace) end)

    write_log(sessions, "parent-offsets", [
      event("parent-offsets", "child-a", 0, "2026-07-10T04:00:00+02:00", "started", "running", "sub-a"),
      event("parent-offsets", "child-a", 1, "2026-07-10T03:00:00Z", "finished", "completed", "sub-a")
    ])

    assert {:ok, %{"rows" => [row]}} =
             PixirMonitor.Projection.Source.Filesystem.list_runs(workspace: workspace)

    assert row["latest_at"] == "2026-07-10T03:00:00Z"
    assert get_in(row, ["temporal", "latest_at", "value"]) == "2026-07-10T03:00:00Z"
  end

  test "parent advisory keeps list and lazy detail attention in parity" do
    workspace =
      Path.join(
        System.tmp_dir!(),
        "pixir-monitor-source-advisory-parity-#{System.unique_integer([:positive, :monotonic])}"
      )

    sessions = Path.join([workspace, ".pixir", "sessions"])
    File.mkdir_p!(sessions)
    on_exit(fn -> File.rm_rf!(workspace) end)

    summary =
      Jason.encode!(%{
        "status" => "implemented",
        "checkpoint_status" => "checkpoint_ready",
        "summary" => "The bounded worker completed its assigned slice."
      })

    finished =
      event("parent-advisory", "child-advisory", 1, "2026-07-10T00:00:01Z", "finished", "completed", "sub-advisory")
      |> put_in(["data", "summary"], summary)

    write_log(sessions, "parent-advisory", [
      event("parent-advisory", "child-advisory", 0, "2026-07-10T00:00:00Z", "started", "running", "sub-advisory"),
      finished
    ])

    assert {:ok, %{"rows" => [row]}} =
             PixirMonitor.Projection.Source.Filesystem.list_runs(workspace: workspace)

    assert row["counts"]["attention_units"] == 1
    assert row["advisory_counts"] == %{"unknown" => 1}

    write_log(sessions, "child-advisory", [])

    assert {:ok, input} =
             PixirMonitor.Projection.Source.Filesystem.fetch_input("parent-advisory", workspace: workspace)

    assert {:ok, detail} = PixirMonitor.Projection.project(input)
    assert detail["counts"]["attention_units"] == row["counts"]["attention_units"]

    assert [%{"attention" => %{"reasons" => ["advisory_gate_disagreement"]}}] =
             detail["units"]
  end

  test "resume keeps the earlier advisory and its evidence aligned across list and detail" do
    workspace =
      Path.join(
        System.tmp_dir!(),
        "pixir-monitor-source-advisory-resume-#{System.unique_integer([:positive, :monotonic])}"
      )

    sessions = Path.join([workspace, ".pixir", "sessions"])
    File.mkdir_p!(sessions)
    on_exit(fn -> File.rm_rf!(workspace) end)

    summary =
      Jason.encode!(%{
        "checkpoint_status" => "checkpoint_ready",
        "summary" => "The first completed attempt supplied the advisory."
      })

    first_finished =
      event("parent-advisory-resume", "child-advisory-a", 1, "2026-07-10T00:00:01Z", "finished", "completed", "sub-advisory")
      |> put_in(["data", "summary"], summary)

    write_log(sessions, "parent-advisory-resume", [
      event("parent-advisory-resume", "child-advisory-a", 0, "2026-07-10T00:00:00Z", "started", "running", "sub-advisory"),
      first_finished,
      event("parent-advisory-resume", "child-advisory-b", 2, "2026-07-10T00:00:02Z", "input", "running", "sub-advisory"),
      event("parent-advisory-resume", "child-advisory-b", 3, "2026-07-10T00:00:03Z", "finished", "completed", "sub-advisory")
      |> put_in(["data", "summary"], "")
    ])

    assert {:ok, %{"rows" => [row]}} =
             PixirMonitor.Projection.Source.Filesystem.list_runs(workspace: workspace)

    assert row["counts"]["attention_units"] == 1
    assert row["advisory_counts"] == %{"unknown" => 1}

    write_log(sessions, "child-advisory-a", [])
    write_log(sessions, "child-advisory-b", [])

    assert {:ok, input} =
             PixirMonitor.Projection.Source.Filesystem.fetch_input("parent-advisory-resume", workspace: workspace)

    assert {:ok, detail} = PixirMonitor.Projection.project(input)
    assert detail["counts"]["attention_units"] == row["counts"]["attention_units"]

    advisory_evidence =
      Enum.find(detail["evidence"], &(&1["source_kind"] == "model_summary"))

    assert advisory_evidence["session_id"] == "parent-advisory-resume"
    assert advisory_evidence["seq"] == 1
  end

  test "invalid advisory evidence stays attributed to its earlier resumed attempt" do
    workspace =
      Path.join(
        System.tmp_dir!(),
        "pixir-monitor-source-invalid-advisory-resume-#{System.unique_integer([:positive, :monotonic])}"
      )

    sessions = Path.join([workspace, ".pixir", "sessions"])
    File.mkdir_p!(sessions)
    on_exit(fn -> File.rm_rf!(workspace) end)

    first_finished =
      event("parent-invalid-resume", "child-invalid-a", 1, "2026-07-10T00:00:01Z", "finished", "completed", "sub-invalid")
      |> put_in(["data", "summary"], "{truncated")

    write_log(sessions, "parent-invalid-resume", [
      event("parent-invalid-resume", "child-invalid-a", 0, "2026-07-10T00:00:00Z", "started", "running", "sub-invalid"),
      first_finished,
      event("parent-invalid-resume", "child-invalid-b", 2, "2026-07-10T00:00:02Z", "input", "running", "sub-invalid"),
      event("parent-invalid-resume", "child-invalid-b", 3, "2026-07-10T00:00:03Z", "finished", "completed", "sub-invalid")
    ])

    assert {:ok, %{"rows" => [list_row]}} =
             PixirMonitor.Projection.Source.Filesystem.list_runs(workspace: workspace)

    assert list_row["advisory_counts"] == %{"invalid" => 1}

    assert list_row["attention"] == %{
             "basis" => "parent_log_only",
             "reasons" => ["advisory_unparseable"]
           }

    write_log(sessions, "child-invalid-a", [])
    write_log(sessions, "child-invalid-b", [])

    assert {:ok, input} =
             PixirMonitor.Projection.Source.Filesystem.fetch_input("parent-invalid-resume", workspace: workspace)

    assert {:ok, detail} = PixirMonitor.Projection.project(input)

    invalid_evidence =
      Enum.find(detail["evidence"], &(&1["source_kind"] == "model_summary"))

    assert invalid_evidence["session_id"] == "child-invalid-a"
    assert invalid_evidence["seq"] == 1
  end

  test "list rows expose parent-observed child Session ids without folding child Logs" do
    workspace =
      Path.join(
        System.tmp_dir!(),
        "pixir-monitor-source-children-#{System.unique_integer([:positive, :monotonic])}"
      )

    sessions = Path.join([workspace, ".pixir", "sessions"])
    File.mkdir_p!(sessions)
    on_exit(fn -> File.rm_rf!(workspace) end)

    write_log(sessions, "parent-children", [
      event("parent-children", "child-search-a", 0, "2026-07-13T00:00:00Z", "started", "running", "sub-search"),
      event("parent-children", "child-search-a", 1, "2026-07-13T00:00:01Z", "failed", "failed", "sub-search"),
      event("parent-children", "child-search-b", 2, "2026-07-13T00:00:02Z", "input", "running", "sub-search"),
      event("parent-children", "child-search-b", 3, "2026-07-13T00:00:03Z", "finished", "completed", "sub-search")
    ])

    # No child Logs exist in the workspace: the mapping is parent-observed only.
    assert {:ok, %{"rows" => [row]}} =
             PixirMonitor.Projection.Source.Filesystem.list_runs(workspace: workspace)

    assert row["children"] == [
             %{"session_id" => "child-search-a", "unit_id" => "sub-search"},
             %{"session_id" => "child-search-b", "unit_id" => "sub-search"}
           ]
  end

  test "selects newest bounded inventory and reports truncation instead of failing" do
    workspace =
      Path.join(
        System.tmp_dir!(),
        "pixir-monitor-source-bound-#{System.unique_integer([:positive, :monotonic])}"
      )

    sessions = Path.join([workspace, ".pixir", "sessions"])
    File.mkdir_p!(sessions)
    on_exit(fn -> File.rm_rf!(workspace) end)

    for {id, day} <- [{"old", 1}, {"new-a", 2}, {"new-b", 2}] do
      path = write_log(sessions, id, [event(id, "child-#{id}", 0, "2026-07-0#{day}T00:00:00Z", "started", "running", "sub-#{id}")])
      File.touch!(path, {{2026, 7, day}, {0, 0, 0}})
    end

    assert {:ok, %{"rows" => rows, "metadata" => metadata}} =
             PixirMonitor.Projection.Source.Filesystem.list_runs(workspace: workspace, max_logs: 2)

    assert Enum.map(rows, & &1["id"]) == ["new-a", "new-b"]
    assert metadata["total"] == 3
    assert metadata["selected"] == 2
    assert metadata["truncated"] == true
    assert [%{"kind" => "run_inventory_truncated", "details" => details}] = metadata["limitations"]
    assert details == %{"max_logs" => 2, "total" => 3, "selected" => 2}
  end

  test "list projection keeps a running sibling visible after another sibling finishes" do
    workspace =
      Path.join(
        System.tmp_dir!(),
        "pixir-monitor-source-parallel-#{System.unique_integer([:positive, :monotonic])}"
      )

    sessions = Path.join([workspace, ".pixir", "sessions"])
    File.mkdir_p!(sessions)
    on_exit(fn -> File.rm_rf!(workspace) end)

    write_log(sessions, "parallel", [
      event("parallel", "child-a", 0, "2026-07-10T00:00:00Z", "started", "running", "sub-a"),
      event("parallel", "child-b", 1, "2026-07-10T00:00:01Z", "started", "running", "sub-b"),
      event("parallel", "child-a", 2, "2026-07-10T00:00:02Z", "finished", "completed", "sub-a")
    ])

    assert {:ok, %{"rows" => [row]}} =
             PixirMonitor.Projection.Source.Filesystem.list_runs(workspace: workspace)

    assert row["execution"] == %{"state" => "running", "terminal" => false}
    assert row["counts"]["planned_units"] == 2
    assert row["counts"]["completed_units"] == 1
  end

  test "parent-only attention exposes execution and gate reasons as an observed lower bound" do
    workspace =
      Path.join(
        System.tmp_dir!(),
        "pixir-monitor-source-parent-attention-#{System.unique_integer([:positive, :monotonic])}"
      )

    sessions = Path.join([workspace, ".pixir", "sessions"])
    File.mkdir_p!(sessions)
    on_exit(fn -> File.rm_rf!(workspace) end)

    failed_started =
      event("parent-attention", "child-failed", 1, "2026-07-10T00:00:01Z", "started", "running", "sub-failed")
      |> put_in(["data", "delegation_context"], %{"step_id" => "failed-step"})

    failed =
      event("parent-attention", "child-failed", 2, "2026-07-10T00:00:02Z", "failed", "failed", "sub-failed")
      |> put_in(["data", "delegation_context"], %{"step_id" => "failed-step"})

    completed_started =
      event("parent-attention", "child-completed", 5, "2026-07-10T00:00:05Z", "started", "running", "sub-completed")
      |> put_in(["data", "delegation_context"], %{"step_id" => "completed-step"})

    completed =
      event("parent-attention", "child-completed", 6, "2026-07-10T00:00:06Z", "finished", "completed", "sub-completed")
      |> put_in(["data", "delegation_context"], %{"step_id" => "completed-step"})

    write_log(sessions, "parent-attention", [
      workflow_event("parent-attention", 0, "2026-07-10T00:00:00Z", "workflow_started", %{
        "workflow_id" => "wf-parent-attention",
        "workflow_name" => "Parent attention",
        "graph" => %{
          "steps" => [
            %{"id" => "failed-step"},
            %{"id" => "held-step"},
            %{"id" => "completed-step"},
            %{"id" => "gate-failed-step"},
            %{"id" => "orchestrator-step"}
          ]
        }
      }),
      failed_started,
      failed,
      workflow_event("parent-attention", 3, "2026-07-10T00:00:03Z", "checkpoint_decided", %{
        "step_id" => "failed-step",
        "checkpoint_status" => "partial"
      }),
      workflow_event("parent-attention", 4, "2026-07-10T00:00:04Z", "step_held", %{
        "step_id" => "held-step"
      }),
      completed_started,
      completed,
      workflow_event("parent-attention", 7, "2026-07-10T00:00:07Z", "checkpoint_decided", %{
        "step_id" => "gate-failed-step",
        "checkpoint_status" => "failed"
      }),
      workflow_event("parent-attention", 8, "2026-07-10T00:00:08Z", "checkpoint_decided", %{
        "step_id" => "orchestrator-step",
        "checkpoint_status" => "needs_orchestrator"
      })
    ])

    assert {:ok, %{"rows" => [row]}} =
             PixirMonitor.Projection.Source.Filesystem.list_runs(workspace: workspace)

    assert row["counts"] == %{
             "planned_units" => 5,
             "completed_units" => 1,
             "attention_units" => 5
           }

    assert row["attention"] == %{
             "basis" => "parent_log_only",
             "reasons" => [
               "execution_failed",
               "execution_held",
               "execution_unknown",
               "gate_failed",
               "gate_held",
               "gate_needs_orchestrator",
               "gate_partial",
               "gate_unknown"
             ]
           }

    assert row["gate_counts"] == %{
             "failed" => 1,
             "held" => 1,
             "needs_orchestrator" => 1,
             "partial" => 1,
             "unknown" => 1
           }

    assert {:ok, input} =
             PixirMonitor.Projection.Source.Filesystem.fetch_input("parent-attention", workspace: workspace)

    assert {:ok, detail} = PixirMonitor.Projection.project(input)
    units = Map.new(detail["units"], &{List.last(String.split(&1["logical_id"], ":")), &1})

    assert "execution_held" in units["held-step"]["attention"]["reasons"]
    assert "execution_failed" in units["gate-failed-step"]["attention"]["reasons"]
  end

  test "partial workflow joins fail closed instead of double-counting an unbound alias" do
    workspace =
      Path.join(
        System.tmp_dir!(),
        "pixir-monitor-source-partial-join-#{System.unique_integer([:positive, :monotonic])}"
      )

    sessions = Path.join([workspace, ".pixir", "sessions"])
    File.mkdir_p!(sessions)
    on_exit(fn -> File.rm_rf!(workspace) end)

    write_log(sessions, "partial-join", [
      workflow_event("partial-join", 0, "2026-07-10T00:00:00Z", "workflow_started", %{
        "workflow_id" => "wf-partial-join",
        "workflow_name" => "Partial join",
        "graph" => %{"steps" => [%{"id" => "step-a"}]}
      }),
      event("partial-join", "child-unbound", 1, "2026-07-10T00:00:01Z", "started", "running", "sub-unbound"),
      event("partial-join", "child-unbound", 2, "2026-07-10T00:00:02Z", "finished", "completed", "sub-unbound"),
      workflow_event("partial-join", 3, "2026-07-10T00:00:03Z", "checkpoint_decided", %{
        "step_id" => "step-a",
        "checkpoint_status" => "partial"
      })
    ])

    assert {:ok, %{"rows" => [], "metadata" => metadata}} =
             PixirMonitor.Projection.Source.Filesystem.list_runs(workspace: workspace)

    assert metadata["dropped_logs"] == 1

    assert [%{"kind" => "run_projection_incomplete", "details" => details}] =
             metadata["limitations"]

    assert details["error_kinds"] == %{"run_execution_identity_unresolved" => 1}
  end

  test "parent-only fan-out attention exposes every terminal execution reason" do
    workspace =
      Path.join(
        System.tmp_dir!(),
        "pixir-monitor-source-parent-execution-#{System.unique_integer([:positive, :monotonic])}"
      )

    sessions = Path.join([workspace, ".pixir", "sessions"])
    File.mkdir_p!(sessions)
    on_exit(fn -> File.rm_rf!(workspace) end)

    events =
      ~w(failed timed_out cancelled detached)
      |> Enum.with_index()
      |> Enum.flat_map(fn {status, index} ->
        seq = index * 2

        [
          event("parent-execution", "child-#{status}", seq, "2026-07-10T00:00:0#{seq}Z", "started", "running", "sub-#{status}"),
          event("parent-execution", "child-#{status}", seq + 1, "2026-07-10T00:00:0#{seq + 1}Z", status, status, "sub-#{status}")
        ]
      end)

    write_log(sessions, "parent-execution", events)

    assert {:ok, %{"rows" => [row]}} =
             PixirMonitor.Projection.Source.Filesystem.list_runs(workspace: workspace)

    assert row["counts"]["attention_units"] == 4

    assert row["attention"] == %{
             "basis" => "parent_log_only",
             "reasons" => [
               "execution_cancelled",
               "execution_detached",
               "execution_failed",
               "execution_timed_out"
             ]
           }

    for status <- ~w(failed timed_out cancelled detached) do
      write_log(sessions, "child-#{status}", [])
    end

    assert {:ok, input} =
             PixirMonitor.Projection.Source.Filesystem.fetch_input("parent-execution", workspace: workspace)

    assert {:ok, detail} = PixirMonitor.Projection.project(input)
    assert detail["counts"]["attention_units"] == row["counts"]["attention_units"]
  end

  test "inventory confesses selected Logs that cannot be projected" do
    workspace =
      Path.join(
        System.tmp_dir!(),
        "pixir-monitor-source-projection-drop-#{System.unique_integer([:positive, :monotonic])}"
      )

    sessions = Path.join([workspace, ".pixir", "sessions"])
    File.mkdir_p!(sessions)
    on_exit(fn -> File.rm_rf!(workspace) end)

    write_log(sessions, "healthy-parent", [
      event("healthy-parent", "child-healthy", 0, "2026-07-10T00:00:00Z", "queued", "queued", "sub-healthy")
    ])

    write_log(sessions, "over-limit-parent", [
      event("over-limit-parent", "child-over", 0, "2026-07-10T00:00:00Z", "started", "running", "sub-over"),
      event("over-limit-parent", "child-over", 1, "2026-07-10T00:00:01Z", "finished", "completed", "sub-over")
    ])

    assert {:ok, %{"rows" => [%{"id" => "healthy-parent"}], "metadata" => metadata}} =
             PixirMonitor.Projection.Source.Filesystem.list_runs(
               workspace: workspace,
               max_events: 1
             )

    assert metadata["selected"] == 2
    assert metadata["projected_runs"] == 1
    assert metadata["dropped_logs"] == 1

    assert [%{"kind" => "run_projection_incomplete", "details" => details}] =
             metadata["limitations"]

    assert details["error_kinds"] == %{"run_event_limit" => 1}
  end

  test "multiple subagents bound to one step contribute only the latest advisory" do
    workspace =
      Path.join(
        System.tmp_dir!(),
        "pixir-monitor-source-advisory-multibind-#{System.unique_integer([:positive, :monotonic])}"
      )

    sessions = Path.join([workspace, ".pixir", "sessions"])
    File.mkdir_p!(sessions)
    on_exit(fn -> File.rm_rf!(workspace) end)

    stop = Jason.encode!(%{"mergeable" => false, "checkpoint_status" => "checkpoint_ready", "summary" => "Stop"})
    pass = Jason.encode!(%{"mergeable" => true, "checkpoint_status" => "checkpoint_ready", "summary" => "Pass"})

    started_a =
      event("advisory-multibind", "child-a", 1, "2026-07-10T00:00:01Z", "started", "running", "sub-a")
      |> put_in(["data", "delegation_context"], %{"step_id" => "review"})

    finished_a =
      event("advisory-multibind", "child-a", 2, "2026-07-10T00:00:02Z", "finished", "completed", "sub-a")
      |> put_in(["data", "delegation_context"], %{"step_id" => "review"})
      |> put_in(["data", "summary"], stop)

    started_b =
      event("advisory-multibind", "child-b", 3, "2026-07-10T00:00:03Z", "started", "running", "sub-b")
      |> put_in(["data", "delegation_context"], %{"step_id" => "review"})

    finished_b =
      event("advisory-multibind", "child-b", 4, "2026-07-10T00:00:04Z", "finished", "completed", "sub-b")
      |> put_in(["data", "delegation_context"], %{"step_id" => "review"})
      |> put_in(["data", "summary"], pass)

    write_log(sessions, "advisory-multibind", [
      workflow_event("advisory-multibind", 0, "2026-07-10T00:00:00Z", "workflow_started", %{
        "workflow_id" => "wf-advisory-multibind",
        "workflow_name" => "Advisory multibind",
        "graph" => %{"steps" => [%{"id" => "review"}]}
      }),
      started_a,
      finished_a,
      started_b,
      finished_b,
      workflow_event("advisory-multibind", 5, "2026-07-10T00:00:05Z", "checkpoint_decided", %{
        "step_id" => "review",
        "checkpoint_status" => "checkpoint_ready"
      })
    ])

    assert {:ok, %{"rows" => [row]}} =
             PixirMonitor.Projection.Source.Filesystem.list_runs(workspace: workspace)

    assert row["advisory_counts"] == %{"pass" => 1}
    assert row["counts"]["completed_units"] == 1
    assert row["counts"]["attention_units"] == 0

    write_log(sessions, "child-a", [])
    write_log(sessions, "child-b", [])

    assert {:ok, input} =
             PixirMonitor.Projection.Source.Filesystem.fetch_input("advisory-multibind", workspace: workspace)

    assert {:ok, detail} = PixirMonitor.Projection.project(input)
    assert [%{"advisory" => %{"verdict" => "pass"}}] = detail["units"]
  end

  test "later blank summaries cannot erase an earlier unit advisory" do
    workspace =
      Path.join(
        System.tmp_dir!(),
        "pixir-monitor-source-advisory-empty-later-#{System.unique_integer([:positive, :monotonic])}"
      )

    sessions = Path.join([workspace, ".pixir", "sessions"])
    File.mkdir_p!(sessions)
    on_exit(fn -> File.rm_rf!(workspace) end)

    stop = Jason.encode!(%{"mergeable" => false, "checkpoint_status" => "checkpoint_ready", "summary" => "Stop"})

    events = [
      workflow_event("advisory-empty-later", 0, "2026-07-10T00:00:00Z", "workflow_started", %{
        "workflow_id" => "wf-advisory-empty-later",
        "workflow_name" => "Advisory empty later",
        "graph" => %{"steps" => [%{"id" => "review"}]}
      }),
      event("advisory-empty-later", "child-a", 1, "2026-07-10T00:00:01Z", "started", "running", "sub-a")
      |> put_in(["data", "delegation_context"], %{"step_id" => "review"}),
      event("advisory-empty-later", "child-a", 2, "2026-07-10T00:00:02Z", "finished", "completed", "sub-a")
      |> put_in(["data", "delegation_context"], %{"step_id" => "review"})
      |> put_in(["data", "summary"], stop),
      event("advisory-empty-later", "child-b", 3, "2026-07-10T00:00:03Z", "started", "running", "sub-b")
      |> put_in(["data", "delegation_context"], %{"step_id" => "review"}),
      event("advisory-empty-later", "child-b", 4, "2026-07-10T00:00:04Z", "finished", "completed", "sub-b")
      |> put_in(["data", "delegation_context"], %{"step_id" => "review"})
      |> put_in(["data", "summary"], ""),
      event("advisory-empty-later", "child-c", 5, "2026-07-10T00:00:05Z", "started", "running", "sub-c")
      |> put_in(["data", "delegation_context"], %{"step_id" => "review"}),
      event("advisory-empty-later", "child-c", 6, "2026-07-10T00:00:06Z", "finished", "completed", "sub-c")
      |> put_in(["data", "delegation_context"], %{"step_id" => "review"})
      |> put_in(["data", "summary"], "   "),
      workflow_event("advisory-empty-later", 7, "2026-07-10T00:00:07Z", "checkpoint_decided", %{
        "step_id" => "review",
        "checkpoint_status" => "checkpoint_ready"
      })
    ]

    write_log(sessions, "advisory-empty-later", events)

    assert {:ok, %{"rows" => [row]}} =
             PixirMonitor.Projection.Source.Filesystem.list_runs(workspace: workspace)

    assert row["advisory_counts"] == %{"stop" => 1}
    assert row["counts"]["attention_units"] == 1

    write_log(sessions, "child-a", [])
    write_log(sessions, "child-b", [])
    write_log(sessions, "child-c", [])

    assert {:ok, input} =
             PixirMonitor.Projection.Source.Filesystem.fetch_input("advisory-empty-later", workspace: workspace)

    assert {:ok, detail} = PixirMonitor.Projection.project(input)
    assert detail["counts"]["attention_units"] == row["counts"]["attention_units"]
    assert [%{"advisory" => %{"verdict" => "stop"}}] = detail["units"]
  end

  test "recovered latest unit execution does not retain earlier failed attention" do
    workspace =
      Path.join(
        System.tmp_dir!(),
        "pixir-monitor-source-execution-multibind-#{System.unique_integer([:positive, :monotonic])}"
      )

    sessions = Path.join([workspace, ".pixir", "sessions"])
    File.mkdir_p!(sessions)
    on_exit(fn -> File.rm_rf!(workspace) end)

    events = [
      workflow_event("execution-multibind", 0, "2026-07-10T00:00:00Z", "workflow_started", %{
        "workflow_id" => "wf-execution-multibind",
        "workflow_name" => "Execution multibind",
        "graph" => %{"steps" => [%{"id" => "work"}]}
      }),
      event("execution-multibind", "child-a", 1, "2026-07-10T00:00:01Z", "started", "running", "sub-a")
      |> put_in(["data", "delegation_context"], %{"step_id" => "work"}),
      event("execution-multibind", "child-a", 2, "2026-07-10T00:00:02Z", "failed", "failed", "sub-a")
      |> put_in(["data", "delegation_context"], %{"step_id" => "work"}),
      event("execution-multibind", "child-b", 3, "2026-07-10T00:00:03Z", "started", "running", "sub-b")
      |> put_in(["data", "delegation_context"], %{"step_id" => "work"}),
      event("execution-multibind", "child-b", 4, "2026-07-10T00:00:04Z", "finished", "completed", "sub-b")
      |> put_in(["data", "delegation_context"], %{"step_id" => "work"}),
      workflow_event("execution-multibind", 5, "2026-07-10T00:00:05Z", "checkpoint_decided", %{
        "step_id" => "work",
        "checkpoint_status" => "checkpoint_ready"
      })
    ]

    write_log(sessions, "execution-multibind", events)

    assert {:ok, %{"rows" => [row]}} =
             PixirMonitor.Projection.Source.Filesystem.list_runs(workspace: workspace)

    assert row["counts"]["completed_units"] == 1
    assert row["counts"]["attention_units"] == 0
    assert row["attention"]["reasons"] == []

    write_log(sessions, "child-a", [])
    write_log(sessions, "child-b", [])

    assert {:ok, input} =
             PixirMonitor.Projection.Source.Filesystem.fetch_input("execution-multibind", workspace: workspace)

    assert {:ok, detail} = PixirMonitor.Projection.project(input)
    assert detail["counts"]["completed_units"] == row["counts"]["completed_units"]
    assert detail["counts"]["attention_units"] == row["counts"]["attention_units"]
  end

  test "checkpoint-ready engine-only step counts completed in list and detail" do
    workspace =
      Path.join(
        System.tmp_dir!(),
        "pixir-monitor-source-gate-completed-#{System.unique_integer([:positive, :monotonic])}"
      )

    sessions = Path.join([workspace, ".pixir", "sessions"])
    File.mkdir_p!(sessions)
    on_exit(fn -> File.rm_rf!(workspace) end)

    write_log(sessions, "gate-completed", [
      workflow_event("gate-completed", 0, "2026-07-10T00:00:00Z", "workflow_started", %{
        "workflow_id" => "wf-gate-completed",
        "workflow_name" => "Gate completed",
        "graph" => %{"steps" => [%{"id" => "engine-step", "execution_kind" => "virtual_diff_apply"}]}
      }),
      workflow_event("gate-completed", 1, "2026-07-10T00:00:01Z", "checkpoint_decided", %{
        "step_id" => "engine-step",
        "checkpoint_status" => "checkpoint_ready"
      })
    ])

    assert {:ok, %{"rows" => [row]}} =
             PixirMonitor.Projection.Source.Filesystem.list_runs(workspace: workspace)

    assert row["counts"]["completed_units"] == 1
    assert row["gate_counts"] == %{"checkpoint_ready" => 1}

    assert {:ok, input} =
             PixirMonitor.Projection.Source.Filesystem.fetch_input("gate-completed", workspace: workspace)

    assert {:ok, detail} = PixirMonitor.Projection.project(input)
    assert detail["counts"]["completed_units"] == row["counts"]["completed_units"]
  end

  test "non-enum and blank gate statuses stay contract-valid across list and detail" do
    workspace =
      Path.join(
        System.tmp_dir!(),
        "pixir-monitor-source-gate-normalization-#{System.unique_integer([:positive, :monotonic])}"
      )

    sessions = Path.join([workspace, ".pixir", "sessions"])
    File.mkdir_p!(sessions)
    on_exit(fn -> File.rm_rf!(workspace) end)

    write_log(sessions, "gate-normalization", [
      workflow_event("gate-normalization", 0, "2026-07-10T00:00:00Z", "workflow_started", %{
        "workflow_id" => "wf-gate-normalization",
        "workflow_name" => "Gate normalization",
        "graph" => %{
          "steps" => [
            %{"id" => "future"},
            %{"id" => "blank"},
            %{"id" => "held"},
            %{"id" => "safe"}
          ]
        }
      }),
      workflow_event("gate-normalization", 1, "2026-07-10T00:00:01Z", "checkpoint_decided", %{
        "step_id" => "future",
        "checkpoint_status" => "ready"
      }),
      workflow_event("gate-normalization", 2, "2026-07-10T00:00:02Z", "checkpoint_decided", %{
        "step_id" => "blank",
        "checkpoint_status" => ""
      }),
      workflow_event("gate-normalization", 3, "2026-07-10T00:00:03Z", "step_held", %{
        "step_id" => "held",
        "checkpoint_status" => "   "
      }),
      workflow_event("gate-normalization", 4, "2026-07-10T00:00:04Z", "checkpoint_decided", %{
        "step_id" => "safe",
        "checkpoint_status" => "checkpoint_ready",
        "dependent_safe" => "yes"
      })
    ])

    assert {:ok, %{"rows" => [row]}} =
             PixirMonitor.Projection.Source.Filesystem.list_runs(workspace: workspace)

    assert row["gate_counts"] == %{"checkpoint_ready" => 1, "held" => 1, "unknown" => 2}
    assert row["counts"]["attention_units"] == 3

    Application.put_env(
      :pixir_monitor,
      :projection_input_provider,
      PixirMonitor.Projection.Source.Filesystem
    )

    Application.put_env(:pixir_monitor, :projection_source, workspace: workspace)

    assert {:ok, detail} =
             PixirMonitor.Projection.Source.fetch_run("gate-normalization")

    assert detail["counts"]["attention_units"] == row["counts"]["attention_units"]
    assert detail["units"] |> Enum.map(&get_in(&1, ["gate", "state"])) |> Enum.frequencies() == row["gate_counts"]

    safe = Enum.find(detail["units"], &String.ends_with?(&1["logical_id"], ":safe"))
    assert safe["gate"]["dependent_safe"] == nil

    assert Enum.any?(
             detail["evidence"],
             &(&1["description"] == "Future checkpoint status is unknown.")
           )
  end

  test "interleaved attempts for one logical step fail closed in list and detail" do
    workspace =
      Path.join(
        System.tmp_dir!(),
        "pixir-monitor-source-unit-overlap-#{System.unique_integer([:positive, :monotonic])}"
      )

    sessions = Path.join([workspace, ".pixir", "sessions"])
    File.mkdir_p!(sessions)
    on_exit(fn -> File.rm_rf!(workspace) end)

    stop =
      Jason.encode!(%{
        "mergeable" => false,
        "checkpoint_status" => "checkpoint_ready",
        "summary" => "Stop"
      })

    started_a =
      event("unit-overlap", "child-a", 1, "2026-07-10T00:00:01Z", "started", "running", "sub-a")
      |> put_in(["data", "delegation_context"], %{"step_id" => "review"})

    started_b =
      event("unit-overlap", "child-b", 2, "2026-07-10T00:00:02Z", "started", "running", "sub-b")
      |> put_in(["data", "delegation_context"], %{"step_id" => "review"})

    finished_a =
      event("unit-overlap", "child-a", 3, "2026-07-10T00:00:03Z", "finished", "completed", "sub-a")
      |> put_in(["data", "delegation_context"], %{"step_id" => "review"})
      |> put_in(["data", "summary"], stop)

    finished_b =
      event("unit-overlap", "child-b", 4, "2026-07-10T00:00:04Z", "finished", "completed", "sub-b")
      |> put_in(["data", "delegation_context"], %{"step_id" => "review"})

    write_log(sessions, "unit-overlap", [
      workflow_event("unit-overlap", 0, "2026-07-10T00:00:00Z", "workflow_started", %{
        "workflow_id" => "wf-unit-overlap",
        "workflow_name" => "Unit overlap",
        "graph" => %{"steps" => [%{"id" => "review"}]}
      }),
      started_a,
      started_b,
      finished_a,
      finished_b,
      workflow_event("unit-overlap", 5, "2026-07-10T00:00:05Z", "checkpoint_decided", %{
        "step_id" => "review",
        "checkpoint_status" => "checkpoint_ready"
      })
    ])

    terminal_started =
      event("terminal-start", "child-terminal", 1, "2026-07-10T00:00:01Z", "started", "completed", "sub-terminal")
      |> put_in(["data", "delegation_context"], %{"step_id" => "review"})

    second_started =
      event("terminal-start", "child-running", 2, "2026-07-10T00:00:02Z", "started", "running", "sub-running")
      |> put_in(["data", "delegation_context"], %{"step_id" => "review"})

    write_log(sessions, "terminal-start", [
      workflow_event("terminal-start", 0, "2026-07-10T00:00:00Z", "workflow_started", %{
        "workflow_id" => "wf-terminal-start",
        "workflow_name" => "Terminal start",
        "graph" => %{"steps" => [%{"id" => "review"}]}
      }),
      terminal_started,
      second_started
    ])

    invalid_start_ids =
      ["Completed", "completed ", "partial", "held", "", false]
      |> Enum.with_index()
      |> Enum.map(fn {status, index} ->
        id = "noncanonical-start-#{index}"

        invalid_started =
          event(id, "child-#{index}", 1, "2026-07-10T00:00:01Z", "started", status, "sub-#{index}")
          |> put_in(["data", "delegation_context"], %{"step_id" => "review"})

        write_log(sessions, id, [
          workflow_event(id, 0, "2026-07-10T00:00:00Z", "workflow_started", %{
            "workflow_id" => "wf-#{id}",
            "workflow_name" => "Noncanonical start",
            "graph" => %{"steps" => [%{"id" => "review"}]}
          }),
          invalid_started
        ])

        id
      end)

    assert {:ok, %{"rows" => [], "metadata" => metadata}} =
             PixirMonitor.Projection.Source.Filesystem.list_runs(workspace: workspace)

    assert metadata["dropped_logs"] == 8

    assert [
             %{
               "details" => %{
                 "error_kinds" => %{
                   "parent_start_status_invalid" => 7,
                   "parent_unit_attempt_overlap" => 1
                 }
               }
             }
           ] =
             metadata["limitations"]

    assert {:error, %{kind: "parent_unit_attempt_overlap"}} =
             PixirMonitor.Projection.Source.Filesystem.fetch_input("unit-overlap", workspace: workspace)

    assert {:error, %{kind: "parent_start_status_invalid"}} =
             PixirMonitor.Projection.Source.Filesystem.fetch_input("terminal-start", workspace: workspace)

    for id <- invalid_start_ids do
      assert {:error, %{kind: "parent_start_status_invalid"}} =
               PixirMonitor.Projection.Source.Filesystem.fetch_input(id, workspace: workspace)
    end
  end

  test "malformed parent evidence fails closed with an inventory limitation" do
    workspace =
      Path.join(
        System.tmp_dir!(),
        "pixir-monitor-source-malformed-parent-#{System.unique_integer([:positive, :monotonic])}"
      )

    sessions = Path.join([workspace, ".pixir", "sessions"])
    File.mkdir_p!(sessions)
    on_exit(fn -> File.rm_rf!(workspace) end)

    write_log(sessions, "terminal-only", [
      event("terminal-only", "child-terminal", 0, "2026-07-10T00:00:00Z", "failed", "failed", "sub-terminal")
    ])

    write_log(sessions, "anonymous-failure", [
      event("anonymous-failure", "child-anonymous", 0, "2026-07-10T00:00:00Z", "started", "running", nil),
      event("anonymous-failure", "child-anonymous", 1, "2026-07-10T00:00:01Z", "failed", "failed", nil)
    ])

    write_log(sessions, "rogue-gate", [
      workflow_event("rogue-gate", 0, "2026-07-10T00:00:00Z", "workflow_started", %{
        "workflow_id" => "wf-rogue-gate",
        "workflow_name" => "Rogue gate",
        "graph" => %{"steps" => [%{"id" => "planned"}]}
      }),
      workflow_event("rogue-gate", 1, "2026-07-10T00:00:01Z", "checkpoint_decided", %{
        "step_id" => "rogue",
        "checkpoint_status" => "failed"
      })
    ])

    write_log(sessions, "fanout-rogue-gate", [
      event(
        "fanout-rogue-gate",
        "child-named",
        0,
        "2026-07-10T00:00:00Z",
        "started",
        "running",
        "named"
      ),
      workflow_event(
        "fanout-rogue-gate",
        1,
        "2026-07-10T00:00:01Z",
        "checkpoint_decided",
        %{"step_id" => "ghost", "checkpoint_status" => "failed"}
      )
    ])

    write_log(sessions, "duplicate-graph", [
      workflow_event("duplicate-graph", 0, "2026-07-10T00:00:00Z", "workflow_started", %{
        "workflow_id" => "wf-duplicate-graph",
        "workflow_name" => "Duplicate graph",
        "graph" => %{"steps" => [%{"id" => "same"}, %{"id" => "same"}]}
      })
    ])

    write_log(sessions, "invalid-step-id", [
      workflow_event("invalid-step-id", 0, "2026-07-10T00:00:00Z", "workflow_started", %{
        "workflow_id" => "wf-invalid-step-id",
        "workflow_name" => "Invalid step id",
        "graph" => %{"steps" => [%{"id" => "real"}, %{}, %{"label" => "ghost"}]}
      })
    ])

    write_log(sessions, "missing-workflow-id", [
      workflow_event("missing-workflow-id", 0, "2026-07-10T00:00:00Z", "workflow_started", %{
        "workflow_name" => "Missing Workflow id",
        "graph" => %{"steps" => [%{"id" => "real"}]}
      })
    ])

    write_log(sessions, "unknown-dependency", [
      workflow_event("unknown-dependency", 0, "2026-07-10T00:00:00Z", "workflow_started", %{
        "workflow_id" => "wf-unknown-dependency",
        "workflow_name" => "Unknown dependency",
        "graph" => %{
          "steps" => [
            %{"id" => "a"},
            %{"id" => "b", "depends_on" => ["missing"]}
          ]
        }
      })
    ])

    write_log(sessions, "cyclic-dependency", [
      workflow_event("cyclic-dependency", 0, "2026-07-10T00:00:00Z", "workflow_started", %{
        "workflow_id" => "wf-cyclic-dependency",
        "workflow_name" => "Cyclic dependency",
        "graph" => %{
          "steps" => [
            %{"id" => "a", "depends_on" => ["b"]},
            %{"id" => "b", "depends_on" => ["a"]}
          ]
        }
      })
    ])

    write_log(sessions, "conflicting-child-binding", [
      workflow_event("conflicting-child-binding", 0, "2026-07-10T00:00:00Z", "workflow_started", %{
        "workflow_id" => "wf-conflicting-child-binding",
        "workflow_name" => "Conflicting child binding",
        "graph" => %{"steps" => [%{"id" => "a"}, %{"id" => "b"}]}
      }),
      workflow_event("conflicting-child-binding", 1, "2026-07-10T00:00:01Z", "checkpoint_decided", %{
        "step_id" => "a",
        "child_session_id" => "child-shared",
        "checkpoint_status" => "checkpoint_ready"
      }),
      event("conflicting-child-binding", "child-shared", 2, "2026-07-10T00:00:02Z", "started", "running", "sub-shared"),
      event("conflicting-child-binding", "child-shared", 3, "2026-07-10T00:00:03Z", "finished", "completed", "sub-shared"),
      workflow_event("conflicting-child-binding", 4, "2026-07-10T00:00:04Z", "checkpoint_decided", %{
        "step_id" => "b",
        "child_session_id" => "child-shared",
        "checkpoint_status" => "failed"
      })
    ])

    write_log(sessions, "anonymous-running", [
      event("anonymous-running", "child-running", 0, "2026-07-10T00:00:00Z", "started", "running", nil)
    ])

    assert {:ok, %{"rows" => [], "metadata" => metadata}} =
             PixirMonitor.Projection.Source.Filesystem.list_runs(workspace: workspace)

    assert metadata["selected"] == 11
    assert metadata["projected_runs"] == 0
    assert metadata["non_parent_logs"] == 0
    assert metadata["dropped_logs"] == 11

    assert [%{"kind" => "run_projection_incomplete", "details" => details}] =
             metadata["limitations"]

    assert details["error_kinds"] == %{
             "parent_terminal_target_unresolved" => 1,
             "run_execution_identity_unresolved" => 2,
             "run_gate_identity_unresolved" => 2,
             "run_graph_identity_invalid" => 5,
             "run_workflow_identity_conflict" => 1
           }

    expected_detail_errors = %{
      "terminal-only" => "parent_terminal_target_unresolved",
      "anonymous-failure" => "run_execution_identity_unresolved",
      "rogue-gate" => "run_gate_identity_unresolved",
      "fanout-rogue-gate" => "run_gate_identity_unresolved",
      "duplicate-graph" => "run_graph_identity_invalid",
      "invalid-step-id" => "run_graph_identity_invalid",
      "missing-workflow-id" => "run_graph_identity_invalid",
      "unknown-dependency" => "run_graph_identity_invalid",
      "cyclic-dependency" => "run_graph_identity_invalid",
      "conflicting-child-binding" => "run_workflow_identity_conflict",
      "anonymous-running" => "run_execution_identity_unresolved"
    }

    for {run_id, expected_kind} <- expected_detail_errors do
      assert {:error, %{kind: ^expected_kind}} =
               PixirMonitor.Projection.Source.Filesystem.fetch_input(run_id, workspace: workspace)
    end
  end

  test "filesystem inventory preserves an empty clean workspace" do
    workspace =
      Path.join(
        System.tmp_dir!(),
        "pixir-monitor-source-empty-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf!(workspace) end)

    assert {:ok,
            %{
              "rows" => [],
              "metadata" => %{
                "total" => 0,
                "selected" => 0,
                "projected_runs" => 0,
                "non_parent_logs" => 0,
                "dropped_logs" => 0,
                "truncated" => false,
                "limitations" => []
              }
            }} = PixirMonitor.Projection.Source.Filesystem.list_runs(workspace: workspace)
  end

  test "filesystem inventory rejects a symlinked .pixir component" do
    root =
      Path.join(
        System.tmp_dir!(),
        "pixir-monitor-source-pixir-link-#{System.unique_integer([:positive, :monotonic])}"
      )

    workspace = Path.join(root, "workspace")
    target = Path.join(root, "target")
    File.mkdir_p!(Path.join(target, "sessions"))
    File.mkdir_p!(workspace)
    File.ln_s!(target, Path.join(workspace, ".pixir"))
    on_exit(fn -> File.rm_rf!(root) end)

    assert {:error,
            %{
              kind: "state_tree_symlink_rejected",
              details: %{component: ".pixir"}
            }} = PixirMonitor.Projection.Source.Filesystem.list_runs(workspace: workspace)
  end

  test "filesystem inventory rejects a symlinked sessions component" do
    root =
      Path.join(
        System.tmp_dir!(),
        "pixir-monitor-source-sessions-link-#{System.unique_integer([:positive, :monotonic])}"
      )

    workspace = Path.join(root, "workspace")
    pixir = Path.join(workspace, ".pixir")
    target = Path.join(root, "target-sessions")
    File.mkdir_p!(pixir)
    File.mkdir_p!(target)
    File.ln_s!(target, Path.join(pixir, "sessions"))
    on_exit(fn -> File.rm_rf!(root) end)

    assert {:error,
            %{
              kind: "state_tree_symlink_rejected",
              details: %{component: "sessions"}
            }} = PixirMonitor.Projection.Source.Filesystem.list_runs(workspace: workspace)

    assert {:error,
            %{
              kind: "state_tree_symlink_rejected",
              details: %{component: "sessions"}
            }} = PixirMonitor.Projection.Source.Filesystem.fetch_input("target-run", workspace: workspace)
  end

  test "uses the canonical Session-id byte bound before invoking a provider" do
    assert {:error, %{kind: "unexpected_id"}} =
             PixirMonitor.Projection.Source.fetch_run(String.duplicate("x", 235))

    for length <- [236, 257] do
      assert {:error, %{kind: "invalid_run_id"}} =
               PixirMonitor.Projection.Source.fetch_run(String.duplicate("x", length))
    end
  end

  test "preserves structured provider limitations" do
    assert {:error, %{kind: "fixture_only"}} = PixirMonitor.Projection.Source.fetch_run("run-1")
  end

  test "nil-Subagent child reuse across Workflow steps fails closed in list and detail" do
    workspace =
      Path.join(
        System.tmp_dir!(),
        "pixir-monitor-source-child-rebind-#{System.unique_integer([:positive, :monotonic])}"
      )

    sessions = Path.join([workspace, ".pixir", "sessions"])
    File.mkdir_p!(sessions)
    on_exit(fn -> File.rm_rf!(workspace) end)

    graph = %{
      "steps" => [
        %{"id" => "a", "depends_on" => []},
        %{"id" => "b", "depends_on" => []}
      ]
    }

    lifecycle = fn seq, step, kind, status ->
      event(
        "child-rebind",
        "child-shared",
        seq,
        "2026-07-10T00:00:0#{seq}Z",
        kind,
        status,
        nil
      )
      |> put_in(["data", "delegation_context"], %{"step_id" => step})
    end

    write_log(sessions, "child-rebind", [
      workflow_event("child-rebind", 0, "2026-07-10T00:00:00Z", "workflow_started", %{
        "workflow_id" => "wf-child-rebind",
        "graph" => graph
      }),
      lifecycle.(1, "a", "started", "running"),
      lifecycle.(2, "a", "finished", "completed"),
      lifecycle.(3, "b", "started", "running"),
      lifecycle.(4, "b", "finished", "completed")
    ])

    assert {:ok, %{"rows" => [], "metadata" => metadata}} =
             PixirMonitor.Projection.Source.Filesystem.list_runs(workspace: workspace)

    assert [
             %{
               "kind" => "run_projection_incomplete",
               "details" => %{
                 "error_kinds" => %{"run_workflow_identity_conflict" => 1}
               }
             }
           ] = metadata["limitations"]

    assert {:error, %{kind: "run_workflow_identity_conflict"}} =
             PixirMonitor.Projection.Source.Filesystem.fetch_input(
               "child-rebind",
               workspace: workspace
             )
  end

  test "delimiter-bearing unit components fail closed in list and detail" do
    workspace =
      Path.join(
        System.tmp_dir!(),
        "pixir-monitor-source-unit-component-#{System.unique_integer([:positive, :monotonic])}"
      )

    sessions = Path.join([workspace, ".pixir", "sessions"])
    File.mkdir_p!(sessions)
    on_exit(fn -> File.rm_rf!(workspace) end)

    write_log(sessions, "colon-step", [
      workflow_event("colon-step", 0, "2026-07-10T00:00:00Z", "workflow_started", %{
        "workflow_id" => "wf-safe",
        "graph" => %{"steps" => [%{"id" => "review:main", "depends_on" => []}]}
      })
    ])

    write_log(sessions, "colon-subagent", [
      event("colon-subagent", "child-one", 0, "2026-07-10T00:00:00Z", "started", "running", "agent:one"),
      event("colon-subagent", "child-one", 1, "2026-07-10T00:00:01Z", "finished", "completed", "agent:one")
    ])

    write_log(sessions, "unsafe-workflow", [
      workflow_event("unsafe-workflow", 0, "2026-07-10T00:00:00Z", "workflow_started", %{
        "workflow_id" => "wf:unsafe",
        "graph" => %{"steps" => [%{"id" => "review", "depends_on" => []}]}
      })
    ])

    write_log(sessions, "run.with.dots", [
      event("run.with.dots", "child-two", 0, "2026-07-10T00:00:00Z", "started", "running", "agent-two"),
      event("run.with.dots", "child-two", 1, "2026-07-10T00:00:01Z", "finished", "completed", "agent-two")
    ])

    assert {:ok, %{"rows" => [dotted_row], "metadata" => metadata}} =
             PixirMonitor.Projection.Source.Filesystem.list_runs(workspace: workspace)

    assert dotted_row["id"] == "run.with.dots"
    assert metadata["dropped_logs"] == 3

    assert [%{"kind" => "run_projection_incomplete", "details" => details}] =
             metadata["limitations"]

    assert details["error_kinds"] == %{
             "run_graph_identity_invalid" => 2,
             "run_unit_identity_invalid" => 1
           }

    assert {:error, %{kind: "run_graph_identity_invalid"}} =
             PixirMonitor.Projection.Source.Filesystem.fetch_input(
               "colon-step",
               workspace: workspace
             )

    assert {:error, %{kind: "run_unit_identity_invalid"}} =
             PixirMonitor.Projection.Source.Filesystem.fetch_input(
               "colon-subagent",
               workspace: workspace
             )

    assert {:error, %{kind: "run_graph_identity_invalid"}} =
             PixirMonitor.Projection.Source.Filesystem.fetch_input(
               "unsafe-workflow",
               workspace: workspace
             )

    assert {:ok, dotted_input} =
             PixirMonitor.Projection.Source.Filesystem.fetch_input(
               "run.with.dots",
               workspace: workspace
             )

    assert {:ok, dotted_projection} = PixirMonitor.Projection.project(dotted_input)
    assert dotted_projection["run"]["id"] == "run.with.dots"
  end

  defp write_log(sessions, session_id, events) do
    body = Enum.map_join(events, "", &(Jason.encode!(&1) <> "\n"))
    path = Path.join(sessions, "#{session_id}.ndjson")
    File.write!(path, body)
    path
  end

  defp event(log_session_id, child_session_id, seq, timestamp, lifecycle, status, subagent_id) do
    data = %{
      "event" => lifecycle,
      "status" => status,
      "child_session_id" => child_session_id
    }

    data = if subagent_id, do: Map.put(data, "subagent_id", subagent_id), else: data

    %{
      "id" => "event-#{log_session_id}-#{seq}",
      "session_id" => log_session_id,
      "seq" => seq,
      "ts" => timestamp,
      "type" => "subagent_event",
      "data" => data
    }
  end

  defp workflow_event(log_session_id, seq, timestamp, kind, data) do
    %{
      "id" => "event-#{log_session_id}-#{seq}",
      "session_id" => log_session_id,
      "seq" => seq,
      "ts" => timestamp,
      "type" => "workflow_event",
      "data" => Map.put(data, "kind", kind)
    }
  end

  defp restore(key, nil), do: Application.delete_env(:pixir_monitor, key)
  defp restore(key, value), do: Application.put_env(:pixir_monitor, key, value)
end
