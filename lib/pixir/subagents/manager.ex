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
    SessionId,
    SessionSupervisor,
    Subagents,
    Subagents.DelegationContext,
    Subagents.Scheduler,
    Subagents.WarmStart,
    Subagents.WorkspaceSnapshot,
    Tool,
    Turn,
    VirtualOverlay,
    WorkspaceStrategy
  }

  alias Pixir.Permissions.WritePolicy
  alias Pixir.Provider.{HostedTools, OutputTruncation, OutputTruncationSummary}

  @server __MODULE__
  @manager_child_event_types ~w(assistant_message provider_usage status turn_failed)a
  @retry_jitter_ceiling_ms 60_000
  # Erlang timers reject delays above 2^32 - 1 ms (~49.7 days); clamp every
  # Process.send_after delay so an oversized accepted value degrades to the
  # ceiling instead of a badarg crash after durable evidence was recorded.
  @erlang_timer_max_ms 4_294_967_295
  @virtual_diff_max_encoded_bytes 262_144

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
    with :ok <- SessionId.validate(parent_session_id) do
      GenServer.call(@server, {:spawn_agent, parent_session_id, args, opts}, 30_000)
    end
  end

  @doc false
  def validate_spawn(parent_session_id, args, opts \\ []) do
    with {:ok, normalized} <- normalize_spawn(parent_session_id, args, opts),
         :ok <- check_depth(normalized) do
      {:ok, spawn_plan(normalized)}
    end
  end

  def send_input(parent_session_id, subagent_id, prompt, opts \\ []) do
    with :ok <- SessionId.validate(parent_session_id) do
      GenServer.call(@server, {:send_input, parent_session_id, subagent_id, prompt, opts}, 30_000)
    end
  end

  def wait(parent_session_id, ids, timeout_ms, opts \\ []) do
    with :ok <- SessionId.validate(parent_session_id) do
      timeout_ms = clamp_timer_ms(timeout_ms, @erlang_timer_max_ms - 1_000)

      GenServer.call(
        @server,
        {:wait, parent_session_id, ids, timeout_ms, opts},
        timeout_ms + 1_000
      )
    end
  catch
    :exit, {:timeout, _} ->
      {:error, Tool.error(:timeout, "wait_agent timed out", %{timeout_ms: timeout_ms})}
  end

  def wait_outcome(parent_session_id, ids, timeout_ms, opts \\ []) do
    with :ok <- SessionId.validate(parent_session_id) do
      timeout_ms = clamp_timer_ms(timeout_ms, @erlang_timer_max_ms - 1_000)

      GenServer.call(
        @server,
        {:wait_outcome, parent_session_id, ids, timeout_ms, opts},
        timeout_ms + 1_000
      )
    end
  catch
    :exit, {:timeout, _} ->
      {:error, Tool.error(:timeout, "wait_agent timed out", %{timeout_ms: timeout_ms})}
  end

  def close(parent_session_id, subagent_id, opts \\ []) do
    with :ok <- SessionId.validate(parent_session_id) do
      GenServer.call(@server, {:close, parent_session_id, subagent_id, opts}, 30_000)
    end
  end

  def list(parent_session_id, opts \\ []) do
    with :ok <- SessionId.validate(parent_session_id) do
      GenServer.call(@server, {:list, parent_session_id, opts})
    end
  end

  @diagnostics_timeout_ms 30_000

  def diagnostics(parent_session_id, opts \\ []) do
    with :ok <- SessionId.validate(parent_session_id) do
      GenServer.call(
        @server,
        {:diagnostics, parent_session_id, opts},
        @diagnostics_timeout_ms
      )
    end
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

  defp spawn_plan(spec) do
    workspace =
      case WorkspaceStrategy.delegation_context(Map.get(spec, :workspace_mode), %{}) do
        {:ok, context} ->
          Map.take(context, [
            "workspace_fidelity",
            "read_boundary",
            "write_semantics",
            "parent_workspace_mutation"
          ])

        {:error, _error} ->
          %{}
      end

    %{
      "action" => "spawn_agent",
      "agent" => Map.get(spec, :agent),
      "task" => Map.get(spec, :task),
      "depth" => Map.get(spec, :depth),
      "max_depth" => Map.get(spec, :max_depth),
      "timeout_ms" => Map.get(spec, :timeout_ms),
      "max_threads" => Map.get(spec, :max_threads),
      "limits" => %{
        "timeout_ms" => Map.get(spec, :timeout_ms),
        "max_threads" => Map.get(spec, :max_threads),
        "max_depth" => Map.get(spec, :max_depth),
        "retry_attempts" => Map.get(spec, :retry_max_attempts),
        "retry_jitter_ms" => Map.get(spec, :retry_jitter_ms)
      },
      "workspace_mode" => Map.get(spec, :workspace_mode),
      "permission_mode" => plan_permission_mode(Map.get(spec, :permission_mode)),
      "write_policy" => WritePolicy.metadata(Map.get(spec, :write_policy)),
      "resources" => [
        "manager_entry",
        "workspace_preparation",
        "child_session",
        "subagent_lifecycle_evidence"
      ],
      "limitations" => [
        "Validation does not prove workspace snapshot capacity.",
        "Validation does not prove filesystem writeability.",
        "Validation does not prove provider authentication.",
        "Validation does not prove network reachability.",
        "Validation does not prove future queue position."
      ]
    }
    |> Map.merge(workspace)
  end

  defp plan_permission_mode(mode) when is_atom(mode), do: Atom.to_string(mode)
  defp plan_permission_mode(mode), do: mode

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
      {agent, event} = close_or_cancel_agent(agent, opts)
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

  def handle_call({:diagnostics, parent_sid, opts}, _from, state)
      when is_binary(parent_sid) do
    state = restore_parent(state, parent_sid, opts)
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

        agent = maybe_attach_virtual_diff_after_failure(agent)
        state = put_agent(state, agent)
        state = cancel_timer(state, agent)

        state =
          record_parent_event(
            state,
            agent,
            "timed_out",
            "timed_out",
            terminal_event_fields(agent)
          )

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
         true <- transport_retry_eligible?(agent) do
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
    get_in(data, ["details", "retryable"]) == true or
      get_in(data, ["details", "type"]) == "server_error"
  end

  defp retryable_provider_http_error?(_data), do: false

  defp transport_retry_eligible?(%{workspace_mode: "virtual_overlay"} = agent) do
    not write_capable?(agent) and virtual_retry_log_safe?(agent)
  end

  defp transport_retry_eligible?(agent), do: not write_capable?(agent)

  # Public seam for the ADR 0036 fail-closed pins: every retry blocker is
  # exercised against a real child Log without spawning (@doc false precedent).
  @doc false
  @spec virtual_retry_log_safe?(map()) :: boolean()
  def virtual_retry_log_safe?(agent) do
    child_sid = Map.get(agent, :child_session_id)
    child_workspace = Map.get(agent, :child_workspace)

    with true <- is_binary(child_sid) and child_sid != "",
         true <- is_binary(child_workspace) and child_workspace != "",
         {:ok, true} <- Log.exists(child_sid, workspace: child_workspace),
         {:ok, history} <- Log.fold(child_sid, workspace: child_workspace) do
      not virtual_retry_evidence?(history)
    else
      _unreadable_or_missing -> false
    end
  end

  defp virtual_retry_evidence?(history) do
    virtual_call_ids =
      history
      |> Enum.filter(fn
        %{type: :tool_call, data: %{"name" => "run_virtual_commands"}} -> true
        _event -> false
      end)
      |> MapSet.new(& &1.data["call_id"])

    Enum.any?(history, fn
      %{type: type} when type in [:assistant_message, :provider_usage, :permission_decision] ->
        true

      %{type: :tool_call, data: %{"name" => "run_virtual_commands"}} ->
        true

      %{type: :tool_result, data: %{"call_id" => call_id} = data} ->
        MapSet.member?(virtual_call_ids, call_id) or is_map(data["virtual_diff"])

      _event ->
        false
    end)
  end

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

  defp build_spec(parent_sid, args, opts) do
    with {:ok, normalized} <- normalize_spawn(parent_sid, args, opts) do
      {:ok, materialize_spawn_spec(normalized)}
    end
  end

  defp normalize_spawn(parent_sid, %{"task" => task} = args, opts)
       when is_binary(task) and task != "" do
    workspace = Keyword.fetch!(opts, :workspace)
    agent_name = Map.get(args, "agent", "default")
    agents_opts = Keyword.get(opts, :agents_opts, [])

    with :ok <- SessionId.validate(parent_sid),
         {:ok, agent_config} <- Agents.get(agent_name, workspace, agents_opts) do
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

      requested_permission_mode =
        child_permission_mode(agent_config, Keyword.get(opts, :permission_mode, :auto))

      # Runtime-owned identity and evidence ride opts, never args. The
      # spawn_agent tool strips caller-authored runtime fields as defense in
      # depth, but this builder is the enforcement barrier: forged args values
      # for index/id are not read at all. Existing operator knobs that still
      # ride args (model, reasoning_effort, web_search, attachments) migrate
      # opportunistically; new runtime knobs must enter through opts from day
      # one.
      index = Keyword.get(opts, :index)
      # Warm-start seeding is runtime-owned lineage, so it rides opts and is never
      # read from args: a forged args value must not be able to name a seed Session.
      seed_session_id = Keyword.get(opts, :seed_session_id)

      with :ok <- validate_optional_non_negative_integer("index", index),
           {:ok, warm_start} <- validate_optional_seed(seed_session_id, workspace),
           :ok <- validate_optional_binary("model", provider_model),
           {:ok, web_search} <- validate_optional_web_search(web_search),
           :ok <- validate_optional_reasoning_effort(reasoning_effort),
           {:ok, _effective_effort} <-
             Pixir.ReasoningEffort.validate_runtime(
               Keyword.get(opts, :provider, Pixir.Provider),
               opts
               |> Keyword.get(:provider_opts, [])
               |> put_provider_knob(:model, provider_model)
               |> put_provider_knob(:reasoning_effort, reasoning_effort)
             ),
           :ok <- validate_attachments(attachments),
           :ok <- validate_positive_integer("max_threads", max_threads),
           :ok <- validate_non_negative_integer("max_depth", max_depth),
           :ok <- validate_positive_integer("timeout_ms", timeout_ms),
           :ok <- validate_non_negative_integer("retry_attempts", retry_max_attempts),
           :ok <- validate_non_negative_integer("retry_jitter_ms", retry_jitter_ms),
           {:ok, virtual_overlay} <-
             normalize_virtual_overlay_context(Keyword.get(opts, :virtual_overlay)),
           {:ok, workspace_mode} <-
             normalize_subagent_workspace_mode(workspace_mode, virtual_overlay),
           :ok <- validate_virtual_overlay_permission(workspace_mode, requested_permission_mode) do
        {:ok,
         %{
           parent_session_id: parent_sid,
           index: index,
           task: task,
           prompt: task,
           agent: agent_config.name,
           agent_config: agent_config,
           depth: Keyword.get(opts, :depth, 0) + 1,
           max_threads: max_threads,
           max_depth: max_depth,
           timeout_ms: timeout_ms,
           retry_max_attempts: retry_max_attempts,
           retry_jitter_ms: retry_jitter_ms,
           retry_attempt_index: 0,
           retry_history: [],
           workspace: workspace,
           workspace_mode: workspace_mode,
           virtual_overlay: virtual_overlay_for_mode(workspace_mode, virtual_overlay),
           provider_model: provider_model,
           reasoning_effort: reasoning_effort,
           web_search: web_search,
           attachments: attachments,
           workspace_snapshot_opts: Keyword.get(opts, :workspace_snapshot_opts, []),
           provider: Keyword.get(opts, :provider, Pixir.Provider),
           provider_opts: Keyword.get(opts, :provider_opts, []),
           permission_mode:
             virtual_overlay_permission_mode(workspace_mode, requested_permission_mode),
           write_policy: Keyword.get(opts, :write_policy),
           skills_opts: Keyword.get(opts, :skills_opts, []),
           agents_opts: agents_opts,
           delegation_context: Keyword.get(opts, :delegation_context, %{}),
           seed_session_id: seed_session_id,
           warm_start: warm_start
         }}
      end
    end
  end

  defp normalize_spawn(_parent_sid, _args, _opts),
    do: {:error, Tool.error(:invalid_args, "task is required", %{})}

  defp materialize_spawn_spec(normalized) do
    Map.merge(normalized, %{
      id: gen_id(),
      child_session_id: nil,
      child_pid: nil,
      status: "queued",
      summary: nil,
      parent_log_path: Log.path(normalized.parent_session_id, workspace: normalized.workspace),
      child_log_path: nil,
      child_workspace: nil,
      workspace_snapshot: nil,
      timer_ref: nil,
      started_at_ms: nil,
      deadline_at: nil,
      elapsed_ms: nil,
      timeout_reason: nil,
      next_actions: [],
      cancellation_evidence: nil,
      last_seen_child_event_seq: nil,
      last_seen_child_event_type: nil,
      last_seen_child_event_ts: nil,
      output_truncation: nil,
      output_warning_count: 0,
      output_warnings: [],
      output_warning_keys: MapSet.new(),
      output_warning_reasons: MapSet.new(),
      output_latest_warning_order_key: nil,
      created_at: now(),
      updated_at: now()
    })
    |> Map.put_new(:seed_session_id, nil)
    |> Map.put_new(:warm_start, nil)
  end

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

  # A bad seed reference must be rejected here, during normalization, so no child
  # Session, workspace snapshot, or partial child Log is ever created for it (#435).
  # The seed is resolved against the DELEGATE workspace, which owns the seed Log;
  # the child's snapshot workspace does not exist yet and never holds seed Logs.
  defp validate_optional_seed(nil, _workspace), do: {:ok, nil}

  defp validate_optional_seed(seed_session_id, workspace),
    do: WarmStart.validate(seed_session_id, workspace: workspace)

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
  defp validate_optional_web_search(false), do: {:ok, false}
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

  defp normalize_virtual_overlay_context(nil), do: {:ok, nil}

  defp normalize_virtual_overlay_context(config) when is_map(config) do
    read_set = manager_virtual_overlay_field(config, :read_set, "read_set")
    limits = manager_virtual_overlay_field(config, :limits, "limits")

    with :ok <- manager_validate_read_set(read_set),
         :ok <- manager_validate_virtual_limits(limits) do
      {:ok, %{read_set: read_set, limits: limits}}
    end
  end

  defp normalize_virtual_overlay_context(_config) do
    {:error,
     Tool.error(:invalid_args, "virtual_overlay context must be a map", %{
       "field" => "virtual_overlay"
     })}
  end

  defp manager_validate_read_set(read_set) do
    case VirtualOverlay.validate_read_set(read_set) do
      :ok ->
        :ok

      {:error, %{index: index, reason: reason}} ->
        {:error,
         Tool.error(:invalid_args, "virtual_overlay read_set entry is unsafe", %{
           "field" => "virtual_overlay.read_set",
           "index" => index,
           "reason" => reason
         })}

      {:error, _reason} ->
        {:error,
         Tool.error(:invalid_args, "virtual_overlay requires a non-empty read_set", %{
           "field" => "virtual_overlay.read_set"
         })}
    end
  end

  defp manager_validate_virtual_limits(limits) do
    if is_nil(limits) or is_map(limits) do
      :ok
    else
      {:error,
       Tool.error(:invalid_args, "virtual_overlay limits must be a map", %{
         "field" => "virtual_overlay.limits"
       })}
    end
  end

  defp manager_virtual_overlay_field(config, atom_key, string_key) do
    case Map.fetch(config, atom_key) do
      {:ok, value} -> value
      :error -> Map.get(config, string_key)
    end
  end

  defp normalize_subagent_workspace_mode(workspace_mode, nil),
    do: WorkspaceStrategy.normalize_runtime_mode(workspace_mode, "subagent")

  defp normalize_subagent_workspace_mode(workspace_mode, _virtual_overlay) do
    WorkspaceStrategy.normalize_runtime_mode(workspace_mode, "subagent", %{},
      supported_modes: ~w(shared isolated virtual_overlay)
    )
  end

  defp validate_virtual_overlay_permission("virtual_overlay", permission_mode)
       when permission_mode not in [:read_only, "read_only"] do
    {:error,
     Tool.error(:permission_denied, "virtual_overlay children must be read-only", %{
       "workspace_mode" => "virtual_overlay",
       "permission_mode" => to_string(permission_mode)
     })}
  end

  defp validate_virtual_overlay_permission(_workspace_mode, _permission_mode), do: :ok

  defp virtual_overlay_for_mode("virtual_overlay", virtual_overlay), do: virtual_overlay
  defp virtual_overlay_for_mode(_workspace_mode, _virtual_overlay), do: nil

  defp virtual_overlay_permission_mode("virtual_overlay", _permission_mode), do: :read_only
  defp virtual_overlay_permission_mode(_workspace_mode, permission_mode), do: permission_mode

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
    with {:ok, _effort} <-
           Pixir.ReasoningEffort.validate_runtime(agent.provider, child_provider_opts(agent)),
         {:ok, child_workspace, workspace_snapshot} <- prepare_workspace(agent),
         {:ok, allocated_sid, warm_start} <- allocate_child_session(agent, child_workspace),
         {:ok, child_sid, child_pid} <-
           start_child_session(allocated_sid, child_workspace, warm_start) do
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

      turn_agent = Map.put(turn_agent, :warm_start, warm_start)

      with :ok <- subscribe_child_events(child_sid),
           :ok <- persist_child_permission_posture(turn_agent, child_sid),
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
            output_truncation: nil,
            output_warning_count: 0,
            output_warnings: [],
            output_warning_keys: MapSet.new(),
            output_warning_reasons: MapSet.new(),
            output_latest_warning_order_key: nil,
            updated_at: now()
        }

        state =
          state
          |> put_agent(started)
          |> put_child_index(started)
          |> record_parent_event(started, "started", "running")

        {:ok, started, state}
      else
        # The child Session is already live here: a setup failure (subscription,
        # posture persistence, Turn start) must stop it and drop the subscription,
        # or a write-capable Session survives untracked. This branch also keeps
        # start_agent's contract: callers match 3-tuples only.
        {:error, error} ->
          _ = persist_child_start_failure(turn_agent, error)
          Events.unsubscribe(child_sid)
          SessionSupervisor.stop_session(child_sid)

          failed = %{turn_agent | status: "failed", summary: inspect(error), updated_at: now()}

          state =
            state
            |> put_agent(failed)
            |> record_parent_event(failed, "failed", "failed")

          {:error, error, state}
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

  # A warm-started child's Log is written to disk BEFORE its Session starts. If the
  # start then fails, that Log must go: leaving it behind strands replayed conversation
  # content under an id nothing will ever open, and breaks the same invariant the
  # rejected-seed path already holds (a failed spawn leaves .pixir/sessions untouched).
  defp start_child_session(allocated_sid, child_workspace, warm_start) do
    case SessionSupervisor.start_session(
           id: allocated_sid,
           workspace: child_workspace,
           role: :subagent
         ) do
      {:ok, _child_sid, _child_pid} = ok ->
        ok

      other ->
        if is_map(warm_start) do
          _ = File.rm_rf(Log.path(allocated_sid, workspace: child_workspace))
        end

        other
    end
  end

  # Cold children keep the historical shape exactly: the Session generates its own
  # id and opens on an empty Log. A warm-started child needs its id up front, because
  # the seeded Log must exist BEFORE the Session process folds it — that fold is what
  # derives `fork_root_session_id`, and therefore the `s_` cache-family segment, from
  # the seq-0 lineage Event (ADR 0020/0024).
  defp allocate_child_session(%{warm_start: %{} = _lineage} = agent, child_workspace) do
    child_sid = Session.gen_id()

    # The seed Log is read from the delegate workspace that owns it and written into
    # the child's workspace: an isolated child runs in a snapshot that excludes .pixir,
    # so the two are not the same directory.
    case WarmStart.seed_child_log(child_sid, agent.seed_session_id,
           workspace: agent.workspace,
           child_workspace: child_workspace,
           permission_posture: child_permission_posture_request(agent, child_workspace)
         ) do
      {:ok, lineage} -> {:ok, child_sid, lineage}
      {:error, _error} = error -> error
    end
  end

  defp allocate_child_session(_agent, _child_workspace), do: {:ok, Session.gen_id(), nil}

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
            cancellation_evidence: nil,
            updated_at: now()
        }

        state =
          state
          |> put_agent(updated)
          |> record_parent_event(updated, "input", "running", %{prompt: prompt})

        {:ok, updated, state}

      {:error, :busy} ->
        {:error, Tool.error(:permission_denied, "subagent is already running", %{id: agent.id})}

      {:error, error} ->
        {:error, error}
    end
  end

  defp restart_agent(_agent, _prompt, _opts, _state),
    do: {:error, Tool.error(:invalid_args, "prompt is required", %{})}

  # Warm children already carry this Event in the atomic seed Log immediately
  # after their runtime boundary. Appending it again after Session start would
  # split construction authority and let the earlier validation snapshot drift
  # from the lineage resolved by WarmStart's own fold.
  defp persist_child_permission_posture(%{warm_start: %{"warm_started" => true}}, _child_sid),
    do: :ok

  defp persist_child_permission_posture(agent, child_sid) do
    data =
      agent
      |> child_permission_posture_request(agent.child_workspace)
      |> Subagents.child_permission_posture(nil)

    case Session.record(child_sid, Event.subagent_event(child_sid, data)) do
      {:ok, _event} -> :ok
      {:error, _error} = error -> error
    end
  end

  defp child_permission_posture_request(agent, child_workspace) do
    %{
      subagent_id: agent.id,
      parent_session_id: agent.parent_session_id,
      permission_mode: agent.permission_mode,
      write_policy: agent.write_policy,
      workspace_mode: agent.workspace_mode,
      workspace: child_workspace
    }
  end

  # Turn-scoped cancellation statement on the CHILD's own Log (issue #444/#491).
  #
  # Reuses the `:subagent_event` seam already used for the child's permission
  # posture at spawn, and the existing `cancelled_by_parent` vocabulary: a reader
  # of the child Log alone can tell "cancelled by my parent" from "the process died
  # mid-write". The parent-side `:subagent_event`, the manager status record, and
  # the Workflow step record stay authoritative and untouched — a child Log that
  # cannot be written (child Session gone, lease lost, write error) degrades to the
  # parent-only evidence rather than failing the cancellation or killing the Manager.
  defp persist_child_cancellation(%{child_session_id: child_sid} = agent, opts)
       when is_binary(child_sid) and child_sid != "" do
    data =
      %{
        "event" => "cancelled_by_parent",
        "scope" => "turn",
        "lineage" => "child",
        "source" => "subagent_close",
        "status" => "cancelled",
        "reason" => "cancelled_by_parent",
        "subagent_id" => agent.id,
        "parent_session_id" => agent.parent_session_id,
        "child_session_id" => child_sid
      }
      # Absent, never null-filled, when no Workflow is above this cancellation.
      |> maybe_put_event("workflow_id", Keyword.get(opts, :workflow_id))
      |> maybe_put_event("workflow_step_id", Keyword.get(opts, :workflow_step_id))
      |> maybe_put_event("workflow_close_outcome", workflow_close_outcome(opts))

    case safe_record(child_sid, Event.subagent_event(child_sid, data)) do
      {:ok, _event} -> :ok
      {:error, _error} = error -> error
    end
  end

  defp persist_child_cancellation(_agent, _opts), do: {:error, :no_child_session}

  defp workflow_close_outcome(opts) do
    case Keyword.get(opts, :workflow_id) do
      id when is_binary(id) and id != "" ->
        Keyword.get(opts, :workflow_close_outcome)

      _ ->
        nil
    end
  end

  defp permission_mode_string(nil), do: nil
  defp permission_mode_string(mode) when is_atom(mode), do: Atom.to_string(mode)
  defp permission_mode_string(mode) when is_binary(mode), do: mode

  # Like cancellation evidence, setup failure is recorded without inventing a Turn.
  # A failed Log write must not prevent lease cleanup or the canonical parent failure.
  defp persist_child_start_failure(agent, error) do
    failure =
      case error do
        %{error: %{kind: kind, message: message, details: details} = failure}
        when is_atom(kind) and is_binary(message) and is_map(details) ->
          failure

        _ ->
          %{}
      end

    details = Map.get(failure, :details, %{})

    data = %{
      "event" => "child_start_failed",
      "scope" => "session",
      "lineage" => "child",
      "source" => "subagent_start",
      "status" => "failed",
      "reason" => "child_start_failed",
      "subagent_id" => agent.id,
      "parent_session_id" => agent.parent_session_id,
      "child_session_id" => agent.child_session_id,
      "error_kind" => to_string(Map.get(failure, :kind, :child_start_failed)),
      "error_message" => Map.get(failure, :message, "Subagent failed before Turn start."),
      "details" => %{
        "field" => child_failure_detail(details, :field, ""),
        "reason" => child_failure_detail(details, :reason, "child_start_failed")
      }
    }

    safe_record(agent.child_session_id, Event.subagent_event(agent.child_session_id, data))
  end

  defp child_failure_detail(details, key, default) do
    case Map.get(details, key) do
      value when is_binary(value) -> value
      value when is_atom(value) and not is_nil(value) -> Atom.to_string(value)
      _ -> default
    end
  end

  defp child_provider_opts(agent) do
    agent.provider_opts
    |> List.wrap()
    |> put_provider_knob(:model, Map.get(agent, :provider_model))
    |> put_provider_knob(:reasoning_effort, Map.get(agent, :reasoning_effort))
    |> put_provider_knob(:web_search, Map.get(agent, :web_search))
  end

  defp start_child_turn(agent, child_sid, child_workspace, turn_overrides \\ []) do
    instructions = agent.agent_config.developer_instructions

    # The Turn reads model/reasoning_effort from provider_opts (same seam ACP
    # uses for _meta knobs); a spec knob wins over any inherited default.
    provider_opts = child_provider_opts(agent)

    # Admission is checked again for queued children and follow-up Turns:
    # defaults may have changed since the original spawn was normalized.
    with {:ok, _effort} <- Pixir.ReasoningEffort.validate_runtime(agent.provider, provider_opts) do
      Session.start_turn(child_sid, fn ctx ->
        Turn.run(%{ctx | workspace: child_workspace}, agent.prompt,
          provider: agent.provider,
          provider_opts: provider_opts,
          permission_mode: agent.permission_mode,
          attachments:
            Keyword.get(turn_overrides, :attachments, Map.get(agent, :attachments, [])),
          write_policy: agent.write_policy,
          skills_opts: agent.skills_opts,
          agents_opts: agent.agents_opts,
          subagent_depth: agent.depth,
          virtual_overlay: Map.get(agent, :virtual_overlay),
          agent_instructions: instructions,
          delegation_context: DelegationContext.from_agent(agent)
        )
      end)
    end
  end

  defp put_provider_knob(opts, _key, nil), do: opts
  defp put_provider_knob(opts, key, value), do: Keyword.put(opts, key, value)

  defp subscribe_child_events(child_sid),
    do: Events.subscribe(child_sid, only: @manager_child_event_types)

  defp prepare_workspace(%{workspace_mode: "virtual_overlay", workspace: workspace}),
    do: {:ok, workspace, nil}

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

  defp handle_child_event(parent_sid, id, %{type: :provider_usage} = event, state) do
    {:ok, agent} = fetch_agent(state, parent_sid, id)
    projection = OutputTruncationSummary.project(event)
    warning = OutputTruncationSummary.warning(event)

    agent =
      if projection["call_role"] == "final_answer" do
        %{agent | output_truncation: projection}
      else
        agent
      end

    agent = if warning, do: track_child_warning(agent, event, warning), else: agent
    {:noreply, put_agent(state, %{agent | updated_at: now()})}
  end

  defp handle_child_event(
         parent_sid,
         id,
         %{type: :assistant_message, data: %{"text" => text} = data} = event,
         state
       ) do
    {:ok, agent} = fetch_agent(state, parent_sid, id)

    agent =
      case OutputTruncationSummary.assistant_fallback(event) do
        {:ok, projection, warning} ->
          agent
          |> Map.put(:output_truncation, projection)
          |> track_child_warning(event, warning)

        :error ->
          agent
      end

    summary =
      if partial_assistant?(data) do
        agent.summary
      else
        text
      end

    {:noreply, put_agent(state, %{agent | summary: summary, updated_at: now()})}
  end

  defp handle_child_event(
         parent_sid,
         id,
         %{type: :status, data: %{"status" => "done"}},
         state
       ) do
    {:ok, agent} = fetch_agent(state, parent_sid, id)

    if agent.workspace_mode == "virtual_overlay" do
      finish_virtual_overlay_agent(parent_sid, agent, state)
    else
      finish_completed_agent(parent_sid, agent, state)
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

      agent = maybe_attach_virtual_diff_after_failure(agent)

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

  defp track_child_warning(agent, event, warning) do
    key = {event.session_id, warning["provider_usage_event_id"]}
    order_key = {warning["provider_usage_seq"], warning["provider_usage_event_id"]}

    cond do
      MapSet.member?(agent.output_warning_keys, key) ->
        agent

      not is_nil(agent.output_latest_warning_order_key) and
          order_key <= agent.output_latest_warning_order_key ->
        agent

      MapSet.size(agent.output_warning_keys) < 64 ->
        child_warning =
          warning
          |> Map.put("child_session_id", event.session_id)

        %{
          agent
          | output_warning_count: agent.output_warning_count + 1,
            output_warnings: agent.output_warnings ++ [child_warning],
            output_warning_keys: MapSet.put(agent.output_warning_keys, key),
            output_warning_reasons: MapSet.put(agent.output_warning_reasons, warning["reason"]),
            output_latest_warning_order_key: order_key
        }

      true ->
        %{
          agent
          | output_warning_count: agent.output_warning_count + 1,
            output_warning_reasons: MapSet.put(agent.output_warning_reasons, warning["reason"]),
            output_latest_warning_order_key: order_key
        }
    end
  end

  defp finish_completed_agent(_parent_sid, agent, state) do
    if Subagents.terminal?(agent.status) do
      {:noreply, state}
    else
      summary = agent.summary || latest_child_answer(agent)
      # elapsed_ms alongside status, like the failed/timeout/cancelled paths:
      # terminal_event_fields drops it otherwise, and a successful completion
      # would lose its duration in the parent Log and after cold restore.
      agent = %{
        agent
        | status: "completed",
          summary: summary,
          elapsed_ms: elapsed_ms(agent),
          updated_at: now()
      }

      state =
        state
        |> put_agent(agent)
        |> cancel_timer(agent)
        |> record_parent_event(
          agent,
          "finished",
          "completed",
          terminal_event_fields(agent)
        )
        |> maybe_start_queued(agent.parent_session_id)
        |> reply_waiters()

      {:noreply, state}
    end
  end

  defp finish_virtual_overlay_agent(_parent_sid, agent, state) do
    if Subagents.terminal?(agent.status) do
      {:noreply, state}
    else
      case select_virtual_diff(agent) do
        {:ok, artifact, ref} ->
          summary = agent.summary || latest_child_answer(agent)

          agent =
            Map.merge(agent, %{
              status: "completed",
              summary: summary,
              elapsed_ms: elapsed_ms(agent),
              virtual_diff: artifact,
              virtual_diff_ref: ref,
              updated_at: now()
            })

          state =
            state
            |> put_agent(agent)
            |> cancel_timer(agent)
            |> record_parent_event(
              agent,
              "finished",
              "completed",
              terminal_event_fields(agent)
            )
            |> maybe_start_queued(agent.parent_session_id)
            |> reply_waiters()

          {:noreply, state}

        {:error, "virtual_diff_oversize", ref} ->
          fail_virtual_overlay_agent(agent, state, "virtual_diff_oversize", ref)

        {:error, "virtual_diff_missing", nil} ->
          fail_virtual_overlay_agent(agent, state, "virtual_diff_missing", nil)
      end
    end
  end

  defp fail_virtual_overlay_agent(agent, state, reason, ref) do
    next_actions = ["inspect_child_session_log", "rerun_virtual_overlay_child"]

    agent =
      Map.merge(agent, %{
        status: "failed",
        summary: "Virtual overlay child finished without an exportable virtual_diff artifact.",
        elapsed_ms: elapsed_ms(agent),
        timeout_reason: reason,
        next_actions: next_actions,
        virtual_diff_ref: ref,
        updated_at: now()
      })

    state =
      state
      |> put_agent(agent)
      |> cancel_timer(agent)
      |> record_parent_event(agent, "failed", "failed", terminal_event_fields(agent))
      |> maybe_start_queued(agent.parent_session_id)
      |> reply_waiters()

    {:noreply, state}
  end

  defp maybe_attach_virtual_diff_after_failure(%{workspace_mode: "virtual_overlay"} = agent) do
    case select_virtual_diff(agent) do
      {:ok, artifact, ref} ->
        Map.merge(agent, %{virtual_diff: artifact, virtual_diff_ref: ref})

      {:error, "virtual_diff_oversize", ref} ->
        Map.put(agent, :virtual_diff_ref, ref)

      {:error, "virtual_diff_missing", nil} ->
        agent
    end
  end

  defp maybe_attach_virtual_diff_after_failure(agent), do: agent

  defp select_virtual_diff(agent) do
    with {:ok, history} <- Log.fold(agent.child_session_id, workspace: agent.child_workspace),
         {artifact, source_seq} <-
           find_last_virtual_diff(history, virtual_delivery_boundary(agent)) do
      encoded = Jason.encode!(artifact)
      ref = virtual_diff_ref(artifact, encoded, source_seq)

      if byte_size(encoded) <= @virtual_diff_max_encoded_bytes do
        {:ok, artifact, ref}
      else
        {:error, "virtual_diff_oversize", ref}
      end
    else
      _other -> {:error, "virtual_diff_missing", nil}
    end
  end

  # Reuse the existing validated runtime lineage proof, rather than treating a
  # user-authored marker or final prose as authority over delivery selection.
  defp virtual_delivery_boundary(agent) do
    case Subagents.warm_lineage_proof(agent.child_session_id, workspace: agent.child_workspace) do
      {:ok, %{boundary_event: boundary}} -> boundary.id
      _other -> nil
    end
  end

  defp find_last_virtual_diff(history, boundary_id) do
    {_calls, latest, explicit} =
      Enum.reduce(history, {%{}, nil, nil}, fn event, {calls, latest, explicit} = acc ->
        cond do
          not is_nil(boundary_id) and event.id == boundary_id ->
            # Keep legacy latest-artifact fallback, but never inherit the seed's
            # explicit delivery intent or pair its calls with live child results.
            {%{}, latest, nil}

          event.type == :tool_call ->
            key = {event.session_id, event.data["call_id"]}
            intent = virtual_call_intent(event.data)
            intent = if Map.has_key?(calls, key), do: :invalid, else: intent
            {Map.put(calls, key, intent), latest, explicit}

          event.type == :tool_result ->
            key = {event.session_id, event.data["call_id"]}
            {intent, calls} = Map.pop(calls, key, :invalid)

            case virtual_result_candidate(event, intent) do
              {:ok, artifact, marked} ->
                selected = {artifact, event.seq}
                {calls, selected, if(marked, do: selected, else: explicit)}

              :invalid ->
                {calls, latest, explicit}
            end

          true ->
            acc
        end
      end)

    explicit || latest
  end

  defp virtual_call_intent(%{"name" => "run_virtual_commands", "call_id" => id, "args" => args})
       when is_binary(id) and is_map(args) do
    flag = Map.get(args, "deliverable", false)
    commands = Map.get(args, "commands", [])

    if is_boolean(flag) and is_list(commands) and Enum.all?(commands, &is_binary/1) and
         Map.keys(args) -- ["commands", "deliverable"] == [] and
         (not flag or Map.has_key?(args, "commands")) do
      flag
    else
      :invalid
    end
  end

  defp virtual_call_intent(_data), do: :invalid

  defp virtual_result_candidate(
         %{
           data: %{"ok" => true, "virtual_diff" => %{"kind" => "virtual_diff"} = artifact} = data
         },
         intent
       )
       when is_boolean(intent) do
    # A marker alone is not authority: both the genuine call and its one matching
    # successful result must carry true intent. Reject mismatches even as fallback.
    if Map.get(data, "deliverable", false) === intent and data["dry_run"] != true do
      {:ok, artifact, intent}
    else
      :invalid
    end
  end

  defp virtual_result_candidate(_event, _intent), do: :invalid

  defp virtual_diff_ref(artifact, encoded, source_seq) do
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

  # A late timeout or cancel can race a child Session that already terminated. Return a
  # bounded evidence classification rather than leaking or discarding the raw call result:
  # the Manager may still fence its local running authority when the child is absent, while
  # honestly projecting that the Session-owned interruption evidence is incomplete.
  defp safe_interrupt(session_id) do
    case Session.interrupt(session_id) do
      :ok -> :complete
      {:error, :no_turn} -> :complete
      {:error, _error} -> :partial
    end
  catch
    :exit, _reason -> :partial
  end

  defp close_or_cancel_agent(%{status: "running"} = agent, opts) do
    interrupt_evidence = safe_interrupt(agent.child_session_id)

    # This follows the synchronous interrupt result, but it is not promised physically
    # list-last: an unlinked declaration producer may survive the logical Turn fence and
    # append a later C6-classified straggler under its original compound identity.
    child_event_evidence =
      case persist_child_cancellation(agent, opts) do
        :ok -> :complete
        {:error, _error} -> :partial
      end

    cancellation_evidence =
      Subagents.cancellation_evidence(
        interrupt_evidence == :complete,
        child_event_evidence == :complete
      )

    {%{
       agent
       | status: "cancelled",
         summary: "Subagent was cancelled by parent before completion.",
         elapsed_ms: elapsed_ms(agent),
         timeout_reason: "cancelled_by_parent",
         next_actions: interrupted_next_actions(agent),
         cancellation_evidence: cancellation_evidence,
         updated_at: now()
     }, "cancelled"}
  end

  defp close_or_cancel_agent(%{status: "queued"} = agent, _opts) do
    {%{
       agent
       | status: "closed",
         summary: "Subagent was closed before it started.",
         timeout_reason: "closed_before_start",
         next_actions: cleanup_next_actions(agent),
         updated_at: now()
     }, "closed"}
  end

  defp close_or_cancel_agent(agent, _opts) do
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
    workspace = Keyword.get(opts, :workspace) || live_parent_workspace(parent_sid)
    state = ensure_parent(state, parent_sid)
    parent = Map.fetch!(state.parents, parent_sid)

    if parent.restored do
      state
    else
      case parent_history(parent_sid, workspace) do
        {:ok, []} ->
          mark_parent_restored(state, parent_sid)

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

  defp live_parent_workspace(parent_sid) do
    case Session.info(parent_sid) do
      %{workspace: workspace} when is_binary(workspace) and workspace != "" -> workspace
      _other -> nil
    end
  catch
    :exit, _reason -> nil
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
    output = OutputTruncationSummary.normalize_child_output(data)

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
      output_truncation: restored_output_truncation(output, terminal.status),
      output_warning_count: output["output_warning_count"],
      output_warnings: output["output_warnings"],
      output_warning_keys: restored_warning_keys(output),
      output_warning_reasons: MapSet.new(output["output_warning_reasons"]),
      output_latest_warning_order_key: output["output_latest_warning_order_key"],
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
      cancellation_evidence:
        Subagents.normalize_cancellation_evidence(data["cancellation_evidence"]),
      last_seen_child_event_seq: nil,
      last_seen_child_event_type: nil,
      last_seen_child_event_ts: nil,
      workspace: workspace || File.cwd!(),
      child_workspace: data["workspace"],
      workspace_mode: data["workspace_mode"] || "isolated",
      workspace_snapshot: data["workspace_snapshot"],
      workspace_snapshot_opts: [],
      delegation_context: data["delegation_context"] || %{},
      seed_session_id: get_in(data, ["warm_start", "seed_session_id"]),
      warm_start: restored_warm_start(data["warm_start"]),
      retry_attempt_index: data["retry_attempts"] || 0,
      retry_max_attempts: data["retry_max_attempts"] || Subagents.default_limits().retry_attempts,
      retry_jitter_ms: Subagents.default_limits().retry_jitter_ms,
      retry_history: data["retry_history"] || [],
      virtual_diff: nil,
      virtual_diff_ref: data["virtual_diff_ref"],
      provider: nil,
      provider_opts: [],
      permission_mode: restored_permission_mode(data["permission_mode"]),
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

  # A cold child restores to `nil`, which is exactly what `envelope_projection/1`
  # already renders as the cold shape — so a parent Log written before this field
  # existed reconstructs to the same envelope it reported live.
  defp restored_warm_start(%{"warm_started" => true} = lineage), do: lineage
  defp restored_warm_start(_lineage), do: nil

  defp restored_permission_mode("auto"), do: :auto
  defp restored_permission_mode("ask"), do: :ask
  defp restored_permission_mode("read_only"), do: :read_only
  defp restored_permission_mode(_mode), do: nil

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
          cancellation_evidence:
            restored.cancellation_evidence || Map.get(live, :cancellation_evidence),
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
    presenter_liveness_count = Enum.count(agents, &presenter_liveness?(&1, waiters))
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
      "presenter_liveness_count" => presenter_liveness_count,
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

  defp presenter_liveness?(%{status: "running"} = agent, _waiters),
    do: active_agent_hang_cap?(agent)

  defp presenter_liveness?(%{status: "queued"} = agent, waiters) do
    retry_attempt_index(agent) > 0 and Enum.any?(waiters, &active_waiter_for?(&1, agent.id))
  end

  defp presenter_liveness?(_agent, _waiters), do: false

  defp active_agent_hang_cap?(agent) do
    is_integer(agent.timeout_ms) and agent.timeout_ms > 0 and
      is_binary(agent.deadline_at) and is_reference(agent.timer_ref)
  end

  defp active_waiter_for?(waiter, id) do
    is_integer(waiter.timeout_ms) and waiter.timeout_ms > 0 and
      is_reference(waiter.timer_ref) and id in waiter.ids
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
        "output_truncation" => agent.output_truncation,
        "output_warning_count" => agent.output_warning_count,
        "output_warnings" => agent.output_warnings,
        "output_warning_reasons" =>
          agent.output_warning_reasons |> MapSet.to_list() |> Enum.sort(),
        "output_warnings_truncated" => agent.output_warning_count > length(agent.output_warnings),
        "parent_log_path" => parent_log_path(agent)
      }
      |> maybe_put_event("index", Map.get(agent, :index))
      |> maybe_put_event("model", Map.get(agent, :provider_model))
      |> maybe_put_event("reasoning_effort", Map.get(agent, :reasoning_effort))
      |> maybe_put_event("web_search", Map.get(agent, :web_search))
      |> maybe_put_event("permission_mode", permission_mode_string(agent.permission_mode))
      |> maybe_put_event("deadline_at", agent.deadline_at)
      |> maybe_put_event("child_log_path", child_log_path(agent))
      |> maybe_put_event("workspace_snapshot", agent.workspace_snapshot)
      |> maybe_put_event("write_policy", WritePolicy.metadata(Map.get(agent, :write_policy)))
      # The parent Log is the ONLY durable evidence `restored_agent/3` reads, so
      # lineage that is not written here does not survive a Manager restart: the
      # envelope would silently downgrade a warm child to the cold projection (#435).
      |> Map.put("warm_start", WarmStart.envelope_projection(Map.get(agent, :warm_start)))
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
    |> maybe_put_public("cancellation_evidence", Map.get(agent, :cancellation_evidence))
    |> maybe_put_public("virtual_diff", Map.get(agent, :virtual_diff))
    |> maybe_put_public("virtual_diff_ref", Map.get(agent, :virtual_diff_ref))
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
      "output_truncation" => agent.output_truncation,
      "output_warning_count" => agent.output_warning_count,
      "output_warnings" => agent.output_warnings,
      "output_warning_reasons" => agent.output_warning_reasons |> MapSet.to_list() |> Enum.sort(),
      "output_warnings_truncated" => agent.output_warning_count > length(agent.output_warnings),
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
    |> Map.put("warm_start", WarmStart.envelope_projection(Map.get(agent, :warm_start)))
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

  defp restored_output_truncation(%{"output_truncation" => evidence}, _status)
       when is_map(evidence),
       do: evidence

  defp restored_output_truncation(_output, "completed"),
    do: OutputTruncation.to_event_data(OutputTruncation.unknown(:historical_evidence_absent))

  defp restored_output_truncation(_output, _status), do: nil

  defp restored_warning_keys(data) do
    data
    |> Map.get("output_warnings", [])
    |> Enum.reduce(MapSet.new(), fn warning, keys ->
      case {warning["child_session_id"], warning["provider_usage_event_id"]} do
        {sid, event_id} when is_binary(sid) and is_binary(event_id) ->
          MapSet.put(keys, {sid, event_id})

        _ ->
          keys
      end
    end)
  end

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
    |> maybe_put_event("cancellation_evidence", Map.get(agent, :cancellation_evidence))
    |> maybe_put_event("virtual_diff_ref", Map.get(agent, :virtual_diff_ref))
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
