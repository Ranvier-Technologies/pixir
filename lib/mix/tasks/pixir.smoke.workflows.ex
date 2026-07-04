defmodule Mix.Tasks.Pixir.Smoke.Workflows do
  @shortdoc "No-network smoke for structural Workflows"

  @moduledoc """
  Verifies Pixir Workflows end-to-end without hitting the network:

    * validates a structural dependency graph;
    * proves read-only explorer steps can run together;
    * proves overlapping writer write-sets are serialized;
    * runs the Workflow through supervised Subagents with a fake provider;
    * verifies terminal summaries and canonical Subagent lifecycle evidence;
    * diagnoses durable Workflow event/checkpoint evidence before cleanup.

  Usage:

      mix pixir.smoke.workflows [--dry-run] [--json]

  Options:

    * `--dry-run` - validate and print the planned waves without spawning Subagents.
    * `--json` - print machine-readable evidence.
    * `--help` - print this help.
  """

  use Mix.Task

  alias Pixir.{Log, SessionDiagnostics, SessionSupervisor, Workflows}

  @impl Mix.Task
  @doc """
  Parses CLI options and either prints help or runs the smoke workflow.

  Recognizes the switches `--dry-run`, `--json`, and `--help`. If `--help` is present, prints the module documentation to the Mix shell; otherwise starts the application and executes the smoke workflow using the parsed options.
  ## Parameters

    - args: list of command-line arguments passed to the Mix task.
  """
  @spec run([String.t()]) :: any()
  def run(args) do
    {opts, _argv, _invalid} =
      OptionParser.parse(args, switches: [dry_run: :boolean, json: :boolean, help: :boolean])

    if opts[:help] do
      Mix.shell().info(@moduledoc)
    else
      Mix.Task.run("app.start")
      run_smoke(opts)
    end
  end

  defmodule EchoProvider do
    @doc """
    Produces a deterministic assistant-like summary based on the first `:user_message` in `state.history`.

    If the first user message contains a line starting with `Step: `, the identifier after that prefix is used; otherwise `"unknown"` is used. Returns an `{:ok, map}` shaped like a workflow provider response with `text` set to `"summary:<step>"`, empty reasoning fields, no function calls, and `finish_reason: :stop`.

    ## Parameters

      - state: Map containing a `:history` key with a list of message maps (each message is expected to have `:type` and `data["text"]`).
      - _opts: Unused options (kept for provider compatibility).

    ## Examples

        iex> Mix.Tasks.Pixir.Smoke.Workflows.EchoProvider.stream(%{history: [%{type: :user_message, data: %{"text" => "Step: alpha"}}]}, [])
        {:ok, %{text: "summary:alpha", reasoning: "", reasoning_items: [], function_calls: [], finish_reason: :stop}}

    """
    @spec stream(map(), Keyword.t()) :: {:ok, map()}
    def stream(%{history: history}, _opts) do
      prompt =
        history
        |> Enum.find(&(&1.type == :user_message))
        |> then(&((&1 && &1.data["text"]) || ""))

      step =
        prompt
        |> String.split("\n")
        |> Enum.find_value("unknown", fn
          "Step: " <> id -> id
          _ -> nil
        end)

      {:ok,
       %{
         text: "summary:#{step}",
         reasoning: "",
         reasoning_items: [],
         function_calls: [],
         finish_reason: :stop
       }}
    end
  end

  defp run_smoke(opts) do
    scratch = scratch_dir()
    workspace = Path.join(scratch, "workspace")

    try do
      File.mkdir_p!(workspace)
      File.write!(Path.join(workspace, "source.txt"), "workflow source")

      result =
        if opts[:dry_run] do
          dry_run_evidence(workspace)
        else
          run_evidence(workspace)
        end

      case result do
        {:ok, evidence} -> print_success(evidence, opts[:json])
        {:error, stage, reason} -> fail(stage, reason, opts[:json])
      end
    after
      File.rm_rf!(scratch)
    end
  end

  defp dry_run_evidence(workspace) do
    with :ok <- install_example_skill_template(workspace),
         {:ok, plan} <- Workflows.dry_run(workflow_spec(), workspace: workspace),
         :ok <- verify_plan(plan),
         {:ok, template_plan} <-
           Workflows.dry_run(template_workflow_spec(), workspace: workspace),
         :ok <- verify_template_plan(template_plan) do
      {:ok,
       %{
         "ok" => true,
         "mode" => "dry_run",
         "workflow" => plan,
         "template_workflow" => template_plan,
         "requirements" => dry_run_requirements()
       }}
    else
      {:error, %{error: error}} -> {:error, "dry_run", error}
      {:error, stage, reason} -> {:error, stage, reason}
      other -> {:error, "dry_run", other}
    end
  end

  defp run_evidence(workspace) do
    {:ok, sid, pid} = SessionSupervisor.start_session(workspace: workspace, role: :build)

    try do
      with {:ok, result} <-
             Workflows.run(sid, workflow_spec(),
               workspace: workspace,
               provider: EchoProvider,
               poll_ms: 10,
               timeout_ms: 5_000
             ),
           :ok <- verify_result(result),
           {:ok, history} <- Log.fold(sid, workspace: workspace),
           :ok <- verify_log(history),
           {:ok, diagnostics} <- SessionDiagnostics.run(sid, workspace: workspace),
           :ok <- verify_workflow_diagnostics(diagnostics) do
        {:ok,
         %{
           "ok" => true,
           "mode" => "run",
           "session" => sid,
           "workflow" => result,
           "diagnostics" => workflow_diagnostic_evidence(diagnostics),
           "finished_subagent_events" => finished_count(history),
           "requirements" => run_requirements()
         }}
      else
        {:error, %{error: error}} -> {:error, "run", error}
        {:error, stage, reason} -> {:error, stage, reason}
        other -> {:error, "run", other}
      end
    after
      if Process.alive?(pid), do: DynamicSupervisor.terminate_child(SessionSupervisor, pid)
    end
  end

  defp verify_plan(plan) do
    cond do
      plan["proof_states"] != Workflows.dry_run_proof_states() ->
        {:error, "proof", "proof_states did not match Workflows.dry_run_proof_states/0"}

      not Enum.any?(plan["waves"], &("inspect_a" in &1 and "inspect_b" in &1)) ->
        {:error, "parallel_readers", "explorer steps were not planned together"}

      Enum.any?(plan["waves"], &("write_a" in &1 and "write_b" in &1)) ->
        {:error, "write_conflicts", "conflicting writers were planned in the same wave"}

      List.last(plan["waves"]) != ["summarize"] ->
        {:error, "dependencies", "summary step was not last"}

      true ->
        :ok
    end
  end

  defp verify_template_plan(plan) do
    cond do
      get_in(plan, ["template", "template_id"]) != "readonly-review/parallel_review" ->
        {:error, "template", "template metadata missing from dry-run plan"}

      plan["workflow_id"] != "readonly_review" ->
        {:error, "template", "template workflow id was not expanded"}

      not template_steps_expanded?(plan) ->
        {:error, "template", "template steps were not expanded"}

      true ->
        :ok
    end
  end

  defp template_steps_expanded?(plan) do
    actual =
      plan["would_run"]
      |> Enum.map(& &1["id"])
      |> MapSet.new()

    expected = MapSet.new(["inspect_a", "inspect_b", "synthesize"])
    actual == expected
  end

  defp verify_result(result) do
    cond do
      result["status"] != "completed" ->
        {:error, "completion", "workflow status was #{inspect(result["status"])}"}

      result["proof_states"] != Workflows.proof_states() ->
        {:error, "proof", "proof_states did not match Workflows.proof_states/0"}

      length(result["steps"]) != 5 ->
        {:error, "steps", "expected 5 completed steps, got #{length(result["steps"])}"}

      Enum.any?(result["waves"], &("write_a" in &1 and "write_b" in &1)) ->
        {:error, "write_conflicts", "conflicting writers ran in the same wave"}

      result["steps"] |> List.last() |> Map.get("summary", "") |> String.contains?("summarize") ->
        :ok

      true ->
        {:error, "summaries", "terminal summaries were not collected"}
    end
  end

  defp verify_log(history) do
    if finished_count(history) == 5 do
      :ok
    else
      {:error, "log", "expected 5 finished subagent events, got #{finished_count(history)}"}
    end
  end

  defp finished_count(history),
    do: Enum.count(history, &(&1.type == :subagent_event and &1.data["event"] == "finished"))

  defp verify_workflow_diagnostics(diagnostics) do
    workflow_events = diagnostic_check(diagnostics, "workflow_events")
    workflow_checkpoints = diagnostic_check(diagnostics, "workflow_checkpoints")
    workflows = diagnostics["workflows"] || %{}
    run = workflows |> Map.get("runs", []) |> List.first(%{})

    cond do
      workflow_events["status"] != "passed" ->
        {:error, "diagnostics", "workflow_events check did not pass"}

      workflow_checkpoints["status"] != "passed" ->
        {:error, "diagnostics", "workflow_checkpoints check did not pass"}

      workflows["count"] != 1 ->
        {:error, "diagnostics", "expected one diagnosed workflow run"}

      workflows["checkpoint_decision_count"] != 5 ->
        {:error, "diagnostics", "expected five diagnosed checkpoint decisions"}

      run == %{} or run["status"] != "completed" or run["finished"] != true ->
        {:error, "diagnostics", "workflow run was not diagnosed as completed"}

      run["gaps"] != [] ->
        {:error, "diagnostics", "workflow run had diagnostic gaps"}

      true ->
        :ok
    end
  end

  defp workflow_diagnostic_evidence(diagnostics) do
    workflows = diagnostics["workflows"] || %{}

    %{
      "status" => diagnostics["status"],
      "workflow_checks" =>
        diagnostics["checks"]
        |> Enum.filter(&(&1["id"] in ["workflow_events", "workflow_checkpoints"]))
        |> Enum.map(&Map.take(&1, ["id", "status", "message", "details"])),
      "workflows" => %{
        "count" => workflows["count"],
        "event_count" => workflows["event_count"],
        "checkpoint_decision_count" => workflows["checkpoint_decision_count"],
        "runs" =>
          workflows
          |> Map.get("runs", [])
          |> Enum.map(fn run ->
            Map.take(run, [
              "workflow_id",
              "status",
              "finished",
              "step_counts",
              "typed_schema_ids",
              "gaps"
            ])
          end)
      }
    }
  end

  defp diagnostic_check(diagnostics, id) do
    diagnostics
    |> Map.get("checks", [])
    |> Enum.find(%{}, &(&1["id"] == id))
  end

  defp workflow_spec do
    %{
      "id" => "smoke_workflow",
      "name" => "Workflow smoke",
      "max_concurrency" => 4,
      "steps" => [
        %{"id" => "inspect_a", "task" => "inspect A", "agent" => "explorer"},
        %{"id" => "inspect_b", "task" => "inspect B", "agent" => "explorer"},
        %{
          "id" => "write_a",
          "task" => "writer A",
          "agent" => "worker",
          "write_set" => ["shared/result.txt"]
        },
        %{
          "id" => "write_b",
          "task" => "writer B",
          "agent" => "worker",
          "write_set" => ["shared/result.txt"]
        },
        %{
          "id" => "summarize",
          "task" => "summarize all steps",
          "agent" => "explorer",
          "depends_on" => ["inspect_a", "inspect_b", "write_a", "write_b"]
        }
      ]
    }
  end

  defp template_workflow_spec do
    %{
      "template_id" => "readonly-review/parallel_review",
      "template_args" => %{
        "topic" => "repository",
        "focus_a" => "architecture",
        "focus_b" => "tests"
      }
    }
  end

  defp install_example_skill_template(workspace) do
    skill_dir = Path.join(workspace, ".agents/skills/readonly-review")
    workflows_dir = Path.join(skill_dir, "workflows")
    skill_path = Path.join(skill_dir, "SKILL.md")
    template_path = Path.join(workflows_dir, "parallel_review.json")

    result =
      with :ok <- mkdir_p(workflows_dir),
           :ok <- atomic_write(skill_path, example_skill_template_markdown()),
           {:ok, template_json} <- example_skill_template_json(),
           :ok <- atomic_write(template_path, template_json) do
        :ok
      end

    case result do
      :ok -> :ok
      {:error, reason} -> {:error, "install_template", reason}
    end
  end

  defp example_skill_template_markdown do
    """
    ---
    name: readonly-review
    description: No-network read-only review workflow template.
    ---

    # Read-only review

    Inspect workflows/parallel_review.json before using this template.
    """
  end

  defp example_skill_template_json do
    %{
      "id" => "parallel_review",
      "version" => 1,
      "name" => "Parallel read-only review",
      "parameters" => %{
        "topic" => %{"type" => "string", "required" => true},
        "focus_a" => %{"type" => "string", "required" => true},
        "focus_b" => %{"type" => "string", "required" => true}
      },
      "workflow" => %{
        "id" => "readonly_review",
        "max_concurrency" => 2,
        "steps" => [
          %{
            "id" => "inspect_a",
            "agent" => "explorer",
            "task" => "Inspect {{topic}} for {{focus_a}}"
          },
          %{
            "id" => "inspect_b",
            "agent" => "explorer",
            "task" => "Inspect {{topic}} for {{focus_b}}"
          },
          %{
            "id" => "synthesize",
            "agent" => "explorer",
            "depends_on" => ["inspect_a", "inspect_b"],
            "task" => "Synthesize {{topic}}"
          }
        ]
      }
    }
    |> Jason.encode(pretty: true)
    |> case do
      {:ok, json} -> {:ok, json}
      {:error, reason} -> {:error, %{operation: "encode_template", reason: inspect(reason)}}
    end
  end

  defp mkdir_p(path) do
    case File.mkdir_p(path) do
      :ok -> :ok
      {:error, reason} -> {:error, %{operation: "mkdir_p", path: path, reason: reason}}
    end
  end

  defp atomic_write(path, content) do
    tmp = Path.join(Path.dirname(path), ".#{Path.basename(path)}.tmp-#{random_id()}")

    with :ok <- write_tmp(tmp, content),
         :ok <- rename_tmp(tmp, path) do
      :ok
    else
      {:error, reason} ->
        _ = File.rm(tmp)
        {:error, reason}
    end
  end

  defp write_tmp(path, content) do
    case File.write(path, content) do
      :ok -> :ok
      {:error, reason} -> {:error, %{operation: "write_tmp", path: path, reason: reason}}
    end
  end

  defp rename_tmp(tmp, path) do
    case File.rename(tmp, path) do
      :ok ->
        :ok

      {:error, reason} ->
        {:error, %{operation: "rename_tmp", source: tmp, target: path, reason: reason}}
    end
  end

  defp dry_run_requirements do
    [
      %{"requirement" => "workflow_validated", "status" => "proved"},
      %{"requirement" => "skill_workflow_template_instantiated", "status" => "proved"},
      %{"requirement" => "read_only_steps_parallelized", "status" => "planned"},
      %{"requirement" => "overlapping_write_sets_serialized", "status" => "planned"},
      %{"requirement" => "dependency_edges_validated", "status" => "proved"},
      %{"requirement" => "subagent_lifecycle_evidence_logged", "status" => "not_run"}
    ]
  end

  defp run_requirements do
    [
      %{"requirement" => "workflow_validated", "status" => "proved"},
      %{"requirement" => "read_only_steps_parallelized", "status" => "proved"},
      %{"requirement" => "overlapping_write_sets_serialized", "status" => "proved"},
      %{"requirement" => "dependency_summaries_collected", "status" => "proved"},
      %{"requirement" => "subagent_lifecycle_evidence_logged", "status" => "proved"}
    ]
  end

  defp print_success(evidence, true), do: Mix.shell().info(Jason.encode!(evidence, pretty: true))

  defp print_success(evidence, _json?) do
    workflow = evidence["workflow"]

    Mix.shell().info("""

    Workflows smoke passed.
      mode:      #{evidence["mode"]}
      workflow:  #{workflow["workflow_id"]}
      waves:     #{length(workflow["waves"])}
      proofs:    #{Enum.join(workflow["proof_states"], ", ")}
    """)
  end

  defp fail(stage, reason, true) do
    Mix.shell().error(
      Jason.encode!(%{"ok" => false, "stage" => stage, "reason" => inspect(reason)})
    )

    Mix.raise("Workflows smoke failed at #{stage}")
  end

  defp fail(stage, reason, _json?) do
    Mix.raise("Workflows smoke failed at #{stage}: #{inspect(reason)}")
  end

  defp scratch_dir do
    Path.join(System.tmp_dir!(), "pixir-workflows-smoke-" <> random_id())
  end

  defp random_id do
    :crypto.strong_rand_bytes(6) |> Base.encode16(case: :lower)
  end
end
