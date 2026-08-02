defmodule Pixir.Subagents do
  @moduledoc """
  Public facade for BEAM-native Subagent orchestration (ADR 0011).

  Subagents move through a small lifecycle state machine. The usual path is
  `queued -> running -> completed`, but failures, timeouts, cancellation, and
  detached restored children must remain explicit so parents and diagnostics can
  tell "finished cleanly" apart from "needs operator attention".

  `max_depth` is an absolute delegation-depth cap from the root Session. A child
  spawned by the root runs at depth `1`; that child may only spawn another child
  when the configured cap is at least `2`.
  """

  alias Pixir.{Log, Permissions, SessionId, Tool}
  alias Pixir.Permissions.WritePolicy
  alias Pixir.Subagents.Manager

  @statuses ~w(queued running completed failed timed_out cancelled detached closed)
  @terminal_statuses ~w(completed failed cancelled timed_out closed detached)

  @allowed_transitions %{
    "queued" => ~w(running failed detached closed),
    "running" => ~w(completed failed timed_out cancelled detached),
    "completed" => ~w(running closed),
    "failed" => ~w(running closed),
    "timed_out" => ~w(running closed),
    "cancelled" => ~w(running closed),
    "detached" => [],
    "closed" => []
  }

  @doc "Application child spec."
  def child_spec(opts), do: Manager.child_spec(opts)

  @doc "Default runtime limits."
  def default_limits do
    config = Application.get_env(:pixir, :subagents, [])

    %{
      max_threads: Keyword.get(config, :max_threads, 6),
      max_depth: Keyword.get(config, :max_depth, 1),
      timeout_ms: Keyword.get(config, :timeout_ms, 120_000),
      retry_attempts: Keyword.get(config, :retry_attempts, 1),
      retry_jitter_ms: Keyword.get(config, :retry_jitter_ms, 250)
    }
  end

  @doc "Spawn or queue a Subagent."
  def spawn_agent(parent_session_id, args, opts \\ []),
    do: Manager.spawn_agent(parent_session_id, args, opts)

  @doc "Validate and normalize a Subagent spawn without creating runtime state."
  def validate_spawn(parent_session_id, args, opts \\ []),
    do: Manager.validate_spawn(parent_session_id, args, opts)

  @doc "Send follow-up input to an idle Subagent."
  def send_input(parent_session_id, subagent_id, prompt, opts \\ []),
    do: Manager.send_input(parent_session_id, subagent_id, prompt, opts)

  @doc "Wait for selected Subagents to reach a terminal status."
  def wait(parent_session_id, ids, timeout_ms \\ 30_000, opts \\ []),
    do: Manager.wait(parent_session_id, ids, timeout_ms, opts)

  @doc """
  Wait for selected Subagents and return a structured outcome.

  Unlike `wait/4`, this keeps partial fanout visible: timed-out, failed, detached,
  cancelled, and still-incomplete children are bucketed instead of turning the
  parent tool call into an opaque failure. The returned `"partial"` boolean is
  true for any non-completed aggregate status; consumers should use `"status"`
  when they need to distinguish `"partial"` from `"incomplete"`.
  """
  def wait_outcome(parent_session_id, ids, timeout_ms \\ 30_000, opts \\ []),
    do: Manager.wait_outcome(parent_session_id, ids, timeout_ms, opts)

  @doc """
  Cancel a running Subagent, or close a queued/terminal Subagent as cleanup.

  Cancelling a running Subagent also appends a terminal `cancelled_by_parent`
  `:subagent_event` to the **child's** own Log, so the child Log alone is evidence
  of its cancellation. Callers that cancel on behalf of a Workflow may name the
  canceller with `:workflow_id`, `:workflow_step_id`, and `:workflow_close_outcome`;
  those fields are simply absent from the child event for a plain parent close. The
  return contract (`status`, `reason`, `elapsed_ms`, `next_actions`) is unchanged.
  """
  def close(parent_session_id, id, opts \\ []), do: Manager.close(parent_session_id, id, opts)

  @doc "List Subagents for a parent Session."
  def list(parent_session_id, opts \\ []), do: Manager.list(parent_session_id, opts)

  @doc """
  Return a read-only snapshot of the Subagent Manager runtime for one parent Session.

  This is volatile process health evidence, not durable history. Use the Session Log
  and Session tree for canonical lifecycle facts.
  """
  def diagnostics(parent_session_id, opts \\ []), do: Manager.diagnostics(parent_session_id, opts)

  @doc "Summarize agent maps for model-facing output."
  def summarize(agents) when is_list(agents) do
    agents
    |> Enum.map_join("\n", fn agent ->
      summary = agent["summary"] || agent[:summary] || ""
      id = agent["id"] || agent[:id]
      name = agent["agent"] || agent[:agent]
      status = agent["status"] || agent[:status]
      "- #{id} (#{name}) #{status}: #{summary}"
    end)
  end

  @doc "Build model-facing text for a structured wait outcome."
  def summarize_wait_outcome(%{"summary" => summary}) when is_binary(summary), do: summary
  def summarize_wait_outcome(_outcome), do: "wait_agent outcome unavailable."

  @doc """
  Rehydrate a Session's durable permission posture for a cold resume.

  Root Sessions record their posture at creation (`Pixir.Conversation.start/1`,
  lineage `root`, trusted only in root position: first non-`session_fork` event,
  runtime-authored source) and restore the recorded capability ceiling —
  including unbounded auto when the marker declared it. Spawned
  children record theirs in the Subagent Manager (lineage `child`) and keep the
  stricter contract: write-capable history restores only with a bounded policy.
  Legacy Logs without posture evidence remain resumable only when they contain
  no write-capable evidence, and then restore an explicit read-only ceiling;
  otherwise they fail closed with reason `missing`, which is the one
  classification the operator may override via the CLI's explicit legacy-root
  attestation (never as unbounded auto).
  """
  @spec resume_posture(String.t(), keyword()) :: {:ok, map()} | {:error, map()}
  def resume_posture(session_id, opts \\ []) do
    workspace = Keyword.get(opts, :workspace, File.cwd!())

    with :ok <- SessionId.validate(session_id),
         {:ok, workspace} <- canonical_resume_workspace(session_id, workspace),
         {:ok, history} <- fold_resume_history(session_id, workspace) do
      evidence? = write_capable_evidence?(history)

      case posture_events(history) do
        [] ->
          if evidence? do
            {:error, resume_posture_error(session_id, "missing")}
          else
            {:ok,
             %{
               permission_mode: :read_only,
               write_policy: nil,
               workspace_mode: "shared",
               workspace: workspace,
               lineage: :legacy_unknown
             }}
          end

        events ->
          with {:ok, posture} <- restore_posture_events(session_id, events, history),
               :ok <- validate_restored_workspace(session_id, posture, workspace),
               :ok <- validate_restored_policy(session_id, posture, evidence?) do
            {:ok, posture}
          end
      end
    end
  end

  defp canonical_resume_workspace(session_id, workspace) when is_binary(workspace) do
    case canonical_path(workspace) do
      {:ok, canonical} ->
        {:ok, canonical}

      {:error, reason} ->
        {:error,
         resume_posture_error(session_id, "workspace_unavailable", %{
           "workspace" => Path.expand(workspace),
           "filesystem_reason" => inspect(reason)
         })}
    end
  end

  defp canonical_resume_workspace(session_id, workspace) do
    {:error,
     resume_posture_error(session_id, "workspace_unavailable", %{
       "workspace" => inspect(workspace)
     })}
  end

  # Normal Log.fold/2 intentionally seq-sorts History and treats :enoent as empty.
  # Resume trust instead reads physical append order so caller-authored seq cannot
  # move a late posture marker into root position. A caller explicitly resuming a
  # Session also has a stricter existence contract: an absent Log is not a readable
  # legacy Log, so detect it before folding and fail closed distinctly.
  defp fold_resume_history(session_id, workspace) do
    path = Log.path(session_id, workspace: workspace)

    case Log.exists(session_id, workspace: workspace) do
      {:ok, true} ->
        case Log.fold_append_order(session_id, workspace: workspace) do
          {:ok, history} -> {:ok, history}
          {:error, %{error: %{kind: :unsafe_state_path}} = error} -> {:error, error}
          {:error, error} -> {:error, resume_log_error(session_id, path, error)}
        end

      {:ok, false} ->
        {:error,
         resume_posture_error(session_id, "log_missing", %{
           "log_path" => path
         })}

      {:error, error} ->
        {:error, error}
    end
  end

  defp resume_log_error(session_id, path, error) do
    resume_posture_error(session_id, "log_unreadable", %{
      "log_path" => path,
      "log_error" => error
    })
  end

  defp posture_events(history) do
    Enum.filter(history, fn
      %{type: :subagent_event, data: %{"event" => "permission_posture", "scope" => "session"}} ->
        true

      _event ->
        false
    end)
  end

  defp restore_posture_events(session_id, events, history) do
    restored = Enum.map(events, &restore_posture(&1, history))

    case Enum.uniq(restored) do
      [{:ok, posture}] -> {:ok, posture}
      [{:error, _error}] -> {:error, resume_posture_error(session_id, "unreadable")}
      _ambiguous -> {:error, resume_posture_error(session_id, "ambiguous")}
    end
  end

  defp restore_posture(%{data: data} = event, history) do
    with {:ok, permission_mode} <- Map.fetch(data, "permission_mode"),
         {:ok, mode} <- restore_permission_mode(permission_mode),
         {:ok, workspace_mode} when is_binary(workspace_mode) and workspace_mode != "" <-
           Map.fetch(data, "workspace_mode"),
         {:ok, metadata} <- Map.fetch(data, "write_policy"),
         {:ok, write_policy} <- WritePolicy.from_metadata(metadata),
         {:ok, lineage} <- restore_lineage(data, event, history) do
      {:ok,
       %{
         permission_mode: mode,
         write_policy: write_policy,
         workspace_mode: workspace_mode,
         workspace: Map.get(data, "workspace"),
         lineage: lineage
       }}
    else
      _invalid -> {:error, :invalid_posture}
    end
  end

  # A root marker is trusted in exactly two shapes: the runtime-authored event
  # (`source: "root_session_start"` — the only producer is Conversation.start;
  # a fork-replayed CHILD posture keeps `source: "subagent_spawn"`, so a partial
  # lineage edit of a forked child Log is refused by source alone) sitting in
  # the Log's ROOT POSITION, or an explicit operator attestation, which may
  # appear at any position but never restores unbounded auto
  # (validate_restored_policy/3). Root position means the event IS the first
  # non-`session_fork` event in physical append order — computed by position,
  # never by event id or claimed seq, both attacker-controlled in a hand-edited
  # Log (an id collision must not truncate the prefix and a forged seq must not
  # reorder trust evidence). A plain root has nothing
  # before its posture; a forked root has exactly the seq-0 `session_fork`
  # (`session_fork` is not in Fork.replay_types, so fork chains never nest).
  # A root marker carrying child spawn fields (subagent_id / parent_session_id)
  # is a contradiction refused outright. Full same-UID Log rewriting can still
  # fabricate the complete trusted shape — that residue is the documented local
  # NDJSON threat model, unchanged by this PR. Anything else folds as child
  # lineage, the conservative default: absent-lineage events are the child
  # events this evidence channel originally shipped with.
  defp restore_lineage(data, event, history) do
    case {Map.get(data, "lineage"), Map.get(data, "source")} do
      {"root", "operator_attested_legacy_root"} ->
        {:ok, :attested_root}

      {"root", "root_session_start"} ->
        cond do
          Map.has_key?(data, "subagent_id") or Map.has_key?(data, "parent_session_id") ->
            {:error, :untrusted_root_marker}

          root_position?(history, event) ->
            {:ok, :root}

          true ->
            {:error, :untrusted_root_marker}
        end

      {"root", _other_source} ->
        {:error, :untrusted_root_marker}

      {_absent_or_child, _source} ->
        {:ok, :child}
    end
  end

  defp root_position?(history, event) do
    Enum.find(history, &(&1.type != :session_fork)) == event
  end

  # Explicit matching is cold-VM safe; never derive atoms from Log strings.
  defp restore_permission_mode("auto"), do: {:ok, :auto}
  defp restore_permission_mode("ask"), do: {:ok, :ask}
  defp restore_permission_mode("read_only"), do: {:ok, :read_only}
  defp restore_permission_mode(_mode), do: {:error, :invalid_permission_mode}

  defp write_capable_evidence?(history) do
    mutation_attempt?(history) or write_policy_decision?(history)
  end

  defp mutation_attempt?(history) do
    ran = succeeded_call_ids(history)

    Enum.any?(history, fn
      %{type: :tool_call, data: data} when is_map(data) -> mutating_call?(data, ran)
      _event -> false
    end)
  end

  # Call ids the Log says actually produced a SUCCESSFUL result. `ok == false` is not in
  # here on purpose: a failed result is not a claim that the call ran to effect, and the
  # honest drain/synthesis pairing is exactly `ok: false` with an `orphan_tool_call` error.
  defp succeeded_call_ids(history) do
    for %{type: :tool_result, data: %{"call_id" => call_id} = data} <- history,
        data["ok"] == true,
        into: MapSet.new(),
        do: call_id
  end

  # #462: a `tool_call` Pixir itself wrote to close a cancellation window is NOT evidence
  # of a mutation attempt. Both markers name calls that provably never ran:
  #
  #   * `"synthesized"` — layer-2 recovery, whose name is the `"unknown"` placeholder;
  #     `Permissions.mutating?/2` fails closed on unknown names, so without this a legacy
  #     Log with no posture event would fail `resume_posture/2` closed with reason
  #     "missing" over a call nothing executed;
  #   * `"drained"` — layer-1 drain, which carries the call's real name but was persisted
  #     precisely BECAUSE the Turn was killed before the Executor could run it.
  #
  # #462 round 5: the marker alone does not buy the exemption — the PAIRING does. Both
  # markers are written by Pixir alongside a result asserting the call did not run, and
  # that assertion is the whole basis for exempting them. A Log that carries the marker
  # next to a SUCCESSFUL result is describing a call that ran, whatever the marker claims,
  # and the marker key is an ordinary string any writer (a forged Log, a corrupted one, a
  # future path that reuses the key for something that does execute) can place there.
  # Keying on presence alone would let that hide a real write and resume the Session
  # write-capable over it. So: exempt while no successful result exists for the id, and
  # fall through to the ordinary classification the moment one does. A marker with no
  # result at all stays exempt — that is the honest mid-drain shape, where the closing
  # reconciliation has not run (or its Log append failed).
  #
  # The catch-all classification for ordinary unknown names is untouched: only Pixir's own
  # markers, and only unpaired-with-success, are exempt.
  defp mutating_call?(%{"synthesized" => marker, "call_id" => call_id} = data, ran)
       when is_map(marker),
       do: MapSet.member?(ran, call_id) and mutating_by_name?(data)

  defp mutating_call?(%{"drained" => marker, "call_id" => call_id} = data, ran)
       when is_map(marker),
       do: MapSet.member?(ran, call_id) and mutating_by_name?(data)

  # A marker with no readable `call_id` cannot be tied to any result, so nothing can vouch
  # that it ran: it keeps the exemption, exactly as before round 5.
  defp mutating_call?(%{"synthesized" => marker}, _ran) when is_map(marker), do: false
  defp mutating_call?(%{"drained" => marker}, _ran) when is_map(marker), do: false

  defp mutating_call?(data, _ran), do: mutating_by_name?(data)

  # `Permissions.mutating?/2` fails closed on names it does not know, which is what makes
  # the layer-2 `"unknown"` placeholder classify as a write once it is no longer exempt.
  defp mutating_by_name?(%{"name" => name, "args" => args}) when is_binary(name),
    do: Permissions.mutating?(name, if(is_map(args), do: args, else: %{}))

  defp mutating_by_name?(%{"name" => name}) when is_binary(name),
    do: Permissions.mutating?(name, %{})

  defp mutating_by_name?(_data), do: false

  defp write_policy_decision?(history) do
    Enum.any?(history, fn
      %{type: :permission_decision, data: data} when is_map(data) ->
        data["gate"] == "write_policy"

      _event ->
        false
    end)
  end

  defp validate_restored_policy(_session_id, %{permission_mode: :read_only}, _evidence?), do: :ok

  # An operator attestation never restores unbounded auto: the whole point of
  # the override is recovering a legacy Log without being able to prove it was
  # not a bounded child. The CLI refuses to write such an event; this clause
  # keeps a hand-forged one from restoring anyway. Attested ask stays valid —
  # every action still round-trips through the operator.
  defp validate_restored_policy(
         session_id,
         %{lineage: :attested_root, permission_mode: :auto, write_policy: nil},
         _evidence?
       ),
       do: {:error, resume_posture_error(session_id, "unbounded_write_policy")}

  defp validate_restored_policy(_session_id, %{lineage: :attested_root}, _evidence?), do: :ok

  # A trusted root marker (runtime-authored and first in physical append order)
  # restores its recorded ceiling verbatim — auto with no policy is a legitimate
  # declared capability for an operator-owned root Session.
  defp validate_restored_policy(_session_id, %{lineage: :root}, _evidence?), do: :ok

  defp validate_restored_policy(_session_id, %{write_policy: policy}, _evidence?)
       when is_map(policy), do: :ok

  # An unbounded `auto` ceiling with no write policy is legitimate ONLY for a
  # trusted root or an operator attestation (handled above). Any other lineage
  # claiming auto+nil is refused even with no write evidence: otherwise deleting
  # a bounded child's write events (tool_call/result) alongside nulling its
  # policy would resume it unbounded — a cheaper elevation than fabricating the
  # trusted-root shape. read_only postures already returned :ok above.
  defp validate_restored_policy(
         session_id,
         %{permission_mode: :auto, write_policy: nil},
         _evidence?
       ),
       do: {:error, resume_posture_error(session_id, "unbounded_write_policy")}

  defp validate_restored_policy(_session_id, _posture, false), do: :ok

  defp validate_restored_policy(session_id, _posture, true),
    do: {:error, resume_posture_error(session_id, "unbounded_write_policy")}

  defp validate_restored_workspace(session_id, posture, workspace) do
    recorded = posture.workspace

    cond do
      not (is_binary(recorded) and recorded != "") ->
        {:error, resume_posture_error(session_id, "workspace_unavailable")}

      true ->
        case canonical_path(recorded) do
          {:ok, ^workspace} ->
            :ok

          {:ok, _other_workspace} ->
            {:error, resume_posture_error(session_id, "workspace_mismatch")}

          {:error, reason} ->
            {:error,
             resume_posture_error(session_id, "workspace_unavailable", %{
               "workspace" => Path.expand(recorded),
               "filesystem_reason" => inspect(reason)
             })}
        end
    end
  end

  # Resolve every existing symlink segment instead of comparing path spellings.
  # This covers macOS' /var -> /private/var alias and symlinked temp/worktree roots.
  defp canonical_path(path) do
    path
    |> Path.expand()
    |> canonical_path(0)
  end

  defp canonical_path(_path, depth) when depth > 20, do: {:error, :symlink_depth_exceeded}

  defp canonical_path(path, depth) do
    case Path.split(path) do
      [root | segments] -> resolve_path_segments(root, segments, depth)
      [] -> {:ok, path}
    end
  end

  defp resolve_path_segments(current, [], _depth), do: {:ok, current}

  defp resolve_path_segments(current, [segment | rest], depth) do
    candidate = Path.join(current, segment)

    case File.lstat(candidate) do
      {:ok, %File.Stat{type: :symlink}} ->
        case File.read_link(candidate) do
          {:ok, link} ->
            target =
              case Path.type(link) do
                :absolute -> Path.expand(link)
                _relative -> Path.expand(link, Path.dirname(candidate))
              end

            [target | rest]
            |> Path.join()
            |> canonical_path(depth + 1)

          {:error, reason} ->
            {:error, {:read_link_failed, candidate, reason}}
        end

      {:error, reason} when reason not in [:enoent] ->
        {:error, {:lstat_failed, candidate, reason}}

      _existing_or_not_yet_created ->
        resolve_path_segments(candidate, rest, depth)
    end
  end

  @doc "Apply the common restrict-never-widen rules to a restored posture."
  @spec restrict_resume_posture(map() | nil, Permissions.mode(), map() | nil) ::
          {:ok, map() | nil} | {:error, map()}
  def restrict_resume_posture(nil, _requested_mode, _requested_policy), do: {:ok, nil}

  def restrict_resume_posture(posture, requested_mode, requested_policy) when is_map(posture) do
    effective_mode = restrict_permission_mode(posture.permission_mode, requested_mode)

    with {:ok, effective_policy} <-
           restrict_write_policy(posture.write_policy, requested_policy) do
      {:ok,
       %{
         posture
         | permission_mode: effective_mode,
           write_policy: if(effective_mode == :read_only, do: nil, else: effective_policy)
       }}
    end
  end

  defp restrict_permission_mode(:read_only, _requested), do: :read_only
  defp restrict_permission_mode(_durable, :read_only), do: :read_only
  defp restrict_permission_mode(:ask, _requested), do: :ask
  defp restrict_permission_mode(_durable, :ask), do: :ask
  defp restrict_permission_mode(:auto, :auto), do: :auto

  defp restrict_write_policy(nil, requested), do: {:ok, requested}
  defp restrict_write_policy(durable, nil), do: {:ok, durable}

  defp restrict_write_policy(durable, requested) do
    durable_rules = durable["allow_writes"] || []
    requested_rules = requested["allow_writes"] || []

    intersection =
      (Enum.filter(durable_rules, &rule_set_covers?(requested, &1)) ++
         Enum.filter(requested_rules, &rule_set_covers?(durable, &1)))
      |> Enum.uniq()

    if intersection == [] do
      {:error,
       Tool.error(
         :resume_policy_unavailable,
         "restored and requested write policies do not overlap",
         %{
           "reason" => "empty_policy_intersection"
         }
       )}
    else
      WritePolicy.normalize(%{
        "version" => durable["version"],
        "metadata" => %{"id" => durable["id"]},
        "allow_writes" => intersection,
        "deny_writes" =>
          Enum.uniq((durable["deny_writes"] || []) ++ (requested["deny_writes"] || [])),
        "bash" => restrict_policy_bash(durable["bash"], requested["bash"])
      })
    end
  end

  defp rule_set_covers?(policy, rule) do
    match?({:ok, _}, WritePolicy.narrow_to_write_set(policy, [rule]))
  end

  defp restrict_policy_bash("disabled", _requested), do: "disabled"
  defp restrict_policy_bash(_durable, "disabled"), do: "disabled"

  defp restrict_policy_bash(%{"verify" => durable} = durable_bash, %{"verify" => requested} = req) do
    verify = Enum.filter(requested, &(&1 in durable))

    # The operator-declared verify allowlist (#445) must survive the intersection:
    # dropping it would silently re-impose the Elixir default and reject the very
    # commands both sides agreed on. A side that declared nothing contributes the
    # default it was normalized under.
    case intersect_verify_prefixes(durable_bash, req) do
      # Nothing shared to authorize: the honest restriction is a disabled shell.
      _prefixes when verify == [] ->
        "disabled"

      # Unreachable while `verify` is non-empty — a command both sides admitted
      # was covered by a prefix on each side, and two prefixes covering the same
      # command are always leading runs of it, so one covers the other. Kept as a
      # fail-closed floor rather than emitting an empty allowlist, which normalize
      # rejects as malformed.
      [] ->
        "disabled"

      nil ->
        %{"verify" => verify}

      prefixes ->
        %{"verify_prefixes" => prefixes, "verify" => verify}
    end
  end

  defp restrict_policy_bash(_durable, _requested), do: "disabled"

  # Prefixes are compared by tokenwise coverage, not as exact strings — the same
  # relation `rule_set_covers?/2` applies to write rules just above. A prefix is
  # a constraint on what may be admitted, so a survivor must be covered by the
  # durable side: it survives only when some durable prefix is a tokenwise prefix
  # of it, which means it admits a subset of what durable already admitted. The
  # filter runs both ways, so each survivor is at least as narrow as both sides
  # (durable `mix` against requested `mix format` keeps `mix format`).
  #
  # Exact string intersection was the bug: it dropped `mix` and `mix format` as
  # unrelated, and the surviving `verify` command `mix format --check-formatted`
  # was then left uncovered by the remaining prefixes. `WritePolicy.normalize/1`
  # re-validates the restricted map, so an uncovered command failed resume closed
  # on a command both sides had already authorized.
  defp intersect_verify_prefixes(%{"verify_prefixes" => a}, %{"verify_prefixes" => b})
       when is_list(a) and is_list(b) do
    (Enum.filter(b, fn requested -> Enum.any?(a, &prefix_covers?(&1, requested)) end) ++
       Enum.filter(a, fn durable -> Enum.any?(b, &prefix_covers?(&1, durable)) end))
    |> Enum.uniq()
  end

  # Only one side declared. The other was normalized under the built-in default,
  # and every surviving command was admitted by both, so the declaration stands.
  defp intersect_verify_prefixes(%{"verify_prefixes" => a}, _requested) when is_list(a), do: a
  defp intersect_verify_prefixes(_durable, %{"verify_prefixes" => b}) when is_list(b), do: b
  defp intersect_verify_prefixes(_durable, _requested), do: nil

  # `covering` admits everything `candidate` admits when its tokens are a leading
  # run of `candidate`'s: `mix` covers `mix format`, `mix format` does not cover
  # `mix`, and `mix` never covers `mixer` (token equality, never substring).
  defp prefix_covers?(covering, candidate) do
    covering_tokens = String.split(covering, ~r/\s+/, trim: true)
    candidate_tokens = String.split(candidate, ~r/\s+/, trim: true)

    Enum.take(candidate_tokens, length(covering_tokens)) == covering_tokens
  end

  defp resume_posture_error(session_id, reason, extra_details \\ %{}) do
    Tool.error(
      :resume_policy_unavailable,
      "refusing to resume without unambiguous permission posture evidence",
      Map.merge(
        %{
          "session_id" => session_id,
          "reason" => reason,
          "next_actions" => posture_error_next_actions(reason)
        },
        extra_details
      )
    )
  end

  # Only the `missing` classification is operator-overrideable: the Log is
  # readable and unambiguous, it just predates posture evidence. Every other
  # failure (unreadable, ambiguous, workspace mismatch, untrusted marker) has
  # no honest recovery besides fixing the evidence itself.
  defp posture_error_next_actions("missing") do
    [
      "inspect_the_child_session_log",
      "resume_with_--assume-legacy-root_--legacy-root-reason_and_an_explicit_read_only_ask_or_bounded_posture",
      "start_a_new_read_only_session_instead_of_widening_this_session"
    ]
  end

  defp posture_error_next_actions(_reason) do
    [
      "inspect_the_child_session_log",
      "recover_or_recreate_the_permission_posture_evidence",
      "start_a_new_read_only_session_instead_of_widening_this_session"
    ]
  end

  @doc "All known Subagent lifecycle statuses."
  def statuses, do: @statuses

  @doc "Statuses that no longer have a live child runtime."
  def terminal_statuses, do: @terminal_statuses

  @doc "Whether a status is terminal."
  def terminal?(status), do: status in @terminal_statuses

  @doc """
  Whether the public lifecycle contract allows a status transition.

  `closed` is retained as Pixir's local close/cleanup state. Completed, failed,
  timed-out, and cancelled Subagents may be restarted by `send_input/4`; detached
  children cannot be resumed because there is no live process handle.
  """
  def transition_allowed?(from, to) when is_binary(from) and is_binary(to) do
    to in Map.get(@allowed_transitions, from, [])
  end

  def transition_allowed?(_from, _to), do: false

  @doc """
  Reconstruct Subagent relationships and terminal state from parent History.
  """
  def reconstruct(history) when is_list(history) do
    history
    |> Enum.filter(&(&1.type == :subagent_event))
    # Session-scoped evidence a Session writes about ITSELF (permission posture at
    # spawn, the terminal `cancelled_by_parent` statement) is not a child lifecycle
    # event: folding it here would fabricate a phantom child — a nil-id one for
    # posture, or a self-referential entry for cancellation — and flip delegate
    # snapshots to incomplete. Only the parent-side records describe children.
    |> Enum.reject(&self_scoped_event?/1)
    |> Enum.reduce(%{}, fn %{data: data}, acc ->
      id = data["subagent_id"]

      current =
        Map.get(acc, id, %{
          "id" => id,
          "events" => []
        })

      updated =
        current
        |> Map.merge(Map.take(data, subagent_fields()))
        |> Map.put("events", current["events"] ++ [data["event"]])

      Map.put(acc, id, updated)
    end)
  end

  defp self_scoped_event?(%{data: %{"event" => "permission_posture"}}), do: true

  defp self_scoped_event?(%{data: %{"event" => "cancelled_by_parent", "lineage" => "child"}}),
    do: true

  defp self_scoped_event?(_event), do: false

  defp subagent_fields do
    [
      "subagent_id",
      "child_session_id",
      "agent",
      "status",
      "task",
      "depth",
      "max_depth",
      "workspace",
      "workspace_mode",
      "index",
      "parent_log_path",
      "child_log_path",
      "summary",
      "event",
      "timeout_ms",
      "deadline_at",
      "permission_mode",
      "write_policy",
      "warm_start",
      "elapsed_ms",
      "reason",
      "next_actions",
      "retry_attempts",
      "retry_max_attempts",
      "current_attempt_index",
      "retry_history",
      "virtual_diff_ref",
      "output_truncation",
      "output_warning_count",
      "output_warnings",
      "output_warning_reasons",
      "output_warnings_truncated"
    ]
  end
end
