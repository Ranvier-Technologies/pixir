defmodule PixirMonitor.SemanticZoomFixture do
  @moduledoc false

  @wave_sizes [30, 40, 20, 10]
  @workflow_id "semantic-zoom-100"
  @parent_id "20260715T000000-a1b2c3"

  def wave_sizes, do: @wave_sizes

  def limitation_input do
    input()
    |> Map.put("fixture_id", "semantic-zoom-100-limitation")
    |> put_in(["completeness", "child_logs"], "explicitly_missing")
  end

  def hostile_input do
    replacement_id = String.duplicate("A", 256)

    input()
    |> replace_value("wave-0-unit-00", replacement_id)
    |> replace_value("semantic_zoom_worker", "<script>alert('& hostile label')</script>\u202E")
  end

  def limitation_input_500 do
    input_500()
    |> Map.put("fixture_id", "semantic-zoom-500-limitation")
    |> put_in(["completeness", "child_logs"], "explicitly_missing")
  end

  def hostile_input_500 do
    id_target = steps_500() |> Enum.at(0) |> Map.fetch!("id")
    capped_label = "cap:" <> String.duplicate("Z", 32_764)

    input_500()
    |> Map.put("fixture_id", "semantic-zoom-500-hostile")
    |> put_step_field(41 * 1, "agent", "<script>alert('semantic zoom')</script>")
    |> put_step_field(41 * 2, "agent", "&lt;hostile&gt;&amp;&#x202E;")
    |> put_step_field(41 * 3, "agent", "right-to-left-override:\u202Epayload")
    |> put_step_field(41 * 4, "agent", capped_label)
    |> replace_value(id_target, String.duplicate("A", 256))
  end

  def malformed_input_500 do
    malformed_ids =
      steps_500()
      |> Enum.with_index()
      |> Enum.filter(fn {_step, ordinal} -> rem(ordinal, 41) == 0 end)
      |> MapSet.new(fn {step, _ordinal} -> step["id"] end)

    input_500()
    |> Map.put("fixture_id", "semantic-zoom-500-malformed")
    |> update_in(["inputs", "parent_log"], fn events ->
      Enum.map(events, &malformed_event(&1, malformed_ids))
    end)
    |> seed_input_reachable_malformed_fields()
  end

  defp seed_input_reachable_malformed_fields(input) do
    target = steps_500() |> List.first() |> Map.fetch!("id")
    malformed_observed_at = "2026-07-15 23:59:59Z"

    input
    |> put_in(["inputs", "terminal_envelope", "strategy"], "future_strategy")
    |> put_in(["inputs", "terminal_envelope", "mode"], "future_mode")
    |> put_in(
      ["inputs", "terminal_envelope", "steps"],
      [
        %{
          "step_id" => target,
          "apply_from" => "future-producer",
          "checkpoint" => %{
            "virtual_diff_apply" => %{
              "status" => "future_artifact_state",
              "artifact" => %{"sha256" => "future-artifact-hash"},
              "files" => []
            }
          }
        }
      ]
    )
    |> put_in(
      ["inputs", "runtime_diagnostics"],
      %{
        "parent_session_id" => @parent_id,
        "observed_at" => malformed_observed_at,
        "runtime_gaps" => [],
        "subagents" => []
      }
    )
    |> put_in(["inputs", "owner_state"], %{"reachable" => true})
    |> update_in(["inputs", "parent_log"], fn events ->
      events = Enum.map(events, &seed_target_malformed_event(&1, target))
      next_seq = events |> Enum.map(& &1["seq"]) |> Enum.max() |> Kernel.+(1)

      events ++
        [
          event(next_seq, "workflow_event", %{
            "kind" => "workflow_finished",
            "workflow_id" => "semantic-zoom-500",
            "status" => "future_execution_state"
          })
        ]
    end)
  end

  defp seed_target_malformed_event(event, target) do
    data = event["data"] || %{}
    step = get_in(data, ["delegation_context", "step_id"]) || data["step_id"]

    cond do
      step == target and data["event"] in ~w(finished failed timed_out cancelled detached closed) ->
        put_in(event, ["data", "summary"], ~s({"verdict":"future_advisory_verdict"}))

      step == target and data["kind"] in ~w(checkpoint_decided step_held) ->
        event
        |> put_in(["data", "checkpoint_status"], "future_gate_state")
        |> put_in(
          ["data", "checkpoint"],
          %{
            "artifact_refs" => [
              %{
                "kind" => "virtual_diff_apply",
                "version" => 1,
                "hash" => "future-artifact-hash",
                "workspace_strategy" => "isolated"
              }
            ]
          }
        )

      true ->
        event
    end
  end

  defp replace_value(value, target, replacement) when is_map(value) do
    Map.new(value, fn {key, item} -> {key, replace_value(item, target, replacement)} end)
  end

  defp replace_value(value, target, replacement) when is_list(value),
    do: Enum.map(value, &replace_value(&1, target, replacement))

  defp replace_value(target, target, replacement), do: replacement
  defp replace_value(value, _target, _replacement), do: value

  defp put_step_field(input, ordinal, field, replacement) do
    target = steps_500() |> Enum.at(ordinal) |> Map.fetch!("id")

    update_in(input, ["inputs", "parent_log"], fn events ->
      Enum.map(events, fn event ->
        map_graph_steps(event, fn steps ->
          Enum.map(steps, fn step ->
            if step["id"] == target, do: Map.put(step, field, replacement), else: step
          end)
        end)
      end)
    end)
  end

  defp malformed_event(event, malformed_ids) do
    data = event["data"] || %{}

    event =
      map_graph_steps(event, fn steps ->
        Enum.map(steps, fn step ->
          if MapSet.member?(malformed_ids, step["id"]) do
            step
            |> Map.put("execution_kind", "future_execution_kind")
            |> Map.put("workspace_mode", "future_workspace_mode")
            |> Map.put("posture", "future_posture")
          else
            step
          end
        end)
      end)

    step_id = get_in(data, ["delegation_context", "step_id"]) || data["step_id"]

    if MapSet.member?(malformed_ids, step_id) do
      Map.put(event, "ts", "malformed-timestamp-for-#{step_id}")
    else
      event
    end
  end

  defp map_graph_steps(event, fun) do
    case get_in(event, ["data", "graph", "steps"]) do
      steps when is_list(steps) -> put_in(event, ["data", "graph", "steps"], fun.(steps))
      _other -> event
    end
  end

  def input do
    steps = steps()
    events = [workflow_started(0, steps)] ++ lifecycle_events(steps) ++ gate_events(steps)

    %{
      "fixture_id" => "semantic-zoom-100-seed-348",
      "observed_at" => timestamp(length(events) + 1),
      "completeness" => %{
        "parent_log" => "complete",
        "child_logs" => "complete_through_observed_at"
      },
      "inputs" => %{
        "terminal_envelope" => %{
          "delegate_id" => @parent_id,
          "parent_session_id" => @parent_id,
          "workflow_id" => @workflow_id,
          "strategy" => "workflow",
          "mode" => "bounded_write"
        },
        "delegate_snapshot" => nil,
        "parent_log" => events,
        "parent_log_origin" => "fixture",
        "child_logs" => %{},
        "runtime_diagnostics" => nil,
        "owner_state" => %{"reachable" => false},
        "evidence_mirror" => nil,
        "observed_at" => timestamp(length(events) + 1)
      }
    }
  end

  def input_500 do
    steps = steps_500()
    events = [workflow_started_500(0, steps)] ++ lifecycle_events_500(steps) ++ gate_events_500(steps)

    %{
      "fixture_id" => "semantic-zoom-500-seed-377",
      "observed_at" => timestamp(length(events) + 1),
      "completeness" => %{
        "parent_log" => "complete",
        "child_logs" => "complete_through_observed_at"
      },
      "inputs" => %{
        "terminal_envelope" => %{
          "delegate_id" => @parent_id,
          "parent_session_id" => @parent_id,
          "workflow_id" => "semantic-zoom-500",
          "strategy" => "workflow",
          "mode" => "bounded_write"
        },
        "delegate_snapshot" => nil,
        "parent_log" => events,
        "parent_log_origin" => "fixture",
        "child_logs" => %{},
        "runtime_diagnostics" => nil,
        "owner_state" => %{"reachable" => false},
        "evidence_mirror" => nil,
        "observed_at" => timestamp(length(events) + 1)
      }
    }
  end

  defp steps_500 do
    waves =
      (List.duplicate(36, 12) ++ [34, 34])
      |> Enum.with_index()
      |> Enum.map(fn {size, wave} ->
        for ordinal <- 0..(size - 1), do: step_id(wave, ordinal)
      end)

    waves
    |> Enum.with_index()
    |> Enum.flat_map(fn {ids, wave} ->
      ids
      |> Enum.with_index()
      |> Enum.map(fn {id, ordinal} ->
        %{
          "id" => id,
          "agent" => "semantic_zoom_worker",
          "execution_kind" => "subagent",
          "workspace_mode" => "isolated",
          "posture" => "read_only",
          "depends_on" => dependencies_500(waves, wave, ordinal)
        }
      end)
    end)
  end

  defp dependencies_500(_waves, 0, _ordinal), do: []

  defp dependencies_500(waves, wave, ordinal) do
    previous_wave = Enum.at(waves, wave - 1)
    previous_size = length(previous_wave)

    [
      Enum.at(previous_wave, rem(ordinal * 5 + wave, previous_size)),
      Enum.at(previous_wave, rem(ordinal * 5 + wave + 1, previous_size))
    ]
  end

  defp workflow_started_500(seq, steps) do
    event(seq, "workflow_event", %{
      "kind" => "workflow_started",
      "workflow_id" => "semantic-zoom-500",
      "workflow_name" => "Deterministic 500-unit semantic zoom",
      "graph" => %{"steps" => steps}
    })
  end

  defp lifecycle_events_500(steps) do
    steps
    |> Enum.with_index()
    |> Enum.flat_map(fn {step, index} ->
      subagent_id = "zoom-scale-unit-" <> String.pad_leading(Integer.to_string(index), 3, "0")
      child_id = "20260715T" <> String.pad_leading(Integer.to_string(rem(index, 60)), 6, "0") <> "-" <> String.pad_leading(Integer.to_string(index, 16), 6, "0")
      base = 1 + index * 2
      context = %{"step_id" => step["id"]}

      started =
        event(base, "subagent_event", %{
          "event" => "started",
          "status" => "running",
          "subagent_id" => subagent_id,
          "child_session_id" => child_id,
          "agent" => step["agent"],
          "workspace_mode" => step["workspace_mode"],
          "delegation_context" => context
        })

      terminal =
        Enum.at(
          ~w(completed completed completed failed timed_out cancelled detached closed),
          rem(index * 3 + div(index, 36), 8)
        )

      finished =
        event(base + 1, "subagent_event", %{
          "event" => terminal_event(terminal),
          "status" => terminal,
          "subagent_id" => subagent_id,
          "child_session_id" => child_id,
          "delegation_context" => context,
          "summary" => nil
        })

      [started, finished]
    end)
  end

  defp gate_events_500(steps) do
    offset = 1 + length(steps) * 2
    checkpoints = ~w(checkpoint_ready partial checkpoint_ready failed held checkpoint_ready needs_orchestrator)

    steps
    |> Enum.with_index()
    |> Enum.map(fn {step, index} ->
      checkpoint = Enum.at(checkpoints, rem(index * 5 + div(index, 36), length(checkpoints)))

      event(offset + index, "workflow_event", %{
        "kind" => if(checkpoint == "held", do: "step_held", else: "checkpoint_decided"),
        "workflow_id" => "semantic-zoom-500",
        "step_id" => step["id"],
        "checkpoint_status" => checkpoint,
        "dependent_safe" => checkpoint == "checkpoint_ready"
      })
    end)
  end

  def steps do
    waves =
      @wave_sizes
      |> Enum.with_index()
      |> Enum.map(fn {size, wave} ->
        for ordinal <- 0..(size - 1), do: step_id(wave, ordinal)
      end)

    waves
    |> Enum.with_index()
    |> Enum.flat_map(fn {ids, wave} ->
      ids
      |> Enum.with_index()
      |> Enum.map(fn {id, ordinal} ->
        %{
          "id" => id,
          "agent" => "semantic_zoom_worker",
          "execution_kind" => "subagent",
          "workspace_mode" => "isolated",
          "posture" => "read_only",
          "depends_on" => dependencies(waves, wave, ordinal)
        }
      end)
    end)
  end

  defp dependencies(_waves, 0, _ordinal), do: []

  defp dependencies(waves, wave, ordinal) do
    previous = Enum.at(Enum.at(waves, wave - 1), rem(ordinal * 7 + wave, length(Enum.at(waves, wave - 1))))

    if wave >= 2 and rem(ordinal, 3) == 0 do
      skipped = Enum.at(Enum.at(waves, wave - 2), rem(ordinal * 11 + wave, length(Enum.at(waves, wave - 2))))
      [previous, skipped]
    else
      [previous]
    end
  end

  defp workflow_started(seq, steps) do
    event(seq, "workflow_event", %{
      "kind" => "workflow_started",
      "workflow_id" => @workflow_id,
      "workflow_name" => "Deterministic 100-unit semantic zoom",
      "graph" => %{"steps" => steps}
    })
  end

  defp lifecycle_events(steps) do
    steps
    |> Enum.with_index()
    |> Enum.flat_map(fn {step, index} ->
      subagent_id = "zoom-unit-" <> String.pad_leading(Integer.to_string(index), 3, "0")
      child_id = "20260715T" <> String.pad_leading(Integer.to_string(rem(index, 60)), 6, "0") <> "-" <> String.pad_leading(Integer.to_string(index, 16), 6, "0")
      base = 1 + index * 2
      context = %{"step_id" => step["id"]}

      started =
        event(base, "subagent_event", %{
          "event" => "started",
          "status" => "running",
          "subagent_id" => subagent_id,
          "child_session_id" => child_id,
          "agent" => step["agent"],
          "workspace_mode" => step["workspace_mode"],
          "delegation_context" => context
        })

      terminal = Enum.at(~w(completed completed completed failed timed_out cancelled detached closed), rem(index, 8))

      finished =
        event(base + 1, "subagent_event", %{
          "event" => terminal_event(terminal),
          "status" => terminal,
          "subagent_id" => subagent_id,
          "child_session_id" => child_id,
          "delegation_context" => context,
          "summary" => nil
        })

      [started, finished]
    end)
  end

  defp gate_events(steps) do
    offset = 1 + length(steps) * 2

    steps
    |> Enum.with_index()
    |> Enum.map(fn {step, index} ->
      checkpoint = Enum.at(~w(checkpoint_ready checkpoint_ready checkpoint_ready partial failed held needs_orchestrator), rem(index, 7))

      event(offset + index, "workflow_event", %{
        "kind" => if(checkpoint == "held", do: "step_held", else: "checkpoint_decided"),
        "workflow_id" => @workflow_id,
        "step_id" => step["id"],
        "checkpoint_status" => checkpoint,
        "dependent_safe" => checkpoint == "checkpoint_ready"
      })
    end)
  end

  defp terminal_event("failed"), do: "failed"
  defp terminal_event("timed_out"), do: "timed_out"
  defp terminal_event("cancelled"), do: "cancelled"
  defp terminal_event("detached"), do: "detached"
  defp terminal_event("closed"), do: "closed"
  defp terminal_event(_status), do: "finished"

  defp step_id(wave, ordinal), do: "wave-#{wave}-unit-#{String.pad_leading(Integer.to_string(ordinal), 2, "0")}"

  defp event(seq, type, data) do
    %{"seq" => seq, "ts" => timestamp(seq), "type" => type, "data" => data}
  end

  defp timestamp(seq) do
    seconds = rem(seq, 86_400)
    hour = div(seconds, 3_600)
    minute = div(rem(seconds, 3_600), 60)
    second = rem(seconds, 60)
    "2026-07-15T#{pad(hour)}:#{pad(minute)}:#{pad(second)}Z"
  end

  defp pad(value), do: value |> Integer.to_string() |> String.pad_leading(2, "0")
end
