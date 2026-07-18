defmodule PixirMonitor.Projection.WorkflowGraphTest do
  @moduledoc "Contract pins for shared Workflow DAG validation."
  use ExUnit.Case, async: true

  alias PixirMonitor.Projection.WorkflowGraph

  test "accepts absent fan-out graphs and valid fan-in DAGs" do
    assert {:ok, :valid} = WorkflowGraph.validate(nil)

    assert {:ok, :valid} =
             WorkflowGraph.validate([
               %{"id" => "a"},
               %{"id" => "b"},
               %{"id" => "join", "depends_on" => ["a", "b"]}
             ])
  end

  test "rejects malformed identities, dependencies, and cycles" do
    invalid_graphs = [
      [%{}],
      [%{"id" => ""}],
      [%{"id" => "review:main"}],
      [%{"id" => "same"}, %{"id" => "same"}],
      [%{"id" => "a", "depends_on" => ["missing"]}],
      [%{"id" => "a", "depends_on" => "missing"}],
      [%{"id" => "a", "depends_on" => ["a"]}],
      [%{"id" => "a", "depends_on" => ["b"]}, %{"id" => "b", "depends_on" => ["a"]}]
    ]

    for graph <- invalid_graphs do
      assert {:error, %{kind: "run_graph_identity_invalid"}} =
               WorkflowGraph.validate(graph)
    end
  end
end
