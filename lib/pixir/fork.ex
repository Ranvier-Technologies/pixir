defmodule Pixir.Fork do
  @moduledoc """
  Inter-Session fork planning and execution (ADR 0024).

  A fork creates a new child Session Log by replaying a prefix of a parent Session's
  canonical History. The parent Log is never mutated.
  """

  alias Pixir.{BranchSummary, Event, Log, Session, SessionId, SessionResources, Subagents, Tool}

  @strategy "replay_v1"

  @replay_types ~w(
    user_message assistant_message reasoning skill_activation subagent_event workflow_event
    tool_call tool_result permission_decision
  )a

  @doc "Plan a fork without writing the child Log."
  @spec dry_run(String.t(), keyword()) :: {:ok, map()} | {:error, map()}
  def dry_run(parent_session_id, opts \\ []) do
    plan(parent_session_id, Keyword.put(opts, :dry_run, true))
  end

  @doc "Create a child Session Log from a parent prefix."
  @spec fork(String.t(), keyword()) :: {:ok, map()} | {:error, map()}
  def fork(parent_session_id, opts \\ []) do
    workspace = workspace(opts)

    with {:ok, plan} <- plan(parent_session_id, opts),
         {:ok, child_session_id} <- write_child_log(plan, workspace, opts) do
      {:ok,
       plan
       |> Map.put("recorded", true)
       |> Map.put("child_session_id", child_session_id)
       |> Map.put("resume_command", resume_command(child_session_id))}
    end
  end

  @doc "Build a fork plan for CLI dry-run and execution."
  @spec plan(String.t(), keyword()) :: {:ok, map()} | {:error, map()}
  def plan(parent_session_id, opts \\ [])

  def plan(parent_session_id, opts) do
    with :ok <- SessionId.validate(parent_session_id) do
      do_plan(parent_session_id, opts)
    end
  end

  defp do_plan(parent_session_id, opts) do
    workspace = workspace(opts)
    summarize? = Keyword.get(opts, :summarize, false)
    child_session_id = Keyword.get_lazy(opts, :child_session_id, &Session.gen_id/0)

    with :ok <- SessionId.validate(child_session_id),
         {:ok, to_seq} <- resolve_to_seq(parent_session_id, workspace, opts),
         {:ok, history} <- Log.fold(parent_session_id, workspace: workspace),
         :ok <- ensure_parent_history(history, parent_session_id, workspace),
         replay_events <- {:ok, select_replay_events(history, to_seq)},
         {:ok, replay_events} <- replay_events,
         fork_root = fork_root_session_id(history, parent_session_id) do
      {:ok,
       %{
         "ok" => true,
         "recorded" => false,
         "dry_run" => Keyword.get(opts, :dry_run, false),
         "parent_session_id" => parent_session_id,
         "child_session_id" => child_session_id,
         "fork_root_session_id" => fork_root,
         "from_seq" => first_seq(replay_events),
         "to_seq" => to_seq,
         "event_count" => length(replay_events),
         "workspace" => workspace,
         "parent_log_path" => Log.path(parent_session_id, workspace: workspace),
         "child_log_path" => Log.path(child_session_id, workspace: workspace),
         "summarize" => summarize?,
         "would_record_branch_summary" => summarize?,
         "branch_summary_strategy" => branch_summary_strategy(summarize?),
         "strategy" => @strategy,
         "resume_command" => resume_command(child_session_id)
       }}
    end
  end

  @doc "Canonical event types copied into a child fork Log."
  @spec replay_types() :: [atom()]
  def replay_types, do: @replay_types

  @doc """
  Resolve the fork-tree root Session id for Provider cache-family routing (ADR 0020).

  Returns the root from the first `session_fork` Event when present; otherwise
  `session_id` (a non-fork Session is its own root).
  """
  @spec fork_root_session_id([Event.t()], String.t()) :: String.t()
  def fork_root_session_id(history, session_id) when is_list(history) and is_binary(session_id) do
    case Enum.find(history, &(&1.type == :session_fork)) do
      %{data: %{"fork_root_session_id" => root}} when is_binary(root) and root != "" ->
        root

      _ ->
        session_id
    end
  end

  defp write_child_log(plan, workspace, opts) do
    child_session_id = plan["child_session_id"]

    case Log.exists(child_session_id, workspace: workspace) do
      {:ok, true} ->
        {:error,
         Tool.error(:already_exists, "child session log already exists", %{
           child_session_id: child_session_id,
           log_path: plan["child_log_path"],
           next_actions: ["pick a new child session id", "remove the existing log if safe"]
         })}

      {:ok, false} ->
        with {:ok, events} <- build_child_events(child_session_id, plan, workspace),
             {:ok, _written} <-
               SessionResources.with_copied_resources(
                 plan["parent_session_id"],
                 child_session_id,
                 events,
                 resource_copy_opts(opts, workspace),
                 fn -> create_child_session(child_session_id, events, workspace, opts) end
               ) do
          {:ok, child_session_id}
        end

      {:error, _error} = error ->
        error
    end
  end

  defp resource_copy_opts(opts, workspace) do
    [parent_workspace: workspace, child_workspace: workspace]
    |> Keyword.merge(Keyword.take(opts, [:resource_copy_failpoint]))
  end

  # Test injection is confined to the atomic Log-create call and never enters Events.
  defp create_child_session(child_session_id, events, workspace, opts) do
    case Keyword.get(opts, :log_create_fun, &Log.create_session/3) do
      create when is_function(create, 3) ->
        create.(child_session_id, events, workspace: workspace)

      _other ->
        {:error,
         Tool.error(:invalid_args, "log_create_fun must be a three-arity function", %{
           expected_arity: 3
         })}
    end
  end

  defp build_child_events(child_session_id, plan, workspace) do
    parent_session_id = plan["parent_session_id"]

    with {:ok, history} <- Log.fold(parent_session_id, workspace: workspace) do
      source_events = select_replay_events(history, plan["to_seq"])

      replayed =
        source_events
        |> Enum.with_index(1)
        |> Enum.map(fn {event, seq} ->
          %{
            event
            | id: Event.new(child_session_id, event.type, event.data).id,
              session_id: child_session_id,
              seq: seq
          }
          |> Event.with_seq(seq)
        end)

      warm_lineage =
        inherited_warm_lineage(parent_session_id, workspace, source_events, replayed)

      fork_data =
        %{
          "parent_session_id" => plan["parent_session_id"],
          "fork_root_session_id" => plan["fork_root_session_id"],
          "forked_to_seq" => plan["to_seq"],
          "parent_workspace" => plan["workspace"],
          "child_workspace" => plan["workspace"],
          "replay_event_count" => plan["event_count"],
          "from_seq" => plan["from_seq"],
          "strategy" => @strategy,
          "limitations" => [
            "full replayed prefix remains authoritative; session_fork is lineage metadata only"
          ]
        }
        |> maybe_put_warm_lineage(warm_lineage)

      fork_event =
        child_session_id
        |> Event.session_fork(fork_data)
        |> Event.with_seq(0)

      events = [fork_event | replayed]

      {:ok,
       if plan["summarize"] do
         summary_seq = length(replayed) + 1

         summary_event =
           replayed
           |> BranchSummary.event_data(plan)
           |> then(&Event.branch_summary(child_session_id, &1))
           |> Event.with_seq(summary_seq)

         events ++ [summary_event]
       else
         events
       end}
    end
  end

  defp inherited_warm_lineage(parent_session_id, workspace, source_events, replayed) do
    with {:ok, proof} <- Subagents.warm_lineage_proof(parent_session_id, workspace: workspace),
         boundary_source_index when is_integer(boundary_source_index) <-
           Enum.find_index(source_events, &(&1 == proof.boundary_event)),
         %{id: _boundary_id} = boundary <- Enum.at(replayed, boundary_source_index) do
      posture_source_index = Enum.find_index(source_events, &(&1 == proof.posture_event))

      posture =
        if posture_source_index == boundary_source_index + 1 do
          Enum.at(replayed, posture_source_index)
        end

      %{
        "version" => 1,
        "boundary_event_id" => boundary.id,
        "posture_event_id" => posture && posture.id,
        "boundary_index" => boundary_source_index + 1,
        "posture_index" => boundary_source_index + 2,
        "seed_session_id" => proof.seed_session_id,
        "fork_root_session_id" => proof.fork_root_session_id,
        "replay_event_count" => proof.replay_event_count
      }
    else
      _no_trusted_or_selected_segment -> nil
    end
  end

  defp maybe_put_warm_lineage(data, nil), do: data
  defp maybe_put_warm_lineage(data, warm_lineage), do: Map.put(data, "warm_lineage", warm_lineage)

  defp branch_summary_strategy(true), do: BranchSummary.strategy()
  defp branch_summary_strategy(false), do: nil

  defp resolve_to_seq(parent_session_id, workspace, opts) do
    case Keyword.get(opts, :to_seq) do
      nil ->
        with {:ok, history} <- Log.fold(parent_session_id, workspace: workspace),
             :ok <- ensure_parent_history(history, parent_session_id, workspace) do
          {:ok, default_to_seq(history)}
        end

      to_seq when is_integer(to_seq) and to_seq >= 0 ->
        {:ok, to_seq}

      other ->
        {:error,
         Tool.error(:invalid_args, "to_seq must be a non-negative integer", %{
           to_seq: other,
           next_actions: [
             "omit --to-seq to fork the full replayable prefix",
             "pass a non-negative integer such as --to-seq 5"
           ]
         })}
    end
  end

  defp ensure_parent_history([], parent_session_id, workspace) do
    {:error,
     Tool.error(:not_found, "parent session log was not found or is empty", %{
       parent_session_id: parent_session_id,
       log_path: Log.path(parent_session_id, workspace: workspace),
       next_actions: [
         "check the session id",
         "run pixir fork from the workspace that owns the parent log"
       ]
     })}
  end

  defp ensure_parent_history(_history, _parent_session_id, _workspace), do: :ok

  defp select_replay_events(history, to_seq) do
    history
    |> Enum.filter(fn event ->
      event.type in @replay_types and is_integer(event.seq) and event.seq <= to_seq
    end)
    |> Enum.sort_by(& &1.seq)
  end

  defp default_to_seq(history) do
    history
    |> Enum.filter(&(&1.type in @replay_types and is_integer(&1.seq)))
    |> Enum.map(& &1.seq)
    |> case do
      [] -> 0
      seqs -> Enum.max(seqs)
    end
  end

  defp first_seq([]), do: nil
  defp first_seq(events), do: events |> List.first() |> Map.fetch!(:seq)

  defp resume_command(child_session_id), do: "pixir resume #{child_session_id} \"...\""

  defp workspace(opts),
    do: opts |> Keyword.get(:workspace, File.cwd!()) |> Path.expand()
end
