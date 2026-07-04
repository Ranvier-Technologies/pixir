defmodule Mix.Tasks.Pixir.Bench.FanoutGauntletTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Pixir.Bench.FanoutGauntlet, as: BenchTask

  setup do
    output_dir =
      Path.join(
        System.tmp_dir!(),
        "pixir-bench-fanout-gauntlet-test-" <>
          Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
      )

    bin_dir =
      Path.join(
        System.tmp_dir!(),
        "pixir-bench-fanout-gauntlet-bin-" <>
          Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
      )

    File.mkdir_p!(bin_dir)

    on_exit(fn ->
      File.rm_rf!(output_dir)
      File.rm_rf!(bin_dir)
    end)

    %{output_dir: output_dir, bin_dir: bin_dir}
  end

  test "--json --help is machine-readable and advertises artifacts" do
    payload =
      capture_io(fn ->
        assert catch_exit(BenchTask.run(["--json", "--help"])) == :normal
      end)
      |> Jason.decode!()

    assert payload["ok"] == true
    assert payload["command"] == "mix pixir.bench.fanout_gauntlet"
    assert "direct_runs.jsonl" in payload["artifacts"]
    assert "--mode all|direct|parent" in payload["options"]
  end

  test "--dry-run --json is no-write and declares planned checks", %{output_dir: output_dir} do
    payload =
      capture_io(fn ->
        assert catch_exit(
                 BenchTask.run([
                   "--dry-run",
                   "--json",
                   "--output",
                   output_dir,
                   "--mode",
                   "all",
                   "--direct-n",
                   "2",
                   "--parent-n",
                   "3"
                 ])
               ) == :normal
      end)
      |> Jason.decode!()

    assert payload["ok"] == true
    assert payload["mode"] == "dry_run"
    assert payload["would_run"] == ["direct_cli", "parent_led_subagents"]
    assert payload["estimated_real_network_runs"] == 0
    assert payload["direct"]["n"] == 2
    assert payload["parent"]["includes_timeout_fixture"] == true
    refute File.exists?(output_dir)
  end

  test "invalid inputs return structured errors" do
    payload =
      capture_io(fn ->
        assert catch_exit(BenchTask.run(["--mode", "bogus", "--json"])) == {:shutdown, 1}
      end)
      |> Jason.decode!()

    assert payload["ok"] == false
    assert payload["error"]["kind"] == "invalid_mode"

    payload =
      capture_io(fn ->
        assert catch_exit(BenchTask.run(["--direct-n", "0", "--json"])) == {:shutdown, 1}
      end)
      |> Jason.decode!()

    assert payload["ok"] == false
    assert payload["error"]["kind"] == "invalid_positive_integer"
    assert payload["error"]["details"]["field"] == "direct_n"
  end

  test "direct mode records stdout, stderr, exit code, session id, and terminal outcome", %{
    output_dir: output_dir,
    bin_dir: bin_dir
  } do
    pixir_bin = fake_pixir!(bin_dir, :normal)

    payload =
      capture_io(fn ->
        BenchTask.run([
          "--mode",
          "direct",
          "--direct-n",
          "3",
          "--pixir-bin",
          pixir_bin,
          "--output",
          output_dir,
          "--json"
        ])
      end)
      |> Jason.decode!()

    assert payload["ok"] == true
    assert payload["completion_audit"]["status"] == "completion_ready"

    records = read_jsonl!(Path.join(output_dir, "direct_runs.jsonl"))
    assert length(records) == 3

    assert Enum.all?(records, &(&1["status"] == "passed"))
    assert Enum.all?(records, &is_integer(&1["exit_code"]))
    assert Enum.any?(records, &(&1["session_id"] == "doctor-session"))
    assert Enum.all?(records, &(&1["diagnostics"]["issues"] == []))
    assert Enum.all?(records, &File.exists?(&1["stdout_path"]))
    assert Enum.all?(records, &File.exists?(&1["stderr_path"]))

    terminal_outcomes = Enum.map(records, & &1["terminal_outcome"])
    assert "completed_with_session" in terminal_outcomes
    assert "completed_no_session" in terminal_outcomes
  end

  test "direct mode fails on empty stdout false success", %{
    output_dir: output_dir,
    bin_dir: bin_dir
  } do
    pixir_bin = fake_pixir!(bin_dir, :empty_success)

    payload =
      capture_io(fn ->
        assert catch_exit(
                 BenchTask.run([
                   "--mode",
                   "direct",
                   "--direct-n",
                   "1",
                   "--pixir-bin",
                   pixir_bin,
                   "--output",
                   output_dir,
                   "--json"
                 ])
               ) == {:shutdown, 1}
      end)
      |> Jason.decode!()

    assert payload["ok"] == false
    assert payload["completion_audit"]["status"] == "incomplete"

    [record] = read_jsonl!(Path.join(output_dir, "direct_runs.jsonl"))
    assert record["status"] == "failed"
    assert record["terminal_outcome"] == "missing_stdout"
    assert [%{"kind" => "empty_stdout_false_success"} | _] = record["diagnostics"]["issues"]
  end

  test "parent mode records honest partial timeout evidence", %{output_dir: output_dir} do
    payload =
      capture_io(fn ->
        BenchTask.run([
          "--mode",
          "parent",
          "--parent-n",
          "3",
          "--timeout-ms",
          "500",
          "--output",
          output_dir,
          "--json"
        ])
      end)
      |> Jason.decode!()

    assert payload["ok"] == true
    assert payload["completion_audit"]["status"] == "completion_ready"

    [record] = read_jsonl!(Path.join(output_dir, "parent_runs.jsonl"))
    assert record["status"] == "passed"
    assert record["parent_outcome"]["status"] == "partial_honest"
    assert record["parent_outcome"]["wait_status"] == "partial"
    assert record["functional"]["children_requested"] == 3
    assert record["functional"]["completed_count"] == 2
    assert record["functional"]["timed_out_count"] == 1
    assert "subagent_timeouts" in record["evidence"]["diagnostic_warning_checks"]

    timeout_child = Enum.find(record["child_outcomes"], &(&1["status"] == "timed_out"))
    assert timeout_child["reason"] == "timeout"
    assert timeout_child["timeout_ms"] == 500
    assert "retry_subagent_with_larger_timeout" in timeout_child["next_actions"]
  end

  test "all mode writes summary, report, and completion audit", %{
    output_dir: output_dir,
    bin_dir: bin_dir
  } do
    pixir_bin = fake_pixir!(bin_dir, :normal)

    payload =
      capture_io(fn ->
        BenchTask.run([
          "--mode",
          "all",
          "--direct-n",
          "3",
          "--parent-n",
          "3",
          "--timeout-ms",
          "500",
          "--pixir-bin",
          pixir_bin,
          "--output",
          output_dir,
          "--json"
        ])
      end)
      |> Jason.decode!()

    assert payload["ok"] == true
    assert payload["summary"]["status"] == "passed"
    assert payload["completion_audit"]["status"] == "completion_ready"

    assert File.exists?(Path.join(output_dir, "summary.json"))
    assert File.exists?(Path.join(output_dir, "report.md"))
    assert File.exists?(Path.join(output_dir, "completion_audit.json"))

    report = File.read!(Path.join(output_dir, "report.md"))
    assert report =~ "correctness and honest-outcome gauntlet"
    assert report =~ "Resource pressure is not sampled"
  end

  defp fake_pixir!(bin_dir, mode) do
    path = Path.join(bin_dir, "pixir")

    body =
      case mode do
        :normal ->
          """
          #!/bin/sh
          case "$1" in
            --version)
              echo "0.1.test"
              ;;
            doctor)
              echo "ok: true"
              echo "session_id: doctor-session"
              ;;
            help)
              echo "pixir help"
              ;;
            *)
              echo "unknown command" >&2
              exit 2
              ;;
          esac
          """

        :empty_success ->
          """
          #!/bin/sh
          exit 0
          """
      end

    File.write!(path, body)
    File.chmod!(path, 0o755)
    path
  end

  defp read_jsonl!(path) do
    path
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&Jason.decode!/1)
  end
end
