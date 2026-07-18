defmodule PixirMonitor.Projection.Source do
  @moduledoc """
  Runtime `PixirMonitor.RunSource` backed by bounded, read-only projection inputs.

  List inventory folds parent Logs only. Each list row carries honest list-scope
  liveness — `"unobserved"` for nonterminal rows, `"not_applicable"` for terminal
  rows, never `"live"`, which requires detail-scope owner diagnostics — plus the
  frozen `"temporal"` schema from `PixirMonitor.Projection.Temporal` and
  parent-observed `"children"` so an exact child Session id resolves without
  scanning child Logs. Rows are pre-sorted by the pinned `recency_desc` total
  order.

  Detail fetch discovers child Session ids from canonical parent evidence and lazily
  folds only those Logs before invoking the same Presenter projector used by
  fixtures. Workspace paths are server configuration and are never accepted from
  browser ids.
  """

  @behaviour PixirMonitor.RunSource
  @session_id_max_bytes Pixir.SessionId.max_bytes()

  @impl true
  @spec list_runs() :: {:ok, map()} | {:error, map()}
  def list_runs, do: list_runs(options())

  @spec list_runs(keyword()) :: {:ok, map()} | {:error, map()}
  def list_runs(opts) when is_list(opts) do
    with {:ok, inventory} <- provider().list_runs(opts) do
      {rows, metadata} = normalize_inventory(inventory)

      {:ok,
       %{
         "schema" => "pixir.monitor.runs",
         "schema_version" => 1,
         "runs" => Enum.sort_by(rows, &sort_key/1),
         "inventory" => metadata
       }}
    end
  end

  def list_runs(_opts),
    do: {:error, %{kind: "invalid_projection_options", message: "Projection options must be a keyword list", details: %{}}}

  @impl true
  @spec fetch_run(String.t()) :: {:ok, map()} | {:error, map()}
  def fetch_run(id), do: fetch_run(id, options())

  @spec fetch_run(String.t(), keyword()) :: {:ok, map()} | {:error, map()}
  def fetch_run(id, opts)
      when is_binary(id) and byte_size(id) in 1..@session_id_max_bytes and is_list(opts) do
    with {:ok, input} <- provider().fetch_input(id, opts),
         {:ok, projection} <- PixirMonitor.Projection.project(input) do
      {:ok, projection}
    end
  end

  def fetch_run(_id, _opts),
    do: {:error, %{kind: "invalid_run_id", message: "Run id must be a bounded non-empty string", details: %{}}}

  defp provider, do: Application.get_env(:pixir_monitor, :projection_input_provider, PixirMonitor.Projection.Source.Filesystem)
  defp options, do: Application.get_env(:pixir_monitor, :projection_source, [])

  defp normalize_inventory(%{"rows" => rows, "metadata" => metadata}) when is_list(rows) and is_map(metadata),
    do: {rows, metadata}

  defp normalize_inventory(rows) when is_list(rows) do
    count = length(rows)
    {rows, %{"total" => count, "selected" => count, "truncated" => false, "limitations" => []}}
  end

  # Default inventory order is the pinned `recency_desc` total order: complete
  # `latest_at` newest-first, then unknown, then malformed, ties by ascending id.
  defp sort_key(row), do: PixirMonitor.Projection.Temporal.recency_desc_key(row)
end

defmodule PixirMonitor.Projection.Source.InputProvider do
  @moduledoc """
  Injection seam for producing bounded runtime projection inputs.

  Implementations provide parent-only list rows and full lazy detail inputs. They must
  not persist projections or accept browser-selected filesystem paths.
  """

  @callback list_runs(keyword()) :: {:ok, [map()] | map()} | {:error, map()}
  @callback fetch_input(String.t(), keyword()) :: {:ok, map()} | {:error, map()}
end

