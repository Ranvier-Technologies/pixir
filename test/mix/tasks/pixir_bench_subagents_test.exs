defmodule Mix.Tasks.Pixir.Bench.SubagentsTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Pixir.Bench.Subagents, as: BenchTask

  setup do
    output_dir =
      Path.join(
        System.tmp_dir!(),
        "pixir-bench-subagents-test-" <>
          Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
      )

    on_exit(fn -> File.rm_rf!(output_dir) end)

    %{output_dir: output_dir}
  end

  test "--json --help is machine-readable and advertises proof states" do
    payload =
      capture_io(fn ->
        assert catch_exit(BenchTask.run(["--json", "--help"])) == :normal
      end)
      |> Jason.decode!()

    assert payload["ok"] == true
    assert payload["command"] == "mix pixir.bench.subagents"
    assert "schema_validated" in payload["proof_states"]
    assert "completion_ready" in payload["proof_states"]
  end

  test "--dry-run --json is no-write and declares planned artifacts", %{output_dir: output_dir} do
    payload =
      capture_io(fn ->
        assert catch_exit(BenchTask.run(["--dry-run", "--json", "--output", output_dir])) ==
                 :normal
      end)
      |> Jason.decode!()

    assert payload["ok"] == true
    assert payload["mode"] == "dry_run"
    assert payload["estimated_real_network_runs"] == 0
    assert Path.join(output_dir, "completion_audit.json") in payload["would_write"]
    refute File.exists?(output_dir)
  end

  test "invalid inputs return structured recoverable errors" do
    payload =
      capture_io(fn ->
        assert catch_exit(BenchTask.run(["--n", "nope", "--json"])) == {:shutdown, 1}
      end)
      |> Jason.decode!()

    assert payload["ok"] == false
    assert payload["error"]["kind"] == "invalid_n_values"
    assert payload["error"]["details"]["invalid"] == ["nope"]

    payload =
      capture_io(fn ->
        assert catch_exit(BenchTask.run(["--repetitions", "0", "--json"])) == {:shutdown, 1}
      end)
      |> Jason.decode!()

    assert payload["ok"] == false
    assert payload["error"]["kind"] == "invalid_repetitions"
  end

  test "run emits reconciled records, summary, report, and completion audit", %{
    output_dir: output_dir
  } do
    payload =
      capture_io(fn ->
        BenchTask.run(["--n", "1,2", "--repetitions", "1", "--json", "--output", output_dir])
      end)
      |> Jason.decode!()

    assert payload["ok"] == true
    assert payload["summary"]["status"] == "passed"
    assert payload["summary"]["schema_validation"]["status"] == "passed"
    assert payload["completion_audit"]["status"] == "completion_ready"

    runs_path = Path.join(output_dir, "runs.jsonl")
    summary_path = Path.join(output_dir, "summary.json")
    report_path = Path.join(output_dir, "report.md")
    audit_path = Path.join(output_dir, "completion_audit.json")

    assert File.exists?(runs_path)
    assert File.exists?(summary_path)
    assert File.exists?(report_path)
    assert File.exists?(audit_path)

    records = read_jsonl!(runs_path)
    summary = summary_path |> File.read!() |> Jason.decode!()
    audit = audit_path |> File.read!() |> Jason.decode!()
    report = File.read!(report_path)

    assert length(records) == 5
    assert summary["records_count"] == length(records)
    assert summary["schema_validation"]["status"] == "passed"
    assert audit["status"] == "completion_ready"
    assert Enum.all?(audit["requirements"], &(&1["status"] == "proved"))
    assert report =~ "## Schema Validation"
    assert report =~ "## Completion Audit"
    assert report =~ summary["run_id"]

    spawn_records = Enum.filter(records, &(&1["scenario"] == "pixir_spawn_wait_n"))
    assert Enum.map(spawn_records, & &1["n"]) |> Enum.sort() == [1, 2]

    for record <- spawn_records do
      assert record["status"] == "passed"
      assert record["network"] == false
      assert record["metrics"]["spawned_count"] == record["n"]
      assert record["metrics"]["completed_count"] == record["n"]
      assert record["metrics"]["active_after_wait_count"] == 0
      assert record["metrics"]["child_log_count"] == record["n"]
      assert record["evidence"]["missing_child_output_ids"] == []
      assert record["evidence"]["parent_write_present"] == false
      assert record["evidence"]["reconstructed_count"] == record["n"]
    end

    close_record = Enum.find(records, &(&1["scenario"] == "pixir_close_mid_fanout"))
    assert close_record["status"] == "passed"
    assert close_record["metrics"]["cancelled_count"] == close_record["metrics"]["spawned_count"]
    assert close_record["metrics"]["terminal_count"] == close_record["metrics"]["spawned_count"]
    assert close_record["evidence"]["cancelled_events"] == 5

    replay_record = Enum.find(records, &(&1["scenario"] == "pixir_replay_summary"))
    assert replay_record["status"] == "passed"
    assert replay_record["evidence"]["replay_contains_subagent"] == true
    assert replay_record["evidence"]["replay_contains_completed"] == true
    assert replay_record["evidence"]["replay_drops_raw_tool_call_ids"] == true

    codex_record = Enum.find(records, &(&1["scenario"] == "codex_visible_fanout_probe"))
    assert codex_record["status"] == "not_observed"
    assert codex_record["network"] == false
    assert codex_record["evidence"]["reason"] =~ "does not drive T3 Code"
  end

  defp read_jsonl!(path) do
    path
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&Jason.decode!/1)
  end
end
