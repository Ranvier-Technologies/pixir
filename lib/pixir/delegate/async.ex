defmodule Pixir.Delegate.Async do
  @moduledoc """
  Async/liveness helpers for `pixir delegate` service commands.

  This module is intentionally not a second scheduler. It projects delegate state from
  the durable Session Log for `status`, and uses the existing Subagent Manager
  only for bounded lifecycle actions such as `cancel`. The Log remains the source of
  truth; Manager access is live-handle evidence that may be unavailable after a process
  restart.

  ## TODO(delegate-service-v1)

  Grow this into richer daemon/IPC-backed `attach` progress once Delegate needs
  cross-invocation streaming observation. Current owner-backed `start`, `status`,
  `attach`, and `cancel` can report daemon residency when routed through a manual
  workspace daemon, but `attach` remains a bounded snapshot rather than a stream.

  The next slice should preserve the current split:

    * `status` stays a durable Log projection and must remain useful after restart;
    * `cancel` should route through a live Delegate owner when one exists, and report an
      explicit `owner_unavailable`/`stale_handle` shape when it cannot affect running
      children;
    * `attach` should stream or snapshot progress without polling through shell loops;
    * response metadata should separate "request accepted" from "work complete" so
      long-running service clients do not treat `ok: false` running snapshots as errors.
  """

  alias Pixir.{Log, SessionTree, Subagents}
  alias Pixir.Delegate.{Handle, Owner, OwnerSupervisor}

  @active_statuses ~w(queued running)
  @completed_status "completed"
  @terminal_statuses ~w(completed failed timed_out cancelled detached closed)
  @snapshot_ttl_ms 5_000
  @retry_after_ms 10_000

  @doc "Start a Delegate run with a current-runtime owner."
  @spec start(map(), map(), map(), keyword()) :: {:ok, map()} | {:error, map()}
  def start(request, spec, spec_meta, opts \\ []) do
    start_delegate = Keyword.get(opts, :start_delegate, &OwnerSupervisor.start_delegate/4)
    runtime_opts = Keyword.get(opts, :runtime_opts, [])

    start_delegate.(request, spec, spec_meta, runtime_opts: runtime_opts)
  end

  @doc "Return a durable Delegate status snapshot for a Delegate handle or parent Session."
  @spec status(String.t(), keyword()) :: {:ok, map()} | {:error, map()}
  def status(handle_or_session_id, opts \\ [])

  def status(handle_or_session_id, opts) when is_binary(handle_or_session_id) do
    workspace = workspace(opts)

    with {:ok, handle} <- Handle.resolve(handle_or_session_id),
         {:ok, snapshot} <- durable_snapshot(handle["parent_session_id"], workspace, opts),
         {:ok, owner} <- owner_or_snapshot(handle) do
      {:ok, status_payload(handle, snapshot, owner)}
    end
  end

  def status(_handle_or_session_id, _opts),
    do:
      {:error,
       error_payload("invalid_args", "delegate status requires a Delegate handle", %{
         "usage" => "pixir delegate status <delegate_id|parent_session_id> --json",
         "next_actions" => ["provide_delegate_id_or_parent_session_id"]
       })}

  @doc "Cancel live Subagent children for a Delegate handle when the Manager has handles."
  @spec cancel(String.t(), keyword()) :: {:ok, map()} | {:error, map()}
  def cancel(handle_or_session_id, opts \\ [])

  def cancel(handle_or_session_id, opts) when is_binary(handle_or_session_id) do
    workspace = workspace(opts)

    with {:ok, handle} <- Handle.resolve(handle_or_session_id),
         {:ok, snapshot} <- durable_snapshot(handle["parent_session_id"], workspace, opts) do
      case OwnerSupervisor.cancel(handle, workspace: workspace) do
        {:ok,
         %{
           "manager_children" => manager_children,
           "cancelled_children" => cancelled_children,
           "errors" => errors,
           "owner" => owner
         }} ->
          {:ok,
           cancel_payload(handle, snapshot, manager_children, cancelled_children, errors, owner)}

        {:error, :not_found} ->
          cancel_with_manager_snapshot(handle, snapshot, workspace, opts)

        {:error, error} ->
          {:ok, owner_error} = Owner.owner_unavailable_error(handle, error)
          {:ok, cancel_owner_unavailable_payload(handle, snapshot, owner_error)}
      end
    end
  end

  def cancel(_handle_or_session_id, _opts),
    do:
      {:error,
       error_payload("invalid_args", "delegate cancel requires a Delegate handle", %{
         "usage" => "pixir delegate cancel <delegate_id|parent_session_id> --json",
         "next_actions" => ["provide_delegate_id_or_parent_session_id"]
       })}

  @doc "Attach to Delegate evidence by returning a bounded durable snapshot."
  @spec attach(String.t(), keyword()) :: {:ok, map()} | {:error, map()}
  def attach(handle_or_session_id, opts \\ [])

  def attach(handle_or_session_id, opts) when is_binary(handle_or_session_id) do
    workspace = workspace(opts)

    with {:ok, handle} <- Handle.resolve(handle_or_session_id),
         {:ok, snapshot} <- durable_snapshot(handle["parent_session_id"], workspace, opts),
         {:ok, owner} <- owner_or_snapshot(handle) do
      {:ok, attach_payload(handle, snapshot, owner)}
    end
  end

  def attach(_handle_or_session_id, _opts),
    do:
      {:error,
       error_payload("invalid_args", "delegate attach requires a Delegate handle", %{
         "usage" => "pixir delegate attach <delegate_id|parent_session_id> --json",
         "next_actions" => ["provide_delegate_id_or_parent_session_id"]
       })}

  defp durable_snapshot(session_id, workspace, opts) do
    if Log.exists?(session_id, workspace: workspace) do
      with {:ok, history} <- Log.fold(session_id, workspace: workspace),
           {:ok, tree} <-
             SessionTree.project(session_id,
               workspace: workspace,
               max_depth: Keyword.get(opts, :max_depth, 2)
             ) do
        children =
          history
          |> Subagents.reconstruct()
          |> Map.values()
          |> Enum.map(&child_payload/1)
          |> Enum.sort_by(&(&1["subagent_id"] || ""))

        {:ok,
         %{
           session_id: session_id,
           workspace: workspace,
           history: history,
           tree: tree,
           children: children
         }}
      else
        {:error, error} -> {:error, normalize_error(error)}
      end
    else
      {:error,
       error_payload("not_found", "session log was not found", %{
         "session_id" => session_id,
         "workspace" => workspace,
         "log_path" => Log.path(session_id, workspace: workspace),
         "next_actions" => [
           "check_the_session_id",
           "run_from_the_workspace_that_owns_the_session_log"
         ]
       })}
    end
  end

  defp status_payload(handle, snapshot, owner) do
    counts = counts(snapshot.children)
    status = aggregate_status(counts)

    %{
      "ok" => status == @completed_status,
      "status" => status,
      "kind" => "delegate_status",
      "delegate_id" => handle["delegate_id"],
      "parent_session_id" => handle["parent_session_id"],
      "session_id" => snapshot.session_id,
      "handle" => handle,
      "workspace" => snapshot.workspace,
      "summary" => status_summary(status, counts),
      "children" => snapshot.children,
      "counts" => counts,
      "complete" => complete?(counts),
      "snapshot_ttl_ms" => @snapshot_ttl_ms,
      "retry_after_ms" => retry_after(status),
      "observed_at" => now(),
      "durable_source" => durable_source(snapshot),
      "tree" => tree_summary(snapshot.tree),
      "diagnostics" => diagnostics(snapshot.session_id),
      "owner" => owner,
      "service_state" => owner["state"],
      "beam_coordination" => beam_coordination("status_snapshot"),
      "host_boundary" => host_boundary(),
      "next_actions" => status_next_actions(status, counts)
    }
  end

  defp cancel_payload(
         handle,
         snapshot,
         manager_children,
         cancelled,
         errors,
         owner_override \\ nil
       ) do
    {:ok, snapshot_owner} = Owner.snapshot_state(handle)
    before = status_payload(handle, snapshot, snapshot_owner)
    manager_children = Enum.map(manager_children, &child_payload/1)
    manager_counts = counts(manager_children)
    cancelled_children = Enum.map(cancelled, &child_payload/1)
    stale_live_children = stale_live_children(before["children"], manager_children)
    stale_errors = stale_handle_errors(handle, stale_live_children)
    errors = errors ++ stale_errors

    {:ok, owner} =
      if owner_override do
        {:ok, owner_override}
      else
        Owner.cancel_state(
          handle,
          manager_children,
          cancelled_children,
          errors,
          stale_live_children
        )
      end

    status =
      cancel_status(before, manager_counts, cancelled_children, errors, stale_live_children)

    %{
      "ok" => errors == [] and status in ["cancelled", "completed"],
      "status" => status,
      "kind" => "delegate_cancel",
      "delegate_id" => handle["delegate_id"],
      "parent_session_id" => handle["parent_session_id"],
      "session_id" => snapshot.session_id,
      "handle" => handle,
      "workspace" => snapshot.workspace,
      "summary" => cancel_summary(status, cancelled_children, errors, owner),
      "cancelled_child_count" => length(cancelled_children),
      "manager_child_counts_before" => manager_counts,
      "durable_status_before" => before["status"],
      "durable_child_counts_before" => before["counts"],
      "cancelled_children" => cancelled_children,
      "not_cancellable_children" => not_cancellable_children(manager_children),
      "stale_live_children" => stale_live_children,
      "errors" => errors,
      "snapshot_ttl_ms" => @snapshot_ttl_ms,
      "retry_after_ms" => @retry_after_ms,
      "observed_at" => now(),
      "diagnostics" => diagnostics(snapshot.session_id),
      "owner" => owner,
      "service_state" => owner["state"],
      "beam_coordination" => beam_coordination("manager_cancel"),
      "host_boundary" => host_boundary(),
      "next_actions" => cancel_next_actions(status, errors)
    }
  end

  defp cancel_with_manager_snapshot(handle, snapshot, workspace, opts) do
    case list_subagents(handle["parent_session_id"], workspace, opts) do
      {:ok, manager_children} ->
        cancellable = Enum.filter(manager_children, &(child_status(&1) in @active_statuses))

        {cancelled, errors} =
          close_children(handle["parent_session_id"], cancellable, workspace, opts)

        {:ok, cancel_payload(handle, snapshot, manager_children, cancelled, errors)}

      {:error, error} ->
        {:ok, owner_error} = Owner.owner_unavailable_error(handle, error)
        {:ok, cancel_owner_unavailable_payload(handle, snapshot, owner_error)}
    end
  end

  defp cancel_owner_unavailable_payload(handle, snapshot, owner_error) do
    {:ok, owner} = Owner.cancel_state(handle, [], [], [owner_error], [])
    {:ok, snapshot_owner} = Owner.snapshot_state(handle)
    before = status_payload(handle, snapshot, snapshot_owner)

    %{
      "ok" => false,
      "status" => "partial",
      "kind" => "delegate_cancel",
      "delegate_id" => handle["delegate_id"],
      "parent_session_id" => handle["parent_session_id"],
      "session_id" => snapshot.session_id,
      "handle" => handle,
      "workspace" => snapshot.workspace,
      "summary" =>
        "delegate cancel could not reach a live owner; returned durable snapshot only.",
      "cancelled_child_count" => 0,
      "manager_child_counts_before" => %{"total" => 0, "active" => 0, "terminal" => 0},
      "durable_status_before" => before["status"],
      "durable_child_counts_before" => before["counts"],
      "cancelled_children" => [],
      "not_cancellable_children" => [],
      "stale_live_children" => active_children(before["children"]),
      "errors" => [owner_error],
      "snapshot_ttl_ms" => @snapshot_ttl_ms,
      "retry_after_ms" => @retry_after_ms,
      "observed_at" => now(),
      "diagnostics" => diagnostics(snapshot.session_id),
      "owner" => owner,
      "service_state" => owner["state"],
      "beam_coordination" => beam_coordination("manager_cancel_unavailable"),
      "host_boundary" => host_boundary(),
      "next_actions" => cancel_next_actions("partial", [owner_error])
    }
  end

  # NOTE(delegate-service-v1): `attach_payload/3` reports accepted snapshot delivery,
  # not Delegate work success. Unlike `status_payload/1`, `"ok" => true` means Pixir
  # could read and return durable Log evidence; JSON consumers must inspect `status`,
  # `complete`, and `attach` for work state until the module TODO grows a real owner.
  defp attach_payload(handle, snapshot, owner) do
    status = status_payload(handle, snapshot, owner)

    status
    |> Map.merge(%{
      "ok" => true,
      "kind" => "delegate_attach",
      "delegate_id" => handle["delegate_id"],
      "parent_session_id" => handle["parent_session_id"],
      "summary" => attach_summary(status),
      "attach" => %{
        "mode" => "one_shot_snapshot",
        "streaming" => false,
        "source" => "durable_session_log",
        "status" => status["status"],
        "complete" => status["complete"],
        "service_state" => owner["state"]
      },
      "owner" => owner,
      "service_state" => owner["state"],
      "beam_coordination" => beam_coordination("attach_snapshot"),
      "host_boundary" => host_boundary(),
      "next_actions" => attach_next_actions(status["status"], status["counts"])
    })
  end

  defp list_subagents(session_id, workspace, opts) do
    list_subagents = Keyword.get(opts, :list_subagents, &Subagents.list/2)

    case list_subagents.(session_id, workspace: workspace) do
      {:ok, children} when is_list(children) ->
        {:ok, children}

      {:error, error} ->
        {:error, normalize_error(error)}

      other ->
        {:error,
         error_payload(
           "manager_unavailable",
           "Subagent Manager returned an unexpected response",
           %{
             "response" => inspect(other),
             "next_actions" => ["retry_status", "inspect_subagent_manager"]
           }
         )}
    end
  catch
    :exit, {:noproc, _} ->
      {:error,
       error_payload("manager_unavailable", "Subagent Manager runtime is unavailable", %{
         "session_id" => session_id,
         "next_actions" => ["retry_status", "start_or_restart_pixir"]
       })}

    :exit, {:timeout, _} ->
      {:error,
       error_payload("timeout", "Subagent Manager cancel snapshot timed out", %{
         "session_id" => session_id,
         "next_actions" => ["retry_cancel_with_backoff", "inspect_subagent_manager_mailbox"]
       })}
  end

  defp owner_or_snapshot(handle) do
    case OwnerSupervisor.owner_state(handle) do
      {:ok, owner} -> {:ok, owner}
      {:error, :not_found} -> Owner.snapshot_state(handle)
      {:error, _error} -> Owner.snapshot_state(handle)
    end
  end

  defp close_children(session_id, children, workspace, opts) do
    close_subagent = Keyword.get(opts, :close_subagent, &Subagents.close/3)

    Enum.reduce(children, {[], []}, fn child, {closed, errors} ->
      id = child["subagent_id"] || child["id"]

      case close_child(close_subagent, session_id, id, workspace) do
        {:ok, updated} ->
          {[updated | closed], errors}

        {:error, error} ->
          {closed, [normalize_error(error) | errors]}

        other ->
          error =
            error_payload("cancel_failed", "Subagent close returned an unexpected response", %{
              "subagent_id" => id,
              "response" => inspect(other)
            })

          {closed, [error | errors]}
      end
    end)
    |> then(fn {closed, errors} -> {Enum.reverse(closed), Enum.reverse(errors)} end)
  end

  defp close_child(close_subagent, session_id, id, workspace) do
    close_subagent.(session_id, id, workspace: workspace)
  catch
    :exit, {:noproc, _} ->
      {:error,
       error_payload("manager_unavailable", "Subagent Manager runtime is unavailable", %{
         "subagent_id" => id,
         "next_actions" => ["retry_status", "start_or_restart_pixir"]
       })}

    :exit, {:timeout, _} ->
      {:error,
       error_payload("timeout", "Subagent Manager close timed out", %{
         "subagent_id" => id,
         "next_actions" => ["retry_cancel_with_backoff", "inspect_subagent_manager_mailbox"]
       })}

    :exit, reason ->
      {:error,
       error_payload("manager_unavailable", "Subagent Manager close failed", %{
         "subagent_id" => id,
         "reason" => inspect(reason),
         "next_actions" => ["retry_status", "inspect_subagent_manager"]
       })}
  end

  defp child_payload(child) when is_map(child) do
    %{
      "subagent_id" => child["subagent_id"] || child["id"] || child[:subagent_id] || child[:id],
      "child_session_id" => child["child_session_id"] || child[:child_session_id],
      "agent" => child["agent"] || child[:agent],
      "status" => child_status(child),
      "summary" => child["summary"] || child[:summary],
      "task" => child["task"] || child[:task],
      "workspace_mode" => child["workspace_mode"] || child[:workspace_mode],
      "child_log_path" => child["child_log_path"] || child[:child_log_path],
      "next_actions" => child["next_actions"] || child[:next_actions] || []
    }
  end

  defp child_status(child), do: child["status"] || child[:status] || "unknown"

  defp counts(children) do
    by_status = Enum.frequencies_by(children, &child_status/1)
    active = Enum.count(children, &(child_status(&1) in @active_statuses))
    terminal = Enum.count(children, &(child_status(&1) in @terminal_statuses))

    by_status
    |> Map.put("total", length(children))
    |> Map.put("active", active)
    |> Map.put("terminal", terminal)
  end

  defp aggregate_status(%{"total" => 0}), do: "unknown"
  defp aggregate_status(%{"active" => active}) when active > 0, do: "running"

  defp aggregate_status(%{"total" => total, "completed" => completed}) when total == completed,
    do: "completed"

  defp aggregate_status(%{"terminal" => terminal, "total" => total}) when terminal == total,
    do: "partial"

  defp aggregate_status(_counts), do: "partial"

  defp complete?(%{"total" => 0}), do: false

  defp complete?(%{"active" => 0, "terminal" => terminal, "total" => total}),
    do: terminal == total

  defp complete?(_counts), do: false

  defp retry_after("running"), do: @retry_after_ms
  defp retry_after(_status), do: nil

  defp durable_source(snapshot) do
    %{
      "kind" => "session_log",
      "log_path" => Log.path(snapshot.session_id, workspace: snapshot.workspace),
      "event_count" => length(snapshot.history)
    }
  end

  defp tree_summary(tree) do
    %{
      "event_count" => tree["event_count"],
      "subagent_count" => length(tree["subagents"] || []),
      "fork_count" => length(tree["forks"] || []),
      "log_exists" => tree["log_exists"]
    }
  end

  defp cancel_status(_before, _manager_counts, _cancelled, [_ | _], _stale), do: "partial"
  defp cancel_status(_before, _manager_counts, _cancelled, _errors, [_ | _]), do: "partial"
  defp cancel_status(_before, _manager_counts, [_ | _], _errors, _stale), do: "cancelled"

  defp cancel_status(%{"status" => "running"}, %{"active" => 0}, _cancelled, _errors, _stale),
    do: "partial"

  defp cancel_status(_before, _manager_counts, _cancelled, _errors, _stale), do: "completed"

  defp status_summary("completed", counts),
    do: "delegate completed: #{counts["completed"] || 0} child session(s)."

  defp status_summary("running", counts),
    do: "delegate running: #{counts["active"]} active child session(s)."

  defp status_summary("unknown", _counts),
    do: "delegate status found a Session Log but no Subagent lifecycle events."

  defp status_summary("partial", counts),
    do: "delegate partial: #{counts_summary(counts)}."

  defp cancel_summary("cancelled", children, _errors, _owner),
    do: "delegate cancel requested for #{length(children)} live child session(s)."

  defp cancel_summary("completed", _children, _errors, _owner),
    do: "delegate cancel found no live child session requiring cancellation."

  defp cancel_summary("partial", _children, _errors, %{"state" => "stale_handle"}),
    do:
      "delegate cancel could not reach a live owner for durable running children; returned stale-handle evidence."

  defp cancel_summary("partial", _children, _errors, %{"state" => "owner_unavailable"}),
    do: "delegate cancel could not reach the live owner; returned durable snapshot evidence."

  defp cancel_summary("partial", children, errors, _owner),
    do:
      "delegate cancel partial: cancelled #{length(children)} child session(s), " <>
        "#{length(errors)} error(s) or stale handle(s)."

  defp attach_summary(status) do
    "delegate attach snapshot: #{status["summary"]}"
  end

  defp status_next_actions("running", _counts),
    do: ["attach_snapshot_for_observation", "check_status_later_with_backoff"]

  defp status_next_actions("completed", _counts), do: ["inspect_tree_or_diagnose_for_postmortem"]

  defp status_next_actions(_status, _counts),
    do: ["inspect_tree_or_diagnose_for_postmortem", "check_child_session_logs"]

  defp cancel_next_actions("cancelled", _errors),
    do: ["check_status_later_with_backoff", "inspect_tree_or_diagnose_for_postmortem"]

  defp cancel_next_actions("completed", _errors), do: ["inspect_tree_or_diagnose_for_postmortem"]

  defp cancel_next_actions(_status, _errors),
    do: [
      "inspect_errors",
      "check_status_later_with_backoff",
      "inspect_tree_or_diagnose_for_postmortem"
    ]

  defp attach_next_actions("running", _counts),
    do: ["check_status_later_with_backoff", "cancel_if_the_work_is_no_longer_needed"]

  defp attach_next_actions("completed", _counts), do: ["inspect_tree_or_diagnose_for_postmortem"]

  defp attach_next_actions(_status, _counts),
    do: ["inspect_tree_or_diagnose_for_postmortem", "check_child_session_logs"]

  defp not_cancellable_children(children) do
    Enum.reject(children, &(child_status(&1) in @active_statuses))
  end

  defp stale_live_children(durable_children, manager_children) do
    manager_ids =
      manager_children
      |> Enum.map(& &1["subagent_id"])
      |> MapSet.new()

    Enum.filter(durable_children, fn child ->
      child_status(child) in @active_statuses and
        not MapSet.member?(manager_ids, child["subagent_id"])
    end)
  end

  defp stale_handle_errors(_handle, []), do: []

  defp stale_handle_errors(handle, stale_children) do
    case Owner.stale_handle_error(handle, stale_children) do
      {:ok, error} -> [error]
      {:error, error} -> [error]
    end
  end

  defp active_children(children),
    do: Enum.filter(children, &(child_status(&1) in @active_statuses))

  defp counts_summary(counts) do
    counts
    |> Enum.reject(fn {key, value} -> key in ["total", "active", "terminal"] or value == 0 end)
    |> Enum.sort()
    |> Enum.map_join(", ", fn {status, count} -> "#{status}=#{count}" end)
    |> case do
      "" -> "no terminal child status found"
      summary -> summary
    end
  end

  defp diagnostics(session_id) do
    %{
      "tree_command" => "pixir tree #{session_id} --json",
      "diagnose_command" => "pixir diagnose session #{session_id} --json",
      "issue" => "https://github.com/Ranvier-Technologies/pixir-harness/issues/133"
    }
  end

  defp beam_coordination(mode) do
    %{
      "mode" => mode,
      "entrypoint" => "single_pixir_process",
      "fanout_model" => "BEAM coordination, no process-per-child shell fanout"
    }
  end

  defp host_boundary do
    %{
      "external_process_spawns" => 0,
      "external_process_spawns_scope" =>
        "delegate_async_snapshot_or_cancel_entrypoint_only_not_child_tools",
      "measurement" => "static_contract_assertion_not_global_host_metric",
      "nested_pixir_processes" => 0,
      "nested_mix_processes" => 0,
      "shell_polling" => false,
      "host_command_execution" => "none_in_delegate_async_status_attach_or_cancel",
      "rule" => "treat every external process spawn as a scarce observable boundary crossing"
    }
  end

  defp normalize_error(%{ok: false, error: %{kind: kind, message: message} = error}) do
    error_payload(to_string(kind), message, stringify_keys(Map.get(error, :details, %{})))
  end

  defp normalize_error(%{"ok" => false} = error), do: error

  defp normalize_error(error) do
    error_payload("runtime_error", "delegate async command failed", %{"reason" => inspect(error)})
  end

  defp error_payload(kind, message, details) do
    %{
      "ok" => false,
      "status" => "rejected",
      "kind" => kind,
      "message" => message,
      "details" => details
    }
  end

  defp stringify_keys(%{} = map) do
    Map.new(map, fn {key, value} -> {to_string(key), stringify_keys(value)} end)
  end

  defp stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)
  defp stringify_keys(value), do: value

  defp workspace(opts), do: opts |> Keyword.get(:workspace, File.cwd!()) |> Path.expand()
  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
end
