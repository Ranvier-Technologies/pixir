defmodule Pixir.Turn do
  @moduledoc """
  The tool loop (CONTEXT.md "Turn"): one input-to-final-answer cycle, run inside the
  Session's supervised Task (ADR 0001).

      record user_message
      loop:
        fold History → call the Provider (streaming deltas as ephemeral Events)
        if the model returned function_calls → run each via the Executor
          (which records tool_call / tool_result), then repeat
        else record the final assistant_message and stop
        if the provider fails → record turn_failed; preserve useful partial text
          as audit-only partial assistant evidence

  History is always re-derived from the Log each iteration (ADR 0003): the stateless
  Provider sees tool results because they were persisted, not because we threaded them
  in memory.

  Wire it into a Session like:

      Pixir.Session.start_turn(sid, fn ctx -> Pixir.Turn.run(ctx, prompt) end)

  Options: `:provider` (module, default `Pixir.Provider`), `:provider_opts` (passed to
  the provider — e.g. `:auth`, `:transport`), `:dry_run` (Turn-level dry-run, ADR
  0005), `:max_iterations`, `:bash_timeout_ms` for per-Turn bash execution, and
  `:delegation_context` for Subagent child Turns.
  """

  require Logger

  alias Pixir.{
    Compaction,
    Config,
    Event,
    RecoveryCommands,
    Session,
    SessionResources,
    Skills,
    Tool
  }

  alias Pixir.Provider.{Cache, ContextWindow}
  alias Pixir.Providers.Registry, as: ProviderRegistry
  alias Pixir.Tools.{Executor, Registry}

  @default_max_iterations :infinity
  @presenter_context_max_items 12
  @presenter_context_max_text 1_200
  @overflow_recovery_tail_attempts [40, 20, 10, 5]

  @type ctx :: %{
          :session_id => String.t(),
          :workspace => String.t(),
          :role => atom(),
          # Fork family (ADR 0020): a fork passes its fork-tree ROOT session id so the
          # whole tree shares one prompt-cache family. No producer sets this yet (fork
          # UX is post-v0.1); whoever builds it must thread the key through
          # Session.start_turn's ctx or every fork silently gets a cold cache family.
          optional(:fork_root_session_id) => String.t()
        }

  @doc "Run one Turn for `user_text`. Returns `{:ok, final_text}` or a structured error."
  @spec run(ctx(), String.t(), keyword()) :: {:ok, String.t()} | {:error, map()}
  def run(ctx, user_text, opts \\ []) do
    sid = ctx.session_id
    skills_opts = Keyword.get(opts, :skills_opts, [])

    record_explicit_skill_activations(sid, ctx.workspace, user_text, skills_opts)

    with {:ok, resources} <-
           SessionResources.ingest_attachments(
             sid,
             Keyword.get(opts, :attachments, []),
             workspace: ctx.workspace
           ),
         {:ok, _} <-
           Session.record(sid, Event.user_message(sid, user_text, resources: resources)) do
      run_after_user_message(ctx, user_text, opts, resources, skills_opts)
    end
  end

  defp run_after_user_message(ctx, _user_text, opts, _resources, skills_opts) do
    provider_opts = opts |> Keyword.get(:provider_opts, []) |> Config.merge_provider_opts()
    bash_timeout_ms = Keyword.get(opts, :bash_timeout_ms)

    bash_timeout_source =
      if bash_timeout_ms, do: Keyword.get(opts, :bash_timeout_source, "context")

    mode = normalize_mode(Keyword.get(opts, :mode, :build))

    provider =
      Keyword.get(opts, :provider) || ProviderRegistry.resolve(provider_opts[:model]).provider

    state = %{
      provider: provider,
      provider_opts: provider_opts,
      skills_opts: skills_opts,
      agents_opts: Keyword.get(opts, :agents_opts, []),
      subagent_depth: Keyword.get(opts, :subagent_depth, 0),
      agent_instructions: Keyword.get(opts, :agent_instructions),
      presenter_context: Keyword.get(opts, :presenter_context),
      delegation_context: Keyword.get(opts, :delegation_context),
      # Model that will produce reasoning items this Turn — stamped on each `reasoning`
      # event so replay can drop items captured under a different model (ADR 0007).
      model: provider_opts[:model] || ProviderRegistry.entry_for(provider).default_model,
      dry_run: Keyword.get(opts, :dry_run, false),
      # ADR 0020 overflow recovery uses a finite tail-shrinking sequence. A
      # compacted retry can still overflow on smaller-window models, so subsequent
      # :context_overflow failures in the same Turn consume the next smaller tail
      # instead of giving up after the first recorded checkpoint.
      overflow_recovery_tail_attempts: @overflow_recovery_tail_attempts,
      # The interaction mode (`:build` | `:plan`, default `:build`). In `:plan`
      # the Turn instructs the model to plan (not act) and the permission posture
      # is forced to `:read_only`, so mutating tools are denied (plan-and-wait,
      # D.3) — regardless of any caller-supplied permission_mode.
      mode: mode,
      cap:
        opts
        |> Keyword.get(:max_iterations, default_max_iterations())
        |> normalize_max_iterations(),
      bash_timeout_ms: bash_timeout_ms,
      bash_timeout_source: bash_timeout_source,
      permission: %{
        mode: permission_mode(mode, Keyword.get(opts, :permission_mode, :auto)),
        asker: Keyword.get(opts, :asker, fn _request -> :deny end),
        policy: Keyword.get(opts, :write_policy)
      }
    }

    loop(ctx, 0, state)
  end

  # Accept a string ("plan"/"build") or atom mode from the front-end seam.
  defp normalize_mode(mode) when mode in [:plan, "plan"], do: :plan
  defp normalize_mode(_other), do: :build

  # Plan mode is read-only by definition; otherwise honor the caller's posture.
  defp permission_mode(:plan, _requested), do: :read_only
  defp permission_mode(_build, requested), do: requested

  defp maybe_put_provider_request(request, _key, nil), do: request
  defp maybe_put_provider_request(request, key, value), do: Map.put(request, key, value)

  defp reasoning_dialect(provider),
    do: ProviderRegistry.entry_for(provider).capabilities.reasoning_dialect

  defp provider_tool_specs(provider) do
    case ProviderRegistry.entry_for(provider).capabilities.tool_dialect do
      :anthropic -> Registry.anthropic_specs()
      :responses -> Registry.responses_specs()
    end
  end

  defp reasoning_event_opts(state) do
    case reasoning_dialect(state.provider) do
      dialect when is_binary(dialect) -> [dialect: dialect]
      _ -> []
    end
  end

  @doc "Default tool-loop iteration cap. `:infinity` means no cap."
  def default_max_iterations,
    do:
      :pixir
      |> Application.get_env(:tool_loop_max, @default_max_iterations)
      |> normalize_max_iterations()

  # ── px2 Prompt Contract (ADR 0020) ──────────────────────────────────────────
  #
  # Layer 0 below is byte-identical for every Session in every Workspace: it names
  # no workspace path, no branch, no mode-of-the-day facts. Those are late
  # developer context (an input item built by `developer_context/2`), because
  # authority is carried by role, not position — and the cacheable prefix must
  # stay stable. Layer 1 (the Skills index) is project-stable and appended after.

  @repo_instructions """
  Repository instructions: projects may contain one or more AGENTS.md files. Before
  making or reviewing code changes, inspect the relevant instructions with read or
  bash. Start at the workspace root, then read the nearest AGENTS.md for directories
  you touch. In monorepos, local instructions override broader ones for their
  subtree. Do not rely on stale remembered instructions when the file can be read.
  """

  @checkpoint_contract """
  Compacted history: if a "Compressed session memory" checkpoint appears in the
  conversation, treat it as lossy older context. Recent messages and the current
  request override stale checkpoint intent; the full session log remains
  authoritative outside the conversation.
  """

  # The shared Layer 0 tail, composed at compile time so the two mode prompts can
  # never drift apart paragraph-by-paragraph (their shared layers are one constant).
  @layer0_tail String.trim(@repo_instructions) <> "\n\n" <> String.trim(@checkpoint_contract)

  @doc """
  The default system prompt for a Turn (open knob). `mode` defaults to `:build`.

  px2 pairing contract (ADR 0020): this prompt is byte-stable per mode and names no
  workspace. It tells the model a developer message identifies the workspace root, so
  any direct `Provider.stream` caller using this prompt MUST also pass
  `developer_context: Turn.developer_context(ctx, mode, permission_mode)` — otherwise
  the model is promised a message that never arrives and has no workspace root at all.
  """
  @spec system_prompt(ctx(), :build | :plan, keyword()) :: String.t()
  def system_prompt(ctx, mode \\ :build, skills_opts \\ [])

  def system_prompt(ctx, :plan, skills_opts) do
    base = """
    You are Pixir, a terminal coding agent.
    You are in PLAN MODE: investigate with read-only tools (read, and safe shell
    commands like grep/ls) and produce a clear, step-by-step plan. Do NOT modify
    files or run mutating commands — write/edit and unsafe shell are disabled in
    this mode and will be refused. Call the `update_plan` tool to record the plan
    as a checklist, then STOP and let the user review it. They will switch to
    build mode and re-prompt to execute. All paths are relative to the workspace;
    a developer message in the conversation identifies the workspace root.

    #{@layer0_tail}
    """

    append_skills_index(base, ctx, skills_opts)
  end

  def system_prompt(ctx, _build, skills_opts) do
    base = """
    You are Pixir, a terminal coding agent.
    Use the tools (read, write, bash) to inspect and change files and run commands.
    All paths are relative to the workspace; a developer message in the conversation
    identifies the workspace root. Prefer taking actions with tools over describing
    them, work step by step, and end with a concise summary of what you did.

    #{@layer0_tail}
    """

    append_skills_index(base, ctx, skills_opts)
  end

  @doc """
  The late developer-context input item text (px2 Layer 2): the volatile,
  session-scoped facts deliberately kept OUT of the cacheable instructions prefix.
  Pairs with `system_prompt/3` — see its doc for the pairing contract.

  The base text is deliberately byte-stable across plan/build flips (mode is already
  fully expressed by the instructions, and a changed `input[0]` would break WebSocket
  continuation's prefix-extension check). The base variation is a posture line when the
  EFFECTIVE permission deviates from the mode's default: a build-mode Turn forced
  read-only — the one case the instructions cannot know about.

  Presenter-supplied UX context is appended here as late, non-authoritative developer
  context. Presenters such as T3 Code may supply open-file, selection, branch, or
  diagnostic facts, but Pixir still renders them into Provider input itself.

  Subagent Delegation Context is appended here too: child-specific ids, limits,
  deadlines, and Workflow step facts are authoritative for this Turn but deliberately
  excluded from the stable instructions prefix.
  """
  @spec developer_context(ctx(), :build | :plan, atom(), term(), term()) :: String.t()
  def developer_context(
        ctx,
        mode,
        permission_mode \\ :auto,
        presenter_context \\ nil,
        delegation_context \\ nil
      ) do
    posture =
      if mode == :build and permission_mode == :read_only do
        " Permission posture: read-only — write/edit and unsafe shell will be refused."
      else
        ""
      end

    base = ~s(Developer context: the workspace root is "#{ctx.workspace}".#{posture})

    base
    |> append_late_context(
      "Presenter-supplied UX context (late, non-authoritative UI facts):",
      presenter_context_text(presenter_context)
    )
    |> append_late_context(
      "Subagent delegation context:",
      delegation_context_text(delegation_context)
    )
  end

  # ── loop ──────────────────────────────────────────────────────────────────

  defp loop(ctx, iteration, state) do
    sid = ctx.session_id
    Session.emit(sid, Event.status(sid, "thinking"))

    {:ok, history} = Session.history(sid)

    # Preflight: if the latest provider_usage left the session in "critical" pressure
    # (per the local gauge) and no subsequent compaction has relieved it, compact now
    # *before* building the provider request for this turn. This is deliberate,
    # recorded (history_compaction with trigger "critical_pressure_preflight"), and
    # visible. See ADR 0020 update.
    history = maybe_preflight_critical_compaction(ctx, history)

    tools = provider_tool_specs(state.provider)
    system_prompt = system_prompt(ctx, state.mode, state.skills_opts, state.agent_instructions)
    cache_metadata = cache_metadata(ctx, state, tools) |> provider_cache_metadata(state.provider)

    request =
      %{
        system_prompt: system_prompt,
        developer_context:
          developer_context(
            ctx,
            state.mode,
            state.permission.mode,
            state.presenter_context,
            state.delegation_context
          ),
        workspace: ctx.workspace,
        history: history,
        tools: tools,
        prompt_cache_key: cache_metadata["prompt_cache_key"]
      }
      |> maybe_put_provider_request(:web_search, state.provider_opts[:web_search])

    {:ok, delta_acc} = Agent.start_link(fn -> [] end)

    try do
      provider_opts =
        state.provider_opts
        |> Keyword.put(:on_delta, delta_handler(sid, delta_acc))
        |> Keyword.put_new(:session_id, sid)

      case state.provider.stream(request, provider_opts) do
        {:ok, %{finish_reason: :stop} = result} ->
          with :ok <-
                 record_provider_usage(sid, result, state, cache_metadata, iteration, history) do
            finish(sid, result.text)
          end

        {:ok, %{finish_reason: :tool_calls, function_calls: calls} = result} ->
          with :ok <-
                 record_provider_usage(sid, result, state, cache_metadata, iteration, history) do
            continue_or_cap(
              ctx,
              iteration,
              state,
              calls,
              result[:reasoning_items] || [],
              result[:output_items] || []
            )
          end

        {:error, error} ->
          handle_provider_error(ctx, iteration, state, error, history, streamed_text(delta_acc))
      end
    after
      if Process.alive?(delta_acc), do: Agent.stop(delta_acc)
    end
  end

  defp handle_provider_error(ctx, iteration, state, error, history, partial_text) do
    case recover_from_overflow(ctx, state, error, history) do
      {:recovered, new_state} ->
        # History is re-folded at the top of the loop (see recover_from_overflow).
        # The returned new_state carries the shrunk overflow_recovery_tail_attempts.
        loop(ctx, iteration, new_state)

      :no_recovery ->
        case maybe_recover_from_critical_transport(ctx, state, error, history) do
          {:recovered, new_state} ->
            # Same pattern: compaction recorded + updated attempt list.
            loop(ctx, iteration, new_state)

          :no_recovery ->
            finish_provider_error(ctx.session_id, error, partial_text)
        end
    end
  end

  defp finish_provider_error(sid, error, partial_text) do
    case useful_partial_text(partial_text) do
      {:ok, text} ->
        failure_data =
          error
          |> turn_failure_data(sid)
          |> put_in(["details", "partial_text_length"], String.length(text))

        {:ok, _} =
          Session.record(
            sid,
            Event.assistant_message(sid, text,
              metadata: %{
                "partial" => true,
                "terminal_status" => failure_data["terminal_status"],
                "error_kind" => failure_data["error_kind"],
                "error_message" => failure_data["error_message"]
              }
            )
          )

        {:ok, _} = Session.record(sid, Event.turn_failed(sid, failure_data))
        Session.emit(sid, Event.status(sid, "error"))
        {:error, error}

      :none ->
        # Surface the failure as content before the terminal status, so a front-end
        # shows *why* the turn failed instead of an empty turn (ADR 0009 §4). This
        # path also records audit-only failure evidence so the Log accounts for
        # the terminal Turn without pretending there was assistant text.
        {:ok, _} =
          Session.record(
            sid,
            Event.turn_failed(sid, turn_failure_data(error, sid))
          )

        Session.emit(sid, Event.text_delta(sid, human_error(error)))
        Session.emit(sid, Event.status(sid, "error"))
        {:error, error}
    end
  end

  defp turn_failure_data(error, sid) do
    kind = error_kind(error)

    %{
      "terminal_status" => "provider_error",
      "error_kind" => kind,
      "error_message" => human_error(error),
      "details" => Map.merge(error_details(error), recovery_details(sid, kind))
    }
  end

  defp recovery_details(sid, "stream_idle_timeout") do
    {:ok, commands} = RecoveryCommands.commands(sid)

    %{
      "recovery" => %{
        "classification" => "provider_stream_idle_timeout",
        "diagnose_command" => commands["diagnose_command"],
        "resume_command" => commands["resume_command"],
        "auto_retry" => %{
          "safe" => false,
          "reason" => "automatic replay after an ambiguous idle timeout may duplicate writes"
        },
        "next_actions" => [
          "inspect diagnostics before resuming write-capable work",
          "resume manually with the provided command if the Log shows no unsafe duplicate side effects",
          "do not treat Provider continuation state as durable truth"
        ]
      }
    }
  end

  defp recovery_details(_sid, _kind), do: %{}

  # Recovery after failure (ADR 0020): an actual Provider :context_overflow rejection
  # triggers the classic path. In addition, preflight compaction runs *before* a
  # Provider call when the last provider_usage showed "critical" pressure, and a
  # pragmatic recovery path exists for low-level transport failures (e.g. WebSocket
  # "Could not read frame") when recent pressure was critical. All paths record an
  # explicit canonical history_compaction with a clear trigger.
  #
  # Recovery is finite but iterative. A compacted retry can still overflow on a
  # smaller-window model or after a very large recent tail, so each subsequent
  # :context_overflow in the same Turn consumes the next smaller tail attempt
  # (40 → 20 → 10 → 5). If even the floor leaves nothing compactable, or every
  # tail has already been tried, the structured Provider error is surfaced.
  defp recover_from_overflow(
         ctx,
         %{overflow_recovery_tail_attempts: [_ | _] = attempts} = state,
         %{error: %{kind: :context_overflow}},
         history
       ) do
    sid = ctx.session_id

    case compact_for_recovery(sid, ctx.workspace, attempts) do
      {:ok, result, tail_events, remaining_attempts} ->
        range = result["event"]["range"] || %{}

        message =
          "Provider rejected the request as a context overflow; recorded a recovery " <>
            "compaction checkpoint for seq #{range["from_seq"]}..#{range["to_seq"]} " <>
            "with tail_events #{tail_events} and retrying with compacted history."

        Session.emit(
          sid,
          Event.context_pressure(
            sid,
            recovery_notice_data(
              history,
              %{
                "tier" => "recovery",
                "trigger" => "overflow_recovery",
                "checkpoint_to_seq" => range["to_seq"],
                "tail_events" => tail_events,
                "remaining_tail_attempts" => remaining_attempts,
                "message" => message
              }
            )
          )
        )

        {:recovered, %{state | overflow_recovery_tail_attempts: remaining_attempts}}

      :not_compactable ->
        Session.emit(
          sid,
          Event.context_pressure(
            sid,
            recovery_notice_data(
              history,
              %{
                "tier" => "recovery",
                "trigger" => "overflow_recovery",
                "recovered" => false,
                "message" =>
                  "Provider rejected the request as a context overflow, but recovery could " <>
                    "not record a compaction checkpoint: the history past the latest " <>
                    "checkpoint is too short to compact (tried tail_events " <>
                    "#{Enum.join(attempts, ", ")}). Run " <>
                    "`pixir compact #{sid} --tail-events N` with a smaller N to recover " <>
                    "manually."
              }
            )
          )
        )

        :no_recovery

      {:error, reason} ->
        Session.emit(
          sid,
          Event.context_pressure(
            sid,
            recovery_notice_data(
              history,
              %{
                "tier" => "recovery",
                "trigger" => "overflow_recovery",
                "recovered" => false,
                "error" => inspect(reason),
                "message" =>
                  "Provider rejected the request as a context overflow, but recovery " <>
                    "compaction failed before recording a checkpoint."
              }
            )
          )
        )

        :no_recovery
    end
  end

  defp recover_from_overflow(
         ctx,
         %{overflow_recovery_tail_attempts: []},
         %{error: %{kind: :context_overflow}},
         history
       ) do
    Session.emit(
      ctx.session_id,
      Event.context_pressure(
        ctx.session_id,
        recovery_notice_data(
          history,
          %{
            "tier" => "recovery",
            "trigger" => "overflow_recovery",
            "recovered" => false,
            "message" =>
              "Provider rejected the request as a context overflow after Pixir exhausted " <>
                "its recovery tail attempts (#{Enum.join(@overflow_recovery_tail_attempts, ", ")})."
          }
        )
      )
    )

    :no_recovery
  end

  defp recover_from_overflow(_ctx, _state, _error, _history), do: :no_recovery

  defp compact_for_recovery(_sid, _workspace, []), do: :not_compactable

  defp compact_for_recovery(sid, workspace, [tail_events | smaller]) do
    case Compaction.compact(sid,
           workspace: workspace,
           trigger: "overflow_recovery",
           tail_events: tail_events
         ) do
      {:ok, %{"recorded" => true} = result} -> {:ok, result, tail_events, smaller}
      {:ok, %{"recorded" => false}} -> compact_for_recovery(sid, workspace, smaller)
      {:error, _reason} = error -> error
      _not_recoverable -> compact_for_recovery(sid, workspace, smaller)
    end
  end

  # Preflight compaction when the last recorded provider_usage left the session
  # at "critical" pressure (90%+ of the conservative window). Called after the
  # history fold but before the provider request is built for this Turn, so the
  # current request benefits from the (possible) new checkpoint + tail.
  #
  # Only acts when there is actually a newer critical usage since the last
  # checkpoint. Records a canonical history_compaction (visible, trigger-labeled)
  # and emits a recovery-style context_pressure notice (ephemeral). Gracefully
  # does nothing if nothing is compactable.
  defp maybe_preflight_critical_compaction(ctx, history) do
    sid = ctx.session_id
    latest_usage = history |> Enum.reverse() |> Enum.find(&(&1.type == :provider_usage))

    case latest_usage && get_in(latest_usage.data, ["context_pressure_tier"]) do
      "critical" ->
        last_comp_to_seq = Compaction.latest_checkpoint_to_seq(history)
        usage_seq = latest_usage.seq

        needs_preflight =
          is_nil(last_comp_to_seq) or (is_integer(usage_seq) and usage_seq > last_comp_to_seq)

        {:ok, default_tail_events} = Compaction.default_tail_events()

        if needs_preflight do
          case Compaction.compact(sid,
                 workspace: ctx.workspace,
                 trigger: "critical_pressure_preflight",
                 tail_events: default_tail_events
               ) do
            {:ok, %{"recorded" => true} = result} ->
              range = get_in(result, ["event", "range"]) || %{}

              Session.emit(
                sid,
                Event.context_pressure(sid, %{
                  "tier" => "recovery",
                  "trigger" => "critical_pressure_preflight",
                  "recovered" => true,
                  "message" =>
                    "Last provider call was in critical context pressure (#{result["input_tokens"] || "?"}/#{result["window_tokens"] || "?"}). " <>
                      "Recorded preflight compaction for seq #{range["from_seq"]}..#{range["to_seq"]}. Retrying with compacted history.",
                  "compaction_seq" => result["compaction_seq"]
                })
              )

              # Re-fold so the caller sees the fresh checkpoint + tail for this Turn.
              case Session.history(sid) do
                {:ok, new_history} -> new_history
                _ -> history
              end

            _ ->
              # Not compactable or failed — proceed without stranding the Turn.
              history
          end
        else
          history
        end

      _other ->
        history
    end
  end

  # Pragmatic recovery for low-level transport death (e.g. "Could not read WebSocket frame")
  # when the gauge (latest provider_usage) showed critical pressure. This is the
  # path that was missing in the incident: the socket died at frame level instead of
  # surfacing a clean :context_overflow, so the classic recovery never fired.
  #
  # When both conditions are true we close the current WS (via transport error
  # handling), compact with a labeled trigger, and retry with the fresh checkpoint+tail.
  # Uses the same finite tail-shrinking attempts as overflow recovery.
  defp maybe_recover_from_critical_transport(ctx, state, error, history) do
    if websocket_transport_critical_failure?(error) and recent_pressure_critical?(history) do
      case recover_with_critical_transport_compaction(ctx, state, history) do
        {:recovered, new_state} -> {:recovered, new_state}
        _ -> :no_recovery
      end
    else
      :no_recovery
    end
  end

  defp websocket_transport_critical_failure?(%{error: %{kind: kind}})
       when kind in [
              :websocket_read_failed,
              :websocket_failed,
              :websocket_closed,
              :websocket_timeout
            ],
       do: true

  defp websocket_transport_critical_failure?(_), do: false

  defp recent_pressure_critical?(history) do
    history
    |> Enum.reverse()
    |> Enum.find(&(&1.type == :provider_usage))
    |> case do
      %{data: %{"context_pressure_tier" => "critical"}} -> true
      _ -> false
    end
  end

  # Recovery notices are human-facing ACP updates. T3's valid ACP surface for the
  # live context meter is `usage_update`, which needs gauge fields (`used`/`size`).
  # Recovery events are often emitted after a Provider error, so they may not have a
  # fresh result usage payload. In that case, carry forward the latest durable
  # provider_usage gauge as evidence without making it model replay context.
  defp recovery_notice_data(history, data) do
    history
    |> latest_pressure_gauge()
    |> Map.merge(data)
    |> Map.put_new("presentation", "notice")
  end

  defp latest_pressure_gauge(history) do
    history
    |> Enum.reverse()
    |> Enum.find(fn
      %{type: :provider_usage, data: %{"context_pressure_available" => true}} -> true
      _ -> false
    end)
    |> case do
      %{data: data} ->
        %{}
        |> put_if_present("input_tokens", Map.get(data, "context_pressure_input_tokens"))
        |> put_if_present("window_tokens", Map.get(data, "window_tokens"))
        |> put_if_present("ratio", Map.get(data, "context_pressure_ratio"))
        |> put_if_present("tier", Map.get(data, "context_pressure_tier"))
        |> put_if_present("model", Map.get(data, "model"))

      _ ->
        %{}
    end
  end

  defp put_if_present(map, _key, nil), do: map
  defp put_if_present(map, key, value), do: Map.put(map, key, value)

  defp recover_with_critical_transport_compaction(
         ctx,
         %{overflow_recovery_tail_attempts: [_ | _] = attempts} = state,
         history
       ) do
    # Reuse the existing compact_for_recovery machinery but with our trigger.
    # (We could generalize compact_for_recovery, but keeping the two paths clear
    # for this small change.)
    case compact_for_critical_transport(ctx.session_id, ctx.workspace, attempts) do
      {:ok, result, tail_used, remaining} ->
        Session.emit(
          ctx.session_id,
          Event.context_pressure(
            ctx.session_id,
            recovery_notice_data(
              history,
              %{
                "tier" => "recovery",
                "trigger" => "websocket_critical_recovery",
                "recovered" => true,
                "tail_events" => tail_used,
                "remaining_tail_attempts" => remaining,
                "message" =>
                  "Low-level WebSocket read failure while in critical context pressure. " <>
                    "Recorded compaction (tail #{tail_used}) and retrying with compacted history.",
                "compaction_seq" => result["compaction_seq"]
              }
            )
          )
        )

        {:recovered, %{state | overflow_recovery_tail_attempts: remaining}}

      _ ->
        :no_recovery
    end
  end

  defp recover_with_critical_transport_compaction(
         ctx,
         %{overflow_recovery_tail_attempts: []} = _state,
         history
       ) do
    Session.emit(
      ctx.session_id,
      Event.context_pressure(
        ctx.session_id,
        recovery_notice_data(
          history,
          %{
            "tier" => "recovery",
            "trigger" => "websocket_critical_recovery",
            "recovered" => false,
            "message" =>
              "WebSocket transport failure under critical pressure after exhausting recovery attempts."
          }
        )
      )
    )

    :no_recovery
  end

  defp recover_with_critical_transport_compaction(_ctx, _state, _history), do: :no_recovery

  defp compact_for_critical_transport(_sid, _workspace, []), do: :not_compactable

  defp compact_for_critical_transport(sid, workspace, [tail_events | smaller]) do
    case Compaction.compact(sid,
           workspace: workspace,
           trigger: "websocket_critical_recovery",
           tail_events: tail_events
         ) do
      {:ok, %{"recorded" => true} = result} -> {:ok, result, tail_events, smaller}
      {:ok, %{"recorded" => false}} -> compact_for_critical_transport(sid, workspace, smaller)
      {:error, _reason} = error -> error
      _ -> compact_for_critical_transport(sid, workspace, smaller)
    end
  end

  # A one-line, human-facing rendering of a structured error (ADR 0005 shape:
  # `%{ok: false, error: %{kind, message}}`). Mirrors translate.ex's
  # `result_text(false, …)` so failed turns read consistently with failed tools.
  defp human_error(%{error: %{kind: :network, message: "Provider stream process exited."}}),
    do: "The provider stream exited before Pixir received a final answer."

  defp human_error(%{
         error: %{"kind" => "network", "message" => "Provider stream process exited."}
       }),
       do: "The provider stream exited before Pixir received a final answer."

  defp human_error(%{error: %{message: message}}) when is_binary(message), do: message
  defp human_error(%{error: %{"message" => message}}) when is_binary(message), do: message
  defp human_error(%{error: %{kind: kind}}), do: "The turn failed (#{kind})."
  defp human_error(%{error: %{"kind" => kind}}), do: "The turn failed (#{kind})."
  defp human_error(_other), do: "The turn failed before producing a response."

  defp error_kind(%{error: %{kind: kind}}), do: to_string(kind)
  defp error_kind(%{error: %{"kind" => kind}}), do: to_string(kind)
  defp error_kind(_error), do: "unknown"

  defp error_details(%{error: %{details: details}}) when is_map(details), do: stringify(details)

  defp error_details(%{error: %{"details" => details}}) when is_map(details),
    do: stringify(details)

  defp error_details(_error), do: %{}

  defp cache_metadata(ctx, state, tools) do
    case Cache.metadata(%{
           session_id: ctx.session_id,
           # Cache owns the fork-root default (root = self); Turn only forwards.
           fork_root_session_id: Map.get(ctx, :fork_root_session_id),
           model: state.model,
           mode: state.mode,
           tools: tools,
           skill_index: Skills.render_index(ctx.workspace, state.skills_opts)
         }) do
      {:ok, metadata} ->
        metadata

      {:error, reason} ->
        # Degraded path still carries the contract version: these are exactly the
        # calls a hit-rate audit must not group as unknown-contract (ADR 0020).
        %{
          "prompt_cache_key" => nil,
          "prompt_contract_version" => Cache.prompt_contract_version(),
          "cache_metadata_error" => inspect(reason)
        }
    end
  end

  defp record_provider_usage(sid, result, state, cache_metadata, iteration, history) do
    summary = provider_usage_summary(result, state.provider)
    {:ok, assessment} = ContextWindow.assess(summary, state.model)

    data =
      %{
        "model" => state.model,
        "usage_summary_missing" => is_nil(summary),
        "mode" => Atom.to_string(state.mode),
        "iteration" => iteration,
        "call_index" => iteration,
        "usage_available" => not is_nil(result[:usage]),
        "usage" => stringify(result[:usage] || %{}),
        "usage_summary" => (summary || %{}) |> stringify() |> Map.put_new("model", state.model)
      }
      |> Map.merge(cache_metadata)
      |> Map.merge(stringify(result[:provider_metadata] || %{}))
      |> Map.merge(provider_hosted_tool_evidence(result))
      |> Map.merge(context_pressure_evidence(assessment))

    case safe_session_record(sid, Event.provider_usage(sid, data), "provider_usage") do
      {:ok, _} ->
        emit_context_pressure_snapshot(sid, assessment, history)
        advise_context_pressure(sid, assessment, history)
        :ok

      {:error, error} ->
        Logger.warning("provider_usage evidence could not be recorded",
          session_id: sid,
          error_kind: get_in(error, [:error, :kind])
        )

        {:error, error}
    end
  end

  defp safe_session_record(sid, event, event_type) do
    Session.record(sid, event)
  catch
    :exit, reason ->
      if session_unavailable_exit?(reason) do
        {:error,
         Tool.error(
           :session_record_unavailable,
           "Session was unavailable while recording a canonical event.",
           %{
             session_id: sid,
             event_type: event_type,
             exit_reason: inspect(reason)
           }
         )}
      else
        exit(reason)
      end
  end

  defp session_unavailable_exit?(:noproc), do: true
  defp session_unavailable_exit?(:normal), do: true
  defp session_unavailable_exit?(:shutdown), do: true
  defp session_unavailable_exit?({:noproc, _call}), do: true
  defp session_unavailable_exit?({:normal, _call}), do: true
  defp session_unavailable_exit?({:shutdown, _call}), do: true
  defp session_unavailable_exit?({{:shutdown, _reason}, _call}), do: true
  defp session_unavailable_exit?(_reason), do: false

  # ADR 0020 pressure-gauge evidence on provider_usage. Namespace seam: this
  # module may only add `context_pressure_*` / `window_*` keys here —
  # `continuation_*` / `transport_*` belong to the transport instrumentation,
  # and no existing usage_summary field is renamed.
  defp context_pressure_evidence(%{"available" => true} = assessment) do
    %{
      "context_pressure_available" => true,
      "context_pressure_tier" => assessment["tier"],
      "context_pressure_ratio" => assessment["ratio"],
      "context_pressure_input_tokens" => assessment["input_tokens"],
      "window_tokens" => assessment["window_tokens"]
    }
  end

  defp context_pressure_evidence(assessment) do
    %{
      "context_pressure_available" => false,
      "context_pressure_reason" => assessment["reason"] || "context_window_unknown"
    }
  end

  defp provider_hosted_tool_evidence(result) do
    hosted_tools = result[:provider_hosted_tools] || %{}

    if hosted_tools == %{} do
      %{}
    else
      %{"provider_hosted_tools" => stringify(hosted_tools)}
    end
  end

  # Live presenter gauge (ADR 0020): every available assessment gets an ephemeral
  # snapshot so ACP/T3 can show used/remaining context even below the warning
  # threshold. It is never Provider input, never the Log, and never replayed.
  defp emit_context_pressure_snapshot(sid, %{"available" => true} = assessment, history) do
    data =
      assessment
      |> Map.put("presentation", "snapshot")
      |> Map.put("checkpoint_to_seq", Compaction.latest_checkpoint_to_seq(history))
      |> Map.put("next_actions", [])

    Session.emit(sid, Event.context_pressure(sid, data))
  end

  defp emit_context_pressure_snapshot(_sid, _assessment, _history), do: :ok

  # Advisory before failure (ADR 0020): warning tiers also route a human notice
  # over the same ephemeral context_pressure channel. Hysteresis applies only to
  # notices, not to the routine snapshot above.
  defp advise_context_pressure(sid, %{"available" => true, "tier" => tier} = assessment, history)
       when tier in ["advisory", "warning", "critical"] do
    checkpoint_to_seq = Compaction.latest_checkpoint_to_seq(history)

    case Session.register_pressure_warning(sid, checkpoint_to_seq, tier) do
      {:ok, :warn} ->
        data =
          assessment
          |> Map.put("presentation", "notice")
          |> Map.put("checkpoint_to_seq", checkpoint_to_seq)
          |> Map.put("next_actions", pressure_next_actions(tier, sid))

        Session.emit(sid, Event.context_pressure(sid, data))

      {:ok, :already_warned} ->
        :ok
    end
  end

  defp advise_context_pressure(_sid, _assessment, _history), do: :ok

  defp pressure_next_actions("advisory", _sid), do: []

  defp pressure_next_actions(_tier, sid) do
    [
      %{
        "action" => "inspect_compaction_plan",
        "command" => "pixir compact #{sid} --dry-run --json"
      },
      %{"action" => "compact", "command" => "pixir compact #{sid}"}
    ]
  end

  # Provider-aware neutral cache metadata at the Turn seam (ADR 0037 D7),
  # routed by the registry's cache dialect (D1). Public-but-hidden so the seam
  # contract stays pinned by tests independent of a full Turn.run assertion.
  @doc false
  def provider_cache_metadata(metadata, provider) when is_map(metadata) do
    case ProviderRegistry.entry_for(provider).capabilities do
      %{prompt_cache: :cache_control, prompt_contract_version: version} ->
        metadata
        |> Map.put("prompt_contract_version", version)
        |> Map.delete("prompt_cache_key")

      %{prompt_cache: :prompt_cache_key} ->
        metadata
    end
  end

  defp provider_usage_summary(result, Pixir.Provider) do
    result[:usage_summary] || Pixir.Provider.usage_summary(result[:usage])
  end

  defp provider_usage_summary(result, _provider) do
    case result[:usage_summary] do
      %{} = summary -> summary
      _ -> nil
    end
  end

  defp stringify(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), stringify(value)} end)
  end

  defp stringify(list) when is_list(list), do: Enum.map(list, &stringify/1)
  defp stringify(value), do: value

  defp continue_or_cap(ctx, iteration, state, calls, reasoning_items, output_items) do
    cond do
      capped?(iteration, state.cap) ->
        continue_or_cap(ctx, iteration, state, calls, reasoning_items)

      output_items == [] ->
        continue_or_cap(ctx, iteration, state, calls, reasoning_items)

      true ->
        case walk_output_items(ctx, state, output_items) do
          :ok -> loop(ctx, iteration + 1, state)
          {:terminal_tool_error, result} -> finish_tool_error(ctx.session_id, result)
          {:error, error} -> {:error, error}
        end
    end
  end

  defp continue_or_cap(ctx, iteration, state, calls, reasoning_items) do
    sid = ctx.session_id

    if capped?(iteration, state.cap) do
      # Capped turn: do NOT persist reasoning items — a reasoning item with no following
      # tool execution is rejected on replay ("reasoning without following item", ADR 0007).
      message = "Stopped: reached the tool-iteration cap (#{state.cap})."

      with {:ok, _} <-
             safe_session_record(sid, Event.assistant_message(sid, message), "assistant_message") do
        Session.emit(sid, Event.status(sid, "done"))
        {:error, Tool.error(:iteration_cap, message, %{cap: state.cap})}
      end
    else
      # Record reasoning items (ADR 0007) BEFORE the calls so monotonic `seq` keeps every
      # `rs_` ahead of its paired `fc_` (the Executor records each `tool_call` in turn).
      with :ok <- record_reasoning(sid, reasoning_items, state) do
        case run_calls(ctx, calls, state) do
          :ok -> loop(ctx, iteration + 1, state)
          {:error, error} -> finish_tool_error(sid, error)
        end
      end
    end
  end

  defp capped?(_iteration, :infinity), do: false
  defp capped?(iteration, cap) when is_integer(cap) and cap > 0, do: iteration + 1 >= cap
  defp capped?(_iteration, _cap), do: false

  defp normalize_max_iterations(nil), do: :infinity
  defp normalize_max_iterations(:infinity), do: :infinity
  defp normalize_max_iterations("infinity"), do: :infinity
  defp normalize_max_iterations(cap) when is_integer(cap) and cap > 0, do: cap
  defp normalize_max_iterations(_other), do: :infinity

  defp walk_output_items(ctx, state, output_items) do
    Enum.reduce_while(output_items, :ok, fn
      {:reasoning, item}, :ok ->
        case record_reasoning(ctx.session_id, [item], state) do
          :ok -> {:cont, :ok}
          {:error, error} -> {:halt, {:error, error}}
        end

      {:function_call, call}, :ok ->
        case run_calls(ctx, [call], state) do
          :ok -> {:cont, :ok}
          {:error, error} -> {:halt, {:terminal_tool_error, error}}
        end

      {:provider_hosted_tool, _item}, :ok ->
        {:cont, :ok}

      {kind, _item}, :ok ->
        # Unknown kinds are skipped fail-open for forward compatibility, but never
        # silently: dropped evidence must be visible (ADR 0007).
        Logger.warning("walk_output_items skipped an unrecognized item kind",
          kind: inspect(kind),
          session_id: ctx.session_id
        )

        {:cont, :ok}

      item, :ok ->
        Logger.warning("walk_output_items skipped a malformed output item",
          item: inspect(item),
          session_id: ctx.session_id
        )

        {:cont, :ok}
    end)
  end

  defp record_reasoning(sid, items, state) do
    opts = reasoning_event_opts(state)

    Enum.reduce_while(items, :ok, fn item, :ok ->
      case safe_session_record(sid, Event.reasoning(sid, item, state.model, opts), "reasoning") do
        {:ok, _} -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp run_calls(ctx, calls, state) do
    Enum.reduce_while(calls, :ok, fn %{call_id: id, name: name, args: args}, :ok ->
      result =
        Executor.run(
          %{call_id: id, name: name, args: args},
          %{
            session_id: ctx.session_id,
            workspace: ctx.workspace,
            call_id: id,
            dry_run: state.dry_run,
            bash_timeout_ms: state.bash_timeout_ms,
            bash_timeout_source: state.bash_timeout_source,
            skills_opts: state.skills_opts,
            agents_opts: state.agents_opts,
            provider: state.provider,
            provider_opts: state.provider_opts,
            subagent_depth: state.subagent_depth,
            permission: state.permission
          }
        )

      case result do
        {:error, error} ->
          if terminal_tool_error?(error), do: {:halt, {:error, error}}, else: {:cont, :ok}

        _result ->
          {:cont, :ok}
      end
    end)
  end

  defp terminal_tool_error?(%{error: %{kind: :write_policy_denied}}), do: true
  defp terminal_tool_error?(%{error: %{"kind" => "write_policy_denied"}}), do: true
  defp terminal_tool_error?(_error), do: false

  defp finish_tool_error(sid, error) do
    failure_data =
      error
      |> turn_failure_data(sid)
      |> Map.put("terminal_status", "tool_error")

    {:ok, _} = Session.record(sid, Event.turn_failed(sid, failure_data))
    Session.emit(sid, Event.text_delta(sid, human_error(error)))
    Session.emit(sid, Event.status(sid, "error"))
    {:error, error}
  end

  defp finish(sid, text) do
    with {:ok, _} <-
           safe_session_record(sid, Event.assistant_message(sid, text), "assistant_message") do
      Session.emit(sid, Event.status(sid, "done"))
      {:ok, text}
    end
  end

  defp delta_handler(sid, delta_acc) do
    fn
      {:text_delta, chunk} ->
        Agent.update(delta_acc, &[chunk | &1])
        Session.emit(sid, Event.text_delta(sid, chunk))

      {:reasoning_delta, chunk} ->
        Session.emit(sid, Event.reasoning_delta(sid, chunk))
    end
  end

  defp streamed_text(delta_acc) do
    delta_acc
    |> Agent.get(&Enum.reverse/1)
    |> IO.iodata_to_binary()
  end

  defp useful_partial_text(text) when is_binary(text) do
    if String.trim(text) == "", do: :none, else: {:ok, text}
  end

  defp useful_partial_text(_text), do: :none

  defp system_prompt(ctx, mode, skills_opts, agent_instructions) do
    ctx
    |> system_prompt(mode, skills_opts)
    |> append_agent_instructions(agent_instructions)
  end

  defp append_skills_index(base, ctx, skills_opts) do
    base = String.trim(base)
    base <> "\n\n" <> Skills.render_index(ctx.workspace, skills_opts)
  end

  defp append_agent_instructions(base, nil), do: base
  defp append_agent_instructions(base, ""), do: base

  defp append_agent_instructions(base, instructions) do
    base <> "\n\nSubagent role instructions:\n" <> instructions
  end

  defp presenter_context_text(nil), do: nil
  defp presenter_context_text(%{} = context) when map_size(context) == 0, do: nil
  defp presenter_context_text([]), do: nil

  defp presenter_context_text(%{} = context) do
    context
    |> Enum.sort_by(fn {key, _value} -> to_string(key) end)
    |> Enum.take(@presenter_context_max_items)
    |> Enum.map_join("\n", fn {key, value} ->
      "- #{safe_presenter_key(key)}: #{safe_presenter_value(value)}"
    end)
    |> Tool.truncate(@presenter_context_max_text)
  end

  defp presenter_context_text(context) when is_list(context) do
    context
    |> Enum.take(@presenter_context_max_items)
    |> Enum.map_join("\n", fn value -> "- #{safe_presenter_value(value)}" end)
    |> Tool.truncate(@presenter_context_max_text)
  end

  defp presenter_context_text(context) when is_binary(context) do
    context
    |> String.trim()
    |> case do
      "" -> nil
      text -> "- \"note\": " <> safe_presenter_value(text)
    end
  end

  defp presenter_context_text(_other), do: nil

  @delegation_context_max_items 36
  @delegation_context_max_text 2_400

  @delegation_context_order ~w(
    subagent_id
    parent_session_id
    child_session_id
    agent
    task
    depth
    max_depth
    timeout_ms
    deadline_at
    permission_mode
    write_policy
    workspace_mode
    workspace_fidelity
    read_boundary
    write_semantics
    parent_workspace_mutation
    output_artifact
    apply_status
    requires_explicit_apply
    virtual_command_boundary
    fidelity_caveats
    workflow_id
    workflow_name
    step_id
    wave
    depends_on
    dependency_summaries
    posture
    read_set
    write_set
    checkpoint_requirements
    host_boundary_rule
  )

  defp delegation_context_text(nil), do: nil
  defp delegation_context_text(%{} = context) when map_size(context) == 0, do: nil

  defp delegation_context_text(%{} = context) do
    context
    |> ordered_context_entries(@delegation_context_order)
    |> Enum.take(@delegation_context_max_items)
    |> Enum.map_join("\n", fn {key, value} ->
      "- #{safe_presenter_key(key)}: #{safe_presenter_value(value)}"
    end)
    |> Tool.truncate(@delegation_context_max_text)
  end

  defp delegation_context_text(_other), do: nil

  defp ordered_context_entries(context, order) do
    string_context = Map.new(context, fn {key, value} -> {to_string(key), value} end)
    order_set = MapSet.new(order)

    ordered =
      order
      |> Enum.flat_map(fn key ->
        case Map.fetch(string_context, key) do
          {:ok, value} -> [{key, value}]
          :error -> []
        end
      end)

    rest =
      string_context
      |> Enum.reject(fn {key, _value} -> MapSet.member?(order_set, key) end)
      |> Enum.sort_by(fn {key, _value} -> key end)

    ordered ++ rest
  end

  defp append_late_context(base, _label, nil), do: base
  defp append_late_context(base, _label, ""), do: base
  defp append_late_context(base, label, text), do: base <> "\n" <> label <> "\n" <> text

  defp safe_presenter_key(value) when is_atom(value),
    do: value |> Atom.to_string() |> json_string()

  defp safe_presenter_key(value) when is_binary(value), do: json_string(value)
  defp safe_presenter_key(value), do: value |> inspect() |> json_string()

  defp safe_presenter_value(value) when is_binary(value) do
    value
    |> Tool.truncate(240)
    |> json_string()
  end

  defp safe_presenter_value(value) when is_number(value) or is_boolean(value),
    do: to_string(value)

  defp safe_presenter_value(nil), do: "null"

  defp safe_presenter_value(value) do
    value
    |> inspect(limit: 20, printable_limit: 240)
    |> Tool.truncate(240)
    |> json_string()
  end

  defp json_string(value), do: Jason.encode!(value)

  defp record_explicit_skill_activations(sid, workspace, user_text, skills_opts) do
    workspace
    |> Skills.activations_for_prompt(user_text, skills_opts)
    |> Enum.each(fn data ->
      {:ok, _} = Session.record(sid, Event.skill_activation(sid, data))
    end)
  end
end
