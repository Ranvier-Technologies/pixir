defmodule PixirMonitor.LaunchSurfaceTest do
  use ExUnit.Case, async: false

  alias PixirMonitor.LaunchSurface

  @moduledoc """
  Pins the degrade-and-re-arm launch surface (issue #437).

  A launch handoff is auxiliary: no handoff outcome may terminate serving. FIFO
  mode re-arms a fresh private directory after a reader race or a reader-window
  expiry, and darwin mode reports its launcher outcome and accepts operator-driven
  re-entry that mints a fresh one-use capability every time.
  """

  setup do
    unless Process.whereis(PixirMonitor.Vault), do: start_supervised!(PixirMonitor.Vault)

    previous_launcher = Application.get_env(:pixir_monitor, :browser_launcher)
    previous_port = Application.get_env(:pixir_monitor, :active_port)

    on_exit(fn ->
      restore(:browser_launcher, previous_launcher)
      restore(:active_port, previous_port)
    end)

    Application.put_env(:pixir_monitor, :active_port, 45_931, persistent: false)
    :ok
  end

  describe "fifo degrade and re-arm" do
    @tag :unix
    test "a reader attaching only after the first writer already failed still receives a URL" do
      require_fifo!()
      test_pid = self()

      {:ok, surface} =
        LaunchSurface.start_link(
          launch_mode: "fifo",
          port: 45_931,
          emit: &send(test_pid, {:frame, &1}),
          reader_timeout_ms: 300,
          rearm_limit: 4,
          issue_url: fn -> {:ok, "http://127.0.0.1:45931/#launch=" <> mint!()} end
        )

      first = assert_readiness!()
      # The observed race: the reader is multiple reader-windows late, so the
      # first armed writer is already gone by the time cat arrives.
      assert_receive {:frame, %{status: "launch_degraded", kind: "fifo_reader_timeout"}}, 5_000
      second = assert_readiness!()
      assert second != first

      assert read_fifo!(second) =~ "#launch="
      assert Process.alive?(surface)
    end

    test "a fifo_write_failed carrying a writer_exit reason degrades instead of terminating" do
      test_pid = self()

      {:ok, surface} =
        LaunchSurface.start_link(
          launch_mode: "fifo",
          port: 45_931,
          emit: &send(test_pid, {:frame, &1}),
          rearm_limit: 1,
          handoff: stub_handoff([{:error, write_failed({:writer_exit, 74})}]),
          issue_url: fn -> {:ok, "http://127.0.0.1:45931/#launch=" <> mint!()} end
        )

      assert_receive {:frame, %{status: "launch_degraded", kind: "fifo_write_failed"}}, 5_000
      assert Process.alive?(surface)
      assert LaunchSurface.await_quiescent(surface, 5_000) != :terminated
    end

    @tag :unix
    test "every re-arm announces a distinct fifo_path that exists as a FIFO when announced" do
      require_fifo!()
      test_pid = self()

      {:ok, _surface} =
        LaunchSurface.start_link(
          launch_mode: "fifo",
          port: 45_931,
          emit: &send(test_pid, {:frame, &1}),
          reader_timeout_ms: 60,
          rearm_limit: 3,
          issue_url: fn -> {:ok, "http://127.0.0.1:45931/#launch=" <> mint!()} end
        )

      paths =
        for _attempt <- 1..4 do
          path = assert_readiness!()
          assert {:ok, %File.Stat{type: :other}} = File.stat(path)
          path
        end

      assert length(Enum.uniq(paths)) == 4
    end

    @tag :unix
    test "each degrade emits exactly one bounded frame and no frame carries capability bytes" do
      require_fifo!()
      test_pid = self()

      {:ok, _surface} =
        LaunchSurface.start_link(
          launch_mode: "fifo",
          port: 45_931,
          emit: &send(test_pid, {:frame, &1}),
          reader_timeout_ms: 60,
          rearm_limit: 2,
          issue_url: fn -> {:ok, "http://127.0.0.1:45931/#launch=" <> mint!()} end
        )

      frames = drain_frames(2_500)

      degrades = Enum.filter(frames, &(&1[:status] == "launch_degraded"))
      assert length(degrades) == 3
      assert Enum.all?(degrades, &(&1[:kind] == "fifo_reader_timeout"))

      encoded = Jason.encode!(frames)
      refute encoded =~ "#launch="
      refute encoded =~ "launch="
    end

    @tag :unix
    test "abandoned private directories are removed and shutdown leaves none behind" do
      require_fifo!()
      test_pid = self()

      {:ok, surface} =
        LaunchSurface.start_link(
          launch_mode: "fifo",
          port: 45_931,
          emit: &send(test_pid, {:frame, &1}),
          reader_timeout_ms: 60,
          rearm_limit: 3,
          issue_url: fn -> {:ok, "http://127.0.0.1:45931/#launch=" <> mint!()} end
        )

      paths = for _attempt <- 1..4, do: assert_readiness!()
      directories = Enum.map(paths, &Path.dirname/1)

      assert eventually(fn -> Enum.count(directories, &File.exists?/1) <= 1 end)

      LaunchSurface.stop(surface)
      assert eventually(fn -> Enum.all?(directories, &(not File.exists?(&1))) end)
    end

    @tag :unix
    test "shutdown reaps the armed OS writer instead of leaving it blocked on the pipe" do
      require_fifo!()
      test_pid = self()

      # The writer blocks in `sysopen` before it reads stdin, so closing the Port
      # gives it no EOF: without an explicit reap it outlives the surface holding
      # a pipe nobody will read, until its own 65-second watchdog fires.
      {:ok, surface} =
        LaunchSurface.start_link(
          launch_mode: "fifo",
          port: 45_931,
          emit: &send(test_pid, {:frame, &1}),
          reader_timeout_ms: 60_000,
          rearm_limit: 1,
          issue_url: fn -> {:ok, "http://127.0.0.1:45931/#launch=" <> mint!()} end
        )

      fifo = assert_readiness!()
      assert eventually(fn -> writers_holding(fifo) > 0 end)

      LaunchSurface.stop(surface)
      assert eventually(fn -> writers_holding(fifo) == 0 end)
    end

    @tag :unix
    test "two successive readers each obtain a distinct one-use URL from one surface" do
      require_fifo!()
      test_pid = self()

      {:ok, surface} =
        LaunchSurface.start_link(
          launch_mode: "fifo",
          port: 45_931,
          emit: &send(test_pid, {:frame, &1}),
          reader_timeout_ms: 5_000,
          rearm_limit: 4
        )

      first = read_fifo!(assert_readiness!())
      second = read_fifo!(assert_readiness!())

      assert first != second
      assert Process.alive?(surface)

      for url <- [first, second] do
        capability = capability_of(url)
        assert {:ok, _session} = PixirMonitor.Vault.consume_launch(capability)
        assert {:error, :invalid_or_expired} = PixirMonitor.Vault.consume_launch(capability)
      end
    end

    test "the re-arm bound is explicit: exhaustion emits a terminal frame and keeps serving" do
      test_pid = self()

      {:ok, surface} =
        LaunchSurface.start_link(
          launch_mode: "fifo",
          port: 45_931,
          emit: &send(test_pid, {:frame, &1}),
          rearm_limit: 2,
          handoff: stub_handoff(List.duplicate({:error, write_failed({:writer_exit, 74})}, 4)),
          issue_url: fn -> {:ok, "http://127.0.0.1:45931/#launch=" <> mint!()} end
        )

      assert_receive {:frame, %{status: "launch_surface_exhausted", rearm_limit: 2}}, 5_000
      assert Process.alive?(surface)
      assert LaunchSurface.await_quiescent(surface, 5_000) == :exhausted
    end

    test "an unclassified handoff error still emits the terminal frame and bounds its reason" do
      test_pid = self()

      # An unclassified error stops re-arming. README documents exactly two ways
      # a supervisor learns the surface stopped, so this path must emit the
      # terminal frame too — otherwise a supervisor keyed on `launch_ready` or
      # `launch_surface_exhausted` waits forever. The reason is also a bounded
      # inspect of an arbitrary term, so it must not carry the capability.
      leaky = String.duplicate("abcdefghij", 40)

      {:ok, surface} =
        LaunchSurface.start_link(
          launch_mode: "fifo",
          port: 45_931,
          emit: &send(test_pid, {:frame, &1}),
          rearm_limit: 8,
          handoff: stub_handoff([{:error, {:totally_unclassified, leaky}}]),
          issue_url: fn -> {:ok, "http://127.0.0.1:45931/#launch=" <> mint!()} end
        )

      assert_receive {:frame, %{status: "launch_degraded", kind: "launch_handoff_failed"} = degraded}, 5_000
      assert_receive {:frame, %{status: "launch_surface_exhausted", kind: "launch_handoff_failed"}}, 5_000

      # The bound is the contract: the whole term never reaches the frame.
      assert String.length(degraded.details.reason) < String.length(leaky)
      assert LaunchSurface.await_quiescent(surface, 5_000) == :exhausted
      assert Process.alive?(surface)

      LaunchSurface.stop(surface)
    end

    test "a launch_limit refusal is reported structurally and the surface keeps serving" do
      test_pid = self()

      {:ok, surface} =
        LaunchSurface.start_link(
          launch_mode: "fifo",
          port: 45_931,
          emit: &send(test_pid, {:frame, &1}),
          rearm_limit: 1,
          handoff:
            stub_handoff([
              {:error,
               %{
                 kind: "launch_issue_failed",
                 message: "The one-use launch capability could not be issued",
                 details: %{source_kind: "launch_limit"},
                 next_actions: []
               }}
            ]),
          issue_url: fn -> {:error, %{kind: "launch_limit", message: "Launch capability limit reached", details: %{limit: 256}}} end
        )

      assert_receive {:frame, %{status: "launch_degraded", kind: "launch_issue_failed"} = frame}, 5_000
      assert frame[:details][:source_kind] == "launch_limit"
      assert Process.alive?(surface)
    end
  end

  describe "darwin outcome and re-entry" do
    test "a launcher failure is reported as the launch outcome without terminating" do
      test_pid = self()

      Application.put_env(
        :pixir_monitor,
        :browser_launcher,
        fn _url -> {:error, %{kind: "browser_open_failed", message: "The monitor could not open the browser", details: %{reason: ":launcher_timeout"}, next_actions: []}} end,
        persistent: false
      )

      {:ok, surface} =
        LaunchSurface.start_link(launch_mode: "darwin", port: 45_931, platform: {:unix, :darwin}, emit: &send(test_pid, {:frame, &1}))

      assert %{status: "failed", kind: "browser_open_failed"} = LaunchSurface.outcome(surface, 5_000)
      assert Process.alive?(surface)
    end

    test "a successful launcher reports a succeeded outcome" do
      test_pid = self()
      Application.put_env(:pixir_monitor, :browser_launcher, fn _url -> :ok end, persistent: false)

      {:ok, surface} =
        LaunchSurface.start_link(launch_mode: "darwin", port: 45_931, platform: {:unix, :darwin}, emit: &send(test_pid, {:frame, &1}))

      assert %{status: "succeeded"} = LaunchSurface.outcome(surface, 5_000)
    end

    test "an unsupported platform is an outcome, never a fatal error" do
      test_pid = self()

      {:ok, surface} =
        LaunchSurface.start_link(
          launch_mode: "darwin",
          port: 45_931,
          platform: {:unix, :linux},
          emit: &send(test_pid, {:frame, &1})
        )

      assert %{status: "not_attempted", kind: "unsupported_platform"} = LaunchSurface.outcome(surface, 5_000)
      assert Process.alive?(surface)
    end

    test "re-entry mints a fresh distinct capability and hands it to the launcher without restart" do
      test_pid = self()

      Application.put_env(
        :pixir_monitor,
        :browser_launcher,
        fn url ->
          send(test_pid, {:launched, url})
          :ok
        end,
        persistent: false
      )

      {:ok, surface} =
        LaunchSurface.start_link(launch_mode: "darwin", port: 45_931, platform: {:unix, :darwin}, emit: &send(test_pid, {:frame, &1}))

      assert_receive {:launched, first}, 5_000
      assert %{status: "succeeded"} = LaunchSurface.reenter(surface, 5_000)
      assert_receive {:launched, second}, 5_000
      assert %{status: "succeeded"} = LaunchSurface.reenter(surface, 5_000)
      assert_receive {:launched, third}, 5_000

      assert Process.alive?(surface)
      capabilities = Enum.map([first, second, third], &capability_of/1)
      assert length(Enum.uniq(capabilities)) == 3

      for capability <- capabilities do
        assert {:ok, _session} = PixirMonitor.Vault.consume_launch(capability)
        assert {:error, :invalid_or_expired} = PixirMonitor.Vault.consume_launch(capability)
      end

      frames = drain_frames(200)
      encoded = Jason.encode!(frames)
      refute encoded =~ "#launch="
      refute encoded =~ "launch="
    end

    @tag :unix
    test "the installed SIGUSR2 trap is the re-entry mechanism and mints a fresh capability" do
      require_fifo!()
      test_pid = self()

      Application.put_env(
        :pixir_monitor,
        :browser_launcher,
        fn url ->
          send(test_pid, {:launched, url})
          :ok
        end,
        persistent: false
      )

      {:ok, surface} =
        LaunchSurface.start_link(
          launch_mode: "darwin",
          port: 45_931,
          platform: {:unix, :darwin},
          install_reentry_trap: true,
          emit: &send(test_pid, {:frame, &1})
        )

      assert_receive {:launched, first}, 5_000

      # Through `sh -c` rather than System.find_executable("kill"): on a host
      # where kill exists only as a shell builtin the lookup returns nil and
      # System.cmd/3 raises, failing this pin for a reason unrelated to re-entry.
      {_output, 0} = System.cmd("sh", ["-c", "kill -USR2 #{:os.getpid() |> List.to_string()}"], stderr_to_stdout: true)

      assert_receive {:launched, second}, 5_000
      assert capability_of(first) != capability_of(second)
      assert Process.alive?(surface)

      LaunchSurface.stop(surface)
    end

    test "a launcher that raises with the capability URL never leaks it into diagnostics" do
      test_pid = self()

      # The launcher receives the real capability URL and raises with it in the
      # message — exactly the shape that Exception.message/1 would leak.
      Application.put_env(
        :pixir_monitor,
        :browser_launcher,
        fn url -> raise "spawn failed for #{url}" end,
        persistent: false
      )

      {:ok, surface} =
        LaunchSurface.start_link(launch_mode: "darwin", port: 45_931, platform: {:unix, :darwin}, emit: &send(test_pid, {:frame, &1}))

      outcome = LaunchSurface.outcome(surface, 5_000)
      assert outcome.status == "failed"
      assert outcome.kind == "browser_open_failed"
      assert outcome.details.reason == ":launcher_raised"

      frames = drain_frames(200)
      assert Enum.any?(frames, &(&1[:kind] == "browser_open_failed"))
      encoded = inspect({outcome, frames})
      refute encoded =~ "launch="
      refute encoded =~ "127.0.0.1"
      refute encoded =~ "spawn failed"
    end

    test "a launcher returning outside its contract is a fixed-atom failure, never an inspected term" do
      test_pid = self()

      Application.put_env(
        :pixir_monitor,
        :browser_launcher,
        fn url -> {:surprise, url} end,
        persistent: false
      )

      {:ok, surface} =
        LaunchSurface.start_link(launch_mode: "darwin", port: 45_931, platform: {:unix, :darwin}, emit: &send(test_pid, {:frame, &1}))

      outcome = LaunchSurface.outcome(surface, 5_000)
      assert outcome.status == "failed"
      assert outcome.details.reason == ":launcher_contract_violation"
      refute inspect(outcome) =~ "launch="
    end

    test "a launcher returning its own error map never carries the capability into a frame" do
      test_pid = self()

      # The launcher is arbitrary injected code that RECEIVES the capability. An
      # error map it returns is already `:kind`-shaped, so normalize/1 would pass
      # it through verbatim: the capability must be stripped at this boundary,
      # not trusted to the callback.
      Application.put_env(
        :pixir_monitor,
        :browser_launcher,
        fn url ->
          {:error, %{kind: "browser_open_failed", message: "failed opening #{url}", details: %{url: url}, next_actions: []}}
        end,
        persistent: false
      )

      {:ok, surface} =
        LaunchSurface.start_link(launch_mode: "darwin", port: 45_931, platform: {:unix, :darwin}, emit: &send(test_pid, {:frame, &1}))

      outcome = LaunchSurface.outcome(surface, 5_000)
      assert outcome.status == "failed"
      assert outcome.kind == "browser_open_failed"
      assert outcome.details.reason == ":launcher_reported_failure"

      encoded = inspect({outcome, drain_frames(200)})
      refute encoded =~ "launch="
      refute encoded =~ "127.0.0.1"
      refute encoded =~ "failed opening"

      LaunchSurface.stop(surface)
    end

    test "an already-elapsed TTL capability is refused without waiting on the wall clock" do
      assert {:ok, expired} = PixirMonitor.Vault.issue_launch_for_test(0)
      assert {:error, :invalid_or_expired} = PixirMonitor.Vault.consume_launch(expired)
    end
  end

  defp assert_readiness! do
    assert_receive {:frame, %{status: "launch_ready", launch_mode: "fifo", fifo_path: path}}, 5_000
    path
  end

  defp drain_frames(window_ms), do: drain_frames(window_ms, [])

  defp drain_frames(window_ms, acc) do
    receive do
      {:frame, frame} -> drain_frames(window_ms, [frame | acc])
    after
      window_ms -> Enum.reverse(acc)
    end
  end

  defp stub_handoff(results) do
    {:ok, agent} = Agent.start_link(fn -> results end)

    fn _prepared, issue_url, _opts ->
      _ = issue_url.()

      Agent.get_and_update(agent, fn
        [] -> {{:error, write_failed(:exhausted_stub)}, []}
        [head | tail] -> {head, tail}
      end)
    end
  end

  defp write_failed(reason) do
    %{
      kind: "fifo_write_failed",
      message: "The launch handoff could not be written to the connected FIFO",
      details: %{reason: inspect(reason)},
      next_actions: []
    }
  end

  defp mint! do
    {:ok, capability} = PixirMonitor.Vault.issue_launch()
    capability
  end

  defp capability_of(url) do
    url |> String.trim() |> URI.parse() |> Map.fetch!(:fragment) |> String.replace_prefix("launch=", "")
  end

  defp read_fifo!(path) do
    cat = System.find_executable("cat")
    {bytes, 0} = System.cmd(cat, [path], stderr_to_stdout: true)
    String.trim(bytes)
  end

  defp require_fifo! do
    unless match?({:unix, _}, :os.type()) and is_binary(System.find_executable("mkfifo")) and
             is_binary(System.find_executable("cat")) do
      flunk("this pin requires a unix host with mkfifo and cat")
    end
  end

  # Counts the OS processes still holding this exact FIFO path. `ps` rather than
  # `lsof`: the writer carries the path in its argv, and lsof is not universally
  # installed on CI runners.
  defp writers_holding(fifo) do
    case System.cmd("sh", ["-c", "ps -eo command | grep -F -- '#{fifo}' | grep -c '[s]ysopen'"], stderr_to_stdout: true) do
      {output, _status} -> output |> String.trim() |> Integer.parse() |> then(fn {n, _} -> n end)
    end
  rescue
    _error -> 0
  end

  defp restore(key, nil), do: Application.delete_env(:pixir_monitor, key, persistent: false)
  defp restore(key, value), do: Application.put_env(:pixir_monitor, key, value, persistent: false)

  defp eventually(predicate, attempts \\ 200)

  defp eventually(predicate, attempts) when attempts > 0 do
    if predicate.() do
      true
    else
      Process.sleep(25)
      eventually(predicate, attempts - 1)
    end
  end

  defp eventually(_predicate, 0), do: false
end
