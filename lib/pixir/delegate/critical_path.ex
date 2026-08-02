defmodule Pixir.Delegate.CriticalPath do
  @moduledoc """
  Pure critical-path estimates for Delegate launch admission.

  Subagent estimates use `ceil(task_count / max_threads)` scheduling waves
  multiplied by the resolved uniform child budget. Workflow estimates sum the
  largest effective step budget in each planned dependency wave. Omitted step
  budgets use the runtime Subagent default, while both omitted and explicit budgets
  are capped by the normalized workflow timeout for the current estimate and
  `wave_budgets_ms`. `suggested_timeout_ms` is the least sufficient fixed point after
  that cap moves: it sums each wave's uncapped declared/default maximum, and can
  therefore exceed the current estimate only when the current workflow timeout binds.
  The estimate details carry the resolved caller horizon, whether that wait horizon was
  explicitly supplied rather than defaulted from the delegate timeout, the normalized
  declared workflow timeout, and whether that workflow timeout was explicitly declared
  before default injection, separately from their effective minimum. Rejection recovery
  chooses the wait-horizon knob when it was explicit and the delegate-timeout knob when
  it was derived. An explicit workflow timeout is combined with that caller knob only
  when it also binds. An omitted workflow timeout instead remains a delegate-derived
  ceiling: with an explicit wait horizon, recovery independently widens the wait and/or
  delegate timeout that binds; with a derived wait horizon, widening the delegate timeout
  alone moves both values. Maps from older callers that lack binding-source evidence
  retain the prior classification. Relaunching once at the suggestion is sufficient.
  Separately from admission, `capped_step_budgets/4` names every explicitly declared step
  budget an explicitly declared workflow timeout caps, so the dry-run can predict the
  runtime `closed_by_workflow_timeout` cancellation instead of leaving it implicit in the
  gap between `estimated_critical_path_ms` and `suggested_timeout_ms`. That warning is
  purely advisory: it never moves `would_reject`, an admission verdict, or an exit code.
  Workflow wave maxima deliberately form a conservative batch-admission sum; a
  work-conserving scheduler can realize less wall time by starting newly unblocked work
  before a whole batch finishes.
  Admission still fails closed on that sum. Retries, provider jitter, and orchestration
  overhead are intentionally excluded.
  """

  @type estimate :: %{
          required(:estimated_critical_path_ms) => pos_integer(),
          required(:waves) => pos_integer(),
          required(:suggested_timeout_ms) => pos_integer(),
          optional(:json_pointer) => String.t(),
          optional(:path) => [String.t() | non_neg_integer()],
          optional(:step_index) => non_neg_integer(),
          optional(:per_wave_budget_ms) => pos_integer(),
          optional(:wave_budgets_ms) => [pos_integer()]
        }

  @doc "Estimate uniform-budget Subagent scheduling waves."
  @spec estimate_subagents(pos_integer(), pos_integer(), pos_integer()) ::
          {:ok, estimate()} | {:error, map()}
  def estimate_subagents(task_count, max_threads, child_budget_ms)
      when is_integer(task_count) and task_count > 0 and is_integer(max_threads) and
             max_threads > 0 and is_integer(child_budget_ms) and child_budget_ms > 0 do
    waves = div(task_count + max_threads - 1, max_threads)
    estimate = waves * child_budget_ms

    {:ok,
     %{
       estimated_critical_path_ms: estimate,
       waves: waves,
       suggested_timeout_ms: estimate,
       per_wave_budget_ms: child_budget_ms,
       wave_budgets_ms: List.duplicate(child_budget_ms, waves),
       json_pointer: "/subagents/max_threads",
       path: ["subagents", "max_threads"]
     }}
  end

  def estimate_subagents(_task_count, _max_threads, _child_budget_ms),
    do: {:error, %{kind: :invalid_args, message: "critical-path inputs must be positive"}}

  @doc "Estimate a Workflow using the runtime default for omitted step budgets."
  @spec estimate_workflow([map()], [[non_neg_integer()]], pos_integer()) ::
          {:ok, estimate()} | {:error, map()}
  def estimate_workflow(steps, waves, workflow_timeout_ms) do
    estimate_workflow(
      steps,
      waves,
      workflow_timeout_ms,
      Pixir.Subagents.default_limits().timeout_ms
    )
  end

  @doc "Estimate a Workflow; current arithmetic is capped, while suggestion is its fixed point."
  @spec estimate_workflow([map()], [[non_neg_integer()]], pos_integer(), pos_integer()) ::
          {:ok, estimate()} | {:error, map()}
  def estimate_workflow(steps, waves, workflow_timeout_ms, omitted_step_budget_ms)
      when is_list(steps) and is_list(waves) and waves != [] and
             is_integer(workflow_timeout_ms) and workflow_timeout_ms > 0 and
             is_integer(omitted_step_budget_ms) and omitted_step_budget_ms > 0 do
    with {:ok, maxima} <-
           wave_maxima(steps, waves, workflow_timeout_ms, omitted_step_budget_ms),
         {:ok, suggestion_maxima} <-
           wave_maxima(steps, waves, nil, omitted_step_budget_ms) do
      estimate = Enum.sum(Enum.map(maxima, &elem(&1, 0)))
      suggestion = Enum.sum(Enum.map(suggestion_maxima, &elem(&1, 0)))
      {_budget, source_index} = Enum.max_by(maxima, fn {budget, index} -> {budget, -index} end)

      {:ok,
       %{
         estimated_critical_path_ms: estimate,
         waves: length(waves),
         suggested_timeout_ms: suggestion,
         wave_budgets_ms: Enum.map(maxima, &elem(&1, 0)),
         json_pointer: "/steps/#{source_index}/timeout_ms",
         path: ["steps", source_index, "timeout_ms"],
         step_index: source_index
       }}
    end
  end

  def estimate_workflow(_steps, _waves, _workflow_timeout_ms, _omitted_step_budget_ms),
    do: {:error, %{kind: :invalid_args, message: "workflow estimate requires non-empty waves"}}

  @doc """
  Name every explicitly declared step budget the declared workflow timeout caps.

  Returns `[]` unless the workflow timeout was explicitly declared in the spec: a
  defaulted/derived workflow timeout is a delegate-derived ceiling already covered by
  the horizon guard, not an operator-declared conflict. Steps that omitted `timeout_ms`
  declare no conflicting intent and are skipped even though the Subagent default they
  fall back to may exceed the workflow timeout. Steps whose declared budget is less than
  or equal to the declared workflow timeout are not capped.

  `steps_path` is the 0-based location prefix of the step list *as the caller submitted
  it*, so machine callers can patch the pointer they actually sent: `["steps"]` for a
  flat spec and `["workflow", "steps"]` for the nested shell form, which the runner
  flattens before estimation.
  """
  @spec capped_step_budgets(
          [map()],
          pos_integer() | nil,
          boolean(),
          [String.t()]
        ) :: [map()]
  def capped_step_budgets(
        steps,
        declared_workflow_timeout_ms,
        declared_workflow_timeout_explicit,
        steps_path \\ ["steps"]
      )

  def capped_step_budgets(steps, declared_workflow_timeout_ms, true, steps_path)
      when is_list(steps) and is_integer(declared_workflow_timeout_ms) and
             declared_workflow_timeout_ms > 0 and is_list(steps_path) do
    steps
    |> Enum.with_index()
    |> Enum.flat_map(fn {step, index} ->
      case declared_step_budget(step) do
        budget when is_integer(budget) and budget > declared_workflow_timeout_ms ->
          [capped_step_entry(step, index, budget, declared_workflow_timeout_ms, steps_path)]

        _within_cap_or_omitted ->
          []
      end
    end)
  end

  def capped_step_budgets(_steps, _declared_workflow_timeout_ms, _explicit, _steps_path), do: []

  @doc """
  Build the additive, machine-readable capped-step-budget warning, or `nil` when empty.

  The warning is advisory only: it never changes `would_reject`, the admission verdict,
  or the exit code of an accepted plan. Its recovery guidance covers both directions
  (raise the workflow timeout, or lower the offending step budgets) and reuses the exact
  runtime remedy token the workflow-timeout fold publishes so dry-run and fold vocabulary
  stay greppable together.
  """
  @spec capped_step_budget_warning([map()]) :: map() | nil
  def capped_step_budget_warning([]), do: nil

  def capped_step_budget_warning([first | _rest] = entries) when is_list(entries) do
    %{
      "kind" => "step_budget_capped_by_workflow_timeout",
      "declared_workflow_timeout_ms" => first["declared_workflow_timeout_ms"],
      "steps" => entries,
      "summary" => capped_step_budget_summary(entries),
      "next_actions" => [
        "increase_workflow_timeout_to_cover_declared_step_timeouts",
        "reduce_workflow_step_timeouts",
        "retry_workflow_with_larger_timeout"
      ]
    }
  end

  @doc "Human-readable capped-step-budget lines, one per offending step."
  @spec capped_step_budget_summary([map()]) :: String.t()
  def capped_step_budget_summary(entries) when is_list(entries) do
    "Delegate dry-run warning: " <> Enum.map_join(entries, "; ", & &1["message"])
  end

  defp capped_step_entry(
         step,
         index,
         declared_budget_ms,
         declared_workflow_timeout_ms,
         steps_path
       ) do
    path = steps_path ++ [index, "timeout_ms"]

    %{
      "step_index" => index,
      "json_pointer" => "/" <> Enum.join(path, "/"),
      "path" => path,
      "declared_step_timeout_ms" => declared_budget_ms,
      "declared_workflow_timeout_ms" => declared_workflow_timeout_ms,
      "effective_step_timeout_ms" => declared_workflow_timeout_ms,
      "message" => capped_step_message(declared_budget_ms, declared_workflow_timeout_ms)
    }
    |> put_step_id(step)
  end

  defp capped_step_message(declared_budget_ms, declared_workflow_timeout_ms) do
    "step budget #{declared_budget_ms} ms is capped by workflow timeout " <>
      "#{declared_workflow_timeout_ms} ms and will be cancelled at " <>
      "#{declared_workflow_timeout_ms} ms"
  end

  defp put_step_id(entry, step) do
    case Map.get(step, "id", Map.get(step, :id)) do
      id when is_binary(id) and id != "" -> Map.put(entry, "step_id", id)
      _unset -> entry
    end
  end

  # Declared-versus-omitted must stay distinguishable here: `effective_step_budget/3`
  # deliberately collapses an omitted budget into the Subagent default, which would
  # otherwise make every default-budget step look like a declared conflict.
  defp declared_step_budget(step) when is_map(step) do
    case Map.get(step, "timeout_ms", Map.get(step, :timeout_ms)) do
      value when is_integer(value) and value > 0 -> value
      _omitted -> nil
    end
  end

  defp declared_step_budget(_step), do: nil

  @doc "Return the four stable horizon values shared by advisory, rejection, and override."
  @spec horizon_values(map()) :: map()
  def horizon_values(details) do
    Map.take(details, [
      "effective_timeout_ms",
      "estimated_critical_path_ms",
      "waves",
      "suggested_timeout_ms"
    ])
  end

  @doc "Build the canonical fail-closed horizon error from an enriched estimate."
  @spec rejection(map()) :: map()
  def rejection(details) do
    %{
      "ok" => false,
      "status" => "rejected",
      "kind" => "horizon_shorter_than_critical_path",
      "message" => arithmetic(details),
      "details" =>
        details
        |> Map.drop(["per_wave_budget_ms", "wave_budgets_ms"])
        |> Map.put("next_actions", rejection_next_actions(details))
    }
  end

  defp rejection_next_actions(%{"strategy" => "workflow"} = details) do
    [
      workflow_timeout_action(details),
      "reduce_workflow_dependency_waves",
      "reduce_workflow_step_timeouts",
      "rerun_with_--allow-short-horizon"
    ]
  end

  defp rejection_next_actions(details) do
    [
      caller_timeout_action(details),
      "reduce_delegate_task_count",
      "increase_subagents_max_threads",
      "rerun_with_--allow-short-horizon"
    ]
  end

  defp caller_timeout_action(%{"wait_horizon_explicit" => true}),
    do: "increase_wait_horizon_to_suggested_timeout_ms"

  defp caller_timeout_action(_details),
    do: "increase_delegate_timeout_to_suggested_timeout_ms"

  # New admission payloads classify caller and workflow ceilings from binding-source
  # evidence. An explicit wait horizon must be widened directly; changing the delegate
  # timeout underneath it would not move that caller horizon. An omitted workflow timeout
  # remains a delegate-derived ceiling, so recovery widens the delegate timeout whenever
  # that ceiling binds.
  defp workflow_timeout_action(
         %{
           "caller_horizon_ms" => caller_horizon_ms,
           "wait_horizon_explicit" => wait_horizon_explicit,
           "declared_workflow_timeout_ms" => declared_workflow_timeout_ms,
           "declared_workflow_timeout_explicit" => declared_workflow_timeout_explicit,
           "suggested_timeout_ms" => suggested_timeout_ms
         } = details
       )
       when is_integer(caller_horizon_ms) and is_boolean(wait_horizon_explicit) and
              is_integer(declared_workflow_timeout_ms) and
              is_boolean(declared_workflow_timeout_explicit) and
              is_integer(suggested_timeout_ms) do
    caller_action = caller_timeout_action(details)

    caller_short? = caller_horizon_ms < suggested_timeout_ms
    declared_workflow_timeout_short? = declared_workflow_timeout_ms < suggested_timeout_ms

    if declared_workflow_timeout_explicit do
      case {caller_short?, declared_workflow_timeout_short?} do
        {true, false} -> caller_action
        {false, true} -> "increase_workflow_timeout_to_suggested_timeout_ms"
        {true, true} -> combined_workflow_timeout_action(wait_horizon_explicit)
        {false, false} -> caller_action
      end
    else
      omitted_workflow_timeout_action(
        caller_short?,
        declared_workflow_timeout_short?,
        wait_horizon_explicit
      )
    end
  end

  # Compatibility for enriched maps produced before wait-horizon binding-source
  # evidence was available: preserve their prior caller/delegate classification.
  defp workflow_timeout_action(%{
         "caller_horizon_ms" => caller_horizon_ms,
         "declared_workflow_timeout_ms" => declared_workflow_timeout_ms,
         "declared_workflow_timeout_explicit" => declared_workflow_timeout_explicit,
         "suggested_timeout_ms" => suggested_timeout_ms
       })
       when is_integer(caller_horizon_ms) and is_integer(declared_workflow_timeout_ms) and
              is_boolean(declared_workflow_timeout_explicit) and
              is_integer(suggested_timeout_ms) do
    case {
      caller_horizon_ms < suggested_timeout_ms,
      declared_workflow_timeout_explicit and
        declared_workflow_timeout_ms < suggested_timeout_ms
    } do
      {true, false} -> "increase_delegate_timeout_to_suggested_timeout_ms"
      {false, true} -> "increase_workflow_timeout_to_suggested_timeout_ms"
      {true, true} -> "increase_delegate_and_workflow_timeouts_to_suggested_timeout_ms"
      {false, false} -> "increase_delegate_timeout_to_suggested_timeout_ms"
    end
  end

  # Compatibility for enriched maps produced before binding-source explicitness was
  # available: preserve their prior two-value classification.
  defp workflow_timeout_action(%{
         "caller_horizon_ms" => caller_horizon_ms,
         "declared_workflow_timeout_ms" => declared_workflow_timeout_ms,
         "suggested_timeout_ms" => suggested_timeout_ms
       })
       when is_integer(caller_horizon_ms) and is_integer(declared_workflow_timeout_ms) and
              is_integer(suggested_timeout_ms) do
    case {
      caller_horizon_ms < suggested_timeout_ms,
      declared_workflow_timeout_ms < suggested_timeout_ms
    } do
      {true, false} -> "increase_delegate_timeout_to_suggested_timeout_ms"
      {false, true} -> "increase_workflow_timeout_to_suggested_timeout_ms"
      {true, true} -> "increase_delegate_and_workflow_timeouts_to_suggested_timeout_ms"
      {false, false} -> "increase_delegate_timeout_to_suggested_timeout_ms"
    end
  end

  defp workflow_timeout_action(%{
         "suggested_timeout_ms" => suggested_timeout_ms,
         "estimated_critical_path_ms" => estimated_critical_path_ms
       })
       when is_integer(suggested_timeout_ms) and is_integer(estimated_critical_path_ms) and
              suggested_timeout_ms > estimated_critical_path_ms,
       do: "increase_delegate_and_workflow_timeouts_to_suggested_timeout_ms"

  defp workflow_timeout_action(_details),
    do: "increase_delegate_timeout_to_suggested_timeout_ms"

  defp omitted_workflow_timeout_action(_caller_short?, _delegate_ceiling_short?, false),
    do: "increase_delegate_timeout_to_suggested_timeout_ms"

  defp omitted_workflow_timeout_action(true, true, true),
    do: "increase_wait_horizon_and_delegate_timeout_to_suggested_timeout_ms"

  defp omitted_workflow_timeout_action(true, false, true),
    do: "increase_wait_horizon_to_suggested_timeout_ms"

  defp omitted_workflow_timeout_action(false, true, true),
    do: "increase_delegate_timeout_to_suggested_timeout_ms"

  defp omitted_workflow_timeout_action(false, false, true),
    do: "increase_wait_horizon_to_suggested_timeout_ms"

  defp combined_workflow_timeout_action(true),
    do: "increase_wait_horizon_and_workflow_timeouts_to_suggested_timeout_ms"

  defp combined_workflow_timeout_action(false),
    do: "increase_delegate_and_workflow_timeouts_to_suggested_timeout_ms"

  defp arithmetic(details) do
    expression =
      case details["per_wave_budget_ms"] do
        per_wave when is_integer(per_wave) ->
          "#{details["waves"]} waves x #{per_wave}ms per wave"

        _workflow ->
          details["wave_budgets_ms"]
          |> Enum.map_join(" + ", &"#{&1}ms")
      end

    "#{expression} = #{details["estimated_critical_path_ms"]}ms > #{details["effective_timeout_ms"]}ms horizon"
  end

  defp wave_maxima(steps, waves, workflow_timeout_ms, omitted_step_budget_ms) do
    Enum.reduce_while(waves, {:ok, []}, fn wave, {:ok, acc} ->
      budgets =
        Enum.map(wave, fn index ->
          case Enum.at(steps, index) do
            %{} = step ->
              {effective_step_budget(step, workflow_timeout_ms, omitted_step_budget_ms), index}

            _missing ->
              :invalid
          end
        end)

      if budgets != [] and :invalid not in budgets do
        maximum = Enum.max_by(budgets, fn {budget, index} -> {budget, -index} end)
        {:cont, {:ok, acc ++ [maximum]}}
      else
        {:halt,
         {:error, %{kind: :invalid_args, message: "workflow wave references an invalid step"}}}
      end
    end)
  end

  defp effective_step_budget(step, workflow_timeout_ms, omitted_step_budget_ms) do
    budget =
      case Map.get(step, "timeout_ms", Map.get(step, :timeout_ms)) do
        value when is_integer(value) and value > 0 -> value
        _unset -> omitted_step_budget_ms
      end

    case workflow_timeout_ms do
      timeout when is_integer(timeout) and timeout > 0 -> min(budget, timeout)
      nil -> budget
    end
  end
end
