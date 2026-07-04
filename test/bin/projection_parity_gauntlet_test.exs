defmodule Pixir.BinProjectionParityGauntletTest do
  use ExUnit.Case, async: true

  @script Path.expand("../../bin/pixir-projection-parity-gauntlet", __DIR__)

  test "prints help" do
    assert {out, 0} = run_script(["--help"])
    assert out =~ "Evaluate Pixir projection parity"
    assert out =~ "--runtime-truth-result"
    assert out =~ "--evidence-dir"
    assert out =~ "--dry-run"
    assert out =~ "--json"
  end

  test "lists projection parity scenarios as structured JSON" do
    assert {out, 0} = run_script(["--list-scenarios", "--json"])
    result = Jason.decode!(out)

    assert result["classification"] == "projection_parity_scenario_matrix"
    assert Enum.map(result["scenarios"], & &1["id"]) == ~w(P0 P1 P2 P3 P4 P5)
    assert result["pass_fail_warning_rubric"]["fail"] =~ "partial/failure evidence"
  end

  test "dry-run reports planned inputs without reading them" do
    root = tmp_dir()
    runtime_truth = Path.join(root, "runtime-truth.json")
    evidence_dir = Path.join(root, "presenter-packets")

    assert {out, 0} =
             run_script([
               "--runtime-truth-result",
               runtime_truth,
               "--evidence-dir",
               evidence_dir,
               "--dry-run",
               "--json"
             ])

    result = Jason.decode!(out)

    assert result["classification"] == "projection_parity_dry_run"
    assert result["planned_inputs"]["runtime_truth_result"] == runtime_truth

    assert result["required_packet_files"] == [
             "INDEX.md",
             "scenario-id.txt",
             "session-id.txt",
             "pixir-diagnose.json",
             "classification.md"
           ]
  end

  test "warns, but does not block, when runtime truth passes and live Presenter packets are pending" do
    root = tmp_dir()
    runtime_truth = Path.join(root, "runtime-truth.json")
    write_json!(runtime_truth, runtime_truth_pass())

    assert {out, 0} =
             run_script(["--runtime-truth-result", runtime_truth, "--json", "--fail-on-blocker"])

    result = Jason.decode!(out)

    assert result["ok"]
    assert result["registry_readiness"] == "warning"
    assert result["summary"]["runtime_truth_readiness"] == "not_blocked"
    assert result["summary"]["presenter_evidence_readiness"] == "warning"

    assert "record at least one T3 Code and one Zed Presenter packet when live dogfood is convenient" in result[
             "next_actions"
           ]
  end

  test "blocks when runtime truth contains blockers" do
    root = tmp_dir()
    runtime_truth = Path.join(root, "runtime-truth.json")
    write_json!(runtime_truth, runtime_truth_blocked())

    assert {out, 1} =
             run_script(["--runtime-truth-result", runtime_truth, "--json", "--fail-on-blocker"])

    result = Jason.decode!(out)

    refute result["ok"]
    assert result["registry_readiness"] == "blocked"
    assert [%{"kind" => "runtime_truth_blocked"}] = result["summary"]["blockers"]
  end

  test "passes when runtime truth and Presenter packet evidence are complete" do
    root = tmp_dir()
    runtime_truth = Path.join(root, "runtime-truth.json")
    packets_root = Path.join(root, "packets")

    write_json!(runtime_truth, runtime_truth_pass())

    Enum.each(~w(P0 P1 P2 P3 P4 P5), fn scenario_id ->
      write_packet!(Path.join(packets_root, String.downcase(scenario_id)), scenario_id)
    end)

    assert {out, 0} =
             run_script([
               "--runtime-truth-result",
               runtime_truth,
               "--evidence-dir",
               packets_root,
               "--json",
               "--fail-on-blocker"
             ])

    result = Jason.decode!(out)

    assert result["ok"]
    assert result["registry_readiness"] == "not_blocked"
    assert result["presenter_evidence"]["packet_count"] == 6
    assert Enum.all?(result["summary"]["scenario_statuses"], &(&1["status"] == "pass"))
    assert Enum.all?(result["presenter_evidence"]["packets"], &(&1["status"] == "pass"))
  end

  test "warns when Presenter packet classification is warn" do
    root = tmp_dir()
    runtime_truth = Path.join(root, "runtime-truth.json")
    packets_root = Path.join(root, "packets")

    write_json!(runtime_truth, runtime_truth_pass())

    Enum.each(~w(P0 P1 P2 P3 P4 P5), fn scenario_id ->
      classification = if scenario_id == "P4", do: "warn", else: "pass"

      write_packet!(
        Path.join(packets_root, String.downcase(scenario_id)),
        scenario_id,
        classification
      )
    end)

    assert {out, 0} =
             run_script([
               "--runtime-truth-result",
               runtime_truth,
               "--evidence-dir",
               packets_root,
               "--json",
               "--fail-on-blocker"
             ])

    result = Jason.decode!(out)

    assert result["ok"]
    assert result["registry_readiness"] == "warning"
    assert result["summary"]["presenter_evidence_readiness"] == "warning"
    assert [%{"kind" => "presenter_evidence_warning"}] = result["summary"]["warnings"]

    assert %{"classification" => "warn", "status" => "warn"} =
             Enum.find(result["presenter_evidence"]["packets"], &(&1["scenario_id"] == "P4"))

    assert %{"status" => "warn", "presenter_evidence_status" => "warn"} =
             Enum.find(result["summary"]["scenario_statuses"], &(&1["id"] == "P4"))

    assert "inspect Presenter packets classified as warn and decide whether they are acceptable for #52" in result[
             "next_actions"
           ]
  end

  test "blocks when Presenter packet classification is fail" do
    root = tmp_dir()
    runtime_truth = Path.join(root, "runtime-truth.json")
    packet = Path.join(root, "t3-p4")

    write_json!(runtime_truth, runtime_truth_pass())
    write_packet!(packet, "P4", "fail")

    assert {out, 1} =
             run_script([
               "--runtime-truth-result",
               runtime_truth,
               "--evidence-dir",
               packet,
               "--json",
               "--fail-on-blocker"
             ])

    result = Jason.decode!(out)

    refute result["ok"]
    assert result["registry_readiness"] == "blocked"

    assert %{"classification" => "fail", "status" => "fail"} =
             List.first(result["presenter_evidence"]["packets"])
  end

  test "blocks when Presenter packet classification is invalid" do
    root = tmp_dir()
    runtime_truth = Path.join(root, "runtime-truth.json")
    packet = Path.join(root, "t3-p4")

    write_json!(runtime_truth, runtime_truth_pass())
    write_packet!(packet, "P4", "maybe")

    assert {out, 1} =
             run_script([
               "--runtime-truth-result",
               runtime_truth,
               "--evidence-dir",
               packet,
               "--json",
               "--fail-on-blocker"
             ])

    result = Jason.decode!(out)

    refute result["ok"]
    assert result["registry_readiness"] == "blocked"

    assert ["valid classification.md"] =
             List.first(result["presenter_evidence"]["packets"])["missing_required_files"]
  end

  test "warns when a valid Presenter packet covers only one scenario" do
    root = tmp_dir()
    runtime_truth = Path.join(root, "runtime-truth.json")
    packet = Path.join(root, "zed-p0")

    write_json!(runtime_truth, runtime_truth_pass())
    write_packet!(packet, "P0")

    assert {out, 0} =
             run_script([
               "--runtime-truth-result",
               runtime_truth,
               "--evidence-dir",
               packet,
               "--json",
               "--fail-on-blocker"
             ])

    result = Jason.decode!(out)

    assert result["ok"]
    assert result["registry_readiness"] == "warning"

    assert %{"id" => "P0", "status" => "pass"} =
             List.first(result["summary"]["scenario_statuses"])

    assert Enum.any?(
             result["summary"]["scenario_statuses"],
             &(&1["id"] == "P1" and &1["presenter_evidence_status"] == "missing")
           )

    assert "record Presenter packets for scenarios with missing presenter evidence" in result[
             "next_actions"
           ]
  end

  test "blocks when supplied Presenter packet is incomplete" do
    root = tmp_dir()
    runtime_truth = Path.join(root, "runtime-truth.json")
    packet = Path.join(root, "zed-z1")

    write_json!(runtime_truth, runtime_truth_pass())
    File.mkdir_p!(packet)
    File.write!(Path.join(packet, "INDEX.md"), "# Z1\n")

    assert {out, 1} =
             run_script([
               "--runtime-truth-result",
               runtime_truth,
               "--evidence-dir",
               packet,
               "--json",
               "--fail-on-blocker"
             ])

    result = Jason.decode!(out)

    refute result["ok"]
    assert result["registry_readiness"] == "blocked"
    assert [%{"kind" => "presenter_evidence_invalid"}] = result["summary"]["blockers"]
  end

  test "human output includes structured tool error details" do
    root = tmp_dir()
    missing = Path.join(root, "missing-runtime-truth.json")

    assert {out, 2} = run_script(["--runtime-truth-result", missing])

    assert out =~ "classification: projection_parity_gauntlet_unavailable"
    assert out =~ "error.kind: runtime_truth_result_missing"
  end

  defp run_script(args) do
    cond do
      uv = System.find_executable("uv") ->
        System.cmd(uv, ["run", "python", @script | args], stderr_to_stdout: true)

      python = System.find_executable("python3") ->
        System.cmd(python, [@script | args], stderr_to_stdout: true)

      python = System.find_executable("python") ->
        System.cmd(python, [@script | args], stderr_to_stdout: true)

      true ->
        flunk("no Python runner found; install uv or python3")
    end
  end

  defp runtime_truth_pass do
    %{
      "classification" => "runtime_trust_gauntlet",
      "backend_readiness" => "not_blocked",
      "summary" => %{
        "total" => 12,
        "pass" => 12,
        "warn" => 0,
        "fail" => 0,
        "coverage_status" => "complete",
        "covered_scenarios" => ~w(T0 T1 T2 T3 T4 T5 T6 T7 T8 T9 T10 T11),
        "missing_scenarios" => [],
        "backend_blockers" => []
      }
    }
  end

  defp runtime_truth_blocked do
    %{
      "classification" => "runtime_trust_gauntlet",
      "backend_readiness" => "blocked",
      "summary" => %{
        "total" => 1,
        "pass" => 0,
        "warn" => 0,
        "fail" => 1,
        "coverage_status" => "incomplete",
        "covered_scenarios" => ["T1"],
        "missing_scenarios" => ~w(T0 T2 T3 T4 T5 T6 T7 T8 T9 T10 T11),
        "backend_blockers" => [
          %{
            "scenario" => "T1",
            "classification" => "partial_answer_projection",
            "fixture" => "t1-fail.json"
          }
        ]
      }
    }
  end

  defp write_packet!(packet, scenario_id, classification \\ "pass") do
    File.mkdir_p!(packet)
    File.write!(Path.join(packet, "INDEX.md"), "# #{scenario_id}\n")
    File.write!(Path.join(packet, "scenario-id.txt"), "#{scenario_id}\n")
    File.write!(Path.join(packet, "session-id.txt"), "20260630T000000-z1\n")

    File.write!(
      Path.join(packet, "classification.md"),
      """
      classification: #{classification}
      owner: test_fixture
      reason: fixture packet
      """
    )

    File.write!(
      Path.join(packet, "presenter-visible-notes.md"),
      "Visible response matched Pixir.\n"
    )

    write_json!(Path.join(packet, "pixir-diagnose.json"), %{"ok" => true})
  end

  defp write_json!(path, value) do
    File.write!(path, Jason.encode!(value))
  end

  defp tmp_dir do
    path =
      Path.join(
        System.tmp_dir!(),
        "pixir-projection-parity-gauntlet-test-#{System.unique_integer([:positive])}"
      )

    File.rm_rf!(path)
    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end
end
