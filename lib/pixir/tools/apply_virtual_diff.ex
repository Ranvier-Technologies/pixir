defmodule Pixir.Tools.ApplyVirtualDiff do
  @moduledoc "Model-visible Tool for dry-running or explicitly applying a virtual_diff artifact."

  use Pixir.Tool

  alias Pixir.VirtualDiffApply

  @impl Pixir.Tool
  def __tool__ do
    %{
      name: "apply_virtual_diff",
      description: "Plan or explicitly apply a virtual_diff artifact to the workspace.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "artifact" => %{
            "type" => "object",
            "description" => "ADR 0029 virtual_diff artifact to plan or apply"
          },
          "dry_run" => %{
            "type" => "boolean",
            "description" => "When true or omitted, plan only and perform no mutations.",
            "default" => true
          }
        },
        "required" => ["artifact"]
      }
    }
  end

  @impl Pixir.Tool
  def dry_run(%{"artifact" => artifact}, context) do
    VirtualDiffApply.plan(artifact, context.workspace, tool_opts(context, true))
  end

  @impl Pixir.Tool
  def execute(%{"artifact" => artifact} = args, context) do
    dry_run = Map.get(args, "dry_run", true)

    if dry_run do
      VirtualDiffApply.plan(artifact, context.workspace, tool_opts(context, true))
    else
      case get_in(context, [:permission, :mode]) do
        :read_only -> denied_plan(artifact, context)
        "read_only" -> denied_plan(artifact, context)
        _other -> VirtualDiffApply.apply(artifact, context.workspace, tool_opts(context, false))
      end
    end
  end

  def execute(_args, _context) do
    {:error,
     Pixir.Tool.error(:invalid_args, "apply_virtual_diff requires artifact", %{
       "required" => ["artifact"]
     })}
  end

  defp denied_plan(artifact, context) do
    with {:ok, plan} <-
           VirtualDiffApply.plan(artifact, context.workspace, tool_opts(context, false)) do
      {:ok,
       plan
       |> Map.put("dry_run", false)
       |> Map.put("status", "denied")
       |> Map.put("permission", %{
         "mode" => "read_only",
         "decision" => "deny",
         "reason" => "mutating apply is denied in read_only mode"
       })}
    end
  end

  defp tool_opts(context, dry_run) do
    opts = [dry_run: dry_run]

    case get_in(context, [:permission, :policy]) do
      nil -> opts
      policy -> Keyword.put(opts, :write_policy, policy)
    end
  end
end
