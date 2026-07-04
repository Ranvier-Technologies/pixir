defmodule Pixir.BinBackendGauntletV2Test do
  use ExUnit.Case, async: true

  @script Path.expand("../../bin/pixir-backend-gauntlet-v2", __DIR__)

  test "prints agent-useful help" do
    assert {out, 0} = run_script(["--help"])
    assert out =~ "Run the Pixir backend gauntlet v2 join gate"
    assert out =~ "--dry-run"
    assert out =~ "--json"
    assert out =~ "--mode"
    assert out =~ "--output"
    assert out =~ "--mix-bin"
    assert out =~ "--child-timeout-seconds"
  end

  test "dry-run reports planned artifacts and commands without writing output" do
    root = tmp_dir()
    output = Path.join(root, "planned")

    assert {out, 0} = run_script(["--dry-run", "--json", "--output", output])
    result = Jason.decode!(out)

    assert result["classification"] == "backend_gauntlet_v2_plan"
    assert result["mode"] == "all"
    assert result["network_required"] == false
    assert result["ui_required"] == false
    assert "T11" in result["scenario_ids"]
    refute File.exists?(output)

    assert Enum.any?(result["would_run"], &(&1["component"] == "runtime_truth"))
    assert Enum.any?(result["would_run"], &(&1["component"] == "fanout"))
    assert Enum.any?(result["would_write"], &String.ends_with?(&1, "completion_audit.json"))
  end

  test "runtime-truth mode writes completion-ready backend evidence" do
    root = tmp_dir()
    output = Path.join(root, "runtime")

    assert {out, 0} =
             run_script([
               "--mode",
               "runtime-truth",
               "--json",
               "--output",
               output
             ])

    result = Jason.decode!(out)

    assert result["ok"]
    assert result["classification"] == "backend_gauntlet_v2"
    assert result["completion_audit"]["status"] == "completion_ready"
    assert result["components"]["runtime_truth"]["coverage_status"] == "complete"
    assert result["components"]["runtime_truth"]["backend_readiness"] == "not_blocked"
    assert File.exists?(Path.join(output, "runtime-truth-result.json"))
    assert File.exists?(Path.join(output, "completion_audit.json"))
    assert File.exists?(Path.join(output, "report.md"))
  end

  test "child subprocess timeout returns structured incomplete evidence" do
    root = tmp_dir()
    output = Path.join(root, "timeout")

    assert {out, 1} =
             run_script([
               "--mode",
               "runtime-truth",
               "--json",
               "--output",
               output,
               "--child-timeout-seconds",
               "0.000001"
             ])

    result = Jason.decode!(out)

    assert result["ok"] == false
    assert result["status"] == "failed"
    assert result["components"]["runtime_truth"]["exit_code"] == 124
    assert result["components"]["runtime_truth"]["diagnostic_verdict"] == "blocked"

    child_result = File.read!(Path.join(output, "runtime-truth-result.json")) |> Jason.decode!()
    assert child_result["error"]["kind"] == "child_timeout"

    stderr = File.read!(Path.join(output, "runtime-truth-stderr.txt"))
    assert stderr =~ "[gauntlet] child command timed out"
  end

  test "missing child command returns structured incomplete evidence" do
    root = tmp_dir()
    output = Path.join(root, "missing-command")
    missing_mix = Path.join(root, "definitely-not-mix")

    assert {out, 1} =
             run_script([
               "--mode",
               "fanout",
               "--json",
               "--output",
               output,
               "--mix-bin",
               missing_mix
             ])

    result = Jason.decode!(out)

    assert result["ok"] == false
    assert result["status"] == "failed"
    assert result["components"]["fanout"]["exit_code"] == 127
    assert result["components"]["fanout"]["diagnostic_verdict"] == "incomplete"

    child_result = File.read!(Path.join(output, "fanout-result.json")) |> Jason.decode!()
    assert child_result["error"]["kind"] == "child_command_not_found"

    stderr = File.read!(Path.join(output, "fanout-stderr.txt"))
    assert stderr =~ "[gauntlet] child command not found: #{missing_mix}"
  end

  test "fails with structured error when output exists and force is not passed" do
    root = tmp_dir()
    output = Path.join(root, "existing")
    File.mkdir_p!(output)
    File.write!(Path.join(output, "sentinel.txt"), "exists")

    assert {out, 2} = run_script(["--json", "--output", output])
    result = Jason.decode!(out)

    assert result["status"] == "tool_error"
    assert result["error"]["kind"] == "output_exists"
    assert "or pass --force to overwrite the directory" in result["next_actions"]
  end

  defp run_script(args, opts \\ []) do
    cond do
      uv = System.find_executable("uv") ->
        System.cmd(uv, ["run", "python", @script | args], command_opts(opts))

      python = System.find_executable("python3") ->
        System.cmd(python, [@script | args], command_opts(opts))

      python = System.find_executable("python") ->
        System.cmd(python, [@script | args], command_opts(opts))

      true ->
        flunk("no Python runner found; install uv or python3")
    end
  end

  defp command_opts(opts) do
    Keyword.merge([stderr_to_stdout: true], opts)
  end

  defp tmp_dir do
    path =
      Path.join(
        System.tmp_dir!(),
        "pixir-backend-gauntlet-v2-test-#{System.unique_integer([:positive])}"
      )

    File.rm_rf!(path)
    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end
end
