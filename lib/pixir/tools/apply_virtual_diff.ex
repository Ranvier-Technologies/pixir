defmodule Pixir.Tools.ApplyVirtualDiff do
  @moduledoc "Model-visible Tool for dry-running or explicitly applying a virtual_diff artifact."

  use Pixir.Tool

  alias Pixir.{Log, VirtualDiffApply}

  @impl Pixir.Tool
  def __tool__ do
    %{
      name: "apply_virtual_diff",
      description:
        "Plan or explicitly apply a virtual_diff artifact, either directly or by resolving a delegated child's durable virtual_diff_ref.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "artifact" => %{
            "type" => "object",
            "description" => "ADR 0029 virtual_diff artifact to plan or apply"
          },
          "virtual_diff_ref" => %{
            "type" => "object",
            "description" =>
              "Durable virtual_diff reference from a delegated child's landing manifest"
          },
          "child_session_id" => %{
            "type" => "string",
            "description" =>
              "Child Session whose Log contains the referenced virtual_diff artifact"
          },
          "dry_run" => %{
            "type" => "boolean",
            "description" => "When true or omitted, plan only and perform no mutations.",
            "default" => true
          }
        },
        "required" => []
      }
    }
  end

  @impl Pixir.Tool
  def dry_run(args, context) when is_map(args) do
    with {:ok, artifact} <- resolve_artifact(args, context) do
      VirtualDiffApply.plan(artifact, context.workspace, tool_opts(context, true))
    end
  end

  def dry_run(_args, _context), do: invalid_args()

  @impl Pixir.Tool
  def execute(args, context) when is_map(args) do
    with {:ok, artifact} <- resolve_artifact(args, context) do
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
  end

  def execute(_args, _context), do: invalid_args()

  @doc false
  def resolve_artifact(%{"artifact" => artifact}, _context) when is_map(artifact),
    do: {:ok, artifact}

  def resolve_artifact(
        %{
          "virtual_diff_ref" => virtual_diff_ref,
          "child_session_id" => child_session_id
        },
        %{workspace: workspace}
      )
      when is_map(virtual_diff_ref) and is_binary(child_session_id) and
             child_session_id != "" and is_binary(workspace) do
    with {:ok, history} <- Log.fold(child_session_id, workspace: workspace),
         {:ok, artifact} <- find_referenced_artifact(history, virtual_diff_ref) do
      {:ok, artifact}
    end
  end

  def resolve_artifact(_args, _context), do: invalid_args()

  defp find_referenced_artifact(history, virtual_diff_ref) do
    {_call_ids, artifact} =
      Enum.reduce(history, {MapSet.new(), nil}, fn
        %{type: :tool_call, data: %{"name" => "run_virtual_commands", "call_id" => call_id}},
        {call_ids, selected}
        when is_binary(call_id) ->
          {MapSet.put(call_ids, call_id), selected}

        %{
          type: :tool_result,
          seq: source_seq,
          data: %{
            "call_id" => call_id,
            "ok" => true,
            "virtual_diff" => %{"kind" => "virtual_diff"} = artifact
          }
        },
        {call_ids, selected} ->
          if MapSet.member?(call_ids, call_id) and
               virtual_diff_ref(artifact, source_seq) == virtual_diff_ref do
            {call_ids, artifact}
          else
            {call_ids, selected}
          end

        _event, acc ->
          acc
      end)

    case artifact do
      %{} = artifact -> {:ok, artifact}
      nil -> {:error, Pixir.Tool.error(:not_found, "referenced virtual_diff was not found", %{})}
    end
  end

  defp virtual_diff_ref(artifact, source_seq) do
    encoded = Jason.encode!(artifact)

    %{
      "kind" => artifact["kind"],
      "version" => artifact["version"],
      "sha256" => :crypto.hash(:sha256, encoded) |> Base.encode16(case: :lower),
      "encoded_bytes" => byte_size(encoded),
      "changed_files" => length(Map.get(artifact, "changes", [])),
      "diff_bytes" => get_in(artifact, ["summary", "diff_bytes"]),
      "apply_status" => get_in(artifact, ["apply", "status"]),
      "source_seq" => source_seq
    }
  end

  defp invalid_args do
    {:error,
     Pixir.Tool.error(
       :invalid_args,
       "apply_virtual_diff requires artifact or virtual_diff_ref with child_session_id",
       %{
         "accepted" => [
           ["artifact"],
           ["virtual_diff_ref", "child_session_id"]
         ]
       }
     )}
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
