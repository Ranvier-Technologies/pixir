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
      {:ok,
       %{
         "output" => Subagents.summarize_wait_outcome(outcome),
         "subagents" => outcome["subagents"],
         "outcome" => outcome
       }}
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

  defp validate(timeout_ms, ids)
       when is_integer(timeout_ms) and timeout_ms >= 0 and is_list(ids),
       do: :ok

  defp validate(_timeout_ms, _ids),
    do: {:error, Tool.error(:invalid_args, "ids must be a list and timeout_ms an integer", %{})}
end
