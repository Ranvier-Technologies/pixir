defmodule PixirMonitor.Test.FanoutFixture do
  @moduledoc false

  # Deterministic index math only: this fixture contains no randomized behavior.
  @families ~w(execution advisory liveness mutation virtual_diff evidence)
  @family_reasons %{
    "execution" => "execution_failed",
    "advisory" => "advisory_stop",
    "liveness" => "nonterminal_stale_handle",
    "mutation" => "mutation_partial",
    "virtual_diff" => "virtual_diff_unapplied",
    "evidence" => "child_log_missing"
  }

  def parent_events do
    1..500
    |> Enum.flat_map(&events_for/1)
    |> Enum.with_index(1)
    |> Enum.map(fn {event, seq} -> Map.put(event, "seq", seq) end)
  end

  def units(events) do
    events
    |> Enum.group_by(&get_in(&1, ["data", "subagent_id"]))
    |> Enum.map(fn {id, rows} ->
      first = Enum.min_by(rows, & &1["seq"])
      last = Enum.max_by(rows, & &1["seq"])

      %{
        id: id,
        seq: first["seq"],
        agent: get_in(first, ["data", "agent"]),
        reasons:
          rows
          |> Enum.flat_map(&(get_in(&1, ["data", "fixture_attention_reasons"]) || []))
          |> Enum.uniq(),
        execution: get_in(last, ["data", "status"]),
        attempts: rows |> Enum.map(&get_in(&1, ["data", "attempt_index"])) |> Enum.uniq()
      }
    end)
    |> Enum.sort_by(& &1.seq)
  end

  defp events_for(index) do
    reasons = reasons_for(index)
    agent = if index == 3, do: "<img src=x onerror=alert(1)>\u202Ehostile", else: "worker-#{index}"
    status = if reasons == [], do: "completed", else: "failed"

    initial = event(index, agent, status, 0, reasons)

    if rem(index, 100) == 0 do
      [initial, event(index, agent, status, 1, reasons)]
    else
      [initial]
    end
  end

  defp reasons_for(1),
    do: ["execution_failed", "advisory_stop", "mutation_partial", "child_log_missing"]

  defp reasons_for(2), do: ["child_log_missing"]
  defp reasons_for(79), do: ["execution_failed", "mixed_future_reason"]
  defp reasons_for(80), do: ["evidence_like_thing"]

  defp reasons_for(index) when index <= 80 do
    family = Enum.at(@families, rem(index - 3, length(@families)))
    [Map.fetch!(@family_reasons, family)]
  end

  defp reasons_for(_index), do: []

  defp event(index, agent, status, attempt, reasons) do
    %{
      "type" => "subagent_event",
      "data" => %{
        "subagent_id" => "fanout-#{index}",
        "agent" => agent,
        "status" => status,
        "attempt_index" => attempt,
        "fixture_attention_reasons" => reasons
      }
    }
  end
end
