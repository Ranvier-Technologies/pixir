defmodule PixirMonitor.CliLaunchModeTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  test "help documents the default and explicit FIFO launch mode" do
    output = capture_io(fn -> assert {:ok, 0} = PixirMonitor.CLI.run(["--help"]) end)

    assert output =~ "--launch-mode darwin|fifo"
    assert output =~ "Default: darwin"
    assert output =~ "named-pipe support"
  end

  test "JSON dry-run echoes FIFO mode without creating or issuing launch material" do
    workspace = temporary_workspace!()

    output =
      capture_io(fn ->
        assert {:ok, 0} =
                 PixirMonitor.CLI.run([
                   "serve",
                   "--workspace",
                   workspace,
                   "--launch-mode",
                   "fifo",
                   "--dry-run",
                   "--json"
                 ])
      end)

    plan = Jason.decode!(output)
    assert plan["launch_mode"] == "fifo"
    assert plan["dry_run"] == true
    refute output =~ "#launch="
    refute output =~ "launch.fifo"
  end

  test "dry-run defaults to the unchanged Darwin mode" do
    workspace = temporary_workspace!()

    output =
      capture_io(fn ->
        assert {:ok, 0} =
                 PixirMonitor.CLI.run([
                   "serve",
                   "--workspace",
                   workspace,
                   "--dry-run",
                   "--json"
                 ])
      end)

    assert Jason.decode!(output)["launch_mode"] == "darwin"
  end

  test "unsupported launch mode is a structured JSON error" do
    stderr =
      capture_io(:stderr, fn ->
        assert {:error, 1} =
                 PixirMonitor.CLI.run(["serve", "--launch-mode", "socket", "--json"])
      end)

    decoded = Jason.decode!(stderr)
    assert decoded["error"]["kind"] == "unsupported_launch_mode"
    assert is_map(decoded["error"]["details"])
    assert is_list(decoded["error"]["next_actions"])
  end

  defp temporary_workspace! do
    path =
      Path.join(
        System.tmp_dir!(),
        "pixir-monitor-cli-mode-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf(path) end)
    path
  end
end
