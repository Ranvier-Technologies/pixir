unless Code.ensure_loaded?(PixirMonitor.FixtureWorkspace) do
  Code.require_file("fixture_workspace.ex", __DIR__)
end

defmodule PixirMonitor.InventoryFixture do
  @moduledoc false

  @maximum_materializations 1_024
  @maximum_ordinal 0xFFFFFF

  @spec input(non_neg_integer(), keyword()) :: map()
  def input(ordinal, options \\ [])
      when is_integer(ordinal) and ordinal in 0..@maximum_ordinal and is_list(options) do
    session_id = session_id(ordinal)
    steps = Keyword.get(options, :steps, [])

    %{
      "inputs" => %{
        "terminal_envelope" => %{"parent_session_id" => session_id},
        "parent_log" => [
          %{
            "seq" => 0,
            "ts" => "2026-07-15T00:00:00Z",
            "type" => "workflow_event",
            "data" => %{
              "kind" => "workflow_started",
              "workflow_id" => "inventory-scope",
              "workflow_name" => "Inventory scope proof",
              "graph" => %{"steps" => steps}
            }
          }
        ]
      }
    }
  end

  @spec materialize_many!(Path.t(), Enumerable.t(), keyword()) :: [String.t()]
  def materialize_many!(target_directory, ordinals, options \\ [])
      when is_binary(target_directory) and is_list(options) do
    ordinals = Enum.to_list(ordinals)

    if length(ordinals) > @maximum_materializations do
      raise ArgumentError,
            "inventory fixture materialization is bounded to #{@maximum_materializations} Logs"
    end

    input_builder = Keyword.get(options, :input_builder, &input/1)

    Enum.map(ordinals, fn ordinal ->
      ordinal
      |> input_builder.()
      |> PixirMonitor.FixtureWorkspace.materialize!(target_directory)
    end)
  end

  @spec session_id(non_neg_integer()) :: String.t()
  def session_id(ordinal) when is_integer(ordinal) and ordinal in 0..@maximum_ordinal do
    suffix = ordinal |> Integer.to_string(16) |> String.pad_leading(6, "0")
    "20260715T000000-" <> suffix
  end
end
