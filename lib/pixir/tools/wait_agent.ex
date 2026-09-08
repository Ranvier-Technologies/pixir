defmodule Pixir.Tools.WaitAgent do
  @moduledoc """
  Wait for Subagents and return an honest fanout outcome.

  Mixed child results are reported as structured partial or incomplete outcomes
  instead of turning the parent tool call into an opaque error.
  """

  use Pixir.Tool

  alias Pixir.{Subagents, Tool}

  @impl Pixir.Tool
  def __tool__ do
    %{
      name: "wait_agent",
      description:
        "Wait for one or more Subagents and return compact summaries plus cheap child Log pointers and last-seen event metadata. This timeout is only the parent wait horizon; it does not interrupt running children. Use timeout_ms=0 to poll without blocking.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "ids" => %{
            "type" => "array",
            "items" => %{"type" => "string"},
            "description" => "Subagent ids; omitted means all"
          },
          "timeout_ms" => %{
            "type" => "integer",
            "minimum" => 0,
            "description" =>
              "Parent wait horizon in ms; 0 means non-blocking poll and never cancels the child"
          }
        },
        "required" => []
      }
    }
  end

  @impl Pixir.Tool
  def execute(args, context) when is_map(args) do
    timeout_ms = Map.get(args, "timeout_ms", 30_000)
    ids = Map.get(args, "ids", [])

    with :ok <- validate(timeout_ms, ids),
         {:ok, outcome} <-
           Subagents.wait_outcome(context.session_id, ids, timeout_ms,
             workspace: context.workspace
           ) do
      terminal_presentation? =
        outcome["status"] in ["completed", "partial"] and
          Subagents.potentially_integrable?(outcome["subagents"] || [])

      landing =
        if terminal_presentation? do
          Subagents.landing_manifest_projection(outcome["subagents"] || [], context.workspace,
            parent_session_id: context.session_id
          )
        else
          %{"landing_manifest" => []}
        end

      landing_manifest = landing["landing_manifest"]
      omitted_children = Map.get(landing, "omitted_children", 0)

      output =
        outcome
        |> Subagents.summarize_wait_outcome()
        |> maybe_append_reverification_directive(outcome)
        |> maybe_append_landing_manifest(landing_manifest, omitted_children)

      result = %{
        "output" => output,
        "subagents" => outcome["subagents"],
        "outcome" => outcome
      }

      result =
        result
        |> maybe_put_landing_manifest(landing_manifest)
        |> maybe_put_omitted_children(omitted_children)

      {:ok, result}
    end
  end

  def execute(_args, _context),
    do: {:error, Tool.error(:invalid_args, "arguments must be an object", %{})}

  @impl Pixir.Tool
  def dry_run(args, _context) when is_map(args) do
    {:ok,
     %{
       "dry_run" => true,
       "would" => "wait_agent",
       "ids" => Map.get(args, "ids", []),
       "timeout_ms" => Map.get(args, "timeout_ms", 30_000)
     }}
  end

  def dry_run(_args, _context),
    do: {:error, Tool.error(:invalid_args, "arguments must be an object", %{})}

  @doc false
  def append_reverification_directive_for_test(output, outcome),
    do: maybe_append_reverification_directive(output, outcome)

  defp maybe_append_reverification_directive(output, outcome) do
    if outcome["status"] in ["completed", "partial"] and
         Subagents.potentially_integrable?(outcome["subagents"] || []) do
      output <> "\n\n" <> Subagents.reverification_directive()
    else
      output
    end
  end

  defp maybe_append_landing_manifest(output, [], _omitted_children), do: output

  defp maybe_append_landing_manifest(output, manifest, omitted_children),
    do: output <> "\n\n" <> Subagents.render_landing_manifest(manifest, omitted_children)

  defp maybe_put_landing_manifest(result, []), do: result

  defp maybe_put_landing_manifest(result, manifest),
    do: Map.put(result, "landing_manifest", manifest)

  defp maybe_put_omitted_children(result, 0), do: result

  defp maybe_put_omitted_children(result, omitted_children),
    do: Map.put(result, "omitted_children", omitted_children)

  defp validate(timeout_ms, ids)
       when is_integer(timeout_ms) and timeout_ms >= 0 and is_list(ids),
       do: :ok

  defp validate(_timeout_ms, _ids),
    do: {:error, Tool.error(:invalid_args, "ids must be a list and timeout_ms an integer", %{})}
end
