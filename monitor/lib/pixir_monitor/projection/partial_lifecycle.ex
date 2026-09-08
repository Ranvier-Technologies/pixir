defmodule PixirMonitor.Projection.PartialLifecycle do
  @moduledoc """
  Validates retained lifecycle segments without reconstructing an unread middle.

  The bounded Log selection is the only gap authority. Each logical unit starts
  closed in the complete prefix and with unknown linkage in the tail. Once a
  tail start or close establishes state, ordinary exact-target rules apply;
  subsequent unmatched closes are not explained away as more missing history.

  Returns the validated prefix for durable ordinal construction. Tail records
  remain canonical unit evidence, not attempts with invented ordinals.
  """

  alias PixirMonitor.Projection.AttemptStatus

  @terminal ~w(completed failed timed_out cancelled detached closed)
  @lifecycle ~w(queued started input retrying finished failed timed_out cancelled detached closed)

  @spec fold([map()], map()) :: {:ok, map()} | {:error, map()}
  def fold(events, %{"partial" => true, "tail_first_seq" => boundary})
      when is_list(events) and is_integer(boundary) and boundary >= 0 do
    with {:ok, _last_seq} <- validate_order(events) do
      {prefix, tail} = Enum.split_while(events, &(&1["seq"] < boundary))

      with {:ok, prefix_state} <- segment(prefix, :closed),
           {:ok, _tail_state} <- segment(tail, :unknown) do
        {:ok, %{prefix: prefix, tail: tail, prefix_open: match?({:active, _}, prefix_state)}}
      end
    end
  end

  def fold(_events, _selection), do: failure("partial_lifecycle_selection_invalid", nil)

  defp validate_order(events) do
    Enum.reduce_while(events, {:ok, -1}, fn
      %{"seq" => seq, "data" => data}, {:ok, previous} when is_integer(seq) and seq > previous and is_map(data) ->
        {:cont, {:ok, seq}}

      _event, _acc ->
        {:halt, failure("partial_lifecycle_events_invalid", nil)}
    end)
  end

  defp segment(events, initial) do
    Enum.reduce_while(events, {:ok, initial}, fn event, {:ok, state} ->
      case transition(event, state) do
        {:ok, next} -> {:cont, {:ok, next}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp transition(event, state) do
    data = event["data"] || %{}
    kind = data["event"]
    child = data["child_session_id"]

    cond do
      kind not in @lifecycle ->
        failure("subagent_event_kind_unrecognized", event)

      kind in ~w(queued retrying) and data["status"] not in [nil | @terminal ++ ~w(queued running unknown)] ->
        failure("attempt_status_invalid", event)

      not valid_identities?(data) or (kind != "queued" and not valid_target?(data, kind)) ->
        failure("attempt_child_identity_invalid", event)

      kind == "queued" ->
        {:ok, state}

      kind in ~w(started input) ->
        with {:ok, _status} <- AttemptStatus.start_status(data) do
          case state do
            {:active, _} -> failure("attempt_unit_overlap", event)
            _ -> {:ok, {:active, child}}
          end
        else
          {:error, _} -> failure("attempt_start_status_invalid", event)
        end

      kind == "retrying" ->
        close(state, data["failed_child_session_id"] || child, event, "attempt_retry_target_unresolved")

      data["status"] not in @terminal ->
        failure("attempt_terminal_status_invalid", event)

      true ->
        close(state, child, event, "attempt_terminal_target_unresolved")
    end
  end

  defp valid_identities?(data) do
    Enum.all?([data["child_session_id"], data["failed_child_session_id"]], &(is_nil(&1) or Pixir.SessionId.valid?(&1)))
  end

  defp valid_target?(data, kind) do
    target = if kind == "retrying", do: data["failed_child_session_id"] || data["child_session_id"], else: data["child_session_id"]
    Pixir.SessionId.valid?(target)
  end

  defp close(:unknown, _child, _event, _kind), do: {:ok, :closed}
  defp close({:active, child}, child, _event, _kind), do: {:ok, :closed}
  defp close(_state, _child, event, kind), do: failure(kind, event)

  defp failure(kind, event) do
    {:error,
     %{
       kind: kind,
       message: "Retained lifecycle evidence cannot be projected without inventing attempt state",
       details: %{seq: event && event["seq"]}
     }}
  end
end
