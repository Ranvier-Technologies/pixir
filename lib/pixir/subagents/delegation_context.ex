defmodule Pixir.Subagents.DelegationContext do
  @moduledoc """
  Builds late-bound Delegation Context for Subagent child Turns.

  Delegation Context is model-visible operational metadata for one child Turn. It
  stays out of Pixir's stable prompt prefix: callers pass the returned map to
  `Pixir.Turn.run/3`, which renders it into the late developer-context input
  item. The map is string-keyed so it can be tested, logged later if a future ADR
  accepts a durable event, and rendered deterministically without leaking Elixir
  struct details.
  """

  alias Pixir.Permissions.WritePolicy
  alias Pixir.WorkspaceStrategy

  @host_boundary_rule "OTP fanout yes; OS-boundary fanout carefully bounded."

  @doc "Build a compact string-keyed context map from a live Subagent record."
  @spec from_agent(map()) :: map()
  def from_agent(agent) when is_map(agent) do
    base =
      %{
        "subagent_id" => Map.get(agent, :id),
        "parent_session_id" => Map.get(agent, :parent_session_id),
        "child_session_id" => Map.get(agent, :child_session_id),
        "agent" => Map.get(agent, :agent),
        "task" => Map.get(agent, :prompt) || Map.get(agent, :task),
        "depth" => Map.get(agent, :depth),
        "max_depth" => Map.get(agent, :max_depth),
        "timeout_ms" => Map.get(agent, :timeout_ms),
        "deadline_at" => Map.get(agent, :deadline_at),
        "permission_mode" => permission_mode(Map.get(agent, :permission_mode)),
        "write_policy" => WritePolicy.metadata(Map.get(agent, :write_policy)),
        "workspace_mode" => Map.get(agent, :workspace_mode),
        "host_boundary_rule" => @host_boundary_rule
      }
      |> compact()
      |> merge_metadata(Map.get(agent, :delegation_context))

    merge_workspace_context(base)
  end

  @doc "Merge Workflow or caller metadata into a base Delegation Context map."
  @spec merge_metadata(map(), term()) :: map()
  def merge_metadata(base, metadata) when is_map(base) and is_map(metadata) do
    metadata
    |> stringify_keys()
    |> compact()
    |> Map.merge(base)
  end

  def merge_metadata(base, _metadata) when is_map(base), do: base

  defp merge_workspace_context(context) do
    case WorkspaceStrategy.delegation_context(Map.get(context, "workspace_mode"), context) do
      {:ok, workspace_context} ->
        context
        |> Map.merge(workspace_context)
        |> compact()

      {:error, _error} ->
        context
    end
  end

  defp permission_mode(mode) when is_atom(mode), do: Atom.to_string(mode)
  defp permission_mode(mode), do: mode

  defp stringify_keys(map) do
    Map.new(map, fn {key, value} -> {to_string(key), normalize_value(value)} end)
  end

  defp normalize_value(%{} = value), do: stringify_keys(value)
  defp normalize_value(values) when is_list(values), do: Enum.map(values, &normalize_value/1)
  defp normalize_value(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_value(value), do: value

  defp compact(map) do
    map
    |> Enum.reject(fn {_key, value} -> empty?(value) end)
    |> Map.new()
  end

  defp empty?(nil), do: true
  defp empty?(""), do: true
  defp empty?([]), do: true
  defp empty?(map) when is_map(map), do: map_size(map) == 0
  defp empty?(_value), do: false
end
