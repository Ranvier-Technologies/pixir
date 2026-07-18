defmodule PixirMonitor.CLIWorkspaceTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias PixirMonitor.CLI

  setup do
    original = Application.get_env(:pixir_monitor, :projection_source)

    on_exit(fn ->
      if is_nil(original) do
        Application.delete_env(:pixir_monitor, :projection_source)
      else
        Application.put_env(:pixir_monitor, :projection_source, original)
      end
    end)

    :ok
  end

  defp tmp_dir!(label) do
    path = Path.join(System.tmp_dir!(), "pixir-monitor-#{label}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end

  defp dry_run_json(args) do
    {output, result} = run_io(fn -> CLI.run(["serve", "--dry-run", "--json" | args]) end)
    assert {:ok, 0} = result
    Jason.decode!(output)
  end

  defp dry_run_error(args) do
    output = capture_io(:stderr, fn -> assert {:error, 1} = CLI.run(["serve", "--dry-run", "--json" | args]) end)
    Jason.decode!(output)["error"]
  end

  defp run_io(fun) do
    parent = self()

    output =
      capture_io(fn ->
        send(parent, {:cli_result, fun.()})
      end)

    result =
      receive do
        {:cli_result, result} -> result
      after
        0 -> flunk("CLI did not return")
      end

    {output, result}
  end

  test "help documents --workspace and its precedence" do
    {output, {:ok, 0}} = run_io(fn -> CLI.run(["--help"]) end)
    assert output =~ "--workspace PATH"
    assert output =~ "serve [--workspace PATH] [--dry-run] [--json]"
    assert output =~ "current working directory of this serve invocation"
  end

  test "explicit --workspace wins and is exposed canonically in dry-run JSON" do
    workspace = tmp_dir!("explicit")
    File.mkdir_p!(Path.join(workspace, "nested"))
    noncanonical = Path.join([workspace, "nested", ".."])
    Application.put_env(:pixir_monitor, :projection_source, workspace: tmp_dir!("config"))

    plan = dry_run_json(["--workspace", noncanonical])
    assert plan["ok"] == true
    assert plan["workspace"]["path"] == Path.expand(workspace)
    refute plan["workspace"]["path"] == noncanonical
    assert plan["workspace"]["origin"] == "cli"
  end

  test "runtime config workspace beats invocation default when no CLI flag is given" do
    workspace = tmp_dir!("runtime-config")
    Application.put_env(:pixir_monitor, :projection_source, workspace: workspace)

    plan = dry_run_json([])
    assert plan["workspace"]["path"] == Path.expand(workspace)
    assert plan["workspace"]["origin"] == "runtime_config"
  end

  test "omission resolves to invocation-time File.cwd!/0" do
    Application.put_env(:pixir_monitor, :projection_source, max_logs: 512)

    plan = dry_run_json([])
    assert plan["workspace"]["path"] == File.cwd!()
    assert plan["workspace"]["origin"] == "invocation_cwd"
  end

  test "human dry-run output exposes the resolved workspace" do
    workspace = tmp_dir!("human")

    {output, {:ok, 0}} = run_io(fn -> CLI.run(["serve", "--dry-run", "--workspace", workspace]) end)
    assert output =~ "workspace: #{Path.expand(workspace)} (cli)"
  end

  test "missing workspace fails with a structured error and next action" do
    missing = Path.join(System.tmp_dir!(), "pixir-monitor-missing-#{System.unique_integer([:positive])}")

    error = dry_run_error(["--workspace", missing])
    assert error["kind"] == "workspace_missing"
    assert error["details"]["workspace"] == Path.expand(missing)
    assert error["details"]["origin"] == "cli"
    assert Enum.any?(error["next_actions"], &(&1 =~ "--workspace"))
  end

  test "non-directory workspace fails with a structured error" do
    parent = tmp_dir!("file-parent")
    file = Path.join(parent, "not-a-dir")
    File.write!(file, "x")

    error = dry_run_error(["--workspace", file])
    assert error["kind"] == "workspace_not_directory"
    assert error["details"]["workspace"] == file
  end

  test "unreadable workspace fails with a structured error" do
    workspace = tmp_dir!("unreadable")
    File.chmod!(workspace, 0o000)
    on_exit(fn -> File.chmod!(workspace, 0o700) end)

    case File.stat(workspace) do
      {:ok, %File.Stat{access: access}} when access in [:read, :read_write] ->
        # Running as a user that ignores permission bits (e.g. root); nothing to assert.
        :ok

      _ ->
        error = dry_run_error(["--workspace", workspace])
        assert error["kind"] == "workspace_unreadable"
        assert error["details"]["workspace"] == Path.expand(workspace)
    end
  end

  test "non-traversable workspace fails with a structured unreadable error" do
    workspace = tmp_dir!("non-traversable")
    File.chmod!(workspace, 0o400)
    on_exit(fn -> File.chmod!(workspace, 0o700) end)

    case File.ls(workspace) do
      {:ok, _entries} ->
        # Running as a user that ignores permission bits (e.g. root); nothing to assert.
        :ok

      {:error, _reason} ->
        assert {:error, %{kind: "workspace_unreadable"}} = CLI.resolve_workspace(workspace)
    end
  end

  test "serve with an invalid workspace fails structurally before any launch" do
    missing = Path.join(System.tmp_dir!(), "pixir-monitor-serve-missing-#{System.unique_integer([:positive])}")

    output = capture_io(:stderr, fn -> assert {:error, 1} = CLI.run(["serve", "--json", "--workspace", missing]) end)
    error = Jason.decode!(output)["error"]
    assert error["kind"] == "workspace_missing"
    assert error["details"]["origin"] == "cli"
  end

  test "build-time workspace baking is gone from config and application defaults" do
    config = File.read!(Path.expand("../config/config.exs", __DIR__))
    application = File.read!(Path.expand("../lib/pixir_monitor/application.ex", __DIR__))

    refute config =~ "workspace: File.cwd!()"
    refute application =~ "workspace: File.cwd!()"
  end

  test "two --workspace KEY=PATH declarations survive the REAL argv parse into workspace_set mode" do
    # Empirical-smoke regression: OptionParser :string kept only the last
    # occurrence, so the advertised two-declaration usage was rejected while
    # every test called resolve_workspace_config/1 directly. This test goes
    # through CLI.run with real argv (the seam the smoke run caught).
    alpha = tmp_dir!("alpha")
    beta = tmp_dir!("beta")

    plan = dry_run_json(["--workspace", "alpha=#{alpha}", "--workspace", "beta=#{beta}"])

    assert plan["ok"] == true
    assert plan["mode"] == "workspace_set"

    assert [%{"key" => "alpha", "origin" => "cli"}, %{"key" => "beta", "origin" => "cli"}] =
             Enum.map(plan["workspaces"], &Map.take(&1, ["key", "origin"]))
  end
end
