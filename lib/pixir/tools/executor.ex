defmodule Pixir.Tools.Executor do
  @moduledoc """
  Central tool execution (CONTEXT.md): Pixir — not the model — runs Tools. The Executor
  resolves the tool, validates `args` against its schema, then dispatches to `execute/2`
  (or `dry_run/2` when `context.dry_run`).

  `run/2` is the Turn-loop entry point: it records the canonical `tool_call` Event
  before running and the `tool_result` Event after (both via `Pixir.Session`, so they
  get a `seq`, hit the Log, and publish). `execute_call/2` is the side-effect-free core
  (no Events) used directly in unit tests.
  """

  alias Pixir.{Event, Paths, Permissions, Session, Tool}
  alias Pixir.Permissions.WritePolicy
  alias Pixir.Tools.{Registry, Workspace}

  @type call :: %{call_id: String.t(), name: String.t(), args: map()}

  # Shell tokens that delete, move, or overwrite files. Combined with a `.pixir`
  # reference they trip the evidence guard below as a backwards-compatible fallback.
  @destructive_bash_tokens ~w(rm rmdir mv cp dd shred truncate unlink srm tee ln)

  @doc """
  Run a tool call within a Session: record `tool_call`, protect the Session's own
  evidence (`.pixir`), apply the permission policy (ADR 0006), execute (or refuse),
  record `tool_result`. Returns the raw `{:ok, result} | {:error, structured}` from
  the tool.

  The permission policy is read from `context.permission` (`%{mode, asker}`); it
  defaults to `:auto` (allow everything) so the common path has zero overhead.
  """
  @spec run(call(), Tool.context()) :: Tool.result()
  def run(%{call_id: id, name: name, args: args}, context) do
    sid = context.session_id

    with {:ok, _} <- Session.record(sid, Event.tool_call(sid, id, name, args)) do
      result =
        case protect_evidence(name, args, context.workspace) do
          :ok ->
            with :allow <- authorize_virtual_overlay(name, args, id, context),
                 :allow <- authorize_write_policy(name, args, id, context),
                 :allow <- authorize(name, args, id, context) do
              execute_call(%{name: name, args: args}, context)
            else
              {:deny, reason} -> {:error, Tool.error(:permission_denied, reason, %{tool: name})}
              {:error, _} = error -> error
            end

          {:error, %{error: %{kind: :protected_path}} = error} ->
            case record_evidence_protection_decision(context, id, error) do
              {:ok, _event} ->
                {:error, error}

              {:error, record_error} ->
                {:error,
                 Tool.error(
                   :session_record_unavailable,
                   "evidence protection decision could not be recorded",
                   %{call_id: id, record_error: record_error}
                 )}
            end

          {:error, _} = error ->
            error
        end

      record_result_or_fallback(sid, id, result)
    end
  end

  # ── evidence protection ────────────────────────────────────────────────────

  # The workspace `.pixir` state dir holds the Session Logs — the durable audit
  # evidence for this very run. No tool call may delete or overwrite it, in any
  # permission mode; the denial is terminal guidance, not something to route around.
  # This is a tripwire against self-evidence destruction, not a shell sandbox
  # (workspace-scoped shell policy is tracked separately).
  defp protect_evidence(name, %{"path" => path}, workspace) when name in ["write", "edit"] do
    case Workspace.confine(workspace, path) do
      {:ok, abs} ->
        if protected_state_path?(workspace, abs) do
          {:error, protected_path_error(name, path, workspace, abs)}
        else
          :ok
        end

      # An escaping path is the tool's own confinement error, not this guard's.
      {:error, _} ->
        :ok
    end
  end

  defp protect_evidence("apply_virtual_diff", %{"artifact" => artifact}, workspace)
       when is_map(artifact) do
    artifact
    |> virtual_diff_change_paths()
    |> Enum.find_value(:ok, fn path ->
      case Workspace.confine(workspace, path) do
        {:ok, abs} ->
          if protected_state_path?(workspace, abs) do
            {:error, protected_path_error("apply_virtual_diff", path, workspace, abs)}
          else
            false
          end

        # An escaping path is the tool's own confinement error, not this guard's.
        {:error, _} ->
          false
      end
    end)
  end

  defp protect_evidence("bash", %{"command" => command}, workspace)
       when is_binary(command) do
    tokens = String.split(command, ~r/\s+/, trim: true)
    normalized_tokens = Enum.map(tokens, &strip_shell_token/1)

    state_dir_reference? = Enum.any?(normalized_tokens, &state_dir_token?/1)

    unsafe_state_dir_reference? =
      state_dir_reference? and not Permissions.safe_command?(command)

    destructive_reference? =
      state_dir_reference? and Enum.any?(normalized_tokens, &(&1 in @destructive_bash_tokens))

    if unsafe_state_dir_reference? or destructive_reference? or
         mutating_find_can_reach_state_dir?(normalized_tokens, workspace) or
         redirect_into_state_dir?(normalized_tokens) or
         git_clean_removes_state_dir?(normalized_tokens) do
      {:error, protected_path_error("bash", command, workspace)}
    else
      :ok
    end
  end

  defp protect_evidence(_name, _args, _workspace), do: :ok

  defp apply_virtual_diff_change_paths(%{"artifact" => artifact}) when is_map(artifact) do
    virtual_diff_change_paths(artifact)
  end

  defp apply_virtual_diff_change_paths(_args), do: []

  defp virtual_diff_change_paths(%{"changes" => changes}) when is_list(changes) do
    changes
    |> Enum.map(fn
      %{"path" => path} when is_binary(path) -> path
      _change -> nil
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp virtual_diff_change_paths(_artifact), do: []

  defp state_dir_token?(token) do
    token
    |> String.trim("'")
    |> String.trim("\"")
    |> then(&Regex.match?(~r{(^|[^A-Za-z0-9_.-])\.pixir(/|$|[^A-Za-z0-9_.-])}, &1))
  end

  defp redirect_into_state_dir?(tokens) do
    tokens
    |> Enum.chunk_every(2, 1, [""])
    |> Enum.any?(fn
      [op, target] when op in [">", ">>"] ->
        state_dir_token?(target)

      [token, _next] ->
        String.starts_with?(token, ">") and state_dir_token?(String.trim_leading(token, ">"))
    end)
  end

  defp git_clean_removes_state_dir?(tokens) do
    tokens
    |> Enum.with_index()
    |> Enum.any?(fn
      {"git", index} ->
        case git_clean_args(Enum.drop(tokens, index + 1)) do
          {:ok, args} ->
            not git_clean_dry_run?(args) and
              (Enum.any?(args, &git_clean_ignored_flag?/1) or
                 Enum.any?(args, &state_dir_token?/1))

          :error ->
            false
        end

      _other ->
        false
    end)
  end

  defp git_clean_args(["clean" | args]), do: {:ok, args}

  defp git_clean_args([option, _value | rest])
       when option in ["-C", "-c", "--git-dir", "--work-tree", "--namespace"],
       do: git_clean_args(rest)

  defp git_clean_args([<<"-C", rest::binary>> | args]) when rest != "",
    do: git_clean_args(args)

  defp git_clean_args([<<"-c", rest::binary>> | args]) when rest != "",
    do: git_clean_args(args)

  defp git_clean_args([<<"--git-dir=", _rest::binary>> | args]), do: git_clean_args(args)
  defp git_clean_args([<<"--work-tree=", _rest::binary>> | args]), do: git_clean_args(args)
  defp git_clean_args([<<"--namespace=", _rest::binary>> | args]), do: git_clean_args(args)
  defp git_clean_args(_tokens), do: :error

  defp git_clean_dry_run?(args), do: Enum.any?(args, &git_clean_dry_run_flag?/1)

  defp git_clean_dry_run_flag?("--dry-run"), do: true
  defp git_clean_dry_run_flag?(<<"-", flags::binary>>), do: String.contains?(flags, "n")
  defp git_clean_dry_run_flag?(_flag), do: false

  defp git_clean_ignored_flag?(<<"-", flags::binary>>) do
    String.contains?(flags, "x") or String.contains?(flags, "X")
  end

  defp git_clean_ignored_flag?(_flag), do: false

  defp mutating_find_can_reach_state_dir?(tokens, workspace) do
    tokens
    |> Enum.with_index()
    |> Enum.any?(fn
      {"find", index} ->
        args = Enum.drop(tokens, index + 1)

        mutating_find_args?(args) and
          args
          |> find_roots()
          |> Enum.any?(&find_root_can_reach_state_dir?(workspace, &1))

      _other ->
        false
    end)
  end

  defp mutating_find_args?(args), do: Enum.any?(args, &Permissions.mutating_find_predicate?/1)

  defp find_roots(args) do
    args = drop_find_global_options(args)

    roots =
      args
      |> Enum.take_while(&(not find_expression_token?(&1)))

    case roots do
      [] -> ["."]
      roots -> roots
    end
  end

  defp drop_find_global_options([token | rest]) do
    if find_global_option?(token) do
      drop_find_global_options(rest)
    else
      [token | rest]
    end
  end

  defp drop_find_global_options([]), do: []

  defp find_expression_token?(token) do
    token = Permissions.strip_shell_quotes(token)
    String.starts_with?(token, "-") or token in ["(", ")", "!", ","]
  end

  defp find_global_option?(token), do: Permissions.strip_shell_quotes(token) in ["-H", "-L", "-P"]

  defp find_root_can_reach_state_dir?(workspace, root) do
    state_root = Paths.project_root(workspace)
    target = Path.expand(Permissions.strip_shell_quotes(root), workspace)

    with {:ok, canonical_target} <- canonical_path(target),
         {:ok, canonical_state_root} <- canonical_path(state_root) do
      path_contains?(canonical_target, canonical_state_root) or
        path_contains?(canonical_state_root, canonical_target)
    else
      {:error, _reason} -> true
    end
  end

  defp path_contains?(path, ancestor) do
    path = normalize_canonical_path(path)
    ancestor = normalize_canonical_path(ancestor)

    path == ancestor or ancestor == "/" or String.starts_with?(path, ancestor <> "/")
  end

  defp normalize_canonical_path("/"), do: "/"
  defp normalize_canonical_path(path), do: String.trim_trailing(path, "/")

  defp strip_shell_token(token) do
    Enum.reduce(["'", "\"", "`", "(", ")", ";"], String.trim(token), fn char, acc ->
      String.trim(acc, char)
    end)
  end

  defp protected_state_path?(workspace, abs) do
    root = Paths.project_root(workspace)

    with {:ok, canonical_abs} <- canonical_path(abs),
         {:ok, canonical_root} <- canonical_path(root) do
      canonical_abs == canonical_root or String.starts_with?(canonical_abs, canonical_root <> "/")
    else
      {:error, _reason} -> true
    end
  end

  defp canonical_path(path) do
    path
    |> Path.expand()
    |> canonical_path(0)
  end

  defp canonical_path(_path, depth) when depth > 20, do: {:error, :symlink_depth_exceeded}

  defp canonical_path(path, depth) do
    case Path.split(path) do
      [root | segments] -> resolve_segments(root, segments, depth)
      [] -> path
    end
  end

  defp resolve_segments(current, [], _depth), do: {:ok, current}

  defp resolve_segments(current, [segment | rest], depth) do
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

          {:error, _} ->
            {:error, {:read_link_failed, candidate}}
        end

      _other ->
        resolve_segments(candidate, rest, depth)
    end
  end

  defp protected_path_error(tool, target, workspace),
    do: protected_path_error(tool, target, workspace, nil)

  defp protected_path_error(tool, target, workspace, normalized_target) do
    Tool.error(
      :protected_path,
      ".pixir holds this session's durable evidence and cannot be mutated by tool calls",
      %{
        tool: tool,
        target: target,
        protected_root: if(workspace, do: evidence_path(Paths.project_root(workspace))),
        normalized_target: if(normalized_target, do: evidence_path(normalized_target)),
        next_actions: [
          "leave the .pixir state dir intact",
          "read evidence with the read tool or `pixir diagnose session <id> --json`"
        ]
      }
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()
    )
  end

  defp evidence_path(path) do
    case canonical_path(path) do
      {:ok, canonical} -> canonical
      {:error, _reason} -> Path.expand(path)
    end
  end

  defp record_evidence_protection_decision(
         context,
         call_id,
         %{error: %{kind: kind, message: message, details: details}}
       ) do
    details =
      %{
        "gate" => "evidence_protection",
        "error_kind" => to_string(kind),
        "message" => message,
        "tool" => Map.get(details, :tool),
        "target" => Map.get(details, :target),
        "protected_root" => Map.get(details, :protected_root),
        "normalized_target" => Map.get(details, :normalized_target),
        "next_actions" => Map.get(details, :next_actions)
      }
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()

    record_decision(context, call_id, :deny, details)
  end

  # ── virtual overlay boundary ─────────────────────────────────────────────

  # A virtual overlay child works exclusively against the imported in-memory
  # filesystem (ADR 0028: read_boundary "imported_read_set_only"). The
  # operator context is the switch: when present, host-reaching tools are
  # denied and real reads are confined to the imported read set — otherwise
  # the fidelity contract recorded in the parent's delegation evidence lies.
  # bash gets the non-terminal :bash_disabled kind so the child adapts to
  # run_virtual_commands (#218 precedent); the rest deny as permission_denied.
  @virtual_overlay_denied_tools ~w(write edit spawn_agent run_workflow apply_virtual_diff)

  defp authorize_virtual_overlay(name, args, call_id, %{virtual_overlay: overlay} = context)
       when is_map(overlay) do
    cond do
      # Pure validation crosses no host boundary: a virtual child may rehearse
      # a spawn (validate_only exactly true) even though real spawns are denied.
      name == "spawn_agent" and args["validate_only"] == true ->
        :allow

      name == "bash" ->
        details = virtual_overlay_denial_details(name)
        record_decision(context, call_id, :deny, details)

        {:error,
         Tool.error(
           :bash_disabled,
           "bash is unavailable in a virtual overlay child; run commands through run_virtual_commands",
           details
         )}

      name in @virtual_overlay_denied_tools ->
        details = virtual_overlay_denial_details(name)
        record_decision(context, call_id, :deny, details)

        {:error,
         Tool.error(
           :permission_denied,
           "#{name} is unavailable in a virtual overlay child",
           details
         )}

      name == "read" ->
        authorize_virtual_read(args, call_id, overlay, context)

      true ->
        :allow
    end
  end

  defp authorize_virtual_overlay(_name, _args, _call_id, _context), do: :allow

  defp virtual_overlay_denial_details(name) do
    %{
      "gate" => "virtual_overlay",
      "matched_rule" => "virtual_overlay_host_boundary",
      "tool" => name,
      "next_actions" => ["use_run_virtual_commands_for_virtual_changes"]
    }
  end

  defp authorize_virtual_read(%{"path" => path}, call_id, overlay, context) do
    # Workspace.confine expands the root internally; expand it here too so the
    # relative path is derived against the same base even when the stored
    # workspace is relative (e.g. ".").
    with {:ok, abs} <- Workspace.confine(context.workspace, path),
         rel = Path.relative_to(abs, Path.expand(context.workspace)),
         false <- WritePolicy.rules_cover_path?(overlay.read_set, rel) do
      details = %{
        "gate" => "virtual_overlay",
        "matched_rule" => "virtual_overlay_read_set",
        "normalized_path" => rel,
        "next_actions" => [
          "read_within_imported_read_set",
          "use_run_virtual_commands_for_virtual_changes"
        ]
      }

      record_decision(context, call_id, :deny, details)

      {:error,
       Tool.error(:permission_denied, "read outside the imported virtual read set", details)}
    else
      # Covered paths are allowed; confinement errors fall through to the
      # read tool's own boundary handling.
      true -> :allow
      {:error, _confinement} -> :allow
    end
  end

  defp authorize_virtual_read(_args, _call_id, _overlay, _context), do: :allow

  # Consult the bounded write policy before permission mode. This is a headless
  # executor guard, not an interactive approval flow: denial is structured and
  # auditable. Write-allowlist denials are terminal for the Turn loop; a
  # bash_disabled denial is not (the model adapts with native tools, #218).
  defp authorize_write_policy(name, args, call_id, context) do
    policy = get_in(context, [:permission, :policy])

    case authorize_write_policy_tool(policy, name, args, context.workspace) do
      :allow ->
        if policy && Permissions.mutating?(name, args) do
          record_decision(context, call_id, :allow, %{
            "gate" => "write_policy",
            "policy" => WritePolicy.metadata(policy)
          })
        end

        :allow

      {:deny, %{error: %{details: details}} = error} ->
        record_decision(context, call_id, :deny, policy_decision_details(details))
        {:error, error}

      {:error, %{error: %{kind: :write_policy_denied, details: details}} = error} ->
        record_decision(context, call_id, :deny, policy_decision_details(details))
        {:error, error}

      {:error, _error} = error ->
        error
    end
  end

  defp authorize_write_policy_tool(nil, _name, _args, _workspace), do: :allow

  defp authorize_write_policy_tool(policy, "apply_virtual_diff", args, workspace) do
    if Permissions.mutating?("apply_virtual_diff", args) do
      args
      |> apply_virtual_diff_change_paths()
      |> Enum.reduce_while(:allow, fn path, :allow ->
        case WritePolicy.authorize_tool(policy, "write", %{"path" => path}, workspace) do
          :allow ->
            {:cont, :allow}

          {:deny, error} ->
            {:halt, {:deny, apply_virtual_diff_policy_error(error)}}

          {:error, %{error: %{kind: :write_policy_denied}} = error} ->
            {:halt, {:error, apply_virtual_diff_policy_error(error)}}

          {:error, _error} = error ->
            {:halt, error}
        end
      end)
    else
      :allow
    end
  end

  defp authorize_write_policy_tool(policy, name, args, workspace) do
    WritePolicy.authorize_tool(policy, name, args, workspace)
  end

  defp apply_virtual_diff_policy_error(%{error: %{details: details}} = error)
       when is_map(details) do
    put_in(error, [:error, :details], Map.put(details, "tool", "apply_virtual_diff"))
  end

  defp apply_virtual_diff_policy_error(error), do: error

  defp policy_decision_details(details) do
    %{
      "gate" => "write_policy",
      "policy_id" => Map.get(details, "policy_id"),
      "policy_hash" => Map.get(details, "policy_hash"),
      "policy_version" => Map.get(details, "policy_version"),
      "tool" => Map.get(details, "tool"),
      "requested_command" => Map.get(details, "requested_command"),
      "token" => Map.get(details, "token"),
      "requested_path" => Map.get(details, "requested_path"),
      "normalized_path" => Map.get(details, "normalized_path"),
      "matched_rule" => Map.get(details, "matched_rule") || Map.get(details, "rule"),
      "rule" => Map.get(details, "rule")
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  # Consult the policy; for :ask, invoke the front-end asker. Records a canonical
  # `permission_decision` Event whenever the mode is not :auto (auditable, ADR 0006).
  defp authorize(name, args, call_id, context) do
    %{mode: mode} = perm = Map.get(context, :permission, %{mode: :auto, asker: &default_deny/1})

    case Permissions.decide(mode, name, args) do
      :allow ->
        if mode != :auto, do: record_decision(context, call_id, :allow)
        :allow

      :deny ->
        record_decision(context, call_id, :deny)
        {:deny, "denied by #{mode} mode"}

      {:ask, reason} ->
        asker = Map.get(perm, :asker, &default_deny/1)

        case asker.(%{tool: name, args: args, reason: reason, call_id: call_id}) do
          :allow ->
            record_decision(context, call_id, :allow)
            :allow

          _denied ->
            record_decision(context, call_id, :deny)
            {:deny, "denied by user"}
        end
    end
  end

  defp record_decision(context, call_id, decision, details \\ %{}) do
    Session.record(
      context.session_id,
      Event.permission_decision(context.session_id, call_id, decision, details: details)
    )
  end

  defp default_deny(_request), do: :deny

  @doc "Resolve, validate, and run (or dry-run) a tool call without emitting Events."
  @spec execute_call(%{name: String.t(), args: map()}, Tool.context()) :: Tool.result()
  def execute_call(%{name: name, args: args}, context) do
    with {:ok, module} <- Registry.fetch(name),
         :ok <- validate(module.__tool__(), args) do
      if Map.get(context, :dry_run, false) do
        module.dry_run(args, context)
      else
        module.execute(args, context)
      end
    end
  end

  # ── schema validation (minimal) ──────────────────────────────────────────

  defp validate(%{parameters: %{"required" => required} = schema}, args) when is_list(required) do
    props = Map.get(schema, "properties", %{})

    case Enum.reject(required, &Map.has_key?(args, &1)) do
      [] ->
        case for(k <- required, not type_ok?(props[k], args[k]), do: k) do
          [] -> :ok
          bad -> {:error, Tool.error(:invalid_args, "argument type mismatch", %{invalid: bad})}
        end

      missing ->
        {:error, Tool.error(:invalid_args, "missing required arguments", %{missing: missing})}
    end
  end

  defp validate(_spec, _args), do: :ok

  defp type_ok?(%{"type" => "string"}, v), do: is_binary(v)
  defp type_ok?(%{"type" => "integer"}, v), do: is_integer(v)
  defp type_ok?(%{"type" => "number"}, v), do: is_number(v)
  defp type_ok?(%{"type" => "boolean"}, v), do: is_boolean(v)
  defp type_ok?(%{"type" => "object"}, v), do: is_map(v)
  defp type_ok?(%{"type" => "array"}, v), do: is_list(v)
  defp type_ok?(_schema, _v), do: true

  # ── tool_result event data ─────────────────────────────────────────────────

  defp record_result_or_fallback(sid, call_id, result) do
    case Session.record(sid, Event.tool_result(sid, call_id, result_data(result))) do
      {:ok, _} ->
        result

      {:error, record_error} ->
        fallback =
          {:error,
           Tool.error(
             :tool_result_record_failed,
             "tool result could not be recorded safely",
             %{
               call_id: call_id,
               record_error: record_error
             }
           )}

        _ = Session.record(sid, Event.tool_result(sid, call_id, result_data(fallback)))
        fallback
    end
  end

  defp result_data({:ok, result}) when is_map(result), do: Map.put_new(result, "ok", true)
  defp result_data({:error, %{error: error}}), do: %{"ok" => false, "error" => error}
end
