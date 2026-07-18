defmodule PixirMonitor.Projection.WorkflowGraph do
  @moduledoc """
  Validates the closed Workflow graph shape shared by runtime and fixture projections.

  A Presenter graph is a DAG over safe, delimiter-free, unique step ids. Every
  dependency must name another planned step. Rejecting malformed or cyclic evidence
  before projection prevents inventory rows from linking to Detail views with phantom
  or invisible units.
  """

  alias PixirMonitor.Projection.UnitIdentity

  @doc "Validates Workflow steps, accepting `nil` for non-Workflow fan-out evidence."
  @spec validate(term()) :: {:ok, :valid} | {:error, map()}
  def validate(nil), do: {:ok, :valid}

  def validate(steps) when is_list(steps) do
    ids = Enum.map(steps, &step_id/1)

    cond do
      Enum.any?(ids, &is_nil/1) ->
        error("Every Workflow graph step must have a safe non-empty string id")

      length(ids) != MapSet.size(MapSet.new(ids)) ->
        error("Workflow graph contains duplicate logical step ids")

      not valid_dependencies?(steps, MapSet.new(ids)) ->
        error("Every Workflow dependency must identify a planned step")

      not acyclic?(steps) ->
        error("Workflow dependencies must form an acyclic graph")

      true ->
        {:ok, :valid}
    end
  end

  def validate(_steps), do: error("Workflow graph steps must be a list")

  defp step_id(%{"id" => id}) do
    case UnitIdentity.component(id) do
      {:ok, safe_id} -> safe_id
      {:error, _reason} -> nil
    end
  end

  defp step_id(_step), do: nil

  defp valid_dependencies?(steps, planned_ids) do
    Enum.all?(steps, fn step ->
      case step["depends_on"] do
        nil ->
          true

        dependencies when is_list(dependencies) ->
          Enum.all?(dependencies, &(is_binary(&1) and MapSet.member?(planned_ids, &1)))

        _dependencies ->
          false
      end
    end)
  end

  defp acyclic?(steps) do
    steps
    |> Map.new(fn step -> {step["id"], MapSet.new(step["depends_on"] || [])} end)
    |> remove_dependency_roots()
  end

  defp remove_dependency_roots(remaining) when map_size(remaining) == 0, do: true

  defp remove_dependency_roots(remaining) do
    roots = for {id, dependencies} <- remaining, MapSet.size(dependencies) == 0, do: id

    if roots == [] do
      false
    else
      root_set = MapSet.new(roots)

      remaining
      |> Map.drop(roots)
      |> Map.new(fn {id, dependencies} ->
        {id, MapSet.difference(dependencies, root_set)}
      end)
      |> remove_dependency_roots()
    end
  end

  defp error(message) do
    {:error, %{kind: "run_graph_identity_invalid", message: message, details: %{}}}
  end
end
