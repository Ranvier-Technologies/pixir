defmodule PixirMonitor.Projection.AttemptStatus do
  @moduledoc """
  Validates the closed status vocabulary for durable attempt start evidence.

  `started` and `input` open an attempt; they may not claim terminal, gate-only,
  malformed, or differently-cased states. Missing status remains honest `"unknown"`
  evidence, while any explicit value must be a contract-valid open status.
  """

  @open ~w(queued running unknown)

  @doc "Returns a canonical open-attempt status or a tagged error for explicit invalid data."
  @spec start_status(term()) :: {:ok, String.t()} | {:error, :invalid_open_status}
  def start_status(data) when is_map(data) do
    case Map.fetch(data, "status") do
      :error -> {:ok, "unknown"}
      {:ok, nil} -> {:ok, "unknown"}
      {:ok, status} when status in @open -> {:ok, status}
      {:ok, _status} -> {:error, :invalid_open_status}
    end
  end

  def start_status(_data), do: {:error, :invalid_open_status}
end
