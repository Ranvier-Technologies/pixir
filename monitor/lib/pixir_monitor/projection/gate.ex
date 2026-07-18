defmodule PixirMonitor.Projection.Gate do
  @moduledoc """
  Normalizes durable Workflow gate evidence for list and detail projections.

  The Presenter contract has a closed gate-state vocabulary. Runtime evidence with
  an unknown, blank, or non-string checkpoint status therefore projects as
  `"unknown"` instead of leaking an invalid schema value. A `step_held` event with no
  meaningful explicit status retains its structural `"held"` meaning.
  """

  @states ~w(checkpoint_ready partial failed held needs_orchestrator not_applicable unknown)

  @doc "Returns the contract-valid gate state represented by a Workflow event."
  @spec state(term()) :: {:ok, String.t()}
  def state(event) when is_map(event) do
    data = event_data(event)
    raw = data["checkpoint_status"]

    state =
      cond do
        raw in @states -> raw
        data["kind"] == "step_held" and blank?(raw) -> "held"
        true -> "unknown"
      end

    {:ok, state}
  end

  def state(_event), do: {:ok, "unknown"}

  @doc "Returns a schema-valid dependency-safety value for normalized gate evidence."
  @spec dependent_safe(term()) :: {:ok, boolean() | nil}
  def dependent_safe(event) when is_map(event) do
    data = event_data(event)
    {:ok, state} = state(event)

    value =
      case data["dependent_safe"] do
        true -> state == "checkpoint_ready"
        false -> false
        _value -> nil
      end

    {:ok, value}
  end

  def dependent_safe(_event), do: {:ok, nil}

  defp event_data(event) do
    case Map.get(event, "data") do
      data when is_map(data) -> data
      _data -> %{}
    end
  end

  defp blank?(nil), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_value), do: false
end
