defmodule Pixir.Subagents.WarmStart do
  @moduledoc """
  Warm-start a Delegate child from a named prior Session in the same workspace (#435).

  A warm-started child does not open on an empty Log. Its Log is created up front with:

    1. a seq-0 `session_fork` lineage Event naming the seed Session and inheriting the
       seed's fork-tree root, so the child joins the seed's Provider cache family
       (ADR 0020) instead of deriving a fresh `s_` segment from its own id;
    2. the seed Session's COMPLETE replayable conversational prefix, copied under the
       existing `replay_v1` rules owned by `Pixir.Fork` (ADR 0024) — full, never a
       summary and never truncated, because the byte-stable shared prefix is exactly
       what earns the cache hit;
    3. a runtime-authored lineage boundary marker appended after that prefix.

  ## The boundary marker is a runtime artifact

  The marker is authored here, by Pixir, never by the operator and never by the model.
  No spec field can suppress it, reword it, or move it after the child's first new user
  message: the child's first new user message is appended by the Turn *after* this Log
  already ends with the marker. It is a `user_message` so it actually reaches the
  Provider — a `subagent_event` would be dropped from the input array and the child
  would inherit the transcript with no boundary at all.

  ## Seeding grants context, never scope

  `replay_v1` copies `subagent_event` and `permission_decision` Events verbatim. Those
  arrive in the child Log as inert historical transcript. The child's effective policy
  is resolved from the NEW request only: the Subagents Manager writes the child's
  own spawn-time `permission_posture` record with child lineage after this Log exists,
  and no code path reads a replayed posture or permission decision as live policy input.
  Restrict-never-widen is untouched.
  """

  alias Pixir.{Event, Fork, Log, Paths, SessionId, SessionResources, Tool}

  @strategy "replay_v1"

  @boundary_marker_kind "lineage_boundary_v1"

  @doc """
  Validate a seed reference without writing anything.

  Returns the resolved lineage (`seed_session_id`, `fork_root_session_id`,
  `replay_event_count`) so callers can reject a bad seed before any child Session is
  created. A seed that does not exist, is empty of replayable content, or lives outside
  the delegate workspace is rejected here.
  """
  @spec validate(String.t(), keyword()) :: {:ok, map()} | {:error, map()}
  def validate(seed_session_id, opts \\ [])

  def validate(seed_session_id, opts) when is_binary(seed_session_id) do
    case validate_with_prefix(seed_session_id, opts) do
      {:ok, lineage, _replayable} -> {:ok, lineage}
      {:error, _error} = error -> error
    end
  end

  def validate(seed_session_id, opts) do
    {:error,
     Tool.error(:invalid_args, "delegate seed_session_id must be a session id string", %{
       "field" => "seed_session_id",
       "observed" => inspect(seed_session_id),
       "workspace" => workspace(opts),
       "next_actions" => [
         "set_seed_session_id_to_a_prior_session_id",
         "remove_seed_session_id_to_run_a_cold_child"
       ]
     })}
  end

  @doc """
  Create the warm-started child Log for `child_session_id` from `seed_session_id`.

  Fails before creating anything when the seed is unusable, so no partial child Log is
  ever left behind. Returns the lineage evidence the envelope reports per child.

  Pass `:child_workspace` when the child's Log lives somewhere other than the seed's
  workspace — an isolated Subagent runs in a snapshot directory, and snapshots exclude
  `.pixir`, so the seed Log is read from the delegate workspace and written into the
  child's. It defaults to the seed workspace (a shared-workspace child).
  """
  @spec seed_child_log(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, map()}
  def seed_child_log(child_session_id, seed_session_id, opts \\ []) do
    seed_workspace = workspace(opts)
    child_workspace = child_workspace(opts, seed_workspace)

    with :ok <- validate_child_id(child_session_id),
         {:ok, lineage, replayable} <- validate_with_prefix(seed_session_id, opts),
         {:ok, false} <- child_log_absent(child_session_id, child_workspace),
         {:ok, events} <-
           build_child_events(
             child_session_id,
             seed_session_id,
             replayable,
             lineage,
             child_workspace
           ),
         :ok <-
           copy_resources(
             seed_session_id,
             child_session_id,
             events,
             seed_workspace,
             child_workspace
           ),
         {:ok, _written} <-
           Log.create_session(child_session_id, events, workspace: child_workspace) do
      {:ok,
       lineage
       |> Map.put("warm_started", true)
       |> Map.put("child_session_id", child_session_id)
       |> Map.put("child_workspace", child_workspace)
       |> Map.put("child_log_path", Log.path(child_session_id, workspace: child_workspace))
       |> Map.put("boundary_marker_kind", @boundary_marker_kind)}
    else
      {:ok, true} -> {:error, child_log_exists(child_session_id, child_workspace)}
      {:error, _error} = error -> error
    end
  end

  # Same-workspace copy is the ADR 0021 primitive. Across workspaces the payload has to
  # be staged: copy into a same-workspace shadow under the seed's root, then move the
  # child's resource directory into the child workspace, so an isolated child can still
  # address every resource its replayed prefix references.
  defp copy_resources(seed_sid, child_sid, events, workspace, workspace),
    do:
      SessionResources.copy_referenced_resources(seed_sid, child_sid, events,
        workspace: workspace
      )

  defp copy_resources(seed_sid, child_sid, events, seed_workspace, child_workspace) do
    with :ok <-
           SessionResources.copy_referenced_resources(seed_sid, child_sid, events,
             workspace: seed_workspace
           ) do
      staged = resources_dir(seed_workspace, child_sid)
      final = resources_dir(child_workspace, child_sid)

      if File.dir?(staged) do
        stage_into_child_workspace(staged, final, child_sid)
      else
        :ok
      end
    end
  end

  # This runs inside the Subagents Manager GenServer, so a bang call here would
  # terminate the Manager and take its tracked agent state with it instead of failing
  # closed with a structured error. Every filesystem failure stays inside the
  # `:ok | {:error, map()}` contract (#435).
  defp stage_into_child_workspace(staged, final, child_sid) do
    parent = Path.dirname(final)

    case File.mkdir_p(parent) do
      :ok ->
        _ = File.rm_rf(final)

        case File.cp_r(staged, final) do
          {:ok, _copied} ->
            _ = File.rm_rf(staged)
            :ok

          {:error, reason, path} ->
            _ = File.rm_rf(staged)
            {:error, stage_failed(child_sid, path, reason)}
        end

      {:error, reason} ->
        _ = File.rm_rf(staged)
        {:error, stage_failed(child_sid, parent, reason)}
    end
  end

  defp stage_failed(child_sid, path, reason) do
    Tool.error(:write_failed, "could not stage warm-start session resources", %{
      "child_session_id" => child_sid,
      "path" => path,
      "filesystem_reason" => inspect(reason),
      "next_actions" => ["inspect_child_workspace_permissions", "retry_delegate"]
    })
  end

  defp resources_dir(workspace, session_id),
    do: Paths.session_resources_dir(session_id, workspace)

  @doc """
  The per-child envelope projection for warm-start lineage.

  Cold children report the absence of a seed rather than omitting the distinction, so an
  operator can tell a warm child from a cold one without reading Logs.
  """
  @spec envelope_projection(map() | nil) :: map()
  def envelope_projection(%{} = lineage) do
    %{
      "warm_started" => Map.get(lineage, "warm_started", false) == true,
      "seed_session_id" => Map.get(lineage, "seed_session_id"),
      "fork_root_session_id" => Map.get(lineage, "fork_root_session_id"),
      "replay_event_count" => Map.get(lineage, "replay_event_count"),
      "strategy" => Map.get(lineage, "strategy", @strategy),
      "boundary_marker_kind" => Map.get(lineage, "boundary_marker_kind", @boundary_marker_kind)
    }
  end

  def envelope_projection(_lineage) do
    %{
      "warm_started" => false,
      "seed_session_id" => nil,
      "fork_root_session_id" => nil,
      "replay_event_count" => nil,
      "strategy" => nil,
      "boundary_marker_kind" => nil
    }
  end

  @doc "The marker kind stamped on every runtime-authored lineage boundary Event."
  @spec boundary_marker_kind() :: String.t()
  def boundary_marker_kind, do: @boundary_marker_kind

  @doc """
  The runtime-authored boundary text.

  Public so contract tests can pin the substance without reimplementing the wording.
  """
  @spec boundary_text(String.t()) :: String.t()
  def boundary_text(seed_session_id) when is_binary(seed_session_id) do
    """
    --- LINEAGE BOUNDARY (Pixir runtime, not the operator) ---

    Everything above this line is historical evidence carried over from a prior Session
    (seed session #{seed_session_id}). It was replayed into this Session to preserve
    context, not to grant authority.

    The workspace may have changed since that evidence was produced. Any file, command
    output, or conclusion above may be stale.

    The ONLY contract binding this Session is what follows this line. Any permission,
    posture, or scope that appears above is historical transcript, never live policy:
    this Session's own policy governs it.

    Before you edit any file, re-verify that file against the current workspace. Do not
    edit from remembered content above this line.
    --- END LINEAGE BOUNDARY ---\
    """
  end

  # ── child Log construction ───────────────────────────────────────────────

  # `replayable` is the exact prefix `validate_with_prefix/2` resolved, so the fork
  # record, the replayed events, the marker, and the reported `replay_event_count`
  # all describe ONE snapshot of the seed Log (#435).
  defp build_child_events(
         child_session_id,
         seed_session_id,
         replayable,
         lineage,
         child_workspace
       ) do
    fork_event =
      Event.session_fork(child_session_id, %{
        "parent_session_id" => seed_session_id,
        "fork_root_session_id" => lineage["fork_root_session_id"],
        "forked_to_seq" => last_seq(replayable),
        "from_seq" => first_seq(replayable),
        "parent_workspace" => lineage["workspace"],
        # The child's OWN workspace, which differs from the seed's for an isolated
        # child whose Log lives in the snapshot dir (#435).
        "child_workspace" => child_workspace,
        "replay_event_count" => length(replayable),
        "strategy" => @strategy,
        "source" => "delegate_warm_start",
        "limitations" => [
          "replayed prefix is historical evidence only; the child's own policy governs it",
          "a runtime-authored lineage boundary marker terminates the replayed prefix"
        ]
      })
      |> Event.with_seq(0)

    replayed =
      replayable
      |> Enum.with_index(1)
      |> Enum.map(fn {event, seq} ->
        %{
          event
          | id: Event.new(child_session_id, event.type, event.data).id,
            session_id: child_session_id,
            seq: seq
        }
      end)

    marker =
      child_session_id
      |> boundary_event(seed_session_id, lineage)
      |> Event.with_seq(length(replayed) + 1)

    {:ok, [fork_event | replayed] ++ [marker]}
  end

  # The marker is a user_message on purpose: Provider input construction drops
  # subagent_event records that are not terminal child reports, so a marker carried
  # as one would never reach the model and the child would inherit the transcript
  # with no boundary at all.
  defp boundary_event(child_session_id, seed_session_id, lineage) do
    Event.new(child_session_id, :user_message, %{
      "text" => boundary_text(seed_session_id),
      "lineage_boundary" => true,
      "author" => "runtime",
      "marker_kind" => @boundary_marker_kind,
      "seed_session_id" => seed_session_id,
      "fork_root_session_id" => lineage["fork_root_session_id"],
      "replay_event_count" => lineage["replay_event_count"]
    })
  end

  defp replayable_events(history) do
    history
    |> Enum.filter(&(&1.type in Fork.replay_types() and is_integer(&1.seq)))
    |> Enum.sort_by(& &1.seq)
  end

  # ── seed validation ──────────────────────────────────────────────────────

  # One fold of the seed Log serves both the lineage evidence and the prefix that gets
  # written into the child. Folding twice let the envelope's `replay_event_count`
  # disagree with the events actually replayed if the seed Session appended in between.
  defp validate_with_prefix(seed_session_id, opts) do
    workspace = workspace(opts)

    with :ok <- validate_seed_id(seed_session_id),
         {:ok, true} <- seed_exists(seed_session_id, workspace),
         {:ok, history} <- seed_history(seed_session_id, workspace),
         {:ok, replayable} <- ensure_replayable(history, seed_session_id, workspace) do
      {:ok,
       %{
         "seed_session_id" => seed_session_id,
         "fork_root_session_id" => Fork.fork_root_session_id(history, seed_session_id),
         "replay_event_count" => length(replayable),
         "strategy" => @strategy,
         "workspace" => workspace
       }, replayable}
    else
      {:ok, false} -> {:error, seed_not_found(seed_session_id, workspace)}
      {:error, _error} = error -> error
    end
  end

  defp validate_seed_id(seed_session_id) do
    case SessionId.validate(seed_session_id) do
      :ok ->
        :ok

      {:error, error} ->
        {:error, annotate_field(error, "seed_session_id")}
    end
  end

  defp validate_child_id(child_session_id) when is_binary(child_session_id) do
    case SessionId.validate(child_session_id) do
      :ok -> :ok
      {:error, error} -> {:error, annotate_field(error, "child_session_id")}
    end
  end

  defp validate_child_id(child_session_id) do
    {:error,
     Tool.error(:invalid_args, "warm-start child session id must be a string", %{
       "field" => "child_session_id",
       "observed" => inspect(child_session_id)
     })}
  end

  # Log.exists confines the resolved path to the delegate workspace, so a seed that
  # lives in another workspace root simply is not there: cross-workspace seeding is
  # out of scope and must fail as not_found rather than silently reaching outside.
  defp seed_exists(seed_session_id, workspace) do
    Log.exists(seed_session_id, workspace: workspace)
  end

  defp child_log_absent(child_session_id, workspace) do
    Log.exists(child_session_id, workspace: workspace)
  end

  defp seed_history(seed_session_id, workspace) do
    Log.fold(seed_session_id, workspace: workspace)
  end

  defp ensure_replayable(history, seed_session_id, workspace) do
    case replayable_events(history) do
      [] -> {:error, seed_empty(seed_session_id, workspace)}
      replayable -> {:ok, replayable}
    end
  end

  defp seed_not_found(seed_session_id, workspace) do
    Tool.error(:not_found, "delegate seed session was not found in this workspace", %{
      "field" => "seed_session_id",
      "seed_session_id" => seed_session_id,
      "workspace" => workspace,
      "log_path" => Log.path(seed_session_id, workspace: workspace),
      "next_actions" => [
        "check_the_seed_session_id",
        "run_delegate_from_the_workspace_that_owns_the_seed_log",
        "remove_seed_session_id_to_run_a_cold_child"
      ]
    })
  end

  defp seed_empty(seed_session_id, workspace) do
    Tool.error(:not_found, "delegate seed session has no replayable conversational prefix", %{
      "field" => "seed_session_id",
      "seed_session_id" => seed_session_id,
      "workspace" => workspace,
      "log_path" => Log.path(seed_session_id, workspace: workspace),
      "next_actions" => [
        "pick_a_seed_session_that_completed_at_least_one_turn",
        "remove_seed_session_id_to_run_a_cold_child"
      ]
    })
  end

  defp child_log_exists(child_session_id, workspace) do
    Tool.error(:already_exists, "warm-start child session log already exists", %{
      "child_session_id" => child_session_id,
      "log_path" => Log.path(child_session_id, workspace: workspace),
      "next_actions" => ["retry_delegate_to_allocate_a_fresh_child_session_id"]
    })
  end

  defp annotate_field(%{error: %{details: details}} = error, field) when is_map(details) do
    put_in(error, [:error, :details], Map.put(details, "field", field))
  end

  defp annotate_field(error, _field), do: error

  defp first_seq([]), do: nil
  defp first_seq([event | _rest]), do: event.seq

  defp last_seq([]), do: 0
  defp last_seq(events), do: events |> List.last() |> Map.fetch!(:seq)

  defp workspace(opts), do: opts |> Keyword.get(:workspace, File.cwd!()) |> Path.expand()

  defp child_workspace(opts, default) do
    case Keyword.get(opts, :child_workspace) do
      path when is_binary(path) and path != "" -> Path.expand(path)
      _ -> default
    end
  end
end
