defmodule PixirMonitor.EscriptContractTest do
  use ExUnit.Case, async: true

  test "source and CI contract pins structured real-HTTP escript self-check" do
    cli = File.read!(Path.expand("../lib/pixir_monitor/cli.ex", __DIR__))
    check = File.read!(Path.expand("../lib/pixir_monitor/self_check.ex", __DIR__))
    ci = File.read!(Path.expand("../../.github/workflows/ci.yml", __DIR__))

    assert cli =~ "pixir-monitor self-check [--json]"
    assert cli =~ "PixirMonitor.SelfCheck.run()"
    assert cli =~ "System.halt(status)"
    assert check =~ "Application.ensure_all_started(:pixir_monitor)"
    assert check =~ ":httpc.request(:post"
    assert check =~ ~S|verify_consumed(port, launch)|
    assert check =~ ~S|verify_asset(port, cookie, "app.js")|
    assert check =~ ~S|verify_asset(port, cookie, "app.css")|
    assert check =~ ~S|verify_runs(port, cookie)|
    refute check =~ "IO."
    assert ci =~ "./pixir-monitor self-check --json"
    assert position(ci, "mix escript.build") < position(ci, "./pixir-monitor self-check --json")
  end

  test "runtime defaults are code-owned and assets are compile-time resources" do
    application = File.read!(Path.expand("../lib/pixir_monitor/application.ex", __DIR__))
    assets = File.read!(Path.expand("../lib/pixir_monitor/assets.ex", __DIR__))

    assert application =~ "put_default(:run_source, PixirMonitor.Projection.Source)"
    assert application =~ "put_default(:projection_input_provider, PixirMonitor.Projection.Source.Filesystem)"
    assert application =~ "Keyword.put_new(:http, ip: {127, 0, 0, 1}, port: 0, startup_log: false)"
    assert application =~ "Keyword.put_new(:log_access_url, false)"
    refute application =~ "Application.put_env(:phoenix, :logger, false)"
    refute application =~ "Logger.configure(level:"
    assert assets =~ "@external_resource @app_js_path"
    assert assets =~ "@external_resource @app_css_path"
    assert assets =~ "@app_js File.read!(@app_js_path)"
    assert assets =~ "@app_css File.read!(@app_css_path)"
  end

  defp position(string, needle) do
    {position, _length} = :binary.match(string, needle)
    position
  end
end
