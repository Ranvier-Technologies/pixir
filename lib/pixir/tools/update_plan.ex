defmodule Pixir.Tools.UpdatePlan do
  @moduledoc """
  Record/refine a live plan (to-do checklist) for the current Turn (epic D.1/D.3).

  This is the canonical plan emit site: it publishes an ephemeral `:plan` Event on
  the session bus, which the ACP front-end renders as a live checklist. It mutates
  no files and runs no commands, so it is permitted even in `:read_only`/plan mode
  (the architect tool). The model calls it in plan mode to present its plan, then
  stops (plan-and-wait).
  """

  use Pixir.Tool

  alias Pixir.{Event, Session, Tool}

  @priorities ~w(high medium low)
  @statuses ~w(pending in_progress completed)

  @impl Pixir.Tool
  def __tool__ do
    %{
      name: "update_plan",
      description:
        "Record or update the step-by-step plan as a checklist. Send the COMPLETE " <>
          "current plan each time (it replaces the previous one). Use this in plan " <>
          "mode to present your plan, then stop.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "entries" => %{
            "type" => "array",
            "description" => "The complete ordered list of plan steps.",
            "items" => %{
              "type" => "object",
              "properties" => %{
                "content" => %{"type" => "string", "description" => "What the step does."},
                "priority" => %{
                  "type" => "string",
                  "enum" => @priorities,
                  "description" => "high | medium | low (default medium)."
                },
                "status" => %{
                  "type" => "string",
                  "enum" => @statuses,
                  "description" => "pending | in_progress | completed (default pending)."
                }
              },
              "required" => ["content"]
            }
          }
        },
        "required" => ["entries"]
      }
    }
  end

  @impl Pixir.Tool
  def execute(%{"entries" => entries}, context) when is_list(entries) do
    if Enum.all?(entries, &is_map/1) do
      normalized = Enum.map(entries, &normalize_entry/1)
      Session.emit(context.session_id, Event.plan(context.session_id, normalized))
      {:ok, %{"output" => "Recorded a plan with #{length(normalized)} step(s)."}}
    else
      {:error, Tool.error(:invalid_args, "entries must be a list of objects", %{})}
    end
  end

  def execute(_args, _context),
    do: {:error, Tool.error(:invalid_args, "entries must be a list", %{})}

  @impl Pixir.Tool
  def dry_run(%{"entries" => entries}, _context) when is_list(entries) do
    if Enum.all?(entries, &is_map/1) do
      {:ok, %{"dry_run" => true, "would" => "update_plan", "steps" => length(entries)}}
    else
      {:error, Tool.error(:invalid_args, "entries must be a list of objects", %{})}
    end
  end

  def dry_run(_args, _context),
    do: {:error, Tool.error(:invalid_args, "entries must be a list", %{})}

  # Coerce one entry to the canonical string-keyed shape with valid literals.
  defp normalize_entry(entry) when is_map(entry) do
    %{
      "content" => to_string(entry["content"] || ""),
      "priority" => clamp(entry["priority"], @priorities, "medium"),
      "status" => clamp(entry["status"], @statuses, "pending")
    }
  end

  defp clamp(value, allowed, default) when is_binary(value) do
    if value in allowed, do: value, else: default
  end

  defp clamp(_value, _allowed, default), do: default
end
