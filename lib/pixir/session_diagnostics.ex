defmodule Pixir.SessionDiagnostics do
  @moduledoc """
  Read-only diagnostics for one Pixir Session.

  `Pixir.Doctor` answers "can this local Pixir install run?". This module answers
  "is this Session replayable and internally coherent?" by combining Log facts,
  Workflow decision evidence, Provider replay inspection, Session tree projection,
  and Provider usage metadata without calling auth, the network, or the model.
  """

  alias Pixir.{Log, ReplayInspector, SessionTree, Subagents, Tool}

  @doc "Run local, no-network diagnostics for `session_id`."
  @spec run(String.t(), keyword()) :: {:ok, map()} | {:error, map()}
  def run(session_id, opts \\ [])

  def run(session_id, opts) when is_binary(session_id) do
    workspace = opts |> Keyword.get(:workspace, File.cwd!()) |> Path.expand()

    if Log.exists?(session_id, workspace: workspace) do
      with {:ok, history} <- Log.fold(session_id, workspace: workspace),
           {:ok, replay} <- ReplayInspector.inspect(session_id, workspace: workspace),
           {:ok, tree} <- SessionTree.project(session_id, workspace: workspace) do
        subagents_runtime = subagents_runtime_summary(session_id)
        {:ok, report(session_id, workspace, history, replay, tree, subagents_runtime, opts)}
      end
    else
      {:error,
       Tool.error(:not_found, "session log not found", %{
         session_id: session_id,
         workspace: workspace,
         log_path: Log.path(session_id, workspace: workspace),
         next_actions: [
           "check the session id",
           "run pixir diagnose session from the workspace that owns the session log"
         ]
       })}
    end
  end

  def run(_session_id, _opts),
    do: {:error, Tool.error(:invalid_args, "session id must be a string", %{})}

  defp report(session_id, workspace, history, replay, tree, subagents_runtime, opts) do
    workflows = workflow_diagnostics(history)
    checks = checks(history, replay, tree, subagents_runtime, workflows, opts)

    %{
      "ok" => Enum.all?(checks, &(&1["status"] != "failed")),
      "status" => status(checks),
      "session_id" => session_id,
      "workspace" => workspace,
      "log_path" => Log.path(session_id, workspace: workspace),
      "checks" => checks,
      "events" => event_summary(history),
      "replay" => replay["provider_input"],
      "continuation" => replay["continuation"],
      "tree" => tree_summary(tree),
      "workflows" => workflows,
      "subagents_runtime" => subagents_runtime,
      "provider_usage" => provider_usage_summary(history),
      "next_actions" => next_actions(checks)
    }
  end

  defp checks(history, replay, tree, subagents_runtime, workflows, opts) do
    [
      log_check(history),
      tool_pairing_check(history),
      parent_wait_check(history),
      turn_completion_check(history),
      partial_assistant_check(history),
      turn_failure_check(history),
      subagent_timeout_check(history),
      workflow_event_check(workflows),
      workflow_checkpoint_check(workflows),
      subagent_terminal_state_check(tree),
      subagent_staleness_check(tree, opts),
      subagent_manager_runtime_check(tree, subagents_runtime),
      replay_check(replay),
      tree_check(tree),
      continuation_check(replay["continuation"])
    ]
  end

  defp log_check(history) do
    if history == [] do
      failed("log", "Session Log is empty.", %{})
    else
      passed("log", "Session Log is readable.", %{"event_count" => length(history)})
    end
  end

  defp turn_completion_check(history) do
    incomplete = incomplete_tool_turns(history)

    if incomplete == [] do
      passed(
        "turn_completion",
        "Every user turn with tool/provider activity has assistant or failure evidence.",
        %{}
      )
    else
      warning(
        "turn_completion",
        "Some user turns have tool/provider activity but no following assistant_message.",
        %{
          "classification" => "missing_canonical_assistant_after_provider_activity",
          "turns" => incomplete,
          "next_actions" => [
            "inspect the session log around each user_seq",
            "check whether the Provider stream ended before a final assistant response",
            "rerun or resume the session after deciding whether the missing final answer is acceptable"
          ]
        }
      )
    end
  end

  defp partial_assistant_check(history) do
    partials = partial_assistant_messages(history)

    if partials == [] do
      passed(
        "assistant_canonicalization",
        "No partial assistant_message recovery markers found.",
        %{}
      )
    else
      warning(
        "assistant_canonicalization",
        "Pixir preserved partial assistant text after a Provider stream error.",
        %{
          "classification" => "partial_assistant_preserved_after_provider_error",
          "messages" => partials,
          "next_actions" => [
            "inspect the provider log for stream termination",
            "treat the assistant_message as partial evidence, not a clean final answer",
            "rerun the turn if a complete final answer is required"
          ]
        }
      )
    end
  end

  defp turn_failure_check(history) do
    tool_call_ids =
      history
      |> by_type(:tool_call)
      |> Enum.map(& &1.data["call_id"])
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    tool_result_ids =
      history
      |> by_type(:tool_result)
      |> Enum.map(& &1.data["call_id"])
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    failures =
      history
      |> by_type(:turn_failed)
      |> Enum.map(fn event ->
        failure = %{
          "seq" => event.seq,
          "terminal_status" => event.data["terminal_status"],
          "error_kind" => event.data["error_kind"],
          "has_details" => event.data["details"] not in [nil, %{}]
        }

        failure
        |> maybe_put_recovery(event.data["details"])
        |> maybe_put_missing_output_diagnosis(
          event.data["error_message"],
          tool_call_ids,
          tool_result_ids
        )
      end)

    if failures == [] do
      passed("turn_failure_evidence", "No durable turn_failed events found.", %{})
    else
      remote_desync? =
        Enum.any?(
          failures,
          &(get_in(&1, ["provider_missing_output", "classification"]) ==
              "remote_continuation_desync")
        )

      stream_idle? =
        Enum.any?(
          failures,
          &(get_in(&1, ["recovery", "classification"]) == "provider_stream_idle_timeout")
        )

      warning(
        "turn_failure_evidence",
        "Pixir recorded durable audit evidence for failed Turns.",
        %{
          "classification" => turn_failure_classification(remote_desync?, stream_idle?),
          "failures" => failures,
          "next_actions" => turn_failure_next_actions(remote_desync?, stream_idle?)
        }
      )
    end
  end

  defp maybe_put_recovery(failure, %{"recovery" => %{} = recovery}),
    do: Map.put(failure, "recovery", recovery)

  defp maybe_put_recovery(failure, _details), do: failure

  defp maybe_put_missing_output_diagnosis(failure, message, tool_call_ids, tool_result_ids)
       when is_binary(message) do
    case Regex.run(~r/No tool output found for function call ([A-Za-z0-9_:-]+)/, message) do
      [_, call_id] ->
        Map.put(failure, "provider_missing_output", %{
          "call_id" => call_id,
          "classification" =>
            missing_output_classification(call_id, tool_call_ids, tool_result_ids),
          "known_local_tool_call" => MapSet.member?(tool_call_ids, call_id),
          "known_local_tool_result" => MapSet.member?(tool_result_ids, call_id)
        })

      _ ->
        failure
    end
  end

  defp maybe_put_missing_output_diagnosis(failure, _message, _tool_call_ids, _tool_result_ids),
    do: failure

  defp missing_output_classification(call_id, tool_call_ids, tool_result_ids) do
    cond do
      not MapSet.member?(tool_call_ids, call_id) ->
        "remote_continuation_desync"

      not MapSet.member?(tool_result_ids, call_id) ->
        "local_missing_tool_output"

      true ->
        "provider_rejected_known_paired_call"
    end
  end

  defp turn_failure_classification(true, _stream_idle?), do: "remote_continuation_desync"
  defp turn_failure_classification(_remote_desync?, true), do: "provider_stream_idle_timeout"

  defp turn_failure_classification(_remote_desync?, _stream_idle?),
    do: "durable_turn_failure_evidence"

  defp turn_failure_next_actions(true, _stream_idle?) do
    [
      "treat the missing call_id as provider-side continuation evidence, not local Log corruption",
      "inspect continuation metadata around the preceding provider_usage event",
      "retry with full replay and no previous_response_id if a complete answer is required"
    ]
  end

  defp turn_failure_next_actions(_remote_desync?, true) do
    [
      "inspect diagnostics before resuming write-capable work",
      "use the recorded resume_command only after checking for completed side effects",
      "do not auto-replay ambiguous idle-timeout Turns until a resume policy is explicitly chosen"
    ]
  end

  defp turn_failure_next_actions(_remote_desync?, _stream_idle?) do
    [
      "inspect each turn_failed event and its surrounding log entries",
      "treat turn_failed as audit evidence, not Provider replay context",
      "rerun or resume the session if a complete assistant answer is required"
    ]
  end

  defp subagent_timeout_check(history) do
    timeouts =
      history
      |> by_type(:subagent_event)
      |> Enum.filter(fn event ->
        event.data["event"] == "timed_out" or event.data["status"] == "timed_out"
      end)
      |> Enum.map(fn event ->
        missing =
          [
            "subagent_id",
            "child_session_id",
            "child_log_path",
            "agent",
            "status",
            "timeout_ms",
            "deadline_at",
            "elapsed_ms",
            "reason",
            "next_actions"
          ]
          |> Enum.reject(fn key -> present?(event.data[key]) end)

        %{
          "seq" => event.seq,
          "subagent_id" => event.data["subagent_id"],
          "child_session_id" => event.data["child_session_id"],
          "child_log_path" => event.data["child_log_path"],
          "agent" => event.data["agent"],
          "status" => event.data["status"],
          "reason" => event.data["reason"],
          "timeout_ms" => event.data["timeout_ms"],
          "deadline_at" => event.data["deadline_at"],
          "elapsed_ms" => event.data["elapsed_ms"],
          "next_actions" => event.data["next_actions"] || [],
          "missing_fields" => missing
        }
      end)

    cond do
      timeouts == [] ->
        passed("subagent_timeouts", "No Subagent timeout events found.", %{})

      Enum.any?(timeouts, &(not Enum.empty?(&1["missing_fields"]))) ->
        warning(
          "subagent_timeouts",
          "Pixir found Subagent timeout events with incomplete diagnostic fields.",
          %{
            "classification" => "subagent_timeout_incomplete_evidence",
            "timeouts" => timeouts,
            "next_actions" => [
              "rerun with a Pixir version that records enriched timeout evidence"
            ]
          }
        )

      true ->
        warning(
          "subagent_timeouts",
          "Pixir found explicit Subagent timeout evidence.",
          %{
            "classification" => "subagent_timeout_evidence",
            "timeouts" => timeouts,
            "next_actions" => [
              "inspect the child_session_id log",
              "retry the Subagent with a larger timeout or reduced task scope"
            ]
          }
        )
    end
  end

  defp subagent_terminal_state_check(tree) do
    states =
      tree
      |> all_subagent_records()
      |> Enum.map(&subagent_terminal_state/1)

    notable =
      Enum.reject(states, fn state ->
        state["classification"] in ["completed", "closed"]
      end)

    incomplete = Enum.filter(states, &(not Enum.empty?(&1["missing_fields"])))

    cond do
      states == [] ->
        passed("subagent_terminal_states", "No Subagent terminal state evidence found.", %{})

      incomplete != [] ->
        warning(
          "subagent_terminal_states",
          "Some Subagent terminal states are missing diagnostic fields.",
          %{
            "classification" => "subagent_terminal_state_incomplete_evidence",
            "states" => states,
            "incomplete" => incomplete,
            "next_actions" => [
              "inspect each subagent child_session_id log",
              "rerun with a Pixir version that records enriched terminal evidence"
            ]
          }
        )

      notable != [] ->
        warning(
          "subagent_terminal_states",
          "Pixir found non-completed Subagent terminal or lifecycle states.",
          %{
            "classification" => "subagent_terminal_state_evidence",
            "states" => states,
            "notable" => notable,
            "next_actions" => [
              "inspect non-completed child_session_id logs",
              "retry failed or timed-out Subagents after reducing scope or increasing timeout"
            ]
          }
        )

      true ->
        passed(
          "subagent_terminal_states",
          "All Subagent terminal states are completed or closed.",
          %{"states" => states}
        )
    end
  end

  defp subagent_staleness_check(tree, opts) do
    threshold_ms = Keyword.get(opts, :stale_after_ms, 300_000)
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)

    stale =
      tree
      |> all_subagent_records()
      |> Enum.filter(
        &(subagent_classification(&1["status"] || "unknown", &1["reason"]) in [
            "running",
            "queued"
          ])
      )
      |> Enum.flat_map(&stale_subagent_record(&1, now, threshold_ms))

    if stale == [] do
      passed("subagent_staleness", "No stale running or queued Subagent records found.", %{
        "stale_after_ms" => threshold_ms
      })
    else
      warning(
        "subagent_staleness",
        "Pixir found running or queued Subagents with stale child Log evidence.",
        %{
          "classification" => "stale_running_or_queued_subagent",
          "stale_after_ms" => threshold_ms,
          "subagents" => stale,
          "next_actions" => [
            "inspect each child_session_id log",
            "wait_agent again if the child process is still expected to run",
            "mark or retry stale children if no new Log evidence appears"
          ]
        }
      )
    end
  end

  defp subagent_manager_runtime_check(_tree, %{"available" => false} = runtime) do
    warning(
      "subagent_manager_runtime",
      "Subagent Manager runtime snapshot is unavailable.",
      %{
        "classification" => "subagent_manager_unavailable",
        "error" => runtime["error"],
        "next_actions" => [
          "check whether the Pixir application supervisor is running",
          "inspect the parent Session Log for durable Subagent state"
        ]
      }
    )
  end

  defp subagent_manager_runtime_check(tree, runtime) do
    runtime_gaps = runtime["runtime_gaps"] || []
    missing_runtime = missing_runtime_open_subagents(tree, runtime)

    if runtime_gaps == [] and missing_runtime == [] do
      passed("subagent_manager_runtime", "Subagent Manager runtime snapshot is coherent.", %{
        "known_subagent_count" => runtime["known_subagent_count"] || 0,
        "running_count" => runtime["running_count"] || 0,
        "queued_count" => runtime["queued_count"] || 0,
        "active_waiter_count" => runtime["active_waiter_count"] || 0,
        "child_index_count" => runtime["child_index_count"] || 0,
        "message_queue_len" => runtime["message_queue_len"]
      })
    else
      warning(
        "subagent_manager_runtime",
        "Subagent Manager runtime has gaps relative to live state or durable open Subagents.",
        %{
          "classification" => "subagent_manager_runtime_gap",
          "runtime_gaps" => runtime_gaps,
          "missing_runtime_open_subagents" => missing_runtime,
          "next_actions" => [
            "inspect the runtime_gaps and missing_runtime_open_subagents lists",
            "run pixir tree for the parent Session",
            "call wait_agent, close stale children, or restart the manager after choosing recovery"
          ]
        }
      )
    end
  end

  defp workflow_event_check(%{"event_count" => 0} = workflows) do
    passed("workflow_events", "No Workflow events found.", workflow_check_details(workflows))
  end

  defp workflow_event_check(workflows) do
    gaps = workflow_gaps(workflows, "event_gaps")

    if gaps == [] do
      passed(
        "workflow_events",
        "Workflow event spines are complete enough for diagnosis.",
        workflow_check_details(workflows)
      )
    else
      warning(
        "workflow_events",
        "Pixir found Workflow event spines with diagnostic gaps.",
        Map.merge(workflow_check_details(workflows), %{
          "classification" => "workflow_event_diagnostic_gaps",
          "gaps" => gaps,
          "next_actions" => [
            "inspect workflow_event entries for each affected workflow_id",
            "treat workflows without workflow_finished as interrupted or unknown",
            "rerun or repair the workflow after deciding whether inherited evidence is usable"
          ]
        })
      )
    end
  end

  defp workflow_checkpoint_check(%{"event_count" => 0} = workflows) do
    passed(
      "workflow_checkpoints",
      "No Workflow checkpoint decisions found.",
      workflow_check_details(workflows)
    )
  end

  defp workflow_checkpoint_check(%{"checkpoint_decision_count" => 0} = workflows) do
    warning(
      "workflow_checkpoints",
      "Pixir found Workflow events without checkpoint decisions.",
      Map.merge(workflow_check_details(workflows), %{
        "classification" => "workflow_checkpoint_decisions_missing",
        "next_actions" => [
          "inspect workflow_event entries to determine whether the Workflow was interrupted early",
          "treat dependency readiness as unknown until checkpoint_decided evidence exists"
        ]
      })
    )
  end

  defp workflow_checkpoint_check(workflows) do
    gaps = workflow_gaps(workflows, "checkpoint_gaps")

    if gaps == [] do
      passed(
        "workflow_checkpoints",
        "Workflow checkpoint decisions expose typed payload and artifact references.",
        workflow_check_details(workflows)
      )
    else
      warning(
        "workflow_checkpoints",
        "Pixir found Workflow checkpoint decisions with incomplete typed evidence.",
        Map.merge(workflow_check_details(workflows), %{
          "classification" => "workflow_checkpoint_diagnostic_gaps",
          "gaps" => gaps,
          "next_actions" => [
            "inspect checkpoint_decided events for missing typed_schema_ids or artifact refs",
            "prefer Checkpoint Bundle v2 evidence before unlocking dependents",
            "rerun with a Pixir version that records typed checkpoint projections when needed"
          ]
        })
      )
    end
  end

  defp workflow_check_details(workflows) do
    %{
      "workflow_count" => workflows["count"],
      "event_count" => workflows["event_count"],
      "checkpoint_decision_count" => workflows["checkpoint_decision_count"],
      "workflow_ids" => Enum.map(workflows["runs"], & &1["workflow_id"])
    }
  end

  defp workflow_gaps(workflows, key) do
    workflows["runs"]
    |> Enum.flat_map(fn run ->
      run
      |> Map.get(key, [])
      |> Enum.map(&Map.put(&1, "workflow_id", run["workflow_id"]))
    end)
  end

  defp tool_pairing_check(history) do
    call_ids = history |> by_type(:tool_call) |> Enum.map(& &1.data["call_id"])
    result_ids = history |> by_type(:tool_result) |> Enum.map(& &1.data["call_id"])
    missing = call_ids -- result_ids
    extra = result_ids -- call_ids

    cond do
      missing != [] ->
        failed("tool_pairing", "Some tool_call events have no matching tool_result.", %{
          "missing_result_ids" => missing,
          "extra_result_ids" => extra
        })

      extra != [] ->
        warning("tool_pairing", "Some tool_result events have no matching tool_call.", %{
          "missing_result_ids" => missing,
          "extra_result_ids" => extra
        })

      true ->
        passed("tool_pairing", "All tool_call events have matching tool_result events.", %{
          "tool_calls" => length(call_ids),
          "tool_results" => length(result_ids)
        })
    end
  end

  defp parent_wait_check(history) do
    wait_calls =
      history
      |> by_type(:tool_call)
      |> Enum.filter(&(&1.data["name"] == "wait_agent"))

    results_by_call_id =
      history
      |> by_type(:tool_result)
      |> Map.new(&{&1.data["call_id"], &1})

    issues =
      wait_calls
      |> Enum.flat_map(fn call ->
        result = results_by_call_id[call.data["call_id"]]
        wait_result_issues(call, result)
      end)

    cond do
      wait_calls == [] ->
        passed("parent_waits", "No wait_agent parent waits found.", %{})

      issues == [] ->
        passed("parent_waits", "All wait_agent parent waits have structured outcomes.", %{
          "wait_calls" => length(wait_calls)
        })

      true ->
        warning(
          "parent_waits",
          "Some wait_agent parent waits have missing, synthetic, or misleading results.",
          %{
            "classification" => "parent_wait_inconsistent_result",
            "wait_calls" => length(wait_calls),
            "issues" => issues,
            "next_actions" => [
              "inspect each wait_agent tool_call and tool_result pair",
              "prefer the structured outcome over summary prose",
              "rerun wait_agent when the outcome is missing or incomplete"
            ]
          }
        )
    end
  end

  defp replay_check(%{"provider_input" => input}) do
    cond do
      input["missing_output_ids"] != [] ->
        failed(
          "provider_replay",
          "Provider replay input has function calls without outputs.",
          input
        )

      input["extra_output_ids"] != [] ->
        warning(
          "provider_replay",
          "Provider replay input has outputs without function calls.",
          input
        )

      input["synthetic_orphan_closures"] != [] ->
        warning(
          "provider_replay",
          "Provider replay is balanced using synthetic orphan closures.",
          input
        )

      true ->
        passed(
          "provider_replay",
          "Provider replay input is balanced without synthetic closures.",
          input
        )
    end
  end

  defp tree_check(tree) do
    missing_children =
      tree
      |> child_nodes()
      |> Enum.reject(& &1["log_exists"])
      |> Enum.map(& &1["session_id"])

    if missing_children == [] do
      passed("session_tree", "Session tree child Logs are present or no children exist.", %{
        "subagents" => length(tree["subagents"] || []),
        "forks" => length(tree["forks"] || [])
      })
    else
      warning("session_tree", "Some referenced child Session Logs are missing.", %{
        "missing_child_session_ids" => missing_children
      })
    end
  end

  defp continuation_check(%{"present" => false}) do
    warning("continuation", "No provider_usage event found for continuation metadata.", %{})
  end

  defp continuation_check(%{"continuation_reset_reason" => reason} = details)
       when reason not in [nil, ""] do
    warning("continuation", "Latest provider usage reset continuation.", details)
  end

  defp continuation_check(details) do
    passed("continuation", "Latest provider usage has no continuation reset.", details)
  end

  defp event_summary(history) do
    seqs = history |> Enum.map(& &1.seq) |> Enum.filter(&is_integer/1)

    %{
      "count" => length(history),
      "from_seq" => Enum.min(seqs, fn -> nil end),
      "to_seq" => Enum.max(seqs, fn -> nil end),
      "counts_by_type" =>
        history
        |> Enum.frequencies_by(&Atom.to_string(&1.type))
        |> Enum.into(%{})
    }
  end

  defp workflow_diagnostics(history) do
    events = by_type(history, :workflow_event)

    runs =
      events
      |> Enum.group_by(&workflow_id/1)
      |> Enum.map(fn {workflow_id, run_events} ->
        workflow_run_summary(workflow_id, run_events)
      end)
      |> Enum.sort_by(& &1["first_seq"], :asc)

    %{
      "count" => length(runs),
      "event_count" => length(events),
      "checkpoint_decision_count" =>
        Enum.count(events, &(&1.data["kind"] == "checkpoint_decided")),
      "kinds" =>
        events
        |> Enum.frequencies_by(&(&1.data["kind"] || "unknown"))
        |> Enum.into(%{}),
      "runs" => runs
    }
  end

  defp workflow_run_summary(workflow_id, events) do
    start_event = Enum.find(events, &(&1.data["kind"] == "workflow_started"))

    finish_event =
      events |> Enum.reverse() |> Enum.find(&(&1.data["kind"] == "workflow_finished"))

    checkpoint_events = Enum.filter(events, &(&1.data["kind"] == "checkpoint_decided"))
    held_events = Enum.filter(events, &(&1.data["kind"] == "step_held"))
    scheduled_events = Enum.filter(events, &(&1.data["kind"] == "step_scheduled"))
    checkpoint_summaries = Enum.map(checkpoint_events, &workflow_checkpoint_summary/1)
    event_gaps = workflow_event_gaps(workflow_id, events, start_event, finish_event)
    checkpoint_gaps = workflow_checkpoint_gaps(checkpoint_summaries)

    %{
      "workflow_id" => workflow_id,
      "workflow_name" => workflow_name(events),
      "started" => not is_nil(start_event),
      "finished" => not is_nil(finish_event),
      "status" => workflow_terminal_status(finish_event),
      "ok" => workflow_terminal_ok(finish_event),
      "first_seq" => first_seq(events),
      "last_seq" => last_seq(events),
      "event_count" => length(events),
      "event_kinds" =>
        events
        |> Enum.frequencies_by(&(&1.data["kind"] || "unknown"))
        |> Enum.into(%{}),
      "step_counts" => %{
        "scheduled" => length(scheduled_events),
        "checkpoint_decided" => length(checkpoint_events),
        "held" => length(held_events),
        "checkpoint_ready" =>
          Enum.count(checkpoint_summaries, &(&1["checkpoint_status"] == "checkpoint_ready")),
        "dependent_safe" => Enum.count(checkpoint_summaries, &(&1["dependent_safe"] == true))
      },
      "checkpoint_status_counts" =>
        checkpoint_summaries
        |> Enum.frequencies_by(&(&1["checkpoint_status"] || "unknown"))
        |> Enum.into(%{}),
      "held_steps" => Enum.map(held_events, &workflow_held_step_summary/1),
      "checkpoints" => checkpoint_summaries,
      "typed_schema_ids" =>
        checkpoint_summaries
        |> Enum.flat_map(& &1["typed_schema_ids"])
        |> Enum.uniq(),
      "artifact_refs" =>
        checkpoint_summaries
        |> Enum.flat_map(& &1["artifact_refs"])
        |> Enum.map(&workflow_artifact_ref_summary/1),
      "safe_next_actions" => workflow_safe_next_actions(finish_event),
      "event_gaps" => event_gaps,
      "checkpoint_gaps" => checkpoint_gaps,
      "gaps" => event_gaps ++ checkpoint_gaps
    }
  end

  defp workflow_id(%{data: %{"workflow_id" => id}}) when is_binary(id) and id != "", do: id
  defp workflow_id(_event), do: "unknown"

  defp workflow_name(events) do
    events
    |> Enum.map(& &1.data["workflow_name"])
    |> Enum.find(&present?/1)
  end

  defp workflow_terminal_status(nil), do: "unknown"
  defp workflow_terminal_status(event), do: event.data["status"] || "unknown"

  defp workflow_terminal_ok(nil), do: nil
  defp workflow_terminal_ok(event), do: event.data["ok"]

  defp workflow_safe_next_actions(nil), do: []
  defp workflow_safe_next_actions(event), do: event.data["safe_next_actions"] || []

  defp first_seq(events), do: events |> Enum.map(& &1.seq) |> Enum.min(fn -> nil end)
  defp last_seq(events), do: events |> Enum.map(& &1.seq) |> Enum.max(fn -> nil end)

  defp workflow_checkpoint_summary(event) do
    checkpoint = event.data["checkpoint"] || %{}
    typed_schema_ids = checkpoint["typed_schema_ids"] || []
    artifact_refs = checkpoint["artifact_refs"] || []

    %{
      "seq" => event.seq,
      "step_id" => event.data["step_id"],
      "agent_id" => event.data["agent_id"],
      "child_session_id" => event.data["child_session_id"],
      "workspace_mode" => event.data["workspace_mode"],
      "execution_kind" => event.data["execution_kind"],
      "checkpoint_status" => event.data["checkpoint_status"] || checkpoint["status"],
      "dependent_safe" => event.data["dependent_safe"] == true,
      "version" => checkpoint["version"],
      "typed_schema_ids" => typed_schema_ids,
      "artifact_refs" => artifact_refs,
      "known_limitations" => checkpoint["known_limitations"] || [],
      "summary_present" => present?(checkpoint["summary"]),
      "gaps" => checkpoint_summary_gaps(event, typed_schema_ids, artifact_refs)
    }
  end

  defp workflow_held_step_summary(event) do
    %{
      "seq" => event.seq,
      "step_id" => event.data["step_id"],
      "checkpoint_status" => event.data["checkpoint_status"],
      "reason" => event.data["reason"],
      "workspace_mode" => event.data["workspace_mode"],
      "execution_kind" => event.data["execution_kind"]
    }
  end

  defp workflow_artifact_ref_summary(ref) when is_map(ref) do
    %{
      "schema_id" => ref["schema_id"],
      "kind" => ref["kind"],
      "provenance" => ref["provenance"],
      "hash" => ref["hash"],
      "workspace_strategy" => ref["workspace_strategy"],
      "validation_status" => get_in(ref, ["validation", "status"])
    }
  end

  defp workflow_artifact_ref_summary(ref), do: %{"kind" => "invalid", "value" => inspect(ref)}

  defp workflow_event_gaps(workflow_id, events, start_event, finish_event) do
    []
    |> maybe_add_gap(workflow_id == "unknown", %{
      "kind" => "missing_workflow_id",
      "severity" => "warning",
      "seqs" => Enum.map(events, & &1.seq)
    })
    |> maybe_add_gap(is_nil(start_event), %{
      "kind" => "missing_workflow_started",
      "severity" => "warning"
    })
    |> maybe_add_gap(is_nil(finish_event), %{
      "kind" => "missing_workflow_finished",
      "severity" => "warning"
    })
    |> maybe_add_gap(partial_without_next_actions?(finish_event), %{
      "kind" => "partial_workflow_missing_next_actions",
      "severity" => "warning",
      "seq" => finish_event && finish_event.seq
    })
    |> Enum.reverse()
  end

  defp partial_without_next_actions?(nil), do: false

  defp partial_without_next_actions?(event) do
    event.data["status"] == "partial" and not present?(event.data["safe_next_actions"])
  end

  defp workflow_checkpoint_gaps(checkpoints), do: Enum.flat_map(checkpoints, & &1["gaps"])

  defp checkpoint_summary_gaps(event, typed_schema_ids, artifact_refs) do
    checkpoint = event.data["checkpoint"] || %{}
    version = checkpoint["version"]

    []
    |> maybe_add_gap(version == 2 and "workflow_checkpoint.v1" not in typed_schema_ids, %{
      "kind" => "missing_workflow_checkpoint_schema",
      "severity" => "warning",
      "seq" => event.seq,
      "step_id" => event.data["step_id"]
    })
    |> maybe_add_gap(
      event.data["checkpoint_status"] == "held" and not present?(checkpoint["known_limitations"]),
      %{
        "kind" => "held_checkpoint_missing_limitations",
        "severity" => "warning",
        "seq" => event.seq,
        "step_id" => event.data["step_id"]
      }
    )
    |> Kernel.++(artifact_ref_gaps(event, artifact_refs))
    |> Enum.reverse()
  end

  defp artifact_ref_gaps(event, artifact_refs) do
    artifact_refs
    |> Enum.flat_map(fn ref ->
      []
      |> maybe_add_gap(not is_map(ref), %{
        "kind" => "invalid_artifact_ref",
        "severity" => "warning",
        "seq" => event.seq,
        "step_id" => event.data["step_id"]
      })
      |> maybe_add_gap(is_map(ref) and ref["schema_id"] != "artifact_ref.v1", %{
        "kind" => "missing_artifact_ref_schema",
        "severity" => "warning",
        "seq" => event.seq,
        "step_id" => event.data["step_id"],
        "artifact_kind" => if(is_map(ref), do: ref["kind"], else: nil)
      })
      |> maybe_add_gap(is_map(ref) and not present?(ref["hash"]), %{
        "kind" => "missing_artifact_ref_hash",
        "severity" => "warning",
        "seq" => event.seq,
        "step_id" => event.data["step_id"],
        "artifact_kind" => if(is_map(ref), do: ref["kind"], else: nil)
      })
    end)
  end

  defp maybe_add_gap(gaps, true, gap), do: [gap | gaps]
  defp maybe_add_gap(gaps, _condition, _gap), do: gaps

  defp tree_summary(tree) do
    %{
      "session_id" => tree["session_id"],
      "log_exists" => tree["log_exists"],
      "event_count" => tree["event_count"],
      "subagents" => Enum.map(tree["subagents"] || [], &subagent_summary/1),
      "fork_count" => length(tree["forks"] || [])
    }
  end

  defp subagent_summary(record) do
    session = record["session"] || %{}

    %{
      "subagent_id" => record["subagent_id"],
      "child_session_id" => record["child_session_id"],
      "child_log_path" => get_in(record, ["session", "log_path"]) || record["child_log_path"],
      "status" => record["status"],
      "reason" => record["reason"],
      "elapsed_ms" => record["elapsed_ms"],
      "timeout_ms" => record["timeout_ms"],
      "deadline_at" => record["deadline_at"],
      "next_actions" => record["next_actions"] || [],
      "events" => record["events"] || [],
      "log_exists" => session["log_exists"] == true,
      "event_count" => session["event_count"],
      "child_last_event_ts" => session["last_event_ts"]
    }
  end

  defp provider_usage_summary(history) do
    usage = by_type(history, :provider_usage)
    latest = List.last(usage)

    %{
      "count" => length(usage),
      "latest" => provider_usage_item(latest)
    }
  end

  defp provider_usage_item(nil), do: nil

  defp provider_usage_item(%{seq: seq, data: data}) do
    %{
      "seq" => seq,
      "model" => data["model"],
      "active_transport" => data["active_transport"],
      "continuation_attempted" => data["continuation_attempted"],
      "continuation_reset_reason" => data["continuation_reset_reason"],
      "used_previous_response_id" => data["used_previous_response_id"],
      "usage_summary" => data["usage_summary"]
    }
  end

  defp subagents_runtime_summary(session_id) do
    case Subagents.diagnostics(session_id) do
      {:ok, runtime} ->
        Map.put(runtime, "available", true)

      {:error, error} ->
        %{
          "available" => false,
          "error" => normalize_error(error)
        }
    end
  catch
    :exit, reason ->
      %{
        "available" => false,
        "error" =>
          normalize_error(
            Tool.error(:read_failed, "Subagent Manager runtime snapshot failed", %{
              "reason" => inspect(reason)
            })
          )
      }
  end

  defp normalize_error(%{error: %{kind: kind, message: message, details: details}}) do
    %{
      "kind" => Atom.to_string(kind),
      "message" => message,
      "details" => stringify_keys(details || %{})
    }
  end

  defp normalize_error(error) do
    %{
      "kind" => "unknown",
      "message" => inspect(error),
      "details" => %{}
    }
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end

  defp child_nodes(tree) do
    subagent_children =
      tree
      |> Map.get("subagents", [])
      |> Enum.map(& &1["session"])
      |> Enum.reject(&is_nil/1)

    fork_children =
      tree
      |> Map.get("forks", [])
      |> Enum.map(& &1["session"])
      |> Enum.reject(&is_nil/1)

    subagent_children ++ fork_children
  end

  defp all_subagent_records(tree) do
    root = Map.get(tree, "subagents", [])

    nested =
      tree
      |> child_nodes()
      |> Enum.flat_map(&all_subagent_records/1)

    root ++ nested
  end

  defp missing_runtime_open_subagents(tree, runtime) do
    runtime_ids =
      runtime
      |> Map.get("subagents", [])
      |> Enum.map(& &1["id"])
      |> MapSet.new()

    tree
    |> Map.get("subagents", [])
    |> Enum.filter(
      &(subagent_classification(&1["status"] || "unknown", &1["reason"]) in [
          "running",
          "queued"
        ])
    )
    |> Enum.reject(&MapSet.member?(runtime_ids, &1["subagent_id"]))
    |> Enum.map(fn record ->
      %{
        "subagent_id" => record["subagent_id"],
        "child_session_id" => record["child_session_id"],
        "status" => record["status"],
        "child_log_path" => get_in(record, ["session", "log_path"]) || record["child_log_path"],
        "last_seq" => record["last_seq"]
      }
    end)
  end

  defp subagent_terminal_state(record) do
    status = record["status"] || "unknown"
    reason = record["reason"]

    %{
      "subagent_id" => record["subagent_id"],
      "child_session_id" => record["child_session_id"],
      "child_log_path" => get_in(record, ["session", "log_path"]) || record["child_log_path"],
      "status" => status,
      "classification" => subagent_classification(status, reason),
      "reason" => reason,
      "timeout_ms" => record["timeout_ms"],
      "deadline_at" => record["deadline_at"],
      "elapsed_ms" => record["elapsed_ms"],
      "next_actions" => record["next_actions"] || [],
      "events" => record["events"] || [],
      "missing_fields" => missing_subagent_terminal_fields(record)
    }
  end

  defp subagent_classification("completed", _reason), do: "completed"
  defp subagent_classification("closed", _reason), do: "closed"
  defp subagent_classification("timed_out", _reason), do: "timed_out"
  defp subagent_classification("failed", "partial_" <> _), do: "partial_failed"
  defp subagent_classification("failed", _reason), do: "failed"
  defp subagent_classification("cancelled", _reason), do: "interrupted"
  defp subagent_classification("detached", _reason), do: "detached"
  defp subagent_classification("running", _reason), do: "running"
  defp subagent_classification("queued", _reason), do: "queued"
  defp subagent_classification(_status, _reason), do: "unknown"

  defp missing_subagent_terminal_fields(%{"status" => "timed_out"} = record) do
    missing_fields(record, [
      "subagent_id",
      "child_session_id",
      "status",
      "timeout_ms",
      "deadline_at",
      "elapsed_ms",
      "reason",
      "next_actions"
    ])
  end

  defp missing_subagent_terminal_fields(%{"status" => status} = record)
       when status in ["failed", "cancelled"] do
    missing_fields(record, [
      "subagent_id",
      "child_session_id",
      "status",
      "elapsed_ms",
      "reason",
      "next_actions"
    ])
  end

  defp missing_subagent_terminal_fields(record) do
    missing_fields(record, ["subagent_id", "child_session_id", "status"])
  end

  defp missing_fields(record, fields) do
    Enum.reject(fields, fn field -> present?(record[field]) end)
  end

  defp by_type(history, type), do: Enum.filter(history, &(&1.type == type))

  defp present?(value), do: value not in [nil, "", []]

  defp wait_result_issues(call, nil) do
    [
      %{
        "kind" => "missing_wait_agent_result",
        "severity" => "failed",
        "call_id" => call.data["call_id"],
        "tool_call_seq" => call.seq,
        "next_actions" => ["repair or rerun the missing wait_agent tool_result"]
      }
    ]
  end

  defp wait_result_issues(call, result) do
    data = result.data
    outcome = data["outcome"]

    []
    |> maybe_add_wait_issue(synthetic_tool_result?(data), %{
      "kind" => "synthetic_wait_agent_result",
      "severity" => "warning",
      "call_id" => call.data["call_id"],
      "tool_call_seq" => call.seq,
      "tool_result_seq" => result.seq,
      "next_actions" => ["inspect replay repair evidence before trusting this wait outcome"]
    })
    |> maybe_add_wait_issue(data["ok"] == true and not is_map(outcome), %{
      "kind" => "missing_structured_wait_outcome",
      "severity" => "warning",
      "call_id" => call.data["call_id"],
      "tool_call_seq" => call.seq,
      "tool_result_seq" => result.seq,
      "next_actions" => ["rerun wait_agent with a Pixir version that records structured outcomes"]
    })
    |> maybe_add_wait_issue(is_map(outcome) and inconsistent_wait_counts?(outcome), %{
      "kind" => "inconsistent_wait_outcome_counts",
      "severity" => "warning",
      "call_id" => call.data["call_id"],
      "tool_call_seq" => call.seq,
      "tool_result_seq" => result.seq,
      "status" => outcome["status"],
      "counts" => outcome["counts"] || %{},
      "next_actions" => ["inspect the wait_agent outcome buckets and child Session Logs"]
    })
    |> maybe_add_wait_issue(
      is_map(outcome) and misleading_wait_summary?(data["output"], outcome),
      %{
        "kind" => "misleading_wait_agent_summary",
        "severity" => "warning",
        "call_id" => call.data["call_id"],
        "tool_call_seq" => call.seq,
        "tool_result_seq" => result.seq,
        "status" => outcome["status"],
        "output" => data["output"],
        "next_actions" => ["trust the structured outcome status over summary prose"]
      }
    )
  end

  defp maybe_add_wait_issue(issues, true, issue), do: [issue | issues]
  defp maybe_add_wait_issue(issues, _condition, _issue), do: issues

  defp synthetic_tool_result?(%{"error" => %{"kind" => "orphan_tool_call"}}), do: true
  defp synthetic_tool_result?(_data), do: false

  defp inconsistent_wait_counts?(%{"status" => "completed", "counts" => counts})
       when is_map(counts) do
    Enum.any?(["failed", "timed_out", "cancelled", "detached", "incomplete"], fn key ->
      (counts[key] || 0) > 0
    end)
  end

  defp inconsistent_wait_counts?(_outcome), do: false

  defp misleading_wait_summary?(output, %{"status" => status})
       when is_binary(output) and status in ["partial", "incomplete"] do
    String.contains?(output, "wait_agent completed")
  end

  defp misleading_wait_summary?(_output, _outcome), do: false

  defp stale_subagent_record(record, now, threshold_ms) do
    session = record["session"] || %{}
    last_ts = session["last_event_ts"]

    with true <- session["log_exists"] == true,
         {:ok, age_ms} <- age_ms(last_ts, now),
         true <- age_ms >= threshold_ms do
      [
        %{
          "kind" => "stale_subagent_log",
          "severity" => "warning",
          "subagent_id" => record["subagent_id"],
          "child_session_id" => record["child_session_id"],
          "child_log_path" => session["log_path"] || record["child_log_path"],
          "status" => record["status"],
          "last_seq" => record["last_seq"],
          "child_last_event_ts" => last_ts,
          "age_ms" => age_ms,
          "next_actions" => record["next_actions"] || ["inspect_child_session_log", "wait_again"]
        }
      ]
    else
      _ -> []
    end
  end

  defp age_ms(nil, _now), do: :error

  defp age_ms(ts, now) when is_binary(ts) do
    with {:ok, then_dt, _offset} <- DateTime.from_iso8601(ts) do
      {:ok, DateTime.diff(now, then_dt, :millisecond)}
    else
      _ -> :error
    end
  end

  defp partial_assistant_messages(history) do
    history
    |> by_type(:assistant_message)
    |> Enum.filter(&(get_in(&1.data, ["metadata", "partial"]) == true))
    |> Enum.map(fn event ->
      metadata = Map.get(event.data, "metadata", %{})

      %{
        "seq" => event.seq,
        "error_kind" => metadata["error_kind"],
        "terminal_status" => metadata["terminal_status"],
        "text_length" => event.data |> Map.get("text", "") |> String.length()
      }
    end)
  end

  defp incomplete_tool_turns(history) do
    history
    |> Enum.reduce({nil, []}, fn event, {current, acc} ->
      case {event.type, current} do
        {:user_message, nil} ->
          {new_turn(event), acc}

        {:user_message, turn} ->
          acc = maybe_record_incomplete(turn, event.seq, acc)
          {new_turn(event), acc}

        {:assistant_message, nil} ->
          {nil, acc}

        {:assistant_message, turn} ->
          {%{turn | answered?: true, last_seq: event.seq}, acc}

        {:turn_failed, nil} ->
          {nil, acc}

        {:turn_failed, turn} ->
          {%{turn | failed?: true, last_seq: event.seq}, acc}

        {type, turn}
        when type in [:tool_call, :tool_result, :provider_usage] and not is_nil(turn) ->
          {
            %{
              turn
              | activity?: true,
                tool_calls: turn.tool_calls + if(type == :tool_call, do: 1, else: 0),
                tool_results: turn.tool_results + if(type == :tool_result, do: 1, else: 0),
                provider_calls: turn.provider_calls + if(type == :provider_usage, do: 1, else: 0),
                last_seq: event.seq
            },
            acc
          }

        {_type, turn} when not is_nil(turn) ->
          {%{turn | last_seq: event.seq}, acc}

        {_type, nil} ->
          {nil, acc}
      end
    end)
    |> then(fn {turn, acc} -> maybe_record_incomplete(turn, nil, acc) end)
    |> Enum.reverse()
  end

  defp new_turn(event) do
    %{
      user_seq: event.seq,
      next_user_seq: nil,
      last_seq: event.seq,
      answered?: false,
      failed?: false,
      activity?: false,
      tool_calls: 0,
      tool_results: 0,
      provider_calls: 0
    }
  end

  defp maybe_record_incomplete(nil, _next_user_seq, acc), do: acc

  defp maybe_record_incomplete(%{answered?: true}, _next_user_seq, acc), do: acc

  defp maybe_record_incomplete(%{failed?: true}, _next_user_seq, acc), do: acc

  defp maybe_record_incomplete(%{activity?: false}, _next_user_seq, acc), do: acc

  defp maybe_record_incomplete(turn, next_user_seq, acc) do
    [
      %{
        "user_seq" => turn.user_seq,
        "next_user_seq" => next_user_seq,
        "last_seq" => turn.last_seq,
        "tool_calls" => turn.tool_calls,
        "tool_results" => turn.tool_results,
        "provider_calls" => turn.provider_calls
      }
      | acc
    ]
  end

  defp status(checks) do
    cond do
      Enum.any?(checks, &(&1["status"] == "failed")) -> "blocked"
      Enum.any?(checks, &(&1["status"] == "warning")) -> "ready_with_warnings"
      true -> "ready"
    end
  end

  defp next_actions(checks) do
    checks
    |> Enum.flat_map(&(get_in(&1, ["details", "next_actions"]) || []))
    |> Enum.uniq()
  end

  defp passed(id, message, details), do: check(id, "passed", message, details)
  defp warning(id, message, details), do: check(id, "warning", message, details)
  defp failed(id, message, details), do: check(id, "failed", message, details)

  defp check(id, status, message, details) do
    %{
      "id" => id,
      "status" => status,
      "message" => message,
      "details" => details
    }
  end
end
