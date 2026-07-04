defmodule Pixir.Tools.RunWorkflow do
  @moduledoc "Run a deterministic Workflow over supervised Subagents."

  use Pixir.Tool

  alias Pixir.{Tool, Workflows}

  @impl Pixir.Tool
  @doc """
  Defines the `run_workflow` tool specification including its name, description, and input JSON schema.

  The returned map describes a tool named "run_workflow" and a provider-compatible
  parameters schema for workflow inputs. The schema accepts either a concrete `steps`
  array (each step requires `id` and `task`), a Skill-backed `template_id` plus
  optional `template_args`, or separate `skill` and `template` fields. Optional
  workflow-level fields include: `id`, `name`, `max_concurrency`, and `timeout_ms`.
  Each concrete step object may include `agent`, `depends_on`, `permission_mode`,
  `workspace_mode`, `read_set`, `write_set`, `virtual_commands`, `limits`, and an
  optional per-step `timeout_ms`.

  Keep shape alternatives in descriptions and runtime validation rather than top-level
  JSON Schema composition keywords; the OpenAI Responses API rejects those at the tool
  schema root.
  """
  @spec __tool__() :: map()
  def __tool__ do
    %{
      name: "run_workflow",
      description:
        "Validate and run a Workflow: a dependency graph of Subagent steps, either concrete or expanded from a Skill-backed Workflow Template.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "id" => %{"type" => "string", "description" => "Optional workflow id"},
          "name" => %{"type" => "string", "description" => "Human-readable workflow name"},
          "template_id" => %{
            "type" => "string",
            "description" =>
              "Optional Skill-backed Workflow Template id, usually skill/template. Do not include steps when this is set."
          },
          "skill" => %{
            "type" => "string",
            "description" => "Optional Skill name when using the separate template field"
          },
          "template" => %{
            "type" => "string",
            "description" => "Optional template id when paired with skill"
          },
          "template_args" => %{
            "type" => "object",
            "description" => "Arguments used to instantiate the selected Workflow Template"
          },
          "max_concurrency" => %{
            "type" => "integer",
            "description" => "Maximum concurrently running steps"
          },
          "timeout_ms" => %{
            "type" => "integer",
            "description" => "Whole-workflow timeout in milliseconds"
          },
          "steps" => %{
            "type" => "array",
            "description" => "Workflow steps",
            "items" => %{
              "type" => "object",
              "properties" => %{
                "id" => %{"type" => "string", "description" => "Safe unique step id"},
                "task" => %{"type" => "string", "description" => "Task for the Subagent"},
                "agent" => %{"type" => "string", "description" => "Agent role name"},
                "depends_on" => %{
                  "type" => "array",
                  "items" => %{"type" => "string"},
                  "description" => "Step ids that must complete first"
                },
                "permission_mode" => %{
                  "type" => "string",
                  "description" => "read_only for explorer steps; writer otherwise"
                },
                "workspace_mode" => %{
                  "type" => "string",
                  "enum" => ["shared", "isolated", "virtual_overlay"],
                  "description" =>
                    "shared, isolated, or explicit virtual_overlay for bounded virtual shell work. virtual_overlay requires read_set and virtual_commands and never applies changes to the parent workspace."
                },
                "read_set" => %{
                  "type" => "array",
                  "items" => %{"type" => "string"},
                  "description" =>
                    "Paths this step intends to read. Required and bounded for virtual_overlay; no implicit whole-repo import."
                },
                "write_set" => %{
                  "type" => "array",
                  "items" => %{"type" => "string"},
                  "description" => "Paths this writer may mutate"
                },
                "virtual_commands" => %{
                  "type" => "array",
                  "items" => %{"type" => "string"},
                  "description" =>
                    "Virtual shell commands interpreted inside BEAM for virtual_overlay steps; never host shell commands."
                },
                "limits" => %{
                  "type" => "object",
                  "description" =>
                    "Optional virtual_overlay limits such as max_import_files, max_import_bytes, max_virtual_commands, max_diff_bytes, or max_output_bytes."
                },
                "timeout_ms" => %{
                  "type" => "integer",
                  "description" => "Optional per-step timeout"
                }
              },
              "required" => ["id", "task"]
            }
          }
        },
        "required" => []
      }
    }
  end

  @impl Pixir.Tool
  @doc """
  Runs a workflow described by `args` under the provided `context` and returns a human-readable summary together with the raw workflow result.

  On success returns `{:ok, %{"output" => summary, "workflow" => result}}` where `summary` is a formatted completion string and `result` is the workflow result map. On failure returns `{:error, reason}` propagated from the workflow runner.
  """
  @spec execute(map(), map()) :: {:ok, map()} | {:error, term()}
  def execute(args, context) when is_map(args) do
    with {:ok, result} <- Workflows.run(context.session_id, args, workflow_opts(context)) do
      {:ok, %{"output" => render(result), "workflow" => result}}
    end
  end

  def execute(_args, _context),
    do: {:error, Tool.error(:invalid_args, "workflow arguments must be an object", %{})}

  @impl Pixir.Tool
  @doc """
  Validates and plans a workflow without executing its steps.

  Performs a dry-run of the provided workflow arguments and returns a human-readable summary plus the planner's raw workflow result.

  ## Parameters

    - args: Map representing the workflow specification (steps, optional id/name, concurrency/timeout settings, etc.).
    - context: Execution context used to build planner options (workspace, provider, permission and agent/skill options, depth).

  @returns
  `{:ok, response}` where `response` is a map containing:
    - `"dry_run" => true`
    - `"output"`: a summary string describing the validation/plan
    - `"workflow"`: the planner's raw result map.
  On failure, returns `{:error, reason}` as returned by the workflow planner.
  """
  @spec dry_run(map(), map()) :: {:ok, map()} | {:error, any()}
  def dry_run(args, context) when is_map(args) do
    with {:ok, result} <- Workflows.dry_run(args, workflow_opts(context)) do
      {:ok, %{"dry_run" => true, "output" => render_dry_run(result), "workflow" => result}}
    end
  end

  def dry_run(_args, _context),
    do: {:error, Tool.error(:invalid_args, "workflow arguments must be an object", %{})}

  defp workflow_opts(context) do
    [
      workspace: context.workspace,
      provider: Map.get(context, :provider, Pixir.Provider),
      provider_opts: Map.get(context, :provider_opts, []),
      permission_mode: get_in(context, [:permission, :mode]) || :auto,
      write_policy: get_in(context, [:permission, :policy]),
      skills_opts: Map.get(context, :skills_opts, []),
      agents_opts: Map.get(context, :agents_opts, []),
      depth: Map.get(context, :subagent_depth, 0)
    ]
  end

  defp render(result) do
    summary = result["summary"]

    case result["status"] do
      "completed" ->
        "Workflow #{result["workflow_id"]} completed: #{summary["steps"]} step(s), " <>
          "#{summary["waves"]} wave(s)."

      status ->
        "Workflow #{result["workflow_id"]} #{status}: " <>
          "#{summary["checkpoint_ready_steps"]} checkpoint-ready, " <>
          "#{summary["failed_steps"]} failed, #{summary["held_steps"]} held, " <>
          "#{summary["partial_steps"]} partial, " <>
          "#{summary["needs_orchestrator_steps"]} needing orchestrator."
    end
  end

  defp render_dry_run(result) do
    template =
      case result["template"] do
        %{"template_id" => template_id} -> " from template #{template_id}"
        _ -> ""
      end

    "Workflow #{result["workflow_id"]}#{template} validated: " <>
      "#{length(result["would_run"])} step(s), #{length(result["waves"])} planned wave(s)."
  end
end
