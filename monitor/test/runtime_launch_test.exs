defmodule PixirMonitor.RuntimeLaunchTest do
  use ExUnit.Case, async: true

  @capability_url "http://127.0.0.1:4321/#launch=SECRET-CAPABILITY-BYTES"
  @launch_url_env "PIXIR_MONITOR_LAUNCH_URL"

  describe "darwin_launch_command/1" do
    test "keeps capability bytes out of argv and carries them only in the environment" do
      {executable, args, env} = PixirMonitor.Runtime.darwin_launch_command(@capability_url)

      assert executable == "/usr/bin/osascript"
      assert ["-e", script] = args
      assert script == ~s|open location (system attribute "#{@launch_url_env}")|
      refute String.contains?(executable, "SECRET-CAPABILITY-BYTES")
      refute Enum.any?(args, &String.contains?(&1, "SECRET-CAPABILITY-BYTES"))
      assert env == [{@launch_url_env, @capability_url}]
    end

    test "the environment handoff delivers the exact URL to the spawned launcher" do
      {_executable, _args, env} = PixirMonitor.Runtime.darwin_launch_command(@capability_url)

      probe = ~s(test "$#{@launch_url_env}" = "$EXPECTED_LAUNCH_URL")

      assert :ok =
               PixirMonitor.Runtime.run_launcher_bounded(
                 "/bin/sh",
                 ["-c", probe],
                 env ++ [{"EXPECTED_LAUNCH_URL", @capability_url}],
                 5_000
               )
    end
  end

  describe "run_launcher_bounded/4" do
    test "returns ok when the launcher exits zero" do
      assert :ok = PixirMonitor.Runtime.run_launcher_bounded("/bin/sh", ["-c", "exit 0"], [], 5_000)
    end

    test "reports a nonzero exit as a structured browser failure without echoing launcher output" do
      assert {:error, error} =
               PixirMonitor.Runtime.run_launcher_bounded(
                 "/bin/sh",
                 ["-c", "echo LEAKED-LAUNCHER-OUTPUT; exit 3"],
                 [],
                 5_000
               )

      assert error.kind == "browser_open_failed"
      assert error.details.reason =~ "launcher_exit_status"
      assert error.details.reason =~ "3"
      refute inspect(error) =~ "LEAKED-LAUNCHER-OUTPUT"
    end

    test "a hung launcher is bounded by the timeout AND its OS process is reaped" do
      marker = "pixir-launch-reap-#{System.unique_integer([:positive])}"

      assert {:error, error} =
               PixirMonitor.Runtime.run_launcher_bounded(require_perl!(), ["-e", "sleep 30", marker], [], 100)

      assert error.kind == "browser_open_failed"
      assert error.details.reason =~ "launcher_timeout"
      assert launcher_reaped?(marker)
    end

    test "a chatty launcher cannot slide the deadline past the bound and is reaped" do
      marker = "pixir-launch-chatty-#{System.unique_integer([:positive])}"
      chatty = "$| = 1; while (1) { print \"tick\\n\"; select undef, undef, undef, 0.05 }"
      timeout_ms = 300
      started = System.monotonic_time(:millisecond)

      assert {:error, error} =
               PixirMonitor.Runtime.run_launcher_bounded(require_perl!(), ["-e", chatty, marker], [], timeout_ms)

      elapsed = System.monotonic_time(:millisecond) - started
      assert error.details.reason =~ "launcher_timeout"
      refute error.details.reason =~ "tick"
      assert elapsed < timeout_ms * 5
      assert launcher_reaped?(marker)
    end

    test "an output-flooding launcher cannot starve the deadline and is reaped" do
      # No sleep between writes: the mailbox is kept nonempty on purpose, so this
      # only passes because the deadline is checked BEFORE each receive.
      marker = "pixir-launch-flood-#{System.unique_integer([:positive])}"
      flood = "$| = 1; while (1) { print \"flood\\n\" }"
      timeout_ms = 300
      started = System.monotonic_time(:millisecond)

      assert {:error, error} =
               PixirMonitor.Runtime.run_launcher_bounded(require_perl!(), ["-e", flood, marker], [], timeout_ms)

      elapsed = System.monotonic_time(:millisecond) - started
      assert error.details.reason =~ "launcher_timeout"
      refute error.details.reason =~ "flood"
      assert elapsed < timeout_ms * 5
      assert launcher_reaped?(marker)
    end

    test "a missing launcher executable fails structurally instead of crashing" do
      assert {:error, error} =
               PixirMonitor.Runtime.run_launcher_bounded(
                 "/nonexistent/pixir-monitor-launcher",
                 [],
                 [],
                 5_000
               )

      assert error.kind == "browser_open_failed"
      assert error.details.reason =~ "launcher_spawn_failed"
    end

    test "the exact production command shape terminates on its own (the #386 hang class)" do
      if match?({:unix, :darwin}, :os.type()) and File.exists?("/usr/bin/osascript") do
        # The real darwin_launch_command argv and env mechanism, with a URL whose
        # scheme has no handler: `open location` fails fast (probed: exit 1 in
        # ~0.07s) instead of opening a browser, so the pin exercises the
        # production script + env handoff + termination without side effects and
        # must observe that concrete failure, not merely "returned something".
        {executable, args, env} =
          PixirMonitor.Runtime.darwin_launch_command("pixir-monitor-test-no-such-scheme://probe")

        assert {:error, error} =
                 PixirMonitor.Runtime.run_launcher_bounded(executable, args, env, 5_000)

        assert error.details.reason =~ "launcher_exit_status"
      else
        assert true
      end
    end
  end

  # The reap pins are load-bearing: on a unix host without perl they must fail
  # loudly instead of passing vacuously.
  defp require_perl! do
    case System.find_executable("perl") do
      path when is_binary(path) -> path
      nil -> flunk("perl is required for the launcher reap pins on unix hosts")
    end
  end

  defp launcher_reaped?(marker) do
    Enum.reduce_while(1..20, false, fn _attempt, _acc ->
      {processes, 0} = System.cmd("/bin/ps", ["ax", "-o", "command"], stderr_to_stdout: true)

      if processes =~ marker do
        Process.sleep(50)
        {:cont, false}
      else
        {:halt, true}
      end
    end)
  end
end
