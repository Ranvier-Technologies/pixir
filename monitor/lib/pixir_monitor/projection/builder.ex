defmodule PixirMonitor.Projection.Builder do
  @moduledoc """
  Deterministic fold for Presenter Projection v1.

  This module deliberately keeps canonical execution, Workflow gates, model advisory,
  mutation, and volatile liveness as independent records. All helpers are pure over a
  bounded caller-supplied input map.
  """

  alias PixirMonitor.Projection.{Advisory, AttemptStatus, Gate, UnitIdentity, WorkflowGraph}

  @terminal ~w(completed failed timed_out cancelled detached closed)
  @lifecycle ~w(queued started input retrying finished failed timed_out cancelled detached closed)
  @raw_limits ~w(dependency_not_checkpoint_ready partial_repo_mutation subagent_close_failed subagent_may_still_be_running usage_fixture_minimized virtual_diff_not_applied)
  @unit_enum_vocabulary %{
    "execution_kind" => ~w(subagent virtual_overlay virtual_diff_apply unknown),
    "workspace_mode" => ~w(shared isolated virtual_overlay unknown),
    "posture" => ~w(read_only writer virtual_scratch apply unknown)
  }
  @input_enum_vocabulary %{
    run: %{
      "strategy" => ~w(workflow subagents unknown),
      "mode" => ~w(read_only bounded_write unknown)
    },
    execution: %{
      "state" => ~w(planned queued running completed partial failed timed_out cancelled detached closed held unknown)
    },
    advisory: %{"verdict" => ~w(pass stop needs_review unknown)},
    artifact: %{
      "status" => ~w(produced not_applied applied failed unknown),
      "application_state" => ~w(not_applied applied failed conflicted not_applicable unknown)
    }
  }
  @doc false
  # Single source of truth for the served execution-state vocabulary; the
  # list fold (source.ex) fail-closes into the SAME list so list and detail
  # can never drift apart again (Grok r2 on PR #407).
  def execution_state_vocabulary, do: @input_enum_vocabulary[:execution]["state"]

  @action_registry %{
    "inspect_child_session_log" => {"inspect", "read_only", "informational"},
    "inspect_partial_writes_before_retry" => {"inspect", "read_only", "informational"},
    "inspect_timed_out_step" => {"inspect", "read_only", "informational"},
    "rerun_subagent_after_fixing_provider_error" => {"retry", "mutating", "informational"},
    "rerun_after_dependencies_checkpoint_ready" => {"retry", "mutating", "informational"},
    "ask_user_or_orchestrator" => {"other", "read_only", "informational"},
    "apply_virtual_diff" => {"apply", "mutating", "informational"},
    "diagnose_session" => {"diagnose", "read_only", "copy_only"},
    "resume_session" => {"resume", "mutating", "copy_only"}
  }

  @doc "Builds an unpersisted v1 projection from normalized portable evidence."
  @spec build(map()) :: {:ok, map()} | {:error, map()}
  def build(raw) when is_map(raw) do
    fixture? = is_map(raw["inputs"])
    inputs = if fixture?, do: raw["inputs"], else: raw

    with :ok <- require_inputs(inputs),
         {:ok, parent, origin} <- canonical_parent(inputs),
         :ok <- validate_parent(parent) do
      envelope = inputs["terminal_envelope"] || inputs["delegate_snapshot"] || %{}
      workflow = workflow_definition(parent)
      run_id = envelope["delegate_id"] || envelope["parent_session_id"] || infer_parent(inputs, parent)

      cond do
        blank?(run_id) ->
          error("projection_identity_unavailable", "Projection evidence does not identify a run", %{})

        match?({:error, _reason}, Pixir.SessionId.validate(run_id)) ->
          error(
            "run_identity_invalid",
            "Run identity does not satisfy the canonical Pixir Session-id contract",
            %{}
          )

        true ->
          context = %{
            raw: raw,
            inputs: inputs,
            fixture?: fixture?,
            parent: parent,
            envelope: envelope,
            workflow: workflow,
            run_id: run_id,
            parent_id: envelope["parent_session_id"] || infer_parent(inputs, parent),
            origin: origin,
            observed_at: raw["observed_at"] || inputs["observed_at"],
            completeness: raw["completeness"] || %{}
          }

          do_build(context)
      end
    end
  rescue
    # Builder failures can flow into API diagnostics, and their messages can carry
    # filesystem paths or URLs. Report a fixed atom instead of Exception.message/1.
    _exception ->
      error("projection_build_failed", "Projection evidence could not be folded", %{
        exception: :projection_build_raised
      })
  end

  def build(_raw),
    do: error("invalid_projection_input", "Projection input must be a map", %{})

  defp do_build(ctx) do
    raw_limits = raw_limitations(ctx)
    execution = run_execution(ctx)
    source = source(ctx, execution, raw_limits)

    with {:ok, units0} <- units(ctx),
         {:ok, units1} <- enrich_units(units0, ctx, source, raw_limits) do
      graph = graph(ctx, units1)
      root_usage = usage_for_units(units1)
      root_mutation = root_mutation(units1)
      root_actions = units1 |> Enum.flat_map(& &1["safe_actions"]) |> uniq_by(&{&1["scope"], &1["id"], &1["command"]})
      limitations = units1 |> Enum.flat_map(& &1["limitations"]) |> Kernel.++(source["limitations"]) |> uniq()
      units_with_advisory_source = Enum.map(units1, &put_attention/1)
      evidence = evidence(ctx, units_with_advisory_source, execution, source)
      units = Enum.map(units_with_advisory_source, &strip_advisory_source/1)

      projection = %{
        "schema" => "pixir.presenter.run",
        "schema_version" => 1,
        "projection_id" => projection_id(ctx),
        "projected_at" => projected_at(ctx),
        "run" => run(ctx),
        "source" => source,
        "execution" => execution,
        "liveness" => liveness(ctx, execution, raw_limits, false),
        "counts" => %{
          "planned_units" => if(source["mode"] == "live", do: nil, else: length(units)),
          "observed_units" => length(units),
          "running_units" => Enum.count(units, &(&1["execution"]["state"] == "running")),
          "completed_units" => Enum.count(units, &(&1["execution"]["state"] == "completed")),
          "attention_units" => Enum.count(units, & &1["attention"]["required"])
        },
        "graph" => graph,
        "units" => units,
        "usage" => root_usage,
        "mutation" => root_mutation,
        "safe_actions" => root_actions,
        "evidence" => evidence,
        "limitations" => limitations
      }

      projection = normalize_input_reachable_fields(projection, ctx)
      {:ok, normalize_provenance(projection, ctx)}
    end
  end

  defp require_inputs(inputs) when is_map(inputs) do
    required = ~w(terminal_envelope delegate_snapshot parent_log parent_log_origin child_logs runtime_diagnostics owner_state evidence_mirror)
    missing = Enum.reject(required, &Map.has_key?(inputs, &1))
    if missing == [], do: :ok, else: error("invalid_projection_input", "Projection input is missing required source fields", %{missing: missing})
  end

  defp canonical_parent(inputs) do
    parent = inputs["parent_log"]
    mirror = inputs["evidence_mirror"]

    cond do
      is_list(parent) ->
        {:ok, Enum.sort_by(parent, & &1["seq"]), inputs["parent_log_origin"] || "fixture"}

      is_map(mirror) ->
        case Enum.find(mirror["logs"] || [], &(&1["role"] == "parent" and verified_mirror?(&1))) do
          nil -> {:ok, [], "none"}
          item -> {:ok, Enum.sort_by(item["events"] || [], & &1["seq"]), "evidence_mirror"}
        end

      true ->
        {:ok, [], "none"}
    end
  end

  defp verified_mirror?(item), do: item["status"] == "verified_copy" and item["reported_source_sha256"] == item["reported_mirror_sha256"]

  defp validate_parent(events) do
    duplicate = events |> Enum.group_by(& &1["seq"]) |> Enum.find(fn {_seq, rows} -> length(rows) > 1 end)

    if duplicate do
      error("parent_log_sequence_conflict", "Parent Log sequence is not unique", %{
        seq: elem(duplicate, 0)
      })
    else
      with :ok <- validate_workflow_graph(events),
           :ok <- validate_subagent_components(events) do
        :ok
      end
    end
  end

  defp validate_workflow_graph(events) do
    case workflow_start(events) do
      nil ->
        :ok

      event ->
        with {:ok, _workflow_id} <- UnitIdentity.component(get_in(event, ["data", "workflow_id"])),
             {:ok, :valid} <-
               WorkflowGraph.validate(get_in(event, ["data", "graph", "steps"])) do
          :ok
        else
          {:error, %{kind: "run_unit_identity_invalid"}} ->
            error(
              "run_graph_identity_invalid",
              "Workflow identity cannot be encoded as an unambiguous logical unit id",
              %{}
            )

          {:error, _reason} = error ->
            error
        end
    end
  end

  defp validate_subagent_components(events) do
    events
    |> Enum.filter(&recognized_subagent_lifecycle_event?/1)
    |> Enum.reduce_while(:ok, fn event, :ok ->
      case get_in(event, ["data", "subagent_id"]) do
        nil ->
          {:cont, :ok}

        id ->
          case UnitIdentity.component(id) do
            {:ok, _safe_id} -> {:cont, :ok}
            {:error, _reason} -> {:halt, unit_identity_error(event["seq"])}
          end
      end
    end)
  end

  defp unit_identity_error(seq) do
    error(
      "run_unit_identity_invalid",
      "Subagent identity cannot be encoded as an unambiguous logical unit id",
      %{seq: seq}
    )
  end

  defp run(ctx) do
    workflow_id = ctx.envelope["workflow_id"] || elem(ctx.workflow, 0)
    start = workflow_start(ctx.parent)
    ref = envelope_ref(ctx)

    %{
      "id" => ctx.run_id,
      "delegate_id" => ctx.envelope["delegate_id"],
      "parent_session_id" => ctx.parent_id,
      "workflow_id" => workflow_id,
      "strategy" => run_strategy(ctx, workflow_id),
      "mode" => ctx.envelope["mode"] || "unknown",
      "title" => get_in(start || %{}, ["data", "workflow_name"]),
      "evidence_refs" => compact([ref])
    }
  end

  defp run_strategy(ctx, workflow_id) do
    cond do
      is_binary(ctx.envelope["strategy"]) -> ctx.envelope["strategy"]
      is_binary(workflow_id) -> "workflow"
      Enum.any?(ctx.parent, &recognized_subagent_lifecycle_event?/1) -> "subagents"
      true -> "unknown"
    end
  end

  defp recognized_subagent_lifecycle_event?(event) do
    event["type"] == "subagent_event" and get_in(event, ["data", "event"]) in @lifecycle
  end

  defp run_execution(ctx) do
    finish = Enum.filter(ctx.parent, &(&1["type"] == "workflow_event" and get_in(&1, ["data", "kind"]) == "workflow_finished")) |> List.last()
    subs = Enum.filter(ctx.parent, &recognized_subagent_lifecycle_event?/1)

    cond do
      finish ->
        execution(get_in(finish, ["data", "status"]) || "unknown", "workflow_event_fold", [parent_ref(finish)])

      subs != [] ->
        latest = latest_subagent_lifecycle(subs)
        state = aggregate_subagent_state(latest)
        execution(state, "subagent_event_fold", Enum.map(latest, &parent_ref/1))

      true ->
        execution("unknown", "unknown", [])
    end
  end

  defp execution(state, basis, refs), do: %{"state" => state, "terminal" => state in @terminal or state in ~w(partial held), "basis" => basis, "evidence_refs" => compact(refs)}

  defp latest_subagent_lifecycle(events) do
    events
    |> Enum.group_by(&get_in(&1, ["data", "subagent_id"]))
    |> Map.delete(nil)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(fn {_id, rows} -> List.last(rows) end)
  end

  defp aggregate_subagent_state(events) do
    states = Enum.map(events, &(get_in(&1, ["data", "status"]) || "unknown"))

    cond do
      Enum.any?(states, &(&1 in ~w(running started input retrying))) -> "running"
      "queued" in states -> "queued"
      "failed" in states -> "failed"
      "timed_out" in states -> "timed_out"
      "cancelled" in states -> "cancelled"
      "detached" in states -> "detached"
      "closed" in states -> "closed"
      states != [] and Enum.all?(states, &(&1 == "completed")) -> "completed"
      true -> List.last(states) || "unknown"
    end
  end

  defp source(ctx, execution, raw_limits) do
    has_durable = ctx.parent != [] or is_map(ctx.inputs["evidence_mirror"])
    owner = ctx.inputs["owner_state"] || %{}
    diagnostics = ctx.inputs["runtime_diagnostics"]
    reachable = owner["reachable"] == true

    mode =
      cond do
        not has_durable -> "live"
        reachable and is_map(diagnostics) -> "mixed"
        true -> "reconstructed"
      end

    durable_origin =
      cond do
        ctx.origin == "workspace_log" -> "workspace_log"
        ctx.origin == "evidence_mirror" -> "evidence_mirror"
        ctx.origin == "fixture" -> "fixture"
        true -> "none"
      end

    live = liveness(ctx, execution, raw_limits, false)["state"]

    {last_durable_at, malformed_event_timestamp_count} =
      ctx.parent
      |> Enum.map(& &1["ts"])
      |> derived_datetime_max()

    freshness =
      cond do
        execution["terminal"] -> "terminal"
        has_durable and live in ~w(stale_handle owner_unavailable) -> "stale"
        mode in ~w(live mixed) -> "current"
        true -> "unknown"
      end

    source_limits =
      []
      |> maybe_add(mirror_conflict?(ctx), "canonical_source_conflict")
      |> maybe_add(not has_durable, "durable_log_unavailable")
      |> maybe_add(child_logs_missing?(ctx), "child_log_missing")
      |> maybe_add(freshness == "stale", "source_stale")
      |> maybe_add("subagent_may_still_be_running" in raw_limits, "subagent_may_still_be_running")
      |> maybe_add(
        malformed_event_timestamp_count > 0,
        "malformed_event_timestamps:#{malformed_event_timestamp_count}"
      )

    %{
      "mode" => mode,
      "durable_origin" => durable_origin,
      "as_of_seq" => ctx.parent |> Enum.map(& &1["seq"]) |> max_or_nil(),
      "last_durable_at" => last_durable_at,
      "live_observed_at" => if(mode in ~w(live mixed), do: get_in(diagnostics || %{}, ["observed_at"]), else: nil),
      "freshness" => freshness,
      "limitations" => source_limits
    }
  end

  defp units(ctx) do
    {workflow_id, steps} = ctx.workflow

    cond do
      workflow_id && steps != [] ->
        {:ok, Enum.map(steps, &workflow_unit(&1, workflow_id))}

      ctx.parent != [] ->
        {:ok, fanout_units(ctx)}

      true ->
        with :ok <- validate_volatile_unit_components(ctx) do
          {:ok, volatile_units(ctx)}
        end
    end
  end

  defp validate_volatile_unit_components(ctx) do
    get_in(ctx.inputs, ["runtime_diagnostics", "subagents"])
    |> List.wrap()
    |> Enum.reduce_while(:ok, fn item, :ok ->
      case item do
        %{"id" => id} when is_binary(id) ->
          case UnitIdentity.component(id) do
            {:ok, _safe_id} -> {:cont, :ok}
            {:error, _reason} -> {:halt, unit_identity_error(nil)}
          end

        _item ->
          {:cont, :ok}
      end
    end)
  end

  defp workflow_unit(step, workflow_id) do
    logical = fn id -> "workflow:#{workflow_id}:step:#{id}" end

    %{
      "logical_id" => logical.(step["id"]),
      "unit_kind" => "workflow_step",
      "materialization" => "durable",
      "label" => step["id"],
      "agent" => step["agent"],
      "execution_kind" => step["execution_kind"] || "unknown",
      "workspace_mode" => step["workspace_mode"] || "unknown",
      "posture" => step["posture"] || "unknown",
      "depends_on" => Enum.map(step["depends_on"] || [], logical)
    }
    |> normalize_unit_enums()
  end

  defp fanout_units(ctx) do
    lifecycle_events = Enum.filter(ctx.parent, &recognized_subagent_lifecycle_event?/1)
    ids = lifecycle_events |> Enum.map(&get_in(&1, ["data", "subagent_id"])) |> compact() |> uniq()

    Enum.map(ids, fn id ->
      rows = Enum.filter(lifecycle_events, &(get_in(&1, ["data", "subagent_id"]) == id))
      first = List.first(rows) || %{}
      child = Enum.find(ctx.envelope["children"] || [], &(&1["subagent_id"] == id)) || %{}
      data = first["data"] || %{}
      agent = data["agent"] || child["agent"]

      %{
        "logical_id" => "delegate:#{ctx.run_id}:subagent:#{id}",
        "unit_kind" => "subagent",
        "materialization" => "durable",
        "label" => agent || id,
        "agent" => agent,
        "execution_kind" => "subagent",
        "workspace_mode" => data["workspace_mode"] || child["workspace_mode"] || "unknown",
        "posture" => data["posture"] || child["posture"] || "unknown",
        "depends_on" => []
      }
      |> normalize_unit_enums()
    end)
  end

  defp volatile_units(ctx) do
    for item <- get_in(ctx.inputs, ["runtime_diagnostics", "subagents"]) || [], is_binary(item["id"]) do
      id = item["id"]

      %{
        "logical_id" => "delegate:#{ctx.run_id}:subagent:#{id}",
        "unit_kind" => "subagent",
        "materialization" => "volatile_only",
        "label" => item["agent"] || id,
        "agent" => item["agent"],
        "execution_kind" => "subagent",
        "workspace_mode" => "unknown",
        "posture" => "unknown",
        "depends_on" => []
      }
    end
  end

  defp normalize_input_reachable_fields(projection, ctx) do
    run_raw = %{
      "strategy" => raw_or_projected(ctx.envelope, "strategy", projection["run"]["strategy"]),
      "mode" => raw_or_projected(ctx.envelope, "mode", projection["run"]["mode"])
    }

    {run, run_limits} =
      normalize_enum_fields(projection["run"], @input_enum_vocabulary[:run], run_raw)

    {execution, execution_limits} =
      normalize_enum_fields(projection["execution"], @input_enum_vocabulary[:execution], %{
        "state" => raw_root_execution_state(ctx, projection["execution"]["state"])
      })

    {source, source_limits} = normalize_datetime_fields(projection["source"], ~w(live_observed_at))
    {liveness, liveness_limits} = normalize_datetime_fields(projection["liveness"], ~w(observed_at))

    units = Enum.map(projection["units"], &normalize_input_reachable_unit/1)

    root_limits =
      projection["limitations"]
      |> Kernel.++(run_limits)
      |> Kernel.++(execution_limits)
      |> Kernel.++(liveness_limits)
      |> uniq()

    counts =
      projection["counts"]
      |> Map.put("running_units", Enum.count(units, &(&1["execution"]["state"] == "running")))
      |> Map.put("completed_units", Enum.count(units, &(&1["execution"]["state"] == "completed")))
      |> Map.put("attention_units", Enum.count(units, & &1["attention"]["required"]))

    projection
    |> Map.put("run", run)
    |> Map.put("execution", execution)
    |> Map.put("source", put_nearest_limitations(source, source_limits))
    |> Map.put("liveness", liveness)
    |> Map.put("counts", counts)
    |> Map.put("units", units)
    |> Map.put("limitations", root_limits)
  end

  defp normalize_input_reachable_unit(unit) do
    {execution, execution_limits} =
      normalize_enum_fields(unit["execution"], @input_enum_vocabulary[:execution])

    # advisory.verdict is producer-controlled by classification:
    # Advisory.classify/1 fail-closes every payload into the served vocabulary
    # (mergeable:false wins over a contradicting declared verdict), so the
    # classified value is the authority and is NEVER rewritten from raw. The
    # raw child-declared verdict — from the SAME attempt advisory/2 projected
    # from (transient _raw_verdict, consumed and deleted here) — feeds the
    # confession alone, and ONLY when the classified verdict actually
    # fail-closed to "unknown": everywhere else unknown_enum:field means the
    # field was demoted, and a raw the classifier overrode from stronger
    # signals (mergeable, declared gate) caused no loss to confess.
    classified_verdict = unit["advisory"]["verdict"]

    advisory_limits =
      case Map.fetch(unit["advisory"], "_raw_verdict") do
        {:ok, _raw} when classified_verdict != "unknown" ->
          []

        {:ok, raw} when is_binary(raw) ->
          if raw in @input_enum_vocabulary[:advisory]["verdict"],
            do: [],
            else: ["unknown_enum:verdict:#{bound_free_text(raw)}"]

        {:ok, _raw} ->
          ["unknown_enum:verdict:non_string_value"]

        :error ->
          []
      end

    advisory = Map.delete(unit["advisory"], "_raw_verdict")

    {liveness, liveness_limits} = normalize_datetime_fields(unit["liveness"], ~w(observed_at))

    {artifacts, artifact_limits} =
      Enum.map_reduce(unit["artifacts"], [], fn artifact, limits ->
        {artifact, new_limits} = normalize_enum_fields(artifact, @input_enum_vocabulary[:artifact])
        {artifact, limits ++ new_limits}
      end)

    limitations =
      unit["limitations"]
      |> Kernel.++(execution_limits)
      |> Kernel.++(advisory_limits)
      |> Kernel.++(liveness_limits)
      |> Kernel.++(artifact_limits)
      |> uniq()

    unit
    |> Map.put("execution", execution)
    |> Map.put("advisory", advisory)
    |> Map.put("liveness", liveness)
    |> Map.put("artifacts", artifacts)
    |> Map.put("limitations", limitations)
    |> put_attention()
  end

  defp normalize_enum_fields(value, vocabulary, raw_overrides \\ %{}) do
    Enum.reduce(vocabulary, {value, []}, fn {field, accepted}, {normalized, limitations} ->
      raw = Map.get(raw_overrides, field, normalized[field])
      {normalized, new_limitations} = normalize_enum_field(normalized, field, raw, accepted)
      {normalized, limitations ++ new_limitations}
    end)
  end

  defp normalize_enum_field(value, field, raw, accepted) do
    cond do
      is_binary(raw) and raw in accepted ->
        {Map.put(value, field, raw), []}

      is_binary(raw) ->
        confessed = confess_unknown_enum(Map.put(value, "limitations", []), field, bound_free_text(raw))
        {Map.delete(confessed, "limitations"), confessed["limitations"]}

      true ->
        confessed = confess_unknown_enum(Map.put(value, "limitations", []), field, "non_string_value")
        {Map.delete(confessed, "limitations"), confessed["limitations"]}
    end
  end

  defp normalize_datetime_fields(value, fields) do
    Enum.reduce(fields, {value, []}, fn field, {normalized, limitations} ->
      raw = normalized[field]

      if is_binary(raw) and not valid_iso8601_datetime?(raw) do
        limitation = "malformed_timestamp:#{field}:#{bound_free_text(raw)}"
        {Map.put(normalized, field, nil), limitations ++ [limitation]}
      else
        {normalized, limitations}
      end
    end)
  end

  defp put_nearest_limitations(value, []), do: value

  defp put_nearest_limitations(value, limitations) do
    Map.update!(value, "limitations", &uniq(&1 ++ limitations))
  end

  # A nil raw is treated as ABSENT input (fall back to the projected value),
  # never as an out-of-vocabulary value to confess: an explicit null must not
  # demote a structurally derived projection.
  defp raw_or_projected(source, field, projected) do
    case source[field] do
      nil -> projected
      raw -> raw
    end
  end

  defp raw_root_execution_state(ctx, projected) do
    ctx.parent
    |> Enum.filter(
      &(&1["type"] == "workflow_event" and
          get_in(&1, ["data", "kind"]) == "workflow_finished")
    )
    |> List.last()
    |> then(fn
      nil -> projected
      event -> raw_or_projected(event["data"] || %{}, "status", projected)
    end)
  end

  defp normalize_unit_enums(unit) do
    Enum.reduce(@unit_enum_vocabulary, unit, fn {field, vocabulary}, normalized ->
      raw = normalized[field]

      cond do
        is_binary(raw) and raw in vocabulary ->
          normalized

        is_binary(raw) ->
          confess_unknown_enum(normalized, field, bound_free_text(raw))

        is_nil(raw) ->
          normalized

        # A non-string value (number, list, map) is outside the vocabulary by
        # construction; it is confessed with a fixed token, never inspected.
        true ->
          confess_unknown_enum(normalized, field, "non_string_value")
      end
    end)
  end

  defp confess_unknown_enum(unit, field, confessed) do
    limitation = "unknown_enum:#{field}:#{confessed}"

    unit
    |> Map.put(field, "unknown")
    |> Map.update("limitations", [limitation], &(&1 ++ [limitation]))
  end

  defp normalize_attempt_timestamps(attempt) do
    Enum.reduce(~w(started_at ended_at), attempt, fn field, normalized ->
      raw = normalized[field]

      if is_binary(raw) and not valid_iso8601_datetime?(raw) do
        limitation = "malformed_timestamp:#{field}:#{bound_free_text(raw)}"

        normalized
        |> Map.put(field, nil)
        |> Map.update("limitations", [limitation], &(&1 ++ [limitation]))
      else
        normalized
      end
    end)
  end

  # Parseability alone is not enough: DateTime.from_iso8601 accepts the
  # space-separated form, but the schema's date-time format is RFC3339 with a
  # "T" separator, so a space-form value would pass here and then fail the
  # served validation. Require both.
  defp valid_iso8601_datetime?(value) do
    match?({:ok, _datetime, _utc_offset}, DateTime.from_iso8601(value)) and
      String.contains?(value, "T")
  end

  # Sanitize ALWAYS, then bound: a short raw value can still carry invalid
  # UTF-8, and projected strings must be text only.
  defp bound_free_text(value) when byte_size(value) <= 256, do: trim_invalid_utf8(value)

  defp bound_free_text(value) do
    value
    |> binary_part(0, 256)
    |> trim_invalid_utf8()
  end

  defp trim_invalid_utf8(value) do
    if String.valid?(value),
      do: value,
      else: value |> binary_part(0, byte_size(value) - 1) |> trim_invalid_utf8()
  end

  defp enrich_units(units, ctx, source, raw_limits) do
    case event_bindings(units, ctx) do
      {:ok, bindings} ->
        Enum.reduce_while(units, {:ok, []}, fn unit, {:ok, acc} ->
          events = Map.get(bindings, unit["logical_id"], [])

          case attempts(unit, events, ctx) do
            {:ok, attempts} -> {:cont, {:ok, [enrich_unit(unit, events, attempts, ctx, source, raw_limits) | acc]}}
            {:error, _} = err -> {:halt, err}
          end
        end)
        |> case do
          {:ok, rows} -> {:ok, Enum.reverse(rows)}
          err -> err
        end

      {:error, _} = error ->
        error
    end
  end

  defp event_bindings(units, ctx) do
    subevents = Enum.filter(ctx.parent, &recognized_subagent_lifecycle_event?/1)
    workflow? = Enum.any?(units, &(&1["unit_kind"] == "workflow_step"))

    if not workflow? do
      unbound_gate =
        Enum.find(ctx.parent, fn event ->
          data = event["data"] || %{}

          event["type"] == "workflow_event" and
            data["kind"] in ~w(checkpoint_decided step_held) and
            constraining_gate?(event)
        end)

      unbound_lifecycle =
        Enum.find(subevents, &(not is_binary(get_in(&1, ["data", "subagent_id"]))))

      cond do
        unbound_gate ->
          error(
            "run_gate_identity_unresolved",
            "Constraining gate evidence does not identify a planned logical unit",
            %{seq: unbound_gate["seq"]}
          )

        unbound_lifecycle ->
          error(
            "run_execution_identity_unresolved",
            "Lifecycle evidence does not identify a logical unit",
            %{seq: unbound_lifecycle["seq"]}
          )

        true ->
          {:ok,
           Map.new(units, fn unit ->
             id = unit["logical_id"] |> String.split(":") |> List.last()
             {unit["logical_id"], Enum.filter(subevents, &(get_in(&1, ["data", "subagent_id"]) == id))}
           end)}
      end
    else
      steps = Map.new(units, &{List.last(String.split(&1["logical_id"], ":")), &1["logical_id"]})

      {child_to_step, workflow_child_conflict?} =
        Enum.reduce(ctx.parent, {%{}, false}, fn event, {bindings, conflict?} ->
          d = event["data"] || %{}

          if event["type"] == "workflow_event" and is_binary(steps[d["step_id"]]) and
               is_binary(d["child_session_id"]) do
            {bindings, new_conflict?} =
              put_event_binding(bindings, d["child_session_id"], d["step_id"])

            {bindings, conflict? or new_conflict?}
          else
            {bindings, conflict?}
          end
        end)

      {sub_to_step, subagent_conflict?} =
        Enum.reduce(subevents, {%{}, false}, fn event, {bindings, conflict?} ->
          d = event["data"] || %{}
          step = get_in(d, ["delegation_context", "step_id"]) || child_to_step[d["child_session_id"]]

          if is_binary(steps[step]) and is_binary(d["subagent_id"]) do
            {bindings, new_conflict?} =
              put_event_binding(bindings, d["subagent_id"], step)

            {bindings, conflict? or new_conflict?}
          else
            {bindings, conflict?}
          end
        end)

      {child_to_step, lifecycle_child_conflict?} =
        Enum.reduce(subevents, {child_to_step, false}, fn event, {bindings, conflict?} ->
          d = event["data"] || %{}

          step =
            get_in(d, ["delegation_context", "step_id"]) ||
              sub_to_step[d["subagent_id"]] || bindings[d["child_session_id"]]

          if is_binary(steps[step]) and is_binary(d["child_session_id"]) do
            {bindings, new_conflict?} =
              put_event_binding(bindings, d["child_session_id"], step)

            {bindings, conflict? or new_conflict?}
          else
            {bindings, conflict?}
          end
        end)

      unbound_gate =
        Enum.find(ctx.parent, fn event ->
          data = event["data"] || %{}

          event["type"] == "workflow_event" and
            data["kind"] in ~w(checkpoint_decided step_held) and
            constraining_gate?(event) and not is_binary(steps[data["step_id"]])
        end)

      unbound_lifecycle =
        Enum.find(subevents, fn event ->
          data = event["data"] || %{}

          step =
            get_in(data, ["delegation_context", "step_id"]) ||
              sub_to_step[data["subagent_id"]] || child_to_step[data["child_session_id"]]

          not is_binary(steps[step])
        end)

      cond do
        workflow_child_conflict? or subagent_conflict? or lifecycle_child_conflict? ->
          error(
            "run_workflow_identity_conflict",
            "Workflow evidence binds one durable child or Subagent identity to multiple logical units",
            %{}
          )

        unbound_gate ->
          error(
            "run_gate_identity_unresolved",
            "Constraining gate evidence does not identify a planned logical unit",
            %{seq: unbound_gate["seq"]}
          )

        unbound_lifecycle ->
          error(
            "run_execution_identity_unresolved",
            "Lifecycle evidence does not identify a planned logical unit",
            %{seq: unbound_lifecycle["seq"]}
          )

        true ->
          {:ok,
           Enum.reduce(subevents, Map.new(units, &{&1["logical_id"], []}), fn event, acc ->
             d = event["data"] || %{}

             step =
               get_in(d, ["delegation_context", "step_id"]) ||
                 sub_to_step[d["subagent_id"]] || child_to_step[d["child_session_id"]]

             Map.update!(acc, steps[step], &(&1 ++ [event]))
           end)}
      end
    end
  end

  defp constraining_gate?(event) do
    {:ok, state} = Gate.state(event)
    state in ~w(partial failed held needs_orchestrator)
  end

  defp put_event_binding(bindings, key, value) do
    case bindings do
      %{^key => ^value} -> {bindings, false}
      %{^key => _other} -> {bindings, true}
      %{} -> {Map.put(bindings, key, value), false}
    end
  end

  defp attempts(%{"materialization" => "volatile_only"} = unit, _events, ctx) do
    id = List.last(String.split(unit["logical_id"], ":"))
    live = Enum.find(get_in(ctx.inputs, ["runtime_diagnostics", "subagents"]) || [], &(&1["id"] == id)) || %{}
    attempt = attempt_base("#{unit["logical_id"]}:attempt:provisional:current", nil, "volatile_only", "volatile_runtime", "unknown", nil, live["child_session_id"], "unknown", nil, nil, nil)

    {:ok,
     [
       Map.merge(attempt, %{
         "summary" => nil,
         "child_event_window" => window(live["child_session_id"], nil, nil, "unknown", compact([diagnostics_ref(ctx)])),
         "evidence_refs" => compact([diagnostics_ref(ctx)]),
         "limitations" => ["volatile_attempt_not_durable"]
       })
     ]}
  end

  defp attempts(unit, events, ctx) do
    result =
      Enum.reduce_while(events, {:ok, [], nil, nil}, fn event, {:ok, list, active, pending} ->
        d = event["data"] || %{}
        kind = d["event"]
        child = d["child_session_id"]

        cond do
          kind not in @lifecycle ->
            {:halt, error("subagent_event_kind_unrecognized", "Subagent lifecycle event kind is not recognized", %{seq: event["seq"], event: kind})}

          kind == "queued" ->
            {:cont, {:ok, list, active, pending}}

          kind == "retrying" ->
            target = d["failed_child_session_id"] || child

            if active && active["child_session_id"] == target && active["status"] not in @terminal do
              closed = active |> Map.put("status", "failed") |> Map.put("ended_at", event["ts"]) |> Map.put("error_kind", d["error_kind"] || active["error_kind"]) |> add_refs([parent_ref(event)])
              {:cont, {:ok, replace_last(list, closed), nil, "retry"}}
            else
              {:halt, error("attempt_retry_target_unresolved", "Retry evidence does not target the active attempt", %{seq: event["seq"]})}
            end

          kind in ~w(started input) ->
            case AttemptStatus.start_status(d) do
              {:error, _reason} ->
                {:halt,
                 error(
                   "attempt_start_status_invalid",
                   "Attempt start evidence must use a canonical open status",
                   %{seq: event["seq"]}
                 )}

              {:ok, status} ->
                # The validated status is the ONLY one that may enter the row:
                # attempt.status is repair-guaranteed, so raw is never
                # re-injected past AttemptStatus (a raw nil would otherwise
                # break the schema enum).
                open_attempt(unit, list, active, pending, kind, child, event, status)
            end

          true ->
            status = d["status"] || "unknown"

            if status in @terminal do
              close_attempt(list, active, child, event, d, status)
            else
              {:halt,
               error(
                 "attempt_terminal_status_invalid",
                 "Terminal lifecycle event has a nonterminal status",
                 %{seq: event["seq"], status: status}
               )}
            end
        end
      end)

    case result do
      {:ok, list, _active, _pending} -> {:ok, attach_attempt_evidence(list, ctx)}
      {:error, _} = err -> err
    end
  end

  defp close_attempt(list, active, child, event, data, status) do
    if active && active["child_session_id"] == child do
      summary = advisory_summary(data["summary"])

      closed =
        active
        |> Map.put("status", status)
        |> Map.put("ended_at", event["ts"])
        |> Map.put("error_kind", data["error_kind"] || active["error_kind"])
        |> Map.put("summary", summary)
        |> Map.put("_raw_summary", data["summary"])
        |> add_refs([parent_ref(event)])

      {:cont, {:ok, replace_last(list, closed), nil, nil}}
    else
      {:halt,
       error(
         "attempt_terminal_target_unresolved",
         "Terminal evidence does not target the active attempt",
         %{seq: event["seq"]}
       )}
    end
  end

  defp open_attempt(unit, list, active, pending, kind, child, event, status) do
    if active && active["status"] not in @terminal do
      {:halt,
       error(
         "attempt_unit_overlap",
         "A logical unit cannot have concurrent active attempts",
         %{seq: event["seq"]}
       )}
    else
      relation =
        cond do
          kind == "input" and Enum.any?(list, &(&1["child_session_id"] == child)) -> "resume"
          pending -> pending
          list == [] -> "fresh"
          true -> "unknown"
        end

      ordinal = length(list)
      id = "#{unit["logical_id"]}:attempt:#{ordinal}"
      pred = list |> List.last() |> then(&if(&1, do: &1["attempt_id"], else: nil))

      row =
        attempt_base(
          id,
          ordinal,
          "durable",
          "parent_log",
          relation,
          pred,
          child,
          status,
          event["ts"],
          nil,
          (event["data"] || %{})["error_kind"]
        )
        |> Map.merge(%{
          "summary" => nil,
          "evidence_refs" => [parent_ref(event)],
          "limitations" => []
        })

      {:cont, {:ok, list ++ [row], row, nil}}
    end
  end

  defp attempt_base(id, ordinal, materialization, basis, relation, pred, child, status, started, ended, error_kind) do
    %{
      "attempt_id" => id,
      "ordinal" => ordinal,
      "materialization" => materialization,
      "status_basis" => basis,
      "relation" => relation,
      "predecessor_attempt_id" => pred,
      "child_session_id" => child,
      "status" => status,
      "started_at" => started,
      "ended_at" => ended,
      "error_kind" => error_kind
    }
  end

  defp attach_attempt_evidence(attempts, ctx) do
    by_session = Enum.group_by(attempts, & &1["child_session_id"])

    Enum.map(attempts, fn attempt ->
      session = attempt["child_session_id"]
      siblings = by_session[session] || []
      child = child_events(ctx, session)
      anchors = child |> Enum.filter(&(&1["type"] == "user_message")) |> Enum.map(& &1["seq"]) |> Enum.sort()
      index = Enum.find_index(Enum.sort_by(siblings, & &1["ordinal"]), &(&1["attempt_id"] == attempt["attempt_id"])) || 0

      {from, to, basis} =
        cond do
          length(siblings) == 1 -> {nil, nil, "whole_child_log_single_attempt"}
          length(anchors) == length(siblings) -> {Enum.at(anchors, index), Enum.at(anchors, index + 1), "child_user_message_epoch"}
          true -> {nil, nil, "unknown"}
        end

      selected = Enum.filter(child, fn e -> (is_nil(from) or e["seq"] >= from) and (is_nil(to) or e["seq"] < to) end)

      window_refs =
        if basis == "child_user_message_epoch" do
          [from, to]
          |> compact()
          |> Enum.map(fn seq -> child_ref(session, Enum.find(child, &(&1["seq"] == seq))) end)
        else
          terminal_failures = Enum.filter(selected, &(&1["type"] == "turn_failed"))
          provider_usage = Enum.filter(selected, &(&1["type"] == "provider_usage"))
          decisive = if terminal_failures != [], do: terminal_failures, else: provider_usage
          Enum.map(decisive, &child_ref(session, &1))
        end

      usage_events = Enum.filter(selected, &(&1["type"] == "provider_usage"))
      usage_refs = Enum.map(usage_events, &child_ref(session, &1))
      usage = usage(usage_events, ctx, usage_refs, true)
      error_kind = attempt["error_kind"] || selected |> Enum.filter(&(&1["type"] == "turn_failed")) |> List.last() |> then(&if(&1, do: get_in(&1, ["data", "error_kind"]), else: nil))

      attempt_child_refs =
        if basis == "child_user_message_epoch" do
          order_child_refs(window_refs ++ usage_refs)
        else
          window_refs
        end

      attempt =
        attempt
        |> Map.put("error_kind", error_kind)
        |> Map.put("child_event_window", window(session, from, to, basis, window_refs))
        |> add_refs(attempt_child_refs)

      include_empty_usage? =
        explicitly_empty_child_log?(ctx, session) and
          ctx.completeness["child_logs"] in ~w(complete complete_through_observed_at)

      if usage["calls"] > 0 or include_empty_usage?,
        do: Map.put(attempt, "usage", usage),
        else: attempt
    end)
  end

  defp order_child_refs(refs) do
    refs
    |> uniq()
    |> Enum.with_index()
    |> Enum.sort_by(fn {ref, index} -> {evidence_ref_seq(ref), index} end)
    |> Enum.map(&elem(&1, 0))
  end

  defp evidence_ref_seq(ref) do
    case Regex.run(~r/-(\d+)$/, ref, capture: :all_but_first) do
      [seq] -> String.to_integer(seq)
      _ -> 9_223_372_036_854_775_807
    end
  end

  defp enrich_unit(unit, events, attempts, ctx, source, raw_limits) do
    gate = gate(unit, ctx)
    exec = unit_execution(unit, events, attempts, gate)
    advisory = advisory(attempts, ctx)
    artifacts = artifacts(unit, ctx)
    mutation = unit_mutation(unit, ctx, artifacts)
    usage = usage_for_attempts(attempts, ctx)
    unit_raw = unit_raw_limits(unit, ctx, raw_limits)

    limits =
      (unit["limitations"] || [])
      |> Kernel.++(unit_raw)
      |> maybe_add(mirror_conflict?(ctx), "canonical_source_conflict")
      |> maybe_add(unit["materialization"] == "volatile_only", "durable_log_unavailable")
      |> maybe_add(unit["materialization"] == "volatile_only", "volatile_attempt_not_durable")
      |> maybe_add(source["freshness"] == "stale", "source_stale")
      |> maybe_add(child_logs_missing_for?(ctx, attempts), "child_log_missing")
      |> maybe_add("advisory_gate_disagreement" in advisory_attention_reasons(advisory, gate), "advisory_gate_disagreement")
      |> maybe_add(advisory["parse_status"] == "invalid", "model_advisory_unparseable")
      |> maybe_add("usage_fixture_minimized" in usage["limitations"], "usage_fixture_minimized")
      |> maybe_add("usage_incomplete_missing_child_log" in usage["limitations"], "usage_incomplete_missing_child_log")
      |> maybe_add(mutation["status"] in ~w(unknown indeterminate), "mutation_evidence_incomplete")

    attempts =
      Enum.map(attempts, fn attempt ->
        attempt = normalize_attempt_timestamps(attempt)

        al =
          (attempt["limitations"] || [])
          |> maybe_add(unit["materialization"] == "volatile_only", "volatile_attempt_not_durable")
          |> maybe_add("child_log_missing" in limits and child_events(ctx, attempt["child_session_id"]) == [], "child_log_missing")
          |> Kernel.++(Enum.filter(unit_raw, &(&1 in ~w(partial_repo_mutation subagent_close_failed subagent_may_still_be_running))))
          |> uniq()

        attempt = attempt |> Map.delete("_raw_summary") |> Map.put("limitations", al)

        if advisory["parse_status"] == "invalid" and attempt["attempt_id"] == (List.last(attempts) || %{})["attempt_id"],
          do: add_refs(attempt, advisory["evidence_refs"]),
          else: attempt
      end)

    actions = safe_actions(unit, events, artifacts, ctx)
    unit_liveness = liveness(ctx, exec, unit_raw, true)

    attempts =
      if unit_liveness["state"] == "live" do
        Enum.map(attempts, &add_refs(&1, unit_liveness["evidence_refs"]))
      else
        attempts
      end

    refs = curated_unit_refs(unit, events, attempts, exec, gate, advisory, artifacts, mutation, unit_liveness, ctx)

    unit
    |> Map.merge(%{
      "execution" => exec,
      "liveness" => unit_liveness,
      "gate" => gate,
      "advisory" => advisory,
      "attempts" => attempts,
      "artifacts" => artifacts,
      "usage" => usage,
      "mutation" => mutation,
      "safe_actions" => actions,
      "evidence_refs" => refs,
      "limitations" => limits
    })
  end

  defp curated_unit_refs(unit, events, attempts, execution, gate, advisory, artifacts, mutation, liveness, ctx) do
    if mirror_conflict?(ctx) do
      compact([envelope_ref(ctx), workflow_ref(ctx)])
      |> Kernel.++(gate["evidence_refs"])
      |> Kernel.++(execution["evidence_refs"])
      |> uniq()
    else
      do_curated_unit_refs(unit, events, attempts, execution, gate, advisory, artifacts, mutation, liveness, ctx)
    end
  end

  defp do_curated_unit_refs(unit, events, attempts, execution, gate, advisory, artifacts, mutation, liveness, ctx) do
    event_refs = Enum.map(events, &parent_ref/1)
    workflow_refs = compact([workflow_ref(ctx)])
    repeated_child? = repeated_attempt_session?(attempts)
    terminal_failure? = execution["state"] in ~w(failed timed_out cancelled detached closed)
    mixed_live? = liveness["state"] == "live" and ctx.parent != []

    attempt_decision_refs =
      cond do
        repeated_child? -> Enum.flat_map(attempts, & &1["evidence_refs"]) |> order_parent_then_child_refs()
        terminal_failure? -> execution["evidence_refs"]
        true -> []
      end

    mutation_decisive? = mutation["status"] in ~w(partial indeterminate workspace_applied not_applied)
    mutation_refs = if mutation_decisive?, do: mutation["evidence_refs"], else: []

    identity_refs =
      cond do
        mixed_live? -> []
        unit["unit_kind"] == "subagent" -> compact([envelope_ref(ctx)])
        mutation["status"] == "read_only" and advisory["parse_status"] == "invalid" -> compact([envelope_ref(ctx)])
        true -> []
      end

    unapplied_artifact_refs =
      artifacts
      |> Enum.filter(&(&1["kind"] == "virtual_diff" and &1["application_state"] == "not_applied"))
      |> Enum.flat_map(& &1["evidence_refs"])

    advisory_terminal_refs =
      if advisory["parse_status"] == "invalid" do
        ctx.parent
        |> Enum.filter(&(&1["type"] == "workflow_event" and get_in(&1, ["data", "kind"]) == "workflow_finished"))
        |> List.last()
        |> parent_ref()
        |> then(&compact([&1]))
      else
        []
      end

    live_owner_refs = if(liveness["state"] == "live", do: compact([owner_ref(ctx)]), else: [])

    identity_refs
    |> Kernel.++(workflow_refs)
    |> Kernel.++(event_refs)
    |> Kernel.++(execution["evidence_refs"])
    |> Kernel.++(gate["evidence_refs"])
    |> Kernel.++(unapplied_artifact_refs)
    |> Kernel.++(mutation_refs)
    |> Kernel.++(liveness["evidence_refs"])
    |> Kernel.++(live_owner_refs)
    |> Kernel.++(attempt_decision_refs)
    |> Kernel.++(advisory_terminal_refs)
    |> Kernel.++(advisory["evidence_refs"])
    |> order_unit_decision_refs()
  end

  defp order_unit_decision_refs(refs) do
    refs = uniq(refs)
    {child_refs, other_refs} = Enum.split_with(refs, &String.starts_with?(&1, "e-child-"))
    other_refs ++ order_child_refs(child_refs)
  end

  defp order_parent_then_child_refs(refs) do
    {parent, other} = Enum.split_with(uniq(refs), &String.starts_with?(&1, "e-parent-"))
    parent ++ order_child_refs(other)
  end

  defp unit_execution(_unit, events, attempts, gate) do
    cond do
      events != [] and attempts != [] ->
        last = List.last(attempts)
        terminal_event = List.last(events)

        child_failure_refs =
          if last["status"] in ~w(failed timed_out cancelled detached closed) do
            get_in(last, ["child_event_window", "evidence_refs"]) || []
          else
            []
          end

        execution(last["status"], "subagent_event_fold", uniq(compact([parent_ref(terminal_event)]) ++ child_failure_refs))

      events != [] and attempts == [] ->
        last = List.last(events)
        execution(get_in(last, ["data", "status"]) || "unknown", "subagent_event_fold", compact([parent_ref(last)]))

      gate["state"] == "checkpoint_ready" ->
        execution("completed", "workflow_event_fold", gate["evidence_refs"])

      gate["state"] == "held" ->
        execution("held", "workflow_event_fold", gate["evidence_refs"])

      gate["state"] == "failed" ->
        execution("failed", "workflow_event_fold", gate["evidence_refs"])

      true ->
        execution("unknown", "unknown", [])
    end
  end

  defp gate(%{"unit_kind" => "subagent"}, _ctx), do: %{"state" => "not_applicable", "dependent_safe" => nil, "basis" => "not_applicable", "evidence_refs" => []}

  defp gate(unit, ctx) do
    step = List.last(String.split(unit["logical_id"], ":"))
    event = ctx.parent |> Enum.filter(&(&1["type"] == "workflow_event" and get_in(&1, ["data", "step_id"]) == step and get_in(&1, ["data", "kind"]) in ~w(checkpoint_decided step_held))) |> List.last()

    if event do
      %{
        "state" => normalized_gate_state(event),
        "dependent_safe" => normalized_dependent_safe(event),
        "basis" => "workflow_event",
        "evidence_refs" => [parent_ref(event)]
      }
    else
      %{"state" => "unknown", "dependent_safe" => nil, "basis" => "unknown", "evidence_refs" => []}
    end
  end

  defp normalized_gate_state(event) do
    {:ok, state} = Gate.state(event)
    state
  end

  defp normalized_dependent_safe(event) do
    {:ok, dependent_safe} = Gate.dependent_safe(event)
    dependent_safe
  end

  defp advisory(attempts, ctx) do
    source_attempt =
      attempts
      |> Enum.filter(fn attempt ->
        {:ok, advisory} = Advisory.classify(attempt["_raw_summary"])
        advisory["present"] == true
      end)
      |> List.last()

    raw = if source_attempt, do: source_attempt["_raw_summary"]
    {:ok, advisory} = Advisory.classify(raw)
    advisory = put_raw_verdict(advisory, raw)

    evidence_refs =
      case advisory["parse_status"] do
        "valid" -> compact(["e-advisory-#{attempt_label(source_attempt)}"])
        "invalid" -> [invalid_advisory_ref(source_attempt, ctx)]
        _ -> []
      end

    advisory
    |> Map.put("evidence_refs", evidence_refs)
    |> Map.put("_source_attempt_id", if(source_attempt, do: source_attempt["attempt_id"]))
    |> Map.put("_source_child_session_id", if(source_attempt, do: source_attempt["child_session_id"]))
  end

  # _raw_verdict stays for the end-of-build normalization (its only consumer,
  # which also deletes it); everything else transient drops here. The drop
  # list is defense in depth — the Validator's additionalProperties would
  # fail-close a leak.
  defp strip_advisory_source(unit) do
    Map.update!(unit, "advisory", &Map.drop(&1, ["_source_attempt_id", "_source_child_session_id"]))
  end

  # The raw child-declared verdict from the SAME attempt advisory/2 projects
  # from, kept under a transient key (consumed and deleted by the end-of-build
  # normalization) so the unknown_enum confession always cites the verdict of
  # the attempt that actually backs the projected field.
  defp put_raw_verdict(advisory, raw) when is_binary(raw) do
    with {:ok, payload} when is_map(payload) <- Jason.decode(raw),
         true <- Map.has_key?(payload, "verdict") do
      Map.put(advisory, "_raw_verdict", payload["verdict"])
    else
      _ -> advisory
    end
  end

  defp put_raw_verdict(advisory, _raw), do: advisory

  defp advisory_summary(raw) when is_binary(raw) do
    case Jason.decode(raw) do
      {:ok, %{"summary" => summary}} when is_binary(summary) -> summary
      {:ok, _payload} -> raw
      {:error, _reason} -> if(String.starts_with?(String.trim_leading(raw), "{"), do: nil, else: raw)
    end
  end

  defp advisory_summary(_), do: nil

  defp liveness(ctx, execution, limits, unit?) do
    owner = ctx.inputs["owner_state"] || %{}
    diagnostics = ctx.inputs["runtime_diagnostics"] || %{}

    state =
      cond do
        execution["terminal"] and "subagent_may_still_be_running" not in limits -> "not_applicable"
        execution["terminal"] -> if(owner["state"] == "owner_unavailable", do: "owner_unavailable", else: "stale_handle")
        owner["reachable"] == true -> "live"
        owner["state"] == "owner_unavailable" -> "owner_unavailable"
        execution["state"] in ~w(planned queued running) and owner["state"] in ~w(snapshot_only stale_handle) -> "stale_handle"
        true -> "unknown"
      end

    cond do
      state == "not_applicable" ->
        %{"state" => state, "reachable" => false, "basis" => "terminal_execution", "observed_at" => nil, "evidence_refs" => []}

      execution["terminal"] ->
        %{"state" => state, "reachable" => false, "basis" => "durable_snapshot", "observed_at" => nil, "evidence_refs" => compact([owner_ref(ctx)])}

      state == "live" and diagnostics["observed_at"] ->
        %{
          "state" => state,
          "reachable" => true,
          "basis" => if(unit?, do: "manager_diagnostics", else: "delegate_owner"),
          "observed_at" => diagnostics["observed_at"],
          "evidence_refs" =>
            if(unit?,
              do: compact([diagnostics_ref(ctx)]),
              else: compact([owner_ref(ctx), diagnostics_ref(ctx)])
            )
        }

      map_size(owner) > 0 ->
        %{"state" => state, "reachable" => owner["reachable"] == true, "basis" => "delegate_owner", "observed_at" => ctx.observed_at, "evidence_refs" => compact([owner_ref(ctx)])}

      true ->
        %{"state" => state, "reachable" => false, "basis" => "none", "observed_at" => nil, "evidence_refs" => []}
    end
  end

  defp usage_for_attempts(attempts, ctx) do
    events = attempts |> Enum.flat_map(fn a -> usage_events_from_usage(a, ctx) end) |> uniq_by(fn {s, e} -> {s, e["seq"]} end)
    refs = Enum.map(events, fn {s, e} -> child_ref(s, e) end)
    usage(Enum.map(events, &elem(&1, 1)), ctx, refs, attempts != [])
  end

  defp usage_events_from_usage(attempt, ctx) do
    w = attempt["child_event_window"] || %{}
    session = w["session_id"]

    child_events(ctx, session)
    |> Enum.filter(fn e -> e["type"] == "provider_usage" and (is_nil(w["from_seq"]) or e["seq"] >= w["from_seq"]) and (is_nil(w["to_seq_exclusive"]) or e["seq"] < w["to_seq_exclusive"]) end)
    |> Enum.map(&{session, &1})
  end

  defp usage_for_units(units) do
    groups = units |> Enum.flat_map(& &1["usage"]["groups"]) |> fold_groups()
    calls = Enum.sum(Enum.map(groups, & &1["calls"]))
    limits = units |> Enum.flat_map(& &1["usage"]["limitations"]) |> uniq()
    complete = Enum.all?(units, & &1["usage"]["complete"])

    %{
      "source" =>
        cond do
          not complete -> "incomplete"
          calls > 0 -> "provider_usage_fold"
          true -> "none"
        end,
      "complete" => complete,
      "calls" => calls,
      "groups" => groups,
      "evidence_refs" => units |> Enum.flat_map(& &1["usage"]["evidence_refs"]) |> uniq(),
      "limitations" => limits
    }
  end

  defp usage(events, ctx, refs, relevant?) do
    groups = events |> Enum.filter(&(&1["type"] == "provider_usage")) |> Enum.map(&usage_group/1) |> fold_groups()
    boundary = ctx.completeness["child_logs"]

    limitation =
      cond do
        relevant? and boundary in ~w(provider_usage_sampled not_retained minimized) -> "usage_fixture_minimized"
        relevant? and boundary in ~w(explicitly_missing unavailable) -> "usage_incomplete_missing_child_log"
        true -> nil
      end

    complete = is_nil(limitation)
    calls = Enum.sum(Enum.map(groups, & &1["calls"]))

    %{
      "source" =>
        cond do
          not complete -> "incomplete"
          calls > 0 -> "provider_usage_fold"
          true -> "none"
        end,
      "complete" => complete,
      "calls" => calls,
      "groups" => groups,
      "evidence_refs" => refs |> Enum.filter(&is_binary/1) |> uniq(),
      "limitations" => compact([limitation])
    }
  end

  defp usage_group(event) do
    d = event["data"] || %{}
    s = d["usage_summary"] || %{}
    cache = s["cache"] || %{}

    %{
      "provider" => d["provider"] || "unknown",
      "model" => d["model"],
      "calls" => 1,
      "input_tokens" => s["input_tokens"] || 0,
      "output_tokens" => s["output_tokens"] || 0,
      "reasoning_tokens" => s["reasoning_tokens"] || 0,
      "total_tokens" => s["total_tokens"] || 0,
      "cached_tokens" => s["cached_tokens"] || 0,
      "cache_creation_tokens" => cache["creation_tokens"] || 0,
      "cache_read_tokens" => cache["read_tokens"] || s["cached_tokens"] || 0
    }
  end

  defp fold_groups(groups) do
    groups
    |> Enum.group_by(&{&1["provider"], &1["model"]})
    |> Enum.map(fn {{p, m}, rows} ->
      %{
        "provider" => p,
        "model" => m,
        "calls" => sum(rows, "calls"),
        "input_tokens" => sum(rows, "input_tokens"),
        "output_tokens" => sum(rows, "output_tokens"),
        "reasoning_tokens" => sum(rows, "reasoning_tokens"),
        "total_tokens" => sum(rows, "total_tokens"),
        "cached_tokens" => sum(rows, "cached_tokens"),
        "cache_creation_tokens" => sum(rows, "cache_creation_tokens"),
        "cache_read_tokens" => sum(rows, "cache_read_tokens")
      }
    end)
    |> Enum.sort_by(&{&1["provider"], &1["model"]})
  end

  defp artifacts(unit, ctx) do
    step = List.last(String.split(unit["logical_id"], ":"))
    workflow_id = elem(ctx.workflow, 0)
    events = Enum.filter(ctx.parent, &(&1["type"] == "workflow_event" and get_in(&1, ["data", "step_id"]) == step))

    refs =
      for event <- events, artifact <- get_in(event, ["data", "checkpoint", "artifact_refs"]) || [] do
        base = %{
          "kind" => artifact["kind"],
          "version" => artifact["version"],
          "hash" => artifact["hash"],
          "status" => "produced",
          "workspace_strategy" => artifact["workspace_strategy"],
          "producer_unit_id" => unit["logical_id"],
          "source_artifact_hash" => artifact["hash"],
          "application_state" => "not_applicable",
          "applied_by_unit_id" => nil,
          "correlation" => "not_applicable",
          "evidence_refs" => [parent_ref(event)]
        }

        correlate_artifact(base, step, workflow_id, ctx)
      end

    artifacts =
      refs
      |> uniq_by(&{&1["kind"], &1["hash"]})

    unapplied_virtual_diff_count =
      Enum.count(artifacts, &(&1["kind"] == "virtual_diff" and &1["application_state"] == "not_applied"))

    Enum.map(artifacts, fn artifact ->
      cond do
        artifact["kind"] == "virtual_diff" and artifact["application_state"] == "not_applied" ->
          add_refs(artifact, [artifact_evidence_ref(unit, ctx, artifact, unapplied_virtual_diff_count)])

        envelope_corrobates_step?(step, ctx) ->
          add_refs(artifact, [envelope_ref(ctx)])

        true ->
          artifact
      end
    end)
  end

  defp envelope_corrobates_step?(step_id, ctx) do
    Enum.any?(ctx.envelope["steps"] || [], fn step ->
      step["step_id"] == step_id and is_map(step["checkpoint"])
    end)
  end

  defp correlate_artifact(%{"kind" => "virtual_diff"} = a, step, workflow_id, ctx) do
    consumers = Enum.filter(ctx.envelope["steps"] || [], &(&1["apply_from"] == step))

    case List.last(consumers) do
      nil ->
        Map.merge(a, %{"application_state" => "not_applied", "correlation" => "not_applicable"})

      consumer ->
        apply = get_in(consumer, ["checkpoint", "virtual_diff_apply"]) || %{}
        hash = get_in(apply, ["artifact", "sha256"])

        if hash == a["hash"] and is_binary(apply["status"]),
          do: Map.merge(a, %{"application_state" => apply["status"], "applied_by_unit_id" => "workflow:#{workflow_id}:step:#{consumer["step_id"]}", "correlation" => "matched"}),
          else: Map.merge(a, %{"application_state" => "unknown", "correlation" => "mismatch"})
    end
  end

  defp correlate_artifact(%{"kind" => "virtual_diff_apply"} = a, step, workflow_id, ctx) do
    envelope_step = Enum.find(ctx.envelope["steps"] || [], &(&1["step_id"] == step)) || %{}
    apply = get_in(envelope_step, ["checkpoint", "virtual_diff_apply"]) || %{}
    producer = envelope_step["apply_from"]
    source = get_in(apply, ["artifact", "sha256"])

    Map.merge(a, %{
      "status" => raw_or_projected(apply, "status", "unknown"),
      "producer_unit_id" => if(producer, do: "workflow:#{workflow_id}:step:#{producer}", else: nil),
      "source_artifact_hash" => source,
      "application_state" => raw_or_projected(apply, "status", "unknown"),
      "applied_by_unit_id" => unit_id(workflow_id, step),
      "correlation" => if(producer && source && apply["status"], do: "matched", else: "mismatch")
    })
  end

  defp correlate_artifact(a, _step, _workflow_id, _ctx), do: a

  defp unit_mutation(unit, ctx, artifacts) do
    mode = ctx.envelope["mode"]

    {status, semantics, paths} =
      cond do
        unit["materialization"] == "volatile_only" ->
          {"unknown", "unknown", []}

        unit["execution_kind"] == "virtual_overlay" ->
          {"isolated_only", "none", []}

        unit["execution_kind"] == "virtual_diff_apply" ->
          step = Enum.find(ctx.envelope["steps"] || [], &(&1["step_id"] == List.last(String.split(unit["logical_id"], ":")))) || %{}
          apply = get_in(step, ["checkpoint", "virtual_diff_apply"]) || %{}
          ps = for f <- apply["files"] || [], f["status"] == "applied", do: f["path"]

          cond do
            apply["status"] == "applied" -> {"workspace_applied", "exact", ps}
            apply["status"] in ~w(failed conflicted) -> {"partial", "at_least", ps}
            true -> {"indeterminate", "unknown", ps}
          end

        mode == "read_only" ->
          {"read_only", "none", []}

        true ->
          child = matching_envelope_child(unit, ctx)
          ps = child["observed_applied_writes"] || []

          cond do
            get_in(ctx.envelope, ["write_destination", "contract_status"]) == "partial_repo_mutation" or ps != [] -> {"partial", "at_least", ps}
            ctx.envelope["status"] in ~w(failed partial timed_out) -> {"indeterminate", "unknown", []}
            Enum.any?(artifacts, &(&1["application_state"] == "not_applied")) -> {"not_applied", "none", []}
            true -> {"none", "none", []}
          end
      end

    mutation_limitations =
      []
      |> maybe_add(status in ~w(unknown indeterminate), "mutation_evidence_incomplete")
      |> maybe_add(get_in(ctx.envelope, ["write_destination", "contract_status"]) == "partial_repo_mutation", "partial_repo_mutation")

    artifact_refs =
      artifacts
      |> Enum.filter(&(&1["kind"] == "virtual_diff" and &1["application_state"] == "not_applied"))
      |> Enum.flat_map(& &1["evidence_refs"])

    %{
      "status" => status,
      "observed_paths" => uniq(paths),
      "observed_semantics" => semantics,
      "evidence_refs" => uniq(mutation_refs(unit, ctx) ++ artifact_refs),
      "limitations" => mutation_limitations
    }
  end

  defp root_mutation(units) do
    ms = Enum.map(units, & &1["mutation"])
    statuses = Enum.map(ms, & &1["status"])

    {status, sem, paths} =
      cond do
        "workspace_applied" in statuses -> {"workspace_applied", "exact", paths_for(ms, "workspace_applied")}
        "partial" in statuses -> {"partial", "at_least", paths_for(ms, "partial")}
        "indeterminate" in statuses -> {"indeterminate", "unknown", []}
        Enum.any?(units, fn u -> Enum.any?(u["artifacts"], &(&1["application_state"] == "not_applied")) end) -> {"not_applied", "none", []}
        "unknown" in statuses -> {"unknown", "unknown", []}
        statuses != [] and Enum.all?(statuses, &(&1 == "read_only")) -> {"read_only", "none", []}
        true -> {"none", "none", []}
      end

    mutation_limitations =
      ms
      |> Enum.flat_map(& &1["limitations"])
      |> maybe_add(Enum.any?(units, fn unit -> Enum.any?(unit["artifacts"], &(&1["kind"] == "virtual_diff" and &1["application_state"] == "not_applied")) end), "virtual_diff_not_applied")
      |> uniq()

    decisive_refs =
      if status == "workspace_applied" do
        ms
        |> Enum.filter(&(&1["status"] == "workspace_applied"))
        |> Enum.flat_map(& &1["evidence_refs"])
        |> uniq()
      else
        ms |> Enum.flat_map(& &1["evidence_refs"]) |> uniq()
      end

    %{
      "status" => status,
      "observed_paths" => uniq(paths),
      "observed_semantics" => sem,
      "evidence_refs" => decisive_refs,
      "limitations" => mutation_limitations
    }
  end

  defp graph(ctx, units) do
    {workflow_id, steps} = ctx.workflow

    if workflow_id do
      ids = Map.new(steps, &{&1["id"], unit_id(workflow_id, &1["id"])})
      waves = topo_waves(steps, ids)
      gates = Map.new(units, &{&1["logical_id"], &1["gate"]["state"]})
      edges = for step <- steps, dep <- step["depends_on"] || [], do: %{"from" => ids[dep], "to" => ids[step["id"]], "state" => if(gates[ids[dep]] == "checkpoint_ready", do: "ready", else: "blocked")}
      %{"waves" => waves, "edges" => edges}
    else
      nil
    end
  end

  defp topo_waves(steps, ids), do: topo_waves(steps, ids, MapSet.new(), [])
  defp topo_waves([], _ids, _seen, acc), do: Enum.reverse(acc)

  defp topo_waves(remaining, ids, seen, acc) do
    ready = Enum.filter(remaining, &MapSet.subset?(MapSet.new(&1["depends_on"] || []), seen))
    if ready == [], do: Enum.reverse(acc), else: topo_waves(remaining -- ready, ids, Enum.reduce(ready, seen, &MapSet.put(&2, &1["id"])), [Enum.map(ready, &ids[&1["id"]]) | acc])
  end

  defp safe_actions(unit, events, artifacts, ctx) do
    held? =
      Enum.any?(ctx.parent, fn event ->
        event["type"] == "workflow_event" and
          get_in(event, ["data", "kind"]) == "step_held" and
          get_in(event, ["data", "step_id"]) == List.last(String.split(unit["logical_id"], ":"))
      end)

    base_values = events ++ [matching_envelope_child(unit, ctx)]
    base_candidates = Enum.flat_map(base_values, &collect_actions/1)
    base_ids = base_candidates |> Enum.map(&elem(&1, 1)) |> MapSet.new()

    workflow_guidance =
      ctx.parent
      |> Enum.filter(&(&1["type"] == "workflow_event" and get_in(&1, ["data", "kind"]) == "workflow_finished"))
      |> Enum.flat_map(&collect_actions/1)

    envelope_guidance = collect_actions(ctx.envelope)

    higher_precedence_candidates =
      (workflow_guidance ++ envelope_guidance)
      |> Enum.filter(fn {_source, id, _command, _ref} -> held? or MapSet.member?(base_ids, id) end)

    candidates = base_candidates ++ higher_precedence_candidates

    candidates =
      if Enum.any?(artifacts, &(&1["kind"] == "virtual_diff" and &1["application_state"] == "not_applied")),
        do: candidates ++ [{"virtual_diff_apply_hint", "apply_virtual_diff", nil, artifact_ref(artifacts)}],
        else: candidates

    candidates
    |> Enum.filter(fn {_source, id, _command, _ref} -> Map.has_key?(@action_registry, id) end)
    |> select_action_candidates()
    |> Enum.map(fn {source, id, command, ref} ->
      {kind, effect, presentation} = @action_registry[id]

      %{
        "id" => id,
        "scope" => unit["logical_id"],
        "kind" => kind,
        "effect" => effect,
        "presentation" => presentation,
        "command" => command,
        "source_field" => source,
        "evidence_refs" => compact([ref || envelope_ref(ctx)])
      }
    end)
  end

  defp collect_actions(value), do: collect_actions(value, nil)

  defp collect_actions(value, inherited_ref) when is_map(value) do
    ref = generic_ref(value) || inherited_ref

    next =
      for id <- value["next_actions"] || [], is_binary(id), do: {"next_actions", id, nil, ref}

    safe =
      for id <- value["safe_next_actions"] || [], is_binary(id), do: {"safe_next_actions", id, nil, ref}

    commands =
      []
      |> maybe_command("diagnose_command", "diagnose_session", value["diagnose_command"], ref)
      |> maybe_command("resume_command", "resume_session", value["resume_command"], ref)

    nested =
      value
      |> Enum.reject(fn {key, _child} -> key in ~w(next_actions safe_next_actions diagnose_command resume_command) end)
      |> Enum.sort_by(fn {key, _child} -> to_string(key) end)
      |> Enum.flat_map(fn {_key, child} -> collect_actions(child, ref) end)

    next ++ safe ++ commands ++ nested
  end

  defp collect_actions(value, inherited_ref) when is_list(value), do: Enum.flat_map(value, &collect_actions(&1, inherited_ref))
  defp collect_actions(_value, _inherited_ref), do: []

  defp maybe_command(candidates, _source, _id, command, _ref) when not is_binary(command), do: candidates
  defp maybe_command(candidates, source, id, command, ref), do: candidates ++ [{source, id, command, ref}]

  defp select_action_candidates(candidates) do
    candidates
    |> Enum.with_index()
    |> Enum.group_by(fn {{_source, id, command, _ref}, _index} -> {id, command} end)
    |> Enum.map(fn {_key, entries} ->
      first_index = entries |> Enum.map(&elem(&1, 1)) |> Enum.min()

      selected =
        entries
        |> Enum.map(&elem(&1, 0))
        |> Enum.min_by(fn {source, _id, _command, ref} -> {action_source_rank(source), if(ref, do: 0, else: 1)} end)

      {first_index, selected}
    end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(&elem(&1, 1))
  end

  defp action_source_rank("safe_next_actions"), do: 0
  defp action_source_rank("next_actions"), do: 1
  defp action_source_rank("virtual_diff_apply_hint"), do: 2
  defp action_source_rank("diagnose_command"), do: 3
  defp action_source_rank("resume_command"), do: 4

  defp put_attention(unit) do
    reasons =
      []
      |> attention_execution(unit)
      |> attention_gate(unit)
      |> attention_advisory(unit)
      |> attention_liveness(unit)
      |> attention_mutation(unit)
      |> attention_integrity(unit)
      |> uniq()

    refs =
      cond do
        reasons == [] ->
          []

        reasons == ["advisory_unparseable"] ->
          unit["advisory"]["evidence_refs"]

        "terminal_ambiguous_close" in reasons ->
          unit["evidence_refs"]

        "canonical_source_conflict" in reasons ->
          uniq(unit["gate"]["evidence_refs"] ++ unit["execution"]["evidence_refs"])

        "execution_held" in reasons or "gate_held" in reasons ->
          graph_refs = if(unit["unit_kind"] == "workflow_step", do: Enum.take(unit["evidence_refs"], 1), else: [])
          uniq(graph_refs ++ unit["gate"]["evidence_refs"])

        Enum.any?(reasons, &(&1 in ~w(execution_failed mutation_partial mutation_indeterminate mutation_unknown durable_log_unavailable child_log_missing attempt_index_conflict))) ->
          unit["evidence_refs"]

        true ->
          (unit["execution"]["evidence_refs"] ++
             unit["gate"]["evidence_refs"] ++
             unit["advisory"]["evidence_refs"] ++
             unit["liveness"]["evidence_refs"] ++
             Enum.flat_map(unit["artifacts"], & &1["evidence_refs"]))
          |> uniq()
      end

    Map.put(unit, "attention", %{"required" => reasons != [], "reasons" => reasons, "evidence_refs" => refs})
  end

  defp attention_execution(r, u),
    do:
      maybe_reason(
        r,
        %{
          "failed" => "execution_failed",
          "timed_out" => "execution_timed_out",
          "cancelled" => "execution_cancelled",
          "detached" => "execution_detached",
          "partial" => "execution_partial",
          "held" => "execution_held",
          "unknown" => "execution_unknown"
        }[u["execution"]["state"]]
      )

  defp attention_gate(r, u) do
    reason =
      %{"partial" => "gate_partial", "failed" => "gate_failed", "held" => "gate_held", "needs_orchestrator" => "gate_needs_orchestrator"}[u["gate"]["state"]] ||
        if(u["gate"]["state"] == "unknown" and u["execution"]["terminal"], do: "gate_unknown")

    maybe_reason(r, reason)
  end

  defp attention_advisory(r, u) do
    r ++ advisory_attention_reasons(u["advisory"], u["gate"])
  end

  defp advisory_attention_reasons(advisory, gate) do
    {:ok, reasons} = Advisory.attention_reasons(advisory, gate["state"])
    reasons
  end

  defp attention_liveness(r, u) do
    cond do
      u["execution"]["terminal"] and "subagent_may_still_be_running" in u["limitations"] -> r ++ ["terminal_ambiguous_close"]
      not u["execution"]["terminal"] and u["liveness"]["state"] == "stale_handle" -> r ++ ["nonterminal_stale_handle"]
      not u["execution"]["terminal"] and u["liveness"]["state"] == "owner_unavailable" -> r ++ ["nonterminal_owner_unavailable"]
      not u["execution"]["terminal"] and u["liveness"]["state"] == "unknown" -> r ++ ["nonterminal_liveness_unknown"]
      true -> r
    end
  end

  defp attention_mutation(r, u) do
    r = maybe_reason(r, %{"partial" => "mutation_partial", "indeterminate" => "mutation_indeterminate", "unknown" => "mutation_unknown"}[u["mutation"]["status"]])

    Enum.reduce(u["artifacts"], r, fn a, acc ->
      acc
      |> maybe_reason(if(a["kind"] == "virtual_diff" and a["application_state"] == "not_applied", do: "virtual_diff_unapplied"))
      |> maybe_reason(if(a["kind"] == "virtual_diff_apply" and a["application_state"] in ~w(failed conflicted), do: "virtual_diff_apply_failed"))
      |> maybe_reason(if(a["correlation"] in ~w(missing mismatch unknown), do: "virtual_diff_correlation_unknown"))
    end)
  end

  defp attention_integrity(r, u),
    do:
      Enum.reduce(
        [
          {"canonical_source_conflict", "canonical_source_conflict"},
          {"durable_log_unavailable", "durable_log_unavailable"},
          {"child_log_missing", "child_log_missing"},
          {"attempt_index_conflict", "attempt_index_conflict"}
        ],
        r,
        fn {l, reason}, acc -> maybe_reason(acc, if(l in u["limitations"], do: reason)) end
      )

  defp evidence(ctx, units, execution, source) do
    parent =
      Enum.map(ctx.parent, fn e ->
        %{
          "id" => parent_ref(e),
          "authority" => "canonical",
          "source_kind" => if(ctx.origin == "evidence_mirror", do: "evidence_mirror", else: "parent_log"),
          "session_id" => ctx.parent_id,
          "seq" => e["seq"],
          "description" => parent_event_description(e, ctx)
        }
      end)

    children =
      for {sid, events} <- ctx.inputs["child_logs"] || %{}, is_list(events), e <- events do
        %{
          "id" => child_ref(sid, e),
          "authority" => "canonical",
          "source_kind" => "child_log",
          "session_id" => sid,
          "seq" => e["seq"],
          "description" => child_event_description(e, events, sid, ctx)
        }
      end

    artifact_evidence =
      for unit <- units,
          artifact <- unit["artifacts"],
          artifact["kind"] == "virtual_diff",
          artifact["application_state"] == "not_applied" do
        artifact_id =
          artifact["evidence_refs"]
          |> Enum.find(&String.starts_with?(&1, "e-artifact-"))

        %{
          "id" => artifact_id,
          "authority" => "artifact",
          "source_kind" => "artifact",
          "session_id" => ctx.parent_id,
          "seq" => artifact_seq(unit, ctx),
          "description" => "Virtual diff requires a separate explicit apply decision."
        }
      end

    envelope_evidence =
      []
      |> maybe_evidence(
        envelope_ref(ctx),
        "derived",
        if(ctx.inputs["terminal_envelope"], do: "terminal_envelope", else: "delegate_snapshot"),
        ctx.parent_id,
        envelope_description(ctx, units)
      )

    owner_authority =
      if "subagent_may_still_be_running" in Enum.flat_map(units, & &1["limitations"]),
        do: "derived",
        else: "volatile"

    volatile_evidence =
      []
      |> maybe_evidence(diagnostics_ref(ctx), "volatile", "manager_diagnostics", ctx.parent_id, manager_description(ctx))
      |> maybe_evidence(owner_ref(ctx), owner_authority, "delegate_owner", ctx.parent_id, owner_description(ctx, owner_authority))

    advisories =
      for unit <- units, unit["advisory"]["present"], ref <- unit["advisory"]["evidence_refs"] do
        %{
          "id" => ref,
          "authority" => "model_declared",
          "source_kind" => "model_summary",
          "session_id" => advisory_session_id(unit, ctx),
          "seq" => advisory_seq(unit, ctx),
          "description" => advisory_description(unit),
          "_limitation_only" => unit["advisory"]["parse_status"] == "invalid"
        }
      end

    limitation_advisories = Enum.filter(advisories, & &1["_limitation_only"])
    ordered_advisories = Enum.reject(advisories, & &1["_limitation_only"])

    durable_evidence =
      (parent ++ artifact_evidence ++ ordered_advisories)
      |> Enum.with_index()
      |> Enum.sort_by(fn {item, index} ->
        authority_order = if item["authority"] == "canonical", do: 0, else: 1
        {item["seq"] || 9_223_372_036_854_775_807, authority_order, index}
      end)
      |> Enum.map(&elem(&1, 0))
      |> Kernel.++(limitation_advisories)
      |> Enum.map(&Map.delete(&1, "_limitation_only"))

    mirror_evidence = conflicting_mirror_evidence(ctx)

    used = projection_refs(%{"units" => units, "execution" => execution, "source" => source, "run" => run(ctx)}) |> MapSet.new()

    referenced_evidence =
      (envelope_evidence ++ durable_evidence ++ children ++ volatile_evidence)
      |> uniq_by(& &1["id"])
      |> Enum.filter(&MapSet.member?(used, &1["id"]))

    referenced_evidence ++ mirror_evidence
  end

  defp projection_refs(value) when is_map(value), do: Enum.flat_map(value, fn {k, v} -> if k == "evidence_refs" and is_list(v), do: v, else: projection_refs(v) end)
  defp projection_refs(value) when is_list(value), do: Enum.flat_map(value, &projection_refs/1)
  defp projection_refs(_), do: []

  defp workflow_definition(parent) do
    case workflow_start(parent) do
      nil -> {nil, []}
      event -> {get_in(event, ["data", "workflow_id"]), get_in(event, ["data", "graph", "steps"]) || []}
    end
  end

  defp workflow_start(parent), do: Enum.find(parent, &(&1["type"] == "workflow_event" and get_in(&1, ["data", "kind"]) == "workflow_started"))

  defp raw_limitations(ctx) do
    from_events =
      ctx.parent
      |> Enum.filter(&(&1["type"] == "workflow_event"))
      |> Enum.flat_map(&event_limitations(&1, ctx))

    extra = if get_in(ctx.envelope, ["write_destination", "contract_status"]) == "partial_repo_mutation", do: ["partial_repo_mutation"], else: []
    uniq(from_events ++ extra)
  end

  defp unit_raw_limits(unit, ctx, root) do
    step = if unit["unit_kind"] == "workflow_step", do: List.last(String.split(unit["logical_id"], ":"))

    local =
      ctx.parent
      |> Enum.filter(&(&1["type"] == "workflow_event" and get_in(&1, ["data", "step_id"]) == step))
      |> Enum.flat_map(&event_limitations(&1, ctx))

    uniq(local ++ Enum.filter(root, &(&1 == "partial_repo_mutation")))
  end

  defp event_limitations(event, ctx) do
    data = event["data"] || %{}
    checkpoint = data["checkpoint"] || %{}

    declared =
      (data["known_limitations"] || []) ++
        (checkpoint["known_limitations"] || []) ++
        if data["reason"] in @raw_limits, do: [data["reason"]], else: []

    produced_hashes =
      (checkpoint["artifact_refs"] || [])
      |> Enum.filter(&(&1["kind"] == "virtual_diff"))
      |> Enum.map(& &1["hash"])
      |> MapSet.new()

    applied_hashes = applied_virtual_hashes(ctx)

    declared
    |> Enum.filter(&(&1 in @raw_limits))
    |> Enum.reject(&(&1 == "virtual_diff_not_applied" and not MapSet.disjoint?(produced_hashes, applied_hashes)))
  end

  defp applied_virtual_hashes(ctx) do
    (ctx.envelope["steps"] || [])
    |> Enum.map(&get_in(&1, ["checkpoint", "virtual_diff_apply"]))
    |> Enum.filter(&(is_map(&1) and &1["status"] == "applied"))
    |> Enum.map(&get_in(&1, ["artifact", "sha256"]))
    |> Enum.reject(&is_nil/1)
    |> MapSet.new()
  end

  defp child_logs_missing?(ctx), do: ctx.completeness["child_logs"] in ~w(explicitly_missing unavailable) and Enum.any?(ctx.parent, &(&1["type"] == "subagent_event"))
  defp child_logs_missing_for?(ctx, attempts), do: child_logs_missing?(ctx) and attempts != [] and Enum.all?(attempts, &(child_events(ctx, &1["child_session_id"]) == []))

  defp mirror_conflict?(ctx) do
    mirror = ctx.inputs["evidence_mirror"]

    is_map(mirror) and
      (mirror["status"] == "source_diverged_mirror_retained" or
         Enum.any?(mirror["logs"] || [], &(&1["status"] == "source_diverged_mirror_retained" or &1["reported_source_sha256"] != &1["reported_mirror_sha256"])))
  end

  defp explicitly_empty_child_log?(ctx, session_id) do
    case get_in(ctx.inputs, ["child_logs", session_id]) do
      [] -> true
      _ -> false
    end
  end

  defp child_events(_ctx, nil), do: []

  defp child_events(ctx, sid) do
    case get_in(ctx.inputs, ["child_logs", sid]) do
      events when is_list(events) -> Enum.sort_by(events, & &1["seq"])
      _ -> mirror_child(ctx, sid)
    end
  end

  defp mirror_child(ctx, sid) do
    case Enum.find(get_in(ctx.inputs, ["evidence_mirror", "logs"]) || [], &(&1["role"] == "child" and &1["session_id"] == sid and verified_mirror?(&1))) do
      nil -> []
      item -> item["events"] || []
    end
  end

  defp parent_event_description(event, ctx) do
    if mirror_conflict?(ctx) and ctx.origin == "workspace_log" do
      case {event["type"], get_in(event, ["data", "kind"])} do
        {"workflow_event", "workflow_started"} -> "Primary workspace Log defines the workflow graph."
        {"workflow_event", "checkpoint_decided"} -> "Primary workspace Log records #{normalized_gate_state(event)}."
        {"workflow_event", "workflow_finished"} -> "Primary workspace Log records #{get_in(event, ["data", "status"]) || "unknown"}."
        _ -> "Primary workspace Log records canonical #{event["type"]} evidence."
      end
    else
      default_parent_event_description(event, ctx)
    end
  end

  defp default_parent_event_description(event, ctx) do
    data = event["data"] || %{}

    case {event["type"], data["kind"] || data["event"]} do
      {"workflow_event", "workflow_started"} -> workflow_graph_description(data)
      {"workflow_event", "checkpoint_decided"} -> checkpoint_description(data, ctx)
      {"workflow_event", "step_held"} -> held_description(data, ctx)
      {"workflow_event", "workflow_finished"} -> workflow_finished_description(data, ctx)
      {"subagent_event", lifecycle} when lifecycle in @lifecycle -> subagent_event_description(event, ctx)
      _ -> "Canonical #{event["type"]} event at parent sequence #{event["seq"]}."
    end
  end

  defp workflow_graph_description(data) do
    steps = get_in(data, ["graph", "steps"]) || []
    roots = Enum.filter(steps, &((&1["depends_on"] || []) == []))
    synthesis = Enum.find(steps, &(length(&1["depends_on"] || []) > 1))

    cond do
      Enum.map(steps, & &1["execution_kind"]) == ~w(virtual_overlay subagent virtual_diff_apply) ->
        "Workflow graph and unit order."

      length(steps) == 3 and length(roots) == 2 and not is_nil(synthesis) ->
        "Workflow graph defines two parallel inputs and one synthesis dependency."

      length(steps) == 1 and hd(steps)["id"] == "review" ->
        "Workflow graph defines the review step."

      length(steps) == 1 and hd(steps)["execution_kind"] == "virtual_overlay" ->
        "Workflow graph defines a virtual overlay proposal."

      true ->
        "Workflow graph."
    end
  end

  defp checkpoint_description(data, ctx) do
    step = capitalize(data["step_id"])
    checkpoint = data["checkpoint"] || %{}
    apply_step? = Enum.any?(elem(ctx.workflow, 1), &(&1["execution_kind"] == "virtual_diff_apply"))
    gate_state = normalized_gate_state(%{"data" => data})

    cond do
      data["checkpoint_status"] == "needs_orchestrator" and "subagent_may_still_be_running" in (checkpoint["known_limitations"] || []) ->
        "Checkpoint requires orchestrator and warns the child may still run."

      data["step_id"] == "review" and data["checkpoint_status"] == "checkpoint_ready" and invalid_review_advisory?(data, ctx) ->
        "Runtime checkpoint is ready."

      data["step_id"] == "review" and data["checkpoint_status"] == "checkpoint_ready" ->
        "Runtime checkpoint opened the review dependency gate."

      get_in(checkpoint, ["verification", "source"]) == "virtual_diff_apply_engine" ->
        "Apply engine checkpoint recorded exact workspace mutation."

      Enum.any?(checkpoint["artifact_refs"] || [], &(&1["kind"] == "virtual_diff")) and not apply_step? ->
        "Checkpoint is ready but artifact remains unapplied."

      Enum.any?(checkpoint["artifact_refs"] || [], &(&1["kind"] == "virtual_diff")) ->
        "#{step} checkpoint and virtual diff artifact."

      data["checkpoint_status"] == "failed" ->
        "#{step} checkpoint failed."

      gate_state == "unknown" ->
        "#{step} checkpoint status is unknown."

      true ->
        "#{step} checkpoint opened."
    end
  end

  defp invalid_review_advisory?(checkpoint_data, ctx) do
    child_session_id = checkpoint_data["child_session_id"]

    ctx.parent
    |> Enum.filter(fn event ->
      event["type"] == "subagent_event" and
        get_in(event, ["data", "child_session_id"]) == child_session_id and
        get_in(event, ["data", "event"]) in ~w(finished failed timed_out cancelled detached closed)
    end)
    |> List.last()
    |> then(fn
      nil -> false
      event -> invalid_advisory_summary?(get_in(event, ["data", "summary"]))
    end)
  end

  defp held_description(data, _ctx), do: "#{capitalize(data["step_id"])} held by dependency."

  defp workflow_finished_description(data, ctx) do
    virtual_only? =
      Enum.any?(elem(ctx.workflow, 1), &(&1["execution_kind"] == "virtual_overlay")) and
        not Enum.any?(elem(ctx.workflow, 1), &(&1["execution_kind"] == "virtual_diff_apply"))

    suffix =
      cond do
        "rerun_after_dependencies_checkpoint_ready" in (data["safe_next_actions"] || []) -> " with safe next action."
        virtual_only? and ctx.envelope["mode"] == "read_only" -> " without parent mutation."
        true -> "."
      end

    "Workflow finished #{data["status"] || "unknown"}#{suffix}"
  end

  defp subagent_event_description(event, ctx) do
    data = event["data"] || %{}
    label = subagent_role_label(event, ctx)
    ordinal = attempt_ordinal(event, ctx)
    repeated? = repeated_subagent?(data["subagent_id"], ctx)
    repeated_session? = repeated_child_session_for?(data["subagent_id"], ctx)
    resumed? = data["event"] == "input" or (ordinal > 0 and repeated_session?)

    cond do
      data["event"] == "started" and repeated_session? and ordinal == 0 ->
        "Initial child execution started."

      data["event"] == "started" and get_in(ctx.inputs, ["owner_state", "reachable"]) == true ->
        "Durable Subagent start event."

      data["event"] == "started" and ctx.envelope["status"] == "running" and get_in(ctx.inputs, ["owner_state", "reachable"]) == false ->
        "Durable child execution remains running."

      data["event"] == "retrying" ->
        "#{ordinal_word(max(ordinal - 1, 0))} #{String.downcase(label)} attempt failed and retry was queued."

      data["event"] == "input" ->
        "Input event opened a resumed attempt in the same child Session."

      data["event"] == "started" and repeated? ->
        "#{ordinal_word(ordinal)} #{String.downcase(label)} attempt started in #{data["child_session_id"]}."

      data["event"] == "started" and label == "Synthesis" ->
        "Synthesis attempt started after both checkpoints."

      data["event"] == "started" ->
        "#{label}#{if label in ~w(Producer Worker), do: "", else: " attempt"} started."

      data["event"] in ~w(finished closed) and invalid_advisory_summary?(data["summary"]) ->
        "#{label} attempt completed with a truncated model summary."

      data["event"] in ~w(finished closed) and resumed? ->
        "Resumed child execution completed."

      data["event"] in ~w(finished closed) and repeated_session? ->
        "Initial child execution completed."

      data["event"] in ~w(finished closed) and repeated? ->
        "#{ordinal_word(ordinal)} #{String.downcase(label)} attempt completed."

      data["event"] in ~w(finished closed) ->
        "#{label} attempt completed."

      data["event"] == "failed" and label == "Writer" and get_in(ctx.envelope, ["write_destination", "contract_status"]) == "partial_repo_mutation" ->
        "Writer attempt failed."

      data["event"] == "failed" ->
        "#{label}#{if label == "Subagent", do: " attempt", else: ""} failed."

      data["event"] == "timed_out" and data["reason"] == "close_failed_after_workflow_timeout" ->
        "#{label} timed out and close failed."

      true ->
        "#{label} execution recorded #{data["status"] || "unknown"}."
    end
  end

  defp invalid_advisory_summary?(summary) when is_binary(summary) do
    String.starts_with?(String.trim_leading(summary), "{") and match?({:error, _reason}, Jason.decode(summary))
  end

  defp invalid_advisory_summary?(_summary), do: false

  defp subagent_role_label(event, ctx) do
    data = event["data"] || %{}
    step = bound_step_id(data, ctx)

    cond do
      step -> capitalize(step)
      get_in(ctx.envelope, ["write_destination", "contract_status"]) == "partial_repo_mutation" -> "Writer"
      ctx.envelope["strategy"] == "subagents" and ctx.envelope["status"] == "failed" -> "Subagent"
      true -> capitalize(data["agent"] || "child")
    end
  end

  defp bound_step_id(data, ctx) do
    get_in(data, ["delegation_context", "step_id"]) ||
      Enum.find_value(ctx.parent, fn event ->
        event_data = event["data"] || %{}

        if event["type"] == "workflow_event" and event_data["child_session_id"] == data["child_session_id"],
          do: event_data["step_id"]
      end) ||
      Enum.find_value(ctx.parent, fn event ->
        event_data = event["data"] || %{}

        if event["type"] == "subagent_event" and event_data["subagent_id"] == data["subagent_id"] do
          child_step =
            Enum.find_value(ctx.parent, fn workflow_event ->
              workflow_data = workflow_event["data"] || %{}
              if workflow_event["type"] == "workflow_event" and workflow_data["child_session_id"] == event_data["child_session_id"], do: workflow_data["step_id"]
            end)

          get_in(event_data, ["delegation_context", "step_id"]) || child_step
        end
      end)
  end

  defp attempt_ordinal(event, ctx) do
    data = event["data"] || %{}

    ctx.parent
    |> Enum.filter(fn candidate ->
      candidate["type"] == "subagent_event" and
        get_in(candidate, ["data", "subagent_id"]) == data["subagent_id"] and
        get_in(candidate, ["data", "event"]) in ~w(started input) and
        candidate["seq"] <= event["seq"]
    end)
    |> length()
    |> Kernel.-(1)
    |> max(0)
  end

  defp repeated_subagent?(subagent_id, ctx) do
    Enum.count(ctx.parent, &(&1["type"] == "subagent_event" and get_in(&1, ["data", "subagent_id"]) == subagent_id and get_in(&1, ["data", "event"]) in ~w(started input))) > 1
  end

  defp repeated_child_session_for?(nil, _ctx), do: false

  defp repeated_child_session_for?(subagent_id, ctx) do
    ids =
      ctx.parent
      |> Enum.filter(fn event ->
        event["type"] == "subagent_event" and
          get_in(event, ["data", "subagent_id"]) == subagent_id and
          get_in(event, ["data", "event"]) in ~w(started input)
      end)
      |> Enum.map(&get_in(&1, ["data", "child_session_id"]))
      |> Enum.reject(&is_nil/1)

    length(ids) != length(Enum.uniq(ids))
  end

  defp repeated_attempt_session?(attempts) do
    sessions = attempts |> Enum.map(& &1["child_session_id"]) |> Enum.reject(&is_nil/1)
    length(sessions) != length(Enum.uniq(sessions))
  end

  defp subagent_id_for_child(session_id, ctx) do
    Enum.find_value(ctx.parent, fn event ->
      if event["type"] == "subagent_event" and get_in(event, ["data", "child_session_id"]) == session_id,
        do: get_in(event, ["data", "subagent_id"])
    end)
  end

  defp capitalize(nil), do: "Unknown"
  defp capitalize(value), do: value |> to_string() |> String.replace("_", " ") |> String.capitalize()

  defp advisory_description(unit) do
    advisory = unit["advisory"]

    cond do
      advisory["parse_status"] == "invalid" ->
        "Model summary is truncated and cannot be parsed as advisory JSON."

      advisory["parse_status"] == "valid" and advisory["declared_gate"] == "partial" and advisory["mergeable"] == false ->
        "Parsed reviewer JSON declared partial and mergeable false."

      true ->
        "Model-authored terminal summary parsed as advisory data."
    end
  end

  defp advisory_session_id(unit, ctx) do
    if unit["advisory"]["parse_status"] == "valid" do
      ctx.parent_id
    else
      unit["advisory"]["_source_child_session_id"] || ctx.parent_id
    end
  end

  defp envelope_description(ctx, units) do
    steps = elem(ctx.workflow, 1)
    safe_actions? = collect_actions(ctx.envelope) != []
    virtual_overlay? = Enum.any?(steps, &(&1["execution_kind"] == "virtual_overlay"))
    apply_step? = Enum.any?(steps, &(&1["execution_kind"] == "virtual_diff_apply"))

    cond do
      get_in(ctx.envelope, ["write_destination", "contract_status"]) == "partial_repo_mutation" ->
        "Terminal envelope reports partial repo mutation and lower-bound observed writes."

      is_map(ctx.inputs["delegate_snapshot"]) and ctx.parent == [] ->
        "Live status snapshot supplies run identity but no durable facts."

      is_map(ctx.inputs["delegate_snapshot"]) and get_in(ctx.inputs, ["owner_state", "reachable"]) == true ->
        "Delegate status snapshot supplies identity and read-only mode."

      is_map(ctx.inputs["delegate_snapshot"]) ->
        "Snapshot supplies run identity and read-only mode."

      virtual_overlay? and apply_step? ->
        "Terminal Delegate envelope supplies delegate id and mode."

      is_map(ctx.envelope["workflow"]) and is_list(get_in(ctx.envelope, ["workflow", "waves"])) ->
        "Terminal envelope confirms read-only mode and final wave summary."

      Enum.any?(ctx.envelope["children"] || [], &(is_binary(&1["resume_command"]) or is_binary(&1["diagnose_command"]))) ->
        "Terminal envelope supplies recovery guidance and latest child projection."

      virtual_overlay? and ctx.envelope["mode"] == "read_only" ->
        "Terminal envelope confirms read-only run mode."

      "subagent_may_still_be_running" in Enum.flat_map(units, & &1["limitations"]) and safe_actions? ->
        "Terminal envelope confirms read-only mode and safe next action."

      ctx.envelope["status"] == "partial" and ctx.envelope["mode"] == "read_only" ->
        "Terminal envelope confirms read-only mode."

      Enum.any?(units, &(&1["advisory"]["parse_status"] == "invalid")) or repeated_child_session?(ctx) ->
        "Envelope supplies run identity and read-only mode."

      ctx.envelope["mode"] == "read_only" ->
        "Envelope supplies run identity and read-only mode."

      true ->
        "Delegate envelope supplies run identity and bounded derived fields."
    end
  end

  defp child_event_description(event, events, session_id, ctx) do
    same_type = Enum.filter(events, &(&1["type"] == event["type"]))
    ordinal = Enum.find_index(same_type, &(&1["seq"] == event["seq"])) || 0
    subagent_id = subagent_id_for_child(session_id, ctx)
    repeated_session? = repeated_child_session_for?(subagent_id, ctx)
    child_sessions = child_session_order(ctx)
    child_ordinal = Enum.find_index(child_sessions, &(&1 == session_id)) || 0
    sampled? = ctx.completeness["child_logs"] in ~w(provider_usage_sampled minimized not_retained)
    write_activity? = Enum.any?(events, &(&1["type"] in ~w(tool_call tool_result)))

    case event["type"] do
      "provider_usage" when repeated_session? ->
        "#{ordinal_word(ordinal)} epoch provider usage."

      "provider_usage" when length(child_sessions) > 1 ->
        "Durable provider usage from #{String.downcase(ordinal_word(child_ordinal))} attempt."

      "provider_usage" when sampled? ->
        "Sampled durable provider usage."

      "provider_usage" ->
        "#{ordinal_word(ordinal)} durable provider usage event."

      "tool_call" ->
        "Write tool call targeted the observed path."

      "tool_result" ->
        "Write tool result succeeded."

      "turn_failed" when write_activity? ->
        "Turn failed after the observed write."

      "turn_failed" ->
        "Durable turn failure identifies #{get_in(event, ["data", "error_kind"]) || "unknown"}."

      "user_message" ->
        "#{ordinal_word(ordinal)} user-message epoch starts."

      _ ->
        "Canonical #{event["type"]} event from the child Session."
    end
  end

  defp child_session_order(ctx) do
    ctx.parent
    |> Enum.filter(&(&1["type"] == "subagent_event"))
    |> Enum.map(&get_in(&1, ["data", "child_session_id"]))
    |> Enum.reject(&is_nil/1)
    |> uniq()
  end

  defp ordinal_word(0), do: "First"
  defp ordinal_word(1), do: "Second"
  defp ordinal_word(2), do: "Third"
  defp ordinal_word(index), do: "Event #{index + 1}"

  defp manager_description(ctx) do
    diagnostics = ctx.inputs["runtime_diagnostics"] || %{}

    cond do
      ctx.parent == [] and (ctx.inputs["owner_state"] || %{})["reachable"] == true ->
        "Manager reports a live indexed child."

      (ctx.inputs["owner_state"] || %{})["reachable"] == true and diagnostics["runtime_gaps"] == [] ->
        "Manager reports indexed live child PID and no runtime gaps."

      true ->
        "Manager diagnostics supply volatile liveness only."
    end
  end

  defp owner_description(_ctx, "derived"), do: "No reachable owner handle can resolve ambiguous liveness."

  defp owner_description(ctx, _authority) do
    cond do
      (ctx.inputs["owner_state"] || %{})["reachable"] == true and ctx.parent == [] ->
        "Delegate owner is reachable in the current runtime."

      (ctx.inputs["owner_state"] || %{})["reachable"] == true ->
        "Current runtime has a reachable Delegate owner."

      true ->
        "Only a snapshot remains; no live Owner is reachable."
    end
  end

  defp conflicting_mirror_evidence(ctx) do
    if mirror_conflict?(ctx) and ctx.parent != [] do
      primary_by_seq = Map.new(ctx.parent, &{&1["seq"], &1})

      (ctx.inputs["evidence_mirror"]["logs"] || [])
      |> Enum.filter(&(&1["role"] == "parent"))
      |> Enum.flat_map(&(&1["events"] || []))
      |> Enum.filter(fn event -> Map.get(primary_by_seq, event["seq"]) != event end)
      |> Enum.map(fn event ->
        %{
          "id" => "e-mirror-#{event["seq"]}",
          "authority" => "canonical",
          "source_kind" => "evidence_mirror",
          "session_id" => ctx.parent_id,
          "seq" => event["seq"],
          "description" => mirror_event_description(event)
        }
      end)
    else
      []
    end
  end

  defp mirror_event_description(%{"type" => "workflow_event", "data" => %{"kind" => "checkpoint_decided"}}),
    do: "Retained mirror copy conflicts with the primary checkpoint."

  defp mirror_event_description(%{"type" => "workflow_event", "data" => %{"kind" => "workflow_finished"}}),
    do: "Retained mirror copy conflicts with the primary terminal state."

  defp mirror_event_description(_event), do: "Retained mirror copy conflicts with the primary workspace Log."

  defp normalize_provenance(projection, ctx) do
    projection = add_mirror_decision_refs(projection, ctx)
    id_map = child_evidence_id_map(projection["evidence"], ctx)
    id_map = Map.merge(id_map, structural_role_id_map(projection, ctx))
    id_map = if mirror_conflict?(ctx) and ctx.parent != [], do: Map.merge(id_map, primary_evidence_id_map(ctx)), else: id_map
    rewrite_evidence_ids(projection, id_map)
  end

  defp structural_role_id_map(projection, ctx) do
    envelope_id = envelope_ref(ctx)

    envelope_label =
      cond do
        "model_advisory_unparseable" in projection["limitations"] -> "e-envelope-invalid"
        get_in(ctx.envelope, ["write_destination", "contract_status"]) == "partial_repo_mutation" -> "e-envelope-partial"
        repeated_child_session?(ctx) -> "e-envelope-resume"
        true -> envelope_id
      end

    owner = ctx.inputs["owner_state"] || %{}
    durable? = ctx.parent != []
    ambiguous_close? = "subagent_may_still_be_running" in projection["limitations"]

    %{}
    |> maybe_map_id(envelope_id, envelope_label)
    |> maybe_map_id(diagnostics_ref(ctx), if(owner["reachable"] == true and durable?, do: "e-manager-live", else: diagnostics_ref(ctx)))
    |> maybe_map_id(
      owner_ref(ctx),
      cond do
        owner["reachable"] == true and durable? -> "e-owner-live"
        owner["reachable"] == false and ambiguous_close? -> "e-owner-stale"
        true -> owner_ref(ctx)
      end
    )
  end

  defp repeated_child_session?(ctx) do
    ids =
      ctx.parent
      |> Enum.filter(&(&1["type"] == "subagent_event" and get_in(&1, ["data", "event"]) in ~w(started input)))
      |> Enum.map(&get_in(&1, ["data", "child_session_id"]))
      |> Enum.reject(&is_nil/1)

    length(ids) != length(Enum.uniq(ids))
  end

  defp maybe_map_id(map, nil, _replacement), do: map
  defp maybe_map_id(map, _id, nil), do: map
  defp maybe_map_id(map, id, replacement), do: Map.put(map, id, replacement)

  defp primary_evidence_id_map(ctx), do: Map.new(ctx.parent, fn event -> {parent_ref(event), "e-primary-#{event["seq"]}"} end)

  defp add_mirror_decision_refs(projection, ctx) do
    if mirror_conflict?(ctx) do
      mirror_seqs = conflicting_mirror_evidence(ctx) |> Enum.map(& &1["seq"]) |> MapSet.new()
      projection = update_in(projection, ["execution", "evidence_refs"], &expand_mirror_refs(&1, mirror_seqs))

      units =
        Enum.map(projection["units"], fn unit ->
          unit =
            unit
            |> put_in(["execution", "evidence_refs"], projection["execution"]["evidence_refs"])
            |> update_in(["gate", "evidence_refs"], &expand_mirror_refs(&1, mirror_seqs))

          if "canonical_source_conflict" in unit["limitations"] do
            gate_refs = unit["gate"]["evidence_refs"]
            execution_refs = unit["execution"]["evidence_refs"]
            primary_decision_refs = Enum.reject(gate_refs ++ execution_refs, &String.starts_with?(&1, "e-mirror-")) |> uniq()
            mirror_decision_refs = Enum.filter(gate_refs ++ execution_refs, &String.starts_with?(&1, "e-mirror-")) |> uniq()
            envelope_refs = Enum.filter(unit["evidence_refs"], &String.starts_with?(&1, "e-envelope-"))
            graph_refs = Enum.filter(unit["evidence_refs"], &(&1 == "e-parent-0" or &1 == "e-primary-0"))

            unit
            |> put_in(["attention", "evidence_refs"], primary_decision_refs ++ mirror_decision_refs)
            |> Map.put("evidence_refs", uniq(envelope_refs ++ graph_refs ++ primary_decision_refs ++ mirror_decision_refs))
          else
            unit
          end
        end)

      Map.put(projection, "units", units)
    else
      projection
    end
  end

  defp expand_mirror_refs(refs, mirror_seqs) do
    Enum.flat_map(refs, fn ref ->
      case ref do
        "e-parent-" <> seq_text ->
          case Integer.parse(seq_text) do
            {seq, ""} when is_integer(seq) -> if MapSet.member?(mirror_seqs, seq), do: [ref, "e-mirror-#{seq}"], else: [ref]
            _ -> [ref]
          end

        _ ->
          [ref]
      end
    end)
    |> uniq()
  end

  defp child_evidence_id_map(evidence, ctx) do
    child_sessions =
      ctx.parent
      |> Enum.filter(&(&1["type"] == "subagent_event"))
      |> Enum.map(&get_in(&1, ["data", "child_session_id"]))
      |> Enum.reject(&is_nil/1)
      |> uniq()
      |> Kernel.++(
        evidence
        |> Enum.filter(&(&1["source_kind"] == "child_log"))
        |> Enum.map(& &1["session_id"])
        |> Enum.reject(&is_nil/1)
        |> uniq()
      )
      |> uniq()

    labels =
      case child_sessions do
        [_single] -> Map.new(child_sessions, &{&1, nil})
        sessions -> sessions |> Enum.with_index() |> Map.new(fn {session_id, index} -> {session_id, ordinal_label(index)} end)
      end

    evidence
    |> Enum.filter(&(&1["source_kind"] == "child_log"))
    |> Map.new(fn item ->
      label = labels[item["session_id"]]
      normalized = if label, do: "e-child-#{label}-#{item["seq"]}", else: "e-child-#{item["seq"]}"
      {item["id"], normalized}
    end)
  end

  defp ordinal_label(index) when index >= 0 and index < 26, do: <<?a + index>>
  defp ordinal_label(index), do: Integer.to_string(index)

  defp rewrite_evidence_ids(value, id_map) when is_map(value) do
    Map.new(value, fn
      {"id", id} when is_binary(id) -> {"id", Map.get(id_map, id, id)}
      {"evidence_refs", refs} when is_list(refs) -> {"evidence_refs", Enum.map(refs, &Map.get(id_map, &1, &1))}
      {key, child} -> {key, rewrite_evidence_ids(child, id_map)}
    end)
  end

  defp rewrite_evidence_ids(value, id_map) when is_list(value), do: Enum.map(value, &rewrite_evidence_ids(&1, id_map))
  defp rewrite_evidence_ids(value, _id_map), do: value

  defp projection_id(ctx), do: "projection:" <> (ctx.raw["scenario"] || ctx.run_id)

  defp projected_at(ctx) do
    case Application.get_env(:pixir_monitor, :projection_projected_at) || ctx.raw["projected_at"] || ctx.observed_at do
      nil -> DateTime.utc_now() |> DateTime.to_iso8601()
      value -> value
    end
  end

  defp infer_parent(inputs, parent), do: get_in(inputs, ["runtime_diagnostics", "parent_session_id"]) || parent |> List.first() |> then(&if(&1, do: &1["session_id"], else: nil))

  defp matching_envelope_child(unit, ctx) do
    key = List.last(String.split(unit["logical_id"], ":"))
    Enum.find(ctx.envelope["children"] || [], fn c -> c[if(unit["unit_kind"] == "workflow_step", do: "step_id", else: "subagent_id")] == key end) || %{}
  end

  defp mutation_refs(unit, ctx) do
    step_id = List.last(String.split(unit["logical_id"], ":"))

    checkpoint_refs =
      ctx.parent
      |> Enum.filter(fn event ->
        event["type"] == "workflow_event" and
          get_in(event, ["data", "step_id"]) == step_id and
          get_in(event, ["data", "kind"]) == "checkpoint_decided"
      end)
      |> Enum.map(&parent_ref/1)
      |> Enum.take(-1)

    envelope_decisive? =
      ctx.parent != [] and
        unit["execution_kind"] not in ~w(virtual_overlay virtual_diff_apply) and
        (ctx.envelope["mode"] == "read_only" or ctx.envelope["status"] in ~w(failed partial timed_out))

    write_refs = observed_write_refs(unit, ctx)

    cond do
      unit["execution_kind"] in ~w(virtual_overlay virtual_diff_apply) -> checkpoint_refs
      envelope_decisive? -> uniq(compact([envelope_ref(ctx)]) ++ write_refs)
      write_refs != [] -> uniq(compact([envelope_ref(ctx)]) ++ write_refs)
      true -> []
    end
  end

  defp observed_write_refs(unit, ctx) do
    child_session_id = matching_envelope_child(unit, ctx)["child_session_id"]

    child_events(ctx, child_session_id)
    |> Enum.filter(fn event ->
      (event["type"] == "tool_call" and get_in(event, ["data", "name"]) == "write") or
        (event["type"] == "tool_result" and get_in(event, ["data", "ok"]) == true)
    end)
    |> Enum.map(&child_ref(child_session_id, &1))
  end

  defp paths_for(ms, status), do: ms |> Enum.filter(&(&1["status"] == status)) |> Enum.flat_map(& &1["observed_paths"])
  defp window(s, f, t, b, refs), do: %{"session_id" => s, "from_seq" => f, "to_seq_exclusive" => t, "basis" => b, "evidence_refs" => refs}
  defp unit_id(w, s), do: "workflow:#{w}:step:#{s}"
  defp workflow_ref(ctx), do: ctx.parent |> workflow_start() |> parent_ref()

  defp envelope_ref(ctx) do
    if map_size(ctx.envelope) > 0 do
      prefix = if is_map(ctx.inputs["terminal_envelope"]), do: "envelope", else: "snapshot"
      "e-#{prefix}-#{run_suffix(ctx.run_id)}"
    end
  end

  defp diagnostics_ref(ctx), do: if(is_map(ctx.inputs["runtime_diagnostics"]), do: "e-manager-#{run_suffix(ctx.run_id)}")
  defp owner_ref(ctx), do: if(is_map(ctx.inputs["owner_state"]), do: "e-owner-#{run_suffix(ctx.run_id)}")
  defp parent_ref(nil), do: nil
  defp parent_ref(e), do: "e-parent-#{e["seq"]}"
  defp child_ref(s, e), do: "e-child-#{safe_id(s)}-#{e["seq"]}"

  defp invalid_advisory_ref(attempt, ctx) do
    if invalid_advisory_unit_count(ctx) > 1,
      do: "e-model-invalid-#{attempt_label(attempt)}",
      else: "e-model-invalid"
  end

  defp invalid_advisory_unit_count(ctx) do
    ctx.parent
    |> Enum.filter(fn event ->
      event["type"] == "subagent_event" and
        get_in(event, ["data", "event"]) in ~w(finished failed timed_out cancelled detached closed) and
        invalid_advisory_summary?(get_in(event, ["data", "summary"]))
    end)
    |> Enum.map(fn event ->
      data = event["data"] || %{}
      bound_step_id(data, ctx) || data["subagent_id"]
    end)
    |> Enum.reject(&is_nil/1)
    |> uniq()
    |> length()
  end

  defp attempt_label(nil), do: "unknown"

  defp attempt_label(attempt) do
    attempt["attempt_id"]
    |> String.split(":attempt:")
    |> List.first()
    |> String.split(":")
    |> List.last()
    |> safe_id()
  end

  defp artifact_evidence_ref(unit, ctx, artifact, unapplied_count) do
    base = "e-artifact-#{run_suffix(ctx.run_id)}"

    base =
      if unapplied_virtual_diff_unit_count(ctx) > 1 do
        unit_suffix = unit["logical_id"] |> String.split(":") |> List.last() |> safe_id()
        "#{base}-#{unit_suffix}"
      else
        base
      end

    if unapplied_count > 1 do
      "#{base}-#{artifact_hash_suffix(artifact["hash"])}"
    else
      base
    end
  end

  defp artifact_hash_suffix(hash) do
    :sha256
    |> :crypto.hash(to_string(hash))
    |> Base.encode16(case: :lower)
  end

  defp unapplied_virtual_diff_unit_count(ctx) do
    applied = applied_virtual_hashes(ctx)

    ctx.parent
    |> Enum.filter(&(&1["type"] == "workflow_event"))
    |> Enum.filter(fn event ->
      artifacts = get_in(event, ["data", "checkpoint", "artifact_refs"]) || []

      Enum.any?(artifacts, fn artifact ->
        artifact["kind"] == "virtual_diff" and not MapSet.member?(applied, artifact["hash"])
      end)
    end)
    |> Enum.map(&get_in(&1, ["data", "step_id"]))
    |> Enum.reject(&is_nil/1)
    |> uniq()
    |> length()
  end

  defp artifact_seq(unit, _ctx) do
    unit["artifacts"]
    |> Enum.flat_map(& &1["evidence_refs"])
    |> Enum.find_value(fn
      "e-parent-" <> seq ->
        case Integer.parse(seq) do
          {value, ""} -> value
          _ -> nil
        end

      _ref ->
        nil
    end)
  end

  defp artifact_ref(artifacts), do: artifacts |> List.first() |> then(&if(&1, do: List.last(&1["evidence_refs"]), else: nil))
  defp generic_ref(v), do: if(is_integer(v["seq"]), do: "e-parent-#{v["seq"]}")

  defp advisory_seq(unit, ctx) do
    child_id = unit["advisory"]["_source_child_session_id"]

    ctx.parent
    |> Enum.filter(fn event ->
      event["type"] == "subagent_event" and
        get_in(event, ["data", "child_session_id"]) == child_id and
        is_binary(get_in(event, ["data", "summary"]))
    end)
    |> List.last()
    |> then(&if(&1, do: &1["seq"], else: nil))
  end

  defp safe_id(v), do: v |> to_string() |> String.replace(~r/[^A-Za-z0-9_-]/u, "-")
  defp run_suffix(run_id), do: run_id |> safe_id() |> String.replace_prefix("dlg-", "")
  defp add_refs(map, refs), do: Map.update(map, "evidence_refs", compact(refs), &uniq(&1 ++ compact(refs)))
  defp replace_last([], item), do: [item]
  defp replace_last(list, item), do: List.replace_at(list, -1, item)
  defp max_or_nil([]), do: nil
  defp max_or_nil(values), do: Enum.max(values)

  # Acceptance matches the schema's date-time format, not mere parseability
  # (DateTime.from_iso8601 tolerates the space form the schema rejects), and
  # the derived value is re-encoded canonically so it is schema-valid by
  # construction regardless of the winning input's spelling.
  defp derived_datetime_max(values) do
    values
    |> Enum.reduce({nil, 0}, fn value, {latest, malformed_count} ->
      cond do
        not is_binary(value) ->
          {latest, malformed_count}

        not valid_iso8601_datetime?(value) ->
          {latest, malformed_count + 1}

        true ->
          {:ok, datetime, _utc_offset} = DateTime.from_iso8601(value)

          latest =
            case latest do
              nil -> datetime
              current -> if DateTime.compare(datetime, current) == :gt, do: datetime, else: current
            end

          {latest, malformed_count}
      end
    end)
    |> then(fn {latest, malformed_count} ->
      {if(latest, do: DateTime.to_iso8601(latest)), malformed_count}
    end)
  end

  defp sum(rows, key), do: Enum.sum(Enum.map(rows, &(&1[key] || 0)))
  defp uniq(values), do: Enum.uniq(values)
  defp uniq_by(values, fun), do: Enum.uniq_by(values, fun)
  defp compact(values), do: Enum.reject(values, &is_nil/1)
  defp blank?(v), do: not is_binary(v) or v == ""
  defp maybe_add(list, true, value), do: if(value in list, do: list, else: list ++ [value])
  defp maybe_add(list, _false, _value), do: list
  defp maybe_reason(list, nil), do: list
  defp maybe_reason(list, reason), do: list ++ [reason]
  defp maybe_evidence(list, nil, _a, _s, _sid, _d), do: list
  defp maybe_evidence(list, id, authority, source, sid, desc), do: list ++ [%{"id" => id, "authority" => authority, "source_kind" => source, "session_id" => sid, "seq" => nil, "description" => desc}]
  defp error(kind, message, details), do: {:error, %{kind: kind, message: message, details: details}}
end
