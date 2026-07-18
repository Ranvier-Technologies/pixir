defmodule PixirMonitor.Endpoint do
  @moduledoc """
  Phoenix/Bandit boundary for the literal-loopback monitor HTTP surface.

  It exposes no socket, Channel, LiveView, Presence, or telemetry endpoint.
  """
  use Phoenix.Endpoint, otp_app: :pixir_monitor

  plug(PixirMonitor.Router)
end
