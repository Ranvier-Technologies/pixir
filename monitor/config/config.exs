import Config

config :pixir_monitor, PixirMonitor.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  http: [ip: {127, 0, 0, 1}, port: 0, startup_log: false],
  log_access_url: false,
  url: [host: "127.0.0.1", scheme: "http", port: 0],
  server: true,
  render_errors: [formats: [json: PixirMonitor.ErrorJSON], layout: false],
  secret_key_base: :crypto.strong_rand_bytes(64) |> Base.encode64()

config :pixir_monitor, :run_source, PixirMonitor.Projection.Source
config :pixir_monitor, :projection_input_provider, PixirMonitor.Projection.Source.Filesystem

# Workspace is deliberately absent here: it is resolved at serve invocation time
# (CLI > runtime config > invocation-time File.cwd!/0), never baked at build time.
config :pixir_monitor, :projection_source,
  max_logs: 512,
  max_log_bytes: 8 * 1_024 * 1_024,
  max_events: 20_000

config :phoenix, :json_library, Jason

import_config "#{config_env()}.exs"
