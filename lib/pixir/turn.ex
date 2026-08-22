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
  `:delegation_context` for Subagent child Turns, and `:virtual_overlay` for the
  operator-owned `%{read_set: [...], limits: map | nil}` context used by virtual
  command Tools. String-keyed virtual overlay maps are normalized to that atom-keyed
  representation at Turn intake.
  """

  require Logger

  alias Pixir.{
    Compaction,
    Event,
    RecoveryCommands,
    Session,
    SessionId,
    SessionResources,
    Skills,
    Tool
  }

  alias Pixir.Provider.{Cache, ContextWindow, OutputTruncation}
  alias Pixir.Providers.{ResolvedProviderRequest, ResponsesBackend}
  alias Pixir.Providers.Registry, as: ProviderRegistry
  alias Pixir.Tools.{Executor, Registry}

  @default_max_iterations :infinity
  @presenter_context_max_items 12
  @presenter_context_max_text 1_200
  @overflow_recovery_tail_attempts [40, 20, 10, 5]
  # Bounded-write denials are recoverable feedback until this many strikes land in
  # one Turn; the Nth is turn-fatal. Fixed by owner decision (#446): not a flag,
  # not a policy key, not an env var.
  @write_policy_strike_limit 2
  # Placeholder tool name for a call that only ever existed Provider-side (#462 layer 2):
  # Pixir never saw its name, and inventing a real tool name would be a lie in the Log.
  @dangling_call_tool_name "unknown"
  # Total dangling-call recoveries one Turn may perform across ALL ids (#462 layer 2).
  # The per-id bound alone is not a bound: the Responses validator reports one missing
  # `function_call_output` at a time, so a Log missing N calls yields N distinct ids and
  # an unbounded loop that appends two durable events per round. ADR 0036 requires the
  # attempt count itself to be bounded; this is that count.
  #
  # Sized off the issue's own reproduction, which instructs SEVEN sequential bash calls:
  # a Log poisoned by a pre-#462 binary can therefore be missing seven outputs, and a
  # budget below that would surface the provider error on a Session layer 2 could have
  # healed. Eight covers that recipe with a call to spare. This bounds recovery of an
  # ALREADY-poisoned Log; going forward layer 1 persists each call the instant it is
  # committed on the wire, so a fresh cancellation leaves nothing for this budget to
  # spend.
  @dangling_call_recovery_budget 8
  # Session-LIFETIME ceiling on dangling-call recoveries (#462 round 3). The budget above
  # is per-Turn, so a provider naming a fresh id every Turn resets it and could append two
  # durable events per recovery for the life of the Session. This ceiling is read off the
  # Log itself (the count of synthesized markers already there), so it needs no state and
  # survives a restart. Sized four Turns' worth of the per-Turn budget: comfortably above
  # any real poisoning — the issue's own recipe is seven calls in ONE Turn — while still a
  # hard stop on an endless loop.
  @dangling_call_session_budget 32
  @safe_session_record_event_types ~w(
    assistant_message
    history_compaction
    provider_usage
    reasoning
    tool_call
    tool_result
    turn_failed
  )
  @safe_session_record_failure_classes ~w(noproc normal shutdown timeout)

  @doc false
  @spec dangling_call_recovery_budget() :: pos_integer()
  def dangling_call_recovery_budget, do: @dangling_call_recovery_budget

  @doc false
  @spec dangling_call_session_budget() :: pos_integer()
  def dangling_call_session_budget, do: @dangling_call_session_budget

  @type ctx :: %{
          :session_id => String.t(),
          :workspace => String.t(),
          :role => atom(),
          # Compound runtime Turn identity (#462 round 3, #471). `Session.start_turn/2`
          # always stamps the opaque process-incarnation capability alongside the numeric
          # generation. The declaration path pairs both values; a ctx built without the
          # capability declares under `nil` and is classified as unstamped during a live
          # Turn. The capability is never persisted or rendered.
          :session_incarnation => reference(),
          :turn_generation => pos_integer(),
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

    {:ok, pre_turn_history} = Session.history(sid)
    previous_turn_boundary_seq = previous_turn_boundary_seq(pre_turn_history)

    record_explicit_skill_activations(sid, ctx.workspace, user_text, skills_opts)

    with {:ok, resources} <-
           SessionResources.ingest_attachments(
             sid,
             Keyword.get(opts, :attachments, []),
             workspace: ctx.workspace
           ),
         {:ok, _} <-
           Session.record(sid, Event.user_message(sid, user_text, resources: resources)) do
      run_after_user_message(
        ctx,
        user_text,
        opts,
        resources,
        skills_opts,
        previous_turn_boundary_seq
      )
    end
  end

  defp previous_turn_boundary_seq(pre_turn_history) do
    case List.last(pre_turn_history) do
      %{seq: seq} when is_integer(seq) -> seq
      %{"seq" => seq} when is_integer(seq) -> seq
      _ -> nil
    end
  end

  defp run_after_user_message(
         ctx,
         _user_text,
         opts,
         _resources,
         skills_opts,
         previous_turn_boundary_seq
       ) do
    provider_opts = Keyword.get(opts, :provider_opts, [])
    bash_timeout_ms = Keyword.get(opts, :bash_timeout_ms)
    virtual_overlay = normalize_virtual_overlay(Keyword.get(opts, :virtual_overlay))

    bash_timeout_source =
      if bash_timeout_ms, do: Keyword.get(opts, :bash_timeout_source, "context")

    mode = normalize_mode(Keyword.get(opts, :mode, :build))

    selection = %{
      provider_intent: provider_intent(opts),
      request: %{},
      provider_opts: provider_opts
    }

    with {:ok, resolved} <-
           ProviderRegistry.resolve_request(selection, Keyword.get(opts, :config_opts, [])),
         :ok <- activate_resolved_backend(resolved) do
      provider = ResolvedProviderRequest.provider(resolved)
      capabilities = ResolvedProviderRequest.capabilities(resolved)

      provider_opts = ResolvedProviderRequest.attach_to_provider_opts(resolved, provider_opts)

      state = %{
        provider: provider,
        provider_opts: provider_opts,
        resolved_provider_request: resolved,
        capabilities: capabilities,
        skills_opts: skills_opts,
        agents_opts: Keyword.get(opts, :agents_opts, []),
        subagent_depth: Keyword.get(opts, :subagent_depth, 0),
        agent_instructions: Keyword.get(opts, :agent_instructions),
        previous_turn_boundary_seq: previous_turn_boundary_seq,
        # Rendered once per turn: the Skills index does filesystem discovery and
        # the cache_control request fields are rebuilt every tool-loop iteration.
        rendered_skills_index:
          if capabilities.prompt_cache == :cache_control do
            rendered_skills_index(ctx.workspace, skills_opts)
          end,
        presenter_context: Keyword.get(opts, :presenter_context),
        delegation_context: Keyword.get(opts, :delegation_context),
        # Model that will produce reasoning items this Turn — stamped on each `reasoning`
        # event so replay can drop items captured under a different model (ADR 0007).
        model: ResolvedProviderRequest.model(resolved),
        dry_run: Keyword.get(opts, :dry_run, false),
        # ADR 0020 overflow recovery uses a finite tail-shrinking sequence. A
        # compacted retry can still overflow on smaller-window models, so subsequent
        # :context_overflow failures in the same Turn consume the next smaller tail
        # instead of giving up after the first recorded checkpoint.
        overflow_recovery_tail_attempts: @overflow_recovery_tail_attempts,
        # Turn-scoped bounded-write strike counter (#446). It starts at zero for
        # every Turn — including a resumed Turn over a Log that already carries
        # prior `permission_decision` denials — so history is never recounted, and
        # it is never shared with sibling child Sessions.
        write_policy_strikes: 0,
        # #462 layer 2: call ids for which this Turn has already injected a synthesized
        # cancelled tool output. One recovery per dangling id, per Turn; a second
        # rejection naming the same id surfaces the provider error unchanged.
        dangling_call_recoveries: MapSet.new(),
        # Remaining total recoveries across all ids (see @dangling_call_recovery_budget).
        dangling_call_recovery_budget: @dangling_call_recovery_budget,
        # The interaction mode (`:build` | `:plan`, default `:build`). In `:plan`
        # the Turn instructs the model to plan (not act) and the permission posture
        # is forced to `:read_only`, so mutating tools are denied (plan-and-wait,
        # D.3) — regardless of any caller-supplied permission_mode.
        mode: mode,
        # Presenter binding for the plan→build producer (#520). ACP supplies
        # `%{server, acp_sid}`; CLI and other callers omit it.
        acp_runtime: Keyword.get(opts, :acp_runtime),
        cap:
          opts
          |> Keyword.get(:max_iterations, default_max_iterations())
          |> normalize_max_iterations(),
        bash_timeout_ms: bash_timeout_ms,
        bash_timeout_source: bash_timeout_source,
        virtual_overlay: virtual_overlay,
        permission: %{
          mode: permission_mode(mode, Keyword.get(opts, :permission_mode, :auto)),
          asker: Keyword.get(opts, :asker, fn _request -> :deny end),
          policy: Keyword.get(opts, :write_policy)
        },
        # #522-D: a 400 / unsupported-field rejection of compact_threshold must
        # not retry the field every Turn on the same checkpoint range.
        suppress_compact_threshold: false
      }

      loop(ctx, 0, state)
    else
      {:error, error} -> finish_configuration_error(ctx.session_id, error)
    end
  end

  defp provider_intent(opts) do
    case Keyword.fetch(opts, :provider) do
      :error -> :auto
      {:ok, provider} -> {:explicit, provider}
    end
  end

  defp activate_resolved_backend(resolved) do
    case ResolvedProviderRequest.responses_backend(resolved) do
      :not_applicable -> :ok
      backend -> ResponsesBackend.activation_status(backend)
    end
  end

  defp finish_configuration_error(sid, error) do
    failure_data = %{
      "terminal_status" => "configuration_error",
      "error_kind" => error_kind(error),
      "error_message" => human_error(error),
      "details" => error_details(error)
    }

    record_turn_failure(sid, failure_data)
    Session.emit(sid, Event.text_delta(sid, human_error(error)))
    Session.emit(sid, Event.status(sid, "error"))
    {:error, error}
  end

  # Accept a string ("plan"/"build") or atom mode from the front-end seam.
  defp normalize_mode(mode) when mode in [:plan, "plan"], do: :plan
  defp normalize_mode(_other), do: :build

  # Plan mode is read-only by definition; otherwise honor the caller's posture.
  defp permission_mode(:plan, _requested), do: :read_only
  defp permission_mode(_build, requested), do: requested

  defp normalize_virtual_overlay(nil), do: nil

  defp normalize_virtual_overlay(config) when is_map(config) do
    %{
      read_set: virtual_overlay_field(config, :read_set, "read_set"),
      limits: virtual_overlay_field(config, :limits, "limits")
    }
  end

  defp normalize_virtual_overlay(_config), do: nil

  defp virtual_overlay_field(config, atom_key, string_key) do
    case Map.fetch(config, atom_key) do
      {:ok, value} -> value
      :error -> Map.get(config, string_key)
    end
  end

  defp maybe_put_provider_request(request, _key, nil), do: request
  defp maybe_put_provider_request(request, key, value), do: Map.put(request, key, value)

  defp maybe_put_cache_control_prompt_fields(request, state) do
    case state.capabilities.prompt_cache do
      :cache_control ->
        request =
          request
          |> Map.put(:prompt_mode, state.mode)
          |> maybe_put_provider_request(
            :previous_turn_boundary_seq,
            state.previous_turn_boundary_seq
          )

        request
        |> maybe_put_non_empty(:skills_index, state.rendered_skills_index)
        |> maybe_put_non_empty(:agent_instructions, state.agent_instructions)

      _other ->
        request
    end
  end

  defp maybe_put_non_empty(request, _key, value) when not is_binary(value), do: request
  defp maybe_put_non_empty(request, _key, ""), do: request
  defp maybe_put_non_empty(request, key, value), do: Map.put(request, key, value)

  defp rendered_skills_index(workspace, skills_opts) do
    with {:ok, %{skills: skills}} <- Skills.discover(workspace, skills_opts),
         true <- Enum.any?(skills, &(not Map.get(&1, :disable_model_invocation, false))) do
      Skills.render_index(workspace, skills_opts)
    else
      _ -> nil
    end
  end

  defp reasoning_dialect(state), do: state.capabilities.reasoning_dialect

  defp provider_tool_specs(state) do
    case state.capabilities.tool_dialect do
      :anthropic -> Registry.anthropic_specs()
      :responses -> Registry.responses_specs()
    end
  end

  defp reasoning_event_opts(state) do
    case reasoning_dialect(state) do
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
  def system_prompt(ctx, mode \\ :build, skills_opts \\ []) do
    build_system_prompt(ctx, mode, skills_opts, nil)
  end

  defp build_system_prompt(ctx, :plan, skills_opts, rendered_skills_index) do
    base = """
    You are Pixir, a terminal coding agent.
    You are in PLAN MODE: investigate with read-only tools (read, and safe shell
    commands like grep/ls) and produce a clear, step-by-step plan. Do NOT modify
    files or run mutating commands — write/edit and unsafe shell are disabled in
    this mode and will be refused. Call the `update_plan` tool to record the plan
    as a checklist, then STOP and let the user review it. Recording the plan
    switches this session to build mode; the next prompt can execute. All paths
    are relative to the workspace;
    a developer message in the conversation identifies the workspace root.

    #{@layer0_tail}
    """

    append_skills_index(base, ctx, skills_opts, rendered_skills_index)
  end

  defp build_system_prompt(ctx, _build, skills_opts, rendered_skills_index) do
    base = """
    You are Pixir, a terminal coding agent.
    Use the tools (read, write, bash) to inspect and change files and run commands.
    All paths are relative to the workspace; a developer message in the conversation
    identifies the workspace root. Prefer taking actions with tools over describing
    them, work step by step, and end with a concise summary of what you did.

    #{@layer0_tail}
    """

    append_skills_index(base, ctx, skills_opts, rendered_skills_index)
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

    tools = provider_tool_specs(state)

    system_prompt =
      system_prompt(
        ctx,
        state.mode,
        state.skills_opts,
        state.agent_instructions,
        state.rendered_skills_index
      )

    cache_metadata =
      cache_metadata(ctx, state, tools)
      |> resolved_provider_cache_metadata(state.capabilities)

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
      |> maybe_put_cache_control_prompt_fields(state)

    {:ok, delta_acc} = Agent.start_link(fn -> [] end)
    input_to_seq = Compaction.input_to_seq(history)
    {:ok, threshold_gate} = Agent.start_link(fn -> new_threshold_gate(input_to_seq) end)

    try do
      provider_opts =
        state.provider_opts
        |> Keyword.put(:on_delta, delta_handler(sid, delta_acc))
        |> Keyword.put(
          :on_committed_call,
          threshold_committed_call_handler(sid, turn_identity(ctx), threshold_gate)
        )
        |> Keyword.put(
          :on_compaction_item,
          threshold_item_handler(sid, ctx, state, history, input_to_seq, threshold_gate)
        )
        |> Keyword.put_new(:session_id, sid)
        |> maybe_put_native_preference(state)
        |> maybe_suppress_compact_threshold(state)

      case state.provider.stream(request, provider_opts) do
        {:ok, result} ->
          threshold =
            finalize_threshold_capture(
              sid,
              ctx,
              state,
              history,
              input_to_seq,
              result,
              threshold_gate
            )

          handle_provider_success(
            ctx,
            iteration,
            state,
            result,
            cache_metadata,
            history,
            threshold
          )

        {:error, error} ->
          handle_provider_error(
            ctx,
            iteration,
            state,
            error,
            history,
            streamed_text(delta_acc),
            threshold_gate,
            cache_metadata
          )
      end
    after
      if Process.alive?(delta_acc), do: Agent.stop(delta_acc)
      stop_threshold_gate(sid, turn_identity(ctx), threshold_gate)
    end
  end

  defp handle_provider_success(ctx, iteration, state, result, cache_metadata, history, threshold) do
    sid = ctx.session_id

    if threshold_fired?(threshold) do
      handle_threshold_success(
        ctx,
        iteration,
        state,
        result,
        cache_metadata,
        history,
        threshold
      )
    else
      case result do
        %{finish_reason: :stop} ->
          with {:ok, _usage_event, final_evidence} <-
                 record_provider_usage(
                   sid,
                   result,
                   state,
                   cache_metadata,
                   iteration,
                   history,
                   threshold
                 ) do
            finish(sid, result.text, final_evidence)
          end

        %{finish_reason: :tool_calls, function_calls: calls} ->
          with {:ok, _usage_event, _evidence} <-
                 record_provider_usage(
                   sid,
                   result,
                   state,
                   cache_metadata,
                   iteration,
                   history,
                   threshold
                 ) do
            continue_or_cap(
              ctx,
              iteration,
              state,
              calls,
              result[:reasoning_items] || [],
              result[:output_items] || []
            )
          end
      end
    end
  end

  defp handle_threshold_success(ctx, iteration, state, result, cache_metadata, history, threshold) do
    sid = ctx.session_id

    case result do
      %{finish_reason: :stop} ->
        with {:ok, _usage_event, final_evidence} <-
               record_provider_usage(
                 sid,
                 result,
                 state,
                 cache_metadata,
                 iteration,
                 history,
                 threshold
               ) do
          finish(sid, result.text, final_evidence)
        end

      %{finish_reason: :tool_calls, function_calls: calls} ->
        if capped?(iteration, state.cap) do
          with {:ok, _usage_event, _evidence} <-
                 record_provider_usage(
                   sid,
                   result,
                   state,
                   cache_metadata,
                   iteration,
                   history,
                   threshold
                 ) do
            continue_or_cap(ctx, iteration, state, calls, result[:reasoning_items] || [])
          end
        else
          case persist_threshold_tail(
                 ctx,
                 state,
                 calls,
                 result[:reasoning_items] || [],
                 result[:output_items] || []
               ) do
            {:ok, state} ->
              with {:ok, _usage_event, _evidence} <-
                     record_provider_usage(
                       sid,
                       result,
                       state,
                       cache_metadata,
                       iteration,
                       history,
                       threshold
                     ) do
                loop(ctx, iteration + 1, state)
              end

            {:terminal_tool_error, error} ->
              finish_tool_error(sid, error)

            {:error, error} ->
              finish_tool_error(sid, error)
          end
        end
    end
  end

  defp persist_threshold_tail(ctx, state, calls, reasoning_items, output_items) do
    cond do
      output_items == [] ->
        with :ok <- record_reasoning(ctx.session_id, reasoning_items, state) do
          run_calls(ctx, calls, state)
        end

      true ->
        walk_output_items(ctx, state, output_items)
    end
  end

  defp handle_provider_error(
         ctx,
         iteration,
         state,
         error,
         history,
         partial_text,
         threshold_gate,
         cache_metadata
       ) do
    flush_buffered_committed_calls(ctx.session_id, turn_identity(ctx), threshold_gate)

    if threshold_field_rejected?(error) and not state.suppress_compact_threshold do
      _ = record_threshold_rejection(ctx, state, error, history, cache_metadata, iteration)
      emit_threshold_rejection_notice(ctx.session_id, error)
      loop(ctx, iteration, %{state | suppress_compact_threshold: true})
    else
      handle_provider_error(ctx, iteration, state, error, history, partial_text)
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
            case recover_from_dangling_call(ctx, state, error, history) do
              {:recovered, new_state} ->
                # History is re-folded at the top of the loop; the synthesized output is
                # already a durable tool_call/tool_result pair in the Log by then.
                loop(ctx, iteration, new_state)

              :no_recovery ->
                finish_provider_error(ctx.session_id, error, partial_text)
            end
        end
    end
  end

  # #462 layer 2: the Responses API rejects a request whose input contains a function
  # call with no matching output ("No tool output found for function call <id>"). That
  # happens when the Provider committed a call this Session never persisted — a hard
  # crash between commit and persist, or a Log written by a pre-#462 binary. Pixir
  # synthesizes the missing output for exactly that id and retries once.
  #
  # ADR 0036: the retry is inside the same live Turn and doubly bounded — once per id, and
  # at most @dangling_call_recovery_budget times in total across all ids, since the
  # validator names a fresh id per round when several outputs are missing. Once the budget
  # is spent the provider error surfaces unchanged. The synthesis is durable Log evidence,
  # so the Log never pretends the call ran. The error must name the id structurally
  # (`:dangling_tool_call` classification carries the parsed `call_id`); prose is never
  # substring-matched here.
  defp recover_from_dangling_call(_ctx, %{dangling_call_recovery_budget: 0}, _error, _history),
    do: :no_recovery

  defp recover_from_dangling_call(ctx, state, error, history) do
    with {:ok, call_id} <- dangling_call_id(error),
         false <- MapSet.member?(state.dangling_call_recoveries, call_id),
         false <- persisted_call_id?(history, call_id),
         :ok <- session_recovery_budget_left(ctx.session_id, history),
         :ok <- record_dangling_call_recovery(ctx.session_id, call_id) do
      {:recovered,
       %{
         state
         | dangling_call_recoveries: MapSet.put(state.dangling_call_recoveries, call_id),
           dangling_call_recovery_budget: state.dangling_call_recovery_budget - 1
       }}
    else
      _no_recovery -> :no_recovery
    end
  end

  defp dangling_call_id(%{error: %{kind: :dangling_tool_call, details: %{call_id: call_id}}})
       when is_binary(call_id),
       do: {:ok, call_id}

  defp dangling_call_id(_error), do: :no_recovery

  # #462 round 3: the per-Turn budget bounds ONE Turn. A provider naming fresh ids every
  # Turn would reset it and could append two durable events per recovery forever across a
  # Session's life. This is the Session-scoped ceiling: the synthesized markers already in
  # the Log are the count, so it costs one pass over a history that was folded anyway and
  # needs no new state to survive a restart. Well above any real poisoning (the issue's
  # own recipe is seven calls in one Turn), so a legitimately poisoned Session still
  # heals; past it the provider's own error surfaces with an honest reason.
  defp session_recovery_budget_left(sid, history) do
    spent = Enum.count(history, &(&1.type == :tool_call and is_map(&1.data["synthesized"])))

    if spent < @dangling_call_session_budget do
      :ok
    else
      Logger.warning("dangling tool call recovery refused: Session-lifetime budget spent",
        session_id: sid,
        synthesized_pairs_in_log: spent,
        session_budget: @dangling_call_session_budget
      )

      :no_recovery
    end
  end

  defp persisted_call_id?(history, call_id) do
    Enum.any?(history, fn
      %{type: :tool_call, data: %{"call_id" => ^call_id}} -> true
      _event -> false
    end)
  end

  # The synthesized pair reuses the orphan reconciliation vocabulary (`orphan_tool_call`)
  # so replay, diagnostics, and Monitor read one shape, not two. `reason` names this
  # recovery so the Log distinguishes it from an ordinary interrupt reconciliation.
  defp record_dangling_call_recovery(sid, call_id) do
    call_event =
      Event.new(sid, :tool_call, %{
        "call_id" => call_id,
        "name" => @dangling_call_tool_name,
        "args" => %{},
        "synthesized" => %{"reason" => "provider_dangling_tool_call"}
      })

    result_event =
      Event.tool_result(sid, call_id, %{
        "ok" => false,
        "error" => %{
          "kind" => "orphan_tool_call",
          "message" =>
            "Pixir synthesized a cancelled tool output for a call the Provider had " <>
              "but the Log did not",
          "details" => %{
            "call_id" => call_id,
            "tool" => @dangling_call_tool_name,
            "reason" => "provider_dangling_tool_call"
          }
        }
      })

    # `safe_session_record/3`, not `Session.record/2`: a gone Session EXITS the caller
    # rather than returning `{:error, map}`, so the `else` below would never run and the
    # Turn Task would die instead of surfacing `:no_recovery`. This path executes right
    # after a provider error, which is exactly when a shutdown race is plausible (#462
    # round 3).
    with {:ok, _} <- safe_session_record(sid, call_event, "tool_call"),
         {:ok, _} <- safe_session_record(sid, result_event, "tool_result") do
      :ok
    else
      # Partial write is safe by construction: if the `tool_call` persisted and its result
      # did not, the Log carries a well-formed orphan the existing reconciliation closes
      # on the next `start_turn`/`interrupt`. No retry is issued either way.
      {:error, error} ->
        Logger.warning(
          "dangling tool call recovery could not be recorded; a synthesized tool_call " <>
            "may be left for orphan reconciliation to close",
          safe_session_record_log_metadata(error)
        )

        :no_recovery
    end
  end

  defp finish_provider_error(sid, error, partial_text) do
    case useful_partial_text(partial_text) do
      {:ok, text} ->
        failure_data =
          error
          |> turn_failure_data(sid)
          |> put_in(["details", "partial_text_length"], String.length(text))

        partial_event =
          Event.assistant_message(sid, text,
            metadata: %{
              "partial" => true,
              "terminal_status" => failure_data["terminal_status"],
              "error_kind" => failure_data["error_kind"],
              "error_message" => failure_data["error_message"]
            }
          )

        case safe_session_record(sid, partial_event, "assistant_message") do
          {:ok, _} ->
            :ok

          {:error, record_error} ->
            Logger.warning(
              "partial assistant text could not be recorded on a failed turn",
              safe_session_record_log_metadata(record_error)
            )
        end

        record_turn_failure(sid, failure_data)
        Session.emit(sid, Event.status(sid, "error"))
        {:error, error}

      :none ->
        # Surface the failure as content before the terminal status, so a front-end
        # shows *why* the turn failed instead of an empty turn (ADR 0009 §4). This
        # path also records audit-only failure evidence so the Log accounts for
        # the terminal Turn without pretending there was assistant text.
        record_turn_failure(sid, turn_failure_data(error, sid))
        Session.emit(sid, Event.text_delta(sid, human_error(error)))
        Session.emit(sid, Event.status(sid, "error"))
        {:error, error}
    end
  end

  # #470: a terminal record must never out-crash the Turn it is reporting. Against a
  # dead or stalled Session the evidence has nowhere to land; the miss is logged with
  # a bounded class only (never the raw exit term — it embeds the request), and the
  # caller still returns the ORIGINAL error as the Turn's result.
  defp record_turn_failure(sid, failure_data) do
    case safe_session_record(sid, Event.turn_failed(sid, failure_data), "turn_failed") do
      {:ok, _} ->
        :ok

      {:error, record_error} ->
        Logger.warning(
          "terminal turn_failed could not be recorded",
          safe_session_record_log_metadata(record_error)
        )

        :degraded
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
           # Design boundary: keep this render independent from the Turn snapshot.
           # Its timing feeds skill_index_hash and prompt_cache_key derivation.
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

  defp record_provider_usage(
         sid,
         result,
         state,
         cache_metadata,
         iteration,
         history,
         threshold
       ) do
    summary = provider_usage_summary(result, state.provider)
    {:ok, assessment} = ContextWindow.assess(summary, state.model)
    call_role = if result[:finish_reason] == :stop, do: "final_answer", else: "intermediate"
    truncation = OutputTruncation.from_result(result, state.provider)

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
      |> Map.merge(threshold_usage_evidence(threshold, history))

    usage_event = Event.provider_usage(sid, data)

    evidence =
      truncation
      |> OutputTruncation.to_event_data()
      |> Map.put("provider_usage_event_id", usage_event.id)
      |> Map.put("call_role", call_role)

    usage_event = put_in(usage_event, [:data, "output_truncation"], evidence)

    case safe_session_record(sid, usage_event, "provider_usage") do
      {:ok, stamped_event} ->
        emit_context_pressure_snapshot(sid, assessment, history)
        advise_context_pressure(sid, assessment, history)
        {:ok, stamped_event, Map.put(evidence, "provider_usage_seq", stamped_event.seq)}

      {:error, error} ->
        Logger.warning(
          "provider_usage evidence could not be recorded",
          safe_session_record_log_metadata(error)
        )

        {:error, error}
    end
  end

  # A `GenServer.call` exit embeds the full `{:record, event}` request. The event may
  # contain model text, tool material, Provider metadata, paths, or credentials, so the
  # exit term itself is never returned or logged. Only this closed projection crosses the
  # safe-record boundary. Session ids are included only after canonical validation.
  defp safe_session_record(sid, event, event_type)
       when event_type in @safe_session_record_event_types do
    Session.record(sid, event)
  catch
    :exit, reason ->
      case session_unavailable_failure_class(reason) do
        failure_class when failure_class in @safe_session_record_failure_classes ->
          details =
            %{event_type: event_type, failure_class: failure_class}
            |> maybe_put_safe_session_id(sid)

          {:error,
           Tool.error(
             :session_record_unavailable,
             "Session was unavailable while recording a canonical event.",
             details
           )}

        nil ->
          # Do not turn an unexpected Session fault into ordinary unavailability. The
          # original exit remains loud and preserves the pre-#489 propagation contract.
          exit(reason)
      end
  end

  defp maybe_put_safe_session_id(details, sid) do
    if SessionId.valid?(sid), do: Map.put(details, :session_id, sid), else: details
  end

  defp session_unavailable_failure_class(:noproc), do: "noproc"
  defp session_unavailable_failure_class(:normal), do: "normal"
  defp session_unavailable_failure_class(:shutdown), do: "shutdown"
  defp session_unavailable_failure_class({:noproc, _call}), do: "noproc"
  defp session_unavailable_failure_class({:normal, _call}), do: "normal"
  defp session_unavailable_failure_class({:shutdown, _call}), do: "shutdown"
  defp session_unavailable_failure_class({{:shutdown, _reason}, _call}), do: "shutdown"

  # #470: a record that cannot get an answer out of the Session is as undeliverable as
  # one aimed at a dead Session. Keep the match narrow: only the `GenServer.call` timeout
  # shape belongs to the safe-record projection; unrelated timeout exits still propagate.
  defp session_unavailable_failure_class({:timeout, {GenServer, :call, _call}}), do: "timeout"
  defp session_unavailable_failure_class(_reason), do: nil

  defp session_unavailable_exit?(reason),
    do: not is_nil(session_unavailable_failure_class(reason))

  # Logger metadata is independently projected because `Session.record/2` may also
  # return an arbitrary structured error without exiting. Do not trust such a return to
  # carry the closed details produced above.
  defp safe_session_record_log_metadata(error) do
    details = get_in(error, [:error, :details])
    details = if is_map(details), do: details, else: %{}

    []
    |> maybe_put_safe_log_session_id(detail(details, :session_id))
    |> maybe_put_safe_log_event_type(detail(details, :event_type))
    |> maybe_put_safe_log_failure_class(detail(details, :failure_class))
  end

  defp detail(details, key), do: Map.get(details, key, Map.get(details, Atom.to_string(key)))

  defp maybe_put_safe_log_session_id(metadata, sid) do
    if SessionId.valid?(sid), do: Keyword.put(metadata, :session_id, sid), else: metadata
  end

  defp maybe_put_safe_log_event_type(metadata, event_type)
       when event_type in @safe_session_record_event_types,
       do: Keyword.put(metadata, :event_type, event_type)

  defp maybe_put_safe_log_event_type(metadata, _event_type), do: metadata

  defp maybe_put_safe_log_failure_class(metadata, failure_class)
       when failure_class in @safe_session_record_failure_classes,
       do: Keyword.put(metadata, :failure_class, failure_class)

  defp maybe_put_safe_log_failure_class(metadata, _failure_class), do: metadata

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

  defp resolved_provider_cache_metadata(metadata, capabilities) do
    case capabilities do
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
          {:ok, state} -> loop(ctx, iteration + 1, state)
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
          {:ok, state} -> loop(ctx, iteration + 1, state)
          {:error, error} -> finish_tool_error(sid, error)
        end
      end
    end
  end

  # #462 layer 1: the Provider calls this the instant a `function_call` output item
  # completes on the wire — mid-stream, from inside the streaming process, long before
  # `stream/2` returns. That is the only point early enough: `Session.interrupt/1` kills
  # the Turn Task (and the stream with it) brutally, so a call still held in the stream
  # accumulator dies undeclared and unpersisted, and the next Turn's request omits its
  # output — which the Responses API rejects.
  #
  # The hand-off is a synchronous `GenServer.call`, deliberately, not a cast like
  # `on_delta`: the point is that the call is in the Session's mailbox-and-state before
  # the stream reads another chunk. A cast would reopen the very race this closes (the
  # kill could land while the message is still in flight). Losing a delta is cosmetic;
  # losing a committed call is the bug.
  # The compound runtime identity is captured HERE, at Turn start, and stamped on every
  # declaration this Turn's stream makes (#462 round 3, #471). Pairing the process-local
  # incarnation with the numeric generation lets the Session distinguish this Turn from
  # a dead incarnation's straggler even after a transient restart resets generation to
  # one. The incarnation capability never enters an Event or Pixir-authored Logger output.
  defp committed_call_handler(sid, turn_identity) do
    fn call -> safe_declare_committed_call(sid, call, turn_identity) end
  end

  defp new_threshold_gate(input_to_seq) do
    %{
      input_to_seq: input_to_seq,
      item: nil,
      checkpoint_written: false,
      buffered: [],
      event_data: nil,
      fallback_reason: nil
    }
  end

  # A late `on_committed_call` after cancel/finalize is not in `buffered`: the
  # first Turn's stream `after` already stopped the gate. Fall through to
  # Session C6 (`stale_turn_generation`) instead of exiting `:noproc`.
  defp threshold_committed_call_handler(sid, turn_identity, gate) do
    fn call ->
      if not Process.alive?(gate) do
        committed_call_handler(sid, turn_identity).(call)
      else
        case threshold_gate_decision(gate, call) do
          :buffer -> :ok
          :declare -> committed_call_handler(sid, turn_identity).(call)
        end
      end
    end
  end

  defp threshold_gate_decision(gate, call) do
    Agent.get_and_update(gate, fn
      %{item: item, checkpoint_written: false} = state when not is_nil(item) ->
        {:buffer, %{state | buffered: state.buffered ++ [call]}}

      state ->
        {:declare, state}
    end)
  catch
    :exit, reason ->
      if dead_threshold_gate_exit?(reason) do
        :declare
      else
        exit(reason)
      end
  end

  defp dead_threshold_gate_exit?(:noproc), do: true
  defp dead_threshold_gate_exit?({:noproc, _}), do: true
  defp dead_threshold_gate_exit?(_reason), do: false

  defp threshold_item_handler(sid, ctx, state, history, input_to_seq, gate) do
    fn item ->
      persist_threshold_once(sid, ctx, state, history, input_to_seq, item, gate)
    end
  end

  defp finalize_threshold_capture(sid, ctx, state, history, input_to_seq, result, gate) do
    item = Agent.get(gate, & &1.item) || result[:compaction_item]

    if is_map(item) do
      persist_threshold_once(sid, ctx, state, history, input_to_seq, item, gate)
    else
      flush_buffered_committed_calls(sid, turn_identity(ctx), gate)
    end

    gate_state = Agent.get(gate, & &1)

    Map.merge(gate_state, %{
      compact_threshold_sent: result[:compact_threshold_sent] == true,
      result_item: result[:compaction_item]
    })
  end

  # Claim the write before persisting so stream + finalize cannot both append
  # a native_threshold Event for the same Turn (same range, two cmp_ ids).
  defp persist_threshold_once(sid, ctx, state, history, input_to_seq, item, gate) do
    case claim_threshold_write(gate, item) do
      :write ->
        case write_native_threshold(sid, ctx, state, history, input_to_seq, item, nil) do
          {:ok, event_data} ->
            Agent.update(gate, fn s -> %{s | event_data: event_data, item: item} end)
            flush_buffered_committed_calls(sid, turn_identity(ctx), gate)
            :ok

          {:error, error} ->
            Agent.update(gate, fn s ->
              %{
                s
                | checkpoint_written: false,
                  fallback_reason: threshold_write_reason(error),
                  item: item
              }
            end)

            flush_buffered_committed_calls(sid, turn_identity(ctx), gate)
            :ok
        end

      :already_written ->
        flush_buffered_committed_calls(sid, turn_identity(ctx), gate)
        :ok
    end
  end

  defp claim_threshold_write(gate, item) do
    Agent.get_and_update(gate, fn
      %{checkpoint_written: true} = state ->
        {:already_written, %{state | item: item || state.item}}

      state ->
        {:write, %{state | checkpoint_written: true, item: item || state.item}}
    end)
  end

  defp write_native_threshold(sid, _ctx, state, history, input_to_seq, item, reason) do
    capturing = Compaction.capturing_current(state.resolved_provider_request)

    opts =
      [
        provider: capturing["provider"],
        backend: capturing["backend"],
        dialect: capturing["dialect"],
        model: capturing["model"]
      ]
      |> maybe_put_opt(:fallback_reason, reason)

    case Compaction.native_threshold_event_data(history, input_to_seq, item, opts) do
      {:ok, event_data} ->
        case safe_session_record(
               sid,
               Event.history_compaction(sid, event_data),
               "history_compaction"
             ) do
          {:ok, event} ->
            emit_threshold_notice(sid, event_data, event)
            {:ok, event_data}

          {:error, _} = error ->
            error
        end

      {:error, _} = error ->
        error
    end
  end

  defp emit_threshold_notice(sid, event_data, event) do
    range = event_data["range"] || %{}
    replay = event_data["native_replay"] || %{}
    usable? = replay["recorded_usable"] == true

    Session.emit(
      sid,
      Event.context_pressure(sid, %{
        "presentation" => "notice",
        "tier" => "recovery",
        "trigger" => "native_threshold",
        "recovered" => usable?,
        "message" =>
          if usable? do
            "Provider compact_threshold produced a native compaction item. Recorded a history_compaction checkpoint for seq #{range["from_seq"]}..#{range["to_seq"]}."
          else
            "Native compact_threshold capture was not usable (#{replay["fallback_reason"] || "unknown"}). Recorded a local history_compaction fallback for seq #{range["from_seq"]}..#{range["to_seq"]}."
          end,
        "range" => range,
        "compaction_seq" => event.seq
      })
    )
  end

  defp emit_threshold_rejection_notice(sid, error) do
    reason = threshold_rejection_reason(error)

    Session.emit(
      sid,
      Event.context_pressure(sid, %{
        "presentation" => "notice",
        "tier" => "recovery",
        "trigger" => "native_threshold",
        "recovered" => false,
        "fallback_reason" => reason,
        "message" =>
          "Provider rejected compact_threshold (#{reason}); staying on local History and not retrying the field on this checkpoint range."
      })
    )
  end

  defp record_threshold_rejection(ctx, state, error, history, cache_metadata, iteration) do
    reason = threshold_rejection_reason(error)
    input_to_seq = Compaction.input_to_seq(history)

    threshold = %{
      input_to_seq: input_to_seq,
      item: nil,
      checkpoint_written: false,
      event_data: nil,
      fallback_reason: reason,
      compact_threshold_sent: true,
      result_item: nil
    }

    result = %{
      finish_reason: :error,
      usage: nil,
      provider_metadata: %{},
      provider_hosted_tools: %{}
    }

    record_provider_usage(
      ctx.session_id,
      result,
      state,
      cache_metadata,
      iteration,
      history,
      threshold
    )
  end

  defp flush_buffered_committed_calls(sid, turn_identity, gate) do
    calls =
      Agent.get_and_update(gate, fn state ->
        {state.buffered, %{state | buffered: []}}
      end)

    Enum.each(calls, fn call ->
      safe_declare_committed_call(sid, call, turn_identity)
    end)
  catch
    :exit, reason ->
      if dead_threshold_gate_exit?(reason) do
        :ok
      else
        exit(reason)
      end
  end

  defp stop_threshold_gate(sid, turn_identity, gate) do
    if Process.alive?(gate) do
      flush_buffered_committed_calls(sid, turn_identity, gate)
      if Process.alive?(gate), do: Agent.stop(gate)
    end
  end

  defp threshold_fired?(threshold) when is_map(threshold) do
    threshold.checkpoint_written == true or is_map(threshold[:event_data]) or
      is_map(threshold[:item]) or is_map(threshold[:result_item])
  end

  defp threshold_fired?(_threshold), do: false

  defp threshold_usage_evidence(threshold, history) when is_map(threshold) do
    if threshold_evidence?(threshold) do
      inspected = Compaction.inspect_native_replay(threshold[:event_data] || %{}) || %{}
      ids = inspected["compaction_item_ids"] || compaction_item_ids(threshold)
      reason = inspected["fallback_reason"] || threshold[:fallback_reason]
      usable? = inspected["recorded_usable"] == true

      native =
        %{
          "mode" => "threshold_item",
          "threshold" => Compaction.compact_threshold(),
          "recorded_usable" => usable?,
          "compaction_item_ids" => ids,
          "input_to_seq" => threshold[:input_to_seq],
          "checkpoint_to_seq" => Compaction.latest_checkpoint_to_seq(history)
        }
        |> maybe_put_usage_reason(reason)

      %{"native_compact" => native}
    else
      %{}
    end
  end

  defp threshold_usage_evidence(_threshold, _history), do: %{}

  defp threshold_evidence?(threshold) when is_map(threshold) do
    threshold[:checkpoint_written] == true or is_map(threshold[:event_data]) or
      is_map(threshold[:item]) or is_map(threshold[:result_item]) or
      is_binary(threshold[:fallback_reason])
  end

  defp compaction_item_ids(threshold) do
    item = threshold[:item] || threshold[:result_item]

    case item do
      %{"id" => id} when is_binary(id) -> [id]
      %{id: id} when is_binary(id) -> [id]
      _ -> []
    end
  end

  defp maybe_put_usage_reason(payload, reason) when is_binary(reason) and reason != "",
    do: Map.put(payload, "fallback_reason", reason)

  defp maybe_put_usage_reason(payload, _reason), do: payload

  defp maybe_put_opt(opts, _key, nil), do: opts
  defp maybe_put_opt(opts, key, value), do: Keyword.put(opts, key, value)

  defp maybe_put_native_preference(provider_opts, _state) do
    if Keyword.has_key?(provider_opts, :native) do
      provider_opts
    else
      Keyword.put(provider_opts, :native, Compaction.native_preference(provider_opts))
    end
  end

  defp maybe_suppress_compact_threshold(provider_opts, %{suppress_compact_threshold: true}) do
    Keyword.put(provider_opts, :suppress_compact_threshold, true)
  end

  defp maybe_suppress_compact_threshold(provider_opts, _state), do: provider_opts

  defp threshold_field_rejected?(%{error: %{kind: :backend_rejected, details: details}})
       when is_map(details) do
    details[:compact_threshold_rejected] == true or
      details["compact_threshold_rejected"] == true
  end

  defp threshold_field_rejected?(_error), do: false

  defp threshold_rejection_reason(%{error: %{kind: :backend_rejected}}), do: "backend_rejected"

  defp threshold_rejection_reason(%{error: %{kind: :native_unavailable}}),
    do: "native_unavailable"

  defp threshold_rejection_reason(_error), do: "backend_rejected"

  defp threshold_write_reason(%{error: %{kind: kind}}) when is_atom(kind),
    do: Atom.to_string(kind)

  defp threshold_write_reason(_error), do: "malformed_native_replay"

  defp turn_identity(%{
         session_incarnation: session_incarnation,
         turn_generation: turn_generation
       })
       when is_reference(session_incarnation) and is_integer(turn_generation) and
              turn_generation > 0 do
    {session_incarnation, turn_generation}
  end

  defp turn_identity(_ctx), do: nil

  # Swallowed on purpose, and the swallow is now TRUE (#462 round 3). The failure this
  # documents — a gone Session — arrives as an EXIT from `GenServer.call`, not as
  # `{:error, map}`, so the `{:error, …}` clause alone never fired for it: the exit
  # escaped the stream reducer and killed the Turn, the exact outcome the comment claimed
  # to avoid. A dead Session has nothing left to drain, so there is no evidence to lose,
  # and killing the stream over bookkeeping is the wrong trade. A `:timeout` exit is
  # swallowed for the same reason: a Session busy in a long `Log.fold` is a bookkeeping
  # stall, and letting it escape makes StreamIdle classify it `:network` — which IS
  # provider-retryable, so a stalled Log fold would trigger a re-stream.
  #
  # #462 round 5: anything ELSE returns a STRUCTURED error rather than re-exiting. The
  # re-exit was written to make an unclassified fault loud, but it was not loud — it was
  # laundered. The declare runs inside `Pixir.Provider.StreamIdle.run_stream/3`, whose
  # `catch` turns every throw and exit into `Tool.error(:network, …)`, and `:network` is
  # exactly what `Pixir.Provider.attempt/5` retries. So an unclassified Session crash came
  # back as a transport blip AND triggered a re-stream, whose re-committed calls are the
  # amplifier for the duplicate-declare poison closed above. The structured return travels
  # the Provider's ordinary stream-error path, where `retryable?/1` does not match
  # `:session_record_unavailable`: the fault ends the stream once, named for what it is.
  defp safe_declare_committed_call(sid, call, turn_identity) do
    case Session.declare_committed_calls(sid, [call], turn_identity) do
      :ok -> :ok
      {:error, error} -> warn_undeclared_call(sid, call, error)
    end
  catch
    :exit, reason ->
      if session_unavailable_exit?(reason) or declare_timeout_exit?(reason) do
        warn_undeclared_call(sid, call, reason)
      else
        undeclarable_call_error(sid, call, reason)
      end
  end

  # The existing `:session_record_unavailable` kind, not a new one: this IS "the Session
  # could not take a record", and the vocabulary is deliberately curated (ADR 0005 rule 3).
  # Non-retryable by construction — `Pixir.Provider.retryable?/1` matches only `:network`,
  # `:rate_limited` and 5xx/flagged `:provider_http_error` — which is the whole point.
  defp undeclarable_call_error(sid, call, reason) do
    Logger.error("committed tool call declaration failed with an unclassified Session exit",
      session_id: sid,
      call_id: Map.get(call, :call_id),
      failure_class: declare_failure_class(reason)
    )

    {:error,
     Tool.error(
       :session_record_unavailable,
       "The Session could not accept a Provider-committed tool call declaration.",
       %{
         "call_id" => Map.get(call, :call_id),
         "failure_class" => declare_failure_class(reason)
       }
     )}
  end

  defp declare_timeout_exit?(:timeout), do: true
  defp declare_timeout_exit?({:timeout, _call}), do: true
  defp declare_timeout_exit?(_reason), do: false

  defp warn_undeclared_call(sid, call, reason) do
    Logger.warning("committed tool call could not be declared mid-stream",
      session_id: sid,
      call_id: Map.get(call, :call_id),
      failure_class: declare_failure_class(reason)
    )

    :ok
  end

  # #462 CR: the declare hand-off is a `GenServer.call`, and a `GenServer.call` exit
  # reason EMBEDS THE REQUEST TERM — here `{:declare_committed_calls, [call], identity}`,
  # where `call` carries the tool's ARGUMENTS. `inspect(reason)` therefore leaked whatever
  # the model asked the tool to do (paths, secrets pasted into a command, credentials in a
  # URL) into a Logger metadata line and, on the unclassified path, into the durable
  # `turn_failed` details — evidence that outlives the process and is read by presenters.
  #
  # So nothing derived from the term is emitted except a BOUNDED CLASS from a closed set.
  # The outermost exit tag is admitted only when it is a bare atom (`:noproc`, `:kaboom`),
  # which by construction carries no payload; anything structured collapses to
  # `"unclassified_exit"`. A structured `{:error, %{error: %{kind: …}}}` from the Session's
  # own return path contributes only its curated `kind`, never its details.
  @declare_failure_class_timeout "timeout"
  @declare_failure_class_unavailable "session_unavailable"
  @declare_failure_class_unclassified "unclassified_exit"

  defp declare_failure_class(reason) do
    cond do
      declare_timeout_exit?(reason) -> @declare_failure_class_timeout
      session_unavailable_exit?(reason) -> @declare_failure_class_unavailable
      true -> unclassified_failure_class(reason)
    end
  end

  # A structured Session rejection (the `{:error, map}` return, not an exit): its `kind` is
  # curated vocabulary (ADR 0005 rule 3), so it is safe to name. `message`/`details` are
  # not — the details may echo the rejected call.
  defp unclassified_failure_class(%{error: %{kind: kind}}) when is_atom(kind),
    do: Atom.to_string(kind)

  defp unclassified_failure_class(%{error: %{kind: kind}}) when is_binary(kind), do: kind

  # A BARE atom tag only. `{:kaboom, {GenServer, :call, [...]}}` is the shape that carries
  # the request — and the args with it — so only the tag is taken, never the tuple.
  defp unclassified_failure_class(reason) when is_atom(reason),
    do: @declare_failure_class_unclassified <> ":" <> Atom.to_string(reason)

  defp unclassified_failure_class({tag, _payload}) when is_atom(tag),
    do: @declare_failure_class_unclassified <> ":" <> Atom.to_string(tag)

  defp unclassified_failure_class(_reason), do: @declare_failure_class_unclassified

  defp capped?(_iteration, :infinity), do: false
  defp capped?(iteration, cap) when is_integer(cap) and cap > 0, do: iteration + 1 >= cap
  defp capped?(_iteration, _cap), do: false

  defp normalize_max_iterations(nil), do: :infinity
  defp normalize_max_iterations(:infinity), do: :infinity
  defp normalize_max_iterations("infinity"), do: :infinity
  defp normalize_max_iterations(cap) when is_integer(cap) and cap > 0, do: cap
  defp normalize_max_iterations(_other), do: :infinity

  defp walk_output_items(ctx, state, output_items) do
    Enum.reduce_while(output_items, {:ok, state}, fn
      {:reasoning, item}, {:ok, state} ->
        case record_reasoning(ctx.session_id, [item], state) do
          :ok -> {:cont, {:ok, state}}
          {:error, error} -> {:halt, {:error, error}}
        end

      {:function_call, call}, {:ok, state} ->
        case run_calls(ctx, [call], state) do
          {:ok, state} -> {:cont, {:ok, state}}
          {:error, error} -> {:halt, {:terminal_tool_error, error}}
        end

      {:compaction, _item}, {:ok, state} ->
        {:cont, {:ok, state}}

      {:provider_hosted_tool, _item}, {:ok, state} ->
        {:cont, {:ok, state}}

      {kind, _item}, {:ok, state} ->
        # Unknown kinds are skipped fail-open for forward compatibility, but never
        # silently: dropped evidence must be visible (ADR 0007).
        Logger.warning("walk_output_items skipped an unrecognized item kind",
          kind: inspect(kind),
          session_id: ctx.session_id
        )

        {:cont, {:ok, state}}

      item, {:ok, state} ->
        Logger.warning("walk_output_items skipped a malformed output item",
          item: inspect(item),
          session_id: ctx.session_id
        )

        {:cont, {:ok, state}}
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
    Enum.reduce_while(calls, {:ok, state}, fn %{call_id: id, name: name, args: args},
                                              {:ok, state} ->
      result =
        Executor.run(
          %{call_id: id, name: name, args: args},
          %{
            session_id: ctx.session_id,
            workspace: ctx.workspace,
            call_id: id,
            dry_run: state.dry_run,
            mode: state.mode,
            acp_runtime: state.acp_runtime,
            bash_timeout_ms: state.bash_timeout_ms,
            bash_timeout_source: state.bash_timeout_source,
            virtual_overlay: state.virtual_overlay,
            skills_opts: state.skills_opts,
            agents_opts: state.agents_opts,
            provider: state.provider,
            provider_opts: ResolvedProviderRequest.for_child_turn(state.provider_opts),
            subagent_depth: state.subagent_depth,
            permission: state.permission
          }
        )

      case result do
        {:error, error} ->
          if write_policy_denial?(error) do
            state = Map.update!(state, :write_policy_strikes, &(&1 + 1))

            # Strike 1 is recoverable feedback: the already-recorded `tool_result`
            # carrying the structured denial reaches the model on the next provider
            # round-trip, so it can write inside the allowlist, fall back to
            # read-only work, or finish honestly. Strike 2 is turn-fatal — a model
            # that keeps pushing at the boundary after being told once does not get
            # a third try (#446, fail-closed backstop at N = 2).
            if state.write_policy_strikes >= @write_policy_strike_limit do
              {:halt, {:error, error}}
            else
              {:cont, {:ok, state}}
            end
          else
            {:cont, {:ok, state}}
          end

        _result ->
          {:cont, {:ok, state}}
      end
    end)
  end

  # A bounded-write denial, whichever rule raised it: allowlist miss, deny match,
  # protected path, workspace-root target, child broadening, bash token, or a
  # denial surfaced through `apply_virtual_diff`. The strike is keyed on the
  # denial kind, never on a list of tool names. `:bash_disabled` is a distinct,
  # deliberately non-terminal kind and never strikes.
  defp write_policy_denial?(%{error: %{kind: :write_policy_denied}}), do: true
  defp write_policy_denial?(%{error: %{"kind" => "write_policy_denied"}}), do: true
  defp write_policy_denial?(_error), do: false

  defp finish_tool_error(sid, error) do
    failure_data =
      error
      |> turn_failure_data(sid)
      |> Map.put("terminal_status", "tool_error")

    record_turn_failure(sid, failure_data)
    Session.emit(sid, Event.text_delta(sid, human_error(error)))
    Session.emit(sid, Event.status(sid, "error"))
    {:error, error}
  end

  defp finish(sid, text, output_truncation) do
    opts =
      if output_truncation["status"] == "truncated" do
        [metadata: %{"output_truncation" => output_truncation}]
      else
        []
      end

    with {:ok, _} <-
           safe_session_record(
             sid,
             Event.assistant_message(sid, text, opts),
             "assistant_message"
           ) do
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

  defp system_prompt(
         ctx,
         mode,
         skills_opts,
         agent_instructions,
         rendered_skills_index
       ) do
    ctx
    |> build_system_prompt(mode, skills_opts, rendered_skills_index)
    |> append_agent_instructions(agent_instructions)
  end

  defp append_skills_index(base, ctx, skills_opts, rendered_skills_index) do
    index =
      if is_binary(rendered_skills_index) do
        rendered_skills_index
      else
        Skills.render_index(ctx.workspace, skills_opts)
      end

    String.trim(base) <> "\n\n" <> index
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
