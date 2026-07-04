defmodule Mix.Tasks.Pixir.Bench.CodexPressure do
  @shortdoc "Sample local Mac pressure during Pixir or Codex work"

  @moduledoc """
  Samples local macOS process and memory pressure while Pixir or Codex work is
  running elsewhere.

  This task does not spawn Codex threads or subagents. Codex thread/subagent
  creation is a runtime tool surface, not a shell API. The task is instead an
  agent-useful sampler that can run beside a manual or Codex-orchestrated
  fan-out window and write bounded evidence:

      mix pixir.bench.codex_pressure --dry-run --json
      mix pixir.bench.codex_pressure --target-n 8 --duration-seconds 120
      mix pixir.bench.codex_pressure --profile pixir-runtime-only --json
      mix pixir.bench.codex_pressure --profile codex-app-stack --json
      mix pixir.bench.codex_pressure --process-patterns codex,electron
      mix pixir.bench.codex_pressure --configured-limit 20 --json

  Artifacts:

      samples.jsonl
      summary.json
      report.md
      completion_audit.json

  The reported memory is local process/system pressure. It is not model memory
  and it is not provider-side inference memory.
  """

  use Mix.Task

  @schema_version 1
  @default_duration_seconds 30
  @default_interval_ms 2_000
  @default_profile "codex-app-stack"

  @profiles %{
    "codex-app-stack" => %{
      "description" => "Codex desktop/app orchestration surface visible on the local Mac.",
      "process_patterns" => ["codex"]
    },
    "pixir-runtime-only" => %{
      "description" => "Pixir runtime/escript pressure without a presenter-heavy client.",
      "process_patterns" => ["pixir", "beam.smp"]
    },
    "t3-pixir-stack" => %{
      "description" => "T3 Code presenter plus Pixir ACP/runtime pressure.",
      "process_patterns" => ["T3 Code", "Electron", "pixir", "beam.smp"]
    },
    "zed-pixir-stack" => %{
      "description" => "Zed ACP presenter plus Pixir runtime pressure.",
      "process_patterns" => ["Zed", "pixir", "beam.smp"]
    },
    "custom" => %{
      "description" => "Operator-selected process hints supplied through --process-patterns.",
      "process_patterns" => []
    }
  }

  @proof_states [
    "intent_declared",
    "cli_contract_available",
    "dry_run_passed",
    "samples_produced",
    "summary_reconciled",
    "completion_ready"
  ]

  @switches [
    output: :string,
    duration_seconds: :integer,
    interval_ms: :integer,
    target_n: :integer,
    configured_limit: :integer,
    profile: :string,
    process_patterns: :string,
    codex_config: :string,
    label: :string,
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

    duration_seconds = Keyword.get(opts, :duration_seconds, @default_duration_seconds)
    interval_ms = Keyword.get(opts, :interval_ms, @default_interval_ms)
    profile_name = profile_name(opts)
    profile = profile!(profile_name, json?)
    process_patterns = parse_patterns(Keyword.get(opts, :process_patterns), profile, json?)

    output_dir =
      Keyword.get(opts, :output, Path.join([".pixir", "benchmarks", "resource-pressure", run_id]))

    codex_config = Keyword.get(opts, :codex_config, default_codex_config())
    target_n = Keyword.get(opts, :target_n)
    configured_limit = Keyword.get(opts, :configured_limit)
    label = Keyword.get(opts, :label, "resource-pressure")

    validate_positive_integer!(:duration_seconds, duration_seconds, json?)
    validate_positive_integer!(:interval_ms, interval_ms, json?)

    if target_n && target_n < 1 do
      fail!(
        :invalid_target_n,
        "--target-n must be a positive integer when provided.",
        %{target_n: target_n},
        json?
      )
    end

    if configured_limit && configured_limit < 1 do
      fail!(
        :invalid_configured_limit,
        "--configured-limit must be a positive integer when provided.",
        %{configured_limit: configured_limit},
        json?
      )
    end

    config_snapshot = codex_config_snapshot(codex_config, configured_limit)

    if Keyword.get(opts, :dry_run, false) do
      print_dry_run(
        output_dir,
        duration_seconds,
        interval_ms,
        profile_name,
        profile,
        process_patterns,
        target_n,
        label,
        config_snapshot,
        json?
      )

      exit(:normal)
    end

    File.mkdir_p!(output_dir)

    sample_count = max(1, ceil(duration_seconds * 1_000 / interval_ms))
    started_at = DateTime.utc_now()

    samples =
      for index <- 0..(sample_count - 1) do
        if index > 0 do
          Process.sleep(interval_ms)
        end

        sample(run_id, index, started_at, process_patterns)
      end

    summary =
      summarize(
        run_id,
        output_dir,
        started_at,
        DateTime.utc_now(),
        samples,
        duration_seconds,
        interval_ms,
        profile_name,
        profile,
        process_patterns,
        target_n,
        label,
        config_snapshot
      )

    completion_audit = completion_audit(summary, samples)
    summary = Map.put(summary, "completion_audit", completion_audit)
    report = render_report(summary)

    write_jsonl!(Path.join(output_dir, "samples.jsonl"), samples)
    File.write!(Path.join(output_dir, "summary.json"), Jason.encode!(summary, pretty: true))

    File.write!(
      Path.join(output_dir, "completion_audit.json"),
      Jason.encode!(completion_audit, pretty: true)
    )

    File.write!(Path.join(output_dir, "report.md"), report)

    result = %{
      "ok" => completion_audit["status"] == "completion_ready",
      "mode" => "run",
      "output_dir" => display_path(output_dir),
      "report" => display_path(Path.join(output_dir, "report.md")),
      "summary" => summary,
      "completion_audit" => completion_audit
    }

    if json? do
      IO.puts(Jason.encode!(result, pretty: true))
    else
      Mix.shell().info("""

      Codex pressure sampling finished.
        output: #{output_dir}
        report: #{Path.join(output_dir, "report.md")}
        peak tracked RSS: #{summary["pressure"]["peak_tracked_rss_mb"]} MB
        samples: #{summary["samples_count"]}
      """)
    end
  end

  defp sample(run_id, index, started_at, process_patterns) do
    now = DateTime.utc_now()
    processes = process_snapshot(process_patterns)
    vm = vm_snapshot()

    %{
      "schema_version" => @schema_version,
      "run_id" => run_id,
      "sample_index" => index,
      "elapsed_ms" => DateTime.diff(now, started_at, :millisecond),
      "sampled_at" => DateTime.to_iso8601(now),
      "process_patterns" => process_patterns,
      "processes" => processes,
      "memory" => vm
    }
  end

  defp process_snapshot(process_patterns) do
    rows =
      case System.cmd("ps", ["-axo", "pid=,ppid=,rss=,pcpu=,comm="], stderr_to_stdout: true) do
        {output, 0} ->
          output
          |> String.split("\n", trim: true)
          |> Enum.map(&parse_ps_row/1)
          |> Enum.reject(&is_nil/1)

        {output, code} ->
          [
            %{
              "pid" => nil,
              "ppid" => nil,
              "rss_kb" => 0,
              "cpu_percent" => 0.0,
              "command" => "ps_failed_exit_#{code}: #{String.trim(output)}"
            }
          ]
      end

    tracked = Enum.filter(rows, &tracked_process?(&1, process_patterns))
    tracked_tree = process_tree(rows, tracked)

    %{
      "tracked_count" => length(tracked),
      "tracked_rss_kb" => Enum.sum(Enum.map(tracked, & &1["rss_kb"])),
      "tracked_cpu_percent" =>
        tracked |> Enum.map(& &1["cpu_percent"]) |> Enum.sum() |> Kernel.*(1.0) |> Float.round(2),
      "tracked_top" => top_processes(tracked),
      "process_tree_count" => length(tracked_tree),
      "process_tree_rss_kb" => Enum.sum(Enum.map(tracked_tree, & &1["rss_kb"])),
      "process_tree_cpu_percent" =>
        tracked_tree
        |> Enum.map(& &1["cpu_percent"])
        |> Enum.sum()
        |> Kernel.*(1.0)
        |> Float.round(2),
      "process_tree_top" => top_processes(tracked_tree),
      "system_top_rss" => top_processes(rows)
    }
  end

  defp parse_ps_row(row) do
    case Regex.run(~r/^\s*(\d+)\s+(\d+)\s+(\d+)\s+([\d.]+)\s+(.+?)\s*$/, row) do
      [_all, pid, ppid, rss, cpu, command] ->
        %{
          "pid" => String.to_integer(pid),
          "ppid" => String.to_integer(ppid),
          "rss_kb" => String.to_integer(rss),
          "cpu_percent" => parse_float(cpu),
          "command" => command
        }

      _ ->
        nil
    end
  end

  defp tracked_process?(process, patterns) do
    command = process["command"] |> to_string() |> String.downcase()
    Enum.any?(patterns, &String.contains?(command, String.downcase(&1)))
  end

  defp process_tree(rows, roots) do
    rows_by_parent = Enum.group_by(rows, & &1["ppid"])

    roots
    |> Enum.flat_map(&collect_descendants(&1, rows_by_parent, MapSet.new()))
    |> Enum.uniq_by(& &1["pid"])
  end

  defp collect_descendants(%{"pid" => nil} = row, _rows_by_parent, _seen), do: [row]

  defp collect_descendants(%{"pid" => pid} = row, rows_by_parent, seen) do
    if MapSet.member?(seen, pid) do
      []
    else
      seen = MapSet.put(seen, pid)

      children =
        rows_by_parent
        |> Map.get(pid, [])
        |> Enum.flat_map(&collect_descendants(&1, rows_by_parent, seen))

      [row | children]
    end
  end

  defp top_processes(rows) do
    rows
    |> Enum.sort_by(& &1["rss_kb"], :desc)
    |> Enum.take(10)
    |> Enum.map(fn row ->
      %{
        "pid" => row["pid"],
        "ppid" => row["ppid"],
        "rss_kb" => row["rss_kb"],
        "rss_mb" => kb_to_mb(row["rss_kb"]),
        "cpu_percent" => row["cpu_percent"],
        "command" => row["command"]
      }
    end)
  end

  defp vm_snapshot do
    total_bytes = sysctl_integer("hw.memsize")

    case cmd("vm_stat", []) do
      {:error, reason} ->
        %{
          "source" => "vm_stat_unavailable",
          "error" => reason,
          "total_bytes" => total_bytes,
          "used_mb" => nil,
          "swapouts" => nil
        }

      {output, 0} ->
        page_size = parse_page_size(output)
        pages = parse_vm_pages(output)
        free_pages = Map.get(pages, "Pages free", 0) + Map.get(pages, "Pages speculative", 0)
        used_bytes = max(total_bytes - free_pages * page_size, 0)

        %{
          "source" => "vm_stat",
          "page_size_bytes" => page_size,
          "total_bytes" => total_bytes,
          "used_bytes" => used_bytes,
          "used_mb" => bytes_to_mb(used_bytes),
          "free_pages" => free_pages,
          "compressed_pages" => Map.get(pages, "Pages occupied by compressor", 0),
          "swapins" => Map.get(pages, "Swapins", 0),
          "swapouts" => Map.get(pages, "Swapouts", 0),
          "pages" => pages
        }

      {output, code} ->
        %{
          "source" => "vm_stat_failed",
          "error" => %{"exit_code" => code, "output" => String.trim(output)},
          "total_bytes" => total_bytes
        }
    end
  end

  defp parse_page_size(output) do
    case Regex.run(~r/page size of (\d+) bytes/, output) do
      [_all, size] -> String.to_integer(size)
      _ -> 16_384
    end
  end

  defp parse_vm_pages(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.reduce(%{}, fn line, acc ->
      case Regex.run(~r/^(.+?):\s+([0-9]+)\.?$/, String.trim(line)) do
        [_all, key, value] -> Map.put(acc, key, String.to_integer(value))
        _ -> acc
      end
    end)
  end

  defp sysctl_integer(name) do
    case cmd("sysctl", ["-n", name]) do
      {:error, _reason} -> 0
      {output, 0} -> output |> String.trim() |> String.to_integer()
      _ -> 0
    end
  end

  defp cmd(command, args) do
    System.cmd(command, args, stderr_to_stdout: true)
  rescue
    error in ErlangError ->
      {:error,
       %{
         "kind" => "command_unavailable",
         "command" => command,
         "reason" => inspect(error.original)
       }}
  end

  defp summarize(
         run_id,
         output_dir,
         started_at,
         finished_at,
         samples,
         duration_seconds,
         interval_ms,
         profile_name,
         profile,
         process_patterns,
         target_n,
         label,
         config_snapshot
       ) do
    tracked_rss_kb = Enum.map(samples, &get_in(&1, ["processes", "tracked_rss_kb"]))
    tracked_cpu = Enum.map(samples, &get_in(&1, ["processes", "tracked_cpu_percent"]))
    tree_rss_kb = Enum.map(samples, &get_in(&1, ["processes", "process_tree_rss_kb"]))
    tree_cpu = Enum.map(samples, &get_in(&1, ["processes", "process_tree_cpu_percent"]))
    tree_counts = Enum.map(samples, &get_in(&1, ["processes", "process_tree_count"]))
    used_mb = Enum.map(samples, &get_in(&1, ["memory", "used_mb"])) |> Enum.reject(&is_nil/1)
    swapouts = Enum.map(samples, &get_in(&1, ["memory", "swapouts"])) |> Enum.reject(&is_nil/1)

    %{
      "schema_version" => @schema_version,
      "run_id" => run_id,
      "label" => label,
      "status" => "sampled",
      "output_dir" => display_path(output_dir),
      "started_at" => DateTime.to_iso8601(started_at),
      "finished_at" => DateTime.to_iso8601(finished_at),
      "duration_seconds_requested" => duration_seconds,
      "interval_ms" => interval_ms,
      "samples_count" => length(samples),
      "target_n" => target_n,
      "process_patterns" => process_patterns,
      "profile" => %{
        "name" => profile_name,
        "description" => profile["description"]
      },
      "codex_config" => config_snapshot,
      "pressure" => %{
        "peak_tracked_rss_kb" => Enum.max(tracked_rss_kb, fn -> 0 end),
        "peak_tracked_rss_mb" => tracked_rss_kb |> Enum.max(fn -> 0 end) |> kb_to_mb(),
        "avg_tracked_cpu_percent" => average(tracked_cpu),
        "peak_process_tree_count" => Enum.max(tree_counts, fn -> 0 end),
        "peak_process_tree_rss_kb" => Enum.max(tree_rss_kb, fn -> 0 end),
        "peak_process_tree_rss_mb" => tree_rss_kb |> Enum.max(fn -> 0 end) |> kb_to_mb(),
        "avg_process_tree_cpu_percent" => average(tree_cpu),
        "peak_system_used_mb" => Enum.max(used_mb, fn -> nil end),
        "swapout_delta" => delta(swapouts)
      },
      "artifacts" => %{
        "samples_jsonl" => display_path(Path.join(output_dir, "samples.jsonl")),
        "summary_json" => display_path(Path.join(output_dir, "summary.json")),
        "report_md" => display_path(Path.join(output_dir, "report.md")),
        "completion_audit_json" => display_path(Path.join(output_dir, "completion_audit.json"))
      },
      "notes" => [
        "This sampler measures local process/system pressure only.",
        "It does not spawn Codex agents and does not measure provider-side inference memory.",
        "Use target_n/configured_limit as run metadata, then reconcile against actual spawned work."
      ]
    }
  end

  defp completion_audit(summary, samples) do
    requirements = [
      requirement("samples_jsonl", length(samples) > 0, "At least one sample was collected."),
      requirement(
        "process_pressure",
        is_number(get_in(summary, ["pressure", "peak_tracked_rss_kb"])),
        "Tracked process RSS was summarized."
      ),
      requirement(
        "process_tree_pressure",
        is_number(get_in(summary, ["pressure", "peak_process_tree_rss_kb"])),
        "Tracked root process trees were summarized from PID/PPID snapshots."
      ),
      requirement(
        "system_pressure",
        is_number(get_in(summary, ["pressure", "peak_system_used_mb"])),
        "System memory pressure was summarized from vm_stat."
      ),
      requirement(
        "config_context",
        Map.has_key?(summary["codex_config"], "configured_limit"),
        "Configured limit context was recorded or explicitly left unknown."
      ),
      requirement(
        "bounded_claims",
        true,
        "Report states that measurements are local pressure, not model/provider memory."
      )
    ]

    status =
      if Enum.all?(requirements, &(&1["status"] == "proved")),
        do: "completion_ready",
        else: "incomplete"

    %{
      "status" => status,
      "requirements" => requirements
    }
  end

  defp requirement(id, true, evidence),
    do: %{"id" => id, "status" => "proved", "evidence" => evidence}

  defp requirement(id, false, evidence),
    do: %{"id" => id, "status" => "missing", "evidence" => evidence}

  defp render_report(summary) do
    audit_rows =
      summary["completion_audit"]["requirements"]
      |> Enum.map(fn req -> "| `#{req["id"]}` | #{req["status"]} | #{req["evidence"]} |" end)
      |> Enum.join("\n")

    config_rows =
      summary["codex_config"]["candidate_settings"]
      |> Enum.map(fn setting -> "| `#{setting["key"]}` | `#{setting["value"]}` |" end)
      |> case do
        [] -> "| _none detected_ | _n/a_ |"
        rows -> Enum.join(rows, "\n")
      end

    """
    # Pixir vs Codex Resource Pressure Benchmark

    Run id: `#{summary["run_id"]}`

    ## Scope

    This report measures local Mac pressure during Pixir or Codex work. It does not
    measure provider-side model memory or prove BEAM-vs-Codex work quality.

    ## Run Metadata

    | Field | Value |
    |---|---:|
    | Target N | #{summary["target_n"] || "unknown"} |
    | Profile | #{summary["profile"]["name"]} |
    | Configured limit | #{summary["codex_config"]["configured_limit"] || "unknown"} |
    | Samples | #{summary["samples_count"]} |
    | Interval ms | #{summary["interval_ms"]} |

    ## Pressure Summary

    | Metric | Value |
    |---|---:|
    | Peak tracked RSS MB | #{summary["pressure"]["peak_tracked_rss_mb"]} |
    | Avg tracked CPU % | #{summary["pressure"]["avg_tracked_cpu_percent"]} |
    | Peak process-tree count | #{summary["pressure"]["peak_process_tree_count"]} |
    | Peak process-tree RSS MB | #{summary["pressure"]["peak_process_tree_rss_mb"]} |
    | Avg process-tree CPU % | #{summary["pressure"]["avg_process_tree_cpu_percent"]} |
    | Peak system used MB | #{summary["pressure"]["peak_system_used_mb"] || "unknown"} |
    | Swapout delta | #{summary["pressure"]["swapout_delta"] || "unknown"} |

    ## Codex Config Candidates

    | Key | Value |
    |---|---|
    #{config_rows}

    ## Completion Audit

    | Requirement | Status | Evidence |
    |---|---|---|
    #{audit_rows}
    """
  end

  defp print_dry_run(
         output_dir,
         duration_seconds,
         interval_ms,
         profile_name,
         profile,
         process_patterns,
         target_n,
         label,
         config_snapshot,
         json?
       ) do
    result = %{
      "ok" => true,
      "mode" => "dry_run",
      "command" => "mix pixir.bench.codex_pressure",
      "label" => label,
      "profile" => %{
        "name" => profile_name,
        "description" => profile["description"],
        "available_profiles" => available_profiles()
      },
      "target_n" => target_n,
      "duration_seconds" => duration_seconds,
      "interval_ms" => interval_ms,
      "process_patterns" => process_patterns,
      "codex_config" => config_snapshot,
      "estimated_real_network_runs" => 0,
      "would_run" => [
        "ps -axo pid=,ppid=,rss=,pcpu=,comm=",
        "vm_stat",
        "sysctl -n hw.memsize"
      ],
      "would_write" => planned_writes(output_dir),
      "requirements" => [
        "Start sampler before launching the target Codex parallel run.",
        "Record target N and configured Codex concurrency limit.",
        "Reconcile samples against actual spawned/completed agent evidence."
      ],
      "proof_states" => @proof_states
    }

    if json? do
      IO.puts(Jason.encode!(result, pretty: true))
    else
      Mix.shell().info("""
      Would sample local Pixir/Codex pressure.
        output: #{output_dir}
        profile: #{profile_name}
        duration: #{duration_seconds}s
        interval: #{interval_ms}ms
        process patterns: #{Enum.join(process_patterns, ",")}
      """)
    end
  end

  defp print_help(json?) do
    payload = %{
      "ok" => true,
      "command" => "mix pixir.bench.codex_pressure",
      "description" => "Sample local Mac process and memory pressure during Pixir or Codex work.",
      "options" => [
        "--duration-seconds N",
        "--interval-ms N",
        "--target-n N",
        "--configured-limit N",
        "--profile NAME",
        "--process-patterns codex,electron",
        "--codex-config PATH",
        "--output DIR",
        "--dry-run",
        "--json",
        "--help"
      ],
      "artifacts" => planned_writes("<output>"),
      "profiles" => available_profiles(),
      "proof_states" => @proof_states
    }

    if json? do
      IO.puts(Jason.encode!(payload, pretty: true))
    else
      Mix.shell().info("""
      mix pixir.bench.codex_pressure [options]

      Options:
        --duration-seconds N      Sampling duration. Default: #{@default_duration_seconds}
        --interval-ms N           Sampling interval. Default: #{@default_interval_ms}
        --target-n N              Target Codex parallelism metadata.
        --configured-limit N      Codex configured concurrency metadata.
        --profile NAME            Measurement profile. Default: #{@default_profile}
        --process-patterns CSV    Override process command substrings. Implies custom profile.
        --codex-config PATH       Config file to scan for concurrency-like keys.
        --output DIR              Output directory.
        --dry-run                 Plan without sampling or writing.
        --json                    Emit machine-readable output.
        --help                    Show this help.
      """)
    end
  end

  defp codex_config_snapshot(path, configured_limit) do
    candidate_settings = read_config_candidates(path)

    %{
      "path" => display_path(path),
      "exists" => File.exists?(path),
      "configured_limit" => configured_limit || inferred_configured_limit(candidate_settings),
      "configured_limit_source" => configured_limit_source(configured_limit, candidate_settings),
      "candidate_settings" => candidate_settings
    }
  end

  defp read_config_candidates(path) do
    if File.exists?(path) do
      path
      |> File.read!()
      |> String.split("\n")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "#")))
      |> Enum.flat_map(&config_candidate/1)
    else
      []
    end
  end

  defp config_candidate(line) do
    case String.split(line, "=", parts: 2) do
      [key, value] ->
        key = String.trim(key)
        lower_key = String.downcase(key)

        if String.match?(lower_key, ~r/(agent|thread|parallel|concurr|limit|max)/) do
          [%{"key" => key, "value" => value |> String.trim() |> redact_value()}]
        else
          []
        end

      _ ->
        []
    end
  end

  defp redact_value(value) do
    if String.match?(String.downcase(value), ~r/(token|secret|key|password)/),
      do: "[redacted]",
      else: value
  end

  defp inferred_configured_limit(candidate_settings) do
    candidate_settings
    |> Enum.find_value(fn %{"key" => key, "value" => value} ->
      key = String.downcase(key)

      if key in ["max_threads", "max_parallel_agents", "max_agents", "agent_limit"] do
        parse_integer(value)
      end
    end)
  end

  defp configured_limit_source(configured_limit, _candidate_settings)
       when is_integer(configured_limit),
       do: "cli"

  defp configured_limit_source(_configured_limit, candidate_settings) do
    if inferred_configured_limit(candidate_settings), do: "detected", else: "unknown"
  end

  defp parse_integer(value) do
    value
    |> to_string()
    |> String.trim()
    |> String.trim("\"")
    |> Integer.parse()
    |> case do
      {integer, ""} when integer > 0 -> integer
      _ -> nil
    end
  end

  defp planned_writes(output_dir) do
    for file <- ["samples.jsonl", "summary.json", "report.md", "completion_audit.json"] do
      display_path(Path.join(output_dir, file))
    end
  end

  defp default_codex_config do
    Path.expand("~/.codex/config.toml")
  end

  defp display_path(path) do
    expanded = Path.expand(path)
    workspace = Path.expand(File.cwd!())
    home = Path.expand("~")

    cond do
      display = display_relative(expanded, workspace, "$WORKSPACE") ->
        display

      display = display_relative(expanded, home, "$HOME") ->
        display

      display = display_relative(expanded, Path.expand(System.tmp_dir!()), "$TMPDIR") ->
        display

      display = display_relative(expanded, Path.expand("/tmp"), "$TMPDIR") ->
        display

      display = display_relative(expanded, Path.expand("/private/tmp"), "$TMPDIR") ->
        display

      true ->
        expanded
    end
  end

  defp display_relative(path, root, token) do
    cond do
      path == root -> token
      String.starts_with?(path, root <> "/") -> token <> String.replace_prefix(path, root, "")
      true -> nil
    end
  end

  defp available_profiles do
    @profiles
    |> Enum.map(fn {name, profile} ->
      %{
        "name" => name,
        "description" => profile["description"],
        "process_patterns" => profile["process_patterns"]
      }
    end)
    |> Enum.sort_by(& &1["name"])
  end

  defp profile_name(opts) do
    cond do
      Keyword.has_key?(opts, :profile) -> Keyword.fetch!(opts, :profile)
      Keyword.has_key?(opts, :process_patterns) -> "custom"
      true -> @default_profile
    end
  end

  defp profile!(name, json?) do
    case Map.fetch(@profiles, name) do
      {:ok, profile} ->
        profile

      :error ->
        fail!(
          :invalid_profile,
          "--profile must be one of the supported measurement profiles.",
          %{profile: name, supported_profiles: Map.keys(@profiles) |> Enum.sort()},
          json?
        )
    end
  end

  defp parse_patterns(nil, %{"process_patterns" => []}, json?) do
    fail!(
      :missing_process_patterns,
      "--profile custom requires --process-patterns.",
      %{profile: "custom"},
      json?
    )
  end

  defp parse_patterns(nil, %{"process_patterns" => patterns}, _json?), do: patterns

  defp parse_patterns(value, _profile, json?) do
    value
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> case do
      [] ->
        fail!(
          :missing_process_patterns,
          "--process-patterns must include at least one command substring.",
          %{process_patterns: value},
          json?
        )

      patterns ->
        patterns
    end
  end

  defp validate_positive_integer!(_field, value, _json?) when is_integer(value) and value > 0,
    do: :ok

  defp validate_positive_integer!(field, value, json?) do
    fail!(
      :invalid_positive_integer,
      "--#{String.replace(to_string(field), "_", "-")} must be a positive integer.",
      %{field: field, value: value},
      json?
    )
  end

  defp fail!(kind, message, details, json?) do
    payload = %{
      "ok" => false,
      "error" => %{
        "kind" => to_string(kind),
        "message" => message,
        "details" => details,
        "root_agent_hint" => root_agent_hint(kind)
      }
    }

    if json? do
      IO.puts(Jason.encode!(payload, pretty: true))
    else
      Mix.shell().error("#{message} #{inspect(details)}")
    end

    exit({:shutdown, 1})
  end

  defp root_agent_hint(:invalid_options),
    do: "Run with --help --json and remove unsupported options."

  defp root_agent_hint(:invalid_positive_integer), do: "Use positive integer sampling values."
  defp root_agent_hint(:invalid_target_n), do: "Record target N as a positive integer or omit it."

  defp root_agent_hint(:invalid_configured_limit),
    do: "Record configured limit as a positive integer or omit it."

  defp root_agent_hint(:invalid_profile),
    do: "Run with --help --json and choose one of the advertised profiles."

  defp root_agent_hint(:missing_process_patterns),
    do: "Pass --process-patterns with one or more comma-separated process command substrings."

  defp root_agent_hint(_kind),
    do: "Inspect the structured error details and rerun with --dry-run --json."

  defp write_jsonl!(path, records) do
    body = records |> Enum.map(&Jason.encode!/1) |> Enum.join("\n")
    File.write!(path, body <> "\n")
  end

  defp timestamp do
    DateTime.utc_now()
    |> Calendar.strftime("%Y%m%dT%H%M%SZ")
  end

  defp parse_float(value) do
    case Float.parse(value) do
      {float, _rest} -> float
      :error -> 0.0
    end
  end

  defp average([]), do: 0.0

  defp average(values) do
    values
    |> Enum.sum()
    |> Kernel./(length(values))
    |> Float.round(2)
  end

  defp delta([]), do: nil
  defp delta([_single]), do: 0
  defp delta(values), do: List.last(values) - List.first(values)

  defp kb_to_mb(kb), do: Float.round(kb / 1024, 2)
  defp bytes_to_mb(bytes), do: Float.round(bytes / 1024 / 1024, 2)
end
