defmodule Mix.Tasks.Pixir.Bench.FanoutGauntlet do
  @shortdoc "Run a no-network fanout correctness gauntlet"

  @moduledoc """
  Runs a bounded fanout regression gauntlet for direct Pixir CLI fanout and
  parent-led Subagent fanout.

  This is a correctness gate, not a performance benchmark. It is designed to
  expose false success, missing terminal evidence, hidden failures, and
  misleading parent-led fanout outcomes.

  Usage:

      mix pixir.bench.fanout_gauntlet --dry-run --json
      mix pixir.bench.fanout_gauntlet --json
      mix pixir.bench.fanout_gauntlet --mode direct --pixir-bin ./pixir --direct-n 3
      mix pixir.bench.fanout_gauntlet --mode parent --parent-n 4 --timeout-ms 500

  Artifacts:

      direct_runs.jsonl
      parent_runs.jsonl
      summary.json
      report.md
      completion_audit.json

  Direct mode launches safe, no-network Pixir CLI commands (`--version`, `doctor
  --json`, and `help`). Parent-led mode uses Pixir's in-process Subagent seam with
  fake providers, including one intentional timeout fixture whose success
  criterion is honest partial evidence rather than all-green completion.
  """

  use Mix.Task

  alias Pixir.{Log, SessionDiagnostics, SessionSupervisor, Subagents}

  @schema_version 1
  @command "mix pixir.bench.fanout_gauntlet"
  @default_direct_n 3
  @default_parent_n 4
  @default_timeout_ms 500
  @modes ~w(all direct parent)
  @direct_command_templates [
    ["--version"],
    ["doctor", "--json"],
    ["help"]
  ]

  @switches [
    output: :string,
    mode: :string,
    direct_n: :integer,
    parent_n: :integer,
    timeout_ms: :integer,
    pixir_bin: :string,
    dry_run: :boolean,
    json: :boolean,
    help: :boolean
  ]

  @aliases [o: :output, h: :help]

  @impl Mix.Task
  def run(args) do
    {opts, _argv, invalid} = OptionParser.parse(args, switches: @switches, aliases: @aliases)
    json? = Keyword.get(opts, :json, false)

    if Keyword.get(opts, :help, false) do
      print_help(json?)
      exit(:normal)
    end

    if invalid != [] do
      fail!(:invalid_options, "Invalid command-line options.", %{invalid: invalid}, json?)
    end

    run_id = timestamp()
    mode = Keyword.get(opts, :mode, "all")
    direct_n = Keyword.get(opts, :direct_n, @default_direct_n)
    parent_n = Keyword.get(opts, :parent_n, @default_parent_n)
    timeout_ms = Keyword.get(opts, :timeout_ms, @default_timeout_ms)
    pixir_bin = Keyword.get(opts, :pixir_bin, "./pixir")

    output_dir =
      Keyword.get(opts, :output, Path.join([".pixir", "benchmarks", "fanout-gauntlet", run_id]))

    validate_mode!(mode, json?)
    validate_positive_integer!(:direct_n, direct_n, json?)
    validate_positive_integer!(:parent_n, parent_n, json?)
    validate_positive_integer!(:timeout_ms, timeout_ms, json?)

    if Keyword.get(opts, :dry_run, false) do
      print_dry_run(output_dir, mode, direct_n, parent_n, timeout_ms, pixir_bin, json?)
      exit(:normal)
    end

    File.mkdir_p!(output_dir)
    Mix.Task.run("app.start")

    started_at = DateTime.utc_now()

    direct_records =
      if mode in ["all", "direct"] do
        run_direct_mode(output_dir, run_id, pixir_bin, direct_n)
      else
        []
      end

    parent_records =
      if mode in ["all", "parent"] do
        [run_parent_mode(output_dir, run_id, parent_n, timeout_ms)]
      else
        []
      end

    summary =
      summarize(run_id, output_dir, started_at, mode, direct_records, parent_records)

    completion_audit = completion_audit(summary, direct_records, parent_records)

    summary =
      summary
      |> Map.put("completion_audit", completion_audit)

    report = render_report(summary, direct_records, parent_records)

    write_jsonl!(Path.join(output_dir, "direct_runs.jsonl"), direct_records)
    write_jsonl!(Path.join(output_dir, "parent_runs.jsonl"), parent_records)
    File.write!(Path.join(output_dir, "summary.json"), Jason.encode!(summary, pretty: true))
    File.write!(Path.join(output_dir, "report.md"), report)

    File.write!(
      Path.join(output_dir, "completion_audit.json"),
      Jason.encode!(completion_audit, pretty: true)
    )

    ok? = completion_audit["status"] == "completion_ready"

    result = %{
      "ok" => ok?,
      "mode" => "run",
      "output_dir" => Path.expand(output_dir),
      "report" => Path.expand(Path.join(output_dir, "report.md")),
      "summary" => summary,
      "completion_audit" => completion_audit
    }

    if json? do
      IO.puts(Jason.encode!(result, pretty: true))
    else
      Mix.shell().info("""

      Fanout gauntlet finished.
        output: #{output_dir}
        report: #{Path.join(output_dir, "report.md")}
        status: #{completion_audit["status"]}
      """)
    end

    if not ok?, do: exit({:shutdown, 1})
  end

  defmodule WritingProvider do
    @moduledoc false

    def stream(%{history: history}, opts) do
      on_delta = Keyword.get(opts, :on_delta, fn _ -> :ok end)
      users = Enum.filter(history, &(&1.type == :user_message))
      results = Enum.filter(history, &(&1.type == :tool_result))
      prompt = users |> List.last() |> then(&((&1 && &1.data["text"]) || ""))

      if length(results) < length(users) do
        {:ok,
         %{
           text: "",
           reasoning: "",
           reasoning_items: [],
           function_calls: [
             %{
               call_id: "fanout_write_#{length(users)}",
               name: "write",
               args: %{"path" => "result.txt", "content" => prompt}
             }
           ],
           finish_reason: :tool_calls
         }}
      else
        on_delta.({:text_delta, "done"})

        {:ok,
         %{
           text: "completed #{prompt}",
           reasoning: "",
           reasoning_items: [],
           function_calls: [],
           finish_reason: :stop
         }}
      end
    end
  end

  defmodule BlockingProvider do
    @moduledoc false

    def stream(_request, _opts) do
      Process.sleep(10_000)

      {:ok,
       %{
         text: "late",
         reasoning: "",
         reasoning_items: [],
         function_calls: [],
         finish_reason: :stop
       }}
    end
  end

  defp run_direct_mode(output_dir, run_id, pixir_bin, direct_n) do
    workspace = workspace_dir(output_dir, "direct-cli")
    File.mkdir_p!(workspace)

    plans =
      for index <- 1..direct_n do
        args =
          Enum.at(@direct_command_templates, rem(index - 1, length(@direct_command_templates)))

        %{
          "run_id" => run_id,
          "schema_version" => @schema_version,
          "scenario" => "direct_cli",
          "index" => index,
          "workspace" => Path.expand(workspace),
          "command" => display_command(pixir_bin, args),
          "args" => args
        }
      end

    plans
    |> Task.async_stream(&run_direct_plan(&1, pixir_bin),
      max_concurrency: direct_n,
      timeout: 30_000,
      ordered: true
    )
    |> Enum.map(fn
      {:ok, record} -> record
      {:exit, reason} -> direct_task_crash_record(run_id, workspace, reason)
    end)
  end

  defp run_direct_plan(plan, pixir_bin) do
    started_at = DateTime.utc_now()
    started_native = System.monotonic_time(:millisecond)
    capture_dir = Path.join(plan["workspace"], "captures")
    File.mkdir_p!(capture_dir)

    stdout_path = Path.join(capture_dir, "direct_#{plan["index"]}_stdout.txt")
    stderr_path = Path.join(capture_dir, "direct_#{plan["index"]}_stderr.txt")

    exit_code =
      run_shell_capture(
        pixir_bin,
        plan["args"],
        plan["workspace"],
        stdout_path,
        stderr_path
      )

    elapsed_ms = System.monotonic_time(:millisecond) - started_native
    stdout = File.read!(stdout_path)
    stderr = File.read!(stderr_path)
    session_id = discover_session_id(stdout <> "\n" <> stderr)
    terminal_outcome = direct_terminal_outcome(exit_code, stdout, stderr, session_id)
    issues = direct_issues(exit_code, stdout, stderr, terminal_outcome)

    plan
    |> Map.merge(%{
      "provider_path" => "pixir-cli",
      "network" => false,
      "status" => if(issues == [], do: "passed", else: "failed"),
      "started_at" => DateTime.to_iso8601(started_at),
      "elapsed_ms" => elapsed_ms,
      "stdout" => stdout,
      "stderr" => stderr,
      "stdout_path" => Path.expand(stdout_path),
      "stderr_path" => Path.expand(stderr_path),
      "exit_code" => exit_code,
      "session_id" => session_id,
      "terminal_outcome" => terminal_outcome,
      "diagnostics" => %{"issues" => issues}
    })
  end

  defp direct_task_crash_record(run_id, workspace, reason) do
    %{
      "run_id" => run_id,
      "schema_version" => @schema_version,
      "scenario" => "direct_cli",
      "provider_path" => "pixir-cli",
      "network" => false,
      "status" => "failed",
      "started_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "workspace" => Path.expand(workspace),
      "stdout" => "",
      "stderr" => inspect(reason),
      "exit_code" => nil,
      "session_id" => nil,
      "terminal_outcome" => "task_crashed",
      "diagnostics" => %{
        "issues" => [
          issue(:direct_task_crashed, "Direct CLI task crashed before recording a result.", %{
            "reason" => inspect(reason)
          })
        ]
      }
    }
  end

  defp run_parent_mode(output_dir, run_id, parent_n, timeout_ms) do
    scenario = "parent_led_subagents"
    workspace = workspace_dir(output_dir, scenario)
    File.mkdir_p!(workspace)
    File.write!(Path.join(workspace, "source.txt"), "parent source")

    started_at = DateTime.utc_now()
    started_native = System.monotonic_time(:millisecond)
    {:ok, sid, _pid} = SessionSupervisor.start_session(workspace: workspace, role: :build)

    agents =
      for index <- 1..parent_n do
        provider = if index == parent_n, do: BlockingProvider, else: WritingProvider

        {:ok, agent} =
          Subagents.spawn_agent(
            sid,
            %{
              "task" => "fanout-gauntlet-child-#{index}",
              "agent" => "worker",
              "max_threads" => parent_n,
              "timeout_ms" => timeout_ms
            },
            workspace: workspace,
            provider: provider,
            permission_mode: :auto
          )

        agent
      end

    {:ok, wait_outcome} =
      Subagents.wait_outcome(sid, Enum.map(agents, & &1["id"]), timeout_ms * 4,
        workspace: workspace
      )

    {:ok, listed} = Subagents.list(sid, workspace: workspace)
    {:ok, history} = Log.fold(sid, workspace: workspace)
    {:ok, diagnostics} = SessionDiagnostics.run(sid, workspace: workspace)
    elapsed_ms = System.monotonic_time(:millisecond) - started_native

    issues = parent_issues(wait_outcome, diagnostics)
    honest_partial? = wait_outcome["status"] in ["partial", "incomplete"]

    %{
      "run_id" => run_id,
      "schema_version" => @schema_version,
      "scenario" => scenario,
      "provider_path" => "pixir-native",
      "network" => false,
      "status" => if(issues == [], do: "passed", else: "failed"),
      "started_at" => DateTime.to_iso8601(started_at),
      "elapsed_ms" => elapsed_ms,
      "workspace" => Path.expand(workspace),
      "parent_session_id" => sid,
      "parent_outcome" => %{
        "status" => if(honest_partial?, do: "partial_honest", else: wait_outcome["status"]),
        "wait_status" => wait_outcome["status"],
        "summary" => wait_outcome["summary"]
      },
      "child_ids" => Enum.map(agents, & &1["id"]),
      "child_outcomes" => Enum.map(wait_outcome["subagents"] || listed, &child_outcome/1),
      "wait_result" => wait_outcome,
      "diagnostics" => diagnostics,
      "functional" => %{
        "children_requested" => parent_n,
        "children_reported" => length(wait_outcome["subagents"] || []),
        "completed_count" => count_children(wait_outcome, "completed"),
        "timed_out_count" => count_children(wait_outcome, "timed_out"),
        "all_children_terminal_or_reported" => all_children_terminal_or_reported?(wait_outcome)
      },
      "resource_pressure" => %{
        "sampled" => false,
        "reason" =>
          "This gauntlet separates correctness from resource pressure; use mix pixir.bench.codex_pressure for RSS/CPU sampling."
      },
      "evidence" => %{
        "parent_log_events" => length(history),
        "diagnostic_status" => diagnostics["status"],
        "diagnostic_failed_checks" => diagnostic_checks(diagnostics, "failed"),
        "diagnostic_warning_checks" => diagnostic_checks(diagnostics, "warning")
      },
      "issues" => issues
    }
  end

  defp child_outcome(agent) do
    %{
      "id" => agent["id"],
      "child_session_id" => agent["child_session_id"],
      "agent" => agent["agent"],
      "status" => agent["status"],
      "reason" => agent["reason"],
      "timeout_ms" => agent["timeout_ms"],
      "elapsed_ms" => agent["elapsed_ms"],
      "next_actions" => agent["next_actions"] || []
    }
  end

  defp summarize(run_id, output_dir, started_at, mode, direct_records, parent_records) do
    all_records = direct_records ++ parent_records
    failed = Enum.filter(all_records, &(&1["status"] == "failed"))

    %{
      "schema_version" => @schema_version,
      "run_id" => run_id,
      "mode" => mode,
      "status" => if(failed == [], do: "passed", else: "failed"),
      "generated_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "started_at" => DateTime.to_iso8601(started_at),
      "output_dir" => Path.expand(output_dir),
      "records_count" => length(all_records),
      "failed_count" => length(failed),
      "functional" => %{
        "direct_runs" => length(direct_records),
        "parent_runs" => length(parent_records),
        "direct_failed" => Enum.count(direct_records, &(&1["status"] == "failed")),
        "parent_failed" => Enum.count(parent_records, &(&1["status"] == "failed")),
        "parent_partial_fixture_present" =>
          Enum.any?(parent_records, &(&1["parent_outcome"]["status"] == "partial_honest"))
      },
      "resource_pressure" => %{
        "sampled" => false,
        "reason" => "Functional fanout evidence is separated from resource pressure evidence."
      }
    }
  end

  defp completion_audit(summary, direct_records, parent_records) do
    direct_required? = summary["mode"] in ["all", "direct"]
    parent_required? = summary["mode"] in ["all", "parent"]

    requirements =
      [
        maybe_requirement(direct_required?, "direct_records_present", direct_records != [], %{
          "count" => length(direct_records)
        }),
        maybe_requirement(parent_required?, "parent_records_present", parent_records != [], %{
          "count" => length(parent_records)
        }),
        requirement("no_failed_records", summary["failed_count"] == 0, %{
          "failed_count" => summary["failed_count"]
        }),
        requirement("functional_separated_from_resource_pressure", true, %{
          "resource_pressure_sampled" => false
        }),
        maybe_requirement(
          parent_required?,
          "parent_partial_fixture_present",
          summary["functional"]["parent_partial_fixture_present"],
          %{}
        )
      ]
      |> Enum.reject(&is_nil/1)

    %{
      "schema_version" => @schema_version,
      "status" =>
        if(Enum.all?(requirements, &(&1["status"] == "proved")),
          do: "completion_ready",
          else: "incomplete"
        ),
      "requirements" => requirements
    }
  end

  defp render_report(summary, direct_records, parent_records) do
    """
    # Fanout Regression Gauntlet

    This is a correctness and honest-outcome gauntlet, not a public performance
    benchmark.

    - Run id: `#{summary["run_id"]}`
    - Status: `#{summary["status"]}`
    - Completion audit: `#{summary["completion_audit"]["status"]}`
    - Direct CLI records: #{length(direct_records)}
    - Parent-led records: #{length(parent_records)}

    ## Functional Completion Evidence

    | Surface | Records | Failed |
    | --- | ---: | ---: |
    | Direct CLI | #{length(direct_records)} | #{Enum.count(direct_records, &(&1["status"] == "failed"))} |
    | Parent-led Subagents | #{length(parent_records)} | #{Enum.count(parent_records, &(&1["status"] == "failed"))} |

    ## Resource Pressure Evidence

    Resource pressure is not sampled by this gauntlet. Use
    `mix pixir.bench.codex_pressure` for peak process-tree RSS, CPU, and system
    memory pressure.

    ## Parent-led Outcome

    #{parent_records |> Enum.map_join("\n", &parent_summary_line/1)}

    ## Completion Requirements

    #{summary["completion_audit"]["requirements"] |> Enum.map_join("\n", &requirement_line/1)}
    """
  end

  defp parent_summary_line(record) do
    "- `#{record["parent_session_id"]}`: #{record["parent_outcome"]["status"]}; completed=#{record["functional"]["completed_count"]}; timed_out=#{record["functional"]["timed_out_count"]}"
  end

  defp requirement_line(requirement) do
    "- #{requirement["status"]}: #{requirement["id"]}"
  end

  defp print_dry_run(output_dir, mode, direct_n, parent_n, timeout_ms, pixir_bin, json?) do
    payload = %{
      "ok" => true,
      "command" => @command,
      "mode" => "dry_run",
      "would_run" => planned_modes(mode),
      "would_write" =>
        [
          "direct_runs.jsonl",
          "parent_runs.jsonl",
          "summary.json",
          "report.md",
          "completion_audit.json"
        ]
        |> Enum.map(&Path.expand(Path.join(output_dir, &1))),
      "direct" => %{
        "n" => direct_n,
        "pixir_bin" => pixir_bin,
        "commands" => direct_command_plan(direct_n, pixir_bin)
      },
      "parent" => %{
        "n" => parent_n,
        "timeout_ms" => timeout_ms,
        "includes_timeout_fixture" => true
      },
      "requirements" => [
        "direct CLI records stdout, stderr, exit code, session id, and terminal outcome",
        "parent-led Subagent fanout records parent outcome, child outcomes, wait result, and diagnostics",
        "functional completion evidence stays separate from resource pressure evidence",
        "false success and missing terminal evidence make the gauntlet fail"
      ],
      "estimated_real_network_runs" => 0
    }

    if json? do
      IO.puts(Jason.encode!(payload, pretty: true))
    else
      Mix.shell().info("Dry run. Would write: #{output_dir}")
    end
  end

  defp print_help(json?) do
    payload = %{
      "ok" => true,
      "command" => @command,
      "description" => "No-network fanout correctness gauntlet for Pixir CLI and Subagents.",
      "options" => [
        "--mode all|direct|parent",
        "--direct-n N",
        "--parent-n N",
        "--timeout-ms N",
        "--pixir-bin PATH",
        "--output PATH",
        "--dry-run",
        "--json",
        "--help"
      ],
      "artifacts" => [
        "direct_runs.jsonl",
        "parent_runs.jsonl",
        "summary.json",
        "report.md",
        "completion_audit.json"
      ]
    }

    if json? do
      IO.puts(Jason.encode!(payload, pretty: true))
    else
      Mix.shell().info(@moduledoc)
    end
  end

  defp run_shell_capture(bin, args, cwd, stdout_path, stderr_path) do
    command =
      ([bin] ++ args)
      |> Enum.map(&shell_quote/1)
      |> Enum.join(" ")

    redirect =
      command <>
        " > " <>
        shell_quote(stdout_path) <>
        " 2> " <> shell_quote(stderr_path)

    {_output, exit_code} = System.cmd("/bin/sh", ["-c", redirect], cd: cwd)
    exit_code
  end

  defp shell_quote(value) do
    "'" <> (value |> to_string() |> String.replace("'", "'\"'\"'")) <> "'"
  end

  defp direct_terminal_outcome(0, stdout, _stderr, session_id) do
    cond do
      String.trim(stdout) == "" -> "missing_stdout"
      is_binary(session_id) -> "completed_with_session"
      true -> "completed_no_session"
    end
  end

  defp direct_terminal_outcome(exit_code, _stdout, _stderr, _session_id)
       when is_integer(exit_code) and exit_code > 0,
       do: "failed_exit"

  defp direct_terminal_outcome(_exit_code, _stdout, _stderr, _session_id), do: "unknown"

  defp direct_issues(exit_code, stdout, stderr, terminal_outcome) do
    []
    |> maybe_issue(
      exit_code == 0 and String.trim(stdout) == "",
      :empty_stdout_false_success,
      "Command exited 0 but stdout was empty.",
      %{"stderr_excerpt" => String.slice(stderr, 0, 500)}
    )
    |> maybe_issue(
      terminal_outcome in ["unknown", "missing_stdout"],
      :missing_terminal_outcome,
      "Direct CLI run did not produce a trustworthy terminal outcome.",
      %{"terminal_outcome" => terminal_outcome}
    )
  end

  defp parent_issues(wait_outcome, diagnostics) do
    []
    |> maybe_issue(
      wait_outcome["status"] in [nil, ""],
      :missing_wait_status,
      "wait_agent outcome is missing a status.",
      %{}
    )
    |> maybe_issue(
      wait_outcome["subagents"] in [nil, []],
      :missing_child_outcomes,
      "wait_agent outcome did not include child outcomes.",
      %{}
    )
    |> maybe_issue(
      diagnostics["status"] == "failed",
      :failed_session_diagnostics,
      "Session diagnostics found failed checks.",
      %{"failed_checks" => diagnostic_checks(diagnostics, "failed")}
    )
    |> maybe_issue(
      not all_children_terminal_or_reported?(wait_outcome),
      :missing_child_terminal_evidence,
      "Some children were neither terminal nor explicitly reported as incomplete.",
      %{}
    )
  end

  defp all_children_terminal_or_reported?(wait_outcome) do
    Enum.all?(wait_outcome["subagents"] || [], fn agent ->
      Subagents.terminal?(agent["status"]) or agent["status"] in ["running", "queued"]
    end)
  end

  defp count_children(wait_outcome, status) do
    Enum.count(wait_outcome["subagents"] || [], &(&1["status"] == status))
  end

  defp diagnostic_checks(diagnostics, status) do
    diagnostics
    |> Map.get("checks", [])
    |> Enum.filter(&(&1["status"] == status))
    |> Enum.map(& &1["id"])
  end

  defp requirement(id, proved?, details) do
    %{
      "id" => id,
      "status" => if(proved?, do: "proved", else: "missing"),
      "details" => details
    }
  end

  defp maybe_requirement(false, _id, _proved?, _details), do: nil
  defp maybe_requirement(true, id, proved?, details), do: requirement(id, proved?, details)

  defp maybe_issue(issues, false, _kind, _message, _details), do: issues

  defp maybe_issue(issues, true, kind, message, details) do
    issues ++ [issue(kind, message, details)]
  end

  defp issue(kind, message, details) do
    %{
      "kind" => Atom.to_string(kind),
      "message" => message,
      "details" => details,
      "next_actions" => ["inspect the associated artifact and rerun after fixing the root cause"]
    }
  end

  defp planned_modes("all"), do: ["direct_cli", "parent_led_subagents"]
  defp planned_modes("direct"), do: ["direct_cli"]
  defp planned_modes("parent"), do: ["parent_led_subagents"]

  defp direct_command_plan(n, pixir_bin) do
    for index <- 1..n do
      args = Enum.at(@direct_command_templates, rem(index - 1, length(@direct_command_templates)))
      display_command(pixir_bin, args)
    end
  end

  defp display_command(bin, args), do: Enum.join([bin | args], " ")

  defp validate_mode!(mode, _json?) when mode in ["all", "direct", "parent"], do: :ok

  defp validate_mode!(mode, json?) do
    fail!(
      :invalid_mode,
      "--mode must be one of: #{Enum.join(@modes, ", ")}.",
      %{mode: mode},
      json?
    )
  end

  defp validate_positive_integer!(_name, value, _json?) when is_integer(value) and value >= 1,
    do: :ok

  defp validate_positive_integer!(name, value, json?) do
    fail!(
      :invalid_positive_integer,
      "--#{String.replace(to_string(name), "_", "-")} must be a positive integer.",
      %{field: name, value: value},
      json?
    )
  end

  defp fail!(kind, message, details, json?) do
    payload = %{
      "ok" => false,
      "error" => %{
        "kind" => Atom.to_string(kind),
        "message" => message,
        "details" => details,
        "root_agent_hint" => "Rerun #{@command} --dry-run --json after correcting the inputs."
      }
    }

    if json? do
      IO.puts(Jason.encode!(payload, pretty: true))
    else
      Mix.shell().error("#{message} #{inspect(details)}")
    end

    exit({:shutdown, 1})
  end

  defp write_jsonl!(path, records) do
    body = records |> Enum.map_join("\n", &Jason.encode!/1)
    File.write!(path, if(body == "", do: "", else: body <> "\n"))
  end

  defp discover_session_id(text) do
    Regex.run(~r/session(?:_id)?[:=]\s*([A-Za-z0-9_.:-]+)/i, text, capture: :all_but_first)
    |> case do
      [sid] -> sid
      _ -> nil
    end
  end

  defp workspace_dir(output_dir, name), do: Path.join([output_dir, "workspaces", name])

  defp timestamp do
    DateTime.utc_now()
    |> Calendar.strftime("%Y%m%dT%H%M%S")
  end
end
