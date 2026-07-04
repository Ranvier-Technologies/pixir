defmodule Mix.Tasks.Pixir.Bench.CodexPressureTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Pixir.Bench.CodexPressure, as: BenchTask

  setup do
    output_dir =
      Path.join(
        System.tmp_dir!(),
        "pixir-bench-codex-pressure-test-" <>
          Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
      )

    config_dir =
      Path.join(
        System.tmp_dir!(),
        "pixir-bench-codex-pressure-config-" <>
          Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
      )

    config_path = Path.join(config_dir, "config.toml")
    File.mkdir_p!(config_dir)

    File.write!(config_path, """
    max_parallel_agents = 12
    api_key = "secret-like-value"
    unrelated = "kept out"
    """)

    on_exit(fn ->
      File.rm_rf!(output_dir)
      File.rm_rf!(config_dir)
    end)

    %{output_dir: output_dir, config_path: config_path}
  end

  test "--json --help is machine-readable and advertises artifacts" do
    payload =
      capture_io(fn ->
        assert catch_exit(BenchTask.run(["--json", "--help"])) == :normal
      end)
      |> Jason.decode!()

    assert payload["ok"] == true
    assert payload["command"] == "mix pixir.bench.codex_pressure"
    assert "samples.jsonl" in Enum.map(payload["artifacts"], &Path.basename/1)
    assert "--profile NAME" in payload["options"]

    assert %{"name" => "pixir-runtime-only"} in Enum.map(
             payload["profiles"],
             &Map.take(&1, ["name"])
           )

    assert "completion_ready" in payload["proof_states"]
  end

  test "--dry-run --json is no-write and records config candidates", %{
    output_dir: output_dir,
    config_path: config_path
  } do
    File.mkdir_p!(Path.dirname(config_path))

    File.write!(config_path, """
    max_parallel_agents = 12
    api_key = "secret-like-value"
    unrelated = "kept out"
    """)

    payload =
      capture_io(fn ->
        assert catch_exit(
                 BenchTask.run([
                   "--dry-run",
                   "--json",
                   "--output",
                   output_dir,
                   "--codex-config",
                   config_path,
                   "--configured-limit",
                   "12",
                   "--target-n",
                   "8"
                 ])
               ) == :normal
      end)
      |> Jason.decode!()

    assert payload["ok"] == true
    assert payload["mode"] == "dry_run"
    assert payload["profile"]["name"] == "codex-app-stack"
    assert payload["estimated_real_network_runs"] == 0
    assert payload["target_n"] == 8
    assert payload["codex_config"]["configured_limit"] == 12
    assert payload["codex_config"]["configured_limit_source"] == "cli"

    assert [%{"key" => "max_parallel_agents", "value" => "12"}] =
             payload["codex_config"]["candidate_settings"]

    refute File.exists?(output_dir)
  end

  test "--dry-run --json accepts measurement profiles", %{
    output_dir: output_dir,
    config_path: config_path
  } do
    payload =
      capture_io(fn ->
        assert catch_exit(
                 BenchTask.run([
                   "--dry-run",
                   "--json",
                   "--output",
                   output_dir,
                   "--codex-config",
                   config_path,
                   "--profile",
                   "pixir-runtime-only"
                 ])
               ) == :normal
      end)
      |> Jason.decode!()

    assert payload["profile"]["name"] == "pixir-runtime-only"
    assert "pixir" in payload["process_patterns"]
    assert "beam.smp" in payload["process_patterns"]
  end

  test "--dry-run --json infers configured limit from config", %{
    output_dir: output_dir,
    config_path: config_path
  } do
    File.write!(config_path, """
    [agents]
    multi_agent = true
    max_threads = 20
    max_depth = 2
    """)

    payload =
      capture_io(fn ->
        assert catch_exit(
                 BenchTask.run([
                   "--dry-run",
                   "--json",
                   "--output",
                   output_dir,
                   "--codex-config",
                   config_path,
                   "--target-n",
                   "8"
                 ])
               ) == :normal
      end)
      |> Jason.decode!()

    assert payload["codex_config"]["configured_limit"] == 20
    assert payload["codex_config"]["configured_limit_source"] == "detected"

    assert %{"key" => "max_threads", "value" => "20"} in payload["codex_config"][
             "candidate_settings"
           ]
  end

  test "--dry-run --json redacts default workspace and home paths" do
    payload =
      capture_io(fn ->
        assert catch_exit(BenchTask.run(["--dry-run", "--json"])) == :normal
      end)
      |> Jason.decode!()

    assert String.starts_with?(payload["codex_config"]["path"], "$HOME/")

    assert Enum.all?(payload["would_write"], fn path ->
             String.starts_with?(path, "$WORKSPACE/")
           end)
  end

  test "--dry-run --json redacts workspace paths when cwd is outside home" do
    workspace =
      Path.join(
        System.tmp_dir!(),
        "pixir-bench-workspace-" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
      )

    File.mkdir_p!(workspace)

    try do
      payload =
        File.cd!(workspace, fn ->
          capture_io(fn ->
            assert catch_exit(BenchTask.run(["--dry-run", "--json"])) == :normal
          end)
        end)
        |> Jason.decode!()

      assert Enum.all?(payload["would_write"], &String.starts_with?(&1, "$WORKSPACE/"))
      refute payload |> Jason.encode!() |> String.contains?(Path.expand(workspace))
    after
      File.rm_rf!(workspace)
    end
  end

  test "--dry-run --json redacts private tmp output paths outside the workspace" do
    output_dir =
      Path.join(
        "/private/tmp",
        "pixir-bench-output-" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
      )

    payload =
      capture_io(fn ->
        assert catch_exit(BenchTask.run(["--dry-run", "--json", "--output", output_dir])) ==
                 :normal
      end)
      |> Jason.decode!()

    assert Enum.all?(payload["would_write"], &String.starts_with?(&1, "$TMPDIR/"))
    refute payload |> Jason.encode!() |> String.contains?(Path.expand(output_dir))
  end

  test "invalid inputs return structured errors" do
    payload =
      capture_io(fn ->
        assert catch_exit(BenchTask.run(["--duration-seconds", "0", "--json"])) ==
                 {:shutdown, 1}
      end)
      |> Jason.decode!()

    assert payload["ok"] == false
    assert payload["error"]["kind"] == "invalid_positive_integer"

    payload =
      capture_io(fn ->
        assert catch_exit(BenchTask.run(["--target-n", "0", "--json"])) == {:shutdown, 1}
      end)
      |> Jason.decode!()

    assert payload["ok"] == false
    assert payload["error"]["kind"] == "invalid_target_n"

    payload =
      capture_io(fn ->
        assert catch_exit(BenchTask.run(["--profile", "nope", "--json"])) == {:shutdown, 1}
      end)
      |> Jason.decode!()

    assert payload["ok"] == false
    assert payload["error"]["kind"] == "invalid_profile"

    payload =
      capture_io(fn ->
        assert catch_exit(BenchTask.run(["--process-patterns", "", "--json"])) == {:shutdown, 1}
      end)
      |> Jason.decode!()

    assert payload["ok"] == false
    assert payload["error"]["kind"] == "missing_process_patterns"
  end

  test "short run writes samples, summary, report, and completion audit", %{
    output_dir: output_dir
  } do
    payload =
      capture_io(fn ->
        BenchTask.run([
          "--json",
          "--output",
          output_dir,
          "--duration-seconds",
          "1",
          "--interval-ms",
          "250",
          "--process-patterns",
          "unlikely-pixir-codex-pressure-test-pattern",
          "--configured-limit",
          "20",
          "--target-n",
          "4"
        ])
      end)
      |> Jason.decode!()

    assert payload["summary"]["target_n"] == 4
    assert payload["summary"]["profile"]["name"] == "custom"
    assert payload["summary"]["codex_config"]["configured_limit"] == 20
    assert payload["completion_audit"]["status"] in ["completion_ready", "incomplete"]
    assert payload["ok"] == (payload["completion_audit"]["status"] == "completion_ready")

    samples_path = Path.join(output_dir, "samples.jsonl")
    summary_path = Path.join(output_dir, "summary.json")
    report_path = Path.join(output_dir, "report.md")
    audit_path = Path.join(output_dir, "completion_audit.json")

    assert File.exists?(samples_path)
    assert File.exists?(summary_path)
    assert File.exists?(report_path)
    assert File.exists?(audit_path)

    samples = read_jsonl!(samples_path)
    summary = summary_path |> File.read!() |> Jason.decode!()
    report = File.read!(report_path)

    assert length(samples) >= 1
    assert summary["samples_count"] == length(samples)
    assert is_number(summary["pressure"]["peak_tracked_rss_mb"])
    assert is_number(summary["pressure"]["peak_process_tree_rss_mb"])
    assert is_integer(summary["pressure"]["peak_process_tree_count"])
    assert report =~ "Pixir vs Codex Resource Pressure Benchmark"
    assert report =~ "Peak process-tree RSS MB"
    assert report =~ "not model/provider memory"
  end

  defp read_jsonl!(path) do
    path
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&Jason.decode!/1)
  end
end
