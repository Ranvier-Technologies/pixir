defmodule Pixir.Workflows do
  @moduledoc """
  Deterministic Workflow orchestration over Pixir Subagents.

  A Workflow is a bounded plan of steps with explicit dependency edges and write-set
  metadata. Ordinary steps schedule ADR 0011 Subagents; explicit `virtual_overlay`
  steps run the internal BEAM-native virtual workspace runner and return `virtual_diff`
  evidence without opening a child Session or mutating the parent workspace.

  The top-level Workflow result has a narrow terminal contract: `"completed"` means
  every step produced a dependent-safe checkpoint, while `"partial"` means at least one
  step needs retry, synthesis, inspection, or orchestrator input. Step-level
  `checkpoint_status` values carry the detailed truth (`"held"`, `"failed"`,
  `"partial"`, `"needs_orchestrator"`, or `"checkpoint_ready"`).

  ## TODO(delegate-service-v1)

  Delegate service mode will eventually need a Workflow strategy, but it should not
  bypass this module's checkpoint and partial-outcome vocabulary. Prefer a thin
  Delegate adapter that submits a normalized Workflow spec here, then reports
  `workflow_id`, child ids, checkpoint readiness, and safe next actions through the same
  `delegate status/attach` contract used for Subagent fanout.
  """

  alias Pixir.{
    Agents,
    Event,
    Permissions.WritePolicy,
    Session,
    SessionId,
    SessionResources,
    Skills,
    Subagents,
    Tool,
    VirtualDiffApply,
    VirtualOverlay,
    WorkflowRun,
    WorkspaceStrategy
  }

  @wildcard "**/*"
  @workflow_workspace_modes ~w(shared isolated virtual_overlay)
  @workflow_shell_keys ~w(steps)
  @workflow_step_keys ~w(
    id task agent apply_from workspace_mode read_set virtual_commands limits write_set model
    reasoning_effort attachments depends_on timeout_ms permission_mode sandbox_mode
  )
  @default_poll_ms 50
  @default_timeout_ms 120_000
  @safe_id ~r/^[A-Za-z0-9][A-Za-z0-9_-]*$/
  # Virtual/apply runners use a short-lived linked Task.Supervisor per invocation.
  # That preserves task crash isolation while coupling the runner's lifetime to
  # the interruptible workflow process; see yield_interrupt_coupled_task/2.

  @proof_states ~w(
    intent_declared
    workflow_validated
    dry_run_planned
    subagents_scheduled
    dependencies_resolved
    conflicts_serialized
    summaries_collected
    completion_ready
  )

  @partial_proof_states ~w(
    intent_declared
    workflow_validated
    subagents_scheduled
    dependencies_resolved
    conflicts_serialized
    summaries_collected
    partial_outcome_ready
  )

  @dry_run_proof_states ~w(
    intent_declared
    workflow_validated
    dry_run_planned
    dependencies_resolved
    conflicts_serialized
  )

  @workflow_statuses ~w(completed partial)
  @checkpoint_statuses ~w(checkpoint_ready partial failed held needs_orchestrator)

  @doc false
  @spec workflow_shell_keys() :: [String.t()]
  def workflow_shell_keys, do: @workflow_shell_keys

  @doc false
  @spec workflow_step_keys() :: [String.t()]
  def workflow_step_keys, do: @workflow_step_keys

  @doc "Named proof states used by dry-runs, smoke tasks, and completion audits."
  @spec proof_states() :: [String.t()]
  def proof_states, do: @proof_states

  @doc "Named proof states a Workflow dry-run can prove without spawning Subagents."
  @spec dry_run_proof_states() :: [String.t()]
  def dry_run_proof_states, do: @dry_run_proof_states

  @doc "Named proof states for a Workflow that produced an honest partial outcome."
  @spec partial_proof_states() :: [String.t()]
  def partial_proof_states, do: @partial_proof_states

  @doc "Top-level Workflow result statuses."
  @spec workflow_statuses() :: [String.t()]
  def workflow_statuses, do: @workflow_statuses

  @doc "Step checkpoint statuses that classify completion, partial evidence, and holds."
  @spec checkpoint_statuses() :: [String.t()]
  def checkpoint_statuses, do: @checkpoint_statuses

  @doc "Validate a Workflow and return its normalized execution plan without running it."
  @spec dry_run(map(), keyword()) :: {:ok, map()} | {:error, map()}
  def dry_run(spec, opts \\ [])

  def dry_run(spec, opts) when is_map(spec) do
    with {:ok, workflow} <- normalize(spec, opts),
         {:ok, waves} <- plan_waves(workflow) do
      {:ok,
       %{
         "ok" => true,
         "mode" => "dry_run",
         "workflow_id" => workflow.id,
         "template" => template_metadata(workflow),
         "proof_states" => @dry_run_proof_states,
         "would_run" => Enum.map(workflow.steps, &step_plan_with_knobs/1),
         "waves" => waves,
         "summary" => %{
           "steps" => length(workflow.steps),
           "max_concurrency" => workflow.max_concurrency,
           "conservative_workspace_writers" =>
             workflow.steps
             |> Enum.count(&(&1.posture == "writer" and &1.write_set == [@wildcard]))
         }
       }}
    end
  end

  def dry_run(_spec, _opts),
    do: {:error, Tool.error(:invalid_args, "workflow spec must be an object", %{})}

  defp step_plan_with_knobs(step) do
    step
    |> step_plan()
    |> put_step_plan_field("model", step.model)
    |> put_step_plan_field("reasoning_effort", step.reasoning_effort)
    |> put_attachment_count(step.attachments)
  end

  defp put_step_plan_field(plan, _key, nil), do: plan
  defp put_step_plan_field(plan, key, value), do: Map.put(plan, key, value)

  defp put_attachment_count(plan, attachments)
       when is_list(attachments) and length(attachments) > 0,
       do: Map.put(plan, "attachment_count", length(attachments))

  defp put_attachment_count(plan, _attachments), do: plan

  defp keyword_put_if_present(opts, _key, nil), do: opts
  defp keyword_put_if_present(opts, _key, []), do: opts
  defp keyword_put_if_present(opts, key, value), do: Keyword.put(opts, key, value)

  @doc "Run a Workflow by scheduling its steps through `Pixir.Subagents`."
  @spec run(String.t(), map(), keyword()) :: {:ok, map()} | {:error, map()}
  def run(parent_session_id, spec, opts \\ [])

  def run(parent_session_id, spec, opts) when is_binary(parent_session_id) and is_map(spec) do
    with :ok <- SessionId.validate(parent_session_id),
         {:ok, workflow} <- normalize(spec, opts),
         {:ok, state} <- WorkflowRun.new(workflow),
         :ok <-
           record_workflow_event(
             parent_session_id,
             "workflow_started",
             workflow_started_data(workflow)
           ) do
      run_loop(parent_session_id, workflow, state, opts)
    end
  end

  def run(_parent_session_id, _spec, _opts),
    do:
      {:error, Tool.error(:invalid_args, "parent session id and workflow spec are required", %{})}

  defp normalize(spec, opts) do
    with {:ok, spec, template} <- maybe_instantiate_template(spec, opts),
         {:ok, workflow} <- do_normalize(spec, opts) do
      {:ok, Map.put(workflow, :template, template)}
    end
  rescue
    error in [ArgumentError, Protocol.UndefinedError] ->
      {:error, Tool.error(:invalid_args, Exception.message(error), %{})}
  end

  defp maybe_instantiate_template(spec, opts) do
    case template_ref(spec) do
      nil ->
        {:ok, spec, nil}

      ref ->
        if has_field?(spec, "steps") do
          {:error,
           Tool.error(:invalid_args, "workflow template arguments cannot include steps", %{
             template_id: ref
           })}
        else
          args = field(spec, "template_args", %{})
          workspace = Keyword.get(opts, :workspace) || field(spec, "workspace") || File.cwd!()
          skills_opts = Keyword.get(opts, :skills_opts, [])

          with {:ok, %{template: template, workflow: workflow}} <-
                 Skills.instantiate_workflow_template(ref, args, workspace, skills_opts) do
            {:ok, Map.merge(workflow, workflow_overrides(spec)), template}
          end
        end
    end
  end

  defp template_ref(spec) do
    cond do
      is_binary(field(spec, "template_id")) ->
        field(spec, "template_id")

      is_binary(field(spec, "skill")) and is_binary(field(spec, "template")) ->
        "#{field(spec, "skill")}/#{field(spec, "template")}"

      true ->
        nil
    end
  end

  defp workflow_overrides(spec) do
    ["id", "name", "max_concurrency", "timeout_ms", "workspace"]
    |> Enum.reduce(%{}, fn key, acc ->
      if has_field?(spec, key), do: Map.put(acc, key, field(spec, key)), else: acc
    end)
  end

  defp do_normalize(spec, opts) do
    workspace = Keyword.get(opts, :workspace) || field(spec, "workspace") || File.cwd!()
    agents_opts = Keyword.get(opts, :agents_opts, [])
    steps = field(spec, "steps", [])

    workflow = %{
      id: normalize_workflow_id(field(spec, "id")),
      name: field(spec, "name", "workflow"),
      workspace: workspace,
      max_concurrency:
        positive_integer(
          field(spec, "max_concurrency", Subagents.default_limits().max_threads),
          "max_concurrency"
        ),
      poll_ms: non_negative_integer(Keyword.get(opts, :poll_ms, @default_poll_ms), "poll_ms"),
      timeout_ms:
        positive_integer(
          field(spec, "timeout_ms", Keyword.get(opts, :timeout_ms, @default_timeout_ms)),
          "timeout_ms"
        ),
      write_policy: Keyword.get(opts, :write_policy)
    }

    with :ok <- require_steps(steps),
         {:ok, steps} <- normalize_steps(steps, workspace, agents_opts, opts),
         :ok <- validate_unique_step_ids(steps),
         :ok <- validate_dependencies(steps) do
      {:ok, Map.put(workflow, :steps, steps)}
    end
  end

  defp require_steps([_ | _]), do: :ok

  defp require_steps(_),
    do: {:error, Tool.error(:invalid_args, "workflow requires a non-empty steps list", %{})}

  defp normalize_steps(steps, workspace, agents_opts, opts) do
    steps
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, []}, fn {raw, index}, {:ok, acc} ->
      case normalize_step(raw, index, workspace, agents_opts, opts, acc) do
        {:ok, step} -> {:cont, {:ok, acc ++ [step]}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp normalize_step(raw, index, workspace, agents_opts, opts, previous_steps)
       when is_map(raw) do
    id = field(raw, "id", "step_#{index}") |> to_string()
    task = field(raw, "task")
    agent_name = field(raw, "agent", "default")

    cond do
      not safe_id?(id) ->
        {:error, Tool.error(:invalid_args, "workflow step id must be a safe basename", %{id: id})}

      has_field?(raw, "apply_from") ->
        normalize_apply_step(raw, index, id, opts, previous_steps)

      not (is_binary(task) and String.trim(task) != "") ->
        {:error, Tool.error(:invalid_args, "workflow step task is required", %{id: id})}

      true ->
        with {:ok, agent_config} <- Agents.get(agent_name, workspace, agents_opts) do
          read_only? = read_only_step?(raw, agent_config)
          default_workspace_mode = if read_only?, do: "shared", else: "isolated"

          with {:ok, workspace_mode} <-
                 normalize_workspace_mode(
                   field(raw, "workspace_mode", default_workspace_mode),
                   id
                 ),
               {:ok, read_set} <- normalize_read_set(raw, read_only?, workspace_mode, id),
               {:ok, virtual_commands} <- normalize_virtual_commands(raw, workspace_mode, id),
               {:ok, virtual_limits} <- normalize_virtual_limits(raw, workspace_mode, id),
               {:ok, write_set} <-
                 normalize_write_set(raw, read_only?, workspace_mode, id, opts),
               {:ok, model} <- normalize_optional_model(field(raw, "model"), id),
               {:ok, reasoning_effort} <-
                 normalize_optional_reasoning_effort(field(raw, "reasoning_effort"), id),
               {:ok, attachments} <-
                 normalize_optional_attachments(field(raw, "attachments"), id, workspace),
               :ok <-
                 validate_knobs_apply(workspace_mode, model, reasoning_effort, attachments, id),
               {:ok, write_policy} <-
                 step_write_policy(Keyword.get(opts, :write_policy), write_set, read_only?),
               :ok <-
                 validate_step_read_only_agent_gate(
                   Keyword.get(opts, :write_policy),
                   workspace_mode,
                   read_only?,
                   agent_config,
                   id,
                   index
                 ) do
            {:ok,
             %{
               id: id,
               task: String.trim(task),
               agent: agent_config.name,
               depends_on: normalize_id_list(field(raw, "depends_on", []), "depends_on", id),
               posture: step_posture(workspace_mode, read_only?),
               permission_mode: step_permission_mode(workspace_mode, read_only?, opts),
               workspace_mode: workspace_mode,
               read_set: read_set,
               write_set: write_set,
               write_policy: write_policy,
               virtual_commands: virtual_commands,
               virtual_limits: virtual_limits,
               # Runtime knobs are trusted subagent opts, never spawn args.
               model: model,
               reasoning_effort: reasoning_effort,
               attachments: attachments,
               timeout_ms: maybe_positive_integer(field(raw, "timeout_ms"), "timeout_ms", id)
             }}
          end
        end
    end
  end

  defp normalize_step(_raw, index, _workspace, _agents_opts, _opts, _previous_steps),
    do: {:error, Tool.error(:invalid_args, "workflow step must be an object", %{index: index})}

  defp normalize_apply_step(raw, index, id, opts, previous_steps) do
    with :ok <- validate_apply_from_bounded_write(opts, id, index),
         {:ok, apply_from} <- validate_apply_from_producer(raw, previous_steps, id, index),
         :ok <- validate_apply_from_depends_on(raw, apply_from, id, index),
         :ok <- validate_apply_from_knobs(raw, id, index),
         {:ok, write_set} <- normalize_apply_write_set(raw, id, index),
         {:ok, write_policy} <-
           step_write_policy(Keyword.get(opts, :write_policy), write_set, false) do
      {:ok,
       %{
         id: id,
         task: String.trim(field(raw, "task", "apply virtual_diff from #{apply_from}") || ""),
         agent: nil,
         depends_on: normalize_id_list(field(raw, "depends_on", []), "depends_on", id),
         posture: "apply",
         permission_mode: :auto,
         workspace_mode: "shared",
         read_set: [],
         write_set: write_set,
         write_policy: write_policy,
         virtual_commands: [],
         virtual_limits: nil,
         apply_from: apply_from,
         model: nil,
         reasoning_effort: nil,
         attachments: [],
         timeout_ms: maybe_positive_integer(field(raw, "timeout_ms"), "timeout_ms", id)
       }}
    end
  end

  defp validate_apply_from_bounded_write(opts, id, index) do
    if Keyword.get(opts, :write_policy) do
      :ok
    else
      invalid_apply_from(id, index, "apply_from requires bounded_write with write_policy", %{
        "next_actions" => ["run_with_bounded_write_policy"]
      })
    end
  end

  defp validate_apply_from_producer(raw, previous_steps, id, index) do
    apply_from = field(raw, "apply_from")

    case Enum.find(previous_steps, &(&1.id == apply_from)) do
      nil ->
        invalid_apply_from(
          id,
          index,
          "apply_from must reference a previous virtual_overlay step",
          %{
            "apply_from" => apply_from,
            "next_actions" => ["declare_the_virtual_overlay_producer_before_the_apply_step"]
          }
        )

      %{workspace_mode: "virtual_overlay"} ->
        {:ok, apply_from}

      _producer ->
        invalid_apply_from(
          id,
          index,
          "apply_from producer must use workspace_mode virtual_overlay",
          %{
            "apply_from" => apply_from,
            "next_actions" => ["point_apply_from_at_a_virtual_overlay_step"]
          }
        )
    end
  end

  defp validate_apply_from_depends_on(raw, apply_from, id, index) do
    depends_on = normalize_id_list(field(raw, "depends_on", []), "depends_on", id)

    if apply_from in depends_on do
      :ok
    else
      invalid_apply_from(id, index, "apply_from producer must be listed in depends_on", %{
        "apply_from" => apply_from,
        "depends_on" => depends_on,
        "next_actions" => ["add_the_producer_to_depends_on"]
      })
    end
  end

  defp validate_apply_from_knobs(raw, id, index) do
    rejected =
      ~w(agent model reasoning_effort attachments virtual_commands read_set)
      |> Enum.filter(&has_field?(raw, &1))

    if rejected == [] do
      :ok
    else
      invalid_apply_from(id, index, "apply_from workflow steps do not spawn subagents", %{
        "rejected_fields" => rejected,
        "next_actions" => ["remove_apply_step_subagent_fields"]
      })
    end
  end

  defp normalize_apply_write_set(raw, id, index) do
    if has_field?(raw, "write_set") do
      write_set = normalize_set(field(raw, "write_set"))

      if write_set == [] do
        invalid_apply_from(
          id,
          index,
          "apply_from workflow step requires non-empty write_set",
          %{
            "field" => "write_set",
            "next_actions" => ["add_non_empty_write_set"]
          }
        )
      else
        # Same glob grammar as the bounded write policy: the runtime bound
        # delegates to WritePolicy.rules_cover_path?, so the shapes must match.
        case WritePolicy.validate_path_rules(write_set, "write_set") do
          :ok ->
            {:ok, write_set}

          {:error, %{error: %{details: details}}} ->
            invalid_apply_from(
              id,
              index,
              "apply_from write_set entries must use the write-policy glob grammar",
              Map.merge(
                %{"field" => "write_set"},
                Map.new(details, fn {key, value} -> {to_string(key), value} end)
              )
            )
        end
      end
    else
      invalid_apply_from(id, index, "apply_from workflow step requires write_set", %{
        "field" => "write_set",
        "next_actions" => ["add_explicit_write_set"]
      })
    end
  end

  defp invalid_apply_from(id, index, message, details) do
    {:error,
     Tool.error(
       :invalid_spec,
       message,
       Map.merge(details, %{
         "id" => id,
         "field" => "apply_from",
         # location is a JSON pointer: zero-based, like the delegate
         # contract's step_json_pointer (#182), while `index` stays the
         # 1-based human label used in messages.
         "location" => "/steps/#{index - 1}/apply_from"
       })
     )}
  end

  defp normalize_optional_model(nil, _id), do: {:ok, nil}

  defp normalize_optional_model(model, id) when is_binary(model) do
    model = String.trim(model)

    if model == "" do
      invalid_optional_model(id)
    else
      {:ok, model}
    end
  end

  defp normalize_optional_model(_model, id), do: invalid_optional_model(id)

  defp invalid_optional_model(id) do
    {:error,
     Tool.error(:invalid_args, "workflow step model must be a non-empty string", %{
       "id" => id,
       "field" => "model"
     })}
  end

  defp normalize_optional_reasoning_effort(nil, _id), do: {:ok, nil}

  defp normalize_optional_reasoning_effort(effort, _id) when effort in ~w(low medium high xhigh),
    do: {:ok, effort}

  defp normalize_optional_reasoning_effort(_effort, id) do
    {:error,
     Tool.error(
       :invalid_args,
       "workflow step reasoning_effort must be one of: low, medium, high, xhigh",
       %{
         "id" => id,
         "field" => "reasoning_effort",
         "allowed" => ~w(low medium high xhigh)
       }
     )}
  end

  defp normalize_optional_attachments(nil, _id, _workspace), do: {:ok, []}

  # Paths convert to the resource_link maps the Subagent opts channel accepts,
  # through the canonical ADR 0021 rule (workspace-relative, local-only) shared
  # with the delegate task surface. Existence is checked at ingestion.
  defp normalize_optional_attachments(attachments, id, workspace)
       when is_list(attachments) do
    attachments
    |> Enum.reduce_while({:ok, []}, fn attachment, {:ok, acc} ->
      if is_binary(attachment) do
        case SessionResources.local_attachment_link(attachment, workspace) do
          {:ok, link} -> {:cont, {:ok, [link | acc]}}
          {:error, reason} -> {:halt, invalid_optional_attachments(id, reason)}
        end
      else
        {:halt, invalid_optional_attachments(id, :not_a_string)}
      end
    end)
    |> case do
      {:ok, links} -> {:ok, Enum.reverse(links)}
      {:error, _} = error -> error
    end
  end

  defp normalize_optional_attachments(_attachments, id, _workspace),
    do: invalid_optional_attachments(id, :not_a_list)

  defp invalid_optional_attachments(id, reason) do
    {:error,
     Tool.error(
       :invalid_args,
       "workflow step attachments must be a list of local paths or file:// URIs",
       %{
         "id" => id,
         "field" => "attachments",
         "reason" => to_string(reason)
       }
     )}
  end

  # virtual_overlay steps never spawn Subagents, so accepting these knobs there
  # would make the dry-run plan advertise settings the run ignores.
  defp validate_knobs_apply("virtual_overlay", model, reasoning_effort, attachments, id)
       when model != nil or reasoning_effort != nil or attachments != [] do
    {:error,
     Tool.error(
       :invalid_args,
       "virtual_overlay workflow steps do not take model, reasoning_effort, or attachments",
       %{
         "id" => id,
         "next_actions" => ["remove_the_knobs_or_use_a_subagent_step"]
       }
     )}
  end

  defp validate_knobs_apply(_workspace_mode, _model, _effort, _attachments, _id), do: :ok

  defp normalize_workspace_mode(mode, id) do
    WorkspaceStrategy.normalize_runtime_mode(mode, "workflow step", %{"id" => id},
      supported_modes: @workflow_workspace_modes
    )
  end

  defp normalize_read_set(raw, _read_only?, "virtual_overlay", id) do
    if has_field?(raw, "read_set") do
      case field(raw, "read_set") do
        value when is_list(value) or is_binary(value) ->
          read_set = if is_binary(value), do: [value], else: value

          case VirtualOverlay.validate_read_set(read_set) do
            :ok ->
              {:ok, read_set |> Enum.map(&String.trim/1) |> Enum.uniq()}

            {:error, :read_set_required} ->
              {:error,
               Tool.error(:invalid_args, "virtual_overlay workflow step requires read_set", %{
                 "id" => id,
                 "field" => "read_set"
               })}

            {:error, %{index: index, reason: reason, kind: kind}} ->
              {:error,
               Tool.error(:invalid_args, workflow_read_set_message(kind), %{
                 "id" => id,
                 "field" => "read_set",
                 "index" => index,
                 "reason" => reason,
                 "value" => inspect(Enum.at(read_set, index)),
                 "next_actions" => ["provide_bounded_read_set"]
               })}
          end

        value ->
          {:error,
           Tool.error(:invalid_args, "virtual_overlay read_set must be a string or list", %{
             "id" => id,
             "field" => "read_set",
             "value" => inspect(value)
           })}
      end
    else
      {:error,
       Tool.error(:invalid_args, "virtual_overlay workflow step requires read_set", %{
         "id" => id,
         "field" => "read_set"
       })}
    end
  end

  defp normalize_read_set(raw, read_only?, _workspace_mode, _id),
    do: {:ok, normalize_set(field(raw, "read_set", if(read_only?, do: [@wildcard], else: [])))}

  defp workflow_read_set_message(:unbounded_read_set),
    do: "virtual_overlay read_set cannot import the whole workspace"

  defp workflow_read_set_message(_kind), do: "virtual_overlay read_set entry is invalid"

  defp normalize_virtual_commands(raw, "virtual_overlay", id) do
    case field(raw, "virtual_commands") do
      commands when is_list(commands) ->
        commands = commands |> Enum.map(&trim_virtual_command/1) |> Enum.reject(&(&1 == ""))

        cond do
          commands == [] ->
            virtual_commands_error(id, "must contain at least one command")

          Enum.all?(commands, &is_binary/1) ->
            {:ok, commands}

          true ->
            virtual_commands_error(id, "must be a list of strings")
        end

      value ->
        {:error,
         Tool.error(:invalid_args, "virtual_overlay workflow step requires virtual_commands", %{
           "id" => id,
           "field" => "virtual_commands",
           "value" => inspect(value)
         })}
    end
  end

  defp normalize_virtual_commands(raw, _workspace_mode, id) do
    if has_field?(raw, "virtual_commands") do
      {:error,
       Tool.error(:invalid_args, "virtual_commands require workspace_mode virtual_overlay", %{
         "id" => id,
         "field" => "virtual_commands"
       })}
    else
      {:ok, []}
    end
  end

  defp trim_virtual_command(command) when is_binary(command), do: String.trim(command)
  defp trim_virtual_command(command), do: command

  defp virtual_commands_error(id, reason) do
    {:error,
     Tool.error(:invalid_args, "virtual_overlay virtual_commands #{reason}", %{
       "id" => id,
       "field" => "virtual_commands"
     })}
  end

  defp normalize_virtual_limits(raw, "virtual_overlay", id) do
    case field(raw, "limits") do
      nil ->
        {:ok, nil}

      limits when is_map(limits) ->
        {:ok, limits}

      value ->
        {:error,
         Tool.error(:invalid_args, "virtual_overlay limits must be an object", %{
           "id" => id,
           "field" => "limits",
           "value" => inspect(value)
         })}
    end
  end

  defp normalize_virtual_limits(_raw, _workspace_mode, _id), do: {:ok, nil}

  defp step_posture("virtual_overlay", _read_only?), do: "virtual_scratch"
  defp step_posture(_workspace_mode, true), do: "read_only"
  defp step_posture(_workspace_mode, false), do: "writer"

  defp step_permission_mode("virtual_overlay", _read_only?, _opts), do: :read_only
  defp step_permission_mode(_workspace_mode, true, _opts), do: :read_only

  defp step_permission_mode(_workspace_mode, false, opts),
    do: Keyword.get(opts, :permission_mode, :auto)

  defp normalize_write_set(_raw, _read_only?, "virtual_overlay", _id, _opts), do: {:ok, []}
  defp normalize_write_set(_raw, true, _workspace_mode, _id, _opts), do: {:ok, []}

  defp normalize_write_set(raw, false, _workspace_mode, id, opts) do
    policy = Keyword.get(opts, :write_policy)

    cond do
      policy && not has_field?(raw, "write_set") ->
        {:error,
         Tool.error(:invalid_args, "bounded write workflow writer step requires write_set", %{
           "id" => id,
           "field" => "write_set",
           "next_actions" => ["add_explicit_write_set", "split_read_only_steps_from_writer_steps"]
         })}

      true ->
        set = normalize_set(field(raw, "write_set", [@wildcard]))

        case {policy, set} do
          {%{}, []} ->
            {:error,
             Tool.error(:invalid_args, "bounded write workflow writer step requires write_set", %{
               "id" => id,
               "field" => "write_set",
               "next_actions" => [
                 "add_non_empty_write_set",
                 "split_read_only_steps_from_writer_steps"
               ]
             })}

          {nil, []} ->
            {:ok, [@wildcard]}

          {_policy, set} ->
            {:ok, set}
        end
    end
  end

  defp step_write_policy(nil, _write_set, _read_only?), do: {:ok, nil}
  defp step_write_policy(policy, _write_set, true), do: {:ok, policy}
  defp step_write_policy(policy, [], _read_only?), do: {:ok, policy}

  defp step_write_policy(policy, write_set, false) do
    WritePolicy.narrow_to_write_set(policy, write_set)
  end

  defp read_only_step?(raw, agent_config) do
    value =
      field(raw, "permission_mode") || field(raw, "sandbox_mode") || agent_config[:sandbox_mode]

    read_only_mode?(value)
  end

  defp validate_step_read_only_agent_gate(nil, _workspace_mode, _read_only?, _agent, _id, _index),
    do: :ok

  defp validate_step_read_only_agent_gate(
         _policy,
         workspace_mode,
         false,
         %{sandbox_mode: mode, name: role},
         id,
         index
       ) do
    if workspace_mode != "virtual_overlay" and read_only_mode?(mode) do
      {:error,
       Tool.error(
         :invalid_spec,
         "bounded_write conflicts with the read-only workflow step agent",
         %{
           "id" => id,
           "role" => role,
           "role_sandbox_mode" => mode,
           "mode" => "bounded_write",
           "location" => "/steps/#{index - 1}/agent",
           "next_actions" => ["use_a_write_capable_role", "make_the_step_read_only"]
         }
       )}
    else
      :ok
    end
  end

  defp validate_step_read_only_agent_gate(
         _policy,
         _workspace_mode,
         _read_only?,
         _agent,
         _id,
         _index
       ),
       do: :ok

  defp read_only_mode?(value), do: value in [:read_only, "read_only", "read-only"]

  defp validate_unique_step_ids(steps) do
    ids = Enum.map(steps, & &1.id)

    case ids -- Enum.uniq(ids) do
      [] ->
        :ok

      duplicates ->
        {:error,
         Tool.error(:invalid_args, "workflow step ids must be unique", %{
           duplicates: Enum.uniq(duplicates)
         })}
    end
  end

  defp validate_dependencies(steps) do
    ids = MapSet.new(Enum.map(steps, & &1.id))

    missing =
      steps
      |> Enum.flat_map(fn step ->
        step.depends_on
        |> Enum.reject(&MapSet.member?(ids, &1))
        |> Enum.map(&%{"step" => step.id, "missing_dependency" => &1})
      end)

    cond do
      missing != [] ->
        {:error,
         Tool.error(:invalid_args, "workflow has unknown dependencies", %{missing: missing})}

      cycle?(steps) ->
        {:error, Tool.error(:invalid_args, "workflow dependency graph contains a cycle", %{})}

      true ->
        :ok
    end
  end

  defp cycle?(steps) do
    remaining = Map.new(steps, &{&1.id, MapSet.new(&1.depends_on)})
    remove_ready(remaining) != %{}
  end

  defp remove_ready(remaining) when map_size(remaining) == 0, do: remaining

  defp remove_ready(remaining) do
    ready =
      remaining
      |> Enum.filter(fn {_id, deps} -> MapSet.size(deps) == 0 end)
      |> Enum.map(&elem(&1, 0))

    if ready == [] do
      remaining
    else
      ready_set = MapSet.new(ready)

      remaining
      |> Map.drop(ready)
      |> Map.new(fn {id, deps} -> {id, MapSet.difference(deps, ready_set)} end)
      |> remove_ready()
    end
  end

  defp plan_waves(workflow) do
    do_plan_waves(workflow.steps, %{}, [], workflow.max_concurrency)
  end

  defp do_plan_waves([], _completed, waves, _max_concurrency), do: {:ok, Enum.reverse(waves)}

  defp do_plan_waves(pending, completed, waves, max_concurrency) do
    {wave, rest} = choose_runnable(pending, completed, [], max_concurrency)

    if wave == [] do
      {:error,
       Tool.error(:invalid_args, "workflow cannot make progress", %{
         pending: Enum.map(pending, & &1.id)
       })}
    else
      completed =
        Enum.reduce(wave, completed, fn step, acc ->
          Map.put(acc, step.id, %{
            "status" => "planned",
            "checkpoint_status" => "checkpoint_ready"
          })
        end)

      do_plan_waves(rest, completed, [Enum.map(wave, & &1.id) | waves], max_concurrency)
    end
  end

  defp run_loop(parent_sid, workflow, state, opts) do
    if deadline_exceeded?(workflow, state) do
      with {:ok, state} <- timeout_active_and_hold_pending(workflow, parent_sid, state) do
        finish_workflow_result(parent_sid, workflow, state)
      end
    else
      with {:ok, state, started} <- start_runnable(parent_sid, workflow, state, opts) do
        cond do
          state.pending == [] and state.active == %{} ->
            finish_workflow_result(parent_sid, workflow, state)

          state.active == %{} and started == [] ->
            with {:ok, state} <-
                   hold_pending(state, parent_sid, workflow, "dependency_not_checkpoint_ready") do
              finish_workflow_result(parent_sid, workflow, state)
            end

          true ->
            active_ids = state.active |> Map.values() |> Enum.map(& &1.agent_id)

            with {:ok, agents} <-
                   Subagents.wait(parent_sid, active_ids, workflow.poll_ms,
                     workspace: workflow.workspace
                   ),
                 {:ok, state} <- absorb_poll(parent_sid, workflow, state, agents) do
              run_loop(parent_sid, workflow, state, opts)
            end
        end
      end
    end
  end

  defp start_runnable(parent_sid, workflow, state, opts) do
    capacity = max(workflow.max_concurrency - map_size(state.active), 0)
    completed = state.completed
    active_steps = state.active |> Map.values() |> Enum.map(& &1.step)
    {candidates, pending} = choose_runnable(state.pending, completed, active_steps, capacity)
    wave = if candidates == [], do: state.wave, else: state.wave + 1

    Enum.reduce_while(candidates, {:ok, %{state | pending: pending, wave: wave}, []}, fn step,
                                                                                         {:ok,
                                                                                          acc,
                                                                                          started} ->
      with :ok <-
             record_workflow_event(
               parent_sid,
               "step_scheduled",
               step_scheduled_data(workflow, step, wave)
             ),
           {:ok, started_step} <-
             start_step(parent_sid, workflow, step, wave, opts, acc.completed, acc.started_at_ms) do
        case started_step do
          {:active, record} ->
            active = Map.put(acc.active, step.id, record)
            waves = put_wave(acc.waves, wave, step.id)
            {:cont, {:ok, %{acc | active: active, waves: waves}, [step.id | started]}}

          {:completed, completed_step} ->
            waves = put_wave(acc.waves, wave, step.id)

            acc = %{
              acc
              | completed: Map.put(acc.completed, step.id, completed_step),
                completed_order: acc.completed_order ++ [step.id],
                waves: waves
            }

            case record_checkpoint_decided(parent_sid, workflow, completed_step) do
              :ok -> {:cont, {:ok, acc, [step.id | started]}}
              {:error, error} -> {:halt, {:error, error}}
            end
        end
      else
        {:error, error} ->
          {:halt, {:error, error}}
      end
    end)
  end

  defp choose_runnable(pending, _completed, _active_steps, capacity) when capacity <= 0,
    do: {[], pending}

  defp choose_runnable(pending, completed, active_steps, capacity) do
    Enum.reduce(pending, {[], [], active_steps, capacity}, fn step,
                                                              {chosen, rest, occupied, slots} ->
      cond do
        slots <= 0 ->
          {chosen, rest ++ [step], occupied, slots}

        not deps_ready?(step, completed) ->
          {chosen, rest ++ [step], occupied, slots}

        conflicts_with_any?(step, occupied) ->
          {chosen, rest ++ [step], occupied, slots}

        true ->
          {chosen ++ [step], rest, occupied ++ [step], slots - 1}
      end
    end)
    |> then(fn {chosen, rest, _occupied, _slots} -> {chosen, rest} end)
  end

  defp deps_ready?(%{posture: "apply", apply_from: apply_from} = step, completed) do
    Enum.all?(step.depends_on, fn
      ^apply_from -> Map.has_key?(completed, apply_from)
      dep -> get_in(completed, [dep, "checkpoint_status"]) == "checkpoint_ready"
    end)
  end

  defp deps_ready?(step, completed),
    do:
      Enum.all?(step.depends_on, fn dep ->
        get_in(completed, [dep, "checkpoint_status"]) == "checkpoint_ready"
      end)

  defp start_step(
         _parent_sid,
         workflow,
         %{posture: "apply"} = step,
         wave,
         opts,
         completed,
         run_started_at_ms
       ) do
    {:ok,
     {:completed,
      apply_virtual_diff_step(workflow, step, wave, completed, run_started_at_ms, opts)}}
  end

  defp start_step(
         _parent_sid,
         workflow,
         %{workspace_mode: "virtual_overlay"} = step,
         wave,
         opts,
         _completed,
         run_started_at_ms
       ) do
    params =
      %{
        "read_set" => step.read_set,
        "commands" => step.virtual_commands
      }
      |> maybe_put("limits", step.virtual_limits)

    case run_virtual_overlay(workflow, step, params, opts, run_started_at_ms) do
      {:ok, artifact} ->
        {:ok, {:completed, virtual_completed_step(workflow, step, wave, artifact)}}

      {:timeout, reason, timeout_ms, elapsed_ms} ->
        {:ok,
         {:completed,
          virtual_timed_out_step(workflow, step, wave, reason, timeout_ms, elapsed_ms)}}

      {:error, error} ->
        {:error, error}
    end
  end

  defp start_step(parent_sid, workflow, step, wave, opts, completed, _run_started_at_ms) do
    with {:ok, record} <- spawn_step(parent_sid, workflow, step, wave, opts, completed) do
      {:ok, {:active, record}}
    end
  end

  defp run_virtual_overlay(workflow, step, params, opts, run_started_at_ms) do
    {timeout_ms, timeout_reason} = virtual_timeout_budget(workflow, step, run_started_at_ms)
    runner = Keyword.get(opts, :virtual_overlay_runner, &VirtualOverlay.run/3)

    if timeout_ms <= 0 do
      {:timeout, timeout_reason, timeout_ms, 0}
    else
      started_at = now_ms()

      result =
        yield_interrupt_coupled_task(
          fn -> runner.(workflow.workspace, params, []) end,
          timeout_ms
        )

      case result do
        {:ok, {:ok, artifact}} ->
          {:ok, artifact}

        {:ok, {:error, error}} ->
          {:error, error}

        {:exit, reason} ->
          {:error,
           Tool.error(:command_failed, "virtual_overlay runner task exited", %{
             "reason" => "virtual_overlay_runner_task_exit",
             "exit_reason" => bounded_task_exit_reason(reason)
           })}

        nil ->
          {:timeout, timeout_reason, timeout_ms, max(now_ms() - started_at, 0)}
      end
    end
  end

  defp virtual_timeout_budget(workflow, step, run_started_at_ms) do
    remaining_ms = max(workflow.timeout_ms - max(now_ms() - run_started_at_ms, 0), 0)

    case step.timeout_ms do
      timeout_ms when is_integer(timeout_ms) and timeout_ms < remaining_ms ->
        {timeout_ms, "step_timeout"}

      _ ->
        {remaining_ms, "workflow_timeout"}
    end
  end

  defp spawn_step(parent_sid, workflow, step, wave, opts, completed) do
    prompt = render_step_prompt(workflow, step, completed)

    args =
      %{
        "task" => prompt,
        "agent" => step.agent,
        "workspace_mode" => step.workspace_mode,
        "max_threads" => workflow.max_concurrency
      }
      |> maybe_put("timeout_ms", step.timeout_ms)

    subagent_opts =
      opts
      # Step knobs are the only source for these keys: inherited caller opts
      # must not reach children the dry-run plan showed as knobless. The
      # spawn_agent test seam never travels to the child either.
      |> Keyword.drop([:model, :reasoning_effort, :attachments, :spawn_agent])
      |> Keyword.put(:workspace, workflow.workspace)
      |> Keyword.put(:permission_mode, step.permission_mode)
      |> Keyword.put(:write_policy, step.write_policy)
      |> keyword_put_if_present(:model, step.model)
      |> keyword_put_if_present(:reasoning_effort, step.reasoning_effort)
      |> keyword_put_if_present(:attachments, step.attachments)
      |> Keyword.put(
        :delegation_context,
        workflow_delegation_context(workflow, step, wave, completed)
      )

    spawn_agent = Keyword.get(opts, :spawn_agent, &Subagents.spawn_agent/3)

    with {:ok, agent} <- spawn_agent.(parent_sid, args, subagent_opts) do
      {:ok,
       %{
         step: step,
         agent_id: agent["id"],
         agent: agent,
         wave: wave,
         started_at_ms: now_ms(),
         workflow_timeout_ms: workflow.timeout_ms
       }}
    end
  end

  defp apply_virtual_diff_step(workflow, step, wave, completed, run_started_at_ms, opts) do
    result =
      with {:ok, artifact} <- producer_virtual_diff(completed, step.apply_from),
           :ok <- artifact_paths_within_step_write_set(artifact, step),
           {:ok, apply_result} <-
             apply_with_budget(workflow, step, artifact, run_started_at_ms, opts) do
        apply_result
      else
        {:error, reason, details} -> failed_apply_result(reason, details)
        {:error, error} -> failed_apply_result("failed", %{"error" => error})
      end

    apply_result_step(workflow, step, wave, result)
  end

  # The normalized step timeout_ms is a real budget (same contract as
  # virtual_overlay steps), not an accepted-and-ignored knob.
  defp apply_with_budget(workflow, step, artifact, run_started_at_ms, opts) do
    {timeout_ms, timeout_reason} = virtual_timeout_budget(workflow, step, run_started_at_ms)

    if timeout_ms <= 0 do
      {:error, "timeout", %{"reason" => timeout_reason, "timeout_ms" => timeout_ms}}
    else
      runner = Keyword.get(opts, :virtual_diff_apply_runner, &VirtualDiffApply.apply/3)

      result =
        yield_interrupt_coupled_task(
          fn ->
            runner.(artifact, workflow.workspace, write_policy: workflow.write_policy)
          end,
          timeout_ms
        )

      case result do
        {:ok, {:ok, apply_result}} ->
          {:ok, apply_result}

        {:ok, {:error, error}} ->
          {:error, error}

        {:exit, reason} ->
          {:error, "virtual_diff_apply_task_exit",
           %{
             "reason" => "virtual_diff_apply_task_exit",
             "exit_reason" => bounded_task_exit_reason(reason)
           }}

        nil ->
          {:error, "timeout", %{"reason" => timeout_reason, "timeout_ms" => timeout_ms}}
      end
    end
  end

  # A dedicated supervisor gives these tasks the two lifecycle properties they
  # need at the same time:
  #
  #   * the task is not linked to the workflow process, so Task.yield/2 reports
  #     a runner crash as {:exit, reason};
  #   * the supervisor is linked to the workflow process and owns the task, so
  #     killing an interruptible Turn tears the supervisor and its task down.
  #
  # The latter does not depend on an `after` block running in the killed Turn.
  # `shutdown: :brutal_kill` also prevents an exit-trapping runner from delaying
  # teardown after its owning Turn is interrupted.
  defp yield_interrupt_coupled_task(fun, timeout_ms) do
    {:ok, supervisor} = Task.Supervisor.start_link(shutdown: :brutal_kill)

    try do
      task = Task.Supervisor.async_nolink(supervisor, fun)
      Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill)
    after
      if Process.alive?(supervisor), do: Supervisor.stop(supervisor, :normal)
    end
  end

  defp producer_virtual_diff(completed, apply_from) do
    case Map.get(completed, apply_from) do
      %{"checkpoint_status" => "checkpoint_ready", "virtual_diff" => artifact}
      when is_map(artifact) ->
        {:ok, artifact}

      _other ->
        {:error, "producer_did_not_yield_virtual_diff", %{"apply_from" => apply_from}}
    end
  end

  defp artifact_paths_within_step_write_set(%{"changes" => changes}, step)
       when is_list(changes) do
    outside =
      changes
      |> Enum.map(&Map.get(&1, "path"))
      |> Enum.reject(&write_set_covers_path?(step.write_set, &1))

    if outside == [] do
      :ok
    else
      {:error, "artifact_path_outside_step_write_set",
       %{"paths" => outside, "write_set" => step.write_set}}
    end
  end

  defp artifact_paths_within_step_write_set(_artifact, step),
    do: {:error, "producer_did_not_yield_virtual_diff", %{"apply_from" => step.apply_from}}

  defp write_set_covers_path?(write_set, path) when is_binary(path) do
    path = normalize_path_token(path)
    WritePolicy.rules_cover_path?(write_set, path)
  end

  defp write_set_covers_path?(_write_set, _path), do: false

  defp failed_apply_result(reason, details) do
    %{
      "kind" => "virtual_diff_apply",
      "version" => 1,
      "dry_run" => false,
      "status" => "failed",
      "reason" => reason,
      "details" => details,
      "counts" => %{"files" => 0, "applied" => 0}
    }
  end

  defp apply_result_step(workflow, step, wave, result) do
    applied? = result["status"] == "applied"
    summary = apply_result_summary(result)

    %{
      "id" => step.id,
      "step_id" => step.id,
      "agent_id" => nil,
      "child_session_id" => nil,
      "agent" => nil,
      "status" => if(applied?, do: "completed", else: "failed"),
      "subagent_status" => "not_applicable",
      "checkpoint_status" => if(applied?, do: "checkpoint_ready", else: "failed"),
      "summary" => summary,
      "wave" => wave,
      "posture" => step.posture,
      "read_set" => step.read_set,
      "write_set" => step.write_set,
      "workspace" => workflow.workspace,
      "workspace_mode" => step.workspace_mode,
      "apply_from" => step.apply_from,
      "virtual_diff_apply" => result,
      "checkpoint" => apply_checkpoint_bundle(step, result, summary, applied?),
      "safe_next_actions" => if(applied?, do: [], else: ["inspect_virtual_diff_apply"])
    }
    |> put_write_policy_metadata(step)
  end

  defp apply_checkpoint_bundle(step, result, summary, dependent_safe?) do
    %{
      "step_id" => step.id,
      "agent_id" => nil,
      "child_session_id" => nil,
      "status" => if(dependent_safe?, do: "checkpoint_ready", else: "failed"),
      "dependent_safe" => dependent_safe?,
      "summary" => summary,
      "known_limitations" => if(dependent_safe?, do: [], else: ["virtual_diff_not_applied"]),
      "verification" => %{
        "source" => "virtual_diff_apply_engine",
        "apply_from" => step.apply_from,
        "apply_status" => result["status"]
      },
      "virtual_diff_apply" => result
    }
    |> checkpoint_bundle_v2([artifact_ref(result)])
  end

  defp apply_result_summary(result) do
    counts = result["counts"] || %{}
    file_count = Map.get(counts, "files", length(result["files"] || []))

    "virtual_diff_apply status=#{result["status"]}: " <>
      "#{Map.get(counts, "applied", 0)} applied of #{file_count} files."
  end

  defp virtual_completed_step(workflow, step, wave, artifact) do
    summary = virtual_step_summary(artifact)

    %{
      "id" => step.id,
      "step_id" => step.id,
      "agent_id" => nil,
      "child_session_id" => nil,
      "agent" => step.agent,
      "status" => "completed",
      "subagent_status" => "not_applicable",
      "checkpoint_status" => "checkpoint_ready",
      "summary" => summary,
      "wave" => wave,
      "posture" => step.posture,
      "read_set" => step.read_set,
      "write_set" => step.write_set,
      "workspace" => workflow.workspace,
      "workspace_mode" => step.workspace_mode,
      "virtual_commands" => step.virtual_commands,
      "virtual_diff" => artifact,
      "checkpoint" => virtual_checkpoint_bundle(step, artifact, summary),
      "safe_next_actions" => []
    }
    |> put_write_policy_metadata(step)
  end

  defp virtual_timed_out_step(workflow, step, wave, reason, timeout_ms, elapsed_ms) do
    summary = "virtual_overlay timed out before producing virtual_diff."

    %{
      "id" => step.id,
      "step_id" => step.id,
      "agent_id" => nil,
      "child_session_id" => nil,
      "agent" => step.agent,
      "status" => "timed_out",
      "subagent_status" => "not_applicable",
      "checkpoint_status" => "failed",
      "summary" => summary,
      "wave" => wave,
      "posture" => step.posture,
      "read_set" => step.read_set,
      "write_set" => step.write_set,
      "workspace" => workflow.workspace,
      "workspace_mode" => step.workspace_mode,
      "virtual_commands" => step.virtual_commands,
      "timeout_ms" => timeout_ms,
      "workflow_timeout_ms" => workflow.timeout_ms,
      "step_timeout_ms" => step.timeout_ms,
      "elapsed_ms" => elapsed_ms,
      "reason" => reason,
      "checkpoint" => virtual_timeout_checkpoint_bundle(step, summary, reason, timeout_ms),
      "safe_next_actions" => ["retry_workflow_with_larger_timeout"]
    }
    |> put_write_policy_metadata(step)
  end

  defp virtual_timeout_checkpoint_bundle(step, summary, reason, timeout_ms) do
    %{
      "step_id" => step.id,
      "agent_id" => nil,
      "child_session_id" => nil,
      "status" => "failed",
      "dependent_safe" => false,
      "summary" => summary,
      "known_limitations" => ["virtual_overlay_timeout", "virtual_diff_not_produced"],
      "verification" => %{
        "source" => "virtual_overlay_runner",
        "workspace_strategy" => "virtual_overlay",
        "workspace_fidelity" => "virtual_shell_no_host_binaries",
        "timeout_ms" => timeout_ms,
        "reason" => reason
      }
    }
    |> checkpoint_bundle_v2([])
  end

  defp virtual_checkpoint_bundle(step, artifact, summary) do
    %{
      "step_id" => step.id,
      "agent_id" => nil,
      "child_session_id" => nil,
      "status" => "checkpoint_ready",
      "dependent_safe" => true,
      "summary" => summary,
      "known_limitations" => ["virtual_diff_not_applied"],
      "verification" => %{
        "source" => "virtual_overlay_runner",
        "workspace_strategy" => artifact["workspace_strategy"],
        "workspace_fidelity" => artifact["workspace_fidelity"],
        "parent_workspace_mutation" => get_in(artifact, ["parent_workspace", "mutation"]),
        "apply_status" => get_in(artifact, ["apply", "status"])
      },
      "virtual_diff" => artifact
    }
    |> checkpoint_bundle_v2([artifact_ref(artifact)])
  end

  defp virtual_step_summary(artifact) do
    summary = artifact["summary"] || %{}
    apply_status = get_in(artifact, ["apply", "status"]) || "not_applied"

    "virtual_overlay produced virtual_diff: " <>
      "#{Map.get(summary, "files_added", 0)} added, " <>
      "#{Map.get(summary, "files_modified", 0)} modified, " <>
      "#{Map.get(summary, "files_deleted", 0)} deleted, " <>
      "#{Map.get(summary, "files_unsupported", 0)} unsupported; " <>
      "apply_status=#{apply_status}."
  end

  defp checkpoint_bundle_v2(bundle, artifacts) do
    bundle
    |> Map.put("version", 2)
    |> Map.put("typed_payloads", [workflow_checkpoint_payload(bundle)])
    |> Map.put("artifacts", artifacts)
  end

  defp workflow_checkpoint_payload(bundle) do
    %{
      "schema_id" => "workflow_checkpoint.v1",
      "provenance" => "harness_projection",
      "validation" => %{"status" => "valid", "validated_at" => "runtime"},
      "payload" => %{
        "step_id" => bundle["step_id"],
        "agent_id" => bundle["agent_id"],
        "child_session_id" => bundle["child_session_id"],
        "checkpoint_status" => bundle["status"],
        "dependent_safe" => bundle["dependent_safe"],
        "known_limitations" => bundle["known_limitations"] || [],
        "verification_source" => get_in(bundle, ["verification", "source"])
      }
    }
  end

  defp artifact_ref(%{"kind" => kind} = artifact) do
    %{
      "schema_id" => "artifact_ref.v1",
      "provenance" => "artifact",
      "validation" => %{"status" => "valid", "validated_at" => "runtime"},
      "kind" => kind,
      "version" => artifact["version"],
      "hash" => artifact_hash(artifact),
      "workspace_strategy" => artifact["workspace_strategy"]
    }
  end

  defp artifact_ref(artifact), do: artifact_ref(Map.put(artifact, "kind", "unknown"))

  defp artifact_hash(artifact) do
    artifact
    |> canonical_json()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

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

  defp absorb_poll(parent_sid, workflow, state, agents) do
    by_agent =
      state.active
      |> Enum.map(fn {step_id, record} -> {record.agent_id, step_id} end)
      |> Map.new()

    Enum.reduce_while(agents, {:ok, state}, fn agent, {:ok, acc} ->
      case Map.fetch(by_agent, agent["id"]) do
        :error ->
          {:cont, {:ok, acc}}

        {:ok, step_id} ->
          if Subagents.terminal?(agent["status"]) do
            record = Map.fetch!(acc.active, step_id)
            completed_step = complete_record(record, agent)

            case record_checkpoint_decided(parent_sid, workflow, completed_step) do
              :ok ->
                acc = %{
                  acc
                  | active: Map.delete(acc.active, step_id),
                    completed: Map.put(acc.completed, step_id, completed_step),
                    completed_order: acc.completed_order ++ [step_id]
                }

                {:cont, {:ok, acc}}

              {:error, error} ->
                {:halt, {:error, error}}
            end
          else
            {:cont, {:ok, acc}}
          end
      end
    end)
  end

  defp complete_record(record, agent) do
    checkpoint_status = checkpoint_status(record.step, agent)

    %{
      "id" => record.step.id,
      "step_id" => record.step.id,
      "agent_id" => record.agent_id,
      "child_session_id" => agent["child_session_id"],
      "agent" => record.step.agent,
      "status" => agent["status"],
      "subagent_status" => agent["status"],
      "checkpoint_status" => checkpoint_status,
      "summary" => agent["summary"] || "",
      "wave" => record.wave,
      "posture" => record.step.posture,
      "read_set" => record.step.read_set,
      "write_set" => record.step.write_set,
      "workspace" => agent["workspace"],
      "workspace_mode" => record.step.workspace_mode,
      "checkpoint" => checkpoint_bundle(record, agent, checkpoint_status),
      "safe_next_actions" => step_safe_next_actions(checkpoint_status, agent["status"])
    }
    |> put_write_policy_metadata(record.step)
    |> Map.merge(timeout_step_fields(agent))
  end

  defp workflow_result(workflow, state) do
    steps = Enum.map(workflow.steps, &Map.fetch!(state.completed, &1.id))
    status = workflow_status(steps)
    completed? = status == "completed"

    %{
      "ok" => completed?,
      "mode" => "run",
      "workflow_id" => workflow.id,
      "template" => template_metadata(workflow),
      "status" => status,
      "proof_states" => if(completed?, do: @proof_states, else: @partial_proof_states),
      "waves" => state.waves,
      "steps" => steps,
      "usable_checkpoints" =>
        steps
        |> Enum.filter(&(&1["checkpoint_status"] == "checkpoint_ready"))
        |> Enum.map(& &1["checkpoint"]),
      "held_steps" => Enum.filter(steps, &(&1["checkpoint_status"] == "held")),
      "failed_steps" => Enum.filter(steps, &(&1["checkpoint_status"] == "failed")),
      "timeout_steps" => Enum.filter(steps, &(&1["status"] == "timed_out")),
      "partial_steps" => Enum.filter(steps, &(&1["checkpoint_status"] == "partial")),
      "needs_orchestrator_steps" =>
        Enum.filter(steps, &(&1["checkpoint_status"] == "needs_orchestrator")),
      "safe_next_actions" => workflow_safe_next_actions(status, steps),
      "summary" => %{
        "steps" => length(steps),
        "waves" => length(state.waves),
        "read_only_steps" => Enum.count(steps, &(&1["posture"] == "read_only")),
        "writer_steps" => Enum.count(steps, &(&1["posture"] == "writer")),
        "virtual_overlay_steps" =>
          Enum.count(steps, &(&1["workspace_mode"] == "virtual_overlay")),
        "checkpoint_ready_steps" =>
          Enum.count(steps, &(&1["checkpoint_status"] == "checkpoint_ready")),
        "held_steps" => Enum.count(steps, &(&1["checkpoint_status"] == "held")),
        "failed_steps" => Enum.count(steps, &(&1["checkpoint_status"] == "failed")),
        "timeout_steps" => Enum.count(steps, &(&1["status"] == "timed_out")),
        "partial_steps" => Enum.count(steps, &(&1["checkpoint_status"] == "partial")),
        "needs_orchestrator_steps" =>
          Enum.count(steps, &(&1["checkpoint_status"] == "needs_orchestrator"))
      }
    }
  end

  defp workflow_status(steps) do
    if Enum.all?(steps, &(&1["checkpoint_status"] == "checkpoint_ready")) do
      "completed"
    else
      "partial"
    end
  end

  defp checkpoint_status(_step, %{"status" => "completed", "summary" => summary})
       when is_binary(summary) do
    marker =
      Regex.run(
        ~r/checkpoint_status:\s*(checkpoint_ready|partial|failed|needs_orchestrator)/i,
        summary,
        capture: :all_but_first
      )

    case marker do
      [status] -> String.downcase(status)
      _ -> "checkpoint_ready"
    end
  end

  defp checkpoint_status(_step, %{"status" => "completed"}), do: "checkpoint_ready"
  defp checkpoint_status(_step, _agent), do: "failed"

  defp checkpoint_bundle(record, agent, "checkpoint_ready") do
    %{
      "step_id" => record.step.id,
      "agent_id" => record.agent_id,
      "child_session_id" => agent["child_session_id"],
      "status" => "checkpoint_ready",
      "dependent_safe" => true,
      "summary" => Tool.truncate(agent["summary"] || ""),
      "known_limitations" => [],
      "verification" => %{
        "source" => "subagent_terminal_summary",
        "subagent_status" => agent["status"]
      }
    }
    |> put_timeout_verification(agent)
    |> checkpoint_bundle_v2([])
  end

  defp checkpoint_bundle(record, agent, checkpoint_status) do
    %{
      "step_id" => record.step.id,
      "agent_id" => record.agent_id,
      "child_session_id" => agent["child_session_id"],
      "status" => checkpoint_status,
      "dependent_safe" => false,
      "summary" => Tool.truncate(agent["summary"] || ""),
      "known_limitations" => ["checkpoint_not_ready"],
      "verification" => %{
        "source" => "subagent_terminal_summary",
        "subagent_status" => agent["status"]
      }
    }
    |> put_timeout_verification(agent)
    |> checkpoint_bundle_v2([])
  end

  defp held_record(step, reason) do
    %{
      "id" => step.id,
      "step_id" => step.id,
      "agent_id" => nil,
      "child_session_id" => nil,
      "agent" => step.agent,
      "status" => "held",
      "subagent_status" => "held",
      "checkpoint_status" => "held",
      "summary" => "Held: #{reason}.",
      "wave" => nil,
      "posture" => step.posture,
      "read_set" => step.read_set,
      "write_set" => step.write_set,
      "workspace" => nil,
      "workspace_mode" => step.workspace_mode,
      "held_reason" => reason,
      "checkpoint" =>
        %{
          "step_id" => step.id,
          "agent_id" => nil,
          "child_session_id" => nil,
          "status" => "held",
          "dependent_safe" => false,
          "summary" => "Held: #{reason}.",
          "known_limitations" => held_known_limitations(reason),
          "verification" => %{"source" => "workflow_scheduler"}
        }
        |> checkpoint_bundle_v2([]),
      "safe_next_actions" => held_safe_next_actions(reason)
    }
    |> put_write_policy_metadata(step)
  end

  defp held_known_limitations("workflow_timeout"), do: ["workflow_timeout"]
  defp held_known_limitations(_reason), do: ["dependency_not_checkpoint_ready"]

  defp held_safe_next_actions("workflow_timeout"), do: ["retry_workflow_with_larger_timeout"]
  defp held_safe_next_actions(_reason), do: ["rerun_after_dependencies_checkpoint_ready"]

  defp timed_out_record(record, agent, reason) do
    raw_agent = agent || record.agent
    raw_status = raw_agent["status"] || record.agent["status"] || "unknown"

    agent = %{
      "id" => record.agent_id,
      "child_session_id" => raw_agent["child_session_id"] || record.agent["child_session_id"],
      "status" => "timed_out",
      "summary" => timeout_summary(raw_agent, reason),
      "timeout_ms" => raw_agent["timeout_ms"] || record.workflow_timeout_ms,
      "workflow_timeout_ms" => record.workflow_timeout_ms,
      "step_timeout_ms" => record.step.timeout_ms,
      "elapsed_ms" => timeout_elapsed_ms(raw_agent, record),
      "reason" => reason,
      "next_actions" => ["inspect_timed_out_step", "retry_workflow_with_larger_timeout"],
      "workspace" => raw_agent["workspace"] || record.agent["workspace"]
    }

    record
    |> complete_record(agent)
    |> Map.put("subagent_status", raw_status)
    |> put_in(["checkpoint", "verification", "subagent_status"], raw_status)
    |> put_in(["checkpoint", "verification", "workflow_timeout_action"], reason)
    |> update_in(["checkpoint", "known_limitations"], fn limitations ->
      limitations
      |> Kernel.||([])
      |> Kernel.++(["workflow_timeout"])
      |> Enum.uniq()
    end)
    |> maybe_mark_timeout_close_failed(reason)
    |> refresh_step_checkpoint_projection()
  end

  defp timeout_summary(agent, "closed_by_workflow_timeout") do
    base = agent["summary"] || "Timed out."
    "#{base} Workflow timeout closed the Subagent before returning."
  end

  defp timeout_summary(agent, _reason), do: agent["summary"] || "Timed out."

  defp timeout_elapsed_ms(%{"elapsed_ms" => elapsed_ms}, _record) when is_integer(elapsed_ms),
    do: elapsed_ms

  defp timeout_elapsed_ms(_agent, %{started_at_ms: started_at_ms}) when is_integer(started_at_ms),
    do: max(now_ms() - started_at_ms, 0)

  defp timeout_elapsed_ms(_agent, _record), do: nil

  defp timeout_active_record(parent_sid, workflow, record) do
    case Subagents.close(parent_sid, record.agent_id, workspace: workflow.workspace) do
      {:ok, agent} ->
        timed_out_record(record, agent, "closed_by_workflow_timeout")

      {:error, _error} ->
        timed_out_record(record, nil, "close_failed_after_workflow_timeout")
    end
  end

  defp maybe_mark_timeout_close_failed(outcome, "close_failed_after_workflow_timeout") do
    outcome
    |> Map.put("checkpoint_status", "needs_orchestrator")
    |> put_in(["checkpoint", "status"], "needs_orchestrator")
    |> update_in(["checkpoint", "known_limitations"], fn limitations ->
      limitations
      |> Kernel.||([])
      |> Kernel.++(["subagent_close_failed", "subagent_may_still_be_running"])
      |> Enum.uniq()
    end)
    |> Map.put("safe_next_actions", step_safe_next_actions("needs_orchestrator", "timed_out"))
  end

  defp maybe_mark_timeout_close_failed(outcome, _reason), do: outcome

  defp hold_pending(state, parent_sid, workflow, reason) do
    case Enum.reduce_while(state.pending, {:ok, %{}}, fn step, {:ok, acc} ->
           record = held_record(step, reason)

           with :ok <-
                  record_workflow_event(
                    parent_sid,
                    "step_held",
                    step_held_data(workflow, record, reason)
                  ),
                :ok <- record_checkpoint_decided(parent_sid, workflow, record) do
             {:cont, {:ok, Map.put(acc, step.id, record)}}
           else
             {:error, error} -> {:halt, {:error, error}}
           end
         end) do
      {:ok, held} ->
        {:ok, %{state | pending: [], completed: Map.merge(state.completed, held)}}

      {:error, _error} = error ->
        error
    end
  end

  defp timeout_active_and_hold_pending(workflow, parent_sid, state) do
    state = absorb_terminal_active(parent_sid, workflow, state)

    with {:ok, timed_out} <-
           Enum.reduce_while(state.active, {:ok, %{}}, fn {step_id, record}, {:ok, acc} ->
             timed_out = timeout_active_record(parent_sid, workflow, record)

             case record_checkpoint_decided(parent_sid, workflow, timed_out) do
               :ok -> {:cont, {:ok, Map.put(acc, step_id, timed_out)}}
               {:error, error} -> {:halt, {:error, error}}
             end
           end),
         {:ok, state} <-
           %{state | active: %{}, completed: Map.merge(state.completed, timed_out)}
           |> hold_pending(parent_sid, workflow, "workflow_timeout") do
      {:ok, state}
    end
  end

  defp absorb_terminal_active(_parent_sid, _workflow, %{active: active} = state)
       when map_size(active) == 0,
       do: state

  defp absorb_terminal_active(parent_sid, workflow, state) do
    active_ids = state.active |> Map.values() |> Enum.map(& &1.agent_id)

    with {:ok, agents} <- Subagents.wait(parent_sid, active_ids, 0, workspace: workflow.workspace),
         {:ok, state} <- absorb_poll(parent_sid, workflow, state, agents) do
      state
    else
      _ -> state
    end
  end

  defp step_safe_next_actions("checkpoint_ready", _status), do: []
  defp step_safe_next_actions("partial", _status), do: ["synthesize_from_partial_or_retry_step"]
  defp step_safe_next_actions("needs_orchestrator", _status), do: ["ask_user_or_orchestrator"]
  defp step_safe_next_actions("failed", "timed_out"), do: ["retry_failed_step"]

  defp step_safe_next_actions("failed", _status),
    do: ["inspect_step_failure", "retry_failed_step"]

  defp workflow_safe_next_actions("completed", _steps), do: []

  defp workflow_safe_next_actions("partial", steps) do
    [
      if(Enum.any?(steps, &(&1["checkpoint_status"] == "failed")), do: "retry_failed_steps"),
      if(Enum.any?(steps, &(&1["status"] == "timed_out")),
        do: "inspect_timed_out_steps_or_retry_with_larger_timeout"
      ),
      if(Enum.any?(steps, &(&1["checkpoint_status"] == "partial")),
        do: "synthesize_from_usable_checkpoints_or_retry"
      ),
      if(Enum.any?(steps, &(&1["checkpoint_status"] == "held")),
        do: "rerun_after_dependencies_checkpoint_ready"
      ),
      if(Enum.any?(steps, &(&1["checkpoint_status"] == "needs_orchestrator")),
        do: "ask_user_or_orchestrator"
      )
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp finish_workflow_result(parent_sid, workflow, state) do
    result = workflow_result(workflow, state)

    with :ok <-
           record_workflow_event(
             parent_sid,
             "workflow_finished",
             workflow_finished_data(workflow, result)
           ) do
      {:ok, result}
    end
  end

  defp record_checkpoint_decided(parent_sid, workflow, step) do
    record_workflow_event(
      parent_sid,
      "checkpoint_decided",
      checkpoint_decided_data(workflow, step)
    )
  end

  defp record_workflow_event(parent_sid, kind, data) do
    event_data = Map.put(data, "kind", kind)
    safe_record(parent_sid, Event.workflow_event(parent_sid, event_data))
  end

  defp safe_record(session_id, event) do
    case Session.record(session_id, event) do
      {:ok, _event} -> :ok
      {:error, _error} = error -> error
    end
  catch
    :exit, {:noproc, _reason} ->
      :ok

    :exit, reason ->
      {:error,
       Tool.error(:log_write_failed, "could not record workflow_event", %{reason: inspect(reason)})}
  end

  defp workflow_started_data(workflow) do
    %{
      "workflow_id" => workflow.id,
      "workflow_name" => workflow.name,
      "template" => template_metadata(workflow),
      "graph" => %{
        "steps" => Enum.map(workflow.steps, &workflow_step_summary/1),
        "step_count" => length(workflow.steps)
      },
      "limits" => %{
        "max_concurrency" => workflow.max_concurrency,
        "timeout_ms" => workflow.timeout_ms,
        "poll_ms" => workflow.poll_ms
      },
      "workspace" => workflow.workspace
    }
  end

  defp workflow_step_summary(step) do
    %{
      "id" => step.id,
      "agent" => step.agent,
      "depends_on" => step.depends_on,
      "workspace_mode" => step.workspace_mode,
      "posture" => step.posture,
      "read_set" => step.read_set,
      "write_set" => step.write_set,
      "execution_kind" => execution_kind(step)
    }
    |> put_write_policy_metadata(step)
  end

  defp step_scheduled_data(workflow, step, wave) do
    %{
      "workflow_id" => workflow.id,
      "workflow_name" => workflow.name,
      "step_id" => step.id,
      "wave" => wave,
      "depends_on" => step.depends_on,
      "workspace_mode" => step.workspace_mode,
      "posture" => step.posture,
      "read_set" => step.read_set,
      "write_set" => step.write_set,
      "execution_kind" => execution_kind(step)
    }
    |> put_write_policy_metadata(step)
  end

  defp step_held_data(workflow, step, reason) do
    %{
      "workflow_id" => workflow.id,
      "workflow_name" => workflow.name,
      "step_id" => step["step_id"],
      "checkpoint_status" => step["checkpoint_status"],
      "dependent_safe" => false,
      "reason" => reason,
      "workspace_mode" => step["workspace_mode"],
      "execution_kind" => execution_kind(step)
    }
    |> put_write_policy_metadata(step)
  end

  defp checkpoint_decided_data(workflow, step) do
    checkpoint = step["checkpoint"] || %{}

    %{
      "workflow_id" => workflow.id,
      "workflow_name" => workflow.name,
      "step_id" => step["step_id"],
      "agent_id" => step["agent_id"],
      "child_session_id" => step["child_session_id"],
      "checkpoint_status" => step["checkpoint_status"],
      "dependent_safe" => checkpoint["dependent_safe"] == true,
      "checkpoint" => %{
        "status" => checkpoint["status"],
        "version" => checkpoint["version"],
        "summary" => checkpoint["summary"],
        "known_limitations" => checkpoint["known_limitations"] || [],
        "typed_schema_ids" => typed_schema_ids(checkpoint),
        "artifact_refs" => checkpoint["artifacts"] || []
      },
      "workspace_mode" => step["workspace_mode"],
      "execution_kind" => execution_kind(step)
    }
    |> put_write_policy_metadata(step)
  end

  defp workflow_finished_data(workflow, result) do
    %{
      "workflow_id" => workflow.id,
      "workflow_name" => workflow.name,
      "status" => result["status"],
      "ok" => result["ok"],
      "summary" => result["summary"],
      "safe_next_actions" => result["safe_next_actions"],
      "proof_states" => result["proof_states"]
    }
  end

  defp typed_schema_ids(checkpoint) do
    checkpoint
    |> Map.get("typed_payloads", [])
    |> Enum.map(& &1["schema_id"])
    |> Enum.reject(&is_nil/1)
  end

  defp execution_kind(%{posture: "apply"}), do: "virtual_diff_apply"
  defp execution_kind(%{"posture" => "apply"}), do: "virtual_diff_apply"
  defp execution_kind(%{workspace_mode: "virtual_overlay"}), do: "virtual_overlay"
  defp execution_kind(%{"workspace_mode" => "virtual_overlay"}), do: "virtual_overlay"
  defp execution_kind(_step), do: "subagent"

  defp refresh_step_checkpoint_projection(%{"checkpoint" => checkpoint} = step) do
    checkpoint = Map.put(checkpoint, "typed_payloads", [workflow_checkpoint_payload(checkpoint)])
    Map.put(step, "checkpoint", checkpoint)
  end

  defp refresh_step_checkpoint_projection(step), do: step

  defp template_metadata(%{template: nil}), do: nil
  defp template_metadata(%{template: template}), do: template

  defp step_plan(step) do
    %{
      "id" => step.id,
      "agent" => step.agent,
      "depends_on" => step.depends_on,
      "posture" => step.posture,
      "workspace_mode" => step.workspace_mode,
      "read_set" => step.read_set,
      "write_set" => step.write_set
    }
    |> put_write_policy_metadata(step)
    |> maybe_put("apply_from", Map.get(step, :apply_from))
    |> maybe_put("virtual_commands", non_empty(step.virtual_commands))
  end

  defp render_step_prompt(workflow, step, completed) do
    deps =
      step.depends_on
      |> Enum.map(fn dep ->
        result = Map.fetch!(completed, dep)
        "- #{dep}: #{result["summary"]}"
      end)

    [
      "Workflow: #{workflow.name}",
      "Step: #{step.id}",
      "",
      "Task:",
      step.task,
      output_contract_section(),
      dependency_section(deps)
    ]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  defp output_contract_section do
    """
    Output contract:
    - End with a concise summary of completed work.
    - Include checkpoint_status: checkpoint_ready when the result is safe for dependent Workflow steps.
    - Use checkpoint_status: partial when you produced useful evidence but dependents should not proceed without synthesis or retry.
    - Use checkpoint_status: needs_orchestrator when a human/orchestrator decision is required.
    - Do not spawn further Subagents unless explicitly instructed by this Workflow step.
    """
    |> String.trim()
  end

  defp dependency_section([]), do: ""

  defp dependency_section(deps) do
    ["", "Dependency results:" | deps]
    |> Enum.join("\n")
  end

  defp workflow_delegation_context(workflow, step, wave, completed) do
    dependency_summaries =
      step.depends_on
      |> Enum.map(fn dep ->
        outcome = Map.fetch!(completed, dep)

        %{
          "step_id" => dep,
          "checkpoint_status" => outcome["checkpoint_status"],
          "summary" => outcome["summary"]
        }
      end)

    %{
      "workflow_id" => workflow.id,
      "workflow_name" => workflow.name,
      "step_id" => step.id,
      "wave" => wave,
      "depends_on" => step.depends_on,
      "dependency_summaries" => dependency_summaries,
      "posture" => step.posture,
      "workspace_mode" => step.workspace_mode,
      "read_set" => step.read_set,
      "write_set" => step.write_set,
      "checkpoint_requirements" => %{
        "safe_to_unblock_dependents" => "checkpoint_status: checkpoint_ready",
        "usable_but_not_unblocking" => "checkpoint_status: partial",
        "orchestrator_required" => "checkpoint_status: needs_orchestrator"
      }
    }
    |> put_write_policy_metadata(step)
  end

  defp put_write_policy_metadata(map, step) do
    policy =
      case step do
        %{write_policy: policy} -> policy
        %{"write_policy" => policy} -> policy
        _ -> nil
      end

    maybe_put(map, "write_policy", WritePolicy.metadata(policy))
  end

  defp conflicts_with_any?(step, occupied), do: Enum.any?(occupied, &conflict?(step, &1))

  defp conflict?(%{posture: "apply"} = left, %{posture: posture} = right)
       when posture in ["writer", "apply"],
       do: overlaps?(left.write_set, right.write_set)

  defp conflict?(%{posture: posture} = left, %{posture: "apply"} = right)
       when posture in ["writer", "apply"],
       do: overlaps?(left.write_set, right.write_set)

  # apply mutates the parent workspace directly (engine-side, no child
  # session), so it serializes against any overlapping reader regardless of
  # the reader's workspace_mode: virtual_scratch imports and read_only reads
  # both observe the real files the apply rewrites.
  defp conflict?(%{posture: "apply"} = apply, %{posture: posture} = reader)
       when posture in ["read_only", "virtual_scratch"],
       do: overlaps?(apply.write_set, reader.read_set)

  defp conflict?(%{posture: posture} = reader, %{posture: "apply"} = apply)
       when posture in ["read_only", "virtual_scratch"],
       do: overlaps?(reader.read_set, apply.write_set)

  defp conflict?(%{posture: "virtual_scratch"} = reader, %{posture: "writer"} = writer),
    do: writer.workspace_mode == "shared" and overlaps?(reader.read_set, writer.write_set)

  defp conflict?(%{posture: "writer"} = writer, %{posture: "virtual_scratch"} = reader),
    do: writer.workspace_mode == "shared" and overlaps?(writer.write_set, reader.read_set)

  defp conflict?(%{posture: "read_only"} = reader, %{posture: "writer"} = writer),
    do: writer.workspace_mode == "shared" and overlaps?(reader.read_set, writer.write_set)

  defp conflict?(%{posture: "writer"} = writer, %{posture: "read_only"} = reader),
    do: writer.workspace_mode == "shared" and overlaps?(writer.write_set, reader.read_set)

  defp conflict?(%{posture: "writer"} = left, %{posture: "writer"} = right),
    do: overlaps?(left.write_set, right.write_set)

  defp conflict?(_left, _right), do: false

  defp overlaps?(left, right) do
    @wildcard in left or @wildcard in right or
      Enum.any?(left, fn l -> Enum.any?(right, &path_overlap?(l, &1)) end)
  end

  defp path_overlap?(left, right) do
    left = normalize_path_token(left)
    right = normalize_path_token(right)

    left == right or String.starts_with?(left, right <> "/") or
      String.starts_with?(right, left <> "/")
  end

  defp normalize_path_token(path) do
    path
    |> to_string()
    |> String.trim()
    |> String.trim_leading("./")
    |> String.trim_trailing("/")
  end

  defp normalize_set(values) when is_list(values) do
    values
    |> Enum.map(&normalize_path_token/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp normalize_set(value) when is_binary(value), do: normalize_set([value])
  defp normalize_set(_value), do: [@wildcard]

  defp normalize_id_list(values, _field, _step_id) when is_list(values),
    do: Enum.map(values, &to_string/1)

  defp normalize_id_list(value, _field, _step_id) when is_binary(value), do: [value]
  defp normalize_id_list(_value, _field, _step_id), do: []

  defp field(map, key, default \\ nil) do
    Map.get(map, key, Map.get(map, String.to_atom(key), default))
  rescue
    ArgumentError -> Map.get(map, key, default)
  end

  defp has_field?(map, key) do
    Map.has_key?(map, key) or
      try do
        Map.has_key?(map, String.to_atom(key))
      rescue
        ArgumentError -> false
      end
  end

  defp normalize_workflow_id(nil), do: "wf_" <> random_id()

  defp normalize_workflow_id(id) when is_binary(id),
    do: if(safe_id?(id), do: id, else: "wf_" <> random_id())

  defp normalize_workflow_id(_id), do: "wf_" <> random_id()

  defp safe_id?(id), do: is_binary(id) and Regex.match?(@safe_id, id)

  defp random_id do
    :crypto.strong_rand_bytes(5) |> Base.encode16(case: :lower)
  end

  defp positive_integer(value, _field) when is_integer(value) and value > 0, do: value

  defp positive_integer(value, field),
    do: raise(ArgumentError, "#{field} must be a positive integer, got: #{inspect(value)}")

  defp non_negative_integer(value, _field) when is_integer(value) and value >= 0, do: value

  defp non_negative_integer(value, field),
    do: raise(ArgumentError, "#{field} must be a non-negative integer, got: #{inspect(value)}")

  defp maybe_positive_integer(nil, _field, _id), do: nil
  defp maybe_positive_integer(value, _field, _id) when is_integer(value) and value > 0, do: value

  defp maybe_positive_integer(value, field, id),
    do:
      raise(
        ArgumentError,
        "#{field} for #{id} must be a positive integer, got: #{inspect(value)}"
      )

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp timeout_step_fields(%{"status" => "timed_out"} = agent) do
    %{}
    |> maybe_put("timeout_ms", agent["timeout_ms"])
    |> maybe_put("workflow_timeout_ms", agent["workflow_timeout_ms"])
    |> maybe_put("step_timeout_ms", agent["step_timeout_ms"])
    |> maybe_put("elapsed_ms", agent["elapsed_ms"])
    |> maybe_put("reason", agent["reason"])
    |> maybe_put("next_actions", non_empty(agent["next_actions"]))
  end

  defp timeout_step_fields(_agent), do: %{}

  defp put_timeout_verification(bundle, %{"status" => "timed_out"} = agent) do
    bundle
    |> put_in(["verification", "timeout_ms"], agent["timeout_ms"])
    |> put_in(["verification", "workflow_timeout_ms"], agent["workflow_timeout_ms"])
    |> put_in(["verification", "step_timeout_ms"], agent["step_timeout_ms"])
    |> put_in(["verification", "elapsed_ms"], agent["elapsed_ms"])
    |> put_in(["verification", "reason"], agent["reason"])
    |> maybe_put_timeout_next_actions(agent["next_actions"])
  end

  defp put_timeout_verification(bundle, _agent), do: bundle

  defp maybe_put_timeout_next_actions(bundle, []), do: bundle
  defp maybe_put_timeout_next_actions(bundle, nil), do: bundle

  defp maybe_put_timeout_next_actions(bundle, next_actions),
    do: put_in(bundle, ["verification", "next_actions"], next_actions)

  defp non_empty([]), do: nil
  defp non_empty(value), do: value

  defp put_wave(waves, wave, step_id) do
    case List.pop_at(waves, wave - 1) do
      {nil, _} -> waves ++ [[step_id]]
      {existing, rest} -> List.insert_at(rest, wave - 1, existing ++ [step_id])
    end
  end

  defp deadline_exceeded?(workflow, state) do
    {:ok, exceeded?} = WorkflowRun.deadline_exceeded?(workflow, state)
    exceeded?
  end

  defp bounded_task_exit_reason(reason) do
    reason
    |> inspect(limit: 20, printable_limit: 2_000)
    |> Tool.truncate(4_000)
  end

  defp now_ms, do: System.monotonic_time(:millisecond)
end
