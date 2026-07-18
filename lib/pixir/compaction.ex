defmodule Pixir.Compaction do
  @moduledoc """
  Durable History compaction.

  Pixir keeps the full Log as source of truth, but the Provider does not need every
  old Event on every Turn. Compaction records a canonical `history_compaction` Event
  that summarizes an older prefix and leaves a recent tail uncompressed. Provider
  replay then sends the latest checkpoint plus the tail, so context stays bounded
  while resume/fork/debug still read the original Log.
  """

  alias Pixir.{Config, Event, Log, Provider, Session, SessionId, SessionSupervisor, Tool}

  @summary_limit 480
  @max_named_skill_identities 5
  @strategy_deterministic "deterministic_operational_summary_v1"
  @strategy_model_assisted "model_assisted_operational_summary_v1"

  @doc "Default tail size used for recovery/preflight compactions."
  @spec default_tail_events() :: {:ok, pos_integer()}
  def default_tail_events, do: {:ok, Config.compaction_tail_events()}

  # ADR 0020 trigger policy: compaction is a deliberate lifecycle event. "manual"
  # is the primary UX operation. "overflow_recovery" is the post-rejection
  # automatic path. "critical_pressure_preflight" and "websocket_critical_recovery"
  # are the new gauge-driven paths (preflight before a Turn when the last
  # provider_usage was "critical"; pragmatic recovery when a low-level transport
  # failure like "Could not read WebSocket frame" occurs under critical pressure).
  # All automatic paths still record an explicit, user-visible
  # `history_compaction` Event with the trigger — never silent rewrite.
  @valid_triggers [
    "manual",
    "overflow_recovery",
    "critical_pressure_preflight",
    "websocket_critical_recovery"
  ]

  @skill_activation_limitation "Skills activated only inside the compacted range are not replayed unless they remain in the recent raw tail or are explicitly re-activated."

  @doc """
  Developer instruction for a future model-assisted compaction pass.

  Keep this short and contract-like. Detailed shape belongs in `output_schema/0`, and
  actual Session facts belong in the per-call input payload.
  """
  @spec developer_instruction() :: String.t()
  def developer_instruction do
    """
    You create durable Pixir history compaction checkpoints.

    Goal:
    Compress the supplied older Session Log prefix into an operational checkpoint that lets a future Pixir turn continue safely with less context.

    Constraints:
    - Use only the supplied events.
    - Preserve facts that affect future work: current objective, explicit user constraints, decisions, files touched, tool outcomes, subagent/workflow status, errors, blockers, verification evidence, and unresolved tasks.
    - Be conservative. If the log does not prove success, mark the outcome as partial, failed, unknown, or unresolved.
    - Never include secrets, credentials, raw tokens, or large verbatim tool outputs.
    - Do not invent instructions, decisions, file changes, or successful completion.
    - The full Log remains authoritative; this checkpoint is a replay aid, not a replacement.

    Output:
    Return one compact structured checkpoint matching the provided JSON schema.
    Prefer short, information-dense fields over narrative prose.
    """
    |> String.trim()
  end

  @doc """
  JSON schema for a model-assisted compaction checkpoint.

  This intentionally lives in code instead of prompt prose so the Provider path can
  enforce the shape with structured outputs when model-assisted compaction is enabled.
  """
  @spec output_schema() :: map()
  def output_schema do
    %{
      "name" => "pixir_history_compaction_checkpoint",
      "strict" => true,
      "schema" => %{
        "type" => "object",
        "additionalProperties" => false,
        "required" => [
          "summary",
          "current_objective",
          "user_instructions",
          "decisions",
          "work_completed",
          "open_tasks",
          "files_touched",
          "commands_and_evidence",
          "subagents_and_workflows",
          "risks",
          "open_questions",
          "limitations"
        ],
        "properties" => %{
          "summary" => string_schema("Short operational summary of the compacted range."),
          "current_objective" =>
            string_schema("Best-known active objective at the end of the compacted range."),
          "user_instructions" =>
            string_array_schema("Explicit user instructions that still matter."),
          "decisions" => array_schema(decision_schema()),
          "work_completed" =>
            string_array_schema("Completed work with evidence, not aspirations."),
          "open_tasks" => string_array_schema("Unresolved next tasks or follow-ups."),
          "files_touched" =>
            string_array_schema("Workspace paths mentioned or modified in the compacted range."),
          "commands_and_evidence" => array_schema(command_evidence_schema()),
          "subagents_and_workflows" => array_schema(subagent_workflow_schema()),
          "risks" => string_array_schema("Known risks, blockers, or failure modes."),
          "open_questions" => string_array_schema("Questions that remain unanswered."),
          "limitations" => string_array_schema("Limitations of this checkpoint.")
        }
      }
    }
  end

  @doc """
  Build the instruction, schema, and delimited user payload for model-assisted compaction.
  This does not call the network and does not mutate the Log.
  """
  @spec model_contract(String.t(), [Event.t()], keyword()) :: {:ok, map()} | {:error, map()}
  def model_contract(session_id, events, opts \\ [])

  def model_contract(session_id, [], _opts) when is_binary(session_id) do
    with :ok <- SessionId.validate(session_id) do
      {:error,
       Tool.error(:invalid_args, "cannot build model contract for empty events", %{
         session_id: session_id,
         events: []
       })}
    end
  end

  def model_contract(session_id, events, opts)
      when is_binary(session_id) and is_list(events) do
    tail_events = tail_events(opts)

    with :ok <- SessionId.validate(session_id),
         {:ok, tail_events} <- validate_tail_events(tail_events) do
      {:ok,
       %{
         "developer_instruction" => developer_instruction(),
         "output_schema" => output_schema(),
         "input" => %{
           "compaction_scope" => %{
             "session_id" => session_id,
             "compact_range" => %{"from_seq" => first_seq(events), "to_seq" => last_seq(events)},
             "tail_policy" => "keep last #{tail_events} events outside this checkpoint"
           },
           "events" => Enum.map(events, &event_for_model/1)
         }
       }}
    end
  end

  def model_contract(session_id, _events, _opts) do
    with :ok <- SessionId.validate(session_id) do
      {:error, Tool.error(:invalid_args, "model contract events must be a list", %{})}
    end
  end

  @doc "Plan compaction without appending anything to the Log."
  @spec dry_run(String.t(), keyword()) :: {:ok, map()} | {:error, map()}
  def dry_run(session_id, opts \\ []), do: plan(session_id, opts)

  @doc "Append a durable `history_compaction` checkpoint when there is compactable History."
  @spec compact(String.t(), keyword()) :: {:ok, map()} | {:error, map()}
  def compact(session_id, opts \\ []) do
    workspace = workspace(opts)

    with {:ok, plan} <- plan(session_id, opts),
         {:compactable, true} <- {:compactable, plan["compactable"]},
         {:ok, event_data} <- resolve_event_data(session_id, plan, opts),
         {:ok, ^session_id, _pid} <-
           SessionSupervisor.start_session(id: session_id, workspace: workspace),
         {:ok, event} <-
           Session.record(session_id, Event.history_compaction(session_id, event_data)) do
      {:ok,
       plan
       |> Map.put("event", event_data)
       |> Map.put("recorded", true)
       |> Map.put("compaction_event_id", event.id)
       |> Map.put("compaction_seq", event.seq)}
    else
      {:compactable, false} ->
        {:ok, %{"ok" => true, "compactable" => false, "recorded" => false}}

      {:error, _} = error ->
        error

      other ->
        {:error,
         Tool.error(:session_start_failed, "could not start session for compaction", %{
           session_id: session_id,
           reason: inspect(other)
         })}
    end
  end

  @doc """
  Return the Provider-visible History: latest compaction checkpoint plus uncompressed
  events after its range. Sessions without compaction pass through unchanged.
  """
  @spec provider_history([Event.t()]) :: [Event.t()]
  def provider_history(history) when is_list(history) do
    case latest_compaction(history) do
      nil ->
        history

      compaction ->
        to_seq = compaction_to_seq(compaction)

        tail =
          Enum.filter(history, fn event ->
            event.type != :history_compaction and (is_nil(event.seq) or event.seq > to_seq)
          end)

        [compaction | tail]
    end
  end

  @doc "Render compaction data as a Provider input item."
  @spec render_for_provider(map()) :: String.t()
  def render_for_provider(data) when is_map(data) do
    range = data["range"] || %{}

    """
    Compressed session memory
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

  @doc "Build the deterministic compaction plan for a Session."
  @spec plan(String.t(), keyword()) :: {:ok, map()} | {:error, map()}
  def plan(session_id, opts \\ []) do
    workspace = workspace(opts)
    tail_events = tail_events(opts)

    with {:ok, history} <- Log.fold(session_id, workspace: workspace),
         {:ok, tail_events} <- validate_tail_events(tail_events),
         {:ok, trigger} <- validate_trigger(trigger(opts)) do
      latest = latest_compaction(history)
      latest_to_seq = compaction_to_seq(latest)

      candidates =
        history
        |> Enum.reject(&(&1.type == :history_compaction))
        |> Enum.filter(
          &(is_nil(latest_to_seq) or (is_integer(&1.seq) and &1.seq > latest_to_seq))
        )

      {compact_prefix, tail} = split_for_compaction(candidates, tail_events)

      if compact_prefix == [] do
        {:ok,
         %{
           "ok" => true,
           "compactable" => false,
           "recorded" => false,
           "tail_events" => length(tail),
           "reason" => "history does not exceed requested tail"
         }}
      else
        event_data =
          carry_forward(latest, compact_prefix)
          |> then(&event_data(&1, tail, trigger))
          |> maybe_mark_model_assisted(model_assisted_enabled?(opts))

        {:ok,
         %{
           "ok" => true,
           "compactable" => true,
           "recorded" => false,
           "model_assisted" => model_assisted_enabled?(opts),
           "tail_events" => length(tail),
           "would_compact_events" => length(compact_prefix),
           "event" => event_data
         }}
      end
    end
  end

  defp workspace(opts), do: Keyword.get(opts, :workspace, File.cwd!())

  defp tail_events(opts) do
    case Keyword.fetch(opts, :tail_events) do
      {:ok, value} -> value
      :error -> Config.compaction_tail_events()
    end
  end

  defp trigger(opts), do: Keyword.get(opts, :trigger, "manual")

  defp model_assisted_enabled?(opts) do
    case Keyword.get(opts, :model_assisted) do
      value when is_boolean(value) -> value
      _ -> Config.compaction_model_assisted(config_opts(opts))
    end
  end

  defp config_opts(opts) do
    opts
    |> Keyword.take([:config_path, :raw_config])
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp maybe_mark_model_assisted(event_data, true),
    do: Map.put(event_data, "strategy", @strategy_model_assisted)

  defp maybe_mark_model_assisted(event_data, false), do: event_data

  defp resolve_event_data(_session_id, %{"model_assisted" => false, "event" => event}, _opts),
    do: {:ok, event}

  defp resolve_event_data(session_id, %{"model_assisted" => true, "event" => event}, opts) do
    with {:ok, compact_prefix, _tail, _trigger} <- compaction_material(session_id, opts),
         {:ok, model_event} <-
           model_assisted_event_data(session_id, compact_prefix, event, opts) do
      {:ok, model_event}
    else
      {:error, %{error: %{kind: kind}}} = error
      when kind in [:invalid_config, :unsupported_backend] ->
        error

      {:error, reason} ->
        {:ok,
         event
         |> Map.put("strategy", @strategy_deterministic)
         |> Map.put("model_assisted_fallback", true)
         |> Map.put("model_assisted_fallback_reason", fallback_reason(reason))}
    end
  end

  defp resolve_event_data(_session_id, %{"event" => event}, _opts), do: {:ok, event}

  defp compaction_material(session_id, opts) do
    workspace = workspace(opts)
    tail_events = tail_events(opts)

    with {:ok, history} <- Log.fold(session_id, workspace: workspace),
         {:ok, tail_events} <- validate_tail_events(tail_events),
         {:ok, trigger} <- validate_trigger(trigger(opts)) do
      latest = latest_compaction(history)
      latest_to_seq = compaction_to_seq(latest)

      candidates =
        history
        |> Enum.reject(&(&1.type == :history_compaction))
        |> Enum.filter(
          &(is_nil(latest_to_seq) or (is_integer(&1.seq) and &1.seq > latest_to_seq))
        )

      {compact_prefix, tail} = split_for_compaction(candidates, tail_events)

      if compact_prefix == [] do
        {:error,
         Tool.error(:invalid_state, "no compactable prefix for model-assisted compaction", %{
           session_id: session_id
         })}
      else
        {:ok, carry_forward(latest, compact_prefix), tail, trigger}
      end
    end
  end

  defp model_assisted_event_data(session_id, compact_prefix, deterministic_event, opts) do
    with {:ok, contract} <-
           model_contract(session_id, compact_prefix, tail_events: tail_events(opts)),
         {:ok, checkpoint} <- provider_checkpoint(session_id, contract, opts),
         {:ok, validated} <- validate_model_checkpoint(checkpoint) do
      {:ok, merge_model_checkpoint(deterministic_event, validated)}
    end
  end

  defp provider_checkpoint(session_id, contract, opts) do
    request = %{
      system_prompt: contract["developer_instruction"],
      history: [Event.user_message(session_id, model_input_text(contract["input"]))],
      output_schema: contract["output_schema"]
    }

    provider_opts =
      opts
      |> Keyword.take([
        :transport,
        :auth,
        :model,
        :base_url,
        :max_retries,
        :sleep,
        :reasoning_effort,
        :text_verbosity,
        :responses_backend,
        :resolved_provider_request,
        :config_path,
        :raw_config,
        :request_snapshot_loader
      ])
      |> Keyword.put(:on_delta, fn _ -> :ok end)

    case Provider.stream(request, provider_opts) do
      {:ok, %{text: text}} when is_binary(text) ->
        case Jason.decode(text) do
          {:ok, checkpoint} when is_map(checkpoint) ->
            {:ok, checkpoint}

          {:ok, _} ->
            {:error,
             Tool.error(
               :invalid_response,
               "model-assisted compaction returned non-object JSON",
               %{
                 session_id: session_id
               }
             )}

          {:error, reason} ->
            {:error,
             Tool.error(:invalid_response, "model-assisted compaction returned invalid JSON", %{
               session_id: session_id,
               reason: inspect(reason)
             })}
        end

      {:ok, _} ->
        {:error,
         Tool.error(:invalid_response, "model-assisted compaction returned empty output", %{
           session_id: session_id
         })}

      {:error, _} = error ->
        error
    end
  end

  defp model_input_text(input) when is_map(input) do
    """
    Pixir history compaction input
    #{Jason.encode!(input, pretty: true)}
    """
    |> String.trim()
  end

  @doc false
  @spec validate_model_checkpoint(map()) :: {:ok, map()} | {:error, map()}
  def validate_model_checkpoint(checkpoint) when is_map(checkpoint) do
    schema = output_schema()
    required = schema["schema"]["required"] || []
    properties = schema["schema"]["properties"] || %{}

    missing =
      Enum.filter(required, fn key ->
        not Map.has_key?(checkpoint, key)
      end)

    if missing != [] do
      {:error,
       Tool.error(:invalid_response, "model-assisted compaction checkpoint missing fields", %{
         missing: missing
       })}
    else
      invalid =
        Enum.flat_map(required, fn key ->
          case validate_checkpoint_field(key, Map.get(checkpoint, key), Map.get(properties, key)) do
            :ok -> []
            {:error, message} -> [{key, message}]
          end
        end)

      if invalid == [] do
        {:ok, checkpoint}
      else
        {:error,
         Tool.error(
           :invalid_response,
           "model-assisted compaction checkpoint failed validation",
           %{
             invalid: Map.new(invalid)
           }
         )}
      end
    end
  end

  def validate_model_checkpoint(_checkpoint) do
    {:error,
     Tool.error(:invalid_response, "model-assisted compaction checkpoint must be an object", %{})}
  end

  defp validate_checkpoint_field(_key, value, %{"type" => "string"}) when is_binary(value),
    do: if(String.trim(value) == "", do: {:error, "must be a non-empty string"}, else: :ok)

  defp validate_checkpoint_field(_key, value, %{"type" => "string", "enum" => enum})
       when is_binary(value) do
    if value in enum, do: :ok, else: {:error, "invalid enum value"}
  end

  defp validate_checkpoint_field(_key, value, %{"type" => "boolean"}) when is_boolean(value),
    do: :ok

  defp validate_checkpoint_field(_key, value, %{"anyOf" => _})
       when is_integer(value) or is_nil(value),
       do: :ok

  defp validate_checkpoint_field(_key, value, %{"type" => "array", "items" => item_schema})
       when is_list(value) do
    if valid_checkpoint_array_items?(item_schema, value),
      do: :ok,
      else: {:error, "array items failed schema validation"}
  end

  defp validate_checkpoint_field(_key, value, %{"type" => "array"}) when is_list(value),
    do: if(Enum.all?(value, &is_binary/1), do: :ok, else: {:error, "items must be strings"})

  defp validate_checkpoint_field(_key, _value, _schema),
    do: {:error, "invalid field type"}

  defp valid_checkpoint_array_items?(%{"type" => "string"}, values),
    do: Enum.all?(values, &is_binary/1)

  defp valid_checkpoint_array_items?(%{"type" => "object"} = item_schema, values),
    do: Enum.all?(values, &valid_checkpoint_object?(&1, item_schema))

  defp valid_checkpoint_array_items?(_item_schema, _values), do: false

  defp valid_checkpoint_object?(value, %{
         "type" => "object",
         "required" => required,
         "properties" => properties
       })
       when is_map(value) do
    Enum.all?(required, fn key ->
      case validate_checkpoint_field(key, Map.get(value, key), Map.get(properties, key)) do
        :ok -> true
        {:error, _} -> false
      end
    end)
  end

  defp valid_checkpoint_object?(_value, _schema), do: false

  defp merge_model_checkpoint(deterministic_event, model_checkpoint) do
    deterministic_event
    |> Map.put("strategy", @strategy_model_assisted)
    |> Map.put("summary", model_summary(model_checkpoint))
    |> Map.put("open_tasks", model_open_tasks(model_checkpoint))
    |> Map.put(
      "files_touched",
      model_checkpoint["files_touched"] || deterministic_event["files_touched"]
    )
    |> Map.put("limitations", model_limitations(deterministic_event, model_checkpoint))
    |> Map.put("model_checkpoint", Map.take(model_checkpoint, model_checkpoint_persist_keys()))
  end

  defp model_checkpoint_persist_keys do
    output_schema()["schema"]["required"] || []
  end

  defp model_summary(%{"summary" => summary} = checkpoint) do
    objective = Map.get(checkpoint, "current_objective")

    if is_binary(objective) and String.trim(objective) != "" do
      summary <> "\nCurrent objective: " <> String.trim(objective)
    else
      summary
    end
  end

  defp model_open_tasks(checkpoint) do
    (checkpoint["open_tasks"] || [])
    |> Kernel.++(Enum.map(checkpoint["user_instructions"] || [], &("user instruction: " <> &1)))
    |> Kernel.++(Enum.map(checkpoint["work_completed"] || [], &("completed: " <> &1)))
    |> Kernel.++(Enum.map(checkpoint["risks"] || [], &("risk: " <> &1)))
    |> Kernel.++(Enum.map(checkpoint["open_questions"] || [], &("question: " <> &1)))
    |> Enum.reject(&(String.trim(&1) == ""))
    |> Enum.take(20)
  end

  defp model_limitations(deterministic_event, model_checkpoint) do
    base = deterministic_event["limitations"] || []
    model = model_checkpoint["limitations"] || []
    (base ++ model) |> Enum.uniq()
  end

  defp fallback_reason(%{ok: false, error: %{kind: kind}}), do: Atom.to_string(kind)
  defp fallback_reason(%{error: %{kind: kind}}), do: Atom.to_string(kind)
  defp fallback_reason(other), do: inspect(other)

  defp validate_trigger(trigger) when trigger in @valid_triggers, do: {:ok, trigger}

  defp validate_trigger(trigger) do
    {:error,
     Tool.error(:invalid_args, "trigger must be one of #{inspect(@valid_triggers)}", %{
       trigger: trigger
     })}
  end

  defp validate_tail_events(value) when is_integer(value) and value > 0, do: {:ok, value}

  defp validate_tail_events(value) do
    {:error,
     Tool.error(:invalid_args, "tail_events must be a positive integer", %{
       tail_events: value
     })}
  end

  defp string_schema(description), do: %{"type" => "string", "description" => description}

  defp string_array_schema(description) do
    %{
      "type" => "array",
      "description" => description,
      "items" => %{"type" => "string"}
    }
  end

  defp array_schema(item_schema), do: %{"type" => "array", "items" => item_schema}

  defp nullable_integer_schema, do: %{"anyOf" => [%{"type" => "integer"}, %{"type" => "null"}]}

  defp decision_schema do
    %{
      "type" => "object",
      "additionalProperties" => false,
      "required" => ["seq", "decision", "rationale", "status"],
      "properties" => %{
        "seq" => nullable_integer_schema(),
        "decision" => string_schema("Decision text."),
        "rationale" => string_schema("Evidence-backed rationale, if available."),
        "status" => %{
          "type" => "string",
          "enum" => ["accepted", "tentative", "superseded", "unknown"]
        }
      }
    }
  end

  defp command_evidence_schema do
    %{
      "type" => "object",
      "additionalProperties" => false,
      "required" => ["seq", "command_or_tool", "result", "important_output"],
      "properties" => %{
        "seq" => nullable_integer_schema(),
        "command_or_tool" => string_schema("Command or tool name."),
        "result" => %{"type" => "string", "enum" => ["passed", "failed", "partial", "unknown"]},
        "important_output" => string_schema("Short evidence summary.")
      }
    }
  end

  defp subagent_workflow_schema do
    %{
      "type" => "object",
      "additionalProperties" => false,
      "required" => ["id", "status", "result", "usable"],
      "properties" => %{
        "id" => string_schema("Subagent id, workflow id, or unknown."),
        "status" => %{
          "type" => "string",
          "enum" => ["completed", "failed", "timed_out", "cancelled", "detached", "unknown"]
        },
        "result" => string_schema("Short terminal or partial result."),
        "usable" => %{"type" => "boolean"}
      }
    }
  end

  @doc """
  The `to_seq` of the latest compaction checkpoint in `history`, or `nil` when the
  Session has never been compacted. Keys context-pressure warning hysteresis
  (ADR 0020): a new checkpoint re-arms the warning gate.
  """
  @spec latest_checkpoint_to_seq([Event.t()]) :: non_neg_integer() | nil
  def latest_checkpoint_to_seq(history) when is_list(history) do
    history |> latest_compaction() |> compaction_to_seq()
  end

  defp latest_compaction(history) do
    history
    |> Enum.filter(&(&1.type == :history_compaction))
    |> Enum.max_by(&(&1.seq || -1), fn -> nil end)
  end

  defp compaction_to_seq(nil), do: nil

  defp compaction_to_seq(%{data: %{"range" => %{"to_seq" => to_seq}}}) when is_integer(to_seq),
    do: to_seq

  defp compaction_to_seq(_event), do: nil

  defp split_for_compaction(candidates, tail_events) when length(candidates) <= tail_events,
    do: {[], candidates}

  defp split_for_compaction(candidates, tail_events) do
    compact_count = length(candidates) - tail_events
    Enum.split(candidates, compact_count)
  end

  defp carry_forward(nil, compact_prefix), do: compact_prefix
  defp carry_forward(compaction, compact_prefix), do: [compaction | compact_prefix]

  defp event_data(compact_prefix, tail, trigger) do
    skill_activation_count = compacted_skill_activation_count(compact_prefix)
    all_skill_activations = compacted_skill_activations(compact_prefix)
    skill_activations = latest_skill_activation_identities(all_skill_activations)

    %{
      "strategy" => @strategy_deterministic,
      "trigger" => trigger,
      "range" => %{
        "from_seq" => range_from_seq(compact_prefix),
        "to_seq" => range_to_seq(compact_prefix)
      },
      "source_event_count" => source_event_count(compact_prefix),
      "tail_event_count" => length(tail),
      "event_counts" => event_counts(compact_prefix),
      "compacted_skill_activation_count" => skill_activation_count,
      "compacted_skill_activations" => skill_activations,
      "tool_calls" => tool_calls(compact_prefix),
      "files_touched" => files_touched(compact_prefix),
      "open_tasks" => open_tasks(compact_prefix),
      "limitations" => limitations(skill_activation_count, all_skill_activations),
      "summary" => summary(compact_prefix)
    }
  end

  defp limitations(skill_activation_count, skill_activations) do
    base = [
      "Deterministic compaction keeps operational facts and recent tail; it is not a semantic substitute for the full Log.",
      "The full NDJSON Log remains authoritative for audit, resume repair, and deeper reconstruction."
    ]

    base
    |> append_if(skill_activation_count > 0, @skill_activation_limitation)
    |> append_if(skill_activations != [], named_skill_activation_limitation(skill_activations))
  end

  defp append_if(list, false, _item), do: list
  defp append_if(list, true, item), do: list ++ [item]

  # Design note 0002 principle 5: the checkpoint states WHICH skill activations were
  # compacted away, so a future Turn told by the canonical limitation sentence to
  # "explicitly re-activate" knows what to re-activate without re-reading the raw Log.
  # Path and content hash ride along for principle 7 (recoverability and invalidation).
  defp named_skill_activation_limitation(skill_activations) do
    shown = latest_skill_activation_identities(skill_activations)
    omitted_count = max(length(skill_activations) - length(shown), 0)
    suffix = if omitted_count == 0, do: ".", else: "; +#{omitted_count} earlier."

    "Compacted skill activations: " <>
      Enum.map_join(shown, "; ", &skill_activation_identity/1) <> suffix
  end

  defp latest_skill_activation_identities(records) do
    records
    |> Enum.sort_by(&skill_activation_seq/1)
    |> Enum.take(-@max_named_skill_identities)
  end

  defp skill_activation_seq(%{"seq" => seq}) when is_integer(seq), do: seq
  defp skill_activation_seq(_record), do: -1

  defp skill_activation_identity(record) do
    "#{record["name"] || "unknown"} (seq #{record["seq"] || "?"}, " <>
      "#{record["path"] || "unknown path"}, sha256 #{record["content_hash"] || "unknown"})"
  end

  # ADR 0020: skill activations only count when they fall inside the compacted range.
  # Activations that live in the kept tail are still replayed verbatim, so the tail is
  # never inspected here. A prior checkpoint carried forward by `carry_forward/2` keeps
  # the fact alive through re-compaction structurally — its persisted
  # `compacted_skill_activation_count` aggregates every deeper level, mirroring
  # `source_event_count/1`. The limitation sentence is purely presentational and is
  # never used for detection.
  defp compacted_skill_activation_count(events) do
    Enum.reduce(events, 0, fn
      %{type: :skill_activation}, acc ->
        acc + 1

      %{type: :history_compaction, data: data}, acc when is_map(data) ->
        acc + checkpoint_skill_activation_count(data)

      _event, acc ->
        acc
    end)
  end

  defp checkpoint_skill_activation_count(%{"compacted_skill_activation_count" => count})
       when is_integer(count) and count >= 0,
       do: count

  # Checkpoints recorded before the explicit count existed expose the fact only through
  # their flat `event_counts` (one checkpoint level deep).
  defp checkpoint_skill_activation_count(%{"event_counts" => %{"skill_activation" => count}})
       when is_integer(count) and count >= 0,
       do: count

  defp checkpoint_skill_activation_count(_data), do: 0

  # Per-event identity for every skill activation dropped by this checkpoint, reusing the
  # `tool_calls/1` structural precedent (seq + identifying data). Identities recorded by a
  # carried-forward checkpoint survive re-compaction verbatim; legacy checkpoints that
  # only persisted a count still contribute to `compacted_skill_activation_count/1` but
  # cannot contribute identities — the raw Log remains the recovery path for those.
  defp compacted_skill_activations(events) do
    Enum.flat_map(events, fn
      %{type: :skill_activation, seq: seq, data: data} when is_map(data) ->
        [
          %{
            "seq" => seq,
            "name" => data["name"],
            "path" => data["path"],
            "content_hash" => data["content_hash"]
          }
        ]

      %{type: :history_compaction, data: %{"compacted_skill_activations" => records}}
      when is_list(records) ->
        records
        |> Enum.filter(&is_map/1)
        |> Enum.map(&Map.take(&1, ["seq", "name", "path", "content_hash"]))

      _event ->
        []
    end)
  end

  defp first_seq(events), do: events |> List.first() |> Map.get(:seq)
  defp last_seq(events), do: events |> List.last() |> Map.get(:seq)

  defp range_from_seq([
         %{type: :history_compaction, data: %{"range" => %{"from_seq" => seq}}} | _
       ])
       when is_integer(seq),
       do: seq

  defp range_from_seq(events), do: first_seq(events)

  defp range_to_seq(events) do
    seqs =
      Enum.flat_map(events, fn
        %{type: :history_compaction, data: %{"range" => %{"to_seq" => seq}}}
        when is_integer(seq) ->
          [seq]

        %{seq: seq} when is_integer(seq) ->
          [seq]

        _event ->
          []
      end)

    case seqs do
      [] -> nil
      seqs -> Enum.max(seqs)
    end
  end

  defp source_event_count(events) do
    Enum.reduce(events, 0, fn
      %{type: :history_compaction, data: %{"source_event_count" => count}}, acc
      when is_integer(count) ->
        acc + count

      _event, acc ->
        acc + 1
    end)
  end

  defp event_for_model(%{} = event) do
    %{
      "id" => event.id,
      "seq" => event.seq,
      "ts" => event.ts,
      "type" => Atom.to_string(event.type),
      "data" => event.data
    }
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
    |> Enum.filter(
      &(&1.type in [:history_compaction, :user_message, :assistant_message, :subagent_event])
    )
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
      |> Enum.filter(
        &(&1.type in [:history_compaction, :user_message, :assistant_message, :subagent_event])
      )
      |> Enum.take(-6)
      |> Enum.map(&event_excerpt/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.map_join("\n", &("- " <> &1))

    """
    Compacted #{length(events)} events (#{counts}).
    Recent compacted conversational facts:
    #{if excerpts == "", do: "- none recorded", else: excerpts}
    """
    |> String.trim()
  end

  defp event_excerpt(%{type: :user_message, data: %{"text" => text}}),
    do: "user: " <> excerpt(text)

  defp event_excerpt(%{type: :assistant_message, data: %{"text" => text}}),
    do: "assistant: " <> excerpt(text)

  # Session-scoped posture evidence is not conversational material: excerpting
  # it would persist "subagent unknown: permission_posture" noise into
  # compaction summaries (and branch summaries) for every root Session.
  defp event_excerpt(%{type: :subagent_event, data: %{"event" => "permission_posture"}}), do: ""

  defp event_excerpt(%{type: :subagent_event, data: data}) do
    summary = data["summary"] || data["status"] || data["event"] || ""
    "subagent #{data["subagent_id"] || "unknown"}: " <> excerpt(summary)
  end

  defp event_excerpt(%{type: :history_compaction, data: data}) do
    range = data["range"] || %{}

    "previous checkpoint seq #{range["from_seq"]}..#{range["to_seq"]}: " <>
      excerpt(data["summary"] || "")
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
