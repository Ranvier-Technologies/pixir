defmodule Pixir.BinRuntimeTrustGauntletTest do
  use ExUnit.Case, async: true

  @script Path.expand("../../bin/pixir-runtime-trust-gauntlet", __DIR__)

  test "prints help" do
    assert {out, 0} = run_script(["--help"])
    assert out =~ "Evaluate Pixir runtime trust scenarios"
    assert out =~ "--fixture"
    assert out =~ "--dry-run"
    assert out =~ "--json"
    assert out =~ "--require-all-scenarios"
  end

  test "lists the scenario matrix as structured JSON" do
    assert {out, 0} = run_script(["--list-scenarios", "--json"])
    result = Jason.decode!(out)

    assert result["classification"] == "scenario_matrix"
    assert Enum.map(result["scenarios"], & &1["id"]) == ~w(T0 T1 T2 T3 T4 T5 T6 T7 T8 T9 T10 T11)
  end

  test "dry-run reports planned fixtures without evaluating them" do
    root = tmp_dir()
    fixture = Path.join(root, "t0-pass.json")
    write_json!(fixture, t0_pass_fixture())

    assert {out, 0} = run_script(["--fixture", fixture, "--dry-run", "--json"])
    result = Jason.decode!(out)

    assert result["classification"] == "dry_run"
    assert [path] = result["planned_fixtures"]
    assert path =~ "t0-pass.json"
  end

  test "passes a healthy clean-answer fixture" do
    root = tmp_dir()
    fixture = Path.join(root, "t0-pass.json")
    write_json!(fixture, t0_pass_fixture())

    assert {out, 0} = run_script(["--fixture", fixture, "--json", "--fail-on-blocker"])
    result = Jason.decode!(out)

    assert result["ok"]
    assert result["backend_readiness"] == "not_blocked"
    assert result["registry_readiness"] == "not_blocked"
    assert result["summary"]["pass"] == 1
    assert [scenario] = result["results"]
    assert scenario["scenario"] == "T0"
    assert scenario["status"] == "pass"
  end

  test "blocks Registry readiness when partial evidence is projected as clean success" do
    root = tmp_dir()
    fixture = Path.join(root, "t1-fail.json")
    write_json!(fixture, t1_fail_fixture())

    assert {out, 1} = run_script(["--fixture", fixture, "--json", "--fail-on-blocker"])
    result = Jason.decode!(out)

    refute result["ok"]
    assert result["backend_readiness"] == "blocked"
    assert result["registry_readiness"] == "blocked"
    assert result["summary"]["fail"] == 1

    assert [
             %{
               "scenario" => "T1",
               "classification" => "partial_answer_projection"
             }
           ] = result["summary"]["registry_blockers"]
  end

  test "classifies actionable subagent timeout evidence as a warning, not a blocker" do
    root = tmp_dir()
    fixture = Path.join(root, "t4-warn.json")
    write_json!(fixture, t4_warn_fixture())

    assert {out, 0} = run_script(["--fixture", fixture, "--json", "--fail-on-blocker"])
    result = Jason.decode!(out)

    assert result["registry_readiness"] == "not_blocked"
    assert result["summary"]["warn"] == 1
    assert [scenario] = result["results"]
    assert scenario["scenario"] == "T4"
    assert scenario["classification"] == "subagent_timeout_actionable"
  end

  test "blocks backend readiness when complete coverage is required and scenarios are missing" do
    root = tmp_dir()
    fixture = Path.join(root, "t0-pass.json")
    write_json!(fixture, t0_pass_fixture())

    assert {out, 1} =
             run_script([
               "--fixture",
               fixture,
               "--json",
               "--fail-on-blocker",
               "--require-all-scenarios"
             ])

    result = Jason.decode!(out)

    refute result["ok"]
    assert result["backend_readiness"] == "blocked"
    assert result["summary"]["coverage_status"] == "incomplete"
    assert "T11" in result["summary"]["missing_scenarios"]
  end

  test "passes a complete backend runtime truth fixture set with actionable timeout warning" do
    root = tmp_dir()

    [
      {"t0-pass.json", t0_pass_fixture()},
      {"t1-pass.json", t1_pass_fixture()},
      {"t2-pass.json", t2_pass_fixture()},
      {"t3-pass.json", t3_pass_fixture()},
      {"t4-warn.json", t4_warn_fixture()},
      {"t5-pass.json", t5_pass_fixture()},
      {"t6-pass.json", t6_pass_fixture()},
      {"t7-pass.json", t7_pass_fixture()},
      {"t8-pass.json", t8_pass_fixture()},
      {"t9-pass.json", t9_pass_fixture()},
      {"t10-pass.json", t10_pass_fixture()},
      {"t11-pass.json", t11_pass_fixture()}
    ]
    |> Enum.each(fn {name, fixture} -> write_json!(Path.join(root, name), fixture) end)

    assert {out, 0} =
             run_script([
               "--fixture-dir",
               root,
               "--json",
               "--fail-on-blocker",
               "--require-all-scenarios"
             ])

    result = Jason.decode!(out)

    assert result["ok"]
    assert result["backend_readiness"] == "not_blocked"
    assert result["summary"]["coverage_status"] == "complete"
    assert result["summary"]["pass"] == 11
    assert result["summary"]["warn"] == 1
    assert result["summary"]["fail"] == 0
    assert result["summary"]["missing_scenarios"] == []
  end

  test "turn terminal failure fixture handles null turn_failed_count as structured finding" do
    root = tmp_dir()
    fixture = Path.join(root, "t9-null-count.json")

    write_json!(fixture, put_in(t9_pass_fixture(), ["pixir", "turn_failed_count"], nil))

    assert {out, 1} = run_script(["--fixture", fixture, "--json", "--fail-on-blocker"])
    result = Jason.decode!(out)

    assert result["summary"]["fail"] == 1
    assert [scenario] = result["results"]
    assert scenario["scenario"] == "T9"

    assert "Pixir lacks durable turn_failed evidence for the terminal Turn." in scenario[
             "findings"
           ]
  end

  test "subagent completion fixture reports malformed terminal state entries" do
    root = tmp_dir()
    fixture = Path.join(root, "t10-malformed-state.json")

    write_json!(
      fixture,
      put_in(t10_pass_fixture(), ["pixir", "subagent_terminal_states"], [
        "bad",
        %{"status" => "completed"}
      ])
    )

    assert {out, 1} = run_script(["--fixture", fixture, "--json", "--fail-on-blocker"])
    result = Jason.decode!(out)

    assert result["summary"]["fail"] == 1
    assert [scenario] = result["results"]
    assert scenario["scenario"] == "T10"
    assert "subagent_terminal_states contains 1 non-object entries." in scenario["findings"]

    assert Enum.any?(
             scenario["findings"],
             &String.starts_with?(&1, "Subagent completion evidence is missing fields:")
           )
  end

  test "missing required coverage next actions also surface real backend blockers" do
    root = tmp_dir()
    fixture = Path.join(root, "t1-fail.json")
    write_json!(fixture, t1_fail_fixture())

    assert {out, 1} =
             run_script([
               "--fixture",
               fixture,
               "--json",
               "--fail-on-blocker",
               "--require-all-scenarios"
             ])

    result = Jason.decode!(out)

    assert "add fixtures for every missing scenario" in result["next_actions"]
    assert "inspect each backend_blocker" in result["next_actions"]
    assert result["summary"]["coverage_status"] == "incomplete"
    assert Enum.any?(result["summary"]["backend_blockers"], &(&1["scenario"] == "T1"))
  end

  test "returns a structured tool error when no fixtures are supplied" do
    assert {out, 2} = run_script(["--json"])
    result = Jason.decode!(out)

    assert result["status"] == "tool_error"
    assert result["error"]["kind"] == "no_fixtures"
    assert "pass --fixture <file.json>" in result["next_actions"]
  end

  test "returns a structured tool error when fixture root is not an object" do
    root = tmp_dir()
    fixture = Path.join(root, "not-object.json")
    write_json!(fixture, ["T0"])

    assert {out, 2} = run_script(["--fixture", fixture, "--json"])
    result = Jason.decode!(out)

    assert result["status"] == "tool_error"
    assert result["error"]["kind"] == "fixture_invalid_shape"
    assert result["error"]["details"]["json_type"] == "list"
  end

  defp run_script(args) do
    cond do
      uv = System.find_executable("uv") ->
        System.cmd(uv, ["run", "python", @script | args])

      python = System.find_executable("python3") ->
        System.cmd(python, [@script | args])

      python = System.find_executable("python") ->
        System.cmd(python, [@script | args])

      true ->
        flunk("no Python runner found; install uv or python3")
    end
  end

  defp t0_pass_fixture do
    %{
      "scenario" => "T0",
      "pixir" => %{"clean_assistant_messages" => 1},
      "presenter" => %{"clean_final_answer" => true, "completed" => true},
      "evidence" => %{"session_id" => "20260622T000000-clean"}
    }
  end

  defp t1_fail_fixture do
    %{
      "scenario" => "T1",
      "pixir" => %{"partial_assistant_messages" => 1},
      "presenter" => %{
        "clean_final_answer" => true,
        "completed" => true,
        "partial_marked" => false
      },
      "evidence" => %{"session_id" => "20260622T000001-partial"}
    }
  end

  defp t1_pass_fixture do
    %{
      "scenario" => "T1",
      "pixir" => %{"partial_assistant_messages" => 1},
      "presenter" => %{
        "clean_final_answer" => false,
        "completed" => false,
        "partial_marked" => true
      },
      "evidence" => %{"session_id" => "20260622T000001-partial-pass"}
    }
  end

  defp t2_pass_fixture do
    %{
      "scenario" => "T2",
      "pixir" => %{"turn_failed_count" => 1},
      "presenter" => %{
        "clean_final_answer" => false,
        "stale_historical_answer" => false
      },
      "evidence" => %{"session_id" => "20260622T000002-provider-error"}
    }
  end

  defp t3_pass_fixture do
    %{
      "scenario" => "T3",
      "pixir" => %{
        "tool_pairing_ok" => true,
        "clean_assistant_messages" => 1
      },
      "presenter" => %{"clean_final_answer" => true},
      "evidence" => %{"session_id" => "20260622T000003-tool-final"}
    }
  end

  defp t4_warn_fixture do
    %{
      "scenario" => "T4",
      "pixir" => %{
        "subagent_timeouts" => [
          %{
            "subagent_id" => "sub_1",
            "child_session_id" => "20260622T000002-child",
            "agent" => "explorer",
            "status" => "timed_out",
            "reason" => "timeout",
            "timeout_ms" => 30_000,
            "elapsed_ms" => 30_050,
            "next_actions" => ["retry with a narrower task"],
            "missing_fields" => []
          }
        ]
      },
      "presenter" => %{"completed" => false},
      "evidence" => %{"session_id" => "20260622T000002-parent"}
    }
  end

  defp t5_pass_fixture do
    %{
      "scenario" => "T5",
      "pixir" => %{
        "workflow_status" => "partial",
        "checkpoint_statuses" => ["checkpoint_ready", "failed"]
      },
      "presenter" => %{"completed" => false},
      "evidence" => %{"session_id" => "20260622T000005-workflow-partial"}
    }
  end

  defp t6_pass_fixture do
    %{
      "scenario" => "T6",
      "acp" => %{
        "partial_loaded_as_clean" => false,
        "turn_failed_loaded_as_clean" => false
      },
      "evidence" => %{"session_id" => "20260622T000006-acp-load"}
    }
  end

  defp t7_pass_fixture do
    %{
      "scenario" => "T7",
      "replay" => %{
        "failure_events_in_provider_input" => false,
        "provider_prefix_changed_by_failure_evidence" => false
      },
      "evidence" => %{"session_id" => "20260622T000007-replay-cache"}
    }
  end

  defp t8_pass_fixture do
    %{
      "scenario" => "T8",
      "pixir" => %{"diagnostics_status" => "warn"},
      "presenter" => %{
        "visible" => true,
        "agrees_with_pixir" => true
      },
      "evidence" => %{"session_id" => "20260622T000008-client-parity"}
    }
  end

  defp t9_pass_fixture do
    %{
      "scenario" => "T9",
      "pixir" => %{
        "terminal_status" => "timed_out",
        "turn_failed_count" => 1,
        "error_kind" => "timeout"
      },
      "presenter" => %{
        "clean_final_answer" => false,
        "completed" => false
      },
      "evidence" => %{"session_id" => "20260622T000009-turn-timeout"}
    }
  end

  defp t10_pass_fixture do
    %{
      "scenario" => "T10",
      "pixir" => %{
        "subagent_terminal_states" => [
          %{
            "subagent_id" => "sub_1",
            "child_session_id" => "20260622T000010-child",
            "status" => "completed",
            "elapsed_ms" => 250,
            "summary" => "completed read-only audit"
          }
        ]
      },
      "evidence" => %{"session_id" => "20260622T000010-parent"}
    }
  end

  defp t11_pass_fixture do
    %{
      "scenario" => "T11",
      "pixir" => %{
        "workflow_status" => "completed",
        "checkpoint_statuses" => ["checkpoint_ready", "checkpoint_ready"]
      },
      "presenter" => %{"completed" => true},
      "evidence" => %{"session_id" => "20260622T000011-workflow-complete"}
    }
  end

  defp write_json!(path, value) do
    File.write!(path, Jason.encode!(value))
  end

  defp tmp_dir do
    path =
      Path.join(
        System.tmp_dir!(),
        "pixir-runtime-trust-gauntlet-test-#{System.unique_integer([:positive])}"
      )

    File.rm_rf!(path)
    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end
end
