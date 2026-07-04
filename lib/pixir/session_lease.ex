defmodule Pixir.SessionLease do
  @moduledoc """
  Filesystem-backed writer leases for Pixir Sessions.

  `Pixir.Session` serializes writes inside one BEAM runtime, but a second OS process can
  still try to resume the same Session and append to the same NDJSON Log. A
  `SessionLease` is the cross-process live-capability guard: exactly one writer holder
  can acquire `<workspace>/.pixir/session_leases/<session_id>.json` with exclusive
  create, and `Pixir.Log.append/2` refuses competing appends while a lease is present.

  The lease is not History and never replaces the Log. It is local runtime evidence used
  to answer "may this process write now?" Snapshot readers do not need a lease. Stale or
  ambiguous leases fail closed until an explicit forced-release path records a diagnostic
  release entry under `.pixir/session_leases/releases/`.
  """

  alias Pixir.Paths

  @version 1
  @heartbeat_interval_ms 1_000
  @stale_after_ms 5_000
  @future_skew_ms 5_000

  @type lease :: map()

  @doc "Acquire the writer lease for a Session using atomic exclusive file creation."
  @spec acquire(String.t(), keyword()) :: {:ok, lease()} | {:error, map()}
  def acquire(session_id, opts \\ []) when is_binary(session_id) do
    workspace = workspace(opts)

    with :ok <- maybe_force_release(session_id, workspace, opts) do
      do_acquire(session_id, workspace)
    end
  end

  @doc "Return a parseable Session writer lease status snapshot."
  @spec status(String.t(), keyword()) :: {:ok, map()} | {:error, map()}
  def status(session_id, opts \\ []) when is_binary(session_id) do
    workspace = workspace(opts)
    path = Paths.session_lease(session_id, workspace)

    case read_lease(path) do
      {:ok, nil} ->
        {:ok,
         %{
           "state" => "available",
           "session_id" => session_id,
           "workspace" => workspace,
           "lease_path" => path,
           "writer_present" => false
         }}

      {:ok, lease} ->
        {:ok, classify_lease(session_id, workspace, path, lease, now_ms())}

      {:error, reason} ->
        {:ok,
         ambiguous_status(session_id, workspace, path, %{
           "reason" => inspect(reason),
           "next_actions" => ambiguous_next_actions()
         })}
    end
  end

  @doc """
  Authorize a Log append.

  Raw appenders are allowed only when no writer lease exists. Active/stale/ambiguous
  leases require the matching holder passed as `writer_lease: lease`.
  """
  @spec authorize_append(String.t(), keyword()) :: :ok | {:error, map()}
  def authorize_append(session_id, opts \\ []) when is_binary(session_id) do
    workspace = workspace(opts)

    case Keyword.get(opts, :writer_lease) do
      nil -> authorize_without_holder(session_id, workspace)
      %{} = lease -> authorize_holder(session_id, workspace, lease)
      _other -> {:error, error(:session_writer_ambiguous, "writer lease option is invalid", %{})}
    end
  end

  @doc "Refresh the lease heartbeat for a live Session writer."
  @spec heartbeat(lease()) :: {:ok, lease()} | {:error, map()}
  def heartbeat(%{"session_id" => session_id, "workspace" => workspace} = lease) do
    path = Paths.session_lease(session_id, workspace)
    expected_holder_id = lease["holder_id"]

    case read_lease(path) do
      {:ok, %{"holder_id" => ^expected_holder_id}} ->
        updated =
          lease
          |> Map.put("heartbeat_at_ms", now_ms())
          |> Map.put("heartbeat_at", now_iso())

        with :ok <- write_json_atomic(path, updated) do
          {:ok, updated}
        end

      {:ok, nil} ->
        {:error,
         error(:session_writer_lost, "Session writer lease disappeared", %{
           "session_id" => session_id,
           "workspace" => workspace,
           "lease_path" => path,
           "next_actions" => ["stop_current_session", "inspect_session_writer_lease"]
         })}

      {:ok, current} ->
        {:error,
         error(:session_writer_lost, "Session writer lease is held by another writer", %{
           "session_id" => session_id,
           "workspace" => workspace,
           "lease_path" => path,
           "current_holder" => safe_holder(current),
           "expected_holder_id" => expected_holder_id,
           "next_actions" => ["stop_current_session", "inspect_session_writer_lease"]
         })}

      {:error, reason} ->
        {:error,
         error(:session_writer_ambiguous, "Session writer lease could not be refreshed", %{
           "session_id" => session_id,
           "workspace" => workspace,
           "lease_path" => path,
           "reason" => inspect(reason),
           "next_actions" => ambiguous_next_actions()
         })}
    end
  end

  @doc "Release a writer lease if the current holder still owns it."
  @spec release(lease() | nil) :: :ok
  def release(nil), do: :ok

  def release(%{"session_id" => session_id, "workspace" => workspace} = lease) do
    path = Paths.session_lease(session_id, workspace)
    expected_holder_id = lease["holder_id"]

    case read_lease(path) do
      {:ok, %{"holder_id" => ^expected_holder_id}} ->
        _ = File.rm(path)
        :ok

      _other ->
        :ok
    end
  end

  @doc """
  Explicitly release a stale or ambiguous writer lease.

  Active leases are refused. The release operation records a durable diagnostic JSON
  entry before removing the lease file. This is a break-glass path for orphaned writer
  state, not ordinary startup cleanup.
  """
  @spec force_release(String.t(), keyword()) :: {:ok, map()} | {:error, map()}
  def force_release(session_id, opts \\ []) when is_binary(session_id) do
    workspace = workspace(opts)
    reason = Keyword.get(opts, :reason) || "operator_forced_session_writer_lease_release"

    with {:ok, status} <- status(session_id, workspace: workspace) do
      case status["state"] do
        "available" ->
          {:ok,
           %{
             "released" => false,
             "state_before" => status,
             "reason" => "no_writer_lease_present"
           }}

        "active" ->
          {:error, status_error(status)}

        state when state in ["stale", "ambiguous"] ->
          release_record = release_record(session_id, workspace, status, reason)

          with {:ok, release_path} <- write_release_record(workspace, release_record),
               :ok <- remove_lease(status["lease_path"]) do
            {:ok,
             %{
               "released" => true,
               "state_before" => status,
               "release_record_path" => release_path,
               "reason" => reason
             }}
          end
      end
    end
  end

  defp maybe_force_release(session_id, workspace, opts) do
    if Keyword.get(opts, :force_release?, false) do
      reason = Keyword.get(opts, :force_release_reason)

      case force_release(session_id, workspace: workspace, reason: reason) do
        {:ok, _record} -> :ok
        {:error, error} -> {:error, error}
      end
    else
      :ok
    end
  end

  defp do_acquire(session_id, workspace) do
    Paths.ensure_session_leases_dir(workspace)
    path = Paths.session_lease(session_id, workspace)
    lease = new_lease(session_id, workspace, path)

    case File.open(path, [:write, :exclusive], fn io -> IO.write(io, encode!(lease)) end) do
      {:ok, :ok} ->
        {:ok, lease}

      {:error, :eexist} ->
        with {:ok, status} <- status(session_id, workspace: workspace) do
          {:error, status_error(status)}
        end

      {:error, reason} ->
        {:error,
         error(:session_writer_ambiguous, "Session writer lease could not be acquired", %{
           "session_id" => session_id,
           "workspace" => workspace,
           "lease_path" => path,
           "reason" => inspect(reason),
           "next_actions" => ambiguous_next_actions()
         })}
    end
  end

  defp authorize_without_holder(session_id, workspace) do
    with {:ok, status} <- status(session_id, workspace: workspace) do
      case status["state"] do
        "available" -> :ok
        _state -> {:error, status_error(status)}
      end
    end
  end

  defp authorize_holder(session_id, workspace, lease) do
    path = Paths.session_lease(session_id, workspace)
    expected_holder_id = lease["holder_id"]

    case read_lease(path) do
      {:ok, %{"holder_id" => ^expected_holder_id}} ->
        :ok

      {:ok, nil} ->
        {:error,
         error(:session_writer_lost, "Session writer lease is no longer present", %{
           "session_id" => session_id,
           "workspace" => workspace,
           "lease_path" => path,
           "next_actions" => ["stop_current_session", "inspect_session_writer_lease"]
         })}

      {:ok, current} ->
        {:error,
         error(:session_writer_ambiguous, "Session writer lease holder does not match", %{
           "session_id" => session_id,
           "workspace" => workspace,
           "lease_path" => path,
           "current_holder" => safe_holder(current),
           "expected_holder_id" => expected_holder_id,
           "next_actions" => ambiguous_next_actions()
         })}

      {:error, reason} ->
        {:error,
         error(:session_writer_ambiguous, "Session writer lease status is ambiguous", %{
           "session_id" => session_id,
           "workspace" => workspace,
           "lease_path" => path,
           "reason" => inspect(reason),
           "next_actions" => ambiguous_next_actions()
         })}
    end
  end

  defp classify_lease(session_id, workspace, path, lease, now_ms) do
    cond do
      invalid_lease?(lease, session_id, workspace) ->
        ambiguous_status(session_id, workspace, path, %{
          "reason" => "lease_identity_mismatch_or_missing_fields",
          "lease" => safe_holder(lease),
          "next_actions" => ambiguous_next_actions()
        })

      not is_integer(lease["heartbeat_at_ms"]) ->
        ambiguous_status(session_id, workspace, path, %{
          "reason" => "missing_heartbeat_at_ms",
          "lease" => safe_holder(lease),
          "next_actions" => ambiguous_next_actions()
        })

      lease["heartbeat_at_ms"] > now_ms + @future_skew_ms ->
        ambiguous_status(session_id, workspace, path, %{
          "reason" => "heartbeat_is_in_the_future",
          "lease" => safe_holder(lease),
          "next_actions" => ambiguous_next_actions()
        })

      now_ms - lease["heartbeat_at_ms"] <= stale_after_ms(lease) ->
        lease_status("active", session_id, workspace, path, lease, now_ms)

      true ->
        lease_status("stale", session_id, workspace, path, lease, now_ms)
    end
  end

  defp lease_status(state, session_id, workspace, path, lease, now_ms) do
    age_ms = max(now_ms - lease["heartbeat_at_ms"], 0)

    %{
      "state" => state,
      "session_id" => session_id,
      "workspace" => workspace,
      "lease_path" => path,
      "writer_present" => true,
      "holder" => safe_holder(lease),
      "heartbeat_age_ms" => age_ms,
      "stale_after_ms" => stale_after_ms(lease),
      "next_actions" => next_actions_for_state(state)
    }
  end

  defp ambiguous_status(session_id, workspace, path, details) do
    %{
      "state" => "ambiguous",
      "session_id" => session_id,
      "workspace" => workspace,
      "lease_path" => path,
      "writer_present" => true,
      "details" => details,
      "next_actions" => Map.get(details, "next_actions", ambiguous_next_actions())
    }
  end

  defp status_error(%{"state" => "active"} = status) do
    error(:session_writer_active, "Session already has an active writer lease", %{
      "lease" => Map.delete(status, "next_actions"),
      "next_actions" => next_actions_for_state("active")
    })
  end

  defp status_error(%{"state" => "stale"} = status) do
    error(:session_writer_stale, "Session has a stale writer lease", %{
      "lease" => Map.delete(status, "next_actions"),
      "next_actions" => next_actions_for_state("stale")
    })
  end

  defp status_error(%{"state" => "ambiguous"} = status) do
    error(:session_writer_ambiguous, "Session writer lease state is ambiguous", %{
      "lease" => Map.delete(status, "next_actions"),
      "next_actions" => ambiguous_next_actions()
    })
  end

  defp status_error(status) do
    error(:session_writer_ambiguous, "Session writer lease has unexpected state", %{
      "lease" => status,
      "next_actions" => ambiguous_next_actions()
    })
  end

  defp new_lease(session_id, workspace, path) do
    now_ms = now_ms()

    %{
      "version" => @version,
      "purpose" => "session_writer",
      "session_id" => session_id,
      "workspace" => workspace,
      "lease_path" => path,
      "holder_id" => random_id("wrl"),
      "os_pid" => System.pid(),
      "beam_node" => Atom.to_string(Node.self()),
      "started_at_ms" => now_ms,
      "started_at" => now_iso(),
      "heartbeat_at_ms" => now_ms,
      "heartbeat_at" => now_iso(),
      "heartbeat_interval_ms" => @heartbeat_interval_ms,
      "stale_after_ms" => @stale_after_ms
    }
  end

  defp invalid_lease?(lease, session_id, workspace) do
    lease["version"] != @version or
      lease["purpose"] != "session_writer" or
      lease["session_id"] != session_id or
      Path.expand(lease["workspace"] || "") != workspace or
      not is_binary(lease["holder_id"])
  end

  defp safe_holder(lease) when is_map(lease) do
    Map.take(lease, [
      "version",
      "purpose",
      "session_id",
      "workspace",
      "holder_id",
      "os_pid",
      "beam_node",
      "started_at",
      "heartbeat_at",
      "heartbeat_interval_ms",
      "stale_after_ms"
    ])
  end

  defp stale_after_ms(%{"stale_after_ms" => stale_after_ms})
       when is_integer(stale_after_ms) and stale_after_ms > 0,
       do: stale_after_ms

  defp stale_after_ms(_lease), do: @stale_after_ms

  defp release_record(session_id, workspace, status, reason) do
    %{
      "version" => 1,
      "kind" => "session_writer_lease_forced_release",
      "session_id" => session_id,
      "workspace" => workspace,
      "reason" => reason,
      "released_at" => now_iso(),
      "state_before" => status,
      "note" =>
        "This record is lease diagnostic evidence only; the Session Log was not rewritten."
    }
  end

  defp write_release_record(workspace, record) do
    dir = Paths.ensure_session_lease_releases_dir(workspace)
    path = Path.join(dir, release_filename(record["session_id"]))

    with :ok <- write_json_atomic(path, record) do
      {:ok, path}
    end
  end

  defp release_filename(session_id) do
    safe_id = String.replace(session_id, ~r/[^A-Za-z0-9_.-]/, "_")
    timestamp = DateTime.utc_now() |> Calendar.strftime("%Y%m%dT%H%M%S")
    "#{timestamp}-#{safe_id}-#{Base.encode16(:crypto.strong_rand_bytes(3), case: :lower)}.json"
  end

  defp remove_lease(path) do
    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, write_error(:session_writer_ambiguous, path, reason)}
    end
  end

  defp read_lease(path) do
    case File.read(path) do
      {:ok, raw} ->
        case Jason.decode(raw) do
          {:ok, lease} when is_map(lease) -> {:ok, lease}
          {:ok, other} -> {:error, {:invalid_shape, inspect(other)}}
          {:error, error} -> {:error, {:invalid_json, Exception.message(error)}}
        end

      {:error, :enoent} ->
        {:ok, nil}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp write_json_atomic(path, value) do
    tmp = path <> ".tmp-" <> Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)

    with :ok <- File.write(tmp, encode!(value)),
         :ok <- File.rename(tmp, path) do
      :ok
    else
      {:error, reason} ->
        _ = File.rm(tmp)
        {:error, write_error(:session_writer_ambiguous, path, reason)}
    end
  end

  defp write_error(kind, path, reason) do
    error(kind, "could not write Session writer lease evidence", %{
      "path" => path,
      "reason" => inspect(reason),
      "next_actions" => ["check_pixir_state_directory_permissions", "retry_after_fixing_io"]
    })
  end

  defp next_actions_for_state("active") do
    [
      "wait_for_writer_exit",
      "inspect_session_writer_lease",
      "use_resume_--force-release-writer-lease_only_if_orphaned"
    ]
  end

  defp next_actions_for_state("stale") do
    [
      "inspect_session_writer_lease",
      "use_resume_--force-release-writer-lease_if_the_writer_is_orphaned",
      "preserve_session_log_evidence"
    ]
  end

  defp next_actions_for_state(_state), do: ambiguous_next_actions()

  defp ambiguous_next_actions do
    [
      "inspect_session_writer_lease",
      "avoid_starting_a_competing_writer",
      "use_resume_--force-release-writer-lease_only_after_confirming_the_writer_is_orphaned"
    ]
  end

  defp workspace(opts), do: opts |> Keyword.get(:workspace, File.cwd!()) |> Path.expand()

  defp now_ms, do: System.system_time(:millisecond)
  defp now_iso, do: DateTime.utc_now() |> DateTime.to_iso8601()

  defp random_id(prefix),
    do: prefix <> "_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)

  defp encode!(value), do: Jason.encode!(value, pretty: true)

  defp error(kind, message, details),
    do: %{ok: false, error: %{kind: kind, message: message, details: details}}
end
