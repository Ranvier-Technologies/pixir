defmodule PixirMonitor.ProjectionLivenessExternalObservationTest do
  @moduledoc """
  Owner residency versus owner brokenness at detail scope.

  A read-only Monitor observing somebody else's run is not the owner of the
  Delegate. That non-residency is the ordinary condition for external
  observation, not an anomaly. When the polling caller can assert from durable
  Log evidence that the run advanced since its own prior observation, liveness
  must project the informational `externally_owned` state instead of the
  attention-weight `stale_handle`, without ever claiming reachability the
  observer does not have.
  """
  use ExUnit.Case, async: true

  alias PixirMonitor.Projection.Builder
  alias PixirMonitor.Projection.Validator

  describe "externally owned, durable evidence advancing" do
    test "a nonterminal run with a non-resident owner and asserted advancement is not stale_handle" do
      assert {:ok, projection} = Builder.build(input(activity_evidence: advanced()))

      assert projection["liveness"]["state"] == "externally_owned"
      assert projection["liveness"]["reachable"] == false
      assert projection["liveness"]["basis"] == "durable_log_activity"
      assert projection["execution"]["state"] == "running"
      assert :ok = Validator.validate(projection)
    end

    test "the same projection emits no liveness attention reason and inflates no attention count" do
      assert {:ok, projection} = Builder.build(input(activity_evidence: advanced()))

      [unit] = projection["units"]

      assert unit["liveness"]["state"] == "externally_owned"
      refute "nonterminal_stale_handle" in unit["attention"]["reasons"]
      refute "nonterminal_owner_unavailable" in unit["attention"]["reasons"]
      refute "nonterminal_liveness_unknown" in unit["attention"]["reasons"]
      assert unit["attention"]["required"] == false
      assert projection["counts"]["attention_units"] == 0
    end

    test "the same projection does not force stale freshness nor the source_stale limitation" do
      assert {:ok, projection} = Builder.build(input(activity_evidence: advanced()))

      refute projection["source"]["freshness"] == "stale"
      refute "source_stale" in projection["source"]["limitations"]
      refute "source_stale" in projection["limitations"]
    end

    test "execution.state is byte-identical with and without the activity assertion" do
      assert {:ok, without} = Builder.build(input())
      assert {:ok, with_evidence} = Builder.build(input(activity_evidence: advanced()))

      assert with_evidence["execution"] == without["execution"]

      assert Enum.map(with_evidence["units"], & &1["execution"]) ==
               Enum.map(without["units"], & &1["execution"])
    end
  end

  describe "conservative fallbacks" do
    test "a nonterminal run with a non-resident owner and no assertion still projects stale_handle" do
      assert {:ok, projection} = Builder.build(input())

      [unit] = projection["units"]

      assert projection["liveness"]["state"] == "stale_handle"
      assert unit["liveness"]["state"] == "stale_handle"
      assert "nonterminal_stale_handle" in unit["attention"]["reasons"]
      assert unit["attention"]["required"] == true
      assert projection["counts"]["attention_units"] == 1
      assert projection["source"]["freshness"] == "stale"
      assert "source_stale" in projection["source"]["limitations"]
      assert :ok = Validator.validate(projection)
    end

    test "an assertion that explicitly denies advancement still projects stale_handle" do
      assert {:ok, projection} =
               Builder.build(input(activity_evidence: %{"durable_evidence" => "unchanged"}))

      assert projection["liveness"]["state"] == "stale_handle"
      assert projection["source"]["freshness"] == "stale"
      assert "source_stale" in projection["source"]["limitations"]
    end

    test "an explicit runtime lookup failure still projects owner_unavailable" do
      assert {:ok, projection} =
               Builder.build(
                 input(
                   owner_state: %{"state" => "owner_unavailable", "reachable" => false},
                   activity_evidence: advanced()
                 )
               )

      [unit] = projection["units"]

      assert projection["liveness"]["state"] == "owner_unavailable"
      assert "nonterminal_owner_unavailable" in unit["attention"]["reasons"]
      assert projection["source"]["freshness"] == "stale"
      assert "source_stale" in projection["source"]["limitations"]
      assert :ok = Validator.validate(projection)
    end

    test "a reachable resident owner still projects live even when advancement is asserted" do
      assert {:ok, projection} =
               Builder.build(
                 input(
                   owner_state: %{"state" => "live_delegate_owner", "reachable" => true},
                   activity_evidence: advanced()
                 )
               )

      assert projection["liveness"]["state"] == "live"
      assert projection["liveness"]["reachable"] == true
    end

    test "a terminal execution still projects not_applicable regardless of the assertion" do
      assert {:ok, projection} =
               Builder.build(input(terminal: true, activity_evidence: advanced()))

      assert projection["execution"]["terminal"] == true
      assert projection["liveness"]["state"] == "not_applicable"
      assert :ok = Validator.validate(projection)
    end

    test "the ambiguous-close exception keeps stale_handle even when advancement is asserted" do
      fixture =
        "fixtures/inputs/timeout-needs-orchestrator.json"
        |> package_path()
        |> File.read!()
        |> Jason.decode!()
        |> put_in(["inputs", "activity_evidence"], advanced())

      assert {:ok, projection} = Builder.build(fixture)

      assert projection["execution"]["terminal"] == true
      assert "subagent_may_still_be_running" in projection["limitations"]
      assert projection["liveness"]["state"] == "stale_handle"
      assert :ok = Validator.validate(projection)
    end
  end

  describe "builder purity and input admission" do
    test "building the same input map twice yields byte-identical projections" do
      map = input(activity_evidence: advanced())

      assert {:ok, first} = Builder.build(map)
      assert {:ok, second} = Builder.build(map)

      assert Jason.encode!(first) == Jason.encode!(second)
    end

    test "an unrecognized activity_evidence value is treated as not asserted and recorded" do
      assert {:ok, projection} =
               Builder.build(input(activity_evidence: %{"durable_evidence" => "teleported"}))

      assert projection["liveness"]["state"] == "stale_handle"
      assert "activity_evidence_unrecognized" in projection["limitations"]
    end

    test "a malformed activity_evidence shape is treated as not asserted and recorded" do
      assert {:ok, projection} = Builder.build(input(activity_evidence: "advanced"))

      assert projection["liveness"]["state"] == "stale_handle"
      assert "activity_evidence_unrecognized" in projection["limitations"]
    end

    test "an absent activity_evidence key adds no limitation" do
      assert {:ok, projection} = Builder.build(input())

      refute "activity_evidence_unrecognized" in projection["limitations"]
    end
  end

  describe "the polling caller supplies the assertion end to end" do
    @tag :tmp_dir
    test "a second poll that observes a longer parent Log projects externally_owned", %{
      tmp_dir: tmp_dir
    } do
      sessions = Path.join([tmp_dir, ".pixir", "sessions"])
      File.mkdir_p!(sessions)
      run = "poll-external-" <> Integer.to_string(System.unique_integer([:positive]))

      write_log(sessions, run, [
        log_event(run, 0, "2026-07-31T09:00:00Z", "started", "running", "sub-a")
      ])

      assert {:ok, first_input} =
               PixirMonitor.Projection.Source.Filesystem.fetch_input(run, workspace: tmp_dir)

      assert first_input["inputs"]["activity_evidence"]["durable_evidence"] == "unknown"
      assert {:ok, first} = Builder.build(first_input)
      assert first["liveness"]["state"] == "stale_handle"

      write_log(sessions, run, [
        log_event(run, 0, "2026-07-31T09:00:00Z", "started", "running", "sub-a"),
        log_event(run, 1, "2026-07-31T09:00:10Z", "started", "running", "sub-b")
      ])

      assert {:ok, second_input} =
               PixirMonitor.Projection.Source.Filesystem.fetch_input(run, workspace: tmp_dir)

      assert second_input["inputs"]["activity_evidence"]["durable_evidence"] == "advanced"
      assert {:ok, second} = Builder.build(second_input)
      assert second["liveness"]["state"] == "externally_owned"
      assert second["liveness"]["reachable"] == false
      assert second["source"]["freshness"] != "stale"
      assert second["execution"]["state"] == first["execution"]["state"]
    end

    @tag :tmp_dir
    test "a poll observing no new durable evidence stays conservative", %{tmp_dir: tmp_dir} do
      sessions = Path.join([tmp_dir, ".pixir", "sessions"])
      File.mkdir_p!(sessions)
      run = "poll-quiet-" <> Integer.to_string(System.unique_integer([:positive]))

      events = [log_event(run, 0, "2026-07-31T09:00:00Z", "started", "running", "sub-a")]
      write_log(sessions, run, events)

      assert {:ok, _first} =
               PixirMonitor.Projection.Source.Filesystem.fetch_input(run, workspace: tmp_dir)

      assert {:ok, second_input} =
               PixirMonitor.Projection.Source.Filesystem.fetch_input(run, workspace: tmp_dir)

      assert second_input["inputs"]["activity_evidence"]["durable_evidence"] == "unchanged"
      assert {:ok, second} = Builder.build(second_input)
      assert second["liveness"]["state"] == "stale_handle"
      assert second["source"]["freshness"] == "stale"
      assert "source_stale" in second["source"]["limitations"]
    end
  end

  defp write_log(sessions, id, events) do
    body = events |> Enum.map(&(Jason.encode!(&1) <> "\n")) |> Enum.join()
    File.write!(Path.join(sessions, id <> ".ndjson"), body)
  end

  defp log_event(session_id, seq, ts, event, status, subagent) do
    %{
      "seq" => seq,
      "ts" => ts,
      "session_id" => session_id,
      "type" => "subagent_event",
      "data" => %{
        "event" => event,
        "status" => status,
        "subagent_id" => subagent,
        "child_session_id" => "child-" <> subagent,
        "agent" => "explorer"
      }
    }
  end

  defp advanced, do: %{"durable_evidence" => "advanced"}

  defp package_path(relative),
    do: Path.expand("../../priv/presenter/#{relative}", __DIR__)

  defp input(opts \\ []) do
    owner = Keyword.get(opts, :owner_state, %{"state" => "snapshot_only", "reachable" => false})
    terminal? = Keyword.get(opts, :terminal, false)

    parent_log =
      if terminal? do
        [
          subagent_event(0, "started", "running"),
          subagent_event(1, "finished", "completed")
        ]
      else
        [subagent_event(0, "started", "running")]
      end

    inputs = %{
      "terminal_envelope" => nil,
      "delegate_snapshot" => %{
        "kind" => "delegate_status",
        "delegate_id" => "dlg-external",
        "parent_session_id" => "parent-external",
        "strategy" => "subagents",
        "mode" => "read_only",
        "status" => if(terminal?, do: "completed", else: "running"),
        "children" => [
          %{
            "subagent_id" => "sub-external",
            "child_session_id" => "child-external",
            "agent" => "explorer",
            "status" => if(terminal?, do: "completed", else: "running")
          }
        ]
      },
      "parent_log" => parent_log,
      "parent_log_origin" => "fixture",
      "child_logs" => %{"child-external" => []},
      "runtime_diagnostics" => nil,
      "owner_state" => owner,
      "evidence_mirror" => nil
    }

    inputs =
      case Keyword.fetch(opts, :activity_evidence) do
        {:ok, value} -> Map.put(inputs, "activity_evidence", value)
        :error -> inputs
      end

    %{
      "projected_at" => "2026-07-31T00:10:00Z",
      "observed_at" => "2026-07-31T00:10:00Z",
      "inputs" => inputs,
      "completeness" => %{"parent_log" => "complete", "child_logs" => "complete"}
    }
  end

  defp subagent_event(seq, event, status) do
    %{
      "seq" => seq,
      "ts" => "2026-07-31T00:0#{seq}:00Z",
      "type" => "subagent_event",
      "session_id" => "parent-external",
      "data" => %{
        "event" => event,
        "status" => status,
        "subagent_id" => "sub-external",
        "child_session_id" => "child-external",
        "agent" => "explorer"
      }
    }
  end
end
