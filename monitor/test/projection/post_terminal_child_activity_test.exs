defmodule PixirMonitor.Projection.PostTerminalChildActivityTest do
  @moduledoc """
  Phase 1 of #447: the parent run projection reports child-Session activity
  observed AFTER the parent's own terminal boundary, without touching any
  existing truth dimension.

  The dimension reports; it never reclassifies. `execution` stays exactly what
  parent evidence says, `liveness` stays derived from owner diagnostics, and the
  frozen `temporal.latest_at` keeps its `max_parent_event_ts` basis. Missing
  child evidence is reported as undetermined and never as an observed zero.
  """
  use ExUnit.Case, async: false

  alias PixirMonitor.Projection.{Builder, Validator}

  @boundary_basis "workflow_finished_event_ts"
  @observed_basis "child_events_after_parent_terminal_boundary"
  @limitation "post_terminal_child_activity_observed"

  # ---------------------------------------------------------------- detail ---

  describe "detail projection dimension" do
    test "a partial run with child events after the terminal boundary reports them" do
      assert {:ok, projection} = Builder.build(input(child_logs: %{"child-447" => resumed_child_events()}))
      assert :ok = Validator.validate(projection)

      activity = projection["post_terminal_child_activity"]

      assert activity["state"] == "observed"
      assert activity["basis"] == @observed_basis
      assert activity["boundary_basis"] == @boundary_basis
      assert activity["boundary_at"] == "2026-07-30T10:00:03Z"
      assert activity["event_count"] == 3
      assert activity["latest_event_at"] == "2026-07-30T10:41:00Z"
      assert activity["child_session_ids"] == ["child-447"]
      assert activity["evidence_refs"] != []
    end

    test "post-terminal child activity never moves canonical execution" do
      assert {:ok, projection} = Builder.build(input(child_logs: %{"child-447" => resumed_child_events()}))

      assert projection["execution"]["state"] == "partial"
      assert projection["execution"]["terminal"] == true
      assert projection["execution"]["basis"] == "workflow_event_fold"

      assert {:ok, quiet} = Builder.build(input(child_logs: %{"child-447" => []}))
      assert projection["execution"] == quiet["execution"]
    end

    test "post-terminal child activity never makes the run look reachable" do
      assert {:ok, projection} = Builder.build(input(child_logs: %{"child-447" => resumed_child_events()}))

      assert projection["liveness"]["state"] == "not_applicable"
      assert projection["liveness"]["basis"] == "terminal_execution"
      assert projection["liveness"]["reachable"] == false
    end

    test "the dimension is deterministic across wall-clock time" do
      input = input(child_logs: %{"child-447" => resumed_child_events()})

      assert {:ok, first} = Builder.build(input)
      assert {:ok, second} = Builder.build(Map.put(input, "observed_at", "2027-01-01T00:00:00Z"))

      assert first["post_terminal_child_activity"] == second["post_terminal_child_activity"]
    end

    test "a terminal run whose child evidence has no later events reports an observed zero" do
      quiet = [
        child_event(0, "2026-07-30T10:00:01Z", "user_message"),
        child_event(1, "2026-07-30T10:00:02Z", "provider_usage")
      ]

      assert {:ok, projection} = Builder.build(input(child_logs: %{"child-447" => quiet}))
      assert :ok = Validator.validate(projection)

      activity = projection["post_terminal_child_activity"]

      assert activity["state"] == "none"
      assert activity["basis"] == @observed_basis
      assert activity["event_count"] == 0
      assert activity["latest_event_at"] == nil
      assert activity["child_session_ids"] == []
      refute @limitation in projection["limitations"]
    end

    test "an explicitly empty child log is an observed zero, distinguishable from undetermined" do
      assert {:ok, empty} = Builder.build(input(child_logs: %{"child-447" => []}))
      assert {:ok, unavailable} = Builder.build(undetermined_input())

      assert empty["post_terminal_child_activity"]["state"] == "none"
      assert empty["post_terminal_child_activity"]["event_count"] == 0
      assert unavailable["post_terminal_child_activity"]["state"] == "undetermined"

      assert empty["post_terminal_child_activity"] != unavailable["post_terminal_child_activity"]
    end

    test "a verified evidence_mirror child entry yields the same nonzero dimension" do
      events = resumed_child_events()

      assert {:ok, from_logs} = Builder.build(input(child_logs: %{"child-447" => events}))

      mirror = %{
        "status" => "verified_copy",
        "logs" => [
          %{
            "role" => "child",
            "session_id" => "child-447",
            "status" => "verified_copy",
            "reported_source_sha256" => "sha256:same",
            "reported_mirror_sha256" => "sha256:same",
            "events" => events
          }
        ]
      }

      assert {:ok, from_mirror} = Builder.build(input(child_logs: %{}, evidence_mirror: mirror))
      assert :ok = Validator.validate(from_mirror)

      mirrored = from_mirror["post_terminal_child_activity"]

      assert mirrored["state"] == "observed"
      assert mirrored["event_count"] == from_logs["post_terminal_child_activity"]["event_count"]
      assert mirrored["latest_event_at"] == from_logs["post_terminal_child_activity"]["latest_event_at"]
      assert mirrored["child_session_ids"] == ["child-447"]
      assert mirrored["evidence_refs"] == from_logs["post_terminal_child_activity"]["evidence_refs"]
    end

    test "a nonterminal run reports the defined not-applicable form" do
      assert {:ok, projection} = Builder.build(nonterminal_input())
      assert :ok = Validator.validate(projection)

      activity = projection["post_terminal_child_activity"]

      assert activity["state"] == "not_applicable"
      assert activity["basis"] == "nonterminal_execution"
      assert activity["boundary_at"] == nil
      assert activity["boundary_basis"] == nil
      assert activity["event_count"] == nil
      assert activity["latest_event_at"] == nil
      assert activity["child_session_ids"] == []
      refute @limitation in projection["limitations"]
    end

    test "observed post-terminal activity carries a root limitation, and zero does not" do
      assert {:ok, observed} = Builder.build(input(child_logs: %{"child-447" => resumed_child_events()}))
      assert {:ok, quiet} = Builder.build(input(child_logs: %{"child-447" => []}))

      assert @limitation in observed["limitations"]
      refute @limitation in quiet["limitations"]

      # The existing missing-child-log string keeps its own home; it is not moved.
      refute "child_log_missing" in observed["limitations"]
    end

    test "unavailable child evidence is undetermined, never zero, and confesses the missing Log" do
      assert {:ok, projection} = Builder.build(undetermined_input())
      assert :ok = Validator.validate(projection)

      activity = projection["post_terminal_child_activity"]

      assert activity["state"] == "undetermined"
      assert activity["basis"] == "child_evidence_unavailable"
      assert activity["event_count"] == nil
      assert activity["latest_event_at"] == nil
      assert activity["child_session_ids"] == []

      assert "child_log_missing" in projection["source"]["limitations"]
      assert "child_log_missing" in projection["limitations"]
      refute @limitation in projection["limitations"]
    end

    test "a terminal run whose boundary timestamp is unusable is undetermined, never zero" do
      for bad_ts <- ["not-a-timestamp", "2026-07-30 10:00:03Z", 1_753_869_603, nil] do
        assert {:ok, projection} = Builder.build(unusable_boundary_input(bad_ts))
        assert :ok = Validator.validate(projection)

        activity = projection["post_terminal_child_activity"]

        # The child DID work after the parent ended. Without a usable boundary we
        # cannot say when "after" starts, so the honest answer is undetermined --
        # never the false zero this state exists to prevent.
        assert activity["state"] == "undetermined", "boundary #{inspect(bad_ts)} must not resolve"
        assert activity["basis"] == "terminal_boundary_unavailable"
        assert activity["event_count"] == nil
        assert activity["latest_event_at"] == nil
        assert activity["boundary_at"] == nil
        assert activity["boundary_basis"] == nil

        # An unusable boundary must NOT silently fall back to an earlier
        # lifecycle timestamp, which would manufacture a narrower window.
        refute activity["boundary_basis"] == "terminal_subagent_lifecycle_ts"

        # It reports; it does not reclassify.
        assert projection["execution"]["terminal"] == true
        refute @limitation in projection["limitations"]
      end
    end

    test "an unverified mirror child entry cannot assert an absence" do
      unverified = %{
        "status" => "verified_copy",
        "logs" => [
          %{
            "role" => "child",
            "session_id" => "child-447",
            "status" => "verified_copy",
            "reported_source_sha256" => "sha256:a",
            "reported_mirror_sha256" => "sha256:b",
            "events" => resumed_child_events()
          }
        ]
      }

      raw =
        undetermined_input()
        |> put_in(["inputs", "evidence_mirror"], unverified)

      assert {:ok, projection} = Builder.build(raw)
      assert projection["post_terminal_child_activity"]["state"] == "undetermined"
      assert projection["post_terminal_child_activity"]["event_count"] == nil
    end

    test "the dimension is present on every terminal shape rather than omitted" do
      for child_logs <- [%{"child-447" => resumed_child_events()}, %{"child-447" => []}, %{}] do
        assert {:ok, projection} = Builder.build(input(child_logs: child_logs))
        assert Map.has_key?(projection, "post_terminal_child_activity")
      end
    end

    test "the frozen temporal contract is untouched by post-terminal child events" do
      assert {:ok, observed} = Builder.build(input(child_logs: %{"child-447" => resumed_child_events()}))
      assert {:ok, quiet} = Builder.build(input(child_logs: %{"child-447" => []}))

      assert observed["source"]["last_durable_at"] == quiet["source"]["last_durable_at"]
      assert observed["source"]["freshness"] == "terminal"
    end
  end

  # ------------------------------------------------------------------ list ---

  describe "runs list row" do
    setup do
      workspace =
        Path.join(
          System.tmp_dir!(),
          "pixir-monitor-post-terminal-#{System.unique_integer([:positive, :monotonic])}"
        )

      sessions = Path.join([workspace, ".pixir", "sessions"])
      File.mkdir_p!(sessions)
      on_exit(fn -> File.rm_rf!(workspace) end)

      {:ok, workspace: workspace, sessions: sessions}
    end

    test "the row carries the reduced signal without claiming liveness", context do
      write_parent(context.sessions)
      write_child(context.sessions, resumed_child_events())

      assert {:ok, %{"rows" => [row]}} =
               PixirMonitor.Projection.Source.Filesystem.list_runs(workspace: context.workspace)

      activity = row["post_terminal_child_activity"]

      assert activity["state"] == "observed"
      assert activity["event_count"] == 3
      assert activity["latest_event_at"] == "2026-07-30T10:41:00Z"

      assert row["liveness"]["state"] == "not_applicable"
      assert row["liveness"]["basis"] == "parent_log_only"
      assert row["execution"]["state"] == "partial"
    end

    test "the row's frozen latest_at is unchanged by post-terminal child events", context do
      write_parent(context.sessions)

      assert {:ok, %{"rows" => [before_row]}} =
               PixirMonitor.Projection.Source.Filesystem.list_runs(workspace: context.workspace)

      write_child(context.sessions, resumed_child_events())

      assert {:ok, %{"rows" => [after_row]}} =
               PixirMonitor.Projection.Source.Filesystem.list_runs(workspace: context.workspace)

      assert after_row["temporal"]["latest_at"]["basis"] == "max_parent_event_ts"
      assert after_row["temporal"]["latest_at"] == before_row["temporal"]["latest_at"]
      assert after_row["latest_at"] == before_row["latest_at"]

      assert PixirMonitor.Projection.Temporal.recency_desc_key(after_row) ==
               PixirMonitor.Projection.Temporal.recency_desc_key(before_row)
    end

    test "the full list-row key set is pinned so a row-shape regression fails loudly", context do
      write_parent(context.sessions)
      write_child(context.sessions, resumed_child_events())

      assert {:ok, %{"rows" => [row]}} =
               PixirMonitor.Projection.Source.Filesystem.list_runs(workspace: context.workspace)

      assert Enum.sort(Map.keys(row)) ==
               Enum.sort(~w(
                 id title strategy execution liveness source counts attention gate_counts
                 advisory_counts mutation children latest_at temporal
                 post_terminal_child_activity
               ))

      assert Enum.sort(Map.keys(row["post_terminal_child_activity"])) ==
               Enum.sort(~w(state event_count latest_event_at basis))
    end

    test "a terminal row with no child Log reports undetermined rather than zero", context do
      write_parent(context.sessions)

      assert {:ok, %{"rows" => [row]}} =
               PixirMonitor.Projection.Source.Filesystem.list_runs(workspace: context.workspace)

      assert row["post_terminal_child_activity"]["state"] == "undetermined"
      assert row["post_terminal_child_activity"]["event_count"] == nil
      assert row["post_terminal_child_activity"]["latest_event_at"] == nil
    end

    test "the inventory still classifies exactly the parent Log as a run", context do
      write_parent(context.sessions)
      write_child(context.sessions, resumed_child_events())

      assert {:ok, %{"rows" => rows, "metadata" => metadata}} =
               PixirMonitor.Projection.Source.Filesystem.list_runs(workspace: context.workspace)

      assert Enum.map(rows, & &1["id"]) == ["parent-447"]
      assert metadata["projected_runs"] == 1
      assert metadata["non_parent_logs"] == 1
    end

    test "a child Session id resolves to its parent run from the list document alone", context do
      write_parent(context.sessions)
      write_child(context.sessions, resumed_child_events())

      assert {:ok, %{"runs" => runs}} =
               PixirMonitor.Projection.Source.list_runs(workspace: context.workspace)

      owner =
        Enum.find(runs, fn run ->
          Enum.any?(run["children"] || [], &(&1["session_id"] == "child-447"))
        end)

      assert owner["id"] == "parent-447"

      assert Enum.find(owner["children"], &(&1["session_id"] == "child-447"))["unit_id"] ==
               "worker"
    end

    test "the pinned recency_desc order is byte-identical before and after child resume",
         context do
      write_parent(context.sessions)

      write_log(context.sessions, "parent-other", [
        %{
          "id" => "event-parent-other-0",
          "session_id" => "parent-other",
          "seq" => 0,
          "ts" => "2026-07-29T09:00:00Z",
          "type" => "subagent_event",
          "data" => %{
            "event" => "started",
            "status" => "running",
            "subagent_id" => "sub-other",
            "child_session_id" => "child-other"
          }
        }
      ])

      order = fn ->
        {:ok, %{"rows" => rows}} =
          PixirMonitor.Projection.Source.Filesystem.list_runs(workspace: context.workspace)

        rows
        |> Enum.sort_by(&PixirMonitor.Projection.Temporal.recency_desc_key/1)
        |> Enum.map(& &1["id"])
      end

      before_order = order.()
      write_child(context.sessions, resumed_child_events())

      assert order.() == before_order
      assert before_order == ["parent-447", "parent-other"]
    end

    test "SelfCheck still reports the schema identifiers the endpoints emit", context do
      write_parent(context.sessions)
      write_child(context.sessions, resumed_child_events())

      assert {:ok, %{"schema" => "pixir.monitor.runs", "schema_version" => 1}} =
               PixirMonitor.Projection.Source.list_runs(workspace: context.workspace)

      assert {:ok, %{"schema" => "pixir.presenter.run", "schema_version" => 1}} =
               PixirMonitor.Projection.Source.fetch_run("parent-447", workspace: context.workspace)

      self_check = File.read!(Path.expand("../../lib/pixir_monitor/self_check.ex", __DIR__))
      assert self_check =~ ~s|runs_schema: "pixir.monitor.runs"|
      assert self_check =~ "runs_schema_version: 1"
    end

    test "detail projection over the filesystem provider agrees with the row", context do
      write_parent(context.sessions)
      write_child(context.sessions, resumed_child_events())

      assert {:ok, projection} =
               PixirMonitor.Projection.Source.fetch_run("parent-447", workspace: context.workspace)

      assert :ok = Validator.validate(projection)
      assert projection["post_terminal_child_activity"]["state"] == "observed"
      assert projection["post_terminal_child_activity"]["event_count"] == 3
      assert projection["execution"]["state"] == "partial"
      assert projection["liveness"]["state"] == "not_applicable"
    end

    defp write_parent(sessions) do
      write_log(sessions, "parent-447", parent_events("parent-447"))
    end

    defp write_child(sessions, events) do
      wrapped =
        Enum.map(events, fn event ->
          %{
            "id" => "event-child-447-#{event["seq"]}",
            "session_id" => "child-447",
            "seq" => event["seq"],
            "ts" => event["ts"],
            "type" => event["type"],
            "data" => event["data"]
          }
        end)

      write_log(sessions, "child-447", wrapped)
    end

    defp write_log(sessions, session_id, events) do
      body = Enum.map_join(events, "", &(Jason.encode!(&1) <> "\n"))
      File.write!(Path.join(sessions, "#{session_id}.ndjson"), body)
    end
  end

  # --------------------------------------------------------------- helpers ---

  defp input(opts) do
    %{
      "observed_at" => "2026-07-30T11:00:00Z",
      "inputs" => %{
        "terminal_envelope" => %{
          "kind" => "delegate_result",
          "delegate_id" => "parent-447",
          "parent_session_id" => "parent-447",
          "strategy" => "workflow",
          "mode" => "read_only",
          "workflow_id" => "wf-447",
          "status" => "partial"
        },
        "delegate_snapshot" => nil,
        "parent_log" => parent_events("parent-447"),
        "parent_log_origin" => "fixture",
        "child_logs" => Keyword.get(opts, :child_logs, %{}),
        "runtime_diagnostics" => nil,
        "owner_state" => %{"state" => "snapshot_only", "reachable" => false},
        "evidence_mirror" => Keyword.get(opts, :evidence_mirror)
      },
      "completeness" => %{
        "parent_log" => "complete_through_observed_at",
        "child_logs" => Keyword.get(opts, :child_completeness, "complete_through_observed_at")
      }
    }
  end

  defp undetermined_input do
    input(child_logs: %{"child-447" => nil}, child_completeness: "explicitly_missing")
  end

  # Child evidence is fully present and genuinely later; only the parent's
  # `workflow_finished` timestamp is unusable, so the boundary cannot be derived.
  defp unusable_boundary_input(bad_ts) do
    raw = input(child_logs: %{"child-447" => resumed_child_events()})

    corrupted =
      Enum.map(raw["inputs"]["parent_log"], fn event ->
        if get_in(event, ["data", "kind"]) == "workflow_finished",
          do: Map.put(event, "ts", bad_ts),
          else: event
      end)

    put_in(raw, ["inputs", "parent_log"], corrupted)
  end

  # The workflow is still running: the worker started and nothing has closed it,
  # so no terminal boundary exists to be "after".
  defp nonterminal_input do
    raw = input(child_logs: %{"child-447" => resumed_child_events()})

    running =
      Enum.reject(raw["inputs"]["parent_log"], fn event ->
        get_in(event, ["data", "kind"]) == "workflow_finished" or
          get_in(event, ["data", "event"]) == "timed_out"
      end)

    raw
    |> put_in(["inputs", "parent_log"], running)
    |> put_in(["inputs", "terminal_envelope", "status"], "running")
  end

  defp parent_events(_session_id) do
    [
      %{
        "seq" => 0,
        "ts" => "2026-07-30T10:00:00Z",
        "type" => "workflow_event",
        "data" => %{
          "kind" => "workflow_started",
          "workflow_id" => "wf-447",
          "workflow_name" => "Cancelled by timeout",
          "graph" => %{
            "steps" => [
              %{
                "id" => "worker",
                "agent" => "worker",
                "depends_on" => [],
                "execution_kind" => "subagent",
                "workspace_mode" => "shared",
                "posture" => "read_only"
              }
            ]
          }
        }
      },
      %{
        "seq" => 1,
        "ts" => "2026-07-30T10:00:01Z",
        "type" => "subagent_event",
        "data" => %{
          "event" => "started",
          "status" => "running",
          "subagent_id" => "sub-447",
          "child_session_id" => "child-447",
          "agent" => "worker",
          "delegation_context" => %{"step_id" => "worker"}
        }
      },
      %{
        "seq" => 2,
        "ts" => "2026-07-30T10:00:02Z",
        "type" => "subagent_event",
        "data" => %{
          "event" => "timed_out",
          "status" => "timed_out",
          "subagent_id" => "sub-447",
          "child_session_id" => "child-447",
          "agent" => "worker",
          "delegation_context" => %{"step_id" => "worker"}
        }
      },
      %{
        "seq" => 3,
        "ts" => "2026-07-30T10:00:03Z",
        "type" => "workflow_event",
        "data" => %{
          "kind" => "workflow_finished",
          "workflow_id" => "wf-447",
          "status" => "partial",
          "ok" => false
        }
      }
    ]
  end

  # The child was resumed directly at the Session after the workflow was
  # cancelled. The parent's terminal boundary is 2026-07-30T10:00:03Z, so three
  # of these events (10:05:00Z, 10:40:00Z, 10:41:00Z) are strictly after it and
  # two (10:00:01Z, 10:00:02Z) are not.
  defp resumed_child_events do
    [
      child_event(0, "2026-07-30T10:00:01Z", "user_message"),
      child_event(1, "2026-07-30T10:00:02Z", "provider_usage"),
      child_event(2, "2026-07-30T10:05:00Z", "user_message"),
      child_event(3, "2026-07-30T10:40:00Z", "provider_usage"),
      child_event(4, "2026-07-30T10:41:00Z", "assistant_message")
    ]
  end

  defp child_event(seq, timestamp, type) do
    data =
      case type do
        "provider_usage" ->
          %{
            "model" => "gpt-5.6-sol",
            "usage_summary" => %{
              "input_tokens" => 10,
              "output_tokens" => 5,
              "total_tokens" => 15
            }
          }

        _ ->
          %{}
      end

    %{"seq" => seq, "ts" => timestamp, "type" => type, "data" => data}
  end
end
