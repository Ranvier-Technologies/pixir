defmodule Pixir.Application do
  @moduledoc """
  OTP application root. Starts the long-lived infrastructure that every Session
  depends on (see `docs/adr/` for rationale):

    * `Finch` — HTTP/2 pool for the Provider (ADR 0002/0003).
    * `Pixir.Events.Registry` — the event bus dispatch table (ADR 0004).
    * `Pixir.Sessions.Registry` — `session_id` → Session pid (ADR 0001).
    * `Pixir.TurnSupervisor` — a `Task.Supervisor` that owns each Turn's Task; the
      Session interrupts a Turn by killing its Task (ADR 0001).
    * `Pixir.Auth` — owns the Credential and serializes token refresh (ADR 0002).
    * `Pixir.Provider.ConnectionSupervisor` — owns per-key WebSocket Provider
      connections for the WebSocket-first transport policy (ADR 0019).
    * `Pixir.SessionSupervisor` — a `DynamicSupervisor` of `Pixir.Session` processes.
    * `Pixir.Tools.CommandBoundary` — bounds local host-command process fanout
      separately from BEAM-local Subagent/Workflow fanout (ADR 0027).
    * `Pixir.Subagents` — supervises parent-led Subagent fan-out (ADR 0011).
    * `Pixir.Delegate.OwnerSupervisor` — owns current-runtime Delegate service runs
      and live cancel/status capability (ADR 0034).
  """

  use Application

  @finch_name Pixir.Finch

  @impl true
  def start(_type, _args) do
    children = [
      {Finch, name: @finch_name},
      Pixir.Events.registry_child_spec(),
      {Registry, keys: :unique, name: Pixir.Sessions.Registry},
      {Registry, keys: :unique, name: Pixir.Provider.ConnectionRegistry},
      {Task.Supervisor, name: Pixir.TurnSupervisor},
      Pixir.Auth,
      Pixir.Provider.ConnectionSupervisor,
      Pixir.SessionSupervisor,
      Pixir.Tools.CommandBoundary,
      Pixir.Subagents,
      {Registry, keys: :unique, name: Pixir.Delegate.OwnerRegistry},
      Pixir.Delegate.OwnerSupervisor
    ]

    opts = [strategy: :one_for_one, name: Pixir.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @doc "Name of the shared Finch pool."
  def finch_name, do: @finch_name
end
