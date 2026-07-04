defmodule Pixir.BranchSummary do
  @moduledoc """
  Deterministic branch summaries recorded at fork time (ADR 0024).

  A `branch_summary` Event condenses the replayed parent prefix the child inherited.
  The full replayed prefix in the child Log remains authoritative for audit.
  """

  alias Pixir.{Event, Tool}

  @strategy "deterministic_operational_summary_v1"
  @summary_limit 480

  @doc "Strategy name recorded on deterministic fork summaries."
  @spec strategy() :: String.t()
  def strategy, do: @strategy

  @doc "Build canonical `branch_summary` event data for a forked prefix."
  @spec event_data([Event.t()], map()) :: map()
  def event_data(replay_events, plan) when is_list(replay_events) and is_map(plan) do
    %{
      "strategy" => @strategy,
      "parent_session_id" => plan["parent_session_id"],
      "forked_to_seq" => plan["to_seq"],
      "range" => %{
        "from_seq" => plan["from_seq"],
        "to_seq" => plan["to_seq"]
      },
      "source_event_count" => length(replay_events),
      "event_counts" => event_counts(replay_events),
      "tool_calls" => tool_calls(replay_events),
      "files_touched" => files_touched(replay_events),
      "open_tasks" => open_tasks(replay_events),
      "limitations" => limitations(),
      "summary" => summary(replay_events)
    }
  end

  @doc "Render branch summary data as interpretive Provider input."
  @spec render_for_provider(map()) :: String.t()
  def render_for_provider(data) when is_map(data) do
    range = data["range"] || %{}

    """
    Branch summary from forked parent prefix
    Parent: #{data["parent_session_id"] || "unknown"}
    Range: seq #{range["from_seq"]}..#{range["to_seq"]} (#{data["source_event_count"]} events)
    Strategy: #{data["strategy"]}

    Summary:
    #{data["summary"]}

    Files touched:
    #{bullet_list(data["files_touched"] || [])}

    Open tasks:
    #{bullet_list(data["open_tasks"] || [])}

    Limitations:
    #{bullet_list(data["limitations"] || [])}
    """
    |> String.trim()
  end

  defp limitations do
    [
      "Deterministic branch summary condenses the forked prefix; it is not a semantic substitute for the full replayed Log.",
      "The full replayed prefix in the child Log remains authoritative for audit, resume repair, and deeper reconstruction."
    ]
  end

  defp event_counts(events) do
    events
    |> Enum.frequencies_by(&Atom.to_string(&1.type))
    |> Enum.into(%{})
  end

  defp tool_calls(events) do
    events
    |> Enum.filter(&(&1.type == :tool_call))
    |> Enum.map(fn event ->
      %{
        "seq" => event.seq,
        "call_id" => event.data["call_id"],
        "name" => event.data["name"]
      }
    end)
  end

  defp files_touched(events) do
    events
    |> Enum.flat_map(&event_paths/1)
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.take(30)
  end

  defp event_paths(%{type: :tool_call, data: %{"args" => args}}) when is_map(args) do
    args
    |> Enum.flat_map(fn
      {_key, value} when is_binary(value) ->
        if path_like?(value), do: [value], else: []

      {_key, values} when is_list(values) ->
        Enum.filter(values, &(is_binary(&1) and path_like?(&1)))

      _other ->
        []
    end)
  end

  defp event_paths(_event), do: []

  defp path_like?(value) do
    String.contains?(value, "/") or String.contains?(value, ".")
  end

  defp open_tasks(events) do
    events
    |> Enum.filter(&(&1.type in [:user_message, :assistant_message, :subagent_event]))
    |> Enum.take(-8)
    |> Enum.map(&event_excerpt/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp summary(events) do
    counts =
      events
      |> event_counts()
      |> Enum.sort()
      |> Enum.map_join(", ", fn {type, count} -> "#{type}=#{count}" end)

    excerpts =
      events
      |> Enum.filter(&(&1.type in [:user_message, :assistant_message, :subagent_event]))
      |> Enum.take(-6)
      |> Enum.map_join("\n", &("- " <> event_excerpt(&1)))

    """
    Forked #{length(events)} replayed events (#{counts}).
    Recent forked conversational facts:
    #{if excerpts == "", do: "- none recorded", else: excerpts}
    """
    |> String.trim()
  end

  defp event_excerpt(%{type: :user_message, data: %{"text" => text}}),
    do: "user: " <> excerpt(text)

  defp event_excerpt(%{type: :assistant_message, data: %{"text" => text}}),
    do: "assistant: " <> excerpt(text)

  defp event_excerpt(%{type: :subagent_event, data: data}) do
    summary = data["summary"] || data["status"] || data["event"] || ""
    "subagent #{data["subagent_id"] || "unknown"}: " <> excerpt(summary)
  end

  defp event_excerpt(_event), do: ""

  defp excerpt(text) when is_binary(text) do
    text
    |> String.replace(~r/\s+/, " ")
    |> Tool.truncate(@summary_limit)
  end

  defp excerpt(other), do: other |> inspect() |> excerpt()

  defp bullet_list([]), do: "- none"

  defp bullet_list(items) do
    items
    |> Enum.take(20)
    |> Enum.map_join("\n", &("- " <> to_string(&1)))
  end
end