defmodule PixirMonitor.Projection.Source.Filesystem do
  @moduledoc """
  Bounded filesystem and Pixir-API input provider for the runtime Presenter source.

  It rejects symlinked/non-regular Logs, confines reads beneath the configured
  workspace, limits inventory size and bytes, and discovers detail children only from
  canonical parent `subagent_event` evidence. Inventory rows and lazy detail inputs
  pass through the same fail-closed parent-evidence validation.
  """

  alias PixirMonitor.Projection.{Advisory, AttemptStatus, Gate, Temporal, UnitIdentity, WorkflowGraph}

  require Logger

  @behaviour PixirMonitor.Projection.Source.InputProvider
  @default_max_logs 512
  @default_max_bytes 8 * 1_024 * 1_024
  @default_max_events 20_000
  @subagent_lifecycle_events ~w(queued started input retrying finished failed timed_out cancelled detached closed)
  @terminal_subagent_statuses ~w(completed failed timed_out cancelled detached closed)

  @impl true
  @spec list_runs(keyword()) :: {:ok, map()} | {:error, map()}
  def list_runs(opts) do
    with {:ok, workspace} <- workspace(opts),
         {:ok, ids, metadata} <- inventory(workspace, opts) do
      {rows, dropped, non_parent_logs} =
        ids
        |> Enum.reduce({[], [], 0}, fn id, {rows, dropped, non_parent_logs} ->
          case parent_history(id, workspace, opts) do
            {:ok, history} ->
              if run_parent?(history) do
                case list_row(id, history) do
                  {:ok, row} -> {[row | rows], dropped, non_parent_logs}
                  {:error, error} -> {rows, [error | dropped], non_parent_logs}
                end
              else
                {rows, dropped, non_parent_logs + 1}
              end

            {:error, error} ->
              {rows, [error | dropped], non_parent_logs}
          end
        end)

      rows = Enum.reverse(rows)
      metadata = inventory_projection_metadata(metadata, rows, dropped, non_parent_logs)

      {:ok, %{"rows" => rows, "metadata" => metadata}}
    end
  end

  defp inventory_projection_metadata(metadata, rows, dropped, non_parent_logs) do
    dropped_count = length(dropped)

    metadata =
      metadata
      |> Map.put("projected_runs", length(rows))
      |> Map.put("non_parent_logs", non_parent_logs)
      |> Map.put("dropped_logs", dropped_count)

    if dropped == [] do
      metadata
    else
      add_projection_limitation(metadata, rows, dropped)
    end
  end

  defp add_projection_limitation(metadata, rows, dropped) do
    dropped_count = length(dropped)

    limitation = %{
      "kind" => "run_projection_incomplete",
      "message" => "Selected Session Logs could not all be classified into authoritative run projections",
      "details" => %{
        "selected" => metadata["selected"],
        "projected_runs" => length(rows),
        "dropped_logs" => dropped_count,
        "error_kinds" => dropped |> Enum.map(&projection_error_kind/1) |> Enum.frequencies()
      }
    }

    Map.update(metadata, "limitations", [limitation], &(&1 ++ [limitation]))
  end

  defp projection_error_kind(%{kind: kind}) when is_binary(kind), do: kind
  defp projection_error_kind(_error), do: "run_projection_failed"

  @impl true
  @spec fetch_input(String.t(), keyword()) :: {:ok, map()} | {:error, map()}
  def fetch_input(id, opts) do
    with {:ok, workspace} <- workspace(opts),
         :ok <- safe_id(id),
         {:ok, parent} <- parent_history(id, workspace, opts),
         true <- run_parent?(parent) || {:error, not_found(id)},
         :ok <- validate_parent_projection(parent),
         {:ok, children, missing?} <- child_histories(parent, workspace, opts) do
      diagnostics = diagnostics(id, workspace)
      owner = owner_state(diagnostics)

      {:ok,
       %{
         "projected_at" => now(),
         "observed_at" => now(),
         "inputs" => %{
           "terminal_envelope" => nil,
           "delegate_snapshot" => nil,
           "parent_log" => Enum.map(parent, &portable_event/1),
           "parent_log_origin" => "workspace_log",
           "child_logs" => children,
           "runtime_diagnostics" => diagnostics,
           "owner_state" => owner,
           "evidence_mirror" => nil
         },
         "completeness" => %{
           "parent_log" => "complete_through_observed_at",
           "child_logs" => if(missing?, do: "explicitly_missing", else: "complete_through_observed_at"),
           "runtime_diagnostics" => if(diagnostics, do: "complete_snapshot", else: "unavailable")
         }
       }}
    else
      false -> {:error, not_found(id)}
      {:error, _} = error -> error
    end
  end

  defp workspace(opts) do
    configured = Keyword.get(opts, :workspace, File.cwd!())
    expanded = Path.expand(configured)

    case File.stat(expanded) do
      {:ok, %File.Stat{type: :directory}} ->
        {:ok, expanded}

      {:ok, _} ->
        workspace_unavailable(expanded, "Configured monitor workspace is not a directory")

      {:error, reason} ->
        workspace_unavailable(expanded, "Configured monitor workspace cannot be read", reason)
    end
  end

  defp workspace_unavailable(expanded, message, reason \\ nil) do
    Logger.warning("#{message}: workspace=#{expanded} reason=#{inspect(reason)}")

    details = %{workspace_basename: Path.basename(expanded)}
    details = if is_nil(reason), do: details, else: Map.put(details, :reason, safe_error_kind(reason))

    error("workspace_unavailable", message, details)
  end

  defp inventory(workspace, opts) do
    max = max(Keyword.get(opts, :max_logs, @default_max_logs), 0)

    case sessions_directory(workspace) do
      :absent ->
        empty_inventory()

      {:error, _} = error ->
        error

      {:ok, directory} ->
        inventory_directory(directory, max)
    end
  end

  defp inventory_directory(directory, max) do
    case File.ls(directory) do
      {:ok, names} ->
        logs =
          names
          |> Enum.filter(&String.ends_with?(&1, ".ndjson"))
          |> Enum.flat_map(fn name ->
            path = Path.join(directory, name)

            case File.lstat(path, time: :posix) do
              {:ok, %File.Stat{type: :regular, mtime: mtime}} when is_integer(mtime) ->
                [{String.trim_trailing(name, ".ndjson"), mtime}]

              _ ->
                []
            end
          end)
          |> Enum.sort_by(fn {id, mtime} -> {-mtime, id} end)

        total = length(logs)
        ids = logs |> Enum.take(max) |> Enum.map(&elem(&1, 0))
        selected = length(ids)
        truncated = total > selected

        limitations =
          if truncated do
            [
              %{
                "kind" => "run_inventory_truncated",
                "message" => "Only the newest bounded Session Logs were selected",
                "details" => %{"max_logs" => max, "total" => total, "selected" => selected}
              }
            ]
          else
            []
          end

        {:ok, ids,
         %{
           "total" => total,
           "selected" => selected,
           "truncated" => truncated,
           "limitations" => limitations
         }}

      {:error, :enoent} ->
        empty_inventory()

      {:error, reason} ->
        error_with_reason("run_inventory_failed", "Session Log inventory could not be read", %{}, reason)
    end
  end

  defp empty_inventory,
    do: {:ok, [], %{"total" => 0, "selected" => 0, "truncated" => false, "limitations" => []}}

  defp sessions_directory(workspace) do
    pixir = Path.join(workspace, ".pixir")

    case directory_component(pixir, ".pixir") do
      {:ok, _pixir} -> directory_component(Path.join(pixir, "sessions"), "sessions")
      :absent -> :absent
      {:error, _} = error -> error
    end
  end

  defp require_sessions_directory(workspace) do
    case sessions_directory(workspace) do
      {:ok, directory} -> {:ok, directory}
      :absent -> {:error, :enoent}
      {:error, _} = error -> error
    end
  end

  defp directory_component(path, component) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory}} ->
        {:ok, path}

      {:ok, %File.Stat{type: :symlink}} ->
        error("state_tree_symlink_rejected", "Pixir state directory components must not be symlinks", %{
          component: component
        })

      {:ok, _stat} ->
        error("state_tree_invalid", "Pixir state directory component is not a directory", %{
          component: component
        })

      {:error, :enoent} ->
        :absent

      {:error, reason} ->
        error_with_reason(
          "state_tree_unavailable",
          "Pixir state directory component could not be inspected",
          %{component: component},
          reason
        )
    end
  end

  defp parent_history(id, workspace, opts) do
    with :ok <- safe_id(id),
         {:ok, _directory} <- require_sessions_directory(workspace),
         {:ok, _path} <- safe_log(id, workspace, opts),
         {:ok, history} <- Pixir.Log.fold(id, workspace: workspace),
         :ok <- event_limit(history, opts) do
      {:ok, history}
    else
      {:error, :enoent} -> {:error, not_found(id)}
      {:error, %{kind: _, message: _}} = error -> error
      {:error, reason} -> error_with_reason("run_log_failed", "Session Log could not be folded", %{run_id: id}, reason)
    end
  end

  defp safe_log(id, workspace, opts) do
    path = Pixir.Log.path(id, workspace: workspace) |> Path.expand()
    root = Path.join([workspace, ".pixir", "sessions"]) |> Path.expand()

    if not String.starts_with?(path, root <> "/") do
      error("path_escape_rejected", "Session Log path escapes the configured workspace", %{run_id: id})
    else
      max_bytes = Keyword.get(opts, :max_log_bytes, @default_max_bytes)

      case File.lstat(path) do
        {:ok, %File.Stat{type: :regular, size: size}} ->
          if size <= max_bytes,
            do: {:ok, path},
            else: error("run_log_limit", "Session Log exceeds the configured byte bound", %{run_id: id, bytes: size})

        {:ok, %File.Stat{type: :symlink}} ->
          error("symlink_rejected", "Symlinked Session Logs are not readable by the monitor", %{run_id: id})

        {:ok, _} ->
          error("run_log_invalid", "Session Log is not a regular file", %{run_id: id})

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp child_histories(parent, workspace, opts) do
    ids = parent |> Enum.filter(&(&1.type == :subagent_event)) |> Enum.map(& &1.data["child_session_id"]) |> Enum.filter(&is_binary/1) |> Enum.uniq()

    Enum.reduce_while(ids, {:ok, %{}, false}, fn id, {:ok, acc, missing} ->
      case parent_history(id, workspace, opts) do
        {:ok, events} -> {:cont, {:ok, Map.put(acc, id, Enum.map(events, &portable_event/1)), missing}}
        {:error, _} -> {:cont, {:ok, Map.put(acc, id, nil), true}}
      end
    end)
  end

  defp diagnostics(id, workspace) do
    case Pixir.Subagents.diagnostics(id, workspace: workspace) do
      {:ok, value} when is_map(value) -> stringify(value)
      _ -> nil
    end
  rescue
    _ -> nil
  catch
    _, _ -> nil
  end

  defp owner_state(nil), do: nil

  defp owner_state(diagnostics) do
    reachable = (diagnostics["running_count"] || 0) > 0
    %{"state" => if(reachable, do: "live_delegate_owner", else: "snapshot_only"), "reachable" => reachable}
  end

  defp list_row(id, history) do
    events = Enum.map(history, &portable_event/1)
    workflow = Enum.find(events, &(&1["type"] == "workflow_event" and get_in(&1, ["data", "kind"]) == "workflow_started"))
    finish = events |> Enum.filter(&(&1["type"] == "workflow_event" and get_in(&1, ["data", "kind"]) == "workflow_finished")) |> List.last()
    subs = Enum.filter(events, &subagent_lifecycle_event?/1)
    subagent_folds = fold_subagent_events(subs)
    latest_subagents = Enum.map(subagent_folds, & &1.latest)
    planned_steps = get_in(workflow || %{}, ["data", "graph", "steps"])
    planned_step_ids = list_planned_step_ids(planned_steps)
    workflow_index = list_workflow_index(workflow, planned_step_ids, events)
    unit_folds = latest_folds_by_unit(subagent_folds, workflow_index)
    raw_advisories = Enum.map(subagent_folds, &list_advisory(&1, workflow_index))
    advisories = latest_advisories_by_unit(raw_advisories)

    attention_observations =
      list_attention_observations(unit_folds, advisories, workflow_index)

    # Fail-closed into the served execution vocabulary, matching the detail
    # Builder's normalization of the same raw workflow_finished status: list
    # and detail must never disagree on the state of the same run (the detail
    # projection carries the confession).
    # The aggregate branch is already vocabulary-closed by lifecycle
    # validation; wrapping it too makes the fail-close total even if that
    # validation ever weakens (defense in depth, Grok r2 on PR #407).
    state =
      if finish,
        do: list_execution_state(get_in(finish, ["data", "status"])),
        else: list_execution_state(aggregate_subagent_state(latest_subagents))

    terminal = state in ~w(completed partial failed timed_out cancelled detached closed held)

    planned =
      if is_list(planned_steps) do
        length(planned_step_ids)
      else
        subs
        |> Enum.map(fn event -> get_in(event, ["data", "subagent_id"]) end)
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()
        |> length()
      end

    completed = completed_units(unit_folds, workflow_index)

    attention =
      attention_observations
      |> Enum.map(& &1.unit_id)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> length()

    attention_reasons =
      attention_observations
      |> Enum.flat_map(& &1.reasons)
      |> Enum.uniq()
      |> Enum.sort()

    latest_at = history |> Enum.map(& &1.ts) |> Temporal.max_instant()

    all_terminal? =
      latest_subagents != [] and
        Enum.all?(latest_subagents, &(get_in(&1, ["data", "status"]) in @terminal_subagent_statuses))

    row = %{
      "id" => id,
      "title" => get_in(workflow || %{}, ["data", "workflow_name"]),
      "strategy" => if(workflow, do: "workflow", else: "subagents"),
      "execution" => %{"state" => state, "terminal" => terminal},
      "liveness" => list_liveness(terminal),
      "source" => %{"mode" => "reconstructed", "freshness" => if(terminal, do: "terminal", else: "unknown")},
      "counts" => %{"planned_units" => planned, "completed_units" => completed, "attention_units" => attention},
      "attention" => %{
        "basis" => "parent_log_only",
        "reasons" => attention_reasons
      },
      "gate_counts" => gate_counts(workflow_index),
      "advisory_counts" => advisory_counts(advisories),
      "mutation" => %{"status" => "unknown", "observed_semantics" => "unknown"},
      "children" => list_children(subs, workflow_index),
      "latest_at" => latest_at,
      "temporal" => Temporal.row_temporal(workflow, finish, subs, latest_at, all_terminal?)
    }

    with :ok <- safe_id(id),
         :ok <- validate_parent_projection(history) do
      {:ok, row}
    end
  end

  # List scope rereads the parent Log only: it never consults owner diagnostics,
  # clocks, SSE state, timestamps, or prose, so it can never claim "live". A
  # nonterminal row is honestly "unobserved" (activity evidence unavailable at
  # list scope); a terminal row needs no liveness. Detail scope may load more
  # evidence (owner diagnostics) and is the only place "live" can appear.
  defp list_liveness(true = _terminal),
    do: %{"state" => "not_applicable", "reachable" => false, "basis" => "parent_log_only"}

  defp list_liveness(false = _terminal),
    do: %{"state" => "unobserved", "reachable" => false, "basis" => "parent_log_only"}

  defp validate_parent_projection(history) do
    events = Enum.map(history, &portable_event/1)
    workflow = Enum.find(events, &(&1["type"] == "workflow_event" and get_in(&1, ["data", "kind"]) == "workflow_started"))
    subs = Enum.filter(events, &subagent_lifecycle_event?/1)
    subagent_folds = fold_subagent_events(subs)
    planned_steps = get_in(workflow || %{}, ["data", "graph", "steps"])
    planned_step_ids = list_planned_step_ids(planned_steps)
    workflow_index = list_workflow_index(workflow, planned_step_ids, events)
    raw_advisories = Enum.map(subagent_folds, &list_advisory(&1, workflow_index))

    with :ok <- validate_parent_workflow_identity(workflow),
         :ok <- validate_parent_graph_steps(planned_steps),
         :ok <- validate_parent_subagent_components(subs),
         :ok <- validate_parent_lifecycles(subs),
         :ok <- validate_parent_constraints(events, raw_advisories, workflow_index),
         :ok <- validate_parent_unit_lifecycles(subs, workflow_index) do
      :ok
    end
  end

  defp list_advisory(fold, workflow_index) do
    advisory_event = fold.advisory_event || fold.latest
    {:ok, advisory} = Advisory.classify(get_in(advisory_event, ["data", "summary"]))
    gate_state = list_gate_state(fold.latest, workflow_index)
    {:ok, reasons} = Advisory.attention_reasons(advisory, gate_state)

    %{
      advisory: advisory,
      reasons: reasons,
      unit_id: list_unit_id(fold.latest, workflow_index),
      source_seq: advisory_event["seq"] || -1
    }
  end

  defp latest_advisories_by_unit(advisories) do
    advisories
    |> Enum.filter(&(is_binary(&1.unit_id) and &1.advisory["present"] == true))
    |> Enum.group_by(& &1.unit_id)
    |> Map.values()
    |> Enum.map(&Enum.max_by(&1, fn advisory -> advisory.source_seq end))
  end

  defp latest_folds_by_unit(folds, workflow_index) do
    folds
    |> Enum.map(&{list_unit_id(&1.latest, workflow_index), &1})
    |> Enum.reject(&is_nil(elem(&1, 0)))
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Map.values()
    |> Enum.map(&Enum.max_by(&1, fn fold -> fold.latest["seq"] || -1 end))
  end

  defp list_attention_observations(folds, advisories, workflow_index) do
    bound_unit_ids =
      folds
      |> Enum.map(&list_unit_id(&1.latest, workflow_index))
      |> MapSet.new()

    unit_observations =
      Enum.map(folds, fn fold ->
        status = get_in(fold.latest, ["data", "status"])
        gate_state = list_gate_state(fold.latest, workflow_index)

        reasons =
          []
          |> maybe_list_reason(list_execution_attention_reason(status))
          |> maybe_list_reason(
            list_gate_attention_reason(
              gate_state,
              workflow_index.workflow_units? and list_execution_terminal?(status)
            )
          )

        %{unit_id: list_unit_id(fold.latest, workflow_index), reasons: reasons}
      end)

    advisory_observations =
      Enum.map(advisories, &%{unit_id: &1.unit_id, reasons: &1.reasons})

    gate_observations =
      workflow_index.gate_by_step
      |> Map.values()
      |> Enum.map(fn event ->
        gate_state = list_gate_status_from_event(event)
        unit_id = get_in(event, ["data", "step_id"])

        execution_reason =
          if MapSet.member?(bound_unit_ids, unit_id) do
            nil
          else
            gate_state
            |> list_gate_execution_state()
            |> list_execution_attention_reason()
          end

        %{
          unit_id: unit_id,
          reasons:
            []
            |> maybe_list_reason(execution_reason)
            |> maybe_list_reason(list_gate_attention_reason(gate_state, false))
        }
      end)

    (unit_observations ++ advisory_observations ++ gate_observations)
    |> Enum.filter(&(&1.unit_id && &1.reasons != []))
  end

  defp list_execution_attention_reason(status) do
    %{
      "failed" => "execution_failed",
      "timed_out" => "execution_timed_out",
      "cancelled" => "execution_cancelled",
      "detached" => "execution_detached",
      "partial" => "execution_partial",
      "held" => "execution_held",
      "unknown" => "execution_unknown"
    }[status]
  end

  defp list_gate_attention_reason(state, terminal?) do
    %{
      "partial" => "gate_partial",
      "failed" => "gate_failed",
      "held" => "gate_held",
      "needs_orchestrator" => "gate_needs_orchestrator"
    }[state] || if(state == "unknown" and terminal?, do: "gate_unknown")
  end

  defp list_execution_terminal?(status),
    do: status in ~w(completed partial failed timed_out cancelled detached closed held)

  defp list_gate_execution_state("checkpoint_ready"), do: "completed"
  defp list_gate_execution_state("held"), do: "held"
  defp list_gate_execution_state("failed"), do: "failed"
  defp list_gate_execution_state(_state), do: "unknown"

  defp maybe_list_reason(reasons, nil), do: reasons
  defp maybe_list_reason(reasons, reason), do: reasons ++ [reason]

  defp advisory_counts(advisories) do
    advisories
    |> Enum.filter(&is_binary(&1.unit_id))
    |> Enum.map(& &1.advisory)
    |> Enum.filter(&(&1["present"] == true))
    |> Enum.group_by(fn advisory ->
      if advisory["parse_status"] == "invalid", do: "invalid", else: advisory["verdict"]
    end)
    |> Map.new(fn {verdict, values} -> {verdict, length(values)} end)
  end

  defp list_gate_state(_event, %{workflow_units?: false}), do: "not_applicable"

  defp list_gate_state(event, workflow_index) do
    with step_id when is_binary(step_id) <- list_unit_id(event, workflow_index),
         gate_event when is_map(gate_event) <- workflow_index.gate_by_step[step_id] do
      list_gate_status_from_event(gate_event)
    else
      _ -> "unknown"
    end
  end

  defp list_children(subs, workflow_index) do
    subs
    |> Enum.map(fn event ->
      %{
        "session_id" => get_in(event, ["data", "child_session_id"]),
        "unit_id" => list_unit_id(event, workflow_index)
      }
    end)
    |> Enum.filter(&is_binary(&1["session_id"]))
    |> Enum.uniq_by(& &1["session_id"])
  end

  defp list_unit_id(event, %{workflow_units?: false}), do: get_in(event, ["data", "subagent_id"])

  defp list_unit_id(event, workflow_index) do
    data = event["data"] || %{}

    step_id =
      get_in(data, ["delegation_context", "step_id"]) ||
        workflow_index.step_by_subagent[data["subagent_id"]] ||
        workflow_index.step_by_child[data["child_session_id"]]

    if MapSet.member?(workflow_index.planned_step_ids, step_id), do: step_id
  end

  defp list_planned_step_ids(steps) when is_list(steps) do
    steps
    |> Enum.map(&get_in(&1, ["id"]))
    |> Enum.filter(&is_binary/1)
  end

  defp list_planned_step_ids(_steps), do: []

  defp validate_parent_workflow_identity(nil), do: :ok

  defp validate_parent_workflow_identity(workflow) do
    case get_in(workflow, ["data", "workflow_id"]) do
      id ->
        case UnitIdentity.component(id) do
          {:ok, _workflow_id} ->
            :ok

          {:error, _reason} ->
            error(
              "run_graph_identity_invalid",
              "Workflow start evidence must identify a safe Workflow",
              %{}
            )
        end
    end
  end

  defp validate_parent_graph_steps(steps) do
    case WorkflowGraph.validate(steps) do
      {:ok, :valid} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp validate_parent_subagent_components(events) do
    Enum.reduce_while(events, :ok, fn event, :ok ->
      case get_in(event, ["data", "subagent_id"]) do
        nil ->
          {:cont, :ok}

        id ->
          case UnitIdentity.component(id) do
            {:ok, _safe_id} ->
              {:cont, :ok}

            {:error, _reason} ->
              {:halt,
               error(
                 "run_unit_identity_invalid",
                 "Subagent identity cannot be encoded as an unambiguous logical unit id",
                 %{seq: event["seq"]}
               )}
          end
      end
    end)
  end

  defp validate_parent_lifecycles(events) do
    events
    |> Enum.group_by(&get_in(&1, ["data", "subagent_id"]))
    |> Map.delete(nil)
    |> Map.values()
    |> Enum.reduce_while(:ok, fn rows, :ok ->
      case validate_parent_lifecycle(rows) do
        :ok -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp validate_parent_lifecycle(events) do
    Enum.reduce_while(events, {:ok, nil}, fn event, {:ok, active} ->
      data = event["data"] || %{}
      kind = data["event"]
      child = data["child_session_id"]
      status = data["status"] || "unknown"

      cond do
        kind == "queued" ->
          {:cont, {:ok, active}}

        kind == "retrying" ->
          target = data["failed_child_session_id"] || child

          if active && active.child_session_id == target && active.status not in @terminal_subagent_statuses do
            {:cont, {:ok, nil}}
          else
            {:halt, parent_evidence_error("parent_retry_target_unresolved", event)}
          end

        kind in ~w(started input) ->
          case AttemptStatus.start_status(data) do
            {:error, _reason} ->
              {:halt, parent_evidence_error("parent_start_status_invalid", event)}

            {:ok, start_status} ->
              if active && active.status not in @terminal_subagent_statuses do
                {:halt, parent_evidence_error("parent_unit_attempt_overlap", event)}
              else
                {:cont, {:ok, %{child_session_id: child, status: start_status}}}
              end
          end

        status not in @terminal_subagent_statuses ->
          {:halt, parent_evidence_error("parent_terminal_status_invalid", event)}

        active && active.child_session_id == child ->
          {:cont, {:ok, nil}}

        true ->
          {:halt, parent_evidence_error("parent_terminal_target_unresolved", event)}
      end
    end)
    |> case do
      {:ok, _active} -> :ok
      {:error, _} = error -> error
    end
  end

  defp validate_parent_unit_lifecycles(events, workflow_index) do
    events
    |> Enum.group_by(&list_unit_id(&1, workflow_index))
    |> Map.delete(nil)
    |> Map.values()
    |> Enum.reduce_while(:ok, fn rows, :ok ->
      case validate_parent_unit_lifecycle(rows) do
        :ok -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp validate_parent_unit_lifecycle(events) do
    events
    |> Enum.sort_by(&(&1["seq"] || -1))
    |> Enum.reduce_while({:ok, nil}, fn event, {:ok, active} ->
      data = event["data"] || %{}
      kind = data["event"]
      child = data["child_session_id"]
      status = data["status"] || "unknown"

      cond do
        kind == "queued" ->
          {:cont, {:ok, active}}

        kind == "retrying" ->
          target = data["failed_child_session_id"] || child

          if active && active.child_session_id == target &&
               active.status not in @terminal_subagent_statuses do
            {:cont, {:ok, nil}}
          else
            {:halt, parent_evidence_error("parent_retry_target_unresolved", event)}
          end

        kind in ~w(started input) ->
          case AttemptStatus.start_status(data) do
            {:error, _reason} ->
              {:halt, parent_evidence_error("parent_start_status_invalid", event)}

            {:ok, start_status} ->
              if is_nil(active) do
                {:cont, {:ok, %{child_session_id: child, status: start_status}}}
              else
                {:halt, parent_evidence_error("parent_unit_attempt_overlap", event)}
              end
          end

        status not in @terminal_subagent_statuses ->
          {:halt, parent_evidence_error("parent_terminal_status_invalid", event)}

        active && active.child_session_id == child ->
          {:cont, {:ok, nil}}

        true ->
          {:halt, parent_evidence_error("parent_terminal_target_unresolved", event)}
      end
    end)
    |> case do
      {:ok, _active} -> :ok
      {:error, _} = error -> error
    end
  end

  defp validate_parent_constraints(events, raw_advisories, workflow_index) do
    duplicate_steps? =
      length(workflow_index.planned_step_order) !=
        MapSet.size(workflow_index.planned_step_ids)

    unbound_gate? =
      Enum.any?(events, fn event ->
        event["type"] == "workflow_event" and
          get_in(event, ["data", "kind"]) in ~w(checkpoint_decided step_held) and
          list_gate_attention_reason(list_gate_status_from_event(event), false) != nil and
          not MapSet.member?(workflow_index.planned_step_ids, get_in(event, ["data", "step_id"]))
      end)

    unbound_lifecycle? =
      Enum.any?(events, fn event ->
        subagent_lifecycle_event?(event) and
          is_nil(list_unit_id(event, workflow_index))
      end)

    unbound_advisory? =
      Enum.any?(raw_advisories, fn advisory ->
        is_nil(advisory.unit_id) and advisory.reasons != []
      end)

    cond do
      duplicate_steps? -> error("run_graph_identity_invalid", "Workflow graph contains duplicate logical step ids", %{})
      workflow_index.identity_conflict? -> error("run_workflow_identity_conflict", "Workflow evidence binds one durable child or Subagent identity to multiple logical units", %{})
      unbound_gate? -> error("run_gate_identity_unresolved", "Constraining gate evidence does not identify a planned logical unit", %{})
      unbound_lifecycle? -> error("run_execution_identity_unresolved", "Lifecycle evidence does not identify a logical unit", %{})
      unbound_advisory? -> error("run_advisory_identity_unresolved", "Constraining advisory evidence does not identify a logical unit", %{})
      true -> :ok
    end
  end

  defp parent_evidence_error(kind, event) do
    error(kind, "Parent lifecycle evidence cannot be projected without inventing attempt state", %{
      seq: event["seq"]
    })
  end

  defp list_workflow_index(workflow, planned_step_ids, events) do
    workflow_units? =
      is_binary(get_in(workflow || %{}, ["data", "workflow_id"])) and planned_step_ids != []

    planned = MapSet.new(planned_step_ids)

    if workflow_units? do
      gate_by_step =
        events
        |> latest_workflow_gate_events()
        |> Enum.filter(&MapSet.member?(planned, get_in(&1, ["data", "step_id"])))
        |> Map.new(&{get_in(&1, ["data", "step_id"]), &1})

      {workflow_step_by_child, workflow_child_conflict?} =
        Enum.reduce(events, {%{}, false}, fn event, {bindings, conflict?} ->
          data = event["data"] || %{}

          if event["type"] == "workflow_event" and
               MapSet.member?(planned, data["step_id"]) and
               is_binary(data["child_session_id"]) do
            {bindings, new_conflict?} =
              put_identity_binding(bindings, data["child_session_id"], data["step_id"])

            {bindings, conflict? or new_conflict?}
          else
            {bindings, conflict?}
          end
        end)

      {step_by_subagent, subagent_conflict?} =
        Enum.reduce(events, {%{}, false}, fn event, {bindings, conflict?} ->
          data = event["data"] || %{}

          step_id =
            get_in(data, ["delegation_context", "step_id"]) ||
              workflow_step_by_child[data["child_session_id"]]

          if subagent_lifecycle_event?(event) and
               MapSet.member?(planned, step_id) and
               is_binary(data["subagent_id"]) do
            {bindings, new_conflict?} =
              put_identity_binding(bindings, data["subagent_id"], step_id)

            {bindings, conflict? or new_conflict?}
          else
            {bindings, conflict?}
          end
        end)

      {step_by_child, lifecycle_child_conflict?} =
        Enum.reduce(events, {workflow_step_by_child, false}, fn event, {bindings, conflict?} ->
          data = event["data"] || %{}

          step_id =
            get_in(data, ["delegation_context", "step_id"]) ||
              step_by_subagent[data["subagent_id"]] ||
              bindings[data["child_session_id"]]

          if subagent_lifecycle_event?(event) and
               MapSet.member?(planned, step_id) and
               is_binary(data["child_session_id"]) do
            {bindings, new_conflict?} =
              put_identity_binding(bindings, data["child_session_id"], step_id)

            {bindings, conflict? or new_conflict?}
          else
            {bindings, conflict?}
          end
        end)

      %{
        workflow_units?: true,
        planned_step_ids: planned,
        planned_step_order: planned_step_ids,
        gate_by_step: gate_by_step,
        step_by_subagent: step_by_subagent,
        step_by_child: step_by_child,
        identity_conflict?: workflow_child_conflict? or subagent_conflict? or lifecycle_child_conflict?
      }
    else
      %{
        workflow_units?: false,
        planned_step_ids: planned,
        planned_step_order: [],
        gate_by_step: %{},
        step_by_subagent: %{},
        step_by_child: %{},
        identity_conflict?: false
      }
    end
  end

  defp put_identity_binding(bindings, key, value) do
    case bindings do
      %{^key => ^value} -> {bindings, false}
      %{^key => _other} -> {bindings, true}
      %{} -> {Map.put(bindings, key, value), false}
    end
  end

  defp completed_units(folds, %{workflow_units?: false}) do
    Enum.count(folds, &(get_in(&1.latest, ["data", "status"]) == "completed"))
  end

  defp completed_units(folds, workflow_index) do
    latest_by_step =
      folds
      |> Enum.map(fn fold ->
        {list_unit_id(fold.latest, workflow_index), fold.latest}
      end)
      |> Enum.reject(&is_nil(elem(&1, 0)))
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
      |> Map.new(fn {step_id, step_events} ->
        {step_id, Enum.max_by(step_events, &(&1["seq"] || -1))}
      end)

    Enum.count(workflow_index.planned_step_order, fn step_id ->
      case latest_by_step[step_id] do
        event when is_map(event) ->
          get_in(event, ["data", "status"]) == "completed"

        nil ->
          case workflow_index.gate_by_step[step_id] do
            gate when is_map(gate) -> list_gate_status_from_event(gate) == "checkpoint_ready"
            nil -> false
          end
      end
    end)
  end

  defp latest_workflow_gate_events(events) do
    events
    |> Enum.filter(&(&1["type"] == "workflow_event" and get_in(&1, ["data", "kind"]) in ~w(checkpoint_decided step_held)))
    |> Enum.group_by(&get_in(&1, ["data", "step_id"]))
    |> Map.delete(nil)
    |> Map.values()
    |> Enum.map(&List.last/1)
  end

  defp list_gate_status_from_event(event) do
    {:ok, state} = Gate.state(event)
    state
  end

  defp gate_counts(%{workflow_units?: false}), do: %{}

  defp gate_counts(workflow_index) do
    workflow_index.planned_step_order
    |> Enum.map(fn step_id ->
      case workflow_index.gate_by_step[step_id] do
        event when is_map(event) -> list_gate_status_from_event(event)
        _ -> "unknown"
      end
    end)
    |> Enum.frequencies()
  end

  defp run_parent?(history) do
    Enum.any?(history, fn event ->
      event.type == :workflow_event or
        (event.type == :subagent_event and event.data["event"] in @subagent_lifecycle_events)
    end)
  end

  defp subagent_lifecycle_event?(event) do
    event["type"] == "subagent_event" and get_in(event, ["data", "event"]) in @subagent_lifecycle_events
  end

  defp fold_subagent_events(events) do
    events
    |> Enum.group_by(&get_in(&1, ["data", "subagent_id"]))
    |> Map.delete(nil)
    |> Map.values()
    |> Enum.map(fn subagent_events ->
      %{
        latest: List.last(subagent_events),
        advisory_event:
          subagent_events
          |> Enum.filter(&list_advisory_present?/1)
          |> List.last()
      }
    end)
  end

  defp list_advisory_present?(event) do
    {:ok, advisory} = Advisory.classify(get_in(event, ["data", "summary"]))
    advisory["present"] == true
  end

  # The list serves the same execution vocabulary the run.v1 schema pins for
  # detail (single source of truth: the Builder's normalization vocabulary);
  # anything the producer wrote outside it fail-closes to "unknown".
  @list_execution_vocabulary PixirMonitor.Projection.Builder.execution_state_vocabulary()

  defp list_execution_state(raw) when raw in @list_execution_vocabulary, do: raw
  defp list_execution_state(_raw), do: "unknown"

  defp aggregate_subagent_state([]), do: "unknown"

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
      Enum.all?(states, &(&1 == "completed")) -> "completed"
      true -> List.last(states) || "unknown"
    end
  end

  defp event_limit(events, opts),
    do: if(length(events) <= Keyword.get(opts, :max_events, @default_max_events), do: :ok, else: error("run_event_limit", "Session Log exceeds the configured event bound", %{events: length(events)}))

  defp safe_id(id) do
    case Pixir.SessionId.validate(id) do
      :ok -> :ok
      {:error, _reason} -> error("invalid_run_id", "Run id does not satisfy the canonical Pixir Session-id contract", %{})
    end
  end

  defp portable_event(event), do: %{"seq" => event.seq, "ts" => event.ts, "type" => Atom.to_string(event.type), "data" => stringify(event.data), "session_id" => event.session_id}
  defp stringify(map) when is_map(map), do: Map.new(map, fn {k, v} -> {to_string(k), stringify(v)} end)
  defp stringify(list) when is_list(list), do: Enum.map(list, &stringify/1)
  defp stringify(value), do: value
  defp not_found(id), do: %{kind: "run_not_found", message: "Run was not found", details: %{run_id: id}}
  defp now, do: DateTime.utc_now() |> DateTime.to_iso8601()

  defp error_with_reason(kind, message, details, reason) do
    Logger.warning("#{message}: #{inspect(reason)}")
    error(kind, message, Map.put(details, :reason, safe_error_kind(reason)))
  end

  defp safe_error_kind(%{error: error}), do: safe_error_kind(error)
  defp safe_error_kind(%{"error" => error}), do: safe_error_kind(error)
  defp safe_error_kind(%{kind: kind}), do: safe_error_kind(kind)
  defp safe_error_kind(%{"kind" => kind}), do: safe_error_kind(kind)
  defp safe_error_kind(kind) when is_atom(kind), do: safe_error_kind(Atom.to_string(kind))

  defp safe_error_kind(kind) when is_binary(kind) and byte_size(kind) <= 64 do
    if Regex.match?(~r/\A[a-z][a-z0-9_]*\z/, kind), do: kind, else: "unstructured_error"
  end

  defp safe_error_kind(_reason), do: "unstructured_error"
  defp error(kind, message, details), do: {:error, %{kind: kind, message: message, details: details}}
end
