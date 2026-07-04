defmodule Pixir.Delegate.Evidence do
  @moduledoc """
  Delegate audit-evidence metadata and mirror helpers.

  The Session Log remains Pixir's source of truth. This module adds a narrow
  survivability layer for Delegate executor use: when a write-capable Delegate starts
  and reaches terminal/reportable states, Pixir mirrors available parent and child
  Session Logs plus a small metadata file under the user-global Pixir root. That mirror
  is not a second result store; it is an out-of-workspace audit-preservation copy so an
  executor does not depend only on workspace-local `.pixir` for proof.

  Path blocking in `Pixir.Tools.Executor` is still useful defense in depth. The stronger
  guarantee here is that a bounded-write Delegate can report where durable evidence also
  lives outside the delegated workspace write scope. This is not a shell sandbox:
  user-global Pixir state is local filesystem state and should be treated as audit
  preservation, not containment against an arbitrary host process.
  """

  alias Pixir.{Log, Paths}

  @schema_version 1
  @metadata_filename "evidence.json"

  @doc "Attach current Delegate evidence-location metadata to a result payload."
  @spec annotate_payload(map()) :: {:ok, map()} | {:error, map()}
  def annotate_payload(payload) when is_map(payload),
    do: attach_evidence(payload, refresh?: false)

  def annotate_payload(_payload) do
    {:error,
     %{
       "ok" => false,
       "status" => "rejected",
       "kind" => "invalid_delegate_evidence_payload",
       "message" => "delegate evidence payload must be a map",
       "details" => %{}
     }}
  end

  @doc """
  Refresh Delegate evidence mirror state, then attach evidence metadata to the payload.

  This function is intentionally lifecycle-safe: callers may invoke it at Delegate start,
  after child spawn, terminal completion, and final render. Existing mirror logs are only
  replaced by same-size-or-larger source logs; if a workspace-local source regresses, the
  older mirror is retained and the regression is reported in metadata.
  """
  @spec refresh_payload(map()) :: {:ok, map()} | {:error, map()}
  def refresh_payload(payload) when is_map(payload), do: attach_evidence(payload, refresh?: true)

  def refresh_payload(payload), do: annotate_payload(payload)

  defp attach_evidence(payload, opts) do
    case evidence_from_payload(payload, opts) do
      nil ->
        {:ok, payload}

      evidence ->
        payload =
          payload
          |> Map.put("evidence", merge_evidence(payload["evidence"], evidence))
          |> put_diagnostics_evidence(evidence)

        {:ok, payload}
    end
  end

  defp evidence_from_payload(payload, opts) do
    with session_id when is_binary(session_id) and session_id != "" <-
           payload["session_id"] || payload["parent_session_id"],
         delegate_id when is_binary(delegate_id) and delegate_id != "" <- payload["delegate_id"],
         workspace when is_binary(workspace) and workspace != "" <- payload["workspace"] do
      workspace = Path.expand(workspace)
      local_log_path = Log.path(session_id, workspace: workspace)
      mirror_requirement = mirror_requirement(payload)

      %{
        "schema_version" => @schema_version,
        "kind" => "delegate_evidence",
        "source_of_truth" => "session_log",
        "delegate_id" => delegate_id,
        "session_id" => session_id,
        "workspace" => workspace,
        "workspace_project_state_dir" => Paths.project_root(workspace),
        "workspace_log_path" => local_log_path,
        "workspace_log_exists" => File.exists?(local_log_path),
        "guarantee" => %{
          "primary" => "out_of_workspace_audit_preservation_for_write_capable_delegate_runs",
          "path_blocking" => "defense_in_depth_not_a_shell_sandbox",
          "truth_model" => "mirror_is_audit_preservation_copy_session_log_remains_truth"
        },
        "mirror" =>
          mirror(
            session_id,
            delegate_id,
            workspace,
            local_log_path,
            payload,
            opts,
            mirror_requirement
          )
      }
    else
      _missing_identity -> nil
    end
  end

  defp mirror_requirement(payload) do
    mode =
      payload["mode"] ||
        get_in(payload, ["limits", "mode"]) ||
        get_in(payload, ["write_policy", "mode"])

    cond do
      mode == "bounded_write" -> true
      mode in [nil, ""] -> :unknown
      true -> false
    end
  end

  defp mirror(_session_id, _delegate_id, _workspace, _local_log_path, _payload, _opts, false) do
    %{
      "required" => false,
      "status" => "not_required",
      "reason_code" => "read_only_or_unknown_mode",
      "blast_radius" => "workspace_local_only"
    }
  end

  defp mirror(session_id, delegate_id, workspace, local_log_path, payload, _opts, :unknown) do
    root = delegate_root(workspace, delegate_id)
    metadata_path = Path.join(root, @metadata_filename)
    logs = log_specs(session_id, workspace, local_log_path, payload)

    if File.exists?(metadata_path) do
      mirror_report(root, metadata_path, workspace, logs)
    else
      %{
        "required" => nil,
        "status" => "unknown_mode",
        "reason_code" => "delegate_mode_not_available_in_snapshot",
        "kind" => "user_global_delegate_evidence_mirror",
        "root" => root,
        "metadata_path" => metadata_path,
        "project_hash" => workspace_hash(workspace),
        "outside_workspace" => outside_workspace?(root, workspace),
        "outside_workspace_write_scope" => outside_workspace?(root, workspace),
        "blast_radius" => "unknown_without_delegate_mode"
      }
    end
  rescue
    exception -> mirror_failed_payload(Paths.global_root(), nil, workspace, [], exception)
  end

  defp mirror(session_id, delegate_id, workspace, local_log_path, payload, opts, true) do
    root = delegate_root(workspace, delegate_id)
    sessions_dir = Path.join(root, "sessions")
    metadata_path = Path.join(root, @metadata_filename)
    logs = log_specs(session_id, workspace, local_log_path, payload)

    if Keyword.fetch!(opts, :refresh?) do
      refresh_mirror(
        root,
        sessions_dir,
        metadata_path,
        workspace,
        delegate_id,
        session_id,
        payload,
        logs
      )
    else
      mirror_report(root, metadata_path, workspace, logs)
    end
  end

  defp refresh_mirror(
         root,
         sessions_dir,
         metadata_path,
         workspace,
         delegate_id,
         session_id,
         payload,
         logs
       ) do
    try do
      File.mkdir_p!(sessions_dir)

      copies =
        Enum.map(logs, fn log ->
          copy_log(log, sessions_dir)
        end)

      status = aggregate_status(copies)

      metadata = %{
        "schema_version" => @schema_version,
        "kind" => "delegate_evidence_mirror",
        "role" => "audit_preservation_copy",
        "delegate_id" => delegate_id,
        "session_id" => session_id,
        "workspace" => workspace,
        "workspace_project_state_dir" => Paths.project_root(workspace),
        "mirror_root" => root,
        "metadata_path" => metadata_path,
        "status" => status,
        "updated_at" => now(),
        "truth_model" => "session_log_remains_canonical",
        "logs" => copies,
        "result_envelope" => result_envelope(payload)
      }

      write_json_atomic!(metadata_path, metadata)
      mirror_payload(root, metadata_path, workspace, copies, status)
    rescue
      exception ->
        mirror_failed_payload(root, metadata_path, workspace, copies_from_specs(logs), exception)
    end
  end

  defp mirror_report(root, metadata_path, workspace, logs) do
    copies =
      case File.read(metadata_path) do
        {:ok, bytes} ->
          bytes
          |> Jason.decode!()
          |> Map.get("logs", copies_from_specs(logs))

        {:error, _} ->
          copies_from_specs(logs)
      end

    status = metadata_status(metadata_path)

    mirror_payload(root, metadata_path, workspace, copies, status)
  rescue
    exception ->
      mirror_failed_payload(root, metadata_path, workspace, copies_from_specs(logs), exception)
  end

  defp copy_log(log, sessions_dir) do
    destination = Path.join(sessions_dir, safe_id(log.session_id) <> ".ndjson")

    cond do
      not File.exists?(log.source_path) and File.exists?(destination) ->
        existing = File.stat!(destination)

        %{
          "role" => log.role,
          "session_id" => log.session_id,
          "source_path" => log.source_path,
          "log_copy_path" => destination,
          "status" => "source_missing_mirror_retained",
          "mirror_bytes" => existing.size
        }

      not File.exists?(log.source_path) ->
        %{
          "role" => log.role,
          "session_id" => log.session_id,
          "source_path" => log.source_path,
          "log_copy_path" => destination,
          "status" => "pending_source_log"
        }

      mirror_regressed?(log.source_path, destination) ->
        source = File.stat!(log.source_path)
        existing = File.stat!(destination)

        %{
          "role" => log.role,
          "session_id" => log.session_id,
          "source_path" => log.source_path,
          "log_copy_path" => destination,
          "status" => "source_regressed_mirror_retained",
          "source_bytes" => source.size,
          "mirror_bytes" => existing.size,
          "source_sha256" => file_sha256(log.source_path)
        }

      mirror_diverged?(log.source_path, destination) ->
        source = File.stat!(log.source_path)
        existing = File.stat!(destination)

        %{
          "role" => log.role,
          "session_id" => log.session_id,
          "source_path" => log.source_path,
          "log_copy_path" => destination,
          "status" => "source_diverged_mirror_retained",
          "source_bytes" => source.size,
          "mirror_bytes" => existing.size,
          "source_sha256" => file_sha256(log.source_path),
          "mirror_sha256" => file_sha256(destination)
        }

      true ->
        copy_atomic!(log.source_path, destination)
        source = File.stat!(log.source_path)

        %{
          "role" => log.role,
          "session_id" => log.session_id,
          "source_path" => log.source_path,
          "log_copy_path" => destination,
          "status" => "mirrored",
          "source_bytes" => source.size,
          "mirror_bytes" => File.stat!(destination).size,
          "source_sha256" => file_sha256(log.source_path),
          "copied_at" => now()
        }
    end
  end

  defp mirror_regressed?(source_path, destination) do
    with true <- File.exists?(destination),
         {:ok, source} <- File.stat(source_path),
         {:ok, mirror} <- File.stat(destination) do
      source.size < mirror.size
    else
      _ -> false
    end
  end

  defp mirror_diverged?(source_path, destination) do
    with true <- File.exists?(destination),
         {:ok, mirror} <- File.read(destination),
         {:ok, source} <- File.open(source_path, [:read, :binary]) do
      try do
        IO.binread(source, byte_size(mirror)) != mirror
      after
        File.close(source)
      end
    else
      _ -> false
    end
  end

  defp copy_atomic!(source, destination) do
    tmp = destination <> ".tmp-" <> Integer.to_string(System.unique_integer([:positive]))

    try do
      File.cp!(source, tmp)
      File.rename!(tmp, destination)
    after
      File.rm(tmp)
    end
  end

  defp write_json_atomic!(path, map) do
    tmp = path <> ".tmp-" <> Integer.to_string(System.unique_integer([:positive]))

    try do
      File.write!(tmp, Jason.encode!(map, pretty: true))
      File.rename!(tmp, path)
    after
      File.rm(tmp)
    end
  end

  defp file_sha256(path) do
    path
    |> File.stream!(65_536, [:read, :binary])
    |> Enum.reduce(:crypto.hash_init(:sha256), fn chunk, context ->
      :crypto.hash_update(context, chunk)
    end)
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end

  defp aggregate_status(copies) do
    statuses = Enum.map(copies, & &1["status"])

    cond do
      Enum.any?(statuses, &(&1 == "mirror_failed")) ->
        "mirror_failed"

      Enum.any?(statuses, &(&1 == "source_regressed_mirror_retained")) ->
        "source_regressed_mirror_retained"

      Enum.any?(statuses, &(&1 == "source_diverged_mirror_retained")) ->
        "source_diverged_mirror_retained"

      Enum.all?(statuses, &(&1 == "pending_source_log")) ->
        "pending_source_log"

      Enum.any?(statuses, &(&1 in ["pending_source_log", "source_missing_mirror_retained"])) ->
        "partial_mirror"

      Enum.all?(statuses, &(&1 == "mirrored")) ->
        "mirrored"

      true ->
        "partial_mirror"
    end
  end

  defp mirror_payload(root, metadata_path, workspace, copies, status) do
    parent = Enum.find(copies, &(&1["role"] == "parent")) || %{}
    child_copies = Enum.filter(copies, &(&1["role"] == "child"))

    %{
      "required" => true,
      "status" => status,
      "kind" => "user_global_delegate_evidence_mirror",
      "role" => "audit_preservation_copy",
      "root" => root,
      "session_log_path" => parent["log_copy_path"],
      "log_copy_path" => parent["log_copy_path"],
      "metadata_path" => metadata_path,
      "project_hash" => workspace_hash(workspace),
      "outside_workspace" => outside_workspace?(root, workspace),
      "outside_workspace_write_scope" => outside_workspace?(root, workspace),
      "blast_radius" => "outside_workspace_write_scope",
      "parent_log" => parent,
      "child_logs" => child_copies,
      "child_log_count" => length(child_copies)
    }
  end

  defp metadata_status(metadata_path) do
    case File.read(metadata_path) do
      {:ok, bytes} ->
        bytes
        |> Jason.decode!()
        |> Map.get("status", "reported")

      {:error, _} ->
        "not_initialized"
    end
  rescue
    _ -> "reported"
  end

  defp mirror_failed_payload(root, metadata_path, workspace, copies, exception) do
    %{
      "required" => true,
      "status" => "mirror_failed",
      "kind" => "user_global_delegate_evidence_mirror",
      "role" => "audit_preservation_copy",
      "root" => root,
      "session_log_path" => parent_copy_path(copies),
      "log_copy_path" => parent_copy_path(copies),
      "metadata_path" => metadata_path,
      "project_hash" => workspace_hash(workspace),
      "outside_workspace" => outside_workspace?(root, workspace),
      "outside_workspace_write_scope" => outside_workspace?(root, workspace),
      "error" => %{
        "kind" => "delegate_evidence_mirror_failed",
        "message" => Exception.message(exception)
      },
      "blast_radius" => "outside_workspace_write_scope"
    }
  end

  defp parent_copy_path(copies) do
    copies
    |> Enum.find(&(&1["role"] == "parent"))
    |> case do
      nil -> nil
      copy -> copy["log_copy_path"]
    end
  end

  defp copies_from_specs(logs) do
    Enum.map(logs, fn log ->
      %{
        "role" => log.role,
        "session_id" => log.session_id,
        "source_path" => log.source_path,
        "log_copy_path" =>
          Path.join(
            delegate_sessions_dir(log.workspace, log.delegate_id),
            safe_id(log.session_id) <> ".ndjson"
          ),
        "status" => "not_copied"
      }
    end)
  end

  defp log_specs(parent_session_id, workspace, local_log_path, payload) do
    parent = %{
      role: "parent",
      delegate_id: payload["delegate_id"],
      workspace: workspace,
      session_id: parent_session_id,
      source_path: local_log_path
    }

    children =
      payload
      |> Map.get("children", [])
      |> Enum.flat_map(&child_log_spec(&1, workspace, payload["delegate_id"]))

    [parent | children]
    |> Enum.uniq_by(&{&1.role, &1.session_id})
  end

  defp child_log_spec(%{"child_session_id" => session_id} = child, workspace, delegate_id)
       when is_binary(session_id) and session_id != "" do
    source_path =
      case child["child_log_path"] do
        path when is_binary(path) and path != "" -> path
        _ -> Log.path(session_id, workspace: workspace)
      end

    [
      %{
        role: "child",
        delegate_id: delegate_id,
        workspace: workspace,
        session_id: session_id,
        source_path: source_path
      }
    ]
  end

  defp child_log_spec(_child, _workspace, _delegate_id), do: []

  defp result_envelope(payload) do
    Map.take(payload, [
      "status",
      "kind",
      "ok",
      "command_ok",
      "work_complete",
      "outcome",
      "reason_code",
      "counts",
      "exit_code",
      "summary"
    ])
  end

  defp delegate_sessions_dir(workspace, delegate_id) do
    Path.join(delegate_root(workspace, delegate_id), "sessions")
  end

  defp delegate_root(workspace, delegate_id) do
    Path.join([
      Paths.global_root(),
      "projects",
      workspace_hash(workspace),
      "delegates",
      safe_id(delegate_id)
    ])
  end

  defp workspace_hash(workspace) do
    :sha256
    |> :crypto.hash(Path.expand(workspace))
    |> Base.encode16(case: :lower)
    |> binary_part(0, 16)
  end

  defp safe_id(value), do: String.replace(value, ~r/[^A-Za-z0-9_.-]/, "_")

  defp outside_workspace?(path, workspace) do
    path = Path.expand(path)
    workspace = Path.expand(workspace)

    path != workspace and not String.starts_with?(path, workspace <> "/")
  end

  defp merge_evidence(%{} = existing, evidence), do: Map.merge(existing, evidence)
  defp merge_evidence(_existing, evidence), do: evidence

  defp put_diagnostics_evidence(payload, evidence) do
    Map.update(payload, "diagnostics", %{"evidence" => diagnostics_evidence(evidence)}, fn
      %{} = diagnostics -> Map.put(diagnostics, "evidence", diagnostics_evidence(evidence))
      other -> other
    end)
  end

  defp diagnostics_evidence(evidence) do
    %{
      "source_of_truth" => evidence["source_of_truth"],
      "workspace_log_path" => evidence["workspace_log_path"],
      "mirror" =>
        Map.take(evidence["mirror"], [
          "required",
          "status",
          "session_log_path",
          "log_copy_path",
          "metadata_path",
          "child_log_count"
        ])
    }
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
end
