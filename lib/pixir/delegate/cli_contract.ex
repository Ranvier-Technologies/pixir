defmodule Pixir.Delegate.CLIContract do
  @moduledoc """
  Delegate CLI I/O Contract v1.

  This module owns the machine-facing contract for `pixir delegate`. It is intentionally
  small and testable: parse CLI flags, read a JSON spec, validate the contract, and emit
  a stable dry-run result, attached runtime result, or structured error. Runtime
  execution is delegated to `Pixir.Delegate.Runner` after the same parser accepts the
  request.

  The scaling rule is part of the contract: `delegate` should enter Pixir once and let
  BEAM coordinate fanout. Caller-side polling loops and process-per-child shell fanout
  are explicitly outside this surface.

  Task object attachments are operator-supplied file paths that become ADR 0021
  Session Resources in child Turns; the envelope records counts for dry-run planning
  but never echoes attachment contents or paths.

  ## TODO(delegate-service-v1)

  The `start`, `status`, `attach`, and `cancel` subcommands attempt daemon/IPC Delegate
  service work when a manual workspace daemon is reachable. `start` requires that
  resident owner so returned running work survives the short-lived CLI process; status,
  attach, and cancel can fall back to durable Delegate snapshots. `attach` is
  snapshot-first, and `attach --progress=stderr-jsonl --wait-horizon-ms N` requests a
  daemon/owner follow stream rather than a caller-side polling loop. Keep the CLI shape
  agent-useful:

    * `--json` responses should always expose `delegate_id`, parent `session_id`,
      diagnostics commands, and host-boundary metadata;
    * `attach --progress=stderr-jsonl` should emit bounded live/snapshot progress frames
      to stderr while stdout remains exactly one final JSON envelope;
    * long-running snapshots should distinguish accepted/running/incomplete from
      terminal success/failure;
    * `pixir delegate help` should become a supported alias for the delegate section of
      `pixir help`;
    * `command_ok` means the Delegate command itself was accepted and rendered a
      structured response; `work_complete` reports whether delegated work reached a
      clean terminal success, so consumers must not collapse them into one boolean;
    * service mode should still start exactly one Pixir entrypoint and let OTP own
      Subagent/Workflow fanout.
  """

  alias Pixir.Agents
  alias Pixir.Delegate.{Async, DaemonClient, DaemonCommand, Evidence, Progress, Runner}
  alias Pixir.Permissions.WritePolicy
  alias Pixir.Provider.OutputTruncationSummary

  @contract_version 1
  # Revision 5: additive bounded Provider-output truncation evidence (#268).
  # Revision 4: additive virtual-overlay child artifact/apply projection and
  # dry-run bounded-overlay planning evidence (#284).
  # Revision 3: additive dry-run children[].attachment_count (#250).
  # Revision 2: additive children[].index + children_order envelope keys
  # (#227). The pixir.delegate.envelope.v1 family name is reserved for
  # breaking shape changes; additive keys bump this revision instead.
  @envelope_schema_version 5
  @max_spec_bytes 1_000_000
  @supported_strategies ~w(subagents workflow)
  @supported_modes [nil, "read_only", "bounded_write"]
  @incomplete_terminal_statuses ~w(partial timed_out failed cancelled)
  # TODO(delegate-service-v1): `start` routes through a manual daemon/IPC owner when
  # reachable; status/attach/cancel can use durable fallback. `attach` stays
  # snapshot-first, while `--progress=stderr-jsonl --wait-horizon-ms N` requests daemon
  # follow streaming from a real Pixir-owned process instead of caller-side polling.
  @reserved_subcommands ~w(start status attach cancel daemon)
  @supported_progress_modes [nil, "stderr-jsonl"]
  # Derived from actual spec reads in cli_contract.ex, runner.ex, and
  # workflows.ex - every key here is consumed somewhere. Adding a key that
  # nothing reads would reintroduce the silent-ignore #223 removes.
  @known_spec_keys ~w(
    contract_version strategy task tasks subagents agent mode write_policy transport workspace
    workflow limits timeout_ms steps id name max_concurrency template_id template template_args
    skill
  )
  @known_subagents_keys ~w(
    role agent count max_threads max_depth timeout_ms transport workspace_mode model
    reasoning_effort web_search read_set limits
  )
  @virtual_overlay_limit_keys Pixir.VirtualOverlay.limit_keys()
  @valid_reasoning_efforts Pixir.Config.valid_reasoning_efforts()
  @web_search_config_fields ~w(
    enabled
    include_sources
    type
    search_context_size
    filters
    user_location
    external_web_access
    return_token_budget
    search_content_types
    image_settings
  )

  @type rendered :: %{
          required(:exit_code) => non_neg_integer(),
          required(:json?) => boolean(),
          required(:payload) => map(),
          required(:text) => String.t(),
          optional(:after_render) => (-> :ok)
        }
  @type result :: {:ok, rendered()} | {:error, rendered()}

  @doc "Parse and execute Delegate CLI Contract v1 dry-run or attached runtime behavior."
  @spec run([String.t()], keyword()) :: result()
  def run(argv, opts \\ []) when is_list(argv) do
    case argv do
      [subcommand | rest] when subcommand in @reserved_subcommands ->
        run_subcommand(subcommand, rest, opts)

      _ ->
        run_attached(argv, opts)
    end
  end

  defp run_attached(argv, opts) do
    workspace = Keyword.get(opts, :workspace, File.cwd!())
    read_stdin = Keyword.get(opts, :read_stdin, fn -> IO.read(:stdio, :eof) end)
    runner = Keyword.get(opts, :runner, Pixir.Delegate.Runner)
    runtime_opts = Keyword.get(opts, :runtime_opts, [])

    case parse_args(argv) do
      {:ok, request} ->
        request = Map.put(request, :workspace, workspace)

        case load_and_validate_spec(request, read_stdin, runtime_opts) do
          {:ok, spec, spec_meta} ->
            if request.dry_run? do
              dry_run_result(request, spec, spec_meta)
              |> maybe_put_dry_run_counts(spec)
            else
              runtime_result(runner, request, spec, spec_meta, runtime_opts)
            end

          {:error, error} ->
            error_result(error, request.json?)
        end

      {:error, error, json?} ->
        error_result(error, json?)
    end
  end

  defp run_subcommand(subcommand, rest, opts) do
    workspace = Keyword.get(opts, :workspace, File.cwd!())
    read_stdin = Keyword.get(opts, :read_stdin, fn -> IO.read(:stdio, :eof) end)
    async = Keyword.get(opts, :async, Async)
    daemon_client = Keyword.get(opts, :daemon_client, DaemonClient)
    daemon_command = Keyword.get(opts, :daemon_command, DaemonCommand)
    runtime_opts = Keyword.get(opts, :runtime_opts, [])

    async_opts =
      opts
      |> Keyword.get(:async_opts, [])
      |> Keyword.put(:workspace, workspace)
      |> Keyword.put(:runtime_opts, runtime_opts)

    case parse_subcommand_argv(subcommand, rest) do
      {:ok, request} ->
        request = Map.put(request, :workspace, workspace)

        dispatch_parsed_subcommand(
          subcommand,
          request,
          async,
          async_opts,
          read_stdin,
          daemon_client,
          daemon_command
        )

      {:error, error, json?} ->
        error_result(error, json?)
    end
  end

  @doc "Return the supported Delegate contract version."
  @spec contract_version() :: pos_integer()
  def contract_version, do: @contract_version

  defp maybe_put_dry_run_counts(result, spec) do
    result
    |> maybe_put_dry_run_attachment_counts(spec)
    |> maybe_put_dry_run_virtual_overlay(spec)
    |> maybe_put_dry_run_verify_command_count(spec)
  end

  defp maybe_put_dry_run_virtual_overlay(
         {:ok, %{payload: %{"children" => children} = payload} = rendered},
         %{"subagents" => %{"workspace_mode" => "virtual_overlay"} = subagents}
       )
       when is_list(children) do
    read_set_count = subagents |> Map.fetch!("read_set") |> length()

    children =
      Enum.map(children, fn child ->
        child
        |> Map.put("workspace_mode", "virtual_overlay")
        |> Map.put("read_set_count", read_set_count)
        |> put_if_present("limits", Map.get(subagents, "limits"))
      end)

    {:ok, %{rendered | payload: Map.put(payload, "children", children)}}
  end

  defp maybe_put_dry_run_virtual_overlay(result, _spec), do: result

  defp maybe_put_dry_run_verify_command_count(
         {:ok, %{payload: payload} = rendered},
         %{"mode" => "bounded_write"} = spec
       ) do
    count = write_policy_verify_command_count(spec)

    payload =
      payload
      |> Map.put("verify_command_count", count)
      |> maybe_put_child_verify_command_counts(count)

    {:ok, %{rendered | payload: payload}}
  end

  defp maybe_put_dry_run_verify_command_count(result, _spec), do: result

  defp maybe_put_child_verify_command_counts(%{"children" => children} = payload, count)
       when is_list(children) do
    children = Enum.map(children, &Map.put(&1, "verify_command_count", count))
    Map.put(payload, "children", children)
  end

  defp maybe_put_child_verify_command_counts(payload, _count), do: payload

  defp write_policy_verify_command_count(%{
         "write_policy" => %{"bash" => %{"verify" => commands}}
       })
       when is_list(commands),
       do: length(commands)

  defp write_policy_verify_command_count(_spec), do: 0

  defp maybe_put_dry_run_attachment_counts(
         {:ok, %{payload: %{"children" => children} = payload} = rendered},
         spec
       )
       when is_list(children) do
    counts = task_attachment_counts(spec)

    children =
      children
      |> Enum.with_index()
      |> Enum.map(fn {child, index} ->
        case Enum.at(counts, index) do
          nil -> child
          count -> Map.put(child, "attachment_count", count)
        end
      end)

    {:ok, %{rendered | payload: Map.put(payload, "children", children)}}
  end

  defp maybe_put_dry_run_attachment_counts(result, _spec), do: result

  defp task_attachment_counts(%{"tasks" => tasks}) when is_list(tasks) do
    Enum.map(tasks, fn
      %{"attachments" => attachments} when is_list(attachments) -> length(attachments)
      _entry -> 0
    end)
  end

  defp task_attachment_counts(%{"task" => task} = spec) when is_binary(task) do
    count = get_in(spec, ["subagents", "count"]) || 1
    List.duplicate(0, count)
  end

  defp task_attachment_counts(_spec), do: []

  defp parse_args(argv) do
    parse_args(argv, %{
      dry_run?: false,
      fail_on_incomplete?: false,
      json?: "--json" in argv,
      output_dir: nil,
      progress: nil,
      quiet?: false,
      spec_source: nil,
      timeout_ms: nil,
      contract_version: @contract_version
    })
  end

  defp parse_args([], acc) do
    cond do
      is_nil(acc.spec_source) ->
        {:error,
         invalid_args("delegate requires --spec PATH or --spec -", %{
           "missing" => ["spec"],
           "usage" => usage()
         }), acc.json?}

      acc.contract_version != @contract_version ->
        {:error, unsupported_contract_version(acc.contract_version, %{"source" => "cli_flag"}),
         acc.json?}

      acc.progress not in @supported_progress_modes ->
        {:error,
         invalid_args("--progress must be stderr-jsonl", %{
           "observed" => acc.progress,
           "accepted_values" => ["stderr-jsonl"]
         }), acc.json?}

      not is_nil(acc.progress) ->
        {:error, unsupported_attached_progress(acc.progress), acc.json?}

      true ->
        {:ok, acc}
    end
  end

  defp parse_args(["--spec", value | rest], acc) when is_binary(value) and value != "",
    do: parse_args(rest, %{acc | spec_source: value})

  defp parse_args(["--spec" | _rest], acc),
    do: {:error, invalid_args("--spec requires a path or -", %{"usage" => usage()}), acc.json?}

  defp parse_args(["--dry-run" | rest], acc), do: parse_args(rest, %{acc | dry_run?: true})
  defp parse_args(["--json" | rest], acc), do: parse_args(rest, %{acc | json?: true})
  defp parse_args(["--quiet" | rest], acc), do: parse_args(rest, %{acc | quiet?: true})

  defp parse_args(["--fail-on-incomplete" | rest], acc),
    do: parse_args(rest, %{acc | fail_on_incomplete?: true})

  defp parse_args(["--output-dir", value | rest], acc) when is_binary(value) and value != "",
    do: parse_args(rest, %{acc | output_dir: value})

  defp parse_args(["--output-dir" | _rest], acc),
    do: {:error, invalid_args("--output-dir requires a path", %{"usage" => usage()}), acc.json?}

  defp parse_args(["--timeout-ms", value | rest], acc) do
    case parse_positive_integer(value) do
      {:ok, timeout_ms} ->
        parse_args(rest, %{acc | timeout_ms: timeout_ms})

      :error ->
        {:error, invalid_args("--timeout-ms must be a positive integer", %{"observed" => value}),
         acc.json?}
    end
  end

  defp parse_args(["--timeout-ms" | _rest], acc),
    do:
      {:error, invalid_args("--timeout-ms requires a positive integer", %{"usage" => usage()}),
       acc.json?}

  defp parse_args(["--contract-version", value | rest], acc) do
    case parse_positive_integer(value) do
      {:ok, version} ->
        parse_args(rest, %{acc | contract_version: version})

      :error ->
        {:error, invalid_args("--contract-version must be a positive integer", %{}), acc.json?}
    end
  end

  defp parse_args(["--contract-version" | _rest], acc),
    do:
      {:error,
       invalid_args("--contract-version requires a positive integer", %{"usage" => usage()}),
       acc.json?}

  defp parse_args(["--progress=stderr-jsonl" | rest], acc),
    do: parse_args(rest, %{acc | progress: "stderr-jsonl"})

  defp parse_args(["--progress", "stderr-jsonl" | rest], acc),
    do: parse_args(rest, %{acc | progress: "stderr-jsonl"})

  defp parse_args(["--progress", value | _rest], acc),
    do:
      {:error,
       invalid_args("--progress must be stderr-jsonl", %{
         "observed" => value,
         "accepted_values" => ["stderr-jsonl"]
       }), acc.json?}

  defp parse_args(["--progress" | _rest], acc),
    do: {:error, invalid_args("--progress requires a value", %{"usage" => usage()}), acc.json?}

  defp parse_args([subcommand | _rest], acc) when subcommand in @reserved_subcommands,
    do: {:error, unsupported_subcommand(subcommand), acc.json?}

  defp parse_args([arg | _rest], acc) when is_binary(arg) do
    if String.starts_with?(arg, "-") do
      {:error, invalid_args("unsupported delegate option", %{}), acc.json?}
    else
      {:error, invalid_args("unexpected delegate argument", %{"argument" => arg}), acc.json?}
    end
  end

  # decode_spec/1 guarantees a JSON object, so a map is the only input shape.
  defp validate_strict_spec_keys(%{} = spec, workspace, opts) do
    with :ok <- reject_unknown_keys(spec, @known_spec_keys, [], %{}),
         :ok <- validate_subagents_shape_for_strict_keys(spec),
         :ok <- validate_task_entries_for_strict_keys(spec),
         :ok <- validate_virtual_overlay_contract(spec),
         :ok <- validate_subagent_model(spec),
         :ok <- validate_subagent_reasoning_effort(spec),
         :ok <- validate_subagent_web_search(spec),
         :ok <- validate_bounded_write_read_only_role(spec, workspace, opts) do
      :ok
    end
  end

  defp validate_virtual_overlay_contract(%{"strategy" => "subagents"} = spec) do
    subagents = Map.get(spec, "subagents", %{})
    workspace_mode = Map.get(subagents, "workspace_mode", "shared")

    with :ok <- validate_subagent_workspace_mode(workspace_mode),
         :ok <- validate_virtual_only_fields(subagents, workspace_mode),
         :ok <- validate_virtual_overlay_mode(spec, workspace_mode),
         :ok <- validate_virtual_overlay_read_set(subagents, workspace_mode),
         :ok <- validate_virtual_overlay_limits(subagents, workspace_mode),
         :ok <- validate_virtual_overlay_attachments(spec, workspace_mode) do
      :ok
    end
  end

  defp validate_virtual_overlay_contract(%{"subagents" => subagents})
       when is_map(subagents) do
    case Enum.find(["read_set", "limits"], &Map.has_key?(subagents, &1)) do
      nil ->
        :ok

      field ->
        {:error,
         invalid_spec(
           "subagents.#{field} is only valid for virtual_overlay subagent strategy specs",
           %{
             "next_actions" => ["remove_virtual_overlay_only_field", "use_subagents_strategy"]
           }
           |> Map.merge(object_location_details(["subagents", field]))
         )}
    end
  end

  defp validate_virtual_overlay_contract(_spec), do: :ok

  defp validate_subagent_workspace_mode(mode)
       when mode in ["shared", "isolated", "virtual_overlay"],
       do: :ok

  defp validate_subagent_workspace_mode(mode) do
    {:error,
     invalid_spec(
       "subagents.workspace_mode is unsupported",
       %{
         "observed" => mode,
         "accepted_values" => ["shared", "isolated", "virtual_overlay"],
         "next_actions" => ["set_workspace_mode_to_shared_isolated_or_virtual_overlay"]
       }
       |> Map.merge(object_location_details(["subagents", "workspace_mode"]))
     )}
  end

  defp validate_virtual_only_fields(_subagents, "virtual_overlay"), do: :ok

  defp validate_virtual_only_fields(subagents, _workspace_mode) do
    case Enum.find(["read_set", "limits"], &Map.has_key?(subagents, &1)) do
      nil ->
        :ok

      field ->
        {:error,
         invalid_spec(
           "subagents.#{field} is only valid for virtual_overlay",
           %{
             "workspace_mode" => Map.get(subagents, "workspace_mode", "shared"),
             "next_actions" => [
               "set_workspace_mode_to_virtual_overlay",
               "remove_virtual_overlay_only_field"
             ]
           }
           |> Map.merge(object_location_details(["subagents", field]))
         )}
    end
  end

  defp validate_virtual_overlay_mode(spec, "virtual_overlay") do
    cond do
      Map.has_key?(spec, "write_policy") ->
        {:error,
         invalid_spec(
           "virtual_overlay delegate specs cannot include write_policy",
           %{
             "workspace_mode" => "virtual_overlay",
             "next_actions" => ["remove_write_policy", "apply_the_artifact_explicitly_later"]
           }
           |> Map.merge(object_location_details(["write_policy"]))
         )}

      Map.get(spec, "mode") not in [nil, "read_only"] ->
        {:error,
         invalid_spec(
           "virtual_overlay delegate specs must be read_only",
           %{
             "observed" => Map.get(spec, "mode"),
             "accepted_values" => ["read_only"],
             "next_actions" => ["set_mode_to_read_only", "remove_mode"]
           }
           |> Map.merge(object_location_details(["mode"]))
         )}

      true ->
        :ok
    end
  end

  defp validate_virtual_overlay_mode(_spec, _workspace_mode), do: :ok

  defp validate_virtual_overlay_read_set(subagents, "virtual_overlay") do
    read_set = Map.get(subagents, "read_set")

    case Pixir.VirtualOverlay.validate_read_set(read_set) do
      :ok ->
        :ok

      {:error, %{kind: kind, index: index, reason: reason}}
      when kind in [:invalid_read_set_entry, :unbounded_read_set] ->
        {:error,
         invalid_spec(
           delegate_read_set_message(kind),
           %{
             "observed" => Enum.at(read_set, index),
             "reason" => reason,
             "matched_rule" => reason,
             "next_actions" => ["replace_read_set_entry_with_a_bounded_path"]
           }
           |> Map.merge(read_set_location_details(index))
         )}

      {:error, _reason} ->
        {:error,
         invalid_spec(
           "virtual_overlay delegate specs require a non-empty subagents.read_set",
           %{
             "observed" => read_set,
             "missing" => ["subagents.read_set"],
             "next_actions" => ["add_a_non_empty_bounded_read_set"]
           }
           |> Map.merge(object_location_details(["subagents", "read_set"]))
         )}
    end
  end

  defp validate_virtual_overlay_read_set(_subagents, _workspace_mode), do: :ok

  defp delegate_read_set_message(:unbounded_read_set),
    do: "subagents.read_set cannot import an unbounded workspace"

  defp delegate_read_set_message(_kind), do: "subagents.read_set entry is invalid"

  defp validate_virtual_overlay_limits(subagents, "virtual_overlay") do
    case Map.fetch(subagents, "limits") do
      :error ->
        :ok

      {:ok, limits} when is_map(limits) ->
        limits
        |> Enum.sort_by(fn {key, _value} -> to_string(key) end)
        |> Enum.reduce_while(:ok, fn {key, value}, :ok ->
          cond do
            key not in @virtual_overlay_limit_keys ->
              {:halt,
               {:error,
                invalid_spec(
                  "subagents.limits contains an unknown key",
                  %{
                    "unknown_key" => key,
                    "accepted_keys" => @virtual_overlay_limit_keys,
                    "next_actions" => ["remove_unknown_limit", "check_virtual_overlay_limits"]
                  }
                  |> Map.merge(object_location_details(["subagents", "limits", key]))
                )}}

            not is_integer(value) or value < 0 ->
              {:halt,
               {:error,
                invalid_spec(
                  "virtual_overlay limits must be non-negative integers",
                  %{
                    "observed" => value,
                    "next_actions" => ["set_limit_to_a_non_negative_integer"]
                  }
                  |> Map.merge(object_location_details(["subagents", "limits", key]))
                )}}

            true ->
              {:cont, :ok}
          end
        end)

      {:ok, value} ->
        {:error,
         invalid_spec(
           "subagents.limits must be an object",
           %{
             "observed" => value,
             "next_actions" => ["set_limits_to_an_object_or_remove_it"]
           }
           |> Map.merge(object_location_details(["subagents", "limits"]))
         )}
    end
  end

  defp validate_virtual_overlay_limits(_subagents, _workspace_mode), do: :ok

  defp validate_virtual_overlay_attachments(spec, "virtual_overlay") do
    case Runner.virtual_overlay_attachment_index(spec) do
      nil ->
        :ok

      index ->
        {:error,
         invalid_spec(
           "virtual_overlay delegate tasks cannot include attachments",
           %{
             "next_actions" => ["remove_attachments", "add_required_files_to_read_set"]
           }
           |> Map.merge(task_attachment_location_details(index))
         )}
    end
  end

  defp validate_virtual_overlay_attachments(_spec, _workspace_mode), do: :ok

  defp validate_bounded_write_read_only_role(
         %{"mode" => "bounded_write", "strategy" => "workflow"},
         _workspace,
         _opts
       ),
       do: :ok

  defp validate_bounded_write_read_only_role(
         %{"mode" => "bounded_write"} = spec,
         workspace,
         opts
       ) do
    role = effective_subagent_role(spec)
    workspace = effective_spec_workspace(spec, workspace)
    agents_opts = Keyword.get(opts, :agents_opts, [])

    case Agents.get(role, workspace, agents_opts) do
      # read_only_mode?/1 normalizes the config spellings ("read-only",
      # "read_only", :read_only) — a raw-spelled role must not bypass the gate.
      {:ok, %{sandbox_mode: mode}} ->
        if read_only_mode?(mode) do
          {:error,
           invalid_spec(
             "bounded_write conflicts with the read-only role #{role}",
             %{
               "role" => role,
               "role_sandbox_mode" => mode,
               "mode" => "bounded_write",
               "next_actions" => ["use_a_write_capable_role", "set_mode_to_read_only"]
             }
             |> Map.merge(object_location_details(["subagents", "role"]))
           )}
        else
          :ok
        end

      {:ok, _agent} ->
        :ok

      {:error, _error} ->
        :ok
    end
  end

  defp validate_bounded_write_read_only_role(_spec, _workspace, _opts), do: :ok

  defp effective_subagent_role(spec) do
    get_in(spec, ["subagents", "role"]) ||
      get_in(spec, ["subagents", "agent"]) ||
      Map.get(spec, "agent") ||
      "default"
  end

  # Agent discovery must never be laxer than the runner's confinement
  # (runner normalize_workspace rejects escapes): an unconfined spec workspace
  # falls back to the caller workspace for the lookup, and the runner keeps
  # owning the honest rejection of the escape itself.
  defp effective_spec_workspace(%{"workspace" => spec_workspace}, caller_workspace)
       when is_binary(spec_workspace) and is_binary(caller_workspace) do
    case Pixir.Tools.Workspace.confine(caller_workspace, spec_workspace) do
      {:ok, confined} -> confined
      {:error, _outside} -> Path.expand(caller_workspace)
    end
  end

  defp effective_spec_workspace(_spec, caller_workspace), do: caller_workspace

  defp validate_subagents_shape_for_strict_keys(%{"subagents" => %{} = subagents}) do
    reject_unknown_keys(subagents, @known_subagents_keys, ["subagents"], %{
      "max_thread" => "max_threads",
      "thread_count" => "max_threads",
      "roles" => "role"
    })
  end

  # A present but non-object subagents value would crash later get_in/2
  # access; fail it closed here with the structured error instead.
  defp validate_subagents_shape_for_strict_keys(%{"subagents" => subagents}) do
    {:error,
     invalid_spec(
       "delegate spec subagents must be an object",
       %{
         "observed_type" => json_type(subagents),
         "next_actions" => ["set_subagents_to_an_object"]
       }
       |> Map.merge(object_location_details(["subagents"]))
     )}
  end

  defp validate_subagents_shape_for_strict_keys(_spec), do: :ok

  defp validate_subagent_web_search(%{"subagents" => %{"web_search" => true}}), do: :ok

  defp validate_subagent_web_search(%{"subagents" => %{"web_search" => %{} = config}}) do
    known = MapSet.new(@web_search_config_fields)

    case Enum.find(Map.keys(config), &(not MapSet.member?(known, &1))) do
      nil ->
        :ok

      key ->
        {:error,
         invalid_spec(
           "delegate spec subagents.web_search contains unsupported field",
           %{
             "unknown_key" => key,
             "accepted_keys" => @web_search_config_fields,
             "accepted_values" => [true, "object"],
             "next_actions" => ["remove_unknown_field", "check_hosted_web_search_config"]
           }
           |> Map.merge(object_location_details(["subagents", "web_search", key]))
         )}
    end
  end

  defp validate_subagent_web_search(%{"subagents" => %{"web_search" => other}}) do
    {:error,
     invalid_spec(
       "delegate spec subagents.web_search must be true or an object",
       %{
         "observed_type" => json_type(other),
         "accepted_values" => [true, "object"],
         "next_actions" => [
           "set_subagents_web_search_to_true_or_object",
           "remove_subagents_web_search"
         ]
       }
       |> Map.merge(object_location_details(["subagents", "web_search"]))
     )}
  end

  defp validate_subagent_web_search(_spec), do: :ok

  defp validate_task_entries_for_strict_keys(%{"tasks" => tasks}) when is_list(tasks) do
    tasks
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {entry, index}, :ok ->
      case validate_task_entry_for_strict_keys(entry, index) do
        :ok -> {:cont, :ok}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp validate_task_entries_for_strict_keys(_spec), do: :ok

  defp validate_task_entry_for_strict_keys(entry, _index) when is_binary(entry), do: :ok

  defp validate_task_entry_for_strict_keys(%{} = entry, index) do
    allowed = ["task", "attachments"]

    with :ok <- reject_unknown_task_entry_keys(entry, index, allowed),
         :ok <- validate_task_entry_text(entry, index),
         :ok <- validate_task_entry_attachments(entry, index) do
      :ok
    end
  end

  defp validate_task_entry_for_strict_keys(_entry, _index), do: :ok

  defp reject_unknown_task_entry_keys(entry, index, allowed) do
    known = MapSet.new(allowed)

    case Enum.find(Map.keys(entry), &(not MapSet.member?(known, &1))) do
      nil ->
        :ok

      key ->
        {:error,
         invalid_spec(
           "delegate tasks entries may only include task and attachments",
           %{
             "unknown_key" => key,
             "accepted_keys" => allowed,
             "next_actions" => ["remove_unknown_field", "check_delegate_spec_contract"]
           }
           |> Map.merge(task_entry_location_details(index))
         )}
    end
  end

  defp validate_task_entry_text(%{"task" => task}, index) when is_binary(task) do
    if String.trim(task) == "" do
      {:error,
       invalid_spec(
         "subagents.tasks entries must be non-empty task strings or task objects",
         %{"next_actions" => ["fix_subagents_tasks_entries"]}
         |> Map.merge(task_entry_location_details(index))
       )}
    else
      :ok
    end
  end

  defp validate_task_entry_text(_entry, index) do
    {:error,
     invalid_spec(
       "subagents.tasks entries must be non-empty task strings or task objects",
       %{"next_actions" => ["fix_subagents_tasks_entries"]}
       |> Map.merge(task_entry_location_details(index))
     )}
  end

  defp validate_task_entry_attachments(%{"attachments" => attachments}, index)
       when is_list(attachments) do
    attachments
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {attachment, attachment_index}, :ok ->
      case validate_task_entry_attachment(attachment, index, attachment_index) do
        :ok -> {:cont, :ok}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp validate_task_entry_attachments(%{"attachments" => _attachments}, index) do
    {:error,
     invalid_spec(
       "delegate task attachments must be a list of paths",
       %{"next_actions" => ["set_attachments_to_a_list_of_paths_or_file_uris"]}
       |> Map.merge(task_attachment_location_details(index))
     )}
  end

  defp validate_task_entry_attachments(_entry, _index), do: :ok

  defp validate_task_entry_attachment(attachment, task_index, attachment_index)
       when is_binary(attachment) do
    attachment = String.trim(attachment)

    cond do
      attachment == "" ->
        invalid_task_entry_attachment(task_index, attachment_index)

      String.starts_with?(attachment, "file://") ->
        validate_file_uri_attachment(attachment, task_index, attachment_index)

      true ->
        :ok
    end
  end

  defp validate_task_entry_attachment(_attachment, task_index, attachment_index),
    do: invalid_task_entry_attachment(task_index, attachment_index)

  defp invalid_task_entry_attachment(task_index, attachment_index) do
    {:error,
     invalid_spec(
       "delegate task attachments must be non-empty strings",
       %{
         "attachment_index" => attachment_index,
         "next_actions" => ["replace_attachment_with_a_non_empty_path_or_file_uri"]
       }
       |> Map.merge(task_attachment_location_details(task_index, attachment_index))
     )}
  end

  defp validate_file_uri_attachment(uri, task_index, attachment_index) do
    if Runner.local_file_uri?(uri) do
      :ok
    else
      invalid_file_uri_attachment(task_index, attachment_index)
    end
  end

  defp invalid_file_uri_attachment(task_index, attachment_index) do
    {:error,
     invalid_spec(
       "delegate task file URI is invalid",
       %{
         "attachment_index" => attachment_index,
         "next_actions" => ["replace_attachment_with_a_file_uri_path_or_filesystem_path"]
       }
       |> Map.merge(task_attachment_location_details(task_index, attachment_index))
     )}
  end

  defp read_set_location_details(index) do
    %{
      "field" => "subagents.read_set[#{index + 1}]",
      "json_pointer" => "/subagents/read_set/#{index}",
      "path" => ["subagents", "read_set", index]
    }
  end

  defp task_entry_location_details(index) do
    %{
      "field" => "tasks[#{index + 1}]",
      "json_pointer" => "/tasks/#{index}",
      "path" => ["tasks", index],
      "task_index" => index
    }
  end

  defp task_attachment_location_details(index) do
    %{
      "field" => "tasks[#{index + 1}].attachments",
      "json_pointer" => "/tasks/#{index}/attachments",
      "path" => ["tasks", index, "attachments"],
      "task_index" => index
    }
  end

  defp task_attachment_location_details(task_index, attachment_index) do
    %{
      "field" => "tasks[#{task_index + 1}].attachments[#{attachment_index + 1}]",
      "json_pointer" => "/tasks/#{task_index}/attachments/#{attachment_index}",
      "path" => ["tasks", task_index, "attachments", attachment_index],
      "task_index" => task_index
    }
  end

  defp valid_task_attachments?(attachments) when is_list(attachments),
    do: Enum.all?(attachments, &valid_task_attachment?/1)

  defp valid_task_attachments?(_attachments), do: false

  defp valid_task_attachment?(attachment) when is_binary(attachment) do
    attachment = String.trim(attachment)

    attachment != "" and
      (not String.starts_with?(attachment, "file://") or Runner.local_file_uri?(attachment))
  end

  defp valid_task_attachment?(_attachment), do: false

  defp validate_subagent_model(%{"subagents" => %{"model" => model}}) when is_binary(model),
    do: :ok

  defp validate_subagent_model(%{"subagents" => %{"model" => model}}) do
    {:error,
     invalid_spec(
       "subagents.model must be a string",
       %{
         "observed" => model,
         "next_actions" => ["set_subagents_model_to_a_model_id_string"]
       }
       |> Map.merge(object_location_details(["subagents", "model"]))
     )}
  end

  defp validate_subagent_model(_spec), do: :ok

  defp validate_subagent_reasoning_effort(%{
         "subagents" => %{"reasoning_effort" => effort}
       })
       when effort in @valid_reasoning_efforts,
       do: :ok

  defp validate_subagent_reasoning_effort(%{"subagents" => %{"reasoning_effort" => effort}}) do
    {:error,
     invalid_spec(
       "subagents.reasoning_effort has an unsupported value",
       %{
         "observed" => effort,
         "accepted_values" => @valid_reasoning_efforts,
         "next_actions" => ["set_subagents_reasoning_effort_to_low_medium_high_or_xhigh"]
       }
       |> Map.merge(object_location_details(["subagents", "reasoning_effort"]))
     )}
  end

  defp validate_subagent_reasoning_effort(_spec), do: :ok

  defp reject_unknown_keys(map, known_keys, path, misplaced_hints) do
    known = MapSet.new(known_keys)

    case Enum.find(Map.keys(map), &(not MapSet.member?(known, &1))) do
      nil ->
        :ok

      key ->
        {:error, unknown_spec_key_error(path ++ [key], known_keys, Map.get(misplaced_hints, key))}
    end
  end

  defp unknown_spec_key_error(path, accepted_keys, nil) do
    invalid_spec(
      "delegate spec contains an unknown field",
      %{
        "unknown_key" => List.last(path),
        "accepted_keys" => accepted_keys,
        "next_actions" => ["remove_unknown_field", "check_delegate_spec_contract"]
      }
      |> Map.merge(object_location_details(path))
    )
  end

  # The hint names a sibling key in the SAME object: rename guidance, not
  # relocation (a literal "move" edit would be wrong).
  defp unknown_spec_key_error(path, accepted_keys, did_you_mean) do
    invalid_spec(
      "delegate spec contains an unknown field",
      %{
        "unknown_key" => List.last(path),
        "accepted_keys" => accepted_keys,
        "did_you_mean" => did_you_mean,
        "next_actions" => [
          "rename_field_to_#{did_you_mean}",
          "check_delegate_spec_contract"
        ]
      }
      |> Map.merge(object_location_details(path))
    )
  end

  defp object_location_details(path) do
    %{
      "field" => Enum.join(path, "."),
      "json_pointer" => json_pointer(path),
      "path" => path
    }
  end

  defp parse_subcommand_argv(subcommand, argv) do
    parse_subcommand_args(argv, %{
      command: subcommand,
      dry_run?: false,
      fail_on_incomplete?: false,
      json?: "--json" in argv,
      output_dir: nil,
      progress: nil,
      quiet?: false,
      session_id: nil,
      spec_source: nil,
      timeout_ms: nil,
      wait_horizon_ms: nil,
      daemon_action: nil,
      contract_version: @contract_version
    })
  end

  defp parse_subcommand_args([], acc), do: validate_subcommand_args(acc)

  defp parse_subcommand_args(["--json" | rest], acc),
    do: parse_subcommand_args(rest, %{acc | json?: true})

  defp parse_subcommand_args(["--quiet" | rest], acc),
    do: parse_subcommand_args(rest, %{acc | quiet?: true})

  defp parse_subcommand_args(["--dry-run" | rest], acc),
    do: parse_subcommand_args(rest, %{acc | dry_run?: true})

  defp parse_subcommand_args(["--fail-on-incomplete" | rest], acc),
    do: parse_subcommand_args(rest, %{acc | fail_on_incomplete?: true})

  defp parse_subcommand_args(["--spec", value | rest], acc) when is_binary(value) and value != "",
    do: parse_subcommand_args(rest, %{acc | spec_source: value})

  defp parse_subcommand_args(["--spec" | _rest], acc),
    do: {:error, invalid_args("--spec requires a path or -", %{"usage" => usage()}), acc.json?}

  defp parse_subcommand_args(["--output-dir", value | rest], acc)
       when is_binary(value) and value != "",
       do: parse_subcommand_args(rest, %{acc | output_dir: value})

  defp parse_subcommand_args(["--output-dir" | _rest], acc),
    do: {:error, invalid_args("--output-dir requires a path", %{"usage" => usage()}), acc.json?}

  defp parse_subcommand_args(["--timeout-ms", value | rest], acc) do
    case parse_positive_integer(value) do
      {:ok, timeout_ms} ->
        parse_subcommand_args(rest, %{acc | timeout_ms: timeout_ms})

      :error ->
        {:error, invalid_args("--timeout-ms must be a positive integer", %{"observed" => value}),
         acc.json?}
    end
  end

  defp parse_subcommand_args(["--timeout-ms" | _rest], acc),
    do:
      {:error, invalid_args("--timeout-ms requires a positive integer", %{"usage" => usage()}),
       acc.json?}

  defp parse_subcommand_args(["--wait-horizon-ms", value | rest], acc) do
    case parse_positive_integer(value) do
      {:ok, wait_horizon_ms} ->
        parse_subcommand_args(rest, %{acc | wait_horizon_ms: wait_horizon_ms})

      :error ->
        {:error,
         invalid_args("--wait-horizon-ms must be a positive integer", %{"observed" => value}),
         acc.json?}
    end
  end

  defp parse_subcommand_args(["--wait-horizon-ms" | _rest], acc),
    do:
      {:error,
       invalid_args("--wait-horizon-ms requires a positive integer", %{"usage" => usage()}),
       acc.json?}

  defp parse_subcommand_args(["--foreground" | rest], %{command: "daemon"} = acc),
    do: parse_subcommand_args(rest, put_daemon_action(acc, "foreground"))

  defp parse_subcommand_args(["--status" | rest], %{command: "daemon"} = acc),
    do: parse_subcommand_args(rest, put_daemon_action(acc, "status"))

  defp parse_subcommand_args(["--stop" | rest], %{command: "daemon"} = acc),
    do: parse_subcommand_args(rest, put_daemon_action(acc, "stop"))

  defp parse_subcommand_args(["--contract-version", value | rest], acc) do
    case parse_positive_integer(value) do
      {:ok, version} ->
        parse_subcommand_args(rest, %{acc | contract_version: version})

      :error ->
        {:error, invalid_args("--contract-version must be a positive integer", %{}), acc.json?}
    end
  end

  defp parse_subcommand_args(["--contract-version" | _rest], acc),
    do:
      {:error,
       invalid_args("--contract-version requires a positive integer", %{"usage" => usage()}),
       acc.json?}

  defp parse_subcommand_args(["--progress=stderr-jsonl" | rest], acc),
    do: parse_subcommand_args(rest, %{acc | progress: "stderr-jsonl"})

  defp parse_subcommand_args(["--progress", "stderr-jsonl" | rest], acc),
    do: parse_subcommand_args(rest, %{acc | progress: "stderr-jsonl"})

  defp parse_subcommand_args(["--progress", value | _rest], acc),
    do:
      {:error,
       invalid_args("--progress must be stderr-jsonl", %{
         "observed" => value,
         "accepted_values" => ["stderr-jsonl"]
       }), acc.json?}

  defp parse_subcommand_args(["--progress" | _rest], acc),
    do: {:error, invalid_args("--progress requires a value", %{"usage" => usage()}), acc.json?}

  defp parse_subcommand_args([arg | rest], acc) when is_binary(arg) do
    cond do
      String.starts_with?(arg, "-") ->
        {:error, invalid_args("unsupported delegate option", %{}), acc.json?}

      is_nil(acc.session_id) and acc.command in ["status", "attach", "cancel"] ->
        parse_subcommand_args(rest, %{acc | session_id: arg})

      true ->
        {:error, invalid_args("unexpected delegate argument", %{"argument" => arg}), acc.json?}
    end
  end

  defp validate_subcommand_args(%{contract_version: version} = acc)
       when version != @contract_version,
       do: {:error, unsupported_contract_version(version, %{"source" => "cli_flag"}), acc.json?}

  defp validate_subcommand_args(%{progress: progress} = acc)
       when progress not in @supported_progress_modes,
       do:
         {:error,
          invalid_args("--progress must be stderr-jsonl", %{
            "observed" => progress,
            "accepted_values" => ["stderr-jsonl"]
          }), acc.json?}

  defp validate_subcommand_args(%{command: command} = acc)
       when command in ["status", "attach", "cancel"] do
    case unsupported_liveness_options(acc) do
      [] ->
        validate_required_subcommand_session(acc)

      unsupported ->
        {:error,
         invalid_args(unsupported_liveness_message(command), %{
           "unsupported_options" => unsupported,
           "accepted_options" => accepted_liveness_options(command),
           "next_actions" => unsupported_liveness_next_actions(command)
         }), acc.json?}
    end
  end

  defp validate_subcommand_args(%{command: "start"} = acc) do
    case unsupported_start_options(acc) do
      [] ->
        validate_required_start_spec(acc)

      unsupported ->
        {:error,
         invalid_args("delegate start does not support these options yet", %{
           "unsupported_options" => unsupported,
           "accepted_options" => ["--spec", "--json", "--contract-version", "--timeout-ms"],
           "next_actions" => ["remove_unsupported_options", "use_delegate_status_after_start"]
         }), acc.json?}
    end
  end

  defp validate_subcommand_args(%{command: "daemon"} = acc) do
    cond do
      Map.has_key?(acc, :daemon_action_conflict) ->
        {:error,
         invalid_args("delegate daemon accepts exactly one action", %{
           "observed_actions" => acc.daemon_action_conflict,
           "accepted_actions" => ["--foreground", "--status", "--stop"],
           "next_actions" => ["choose_one_daemon_action"]
         }), acc.json?}

      true ->
        case unsupported_daemon_options(acc) do
          [] ->
            validate_required_daemon_action(acc)

          unsupported ->
            {:error,
             invalid_args("delegate daemon does not support these options", %{
               "unsupported_options" => unsupported,
               "accepted_options" => [
                 "--foreground",
                 "--status",
                 "--stop",
                 "--json",
                 "--contract-version"
               ],
               "next_actions" => ["remove_unsupported_options", "choose_one_daemon_action"]
             }), acc.json?}
        end
    end
  end

  defp validate_subcommand_args(acc), do: validate_required_subcommand_session(acc)

  defp validate_required_start_spec(%{spec_source: nil} = acc),
    do:
      {:error,
       invalid_args("delegate start requires --spec PATH or --spec -", %{
         "usage" =>
           "pixir delegate start --spec <path|-> [--json] [--contract-version 1] [--timeout-ms N]",
         "next_actions" => ["provide_delegate_spec_path_or_stdin"]
       }), acc.json?}

  defp validate_required_start_spec(acc), do: {:ok, acc}

  defp validate_required_daemon_action(%{daemon_action: nil} = acc),
    do:
      {:error,
       invalid_args("delegate daemon requires an action", %{
         "usage" => "pixir delegate daemon --foreground|--status|--stop [--json]",
         "next_actions" => ["choose_--foreground_--status_or_--stop"]
       }), acc.json?}

  defp validate_required_daemon_action(acc), do: {:ok, acc}

  defp validate_required_subcommand_session(%{command: command, session_id: nil} = acc)
       when command in ["status", "attach", "cancel"],
       do:
         {:error,
          invalid_args("delegate #{command} requires a Delegate handle", %{
            "usage" =>
              "pixir delegate #{command} <delegate_id|parent_session_id> [--json] [--contract-version 1]",
            "next_actions" => ["provide_delegate_id_or_parent_session_id"]
          }), acc.json?}

  defp validate_required_subcommand_session(acc), do: {:ok, acc}

  defp unsupported_liveness_options(%{command: "attach"} = acc) do
    [
      {"--dry-run", acc.dry_run?},
      {"--fail-on-incomplete", acc.fail_on_incomplete?},
      {"--output-dir", not is_nil(acc.output_dir)},
      {"--quiet", acc.quiet?},
      {"--spec", not is_nil(acc.spec_source)},
      {"--timeout-ms", not is_nil(acc.timeout_ms)},
      {"--wait-horizon-ms", not is_nil(acc.wait_horizon_ms) and is_nil(acc.progress)}
    ]
    |> Enum.filter(fn {_flag, present?} -> present? end)
    |> Enum.map(fn {flag, _present?} -> flag end)
  end

  defp unsupported_liveness_options(acc) do
    [
      {"--dry-run", acc.dry_run?},
      {"--fail-on-incomplete", acc.fail_on_incomplete?},
      {"--output-dir", not is_nil(acc.output_dir)},
      {"--progress", not is_nil(acc.progress)},
      {"--quiet", acc.quiet?},
      {"--spec", not is_nil(acc.spec_source)},
      {"--timeout-ms", not is_nil(acc.timeout_ms)},
      {"--wait-horizon-ms", not is_nil(acc.wait_horizon_ms)}
    ]
    |> Enum.filter(fn {_flag, present?} -> present? end)
    |> Enum.map(fn {flag, _present?} -> flag end)
  end

  defp accepted_liveness_options("attach"),
    do: ["--json", "--contract-version", "--progress=stderr-jsonl", "--wait-horizon-ms"]

  defp accepted_liveness_options(_command), do: ["--json", "--contract-version"]

  defp unsupported_start_options(acc) do
    [
      {"--dry-run", acc.dry_run?},
      {"--fail-on-incomplete", acc.fail_on_incomplete?},
      {"--output-dir", not is_nil(acc.output_dir)},
      {"--progress", not is_nil(acc.progress)},
      {"--quiet", acc.quiet?},
      {"--wait-horizon-ms", not is_nil(acc.wait_horizon_ms)}
    ]
    |> Enum.filter(fn {_flag, present?} -> present? end)
    |> Enum.map(fn {flag, _present?} -> flag end)
  end

  defp unsupported_daemon_options(acc) do
    [
      {"--dry-run", acc.dry_run?},
      {"--fail-on-incomplete", acc.fail_on_incomplete?},
      {"--output-dir", not is_nil(acc.output_dir)},
      {"--progress", not is_nil(acc.progress)},
      {"--quiet", acc.quiet?},
      {"--spec", not is_nil(acc.spec_source)},
      {"--timeout-ms", not is_nil(acc.timeout_ms)},
      {"--wait-horizon-ms", not is_nil(acc.wait_horizon_ms)}
    ]
    |> Enum.filter(fn {_flag, present?} -> present? end)
    |> Enum.map(fn {flag, _present?} -> flag end)
  end

  defp put_daemon_action(%{daemon_action: nil} = acc, action),
    do: %{acc | daemon_action: action}

  defp put_daemon_action(acc, action) do
    Map.put(acc, :daemon_action_conflict, [acc.daemon_action, action])
  end

  defp unsupported_liveness_message("attach"),
    do: "delegate attach does not support these options yet"

  defp unsupported_liveness_message(command),
    do: "delegate #{command} does not support these options"

  defp unsupported_liveness_next_actions("attach"),
    do: [
      "remove_unsupported_options",
      "use_delegate_attach_for_snapshot_observation",
      "use_--progress=stderr-jsonl_for_bounded_progress_frames"
    ]

  defp unsupported_liveness_next_actions(_command),
    do: ["remove_unsupported_options", "use_delegate_attach_for_observation"]

  defp dispatch_parsed_subcommand(
         "start",
         request,
         async,
         async_opts,
         read_stdin,
         daemon_client,
         _daemon_command
       ) do
    case load_and_validate_spec(request, read_stdin, Keyword.get(async_opts, :runtime_opts, [])) do
      {:ok, spec, spec_meta} ->
        local_start = fn -> apply(async, :start, [request, spec, spec_meta, async_opts]) end

        dispatch_daemon_start_or_local(
          daemon_client,
          request,
          async_opts,
          %{
            "request" => request_to_wire(request),
            "spec" => spec,
            "spec_meta" => spec_meta,
            "runtime_opts" => []
          },
          local_start
        )
        |> render_async_dispatch(request)

      {:error, error} ->
        error_result(error, request.json?)
    end
  end

  defp dispatch_parsed_subcommand(
         "daemon",
         request,
         _async,
         async_opts,
         _read_stdin,
         daemon_client,
         daemon_command
       ) do
    daemon_opts =
      async_opts
      |> Keyword.put(:client, daemon_client)
      |> Keyword.put(:workspace, request.workspace)

    case apply(daemon_command, :run, [request.daemon_action, daemon_opts]) do
      {:ok, %{after_render: after_render} = payload} ->
        payload = Map.delete(payload, :after_render)
        {:ok, rendered(payload, request.json?, 0, human_async(payload), after_render)}

      {:ok, payload} ->
        {:ok, rendered(payload, request.json?, 0, human_async(payload))}

      {:error, error} ->
        error_result(error, request.json?)
    end
  end

  defp dispatch_parsed_subcommand(
         subcommand,
         request,
         async,
         async_opts,
         _read_stdin,
         daemon_client,
         _daemon_command
       ) do
    dispatch =
      if subcommand == "attach" and request.progress == "stderr-jsonl" do
        dispatch_attach_progress(request, async, async_opts, daemon_client)
      else
        dispatch_subcommand(subcommand, request, async, async_opts, daemon_client)
      end

    case dispatch do
      {:ok, payload} ->
        {:ok,
         rendered(
           payload,
           request.json?,
           subcommand_exit_code(subcommand, payload, request),
           human_async(payload)
         )}

      {:error, error} ->
        error_result(error, request.json?)
    end
  end

  defp dispatch_subcommand("status", request, async, async_opts, daemon_client) do
    dispatch_daemon_or_local(
      "delegate_status",
      daemon_client,
      request,
      %{"handle" => request.session_id},
      fn -> apply(async, :status, [request.session_id, async_opts]) end
    )
  end

  defp dispatch_subcommand("attach", request, async, async_opts, daemon_client) do
    dispatch_daemon_or_local(
      "delegate_attach",
      daemon_client,
      request,
      %{"handle" => request.session_id},
      fn -> apply(async, :attach, [request.session_id, async_opts]) end
    )
  end

  defp dispatch_subcommand("cancel", request, async, async_opts, daemon_client) do
    dispatch_daemon_or_local(
      "delegate_cancel",
      daemon_client,
      request,
      %{"handle" => request.session_id},
      fn -> apply(async, :cancel, [request.session_id, async_opts]) end
    )
  end

  defp dispatch_subcommand(subcommand, _request, _async, _async_opts, _daemon_client),
    do: {:error, unsupported_subcommand(subcommand)}

  defp dispatch_attach_progress(request, async, async_opts, daemon_client) do
    if request.wait_horizon_ms do
      dispatch_attach_follow_progress(request, async, async_opts, daemon_client)
    else
      dispatch_attach_snapshot_progress(request, async, async_opts, daemon_client)
    end
  end

  defp dispatch_attach_snapshot_progress(request, async, async_opts, daemon_client) do
    with {:ok, payload} <-
           dispatch_subcommand("attach", request, async, async_opts, daemon_client) do
      frame = Progress.frame(payload, 1, source: Progress.source(payload))
      emit_progress_frame(frame)

      {:ok,
       annotate_attach_progress(payload, request, %{
         "frame_count" => 1,
         "follow_requested" => false,
         "followed" => false,
         "follow_transport" => "snapshot",
         "wait_horizon_exhausted" => false,
         "follow_error_count" => 0,
         "source" => frame["source"]
       })}
    end
  end

  defp dispatch_attach_follow_progress(request, async, async_opts, daemon_client) do
    emit_frame = fn frame -> emit_progress_frame(frame) end
    body = %{"handle" => request.session_id, "wait_horizon_ms" => request.wait_horizon_ms}

    daemon_result =
      if Code.ensure_loaded?(daemon_client) and function_exported?(daemon_client, :follow, 4) do
        apply(daemon_client, :follow, [
          "delegate_attach_follow",
          body,
          emit_frame,
          [workspace: request.workspace]
        ])
      else
        {:error,
         error_payload("daemon_follow_unsupported", "Delegate daemon follow is unsupported", %{
           "fallback_allowed" => true,
           "next_actions" => ["upgrade_pixir_daemon", "use_snapshot_attach_fallback"]
         })}
      end

    case daemon_result do
      {:ok, payload} ->
        {:ok, put_attach_exit_metadata(payload, request)}

      {:error, error} ->
        if daemon_fallback_allowed?(error) do
          emit_follow_fallback_snapshot(error, request, async, async_opts)
        else
          {:error, error}
        end
    end
  end

  defp emit_follow_fallback_snapshot(error, request, async, async_opts) do
    with {:ok, payload} <- apply(async, :attach, [request.session_id, async_opts]) do
      payload = annotate_daemon_fallback(payload, error)
      source = Progress.source(payload)
      frame = Progress.frame(payload, 1, source: source)
      emit_progress_frame(frame)

      {:ok,
       annotate_attach_progress(payload, request, %{
         "frame_count" => 1,
         "follow_requested" => true,
         "followed" => false,
         "follow_transport" => "durable_snapshot_fallback",
         "wait_horizon_exhausted" => false,
         "follow_error_count" => 1,
         "source" => source,
         "last_follow_error" => Map.take(error, ["kind", "message", "details"])
       })}
    end
  end

  defp emit_progress_frame(frame), do: IO.puts(:stderr, Jason.encode!(frame))

  defp annotate_attach_progress(payload, request, progress) do
    progress =
      progress
      |> Map.put_new("wait_horizon_ms", request.wait_horizon_ms)
      |> Map.put_new("exit_code", subcommand_exit_code("attach", payload, request))

    payload
    |> Progress.annotate(progress)
    |> put_attach_exit_metadata(request)
  end

  defp put_attach_exit_metadata(payload, request) do
    exit_code = subcommand_exit_code("attach", payload, request)

    payload
    |> Map.put("command_ok", true)
    |> Map.put("work_complete", payload["status"] == "completed" and payload["complete"] == true)
    |> Map.put("exit_code", exit_code)
    |> update_in(["progress"], fn
      %{} = progress -> Map.put(progress, "exit_code", exit_code)
      other -> other
    end)
  end

  defp dispatch_daemon_start_or_local(daemon_client, request, async_opts, body, local_fun) do
    daemon_result =
      case daemon_runtime_opts_error(async_opts) do
        nil ->
          apply(daemon_client, :call, ["delegate_start", body, [workspace: request.workspace]])

        error ->
          {:error, error}
      end

    case daemon_result do
      {:ok, payload} ->
        {:ok, payload}

      {:error, error} ->
        cond do
          not daemon_fallback_allowed?(error) ->
            {:error, error}

          allow_current_runtime_start?(async_opts) ->
            case local_fun.() do
              {:ok, payload} -> {:ok, annotate_daemon_fallback(payload, error)}
              {:error, local_error} -> {:error, annotate_daemon_fallback(local_error, error)}
            end

          true ->
            {:error, start_requires_daemon_error(error)}
        end
    end
  end

  defp dispatch_daemon_or_local(action, daemon_client, request, body, local_fun) do
    case apply(daemon_client, :call, [action, body, [workspace: request.workspace]]) do
      {:ok, payload} ->
        {:ok, payload}

      {:error, error} ->
        if daemon_fallback_allowed?(error) do
          case local_fun.() do
            {:ok, payload} -> {:ok, annotate_daemon_fallback(payload, error)}
            {:error, local_error} -> {:error, annotate_daemon_fallback(local_error, error)}
          end
        else
          {:error, error}
        end
    end
  end

  defp daemon_runtime_opts_error(async_opts) do
    runtime_opts = Keyword.get(async_opts, :runtime_opts, [])

    if runtime_opts == [] do
      nil
    else
      error_payload(
        "daemon_runtime_opts_unsupported",
        "Delegate daemon dispatch does not accept non-empty runtime_opts in this slice",
        %{
          "fallback_allowed" => true,
          "runtime_opts_count" => length(runtime_opts),
          "next_actions" => [
            "use_attached_delegate_for_injected_runtime_opts",
            "avoid_daemon_for_injected_provider_or_auth_seams"
          ]
        }
      )
    end
  end

  defp daemon_fallback_allowed?(%{"details" => %{"fallback_allowed" => true}}), do: true
  defp daemon_fallback_allowed?(_error), do: false

  defp allow_current_runtime_start?(async_opts) do
    async_opts
    |> Keyword.get(:allow_current_runtime_start?, false)
    |> Kernel.==(true)
  end

  defp render_async_dispatch({:ok, payload}, request) do
    {:ok,
     rendered(payload, request.json?, runtime_exit_code(payload, request), human_async(payload))}
  end

  defp render_async_dispatch({:error, error}, request), do: error_result(error, request.json?)

  defp annotate_daemon_fallback(payload, error) when is_map(payload) do
    Map.put(payload, "daemon_fallback", %{
      "attempted" => true,
      "used" => false,
      "reason" => error["kind"],
      "message" => error["message"],
      "details" => Map.get(error, "details", %{}),
      "fallback" => "current_runtime_or_durable_snapshot"
    })
  end

  defp start_requires_daemon_error(daemon_error) do
    error_payload(
      "daemon_required",
      "delegate start requires a reachable resident Delegate daemon",
      %{
        "daemon_error" => daemon_error,
        "fallback_allowed" => false,
        "reason" => "start_without_resident_owner_would_not_survive_cli_process_exit",
        "next_actions" => [
          "start_pixir_delegate_daemon_--foreground_--json_in_a_managed_process",
          "rerun_delegate_start_after_daemon_is_reachable",
          "use_attached_delegate_--spec_for_single_invocation_execution"
        ]
      }
    )
  end

  defp request_to_wire(request) do
    %{
      "json?" => request.json?,
      "spec_source" => request.spec_source,
      "timeout_ms" => request.timeout_ms,
      "contract_version" => request.contract_version
    }
  end

  defp load_and_validate_spec(request, read_stdin, runtime_opts) do
    # Strict key validation runs right after decode: unknown-field diagnosis
    # must not wait on (or be masked by) filesystem-backed role discovery.
    with {:ok, raw, source_meta} <- read_spec(request.spec_source, read_stdin),
         {:ok, spec} <- decode_spec(raw),
         :ok <- validate_strict_spec_keys(spec, request.workspace, runtime_opts),
         {:ok, spec_meta} <- validate_spec(spec, request.workspace, runtime_opts) do
      {:ok, spec, Map.merge(source_meta, spec_meta)}
    end
  end

  defp read_spec("-", read_stdin) do
    case read_stdin.() do
      :eof ->
        {:error, invalid_json("delegate spec stdin was empty", %{"source" => "stdin"})}

      {:error, reason} ->
        {:error,
         error_payload("stdin_error", "could not read delegate spec from stdin", %{
           "reason" => inspect(reason),
           "next_actions" => ["retry_with_spec_file", "pipe_exactly_one_json_object_to_stdin"]
         })}

      raw when is_binary(raw) ->
        accept_raw_spec(raw, %{"kind" => "stdin", "bytes" => byte_size(raw)})
    end
  end

  defp read_spec(path, _read_stdin) when is_binary(path) do
    case File.read(path) do
      {:ok, raw} ->
        accept_raw_spec(raw, %{"kind" => "file", "path" => path, "bytes" => byte_size(raw)})

      {:error, reason} ->
        {:error,
         error_payload("spec_read_failed", "could not read delegate spec", %{
           "path" => path,
           "reason" => inspect(reason),
           "next_actions" => ["check_the_spec_path", "run_pixir_delegate_with_--spec_-"]
         })}
    end
  end

  defp accept_raw_spec(raw, meta) do
    cond do
      String.trim(raw) == "" ->
        {:error, invalid_json("delegate spec was empty", meta)}

      byte_size(raw) > @max_spec_bytes ->
        {:error,
         invalid_args("delegate spec is too large", %{
           "bytes" => byte_size(raw),
           "max_bytes" => @max_spec_bytes
         })}

      true ->
        {:ok, raw, meta}
    end
  end

  defp decode_spec(raw) do
    case Jason.decode(raw) do
      {:ok, spec} when is_map(spec) ->
        {:ok, spec}

      {:ok, other} ->
        {:error,
         invalid_spec("delegate spec must be a JSON object", %{
           "observed_type" => json_type(other)
         })}

      {:error, error} ->
        {:error,
         invalid_json("delegate spec is not valid JSON", %{
           "decode_error" => Exception.message(error),
           "next_actions" => ["provide_exactly_one_json_object"]
         })}
    end
  end

  defp validate_spec(spec, workspace, runtime_opts) do
    with :ok <- validate_spec_contract_version(spec),
         {:ok, strategy} <- validate_strategy(spec),
         {:ok, mode} <- validate_mode(spec),
         :ok <- validate_strategy_mode(strategy, mode),
         {:ok, write_policy} <- validate_write_policy(spec, mode),
         {:ok, transport} <- validate_transport(spec),
         {:ok, planned_child_count} <- validate_strategy_shape(strategy, spec),
         {:ok, strategy_meta} <-
           validate_strategy_contract(strategy, spec, workspace, runtime_opts) do
      {:ok,
       Map.merge(
         %{
           "strategy" => strategy,
           "mode" => mode || "read_only",
           "write_policy" => write_policy,
           "transport" => transport,
           "planned_child_count" => planned_child_count,
           "spec_contract_version" => Map.get(spec, "contract_version", @contract_version)
         },
         strategy_meta
       )}
    end
  end

  defp validate_spec_contract_version(%{"contract_version" => version})
       when version != @contract_version,
       do: {:error, unsupported_contract_version(version, %{"source" => "spec"})}

  defp validate_spec_contract_version(_spec), do: :ok

  defp validate_strategy(%{"strategy" => strategy}) when strategy in @supported_strategies,
    do: {:ok, strategy}

  defp validate_strategy(%{"strategy" => strategy}),
    do:
      {:error,
       invalid_spec("delegate spec strategy is unsupported", %{
         "observed" => strategy,
         "accepted_values" => @supported_strategies
       })}

  defp validate_strategy(_spec),
    do:
      {:error,
       invalid_spec("delegate spec is missing strategy", %{
         "missing" => ["strategy"],
         "accepted_values" => @supported_strategies
       })}

  defp validate_mode(%{"mode" => mode}) when mode in @supported_modes, do: {:ok, mode}
  defp validate_mode(%{"mode" => mode}), do: {:error, unsupported_mode(mode)}
  defp validate_mode(_spec), do: {:ok, nil}

  @supported_transports ["auto", "websocket", "http_sse"]

  defp validate_transport(spec) do
    value = get_in(spec, ["subagents", "transport"]) || Map.get(spec, "transport")

    cond do
      is_nil(value) ->
        {:ok, nil}

      value in @supported_transports ->
        {:ok, value}

      true ->
        {:error,
         invalid_spec("delegate spec transport is unsupported", %{
           "observed" => inspect(value),
           "supported_transports" => @supported_transports,
           "next_actions" => ["use_auto_websocket_or_http_sse", "remove_transport_field"]
         })}
    end
  end

  defp validate_strategy_mode("workflow", mode) when mode in [nil, "read_only", "bounded_write"],
    do: :ok

  defp validate_strategy_mode(_strategy, _mode), do: :ok

  defp validate_write_policy(%{"write_policy" => raw_policy}, "bounded_write") do
    case WritePolicy.normalize(raw_policy) do
      {:ok, policy} ->
        {:ok, WritePolicy.metadata(policy)}

      {:error, error} ->
        {:error, write_policy_error(error)}
    end
  end

  defp validate_write_policy(_spec, "bounded_write") do
    {:error,
     invalid_spec("bounded_write delegate spec requires write_policy", %{
       "missing" => ["write_policy"],
       "next_actions" => ["add_write_policy_or_use_read_only_mode"]
     })}
  end

  defp validate_write_policy(%{"write_policy" => _raw_policy}, _mode) do
    {:error,
     invalid_spec("write_policy requires mode bounded_write", %{
       "next_actions" => ["set_mode_to_bounded_write", "remove_write_policy"]
     })}
  end

  defp validate_write_policy(_spec, _mode), do: {:ok, nil}

  # Branch precedence mirrors Runner.normalize_tasks/1: a list-valued tasks
  # field owns task normalization (even when empty), before any legacy task.
  defp validate_strategy_shape("subagents", spec) do
    tasks = Map.get(spec, "tasks")

    cond do
      non_empty_list?(tasks) ->
        case Enum.find_index(tasks, &(not valid_task_entry?(&1))) do
          nil ->
            {:ok, length(tasks)}

          task_index ->
            {:error,
             invalid_spec(
               "subagents.tasks entries must be non-empty task strings",
               Map.merge(task_location_details(task_index), %{
                 "next_actions" => ["fix_subagents_tasks_entries"]
               })
             )}
        end

      is_list(tasks) ->
        {:error,
         invalid_spec("subagents delegate spec requires non-empty task text", %{
           "missing_any_of" => ["task", "tasks"],
           "next_actions" => ["add_task_for_one_child", "add_tasks_for_fanout"]
         })}

      non_empty_string?(Map.get(spec, "task")) ->
        planned_child_count(spec)

      true ->
        {:error,
         invalid_spec("subagents delegate spec requires task or tasks", %{
           "missing_any_of" => ["task", "tasks"],
           "next_actions" => ["add_task_for_one_child", "add_tasks_for_fanout"]
         })}
    end
  end

  defp validate_strategy_shape("workflow", spec) do
    steps = workflow_steps(spec)

    if non_empty_list?(steps) do
      {:ok, length(steps)}
    else
      {:error,
       invalid_spec("workflow delegate spec requires steps", %{
         "missing_any_of" => ["steps", "workflow.steps"],
         "next_actions" => ["add_a_non_empty_steps_array"]
       })}
    end
  end

  defp workflow_steps(spec), do: Map.get(spec, "steps") || get_in(spec, ["workflow", "steps"])

  # Mirrors Pixir.Delegate.Runner.normalize_task/1 so dry-run rejects
  # exactly the tasks[] entries the real run would reject.
  defp valid_task_entry?(task) when is_binary(task), do: String.trim(task) != ""

  defp valid_task_entry?(%{"task" => task} = entry) when is_binary(task),
    do:
      String.trim(task) != "" and
        Enum.all?(Map.keys(entry), &(&1 in ["task", "attachments"])) and
        valid_task_attachments?(Map.get(entry, "attachments", []))

  defp valid_task_entry?(_task), do: false

  defp planned_child_count(spec) do
    count = get_in(spec, ["subagents", "count"]) || 1

    if is_integer(count) and count > 0 do
      {:ok, count}
    else
      {:error,
       invalid_spec("subagents.count must be a positive integer", %{
         "observed" => inspect(count),
         "next_actions" => ["set_subagents_count_to_a_positive_integer"]
       })}
    end
  end

  defp validate_strategy_contract("subagents", spec, workspace, runtime_opts) do
    with {:ok, role} <- validate_subagent_role_shape(spec),
         {:ok, known} <- validate_known_subagent_role(role, workspace, runtime_opts) do
      {:ok,
       %{
         "subagent_role" => role,
         "subagent_role_validation" => %{"status" => "known", "known" => known}
       }}
    end
  end

  defp validate_strategy_contract(
         "workflow",
         %{"mode" => "bounded_write"} = spec,
         workspace,
         runtime_opts
       ) do
    with {:ok, policy} <- normalize_contract_write_policy(spec),
         :ok <- validate_workflow_bounded_write_contract(spec, policy),
         :ok <- rehearse_workflow_contract(spec, "bounded_write", workspace, runtime_opts, policy) do
      {:ok,
       %{
         "workflow_write_validation" => %{
           "status" => "known_bounded_write",
           "gate" => "fail_closed",
           "workspace_mode" => "shared"
         }
       }}
    end
  end

  defp validate_strategy_contract("workflow", spec, workspace, runtime_opts) do
    with :ok <- validate_workflow_read_only_contract(spec),
         :ok <-
           rehearse_workflow_contract(
             spec,
             Map.get(spec, "mode") || "read_only",
             workspace,
             runtime_opts,
             nil
           ) do
      {:ok,
       %{
         "workflow_read_only_validation" => %{
           "status" => "known_read_only",
           "gate" => "fail_closed"
         }
       }}
    end
  end

  defp validate_strategy_contract(_strategy, _spec, _workspace, _runtime_opts), do: {:ok, %{}}

  defp normalize_contract_write_policy(%{"write_policy" => raw_policy}) do
    case WritePolicy.normalize(raw_policy) do
      {:ok, policy} -> {:ok, policy}
      {:error, error} -> {:error, write_policy_error(error)}
    end
  end

  defp normalize_contract_write_policy(_spec), do: {:ok, nil}

  defp validate_workflow_bounded_write_contract(spec, policy) do
    spec
    |> workflow_steps()
    |> Enum.with_index(1)
    |> Enum.reduce_while(:ok, fn {step, index}, :ok ->
      case workflow_step_bounded_write_contract(step, index, policy) do
        :ok -> {:cont, :ok}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp workflow_step_bounded_write_contract(step, index, _policy) when not is_map(step) do
    {:error,
     invalid_spec(
       "workflow step must be an object",
       Map.merge(step_location_details(index), %{
         "index" => index,
         "next_actions" => ["replace_workflow_step_with_an_object"]
       })
     )}
  end

  defp workflow_step_bounded_write_contract(step, index, policy) do
    value = step_field(step, "permission_mode") || step_field(step, "sandbox_mode")

    if read_only_mode?(value) do
      :ok
    else
      validate_workflow_writer_step_contract(step, index, policy)
    end
  end

  defp validate_workflow_writer_step_contract(step, index, policy) do
    id = step_field(step, "id") || "step_#{index}"

    with {:ok, write_set} <- workflow_writer_write_set(step, index, id),
         :ok <- workflow_writer_shared_workspace(step, index, id),
         :ok <- workflow_writer_write_set_within_policy(write_set, step, index, id, policy) do
      :ok
    end
  end

  defp workflow_writer_write_set(step, index, id) do
    cond do
      not has_step_field?(step, "write_set") ->
        {:error,
         invalid_spec(
           "bounded_write workflow writer step requires write_set",
           Map.merge(step_location_details(index, "write_set"), %{
             "id" => id,
             "next_actions" => [
               "add_explicit_write_set",
               "split_read_only_steps_from_writer_steps"
             ]
           })
         )}

      true ->
        case normalize_contract_write_set(step_field(step, "write_set")) do
          {:ok, [_ | _] = write_set} ->
            {:ok, write_set}

          {:ok, []} ->
            {:error,
             invalid_spec(
               "bounded_write workflow writer step requires write_set",
               Map.merge(step_location_details(index, "write_set"), %{
                 "id" => id,
                 "next_actions" => [
                   "add_non_empty_write_set",
                   "split_read_only_steps_from_writer_steps"
                 ]
               })
             )}

          {:error, details} ->
            {:error,
             invalid_spec(
               "workflow writer write_set must be a string or list of strings",
               Map.merge(step_location_details(index, "write_set"), %{
                 "id" => id,
                 "observed" => details["observed"],
                 "next_actions" => ["replace_write_set_with_path_strings"]
               })
             )}
        end
    end
  end

  defp workflow_writer_shared_workspace(step, index, id) do
    case step_field(step, "workspace_mode") do
      "shared" ->
        :ok

      nil ->
        {:error,
         invalid_spec(
           "bounded_write workflow writer step requires explicit shared workspace_mode",
           Map.merge(step_location_details(index, "workspace_mode"), %{
             "id" => id,
             "reason" => "missing_workspace_mode_defaults_to_isolated_snapshot",
             "accepted_values" => ["shared"],
             "next_actions" => ["set_writer_step_workspace_mode_to_shared"]
           })
         )}

      observed ->
        {:error,
         invalid_spec(
           "bounded_write workflow writer step must use shared workspace_mode",
           Map.merge(step_location_details(index, "workspace_mode"), %{
             "id" => id,
             "observed" => observed_mode(observed),
             "reason" => "isolated_writes_do_not_mutate_parent_workspace",
             "accepted_values" => ["shared"],
             "next_actions" => ["set_writer_step_workspace_mode_to_shared"]
           })
         )}
    end
  end

  defp workflow_writer_write_set_within_policy(_write_set, _step, index, id, nil) do
    {:error,
     invalid_spec(
       "bounded_write workflow writer step requires write_policy",
       Map.merge(step_location_details(index, "write_set"), %{
         "id" => id,
         "missing" => ["write_policy"],
         "next_actions" => ["add_write_policy_or_use_read_only_mode"]
       })
     )}
  end

  defp workflow_writer_write_set_within_policy(write_set, _step, index, id, policy) do
    case WritePolicy.narrow_to_write_set(policy, write_set) do
      {:ok, _narrowed} ->
        :ok

      {:error, error} ->
        {:error,
         error
         |> write_policy_error()
         |> merge_error_details(
           Map.merge(step_location_context(index, "write_set"), %{"id" => id})
         )}
    end
  end

  defp normalize_contract_write_set(value) when is_binary(value),
    do: normalize_contract_write_set([value])

  defp normalize_contract_write_set(values) when is_list(values) do
    if Enum.all?(values, &is_binary/1) do
      write_set =
        values
        |> Enum.map(&normalize_contract_path_token/1)
        |> Enum.reject(&(&1 == ""))
        |> Enum.uniq()

      {:ok, write_set}
    else
      {:error, %{"observed" => inspect(values)}}
    end
  end

  defp normalize_contract_write_set(value), do: {:error, %{"observed" => inspect(value)}}

  defp normalize_contract_path_token(value) do
    value
    |> String.trim()
    |> String.trim_leading("./")
    |> String.trim_trailing("/")
  end

  defp validate_workflow_read_only_contract(spec) do
    top_level_read_only? = Map.get(spec, "mode") == "read_only"

    spec
    |> workflow_steps()
    |> Enum.with_index(1)
    |> Enum.reduce_while(:ok, fn {step, index}, :ok ->
      case workflow_step_read_only_contract(step, index, top_level_read_only?) do
        :ok -> {:cont, :ok}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp workflow_step_read_only_contract(step, index, _top_level_read_only?)
       when not is_map(step) do
    {:error,
     invalid_spec(
       "workflow step must be an object",
       Map.merge(step_location_details(index), %{
         "index" => index,
         "next_actions" => ["replace_workflow_step_with_an_object"]
       })
     )}
  end

  defp workflow_step_read_only_contract(step, index, top_level_read_only?) do
    value = Map.get(step, "permission_mode") || Map.get(step, "sandbox_mode")

    cond do
      read_only_mode?(value) ->
        :ok

      not is_nil(value) ->
        {:error,
         invalid_spec(
           "workflow delegate runtime v0 only supports read-only steps",
           Map.merge(step_location_details(index, "permission_mode"), %{
             "id" => Map.get(step, "id", "step_#{index}"),
             "observed" => observed_mode(value),
             "accepted_values" => ["read_only", "read-only"],
             "next_actions" => [
               "set_step_permission_mode_to_read_only",
               "split_write_capable_workflows_out_of_delegate_v0"
             ]
           })
         )}

      top_level_read_only? ->
        :ok

      true ->
        {:error,
         invalid_spec(
           "workflow delegate runtime v0 requires provably read-only steps",
           Map.merge(step_location_details(index, "permission_mode"), %{
             "id" => Map.get(step, "id", "step_#{index}"),
             "reason" => "missing_permission_mode_is_writer_capable_by_default",
             "next_actions" => [
               "set_mode_to_read_only_to_apply_read_only_to_all_steps",
               "set_each_step_permission_mode_to_read_only"
             ]
           })
         )}
    end
  end

  defp read_only_mode?(value), do: value in [:read_only, "read_only", "read-only"]

  # Same location convention as step_location_details/2: the human-facing
  # field label is 1-based, the machine fields (json_pointer/path/task_index)
  # are 0-based. Takes the 0-based tasks[] position directly.
  defp task_location_details(task_index) do
    path = ["tasks", task_index]

    %{
      "field" => "tasks[#{task_index + 1}]",
      "json_pointer" => json_pointer(path),
      "path" => path,
      "task_index" => task_index
    }
  end

  defp step_location_details(index, field \\ nil) do
    step_index = index - 1

    path =
      case field do
        nil -> ["steps", step_index]
        field -> ["steps", step_index, field]
      end

    field_label =
      case field do
        nil -> "steps[#{index}]"
        field -> "steps[#{index}].#{field}"
      end

    %{
      "field" => field_label,
      "json_pointer" => json_pointer(path),
      "path" => path,
      "step_index" => step_index
    }
  end

  defp step_location_context(index, field) do
    %{
      "step_field" => "steps[#{index}].#{field}",
      "step_json_pointer" => "/steps/#{index - 1}/#{json_pointer_token(field)}",
      "step_path" => ["steps", index - 1, field],
      "step_index" => index - 1
    }
  end

  defp json_pointer(path) do
    "/" <> Enum.map_join(path, "/", &json_pointer_token/1)
  end

  defp json_pointer_token(value) when is_integer(value), do: Integer.to_string(value)

  defp json_pointer_token(value) do
    value
    |> to_string()
    |> String.replace("~", "~0")
    |> String.replace("/", "~1")
  end

  defp observed_mode(value) when is_binary(value), do: value
  defp observed_mode(value) when is_atom(value), do: to_string(value)
  defp observed_mode(value), do: inspect(value)

  defp step_field(map, key), do: Map.get(map, key)

  defp has_step_field?(map, key), do: Map.has_key?(map, key)

  defp validate_subagent_role_shape(spec) do
    role =
      get_in(spec, ["subagents", "role"]) ||
        get_in(spec, ["subagents", "agent"]) ||
        Map.get(spec, "agent") ||
        "explorer"

    if is_binary(role) and String.trim(role) != "" do
      {:ok, String.trim(role)}
    else
      {:error,
       invalid_spec("subagents.role must be a non-empty string", %{
         "next_actions" => ["set_subagents_role_to_explorer"]
       })}
    end
  end

  defp validate_known_subagent_role(role, workspace, runtime_opts) do
    {:ok, %{agents: agents}} =
      Agents.discover(workspace, Keyword.get(runtime_opts, :agents_opts, []))

    known = Enum.map(agents, & &1.name)

    if role in known do
      {:ok, known}
    else
      {:error,
       error_payload("not_found", "agent not found", %{
         "field" => "subagents.role",
         "role" => role,
         "known" => known,
         "next_actions" => [
           "choose_known_subagent_role",
           "add_a_matching_agent_config",
           "rerun_delegate_dry_run"
         ]
       })}
    end
  end

  defp dry_run_result(request, spec, spec_meta) do
    dry_run_children = dry_run_children(spec, spec_meta)

    payload =
      %{
        "ok" => true,
        "status" => "planned",
        "kind" => "delegate_plan",
        "contract_version" => @contract_version,
        "dry_run" => true,
        "strategy" => spec_meta["strategy"],
        "workspace" => request.workspace,
        "summary" =>
          "Delegate dry-run accepted; no provider, Subagent, Workflow, host command, or artifact execution was performed.",
        "spec_source" => Map.take(spec_meta, ["kind", "path", "bytes"]),
        "limits" => limits(request),
        "beam_coordination" => beam_coordination(spec_meta),
        "write_policy" => spec_meta["write_policy"],
        "host_boundary" => host_boundary(),
        "diagnostics" => diagnostics(),
        "artifacts" => [],
        "next_actions" => dry_run_next_actions(spec_meta)
      }
      |> put_if_present("children", dry_run_children)
      |> put_if_present("children_order", dry_run_children_order(spec_meta, dry_run_children))
      |> put_if_present("role_validation", spec_meta["subagent_role_validation"])
      |> put_if_present("transport", spec_meta["transport"])

    {:ok, rendered(payload, request.json?, 0, human_success(payload))}
  end

  defp dry_run_children(%{"tasks" => tasks}, %{"strategy" => "subagents"}) when is_list(tasks) do
    tasks
    |> Enum.map(&dry_run_task_text/1)
    |> Enum.with_index()
    |> Enum.map(fn {task, index} ->
      %{
        "status" => "planned",
        "task" => task,
        "index" => index
      }
    end)
  end

  defp dry_run_children(%{"task" => task} = spec, %{"strategy" => "subagents"})
       when is_binary(task) do
    count = get_in(spec, ["subagents", "count"]) || 1

    if is_integer(count) and count > 0 do
      Enum.map(1..count, fn _position ->
        %{
          "status" => "planned",
          "task" => String.trim(task)
        }
      end)
    else
      nil
    end
  end

  defp dry_run_children(_spec, _spec_meta), do: nil

  defp dry_run_task_text(task) when is_binary(task) do
    case String.trim(task) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp dry_run_task_text(%{"task" => task}) when is_binary(task), do: dry_run_task_text(task)
  defp dry_run_task_text(_task), do: nil

  defp dry_run_children_order(%{"strategy" => "subagents"}, children) when is_list(children),
    do: "unspecified; use children[].index as task-position evidence when present"

  defp dry_run_children_order(_spec_meta, _children), do: nil

  defp dry_run_next_actions(%{"strategy" => "workflow"}) do
    [
      "run_without_--dry-run_for_attached_workflow",
      "inspect_delegate_diagnostics_after_session",
      "keep_async_start_status_attach_cancel_as_TODO_delegate_async"
    ]
  end

  defp dry_run_next_actions(_spec_meta) do
    [
      "run_without_--dry-run_for_attached_subagents",
      "inspect_delegate_diagnostics_after_session",
      "keep_async_start_status_attach_cancel_as_TODO_delegate_async"
    ]
  end

  defp runtime_result(runner, request, spec, spec_meta, runtime_opts) do
    case runner.run(request, spec, spec_meta, runtime_opts) do
      {:ok, payload} ->
        payload = normalize_runtime_payload(payload, request, spec_meta)
        exit_code = runtime_exit_code(payload, request)
        {:ok, rendered(payload, request.json?, exit_code, human_runtime(payload))}

      {:error, error} ->
        payload = normalize_error_payload(error)
        exit_code = runtime_exit_code(payload, request)
        {:error, rendered(payload, request.json?, exit_code, payload["message"])}
    end
  end

  defp error_result(error, json?) do
    payload = normalize_error_payload(error)
    exit_code = exit_code(payload)
    {:error, rendered(payload, json?, exit_code, payload["message"])}
  end

  defp rendered(payload, json?, exit_code, text) do
    payload =
      payload
      |> put_envelope_v1(exit_code)
      |> put_evidence_metadata()

    %{payload: payload, json?: json?, exit_code: exit_code, text: text}
  end

  defp rendered(payload, json?, exit_code, text, after_render)
       when is_function(after_render, 0) do
    payload
    |> rendered(json?, exit_code, text)
    |> Map.put(:after_render, after_render)
  end

  defp limits(request) do
    %{
      "delegate_timeout_ms" => request.timeout_ms,
      "fail_on_incomplete" => request.fail_on_incomplete?,
      "progress" => request.progress,
      "quiet" => request.quiet?,
      "output_dir" => request.output_dir
    }
  end

  defp beam_coordination(spec_meta) do
    %{
      "mode" => "planned",
      "entrypoint" => "single_pixir_process",
      "fanout_model" => "BEAM coordination, no process-per-child shell fanout",
      "strategy" => spec_meta["strategy"],
      "delegate_mode" => spec_meta["mode"],
      "planned_child_count" => spec_meta["planned_child_count"],
      "runtime_entrypoints" => ["Pixir.Subagents.Manager", "Pixir.Workflows"]
    }
    |> put_if_present("subagent_role", spec_meta["subagent_role"])
  end

  defp host_boundary do
    %{
      "external_process_spawns" => 0,
      "external_process_spawns_scope" => "delegate_entrypoint_only_not_child_tools",
      "measurement" => "static_contract_assertion_not_global_host_metric",
      "nested_pixir_processes" => 0,
      "nested_mix_processes" => 0,
      "shell_polling" => false,
      "host_command_execution" => "none_in_delegate_contract",
      "rule" => "treat every external process spawn as a scarce observable boundary crossing"
    }
  end

  defp diagnostics do
    %{
      "tree_command" => "available_after_delegate_runner_creates_a_session",
      "diagnose_command" => "available_after_delegate_runner_creates_a_session",
      "issue" => "private-tracker#133 (see docs/adr/README.md on private refs)"
    }
  end

  defp normalize_error_payload(payload) do
    next_actions = get_in(payload, ["details", "next_actions"]) || ["run_pixir_delegate_--help"]

    payload
    |> Map.put_new("ok", false)
    |> Map.put_new("contract_version", @contract_version)
    |> Map.put_new("beam_coordination", %{"mode" => "not_started"})
    |> Map.put_new("host_boundary", host_boundary())
    |> Map.put_new("next_actions", next_actions)
  end

  defp normalize_runtime_payload(payload, request, spec_meta) do
    payload
    |> Map.put_new("ok", payload["status"] == "completed")
    |> Map.put_new("kind", "delegate_result")
    |> Map.put_new("contract_version", @contract_version)
    |> Map.put_new("dry_run", false)
    |> Map.put_new("strategy", spec_meta["strategy"])
    |> Map.put_new("mode", spec_meta["mode"])
    |> Map.put_new("write_policy", spec_meta["write_policy"])
    |> Map.put_new("workspace", request.workspace)
    |> Map.put_new("limits", limits(request))
    |> Map.put_new("beam_coordination", beam_coordination(spec_meta))
    |> Map.put_new("host_boundary", host_boundary())
    |> Map.put_new("artifacts", [])
    |> Map.put_new("next_actions", [])
  end

  defp put_envelope_v1(payload, exit_code) do
    payload
    |> Map.put_new("schema_version", @envelope_schema_version)
    |> Map.put_new("schema", "pixir.delegate.envelope.v1")
    |> Map.put_new("command_ok", command_ok?(payload))
    |> Map.put_new("work_complete", work_complete?(payload))
    |> Map.put_new("outcome", outcome(payload))
    |> Map.put_new("reason_code", reason_code(payload))
    |> Map.put_new("exit_code", exit_code)
    |> put_children_envelope_v1()
    |> put_output_warning_envelope()
  end

  defp put_evidence_metadata(payload) do
    case Evidence.refresh_payload(payload) do
      {:ok, payload} -> payload
      {:error, _error} -> payload
    end
  end

  defp command_ok?(%{"status" => status}) when status in ["rejected", "unsupported"], do: false
  defp command_ok?(_payload), do: true

  defp work_complete?(%{"status" => "completed", "ok" => false}), do: false
  defp work_complete?(%{"status" => "completed", "ok" => true}), do: true
  defp work_complete?(%{"status" => "completed", "complete" => true}), do: true
  defp work_complete?(%{"status" => "completed"}), do: true
  defp work_complete?(_payload), do: false

  defp outcome(%{"status" => status}) when is_binary(status), do: status
  defp outcome(%{"kind" => kind}) when is_binary(kind), do: kind
  defp outcome(_payload), do: "unknown"

  defp reason_code(%{"status" => "completed"}), do: "completed"
  defp reason_code(%{"status" => "planned"}), do: "planned_not_executed"
  defp reason_code(%{"status" => "running"}), do: "work_still_running"
  defp reason_code(%{"status" => "queued"}), do: "queued"
  defp reason_code(%{"status" => "cancelled"}), do: "cancelled"
  defp reason_code(%{"status" => "failed"}), do: "failed"

  defp reason_code(%{
         "status" => status,
         "timeout_diagnostics" => %{"classification" => classification}
       })
       when status in ["timed_out", "partial"] and is_binary(classification),
       do: classification_reason_code(classification)

  defp reason_code(%{"status" => "timed_out"}), do: "child_timed_out"
  defp reason_code(%{"status" => "unsupported"}), do: "unsupported"

  defp reason_code(%{"status" => "rejected", "kind" => kind}) when is_binary(kind), do: kind

  defp reason_code(%{"status" => "partial"} = payload) do
    counts = payload["counts"] || %{}

    cond do
      is_map(payload["spawn_failure"]) -> "spawn_failed"
      error_kind?(payload, "stale_handle") -> "stale_handle"
      error_kind?(payload, "owner_unavailable") -> "owner_unavailable"
      (counts["timed_out"] || 0) > 0 -> "child_timed_out"
      (counts["failed"] || 0) > 0 -> "child_failed"
      (counts["cancelled"] || 0) > 0 -> "cancelled"
      (counts["active"] || 0) > 0 -> "work_still_running"
      true -> "partial"
    end
  end

  defp reason_code(%{"status" => status}) when is_binary(status), do: status
  defp reason_code(%{"kind" => kind}) when is_binary(kind), do: kind
  defp reason_code(_payload), do: "unknown"

  defp classification_reason_code("spawn_failure"), do: "spawn_failed"
  defp classification_reason_code("child_timeout"), do: "child_timed_out"
  defp classification_reason_code("child_failure"), do: "child_failed"
  defp classification_reason_code("child_cancelled"), do: "cancelled"
  defp classification_reason_code("partial_terminal_mix"), do: "partial"
  defp classification_reason_code(classification), do: classification

  defp error_kind?(payload, kind) do
    Enum.any?(payload["errors"] || [], &(&1["kind"] == kind))
  end

  defp put_children_envelope_v1(%{"children" => children} = payload) when is_list(children) do
    Map.put(payload, "children", Enum.map(children, fn child -> put_child_envelope_v1(child) end))
  end

  defp put_children_envelope_v1(payload), do: payload

  defp put_output_warning_envelope(payload) do
    raw_children = Map.get(payload, "children", [])

    children =
      if is_list(raw_children),
        do: Enum.map(raw_children, &normalize_child_warning_fields/1),
        else: raw_children

    if is_list(children) do
      indexed =
        children
        |> Enum.with_index()
        |> Enum.sort_by(&indexed_child_order/1)

      ordered_children = Enum.map(indexed, &elem(&1, 0))

      positive_children =
        Enum.filter(indexed, fn {child, _position} ->
          is_list(child["output_warnings"]) and child["output_warnings"] != []
        end)

      truncated_children =
        positive_children
        |> Enum.map(fn {child, _position} -> child["child_session_id"] end)
        |> Enum.filter(&is_binary/1)
        |> Enum.uniq()

      all_warnings =
        positive_children
        |> Enum.flat_map(fn {child, position} ->
          child_order = indexed_child_order({child, position})

          Enum.map(child["output_warnings"] || [], fn warning ->
            {child_order, child["child_session_id"] || "", warning}
          end)
        end)
        |> Enum.uniq_by(fn {_order, child_sid, warning} ->
          {child_sid, warning["provider_usage_event_id"]}
        end)
        |> Enum.sort_by(fn {child_order, child_sid, warning} ->
          {child_order, child_sid, warning["provider_usage_seq"] || 0,
           warning["provider_usage_event_id"] || ""}
        end)
        |> Enum.map(fn {_order, _child_sid, warning} -> warning end)

      warning_count = authoritative_warning_count(positive_children)
      warnings = Enum.take(all_warnings, 256)

      payload
      |> maybe_put_normalized_children(ordered_children)
      |> Map.put("truncated_child_count", length(truncated_children))
      |> Map.put("truncated_children", Enum.take(truncated_children, 256))
      |> Map.put("truncated_children_truncated", length(truncated_children) > 256)
      |> Map.put("warning_count", warning_count)
      |> Map.put("warnings", warnings)
      |> Map.put("warnings_truncated", warning_count > length(warnings))
    else
      payload
    end
  end

  defp normalize_child_warning_fields(child) when is_map(child) do
    if Enum.any?(
         ~w(output_truncation output_warning_count output_warnings output_warning_reasons output_warnings_truncated),
         &Map.has_key?(child, &1)
       ) do
      normalized = OutputTruncationSummary.normalize_child_output(child)

      child
      |> Map.put("output_truncation", normalized["output_truncation"])
      |> Map.put("output_warning_count", normalized["output_warning_count"])
      |> Map.put("output_warnings", normalized["output_warnings"])
      |> Map.put("output_warning_reasons", normalized["output_warning_reasons"])
      |> Map.put("output_warnings_truncated", normalized["output_warnings_truncated"])
    else
      child
    end
  end

  defp normalize_child_warning_fields(child), do: child

  defp indexed_child_order({child, position}) do
    case child["index"] do
      index when is_integer(index) and index >= 0 ->
        {0, index, child["child_session_id"] || "", position}

      _invalid_or_missing ->
        {1, position, "", position}
    end
  end

  defp authoritative_warning_count(indexed_children) do
    indexed_children
    |> Enum.group_by(fn {child, _position} -> child["child_session_id"] end)
    |> Enum.reduce(0, fn {_child_sid, group}, total ->
      claimed =
        group
        |> Enum.map(fn {child, _position} -> child["output_warning_count"] end)
        |> Enum.filter(&(is_integer(&1) and &1 >= 0))
        |> Enum.max(fn -> 0 end)

      distinct =
        group
        |> Enum.flat_map(fn {child, _position} -> child["output_warnings"] end)
        |> Enum.uniq_by(& &1["provider_usage_event_id"])
        |> length()

      total + max(claimed, distinct)
    end)
  end

  defp maybe_put_normalized_children(payload, children) do
    if Map.has_key?(payload, "children"),
      do: Map.put(payload, "children", children),
      else: payload
  end

  defp put_child_envelope_v1(%{} = child) do
    child
    |> Map.put_new("outcome", child_status(child))
    |> Map.put_new("reason_code", child_reason_code(child))
  end

  defp put_child_envelope_v1(child), do: child

  defp child_status(child), do: child["status"] || "unknown"

  defp child_reason_code(%{"status" => "completed"}), do: "completed"
  defp child_reason_code(%{"status" => "running"}), do: "work_still_running"
  defp child_reason_code(%{"status" => "queued"}), do: "queued"
  defp child_reason_code(%{"status" => "failed"}), do: "child_failed"
  defp child_reason_code(%{"status" => "timed_out"}), do: "child_timed_out"
  defp child_reason_code(%{"status" => "cancelled"}), do: "cancelled"
  defp child_reason_code(%{"status" => status}) when is_binary(status), do: status
  defp child_reason_code(_child), do: "unknown"

  defp invalid_args(message, details), do: error_payload("invalid_args", message, details)
  defp invalid_json(message, details), do: error_payload("invalid_json", message, details)

  defp rehearse_workflow_contract(spec, mode, workspace, runtime_opts, policy) do
    opts = Keyword.put(runtime_opts, :workspace, workspace)
    opts = if is_nil(policy), do: opts, else: Keyword.put(opts, :write_policy, policy)

    case Runner.rehearse_workflow_spec(spec, mode, opts) do
      {:ok, _plan} ->
        :ok

      {:error, %{"message" => message, "details" => details}} when is_map(details) ->
        {:error,
         invalid_spec(
           message,
           Map.put_new(details, "next_actions", ["fix_workflow_dependency_graph"])
         )}

      {:error, %{"message" => message}} ->
        {:error, invalid_spec(message, %{"next_actions" => ["fix_workflow_dependency_graph"]})}

      {:error, error} ->
        {:error,
         invalid_spec("delegate workflow spec is invalid", %{
           "error" => inspect(error),
           "next_actions" => ["fix_workflow_dependency_graph"]
         })}
    end
  end

  defp invalid_spec(message, details), do: error_payload("invalid_spec", message, details)

  defp unsupported_mode(mode) do
    error_payload("unsupported_mode", "delegate spec mode is unsupported", %{
      "observed" => mode,
      "accepted_values" => ["read_only", "bounded_write"],
      "next_actions" => ["set_mode_to_read_only_or_bounded_write"]
    })
    |> Map.put("status", "unsupported")
  end

  defp write_policy_error(%{error: %{kind: kind, message: message, details: details}}) do
    error_payload(to_string(kind), message, stringify_keys(details))
  end

  defp merge_error_details(error, extra) do
    Map.update(error, "details", extra, &Map.merge(&1, extra))
  end

  defp unsupported_subcommand(subcommand) do
    error_payload(
      "unsupported_subcommand",
      "delegate subcommand is reserved but not implemented in this slice",
      %{
        "subcommand" => subcommand,
        "reserved_subcommands" => @reserved_subcommands,
        "supported_subcommands_now" => ["start", "status", "attach", "cancel", "daemon"],
        "next_actions" => [
          "use_delegate_status_attach_or_cancel_for_existing_sessions",
          "use_attached_delegate_for_execution",
          "implement_TODO_delegate_async"
        ]
      }
    )
    |> Map.put("status", "unsupported")
  end

  defp unsupported_contract_version(version, extra) do
    details =
      Map.merge(extra, %{
        "observed" => version,
        "supported" => [@contract_version],
        "next_actions" => ["set_contract_version_to_1"]
      })

    error_payload(
      "unsupported_contract_version",
      "delegate contract version is unsupported",
      details
    )
    |> Map.put("status", "unsupported")
  end

  defp unsupported_attached_progress(progress) do
    error_payload(
      "invalid_args",
      "attached delegate --progress is not supported yet",
      %{
        "mode" => progress,
        "scope" => "attached_delegate",
        "supported_progress_now" => ["pixir delegate attach <handle> --progress=stderr-jsonl"],
        "stdout_contract" => "one_final_json_envelope",
        "next_actions" => [
          "remove_--progress_for_attached_delegate",
          "use_delegate_start_then_attach_--progress_when_a_daemon_owner_is_available",
          "implement_TODO_delegate_progress_for_attached_runs"
        ]
      }
    )
  end

  defp error_payload(kind, message, details) do
    %{
      "ok" => false,
      "status" => "rejected",
      "kind" => kind,
      "message" => message,
      "details" => details
    }
  end

  defp exit_code(%{"status" => "unsupported"}), do: 2

  defp exit_code(%{"kind" => kind}) when kind in ["invalid_args", "invalid_json", "invalid_spec"],
    do: 2

  defp exit_code(%{"kind" => "spec_read_failed"}), do: 2
  defp exit_code(%{"kind" => "stdin_error"}), do: 2
  defp exit_code(%{"kind" => "not_found"}), do: 2
  defp exit_code(%{"kind" => "write_policy_denied"}), do: 3
  defp exit_code(%{"kind" => "bash_disabled"}), do: 3
  defp exit_code(%{"kind" => "manager_unavailable"}), do: 5
  defp exit_code(%{"kind" => "timeout"}), do: 5
  defp exit_code(%{"kind" => "daemon_required"}), do: 5
  defp exit_code(_payload), do: 1

  defp runtime_exit_code(%{"status" => "unsupported"}, _request), do: 2

  defp runtime_exit_code(%{"kind" => "delegate_start", "status" => status}, _request)
       when status in ["accepted", "running"],
       do: 0

  defp runtime_exit_code(%{"kind" => kind}, _request)
       when kind in ["invalid_args", "invalid_json", "invalid_spec", "unsupported_mode"],
       do: 2

  defp runtime_exit_code(%{"kind" => kind}, _request)
       when kind in [
              "permission_denied",
              "outside_workspace",
              "write_policy_denied",
              "bash_disabled"
            ],
       do: 3

  defp runtime_exit_code(%{"kind" => kind}, _request)
       when kind in ["not_authenticated", "provider_http_error", "network"],
       do: 4

  defp runtime_exit_code(%{"kind" => kind}, _request) when kind in ["timeout", "backpressure"],
    do: 5

  defp runtime_exit_code(%{"status" => status}, _request)
       when status in @incomplete_terminal_statuses,
       do: 6

  defp runtime_exit_code(%{"status" => status}, _request)
       when status in ["completed", "queued", "running"],
       do: 0

  defp runtime_exit_code(_payload, _request), do: 1

  defp subcommand_exit_code("cancel", %{"ok" => true}, _request), do: 0

  defp subcommand_exit_code(_subcommand, payload, request),
    do: runtime_exit_code(payload, request)

  defp human_success(payload) do
    "delegate dry-run accepted: strategy #{payload["strategy"]}; no runtime executed"
  end

  defp human_runtime(payload) do
    "delegate #{payload["strategy"]} #{payload["status"]}: #{payload["summary"]}"
  end

  defp human_async(payload) do
    payload["summary"] || "delegate #{payload["kind"] || "command"} #{payload["status"]}"
  end

  defp usage do
    "pixir delegate --spec <path|-> [--dry-run] [--json] [--contract-version 1] [--timeout-ms N]\n" <>
      "pixir delegate start --spec <path|-> [--json] [--contract-version 1] [--timeout-ms N]\n" <>
      "pixir delegate status <delegate_id|parent_session_id> [--json] [--contract-version 1]\n" <>
      "pixir delegate attach <delegate_id|parent_session_id> [--json] [--contract-version 1] [--progress=stderr-jsonl] [--wait-horizon-ms N]\n" <>
      "pixir delegate cancel <delegate_id|parent_session_id> [--json] [--contract-version 1]\n" <>
      "pixir delegate daemon --foreground|--status|--stop [--json] [--contract-version 1]"
  end

  defp parse_positive_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} when integer > 0 -> {:ok, integer}
      _ -> :error
    end
  end

  defp parse_positive_integer(_value), do: :error

  defp non_empty_string?(value), do: is_binary(value) and String.trim(value) != ""
  defp non_empty_list?(value), do: is_list(value) and value != []

  defp json_type(value) when is_list(value), do: "array"
  defp json_type(value) when is_binary(value), do: "string"
  defp json_type(value) when is_number(value), do: "number"
  defp json_type(value) when is_boolean(value), do: "boolean"
  defp json_type(nil), do: "null"
  defp json_type(value) when is_map(value), do: "object"

  defp put_if_present(map, _key, nil), do: map
  defp put_if_present(map, key, value), do: Map.put(map, key, value)

  defp stringify_keys(%{} = map) do
    Map.new(map, fn {key, value} -> {to_string(key), stringify_keys(value)} end)
  end

  defp stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)
  defp stringify_keys(value), do: value
end
