defmodule Pixir.ACP.RuntimeMode do
  @moduledoc """
  Live producer for agent-initiated plan→build (#520).

  `Pixir.ACP.Server.runtime_config_change/3` is the presenter wire. This module
  is the caller: when a plan-mode Turn records a plan, Pixir advertises `build`
  so the client picker moves without a `session/set_mode` round-trip.

  CLI and other non-ACP Turns have no `acp_runtime` binding and are a no-op.
  A Turn that is already in build does not emit a no-op flip. The Server helper
  also drops an unchanged advertised mode, so a second `update_plan` in the same
  plan-mode Turn does not duplicate the wire update.
  """

  alias Pixir.ACP.Server

  @type acp_runtime :: %{server: GenServer.server(), acp_sid: String.t()}

  @doc """
  Advertise plan→build for the ACP session bound on this tool context.

  Called from `Pixir.Tools.UpdatePlan` after a plan is recorded. Returns
  `{:ok, :queued}` when a change was handed to the Server, or `:ok` when there
  is no ACP binding or the Turn is not in plan mode.
  """
  @spec leave_plan(map()) :: :ok | {:ok, :queued} | {:error, map()}
  def leave_plan(%{mode: :plan, acp_runtime: %{server: server, acp_sid: acp_sid}})
      when is_binary(acp_sid) do
    Server.runtime_config_change(server, acp_sid, %{"mode" => "build"})
  end

  def leave_plan(_context), do: :ok
end
