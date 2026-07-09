defmodule Pixir.Subagents.Manager do
  @moduledoc false

  use GenServer

  alias Pixir.{
    Agents,
    Event,
    Events,
    Log,
    Paths,
    Session,
    SessionSupervisor,
    Subagents,
    Subagents.DelegationContext,
    Subagents.Scheduler,
    Subagents.WorkspaceSnapshot,
    Tool,
    Turn,
    WorkspaceStrategy
  }

  alias Pixir.Permissions.WritePolicy
  alias Pixir.Provider.HostedTools

  @server __MODULE__
  @manager_child_event_types ~w(assistant_message status turn_failed)a
  @retry_jitter_ceiling_ms 60_000
  # Erlang timers reject delays above 2^32 - 1 ms (~49.7 days); clamp every
  # Process.send_after delay so an oversized accepted value degrades to the
  # ceiling instead of a badarg crash after durable evidence was recorded.
  @erlang_timer_max_ms 4_294_967_295

  # TODO(service-lifetime): Delegate service mode needs an owner process that can keep
  # live child handles across CLI invocations. Today the Manager can restore durable
  # lifecycle state from Logs, but active cancellation from another OS process cannot
  # reliably close children owned by an attached runner. Preserve this distinction:
  # durable snapshots are truth for `status`; live handles are capability evidence for
  # `cancel`/`attach`, and missing handles must be reported honestly.

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent,
      shutdown: 5_000
    }
  end

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: @server)

  def spawn_agent(parent_session_id, args, opts \\ []) do
    GenServer.call(@server, {:spawn_agent, parent_session_id, args, opts}, 30_000)
  end

  def send_input(parent_session_id, subagent_id, prompt, opts \\ []) do
    GenServer.call(@server, {:send_input, parent_session_id, subagent_id, prompt, opts}, 30_000)
  end

  def wait(parent_session_id, ids, timeout_ms, opts \\ []) do
    timeout_ms = clamp_timer_ms(timeout_ms, @erlang_timer_max_ms - 1_000)

    GenServer.call(@server, {:wait, parent_session_id, ids, timeout_ms, opts}, timeout_ms + 1_000)
  catch
    :exit, {:timeout, _} ->
      {:error, Tool.error(:timeout, "wait_agent timed out", %{timeout_ms: timeout_ms})}
  end

  def wait_outcome(parent_session_id, ids, timeout_ms, opts \\ []) do
    timeout_ms = clamp_timer_ms(timeout_ms, @erlang_timer_max_ms - 1_000)

    GenServer.call(
      @server,
      {:wait_outcome, parent_session_id, ids, timeout_ms, opts},
      timeout_ms + 1_000
    )
  catch
    :exit, {:timeout, _} ->
      {:error, Tool.error(:timeout, "wait_agent timed out", %{timeout_ms: timeout_ms})}
  end

  def close(parent_session_id, subagent_id, opts \\ []) do
    GenServer.call(@server, {:close, parent_session_id, subagent_id, opts}, 30_000)
  end

  def list(parent_session_id, opts \\ []),
    do: GenServer.call(@server, {:list, parent_session_id, opts})

  def diagnostics(parent_session_id, opts \\ []) do
    GenServer.call(@server, {:diagnostics, parent_session_id, opts})
  catch
    :exit, {:noproc, _} ->
      {:error,
       Tool.error(:read_failed, "Subagent Manager runtime snapshot is unavailable", %{
         "parent_session_id" => parent_session_id,
         "next_actions" => ["start_or_restart_pixir", "inspect_application_supervisor"]
       })}

    :exit, {:timeout, _} ->
      {:error,
       Tool.error(:timeout, "Subagent Manager runtime snapshot timed out", %{
         "parent_session_id" => parent_session_id,
         "next_actions" => ["retry_diagnostics", "inspect_subagent_manager_mailbox"]
       })}
  end

  @impl true
  def init(_opts) do
    {:ok, %{parents: %{}, child_to_agent: %{}, waiters: %{}}}
  end

  @impl true
  def handle_call({:spawn_agent, parent_sid, args, opts}, _from, state) do
    with {:ok, spec} <- build_spec(parent_sid, args, opts),
         :ok <- check_depth(spec) do
      state = ensure_parent(state, parent_sid)
      {agent, state} = put_new_agent(state, spec)

      {:ok, can_start?} = Scheduler.can_start?(parent_agents(state, parent_sid), spec.max_threads)

      if can_start? do
        case start_agent(agent, state) do
          {:ok, started, state} -> {:reply, {:ok, public_agent(started)}, state}
          {:error, error, state} -> {:reply, {:error, error}, state}
        end
      else
        state = record_parent_event(state, agent, "queued", "queued")
        {:reply, {:ok, public_agent(agent)}, state}
      end
    else
      {:error, error} -> {:reply, {:error, error}, state}
    end
  end

  def handle_call({:send_input, parent_sid, id, prompt, opts}, _from, state) do
    state = restore_parent(state, parent_sid, opts)

    with {:ok, agent} <- fetch_agent(state, parent_sid, id),
         :ok <- ensure_idle_for_input(agent),
         {:ok, updated, state} <-
           restart_agent(agent, prompt, Keyword.put(opts, :attachments, []), state) do
      {:reply, {:ok, public_agent(updated)}, state}
    else
      {:error, :busy} ->
        {:reply,
         {:error, Tool.error(:permission_denied, "subagent is already running", %{id: id})},
         state}

      {:error, :closed} ->
        {:reply, {:error, Tool.error(:not_found, "subagent is closed", %{id: id})}, state}

      {:error, :detached} ->
        {:reply, {:error, detached_error(id)}, state}

      {:error, error} ->
        {:reply, {:error, error}, state}
    end
  end

  def handle_call({:wait, parent_sid, ids, timeout_ms, opts}, from, state) do
    state = restore_parent(state, parent_sid, opts)
    ids = normalize_ids(ids, state, parent_sid)
    agents = agents_for_ids(state, parent_sid, ids)

    cond do
      ids == [] ->
        {:reply, {:ok, []}, state}

      length(agents) != length(ids) ->
        {:reply,
         {:error, Tool.error(:not_found, "one or more subagents are unknown", %{ids: ids})},
         state}

      Enum.all?(agents, &Subagents.terminal?(&1.status)) ->
        {:reply, {:ok, Enum.map(agents, &public_agent/1)}, state}

      timeout_ms == 0 ->
        {:reply, {:ok, Enum.map(agents, &public_agent/1)}, state}

      true ->
        waiter_id = make_ref()
        timer = Process.send_after(self(), {:wait_timeout, waiter_id}, clamp_timer_ms(timeout_ms))

        waiters =
          Map.put(state.waiters, waiter_id, %{
            from: from,
            parent_sid: parent_sid,
            ids: ids,
            timer_ref: timer,
            mode: :agents,
            timeout_ms: timeout_ms
          })

        {:noreply, %{state | waiters: waiters}}
    end
  end

  def handle_call({:wait_outcome, parent_sid, ids, timeout_ms, opts}, from, state) do
    state = restore_parent(state, parent_sid, opts)
    ids = normalize_ids(ids, state, parent_sid)
    agents = agents_for_ids(state, parent_sid, ids)

    cond do
      ids == [] ->
        {:reply, {:ok, wait_outcome([], timeout_ms)}, state}

      length(agents) != length(ids) ->
        {:reply,
         {:error, Tool.error(:not_found, "one or more subagents are unknown", %{ids: ids})},
         state}

      Enum.all?(agents, &Subagents.terminal?(&1.status)) ->
        {:reply, {:ok, wait_outcome(agents, timeout_ms)}, state}

      timeout_ms == 0 ->
        {:reply, {:ok, wait_outcome(agents, timeout_ms)}, state}

      true ->
        waiter_id = make_ref()
        timer = Process.send_after(self(), {:wait_timeout, waiter_id}, clamp_timer_ms(timeout_ms))

        waiters =
          Map.put(state.waiters, waiter_id, %{
            from: from,
            parent_sid: parent_sid,
            ids: ids,
            timer_ref: timer,
            mode: :outcome,
            timeout_ms: timeout_ms
          })

        {:noreply, %{state | waiters: waiters}}
    end
  end

  def handle_call({:close, parent_sid, id, opts}, _from, state) do
    state = restore_parent(state, parent_sid, opts)

    with {:ok, agent} <- fetch_agent(state, parent_sid, id),
         :ok <- ensure_closeable(agent) do
      {agent, event} = close_or_cancel_agent(agent)
      state = put_agent(state, agent)
      state = cancel_timer(state, agent)
      state = record_parent_event(state, agent, event, agent.status, terminal_event_fields(agent))
      state = maybe_start_queued(state, parent_sid)
      {:reply, {:ok, public_agent(agent)}, reply_waiters(state)}
    else
      {:error, :detached} -> {:reply, {:error, detached_error(id)}, state}
      {:error, error} -> {:reply, {:error, error}, state}
    end
  end

  def handle_call({:list, parent_sid, opts}, _from, state) do
    state = restore_parent(state, parent_sid, opts)

    agents =
      state
      |> parent_agents(parent_sid)
      |> Enum.map(&public_agent/1)

    {:reply, {:ok, agents}, state}
  end

  def handle_call({:diagnostics, parent_sid, _opts}, _from, state)
      when is_binary(parent_sid) do
    agents = parent_agents(state, parent_sid)
    {:reply, {:ok, manager_diagnostics(parent_sid, agents, state)}, state}
  end

  def handle_call({:diagnostics, _parent_sid, _opts}, _from, state) do
    {:reply, {:error, Tool.error(:invalid_args, "parent session id must be a string", %{})},
     state}
  end

  @impl true
  def handle_info({:pixir_event, %{session_id: child_sid} = event}, state) do
    case Map.fetch(state.child_to_agent, child_sid) do
      {:ok, {parent_sid, id}} ->
        state = remember_child_event(state, parent_sid, id, event)

        case maybe_retry_transport_failure(parent_sid, id, event, state) do
          {:retrying, state} -> {:noreply, state}
          :no_retry -> handle_child_event(parent_sid, id, event, state)
        end

      :error ->
        {:noreply, state}
    end
  end

  def handle_info({:subagent_timeout, parent_sid, id}, state) do
    case fetch_agent(state, parent_sid, id) do
      {:ok, %{status: "running"} = agent} ->
        _ = safe_interrupt(agent.child_session_id)
        elapsed_ms = elapsed_ms(agent)
        next_actions = timeout_next_actions(agent)

        agent = %{
          agent
          | status: "timed_out",
            summary: timeout_summary(agent, elapsed_ms),
            elapsed_ms: elapsed_ms,
            timeout_reason: "timeout",
            next_actions: next_actions,
            updated_at: now()
        }

        state = put_agent(state, agent)
        state = cancel_timer(state, agent)

        state =
          record_parent_event(state, agent, "timed_out", "timed_out", %{
            "reason" => "timeout",
            "timeout_ms" => agent.timeout_ms,
            "elapsed_ms" => elapsed_ms,
            "next_actions" => next_actions
          })

        state = maybe_start_queued(state, parent_sid)
        {:noreply, reply_waiters(state)}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:subagent_retry, parent_sid, id}, state) do
    case fetch_agent(state, parent_sid, id) do
      {:ok, %{status: "queued"}} ->
        {:noreply, maybe_start_queued(state, parent_sid)}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:wait_timeout, waiter_id}, state) do
    case Map.pop(state.waiters, waiter_id) do
      {nil, _waiters} ->
        {:noreply, state}

      {waiter, waiters} ->
        agents = agents_for_ids(state, waiter.parent_sid, waiter.ids)
        GenServer.reply(waiter.from, waiter_reply(waiter, agents))
        {:noreply, %{state | waiters: waiters}}
    end
  end

  # ── retry handling ───────────────────────────────────────────────────────

  defp maybe_retry_transport_failure(parent_sid, id, event, state) do
    with {:ok, agent} <- fetch_agent(state, parent_sid, id),
         true <- transport_retry_event?(event),
         true <- retry_attempt_index(agent) < retry_max_attempts(agent),
         true <- not write_capable?(agent) do
      old_agent = agent

      retry_entry = %{
        "attempt_index" => retry_attempt_index(agent),
        "failed_child_session_id" => agent.child_session_id,
        "error_kind" => event.data["error_kind"],
        "timestamp" => now()
      }

      agent =
        agent
        |> Map.merge(%{
          status: "queued",
          child_pid: nil,
          timer_ref: nil,
          retry_attempt_index: retry_attempt_index(agent) + 1,
          retry_history: Map.get(agent, :retry_history, []) ++ [retry_entry],
          updated_at: now()
        })

      state =
        state
        |> cancel_timer(old_agent)
        |> put_agent(agent)
        |> remove_child_mapping(retry_entry["failed_child_session_id"])
        |> record_parent_event(agent, "retrying", "queued", %{
          "retry_attempts" => retry_attempt_index(agent),
          "retry_max_attempts" => retry_max_attempts(agent),
          "failed_child_session_id" => retry_entry["failed_child_session_id"],
          "error_kind" => retry_entry["error_kind"]
        })

      Process.send_after(
        self(),
        {:subagent_retry, parent_sid, id},
        retry_jitter(Map.get(agent, :retry_jitter_ms, 0))
      )

      {:retrying, state}
    else
      _ -> :no_retry
    end
  end

  defp transport_retry_event?(%{type: :turn_failed, data: data}) when is_map(data) do
    data["terminal_status"] == "provider_error" and
      (data["error_kind"] in websocket_transport_error_kinds() or
         retryable_provider_http_error?(data))
  end

  defp transport_retry_event?(_event), do: false

  defp websocket_transport_error_kinds do
    ~w(websocket_read_failed websocket_failed websocket_closed websocket_timeout)
  end

  defp retryable_provider_http_error?(%{"error_kind" => "provider_http_error"} = data) do
    get_in(data, ["details", "type"]) == "server_error"
  end

  defp retryable_provider_http_error?(_data), do: false

  defp write_capable?(%{permission_mode: :read_only}), do: false
  defp write_capable?(%{permission_mode: "read_only"}), do: false
  defp write_capable?(_agent), do: true

  defp clamp_timer_ms(ms, ceiling \\ @erlang_timer_max_ms)

  defp clamp_timer_ms(ms, ceiling) when is_integer(ms) and ms >= 0,
    do: min(ms, ceiling)

  defp clamp_timer_ms(_ms, _ceiling), do: 0

  defp retry_jitter(ms) when is_integer(ms) and ms > 0,
    do: :rand.uniform(clamp_timer_ms(ms, @retry_jitter_ceiling_ms) + 1) - 1

  defp retry_jitter(_ms), do: 0

  defp remove_child_mapping(state, nil), do: state

  defp remove_child_mapping(state, child_sid) do
    %{state | child_to_agent: Map.delete(state.child_to_agent, child_sid)}
  end

  # ── build/start ──────────────────────────────────────────────────────────

  defp build_spec(parent_sid, %{"task" => task} = args, opts)
       when is_binary(task) and task != "" do
    workspace = Keyword.fetch!(opts, :workspace)
    agent_name = Map.get(args, "agent", "default")
    agents_opts = Keyword.get(opts, :agents_opts, [])

    with {:ok, agent_config} <- Agents.get(agent_name, workspace, agents_opts) do
      limits = Subagents.default_limits()
      max_threads = Map.get(args, "max_threads", limits.max_threads)
      max_depth = Map.get(args, "max_depth", limits.max_depth)
      timeout_ms = Map.get(args, "timeout_ms", limits.timeout_ms)
      retry_max_attempts = Map.get(args, "retry_attempts", limits.retry_attempts)
      retry_jitter_ms = Map.get(args, "retry_jitter_ms", limits.retry_jitter_ms)
      workspace_mode = Map.get(args, "workspace_mode", "isolated")
      provider_model = Map.get(args, "model") || Keyword.get(opts, :model)
      reasoning_effort = Map.get(args, "reasoning_effort") || Keyword.get(opts, :reasoning_effort)
      # Map.fetch, not ||: an explicit "web_search" => false in args must beat
      # an inherited truthy default in opts (explicit opt-out stays an opt-out).
      web_search =
        case Map.fetch(args, "web_search") do
          {:ok, value} -> value
          :error -> Keyword.get(opts, :web_search)
        end

      attachments = Keyword.get(opts, :attachments, Map.get(args, "attachments", []))

      # Runtime-owned identity and evidence ride opts, never args. The
      # spawn_agent tool strips caller-authored runtime fields as defense in
      # depth, but this builder is the enforcement barrier: forged args values
      # for index/id are not read at all. Existing operator knobs that still
      # ride args (model, reasoning_effort, web_search, attachments) migrate
      # opportunistically; new runtime knobs must enter through opts from day
      # one.
      index = Keyword.get(opts, :index)
      id = gen_id()

      with :ok <- validate_optional_non_negative_integer("index", index),
           :ok <- validate_optional_binary("model", provider_model),
           {:ok, web_search} <- validate_optional_web_search(web_search),
           :ok <- validate_optional_reasoning_effort(reasoning_effort),
           :ok <- validate_attachments(attachments),
           :ok <- validate_positive_integer("max_threads", max_threads),
           :ok <- validate_non_negative_integer("max_depth", max_depth),
           :ok <- validate_positive_integer("timeout_ms", timeout_ms),
           :ok <- validate_non_negative_integer("retry_attempts", retry_max_attempts),
           :ok <- validate_non_negative_integer("retry_jitter_ms", retry_jitter_ms),
           {:ok, workspace_mode} <-
             WorkspaceStrategy.normalize_runtime_mode(workspace_mode, "subagent") do
        {:ok,
         %{
           id: id,
           parent_session_id: parent_sid,
           index: index,
           child_session_id: nil,
           child_pid: nil,
           task: task,
           prompt: task,
           agent: agent_config.name,
           agent_config: agent_config,
           status: "queued",
           summary: nil,
           depth: Keyword.get(opts, :depth, 0) + 1,
           max_threads: max_threads,
           max_depth: max_depth,
           timeout_ms: timeout_ms,
           retry_max_attempts: retry_max_attempts,
           retry_jitter_ms: retry_jitter_ms,
           retry_attempt_index: 0,
           retry_history: [],
           parent_log_path: Log.path(parent_sid, workspace: workspace),
           child_log_path: nil,
           workspace: workspace,
           child_workspace: nil,
           workspace_mode: workspace_mode,
           provider_model: provider_model,
           reasoning_effort: reasoning_effort,
           web_search: web_search,
           attachments: attachments,
           workspace_snapshot: nil,
           workspace_snapshot_opts: Keyword.get(opts, :workspace_snapshot_opts, []),
           provider: Keyword.get(opts, :provider, Pixir.Provider),
           provider_opts: Keyword.get(opts, :provider_opts, []),
           permission_mode:
             child_permission_mode(agent_config, Keyword.get(opts, :permission_mode, :auto)),
           write_policy: Keyword.get(opts, :write_policy),
           skills_opts: Keyword.get(opts, :skills_opts, []),
           agents_opts: agents_opts,
           delegation_context: Keyword.get(opts, :delegation_context, %{}),
           timer_ref: nil,
           started_at_ms: nil,
           deadline_at: nil,
           elapsed_ms: nil,
           timeout_reason: nil,
           next_actions: [],
           last_seen_child_event_seq: nil,
           last_seen_child_event_type: nil,
           last_seen_child_event_ts: nil,
           created_at: now(),
           updated_at: now()
         }}
      end
    end
  end

  defp build_spec(_parent_sid, _args, _opts),
    do: {:error, Tool.error(:invalid_args, "task is required", %{})}

  defp validate_positive_integer(_field, value) when is_integer(value) and value > 0, do: :ok

  defp validate_positive_integer(field, value) do
    {:error,
     Tool.error(:invalid_args, "#{field} must be a positive integer", %{
       "field" => field,
       "value" => inspect(value)
     })}
  end

  defp validate_optional_non_negative_integer(_field, nil), do: :ok

  defp validate_optional_non_negative_integer(field, value),
    do: validate_non_negative_integer(field, value)

  defp validate_attachments(attachments) when is_list(attachments) do
    if Enum.all?(attachments, &valid_attachment?/1) do
      :ok
    else
      {:error,
       Tool.error(:invalid_args, "attachments must be resource_link maps", %{
         "field" => "attachments",
         "expected" => "list of resource_link maps with non-empty uri"
       })}
    end
  end

  defp validate_attachments(_attachments) do
    {:error,
     Tool.error(:invalid_args, "attachments must be a list", %{
       "field" => "attachments",
       "expected" => "list of resource_link maps"
     })}
  end

  # Only local file:// links: remote resource_links stay descriptor-only on the
  # ACP surface (CONTEXT.md) and the delegate surface never fabricates them.
  defp valid_attachment?(%{"type" => "resource_link", "uri" => "file://" <> rest})
       when rest != "",
       do: true

  defp valid_attachment?(_attachment), do: false

  defp validate_optional_binary(_field, nil), do: :ok
  defp validate_optional_binary(_field, value) when is_binary(value) and value != "", do: :ok

  defp validate_optional_binary(field, value) do
    {:error,
     Tool.error(:invalid_args, "#{field} must be a non-empty string", %{
       "field" => field,
       "value" => inspect(value)
     })}
  end

  # Building the error report must never crash the Manager: the catch-all
  # covers non-JSON terms reachable through the internal opts path (atoms,
  # tuples, pids). Maps, nil, and booleans are consumed by earlier validate
  # clauses and never reach this helper.
  defp json_type(value) when is_binary(value), do: "string"
  defp json_type(value) when is_integer(value) or is_float(value), do: "number"
  defp json_type(value) when is_list(value), do: "array"
  defp json_type(_value), do: "unknown"

  defp validate_optional_web_search(nil), do: {:ok, nil}
  defp validate_optional_web_search(false), do: {:ok, nil}
  defp validate_optional_web_search(true), do: {:ok, %{"enabled" => true}}

  defp validate_optional_web_search(%{} = web_search) do
    case HostedTools.web_search(web_search) do
      {:ok, _tool} -> {:ok, web_search}
      {:error, reason} -> {:error, Tool.error(reason.kind, reason.message, reason.details)}
    end
  end

  defp validate_optional_web_search(other) do
    {:error,
     Tool.error(:invalid_args, "web_search must be true or an object", %{
       "field" => "web_search",
       "observed_type" => json_type(other),
       "accepted_values" => [true, "object"]
     })}
  end

  defp validate_optional_reasoning_effort(nil), do: :ok

  defp validate_optional_reasoning_effort(value) do
    accepted = Pixir.Config.valid_reasoning_efforts()

    if value in accepted do
      :ok
    else
      {:error,
       Tool.error(:invalid_args, "reasoning_effort has an unsupported value", %{
         "field" => "reasoning_effort",
         "value" => inspect(value),
         "accepted_values" => accepted
       })}
    end
  end

  defp validate_non_negative_integer(_field, value) when is_integer(value) and value >= 0,
    do: :ok

  defp validate_non_negative_integer(field, value) do
    {:error,
     Tool.error(:invalid_args, "#{field} must be a non-negative integer", %{
       "field" => field,
       "value" => inspect(value)
     })}
  end

  defp check_depth(%{depth: depth, max_depth: max_depth}) when depth <= max_depth, do: :ok

  defp check_depth(spec),
    do:
      {:error,
       Tool.error(:permission_denied, "subagent max_depth exceeded", %{
         "current_depth" => spec.depth - 1,
         "requested_child_depth" => spec.depth,
         "max_depth" => spec.max_depth,
         "meaning" =>
           "max_depth is the maximum absolute Subagent depth from the root Session; root children run at depth 1",
         "next_actions" => [
           "increase_max_depth_to_#{spec.depth}",
           "run_the_task_in_the_current_session",
           "reduce_recursive_delegation"
         ]
       })}

  defp start_agent(agent, state) do
    with {:ok, child_workspace, workspace_snapshot} <- prepare_workspace(agent),
         {:ok, child_sid, child_pid} <-
           SessionSupervisor.start_session(workspace: child_workspace, role: :subagent) do
      deadline_at = deadline_at(agent.timeout_ms)
      child_log_path = Log.path(child_sid, workspace: child_workspace)

      turn_agent = %{
        agent
        | child_session_id: child_sid,
          child_workspace: child_workspace,
          child_log_path: child_log_path,
          workspace_snapshot: workspace_snapshot,
          deadline_at: deadline_at
      }

      with :ok <- subscribe_child_events(child_sid),
           {:ok, _ref} <- start_child_turn(turn_agent, child_sid, child_workspace) do
        timer =
          Process.send_after(
            self(),
            {:subagent_timeout, agent.parent_session_id, agent.id},
            clamp_timer_ms(agent.timeout_ms)
          )

        started = %{
          turn_agent
          | child_pid: child_pid,
            status: "running",
            timer_ref: timer,
            started_at_ms: monotonic_ms(),
            elapsed_ms: nil,
            timeout_reason: nil,
            next_actions: [],
            updated_at: now()
        }

        state =
          state
          |> put_agent(started)
          |> put_child_index(started)
          |> record_parent_event(started, "started", "running")

        {:ok, started, state}
      end
    else
      {:error, error} ->
        failed = %{agent | status: "failed", summary: inspect(error), updated_at: now()}

        state =
          state
          |> put_agent(failed)
          |> record_parent_event(failed, "failed", "failed")

        {:error, error, state}
    end
  end

  defp restart_agent(agent, prompt, _opts, state) when is_binary(prompt) and prompt != "" do
    deadline_at = deadline_at(agent.timeout_ms)
    turn_agent = %{agent | prompt: prompt, deadline_at: deadline_at}

    case start_child_turn(
           turn_agent,
           agent.child_session_id,
           agent.child_workspace,
           # Same-session restarts must not re-ingest operator attachments: the
           # first Turn already persisted them as durable Session Resources.
           attachments: []
         ) do
      {:ok, _ref} ->
        timer =
          Process.send_after(
            self(),
            {:subagent_timeout, agent.parent_session_id, agent.id},
            clamp_timer_ms(agent.timeout_ms)
          )

        updated = %{
          turn_agent
          | prompt: prompt,
            status: "running",
            summary: nil,
            timer_ref: timer,
            started_at_ms: monotonic_ms(),
            deadline_at: deadline_at,
            elapsed_ms: nil,
            timeout_reason: nil,
            next_actions: [],
            updated_at: now()
        }

        state =
          state
          |> put_agent(updated)
          |> record_parent_event(updated, "input", "running", %{prompt: prompt})

        {:ok, updated, state}

      {:error, :busy} ->
        {:error, Tool.error(:permission_denied, "subagent is already running", %{id: agent.id})}
    end
  end

  defp restart_agent(_agent, _prompt, _opts, _state),
    do: {:error, Tool.error(:invalid_args, "prompt is required", %{})}

  defp start_child_turn(agent, child_sid, child_workspace, turn_overrides \\ []) do
    instructions = agent.agent_config.developer_instructions

    # The Turn reads model/reasoning_effort from provider_opts (same seam ACP
    # uses for _meta knobs); a spec knob wins over any inherited default.
    provider_opts =
      agent.provider_opts
      |> List.wrap()
      |> put_provider_knob(:model, Map.get(agent, :provider_model))
      |> put_provider_knob(:reasoning_effort, Map.get(agent, :reasoning_effort))
      |> put_provider_knob(:web_search, Map.get(agent, :web_search))

    Session.start_turn(child_sid, fn ctx ->
      Turn.run(%{ctx | workspace: child_workspace}, agent.prompt,
        provider: agent.provider,
        provider_opts: provider_opts,
        permission_mode: agent.permission_mode,
        attachments: Keyword.get(turn_overrides, :attachments, Map.get(agent, :attachments, [])),
        write_policy: agent.write_policy,
        skills_opts: agent.skills_opts,
        agents_opts: agent.agents_opts,
        subagent_depth: agent.depth,
        agent_instructions: instructions,
        delegation_context: DelegationContext.from_agent(agent)
      )
    end)
  end

  defp put_provider_knob(opts, _key, nil), do: opts
  defp put_provider_knob(opts, key, value), do: Keyword.put(opts, key, value)

  defp subscribe_child_events(child_sid),
    do: Events.subscribe(child_sid, only: @manager_child_event_types)

  defp prepare_workspace(%{workspace_mode: "shared", workspace: workspace}),
    do: {:ok, workspace, nil}

  defp prepare_workspace(agent) do
    with {:ok, dest} <- child_workspace_dest(agent),
         :ok <- reset_child_workspace(dest) do
      case WorkspaceSnapshot.copy(agent.workspace, dest, agent.workspace_snapshot_opts) do
        {:ok, metadata} ->
          {:ok, dest, metadata}

        {:error, details} ->
          _ = File.rm_rf(dest)

          {:error, Tool.error(:write_failed, "could not prepare subagent workspace", details)}
      end
    end
  end

  defp child_workspace_dest(agent) do
    subagents_root = Path.join(Paths.project_root(agent.workspace), "subagents")
    dest = Path.expand(Path.join([subagents_root, agent.id, "workspace"]))
    root = Path.expand(subagents_root)

    if under_path?(dest, root) do
      {:ok, dest}
    else
      {:error,
       workspace_setup_error("snapshot_destination_outside_subagents_root", dest, :outside_root)}
    end
  end

  defp reset_child_workspace(dest) do
    with {:ok, _removed} <- File.rm_rf(dest),
         :ok <- File.mkdir_p(dest) do
      :ok
    else
      {:error, path, reason} ->
        {:error, workspace_setup_error("snapshot_workspace_cleanup_failed", path, reason)}

      {:error, reason} ->
        {:error, workspace_setup_error("snapshot_workspace_mkdir_failed", dest, reason)}
    end
  end

  defp workspace_setup_error(reason, path, filesystem_reason) do
    Tool.error(:write_failed, "could not prepare subagent workspace", %{
      "reason" => reason,
      "path" => path,
      "filesystem_reason" => inspect(filesystem_reason),
      "next_actions" => [
        "inspect_subagent_workspace_path",
        "remove_conflicting_workspace_artifact",
        "retry_spawn_agent"
      ]
    })
  end

  defp under_path?(path, root) do
    relative = Path.relative_to(path, root)
    relative != "." and not String.starts_with?(relative, "..")
  end

  # ── child event handling ────────────────────────────────────────────────

  defp handle_child_event(
         parent_sid,
         id,
         %{type: :assistant_message, data: %{"text" => text} = data},
         state
       ) do
    {:ok, agent} = fetch_agent(state, parent_sid, id)

    summary =
      if partial_assistant?(data) do
        agent.summary
      else
        text
      end

    {:noreply, put_agent(state, %{agent | summary: summary, updated_at: now()})}
  end

  defp handle_child_event(parent_sid, id, %{type: :status, data: %{"status" => "done"}}, state) do
    {:ok, agent} = fetch_agent(state, parent_sid, id)

    if Subagents.terminal?(agent.status) do
      {:noreply, state}
    else
      summary = agent.summary || latest_child_answer(agent)
      agent = %{agent | status: "completed", summary: summary, updated_at: now()}

      state =
        state
        |> put_agent(agent)
        |> cancel_timer(agent)
        |> record_parent_event(agent, "finished", "completed")
        |> maybe_start_queued(parent_sid)
        |> reply_waiters()

      {:noreply, state}
    end
  end

  defp handle_child_event(parent_sid, id, %{type: :status, data: %{"status" => "error"}}, state) do
    {:ok, agent} = fetch_agent(state, parent_sid, id)

    if Subagents.terminal?(agent.status) do
      {:noreply, state}
    else
      evidence = child_failure_evidence(agent)

      agent = %{
        agent
        | status: "failed",
          summary: agent.summary || evidence.summary,
          elapsed_ms: elapsed_ms(agent),
          timeout_reason: evidence.reason,
          next_actions: evidence.next_actions,
          updated_at: now()
      }

      state =
        state
        |> put_agent(agent)
        |> cancel_timer(agent)
        |> record_parent_event(agent, "failed", "failed", terminal_event_fields(agent))
        |> maybe_start_queued(parent_sid)
        |> reply_waiters()

      {:noreply, state}
    end
  end

  defp handle_child_event(
         parent_sid,
         id,
         %{type: :status, data: %{"status" => "interrupted"}},
         state
       ) do
    {:ok, agent} = fetch_agent(state, parent_sid, id)

    if Subagents.terminal?(agent.status) do
      {:noreply, state}
    else
      next_actions = interrupted_next_actions(agent)

      agent = %{
        agent
        | status: "cancelled",
          summary: "Subagent was interrupted before completion.",
          elapsed_ms: elapsed_ms(agent),
          timeout_reason: "interrupted",
          next_actions: next_actions,
          updated_at: now()
      }

      state =
        state
        |> put_agent(agent)
        |> cancel_timer(agent)
        |> record_parent_event(agent, "cancelled", "cancelled", terminal_event_fields(agent))
        |> maybe_start_queued(parent_sid)
        |> reply_waiters()

      {:noreply, state}
    end
  end

  defp handle_child_event(_parent_sid, _id, _event, state), do: {:noreply, state}

  defp latest_child_answer(%{child_session_id: nil}), do: ""

  defp latest_child_answer(agent) do
    case Log.fold(agent.child_session_id, workspace: agent.child_workspace) do
      {:ok, history} ->
        history
        |> Enum.reverse()
        |> Enum.find(&(&1.type == :assistant_message and not partial_assistant?(&1.data)))
        |> case do
          nil -> ""
          event -> event.data["text"] || ""
        end

      _ ->
        ""
    end
  end

  defp ensure_idle_for_input(%{status: "closed"}), do: {:error, :closed}
  defp ensure_idle_for_input(%{status: "detached"}), do: {:error, :detached}

  defp ensure_idle_for_input(%{status: status}) when status in ["running", "queued"],
    do: {:error, :busy}

  defp ensure_idle_for_input(%{agent_config: nil}), do: {:error, :detached}

  defp ensure_idle_for_input(_agent), do: :ok

  defp ensure_closeable(%{status: "detached"}), do: {:error, :detached}
  defp ensure_closeable(_agent), do: :ok

  # A late timeout or cancel can race a child Session that already terminated
  # (its test/app tore down, or it finished between deadline firing and handling).
  # Interrupting a dead child must not crash the Manager: the timeout/cancel
  # evidence below is still the honest record either way.
  defp safe_interrupt(session_id) do
    Session.interrupt(session_id)
  catch
    :exit, _ -> :ok
  end

  defp close_or_cancel_agent(%{status: "running"} = agent) do
    _ = safe_interrupt(agent.child_session_id)

    {%{
       agent
       | status: "cancelled",
         summary: "Subagent was cancelled by parent before completion.",
         elapsed_ms: elapsed_ms(agent),
         timeout_reason: "cancelled_by_parent",
         next_actions: interrupted_next_actions(agent),
         updated_at: now()
     }, "cancelled"}
  end

  defp close_or_cancel_agent(%{status: "queued"} = agent) do
    {%{
       agent
       | status: "closed",
         summary: "Subagent was closed before it started.",
         timeout_reason: "closed_before_start",
         next_actions: cleanup_next_actions(agent),
         updated_at: now()
     }, "closed"}
  end

  defp close_or_cancel_agent(agent) do
    {%{
       agent
       | status: "closed",
         timeout_reason: agent.timeout_reason || "closed_by_parent",
         next_actions: non_empty(agent.next_actions) || cleanup_next_actions(agent),
         updated_at: now()
     }, "closed"}
  end

  defp detached_error(id) do
    Tool.error(:detached, "subagent has no live runtime handle", %{id: id})
  end

  # ── state helpers ───────────────────────────────────────────────────────

  defp restore_parent(state, parent_sid, opts) do
    workspace = Keyword.get(opts, :workspace)
    state = ensure_parent(state, parent_sid)
    parent = Map.fetch!(state.parents, parent_sid)

    if parent.restored do
      state
    else
      case parent_history(parent_sid, workspace) do
        {:ok, []} ->
          state

        {:ok, history} ->
          history
          |> Subagents.reconstruct()
          |> Map.values()
          |> Enum.reduce(state, fn data, acc ->
            merge_restored_agent(acc, restored_agent(parent_sid, data, workspace))
          end)
          |> mark_parent_restored(parent_sid)

        _ ->
          state
      end
    end
  end

  defp parent_history(parent_sid, workspace) do
    case safe_session_history(parent_sid) do
      {:ok, _history} = ok ->
        ok

      _ when is_binary(workspace) ->
        Log.fold(parent_sid, workspace: workspace)

      error ->
        error
    end
  end

  defp safe_session_history(parent_sid) do
    Session.history(parent_sid)
  catch
    :exit, _reason -> {:error, :parent_not_running}
  end

  defp restored_agent(parent_sid, data, workspace) do
    terminal = restored_terminal(data)
    task = data["task"] || ""

    %{
      id: data["id"] || data["subagent_id"],
      parent_session_id: parent_sid,
      index: data["index"],
      provider_model: data["model"],
      reasoning_effort: data["reasoning_effort"],
      web_search: data["web_search"],
      child_session_id: data["child_session_id"],
      child_pid: nil,
      task: task,
      prompt: task,
      agent: data["agent"] || "default",
      agent_config: nil,
      source_status: data["status"],
      status: terminal.status,
      summary: terminal.summary,
      depth: data["depth"] || 1,
      max_threads: 0,
      max_depth: data["max_depth"] || 0,
      timeout_ms: data["timeout_ms"] || 0,
      deadline_at: data["deadline_at"],
      parent_log_path: data["parent_log_path"],
      child_log_path: data["child_log_path"],
      started_at_ms: nil,
      elapsed_ms: terminal.elapsed_ms || data["elapsed_ms"],
      timeout_reason: terminal.reason || data["reason"],
      next_actions: terminal.next_actions || data["next_actions"] || [],
      last_seen_child_event_seq: nil,
      last_seen_child_event_type: nil,
      last_seen_child_event_ts: nil,
      workspace: workspace || data["workspace"] || File.cwd!(),
      child_workspace: data["workspace"],
      workspace_mode: data["workspace_mode"] || "isolated",
      workspace_snapshot: data["workspace_snapshot"],
      workspace_snapshot_opts: [],
      delegation_context: data["delegation_context"] || %{},
      retry_attempt_index: data["retry_attempts"] || 0,
      retry_max_attempts: data["retry_max_attempts"] || Subagents.default_limits().retry_attempts,
      retry_jitter_ms: Subagents.default_limits().retry_jitter_ms,
      retry_history: data["retry_history"] || [],
      provider: nil,
      provider_opts: [],
      permission_mode: nil,
      write_policy: restored_write_policy(data["write_policy"]),
      skills_opts: [],
      agents_opts: [],
      timer_ref: nil,
      created_at: now(),
      updated_at: now()
    }
  end

  defp restored_terminal(%{"status" => status} = data) when status in ["running", "queued"] do
    terminal("detached", data["summary"] || detached_summary(data),
      next_actions: data["next_actions"]
    )
  end

  defp restored_terminal(%{"status" => status} = data) when is_binary(status) do
    terminal(status, data["summary"],
      reason: data["reason"],
      elapsed_ms: data["elapsed_ms"],
      next_actions: data["next_actions"]
    )
  end

  defp restored_terminal(data), do: terminal("detached", detached_summary(data))

  defp restored_write_policy(metadata) do
    case WritePolicy.from_metadata(metadata) do
      {:ok, policy} -> policy
      {:error, _error} -> nil
    end
  end

  defp detached_summary(data) do
    status = data["status"] || data["event"] || "unknown"
    child_sid = data["child_session_id"] || "unknown"

    "Subagent was #{status} in a previous Pixir runtime; no live runtime handle is " <>
      "available in this process. child_session_id=#{child_sid}."
  end

  defp merge_restored_agent(state, %{id: nil}), do: state

  defp merge_restored_agent(state, restored) do
    state = ensure_parent(state, restored.parent_session_id)
    parent = Map.fetch!(state.parents, restored.parent_session_id)

    case Map.fetch(parent.agents, restored.id) do
      :error ->
        restored = maybe_reattach_restored_agent(restored)

        parent = %{
          parent
          | agents: Map.put(parent.agents, restored.id, restored),
            order: append_once(parent.order, restored.id)
        }

        state
        |> put_in([:parents, restored.parent_session_id], parent)
        |> maybe_put_child_index(restored)

      {:ok, live} ->
        put_agent(state, merge_live_with_restored(live, restored))
    end
  end

  defp merge_live_with_restored(%{status: status} = live, %{status: "detached"})
       when status in ["running", "queued"],
       do: live

  defp merge_live_with_restored(%{status: status} = live, %{source_status: source_status})
       when status in ["running", "queued"] and source_status in ["running", "queued"],
       do: live

  defp merge_live_with_restored(live, restored) do
    if Subagents.terminal?(restored.status) do
      %{
        live
        | status: restored.status,
          summary: restored.summary || live.summary,
          child_session_id: live.child_session_id || restored.child_session_id,
          child_workspace: live.child_workspace || restored.child_workspace,
          workspace_snapshot: live.workspace_snapshot || restored.workspace_snapshot,
          parent_log_path: live.parent_log_path || restored.parent_log_path,
          child_log_path: live.child_log_path || restored.child_log_path,
          deadline_at: live.deadline_at || restored.deadline_at,
          updated_at: now()
      }
    else
      live
    end
  end

  defp maybe_reattach_restored_agent(
         %{source_status: status, child_session_id: child_sid} = agent
       )
       when status in ["running", "queued"] and is_binary(child_sid) do
    case live_child_session(child_sid) do
      {:ok, child_pid} ->
        _ = subscribe_child_events(child_sid)

        if child_turn_running?(child_sid) do
          reattach_running_agent(agent, child_pid)
        else
          agent
        end

      :error ->
        agent
    end
  end

  defp maybe_reattach_restored_agent(agent), do: agent

  defp live_child_session(child_sid) when is_binary(child_sid) do
    with [{pid, _meta}] <- Registry.lookup(Pixir.Sessions.Registry, child_sid),
         true <- Process.alive?(pid) do
      {:ok, pid}
    else
      _ -> :error
    end
  end

  defp reattach_running_agent(agent, child_pid) do
    {timer_ref, started_at_ms, deadline_at} = rearm_timeout(agent)

    %{
      agent
      | status: "running",
        summary: reattached_summary(agent),
        child_pid: child_pid,
        timer_ref: timer_ref,
        started_at_ms: started_at_ms,
        deadline_at: deadline_at,
        timeout_reason: nil,
        next_actions: [],
        updated_at: now()
    }
  end

  defp child_turn_running?(child_sid) do
    Session.turn_running?(child_sid)
  catch
    :exit, _reason -> false
  end

  defp rearm_timeout(%{timeout_ms: timeout_ms} = agent)
       when is_integer(timeout_ms) and timeout_ms > 0 do
    deadline_at = agent.deadline_at || deadline_at(timeout_ms)
    remaining_ms = remaining_timeout_ms(deadline_at, timeout_ms)

    timer_ref =
      Process.send_after(
        self(),
        {:subagent_timeout, agent.parent_session_id, agent.id},
        clamp_timer_ms(remaining_ms)
      )

    started_at_ms = monotonic_ms() - max(timeout_ms - remaining_ms, 0)
    {timer_ref, started_at_ms, deadline_at}
  end

  defp rearm_timeout(_agent), do: {nil, nil, nil}

  defp remaining_timeout_ms(nil, timeout_ms), do: timeout_ms

  defp remaining_timeout_ms(deadline_at, timeout_ms) when is_binary(deadline_at) do
    case DateTime.from_iso8601(deadline_at) do
      {:ok, deadline, _offset} ->
        max(DateTime.diff(deadline, DateTime.utc_now(), :millisecond), 1)

      _ ->
        timeout_ms
    end
  end

  defp remaining_timeout_ms(_deadline_at, timeout_ms), do: timeout_ms

  defp reattached_summary(%{status: "detached"}),
    do: "Subagent runtime was reattached after Pixir.Subagents.Manager restarted."

  defp reattached_summary(agent), do: agent.summary

  defp append_once(list, item), do: if(item in list, do: list, else: list ++ [item])

  defp ensure_parent(state, parent_sid) do
    update_in(state.parents, fn parents ->
      Map.update(parents, parent_sid, new_parent(), &normalize_parent/1)
    end)
  end

  defp new_parent, do: %{agents: %{}, order: [], restored: false}

  defp normalize_parent(parent), do: Map.put_new(parent, :restored, false)

  defp mark_parent_restored(state, parent_sid) do
    update_in(state.parents[parent_sid], &Map.put(&1, :restored, true))
  end

  defp put_new_agent(state, spec) do
    state = ensure_parent(state, spec.parent_session_id)
    parent = Map.fetch!(state.parents, spec.parent_session_id)
    agent = Map.put(spec, :status, "queued")

    parent = %{
      parent
      | agents: Map.put(parent.agents, agent.id, agent),
        order: parent.order ++ [agent.id]
    }

    {agent, put_in(state.parents[spec.parent_session_id], parent)}
  end

  defp put_agent(state, agent) do
    update_in(state.parents[agent.parent_session_id].agents, &Map.put(&1, agent.id, agent))
  end

  defp put_child_index(state, agent) do
    put_in(state.child_to_agent[agent.child_session_id], {agent.parent_session_id, agent.id})
  end

  defp maybe_put_child_index(state, %{status: "running", child_session_id: child_sid} = agent)
       when is_binary(child_sid),
       do: put_child_index(state, agent)

  defp maybe_put_child_index(state, _agent), do: state

  defp remember_child_event(state, parent_sid, id, event) do
    case fetch_agent(state, parent_sid, id) do
      {:ok, agent} ->
        put_agent(state, %{
          agent
          | last_seen_child_event_seq: event.seq,
            last_seen_child_event_type: Atom.to_string(event.type),
            last_seen_child_event_ts: event.ts
        })

      {:error, _error} ->
        state
    end
  end

  defp parent_agents(state, parent_sid) do
    case Map.fetch(state.parents, parent_sid) do
      {:ok, parent} -> Enum.map(parent.order, &Map.fetch!(parent.agents, &1))
      :error -> []
    end
  end

  defp manager_diagnostics(parent_sid, agents, state) do
    status_counts = agents |> Enum.frequencies_by(& &1.status) |> Enum.into(%{})
    child_index_entries = child_index_entries_for_parent(state, parent_sid)
    waiters = waiters_for_parent(state, parent_sid)
    runtime_gaps = runtime_gaps(parent_sid, agents, state)

    %{
      "parent_session_id" => parent_sid,
      "observed_at" => now(),
      "message_queue_len" => message_queue_len(),
      "known_subagent_count" => length(agents),
      "status_counts" => status_counts,
      "running_count" => Map.get(status_counts, "running", 0),
      "queued_count" => Map.get(status_counts, "queued", 0),
      "terminal_count" => Enum.count(agents, &Subagents.terminal?(&1.status)),
      "child_index_count" => length(child_index_entries),
      "active_waiter_count" => length(waiters),
      "active_waiters" => Enum.map(waiters, &public_waiter/1),
      "subagents" => Enum.map(agents, &runtime_agent_summary(&1, state)),
      "runtime_gaps" => runtime_gaps,
      "next_actions" => manager_diagnostics_next_actions(runtime_gaps)
    }
  end

  defp message_queue_len do
    case Process.info(self(), :message_queue_len) do
      {:message_queue_len, value} -> value
      _ -> nil
    end
  end

  defp child_index_entries_for_parent(state, parent_sid) do
    Enum.filter(state.child_to_agent, fn {_child_sid, {indexed_parent_sid, _id}} ->
      indexed_parent_sid == parent_sid
    end)
  end

  defp waiters_for_parent(state, parent_sid) do
    state.waiters
    |> Enum.filter(fn {_ref, waiter} -> waiter.parent_sid == parent_sid end)
    |> Enum.map(fn {_ref, waiter} -> waiter end)
  end

  defp public_waiter(waiter) do
    %{
      "ids" => waiter.ids,
      "mode" => Atom.to_string(waiter.mode),
      "timeout_ms" => waiter.timeout_ms
    }
  end

  defp runtime_agent_summary(agent, state) do
    %{
      "id" => agent.id,
      "child_session_id" => agent.child_session_id,
      "status" => agent.status,
      "agent" => agent.agent,
      "task" => agent.task,
      "deadline_at" => agent.deadline_at,
      "last_seen_child_event_seq" => agent.last_seen_child_event_seq,
      "last_seen_child_event_type" => agent.last_seen_child_event_type,
      "last_seen_child_event_ts" => agent.last_seen_child_event_ts,
      "child_indexed" => child_indexed?(state, agent),
      "child_pid_alive" => child_pid_alive?(agent)
    }
    |> maybe_put_public("index", Map.get(agent, :index))
    |> maybe_put_public("write_policy", WritePolicy.metadata(Map.get(agent, :write_policy)))
  end

  defp child_indexed?(_state, %{child_session_id: nil}), do: false

  defp child_indexed?(state, agent) do
    Map.get(state.child_to_agent, agent.child_session_id) == {agent.parent_session_id, agent.id}
  end

  defp child_pid_alive?(%{child_pid: pid}) when is_pid(pid), do: Process.alive?(pid)
  defp child_pid_alive?(_agent), do: false

  defp runtime_gaps(parent_sid, agents, state) do
    agent_ids = MapSet.new(Enum.map(agents, & &1.id))

    agent_gaps = Enum.flat_map(agents, &agent_runtime_gaps(&1, state))

    index_gaps =
      child_index_entries_for_parent(state, parent_sid)
      |> Enum.flat_map(fn {child_sid, {_parent_sid, id}} ->
        if MapSet.member?(agent_ids, id) do
          []
        else
          [
            %{
              "kind" => "orphan_child_index",
              "severity" => "warning",
              "subagent_id" => id,
              "child_session_id" => child_sid,
              "next_actions" => ["restart_subagent_manager", "inspect_parent_session_log"]
            }
          ]
        end
      end)

    waiter_gaps =
      waiters_for_parent(state, parent_sid)
      |> Enum.flat_map(fn waiter ->
        missing_ids = Enum.reject(waiter.ids, &MapSet.member?(agent_ids, &1))

        if missing_ids == [] do
          []
        else
          [
            %{
              "kind" => "waiter_unknown_subagent",
              "severity" => "warning",
              "subagent_ids" => missing_ids,
              "mode" => Atom.to_string(waiter.mode),
              "timeout_ms" => waiter.timeout_ms,
              "next_actions" => ["cancel_or_retry_wait_agent", "inspect_parent_session_log"]
            }
          ]
        end
      end)

    agent_gaps ++ index_gaps ++ waiter_gaps
  end

  defp agent_runtime_gaps(%{status: "running", child_session_id: nil} = agent, _state) do
    [
      %{
        "kind" => "running_without_child_session_id",
        "severity" => "warning",
        "subagent_id" => agent.id,
        "next_actions" => ["inspect_parent_session_log", "restart_subagent_manager"]
      }
    ]
  end

  defp agent_runtime_gaps(%{status: "running"} = agent, state) do
    []
    |> maybe_add_runtime_gap(not child_indexed?(state, agent), %{
      "kind" => "missing_child_index",
      "severity" => "warning",
      "subagent_id" => agent.id,
      "child_session_id" => agent.child_session_id,
      "next_actions" => ["restart_subagent_manager", "inspect_parent_session_log"]
    })
    |> maybe_add_runtime_gap(not child_pid_alive?(agent), %{
      "kind" => "dead_child_pid",
      "severity" => "warning",
      "subagent_id" => agent.id,
      "child_session_id" => agent.child_session_id,
      "next_actions" => ["inspect_child_session_log", "retry_or_close_subagent"]
    })
    |> Enum.reverse()
  end

  defp agent_runtime_gaps(_agent, _state), do: []

  defp maybe_add_runtime_gap(gaps, true, gap), do: [gap | gaps]
  defp maybe_add_runtime_gap(gaps, _condition, _gap), do: gaps

  defp manager_diagnostics_next_actions([]), do: []

  defp manager_diagnostics_next_actions(_runtime_gaps) do
    [
      "inspect_subagent_manager_runtime_gaps",
      "run_pixir_tree_for_parent",
      "retry_wait_agent_or_close_stale_subagents"
    ]
  end

  defp fetch_agent(state, parent_sid, id) do
    case get_in(state.parents, [parent_sid, :agents, id]) do
      nil -> {:error, Tool.error(:not_found, "subagent not found", %{id: id})}
      agent -> {:ok, agent}
    end
  end

  defp agents_for_ids(state, parent_sid, ids) do
    ids
    |> Enum.map(fn id -> get_in(state.parents, [parent_sid, :agents, id]) end)
    |> Enum.reject(&is_nil/1)
  end

  defp normalize_ids(nil, state, parent_sid),
    do: state |> parent_agents(parent_sid) |> Enum.map(& &1.id)

  defp normalize_ids([], state, parent_sid), do: normalize_ids(nil, state, parent_sid)
  defp normalize_ids(ids, _state, _parent_sid) when is_list(ids), do: ids
  defp normalize_ids(id, _state, _parent_sid) when is_binary(id), do: [id]

  defp maybe_start_queued(state, parent_sid) do
    case Scheduler.next_startable(parent_agents(state, parent_sid)) do
      {:ok, nil} ->
        state

      {:ok, queued} ->
        case start_agent(queued, state) do
          {:ok, _started, state} -> maybe_start_queued(state, parent_sid)
          {:error, _error, state} -> maybe_start_queued(state, parent_sid)
        end

      {:error, _error} ->
        state
    end
  end

  defp cancel_timer(state, %{timer_ref: nil}), do: state

  defp cancel_timer(state, agent) do
    Process.cancel_timer(agent.timer_ref)
    put_agent(state, %{agent | timer_ref: nil})
  end

  defp record_parent_event(state, agent, event, status, extra \\ %{}) do
    data =
      %{
        "event" => event,
        "subagent_id" => agent.id,
        "child_session_id" => agent.child_session_id,
        "agent" => agent.agent,
        "task" => agent.task,
        "depth" => agent.depth,
        "max_depth" => agent.max_depth,
        "timeout_ms" => agent.timeout_ms,
        "status" => status,
        "workspace_mode" => agent.workspace_mode,
        "workspace" => agent.child_workspace || agent.workspace,
        "summary" => agent.summary,
        "parent_log_path" => parent_log_path(agent)
      }
      |> maybe_put_event("index", Map.get(agent, :index))
      |> maybe_put_event("model", Map.get(agent, :provider_model))
      |> maybe_put_event("reasoning_effort", Map.get(agent, :reasoning_effort))
      |> maybe_put_event("web_search", Map.get(agent, :web_search))
      |> maybe_put_event("deadline_at", agent.deadline_at)
      |> maybe_put_event("child_log_path", child_log_path(agent))
      |> maybe_put_event("workspace_snapshot", agent.workspace_snapshot)
      |> maybe_put_event("write_policy", WritePolicy.metadata(Map.get(agent, :write_policy)))
      |> Map.merge(extra)
      |> maybe_put_event("delegation_context", DelegationContext.from_agent(agent))

    _ = safe_record(agent.parent_session_id, Event.subagent_event(agent.parent_session_id, data))
    state
  end

  defp safe_record(session_id, event) do
    Session.record(session_id, event)
  catch
    :exit, _reason -> {:error, :parent_not_running}
  end

  defp reply_waiters(state) do
    {done, pending} =
      Enum.split_with(state.waiters, fn {_id, waiter} ->
        state
        |> agents_for_ids(waiter.parent_sid, waiter.ids)
        |> Enum.all?(&Subagents.terminal?(&1.status))
      end)

    Enum.each(done, fn {_id, waiter} ->
      Process.cancel_timer(waiter.timer_ref)
      agents = agents_for_ids(state, waiter.parent_sid, waiter.ids)
      GenServer.reply(waiter.from, waiter_reply(waiter, agents))
    end)

    %{state | waiters: Map.new(pending)}
  end

  defp waiter_reply(%{mode: :outcome, timeout_ms: timeout_ms}, agents),
    do: {:ok, wait_outcome(agents, timeout_ms)}

  defp waiter_reply(_waiter, agents), do: {:ok, Enum.map(agents, &public_agent/1)}

  defp wait_outcome(agents, timeout_ms) do
    public_agents = Enum.map(agents, &public_agent/1)
    buckets = bucket_agents(public_agents)
    counts = Map.new(buckets, fn {bucket, agents} -> {bucket, length(agents)} end)
    status = wait_status(counts)

    %{
      "status" => status,
      "complete" => status == "completed",
      "partial" => status in ["partial", "incomplete"],
      "timeout_ms" => timeout_ms,
      "counts" => counts,
      "subagents" => public_agents,
      "completed" => buckets["completed"],
      "failed" => buckets["failed"],
      "timed_out" => buckets["timed_out"],
      "cancelled" => buckets["cancelled"],
      "detached" => buckets["detached"],
      "incomplete" => buckets["incomplete"],
      "next_actions" => wait_next_actions(buckets),
      "summary" => wait_summary(status, counts, timeout_ms)
    }
    |> Map.put("observed_at", now())
  end

  defp bucket_agents(agents) do
    empty = %{
      "completed" => [],
      "failed" => [],
      "timed_out" => [],
      "cancelled" => [],
      "detached" => [],
      "incomplete" => []
    }

    Enum.reduce(agents, empty, fn agent, acc ->
      Map.update!(acc, wait_bucket(agent["status"]), &[agent | &1])
    end)
    |> Map.new(fn {bucket, agents} -> {bucket, Enum.reverse(agents)} end)
  end

  defp wait_bucket("completed"), do: "completed"
  defp wait_bucket("failed"), do: "failed"
  defp wait_bucket("timed_out"), do: "timed_out"
  defp wait_bucket("detached"), do: "detached"
  defp wait_bucket(status) when status in ["cancelled", "closed"], do: "cancelled"
  defp wait_bucket(_status), do: "incomplete"

  defp wait_status(%{"incomplete" => incomplete}) when incomplete > 0, do: "incomplete"

  defp wait_status(counts) do
    if counts["failed"] + counts["timed_out"] + counts["cancelled"] + counts["detached"] > 0 do
      "partial"
    else
      "completed"
    end
  end

  defp wait_next_actions(buckets) do
    buckets
    |> Map.take(["failed", "timed_out", "cancelled", "detached", "incomplete"])
    |> Map.values()
    |> List.flatten()
    |> Enum.flat_map(&(&1["next_actions"] || []))
    |> Kernel.++(
      if buckets["incomplete"] == [],
        do: [],
        else: ["wait_again", "inspect_child_log_if_stale"]
    )
    |> Enum.uniq()
  end

  defp wait_summary("completed", counts, _timeout_ms) do
    "wait_agent completed: #{counts["completed"]} subagents."
  end

  defp wait_summary("partial", counts, _timeout_ms) do
    "wait_agent partial: #{wait_counts_summary(counts)}. Inspect child sessions or retry failed children."
  end

  defp wait_summary("incomplete", counts, timeout_ms) do
    "wait_agent incomplete after #{timeout_ms}ms: #{wait_counts_summary(counts)}. " <>
      "Use wait_agent again or reduce the fanout scope."
  end

  defp wait_counts_summary(counts) do
    counts
    |> Enum.filter(fn {_bucket, count} -> count > 0 end)
    |> Enum.map_join("; ", fn {bucket, count} -> "#{count} #{bucket}" end)
  end

  defp retry_attempt_index(agent), do: Map.get(agent, :retry_attempt_index, 0)

  defp retry_max_attempts(agent), do: Map.get(agent, :retry_max_attempts, 0)

  defp maybe_put_retry_lineage(map, %{retry_history: history} = agent)
       when is_list(history) and history != [] do
    map
    |> Map.put("retry_attempts", retry_attempt_index(agent))
    |> Map.put("retry_max_attempts", retry_max_attempts(agent))
    |> Map.put("current_attempt_index", retry_attempt_index(agent))
    |> Map.put("retry_history", history)
  end

  defp maybe_put_retry_lineage(map, _agent), do: map

  defp public_agent(agent) do
    agent
    |> public_agent_base()
    |> maybe_put_retry_lineage(agent)
  end

  defp public_agent_base(agent) do
    %{
      "id" => agent.id,
      "parent_session_id" => agent.parent_session_id,
      "child_session_id" => agent.child_session_id,
      "agent" => agent.agent,
      "task" => agent.task,
      "status" => agent.status,
      "summary" => agent.summary,
      "depth" => agent.depth,
      "max_depth" => agent.max_depth,
      "timeout_ms" => agent.timeout_ms,
      "workspace" => agent.child_workspace || agent.workspace,
      "workspace_mode" => agent.workspace_mode,
      "parent_log_path" => parent_log_path(agent)
    }
    |> Map.merge(child_log_fields(agent))
    |> maybe_put_public("index", Map.get(agent, :index))
    |> maybe_put_public("child_last_event_seq", agent.last_seen_child_event_seq)
    |> maybe_put_public("child_last_event_type", agent.last_seen_child_event_type)
    |> maybe_put_public("child_last_event_ts", agent.last_seen_child_event_ts)
    |> maybe_put_public("workspace_snapshot", agent.workspace_snapshot)
    |> maybe_put_public("write_policy", WritePolicy.metadata(Map.get(agent, :write_policy)))
    |> maybe_put_public("deadline_at", agent.deadline_at)
    |> maybe_put_public("elapsed_ms", agent.elapsed_ms)
    |> maybe_put_public("reason", agent.timeout_reason)
    |> maybe_put_public("next_actions", non_empty(agent.next_actions))
  end

  defp parent_log_path(%{parent_log_path: path}) when is_binary(path) and path != "", do: path

  defp parent_log_path(agent),
    do: Log.path(agent.parent_session_id, workspace: agent.workspace)

  defp child_log_path(%{child_log_path: path}) when is_binary(path) and path != "", do: path

  defp child_log_path(%{child_session_id: child_sid, child_workspace: child_workspace})
       when is_binary(child_sid) and is_binary(child_workspace),
       do: Log.path(child_sid, workspace: child_workspace)

  defp child_log_path(_agent), do: nil

  defp child_log_fields(agent) do
    case child_log_path(agent) do
      path when is_binary(path) and path != "" -> %{"child_log_path" => path}
      _ -> %{}
    end
  end

  defp timeout_summary(agent, elapsed_ms) do
    "Timed out after #{elapsed_ms}ms (configured timeout #{agent.timeout_ms}ms). " <>
      "Pixir interrupted the child Session; inspect child_session_id=#{agent.child_session_id} " <>
      "or retry with a larger timeout."
  end

  defp timeout_next_actions(_agent) do
    [
      "inspect_child_session_log",
      "retry_subagent_with_larger_timeout",
      "reduce_task_scope"
    ]
  end

  defp child_failure_evidence(%{child_session_id: nil}), do: default_failure_evidence()

  defp child_failure_evidence(agent) do
    case Log.fold(agent.child_session_id, workspace: agent.child_workspace) do
      {:ok, history} -> failure_evidence(history)
      _ -> default_failure_evidence()
    end
  end

  defp failure_evidence(history) do
    failure = latest_turn_failure(history)
    partial = latest_partial_assistant(history)

    reason =
      cond do
        partial != nil -> "partial_#{failure_field(failure, "terminal_status", "provider_error")}"
        failure != nil -> failure_field(failure, "terminal_status", "child_turn_failed")
        true -> "child_turn_failed"
      end

    summary =
      cond do
        partial != nil ->
          "Subagent failed after preserving partial assistant evidence. " <>
            "Inspect the child Session before trusting the partial answer."

        failure != nil ->
          failure_field(failure, "error_message", "Subagent failed before completion.")

        true ->
          "Subagent failed before completion."
      end

    %{
      reason: reason,
      summary: summary,
      next_actions: failure_next_actions(reason)
    }
  end

  defp default_failure_evidence do
    %{
      reason: "child_turn_failed",
      summary: "Subagent failed before completion.",
      next_actions: failure_next_actions("child_turn_failed")
    }
  end

  defp latest_turn_failure(history) do
    history
    |> Enum.reverse()
    |> Enum.find(&(&1.type == :turn_failed))
  end

  defp latest_partial_assistant(history) do
    history
    |> Enum.reverse()
    |> Enum.find(&(&1.type == :assistant_message and partial_assistant?(&1.data)))
  end

  defp partial_assistant?(%{"metadata" => %{"partial" => true}}), do: true
  defp partial_assistant?(_data), do: false

  defp failure_field(nil, _field, default), do: default
  defp failure_field(%{data: data}, field, default), do: data[field] || default

  defp failure_next_actions(reason) do
    [
      "inspect_child_session_log",
      "rerun_subagent_after_fixing_#{reason}",
      "reduce_task_scope"
    ]
  end

  defp interrupted_next_actions(_agent) do
    [
      "inspect_child_session_log",
      "rerun_subagent_if_still_needed"
    ]
  end

  defp cleanup_next_actions(%{child_session_id: nil}) do
    [
      "inspect_parent_session_log",
      "spawn_agent_again_if_needed"
    ]
  end

  defp cleanup_next_actions(_agent) do
    [
      "inspect_child_session_log",
      "spawn_agent_again_if_needed"
    ]
  end

  defp terminal_event_fields(agent) do
    agent
    |> terminal_event_fields_base()
    |> maybe_put_retry_lineage(agent)
  end

  defp terminal_event_fields_base(agent) do
    %{
      "reason" => agent.timeout_reason,
      "timeout_ms" => agent.timeout_ms,
      "deadline_at" => agent.deadline_at,
      "elapsed_ms" => agent.elapsed_ms,
      "next_actions" => agent.next_actions
    }
    |> Enum.reject(fn {_key, value} -> value in [nil, "", []] end)
    |> Map.new()
  end

  defp terminal(status, summary, opts \\ []) do
    %{
      status: status,
      summary: summary,
      reason: Keyword.get(opts, :reason),
      elapsed_ms: Keyword.get(opts, :elapsed_ms),
      next_actions: Keyword.get(opts, :next_actions)
    }
  end

  defp elapsed_ms(%{started_at_ms: started_at_ms}) when is_integer(started_at_ms),
    do: max(monotonic_ms() - started_at_ms, 0)

  defp elapsed_ms(%{elapsed_ms: elapsed_ms}) when is_integer(elapsed_ms), do: elapsed_ms
  defp elapsed_ms(_agent), do: nil

  defp maybe_put_public(map, _key, nil), do: map
  defp maybe_put_public(map, _key, []), do: map
  defp maybe_put_public(map, key, value), do: Map.put(map, key, value)

  defp maybe_put_event(map, _key, nil), do: map
  defp maybe_put_event(map, _key, ""), do: map
  defp maybe_put_event(map, key, value), do: Map.put(map, key, value)

  defp non_empty([]), do: nil
  defp non_empty(value), do: value

  defp monotonic_ms, do: System.monotonic_time(:millisecond)

  defp child_permission_mode(%{sandbox_mode: "read-only"}, _parent_mode), do: :read_only
  defp child_permission_mode(_agent_config, parent_mode), do: parent_mode

  defp gen_id, do: "sub_" <> Base.encode16(:crypto.strong_rand_bytes(5), case: :lower)

  defp deadline_at(timeout_ms) when is_integer(timeout_ms) and timeout_ms > 0 do
    DateTime.utc_now()
    |> DateTime.add(timeout_ms, :millisecond)
    |> DateTime.to_iso8601()
  end

  defp deadline_at(_timeout_ms), do: nil

  defp now, do: DateTime.utc_now() |> DateTime.to_iso8601()
end
