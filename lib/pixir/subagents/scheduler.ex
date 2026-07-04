defmodule Pixir.Subagents.Scheduler do
  @moduledoc """
  Pure scheduling policy for Subagent fan-out.

  The subagent manager owns lifecycle, timers, logs, and child Sessions. This
  module owns only queue selection and concurrency decisions so those rules can be
  tested without starting BEAM processes or provider Turns.
  """

  alias Pixir.Tool

  @running_status "running"
  @queued_status "queued"

  @doc """
  Returns whether a new or queued Subagent can start under `max_threads`.

  Only agents with status `"running"` count against the limit. This preserves the
  current Manager policy where terminal, detached, and queued agents do not
  consume runtime slots.
  """
  def can_start?(agents, max_threads)
      when is_list(agents) and is_integer(max_threads) and max_threads > 0 do
    with {:ok, count} <- running_count(agents) do
      {:ok, count < max_threads}
    end
  end

  def can_start?(_agents, _max_threads), do: invalid_schedule_args()

  @doc """
  Returns the next queued agent that can start, preserving parent insertion order.
  """
  def next_startable(agents) when is_list(agents) do
    queued = Enum.find(agents, &(Map.get(&1, :status) == @queued_status))

    cond do
      queued == nil ->
        {:ok, nil}

      true ->
        with {:ok, max_threads} <- queued_max_threads(queued),
             {:ok, can_start?} <- can_start?(agents, max_threads) do
          {:ok, if(can_start?, do: queued)}
        end
    end
  end

  def next_startable(_agents), do: invalid_schedule_args()

  @doc """
  Counts currently running Subagents in a parent fan-out.
  """
  def running_count(agents) when is_list(agents) do
    {:ok, Enum.count(agents, &(Map.get(&1, :status) == @running_status))}
  end

  def running_count(_agents), do: invalid_schedule_args()

  defp invalid_schedule_args do
    {:error, Tool.error(:invalid_args, "invalid subagent scheduler input", %{})}
  end

  defp queued_max_threads(%{max_threads: max_threads})
       when is_integer(max_threads) and max_threads > 0,
       do: {:ok, max_threads}

  defp queued_max_threads(_queued), do: invalid_schedule_args()
end
