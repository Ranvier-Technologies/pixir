defmodule PixirMonitor.FoundationTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO

  defmodule SelfCheckStub do
    def run do
      {:ok,
       %{
         ok: true,
         check: "pixir_monitor_loopback",
         listener: "127.0.0.1",
         bootstrap: "one_use_accepted",
         assets: ["app.js", "app.css"],
         runs_schema: "pixir.monitor.runs",
         runs_schema_version: 1
       }}
    end
  end

  test "Mix boundary pins standalone app and exact direct dependency set" do
    source = File.read!(Path.expand("../mix.exs", __DIR__))
    assert source =~ "app: :pixir_monitor"
    assert source =~ "escript: [main_module: PixirMonitor.CLI, name: \"pixir-monitor\", app: nil]"
    assert source =~ "elixir: \"~> 1.20\""
    assert source =~ "{:pixir, path: \"..\"}"

    for dependency <- ["phoenix, \"== 1.8.9\"", "bandit, \"== 1.12.0\"", "jason, \"== 1.4.5\"", "jsv, \"== 0.20.0\""] do
      assert source =~ dependency
    end

    refute source =~ "live_view"
    refute source =~ "phoenix_live_view"
  end

  test "endpoint is literal IPv4 loopback and ephemeral" do
    config = Application.get_env(:pixir_monitor, PixirMonitor.Endpoint)
    assert config[:http][:ip] == {127, 0, 0, 1}
    assert config[:http][:port] == 0

    previous = Application.get_env(:pixir_monitor, :active_port)

    on_exit(fn ->
      if previous do
        Application.put_env(:pixir_monitor, :active_port, previous, persistent: false)
      else
        Application.delete_env(:pixir_monitor, :active_port, persistent: false)
      end
    end)

    Application.put_env(:pixir_monitor, :active_port, 45_555, persistent: false)
    assert PixirMonitor.PortRegistry.active_port() == {:ok, 45_555}
  end

  test "empty RunSource carries no presenter store" do
    assert PixirMonitor.RunSource.Empty.list_runs() == {:ok, []}
    assert {:error, %{kind: "run_not_found"}} = PixirMonitor.RunSource.Empty.fetch_run("anything")
    refute Process.whereis(PixirMonitor.RunSource.Empty)
  end

  test "invalidation hub coalesces to one pending non-normative message" do
    assert {:ok, _} = PixirMonitor.InvalidationHub.subscribe()
    assert :ok = PixirMonitor.InvalidationHub.projection_changed("projection:one")
    assert :ok = PixirMonitor.InvalidationHub.projection_changed("projection:two")
    assert :ok = PixirMonitor.InvalidationHub.projection_changed("projection:three")
    assert_receive {:projection_changed, first, nil, "projection:one"}
    refute_receive {:projection_changed, _, _, _}, 20

    PixirMonitor.InvalidationHub.ack()
    assert_receive {:projection_changed, latest, nil, "projection:three"}
    assert latest == first + 2
    refute_receive {:projection_changed, _, _, _}, 20

    frame = PixirMonitor.InvalidationHub.frame(latest, "projection:three")
    assert frame =~ "event: projection_changed"
    assert frame =~ "\"projection_id\":\"projection:three\""
    refute frame =~ "execution"
    refute frame =~ "gate"
    refute frame =~ "advisory"

    max_id = String.duplicate("x", 235)
    assert :ok = PixirMonitor.InvalidationHub.projection_changed(max_id)
    PixirMonitor.InvalidationHub.ack()
    assert_receive {:projection_changed, bounded, nil, ^max_id}
    assert bounded == latest + 1

    assert {:error, %{kind: "invalid_projection_id", details: %{max_bytes: 235}}} =
             PixirMonitor.InvalidationHub.projection_changed(String.duplicate("x", 236))

    PixirMonitor.InvalidationHub.unsubscribe()
  end

  test "duplicate invalidation subscription preserves coalescing and unsubscribe cleans up" do
    on_exit(fn -> PixirMonitor.InvalidationHub.unsubscribe() end)

    assert {:ok, initial_sequence} = PixirMonitor.InvalidationHub.subscribe()
    assert :ok = PixirMonitor.InvalidationHub.projection_changed("projection:first")
    assert :ok = PixirMonitor.InvalidationHub.projection_changed("projection:latest")
    assert {:ok, current_sequence} = PixirMonitor.InvalidationHub.subscribe()
    assert current_sequence == initial_sequence + 2

    assert_receive {:projection_changed, first_sequence, nil, "projection:first"}
    refute_receive {:projection_changed, _, _, _}, 20

    PixirMonitor.InvalidationHub.ack()
    assert_receive {:projection_changed, latest_sequence, nil, "projection:latest"}
    assert latest_sequence == first_sequence + 1

    PixirMonitor.InvalidationHub.unsubscribe()
    state = :sys.get_state(PixirMonitor.InvalidationHub)
    refute Map.has_key?(state.subscribers, self())
  end

  test "bootstrap source clears history before subresources and assets stay text-only/local" do
    assert {:ok, bootstrap} = PixirMonitor.Bootstrap.source()
    assert bootstrap =~ "location.hash"
    assert position(bootstrap, "history.replaceState") < position(bootstrap, "fetch(\"/bootstrap\"")
    assert position(bootstrap, "fetch(\"/bootstrap\"") < position(bootstrap, "trustedTypes.createPolicy")
    assert position(bootstrap, "history.replaceState") < position(bootstrap, "createElement")
    assert bootstrap =~ ~S|const appScript="/assets/app.js"|
    assert bootstrap =~ ~S|trustedTypes.createPolicy("pixir-bootstrap"|
    assert bootstrap =~ ~S|if(value===appScript)return appScript;throw new TypeError|
    assert bootstrap =~ ~S|policy.createScriptURL(appScript)|
    assert bootstrap =~ "script.src=trustedAppScript"
    refute bootstrap =~ "return value"
    refute bootstrap =~ ~S|createPolicy("default"|
    # The bootstrap failure path is TERMINAL and visible: the rejection is
    # consumed by a separate handler (app.js never loads on failure, so nobody
    # else can), the copy names the failure CATEGORY without echoing any
    # token, and it lands in the live-region status node. Only a 401 maps to
    # the capability copy family; the client cannot (and must not) split
    # expired from already-used, because the server deliberately folds both
    # into the single invalid_launch 401.
    assert position(bootstrap, "document.head.append(script)") < position(bootstrap, "__pixirBootstrap.catch")
    assert bootstrap =~ ~S|const capabilityAbsent=launch===null|
    assert bootstrap =~ ~S|response.status===401?(capabilityAbsent?"capability_absent":"capability_rejected"):"bootstrap_failed"|
    assert bootstrap =~ ~S|window.__pixirBootstrap.catch(function(error){var status=document.getElementById("status")|
    assert bootstrap =~ "Open the Monitor through the one-use link printed by pixir-monitor serve. This page was opened without one."
    assert bootstrap =~ "Launch link invalid, expired, or already used. Launch tokens are one-use and expire in 30 seconds. Run pixir-monitor serve again to mint a fresh one."
    assert bootstrap =~ "Monitor failed to start before loading. Reload the page, or run pixir-monitor serve again for a fresh session."
    # A 200 bootstrap with a failing app.js asset must not hang on
    # "Starting…" either: the script element carries a terminal onerror,
    # wired BEFORE the element joins the document.
    assert bootstrap =~ ~S|script.onerror=function()|
    assert position(bootstrap, "script.onerror") < position(bootstrap, "document.head.append(script)")
    assert bootstrap =~ "Monitor interface failed to load. Reload the page, or run pixir-monitor serve again for a fresh session."
    # Exactly one catch site — pinned both lexically (split) and structurally
    # (the real call-site shape), so the hygiene split below cannot be pointed
    # at a decoy consumer or dodged via a bracket-access rewrite.
    assert length(String.split(bootstrap, "__pixirBootstrap.catch")) == 2
    assert length(Regex.scan(~r/window\.__pixirBootstrap\.catch\(function/, bootstrap)) == 1
    catch_segment = bootstrap |> String.split("__pixirBootstrap.catch") |> List.last()
    refute catch_segment =~ "launch"
    refute catch_segment =~ "+"
    assert {:ok, csp_hash} = PixirMonitor.Bootstrap.csp_hash()
    assert csp_hash == :crypto.hash(:sha256, bootstrap) |> Base.encode64()
    assert {:ok, shell} = PixirMonitor.Bootstrap.shell()
    assert shell =~ "<main aria-label=\"Pixir Monitor\""
    # role="status" makes the terminal bootstrap copy a live region, so the
    # failure messages assigned by the catch handler AND the script onerror
    # handler are announced by screen readers instead of silently replacing
    # static text.
    assert shell =~ ~S|<p id="status" role="status">|
    assert shell =~ "<script>#{bootstrap}</script>"

    js = File.read!(Path.expand("../priv/static/app.js", __DIR__))
    refute js =~ "innerHTML"
    refute js =~ "serviceWorker"
    assert js =~ "navigator.clipboard.writeText"
    refute js =~ "execCommand"
    refute js =~ "http://"
    refute js =~ "https://"
    refute js =~ "telemetry"
  end

  test "CLI help and dry-run JSON are capability-free" do
    help = capture_io(fn -> assert PixirMonitor.CLI.main(["--help"]) == {:ok, 0} end)
    assert help =~ "pixir-monitor serve"

    output = capture_io(fn -> assert PixirMonitor.CLI.main(["serve", "--dry-run", "--json"]) == {:ok, 0} end)
    decoded = Jason.decode!(output)
    assert decoded["dry_run"] == true
    assert decoded["bind"] == %{"address" => "127.0.0.1", "port" => 0, "port_strategy" => "ephemeral"}
    assert decoded["renderer"] == "spa_sse"
    refute output =~ "#launch="
    refute output =~ "capability"
  end

  test "CLI self-check has distinct bounded human and compact JSON success modes" do
    previous_runner = Application.fetch_env(:pixir_monitor, :self_check_runner)

    on_exit(fn ->
      case previous_runner do
        {:ok, runner} -> Application.put_env(:pixir_monitor, :self_check_runner, runner)
        :error -> Application.delete_env(:pixir_monitor, :self_check_runner)
      end
    end)

    Application.put_env(:pixir_monitor, :self_check_runner, SelfCheckStub)

    human = capture_io(fn -> assert PixirMonitor.CLI.run(["self-check"]) == {:ok, 0} end)
    json = capture_io(fn -> assert PixirMonitor.CLI.run(["self-check", "--json"]) == {:ok, 0} end)

    assert human != json
    assert human =~ "Pixir Monitor self-check passed"
    assert human =~ "bootstrap: one_use_accepted"
    assert human =~ "Runs API: pixir.monitor.runs v1"
    assert byte_size(human) < 1_024
    assert {:error, %Jason.DecodeError{}} = Jason.decode(human)
    refute human =~ "#launch="
    refute human =~ "capability"

    assert String.ends_with?(json, "\n")
    refute String.trim_trailing(json) =~ "\n"

    assert Jason.decode!(json) == %{
             "ok" => true,
             "check" => "pixir_monitor_loopback",
             "listener" => "127.0.0.1",
             "bootstrap" => "one_use_accepted",
             "assets" => ["app.js", "app.css"],
             "runs_schema" => "pixir.monitor.runs",
             "runs_schema_version" => 1
           }

    refute json =~ "#launch="
    refute json =~ "capability"
  end

  test "embedded asset bytes and code-default Filesystem source are pinned" do
    assert {:ok, "text/javascript; charset=utf-8", js} = PixirMonitor.Assets.fetch("app.js")
    assert {:ok, "text/css; charset=utf-8", css} = PixirMonitor.Assets.fetch("app.css")
    assert js == File.read!(Path.expand("../priv/static/app.js", __DIR__))
    assert css == File.read!(Path.expand("../priv/static/app.css", __DIR__))

    source = File.read!(Path.expand("../lib/pixir_monitor/run_source.ex", __DIR__))
    assert source =~ "Application.get_env(:pixir_monitor, :run_source, PixirMonitor.Projection.Source)"
  end

  test "session capacity rejection does not consume a valid launch" do
    original = :sys.get_state(PixirMonitor.Vault)
    on_exit(fn -> :sys.replace_state(PixirMonitor.Vault, fn _ -> original end) end)

    now = System.monotonic_time(:millisecond)
    sessions = Map.new(1..256, &{"session-#{&1}", now + 60_000})
    :sys.replace_state(PixirMonitor.Vault, fn _ -> %{launches: %{}, sessions: sessions} end)

    assert {:ok, launch} = PixirMonitor.Vault.issue_launch()
    assert {:error, %{kind: "session_limit"}} = PixirMonitor.Vault.consume_launch(launch)

    :sys.replace_state(PixirMonitor.Vault, fn state -> %{state | sessions: %{}} end)
    assert {:ok, _session} = PixirMonitor.Vault.consume_launch(launch)
    assert {:error, :invalid_or_expired} = PixirMonitor.Vault.consume_launch(launch)
  end

  test "CLI supports serve help, bounded plain plans, and tagged structured failures" do
    assert capture_io(fn -> assert PixirMonitor.CLI.run(["serve", "--help"]) == {:ok, 0} end) =~ "pixir-monitor serve"

    plain = capture_io(fn -> assert PixirMonitor.CLI.run(["serve", "--dry-run"]) == {:ok, 0} end)
    assert plain =~ "append-only filesystem Logs"
    assert byte_size(plain) < 1_024
    refute plain =~ "#launch="

    error = capture_io(:stderr, fn -> assert PixirMonitor.CLI.run(["bad-command"]) == {:error, 1} end)
    assert error =~ "invalid_arguments"
  end

  test "runtime launch uses honest naming and a bounded no-argv environment handoff" do
    source = File.read!(Path.expand("../lib/pixir_monitor/runtime.ex", __DIR__))
    assert source =~ "def issue_launch_url(port)"
    refute source =~ "launch_url_for_test"
    assert source =~ ~S|system attribute "#{@launch_url_env}"|
    assert source =~ ~S|{@launch_url_env, url}|
    assert source =~ ~S|Port.info(port, :os_pid)|
    assert source =~ ~S|System.cmd("/bin/kill", ["-9", Integer.to_string(os_pid)]|
    assert source =~ ~S|deadline = System.monotonic_time(:millisecond) + timeout_ms|
    assert source =~ ~S|if remaining_ms(deadline) == 0 do|
    assert source =~ ":launcher_pid_unavailable"
    assert source =~ ":launcher_contract_violation"
    assert source =~ "_discarded_output"
    refute source =~ "mkfifo"
    refute source =~ "launch.fifo"
    refute source =~ "Task.async"
    refute source =~ ~S|args: [url]|
    refute source =~ ~S|"#{url}"|
    assert source =~ "unsupported_platform"
  end

  test "SSE rotation is long and bounded rather than a five-second refold loop" do
    source = File.read!(Path.expand("../lib/pixir_monitor/router.ex", __DIR__))
    assert source =~ "@sse_lifetime_ms 300_000"
    assert source =~ "@sse_max_events 100"
    refute source =~ "@sse_lifetime_ms 5_000"
  end

  test "metadata watcher and port registry are bounded and hold no projections" do
    watcher = File.read!(Path.expand("../lib/pixir_monitor/log_watcher.ex", __DIR__))
    registry = File.read!(Path.expand("../lib/pixir_monitor/port_registry.ex", __DIR__))
    assert watcher =~ "File.lstat"
    refute watcher =~ "Pixir.Log.fold"
    assert watcher =~ "Enum.take(max_logs)"
    assert registry =~ ":port_discovery_status, :exhausted"
    assert registry =~ "Application.delete_env(:pixir_monitor, :active_port"
  end

  test "vendored Presenter files match their frozen fixture lock" do
    root = Path.expand("../priv/presenter", __DIR__)
    lock = root |> Path.join("fixtures/fixture-lock.json") |> File.read!() |> Jason.decode!()

    Enum.each(lock["files"], fn entry ->
      bytes = File.read!(Path.join(root, entry["path"]))
      assert byte_size(bytes) == entry["bytes"]
      assert "sha256:" <> Base.encode16(:crypto.hash(:sha256, bytes), case: :lower) == entry["sha256"]
    end)
  end

  defp position(string, needle) do
    {position, _length} = :binary.match(string, needle)
    position
  end
end
