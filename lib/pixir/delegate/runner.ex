defmodule Pixir.Delegate.Runner do
  @moduledoc """
  Attached runtime runner for `pixir delegate`.

  This module is the first real implementation behind the Delegate CLI I/O Contract.
  It keeps `Pixir.Delegate.CLIContract` focused on parsing/rendering and uses existing
  Pixir runtime surfaces for work:

    * parent Session creation goes through `Pixir.Conversation`;
    * Subagent fanout goes through `Pixir.Subagents`;
    * read-only and bounded-write Workflow fanout goes through `Pixir.Workflows`;
    * terminal status comes from `wait_outcome/4` or the Workflow result envelope;
    * durable truth remains the parent and child Session Logs plus Workflow Events.

  It also exposes a start-only primitive for the current-runtime Delegate owner. It
  deliberately does not implement streaming attach, cross-invocation daemon residency,
  merge-back/apply, or any process-per-child shell fanout. Bounded-write Workflow support
  is attached-only, requires explicit per-step write sets, and reports where writes land.

  Delegate task attachments are operator-supplied Session Resource links under ADR 0021;
  they are consumed by each child Session's first user message and are not echoed in
  the delegate envelope.

  ## TODO(delegate-service-v1)

  Keep the attached runner as the synchronous compatibility path. The service owner
  reuses the same normalization and start vocabulary, but owns current-runtime lifetime
  and active cancellation in OTP. Avoid adding caller-side loops here that would make
  `pixir delegate --spec` pretend to be a detached daemon.
  """

  alias Pixir.{Config, Conversation, Log, RecoveryCommands, Subagents, Workflows}
  alias Pixir.Delegate.{Evidence, Handle, Owner}
  alias Pixir.Permissions.WritePolicy
  alias Pixir.Tools.Workspace

  @supported_modes [nil, "read_only", "bounded_write"]
  @supported_transports ["auto", "websocket", "http_sse"]
  @incomplete_statuses ~w(partial timed_out failed cancelled)
  @guided_resume_statuses ~w(failed timed_out cancelled detached closed)
  @websocket_transport_error_kinds ~w(
    websocket_read_failed websocket_failed websocket_closed websocket_timeout
  )
  @in_band_transport_error_kinds ~w(
    service_unavailable_error server_is_overloaded overloaded server_error
  )

  @doc "Run a validated Delegate spec through the attached runtime path."
  @spec run(map(), map(), map(), keyword()) :: {:ok, map()} | {:error, map()}
  def run(request, spec, spec_meta, opts \\ [])

  def run(request, spec, %{"strategy" => "subagents"} = spec_meta, opts) do
    with {:ok, runtime} <- normalize_subagents_runtime(request, spec, spec_meta),
         {:ok, parent_session_id} <- start_parent_session(runtime.workspace) do
      refresh_lifecycle_evidence(parent_session_id, runtime, [])

      case spawn_subagents(parent_session_id, runtime, opts) do
        {:ok, agents} ->
          refresh_lifecycle_evidence(parent_session_id, runtime, agents)

          with {:ok, outcome} <- wait_for_agents(parent_session_id, runtime, agents, opts) do
            {:ok,
             result_payload(parent_session_id, runtime, agents, outcome)
             |> refresh_evidence_payload()}
          end

        {:partial, agents, spawn_error} ->
          refresh_lifecycle_evidence(parent_session_id, runtime, agents)

          {:ok,
           partial_spawn_payload(parent_session_id, runtime, agents, spawn_error, opts)
           |> refresh_evidence_payload()}

        {:error, error} ->
          {:error, normalize_error(error)}
      end
    else
      {:error, error} -> {:error, normalize_error(error)}
    end
  end

  def run(request, spec, %{"strategy" => "workflow"} = spec_meta, opts) do
    with {:ok, runtime} <- normalize_workflow_runtime(request, spec, spec_meta),
         {:ok, parent_session_id} <- start_parent_session(runtime.workspace),
         {:ok, result} <- run_workflow(parent_session_id, runtime, opts) do
      {:ok,
       workflow_result_payload(parent_session_id, runtime, result)
       |> refresh_evidence_payload()}
    else
      {:error, error} -> {:error, normalize_error(error)}
    end
  end

  @doc false
  @spec rehearse_workflow_spec(map(), String.t() | nil, keyword()) ::
          {:ok, map()} | {:error, map()}
  def rehearse_workflow_spec(spec, mode, opts \\ []) when is_map(spec) do
    with {:ok, workflow_spec} <- normalize_workflow_spec(spec, mode),
         {:ok, plan} <- Workflows.dry_run(workflow_spec, opts) do
      {:ok, plan}
    else
      {:error, error} -> {:error, normalize_error(error)}
    end
  end

  @doc """
  Start a validated subagents Delegate spec without waiting for terminal completion.

  This is the runtime primitive used by the current-BEAM Delegate owner. It creates the
  durable parent Session, spawns child Subagents through the normal Manager, and returns
  start evidence plus owner context. It does not start a daemon or a nested Pixir
  process.
  """
  @spec start(map(), map(), map(), keyword()) :: {:ok, map()} | {:error, map()}
  def start(request, spec, spec_meta, opts \\ [])

  def start(request, spec, %{"strategy" => "subagents"} = spec_meta, opts) do
    with {:ok, runtime} <- normalize_subagents_runtime(request, spec, spec_meta),
         {:ok, parent_session_id} <- start_parent_session(runtime.workspace) do
      refresh_lifecycle_evidence(parent_session_id, runtime, [])

      case spawn_subagents(parent_session_id, runtime, opts) do
        {:ok, agents} ->
          refresh_lifecycle_evidence(parent_session_id, runtime, agents)
          {:ok, start_context(parent_session_id, runtime, agents, nil)}

        {:partial, agents, spawn_error} ->
          refresh_lifecycle_evidence(parent_session_id, runtime, agents)
          {:ok, start_context(parent_session_id, runtime, agents, spawn_error)}

        {:error, error} ->
          {:error, normalize_error(error)}
      end
    else
      {:error, error} -> {:error, normalize_error(error)}
    end
  end

  def start(_request, _spec, %{"strategy" => "workflow"}, _opts) do
    {:error,
     error_payload(
       "unsupported_runtime_path",
       "delegate workflow service runtime is not implemented yet",
       %{
         "strategy" => "workflow",
         "supported_now" => ["strategy:subagents", "--dry-run"],
         "next_actions" => [
           "rerun_with_strategy_subagents",
           "rerun_workflow_specs_with_--dry-run",
           "implement_delegate_workflow_runtime"
         ]
       }
     )
     |> Map.put("status", "unsupported")}
  end

  defp normalize_subagents_runtime(request, spec, spec_meta) do
    with {:ok, workspace} <- normalize_workspace(spec, request.workspace),
         {:ok, mode} <- normalize_mode(Map.get(spec, "mode")),
         {:ok, write_policy} <- normalize_write_policy(spec, mode),
         {:ok, tasks} <- normalize_tasks(spec, workspace),
         {:ok, timeouts} <- normalize_timeouts(request, spec),
         {:ok, max_threads} <- normalize_positive_integer(spec, ["subagents", "max_threads"]),
         {:ok, max_depth} <- normalize_non_negative_integer(spec, ["subagents", "max_depth"]),
         {:ok, provider_transport} <- normalize_provider_transport(spec),
         {:ok, provider_model} <- normalize_provider_model(spec),
         {:ok, reasoning_effort} <- normalize_reasoning_effort(spec),
         {:ok, web_search} <- normalize_web_search(spec),
         {:ok, workspace_mode} <- normalize_workspace_mode(spec),
         {:ok, virtual_overlay} <- normalize_virtual_overlay(spec, workspace_mode, mode),
         {:ok, agent} <- normalize_agent(spec),
         :ok <- ensure_child_count(tasks, spec_meta) do
      {:ok,
       %{
         workspace: workspace,
         mode: mode,
         write_policy: write_policy,
         tasks: tasks,
         timeout_ms: timeouts.legacy_timeout_ms,
         delegate_timeout_ms: timeouts.delegate_timeout_ms,
         child_timeout_ms: timeouts.child_timeout_ms,
         wait_horizon_ms: timeouts.wait_horizon_ms,
         max_threads: max_threads,
         max_depth: max_depth,
         provider_transport: provider_transport,
         provider_model: provider_model,
         reasoning_effort: reasoning_effort,
         web_search: web_search,
         workspace_mode: workspace_mode,
         virtual_overlay: virtual_overlay,
         agent: agent,
         planned_child_count: length(tasks)
       }}
    end
  end

  defp normalize_workspace(spec, default_workspace) do
    workspace_value = Map.get(spec, "workspace") || default_workspace

    if is_binary(workspace_value) and is_binary(default_workspace) do
      caller_workspace = Path.expand(default_workspace)
      workspace = Path.expand(workspace_value, caller_workspace)

      with :ok <- ensure_workspace_confined(workspace, caller_workspace),
           :ok <- ensure_workspace_directory(workspace) do
        {:ok, workspace}
      end
    else
      {:error,
       error_payload("invalid_spec", "delegate workspace must be a string path", %{
         "observed" => inspect(workspace_value),
         "next_actions" => ["remove_workspace_or_set_it_to_a_string_path"]
       })}
    end
  end

  defp ensure_workspace_confined(workspace, caller_workspace) do
    case Workspace.confine(caller_workspace, workspace) do
      {:ok, ^workspace} ->
        :ok

      {:ok, confined} ->
        {:error,
         error_payload("invalid_spec", "delegate workspace must stay inside caller workspace", %{
           "workspace" => workspace,
           "caller_workspace" => caller_workspace,
           "confined_workspace" => confined,
           "next_actions" => [
             "run_pixir_delegate_from_the_target_workspace",
             "remove_spec_workspace_escape"
           ]
         })}

      {:error, _error} ->
        {:error,
         error_payload("invalid_spec", "delegate workspace must stay inside caller workspace", %{
           "workspace" => workspace,
           "caller_workspace" => caller_workspace,
           "next_actions" => [
             "run_pixir_delegate_from_the_target_workspace",
             "remove_spec_workspace_escape"
           ]
         })}
    end
  end

  defp ensure_workspace_directory(workspace) do
    if File.dir?(workspace) do
      :ok
    else
      {:error,
       error_payload("invalid_spec", "delegate workspace must be an existing directory", %{
         "workspace" => workspace,
         "next_actions" => [
           "set_workspace_to_an_existing_directory",
           "run_from_the_target_workspace"
         ]
       })}
    end
  end

  defp normalize_mode(mode) when mode in @supported_modes, do: {:ok, mode || "read_only"}

  defp normalize_mode(mode) do
    {:error,
     error_payload("unsupported_mode", "delegate runtime mode is unsupported", %{
       "observed" => mode,
       "accepted_values" => ["read_only", "bounded_write"],
       "next_actions" => ["set_mode_to_read_only_or_bounded_write"]
     })
     |> Map.put("status", "unsupported")}
  end

  defp normalize_write_policy(%{"write_policy" => raw_policy}, "bounded_write") do
    case WritePolicy.normalize(raw_policy) do
      {:ok, policy} ->
        {:ok, policy}

      {:error, error} ->
        {:error, normalize_error(error)}
    end
  end

  defp normalize_write_policy(_spec, "bounded_write") do
    {:error,
     error_payload("invalid_spec", "bounded_write delegate mode requires write_policy", %{
       "missing" => ["write_policy"],
       "next_actions" => ["add_write_policy_or_use_read_only_mode"]
     })}
  end

  defp normalize_write_policy(%{"write_policy" => _raw_policy}, _mode) do
    {:error,
     error_payload("invalid_spec", "write_policy requires mode bounded_write", %{
       "next_actions" => ["set_mode_to_bounded_write", "remove_write_policy"]
     })}
  end

  defp normalize_write_policy(_spec, _mode), do: {:ok, nil}

  defp normalize_tasks(%{"tasks" => tasks}, workspace) when is_list(tasks) do
    cond do
      tasks == [] ->
        {:error, invalid_tasks()}

      true ->
        tasks
        |> Enum.with_index()
        |> Enum.reduce_while({:ok, []}, fn {entry, index}, {:ok, acc} ->
          case normalize_task_entry(entry, index, workspace) do
            {:ok, task} -> {:cont, {:ok, [task | acc]}}
            {:error, error} -> {:halt, {:error, error}}
          end
        end)
        |> case do
          {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
          {:error, _} = error -> error
        end
    end
  end

  defp normalize_tasks(%{"task" => task} = spec, _workspace) when is_binary(task) do
    count = get_in(spec, ["subagents", "count"]) || 1
    task = String.trim(task)

    cond do
      task == "" ->
        {:error, invalid_tasks()}

      is_integer(count) and count > 0 ->
        {:ok, List.duplicate(String.trim(task), count)}

      true ->
        {:error,
         error_payload("invalid_spec", "subagents.count must be a positive integer", %{
           "observed" => inspect(count),
           "next_actions" => ["set_subagents_count_to_a_positive_integer"]
         })}
    end
  end

  defp normalize_tasks(_spec, _workspace), do: {:error, invalid_tasks()}

  defp normalize_task_entry(task, index, _workspace) when is_binary(task) do
    task = String.trim(task)

    if task == "" do
      {:error, invalid_task_entry(index)}
    else
      {:ok, %{task: task, index: index, attachments: []}}
    end
  end

  defp normalize_task_entry(%{} = entry, index, workspace) do
    with :ok <- reject_unknown_task_entry_keys(entry, index),
         {:ok, task} <- normalize_task_text(Map.get(entry, "task"), index),
         {:ok, attachments} <-
           normalize_task_attachments(Map.get(entry, "attachments", []), index, workspace) do
      {:ok, %{task: task, index: index, attachments: attachments}}
    end
  end

  defp normalize_task_entry(_entry, index, _workspace), do: {:error, invalid_task_entry(index)}

  defp normalize_task_text(task, index) when is_binary(task) do
    task = String.trim(task)
    if task == "", do: {:error, invalid_task_entry(index)}, else: {:ok, task}
  end

  defp normalize_task_text(_task, index), do: {:error, invalid_task_entry(index)}

  defp reject_unknown_task_entry_keys(entry, index) do
    allowed = MapSet.new(["task", "attachments"])

    case Enum.find(Map.keys(entry), &(not MapSet.member?(allowed, &1))) do
      nil ->
        :ok

      key ->
        {:error,
         task_entry_error(
           index,
           "delegate tasks entries may only include task and attachments",
           %{
             "unknown_key" => key,
             "accepted_keys" => ["task", "attachments"],
             "next_actions" => ["remove_unknown_field", "check_delegate_spec_contract"]
           }
         )}
    end
  end

  defp normalize_task_attachments(nil, index, _workspace) do
    {:error,
     task_entry_error(index, "delegate task attachments must be a list of paths", %{
       "field" => "tasks[#{index + 1}].attachments",
       "json_pointer" => "/tasks/#{index}/attachments",
       "path" => ["tasks", index, "attachments"],
       "task_index" => index,
       "next_actions" => ["set_attachments_to_a_list_of_paths_or_file_uris"]
     })}
  end

  defp normalize_task_attachments(attachments, index, workspace) when is_list(attachments) do
    attachments
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {attachment, attachment_index}, {:ok, acc} ->
      case normalize_task_attachment(attachment, index, attachment_index, workspace) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      {:error, _} = error -> error
    end
  end

  defp normalize_task_attachments(_attachments, index, _workspace) do
    {:error,
     task_entry_error(index, "delegate task attachments must be a list of paths", %{
       "field" => "tasks[#{index + 1}].attachments",
       "json_pointer" => "/tasks/#{index}/attachments",
       "path" => ["tasks", index, "attachments"],
       "task_index" => index,
       "next_actions" => ["set_attachments_to_a_list_of_paths_or_file_uris"]
     })}
  end

  defp normalize_task_attachment(path, task_index, attachment_index, workspace)
       when is_binary(path) do
    case Pixir.SessionResources.local_attachment_link(path, workspace) do
      {:ok, attachment} -> {:ok, attachment}
      {:error, :remote_uri} -> invalid_file_uri_attachment(task_index, attachment_index)
      {:error, _reason} -> invalid_task_attachment(task_index, attachment_index)
    end
  end

  defp normalize_task_attachment(_path, task_index, attachment_index, _workspace),
    do: invalid_task_attachment(task_index, attachment_index)

  @doc false
  # Delegates to the canonical local file:// acceptance rule, now owned by
  # Pixir.SessionResources (ADR 0021) and shared with the Workflow step
  # attachment surface; kept public here for the dry-run contract callers.
  @spec local_file_uri?(String.t()) :: boolean()
  def local_file_uri?(uri) when is_binary(uri),
    do: Pixir.SessionResources.local_file_uri?(uri)

  defp invalid_file_uri_attachment(task_index, attachment_index) do
    {:error,
     task_entry_error(task_index, "delegate task file URI is invalid", %{
       "field" => "tasks[#{task_index + 1}].attachments[#{attachment_index + 1}]",
       "json_pointer" => "/tasks/#{task_index}/attachments/#{attachment_index}",
       "path" => ["tasks", task_index, "attachments", attachment_index],
       "task_index" => task_index,
       "attachment_index" => attachment_index,
       "next_actions" => ["replace_attachment_with_a_file_uri_path_or_filesystem_path"]
     })}
  end

  defp invalid_task_attachment(task_index, attachment_index) do
    {:error,
     task_entry_error(task_index, "delegate task attachments must be non-empty strings", %{
       "field" => "tasks[#{task_index + 1}].attachments[#{attachment_index + 1}]",
       "json_pointer" => "/tasks/#{task_index}/attachments/#{attachment_index}",
       "path" => ["tasks", task_index, "attachments", attachment_index],
       "task_index" => task_index,
       "attachment_index" => attachment_index,
       "next_actions" => ["replace_attachment_with_a_non_empty_path_or_file_uri"]
     })}
  end

  defp invalid_task_entry(index) do
    task_entry_error(
      index,
      "subagents.tasks entries must be non-empty task strings or task objects",
      %{
        "next_actions" => ["fix_subagents_tasks_entries"]
      }
    )
  end

  defp task_entry_error(index, message, details) do
    base = %{
      "field" => "tasks[#{index + 1}]",
      "json_pointer" => "/tasks/#{index}",
      "path" => ["tasks", index],
      "task_index" => index
    }

    error_payload("invalid_spec", message, Map.merge(base, details))
  end

  defp task_text(%{task: task}) when is_binary(task), do: task
  defp task_text(task) when is_binary(task), do: task

  defp task_index(%{index: index}) when is_integer(index), do: index
  defp task_index(_task), do: nil

  defp task_attachments(%{attachments: attachments}) when is_list(attachments), do: attachments
  defp task_attachments(_task), do: []

  defp invalid_tasks do
    error_payload("invalid_spec", "subagents delegate spec requires non-empty task text", %{
      "missing_any_of" => ["task", "tasks"],
      "next_actions" => ["add_task_for_one_child", "add_tasks_for_fanout"]
    })
  end

  defp normalize_timeouts(request, spec) do
    default_timeout_ms = Subagents.default_limits().timeout_ms

    with {:ok, legacy_timeout_ms} <-
           normalize_timeout_candidate(
             [
               request_timeout_candidate(request),
               timeout_candidate(spec, ["limits", "timeout_ms"]),
               timeout_candidate(spec, ["timeout_ms"])
             ],
             default_timeout_ms,
             "limits.timeout_ms"
           ),
         {:ok, delegate_timeout_ms} <-
           normalize_timeout_candidate(
             [timeout_candidate(spec, ["limits", "delegate_timeout_ms"])],
             legacy_timeout_ms,
             "limits.delegate_timeout_ms"
           ),
         {:ok, child_timeout_ms} <-
           normalize_timeout_candidate(
             [
               timeout_candidate(spec, ["limits", "child_timeout_ms"]),
               timeout_candidate(spec, ["subagents", "timeout_ms"])
             ],
             legacy_timeout_ms,
             "limits.child_timeout_ms"
           ),
         {:ok, wait_horizon_ms} <-
           normalize_timeout_candidate(
             [
               request_wait_horizon_candidate(request),
               timeout_candidate(spec, ["limits", "wait_horizon_ms"])
             ],
             delegate_timeout_ms,
             "limits.wait_horizon_ms"
           ) do
      {:ok,
       %{
         legacy_timeout_ms: legacy_timeout_ms,
         delegate_timeout_ms: delegate_timeout_ms,
         child_timeout_ms: child_timeout_ms,
         wait_horizon_ms: wait_horizon_ms
       }}
    end
  end

  defp request_timeout_candidate(%{timeout_ms: timeout_ms}),
    do: {timeout_ms, "request.timeout_ms"}

  defp request_timeout_candidate(_request), do: nil

  defp request_wait_horizon_candidate(%{wait_horizon_ms: wait_horizon_ms}),
    do: {wait_horizon_ms, "request.wait_horizon_ms"}

  defp request_wait_horizon_candidate(_request), do: nil

  defp timeout_candidate(spec, path) do
    case get_in(spec, path) do
      nil -> nil
      value -> {value, Enum.join(path, ".")}
    end
  end

  defp normalize_timeout_candidate(candidates, default_value, default_field) do
    candidates
    |> Enum.find(fn
      {nil, _field} -> false
      nil -> false
      {_value, _field} -> true
    end)
    |> case do
      nil -> normalize_timeout_value(default_value, default_field)
      {value, field} -> normalize_timeout_value(value, field)
    end
  end

  defp normalize_timeout_value(value, _field) when is_integer(value) and value > 0,
    do: {:ok, value}

  defp normalize_timeout_value(value, field) do
    {:error,
     error_payload("invalid_spec", "#{field} must be a positive integer", %{
       "field" => field,
       "observed" => inspect(value),
       "next_actions" => ["set_#{String.replace(field, ".", "_")}_to_a_positive_integer"]
     })}
  end

  defp normalize_positive_integer(spec, path) do
    value = get_in(spec, path)

    cond do
      is_nil(value) -> {:ok, Subagents.default_limits().max_threads}
      is_integer(value) and value > 0 -> {:ok, value}
      true -> {:error, integer_error(path, value, "positive")}
    end
  end

  defp normalize_non_negative_integer(spec, path) do
    value = get_in(spec, path)

    cond do
      is_nil(value) -> {:ok, Subagents.default_limits().max_depth}
      is_integer(value) and value >= 0 -> {:ok, value}
      true -> {:error, integer_error(path, value, "non_negative")}
    end
  end

  defp normalize_provider_model(spec) do
    case get_in(spec, ["subagents", "model"]) do
      nil -> {:ok, nil}
      model when is_binary(model) -> {:ok, model}
      value -> {:error, invalid_subagent_provider_knob("model", value, nil)}
    end
  end

  defp normalize_reasoning_effort(spec) do
    case get_in(spec, ["subagents", "reasoning_effort"]) do
      nil ->
        {:ok, nil}

      effort when is_binary(effort) ->
        if effort in Config.valid_reasoning_efforts() do
          {:ok, effort}
        else
          {:error,
           invalid_subagent_provider_knob(
             "reasoning_effort",
             effort,
             Config.valid_reasoning_efforts()
           )}
        end

      value ->
        {:error,
         invalid_subagent_provider_knob(
           "reasoning_effort",
           value,
           Config.valid_reasoning_efforts()
         )}
    end
  end

  # Shape validation lives in the spec contract (cli_contract) and the spawn
  # seam (Manager); the runner only refuses values neither of those would take.
  defp normalize_web_search(spec) do
    case get_in(spec, ["subagents", "web_search"]) do
      nil -> {:ok, nil}
      true -> {:ok, true}
      %{} = web_search -> {:ok, web_search}
      value -> {:error, invalid_subagent_provider_knob("web_search", value, [true, "object"])}
    end
  end

  defp invalid_subagent_provider_knob(field, value, nil) do
    error_payload("invalid_spec", "subagents.#{field} has an invalid value", %{
      "field" => "subagents.#{field}",
      "json_pointer" => "/subagents/#{field}",
      "path" => ["subagents", field],
      "observed" => value,
      "next_actions" => ["set_subagents_#{field}_to_a_valid_value"]
    })
  end

  defp invalid_subagent_provider_knob(field, value, accepted_values) do
    error_payload("invalid_spec", "subagents.#{field} has an unsupported value", %{
      "field" => "subagents.#{field}",
      "json_pointer" => "/subagents/#{field}",
      "path" => ["subagents", field],
      "observed" => value,
      "accepted_values" => accepted_values,
      "next_actions" => ["set_subagents_#{field}_to_an_accepted_value"]
    })
  end

  defp integer_error(path, value, kind) do
    field = Enum.join(path, ".")

    error_payload("invalid_spec", "#{field} must be #{kind} integer", %{
      "field" => field,
      "observed" => inspect(value),
      "next_actions" => ["fix_#{String.replace(field, ".", "_")}"]
    })
  end

  defp normalize_provider_transport(spec) do
    {value, path} = provider_transport_candidate(spec)

    cond do
      is_nil(value) ->
        {:ok, nil}

      value in @supported_transports ->
        {:ok, value}

      true ->
        {:error, provider_transport_error(path, value)}
    end
  end

  defp provider_transport_candidate(spec) do
    cond do
      not is_nil(get_in(spec, ["subagents", "transport"])) ->
        {get_in(spec, ["subagents", "transport"]), ["subagents", "transport"]}

      not is_nil(Map.get(spec, "transport")) ->
        {Map.get(spec, "transport"), ["transport"]}

      true ->
        {nil, ["transport"]}
    end
  end

  defp provider_transport_error(path, value) do
    field = Enum.join(path, ".")

    error_payload("invalid_spec", "#{field} must be supported transport", %{
      "field" => field,
      "observed" => inspect(value),
      "accepted_values" => @supported_transports,
      "next_actions" => ["fix_#{String.replace(field, ".", "_")}"]
    })
  end

  defp with_provider_transport(opts, nil), do: opts

  defp with_provider_transport(opts, transport),
    do: Keyword.put(opts, :provider_transport, transport)

  defp normalize_workspace_mode(spec) do
    value =
      Map.get(spec, "workspace_mode") ||
        get_in(spec, ["subagents", "workspace_mode"]) ||
        "shared"

    if value in ["shared", "isolated", "virtual_overlay"] do
      {:ok, value}
    else
      {:error,
       error_payload("invalid_spec", "subagents workspace_mode is unsupported", %{
         "observed" => value,
         "accepted_values" => ["shared", "isolated", "virtual_overlay"],
         "next_actions" => ["set_workspace_mode_to_shared_isolated_or_virtual_overlay"]
       })}
    end
  end

  defp normalize_virtual_overlay(spec, "virtual_overlay", mode) do
    subagents = Map.get(spec, "subagents", %{})
    read_set = Map.get(subagents, "read_set")
    limits = Map.get(subagents, "limits", %{})
    read_set_validation = Pixir.VirtualOverlay.validate_read_set(read_set)
    attachment_index = virtual_overlay_attachment_index(spec)

    cond do
      mode != "read_only" or Map.has_key?(spec, "write_policy") ->
        {:error,
         error_payload("invalid_spec", "virtual_overlay delegate specs must be read_only", %{
           "workspace_mode" => "virtual_overlay",
           "mode" => mode,
           "json_pointer" => "/mode",
           "path" => ["mode"],
           "next_actions" => ["set_mode_to_read_only", "remove_write_policy"]
         })}

      read_set_validation != :ok ->
        {:error,
         error_payload("invalid_spec", "virtual_overlay requires a bounded read_set", %{
           "json_pointer" => "/subagents/read_set",
           "path" => ["subagents", "read_set"],
           "next_actions" => ["add_a_non_empty_bounded_read_set"]
         })}

      not is_map(limits) ->
        {:error,
         error_payload("invalid_spec", "virtual_overlay limits must be a map", %{
           "json_pointer" => "/subagents/limits",
           "path" => ["subagents", "limits"],
           "next_actions" => ["set_limits_to_a_map_or_remove_it"]
         })}

      not is_nil(attachment_index) ->
        {:error,
         error_payload("invalid_spec", "virtual_overlay tasks cannot include attachments", %{
           "next_actions" => ["remove_attachments", "add_required_files_to_read_set"]
         })}

      true ->
        with :ok <- normalize_virtual_overlay_limits(limits) do
          {:ok, %{read_set: read_set, limits: limits}}
        end
    end
  end

  defp normalize_virtual_overlay(spec, _workspace_mode, _mode) do
    subagents = Map.get(spec, "subagents", %{})

    if Map.has_key?(subagents, "read_set") or Map.has_key?(subagents, "limits") do
      {:error,
       error_payload("invalid_spec", "virtual_overlay fields require virtual_overlay mode", %{
         "next_actions" => ["set_workspace_mode_to_virtual_overlay", "remove_virtual_fields"]
       })}
    else
      {:ok, nil}
    end
  end

  @doc false
  @spec virtual_overlay_attachment_index(map()) :: non_neg_integer() | nil
  def virtual_overlay_attachment_index(%{"tasks" => tasks}) when is_list(tasks) do
    Enum.find_index(tasks, fn
      %{"attachments" => attachments} when is_list(attachments) -> attachments != []
      _entry -> false
    end)
  end

  def virtual_overlay_attachment_index(_spec), do: nil

  defp normalize_virtual_overlay_limits(limits) do
    known = Pixir.VirtualOverlay.limit_keys()

    case Enum.find(limits, fn {key, value} ->
           key not in known or not is_integer(value) or value < 0
         end) do
      nil ->
        :ok

      {key, value} ->
        {:error,
         error_payload("invalid_spec", "virtual_overlay limit is invalid", %{
           "field" => "subagents.limits.#{key}",
           "json_pointer" => "/subagents/limits/#{key}",
           "path" => ["subagents", "limits", key],
           "observed" => value,
           "accepted_keys" => known,
           "next_actions" => ["use_a_known_non_negative_integer_limit"]
         })}
    end
  end

  defp normalize_agent(spec) do
    agent =
      get_in(spec, ["subagents", "role"]) ||
        get_in(spec, ["subagents", "agent"]) ||
        Map.get(spec, "agent") ||
        "explorer"

    if is_binary(agent) and String.trim(agent) != "" do
      {:ok, agent}
    else
      {:error,
       error_payload("invalid_spec", "subagents.role must be a non-empty string", %{
         "next_actions" => ["set_subagents_role_to_explorer"]
       })}
    end
  end

  defp ensure_child_count(tasks, %{"planned_child_count" => planned})
       when length(tasks) == planned,
       do: :ok

  defp ensure_child_count(tasks, %{"planned_child_count" => planned}) do
    {:error,
     error_payload("invalid_spec", "normalized task count does not match planned child count", %{
       "planned_child_count" => planned,
       "normalized_child_count" => length(tasks),
       "next_actions" => ["fix_delegate_task_list"]
     })}
  end

  defp ensure_child_count(_tasks, _spec_meta), do: :ok

  defp normalize_workflow_runtime(request, spec, spec_meta) do
    with {:ok, workspace} <- normalize_workspace(spec, request.workspace),
         {:ok, mode} <- normalize_mode(Map.get(spec, "mode")),
         {:ok, write_policy} <- normalize_write_policy(spec, mode),
         {:ok, timeouts} <- normalize_timeouts(request, spec),
         {:ok, workflow_spec} <- normalize_workflow_spec(spec, mode),
         :ok <- ensure_workflow_child_count(workflow_spec, spec_meta) do
      {:ok,
       %{
         workspace: workspace,
         workflow_spec: workflow_spec,
         mode: mode,
         write_policy: write_policy,
         timeout_ms: timeouts.legacy_timeout_ms,
         delegate_timeout_ms: timeouts.delegate_timeout_ms,
         child_timeout_ms: timeouts.child_timeout_ms,
         wait_horizon_ms: timeouts.wait_horizon_ms,
         planned_step_count: spec_meta["planned_child_count"]
       }}
    end
  end

  defp normalize_workflow_spec(spec, mode) do
    workflow =
      if Map.has_key?(spec, "steps") do
        spec
      else
        case Map.get(spec, "workflow") do
          %{} = nested ->
            Map.merge(Map.take(spec, ~w(id name max_concurrency timeout_ms workspace)), nested)

          _other ->
            %{}
        end
      end

    case Map.get(workflow, "steps") do
      steps when is_list(steps) ->
        steps =
          if mode == "bounded_write" do
            steps
          else
            Enum.map(steps, &force_read_only_step/1)
          end

        {:ok, Map.put(workflow, "steps", steps)}

      _other ->
        {:error,
         error_payload("invalid_spec", "workflow delegate spec requires steps", %{
           "missing_any_of" => ["steps", "workflow.steps"],
           "next_actions" => ["add_a_non_empty_steps_array"]
         })}
    end
  end

  defp force_read_only_step(%{} = step), do: Map.put_new(step, "permission_mode", "read_only")
  defp force_read_only_step(step), do: step

  defp ensure_workflow_child_count(%{"steps" => steps}, %{"planned_child_count" => planned})
       when is_list(steps) and length(steps) == planned,
       do: :ok

  defp ensure_workflow_child_count(%{"steps" => steps}, %{"planned_child_count" => planned})
       when is_list(steps) do
    {:error,
     error_payload(
       "invalid_spec",
       "normalized workflow step count does not match planned steps",
       %{
         "planned_step_count" => planned,
         "normalized_step_count" => length(steps),
         "next_actions" => ["fix_workflow_steps"]
       }
     )}
  end

  defp ensure_workflow_child_count(_workflow_spec, _spec_meta), do: :ok

  defp start_parent_session(workspace) do
    case Conversation.start(workspace: workspace, role: :delegate) do
      {:ok, session_id} -> {:ok, session_id}
      {:error, error} -> {:error, normalize_error(error)}
    end
  end

  defp spawn_subagents(parent_session_id, runtime, opts) do
    spawn_agent = Keyword.get(opts, :spawn_agent, &Subagents.spawn_agent/3)

    runtime.tasks
    |> Enum.reduce_while({:ok, []}, fn task, {:ok, agents} ->
      args =
        %{
          "task" => task_text(task),
          "agent" => runtime.agent,
          "max_threads" => runtime.max_threads,
          "max_depth" => runtime.max_depth,
          "timeout_ms" => runtime.child_timeout_ms,
          "workspace_mode" => runtime.workspace_mode
        }
        |> maybe_put("attachments", task_attachments(task))
        |> maybe_put("model", runtime.provider_model)
        |> maybe_put("reasoning_effort", runtime.reasoning_effort)
        |> maybe_put("web_search", runtime.web_search)

      spawn_opts =
        opts
        |> Keyword.take([:provider, :provider_opts, :skills_opts, :agents_opts])
        |> Keyword.put(:workspace, runtime.workspace)
        |> maybe_put_opt(:index, task_index(task))
        |> Keyword.put(:permission_mode, runtime_permission_mode(runtime))
        |> Keyword.put(:write_policy, runtime.write_policy)
        |> maybe_put_opt(:virtual_overlay, runtime.virtual_overlay)

      case spawn_agent.(
             parent_session_id,
             args,
             with_provider_transport(spawn_opts, runtime.provider_transport)
           ) do
        {:ok, agent} ->
          {:cont, {:ok, [agent | agents]}}

        {:error, error} ->
          error = normalize_error(error)

          if agents == [] do
            {:halt, {:error, error}}
          else
            {:halt, {:partial, Enum.reverse(agents), error}}
          end
      end
    end)
    |> case do
      {:ok, agents} -> {:ok, Enum.reverse(agents)}
      {:partial, _agents, _error} = partial -> partial
      {:error, _} = error -> error
    end
  end

  defp wait_for_agents(parent_session_id, runtime, agents, opts) do
    wait_outcome = Keyword.get(opts, :wait_outcome, &Subagents.wait_outcome/4)

    wait_outcome.(
      parent_session_id,
      Enum.map(agents, & &1["id"]),
      runtime.wait_horizon_ms,
      workspace: runtime.workspace
    )
  end

  defp run_workflow(parent_session_id, runtime, opts) do
    workflow_runner = Keyword.get(opts, :workflow_runner, &Workflows.run/3)

    workflow_opts =
      opts
      |> Keyword.take([:provider, :provider_opts, :skills_opts, :agents_opts])
      |> Keyword.put(:workspace, runtime.workspace)
      |> Keyword.put(:permission_mode, runtime_permission_mode(runtime))
      |> Keyword.put(:write_policy, runtime.write_policy)
      |> Keyword.put(:timeout_ms, runtime.delegate_timeout_ms)

    workflow_runner.(parent_session_id, runtime.workflow_spec, workflow_opts)
  end

  defp partial_spawn_payload(parent_session_id, runtime, agents, spawn_error, opts) do
    outcome =
      case wait_for_agents(parent_session_id, runtime, agents, opts) do
        {:ok, outcome} ->
          outcome

        {:error, wait_error} ->
          %{
            "status" => "partial",
            "counts" => %{
              "completed" => 0,
              "failed" => 0,
              "timed_out" => 0,
              "cancelled" => 0,
              "detached" => 0,
              "incomplete" => length(agents)
            },
            "subagents" => agents,
            "wait_error" => normalize_error(wait_error)
          }
      end
      |> annotate_partial_spawn(runtime, agents, spawn_error)

    result_payload(parent_session_id, runtime, agents, outcome)
    |> Map.put("ok", false)
    |> Map.put("status", "partial")
    |> Map.put("spawn_failure", spawn_error)
  end

  defp annotate_partial_spawn(outcome, runtime, agents, spawn_error) do
    next_actions =
      [
        "inspect_delegate_diagnostics",
        "inspect_spawn_failure",
        "retry_delegate_after_fixing_spawn_failure"
      ] ++ (outcome["next_actions"] || [])

    outcome
    |> Map.put("status", "partial")
    |> Map.put("complete", false)
    |> Map.put("partial", true)
    |> Map.put_new("subagents", agents)
    |> Map.put("spawn_failure", spawn_error)
    |> Map.put("summary", partial_spawn_summary(runtime, agents, spawn_error))
    |> Map.put("next_actions", Enum.uniq(next_actions))
  end

  defp partial_spawn_summary(runtime, agents, spawn_error) do
    message = spawn_error["message"] || spawn_error["kind"] || "unknown spawn failure"

    "delegate partial; spawned #{length(agents)}/#{runtime.planned_child_count} child session(s) before spawn failed: #{message}"
  end

  defp result_payload(parent_session_id, runtime, agents, outcome) do
    {:ok, handle} = Handle.build(parent_session_id)
    status = delegate_status(outcome)
    children = Enum.map(outcome["subagents"] || agents, &child_result(&1, :delegate_result))
    timeout_diagnostics = timeout_diagnostics(runtime, outcome, children)

    %{
      "ok" => status == "completed",
      "status" => status,
      "kind" => "delegate_result",
      "strategy" => "subagents",
      "delegate_id" => handle["delegate_id"],
      "parent_session_id" => parent_session_id,
      "session_id" => parent_session_id,
      "handle" => handle,
      "workspace" => runtime.workspace,
      "children" => children,
      "summary" => delegate_summary(status, outcome),
      "artifacts" => [],
      "diagnostics" => diagnostics(parent_session_id, runtime.workspace),
      "timeout_diagnostics" => timeout_diagnostics,
      "limits" => %{
        "timeout_ms" => runtime.timeout_ms,
        "delegate_timeout_ms" => runtime.delegate_timeout_ms,
        "child_timeout_ms" => runtime.child_timeout_ms,
        "wait_horizon_ms" => runtime.wait_horizon_ms,
        "timeout_semantics" => timeout_semantics(),
        "max_threads" => runtime.max_threads,
        "transport" => runtime.provider_transport,
        "max_depth" => runtime.max_depth,
        "mode" => runtime.mode,
        "workspace_mode" => runtime.workspace_mode,
        "write_policy" => WritePolicy.metadata(runtime.write_policy)
      },
      "beam_coordination" => %{
        "mode" => "attached",
        "entrypoint" => "single_pixir_process",
        "fanout_model" => "BEAM Subagents through Pixir.Subagents.Manager",
        "strategy" => "subagents",
        "planned_child_count" => runtime.planned_child_count,
        "spawned_child_count" => length(agents),
        "completed_child_count" => get_in(outcome, ["counts", "completed"]) || 0
      },
      "host_boundary" => %{
        "external_process_spawns" => 0,
        "external_process_spawns_scope" => "delegate_entrypoint_only_not_child_tools",
        "measurement" => "static_contract_assertion_not_global_host_metric",
        "nested_pixir_processes" => 0,
        "nested_mix_processes" => 0,
        "shell_polling" => false,
        "host_command_execution" => "none_in_delegate_runner",
        "child_host_commands" => "inspect_child_session_logs_and_diagnostics",
        "rule" => "treat every external process spawn as a scarce observable boundary crossing"
      },
      "next_actions" => delegate_next_actions(status, outcome)
    }
  end

  defp workflow_result_payload(parent_session_id, runtime, result) do
    {:ok, handle} = Handle.build(parent_session_id)
    status = workflow_delegate_status(result)
    steps = result["steps"] || []
    observed_applied_writes_by_step = workflow_observed_applied_writes_by_step(runtime, steps)

    children =
      steps
      |> Enum.zip(observed_applied_writes_by_step)
      |> Enum.map(fn {step, observed_applied_writes} ->
        workflow_child_result(step, observed_applied_writes)
      end)

    %{
      "ok" => status == "completed" and result["ok"] == true,
      "status" => status,
      "kind" => "delegate_result",
      "strategy" => "workflow",
      "delegate_id" => handle["delegate_id"],
      "parent_session_id" => parent_session_id,
      "session_id" => parent_session_id,
      "handle" => handle,
      "workflow_id" => result["workflow_id"],
      "workspace" => runtime.workspace,
      "mode" => runtime.mode,
      "write_policy" => WritePolicy.metadata(runtime.write_policy),
      "write_destination" =>
        workflow_write_destination(runtime, steps, List.flatten(observed_applied_writes_by_step)),
      "children" => children,
      "steps" => steps,
      "held_steps" => result["held_steps"] || [],
      "failed_steps" => result["failed_steps"] || [],
      "timeout_steps" => result["timeout_steps"] || [],
      "partial_steps" => result["partial_steps"] || [],
      "needs_orchestrator_steps" => result["needs_orchestrator_steps"] || [],
      "usable_checkpoints" => result["usable_checkpoints"] || [],
      "safe_next_actions" => result["safe_next_actions"] || [],
      "workflow" => workflow_projection(result),
      "summary" => workflow_delegate_summary(status, result),
      "artifacts" => [],
      "diagnostics" => workflow_diagnostics(parent_session_id, runtime.workspace),
      "limits" => %{
        "timeout_ms" => runtime.timeout_ms,
        "delegate_timeout_ms" => runtime.delegate_timeout_ms,
        "child_timeout_ms" => runtime.child_timeout_ms,
        "wait_horizon_ms" => runtime.wait_horizon_ms,
        "timeout_semantics" => timeout_semantics(),
        "mode" => runtime.mode,
        "workflow_mode" => runtime.mode,
        "write_policy" => WritePolicy.metadata(runtime.write_policy),
        "planned_step_count" => runtime.planned_step_count
      },
      "beam_coordination" => %{
        "mode" => "attached",
        "entrypoint" => "single_pixir_process",
        "fanout_model" => "BEAM Workflow through Pixir.Workflows",
        "strategy" => "workflow",
        "planned_step_count" => runtime.planned_step_count,
        "observed_step_count" => length(steps),
        "completed_step_count" => workflow_summary_count(result, "checkpoint_ready_steps")
      },
      "host_boundary" => %{
        "external_process_spawns" => 0,
        "external_process_spawns_scope" => "delegate_entrypoint_only_not_child_tools",
        "measurement" => "static_contract_assertion_not_global_host_metric",
        "nested_pixir_processes" => 0,
        "nested_mix_processes" => 0,
        "shell_polling" => false,
        "host_command_execution" => "none_in_delegate_runner",
        "child_host_commands" => "inspect_child_session_logs_and_diagnostics",
        "rule" => "treat every external process spawn as a scarce observable boundary crossing"
      },
      "next_actions" => workflow_next_actions(status, result)
    }
  end

  defp workflow_projection(result) do
    Map.take(result, [
      "workflow_id",
      "status",
      "proof_states",
      "waves",
      "summary",
      "safe_next_actions"
    ])
  end

  defp workflow_delegate_status(%{"status" => "completed"}), do: "completed"
  defp workflow_delegate_status(_result), do: "partial"

  defp workflow_child_result(step, observed_applied_writes) do
    %{
      "step_id" => step["step_id"] || step["id"],
      "subagent_id" => step["agent_id"],
      "child_session_id" => step["child_session_id"],
      "agent" => step["agent"],
      "status" => step["status"],
      "subagent_status" => step["subagent_status"],
      "checkpoint_status" => step["checkpoint_status"],
      "summary" => step["summary"],
      "task" => step["task"],
      "workspace_mode" => step["workspace_mode"],
      "writes_applied_to" => workflow_step_write_destination(step),
      "checkpoint" => step["checkpoint"],
      "next_actions" => step["safe_next_actions"] || []
    }
    |> maybe_put("timeout_ms", step["timeout_ms"])
    |> maybe_put("write_policy", step["write_policy"])
    |> maybe_put_observed_applied_writes(observed_applied_writes)
  end

  defp workflow_delegate_summary("completed", result) do
    summary = result["summary"] || %{}
    steps = summary["steps"] || length(result["steps"] || [])

    "delegate workflow completed: #{steps} step(s) checkpoint-ready."
  end

  defp workflow_delegate_summary(_status, result) do
    summary = result["summary"] || %{}
    held = summary["held_steps"] || length(result["held_steps"] || [])
    failed = summary["failed_steps"] || length(result["failed_steps"] || [])
    partial = summary["partial_steps"] || length(result["partial_steps"] || [])

    needs =
      summary["needs_orchestrator_steps"] || length(result["needs_orchestrator_steps"] || [])

    "delegate workflow partial: #{failed} failed, #{held} held, #{partial} partial, #{needs} needing orchestrator."
  end

  defp workflow_next_actions("completed", _result), do: []

  defp workflow_next_actions(_status, result) do
    result["safe_next_actions"] || ["inspect_delegate_diagnostics"]
  end

  defp workflow_summary_count(result, key), do: get_in(result, ["summary", key]) || 0

  defp workflow_write_destination(%{mode: "bounded_write"}, steps, observed_applied_writes) do
    destinations = Enum.map(steps, &workflow_step_write_destination/1)

    destination =
      cond do
        "indeterminate" in destinations ->
          %{
            "writes_applied_to" => "indeterminate",
            "contract_status" => "unverified_partial_writes",
            "workspace_modes" => workflow_workspace_modes(steps)
          }

        "workspace" in destinations and Enum.all?(steps, &workflow_step_checkpoint_ready?/1) ->
          %{
            "writes_applied_to" => "workspace",
            "contract_status" => "repo_mutating_success",
            "workspace_modes" => workflow_workspace_modes(steps)
          }

        "workspace" in destinations ->
          %{
            "writes_applied_to" => "workspace",
            "contract_status" => "partial_repo_mutation",
            "workspace_modes" => workflow_workspace_modes(steps)
          }

        "isolated_snapshot" in destinations ->
          %{
            "writes_applied_to" => "isolated_snapshot",
            "contract_status" => "not_repo_mutating_success",
            "workspace_modes" => workflow_workspace_modes(steps)
          }

        "not_applied" in destinations ->
          %{
            "writes_applied_to" => "none",
            "contract_status" => "no_workspace_write_applied",
            "workspace_modes" => workflow_workspace_modes(steps)
          }

        true ->
          %{
            "writes_applied_to" => "none",
            "contract_status" => "no_writer_steps_observed",
            "workspace_modes" => workflow_workspace_modes(steps)
          }
      end

    maybe_put_observed_applied_writes(destination, observed_applied_writes)
  end

  defp workflow_write_destination(_runtime, steps, _observed_applied_writes) do
    %{
      "writes_applied_to" => "none",
      "contract_status" => "read_only",
      "workspace_modes" => workflow_workspace_modes(steps)
    }
  end

  defp workflow_step_write_destination(step) do
    write_set = step["write_set"] || []

    cond do
      write_set == [] ->
        "none"

      step["workspace_mode"] == "shared" and not workflow_step_ran_to_completion?(step) ->
        "indeterminate"

      not workflow_step_ran_to_completion?(step) ->
        "not_applied"

      step["workspace_mode"] == "shared" ->
        "workspace"

      step["workspace_mode"] == "isolated" ->
        "isolated_snapshot"

      true ->
        "unknown"
    end
  end

  defp workflow_step_ran_to_completion?(step) do
    step["status"] == "completed" or step["subagent_status"] == "completed"
  end

  defp workflow_step_checkpoint_ready?(step), do: step["checkpoint_status"] == "checkpoint_ready"

  defp workflow_workspace_modes(steps) do
    steps
    |> Enum.map(&(&1["workspace_mode"] || "unknown"))
    |> Enum.uniq()
  end

  defp workflow_observed_applied_writes_by_step(%{mode: "bounded_write"} = runtime, steps) do
    Enum.map(steps, &workflow_observed_applied_writes(runtime, &1))
  end

  defp workflow_observed_applied_writes_by_step(_runtime, steps),
    do: Enum.map(steps, fn _ -> [] end)

  defp workflow_observed_applied_writes(
         %{workspace: workspace},
         %{
           "workspace_mode" => "shared",
           "child_session_id" => child_session_id,
           "write_set" => write_set
         }
       )
       when is_binary(workspace) and is_binary(child_session_id) and is_list(write_set) and
              write_set != [] do
    case Log.fold(child_session_id, workspace: workspace) do
      {:ok, history} -> observed_applied_write_paths(history, workspace)
      {:error, _error} -> []
    end
  end

  defp workflow_observed_applied_writes(_runtime, _step), do: []

  defp observed_applied_write_paths(history, workspace) do
    successful_results =
      history
      |> Enum.filter(&match?(%{type: :tool_result, data: %{"call_id" => _, "ok" => true}}, &1))
      |> MapSet.new(& &1.data["call_id"])

    history
    |> Enum.flat_map(fn
      %{
        type: :tool_call,
        data: %{"call_id" => call_id, "name" => name, "args" => %{"path" => path}}
      }
      when name in ["write", "edit"] and is_binary(call_id) and is_binary(path) ->
        if MapSet.member?(successful_results, call_id) do
          case observed_workspace_relative_path(workspace, path) do
            nil -> []
            relative_path -> [relative_path]
          end
        else
          []
        end

      _event ->
        []
    end)
    |> uniq_preserving_order()
  end

  defp observed_workspace_relative_path(workspace, path) do
    workspace = Path.expand(workspace)
    absolute_path = Path.expand(path, workspace)

    if absolute_path == workspace or String.starts_with?(absolute_path, workspace <> "/") do
      Path.relative_to(absolute_path, workspace)
    end
  end

  defp maybe_put_observed_applied_writes(map, observed_applied_writes) do
    case uniq_preserving_order(observed_applied_writes || []) do
      [] ->
        map

      writes ->
        map
        |> Map.put("observed_applied_writes", writes)
        |> Map.put("observed_writes_source", "child_log")
        |> Map.put("observed_writes_semantics", "at_least")
    end
  end

  defp uniq_preserving_order(values) do
    values
    |> Enum.reduce({MapSet.new(), []}, fn value, {seen, acc} ->
      if MapSet.member?(seen, value) do
        {seen, acc}
      else
        {MapSet.put(seen, value), [value | acc]}
      end
    end)
    |> elem(1)
    |> Enum.reverse()
  end

  defp start_context(parent_session_id, runtime, agents, spawn_error) do
    {:ok, handle} = Handle.build(parent_session_id)
    status = if is_nil(spawn_error), do: "running", else: "partial"
    {:ok, owner} = Owner.live_owner_state(handle, %{"runtime_residency" => runtime_residency()})
    children = Enum.map(agents, &child_result/1)

    payload = %{
      "ok" => is_nil(spawn_error),
      "status" => status,
      "kind" => "delegate_start",
      "strategy" => "subagents",
      "delegate_id" => handle["delegate_id"],
      "parent_session_id" => parent_session_id,
      "session_id" => parent_session_id,
      "handle" => handle,
      "workspace" => runtime.workspace,
      "children" => children,
      "summary" => start_summary(status, runtime, agents, spawn_error),
      "artifacts" => [],
      "diagnostics" => diagnostics(parent_session_id, runtime.workspace),
      "timeout_diagnostics" => start_timeout_diagnostics(runtime, children, spawn_error),
      "limits" => %{
        "timeout_ms" => runtime.timeout_ms,
        "delegate_timeout_ms" => runtime.delegate_timeout_ms,
        "child_timeout_ms" => runtime.child_timeout_ms,
        "wait_horizon_ms" => runtime.wait_horizon_ms,
        "timeout_semantics" => timeout_semantics(),
        "max_threads" => runtime.max_threads,
        "transport" => runtime.provider_transport,
        "max_depth" => runtime.max_depth,
        "mode" => runtime.mode,
        "workspace_mode" => runtime.workspace_mode,
        "write_policy" => WritePolicy.metadata(runtime.write_policy)
      },
      "owner" => owner,
      "service_state" => owner["state"],
      "runtime_residency" => runtime_residency(),
      "beam_coordination" => %{
        "mode" => "owner_start",
        "entrypoint" => "single_pixir_process",
        "fanout_model" => "BEAM Subagents through Pixir.Subagents.Manager",
        "strategy" => "subagents",
        "planned_child_count" => runtime.planned_child_count,
        "spawned_child_count" => length(agents),
        "completed_child_count" => 0
      },
      "host_boundary" => %{
        "external_process_spawns" => 0,
        "external_process_spawns_scope" => "delegate_start_entrypoint_only_not_child_tools",
        "measurement" => "static_contract_assertion_not_global_host_metric",
        "nested_pixir_processes" => 0,
        "nested_mix_processes" => 0,
        "shell_polling" => false,
        "host_command_execution" => "none_in_delegate_start",
        "child_host_commands" => "inspect_child_session_logs_and_diagnostics",
        "rule" => "treat every external process spawn as a scarce observable boundary crossing"
      },
      "next_actions" => start_next_actions(status)
    }

    payload =
      if spawn_error do
        Map.put(payload, "spawn_failure", spawn_error)
      else
        payload
      end

    payload = refresh_evidence_payload(payload)

    %{
      handle: handle,
      parent_session_id: parent_session_id,
      runtime: runtime,
      agents: agents,
      payload: payload
    }
  end

  defp refresh_lifecycle_evidence(parent_session_id, runtime, agents) do
    parent_session_id
    |> lifecycle_evidence_payload(runtime, agents)
    |> refresh_evidence_payload()

    :ok
  end

  defp lifecycle_evidence_payload(parent_session_id, runtime, agents) do
    {:ok, handle} = Handle.build(parent_session_id)

    %{
      "ok" => true,
      "status" => "running",
      "kind" => "delegate_evidence_lifecycle",
      "delegate_id" => handle["delegate_id"],
      "parent_session_id" => parent_session_id,
      "session_id" => parent_session_id,
      "workspace" => runtime.workspace,
      "mode" => runtime.mode,
      "children" => Enum.map(agents, &child_result/1),
      "limits" => %{
        "mode" => runtime.mode,
        "workspace_mode" => runtime.workspace_mode,
        "write_policy" => WritePolicy.metadata(runtime.write_policy)
      }
    }
  end

  defp refresh_evidence_payload(payload) do
    case Evidence.refresh_payload(payload) do
      {:ok, payload} -> payload
      {:error, _error} -> payload
    end
  end

  defp delegate_status(%{"status" => "completed"}), do: "completed"
  defp delegate_status(%{"status" => "incomplete"}), do: "timed_out"
  defp delegate_status(%{"status" => "partial", "spawn_failure" => _spawn_failure}), do: "partial"

  defp delegate_status(%{"counts" => counts}) do
    cond do
      (counts["failed"] || 0) > 0 -> "failed"
      (counts["timed_out"] || 0) > 0 -> "timed_out"
      (counts["cancelled"] || 0) > 0 -> "cancelled"
      true -> "partial"
    end
  end

  defp delegate_status(_outcome), do: "partial"

  defp delegate_summary("completed", outcome), do: outcome["summary"] || "delegate completed."

  defp delegate_summary(status, outcome) when status in @incomplete_statuses do
    outcome["summary"] || "delegate #{status}; inspect child sessions for details."
  end

  defp start_summary("running", runtime, agents, _spawn_error) do
    "delegate start accepted: spawned #{length(agents)}/#{runtime.planned_child_count} child session(s)."
  end

  defp start_summary("partial", runtime, agents, spawn_error) do
    message = spawn_error["message"] || spawn_error["kind"] || "unknown spawn failure"

    "delegate start partial: spawned #{length(agents)}/#{runtime.planned_child_count} child session(s) before spawn failed: #{message}"
  end

  defp start_next_actions("running"),
    do: ["check_delegate_status", "attach_snapshot_for_observation", "cancel_if_needed"]

  defp start_next_actions(_status),
    do: ["inspect_spawn_failure", "check_delegate_status", "inspect_delegate_diagnostics"]

  defp maybe_put_child_retry_lineage(child, agent) do
    retry_attempts = Map.get(agent, "retry_attempts")
    retry_history = Map.get(agent, "retry_history", [])

    if retry_attempts in [nil, 0] and retry_history in [nil, []] do
      child
    else
      child
      |> maybe_copy_child_field(agent, "retry_attempts")
      |> maybe_copy_child_field(agent, "retry_max_attempts")
      |> maybe_copy_child_field(agent, "current_attempt_index")
      |> maybe_copy_child_field(agent, "retry_history")
    end
  end

  defp maybe_copy_child_field(child, agent, field) do
    case Map.fetch(agent, field) do
      {:ok, nil} -> child
      {:ok, []} -> child
      {:ok, value} -> Map.put(child, field, value)
      :error -> child
    end
  end

  defp child_result(agent, context \\ :snapshot) do
    agent
    |> child_result_base()
    |> maybe_put_child_retry_lineage(agent)
    |> maybe_put_virtual_overlay_result(agent)
    |> maybe_put_child_recovery(context)
    |> maybe_put_guided_resume(agent)
  end

  defp maybe_put_virtual_overlay_result(result, %{"workspace_mode" => "virtual_overlay"} = agent) do
    result = maybe_copy_child_field(result, agent, "virtual_diff_ref")

    case Map.get(agent, "virtual_diff") do
      %{} = artifact ->
        result
        |> Map.put("virtual_diff", artifact)
        |> Map.put("apply", %{
          "status" => "not_applied",
          "requires_explicit_apply" => true,
          "tool" => "apply_virtual_diff",
          "dry_run_default" => true,
          "workflow_apply_from_compatible" => false
        })

      _other ->
        result
    end
  end

  defp maybe_put_virtual_overlay_result(result, _agent), do: result

  # Parity with one-shot envelopes: a non-completed child ships the same
  # ready-made recovery commands the one-shot contract puts at .resume_command,
  # so orchestrators recover per child without composing commands from parts.
  # Conditional presence, like the retry confession: completed children omit them.
  #
  # Context matters for "running": in the FINAL delegate_result envelope a child
  # still reported running was cut off at the collection horizon; the reader holds
  # a durable log, and if anything is genuinely alive the writer lease fails
  # closed, so diagnose-then-resume is the documented recovery either way.
  # Start/lifecycle snapshots keep the terminal-only rule: their running children
  # are owned and mid-flight, not recovery targets.
  @recoverable_child_statuses ~w(failed timed_out cancelled)

  defp maybe_put_child_recovery(
         %{"status" => status, "child_session_id" => sid} = result,
         context
       )
       when is_binary(sid) and sid != "" and
              (status in @recoverable_child_statuses or
                 (context == :delegate_result and status != "completed")) do
    case RecoveryCommands.commands(sid, workspace_mode: result["workspace_mode"]) do
      {:ok, commands} ->
        result
        |> Map.put("resume_command", commands["resume_command"])
        |> Map.put("diagnose_command", commands["diagnose_command"])
        |> maybe_put_virtual_recovery(commands)

      {:error, _details} ->
        result
    end
  end

  defp maybe_put_child_recovery(result, _context), do: result

  defp maybe_put_guided_resume(
         %{"status" => status, "child_session_id" => sid} = result,
         agent
       )
       when status in @guided_resume_statuses and is_binary(sid) and sid != "" do
    case transport_error_kind(agent) do
      nil ->
        result

      error_kind ->
        opts = [
          workspace_mode: result["workspace_mode"],
          write_capable: write_capable_child?(agent)
        ]

        case RecoveryCommands.commands(sid, opts) do
          {:ok, commands} ->
            recovery =
              result
              |> Map.get("recovery", %{})
              |> normalize_recovery()
              |> Map.merge(%{
                "kind" => "resume_suggested",
                "reason" => "terminal transport error: #{error_kind}"
              })
              |> maybe_merge_recovery_notes(commands["notes"])

            Map.put(result, "recovery", recovery)

          {:error, _error} ->
            result
        end
    end
  end

  defp maybe_put_guided_resume(result, _agent), do: result

  defp normalize_recovery(recovery) when is_map(recovery), do: recovery
  defp normalize_recovery(_recovery), do: %{}

  defp maybe_merge_recovery_notes(recovery, notes) when is_list(notes) and notes != [] do
    Map.update(recovery, "notes", notes, fn
      existing when is_list(existing) -> Enum.uniq(existing ++ notes)
      _existing -> notes
    end)
  end

  defp maybe_merge_recovery_notes(recovery, _notes), do: recovery

  defp transport_error_kind(agent) when is_map(agent) do
    transport_error_kind_from_evidence(agent) || transport_error_kind_from_child_log(agent)
  end

  defp transport_error_kind(_agent), do: nil

  defp transport_error_kind_from_evidence(evidence) when is_map(evidence) do
    candidates = transport_error_candidates(evidence)

    Enum.find(candidates, &specific_transport_error_kind?/1) ||
      if("provider_http_error" in candidates and retryable_provider_http_evidence?(evidence),
        do: "provider_http_error"
      )
  end

  defp transport_error_kind_from_evidence(_evidence), do: nil

  defp transport_error_kind_from_child_log(agent) do
    sid = map_value(agent, "child_session_id", :child_session_id)
    workspace = map_value(agent, "workspace", :workspace)

    with true <- is_binary(sid) and sid != "",
         true <- is_binary(workspace) and workspace != "",
         {:ok, history} <- Log.fold(sid, workspace: workspace),
         %{type: :turn_failed, data: failure} <-
           Enum.find(Enum.reverse(history), &(&1.type == :turn_failed)) do
      transport_error_kind_from_evidence(failure)
    else
      _missing_or_unreadable -> nil
    end
  end

  defp transport_error_candidates(value) when is_binary(value), do: [value]
  defp transport_error_candidates(value) when is_atom(value), do: [Atom.to_string(value)]

  defp transport_error_candidates(value) when is_map(value) do
    direct =
      [
        map_value(value, "error_kind", :error_kind),
        map_value(value, "kind", :kind),
        map_value(value, "type", :type)
      ]
      |> Enum.flat_map(&transport_error_candidates/1)

    nested =
      [
        map_value(value, "reason", :reason),
        map_value(value, "error", :error),
        map_value(value, "failure", :failure),
        map_value(value, "terminal_error", :terminal_error),
        map_value(value, "details", :details)
      ]
      |> Enum.flat_map(&transport_error_candidates/1)

    direct ++ nested
  end

  defp transport_error_candidates(_value), do: []

  defp specific_transport_error_kind?(kind) do
    kind in @websocket_transport_error_kinds or
      kind in @in_band_transport_error_kinds or
      kind in ["network", "rate_limited"] or rate_limit_error_kind?(kind)
  end

  defp rate_limit_error_kind?(kind) when is_binary(kind) do
    String.contains?(kind, "rate_limit") or String.contains?(kind, "rate-limit")
  end

  defp retryable_provider_http_evidence?(value) when is_map(value) do
    retryable = map_value(value, "retryable", :retryable)
    status = map_value(value, "status", :status)
    type = map_value(value, "type", :type)

    retryable == true or status in [500, 502, 503, 504] or type == "server_error" or
      Enum.any?(
        [
          map_value(value, "reason", :reason),
          map_value(value, "error", :error),
          map_value(value, "failure", :failure),
          map_value(value, "terminal_error", :terminal_error),
          map_value(value, "details", :details)
        ],
        &retryable_provider_http_evidence?/1
      )
  end

  defp retryable_provider_http_evidence?(_value), do: false

  defp write_capable_child?(agent) do
    permission_mode = map_value(agent, "permission_mode", :permission_mode)
    write_policy = map_value(agent, "write_policy", :write_policy)
    mode = map_value(agent, "mode", :mode)
    role = map_value(agent, "agent", :agent)

    cond do
      permission_mode in ["read_only", :read_only] -> false
      permission_mode in ["auto", :auto] -> true
      mode in ["bounded_write", :bounded_write] -> true
      is_map(write_policy) -> true
      role in ["worker", :worker] -> true
      true -> false
    end
  end

  defp map_value(map, string_key, atom_key) do
    case Map.fetch(map, string_key) do
      {:ok, value} -> value
      :error -> Map.get(map, atom_key)
    end
  end

  defp maybe_put_virtual_recovery(
         %{"workspace_mode" => "virtual_overlay"} = result,
         %{"notes" => notes}
       ) do
    recovery =
      %{
        "workspace_mode" => "virtual_overlay",
        "notes" => notes,
        "virtual_diff_preserved" => is_map(result["virtual_diff"]),
        "apply_tool" => "apply_virtual_diff",
        "apply_is_separate_explicit_decision" => true
      }
      |> maybe_put("virtual_diff_ref", result["virtual_diff_ref"])

    Map.put(result, "recovery", recovery)
  end

  defp maybe_put_virtual_recovery(result, _commands), do: result

  defp child_result_base(agent) do
    %{
      "subagent_id" => agent["id"],
      "child_session_id" => agent["child_session_id"],
      "agent" => agent["agent"],
      "status" => agent["status"],
      "summary" => agent["summary"],
      "task" => agent["task"],
      "workspace_mode" => agent["workspace_mode"],
      "child_log_path" => agent["child_log_path"],
      "next_actions" => agent["next_actions"] || []
    }
    |> maybe_put("index", agent["index"])
    |> maybe_put("timeout_ms", agent["timeout_ms"])
    |> maybe_put("write_policy", agent["write_policy"])
  end

  defp timeout_semantics do
    %{
      "timeout_ms" => "legacy_request_or_spec_timeout_default",
      "delegate_timeout_ms" =>
        "delegate_level_budget_and_default_wait_horizon_metadata_for_this_v1",
      "child_timeout_ms" => "per_child_subagent_execution_timeout",
      "wait_horizon_ms" => "parent_wait_horizon_for_attached_result_collection"
    }
  end

  defp timeout_diagnostics(runtime, outcome, children) do
    counts = outcome["counts"] || %{}
    child_status_counts = child_status_counts(children)

    %{
      "classification" => timeout_classification(outcome, counts, child_status_counts),
      "delegate_timeout_ms" => runtime.delegate_timeout_ms,
      "child_timeout_ms" => runtime.child_timeout_ms,
      "wait_horizon_ms" => runtime.wait_horizon_ms,
      "observed_wait_timeout_ms" => outcome["timeout_ms"],
      "wait_horizon_exhausted" => outcome["status"] == "incomplete",
      "delegate_timeout_enforcement" => "not_enforced_as_active_cancellation_in_attached_v1",
      "queued_child_count" => child_status_counts["queued"] || 0,
      "running_child_count" => child_status_counts["running"] || 0,
      "incomplete_child_count" => counts["incomplete"] || 0,
      "child_timeout_count" => counts["timed_out"] || 0,
      "failed_child_count" => counts["failed"] || 0,
      "cancelled_child_count" => counts["cancelled"] || 0,
      "detached_child_count" => counts["detached"] || 0
    }
  end

  defp start_timeout_diagnostics(runtime, children, nil) do
    child_status_counts = child_status_counts(children)

    %{
      "classification" => "started_without_wait",
      "delegate_timeout_ms" => runtime.delegate_timeout_ms,
      "child_timeout_ms" => runtime.child_timeout_ms,
      "wait_horizon_ms" => runtime.wait_horizon_ms,
      "wait_horizon_exhausted" => false,
      "delegate_timeout_enforcement" => "owned_by_live_delegate_runtime_after_start",
      "queued_child_count" => child_status_counts["queued"] || 0,
      "running_child_count" => child_status_counts["running"] || 0,
      "child_timeout_count" => 0,
      "failed_child_count" => 0,
      "cancelled_child_count" => 0
    }
  end

  defp start_timeout_diagnostics(runtime, children, _spawn_error) do
    child_status_counts = child_status_counts(children)

    %{
      "classification" => "spawn_failure",
      "delegate_timeout_ms" => runtime.delegate_timeout_ms,
      "child_timeout_ms" => runtime.child_timeout_ms,
      "wait_horizon_ms" => runtime.wait_horizon_ms,
      "wait_horizon_exhausted" => false,
      "delegate_timeout_enforcement" => "owned_by_live_delegate_runtime_after_start",
      "queued_child_count" => child_status_counts["queued"] || 0,
      "running_child_count" => child_status_counts["running"] || 0,
      "child_timeout_count" => 0,
      "failed_child_count" => 0,
      "cancelled_child_count" => 0
    }
  end

  defp timeout_classification(outcome, counts, child_status_counts) do
    cond do
      Map.has_key?(outcome, "spawn_failure") ->
        "spawn_failure"

      (counts["timed_out"] || 0) > 0 ->
        "child_timeout"

      (counts["failed"] || 0) > 0 ->
        "child_failure"

      (counts["cancelled"] || 0) > 0 ->
        "child_cancelled"

      (counts["detached"] || 0) > 0 ->
        "child_detached"

      outcome["status"] == "incomplete" and (child_status_counts["queued"] || 0) > 0 ->
        "wait_horizon_exhausted_with_queued_work"

      outcome["status"] == "incomplete" and (child_status_counts["running"] || 0) > 0 ->
        "wait_horizon_exhausted_with_running_work"

      outcome["status"] == "incomplete" ->
        "wait_horizon_exhausted"

      outcome["status"] == "completed" ->
        "completed"

      true ->
        "partial_terminal_mix"
    end
  end

  defp child_status_counts(children) do
    Enum.frequencies_by(children, &(&1["status"] || "unknown"))
  end

  defp runtime_permission_mode(%{mode: "bounded_write"}), do: :auto
  defp runtime_permission_mode(_runtime), do: :read_only

  defp diagnostics(parent_session_id, workspace) do
    %{
      "log_path" => Log.path(parent_session_id, workspace: workspace),
      "tree_command" => "pixir tree #{parent_session_id} --json",
      "diagnose_command" => "pixir diagnose session #{parent_session_id} --json",
      "issue" => "private-tracker#133 (see docs/adr/README.md on private refs)"
    }
  end

  defp workflow_diagnostics(parent_session_id, workspace) do
    parent_session_id
    |> diagnostics(workspace)
    |> Map.put("issue", "private-tracker#150 (see docs/adr/README.md on private refs)")
  end

  defp delegate_next_actions("completed", _outcome), do: []

  defp delegate_next_actions(_status, outcome) do
    outcome["next_actions"] || ["inspect_delegate_diagnostics"]
  end

  defp runtime_residency do
    %{
      "model" => "current_beam_runtime",
      "survives_cli_process_exit" => false,
      "cross_invocation_owner" => false,
      "daemon_or_ipc" => false,
      "note" => "live owner capability is available only while this BEAM runtime remains alive"
    }
  end

  defp normalize_error(%{ok: false, error: %{kind: kind, message: message, details: details}}) do
    error_payload(to_string(kind), message, stringify_keys(details))
  end

  defp normalize_error(%{"ok" => false} = error), do: error

  defp normalize_error(error) do
    error_payload("runtime_error", "delegate runtime failed", %{"reason" => inspect(error)})
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

  defp stringify_keys(%{} = map) do
    Map.new(map, fn {key, value} -> {to_string(key), stringify_keys(value)} end)
  end

  defp stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)
  defp stringify_keys(value), do: value

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp maybe_put_opt(opts, _key, nil), do: opts
  defp maybe_put_opt(opts, key, value), do: Keyword.put(opts, key, value)
end
