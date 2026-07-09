defmodule Pixir.DoctorTest do
  use ExUnit.Case, async: true

  alias Pixir.Doctor

  test "reports source-install readiness with auth warning and next actions" do
    workspace = tmp_dir("doctor-ready")
    binary = Path.join(workspace, "pixir")
    File.write!(binary, "#!/bin/sh\n")
    File.chmod!(binary, 0o755)

    result =
      Doctor.run(
        workspace: workspace,
        binary_path: binary,
        config_path: Path.join(workspace, "missing-config.json"),
        auth_status: %{authenticated?: false, kind: nil},
        model: "gpt-5.5"
      )

    assert result["ok"] == true
    assert result["status"] == "ready_with_warnings"
    assert check(result, "source_install_binary")["status"] == "passed"
    assert check(result, "workspace")["status"] == "passed"
    assert check(result, "auth")["status"] == "warning"
    assert Enum.any?(result["next_actions"], &String.contains?(&1, "pixir login"))
  end

  test "fails workspace readiness when session logs cannot be written" do
    workspace = tmp_dir("doctor-blocked-sessions")
    File.write!(Path.join(workspace, ".pixir"), "block sessions dir creation")

    result =
      Doctor.run(
        workspace: workspace,
        binary_path: Path.join(workspace, "missing-pixir"),
        config_path: Path.join(workspace, "missing-config.json"),
        auth_status: %{authenticated?: true, kind: :api_key},
        model: "gpt-5.5"
      )

    workspace_check = check(result, "workspace")

    assert result["ok"] == false
    assert workspace_check["status"] == "failed"
    assert workspace_check["details"]["kind"] == "workspace_not_writable"
  end

  test "doctor --json reports effective config and warnings for invalid fields" do
    workspace = tmp_dir("doctor-config-effective")
    config_path = Path.join(workspace, "config.json")

    File.write!(
      config_path,
      Jason.encode!(%{
        "permission_default" => "ask",
        "reasoning" => %{"effort" => "nope"},
        "bash_timeout_ms" => 60_000,
        "bash_timeout_max_ms" => 240_000
      })
    )

    result =
      Doctor.run(
        workspace: workspace,
        binary_path: Path.join(workspace, "missing-pixir"),
        config_path: config_path,
        auth_status: %{authenticated?: true, kind: :api_key},
        model: "gpt-5.5"
      )

    assert result["config_effective"]["permission_default"] == "ask"
    assert result["config_effective"]["bash_timeout_ms"] == 60_000
    assert result["config_effective"]["bash_timeout_max_ms"] == 240_000
    assert Enum.any?(result["config_warnings"], &(&1["field"] == "reasoning.effort"))

    config_check = check(result, "config")
    assert config_check["status"] == "warning"
    assert config_check["details"]["effective"]["permission_default"] == "ask"
  end

  test "invalid config json blocks readiness with structured details" do
    workspace = tmp_dir("doctor-invalid-config")
    config_path = Path.join(workspace, "config.json")
    File.write!(config_path, "{not-json")

    result =
      Doctor.run(
        workspace: workspace,
        binary_path: Path.join(workspace, "missing-pixir"),
        config_path: config_path,
        auth_status: %{authenticated?: true, kind: :api_key},
        model: "gpt-5.5"
      )

    assert result["ok"] == false
    assert result["status"] == "blocked"

    config = check(result, "config")
    assert config["status"] == "failed"
    assert config["details"]["path"] == config_path
    assert Enum.any?(result["next_actions"], &String.contains?(&1, "remove the file"))
  end

  test "render produces compact human-readable output" do
    workspace = tmp_dir("doctor-render")

    output =
      Doctor.run(
        workspace: workspace,
        binary_path: Path.join(workspace, "missing-pixir"),
        config_path: Path.join(workspace, "missing-config.json"),
        auth_status: %{authenticated?: false, kind: nil},
        model: "gpt-5.5"
      )
      |> Doctor.render()

    assert output =~ "Pixir doctor"
    assert output =~ "status:"
    assert output =~ "Next actions:"
  end

  test "anthropic auth warning names api key env and retention note" do
    workspace = tmp_dir("doctor-anthropic-missing-auth")

    result =
      Doctor.run(
        workspace: workspace,
        binary_path: Path.join(workspace, "missing-pixir"),
        config_path: Path.join(workspace, "missing-config.json"),
        model: "claude-fable-5",
        env: fn "ANTHROPIC_API_KEY" -> nil end
      )

    auth = check(result, "auth")

    assert auth["status"] == "warning"
    assert auth["details"]["next_actions"] == ["set ANTHROPIC_API_KEY"]
    refute Jason.encode!(auth) =~ "pixir login"

    assert Enum.any?(
             auth["details"]["notes"],
             &String.contains?(&1, "30-day organization data retention")
           )
  end

  test "anthropic auth passed reports env var and retention note" do
    workspace = tmp_dir("doctor-anthropic-auth")

    result =
      Doctor.run(
        workspace: workspace,
        binary_path: Path.join(workspace, "missing-pixir"),
        config_path: Path.join(workspace, "missing-config.json"),
        model: "claude-fable-5",
        env: fn "ANTHROPIC_API_KEY" -> "test-key" end
      )

    auth = check(result, "auth")

    assert auth["status"] == "passed"
    assert auth["details"]["env_var"] == "ANTHROPIC_API_KEY"

    assert Enum.any?(
             auth["details"]["notes"],
             &String.contains?(&1, "30-day organization data retention")
           )
  end

  test "retention note rides only Covered Models, not every claude id" do
    workspace = tmp_dir("doctor-anthropic-haiku")

    result =
      Doctor.run(
        workspace: workspace,
        binary_path: Path.join(workspace, "missing-pixir"),
        config_path: Path.join(workspace, "missing-config.json"),
        model: "claude-haiku-4-5-20251001",
        env: fn "ANTHROPIC_API_KEY" -> "test-key" end
      )

    auth = check(result, "auth")

    assert auth["status"] == "passed"
    assert auth["details"]["provider"] == "anthropic"
    refute Map.has_key?(auth["details"], "notes")
  end

  test "config check reports resolved provider label" do
    workspace = tmp_dir("doctor-provider-label")
    config_path = Path.join(workspace, "config.json")

    File.write!(config_path, Jason.encode!(%{"model" => "claude-fable-5"}))

    openai_result =
      Doctor.run(
        workspace: workspace,
        binary_path: Path.join(workspace, "missing-pixir"),
        config_path: Path.join(workspace, "missing-config.json"),
        auth_status: %{authenticated?: true, kind: :api_key}
      )

    anthropic_result =
      Doctor.run(
        workspace: workspace,
        binary_path: Path.join(workspace, "missing-pixir"),
        config_path: config_path,
        env: fn "ANTHROPIC_API_KEY" -> "test-key" end
      )

    assert check(openai_result, "config")["details"]["provider"] == "openai"
    assert check(anthropic_result, "config")["details"]["provider"] == "anthropic"
  end

  defp check(result, id), do: Enum.find(result["checks"], &(&1["id"] == id))

  defp tmp_dir(name) do
    dir = Path.join(System.tmp_dir!(), "pixir-#{name}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    dir
  end
end
