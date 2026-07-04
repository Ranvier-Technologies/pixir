defmodule Mix.Tasks.Pixir.Bench.Subagents do
  @shortdoc "Run a verifiable no-network Subagents benchmark"

  @moduledoc """
  Runs a deterministic Subagents benchmark and writes evidence artifacts.

  This is the executable adapter for `docs/benchmarks/subagents.md`'s Pixir-native
  stress layer. It intentionally avoids real provider calls by injecting fake
  providers through Pixir's existing test seam.

  Usage:

      mix pixir.bench.subagents
      mix pixir.bench.subagents --n 1,5,10 --repetitions 3
      mix pixir.bench.subagents --dry-run --json
      mix pixir.bench.subagents --output .pixir/benchmarks/subagents/custom-run

  Artifacts:

      runs.jsonl
      summary.json
      report.md
  """

  use Mix.Task

  alias Pixir.{Auth, Log, Provider, SessionSupervisor, Subagents}

  @schema_version 1
  @default_n [1, 5, 10, 25, 50]
  @default_repetitions 1
  @scenarios [
    "pixir_spawn_wait_n",
    "pixir_close_mid_fanout",
    "pixir_replay_summary",
    "codex_visible_fanout_probe"
  ]

  @switches [
    output: :string,
    n: :string,
    repetitions: :integer,
    dry_run: :boolean,
    json: :boolean,
    help: :boolean
  ]

  @aliases [o: :output, r: :repetitions, h: :help]

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

    output_dir =
      Keyword.get(opts, :output, Path.join([".pixir", "benchmarks", "subagents", run_id]))

    ns =
      case parse_n(Keyword.get(opts, :n)) do
        {:ok, values} ->
          values

        {:error, details} ->
          fail!(:invalid_n_values, "--n must contain positive integers.", details, json?)
      end

    repetitions = Keyword.get(opts, :repetitions, @default_repetitions)

    if repetitions < 1 do
      fail!(
        :invalid_repetitions,
        "--repetitions must be a positive integer.",
        %{repetitions: repetitions},
        json?
      )
    end

    if Keyword.get(opts, :dry_run, false) do
      print_dry_run(output_dir, ns, repetitions, json?)
      exit(:normal)
    end

    Mix.Task.run("app.start")

    File.mkdir_p!(output_dir)
    File.mkdir_p!(Path.join(output_dir, "workspaces"))

    records =
      Enum.flat_map(ns, fn n ->
        for repetition <- 1..repetitions do
          run_spawn_wait(output_dir, run_id, n, repetition)
        end
      end) ++
        [
          run_close_mid_fanout(output_dir, run_id),
          run_replay_summary(output_dir, run_id),
          codex_observability_record(run_id)
        ]

    summary = summarize(records, run_id, output_dir, ns)
    draft_report = render_report(summary, records)
    validation = validate_benchmark(records, summary, draft_report, ns)
    completion_audit = completion_audit(records, summary, validation)

    summary =
      summary
      |> Map.put("schema_validation", validation)
      |> Map.put("completion_audit", completion_audit)

    report = render_report(summary, records)
    validation = validate_benchmark(records, summary, report, ns)
    completion_audit = completion_audit(records, summary, validation)

    summary =
      summary
      |> Map.put("schema_validation", validation)
      |> Map.put("completion_audit", completion_audit)

    report = render_report(summary, records)

    write_jsonl!(Path.join(output_dir, "runs.jsonl"), records)
    File.write!(Path.join(output_dir, "summary.json"), Jason.encode!(summary, pretty: true))
    File.write!(Path.join(output_dir, "report.md"), report)

    File.write!(
      Path.join(output_dir, "completion_audit.json"),
      Jason.encode!(completion_audit, pretty: true)
    )

    ok? = summary["status"] == "passed" and completion_audit["status"] == "completion_ready"

    result = %{
      "ok" => ok?,
      "mode" => "run",
      "output_dir" => Path.expand(output_dir),
      "report" => Path.expand(Path.join(output_dir, "report.md")),
      "completion_audit" => completion_audit,
      "completion_audit_path" => Path.expand(Path.join(output_dir, "completion_audit.json")),
      "summary" => summary
    }

    if json? do
      IO.puts(Jason.encode!(result, pretty: true))
    else
      Mix.shell().info("""

      Subagents benchmark finished.
        output: #{output_dir}
        report: #{Path.join(output_dir, "report.md")}
        status: #{summary["status"]}
      """)
    end

    if not ok?, do: exit({:shutdown, 1})
  end

  defmodule WritingProvider do
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
               call_id: "bench_write_#{length(users)}",
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

  defmodule NoOAuth do
    def refresh_skew_ms, do: 60_000
  end

  defp run_spawn_wait(output_dir, run_id, n, repetition) do
    scenario = "pixir_spawn_wait_n"
    workspace = workspace_dir(output_dir, "#{scenario}_#{n}_r#{repetition}")
    File.mkdir_p!(workspace)
    File.write!(Path.join(workspace, "source.txt"), "parent source")

    started_at = DateTime.utc_now()
    started_native = System.monotonic_time(:millisecond)

    {:ok, sid, _pid} = SessionSupervisor.start_session(workspace: workspace, role: :build)

    spawn_started = System.monotonic_time(:millisecond)

    agents =
      for i <- 1..n do
        {:ok, agent} =
          Subagents.spawn_agent(
            sid,
            %{
              "task" => "bench-task-#{i}",
              "agent" => "worker",
              "max_threads" => min(max(n, 1), 16),
              "timeout_ms" => 10_000
            },
            workspace: workspace,
            provider: WritingProvider,
            permission_mode: :auto
          )

        agent
      end

    first_child_ms =
      if agents == [], do: nil, else: System.monotonic_time(:millisecond) - spawn_started

    all_spawned_ms = System.monotonic_time(:millisecond) - spawn_started
    {:ok, completed} = Subagents.wait(sid, Enum.map(agents, & &1["id"]), 30_000)
    total_ms = System.monotonic_time(:millisecond) - started_native

    {:ok, history} = Log.fold(sid, workspace: workspace)
    {:ok, listed} = Subagents.list(sid)

    missing_child_outputs =
      Enum.reject(completed, fn agent ->
        Path.join(agent["workspace"], "result.txt")
        |> File.read()
        |> case do
          {:ok, "bench-task-" <> _} -> true
          _ -> false
        end
      end)

    parent_write_present = File.exists?(Path.join(workspace, "result.txt"))
    reconstructed = Subagents.reconstruct(history)
    events_by_type = count_by(history, &Atom.to_string(&1.type))
    subagent_events_by_name = count_by_subagent_event(history)
    statuses = count_by(completed, & &1["status"])
    active_after_wait = Enum.count(listed, &(not Subagents.terminal?(&1["status"])))

    ok =
      length(completed) == n and statuses["completed"] == n and missing_child_outputs == [] and
        not parent_write_present and map_size(reconstructed) == n and active_after_wait == 0

    %{
      "run_id" => run_id,
      "schema_version" => @schema_version,
      "scenario" => scenario,
      "provider_path" => "pixir-native",
      "network" => false,
      "status" => if(ok, do: "passed", else: "failed"),
      "started_at" => DateTime.to_iso8601(started_at),
      "n" => n,
      "repetition" => repetition,
      "workspace" => Path.expand(workspace),
      "parent_session_id" => sid,
      "child_ids" => Enum.map(completed, & &1["id"]),
      "child_session_ids" => Enum.map(completed, & &1["child_session_id"]),
      "metrics" => %{
        "prompt_to_first_child_event_ms" => first_child_ms,
        "prompt_to_all_spawned_ms" => all_spawned_ms,
        "wait_all_completed_ms" => total_ms - all_spawned_ms,
        "total_turn_ms" => total_ms,
        "spawned_count" => length(agents),
        "completed_count" => statuses["completed"] || 0,
        "failed_count" => statuses["failed"] || 0,
        "timed_out_count" => statuses["timed_out"] || 0,
        "cancelled_count" => statuses["cancelled"] || 0,
        "active_after_wait_count" => active_after_wait,
        "parent_log_events" => length(history),
        "child_log_count" => count_child_logs(completed),
        "parent_log_bytes" => log_bytes(workspace, sid),
        "child_log_bytes_total" => child_log_bytes(completed)
      },
      "evidence" => %{
        "events_by_type" => events_by_type,
        "subagent_events_by_name" => subagent_events_by_name,
        "reconstructed_count" => map_size(reconstructed),
        "missing_child_output_ids" => Enum.map(missing_child_outputs, & &1["id"]),
        "parent_write_present" => parent_write_present,
        "terminal_subagent_events" =>
          Enum.count(history, &(&1.type == :subagent_event and &1.data["event"] == "finished"))
      }
    }
  end

  defp run_close_mid_fanout(output_dir, run_id) do
    scenario = "pixir_close_mid_fanout"
    workspace = workspace_dir(output_dir, scenario)
    File.mkdir_p!(workspace)
    File.write!(Path.join(workspace, "source.txt"), "parent source")

    started_at = DateTime.utc_now()
    started_native = System.monotonic_time(:millisecond)
    {:ok, sid, _pid} = SessionSupervisor.start_session(workspace: workspace, role: :build)

    agents =
      for i <- 1..5 do
        {:ok, agent} =
          Subagents.spawn_agent(
            sid,
            %{
              "task" => "blocking-#{i}",
              "agent" => "worker",
              "max_threads" => 5,
              "timeout_ms" => 30_000
            },
            workspace: workspace,
            provider: BlockingProvider,
            permission_mode: :auto
          )

        agent
      end

    agent_ids = Enum.map(agents, & &1["id"])

    start_wait =
      wait_until(fn ->
        case listed_agents_for(sid, agent_ids) do
          listed when length(listed) == 5 ->
            Enum.all?(listed, &(&1["status"] == "running"))

          _ ->
            false
        end
      end)

    closed =
      for agent <- agents do
        {:ok, closed} = Subagents.close(sid, agent["id"])
        closed
      end

    terminal_wait =
      wait_until(fn ->
        case listed_agents_for(sid, agent_ids) do
          listed when length(listed) == 5 ->
            Enum.all?(listed, &Subagents.terminal?(&1["status"]))

          _ ->
            false
        end
      end)

    total_ms = System.monotonic_time(:millisecond) - started_native
    {:ok, history} = Log.fold(sid, workspace: workspace)

    cancelled_events =
      Enum.count(history, &(&1.type == :subagent_event and &1.data["event"] == "cancelled"))

    terminal_count =
      Enum.count(closed, &(Subagents.terminal?(&1["status"]) and &1["status"] != "queued"))

    ok =
      start_wait == :ok and terminal_wait == :ok and length(closed) == 5 and
        Enum.all?(closed, &(&1["status"] == "cancelled")) and
        cancelled_events == 5

    %{
      "run_id" => run_id,
      "schema_version" => @schema_version,
      "scenario" => scenario,
      "provider_path" => "pixir-native",
      "network" => false,
      "status" => if(ok, do: "passed", else: "failed"),
      "started_at" => DateTime.to_iso8601(started_at),
      "n" => 5,
      "workspace" => Path.expand(workspace),
      "parent_session_id" => sid,
      "child_ids" => Enum.map(closed, & &1["id"]),
      "child_session_ids" => Enum.map(closed, & &1["child_session_id"]),
      "metrics" => %{
        "total_turn_ms" => total_ms,
        "spawned_count" => length(agents),
        "closed_count" => Enum.count(closed, &(&1["status"] == "closed")),
        "cancelled_count" => Enum.count(closed, &(&1["status"] == "cancelled")),
        "terminal_count" => terminal_count,
        "parent_log_events" => length(history),
        "child_log_count" => count_child_logs(closed)
      },
      "evidence" => %{
        "start_wait" => wait_status(start_wait),
        "terminal_wait" => wait_status(terminal_wait),
        "events_by_type" => count_by(history, &Atom.to_string(&1.type)),
        "subagent_events_by_name" => count_by_subagent_event(history),
        "closed_events" =>
          Enum.count(history, &(&1.type == :subagent_event and &1.data["event"] == "closed")),
        "cancelled_events" => cancelled_events
      }
    }
  end

  defp run_replay_summary(output_dir, run_id) do
    scenario = "pixir_replay_summary"
    workspace = workspace_dir(output_dir, scenario)
    File.mkdir_p!(workspace)
    File.write!(Path.join(workspace, "source.txt"), "parent source")

    started_at = DateTime.utc_now()
    {:ok, sid, _pid} = SessionSupervisor.start_session(workspace: workspace, role: :build)

    agents =
      for i <- 1..2 do
        {:ok, agent} =
          Subagents.spawn_agent(
            sid,
            %{
              "task" => "replay-task-#{i}",
              "agent" => "explorer",
              "max_threads" => 2,
              "timeout_ms" => 10_000
            },
            workspace: workspace,
            provider: WritingProvider,
            permission_mode: :auto
          )

        agent
      end

    {:ok, completed} = Subagents.wait(sid, Enum.map(agents, & &1["id"]), 30_000)
    {:ok, history} = Log.fold(sid, workspace: workspace)

    replay_text = capture_replay_text(history)

    ok =
      Enum.all?(completed, &(&1["status"] == "completed")) and
        String.contains?(replay_text, "Subagent") and
        String.contains?(replay_text, "completed") and
        not String.contains?(replay_text, "bench_write_")

    %{
      "run_id" => run_id,
      "schema_version" => @schema_version,
      "scenario" => scenario,
      "provider_path" => "pixir-native",
      "network" => false,
      "status" => if(ok, do: "passed", else: "failed"),
      "started_at" => DateTime.to_iso8601(started_at),
      "n" => 2,
      "workspace" => Path.expand(workspace),
      "parent_session_id" => sid,
      "child_ids" => Enum.map(completed, & &1["id"]),
      "child_session_ids" => Enum.map(completed, & &1["child_session_id"]),
      "metrics" => %{
        "parent_log_events" => length(history),
        "child_log_count" => count_child_logs(completed),
        "replay_text_bytes" => byte_size(replay_text)
      },
      "evidence" => %{
        "replay_contains_subagent" => String.contains?(replay_text, "Subagent"),
        "replay_contains_completed" => String.contains?(replay_text, "completed"),
        "replay_drops_raw_tool_call_ids" => not String.contains?(replay_text, "bench_write_"),
        "replay_excerpt" => String.slice(replay_text, 0, 1_000)
      }
    }
  end

  defp capture_replay_text(history) do
    name = :"subagents_bench_auth_#{System.unique_integer([:positive])}"
    path = Path.join(System.tmp_dir!(), "pixir-subagents-bench-auth-#{name}.json")

    try do
      {:ok, _pid} =
        Auth.start_link(name: name, store_path: path, env_api_key: "sk-bench", oauth: NoOAuth)

      {:ok, _} =
        Provider.stream(%{history: history},
          auth: name,
          transport: capture_transport(self())
        )

      receive do
        {:provider_body, body} ->
          body["input"]
          |> Enum.flat_map(&Map.get(&1, "content", []))
          |> Enum.map_join("\n", &Map.get(&1, "text", ""))
      after
        1_000 -> ""
      end
    after
      File.rm_rf!(path)
    end
  end

  defp capture_transport(test_pid) do
    fn request, acc, feed ->
      send(test_pid, {:provider_body, Jason.decode!(request.body)})
      acc = feed.({:status, 200}, acc)
      {:ok, feed.({:data, "data: {\"type\":\"response.completed\"}\n\n"}, acc)}
    end
  end

  defp codex_observability_record(run_id) do
    %{
      "run_id" => run_id,
      "schema_version" => @schema_version,
      "scenario" => "codex_visible_fanout_probe",
      "provider_path" => "codex-through-t3",
      "network" => false,
      "status" => "not_observed",
      "started_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "n" => nil,
      "metrics" => %{},
      "evidence" => %{
        "reason" =>
          "This Pixir-native benchmark adapter does not drive T3 Code's Codex provider. Codex visibility is measured by the separate local T3 harness at scripts/codex-subagents-observability-probe.ts."
      }
    }
  end

  defp summarize(records, run_id, output_dir, required_scales) do
    failed = Enum.filter(records, &(&1["status"] == "failed"))

    %{
      "schema_version" => @schema_version,
      "run_id" => run_id,
      "status" => if(failed == [], do: "passed", else: "failed"),
      "output_dir" => Path.expand(output_dir),
      "generated_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "records_count" => length(records),
      "failed_count" => length(failed),
      "not_observed_count" => Enum.count(records, &(&1["status"] == "not_observed")),
      "scales" =>
        records
        |> Enum.filter(&(&1["scenario"] == "pixir_spawn_wait_n"))
        |> Enum.map(& &1["n"])
        |> Enum.uniq()
        |> Enum.sort(),
      "requirements" => %{
        "pixir_required_scales_present" =>
          Enum.all?(required_scales, fn n ->
            Enum.any?(records, &(&1["scenario"] == "pixir_spawn_wait_n" and &1["n"] == n))
          end),
        "no_failed_records" => failed == [],
        "close_mid_fanout_checked" =>
          Enum.any?(records, &(&1["scenario"] == "pixir_close_mid_fanout")),
        "replay_summary_checked" =>
          Enum.any?(records, &(&1["scenario"] == "pixir_replay_summary")),
        "codex_comparability_noted" =>
          Enum.any?(records, &(&1["scenario"] == "codex_visible_fanout_probe"))
      }
    }
  end

  defp validate_benchmark(records, summary, report, required_scales) do
    record_issues = validate_records(records)
    summary_issues = validate_summary(summary, records, required_scales)
    report_issues = validate_report(report, summary, records)

    %{
      "schema_version" => @schema_version,
      "status" =>
        if(record_issues == [] and summary_issues == [] and report_issues == [],
          do: "passed",
          else: "failed"
        ),
      "record_count" => length(records),
      "record_issues" => record_issues,
      "summary_issues" => summary_issues,
      "report_issues" => report_issues
    }
  end

  defp validate_records(records) do
    records
    |> Enum.with_index()
    |> Enum.flat_map(fn {record, index} ->
      base_record_issues(record, index) ++ scenario_record_issues(record, index)
    end)
  end

  defp base_record_issues(record, index) do
    []
    |> require_equal(
      ["records", index, "schema_version"],
      record["schema_version"],
      @schema_version
    )
    |> require_string(["records", index, "run_id"], record["run_id"])
    |> require_in(["records", index, "scenario"], record["scenario"], @scenarios)
    |> require_string(["records", index, "provider_path"], record["provider_path"])
    |> require_in(["records", index, "status"], record["status"], [
      "passed",
      "failed",
      "not_observed"
    ])
    |> require_string(["records", index, "started_at"], record["started_at"])
    |> require_equal(["records", index, "network"], record["network"], false)
    |> require_map(["records", index, "metrics"], record["metrics"])
    |> require_map(["records", index, "evidence"], record["evidence"])
  end

  defp scenario_record_issues(%{"scenario" => "pixir_spawn_wait_n"} = record, index) do
    n = record["n"]
    metrics = record["metrics"] || %{}
    evidence = record["evidence"] || %{}

    []
    |> require_positive_integer(["records", index, "n"], n)
    |> require_positive_integer(["records", index, "repetition"], record["repetition"])
    |> require_list_length(["records", index, "child_ids"], record["child_ids"], n)
    |> require_list_length(
      ["records", index, "child_session_ids"],
      record["child_session_ids"],
      n
    )
    |> require_equal(["records", index, "metrics", "spawned_count"], metrics["spawned_count"], n)
    |> require_equal(
      ["records", index, "metrics", "completed_count"],
      metrics["completed_count"],
      n
    )
    |> require_equal(
      ["records", index, "metrics", "active_after_wait_count"],
      metrics["active_after_wait_count"],
      0
    )
    |> require_equal(
      ["records", index, "metrics", "child_log_count"],
      metrics["child_log_count"],
      n
    )
    |> require_equal(
      ["records", index, "evidence", "reconstructed_count"],
      evidence["reconstructed_count"],
      n
    )
    |> require_equal(
      ["records", index, "evidence", "missing_child_output_ids"],
      evidence["missing_child_output_ids"],
      []
    )
    |> require_equal(
      ["records", index, "evidence", "parent_write_present"],
      evidence["parent_write_present"],
      false
    )
  end

  defp scenario_record_issues(%{"scenario" => "pixir_close_mid_fanout"} = record, index) do
    metrics = record["metrics"] || %{}
    evidence = record["evidence"] || %{}

    []
    |> require_equal(["records", index, "n"], record["n"], 5)
    |> require_list_length(["records", index, "child_ids"], record["child_ids"], 5)
    |> require_equal(
      ["records", index, "metrics", "cancelled_count"],
      metrics["cancelled_count"],
      5
    )
    |> require_equal(
      ["records", index, "metrics", "terminal_count"],
      metrics["terminal_count"],
      5
    )
    |> require_equal(
      ["records", index, "evidence", "cancelled_events"],
      evidence["cancelled_events"],
      5
    )
  end

  defp scenario_record_issues(%{"scenario" => "pixir_replay_summary"} = record, index) do
    evidence = record["evidence"] || %{}

    []
    |> require_equal(["records", index, "n"], record["n"], 2)
    |> require_list_length(["records", index, "child_ids"], record["child_ids"], 2)
    |> require_equal(
      ["records", index, "evidence", "replay_contains_subagent"],
      evidence["replay_contains_subagent"],
      true
    )
    |> require_equal(
      ["records", index, "evidence", "replay_contains_completed"],
      evidence["replay_contains_completed"],
      true
    )
    |> require_equal(
      ["records", index, "evidence", "replay_drops_raw_tool_call_ids"],
      evidence["replay_drops_raw_tool_call_ids"],
      true
    )
  end

  defp scenario_record_issues(%{"scenario" => "codex_visible_fanout_probe"} = record, index) do
    evidence = record["evidence"] || %{}

    []
    |> require_equal(["records", index, "status"], record["status"], "not_observed")
    |> require_string(["records", index, "evidence", "reason"], evidence["reason"])
  end

  defp scenario_record_issues(record, index) do
    [
      issue(
        ["records", index, "scenario"],
        "unknown_scenario",
        "Unknown scenario.",
        record["scenario"]
      )
    ]
  end

  defp validate_summary(summary, records, required_scales) do
    actual_scales =
      records
      |> Enum.filter(&(&1["scenario"] == "pixir_spawn_wait_n"))
      |> Enum.map(& &1["n"])
      |> Enum.uniq()
      |> Enum.sort()

    failed_count = Enum.count(records, &(&1["status"] == "failed"))
    requirements = summary["requirements"] || %{}

    []
    |> require_equal(["summary", "schema_version"], summary["schema_version"], @schema_version)
    |> require_string(["summary", "run_id"], summary["run_id"])
    |> require_in(["summary", "status"], summary["status"], ["passed", "failed"])
    |> require_string(["summary", "output_dir"], summary["output_dir"])
    |> require_equal(["summary", "records_count"], summary["records_count"], length(records))
    |> require_equal(["summary", "failed_count"], summary["failed_count"], failed_count)
    |> require_equal(["summary", "scales"], summary["scales"], actual_scales)
    |> require_map(["summary", "requirements"], requirements)
    |> require_requirement_true(requirements, "pixir_required_scales_present")
    |> require_requirement_true(requirements, "no_failed_records")
    |> require_requirement_true(requirements, "close_mid_fanout_checked")
    |> require_requirement_true(requirements, "replay_summary_checked")
    |> require_requirement_true(requirements, "codex_comparability_noted")
    |> require_equal(
      ["summary", "required_scales_observed"],
      Enum.all?(required_scales, &(&1 in actual_scales)),
      true
    )
  end

  defp validate_report(report, summary, _records) do
    [
      {"run_id", summary["run_id"]},
      {"status", "Status: **#{summary["status"]}**"},
      {"raw_records", "Raw records: `runs.jsonl`"},
      {"summary", "Summary: `summary.json`"},
      {"completion_audit", "## Completion Audit"},
      {"schema_validation", "## Schema Validation"}
    ]
    |> Enum.flat_map(fn {field, needle} ->
      if is_binary(needle) and String.contains?(report || "", needle) do
        []
      else
        [
          issue(
            ["report", field],
            "missing_report_evidence",
            "Report did not include required evidence.",
            needle
          )
        ]
      end
    end)
  end

  defp completion_audit(records, summary, validation) do
    requirements = [
      audit_requirement(
        "deterministic_no_network",
        Enum.all?(records, &(&1["network"] == false)),
        "Every benchmark record declares network=false."
      ),
      audit_requirement(
        "records_schema_validated",
        validation["record_issues"] == [],
        "runs.jsonl records validate against deterministic benchmark schema."
      ),
      audit_requirement(
        "summary_schema_validated",
        validation["summary_issues"] == [],
        "summary.json validates against deterministic benchmark schema."
      ),
      audit_requirement(
        "report_reconciled",
        validation["report_issues"] == [],
        "report.md includes run id, status, raw records, summary, schema validation, and completion audit."
      ),
      audit_requirement(
        "all_requirements_true",
        summary["requirements"] |> Map.values() |> Enum.all?(&(&1 == true)),
        "All scenario requirements are true."
      ),
      audit_requirement(
        "no_orphaned_active_children",
        no_orphaned_active_children?(records),
        "Spawn/wait records have zero active children after wait and close records terminally close children."
      ),
      audit_requirement(
        "codex_non_comparability_recorded",
        Enum.any?(records, &(&1["scenario"] == "codex_visible_fanout_probe")),
        "The deterministic Pixir-native adapter records that Codex/T3 comparability is out of scope."
      )
    ]

    %{
      "schema_version" => @schema_version,
      "status" =>
        if(Enum.all?(requirements, &(&1["status"] == "proved")),
          do: "completion_ready",
          else: "incomplete"
        ),
      "proof_states" => [
        "intent_declared",
        "dry_run_passed",
        "benchmark_records_produced",
        "records_validated",
        "schema_validated",
        "report_reconciled",
        "completion_ready"
      ],
      "requirements" => requirements
    }
  end

  defp audit_requirement(name, true, evidence) do
    %{"requirement" => name, "status" => "proved", "evidence" => evidence}
  end

  defp audit_requirement(name, false, evidence) do
    %{"requirement" => name, "status" => "missing", "evidence" => evidence}
  end

  defp no_orphaned_active_children?(records) do
    Enum.all?(records, fn
      %{"scenario" => "pixir_spawn_wait_n", "metrics" => metrics} ->
        metrics["active_after_wait_count"] == 0

      %{"scenario" => "pixir_close_mid_fanout", "metrics" => metrics} ->
        metrics["terminal_count"] == metrics["spawned_count"]

      _record ->
        true
    end)
  end

  defp issue(path, kind, message, value) do
    %{
      "path" => Enum.map(path, &to_string/1),
      "kind" => kind,
      "message" => message,
      "value" => value
    }
  end

  defp require_string(issues, _path, value) when is_binary(value) and value != "", do: issues

  defp require_string(issues, path, value),
    do: [issue(path, "required_string", "Expected a non-empty string.", value) | issues]

  defp require_map(issues, _path, value) when is_map(value), do: issues

  defp require_map(issues, path, value),
    do: [issue(path, "required_map", "Expected a map.", value) | issues]

  defp require_in(issues, path, value, allowed) do
    if value in allowed do
      issues
    else
      [issue(path, "unexpected_value", "Value was not in the allowed set.", value) | issues]
    end
  end

  defp require_equal(issues, path, value, expected) do
    if value == expected do
      issues
    else
      [
        issue(path, "unexpected_value", "Value did not match the expected value.", %{
          "actual" => value,
          "expected" => expected
        })
        | issues
      ]
    end
  end

  defp require_positive_integer(issues, _path, value) when is_integer(value) and value >= 1,
    do: issues

  defp require_positive_integer(issues, path, value),
    do: [issue(path, "positive_integer_required", "Expected a positive integer.", value) | issues]

  defp require_list_length(issues, _path, value, expected_length)
       when is_list(value) and length(value) == expected_length,
       do: issues

  defp require_list_length(issues, path, value, expected_length) do
    [
      issue(path, "unexpected_list_length", "List length did not match expected length.", %{
        "actual" => if(is_list(value), do: length(value), else: nil),
        "expected" => expected_length
      })
      | issues
    ]
  end

  defp require_requirement_true(issues, requirements, key) do
    require_equal(issues, ["summary", "requirements", key], Map.get(requirements, key), true)
  end

  defp render_report(summary, records) do
    scale_rows =
      records
      |> Enum.filter(&(&1["scenario"] == "pixir_spawn_wait_n"))
      |> Enum.sort_by(&{&1["n"], &1["repetition"]})
      |> Enum.map_join("\n", fn record ->
        m = record["metrics"]

        "| #{record["n"]} | #{record["repetition"]} | #{record["status"]} | #{m["prompt_to_first_child_event_ms"]} | #{m["prompt_to_all_spawned_ms"]} | #{m["wait_all_completed_ms"]} | #{m["total_turn_ms"]} | #{m["completed_count"]} | #{m["active_after_wait_count"]} |"
      end)

    codex_note =
      records
      |> Enum.find(&(&1["scenario"] == "codex_visible_fanout_probe"))
      |> get_in(["evidence", "reason"])

    validation_section = validation_section(summary["schema_validation"])
    audit_section = audit_section(summary["completion_audit"])

    """
    # Subagents Benchmark Report

    Run id: `#{summary["run_id"]}`

    Status: **#{summary["status"]}**

    Output directory: `#{summary["output_dir"]}`

    ## Pixir Spawn/Wait Stress

    | N | Rep | Status | First child ms | All spawned ms | Wait completed ms | Total ms | Completed | Active after wait |
    |---:|---:|---|---:|---:|---:|---:|---:|---:|
    #{scale_rows}

    ## Resilience Checks

    - Close mid-fanout checked: #{summary["requirements"]["close_mid_fanout_checked"]}
    - Replay summary checked: #{summary["requirements"]["replay_summary_checked"]}
    - Required scales present: #{summary["requirements"]["pixir_required_scales_present"]}
    - No failed records: #{summary["requirements"]["no_failed_records"]}
    #{validation_section}
    #{audit_section}

    ## Codex Comparability

    #{codex_note}

    Raw records: `runs.jsonl`

    Summary: `summary.json`
    """
  end

  defp validation_section(nil), do: ""

  defp validation_section(validation) do
    """

    ## Schema Validation

    Status: **#{validation["status"]}**

    - Record issues: #{length(validation["record_issues"] || [])}
    - Summary issues: #{length(validation["summary_issues"] || [])}
    - Report issues: #{length(validation["report_issues"] || [])}
    """
  end

  defp audit_section(nil), do: ""

  defp audit_section(audit) do
    rows =
      audit["requirements"]
      |> Enum.map_join("\n", fn requirement ->
        "| #{requirement["requirement"]} | #{requirement["status"]} | #{requirement["evidence"]} |"
      end)

    """

    ## Completion Audit

    Status: **#{audit["status"]}**

    | Requirement | Status | Evidence |
    |---|---|---|
    #{rows}
    """
  end

  defp print_help(json?) do
    payload = %{
      "ok" => true,
      "command" => "mix pixir.bench.subagents",
      "description" => "Run deterministic no-network Pixir Subagents benchmarks.",
      "options" => [
        "--n 1,5,10,25,50",
        "--repetitions 3",
        "--dry-run",
        "--json",
        "--output PATH"
      ],
      "proof_states" => [
        "intent_declared",
        "dry_run_passed",
        "benchmark_records_produced",
        "records_validated",
        "schema_validated",
        "report_reconciled",
        "completion_ready"
      ]
    }

    if json? do
      IO.puts(Jason.encode!(payload, pretty: true))
    else
      Mix.shell().info("""
      Run deterministic no-network Pixir Subagents benchmarks.

      Usage:
        mix pixir.bench.subagents [options]

      Common:
        mix pixir.bench.subagents --dry-run
        mix pixir.bench.subagents --n 1,5,10,25,50 --repetitions 3

      Agent-facing:
        --json       emit machine-readable dry-run/result/error JSON
        --dry-run    print planned artifacts and scenarios without writing files
      """)
    end
  end

  defp print_dry_run(output_dir, ns, repetitions, json?) do
    scenarios =
      Enum.flat_map(ns, fn n ->
        for repetition <- 1..repetitions do
          %{
            "scenario" => "pixir_spawn_wait_n",
            "n" => n,
            "repetition" => repetition,
            "network" => false
          }
        end
      end) ++
        [
          %{"scenario" => "close_mid_fanout", "network" => false},
          %{"scenario" => "replay_summary", "network" => false},
          %{"scenario" => "codex_observability_record", "network" => false}
        ]

    payload = %{
      "ok" => true,
      "mode" => "dry_run",
      "would_write" => [
        Path.join(output_dir, "runs.jsonl"),
        Path.join(output_dir, "summary.json"),
        Path.join(output_dir, "report.md"),
        Path.join(output_dir, "completion_audit.json"),
        Path.join(output_dir, "workspaces")
      ],
      "scenarios" => scenarios,
      "estimated_real_network_runs" => 0,
      "requires" => ["Pixir application can start", "fake provider test seam"]
    }

    if json? do
      IO.puts(Jason.encode!(payload, pretty: true))
    else
      Mix.shell().info("Dry run. Would write: #{output_dir}")
      Mix.shell().info("Scenarios: #{Jason.encode!(scenarios)}")
    end
  end

  defp fail!(kind, message, details, json?) do
    payload = %{
      "ok" => false,
      "error" => %{
        "kind" => Atom.to_string(kind),
        "message" => message,
        "details" => details,
        "root_agent_hint" =>
          "Run with --help or --json --help to inspect the supported adapter contract."
      }
    }

    if json? do
      IO.puts(Jason.encode!(payload, pretty: true))
    else
      Mix.shell().error("#{message} #{inspect(details)}")
    end

    exit({:shutdown, 1})
  end

  defp parse_n(nil), do: {:ok, @default_n}

  defp parse_n(raw) do
    values = raw |> String.split(",", trim: true) |> Enum.map(&String.trim/1)

    parsed =
      Enum.map(values, fn value ->
        case Integer.parse(value) do
          {int, ""} when int >= 1 -> {:ok, int}
          _ -> {:error, value}
        end
      end)

    case Enum.filter(parsed, &match?({:error, _}, &1)) do
      [] -> {:ok, parsed |> Enum.map(fn {:ok, int} -> int end) |> Enum.uniq()}
      invalid -> {:error, %{"invalid" => Enum.map(invalid, fn {:error, value} -> value end)}}
    end
  end

  defp write_jsonl!(path, records) do
    contents = Enum.map_join(records, "\n", &Jason.encode!/1) <> "\n"
    File.write!(path, contents)
  end

  defp workspace_dir(output_dir, name), do: Path.join([output_dir, "workspaces", name])

  defp timestamp do
    DateTime.utc_now()
    |> DateTime.to_iso8601(:basic)
    |> String.replace(~r/[^0-9TZ]/, "")
    |> String.replace("Z", "")
  end

  defp count_by(items, fun) do
    Enum.reduce(items, %{}, fn item, acc ->
      key = fun.(item)
      Map.update(acc, key, 1, &(&1 + 1))
    end)
  end

  defp count_by_subagent_event(history) do
    history
    |> Enum.filter(&(&1.type == :subagent_event))
    |> count_by(& &1.data["event"])
  end

  defp listed_agents_for(parent_session_id, ids) do
    ids = MapSet.new(ids)

    case Subagents.list(parent_session_id) do
      {:ok, agents} -> Enum.filter(agents, &(&1["id"] in ids))
      _ -> []
    end
  end

  defp wait_until(fun, attempts \\ 50)

  defp wait_until(fun, attempts) when attempts > 0 do
    if fun.() do
      :ok
    else
      Process.sleep(20)
      wait_until(fun, attempts - 1)
    end
  end

  defp wait_until(_fun, 0), do: {:error, :timeout}

  defp wait_status(:ok), do: "ok"
  defp wait_status({:error, reason}), do: Atom.to_string(reason)

  defp count_child_logs(agents) do
    Enum.count(agents, fn agent ->
      agent["child_session_id"] &&
        log_path(agent["workspace"], agent["child_session_id"]) |> File.exists?()
    end)
  end

  defp child_log_bytes(agents) do
    Enum.reduce(agents, 0, fn agent, acc ->
      acc + log_bytes(agent["workspace"], agent["child_session_id"])
    end)
  end

  defp log_bytes(_workspace, nil), do: 0

  defp log_bytes(workspace, sid) do
    path = log_path(workspace, sid)

    case File.stat(path) do
      {:ok, stat} -> stat.size
      _ -> 0
    end
  end

  defp log_path(workspace, sid) do
    Path.join([Pixir.Paths.project_root(workspace), "sessions", "#{sid}.ndjson"])
  end
end
