defmodule Mix.Tasks.Pixir.Bench.RealSubagentsTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Pixir.Bench.RealSubagents, as: BenchTask

  setup do
    output_dir =
      Path.join(
        System.tmp_dir!(),
        "pixir-bench-real-subagents-test-" <>
          Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
      )

    on_exit(fn -> File.rm_rf!(output_dir) end)

    %{output_dir: output_dir}
  end

  test "--json --help is machine-readable and advertises gate scenarios" do
    payload =
      capture_io(fn ->
        assert catch_exit(BenchTask.run(["--json", "--help"])) == :normal
      end)
      |> Jason.decode!()

    assert payload["ok"] == true
    assert payload["command"] == "mix pixir.bench.real_subagents"
    assert Enum.any?(payload["options"], &String.contains?(&1, "common_model_gate"))
    assert Enum.any?(payload["options"], &String.contains?(&1, "scaling_lifecycle"))
    assert "schema_validated" in payload["proof_states"]
    assert "completion_ready" in payload["proof_states"]
  end

  test "common_model_gate dry-run plans probes and deferred smoke only", %{
    output_dir: output_dir
  } do
    payload =
      capture_io(fn ->
        BenchTask.run([
          "--scenario",
          "common_model_gate",
          "--models",
          "gpt-5.5",
          "--reasoning-effort",
          "low",
          "--dry-run",
          "--json",
          "--output",
          output_dir
        ])
      end)
      |> Jason.decode!()

    assert payload["ok"] == true
    assert payload["mode"] == "dry_run"
    assert payload["scenario"] == "common_model_gate"
    assert payload["candidate_models"] == ["gpt-5.5"]
    assert payload["estimated_real_network_runs"] == 4
    assert Path.join(output_dir, "completion_audit.json") in payload["would_write"]
    assert payload["completion_semantics"]["success"] == "common_model_smoke_ready"
    assert "model_diverged" in payload["completion_semantics"]["non_comparable_abort"]
    assert "capability_diverged" in payload["completion_semantics"]["non_comparable_abort"]

    assert length(payload["would_run_probe"]) == 2
    assert length(payload["would_run_smoke_if_common_model"]) == 2

    assert Enum.all?(payload["would_run_probe"], fn plan ->
             plan["scenario"] == "probe" and plan["n"] == 0 and
               "--probe" in plan["command"]
           end)

    assert Enum.all?(payload["would_run_smoke_if_common_model"], fn plan ->
             plan["scenario"] == "smoke_real_n2" and plan["n"] == 2 and
               "--probe" not in plan["command"]
           end)

    refute File.exists?(output_dir)
  end

  test "probe permits n zero and smoke rejects it", %{output_dir: output_dir} do
    probe_payload =
      capture_io(fn ->
        BenchTask.run([
          "--scenario",
          "probe",
          "--n",
          "0",
          "--models",
          "gpt-5.5",
          "--dry-run",
          "--json",
          "--output",
          output_dir
        ])
      end)
      |> Jason.decode!()

    assert probe_payload["ok"] == true
    assert Path.join(output_dir, "completion_audit.json") in probe_payload["would_write"]
    assert Enum.all?(probe_payload["would_run"], &(&1["n"] == 0))

    error_payload =
      capture_io(fn ->
        assert catch_exit(
                 BenchTask.run([
                   "--scenario",
                   "smoke_real_n2",
                   "--n",
                   "0",
                   "--models",
                   "gpt-5.5",
                   "--dry-run",
                   "--json"
                 ])
               ) == {:shutdown, 1}
      end)
      |> Jason.decode!()

    assert error_payload["ok"] == false
    assert error_payload["error"]["kind"] == "invalid_n"
    assert error_payload["error"]["details"]["expected_minimum"] == 1
  end

  test "representative_review_n3 is fixed at three children" do
    error_payload =
      capture_io(fn ->
        assert catch_exit(
                 BenchTask.run([
                   "--scenario",
                   "representative_review_n3",
                   "--n",
                   "10",
                   "--models",
                   "gpt-5.5",
                   "--dry-run",
                   "--json"
                 ])
               ) == {:shutdown, 1}
      end)
      |> Jason.decode!()

    assert error_payload["ok"] == false
    assert error_payload["error"]["kind"] == "invalid_n"
    assert error_payload["error"]["details"]["expected_minimum"] == 3
    assert error_payload["error"]["details"]["expected_maximum"] == 3
  end

  test "scaling_lifecycle dry-run plans N=10 fixture prompts without network", %{
    output_dir: output_dir
  } do
    payload =
      capture_io(fn ->
        BenchTask.run([
          "--scenario",
          "scaling_lifecycle",
          "--models",
          "gpt-5.5",
          "--reasoning-effort",
          "low",
          "--dry-run",
          "--json",
          "--output",
          output_dir
        ])
      end)
      |> Jason.decode!()

    assert payload["ok"] == true
    assert payload["mode"] == "dry_run"
    assert payload["estimated_real_network_runs"] == 2
    assert Path.join(output_dir, "completion_audit.json") in payload["would_write"]

    assert Enum.all?(payload["would_run"], fn plan ->
             plan["scenario"] == "scaling_lifecycle" and plan["n"] == 10 and
               "--cwd" in plan["command"] and "--prompt-file" in plan["command"]
           end)

    refute File.exists?(output_dir)
  end
end
