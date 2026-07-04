defmodule Pixir.Delegate.Owner do
  @moduledoc """
  Delegate owner boundary and service-state vocabulary.

  This module is intentionally small: it does not start a daemon or keep a second durable
  store. It names the live-capability boundary required by ADR 0034 so `status`,
  `attach`, and `cancel` can report the difference between durable Log snapshots and
  active owner-backed behavior.

  Current service state:

    * `snapshot_only` means durable Log evidence was readable, but no resident Delegate
      owner is reachable for streaming attach or active cancellation.
    * `live_manager_handles` means the current BEAM runtime has Subagent Manager handles
      for active children, but this is not yet a resident Delegate owner.
    * `live_delegate_owner` means this BEAM runtime has a registered Delegate owner for
      active status/cancel capability. It does not imply cross-invocation daemon
      residency for one-shot escript callers.
    * `stale_handle` means durable evidence claims work was active, but no live handle
      exists in this runtime.
    * `owner_unavailable` means the runtime needed for a live operation could not be
      reached at all.
  """

  @doc "Return owner state for a durable snapshot operation."
  @spec snapshot_state(map(), keyword()) :: {:ok, map()} | {:error, map()}
  def snapshot_state(handle, opts \\ [])

  def snapshot_state(handle, _opts) when is_map(handle) do
    {:ok,
     %{
       "state" => "snapshot_only",
       "reachable" => false,
       "delegate_owner" => false,
       "capabilities" => ["durable_status", "snapshot_attach"],
       "delegate_id" => handle["delegate_id"],
       "parent_session_id" => handle["parent_session_id"],
       "reason" => "live_delegate_owner_not_reachable_in_current_runtime"
     }}
  end

  def snapshot_state(_handle, _opts),
    do: {:error, owner_error("invalid_delegate_handle", "delegate handle is required", %{})}

  @doc "Return live owner state for a current-runtime Delegate owner."
  @spec live_owner_state(map(), map(), keyword()) :: {:ok, map()} | {:error, map()}
  def live_owner_state(handle, details \\ %{}, opts \\ [])

  def live_owner_state(handle, details, _opts) when is_map(handle) do
    {:ok,
     %{
       "state" => "live_delegate_owner",
       "reachable" => true,
       "delegate_owner" => true,
       "capabilities" => ["durable_status", "snapshot_attach", "live_status", "active_cancel"],
       "delegate_id" => handle["delegate_id"],
       "parent_session_id" => handle["parent_session_id"],
       "reason" => "current_beam_runtime_has_registered_delegate_owner"
     }
     |> Map.merge(details)}
  end

  def live_owner_state(_handle, _details, _opts),
    do: {:error, owner_error("invalid_delegate_handle", "delegate handle is required", %{})}

  @doc "Classify cancel reachability from durable and live Manager evidence."
  @spec cancel_state(map(), [map()], [map()], [map()], [map()], keyword()) ::
          {:ok, map()} | {:error, map()}
  def cancel_state(
        handle,
        manager_children,
        cancelled_children,
        errors,
        stale_children,
        opts \\ []
      )

  def cancel_state(
        handle,
        manager_children,
        cancelled_children,
        errors,
        stale_children,
        _opts
      )
      when is_map(handle) do
    cond do
      errors_with_kind?(errors, "owner_unavailable") ->
        {:ok, unavailable_state(handle, errors)}

      cancelled_children != [] ->
        {:ok, live_manager_state(handle)}

      stale_children != [] ->
        {:ok, stale_state(handle, stale_children)}

      Enum.any?(manager_children, &(child_status(&1) == "detached")) ->
        {:ok,
         stale_state(handle, Enum.filter(manager_children, &(child_status(&1) == "detached")))}

      live_manager_children(manager_children) != [] ->
        {:ok, live_manager_state(handle)}

      true ->
        snapshot_state(handle)
    end
  end

  def cancel_state(
        _handle,
        _manager_children,
        _cancelled_children,
        _errors,
        _stale_children,
        _opts
      ),
      do: {:error, owner_error("invalid_delegate_handle", "delegate handle is required", %{})}

  @doc "Build a structured stale-handle error for active operations."
  @spec stale_handle_error(map(), [map()], keyword()) :: {:ok, map()} | {:error, map()}
  def stale_handle_error(handle, stale_children, opts \\ [])

  def stale_handle_error(handle, stale_children, _opts) when is_map(handle) do
    {:ok,
     owner_error(
       "stale_handle",
       "delegate has durable active evidence but no live owner handle",
       %{
         "delegate_id" => handle["delegate_id"],
         "parent_session_id" => handle["parent_session_id"],
         "stale_child_count" => length(stale_children),
         "next_actions" => [
           "inspect_delegate_status",
           "inspect_child_session_logs",
           "retry_from_a_resident_pixir_runtime_when_available"
         ]
       }
     )}
  end

  def stale_handle_error(_handle, _stale_children, _opts),
    do: {:error, owner_error("invalid_delegate_handle", "delegate handle is required", %{})}

  @doc "Build a structured owner-unavailable error for active operations."
  @spec owner_unavailable_error(map(), map() | nil, keyword()) :: {:ok, map()} | {:error, map()}
  def owner_unavailable_error(handle, cause \\ nil, opts \\ [])

  def owner_unavailable_error(handle, cause, _opts) when is_map(handle) do
    {:ok,
     owner_error("owner_unavailable", "Delegate owner runtime is unavailable", %{
       "delegate_id" => handle["delegate_id"],
       "parent_session_id" => handle["parent_session_id"],
       "cause" => cause,
       "next_actions" => [
         "inspect_delegate_status",
         "use_snapshot_attach",
         "restart_pixir_owner_when_service_mode_exists"
       ]
     })}
  end

  def owner_unavailable_error(_handle, _cause, _opts),
    do: {:error, owner_error("invalid_delegate_handle", "delegate handle is required", %{})}

  defp unavailable_state(handle, errors) do
    %{
      "state" => "owner_unavailable",
      "reachable" => false,
      "delegate_owner" => false,
      "capabilities" => ["durable_status", "snapshot_attach"],
      "delegate_id" => handle["delegate_id"],
      "parent_session_id" => handle["parent_session_id"],
      "reason" => "live_owner_or_manager_unavailable",
      "errors" => errors
    }
  end

  defp live_manager_state(handle) do
    %{
      "state" => "live_manager_handles",
      "reachable" => true,
      "delegate_owner" => false,
      "capabilities" => ["active_cancel"],
      "delegate_id" => handle["delegate_id"],
      "parent_session_id" => handle["parent_session_id"],
      "reason" => "current_beam_runtime_had_live_subagent_manager_handles"
    }
  end

  defp stale_state(handle, stale_children) do
    %{
      "state" => "stale_handle",
      "reachable" => false,
      "delegate_owner" => false,
      "capabilities" => ["durable_status", "snapshot_attach"],
      "delegate_id" => handle["delegate_id"],
      "parent_session_id" => handle["parent_session_id"],
      "reason" => "durable_active_children_have_no_live_owner_handle",
      "stale_child_count" => length(stale_children)
    }
  end

  defp errors_with_kind?(errors, kind) do
    Enum.any?(errors, &(&1["kind"] == kind))
  end

  defp live_manager_children(children) do
    Enum.filter(children, &(child_status(&1) in ["queued", "running"]))
  end

  defp child_status(child), do: child["status"] || child[:status] || "unknown"

  defp owner_error(kind, message, details) do
    %{
      "ok" => false,
      "status" => "rejected",
      "kind" => kind,
      "message" => message,
      "details" => details
    }
  end
end
