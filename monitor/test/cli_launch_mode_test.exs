defmodule PixirMonitor.CliLaunchModeTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  test "help documents the default and explicit FIFO launch mode" do
    output = capture_io(fn -> assert {:ok, 0} = PixirMonitor.CLI.run(["--help"]) end)

    assert output =~ "--launch-mode darwin|fifo"
    assert output =~ "Default: darwin"
    assert output =~ "named-pipe support"
  end

  test "help documents the re-arm and the darwin re-entry mechanism" do
    output = capture_io(fn -> assert {:ok, 0} = PixirMonitor.CLI.run(["--help"]) end)

    assert output =~ "re-arm"
    assert output =~ "SIGUSR2"
    assert output =~ "launch_ready"
  end

  test "the dry-run plan describes re-arm and re-entry without creating launch material" do
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
    assert plan["launch_surface"]["rearm_limit"] > 0
    assert plan["launch_surface"]["degrades_instead_of_exiting"] == true
    assert plan["launch_surface"]["reentry"] == "SIGUSR2"
    refute output =~ "#launch="
    refute output =~ "launch.fifo"
  end

  test "the human dry-run echoes the re-arm bound and the re-entry signal" do
    workspace = temporary_workspace!()

    output =
      capture_io(fn ->
        assert {:ok, 0} =
                 PixirMonitor.CLI.run(["serve", "--workspace", workspace, "--launch-mode", "fifo", "--dry-run"])
      end)

    assert output =~ "launch mode: fifo"
    assert output =~ "re-arm limit:"
    assert output =~ "SIGUSR2"
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

  describe "serve treats the launch handoff as auxiliary" do
    setup do
      previous_launcher = Application.get_env(:pixir_monitor, :browser_launcher)
      previous_blocker = Application.get_env(:pixir_monitor, :serve_blocker)
      previous_port = Application.get_env(:pixir_monitor, :active_port)
      previous_platform = Application.get_env(:pixir_monitor, :launch_platform)

      previous_source = Application.get_env(:pixir_monitor, :projection_source)

      # The application is deliberately NOT stopped here: it is shared, ambient
      # test state, and stopping it takes PixirMonitor.Vault down for every
      # later test in the run. What MUST be undone is the launch surface `serve`
      # leaves running (it holds a real reader window and re-arms behind the
      # test) and the workspace `serve` installs into the shared app env.
      on_exit(fn ->
        stop_launch_surface()
        restore(:browser_launcher, previous_launcher)
        restore(:serve_blocker, previous_blocker)
        restore(:active_port, previous_port)
        restore(:launch_platform, previous_platform)
        restore(:projection_source, previous_source)
      end)

      # A bounded blocker replaces the production `Process.sleep(:infinity)` so
      # the serving state is observable as a return value in-process.
      Application.put_env(:pixir_monitor, :serve_blocker, fn -> {:ok, 0} end, persistent: false)

      # The application is started here rather than by `serve` so the discovered
      # port survives: `PixirMonitor.PortRegistry` clears stale port state at
      # init, and the test endpoint deliberately never listens (`server: false`).
      # `ensure_all_started` inside `serve` is then a no-op on the running app.
      {:ok, _apps} = Application.ensure_all_started(:pixir_monitor)
      :ok
    end

    test "a failing darwin launcher still reaches serving and reports the outcome" do
      workspace = temporary_workspace!()
      test_pid = self()

      Application.put_env(
        :pixir_monitor,
        :browser_launcher,
        fn url ->
          send(test_pid, {:launched, url})
          {:error, %{kind: "browser_open_failed", message: "The monitor could not open the browser", details: %{reason: ":launcher_timeout"}, next_actions: []}}
        end,
        persistent: false
      )

      # The test endpoint deliberately does not listen, so the discovered port is
      # installed directly; the launcher path under test is the same either way.
      Application.put_env(:pixir_monitor, :active_port, 45_941, persistent: false)
      Application.put_env(:pixir_monitor, :launch_platform, {:unix, :darwin}, persistent: false)

      output =
        capture_io(fn ->
          capture_io(:stderr, fn ->
            assert {:ok, 0} = PixirMonitor.CLI.run(["serve", "--workspace", workspace, "--json"])
          end)
        end)

      assert_receive {:launched, launch_url}, 5_000
      assert launch_url =~ "#launch="

      frame = Jason.decode!(output)
      assert frame["ok"] == true
      assert frame["status"] == "serving"
      assert frame["launch"]["launch_mode"] == "darwin"
      assert frame["launch"]["status"] == "failed"
      assert frame["launch"]["kind"] == "browser_open_failed"
      refute output =~ "#launch="
    end

    test "a succeeding darwin launcher reports a succeeded outcome on stdout" do
      workspace = temporary_workspace!()
      Application.put_env(:pixir_monitor, :browser_launcher, fn _url -> :ok end, persistent: false)
      Application.put_env(:pixir_monitor, :active_port, 45_942, persistent: false)
      Application.put_env(:pixir_monitor, :launch_platform, {:unix, :darwin}, persistent: false)

      output =
        capture_io(fn ->
          capture_io(:stderr, fn ->
            assert {:ok, 0} = PixirMonitor.CLI.run(["serve", "--workspace", workspace, "--json"])
          end)
        end)

      frame = Jason.decode!(output)
      assert frame["launch"]["status"] == "succeeded"
      refute output =~ "#launch="
    end

    test "a non-darwin platform reports unsupported_platform and keeps serving" do
      workspace = temporary_workspace!()
      test_pid = self()

      Application.put_env(:pixir_monitor, :launch_platform, {:unix, :linux}, persistent: false)
      Application.put_env(:pixir_monitor, :active_port, 45_943, persistent: false)

      Application.put_env(
        :pixir_monitor,
        :browser_launcher,
        fn _url -> send(test_pid, :launcher_must_not_run) end,
        persistent: false
      )

      output =
        capture_io(fn ->
          capture_io(:stderr, fn ->
            assert {:ok, 0} = PixirMonitor.CLI.run(["serve", "--workspace", workspace, "--json"])
          end)
        end)

      frame = Jason.decode!(output)
      assert frame["status"] == "serving"
      assert frame["launch"]["status"] == "not_attempted"
      assert frame["launch"]["kind"] == "unsupported_platform"
      refute_received :launcher_must_not_run
    end

    test "a fifo reader race degrades to serving instead of exiting 1" do
      workspace = temporary_workspace!()

      output =
        capture_io(fn ->
          capture_io(:stderr, fn ->
            assert {:ok, 0} =
                     PixirMonitor.CLI.run([
                       "serve",
                       "--workspace",
                       workspace,
                       "--launch-mode",
                       "fifo",
                       "--json"
                     ])
          end)
        end)

      frame = Jason.decode!(output)
      assert frame["status"] == "serving"
      assert frame["launch"]["launch_mode"] == "fifo"
      refute output =~ "#launch="
    end

    defp restore(key, nil), do: Application.delete_env(:pixir_monitor, key, persistent: false)
    defp restore(key, value), do: Application.put_env(:pixir_monitor, key, value, persistent: false)

    defp stop_launch_surface do
      case Process.whereis(PixirMonitor.LaunchSurface) do
        nil -> :ok
        surface -> PixirMonitor.LaunchSurface.stop(surface)
      end
    catch
      :exit, _reason -> :ok
    end
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
