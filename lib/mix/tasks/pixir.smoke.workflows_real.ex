defmodule Mix.Tasks.Pixir.Smoke.WorkflowsReal do
  @shortdoc "Real-network smoke for Workflows over supervised Subagents"

  @moduledoc """
  Runs small, bounded Pixir Workflows against the real Provider.

  This task is intentionally separate from `mix pixir.smoke.workflows`, which is
  deterministic and no-network. Use this task only when you want live model-backed
  Subagents and durable local evidence under `.pixir/`.

  Usage:

      mix pixir.smoke.workflows_real --dry-run --json
      mix pixir.smoke.workflows_real --scenario micro_parallel --json
      mix pixir.smoke.workflows_real --scenario dependency --model gpt-5.3-codex-spark
      mix pixir.smoke.workflows_real --scenario writer_controlled --output .pixir/smoke/workflows-real/manual
      mix pixir.smoke.workflows_real --help

  Scenarios:

    * `micro_parallel` - two read-only Subagents respond with exact constants.
    * `dependency` - two read-only Subagents feed a dependent summarizer.
    * `writer_controlled` - one writer mutates only the scratch workspace.

  Options:

    * `--scenario NAME` - one of the scenarios above. Default: `micro_parallel`.
    * `--model MODEL` - optional Provider model override.
    * `--timeout-ms N` - whole-workflow timeout. Default: 90000.
    * `--step-timeout-ms N` - per-step timeout. Default: 30000.
    * `--output DIR` - durable evidence directory. Default: `.pixir/smoke/workflows-real/<run_id>`.
    * `--dry-run` - validate and print planned waves without auth, network, or writes.
    * `--json` - print machine-readable evidence or errors.
    * `--help` - print this help and exit.
  """

  use Mix.Task

  alias Pixir.{Auth, Log, SessionSupervisor, Workflows}

  @command "mix pixir.smoke.workflows_real"
  @schema_version 1
  @default_scenario "micro_parallel"
  @default_timeout_ms 90_000
  @default_step_timeout_ms 30_000
  @scenarios ~w(micro_parallel dependency writer_controlled)
  @switches [
    scenario: :string,
    model: :string,
    timeout_ms: :integer,
    step_timeout_ms: :integer,
    output: :string,
    dry_run: :boolean,
    json: :boolean,
    help: :boolean
  ]
  @aliases [s: :scenario, o: :output, h: :help]

  @impl Mix.Task
  @doc """
  Entry point for the Mix task: parses CLI arguments, validates configuration, and either prints help/dry-run output or executes a real workflow run.

  Parses provided `args`, handles `--help` and `--dry-run` flows, validates options, ensures authentication when performing a real run, and delegates execution to the live runner which produces durable evidence on success.
  """
  @spec run([String.t()]) :: no_return() | :ok | {:ok, map()} | {:error, map()}
  def run(args) do
    {opts, _argv, invalid} = OptionParser.parse(args, switches: @switches, aliases: @aliases)
    json? = Keyword.get(opts, :json, false)

    if Keyword.get(opts, :help, false) do
      print_help(json?)
      exit(:normal)
    end

    if invalid != [] do
      fail!(
        :invalid_options,
        "Unsupported command-line option(s).",
        %{invalid: invalid},
        ["Run `#{@command} --help` to see supported options."],
        json?
      )
    end

    config = parse_config!(opts, json?)

    if config.dry_run? do
      print_dry_run(config, json?)
      exit(:normal)
    end

    Mix.Task.run("app.start")
    ensure_auth!(json?)
    run_real!(config, json?)
  end

  defp parse_config!(opts, json?) do
    scenario = Keyword.get(opts, :scenario, @default_scenario)

    unless scenario in @scenarios do
      fail!(
        :invalid_scenario,
        "--scenario must be one of: #{Enum.join(@scenarios, ", ")}.",
        %{scenario: scenario, allowed: @scenarios},
        ["Run `#{@command} --dry-run --json --scenario micro_parallel` for the cheapest check."],
        json?
      )
    end

    timeout_ms = positive_int!(opts, :timeout_ms, @default_timeout_ms, json?)
    step_timeout_ms = positive_int!(opts, :step_timeout_ms, @default_step_timeout_ms, json?)
    run_id = timestamp()

    output_dir =
      Keyword.get(opts, :output, Path.join([".pixir", "smoke", "workflows-real", run_id]))

    %{
      run_id: run_id,
      scenario: scenario,
      model: Keyword.get(opts, :model),
      timeout_ms: timeout_ms,
      step_timeout_ms: step_timeout_ms,
      output_dir: output_dir,
      workspace: Path.join(output_dir, "workspace"),
      dry_run?: Keyword.get(opts, :dry_run, false)
    }
  end

  defp positive_int!(opts, key, default, json?) do
    value = Keyword.get(opts, key, default)

    if is_integer(value) and value > 0 do
      value
    else
      option = String.replace(to_string(key), "_", "-")

      fail!(
        :invalid_positive_integer,
        "--#{option} must be a positive integer.",
        %{option: key, value: value},
        ["Pass a value such as `--#{option} #{default}`."],
        json?
      )
    end
  end

  defp ensure_auth!(json?) do
    if Auth.authenticated?() do
      :ok
    else
      fail!(
        :not_authenticated,
        "No Pixir credential is available.",
        %{},
        [
          "Run `mix pixir.smoke.login --wait` and approve the device-code flow.",
          "Alternatively set OPENAI_API_KEY for this shell."
        ],
        json?
      )
    end
  end

  defp print_help(true) do
    Mix.shell().info(
      Jason.encode!(
        %{
          "ok" => true,
          "schema_version" => @schema_version,
          "command" => @command,
          "network" => true,
          "scenarios" => @scenarios,
          "options" => [
            "--scenario NAME",
            "--model MODEL",
            "--timeout-ms N",
            "--step-timeout-ms N",
            "--output DIR",
            "--dry-run",
            "--json",
            "--help"
          ],
          "dry_run_guarantees" => [
            "does_not_require_auth",
            "does_not_call_provider",
            "does_not_create_output_dir"
          ],
          "next_steps" => [
            "Start with `#{@command} --dry-run --json`.",
            "Then run `#{@command} --scenario micro_parallel --json`.",
            "Use `--scenario dependency` before trying `writer_controlled`."
          ]
        },
        pretty: true
      )
    )
  end

  defp print_help(_json?) do
    Mix.shell().info(@moduledoc)
  end

  defp print_dry_run(config, json?) do
    spec = workflow_spec(config)

    case Workflows.dry_run(spec, workspace: File.cwd!()) do
      {:ok, plan} ->
        %{
          "ok" => true,
          "schema_version" => @schema_version,
          "mode" => "dry_run",
          "command" => @command,
          "scenario" => config.scenario,
          "network" => false,
          "estimated_model_backed_subagents" => length(spec["steps"]),
          "workflow" => plan,
          "would_write" => would_write(config),
          "next_steps" => [
            "Run without `--dry-run` to execute live model-backed Subagents.",
            "If live execution times out, retry `micro_parallel` before broader repo-inspection prompts."
          ]
        }
        |> print_success(json?)

      {:error, %{error: error}} ->
        fail!(
          error.kind,
          error.message,
          error.details,
          ["Fix the workflow spec emitted by the scenario builder, then rerun dry-run."],
          json?
        )
    end
  end

  defp run_real!(config, json?) do
    File.mkdir_p!(config.workspace)

    {:ok, sid, pid} = SessionSupervisor.start_session(workspace: config.workspace, role: :build)

    evidence =
      try do
        execute_workflow(config, sid)
      after
        if Process.alive?(pid), do: DynamicSupervisor.terminate_child(SessionSupervisor, pid)
      end

    case evidence do
      {:ok, payload} ->
        File.write!(
          Path.join(config.output_dir, "evidence.json"),
          Jason.encode!(payload, pretty: true)
        )

        print_success(payload, json?)

      {:error, kind, message, details, next_steps} ->
        fail!(kind, message, details, next_steps, json?)
    end
  end

  defp execute_workflow(config, sid) do
    spec = workflow_spec(config)

    opts =
      [
        workspace: config.workspace,
        timeout_ms: config.timeout_ms,
        poll_ms: 500
      ] ++ if(config.model, do: [provider_opts: [model: config.model]], else: [])

    with {:ok, result} <- Workflows.run(sid, spec, opts),
         :ok <- verify_result(config, result),
         {:ok, history} <- Log.fold(sid, workspace: config.workspace),
         :ok <- verify_log(spec, history) do
      {:ok,
       %{
         "ok" => true,
         "schema_version" => @schema_version,
         "mode" => "run",
         "command" => @command,
         "scenario" => config.scenario,
         "network" => true,
         "model" => config.model || "provider_default",
         "run_id" => config.run_id,
         "output_dir" => config.output_dir,
         "workspace" => config.workspace,
         "session" => sid,
         "workflow" => result,
         "subagent_events" => subagent_event_counts(history),
         "requirements" => requirements(config, result),
         "next_steps" => success_next_steps(config)
       }}
    else
      {:error, %{error: error}} ->
        {:error, error.kind, error.message, error.details, failure_next_steps(error.kind)}

      {:error, stage, reason} ->
        {:error, :verification_failed, "Workflow smoke verification failed.",
         %{stage: stage, reason: reason},
         [
           "Inspect the parent session log under the emitted workspace.",
           "Rerun with `--dry-run --json`."
         ]}
    end
  end

  defp workflow_spec(config) do
    %{
      "id" => "real_#{config.scenario}",
      "name" => "Real workflow smoke: #{config.scenario}",
      "max_concurrency" => 2,
      "timeout_ms" => config.timeout_ms,
      "steps" => scenario_steps(config)
    }
  end

  defp scenario_steps(%{scenario: "micro_parallel", step_timeout_ms: timeout}) do
    [
      read_only_step("alpha", "Do not use tools. Reply exactly: ALPHA_OK", timeout),
      read_only_step("beta", "Do not use tools. Reply exactly: BETA_OK", timeout)
    ]
  end

  defp scenario_steps(%{scenario: "dependency", step_timeout_ms: timeout}) do
    [
      read_only_step("alpha", "Do not use tools. Reply exactly: ALPHA_OK", timeout),
      read_only_step("beta", "Do not use tools. Reply exactly: BETA_OK", timeout),
      read_only_step(
        "summarize",
        "Do not use tools. If Dependency results include ALPHA_OK and BETA_OK, reply exactly: DEP_OK. Otherwise reply exactly: DEP_BAD",
        timeout,
        ["alpha", "beta"]
      )
    ]
  end

  defp scenario_steps(%{scenario: "writer_controlled", step_timeout_ms: timeout}) do
    [
      %{
        "id" => "write_file",
        "task" =>
          "Create a file named workflow-output.txt in the current workspace containing exactly WORKFLOW_WRITE_OK, then reply exactly: WRITE_OK",
        "agent" => "worker",
        "workspace_mode" => "shared",
        "write_set" => ["workflow-output.txt"],
        "timeout_ms" => timeout
      }
    ]
  end

  defp read_only_step(id, task, timeout, deps \\ []) do
    %{
      "id" => id,
      "task" => task,
      "agent" => "explorer",
      "permission_mode" => "read_only",
      "workspace_mode" => "shared",
      "read_set" => ["**/*"],
      "write_set" => [],
      "depends_on" => deps,
      "timeout_ms" => timeout
    }
  end

  defp verify_result(%{scenario: "micro_parallel"}, result) do
    summaries = step_summaries(result)

    cond do
      result["status"] != "completed" ->
        {:error, "completion", "workflow status was #{inspect(result["status"])}"}

      summaries["alpha"] != "ALPHA_OK" ->
        {:error, "alpha_summary", "expected ALPHA_OK, got #{inspect(summaries["alpha"])}"}

      summaries["beta"] != "BETA_OK" ->
        {:error, "beta_summary", "expected BETA_OK, got #{inspect(summaries["beta"])}"}

      true ->
        :ok
    end
  end

  defp verify_result(%{scenario: "dependency"}, result) do
    summaries = step_summaries(result)

    cond do
      result["status"] != "completed" ->
        {:error, "completion", "workflow status was #{inspect(result["status"])}"}

      summaries["summarize"] != "DEP_OK" ->
        {:error, "dependency_summary", "expected DEP_OK, got #{inspect(summaries["summarize"])}"}

      true ->
        :ok
    end
  end

  defp verify_result(%{scenario: "writer_controlled", workspace: workspace}, result) do
    output_path = Path.join(workspace, "workflow-output.txt")
    summaries = step_summaries(result)

    cond do
      result["status"] != "completed" ->
        {:error, "completion", "workflow status was #{inspect(result["status"])}"}

      summaries["write_file"] != "WRITE_OK" ->
        {:error, "writer_summary", "expected WRITE_OK, got #{inspect(summaries["write_file"])}"}

      not File.exists?(output_path) ->
        {:error, "writer_output", "expected #{output_path} to exist"}

      File.read!(output_path) != "WORKFLOW_WRITE_OK" ->
        {:error, "writer_output", "workflow-output.txt did not contain WORKFLOW_WRITE_OK"}

      true ->
        :ok
    end
  end

  defp verify_log(spec, history) do
    expected = length(spec["steps"])

    finished =
      Enum.count(history, &(&1.type == :subagent_event and &1.data["event"] == "finished"))

    if finished == expected do
      :ok
    else
      {:error, "subagent_lifecycle",
       "expected #{expected} finished subagent events, got #{finished}"}
    end
  end

  defp step_summaries(result) do
    Map.new(result["steps"], fn step -> {step["id"], String.trim(step["summary"] || "")} end)
  end

  defp subagent_event_counts(history) do
    history
    |> Enum.filter(&(&1.type == :subagent_event))
    |> Enum.frequencies_by(& &1.data["event"])
  end

  defp requirements(config, result) do
    [
      %{"requirement" => "workflow_completed", "status" => "proved"},
      %{"requirement" => "subagent_lifecycle_logged", "status" => "proved"},
      %{
        "requirement" => "expected_step_summaries_observed",
        "status" => "proved",
        "steps" => Map.keys(step_summaries(result))
      },
      %{
        "requirement" => "writer_constrained_to_scratch_workspace",
        "status" =>
          if(config.scenario == "writer_controlled", do: "proved", else: "not_applicable")
      }
    ]
  end

  defp success_next_steps(%{scenario: "micro_parallel"}) do
    ["Run `#{@command} --scenario dependency --json` to test dependency summary flow."]
  end

  defp success_next_steps(%{scenario: "dependency"}) do
    ["Run `#{@command} --scenario writer_controlled --json` to test a bounded writer."]
  end

  defp success_next_steps(%{scenario: "writer_controlled"}) do
    ["Inspect the durable evidence directory, then consider a broader repo-readonly workflow."]
  end

  defp failure_next_steps(:command_failed) do
    [
      "If details.status is timed_out, retry with `--scenario micro_parallel --step-timeout-ms 60000`.",
      "If many subagents time out together, inspect Provider/Finch pool pressure before increasing N."
    ]
  end

  defp failure_next_steps(:timeout) do
    [
      "Retry with a larger `--timeout-ms`.",
      "If this repeats under micro_parallel, inspect Provider/Finch connection pool settings."
    ]
  end

  defp failure_next_steps(_kind) do
    [
      "Run `#{@command} --dry-run --json` to validate the scenario.",
      "Inspect the parent session log under the emitted workspace."
    ]
  end

  defp would_write(config) do
    [
      config.output_dir,
      config.workspace,
      Path.join(config.output_dir, "evidence.json")
    ]
  end

  defp print_success(payload, true), do: Mix.shell().info(Jason.encode!(payload, pretty: true))

  defp print_success(payload, _json?) do
    workflow = payload["workflow"]

    Mix.shell().info("""

    Real Workflows smoke #{payload["mode"]} passed.
      scenario: #{payload["scenario"]}
      network:  #{payload["network"]}
      workflow: #{workflow["workflow_id"]}
      waves:    #{length(workflow["waves"])}
    """)
  end

  defp fail!(kind, message, details, next_steps, true) do
    Mix.shell().error(
      Jason.encode!(
        %{
          "ok" => false,
          "schema_version" => @schema_version,
          "command" => @command,
          "error" => %{
            "kind" => to_string(kind),
            "message" => message,
            "details" => stringify_details(details)
          },
          "next_steps" => next_steps
        },
        pretty: true
      )
    )

    exit({:shutdown, 1})
  end

  defp fail!(kind, message, details, next_steps, _json?) do
    Mix.shell().error("""
    #{@command} failed: #{kind}
      #{message}
      details: #{inspect(details)}
      next steps:
    #{Enum.map_join(next_steps, "\n", &"        - #{&1}")}
    """)

    exit({:shutdown, 1})
  end

  defp stringify_details(details) when is_map(details) do
    Map.new(details, fn {key, value} -> {to_string(key), value} end)
  end

  defp stringify_details(details), do: %{"value" => inspect(details)}

  defp timestamp do
    NaiveDateTime.utc_now()
    |> Calendar.strftime("%Y%m%dT%H%M%S")
  end
end
