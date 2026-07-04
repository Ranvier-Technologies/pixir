defmodule Pixir.WorkflowRun do
  @moduledoc """
  In-memory ownership boundary for one Workflow execution.

  A WorkflowRun owns the runtime state for one normalized Workflow graph: pending
  steps, active child references, completed step records, wave history, and the
  run start time used for Workflow-level timeouts.

  This is intentionally not a durable GenServer yet. Subagents remain the
  execution authority, `Pixir.Workflows` remains the tool-facing projection, and
  this module does not emit replayable Workflow events. It is the first safe
  backend slice toward a future OTP WorkflowRun process without introducing a
  second source of truth.
  """

  alias Pixir.Tool

  defstruct workflow_id: nil,
            pending: [],
            active: %{},
            completed: %{},
            completed_order: [],
            waves: [],
            wave: 0,
            started_at_ms: nil

  @type t :: %__MODULE__{
          workflow_id: String.t(),
          pending: [map()],
          active: map(),
          completed: map(),
          completed_order: [String.t()],
          waves: [[String.t()]],
          wave: non_neg_integer(),
          started_at_ms: integer()
        }

  @doc """
  Builds the runtime state for one normalized Workflow.
  """
  @spec new(map(), keyword()) :: {:ok, t()} | {:error, map()}
  def new(workflow, opts \\ [])

  def new(%{id: id, steps: steps}, opts) when is_binary(id) and is_list(steps) do
    {:ok,
     %__MODULE__{
       workflow_id: id,
       pending: steps,
       started_at_ms: Keyword.get(opts, :started_at_ms, now_ms())
     }}
  end

  def new(_workflow, _opts),
    do: {:error, Tool.error(:invalid_args, "workflow run requires a normalized workflow", %{})}

  @doc """
  Returns whether the Workflow-level deadline has elapsed for this run.
  """
  @spec deadline_exceeded?(map(), t(), integer() | nil) :: {:ok, boolean()} | {:error, map()}
  def deadline_exceeded?(workflow, run, now_ms \\ nil)

  def deadline_exceeded?(
        %{timeout_ms: timeout_ms},
        %__MODULE__{started_at_ms: started_at_ms},
        now_ms
      )
      when is_integer(timeout_ms) and timeout_ms > 0 and is_integer(started_at_ms) and
             (is_nil(now_ms) or is_integer(now_ms)) do
    now_ms = now_ms || now_ms()
    {:ok, now_ms - started_at_ms > timeout_ms}
  end

  def deadline_exceeded?(_workflow, _run, _now_ms),
    do: {:error, Tool.error(:invalid_args, "workflow run deadline input is invalid", %{})}

  defp now_ms, do: System.monotonic_time(:millisecond)
end
