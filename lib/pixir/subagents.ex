defmodule Pixir.Subagents do
  @moduledoc """
  Public facade for BEAM-native Subagent orchestration (ADR 0011).

  Subagents move through a small lifecycle state machine. The usual path is
  `queued -> running -> completed`, but failures, timeouts, cancellation, and
  detached restored children must remain explicit so parents and diagnostics can
  tell "finished cleanly" apart from "needs operator attention".

  A warm child keeps its copied replay Events as historical evidence. Its live
  authorization posture is the session-scoped posture written immediately after
  the most recent valid runtime lineage boundary; cold resume evaluates posture
  and mutation evidence only in that boundary's current segment. Logs without a
  valid boundary retain the legacy root/child/Fork fold rules.

  `max_depth` is an absolute delegation-depth cap from the root Session. A child
  spawned by the root runs at depth `1`; that child may only spawn another child
  when the configured cap is at least `2`.
  """

  alias Pixir.{Log, Permissions, SessionId, Tool}
  alias Pixir.Permissions.WritePolicy
  alias Pixir.Subagents.{Manager, WarmStart}

  @statuses ~w(queued running completed failed timed_out cancelled detached closed)
  @terminal_statuses ~w(completed failed cancelled timed_out closed detached)
  @potentially_integrable_statuses ~w(completed timed_out closed)

  @reverification_directive "Re-verify all integrated results from delegated children " <>
                              "before committing or declaring the work done. Run the " <>
                              "workspace's own verification, including typechecks, tests, " <>
                              "and any commands named in the work brief."

  @landing_manifest_child_cap 8
  @landing_manifest_path_cap 20
  @shared_workspace_file_tools ~w(write edit)

  @cancellation_steps [
    {:session_interrupt_evidence, "session_interrupt_evidence"},
    {:child_cancellation_event, "child_cancellation_event"}
  ]
  @cancellation_failed_steps Enum.map(@cancellation_steps, &elem(&1, 1))
  @cancellation_next_actions [
    "inspect_parent_session_log",
    "inspect_child_session_log",
    "rerun_subagent_if_still_needed"
  ]

  @allowed_transitions %{
    "queued" => ~w(running failed detached closed),
    "running" => ~w(completed failed timed_out cancelled detached),
    "completed" => ~w(running closed),
    "failed" => ~w(running closed),
    "timed_out" => ~w(running closed),
    "cancelled" => ~w(running closed),
    "detached" => [],
    "closed" => []
  }

  @doc "Application child spec."
  def child_spec(opts), do: Manager.child_spec(opts)

  @doc "Default runtime limits."
  def default_limits do
    config = Application.get_env(:pixir, :subagents, [])

    %{
      max_threads: Keyword.get(config, :max_threads, 6),
      max_depth: Keyword.get(config, :max_depth, 1),
      timeout_ms: Keyword.get(config, :timeout_ms, 120_000),
      retry_attempts: Keyword.get(config, :retry_attempts, 1),
      retry_jitter_ms: Keyword.get(config, :retry_jitter_ms, 250)
    }
  end

  @doc false
  def reverification_directive, do: @reverification_directive

  @doc false
  def landing_manifest_child_cap, do: @landing_manifest_child_cap

  @doc false
  def landing_manifest_path_cap, do: @landing_manifest_path_cap

  @doc false
  def landing_manifest(items, parent_workspace, opts \\ []) do
    items
    |> landing_manifest_projection(parent_workspace, opts)
    |> Map.fetch!("landing_manifest")
  end

  @doc false
  def landing_manifest_projection(items, parent_workspace, opts \\ [])

  def landing_manifest_projection(items, parent_workspace, opts)
      when is_list(items) and is_binary(parent_workspace) and is_list(opts) do
    parent_history = landing_parent_history(opts[:parent_session_id], parent_workspace)

    entries =
      items
      |> Enum.filter(&completed_item?/1)
      |> Enum.map(&landing_manifest_entry(&1, parent_workspace, parent_history))
      |> Enum.reject(&is_nil/1)

    shown = Enum.take(entries, @landing_manifest_child_cap)
    omitted = max(length(entries) - length(shown), 0)

    %{"landing_manifest" => shown}
    |> maybe_put_manifest_count("omitted_children", omitted)
  end

  def landing_manifest_projection(_items, _parent_workspace, _opts),
    do: %{"landing_manifest" => []}

  @doc false
  def append_landing_manifest(output, items, parent_workspace) when is_binary(output) do
    projection = landing_manifest_projection(items, parent_workspace)

    case projection["landing_manifest"] do
      [] ->
        output

      manifest ->
        output <>
          "\n\n" <>
          render_landing_manifest(manifest, Map.get(projection, "omitted_children", 0))
    end
  end

  @doc false
  def render_landing_manifest(manifest, omitted_children \\ 0)

  def render_landing_manifest(manifest, omitted_children)
      when is_list(manifest) and is_integer(omitted_children) and omitted_children >= 0 do
    shown = Enum.take(manifest, @landing_manifest_child_cap)
    overflow = max(length(manifest) - length(shown), 0)
    omitted = omitted_children + overflow
    total = length(shown) + omitted

    heading =
      if omitted > 0 do
        "Landing manifest (showing #{length(shown)} of #{total} completed children " <>
          "with integrable work; #{omitted} omitted by cap):"
      else
        "Landing manifest:"
      end

    heading <> "\n" <> Enum.map_join(shown, "\n", &render_landing_manifest_entry/1)
  end

  defp completed_item?(item) when is_map(item) do
    (item["status"] || item[:status] || item["subagent_status"] || item[:subagent_status]) ==
      "completed"
  end

  defp completed_item?(_item), do: false

  defp landing_manifest_entry(item, parent_workspace, parent_history) do
    workspace = item["workspace"] || item[:workspace]

    child_id =
      item["id"] || item[:id] || item["subagent_id"] || item[:subagent_id] ||
        item["step_id"] || item[:step_id]

    produced =
      []
      |> maybe_add_shared_workspace_files(item, workspace, parent_workspace)
      |> maybe_add_virtual_diff(item, workspace, parent_history)

    if produced == [] do
      nil
    else
      %{}
      |> maybe_put_manifest_field("child_id", child_id)
      |> maybe_put_manifest_field("workspace", workspace)
      |> Map.put("produced", produced)
    end
  end

  defp maybe_add_shared_workspace_files(produced, item, workspace, parent_workspace) do
    if (item["workspace_mode"] || item[:workspace_mode]) == "shared" and is_binary(workspace) do
      case shared_workspace_changed_paths(item, workspace) do
        [] ->
          produced

        paths ->
          all_path_entries =
            Enum.map(paths, &shared_workspace_path_entry(workspace, parent_workspace, &1))

          path_entries = Enum.take(all_path_entries, @landing_manifest_path_cap)
          omitted_paths = max(length(all_path_entries) - length(path_entries), 0)

          verifiable_paths =
            for %{"path" => path, "resolvable" => true} <- path_entries, do: path

          next_action =
            if verifiable_paths == [] do
              nil
            else
              %{
                "action" => "verify_and_commit",
                "paths" => verifiable_paths
              }
            end

          item =
            %{
              "kind" => "shared_workspace_files",
              "paths" => path_entries
            }
            |> maybe_put_manifest_count("omitted_paths", omitted_paths)
            |> maybe_put_manifest_field("next_action", next_action)

          produced ++ [item]
      end
    else
      produced
    end
  end

  defp shared_workspace_changed_paths(item, workspace) do
    child_session_id = item["child_session_id"] || item[:child_session_id]

    with true <- is_binary(child_session_id) and child_session_id != "",
         {:ok, history} <- Log.fold(child_session_id, workspace: workspace) do
      successful_results =
        history
        |> Enum.filter(&successful_tool_result?/1)
        |> Map.new(&{&1.data["call_id"], &1.data})

      history
      |> Enum.flat_map(&changed_paths_from_call(&1, successful_results))
      |> Enum.uniq()
    else
      _absent_or_unreadable_evidence -> []
    end
  end

  defp successful_tool_result?(%{type: :tool_result, data: data}) when is_map(data),
    do: data["ok"] == true and is_binary(data["call_id"])

  defp successful_tool_result?(_event), do: false

  defp changed_paths_from_call(%{type: :tool_call, data: data}, successful_results)
       when is_map(data) do
    case Map.get(successful_results, data["call_id"]) do
      %{} = result -> changed_paths_for_tool(data["name"], data["args"] || %{}, result)
      nil -> []
    end
  end

  defp changed_paths_from_call(_event, _successful_results), do: []

  defp changed_paths_for_tool(name, %{"path" => path}, _result)
       when name in @shared_workspace_file_tools and is_binary(path) and path != "",
       do: [path]

  defp changed_paths_for_tool(
         "apply_virtual_diff",
         %{"artifact" => %{"changes" => changes}, "dry_run" => false},
         %{"status" => "applied"}
       )
       when is_list(changes) do
    changes
    |> Enum.map(fn
      %{"path" => path} when is_binary(path) and path != "" -> path
      _change -> nil
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp changed_paths_for_tool(_name, _args, _result), do: []

  defp shared_workspace_path_entry(workspace, parent_workspace, path) do
    with {:ok, child_absolute_path} <- Pixir.Tools.Workspace.confine(workspace, path),
         relative_path <- Path.relative_to(child_absolute_path, Path.expand(workspace)),
         {:ok, parent_absolute_path} <-
           Pixir.Tools.Workspace.confine(parent_workspace, relative_path) do
      regular? = File.regular?(parent_absolute_path)

      %{
        "path" => relative_path,
        "resolvable" => true,
        "exists_in_parent" => regular?,
        "drift" => not regular?
      }
    else
      {:error, error} ->
        %{
          "path" => path,
          "resolvable" => false,
          "unresolvable" => manifest_error_kind(error)
        }
    end
  end

  defp manifest_error_kind(%{error: %{kind: kind}}), do: to_string(kind)
  defp manifest_error_kind(_error), do: "confinement_failed"

  defp maybe_add_virtual_diff(produced, item, workspace, parent_history) do
    child_session_id = item["child_session_id"] || item[:child_session_id]
    durable_ref = item["virtual_diff_ref"] || item[:virtual_diff_ref]

    with true <- is_binary(child_session_id) and child_session_id != "",
         true <- is_binary(workspace) and workspace != "",
         %{} <- durable_ref,
         {:ok, history} <- Log.fold(child_session_id, workspace: workspace),
         {_call_ids, {%{} = artifact, source_seq}} <- find_last_virtual_diff(history),
         selected_ref <- virtual_diff_ref(artifact, source_seq),
         true <- selected_ref == durable_ref,
         "not_applied" <- selected_ref["apply_status"],
         false <- virtual_diff_applied?(parent_history, selected_ref, child_session_id) do
      produced ++
        [
          %{
            "kind" => "virtual_diff",
            "virtual_diff_ref" => selected_ref,
            "next_action" => %{
              "tool" => "apply_virtual_diff",
              "arguments" => %{
                "virtual_diff_ref" => selected_ref,
                "child_session_id" => child_session_id,
                "dry_run" => true
              }
            }
          }
        ]
    else
      _absent_or_incoherent_evidence -> produced
    end
  end

  defp find_last_virtual_diff(history) do
    Enum.reduce(history, {MapSet.new(), nil}, fn
      %{type: :tool_call, data: %{"name" => "run_virtual_commands", "call_id" => call_id}},
      {call_ids, selected}
      when is_binary(call_id) ->
        {MapSet.put(call_ids, call_id), selected}

      %{
        type: :tool_result,
        seq: source_seq,
        data: %{
          "call_id" => call_id,
          "ok" => true,
          "virtual_diff" => %{"kind" => "virtual_diff"} = artifact
        }
      },
      {call_ids, selected} ->
        if MapSet.member?(call_ids, call_id) do
          {call_ids, {artifact, source_seq}}
        else
          {call_ids, selected}
        end

      _event, acc ->
        acc
    end)
  end

  defp virtual_diff_ref(artifact, source_seq) do
    encoded = Jason.encode!(artifact)

    %{
      "kind" => artifact["kind"],
      "version" => artifact["version"],
      "sha256" => :crypto.hash(:sha256, encoded) |> Base.encode16(case: :lower),
      "encoded_bytes" => byte_size(encoded),
      "changed_files" => length(Map.get(artifact, "changes", [])),
      "diff_bytes" => get_in(artifact, ["summary", "diff_bytes"]),
      "apply_status" => get_in(artifact, ["apply", "status"]),
      "source_seq" => source_seq
    }
  end

  defp landing_parent_history(parent_session_id, parent_workspace)
       when is_binary(parent_session_id) and parent_session_id != "" do
    case Log.fold(parent_session_id, workspace: parent_workspace) do
      {:ok, history} -> history
      {:error, _error} -> []
    end
  end

  defp landing_parent_history(_parent_session_id, _parent_workspace), do: []

  defp virtual_diff_applied?([], _virtual_diff_ref, _child_session_id), do: false

  defp virtual_diff_applied?(history, virtual_diff_ref, child_session_id) do
    successful_apply_ids =
      history
      |> Enum.filter(fn
        %{type: :tool_result, data: %{"call_id" => call_id, "ok" => true, "status" => "applied"}}
        when is_binary(call_id) ->
          true

        _event ->
          false
      end)
      |> MapSet.new(& &1.data["call_id"])

    Enum.any?(history, fn
      %{
        type: :tool_call,
        data: %{
          "call_id" => call_id,
          "name" => "apply_virtual_diff",
          "args" => %{
            "virtual_diff_ref" => %{} = applied_ref,
            "child_session_id" => applied_child_session_id,
            "dry_run" => false
          }
        }
      }
      when is_binary(call_id) and is_binary(applied_child_session_id) ->
        MapSet.member?(successful_apply_ids, call_id) and
          applied_child_session_id == child_session_id and applied_ref == virtual_diff_ref

      %{
        type: :tool_call,
        data: %{
          "call_id" => call_id,
          "name" => "apply_virtual_diff",
          "args" => %{"artifact" => %{} = artifact, "dry_run" => false}
        }
      }
      when is_binary(call_id) ->
        MapSet.member?(successful_apply_ids, call_id) and
          virtual_diff_ref(artifact, virtual_diff_ref["source_seq"])["sha256"] ==
            virtual_diff_ref["sha256"]

      _event ->
        false
    end)
  end

  defp maybe_put_manifest_count(map, _key, 0), do: map

  defp maybe_put_manifest_count(map, key, value) when is_integer(value) and value > 0,
    do: Map.put(map, key, value)

  defp maybe_put_manifest_field(map, _key, nil), do: map
  defp maybe_put_manifest_field(map, _key, ""), do: map
  defp maybe_put_manifest_field(map, key, value), do: Map.put(map, key, value)

  defp render_landing_manifest_entry(entry) do
    lines =
      case {entry["child_id"], entry["workspace"]} do
        {child_id, workspace} when is_binary(child_id) and child_id != "" ->
          ["- #{child_id}"]
          |> maybe_append_manifest_line(workspace, &"  workspace: #{&1}")

        {_absent_child_id, workspace} when is_binary(workspace) and workspace != "" ->
          ["- workspace: #{workspace}"]

        _absent_identity ->
          ["-"]
      end

    lines
    |> Kernel.++(Enum.flat_map(entry["produced"], &render_landing_manifest_item/1))
    |> Enum.join("\n")
  end

  defp render_landing_manifest_item(%{"kind" => "shared_workspace_files"} = item) do
    paths = item["paths"] || []
    shown = Enum.take(paths, @landing_manifest_path_cap)
    overflow = max(length(paths) - length(shown), 0)
    omitted = Map.get(item, "omitted_paths", 0) + overflow
    total = length(shown) + omitted

    changed_paths_heading =
      if omitted > 0 do
        "  changed paths (showing #{length(shown)} of #{total}; " <>
          "#{omitted} omitted by per-child cap):"
      else
        "  changed paths:"
      end

    path_lines = Enum.map(shown, &render_landing_manifest_path/1)

    action_lines =
      case item["next_action"] do
        %{"paths" => paths} when is_list(paths) and paths != [] ->
          rendered_paths = Enum.take(paths, @landing_manifest_path_cap)
          ["  next action: verify and commit paths #{Jason.encode!(rendered_paths)}"]

        _absent_action ->
          []
      end

    ["  produced: shared-workspace files", changed_paths_heading] ++ path_lines ++ action_lines
  end

  defp render_landing_manifest_item(%{"kind" => "virtual_diff"} = item) do
    virtual_diff_ref = Jason.encode!(item["virtual_diff_ref"])
    arguments = Jason.encode!(item["next_action"]["arguments"])

    [
      "  produced: virtual_diff virtual_diff_ref=#{virtual_diff_ref}",
      "  next action: apply_virtual_diff #{arguments}"
    ]
  end

  defp render_landing_manifest_path(%{
         "path" => path,
         "resolvable" => true,
         "exists_in_parent" => exists?,
         "drift" => drift?
       }) do
    "    - #{path} (exists_in_parent=#{exists?}, drift=#{drift?})"
  end

  defp render_landing_manifest_path(%{
         "path" => path,
         "resolvable" => false,
         "unresolvable" => reason
       }) do
    "    - #{path} (unresolvable=#{reason})"
  end

  defp maybe_append_manifest_line(lines, nil, _formatter), do: lines
  defp maybe_append_manifest_line(lines, "", _formatter), do: lines
  defp maybe_append_manifest_line(lines, value, formatter), do: lines ++ [formatter.(value)]

  @doc false
  def potentially_integrable?(items) when is_list(items) do
    Enum.any?(items, fn item ->
      status =
        item["status"] || item[:status] || item["subagent_status"] || item[:subagent_status]

      status in @potentially_integrable_statuses
    end)
  end

  def potentially_integrable?(_items), do: false

  @doc "Spawn or queue a Subagent."
  def spawn_agent(parent_session_id, args, opts \\ []),
    do: Manager.spawn_agent(parent_session_id, args, opts)

  @doc "Validate and normalize a Subagent spawn without creating runtime state."
  def validate_spawn(parent_session_id, args, opts \\ []),
    do: Manager.validate_spawn(parent_session_id, args, opts)

  @doc "Send follow-up input to an idle Subagent."
  def send_input(parent_session_id, subagent_id, prompt, opts \\ []),
    do: Manager.send_input(parent_session_id, subagent_id, prompt, opts)

  @doc "Wait for selected Subagents to reach a terminal status."
  def wait(parent_session_id, ids, timeout_ms \\ 30_000, opts \\ []),
    do: Manager.wait(parent_session_id, ids, timeout_ms, opts)

  @doc """
  Wait for selected Subagents and return a structured outcome.

  Unlike `wait/4`, this keeps partial fanout visible: timed-out, failed, detached,
  cancelled, and still-incomplete children are bucketed instead of turning the
  parent tool call into an opaque failure. The returned `"partial"` boolean is
  true for any non-completed aggregate status; consumers should use `"status"`
  when they need to distinguish `"partial"` from `"incomplete"`.
  """
  def wait_outcome(parent_session_id, ids, timeout_ms \\ 30_000, opts \\ []),
    do: Manager.wait_outcome(parent_session_id, ids, timeout_ms, opts)

  @doc """
  Cancel a running Subagent, or close a queued/terminal Subagent as cleanup.

  Cancelling a running Subagent fences its active logical Turn without stopping the
  reusable child Session. It then appends a `cancelled_by_parent` `:subagent_event`
  with `scope: "turn"` to the child's own Log. The event follows the synchronous
  interrupt result, but a C6-classified late declaration may append after it, so it is
  not promised physically list-last. Callers that cancel on behalf of a Workflow may
  name the canceller with `:workflow_id`, `:workflow_step_id`, and
  `:workflow_close_outcome`; those fields are simply absent from the child event for a
  plain parent close. Running-close results include bounded `cancellation_evidence`;
  the ordinary path is `complete`, while missing durable Session/child evidence is
  `partial` without raw errors or exits. The existing lifecycle return fields remain.
  """
  def close(parent_session_id, id, opts \\ []), do: Manager.close(parent_session_id, id, opts)

  @doc false
  def cancellation_evidence(true, true), do: %{"status" => "complete"}

  def cancellation_evidence(interrupt_complete?, child_event_complete?)
      when is_boolean(interrupt_complete?) and is_boolean(child_event_complete?) do
    completed = %{
      session_interrupt_evidence: interrupt_complete?,
      child_cancellation_event: child_event_complete?
    }

    failed_steps =
      for {key, step} <- @cancellation_steps,
          not Map.fetch!(completed, key),
          do: step

    %{
      "status" => "partial",
      "failed_steps" => failed_steps,
      "next_actions" => @cancellation_next_actions
    }
  end

  @doc false
  def normalize_cancellation_evidence(%{"status" => "complete"}),
    do: %{"status" => "complete"}

  def normalize_cancellation_evidence(%{"status" => "partial"} = evidence) do
    declared_steps = Map.get(evidence, "failed_steps", [])

    failed_steps =
      if is_list(declared_steps) do
        Enum.filter(@cancellation_failed_steps, &(&1 in declared_steps))
      else
        []
      end

    %{
      "status" => "partial",
      "failed_steps" => failed_steps,
      "next_actions" => @cancellation_next_actions
    }
  end

  def normalize_cancellation_evidence(_evidence), do: nil

  @doc "List Subagents for a parent Session."
  def list(parent_session_id, opts \\ []), do: Manager.list(parent_session_id, opts)

  @doc """
  Return a runtime diagnostics projection for one parent Session.

  Diagnostics idempotently hydrates restorable parent state from durable evidence before
  projecting the snapshot. Hydration may reattach live children: it subscribes to child
  event buses through `Pixir.Events` and rearms child timeout timers. It may also fold the
  parent Log after a Manager restart, but it does not write canonical events. The returned
  data remains volatile process-health evidence; use the Session Log and Session tree for
  canonical lifecycle facts.
  """
  def diagnostics(parent_session_id, opts \\ []), do: Manager.diagnostics(parent_session_id, opts)

  @doc "Summarize agent maps for model-facing output."
  def summarize(agents) when is_list(agents) do
    agents
    |> Enum.map_join("\n", fn agent ->
      summary = agent["summary"] || agent[:summary] || ""
      id = agent["id"] || agent[:id]
      name = agent["agent"] || agent[:agent]
      status = agent["status"] || agent[:status]
      "- #{id} (#{name}) #{status}: #{summary}"
    end)
  end

  @doc "Build model-facing text for a structured wait outcome."
  def summarize_wait_outcome(%{"summary" => summary}) when is_binary(summary), do: summary
  def summarize_wait_outcome(_outcome), do: "wait_agent outcome unavailable."

  @doc false
  @spec child_permission_posture(map(), map() | nil) :: map()
  def child_permission_posture(request, warm_lineage) when is_map(request) do
    %{
      "event" => "permission_posture",
      "scope" => "session",
      "lineage" => "child",
      "source" => "subagent_spawn",
      "subagent_id" => Map.fetch!(request, :subagent_id),
      "parent_session_id" => Map.fetch!(request, :parent_session_id),
      "permission_mode" => posture_permission_mode(Map.fetch!(request, :permission_mode)),
      "write_policy" => WritePolicy.metadata(Map.get(request, :write_policy)),
      "workspace_mode" => Map.fetch!(request, :workspace_mode),
      "workspace" => Map.fetch!(request, :workspace),
      "warm_start" => WarmStart.envelope_projection(warm_lineage)
    }
  end

  defp posture_permission_mode(nil), do: nil
  defp posture_permission_mode(mode) when is_atom(mode), do: Atom.to_string(mode)
  defp posture_permission_mode(mode) when is_binary(mode), do: mode

  @doc """
  Rehydrate a Session's durable permission posture for a cold resume.

  Root Sessions record their posture at creation (`Pixir.Conversation.start/1`,
  lineage `root`, trusted only in root position: first non-`session_fork` event,
  runtime-authored source) and restore the recorded capability ceiling —
  including unbounded auto when the marker declared it. Spawned children record
  theirs with lineage `child` and keep the stricter contract: write-capable
  history restores only with a bounded policy.

  Warm-start Logs add a runtime-authored `lineage_boundary_v1` marker. Only the
  permission posture and mutation evidence physically appended after the last
  valid marker govern that live warm segment; copied posture remains replay
  evidence. A valid boundary without current posture fails closed. Without a
  valid boundary, the existing full-history root/child/Fork behavior is
  preserved. Legacy Logs without posture evidence remain resumable only when
  they contain no write-capable evidence, and then restore an explicit read-only
  ceiling; otherwise they fail closed with reason `missing`, which is the one
  classification the operator may override via the CLI's explicit legacy-root
  attestation (never as unbounded auto).
  """
  @spec resume_posture(String.t(), keyword()) :: {:ok, map()} | {:error, map()}
  def resume_posture(session_id, opts \\ []) do
    workspace = Keyword.get(opts, :workspace, File.cwd!())

    with :ok <- SessionId.validate(session_id),
         {:ok, workspace} <- canonical_resume_workspace(session_id, workspace),
         {:ok, history} <- fold_resume_history(session_id, workspace) do
      case current_lineage_segment(history) do
        {:warm, boundary, current_history, posture_proof} ->
          with :ok <-
                 validate_current_segment_posture(
                   session_id,
                   boundary.data,
                   current_history,
                   posture_proof
                 ) do
            restore_resume_posture(
              session_id,
              current_history,
              history,
              workspace,
              "missing_current_posture"
            )
          end

        :full_history ->
          restore_resume_posture(session_id, history, history, workspace, "missing")
      end
    end
  end

  @doc false
  @spec warm_lineage_proof(String.t(), keyword()) :: {:ok, map()} | :none | {:error, map()}
  def warm_lineage_proof(session_id, opts \\ []) do
    workspace = Keyword.get(opts, :workspace, File.cwd!())

    with :ok <- SessionId.validate(session_id),
         {:ok, workspace} <- canonical_resume_workspace(session_id, workspace),
         {:ok, history} <- fold_resume_history(session_id, workspace) do
      case current_lineage_segment(history) do
        {:warm, boundary, current_history, posture_proof} ->
          posture_event =
            case current_history do
              [posture | _rest] ->
                case validate_current_segment_posture(
                       session_id,
                       boundary.data,
                       current_history,
                       posture_proof
                     ) do
                  :ok -> posture
                  {:error, _error} -> nil
                end

              [] ->
                nil
            end

          {:ok,
           %{
             boundary_event: boundary.event,
             posture_event: posture_event,
             seed_session_id: boundary.data["seed_session_id"],
             fork_root_session_id: boundary.data["fork_root_session_id"],
             replay_event_count: boundary.data["replay_event_count"]
           }}

        :full_history ->
          :none
      end
    end
  end

  defp restore_resume_posture(
         session_id,
         posture_history,
         lineage_history,
         workspace,
         missing_reason
       ) do
    evidence? = write_capable_evidence?(posture_history)

    case posture_events(posture_history) do
      [] when missing_reason == "missing_current_posture" ->
        {:error, resume_posture_error(session_id, missing_reason)}

      [] ->
        if evidence? do
          {:error, resume_posture_error(session_id, missing_reason)}
        else
          {:ok,
           %{
             permission_mode: :read_only,
             write_policy: nil,
             workspace_mode: "shared",
             workspace: workspace,
             lineage: :legacy_unknown
           }}
        end

      events ->
        with {:ok, posture} <- restore_posture_events(session_id, events, lineage_history),
             :ok <- validate_restored_workspace(session_id, posture, workspace),
             :ok <- validate_restored_policy(session_id, posture, evidence?) do
          {:ok, posture}
        end
    end
  end

  defp canonical_resume_workspace(session_id, workspace) when is_binary(workspace) do
    case canonical_path(workspace) do
      {:ok, canonical} ->
        {:ok, canonical}

      {:error, reason} ->
        {:error,
         resume_posture_error(session_id, "workspace_unavailable", %{
           "workspace" => Path.expand(workspace),
           "filesystem_reason" => inspect(reason)
         })}
    end
  end

  defp canonical_resume_workspace(session_id, workspace) do
    {:error,
     resume_posture_error(session_id, "workspace_unavailable", %{
       "workspace" => inspect(workspace)
     })}
  end

  # Normal Log.fold/2 intentionally seq-sorts History and treats :enoent as empty.
  # Resume trust instead reads physical append order so caller-authored seq cannot
  # move a late posture marker into root position. A caller explicitly resuming a
  # Session also has a stricter existence contract: an absent Log is not a readable
  # legacy Log, so detect it before folding and fail closed distinctly.
  defp fold_resume_history(session_id, workspace) do
    path = Log.path(session_id, workspace: workspace)

    case Log.exists(session_id, workspace: workspace) do
      {:ok, true} ->
        case Log.fold_append_order(session_id, workspace: workspace) do
          {:ok, history} -> {:ok, history}
          {:error, %{error: %{kind: :unsafe_state_path}} = error} -> {:error, error}
          {:error, error} -> {:error, resume_log_error(session_id, path, error)}
        end

      {:ok, false} ->
        {:error,
         resume_posture_error(session_id, "log_missing", %{
           "log_path" => path
         })}

      {:error, error} ->
        {:error, error}
    end
  end

  defp resume_log_error(session_id, path, error) do
    resume_posture_error(session_id, "log_unreadable", %{
      "log_path" => path,
      "log_error" => error
    })
  end

  # A lineage marker may reset authorization interpretation only when its physical
  # position is covered by an atomic runtime-created `session_fork` prefix. The direct
  # warm-start marker occupies the one position immediately after the fork's replayed
  # prefix; a marker inherited by an ordinary Fork must already be inside that Fork's
  # declared replay prefix. This keeps an append-only writer from manufacturing a later
  # marker and hiding earlier posture or mutation evidence. Full same-UID Log rewriting
  # remains the documented local NDJSON threat-model residue, matching root posture.
  defp current_lineage_segment(history) do
    with {:ok, fork} <- lineage_container(history) do
      boundary =
        history
        |> Enum.with_index()
        |> Enum.reduce(nil, fn {event, index}, last_boundary ->
          case lineage_boundary_origin(event, index, fork) do
            {:ok, origin, data} ->
              %{data: data, event: event, index: index, origin: origin}

            :error ->
              last_boundary
          end
        end)

      case boundary do
        nil ->
          :full_history

        %{index: index, origin: origin} = boundary ->
          {:warm, boundary, Enum.drop(history, index + 1), origin}
      end
    else
      :error -> :full_history
    end
  end

  defp lineage_container([
         %{
           type: :session_fork,
           data:
             %{
               "fork_root_session_id" => fork_root_session_id,
               "replay_event_count" => replay_event_count,
               "strategy" => "replay_v1"
             } = data
         }
         | _rest
       ])
       when is_integer(replay_event_count) and replay_event_count >= 0 do
    parent_session_id = Map.get(data, "parent_session_id")

    if SessionId.valid?(fork_root_session_id) and SessionId.valid?(parent_session_id) do
      {:ok,
       %{
         fork_root_session_id: fork_root_session_id,
         parent_session_id: parent_session_id,
         replay_event_count: replay_event_count,
         source: Map.get(data, "source"),
         warm_lineage: Map.get(data, "warm_lineage")
       }}
    else
      :error
    end
  end

  defp lineage_container(_history), do: :error

  defp lineage_boundary_origin(
         %{
           type: :user_message,
           data:
             %{
               "lineage_boundary" => true,
               "author" => "runtime",
               "marker_kind" => marker_kind,
               "seed_session_id" => seed_session_id,
               "fork_root_session_id" => fork_root_session_id,
               "replay_event_count" => replay_event_count,
               "text" => text
             } = data
         } = event,
         index,
         fork
       )
       when is_integer(replay_event_count) and replay_event_count > 0 do
    coherent_shape? =
      marker_kind == WarmStart.boundary_marker_kind() and
        SessionId.valid?(seed_session_id) and
        SessionId.valid?(fork_root_session_id) and
        fork_root_session_id == fork.fork_root_session_id and
        index == replay_event_count + 1 and
        text == WarmStart.boundary_text(seed_session_id)

    cond do
      coherent_shape? and fork.source == "delegate_warm_start" and
        fork.parent_session_id == seed_session_id and
          replay_event_count == fork.replay_event_count ->
        {:ok, :direct, data}

      coherent_shape? and
          inherited_boundary_proof?(
            fork.warm_lineage,
            data,
            event.id,
            index,
            fork.replay_event_count
          ) ->
        {:ok, {:inherited, fork.warm_lineage}, data}

      true ->
        :error
    end
  end

  defp lineage_boundary_origin(_event, _index, _fork), do: :error

  defp inherited_boundary_proof?(
         %{
           "version" => 1,
           "boundary_event_id" => boundary_event_id,
           "posture_event_id" => posture_event_id,
           "boundary_index" => boundary_index,
           "posture_index" => posture_index,
           "seed_session_id" => seed_session_id,
           "fork_root_session_id" => fork_root_session_id,
           "replay_event_count" => replay_event_count
         },
         boundary,
         event_id,
         index,
         outer_replay_event_count
       ) do
    boundary_event_id == event_id and
      (is_nil(posture_event_id) or non_empty_binary?(posture_event_id)) and
      boundary_index == index and
      boundary_index <= outer_replay_event_count and
      posture_index == index + 1 and
      seed_session_id == boundary["seed_session_id"] and
      fork_root_session_id == boundary["fork_root_session_id"] and
      replay_event_count == boundary["replay_event_count"]
  end

  defp inherited_boundary_proof?(
         _proof,
         _boundary,
         _event_id,
         _index,
         _outer_replay_event_count
       ),
       do: false

  defp validate_current_segment_posture(
         session_id,
         boundary,
         [posture | _rest],
         :direct
       ) do
    if current_posture_matches_boundary?(posture, boundary) do
      :ok
    else
      {:error, resume_posture_error(session_id, "missing_current_posture")}
    end
  end

  defp validate_current_segment_posture(
         session_id,
         boundary,
         [posture | _rest],
         {:inherited, %{"posture_event_id" => posture_event_id}}
       )
       when is_binary(posture_event_id) and posture_event_id != "" do
    if posture.id == posture_event_id and current_posture_matches_boundary?(posture, boundary) do
      :ok
    else
      {:error, resume_posture_error(session_id, "missing_current_posture")}
    end
  end

  defp validate_current_segment_posture(session_id, _boundary, _history, _proof) do
    {:error, resume_posture_error(session_id, "missing_current_posture")}
  end

  defp current_posture_matches_boundary?(
         %{
           type: :subagent_event,
           data: %{
             "event" => "permission_posture",
             "scope" => "session",
             "lineage" => "child",
             "source" => "subagent_spawn",
             "subagent_id" => subagent_id,
             "parent_session_id" => parent_session_id,
             "permission_mode" => permission_mode,
             "write_policy" => _write_policy,
             "workspace_mode" => workspace_mode,
             "workspace" => workspace,
             "warm_start" => warm_start
           }
         },
         boundary
       )
       when is_map(warm_start) do
    non_empty_binary?(subagent_id) and
      non_empty_binary?(parent_session_id) and
      permission_mode in ["auto", "ask", "read_only"] and
      workspace_mode in ["shared", "isolated", "virtual_overlay"] and
      non_empty_binary?(workspace) and
      warm_start["warm_started"] == true and
      warm_start["seed_session_id"] == boundary["seed_session_id"] and
      warm_start["fork_root_session_id"] == boundary["fork_root_session_id"] and
      warm_start["replay_event_count"] == boundary["replay_event_count"] and
      warm_start["strategy"] == "replay_v1" and
      warm_start["boundary_marker_kind"] == boundary["marker_kind"]
  end

  defp current_posture_matches_boundary?(_posture, _boundary), do: false

  defp non_empty_binary?(value), do: is_binary(value) and value != ""

  defp posture_events(history) do
    Enum.filter(history, fn
      %{type: :subagent_event, data: %{"event" => "permission_posture", "scope" => "session"}} ->
        true

      _event ->
        false
    end)
  end

  defp restore_posture_events(session_id, events, history) do
    restored = Enum.map(events, &restore_posture(&1, history))

    case Enum.uniq(restored) do
      [{:ok, posture}] -> {:ok, posture}
      [{:error, _error}] -> {:error, resume_posture_error(session_id, "unreadable")}
      _ambiguous -> {:error, resume_posture_error(session_id, "ambiguous")}
    end
  end

  defp restore_posture(%{data: data} = event, history) do
    with {:ok, permission_mode} <- Map.fetch(data, "permission_mode"),
         {:ok, mode} <- restore_permission_mode(permission_mode),
         {:ok, workspace_mode} when is_binary(workspace_mode) and workspace_mode != "" <-
           Map.fetch(data, "workspace_mode"),
         {:ok, metadata} <- Map.fetch(data, "write_policy"),
         {:ok, write_policy} <- WritePolicy.from_metadata(metadata),
         {:ok, lineage} <- restore_lineage(data, event, history) do
      {:ok,
       %{
         permission_mode: mode,
         write_policy: write_policy,
         workspace_mode: workspace_mode,
         workspace: Map.get(data, "workspace"),
         lineage: lineage
       }}
    else
      _invalid -> {:error, :invalid_posture}
    end
  end

  # A root marker is trusted in exactly two shapes: the runtime-authored event
  # (`source: "root_session_start"` — the only producer is Conversation.start;
  # a fork-replayed CHILD posture keeps `source: "subagent_spawn"`, so a partial
  # lineage edit of a forked child Log is refused by source alone) sitting in
  # the Log's ROOT POSITION, or an explicit operator attestation, which may
  # appear at any position but never restores unbounded auto
  # (validate_restored_policy/3). Root position means the event IS the first
  # non-`session_fork` event in physical append order — computed by position,
  # never by event id or claimed seq, both attacker-controlled in a hand-edited
  # Log (an id collision must not truncate the prefix and a forged seq must not
  # reorder trust evidence). A plain root has nothing
  # before its posture; a forked root has exactly the seq-0 `session_fork`
  # (`session_fork` is not in Fork.replay_types, so fork chains never nest).
  # A root marker carrying child spawn fields (subagent_id / parent_session_id)
  # is a contradiction refused outright. Full same-UID Log rewriting can still
  # fabricate the complete trusted shape — that residue is the documented local
  # NDJSON threat model, unchanged by this PR. Anything else folds as child
  # lineage, the conservative default: absent-lineage events are the child
  # events this evidence channel originally shipped with.
  defp restore_lineage(data, event, history) do
    case {Map.get(data, "lineage"), Map.get(data, "source")} do
      {"root", "operator_attested_legacy_root"} ->
        {:ok, :attested_root}

      {"root", "root_session_start"} ->
        cond do
          Map.has_key?(data, "subagent_id") or Map.has_key?(data, "parent_session_id") ->
            {:error, :untrusted_root_marker}

          root_position?(history, event) ->
            {:ok, :root}

          true ->
            {:error, :untrusted_root_marker}
        end

      {"root", _other_source} ->
        {:error, :untrusted_root_marker}

      {_absent_or_child, _source} ->
        {:ok, :child}
    end
  end

  defp root_position?(history, event) do
    Enum.find(history, &(&1.type != :session_fork)) == event
  end

  # Explicit matching is cold-VM safe; never derive atoms from Log strings.
  defp restore_permission_mode("auto"), do: {:ok, :auto}
  defp restore_permission_mode("ask"), do: {:ok, :ask}
  defp restore_permission_mode("read_only"), do: {:ok, :read_only}
  defp restore_permission_mode(_mode), do: {:error, :invalid_permission_mode}

  defp write_capable_evidence?(history) do
    mutation_attempt?(history) or write_policy_decision?(history)
  end

  defp mutation_attempt?(history) do
    ran = succeeded_call_ids(history)

    Enum.any?(history, fn
      %{type: :tool_call, data: data} when is_map(data) -> mutating_call?(data, ran)
      _event -> false
    end)
  end

  # Call ids the Log says actually produced a SUCCESSFUL result. `ok == false` is not in
  # here on purpose: a failed result is not a claim that the call ran to effect, and the
  # honest drain/synthesis pairing is exactly `ok: false` with an `orphan_tool_call` error.
  defp succeeded_call_ids(history) do
    for %{type: :tool_result, data: %{"call_id" => call_id} = data} <- history,
        data["ok"] == true,
        into: MapSet.new(),
        do: call_id
  end

  # #462: a `tool_call` Pixir itself wrote to close a cancellation window is NOT evidence
  # of a mutation attempt. Both markers name calls that provably never ran:
  #
  #   * `"synthesized"` — layer-2 recovery, whose name is the `"unknown"` placeholder;
  #     `Permissions.mutating?/2` fails closed on unknown names, so without this a legacy
  #     Log with no posture event would fail `resume_posture/2` closed with reason
  #     "missing" over a call nothing executed;
  #   * `"drained"` — layer-1 drain, which carries the call's real name but was persisted
  #     precisely BECAUSE the Turn was killed before the Executor could run it.
  #
  # #462 round 5: the marker alone does not buy the exemption — the PAIRING does. Both
  # markers are written by Pixir alongside a result asserting the call did not run, and
  # that assertion is the whole basis for exempting them. A Log that carries the marker
  # next to a SUCCESSFUL result is describing a call that ran, whatever the marker claims,
  # and the marker key is an ordinary string any writer (a forged Log, a corrupted one, a
  # future path that reuses the key for something that does execute) can place there.
  # Keying on presence alone would let that hide a real write and resume the Session
  # write-capable over it. So: exempt while no successful result exists for the id, and
  # fall through to the ordinary classification the moment one does. A marker with no
  # result at all stays exempt — that is the honest mid-drain shape, where the closing
  # reconciliation has not run (or its Log append failed).
  #
  # The catch-all classification for ordinary unknown names is untouched: only Pixir's own
  # markers, and only unpaired-with-success, are exempt.
  defp mutating_call?(%{"synthesized" => marker, "call_id" => call_id} = data, ran)
       when is_map(marker),
       do: MapSet.member?(ran, call_id) and mutating_by_name?(data)

  defp mutating_call?(%{"drained" => marker, "call_id" => call_id} = data, ran)
       when is_map(marker),
       do: MapSet.member?(ran, call_id) and mutating_by_name?(data)

  # A marker with no readable `call_id` cannot be tied to any result, so nothing can vouch
  # that it ran: it keeps the exemption, exactly as before round 5.
  defp mutating_call?(%{"synthesized" => marker}, _ran) when is_map(marker), do: false
  defp mutating_call?(%{"drained" => marker}, _ran) when is_map(marker), do: false

  defp mutating_call?(data, _ran), do: mutating_by_name?(data)

  # `Permissions.mutating?/2` fails closed on names it does not know, which is what makes
  # the layer-2 `"unknown"` placeholder classify as a write once it is no longer exempt.
  defp mutating_by_name?(%{"name" => name, "args" => args}) when is_binary(name),
    do: Permissions.mutating?(name, if(is_map(args), do: args, else: %{}))

  defp mutating_by_name?(%{"name" => name}) when is_binary(name),
    do: Permissions.mutating?(name, %{})

  # A tool_call whose data carries no binary `name` is unclassifiable. This module's
  # posture is fail-closed, so ordinary unclassifiable calls count as write-capable;
  # only the separate synthesized/drained marker clauses above retain their exemption.
  defp mutating_by_name?(_data), do: true

  defp write_policy_decision?(history) do
    Enum.any?(history, fn
      %{type: :permission_decision, data: data} when is_map(data) ->
        data["gate"] == "write_policy"

      _event ->
        false
    end)
  end

  defp validate_restored_policy(_session_id, %{permission_mode: :read_only}, _evidence?), do: :ok

  # An operator attestation never restores unbounded auto: the whole point of
  # the override is recovering a legacy Log without being able to prove it was
  # not a bounded child. The CLI refuses to write such an event; this clause
  # keeps a hand-forged one from restoring anyway. Attested ask stays valid —
  # every action still round-trips through the operator.
  defp validate_restored_policy(
         session_id,
         %{lineage: :attested_root, permission_mode: :auto, write_policy: nil},
         _evidence?
       ),
       do: {:error, resume_posture_error(session_id, "unbounded_write_policy")}

  defp validate_restored_policy(_session_id, %{lineage: :attested_root}, _evidence?), do: :ok

  # A trusted root marker (runtime-authored and first in physical append order)
  # restores its recorded ceiling verbatim — auto with no policy is a legitimate
  # declared capability for an operator-owned root Session.
  defp validate_restored_policy(_session_id, %{lineage: :root}, _evidence?), do: :ok

  defp validate_restored_policy(_session_id, %{write_policy: policy}, _evidence?)
       when is_map(policy), do: :ok

  # An unbounded `auto` ceiling with no write policy is legitimate ONLY for a
  # trusted root or an operator attestation (handled above). Any other lineage
  # claiming auto+nil is refused even with no write evidence: otherwise deleting
  # a bounded child's write events (tool_call/result) alongside nulling its
  # policy would resume it unbounded — a cheaper elevation than fabricating the
  # trusted-root shape. read_only postures already returned :ok above.
  defp validate_restored_policy(
         session_id,
         %{permission_mode: :auto, write_policy: nil},
         _evidence?
       ),
       do: {:error, resume_posture_error(session_id, "unbounded_write_policy")}

  defp validate_restored_policy(_session_id, _posture, false), do: :ok

  defp validate_restored_policy(session_id, _posture, true),
    do: {:error, resume_posture_error(session_id, "unbounded_write_policy")}

  defp validate_restored_workspace(session_id, posture, workspace) do
    recorded = posture.workspace

    cond do
      not (is_binary(recorded) and recorded != "") ->
        {:error, resume_posture_error(session_id, "workspace_unavailable")}

      true ->
        case canonical_path(recorded) do
          {:ok, ^workspace} ->
            :ok

          {:ok, _other_workspace} ->
            {:error, resume_posture_error(session_id, "workspace_mismatch")}

          {:error, reason} ->
            {:error,
             resume_posture_error(session_id, "workspace_unavailable", %{
               "workspace" => Path.expand(recorded),
               "filesystem_reason" => inspect(reason)
             })}
        end
    end
  end

  # Resolve every existing symlink segment instead of comparing path spellings.
  # This covers macOS' /var -> /private/var alias and symlinked temp/worktree roots.
  defp canonical_path(path) do
    path
    |> Path.expand()
    |> canonical_path(0)
  end

  defp canonical_path(_path, depth) when depth > 20, do: {:error, :symlink_depth_exceeded}

  defp canonical_path(path, depth) do
    case Path.split(path) do
      [root | segments] -> resolve_path_segments(root, segments, depth)
      [] -> {:ok, path}
    end
  end

  defp resolve_path_segments(current, [], _depth), do: {:ok, current}

  defp resolve_path_segments(current, [segment | rest], depth) do
    candidate = Path.join(current, segment)

    case File.lstat(candidate) do
      {:ok, %File.Stat{type: :symlink}} ->
        case File.read_link(candidate) do
          {:ok, link} ->
            target =
              case Path.type(link) do
                :absolute -> Path.expand(link)
                _relative -> Path.expand(link, Path.dirname(candidate))
              end

            [target | rest]
            |> Path.join()
            |> canonical_path(depth + 1)

          {:error, reason} ->
            {:error, {:read_link_failed, candidate, reason}}
        end

      {:error, reason} when reason not in [:enoent] ->
        {:error, {:lstat_failed, candidate, reason}}

      _existing_or_not_yet_created ->
        resolve_path_segments(candidate, rest, depth)
    end
  end

  @doc "Apply the common restrict-never-widen rules to a restored posture."
  @spec restrict_resume_posture(map() | nil, Permissions.mode(), map() | nil) ::
          {:ok, map() | nil} | {:error, map()}
  def restrict_resume_posture(nil, _requested_mode, _requested_policy), do: {:ok, nil}

  def restrict_resume_posture(posture, requested_mode, requested_policy) when is_map(posture) do
    effective_mode = restrict_permission_mode(posture.permission_mode, requested_mode)

    with {:ok, effective_policy} <-
           restrict_write_policy(posture.write_policy, requested_policy) do
      {:ok,
       %{
         posture
         | permission_mode: effective_mode,
           write_policy: if(effective_mode == :read_only, do: nil, else: effective_policy)
       }}
    end
  end

  defp restrict_permission_mode(:read_only, _requested), do: :read_only
  defp restrict_permission_mode(_durable, :read_only), do: :read_only
  defp restrict_permission_mode(:ask, _requested), do: :ask
  defp restrict_permission_mode(_durable, :ask), do: :ask
  defp restrict_permission_mode(:auto, :auto), do: :auto

  defp restrict_write_policy(nil, requested), do: {:ok, requested}
  defp restrict_write_policy(durable, nil), do: {:ok, durable}

  defp restrict_write_policy(durable, requested) do
    durable_rules = durable["allow_writes"] || []
    requested_rules = requested["allow_writes"] || []

    intersection =
      (Enum.filter(durable_rules, &rule_set_covers?(requested, &1)) ++
         Enum.filter(requested_rules, &rule_set_covers?(durable, &1)))
      |> Enum.uniq()

    if intersection == [] do
      {:error,
       Tool.error(
         :resume_policy_unavailable,
         "restored and requested write policies do not overlap",
         %{
           "reason" => "empty_policy_intersection"
         }
       )}
    else
      WritePolicy.normalize(%{
        "version" => durable["version"],
        "metadata" => %{"id" => durable["id"]},
        "allow_writes" => intersection,
        "deny_writes" =>
          Enum.uniq((durable["deny_writes"] || []) ++ (requested["deny_writes"] || [])),
        "bash" => restrict_policy_bash(durable["bash"], requested["bash"])
      })
    end
  end

  defp rule_set_covers?(policy, rule) do
    match?({:ok, _}, WritePolicy.narrow_to_write_set(policy, [rule]))
  end

  defp restrict_policy_bash("disabled", _requested), do: "disabled"
  defp restrict_policy_bash(_durable, "disabled"), do: "disabled"

  defp restrict_policy_bash(%{"verify" => durable} = durable_bash, %{"verify" => requested} = req) do
    verify = Enum.filter(requested, &(&1 in durable))

    # The operator-declared verify allowlist (#445) must survive the intersection:
    # dropping it would silently re-impose the Elixir default and reject the very
    # commands both sides agreed on. A side that declared nothing contributes the
    # default it was normalized under.
    case intersect_verify_prefixes(durable_bash, req) do
      # Nothing shared to authorize: the honest restriction is a disabled shell.
      _prefixes when verify == [] ->
        "disabled"

      # Unreachable while `verify` is non-empty — a command both sides admitted
      # was covered by a prefix on each side, and two prefixes covering the same
      # command are always leading runs of it, so one covers the other. Kept as a
      # fail-closed floor rather than emitting an empty allowlist, which normalize
      # rejects as malformed.
      [] ->
        "disabled"

      nil ->
        %{"verify" => verify}

      prefixes ->
        %{"verify_prefixes" => prefixes, "verify" => verify}
    end
  end

  defp restrict_policy_bash(_durable, _requested), do: "disabled"

  # Prefixes are compared by tokenwise coverage, not as exact strings — the same
  # relation `rule_set_covers?/2` applies to write rules just above. A prefix is
  # a constraint on what may be admitted, so a survivor must be covered by the
  # durable side: it survives only when some durable prefix is a tokenwise prefix
  # of it, which means it admits a subset of what durable already admitted. The
  # filter runs both ways, so each survivor is at least as narrow as both sides
  # (durable `mix` against requested `mix format` keeps `mix format`).
  #
  # Exact string intersection was the bug: it dropped `mix` and `mix format` as
  # unrelated, and the surviving `verify` command `mix format --check-formatted`
  # was then left uncovered by the remaining prefixes. `WritePolicy.normalize/1`
  # re-validates the restricted map, so an uncovered command failed resume closed
  # on a command both sides had already authorized.
  defp intersect_verify_prefixes(%{"verify_prefixes" => a}, %{"verify_prefixes" => b})
       when is_list(a) and is_list(b) do
    (Enum.filter(b, fn requested -> Enum.any?(a, &prefix_covers?(&1, requested)) end) ++
       Enum.filter(a, fn durable -> Enum.any?(b, &prefix_covers?(&1, durable)) end))
    |> Enum.uniq()
  end

  # Only one side declared. The other was normalized under the built-in default,
  # and every surviving command was admitted by both, so the declaration stands.
  defp intersect_verify_prefixes(%{"verify_prefixes" => a}, _requested) when is_list(a), do: a
  defp intersect_verify_prefixes(_durable, %{"verify_prefixes" => b}) when is_list(b), do: b
  defp intersect_verify_prefixes(_durable, _requested), do: nil

  # `covering` admits everything `candidate` admits when its tokens are a leading
  # run of `candidate`'s: `mix` covers `mix format`, `mix format` does not cover
  # `mix`, and `mix` never covers `mixer` (token equality, never substring).
  defp prefix_covers?(covering, candidate) do
    covering_tokens = String.split(covering, ~r/\s+/, trim: true)
    candidate_tokens = String.split(candidate, ~r/\s+/, trim: true)

    Enum.take(candidate_tokens, length(covering_tokens)) == covering_tokens
  end

  defp resume_posture_error(session_id, reason, extra_details \\ %{}) do
    Tool.error(
      :resume_policy_unavailable,
      "refusing to resume without unambiguous permission posture evidence",
      Map.merge(
        %{
          "session_id" => session_id,
          "reason" => reason,
          "next_actions" => posture_error_next_actions(reason)
        },
        extra_details
      )
    )
  end

  # Only the `missing` classification is operator-overrideable: the Log is
  # readable and unambiguous, it just predates posture evidence. Every other
  # failure (unreadable, ambiguous, workspace mismatch, untrusted marker) has
  # no honest recovery besides fixing the evidence itself.
  defp posture_error_next_actions("missing") do
    [
      "inspect_the_child_session_log",
      "resume_with_--assume-legacy-root_--legacy-root-reason_and_an_explicit_read_only_ask_or_bounded_posture",
      "start_a_new_read_only_session_instead_of_widening_this_session"
    ]
  end

  defp posture_error_next_actions(_reason) do
    [
      "inspect_the_child_session_log",
      "recover_or_recreate_the_permission_posture_evidence",
      "start_a_new_read_only_session_instead_of_widening_this_session"
    ]
  end

  @doc "All known Subagent lifecycle statuses."
  def statuses, do: @statuses

  @doc "Statuses that no longer have a live child runtime."
  def terminal_statuses, do: @terminal_statuses

  @doc "Whether a status is terminal."
  def terminal?(status), do: status in @terminal_statuses

  @doc """
  Whether the public lifecycle contract allows a status transition.

  `closed` is retained as Pixir's local close/cleanup state. Completed, failed,
  timed-out, and cancelled Subagents may be restarted by `send_input/4`; detached
  children cannot be resumed because there is no live process handle.
  """
  def transition_allowed?(from, to) when is_binary(from) and is_binary(to) do
    to in Map.get(@allowed_transitions, from, [])
  end

  def transition_allowed?(_from, _to), do: false

  @doc """
  Reconstruct Subagent relationships and terminal state from parent History.
  """
  def reconstruct(history) when is_list(history) do
    history
    |> Enum.filter(&(&1.type == :subagent_event))
    # Evidence a Session writes about ITSELF (permission posture, the Turn-scoped
    # `cancelled_by_parent` statement, and a delegate `horizon_override`) is not a child
    # lifecycle event: folding it here would fabricate a phantom child — a
    # nil-id one for posture or horizon override, or a self-referential entry for
    # cancellation — and flip delegate snapshots to incomplete. Only the parent-side
    # records describe children.
    |> Enum.reject(&self_scoped_event?/1)
    # Structural gate: the fold's identity key is meaningless without a real child id,
    # so any record lacking one is dropped here even if a future session-scoped event
    # is not yet named above. `self_scoped_event?/1` stays as documentation and
    # defense-in-depth for the known producers; this predicate closes the class.
    # Same identity predicate as `Pixir.SessionTree` uses for subagent records.
    |> Enum.filter(fn %{data: data} -> child_identity?(data["subagent_id"]) end)
    |> Enum.reduce(%{}, fn %{data: data}, acc ->
      id = data["subagent_id"]

      current =
        Map.get(acc, id, %{
          "id" => id,
          "events" => []
        })

      updated =
        current
        |> Map.merge(Map.take(data, subagent_fields()))
        |> maybe_clear_reconstructed_cancellation_evidence(data)
        |> normalize_reconstructed_cancellation_evidence()
        |> Map.put("events", current["events"] ++ [data["event"]])

      Map.put(acc, id, updated)
    end)
  end

  # A successful `input` event is the durable boundary of a fresh logical Turn. The live
  # Manager clears the prior Turn's cancellation evidence before writing this event; the
  # fold must perform the same clear even though absent fields ordinarily carry forward.
  defp maybe_clear_reconstructed_cancellation_evidence(agent, %{"event" => "input"}),
    do: Map.delete(agent, "cancellation_evidence")

  defp maybe_clear_reconstructed_cancellation_evidence(agent, _data), do: agent

  defp normalize_reconstructed_cancellation_evidence(agent) do
    case normalize_cancellation_evidence(agent["cancellation_evidence"]) do
      nil -> Map.delete(agent, "cancellation_evidence")
      evidence -> Map.put(agent, "cancellation_evidence", evidence)
    end
  end

  defp self_scoped_event?(%{data: %{"event" => "permission_posture"}}), do: true

  defp self_scoped_event?(%{data: %{"event" => "horizon_override"}}), do: true

  defp self_scoped_event?(%{data: %{"event" => "cancelled_by_parent", "lineage" => "child"}}),
    do: true

  defp self_scoped_event?(_event), do: false

  defp child_identity?(id), do: is_binary(id) and String.trim(id) != ""

  defp subagent_fields do
    [
      "subagent_id",
      "child_session_id",
      "agent",
      "status",
      "task",
      "depth",
      "max_depth",
      "workspace",
      "workspace_mode",
      "index",
      "parent_log_path",
      "child_log_path",
      "summary",
      "event",
      "timeout_ms",
      "deadline_at",
      "permission_mode",
      "write_policy",
      "warm_start",
      "elapsed_ms",
      "reason",
      "next_actions",
      "cancellation_evidence",
      "retry_attempts",
      "retry_max_attempts",
      "current_attempt_index",
      "retry_history",
      "virtual_diff_ref",
      "output_truncation",
      "output_warning_count",
      "output_warnings",
      "output_warning_reasons",
      "output_warnings_truncated"
    ]
  end
end
