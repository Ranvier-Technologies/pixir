defmodule Pixir.Permissions.WritePolicy do
  @moduledoc """
  Bounded write policy for headless executor/delegate runs.

  The policy is deliberately narrower than `:auto`: it only authorizes `write` and
  `edit` against canonical workspace-relative paths, keeps unsafe shell disabled, and
  fails closed when paths or rules are ambiguous. It is a runtime object carried in
  `context.permission.policy`, not a replacement for the existing permission-mode atom.
  """

  alias Pixir.{Permissions, Tool}
  alias Pixir.Tools.Workspace

  @version 1
  @max_rules 100
  @implicit_denies [".pixir/**", ".git/**", "**/.env*", "**/secrets/**"]
  @allowed_keys ~w(version metadata allow_writes deny_writes bash)
  @safe_bash_commands ~w(ls cat pwd echo grep rg ripgrep head tail wc which whoami date true
                         tree stat file dirname basename realpath sort uniq diff)
  @shell_metachars ["\n", "\r", "&&", "||", ";", "|", "&", ">", "<", "`", "$(", ">>"]
  @accepted_verify_prefixes [["mix", "format"], ["mix", "compile"]]
  @max_verify_commands 8

  @doc "Load and normalize a bounded write policy JSON file."
  @spec from_file(String.t(), String.t()) :: {:ok, map()} | {:error, map()}
  def from_file(path, workspace) when is_binary(path) and is_binary(workspace) do
    with {:ok, raw} <- read_policy_file(path),
         {:ok, decoded} <- decode_policy(raw, path),
         {:ok, policy} <- normalize(decoded, workspace: workspace, policy_file: path) do
      {:ok, policy}
    end
  end

  @doc "Normalize a bounded write policy map and compute stable metadata."
  @spec normalize(map(), keyword()) :: {:ok, map()} | {:error, map()}
  def normalize(raw, opts \\ [])

  def normalize(raw, opts) when is_map(raw) do
    policy = stringify(raw)

    with :ok <- reject_unknown_keys(policy),
         :ok <- require_version(policy),
         {:ok, metadata} <- normalize_metadata(Map.get(policy, "metadata", %{})),
         {:ok, allow_writes} <- normalize_rule_list(policy, "allow_writes", required?: true),
         {:ok, deny_writes} <- normalize_rule_list(policy, "deny_writes", required?: false),
         {:ok, bash} <- normalize_bash(Map.get(policy, "bash", "disabled")),
         {:ok, active_policy_rule} <- active_policy_rule(opts) do
      deny_writes =
        (@implicit_denies ++ deny_writes ++ List.wrap(active_policy_rule))
        |> Enum.uniq()

      normalized = %{
        "version" => @version,
        "metadata" => metadata,
        "id" => Map.get(metadata, "id", "bounded-write"),
        "allow_writes" => allow_writes,
        "deny_writes" => deny_writes,
        "bash" => bash
      }

      {:ok, Map.put(normalized, "hash", policy_hash(normalized))}
    end
  end

  def normalize(_raw, _opts),
    do: {:error, Tool.error(:invalid_args, "write_policy must be a JSON object", %{})}

  @doc "Machine-readable policy metadata safe for CLI/delegate JSON output."
  @spec metadata(map() | nil) :: map() | nil
  def metadata(nil), do: nil

  def metadata(policy) when is_map(policy) do
    %{
      "version" => policy["version"],
      "id" => policy["id"],
      "hash" => policy["hash"],
      "allow_writes" => policy["allow_writes"],
      "deny_writes" => policy["deny_writes"],
      "bash" => policy["bash"]
    }
  end

  @doc """
  Rehydrate a runtime policy from safe metadata previously written to the Log.

  The hash is recomputed from the canonical durable fields before the metadata is
  trusted. A mismatch means the Log projection was altered or came from an incompatible
  hash format and therefore fails closed.
  """
  @spec from_metadata(map() | nil) :: {:ok, map() | nil} | {:error, map()}
  def from_metadata(nil), do: {:ok, nil}

  def from_metadata(metadata) when is_map(metadata) do
    policy = stringify(metadata)

    with :ok <- require_version(policy),
         {:ok, id} <- require_metadata_string(policy, "id"),
         {:ok, stored_hash} <- require_metadata_string(policy, "hash"),
         {:ok, allow_writes} <- restore_rule_list(policy, "allow_writes"),
         {:ok, deny_writes} <- restore_rule_list(policy, "deny_writes"),
         {:ok, bash} <- normalize_bash(Map.get(policy, "bash", "disabled")) do
      restored = %{
        "version" => @version,
        "id" => id,
        "allow_writes" => allow_writes,
        "deny_writes" => deny_writes,
        "bash" => bash
      }

      computed_hash = policy_hash(restored)

      if stored_hash == computed_hash do
        {:ok, Map.put(restored, "hash", computed_hash)}
      else
        {:error,
         Tool.error(:invalid_args, "write policy metadata hash does not match its content", %{
           "stored_hash" => stored_hash,
           "computed_hash" => computed_hash,
           "matched_rule" => "metadata_hash_mismatch"
         })}
      end
    end
  end

  def from_metadata(_metadata),
    do: {:error, Tool.error(:invalid_args, "write policy metadata must be an object", %{})}

  @doc "Authorize one tool call under a bounded write policy."
  @spec authorize_tool(map() | nil, String.t(), map(), String.t()) ::
          :allow | {:deny, map()} | {:error, map()}
  def authorize_tool(nil, _tool, _args, _workspace), do: :allow

  def authorize_tool(policy, tool, args, workspace) when tool in ["write", "edit"] do
    path = Map.get(args, "path")

    with {:ok, rel} <- canonical_relative(workspace, path) do
      authorize_write_target(policy, tool, path, rel)
    end
  end

  def authorize_tool(policy, "bash", %{"command" => command}, workspace) do
    case Permissions.outside_workspace_shell_token(command, workspace) do
      {:ok, token} when is_binary(token) ->
        {:deny, outside_workspace_denial(policy, command, token)}

      {:ok, nil} ->
        cond do
          bounded_safe_command?(command) ->
            :allow

          declared_verify_command?(policy, command) ->
            :allow

          true ->
            {:deny, bash_disabled_denial(policy, command)}
        end
    end
  end

  def authorize_tool(policy, "spawn_agent", args, _workspace) do
    if Map.has_key?(args, "write_policy") do
      {:deny,
       denial(policy, "spawn_agent", "child_policy_override_unsupported", %{
         "matched_rule" => "child_policy_override_unsupported"
       })}
    else
      :allow
    end
  end

  def authorize_tool(_policy, tool, _args, _workspace)
      when tool in ["run_workflow", "send_input", "close_agent"],
      do: :allow

  def authorize_tool(policy, tool, args, _workspace) do
    if Permissions.mutating?(tool, args) do
      {:deny,
       denial(policy, tool, "unsupported_mutating_tool", %{
         "matched_rule" => "unsupported_mutating_tool"
       })}
    else
      :allow
    end
  end

  @doc "Return a policy narrowed to the given write set."
  @spec narrow_to_write_set(map(), [String.t()]) :: {:ok, map()} | {:error, map()}
  def narrow_to_write_set(policy, write_set) when is_map(policy) and is_list(write_set) do
    rules = Enum.map(write_set, &normalize_rule/1)

    with :ok <- validate_path_rules(rules, "write_set"),
         :ok <- ensure_rules_narrow(policy, rules) do
      narrowed =
        policy
        |> Map.put("allow_writes", rules)
        |> Map.delete("hash")

      # Hash only the durable fields, exactly like policy_hash/1 and
      # from_metadata/1 — a narrowed policy persisted as posture metadata must
      # verify on cold resume, and hashing the full map (metadata included)
      # would fail closed with metadata_hash_mismatch on honest data.
      narrowed = Map.put(narrowed, "hash", policy_hash(narrowed))

      {:ok, narrowed}
    end
  end

  @doc "Whether a policy explicitly allows the whole workspace."
  @spec allows_global?(map() | nil) :: boolean()
  def allows_global?(%{"allow_writes" => allow_writes}), do: "**/*" in allow_writes
  def allows_global?(_policy), do: false

  @doc "Validate that every write_set rule is within a parent policy allow rule."
  @spec validate_write_set_within_policy(map(), [String.t()]) :: :ok | {:error, map()}
  def validate_write_set_within_policy(policy, write_set) do
    with {:ok, _narrowed} <- narrow_to_write_set(policy, write_set), do: :ok
  end

  @doc "Canonical workspace-relative target for policy checks."
  @spec canonical_relative(String.t(), String.t()) :: {:ok, String.t()} | {:error, map()}
  def canonical_relative(_workspace, path) when not is_binary(path) or path == "",
    do:
      {:error,
       Tool.error(:invalid_args, "write policy target path must be a non-empty string", %{})}

  def canonical_relative(workspace, path) do
    root = Path.expand(workspace)

    with {:ok, abs} <- confine_policy_path(root, path),
         :ok <- reject_symlink_components(root, abs) do
      rel = Path.relative_to(abs, root)

      if rel == "." do
        {:error,
         Tool.error(:write_policy_denied, "write denied by bounded write policy", %{
           "matched_rule" => "workspace_root_not_writable",
           "normalized_path" => rel,
           "next_actions" => ["request_policy_expansion", "write_within_allowed_globs"]
         })}
      else
        {:ok, rel}
      end
    end
  end

  # ── authorization ───────────────────────────────────────────────────────

  defp authorize_write_target(policy, tool, requested_path, rel) do
    cond do
      protected = protected_path_rule(rel) ->
        {:deny,
         denial(policy, tool, "protected_path", %{
           "requested_path" => requested_path,
           "normalized_path" => rel,
           "matched_rule" => protected
         })}

      deny = Enum.find(policy["deny_writes"], &deny_matches?(&1, rel)) ->
        {:deny,
         denial(policy, tool, "deny_match", %{
           "requested_path" => requested_path,
           "normalized_path" => rel,
           "matched_rule" => deny
         })}

      Enum.any?(policy["allow_writes"], &allow_matches?(&1, rel)) ->
        :allow

      true ->
        {:deny,
         denial(policy, tool, "no_allow_match", %{
           "requested_path" => requested_path,
           "normalized_path" => rel,
           "matched_rule" => "no_allow_match"
         })}
    end
  end

  defp denial(policy, tool, rule, details) do
    Tool.error(
      :write_policy_denied,
      "write denied by bounded write policy",
      Map.merge(details, %{
        "tool" => tool,
        "policy_id" => policy["id"],
        "policy_hash" => policy["hash"],
        "policy_version" => policy["version"],
        "rule" => rule,
        "next_actions" => ["request_policy_expansion", "write_within_allowed_globs"]
      })
    )
  end

  # The shell being disabled is a property of the bounded-write mode, not a write
  # allowlist violation: the denial must not read as "write denied" when the command
  # was a read (#218). Distinct kind, honest message, shell-free next_actions.
  defp bash_disabled_denial(policy, command) do
    Tool.error(
      :bash_disabled,
      "shell is disabled by the bounded write policy",
      %{
        "tool" => "bash",
        "requested_command" => command,
        "normalized_path" => nil,
        "policy_id" => policy["id"],
        "policy_hash" => policy["hash"],
        "policy_version" => policy["version"],
        "rule" => "bash_disabled",
        "matched_rule" => "bash_disabled",
        "verify_commands_declared" => verify_command_count(policy),
        "next_actions" => ["use_native_read_tools", "use_edit_or_write_within_allowed_globs"]
      }
    )
  end

  defp outside_workspace_denial(policy, command, token) do
    Tool.error(
      :outside_workspace,
      "bash command references a path outside the workspace",
      %{
        "tool" => "bash",
        "requested_command" => command,
        "token" => token,
        "matched_rule" => "outside_workspace",
        "policy_id" => policy["id"],
        "policy_hash" => policy["hash"],
        "policy_version" => policy["version"],
        "next_actions" => [
          "use_workspace_relative_paths",
          "use_pixir_read_tool_for_file_access",
          "run_pixir_from_the_intended_workspace_root"
        ]
      }
    )
  end

  defp normalize_bash("disabled") do
    _ = validate_bash("disabled")
    {:ok, "disabled"}
  end

  defp normalize_bash(%{} = bash) do
    bash = stringify(bash)

    with :ok <- reject_unknown_bash_keys(bash),
         :ok <- require_bash_verify_key(bash),
         {:ok, verify} <- normalize_verify_commands(Map.get(bash, "verify")) do
      {:ok, %{"verify" => verify}}
    end
  end

  defp normalize_bash(other) do
    {:error,
     Tool.error(
       :invalid_args,
       "write_policy bash must be disabled or a verify command map",
       %{
         "observed" => other,
         "accepted_values" => ["disabled", %{"verify" => accepted_verify_prefixes()}]
       }
     )}
  end

  defp reject_unknown_bash_keys(bash) do
    case Map.keys(bash) -- ["verify"] do
      [] ->
        :ok

      unknown ->
        {:error,
         Tool.error(:invalid_args, "write_policy bash verify map has unsupported keys", %{
           "observed" => unknown,
           "accepted_keys" => ["verify"]
         })}
    end
  end

  defp require_bash_verify_key(%{"verify" => _verify}), do: :ok

  defp require_bash_verify_key(_bash) do
    {:error,
     Tool.error(:invalid_args, "write_policy bash map requires verify", %{
       "missing" => ["verify"],
       "accepted_keys" => ["verify"]
     })}
  end

  defp normalize_verify_commands(commands) when is_list(commands) do
    if length(commands) > @max_verify_commands do
      {:error,
       Tool.error(:invalid_args, "write_policy bash verify command list is too large", %{
         "observed_count" => length(commands),
         "accepted_max" => @max_verify_commands
       })}
    else
      commands
      |> Enum.reduce_while({:ok, []}, fn command, {:ok, acc} ->
        case normalize_verify_command(command) do
          {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
          {:error, _} = error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
        {:error, _} = error -> error
      end
    end
  end

  defp normalize_verify_commands(other) do
    {:error,
     Tool.error(:invalid_args, "write_policy bash verify must be a list", %{
       "observed" => other,
       "accepted_type" => "list"
     })}
  end

  defp normalize_verify_command(command) when is_binary(command) do
    command = String.trim(command)

    cond do
      command == "" ->
        {:error,
         Tool.error(
           :invalid_args,
           "write_policy bash verify entries must be non-empty strings",
           %{
             "observed" => command,
             "accepted_prefixes" => accepted_verify_prefixes()
           }
         )}

      metachar = Enum.find(@shell_metachars, &String.contains?(command, &1)) ->
        {:error,
         Tool.error(
           :invalid_args,
           "write_policy bash verify entries may not contain shell metacharacters",
           %{
             "observed" => command,
             "metachar" => metachar,
             "accepted_prefixes" => accepted_verify_prefixes()
           }
         )}

      command
      |> String.split(~r/\s+/, trim: true)
      |> Enum.any?(&parent_directory_token?/1) ->
        {:error,
         Tool.error(
           :invalid_args,
           "write_policy bash verify entries may not contain parent-directory tokens",
           %{
             "observed" => command,
             "accepted_prefixes" => accepted_verify_prefixes()
           }
         )}

      verify_prefix(command) == ["mix", "test"] ->
        {:error,
         Tool.error(
           :invalid_args,
           "verify test commands are not accepted yet (v1 allows format/compile only)",
           %{
             "observed" => command,
             "accepted_prefixes" => accepted_verify_prefixes(),
             "next_action" => "keep_test_execution_with_the_orchestrator"
           }
         )}

      verify_prefix(command) in @accepted_verify_prefixes ->
        {:ok, command}

      true ->
        {:error,
         Tool.error(
           :invalid_args,
           "write_policy bash verify entries must start with an accepted command prefix",
           %{
             "observed" => command,
             "accepted_prefixes" => accepted_verify_prefixes()
           }
         )}
    end
  end

  defp normalize_verify_command(other) do
    {:error,
     Tool.error(
       :invalid_args,
       "write_policy bash verify entries must be non-empty strings",
       %{
         "observed" => other,
         "accepted_prefixes" => accepted_verify_prefixes()
       }
     )}
  end

  defp verify_prefix(command), do: command |> String.split(~r/\s+/, trim: true) |> Enum.take(2)

  defp accepted_verify_prefixes, do: Enum.map(@accepted_verify_prefixes, &Enum.join(&1, " "))

  defp declared_verify_command?(policy, command) do
    String.trim(command) in verify_commands(policy)
  end

  defp verify_command_count(policy), do: length(verify_commands(policy))

  defp verify_commands(%{"bash" => %{"verify" => commands}}) when is_list(commands), do: commands
  defp verify_commands(_policy), do: []

  # ── path matching ───────────────────────────────────────────────────────

  defp protected_path_rule(rel) do
    segments = rel |> Path.split() |> Enum.map(&String.downcase/1)

    cond do
      List.first(segments) == ".pixir" -> ".pixir/**"
      List.first(segments) == ".git" -> ".git/**"
      Enum.any?(segments, &String.starts_with?(&1, ".env")) -> "**/.env*"
      "secrets" in segments -> "**/secrets/**"
      true -> nil
    end
  end

  @doc """
  Whether a workspace-relative path is covered by one of the given allow-style
  rules. Public single source for the policy glob semantics (#284 F2: the
  workflow apply step's write_set bound delegates here instead of hand-rolling
  a second matcher).
  """
  @spec rules_cover_path?([String.t()], String.t()) :: boolean()
  def rules_cover_path?(rules, rel) when is_list(rules) and is_binary(rel) do
    Enum.any?(rules, &allow_matches?(normalize_rule(&1), rel))
  end

  @doc "Validate a list of allow/deny path rules against the policy glob grammar."
  @spec validate_path_rules([String.t()], String.t()) :: :ok | {:error, map()}
  def validate_path_rules(rules, field) when is_list(rules) do
    Enum.reduce_while(rules, :ok, fn rule, :ok ->
      case validate_rule(rule, field) do
        :ok -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp deny_matches?(pattern, rel) do
    matches?(pattern, rel) or matches?(String.downcase(pattern), String.downcase(rel))
  end

  defp allow_matches?("**/*", rel), do: rel != ""

  defp allow_matches?("**/" <> rest, rel) do
    leaf = Path.basename(rel)

    cond do
      String.ends_with?(rest, "/**") ->
        dir = String.trim_trailing(rest, "/**")
        dir in Path.split(rel)

      String.ends_with?(rest, "*") ->
        prefix = String.trim_trailing(rest, "*")
        String.starts_with?(leaf, prefix)

      true ->
        leaf == rest
    end
  end

  defp allow_matches?(pattern, rel), do: matches?(pattern, rel)

  defp matches?("**/*", rel), do: rel != ""

  defp matches?("**/" <> rest, rel) do
    segments = Path.split(rel)

    cond do
      String.ends_with?(rest, "/**") ->
        dir = String.trim_trailing(rest, "/**")
        dir in segments

      String.ends_with?(rest, "*") ->
        prefix = String.trim_trailing(rest, "*")
        Enum.any?(segments, &String.starts_with?(&1, prefix))

      true ->
        rest in segments
    end
  end

  defp matches?(pattern, rel) do
    cond do
      String.ends_with?(pattern, "/**") ->
        prefix = String.trim_trailing(pattern, "/**")
        rel == prefix or String.starts_with?(rel, prefix <> "/")

      true ->
        rel == pattern
    end
  end

  defp normalize_rule(rule) when is_binary(rule) do
    rule
    |> String.trim()
    |> String.replace(~r{/+}, "/")
    |> trim_current_dir_prefix()
  end

  defp normalize_rule(rule), do: rule

  defp trim_current_dir_prefix("./" <> rest), do: trim_current_dir_prefix(rest)
  defp trim_current_dir_prefix(rule), do: rule

  defp validate_rule(rule, field) when is_binary(rule) and rule != "" do
    cond do
      Path.type(rule) == :absolute ->
        {:error, invalid_rule(field, rule, "absolute paths are not supported")}

      rule |> String.split("/", trim: false) |> Enum.any?(&(&1 == "..")) ->
        {:error, invalid_rule(field, rule, "parent-directory segments are not supported")}

      String.ends_with?(rule, "/") ->
        {:error, invalid_rule(field, rule, "trailing-slash rules are not supported; use /**")}

      rule == "**/*" ->
        :ok

      String.ends_with?(rule, "/**") and not contains_glob?(String.trim_trailing(rule, "/**")) ->
        :ok

      String.starts_with?(rule, "**/") ->
        validate_any_segment_rule(rule, field)

      not String.contains?(rule, "*") ->
        :ok

      true ->
        {:error, invalid_rule(field, rule, "unsupported glob shape")}
    end
  end

  defp validate_rule(rule, field),
    do: {:error, invalid_rule(field, inspect(rule), "rule must be a non-empty string")}

  defp validate_any_segment_rule("**/" <> rest = rule, field) do
    cond do
      rest == "" ->
        {:error, invalid_rule(field, rule, "any-segment rule needs a target")}

      String.ends_with?(rest, "/**") and String.contains?(String.trim_trailing(rest, "/**"), "*") ->
        {:error,
         invalid_rule(field, rule, "directory any-segment rule cannot contain glob characters")}

      String.ends_with?(rest, "*") and String.contains?(String.trim_trailing(rest, "*"), "*") ->
        {:error,
         invalid_rule(field, rule, "prefix any-segment rule has too many glob characters")}

      not String.ends_with?(rest, "*") and String.contains?(rest, "*") ->
        {:error, invalid_rule(field, rule, "unsupported any-segment glob shape")}

      true ->
        :ok
    end
  end

  defp contains_glob?(value), do: String.contains?(value, "*")

  defp ensure_rules_narrow(policy, rules) do
    Enum.reduce_while(rules, :ok, fn rule, :ok ->
      if Enum.any?(policy["allow_writes"], &syntactically_contains?(&1, rule)) do
        {:cont, :ok}
      else
        {:halt,
         {:error,
          Tool.error(:write_policy_denied, "child write policy would broaden parent policy", %{
            "rule" => rule,
            "parent_allow_writes" => policy["allow_writes"],
            "matched_rule" => "not_within_parent_allow",
            "next_actions" => ["narrow_child_write_set", "request_policy_expansion"]
          })}}
      end
    end)
  end

  defp syntactically_contains?("**/*", _child), do: true
  defp syntactically_contains?(parent, child) when parent == child, do: true

  defp syntactically_contains?("**/" <> rest, child) do
    cond do
      String.ends_with?(rest, "/**") ->
        dir = String.trim_trailing(rest, "/**")
        child_rule_within_any_segment_directory?(dir, child)

      String.ends_with?(rest, "*") ->
        prefix = String.trim_trailing(rest, "*")
        child_rule_within_any_segment_prefix?(prefix, child)

      true ->
        child_rule_within_any_segment_leaf?(rest, child)
    end
  end

  defp syntactically_contains?(parent, child) do
    cond do
      String.ends_with?(parent, "/**") ->
        prefix = String.trim_trailing(parent, "/**")
        child == prefix or String.starts_with?(child, prefix <> "/")

      true ->
        false
    end
  end

  defp child_rule_within_any_segment_directory?(dir, child) do
    cond do
      String.ends_with?(child, "/**") ->
        child
        |> String.trim_trailing("/**")
        |> Path.split()
        |> Enum.member?(dir)

      true ->
        dir in Path.split(child)
    end
  end

  defp child_rule_within_any_segment_prefix?(prefix, child) do
    cond do
      String.starts_with?(child, "**/") ->
        child
        |> String.trim_leading("**/")
        |> String.trim_trailing("*")
        |> String.starts_with?(prefix)

      String.ends_with?(child, "/**") ->
        false

      true ->
        child |> Path.basename() |> String.starts_with?(prefix)
    end
  end

  defp child_rule_within_any_segment_leaf?(leaf, child) do
    cond do
      String.starts_with?(child, "**/") ->
        String.trim_leading(child, "**/") == leaf

      String.ends_with?(child, "/**") ->
        false

      true ->
        Path.basename(child) == leaf
    end
  end

  defp invalid_rule(field, rule, reason) do
    Tool.error(:invalid_args, "bounded write policy has unsupported #{field} rule", %{
      "field" => field,
      "rule" => rule,
      "reason" => reason,
      "next_actions" => ["use_exact_paths_or_trailing_/**_directory_rules"]
    })
  end

  # ── normalization ───────────────────────────────────────────────────────

  defp read_policy_file(path) do
    case File.read(path) do
      {:ok, raw} ->
        {:ok, raw}

      {:error, reason} ->
        {:error,
         Tool.error(:invalid_args, "could not read write policy file", %{
           "path" => path,
           "reason" => inspect(reason),
           "next_actions" => ["check_write_policy_path"]
         })}
    end
  end

  defp decode_policy(raw, path) do
    case Jason.decode(raw) do
      {:ok, map} when is_map(map) ->
        {:ok, map}

      {:ok, other} ->
        {:error,
         Tool.error(:invalid_args, "write policy must decode to a JSON object", %{
           "path" => path,
           "observed" => inspect(other)
         })}

      {:error, error} ->
        {:error,
         Tool.error(:invalid_args, "write policy file is not valid JSON", %{
           "path" => path,
           "decode_error" => Exception.message(error),
           "next_actions" => ["provide_exactly_one_policy_json_object"]
         })}
    end
  end

  defp reject_unknown_keys(policy) do
    case Map.keys(policy) -- @allowed_keys do
      [] ->
        :ok

      unknown ->
        {:error,
         Tool.error(:invalid_args, "bounded write policy contains unsupported fields", %{
           "unsupported_fields" => unknown,
           "supported_fields" => @allowed_keys
         })}
    end
  end

  defp require_version(%{"version" => @version}), do: :ok

  defp require_version(%{"version" => version}) do
    {:error,
     Tool.error(:invalid_args, "bounded write policy version is unsupported", %{
       "observed" => version,
       "supported" => [@version]
     })}
  end

  defp require_version(_policy),
    do: {:error, Tool.error(:invalid_args, "bounded write policy requires version 1", %{})}

  defp normalize_metadata(metadata) when is_map(metadata), do: {:ok, stringify(metadata)}

  defp normalize_metadata(_metadata),
    do: {:error, Tool.error(:invalid_args, "write_policy.metadata must be an object", %{})}

  defp normalize_rule_list(policy, field, opts) do
    value = Map.get(policy, field, [])

    cond do
      Keyword.get(opts, :required?) and not Map.has_key?(policy, field) ->
        {:error, Tool.error(:invalid_args, "bounded write policy requires #{field}", %{})}

      is_list(value) ->
        rules = value |> Enum.map(&normalize_rule/1)

        cond do
          length(rules) > @max_rules ->
            {:error,
             Tool.error(:invalid_args, "bounded write policy has too many #{field} rules", %{
               "max_rules" => @max_rules
             })}

          true ->
            with :ok <- validate_path_rules(rules, field), do: {:ok, rules}
        end

      true ->
        {:error, Tool.error(:invalid_args, "bounded write policy #{field} must be a list", %{})}
    end
  end

  defp restore_rule_list(policy, field) do
    case Map.fetch(policy, field) do
      {:ok, value} when is_list(value) ->
        rules = Enum.map(value, &normalize_rule/1)

        with :ok <- validate_path_rules(rules, field), do: {:ok, rules}

      {:ok, _value} ->
        {:error, Tool.error(:invalid_args, "bounded write policy #{field} must be a list", %{})}

      :error ->
        {:error,
         Tool.error(:invalid_args, "bounded write policy metadata requires #{field}", %{})}
    end
  end

  defp require_metadata_string(policy, field) do
    case Map.get(policy, field) do
      value when is_binary(value) and value != "" ->
        {:ok, value}

      _value ->
        {:error,
         Tool.error(:invalid_args, "bounded write policy metadata requires #{field}", %{})}
    end
  end

  # legacy validate_bash/1 was replaced by normalize_bash/1.

  defp validate_bash(value) do
    {:error,
     Tool.error(:invalid_args, "bounded write policy v1 requires bash disabled", %{
       "observed" => value,
       "accepted_values" => ["disabled"]
     })}
  end

  defp bounded_safe_command?(command) when is_binary(command) do
    trimmed = String.trim(command)
    tokens = String.split(trimmed, ~r/\s+/, trim: true)

    with [first | rest] <- tokens,
         true <- first in @safe_bash_commands,
         false <- Enum.any?(@shell_metachars, &String.contains?(trimmed, &1)),
         false <- Enum.any?(rest, &parent_directory_token?/1) do
      true
    else
      _ -> false
    end
  end

  defp bounded_safe_command?(_command), do: false

  defp parent_directory_token?(token) when is_binary(token) do
    token
    |> String.replace(~r/['"]/, "")
    |> String.split("/", trim: false)
    |> Enum.any?(&(&1 == ".."))
  end

  defp parent_directory_token?(_token), do: false

  defp active_policy_rule(opts) do
    case {Keyword.get(opts, :workspace), Keyword.get(opts, :policy_file)} do
      {workspace, path} when is_binary(workspace) and is_binary(path) ->
        case canonical_relative(workspace, path) do
          {:ok, rel} -> {:ok, rel}
          {:error, _error} -> {:ok, nil}
        end

      _ ->
        {:ok, nil}
    end
  end

  defp confine_policy_path(root, path) do
    case Workspace.confine(root, path) do
      {:ok, abs} ->
        {:ok, abs}

      {:error, _error} ->
        {:error,
         Tool.error(:write_policy_denied, "write denied by bounded write policy", %{
           "requested_path" => path,
           "matched_rule" => "path_outside_workspace",
           "normalized_path" => nil,
           "next_actions" => ["write_within_workspace", "request_policy_expansion"]
         })}
    end
  end

  defp reject_symlink_components(root, abs) do
    rel = Path.relative_to(abs, root)

    if rel == "." do
      :ok
    else
      rel
      |> Path.split()
      |> Enum.reduce_while({:ok, root}, fn component, {:ok, current} ->
        next = Path.join(current, component)

        case File.lstat(next) do
          {:ok, %File.Stat{type: :symlink}} ->
            {:halt,
             {:error,
              Tool.error(:write_policy_denied, "write denied by bounded write policy", %{
                "matched_rule" => "symlink_path_component",
                "normalized_path" => Path.relative_to(next, root),
                "next_actions" => ["write_to_real_workspace_paths", "request_policy_expansion"]
              })}}

          {:ok, _stat} ->
            {:cont, {:ok, next}}

          {:error, :enoent} ->
            {:halt, :ok}

          {:error, reason} ->
            {:halt,
             {:error,
              Tool.error(:write_policy_denied, "write denied by bounded write policy", %{
                "matched_rule" => "path_not_inspectable",
                "normalized_path" => Path.relative_to(next, root),
                "reason" => inspect(reason),
                "next_actions" => ["check_workspace_path", "retry_after_fixing_path"]
              })}}
        end
      end)
      |> case do
        {:ok, _current} -> :ok
        :ok -> :ok
        {:error, _} = error -> error
      end
    end
  end

  defp stringify(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), stringify(value)} end)

  defp stringify(list) when is_list(list), do: Enum.map(list, &stringify/1)
  defp stringify(value), do: value

  defp policy_hash(policy) do
    durable = %{
      "version" => policy["version"],
      "id" => policy["id"],
      "allow_writes" => policy["allow_writes"],
      "deny_writes" => policy["deny_writes"],
      "bash" => policy["bash"]
    }

    "sha256:" <> sha256(canonical_json(durable))
  end

  defp sha256(data), do: :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)

  defp canonical_json(value) when is_map(value) do
    value
    |> Enum.sort_by(fn {key, _value} -> to_string(key) end)
    |> Enum.map_join(",", fn {key, value} ->
      Jason.encode!(to_string(key)) <> ":" <> canonical_json(value)
    end)
    |> then(&("{" <> &1 <> "}"))
  end

  defp canonical_json(value) when is_list(value) do
    value
    |> Enum.map_join(",", &canonical_json/1)
    |> then(&("[" <> &1 <> "]"))
  end

  defp canonical_json(value), do: Jason.encode!(value)
end
