defmodule PixirMonitor.Application do
  @moduledoc """
  Owns only disposable monitor security, metadata invalidation, HTTP, and port state.

  Canonical Pixir run state is deliberately absent from this supervision tree; every
  child holds recomputable or disposable state. Children restart `rest_for_one`, so
  a restarted `PixirMonitor.Vault` also rebuilds every security surface started
  after it. Runtime defaults are installed here so the built escript does not depend
  on `config.exs`; the projection workspace deliberately has no default because it
  is resolved at serve invocation time by `PixirMonitor.CLI`.
  """
  use Application

  @impl true
  def start(_type, _args) do
    configure_runtime()

    children = [
      PixirMonitor.Vault,
      PixirMonitor.InvalidationHub,
      PixirMonitor.LogWatcher,
      PixirMonitor.Endpoint,
      PixirMonitor.PortRegistry,
      PixirMonitor.SseDrainer
    ]

    Supervisor.start_link(children, strategy: :rest_for_one, name: PixirMonitor.Supervisor)
  end

  defp configure_runtime do
    endpoint =
      Application.get_env(:pixir_monitor, PixirMonitor.Endpoint, [])
      |> Keyword.put(:secret_key_base, :crypto.strong_rand_bytes(64) |> Base.encode64())
      |> Keyword.put_new(:adapter, Bandit.PhoenixAdapter)
      |> Keyword.put_new(:http, ip: {127, 0, 0, 1}, port: 0, startup_log: false)
      |> Keyword.put_new(:log_access_url, false)
      |> Keyword.put_new(:url, host: "127.0.0.1", scheme: "http", port: 0)
      |> Keyword.put_new(:server, true)
      |> Keyword.put_new(:render_errors, formats: [json: PixirMonitor.ErrorJSON], layout: false)

    Application.put_env(:pixir_monitor, PixirMonitor.Endpoint, endpoint)
    put_default(:run_source, PixirMonitor.Projection.Source)
    put_default(:projection_input_provider, PixirMonitor.Projection.Source.Filesystem)
    # No workspace default here: workspace is resolved at serve invocation time by
    # PixirMonitor.CLI (CLI > runtime config > invocation-time File.cwd!/0).
    put_default(:projection_source, max_logs: 512, max_log_bytes: 8 * 1_024 * 1_024, max_events: 20_000)
  end

  defp put_default(key, value) do
    if is_nil(Application.get_env(:pixir_monitor, key)), do: Application.put_env(:pixir_monitor, key, value)
  end
end
