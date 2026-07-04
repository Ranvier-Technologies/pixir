defmodule Mix.Tasks.Pixir.Bench.RealSubagents do
  @shortdoc "Run real-network T3/Pixir/Codex Subagents gates"

  @moduledoc """
  Runs small, real-network Subagents gates through the local T3 Code harnesses.

  This is the first executable adapter for
  `docs/benchmarks/real-network-subagents.md`. It intentionally measures only
  provider/model capability:

    * does the provider path accept the requested model?
    * does T3 observe Subagent lifecycle for that provider/model?
    * how long did the smoke run take?

  In `common_model_gate`, it first runs tiny no-subagent provider probes for each
  candidate model on both provider paths. It then runs `smoke_real_n2` only for the
  first commonly accepted model. A model or lifecycle divergence is recorded as an
  explicit non-comparable abort, not a failed head-to-head.

  In `representative_review_n3`, it generates the seeded fixture, writes `benchctl`,
  injects a fixed three-child scenario prompt, and scores strict final JSON. In
  `scaling_lifecycle`, it generates one shard assignment per requested child and
  scores lifecycle plus mechanical assignment completion for N=10+ fan-out runs. Usage
  reconciliation is still not implemented.

  The task shells into the paired local T3 Code checkout and runs local-only harnesses:

    * `scripts/pixir-subagents-benchmark.ts`
    * `scripts/codex-subagents-observability-probe.ts`

  Default run is deliberately small:

      mix pixir.bench.real_subagents

  Useful variants:

      mix pixir.bench.real_subagents --dry-run
      mix pixir.bench.real_subagents --scenario common_model_gate --dry-run --json
      mix pixir.bench.real_subagents --scenario common_model_gate --models gpt-5.5 --reasoning-effort low
      mix pixir.bench.real_subagents --scenario probe --models gpt-5.5
      mix pixir.bench.real_subagents --scenario smoke_real_n2 --models gpt-5.5
      mix pixir.bench.real_subagents --scenario representative_review_n3 --dry-run
      mix pixir.bench.real_subagents --scenario scaling_lifecycle --models gpt-5.5 --reasoning-effort low --n 10
      mix pixir.bench.real_subagents --providers pixir --pixir-models gpt-5.3-codex-spark
      mix pixir.bench.real_subagents --providers codex --codex-models default,gpt-5.5
      mix pixir.bench.real_subagents --models gpt-5.5 --reasoning-effort low
      mix pixir.bench.real_subagents --models gpt-5.5 --reasoning-effort low --n-values 1,3,5 --repetitions 3 --include-baseline
      mix pixir.bench.real_subagents --n 2 --output .pixir/benchmarks/real-subagents/manual

  Options:

    * `--scenario` - `capability_matrix`, `probe`, `smoke_real_n2`,
      `common_model_gate`, `representative_review_n3`, or `scaling_lifecycle`. Default:
      `capability_matrix`.
    * `--providers` - comma-separated `pixir,codex` subset. Default: `pixir,codex`.
    * `--pixir-models` - comma-separated models for Pixir. Default:
      `gpt-5.3-codex-spark`.
    * `--codex-models` - comma-separated models for Codex. Default:
      `default,gpt-5.3-codex-spark`.
    * `--models` / `--model-candidates` - comma-separated models for both providers.
      `default` means "do not pass --model".
    * `--reasoning-effort` - effort knob passed to both provider paths. Default: `low`.
    * `--n` - child count for the smoke probe. Default: `1`.
    * `--n-values` - comma-separated child counts for a scaling suite.
    * `--repetitions` - repetitions per provider/model/N. Default: `1`.
    * `--include-baseline` - add no-network T3 harness baselines per provider/model/repetition.
    * `--json` - emit machine-readable result or dry-run output on stdout.
    * `--output` - output directory. Default:
      `.pixir/benchmarks/real-subagents/<run-id>`.
    * `--t3-code-path` - paired T3 Code checkout. Default: `T3_CODE_PATH`, or
      `../t3code` relative to the Pixir repo.
    * `--dry-run` - print planned commands without running or writing artifacts.

  Artifacts:

      runs.jsonl
      summary.json
      report.md
      fixtures/<provider>/<model>/
      provider-artifacts/<provider>/<model>/

  Each provider artifact also includes `memory-samples.txt`, a sampled process-tree
  RSS trace for the T3 harness and its descendants. This task hits real providers
  through T3 Code. Keep `--n` and model lists small.
  """

  use Mix.Task

  @default_providers ["pixir", "codex"]
  @schema_version 1
  @default_pixir_models ["gpt-5.3-codex-spark"]
  @default_codex_models ["default", "gpt-5.3-codex-spark"]
  @default_model_candidates [
    "gpt-5.5",
    "gpt-5.3-codex-spark",
    "gpt-5.3-codex",
    "gpt-5.2-codex",
    "gpt-5.1-codex"
  ]
  @default_n 1
  @smoke_n 2
  @representative_n 3
  @scaling_lifecycle_n 10
  @scaling_concurrency_cap 6
  @default_reasoning_effort "low"
  @default_repetitions 1
  @scenarios [
    "capability_matrix",
    "probe",
    "smoke_real_n2",
    "common_model_gate",
    "representative_review_n3",
    "scaling_lifecycle"
  ]
  @record_scenarios [
    "capability_matrix",
    "probe",
    "smoke_real_n2",
    "representative_review_n3",
    "scaling_lifecycle"
  ]
  @record_statuses [
    "baseline",
    "capability_diverged",
    "failed",
    "not_observed",
    "passed",
    "provider_failed",
    "provider_unknown",
    "provider_weak",
    "weak"
  ]
  @capability_statuses [
    "baseline",
    "failed",
    "not_observed",
    "observed",
    "provider_failed",
    "provider_reachable",
    "provider_unknown",
    "provider_weak",
    "unknown",
    "weak"
  ]
  @summary_statuses [
    "capability_diverged",
    "common_capability_found",
    "common_model_smoke_ready",
    "failed",
    "model_diverged",
    "not_observed",
    "provider_native_capability_found",
    "representative_incomplete",
    "representative_scored",
    "representative_weak",
    "scaling_lifecycle_incomplete",
    "scaling_lifecycle_scored",
    "scaling_lifecycle_weak"
  ]
  @expected_findings ["AUTH-001", "PROV-001", "TOOL-001", "ACP-001", "TEST-001", "SYN-001"]

  @switches [
    scenario: :string,
    providers: :string,
    pixir_models: :string,
    codex_models: :string,
    models: :string,
    model_candidates: :string,
    reasoning_effort: :string,
    n: :integer,
    n_values: :string,
    repetitions: :integer,
    include_baseline: :boolean,
    output: :string,
    t3_code_path: :string,
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

    output_dir =
      opts
      |> Keyword.get(:output, Path.join([".pixir", "benchmarks", "real-subagents", run_id]))
      |> Path.expand()

    t3_code_path = Keyword.get(opts, :t3_code_path, default_t3_code_path())
    scenario = Keyword.get(opts, :scenario, "capability_matrix")

    unless scenario in @scenarios do
      fail!(
        :invalid_scenario,
        "--scenario must be one of: #{Enum.join(@scenarios, ", ")}",
        %{scenario: scenario, allowed: @scenarios},
        json?
      )
    end

    n = Keyword.get(opts, :n, default_n(scenario))

    if invalid_n?(scenario, n) do
      fail!(
        :invalid_n,
        "--n must be #{n_expectation(scenario)}.",
        %{
          scenario: scenario,
          n: n,
          expected_minimum: min_n(scenario),
          expected_maximum: max_n(scenario)
        },
        json?
      )
    end

    n_values =
      case parse_int_csv(Keyword.get(opts, :n_values), [n], min_n(scenario), max_n(scenario)) do
        {:ok, values} ->
          values

        {:error, details} ->
          fail!(
            :invalid_n_values,
            "--n-values must contain #{n_expectation(scenario)}.",
            details,
            json?
          )
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

    include_baseline = Keyword.get(opts, :include_baseline, false)

    providers =
      opts
      |> Keyword.get(:providers)
      |> parse_csv(@default_providers)

    unknown_providers = Enum.reject(providers, &(&1 in @default_providers))

    if unknown_providers != [] do
      fail!(
        :invalid_providers,
        "--providers must include pixir, codex, or both.",
        %{providers: providers, unknown: unknown_providers, allowed: @default_providers},
        json?
      )
    end

    if providers == [] do
      fail!(
        :invalid_providers,
        "--providers must include pixir, codex, or both.",
        %{providers: Keyword.get(opts, :providers), allowed: @default_providers},
        json?
      )
    end

    reasoning_effort = Keyword.get(opts, :reasoning_effort, @default_reasoning_effort)

    if scenario == "common_model_gate" do
      plan =
        common_model_gate_plan(
          providers,
          opts,
          n,
          output_dir,
          t3_code_path,
          reasoning_effort
        )

      if Keyword.get(opts, :dry_run, false) do
        print_common_model_gate_dry_run(output_dir, plan, json?)
      else
        run_common_model_gate(plan, run_id, output_dir, json?)
      end
    else
      combos =
        combos(
          providers,
          opts,
          scenario,
          n_values,
          repetitions,
          include_baseline,
          output_dir,
          t3_code_path,
          reasoning_effort
        )

      if Keyword.get(opts, :dry_run, false) do
        print_dry_run(output_dir, combos, json?)
      else
        run_standard_scenario(combos, run_id, output_dir, scenario, json?)
      end
    end
  end

  defp run_standard_scenario(combos, run_id, output_dir, scenario, json?) do
    preflight!(hd(combos).t3_code_path, combos, json?)
    File.mkdir_p!(output_dir)
    File.mkdir_p!(Path.join(output_dir, "provider-artifacts"))

    records = Enum.map(combos, &run_combo/1)
    summary = summarize(records, run_id, output_dir, scenario)
    summary = write_outputs!(output_dir, records, summary)

    result = %{
      "ok" => completion_ready?(summary),
      "mode" => "run",
      "output_dir" => output_dir,
      "report" => Path.join(output_dir, "report.md"),
      "completion_audit" => summary["completion_audit"],
      "completion_audit_path" => Path.join(output_dir, "completion_audit.json"),
      "summary" => summary
    }

    if json? do
      IO.puts(Jason.encode!(result, pretty: true))
    else
      Mix.shell().info("""

      Real-network Subagents #{report_kind(scenario)} finished.
        output: #{output_dir}
        report: #{Path.join(output_dir, "report.md")}
        status: #{summary["status"]}
      """)
    end
  end

  defp write_outputs!(output_dir, records, summary) do
    draft_report = render_report(summary, records)
    validation = validate_benchmark(records, summary, draft_report)
    completion_audit = completion_audit(records, summary, validation)

    summary =
      summary
      |> Map.put("schema_validation", validation)
      |> Map.put("completion_audit", completion_audit)

    report = render_report(summary, records)
    validation = validate_benchmark(records, summary, report)
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

    summary
  end

  defp completion_ready?(summary),
    do: get_in(summary, ["completion_audit", "status"]) == "completion_ready"

  defp invalid_n?(scenario, n) do
    n < min_n(scenario) or exceeds_max_n?(n, max_n(scenario))
  end

  defp exceeds_max_n?(_n, nil), do: false
  defp exceeds_max_n?(n, max), do: n > max

  defp min_n("probe"), do: 0
  defp min_n("representative_review_n3"), do: @representative_n
  defp min_n(_scenario), do: 1

  defp n_expectation("probe"), do: "a non-negative integer"
  defp n_expectation("representative_review_n3"), do: "exactly #{@representative_n}"

  defp n_expectation("scaling_lifecycle"),
    do: "a positive integer; use 10 or more for completion-ready scaling evidence"

  defp n_expectation(_scenario), do: "a positive integer"

  defp default_n("probe"), do: 0
  defp default_n("smoke_real_n2"), do: @smoke_n
  defp default_n("common_model_gate"), do: @smoke_n
  defp default_n("representative_review_n3"), do: @representative_n
  defp default_n("scaling_lifecycle"), do: @scaling_lifecycle_n
  defp default_n(_scenario), do: @default_n

  defp max_n("representative_review_n3"), do: @representative_n
  defp max_n(_scenario), do: nil

  defp common_model_gate_plan(
         providers,
         opts,
         n,
         output_dir,
         t3_code_path,
         reasoning_effort
       ) do
    candidates = candidate_models(opts)

    probe_combos =
      for provider <- providers,
          model <- candidates do
        combo(
          provider,
          model,
          "probe",
          0,
          1,
          false,
          output_dir,
          t3_code_path,
          reasoning_effort
        )
      end

    smoke_combos =
      for provider <- providers,
          model <- candidates do
        combo(
          provider,
          model,
          "smoke_real_n2",
          n,
          1,
          false,
          output_dir,
          t3_code_path,
          reasoning_effort
        )
      end

    %{
      scenario: "common_model_gate",
      providers: providers,
      candidates: candidates,
      smoke_n: n,
      probe_combos: probe_combos,
      smoke_combos: smoke_combos,
      t3_code_path: t3_code_path,
      reasoning_effort: reasoning_effort
    }
  end

  defp candidate_models(opts) do
    opts
    |> Keyword.get(:models, Keyword.get(opts, :model_candidates))
    |> parse_csv(@default_model_candidates)
  end

  defp run_common_model_gate(plan, run_id, output_dir, json?) do
    combos = plan.probe_combos ++ plan.smoke_combos
    preflight!(plan.t3_code_path, combos, json?)
    File.mkdir_p!(output_dir)
    File.mkdir_p!(Path.join(output_dir, "provider-artifacts"))

    probe_records = Enum.map(plan.probe_combos, &run_combo/1)
    selected = select_common_probe_model(probe_records, plan.candidates)

    smoke_records =
      case selected do
        nil ->
          []

        %{"model_requested" => selected_model} ->
          plan.smoke_combos
          |> Enum.filter(&(&1.model_requested == selected_model))
          |> Enum.map(&run_combo/1)
      end

    records = probe_records ++ smoke_records

    summary =
      records
      |> summarize(run_id, output_dir, "common_model_gate")
      |> attach_common_model_gate(plan, records, selected)

    summary = write_outputs!(output_dir, records, summary)

    result = %{
      "ok" => common_model_gate_ok?(summary),
      "mode" => "run",
      "output_dir" => output_dir,
      "report" => Path.join(output_dir, "report.md"),
      "completion_audit" => summary["completion_audit"],
      "completion_audit_path" => Path.join(output_dir, "completion_audit.json"),
      "summary" => summary
    }

    if json? do
      IO.puts(Jason.encode!(result, pretty: true))
    else
      Mix.shell().info("""

      Real-network Subagents common-model gate finished.
        output: #{output_dir}
        report: #{Path.join(output_dir, "report.md")}
        status: #{summary["status"]}
        selected_model: #{get_in(summary, ["common_model_gate", "selected_model_requested"]) || "<none>"}
      """)
    end
  end

  defp common_model_gate_ok?(summary) do
    status = summary["status"]

    completion_ready?(summary) and
      summary["failed_count"] == 0 and
      status in ["common_model_smoke_ready", "model_diverged", "capability_diverged"]
  end

  defp combos(
         providers,
         opts,
         scenario,
         n_values,
         repetitions,
         include_baseline,
         output_dir,
         t3_code_path,
         reasoning_effort
       ) do
    shared_models = Keyword.get(opts, :models) || Keyword.get(opts, :model_candidates)

    pixir_models =
      shared_models
      |> Kernel.||(Keyword.get(opts, :pixir_models))
      |> parse_csv(@default_pixir_models)

    codex_models =
      shared_models
      |> Kernel.||(Keyword.get(opts, :codex_models))
      |> parse_csv(@default_codex_models)

    provider_models =
      providers
      |> Enum.flat_map(fn
        "pixir" -> Enum.map(pixir_models, &{"pixir", &1})
        "codex" -> Enum.map(codex_models, &{"codex", &1})
      end)

    baseline_combos =
      if include_baseline do
        for {provider, model} <- provider_models,
            repetition <- 1..repetitions do
          combo(
            provider,
            model,
            scenario,
            0,
            repetition,
            true,
            output_dir,
            t3_code_path,
            reasoning_effort
          )
        end
      else
        []
      end

    run_combos =
      for {provider, model} <- provider_models,
          n <- n_values,
          repetition <- 1..repetitions do
        combo(
          provider,
          model,
          scenario,
          n,
          repetition,
          false,
          output_dir,
          t3_code_path,
          reasoning_effort
        )
      end

    baseline_combos ++ run_combos
  end

  defp combo(
         provider,
         model,
         scenario,
         n,
         repetition,
         baseline?,
         output_dir,
         t3_code_path,
         reasoning_effort
       ) do
    model_slug = slug(model)

    run_slug =
      if baseline?,
        do: Path.join(["baseline", "rep-#{repetition}"]),
        else: Path.join(["n-#{n}", "rep-#{repetition}"])

    artifact_dir =
      Path.join([
        output_dir,
        "provider-artifacts",
        provider,
        model_slug,
        run_slug
      ])

    fixture_dir = Path.join([output_dir, "fixtures", provider, model_slug, run_slug])
    prompt_file = Path.join(artifact_dir, "prompt.md")

    script =
      case provider do
        "pixir" -> "scripts/pixir-subagents-benchmark.ts"
        "codex" -> "scripts/codex-subagents-observability-probe.ts"
      end

    args =
      [script, "--n", Integer.to_string(n), "--output", artifact_dir] ++
        scenario_args(scenario, fixture_dir, prompt_file) ++
        model_args(model) ++
        reasoning_effort_args(reasoning_effort) ++ baseline_args(baseline?) ++ ["--json"]

    %{
      provider: provider,
      model_requested: model,
      reasoning_effort: reasoning_effort,
      scenario: scenario,
      n: n,
      repetition: repetition,
      baseline: baseline?,
      fixture_dir: fixture_dir,
      prompt_file: prompt_file,
      artifact_dir: artifact_dir,
      memory_samples_path: Path.join(artifact_dir, "memory-samples.txt"),
      t3_code_path: t3_code_path,
      args: args,
      raw_result_path: raw_result_path(provider, artifact_dir)
    }
  end

  defp run_combo(combo) do
    File.mkdir_p!(combo.artifact_dir)
    maybe_prepare_fixture(combo)
    started_at = DateTime.utc_now()
    started_native = System.monotonic_time(:millisecond)

    Mix.shell().info(
      "Running #{combo.provider} model=#{combo.model_requested} reasoning=#{combo.reasoning_effort} n=#{combo.n} rep=#{combo.repetition}#{if combo.baseline, do: " baseline", else: ""}..."
    )

    {output, exit_code} = run_t3_harness(combo)
    duration_ms = System.monotonic_time(:millisecond) - started_native

    raw =
      case File.read(combo.raw_result_path) do
        {:ok, contents} ->
          case Jason.decode(contents) do
            {:ok, decoded} -> decoded
            {:error, error} -> %{"decode_error" => inspect(error), "raw_output" => output}
          end

        {:error, reason} ->
          %{"read_error" => inspect(reason), "raw_output" => output}
      end

    normalize_record(combo, raw, exit_code, DateTime.to_iso8601(started_at), duration_ms)
  end

  defp run_t3_harness(combo) do
    script = """
    set -e
    if [ -s "$HOME/.nvm/nvm.sh" ]; then
      . "$HOME/.nvm/nvm.sh"
      nvm use 24 >/dev/null
    fi
    PATH="$PWD/node_modules/.bin:$PATH"
    samples=#{shell_escape(combo.memory_samples_path)}
    output=$(mktemp)
    : > "$samples"
    bun #{shell_join(combo.args)} > "$output" 2>&1 &
    bench_pid=$!
    while kill -0 "$bench_pid" 2>/dev/null; do
      printf -- '--- %s %s\\n' "$(date +%s)" "$bench_pid" >> "$samples"
      ps -axo pid=,ppid=,rss=,comm= >> "$samples"
      sleep 0.5
    done
    set +e
    wait "$bench_pid"
    bench_status=$?
    set -e
    printf -- '--- %s %s\\n' "$(date +%s)" "$bench_pid" >> "$samples"
    ps -axo pid=,ppid=,rss=,comm= >> "$samples"
    cat "$output"
    rm -f "$output"
    exit "$bench_status"
    """

    System.cmd("zsh", ["-lc", script], cd: combo.t3_code_path, stderr_to_stdout: true)
  end

  defp normalize_record(combo, raw, exit_code, started_at, duration_ms) do
    metrics =
      raw
      |> Map.get("metrics", %{})
      |> Map.merge(memory_metrics(combo.memory_samples_path))

    raw_status = raw["status"] || if(exit_code == 0, do: "unknown", else: "failed")
    effective_exit_code = effective_exit_code(raw_status, exit_code)
    capability = capability_status(combo, raw_status)

    score = maybe_score(combo, raw)
    status = scenario_status(combo, effective_exit_code, capability, score)

    %{
      "schema_version" => @schema_version,
      "run_id" => raw["run_id"],
      "scenario" => combo.scenario,
      "provider" => combo.provider,
      "provider_path" => raw["provider_path"] || provider_path(combo.provider),
      "status" => status,
      "raw_status" => raw_status,
      "capability_status" => capability,
      "started_at" => started_at,
      "duration_ms" => duration_ms,
      "n" => combo.n,
      "repetition" => combo.repetition,
      "baseline" => combo.baseline,
      "network" => not combo.baseline,
      "model_requested" => combo.model_requested,
      "model_accepted" => raw["model"],
      "reasoning_effort" => combo.reasoning_effort,
      "exit_code" => effective_exit_code,
      "harness_exit_code" => exit_code,
      "metrics" => metrics,
      "lifecycle" => lifecycle(combo.provider, metrics),
      "score" => score,
      "evidence" => %{
        "raw_result_path" => Path.expand(combo.raw_result_path),
        "memory_samples_path" => Path.expand(combo.memory_samples_path),
        "artifact_dir" => Path.expand(combo.artifact_dir),
        "fixture_dir" =>
          if(scenario_uses_fixture?(combo.scenario), do: Path.expand(combo.fixture_dir)),
        "prompt_file" =>
          if(scenario_uses_fixture?(combo.scenario), do: Path.expand(combo.prompt_file)),
        "final_text" => get_in(raw, ["evidence", "final_text"]),
        "note" => get_in(raw, ["evidence", "note"]),
        "event_methods" => get_in(raw, ["evidence", "event_methods"]),
        "tool_events" => get_in(raw, ["evidence", "tool_events"])
      },
      "non_equivalence_notes" => non_equivalence_notes(combo.provider, raw_status, raw)
    }
  end

  defp capability_status(%{scenario: "probe"}, "passed"), do: "provider_reachable"
  defp capability_status(%{scenario: "probe"}, "weak"), do: "provider_weak"
  defp capability_status(%{scenario: "probe"}, "baseline"), do: "baseline"
  defp capability_status(%{scenario: "probe"}, "failed"), do: "provider_failed"
  defp capability_status(%{scenario: "probe"}, _other), do: "provider_unknown"

  defp capability_status(%{provider: "pixir"}, "passed"), do: "observed"
  defp capability_status(%{provider: "pixir"}, "weak"), do: "weak"
  defp capability_status(%{provider: "codex"}, "observed"), do: "observed"
  defp capability_status(_combo, "baseline"), do: "baseline"
  defp capability_status(_combo, "not_observed"), do: "not_observed"
  defp capability_status(_combo, "weak"), do: "weak"
  defp capability_status(_combo, "failed"), do: "failed"
  defp capability_status(_combo, _other), do: "unknown"

  defp effective_exit_code(raw_status, _exit_code)
       when raw_status in ["passed", "observed", "weak", "not_observed", "baseline"],
       do: 0

  defp effective_exit_code(_raw_status, exit_code), do: exit_code

  defp record_status(exit_code, _capability) when exit_code != 0, do: "failed"
  defp record_status(_exit_code, "observed"), do: "passed"
  defp record_status(_exit_code, capability), do: capability

  defp scenario_status(%{baseline: true}, _exit_code, _capability, _score), do: "baseline"

  defp scenario_status(%{scenario: "probe"}, _exit_code, "provider_reachable", _score),
    do: "passed"

  defp scenario_status(%{scenario: "probe"}, _exit_code, capability, _score),
    do: capability

  defp scenario_status(_combo, exit_code, _capability, _score)
       when exit_code != 0,
       do: "failed"

  defp scenario_status(%{scenario: "representative_review_n3"}, _exit_code, capability, score) do
    cond do
      capability != "observed" -> capability
      score["json_parse_status"] != "parsed" -> "weak"
      score["expected_recall"] >= 0.5 and score["tool_compliance"] == true -> "passed"
      true -> "weak"
    end
  end

  defp scenario_status(%{scenario: "scaling_lifecycle"}, _exit_code, capability, score) do
    cond do
      capability != "observed" ->
        capability

      score["json_parse_status"] != "parsed" ->
        "weak"

      score["spawn_request_satisfied"] == true and score["wait_completion_observed"] == true and
        score["assignment_recall"] == 1.0 and score["assignment_precision"] == 1.0 and
        score["benchctl_success_observed"] == true and
        score["json_requested_children_matches"] == true and
          score["tool_compliance"] == true ->
        "passed"

      true ->
        "weak"
    end
  end

  defp scenario_status(_combo, exit_code, capability, _score),
    do: record_status(exit_code, capability)

  defp lifecycle("pixir", metrics) do
    %{
      "spawn_visible_count" => metrics["spawned_visible_count"] || 0,
      "wait_visible_count" => metrics["wait_visible_count"] || 0,
      "completed_count" => nil
    }
  end

  defp lifecycle("codex", metrics) do
    %{
      "spawn_visible_count" => metrics["collab_spawn_completed_count"] || 0,
      "wait_visible_count" => metrics["collab_wait_completed_count"] || 0,
      "completed_count" => nil
    }
  end

  defp memory_metrics(samples_path) do
    with {:ok, contents} <- File.read(samples_path),
         [_ | _] = snapshots <- parse_memory_snapshots(contents),
         [_ | _] = summaries <- Enum.map(snapshots, &memory_snapshot_summary/1),
         peak <- Enum.max_by(summaries, & &1["tree_rss_kb"]) do
      %{
        "memory_sample_count" => length(summaries),
        "peak_tree_rss_kb" => peak["tree_rss_kb"],
        "peak_tree_rss_mb" => Float.round(peak["tree_rss_kb"] / 1024, 2),
        "peak_tree_process_count" => peak["process_count"],
        "peak_process_rss_kb" => peak["peak_process_rss_kb"],
        "peak_process_comm" => peak["peak_process_comm"],
        "peak_component_rss_kb" => peak["component_rss_kb"],
        "memory_peak_at_ms" => peak["at_ms"]
      }
    else
      _ ->
        %{
          "memory_sample_count" => 0,
          "peak_tree_rss_kb" => nil,
          "peak_tree_rss_mb" => nil,
          "peak_tree_process_count" => nil,
          "peak_process_rss_kb" => nil,
          "peak_process_comm" => nil,
          "peak_component_rss_kb" => %{},
          "memory_peak_at_ms" => nil
        }
    end
  end

  defp parse_memory_snapshots(contents) do
    contents
    |> String.split("\n", trim: true)
    |> Enum.reduce([], fn line, acc ->
      case parse_memory_marker(line) do
        {:ok, at_ms, root_pid} ->
          [%{at_ms: at_ms, root_pid: root_pid, rows: []} | acc]

        :error ->
          case {acc, parse_memory_row(line)} do
            {[%{} = current | rest], {:ok, row}} ->
              [%{current | rows: [row | current.rows]} | rest]

            _ ->
              acc
          end
      end
    end)
    |> Enum.reverse()
    |> Enum.map(&%{&1 | rows: Enum.reverse(&1.rows)})
  end

  defp parse_memory_marker("--- " <> rest) do
    case String.split(rest, ~r/\s+/, parts: 2) do
      [at_ms, root_pid] ->
        with {at, _rest} <- Integer.parse(at_ms),
             {pid, _rest} <- Integer.parse(root_pid) do
          {:ok, at, pid}
        else
          _ -> :error
        end

      _ ->
        :error
    end
  end

  defp parse_memory_marker(_line), do: :error

  defp parse_memory_row(line) do
    case String.split(String.trim(line), ~r/\s+/, parts: 4) do
      [pid, ppid, rss, comm] ->
        with {pid_i, ""} <- Integer.parse(pid),
             {ppid_i, ""} <- Integer.parse(ppid),
             {rss_i, ""} <- Integer.parse(rss) do
          {:ok, %{pid: pid_i, ppid: ppid_i, rss_kb: rss_i, comm: comm}}
        else
          _ -> :error
        end

      _ ->
        :error
    end
  end

  defp memory_snapshot_summary(%{at_ms: at_ms, root_pid: root_pid, rows: rows}) do
    pids = descendant_pids(rows, root_pid)

    tree_rows =
      Enum.filter(rows, fn row ->
        MapSet.member?(pids, row.pid)
      end)

    peak_process = Enum.max_by(tree_rows, & &1.rss_kb, fn -> %{rss_kb: 0, comm: nil} end)

    %{
      "at_ms" => at_ms,
      "process_count" => length(tree_rows),
      "tree_rss_kb" => Enum.reduce(tree_rows, 0, &(&1.rss_kb + &2)),
      "peak_process_rss_kb" => peak_process.rss_kb,
      "peak_process_comm" => peak_process.comm,
      "component_rss_kb" => component_rss(tree_rows)
    }
  end

  defp descendant_pids(rows, root_pid) do
    children_by_parent = Enum.group_by(rows, & &1.ppid)
    walk_descendants(children_by_parent, [root_pid], MapSet.new())
  end

  defp walk_descendants(_children_by_parent, [], seen), do: seen

  defp walk_descendants(children_by_parent, [pid | rest], seen) do
    if MapSet.member?(seen, pid) do
      walk_descendants(children_by_parent, rest, seen)
    else
      children = Map.get(children_by_parent, pid, []) |> Enum.map(& &1.pid)
      walk_descendants(children_by_parent, children ++ rest, MapSet.put(seen, pid))
    end
  end

  defp component_rss(rows) do
    %{
      "beam_or_erlang" => component_sum(rows, ~r/(beam|erl|pixir)/i),
      "codex" => component_sum(rows, ~r/codex/i),
      "node_or_bun" => component_sum(rows, ~r/^(node|bun)$/i),
      "shell" => component_sum(rows, ~r/^(sh|zsh|bash)$/i)
    }
  end

  defp component_sum(rows, regex) do
    rows
    |> Enum.filter(&(Regex.match?(regex, &1.comm) or Regex.match?(regex, Path.basename(&1.comm))))
    |> Enum.reduce(0, &(&1.rss_kb + &2))
  end

  defp non_equivalence_notes("pixir", _raw_status, _raw), do: []

  defp non_equivalence_notes("codex", "not_observed", _raw) do
    [
      "Codex model/path responded but did not expose collabAgentToolCall lifecycle in this run."
    ]
  end

  defp non_equivalence_notes("codex", _raw_status, raw) do
    if raw["status"] == "observed" do
      [
        "Codex lifecycle was observed, but this capability matrix does not prove Pixir-like child logs or isolated workspaces."
      ]
    else
      []
    end
  end

  defp scenario_args(scenario, fixture_dir, prompt_file)
       when scenario in ["representative_review_n3", "scaling_lifecycle"],
       do: ["--cwd", fixture_dir, "--prompt-file", prompt_file]

  defp scenario_args("probe", _fixture_dir, _prompt_file), do: ["--probe"]

  defp scenario_args(_scenario, _fixture_dir, _prompt_file), do: []

  defp scenario_uses_fixture?(scenario),
    do: scenario in ["representative_review_n3", "scaling_lifecycle"]

  defp maybe_prepare_fixture(%{baseline: true}), do: :ok

  defp maybe_prepare_fixture(%{scenario: "representative_review_n3"} = combo) do
    File.rm_rf!(combo.fixture_dir)
    File.mkdir_p!(combo.fixture_dir)
    File.mkdir_p!(combo.artifact_dir)
    write_fixture!(combo.fixture_dir)
    File.write!(combo.prompt_file, representative_prompt(combo.n))
  end

  defp maybe_prepare_fixture(%{scenario: "scaling_lifecycle"} = combo) do
    File.rm_rf!(combo.fixture_dir)
    File.mkdir_p!(combo.fixture_dir)
    File.mkdir_p!(combo.artifact_dir)
    write_scaling_fixture!(combo.fixture_dir, combo.n)
    File.write!(combo.prompt_file, scaling_lifecycle_prompt(combo.n, combo.provider))
  end

  defp maybe_prepare_fixture(_combo), do: :ok

  defp write_fixture!(root) do
    File.mkdir_p!(Path.join(root, "src/auth"))
    File.mkdir_p!(Path.join(root, "src/provider"))
    File.mkdir_p!(Path.join(root, "src/tools"))
    File.mkdir_p!(Path.join(root, "src/ui"))
    File.mkdir_p!(Path.join(root, "tests"))
    File.mkdir_p!(Path.join(root, "truth"))

    File.write!(Path.join(root, "AGENTS.md"), fixture_agents())
    File.write!(Path.join(root, "README.md"), fixture_readme())
    File.write!(Path.join(root, "src/auth/token_store.ex"), fixture_auth())
    File.write!(Path.join(root, "src/provider/retry_policy.ex"), fixture_provider())
    File.write!(Path.join(root, "src/tools/executor.ex"), fixture_tools())
    File.write!(Path.join(root, "src/ui/acp_translate.ex"), fixture_ui())
    File.write!(Path.join(root, "tests/smoke_test.exs"), fixture_test())

    File.write!(
      Path.join(root, "truth/expected_findings.json"),
      Jason.encode!(expected_findings(), pretty: true)
    )

    benchctl = Path.join(root, "benchctl")
    File.write!(benchctl, benchctl_script())
    File.chmod!(benchctl, 0o755)
  end

  defp representative_prompt(n) do
    """
    You are running a real-network subagents benchmark in a small fixture repo.

    Spawn exactly #{n} child agents immediately. The parent must not call read, bash,
    list, grep, or any other inspection tool before all child agents are spawned.
    After spawning, the parent should only call the wait tool and then write final JSON.

    If the tool asks for an agent name, use agent="worker", max_depth=1, and timeout_ms=180000.

    - Child A: inspect auth.
    - Child B: inspect provider.
    - Child C: inspect tools and ui.

    Each child must:
    1. Read AGENTS.md.
    2. Run ./benchctl inspect <area> for every assigned area.
    3. Return concise findings with ids if the evidence supports them.

    Child tool budget:
    - Child A may use at most 3 tool calls.
    - Child B may use at most 3 tool calls.
    - Child C may use at most 4 tool calls.

    The parent must deduplicate child findings and finish with strict JSON only, no prose
    and no markdown fences:

    {
      "requested_children": #{n},
      "completed_children": number,
      "findings": [
        {"id": "AUTH-001", "area": "auth", "file": "src/auth/token_store.ex", "evidence": "short quote-free explanation"}
      ],
      "synthesis": ["short safety/reliability summary"],
      "tool_notes": ["which inspect/read/shell tools were used"]
    }

    Use ids in this format only when evidence supports them: AUTH-001, PROV-001,
    TOOL-001, ACP-001, TEST-001, SYN-001.
    Do not read truth/expected_findings.json. Do not modify files.
    Keep every evidence string under 160 characters.
    """
  end

  defp write_scaling_fixture!(root, n) do
    shards_dir = Path.join(root, "shards")
    File.mkdir_p!(shards_dir)

    File.write!(Path.join(root, "AGENTS.md"), scaling_agents())
    File.write!(Path.join(root, "README.md"), scaling_readme(n))

    Enum.each(shard_ids(n), fn shard_id ->
      File.write!(Path.join(shards_dir, "#{shard_id}.txt"), scaling_shard_file(shard_id))
    end)

    benchctl = Path.join(root, "benchctl")
    File.write!(benchctl, scaling_benchctl_script(n))
    File.chmod!(benchctl, 0o755)
  end

  defp scaling_lifecycle_prompt(n, provider) do
    target_concurrency = scaling_target_concurrency(n)
    tool_hint = scaling_tool_hint(provider, n, target_concurrency)

    assignments =
      n
      |> shard_ids()
      |> Enum.with_index(1)
      |> Enum.map_join("\n", fn {shard_id, child} ->
        "#{child}. Child #{pad3(child)}: read AGENTS.md, run ./benchctl inspect #{shard_id}, and return shard=#{shard_id}."
      end)

    """
    You are running a real-network subagent scaling benchmark in a tiny read-only fixture.

    This is a lifecycle/scaling scenario, not a code-review quality scenario.

    Spawn exactly #{n} child agents immediately. The parent must not call read, bash,
    list, grep, or any other inspection tool before all child agents are spawned.

    Provider-native tool hint:
    #{tool_hint}

    Concurrency semantics:
    - requested_children: #{n}
    - target_max_concurrency: #{target_concurrency}
    - If your subagent tool accepts a concurrency/thread option, use #{target_concurrency}.
    - If your runtime queues child agents internally, keep spawning until #{n} children are requested.
    - Do not simulate child agents in parent text.

    If the provider-native hint does not name an agent, use agent="worker",
    max_depth=1, timeout_ms=180000, and isolated workspace settings.

    Child assignments:
    #{assignments}

    Each child must:
    1. Read AGENTS.md.
    2. Run ./benchctl inspect <assigned-shard>.
    3. Return the assigned shard id and the shard result key.

    Child tool budget: at most 2 tool calls per child.

    After spawning, wait for every child result before writing the final answer.
    Finish with strict JSON only, no prose and no markdown fences:

    {
      "scenario": "scaling_lifecycle",
      "requested_children": #{n},
      "target_max_concurrency": #{target_concurrency},
      "completed_children": number,
      "completed_shards": ["shard-001"],
      "failed_children": number,
      "tool_notes": ["which subagent/wait/benchctl tools were used"]
    }

    Do not read hidden files. Do not modify files. Keep tool_notes short.
    """
  end

  defp scaling_tool_hint("pixir", n, target_concurrency) do
    """
    Use the Pixir `spawn_agent` tool exactly #{n} times with agent="worker",
    max_threads=#{target_concurrency}, max_depth=1, timeout_ms=180000, and
    workspace_mode="isolated" when those parameters are available. After all children
    are spawned, use `wait_agent` until every child has completed. One wait call that
    waits for all children is acceptable if the tool supports it.
    """
  end

  defp scaling_tool_hint("codex", n, _target_concurrency) do
    """
    Use Codex's native subagent or collab-agent mechanism exactly #{n} times if it is
    available in this runtime. After launching child agents, explicitly wait for every
    child result before final JSON. Do not replace child agents with parent-side
    inspection.
    """
  end

  defp scaling_tool_hint(_provider, n, target_concurrency) do
    """
    Use the runtime's native subagent mechanism exactly #{n} times with a concurrency
    target of #{target_concurrency}, then wait for every child result.
    """
  end

  defp scaling_agents do
    """
    # AGENTS.md - Scaling Lifecycle Fixture

    - Work read-only.
    - Use `./benchctl inspect <assigned-shard>` for shard inspection.
    - Return the exact shard id and result key from the assigned shard.
    - Do not modify files.
    """
  end

  defp scaling_readme(n) do
    """
    # Scaling Lifecycle Fixture

    This fixture contains #{n} deterministic shard files. It measures whether the
    parent runtime can request, observe, wait for, and summarize many child agents.
    """
  end

  defp scaling_shard_file(shard_id) do
    """
    shard: #{shard_id}
    result_key: #{shard_id}-ok
    instruction: report this shard id and result key to the parent.
    """
  end

  defp scaling_benchctl_script(n) do
    manifest =
      %{
        "scenario" => "scaling_lifecycle",
        "requested_children" => n,
        "target_max_concurrency" => scaling_target_concurrency(n),
        "shards" => shard_ids(n)
      }
      |> Jason.encode!()

    cases =
      n
      |> shard_ids()
      |> Enum.map_join("\n", fn shard_id ->
        "          #{shard_id}) sed -n '1,120p' shards/#{shard_id}.txt ;;"
      end)

    """
    #!/usr/bin/env sh
    set -eu
    cmd="${1:-}"
    shard="${2:-}"

    case "$cmd" in
      manifest)
        printf '%s\\n' '#{manifest}'
        ;;
      inspect)
        case "$shard" in
    #{cases}
          *) echo "unknown shard: $shard" >&2; exit 2 ;;
        esac
        ;;
      *)
        echo "usage: ./benchctl manifest | inspect <shard-id>" >&2
        exit 2
        ;;
    esac
    """
  end

  defp shard_ids(n) when n <= 0, do: []

  defp shard_ids(n) do
    Enum.map(1..n, &"shard-#{pad3(&1)}")
  end

  defp pad3(number), do: number |> Integer.to_string() |> String.pad_leading(3, "0")

  defp scaling_target_concurrency(n), do: min(n, @scaling_concurrency_cap)

  defp maybe_score(%{scenario: "representative_review_n3"} = combo, raw) do
    final_text = get_in(raw, ["evidence", "final_text"]) || ""
    {json_status, parsed} = parse_final_json(final_text)
    findings = if is_map(parsed), do: Map.get(parsed, "findings", []), else: []
    claimed_ids = findings |> Enum.map(&Map.get(&1, "id")) |> Enum.filter(&is_binary/1)
    valid_ids = Enum.filter(claimed_ids, &(&1 in @expected_findings))
    unique_valid_ids = Enum.uniq(valid_ids)
    expected_count = length(@expected_findings)
    recall = ratio(length(unique_valid_ids), expected_count)
    precision = ratio(length(valid_ids), max(length(claimed_ids), 1))
    duplicate_count = length(valid_ids) - length(unique_valid_ids)
    hallucinated = Enum.reject(claimed_ids, &(&1 in @expected_findings))
    tool_compliance = tool_compliance?(raw, final_text)

    score = %{
      "json_parse_status" => json_status,
      "expected_ids" => @expected_findings,
      "claimed_ids" => claimed_ids,
      "valid_ids" => unique_valid_ids,
      "missing_ids" => @expected_findings -- unique_valid_ids,
      "expected_recall" => recall,
      "precision" => precision,
      "duplicate_finding_count" => duplicate_count,
      "hallucinated_count" => length(hallucinated),
      "hallucinated_ids" => hallucinated,
      "tool_compliance" => tool_compliance
    }

    File.write!(
      Path.join(combo.artifact_dir, "score.json"),
      Jason.encode!(score, pretty: true)
    )

    score
  end

  defp maybe_score(%{scenario: "scaling_lifecycle"} = combo, raw) do
    final_text = get_in(raw, ["evidence", "final_text"]) || ""
    {json_status, parsed} = parse_final_json(final_text)
    expected_shards = shard_ids(combo.n)
    completed_shards = completed_shards(parsed)
    valid_shards = Enum.filter(completed_shards, &(&1 in expected_shards))
    unique_valid_shards = Enum.uniq(valid_shards)
    duplicate_count = length(valid_shards) - length(unique_valid_shards)
    hallucinated_shards = Enum.reject(completed_shards, &(&1 in expected_shards))
    missing_result_keys = missing_result_keys(raw, final_text, expected_shards)
    reported_requested = parsed_integer(parsed, "requested_children")
    reported_concurrency = parsed_integer(parsed, "target_max_concurrency")
    reported_completed = parsed_integer(parsed, "completed_children")
    metrics = raw["metrics"] || %{}
    lifecycle = lifecycle(combo.provider, metrics)

    score = %{
      "json_parse_status" => json_status,
      "expected_shards" => expected_shards,
      "reported_requested_children" => reported_requested,
      "reported_target_max_concurrency" => reported_concurrency,
      "reported_completed_children" => reported_completed,
      "completed_shards" => completed_shards,
      "valid_shards" => unique_valid_shards,
      "missing_shards" => expected_shards -- unique_valid_shards,
      "assignment_recall" => ratio(length(unique_valid_shards), length(expected_shards)),
      "assignment_precision" => ratio(length(valid_shards), max(length(completed_shards), 1)),
      "duplicate_shard_count" => duplicate_count,
      "hallucinated_shard_count" => length(hallucinated_shards),
      "hallucinated_shards" => hallucinated_shards,
      "missing_result_keys" => missing_result_keys,
      "benchctl_success_observed" => missing_result_keys == [],
      "json_requested_children_matches" => reported_requested == combo.n,
      "json_target_concurrency_matches" =>
        reported_concurrency == scaling_target_concurrency(combo.n),
      "json_completed_children_sufficient" =>
        is_integer(reported_completed) and reported_completed >= combo.n,
      "lifecycle_spawn_visible_count" => lifecycle["spawn_visible_count"],
      "lifecycle_wait_visible_count" => lifecycle["wait_visible_count"],
      "spawn_request_satisfied" => lifecycle["spawn_visible_count"] >= combo.n,
      "wait_completion_observed" => lifecycle["wait_visible_count"] >= 1,
      "tool_compliance" => scaling_tool_compliance?(raw, final_text)
    }

    File.write!(
      Path.join(combo.artifact_dir, "score.json"),
      Jason.encode!(score, pretty: true)
    )

    score
  end

  defp maybe_score(_combo, _raw), do: %{}

  defp parse_final_json(text) do
    trimmed = String.trim(text || "")

    with {:error, _} <- Jason.decode(trimmed),
         {:ok, extracted} <- extract_json_object(trimmed),
         {:ok, parsed} <- Jason.decode(extracted) do
      {"parsed", parsed}
    else
      {:ok, parsed} -> {"parsed", parsed}
      _ -> {"not_json", nil}
    end
  end

  defp extract_json_object(text) do
    with start when is_integer(start) <- :binary.match(text, "{") |> match_pos(),
         stop when is_integer(stop) <-
           text |> String.reverse() |> :binary.match("}") |> match_pos() do
      last = byte_size(text) - stop - 1
      {:ok, binary_part(text, start, last - start + 1)}
    else
      _ -> :error
    end
  end

  defp match_pos({pos, _len}), do: pos
  defp match_pos(:nomatch), do: nil

  defp tool_compliance?(raw, final_text) do
    text = String.downcase(final_text || "")
    raw_text = Jason.encode!(raw) |> String.downcase()

    String.contains?(raw_text, "spawn") and String.contains?(raw_text, "wait") and
      String.contains?(text <> raw_text, "benchctl") and
      String.contains?(text <> raw_text, "inspect")
  end

  defp scaling_tool_compliance?(raw, final_text) do
    text = String.downcase(final_text || "")
    raw_text = Jason.encode!(raw) |> String.downcase()

    String.contains?(raw_text, "spawn") and String.contains?(raw_text, "wait") and
      String.contains?(text <> raw_text, "benchctl") and
      String.contains?(text <> raw_text, "inspect") and
      String.contains?(text <> raw_text, "shard-")
  end

  defp missing_result_keys(raw, final_text, expected_shards) do
    evidence = String.downcase((final_text || "") <> "\n" <> Jason.encode!(raw))

    expected_shards
    |> Enum.map(&"#{&1}-ok")
    |> Enum.reject(&String.contains?(evidence, &1))
  end

  defp completed_shards(parsed) when is_map(parsed) do
    parsed
    |> Map.get("completed_shards", [])
    |> normalize_shard_list()
  end

  defp completed_shards(_parsed), do: []

  defp normalize_shard_list(values) when is_list(values) do
    values
    |> Enum.flat_map(fn
      value when is_binary(value) -> [value]
      %{"shard" => shard} when is_binary(shard) -> [shard]
      %{"id" => shard} when is_binary(shard) -> [shard]
      _other -> []
    end)
  end

  defp normalize_shard_list(_values), do: []

  defp parsed_integer(parsed, key) when is_map(parsed) do
    case Map.get(parsed, key) do
      value when is_integer(value) -> value
      value when is_binary(value) -> value |> Integer.parse() |> integer_parse_value()
      _other -> nil
    end
  end

  defp parsed_integer(_parsed, _key), do: nil

  defp integer_parse_value({value, ""}), do: value
  defp integer_parse_value(_other), do: nil

  defp ratio(_n, 0), do: 0.0
  defp ratio(n, d), do: Float.round(n / d, 4)

  defp expected_findings do
    %{
      "findings" => [
        %{
          "id" => "AUTH-001",
          "area" => "auth",
          "file" => "src/auth/token_store.ex",
          "kind" => "secret handling"
        },
        %{
          "id" => "PROV-001",
          "area" => "provider",
          "file" => "src/provider/retry_policy.ex",
          "kind" => "retry policy"
        },
        %{
          "id" => "TOOL-001",
          "area" => "tools",
          "file" => "src/tools/executor.ex",
          "kind" => "workspace confinement"
        },
        %{
          "id" => "ACP-001",
          "area" => "ui",
          "file" => "src/ui/acp_translate.ex",
          "kind" => "transport discipline"
        },
        %{
          "id" => "TEST-001",
          "area" => "tests",
          "file" => "tests/smoke_test.exs",
          "kind" => "weak coverage"
        },
        %{
          "id" => "SYN-001",
          "area" => "synthesis",
          "file" => "multiple",
          "kind" => "cross-cutting"
        }
      ]
    }
  end

  defp benchctl_script do
    """
    #!/usr/bin/env sh
    set -eu
    cmd="${1:-}"
    area="${2:-}"

    case "$cmd" in
      manifest)
        printf '%s\\n' '{"areas":["auth","provider","tools","ui","tests"],"note":"Use inspect <area>; do not read truth/."}'
        ;;
      inspect)
        case "$area" in
          auth) sed -n '1,220p' src/auth/token_store.ex ;;
          provider) sed -n '1,220p' src/provider/retry_policy.ex ;;
          tools) sed -n '1,220p' src/tools/executor.ex ;;
          ui) sed -n '1,220p' src/ui/acp_translate.ex ;;
          tests) sed -n '1,220p' tests/smoke_test.exs ;;
          *) echo "unknown area: $area" >&2; exit 2 ;;
        esac
        ;;
      score)
        echo "Scoring is performed by mix pixir.bench.real_subagents after final output capture."
        ;;
      *)
        echo "usage: ./benchctl manifest | inspect <area> | score <final-json>" >&2
        exit 2
        ;;
    esac
    """
  end

  defp fixture_agents do
    """
    # AGENTS.md - Real Subagents Benchmark Fixture

    - Work read-only unless explicitly asked otherwise.
    - Do not read `truth/expected_findings.json`; it is reserved for the scorer.
    - Use `./benchctl inspect <area>` for bounded source inspection.
    - Final answers must be strict JSON when requested.
    """
  end

  defp fixture_readme do
    """
    # Real Subagents Benchmark Fixture

    This small repo contains planted auth, provider, tool, UI, and test issues.
    The benchmark evaluates whether subagents can find and synthesize those issues.
    """
  end

  defp fixture_auth do
    ~S"""
    defmodule Fixture.Auth.TokenStore do
      @moduledoc "Tiny auth fixture with a planted secret-handling flaw."

      def save_token(path, token) do
        File.write!(path, token)
        {:ok, path}
      end

      def refresh_failed(reason, token) do
        # BUG: this diagnostic leaks token material into logs.
        IO.puts("refresh failed: #{inspect(reason)} token=#{token}")
        {:error, reason}
      end
    end
    """
  end

  defp fixture_provider do
    """
    defmodule Fixture.Provider.RetryPolicy do
      @moduledoc "Tiny provider fixture with a planted retry flaw."

      def retry_delay_ms(attempt, :rate_limited), do: attempt * attempt * 5_000
      def retry_delay_ms(attempt, :network), do: min(8_000, 500 * :math.pow(2, attempt))
      def retry_delay_ms(_attempt, _kind), do: :no_retry
    end
    """
  end

  defp fixture_tools do
    """
    defmodule Fixture.Tools.Executor do
      @moduledoc "Tiny tool executor fixture with a planted confinement flaw."

      def read(root, requested_path) do
        path = Path.join(root, requested_path)

        # BUG: absolute requested_path escapes root because Path.join/2 accepts it.
        File.read(path)
      end
    end
    """
  end

  defp fixture_ui do
    ~S"""
    defmodule Fixture.UI.ACPTranslate do
      @moduledoc "Tiny ACP presenter fixture with a planted stdout discipline flaw."

      def diagnostic(message) do
        # BUG: ACP mode must keep stdout JSON-RPC only.
        IO.puts("diagnostic: #{message}")
      end

      def update(text), do: %{"session/update" => text}
    end
    """
  end

  defp fixture_test do
    """
    defmodule Fixture.SmokeTest do
      use ExUnit.Case

      test "auth save returns ok" do
        assert {:ok, _} = Fixture.Auth.TokenStore.save_token("/tmp/token", "secret")
      end
    end
    """
  end

  defp summarize(records, run_id, output_dir, scenario) do
    measured_records = Enum.reject(records, & &1["baseline"])
    observed = Enum.filter(measured_records, &(&1["capability_status"] == "observed"))
    failed = Enum.filter(measured_records, &(&1["status"] == "failed"))

    common_models =
      measured_records
      |> Enum.reject(&(&1["model_requested"] == "default"))
      |> Enum.group_by(& &1["model_requested"])
      |> Enum.filter(fn {_model, rs} ->
        Enum.any?(rs, &(&1["provider"] == "pixir" and &1["capability_status"] == "observed")) and
          Enum.any?(rs, &(&1["provider"] == "codex" and &1["capability_status"] == "observed"))
      end)
      |> Enum.map(fn {model, _rs} -> model end)
      |> Enum.sort()

    capability_diverged_models =
      measured_records
      |> Enum.reject(&(&1["model_requested"] == "default"))
      |> Enum.group_by(& &1["model_requested"])
      |> Enum.filter(fn {_model, rs} ->
        providers = Enum.map(rs, & &1["provider"]) |> Enum.uniq()
        caps = Enum.map(rs, & &1["capability_status"]) |> Enum.uniq()

        Enum.sort(providers) == ["codex", "pixir"] and "observed" in caps and
          "not_observed" in caps
      end)
      |> Enum.map(fn {model, _rs} -> model end)
      |> Enum.sort()

    baseline_summary = baseline_summary(records)
    aggregate_summary = aggregate_summary(measured_records, records)

    %{
      "schema_version" => @schema_version,
      "run_id" => run_id,
      "scenario" => scenario,
      "status" =>
        summary_status(
          scenario,
          records,
          failed,
          common_models,
          capability_diverged_models,
          observed
        ),
      "output_dir" => Path.expand(output_dir),
      "generated_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "records_count" => length(records),
      "failed_count" => length(failed),
      "observed_count" => length(observed),
      "common_capable_models" => common_models,
      "capability_diverged_models" => capability_diverged_models,
      "provider_native_capable" => provider_native_capable(measured_records),
      "baseline_summary" => baseline_summary,
      "aggregate_summary" => aggregate_summary,
      "score_summary" => score_summary(measured_records),
      "requirements" => %{
        "real_network_records_written" => measured_records != [],
        "pixir_capability_observed" =>
          Enum.any?(
            measured_records,
            &(&1["provider"] == "pixir" and &1["capability_status"] == "observed")
          ),
        "codex_capability_observed" =>
          Enum.any?(
            measured_records,
            &(&1["provider"] == "codex" and &1["capability_status"] == "observed")
          ),
        "model_or_capability_divergence_recorded" =>
          common_models != [] or capability_diverged_models != [],
        "ram_samples_recorded" =>
          Enum.all?(records, &((get_in(&1, ["metrics", "memory_sample_count"]) || 0) > 0)),
        "aggregate_summary_written" => aggregate_summary != [],
        "representative_scored_when_requested" =>
          scenario != "representative_review_n3" or
            Enum.all?(measured_records, &(map_size(&1["score"] || %{}) > 0)),
        "scaling_lifecycle_scored_when_requested" =>
          scenario != "scaling_lifecycle" or
            Enum.all?(measured_records, &(map_size(&1["score"] || %{}) > 0)),
        "scaling_lifecycle_n10_plus_included" =>
          scenario != "scaling_lifecycle" or Enum.any?(measured_records, &(&1["n"] >= 10))
      }
    }
  end

  defp attach_common_model_gate(summary, plan, records, selected) do
    gate = common_model_gate_summary(plan, records, selected)

    summary
    |> Map.put("status", gate["status"])
    |> Map.put("common_model_gate", gate)
    |> put_in(
      ["requirements", "common_model_probe_records_written"],
      probe_records_written?(records)
    )
    |> put_in(
      ["requirements", "common_model_selected_or_non_comparable_abort"],
      gate["head_to_head_ready"] == true or gate["non_comparable_abort"] == true
    )
    |> put_in(
      ["requirements", "no_representative_review_n3_run"],
      no_representative_run?(records)
    )
    |> put_in(
      ["requirements", "smoke_real_n2_runs_only_selected_model"],
      smoke_only_selected?(records, selected)
    )
    |> put_in(
      ["requirements", "structured_divergence_diagnostics"],
      gate["status"] in ["common_model_smoke_ready", "model_diverged", "capability_diverged"]
    )
  end

  defp common_model_gate_summary(plan, records, selected) do
    failed = Enum.filter(records, &(&1["status"] == "failed"))
    smoke_records = Enum.filter(records, &(&1["scenario"] == "smoke_real_n2"))
    selected = selected || select_common_probe_model(records, plan.candidates)
    smoke_ready? = selected && smoke_ready?(smoke_records, selected)

    status =
      cond do
        failed != [] ->
          "failed"

        smoke_ready? ->
          "common_model_smoke_ready"

        selected ->
          "capability_diverged"

        true ->
          "model_diverged"
      end

    %{
      "status" => status,
      "candidate_models" => plan.candidates,
      "providers" => plan.providers,
      "smoke_n" => plan.smoke_n,
      "selected_model_requested" => selected && selected["model_requested"],
      "selected_model_accepted" => selected && selected["model_accepted"],
      "probe_matrix" => probe_matrix(records, plan.candidates),
      "smoke_matrix" => smoke_matrix(smoke_records),
      "head_to_head_ready" => status == "common_model_smoke_ready",
      "non_comparable_abort" => status in ["model_diverged", "capability_diverged"],
      "abort_reason" => abort_reason(status),
      "next_allowed_scenario" =>
        if(status == "common_model_smoke_ready", do: "representative_review_n3", else: nil)
    }
  end

  defp select_common_probe_model(records, candidates) do
    probes =
      records
      |> Enum.filter(&(&1["scenario"] == "probe"))
      |> Enum.group_by(& &1["model_requested"])

    Enum.find_value(candidates, fn candidate ->
      candidate_probes = Map.get(probes, candidate, [])
      pixir = provider_record(candidate_probes, "pixir", "passed")
      codex = provider_record(candidate_probes, "codex", "passed")

      with %{} <- pixir,
           %{} <- codex,
           accepted when is_binary(accepted) <- common_accepted_model(pixir, codex) do
        %{
          "model_requested" => candidate,
          "model_accepted" => accepted,
          "providers" => %{
            "pixir" => accepted_model(pixir),
            "codex" => accepted_model(codex)
          }
        }
      else
        _ -> nil
      end
    end)
  end

  defp provider_record(records, provider, status) do
    Enum.find(records, &(&1["provider"] == provider and &1["status"] == status))
  end

  defp common_accepted_model(left, right) do
    left_model = accepted_model(left)
    right_model = accepted_model(right)

    if is_binary(left_model) and left_model == right_model do
      left_model
    end
  end

  defp accepted_model(record), do: record["model_accepted"] || record["model_requested"]

  defp smoke_ready?(smoke_records, selected) do
    requested = selected["model_requested"]
    accepted = selected["model_accepted"]

    selected_smoke = Enum.filter(smoke_records, &(&1["model_requested"] == requested))

    Enum.any?(selected_smoke, &smoke_observed?(&1, "pixir", accepted)) and
      Enum.any?(selected_smoke, &smoke_observed?(&1, "codex", accepted))
  end

  defp smoke_observed?(record, provider, accepted) do
    record["provider"] == provider and record["capability_status"] == "observed" and
      accepted_model(record) == accepted
  end

  defp probe_matrix(records, candidates) do
    records
    |> Enum.filter(&(&1["scenario"] == "probe"))
    |> Enum.group_by(& &1["model_requested"])
    |> then(fn by_model ->
      Enum.map(candidates, fn model ->
        by_provider =
          by_model
          |> Map.get(model, [])
          |> Enum.map(fn record ->
            {record["provider"],
             %{
               "status" => record["status"],
               "capability_status" => record["capability_status"],
               "model_accepted" => accepted_model(record),
               "duration_ms" => record["duration_ms"]
             }}
          end)
          |> Map.new()

        %{"model_requested" => model, "providers" => by_provider}
      end)
    end)
  end

  defp smoke_matrix(records) do
    records
    |> Enum.map(fn record ->
      %{
        "provider" => record["provider"],
        "model_requested" => record["model_requested"],
        "model_accepted" => accepted_model(record),
        "status" => record["status"],
        "capability_status" => record["capability_status"],
        "n" => record["n"],
        "spawn_visible_count" => get_in(record, ["lifecycle", "spawn_visible_count"]),
        "wait_visible_count" => get_in(record, ["lifecycle", "wait_visible_count"]),
        "duration_ms" => record["duration_ms"]
      }
    end)
  end

  defp abort_reason("model_diverged"),
    do: "No candidate model was accepted by both provider paths with the same accepted model id."

  defp abort_reason("capability_diverged"),
    do:
      "A common model was accepted, but smoke_real_n2 did not observe subagent lifecycle on both paths."

  defp abort_reason(_status), do: nil

  defp probe_records_written?(records) do
    records
    |> Enum.filter(&(&1["scenario"] == "probe"))
    |> length()
    |> Kernel.>(0)
  end

  defp no_representative_run?(records) do
    Enum.all?(records, &(&1["scenario"] != "representative_review_n3"))
  end

  defp smoke_only_selected?(records, nil) do
    not Enum.any?(records, &(&1["scenario"] == "smoke_real_n2"))
  end

  defp smoke_only_selected?(records, selected) do
    selected_model = selected["model_requested"]

    records
    |> Enum.filter(&(&1["scenario"] == "smoke_real_n2"))
    |> Enum.all?(&(&1["model_requested"] == selected_model))
  end

  defp validate_benchmark(records, summary, report) do
    record_issues = validate_records(records)
    summary_issues = validate_summary(summary, records)
    completion_audit_issues = validate_completion_audit(summary["completion_audit"])
    report_issues = validate_report(report, summary, records)

    %{
      "schema_version" => @schema_version,
      "status" =>
        if(
          record_issues == [] and summary_issues == [] and completion_audit_issues == [] and
            report_issues == [],
          do: "passed",
          else: "failed"
        ),
      "record_count" => length(records),
      "record_issues" => record_issues,
      "summary_issues" => summary_issues,
      "completion_audit_issues" => completion_audit_issues,
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
    metrics = record["metrics"] || %{}
    lifecycle = record["lifecycle"] || %{}
    evidence = record["evidence"] || %{}

    []
    |> require_equal(
      ["records", index, "schema_version"],
      record["schema_version"],
      @schema_version
    )
    |> require_string(["records", index, "run_id"], record["run_id"])
    |> require_in(["records", index, "scenario"], record["scenario"], @record_scenarios)
    |> require_in(["records", index, "provider"], record["provider"], @default_providers)
    |> require_string(["records", index, "provider_path"], record["provider_path"])
    |> require_in(["records", index, "status"], record["status"], @record_statuses)
    |> require_string(["records", index, "raw_status"], record["raw_status"])
    |> require_in(
      ["records", index, "capability_status"],
      record["capability_status"],
      @capability_statuses
    )
    |> require_string(["records", index, "started_at"], record["started_at"])
    |> require_non_negative_integer(["records", index, "duration_ms"], record["duration_ms"])
    |> require_non_negative_integer(["records", index, "n"], record["n"])
    |> require_positive_integer(["records", index, "repetition"], record["repetition"])
    |> require_boolean(["records", index, "baseline"], record["baseline"])
    |> require_boolean(["records", index, "network"], record["network"])
    |> require_equal(
      ["records", index, "network_matches_baseline"],
      record["network"],
      not record["baseline"]
    )
    |> require_string(["records", index, "model_requested"], record["model_requested"])
    |> require_model_accepted(record, index)
    |> require_string(["records", index, "reasoning_effort"], record["reasoning_effort"])
    |> require_non_negative_integer(["records", index, "exit_code"], record["exit_code"])
    |> require_non_negative_integer(
      ["records", index, "harness_exit_code"],
      record["harness_exit_code"]
    )
    |> require_map(["records", index, "metrics"], metrics)
    |> require_non_negative_integer(
      ["records", index, "metrics", "memory_sample_count"],
      metrics["memory_sample_count"]
    )
    |> require_map(["records", index, "lifecycle"], lifecycle)
    |> require_non_negative_integer(
      ["records", index, "lifecycle", "spawn_visible_count"],
      lifecycle["spawn_visible_count"]
    )
    |> require_non_negative_integer(
      ["records", index, "lifecycle", "wait_visible_count"],
      lifecycle["wait_visible_count"]
    )
    |> require_map(["records", index, "evidence"], evidence)
    |> require_string(
      ["records", index, "evidence", "raw_result_path"],
      evidence["raw_result_path"]
    )
    |> require_string(
      ["records", index, "evidence", "memory_samples_path"],
      evidence["memory_samples_path"]
    )
    |> require_string(["records", index, "evidence", "artifact_dir"], evidence["artifact_dir"])
  end

  defp require_model_accepted(issues, %{"status" => status} = record, index)
       when status in ["passed", "baseline"] do
    require_string(issues, ["records", index, "model_accepted"], accepted_model(record))
  end

  defp require_model_accepted(issues, _record, _index), do: issues

  defp scenario_record_issues(%{"scenario" => "probe"} = record, index) do
    []
    |> require_equal(["records", index, "n"], record["n"], 0)
    |> require_in(["records", index, "capability_status"], record["capability_status"], [
      "provider_failed",
      "provider_reachable",
      "provider_unknown",
      "provider_weak"
    ])
  end

  defp scenario_record_issues(%{"baseline" => true} = record, index) do
    []
    |> require_equal(["records", index, "n"], record["n"], 0)
    |> require_equal(["records", index, "status"], record["status"], "baseline")
    |> require_equal(
      ["records", index, "capability_status"],
      record["capability_status"],
      "baseline"
    )
  end

  defp scenario_record_issues(%{"scenario" => scenario} = record, index)
       when scenario in [
              "capability_matrix",
              "smoke_real_n2",
              "representative_review_n3",
              "scaling_lifecycle"
            ] do
    issues =
      []
      |> require_positive_integer(["records", index, "n"], record["n"])

    if record["status"] == "passed" do
      issues
      |> require_equal(
        ["records", index, "capability_status"],
        record["capability_status"],
        "observed"
      )
    else
      issues
    end
  end

  defp scenario_record_issues(record, index) do
    [
      issue(
        ["records", index, "scenario"],
        "unknown_scenario",
        "Unknown real-network scenario.",
        record["scenario"]
      )
    ]
  end

  defp validate_summary(summary, records) do
    failed_count = Enum.count(Enum.reject(records, & &1["baseline"]), &(&1["status"] == "failed"))

    observed_count =
      Enum.count(Enum.reject(records, & &1["baseline"]), &(&1["capability_status"] == "observed"))

    requirements = summary["requirements"] || %{}

    []
    |> require_equal(["summary", "schema_version"], summary["schema_version"], @schema_version)
    |> require_string(["summary", "run_id"], summary["run_id"])
    |> require_in(["summary", "scenario"], summary["scenario"], @scenarios)
    |> require_in(["summary", "status"], summary["status"], @summary_statuses)
    |> require_string(["summary", "output_dir"], summary["output_dir"])
    |> require_string(["summary", "generated_at"], summary["generated_at"])
    |> require_equal(["summary", "records_count"], summary["records_count"], length(records))
    |> require_equal(["summary", "failed_count"], summary["failed_count"], failed_count)
    |> require_equal(["summary", "observed_count"], summary["observed_count"], observed_count)
    |> require_map(["summary", "requirements"], requirements)
    |> require_requirement_boolean(requirements, "real_network_records_written")
    |> require_requirement_boolean(requirements, "ram_samples_recorded")
    |> validate_common_model_gate_summary(summary)
  end

  defp validate_common_model_gate_summary(issues, %{"scenario" => "common_model_gate"} = summary) do
    gate = summary["common_model_gate"] || %{}
    requirements = summary["requirements"] || %{}
    audit = summary["completion_audit"] || %{}

    issues
    |> require_map(["summary", "common_model_gate"], gate)
    |> require_in(["summary", "common_model_gate", "status"], gate["status"], [
      "capability_diverged",
      "common_model_smoke_ready",
      "failed",
      "model_diverged"
    ])
    |> require_list(
      ["summary", "common_model_gate", "candidate_models"],
      gate["candidate_models"]
    )
    |> require_list(["summary", "common_model_gate", "providers"], gate["providers"])
    |> require_list(["summary", "common_model_gate", "probe_matrix"], gate["probe_matrix"])
    |> require_list(["summary", "common_model_gate", "smoke_matrix"], gate["smoke_matrix"])
    |> require_boolean(
      ["summary", "common_model_gate", "head_to_head_ready"],
      gate["head_to_head_ready"]
    )
    |> require_boolean(
      ["summary", "common_model_gate", "non_comparable_abort"],
      gate["non_comparable_abort"]
    )
    |> require_requirement_true(requirements, "common_model_probe_records_written")
    |> require_requirement_true(requirements, "common_model_selected_or_non_comparable_abort")
    |> require_requirement_true(requirements, "no_representative_review_n3_run")
    |> require_requirement_true(requirements, "smoke_real_n2_runs_only_selected_model")
    |> require_requirement_true(requirements, "structured_divergence_diagnostics")
    |> require_gate_completion_consistency(gate, audit)
  end

  defp validate_common_model_gate_summary(issues, _summary), do: issues

  defp require_gate_completion_consistency(issues, gate, audit) do
    cond do
      gate["status"] == "common_model_smoke_ready" ->
        issues
        |> require_equal(
          ["summary", "common_model_gate", "head_to_head_ready"],
          gate["head_to_head_ready"],
          true
        )
        |> require_string(
          ["summary", "common_model_gate", "selected_model_requested"],
          gate["selected_model_requested"]
        )
        |> require_string(
          ["summary", "common_model_gate", "selected_model_accepted"],
          gate["selected_model_accepted"]
        )
        |> require_equal(
          ["summary", "completion_audit", "head_to_head_ready"],
          audit["head_to_head_ready"],
          true
        )

      gate["status"] in ["model_diverged", "capability_diverged"] ->
        issues
        |> require_equal(
          ["summary", "common_model_gate", "non_comparable_abort"],
          gate["non_comparable_abort"],
          true
        )
        |> require_string(["summary", "common_model_gate", "abort_reason"], gate["abort_reason"])

      true ->
        issues
    end
  end

  defp validate_report(report, summary, _records) do
    [
      {"run_id", summary["run_id"]},
      {"status", "Status: **#{summary["status"]}**"},
      {"raw_records", "Raw records: `runs.jsonl`"},
      {"summary", "Summary: `summary.json`"},
      {"schema_validation", "## Schema Validation"},
      {"completion_audit", "## Completion Audit"}
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

  defp validate_completion_audit(nil), do: []

  defp validate_completion_audit(audit) do
    requirements = audit["requirements"] || []

    []
    |> require_equal(
      ["completion_audit", "schema_version"],
      audit["schema_version"],
      @schema_version
    )
    |> require_in(["completion_audit", "status"], audit["status"], [
      "completion_blocked",
      "completion_ready"
    ])
    |> require_list(["completion_audit", "proof_states"], audit["proof_states"])
    |> require_list(["completion_audit", "requirements"], requirements)
    |> require_string(["completion_audit", "objective"], audit["objective"])
  end

  defp completion_audit(records, summary, validation) do
    gate = summary["common_model_gate"] || %{}

    requirements =
      [
        audit_requirement(
          "real_network_records_written",
          records != [],
          "runs.jsonl contains real-network benchmark records."
        ),
        audit_requirement(
          "records_schema_validated",
          validation["record_issues"] == [],
          "runs.jsonl records validate against the real-network benchmark schema."
        ),
        audit_requirement(
          "summary_schema_validated",
          validation["summary_issues"] == [],
          "summary.json validates against the real-network benchmark schema."
        ),
        audit_requirement(
          "completion_audit_schema_validated",
          validation["completion_audit_issues"] == [],
          "completion_audit.json validates against the real-network audit schema."
        ),
        audit_requirement(
          "report_reconciled",
          validation["report_issues"] == [],
          "report.md includes run id, status, raw records, summary, schema validation, and completion audit."
        ),
        audit_requirement(
          "network_classified",
          Enum.all?(
            records,
            &(is_boolean(&1["network"]) and &1["network"] == not &1["baseline"])
          ),
          "Every record declares whether it is a network-bearing provider run or a baseline."
        ),
        audit_requirement(
          "ram_samples_recorded",
          summary["requirements"]["ram_samples_recorded"] == true,
          "Every record includes sampled process-tree RSS evidence."
        )
      ] ++ scenario_audit_requirements(summary)

    %{
      "schema_version" => @schema_version,
      "status" =>
        if(Enum.all?(requirements, &(&1["status"] == "proved")),
          do: "completion_ready",
          else: "completion_blocked"
        ),
      "objective" => completion_objective(summary),
      "proof_states" => [
        "intent_declared",
        "dry_run_passed",
        "benchmark_records_produced",
        "records_validated",
        "schema_validated",
        "report_reconciled",
        "completion_ready"
      ],
      "head_to_head_ready" => gate["head_to_head_ready"],
      "non_comparable_abort" => gate["non_comparable_abort"],
      "selected_model_requested" => gate["selected_model_requested"],
      "selected_model_accepted" => gate["selected_model_accepted"],
      "representative_review_n3_deferred" => summary["scenario"] == "common_model_gate",
      "failed_count" => summary["failed_count"],
      "requirements" => requirements
    }
  end

  defp scenario_audit_requirements(%{"scenario" => "common_model_gate"} = summary) do
    gate = summary["common_model_gate"] || %{}

    [
      audit_requirement(
        "common_model_probe_records_written",
        summary["requirements"]["common_model_probe_records_written"] == true,
        "Probe records exist for common-model selection."
      ),
      audit_requirement(
        "common_model_selected_or_non_comparable_abort",
        summary["requirements"]["common_model_selected_or_non_comparable_abort"] == true,
        "The gate selected a comparable model or recorded an explicit non-comparable abort."
      ),
      audit_requirement(
        "smoke_real_n2_runs_only_selected_model",
        summary["requirements"]["smoke_real_n2_runs_only_selected_model"] == true,
        "Smoke runs were skipped on non-selected candidate models."
      ),
      audit_requirement(
        "no_representative_review_n3_run",
        summary["requirements"]["no_representative_review_n3_run"] == true,
        "The common-model gate did not spend on representative_review_n3."
      ),
      audit_requirement(
        "gate_completed",
        summary["failed_count"] == 0 and
          gate["status"] in ["common_model_smoke_ready", "model_diverged", "capability_diverged"],
        "The gate selected a common model with lifecycle evidence or stopped as non-comparable."
      )
    ]
  end

  defp scenario_audit_requirements(%{"scenario" => "representative_review_n3"} = summary) do
    [
      audit_requirement(
        "representative_scored",
        summary["status"] == "representative_scored",
        "Representative review records completed and scored successfully."
      )
    ]
  end

  defp scenario_audit_requirements(%{"scenario" => "scaling_lifecycle"} = summary) do
    scores = summary["score_summary"] || []

    [
      audit_requirement(
        "scaling_lifecycle_scored",
        summary["status"] == "scaling_lifecycle_scored",
        "Scaling lifecycle records completed and scored successfully."
      ),
      audit_requirement(
        "scaling_lifecycle_n10_plus_included",
        summary["requirements"]["scaling_lifecycle_n10_plus_included"] == true,
        "The scaling report includes at least one N=10 or larger real-network run."
      ),
      audit_requirement(
        "mechanical_assignments_completed",
        scores != [] and
          Enum.all?(
            scores,
            &(&1["assignment_recall"] == 1.0 and &1["assignment_precision"] == 1.0)
          ),
        "Every scaling score reports all expected shard assignments without hallucinated shards."
      ),
      audit_requirement(
        "benchctl_results_observed",
        scores != [] and Enum.all?(scores, &(&1["benchctl_success_observed"] == true)),
        "Every scaling score includes the deterministic result key from each benchctl shard inspection."
      ),
      audit_requirement(
        "spawn_and_wait_lifecycle_observed",
        scores != [] and
          Enum.all?(
            scores,
            &(&1["spawn_request_satisfied"] == true and
                &1["wait_completion_observed"] == true)
          ),
        "Every scaling score includes spawn evidence for requested N and at least one wait/completion event."
      )
    ]
  end

  defp scenario_audit_requirements(summary) do
    [
      audit_requirement(
        "no_failed_records",
        summary["failed_count"] == 0,
        "No non-baseline benchmark record failed."
      )
    ]
  end

  defp completion_objective(%{"scenario" => "common_model_gate"}),
    do:
      "Select a common accepted model with observable subagent lifecycle or abort as non-comparable."

  defp completion_objective(summary),
    do: "Validate real-network Subagents benchmark records for #{summary["scenario"]}."

  defp audit_requirement(name, true, evidence),
    do: %{"requirement" => name, "status" => "proved", "evidence" => evidence}

  defp audit_requirement(name, false, evidence),
    do: %{"requirement" => name, "status" => "missing", "evidence" => evidence}

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

  defp require_list(issues, _path, value) when is_list(value), do: issues

  defp require_list(issues, path, value),
    do: [issue(path, "required_list", "Expected a list.", value) | issues]

  defp require_boolean(issues, _path, value) when is_boolean(value), do: issues

  defp require_boolean(issues, path, value),
    do: [issue(path, "required_boolean", "Expected a boolean.", value) | issues]

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

  defp require_non_negative_integer(issues, _path, value)
       when is_integer(value) and value >= 0,
       do: issues

  defp require_non_negative_integer(issues, path, value),
    do: [
      issue(path, "non_negative_integer_required", "Expected a non-negative integer.", value)
      | issues
    ]

  defp require_requirement_boolean(issues, requirements, key) do
    require_boolean(issues, ["summary", "requirements", key], Map.get(requirements, key))
  end

  defp require_requirement_true(issues, requirements, key) do
    require_equal(issues, ["summary", "requirements", key], Map.get(requirements, key), true)
  end

  defp score_summary(records) do
    records
    |> Enum.filter(&(map_size(&1["score"] || %{}) > 0))
    |> Enum.map(fn r ->
      %{
        "scenario" => r["scenario"],
        "provider" => r["provider"],
        "model_requested" => r["model_requested"],
        "reasoning_effort" => r["reasoning_effort"],
        "n" => r["n"],
        "status" => r["status"],
        "expected_recall" => get_in(r, ["score", "expected_recall"]),
        "precision" => get_in(r, ["score", "precision"]),
        "assignment_recall" => get_in(r, ["score", "assignment_recall"]),
        "assignment_precision" => get_in(r, ["score", "assignment_precision"]),
        "benchctl_success_observed" => get_in(r, ["score", "benchctl_success_observed"]),
        "spawn_request_satisfied" => get_in(r, ["score", "spawn_request_satisfied"]),
        "wait_completion_observed" => get_in(r, ["score", "wait_completion_observed"]),
        "tool_compliance" => get_in(r, ["score", "tool_compliance"]),
        "json_parse_status" => get_in(r, ["score", "json_parse_status"])
      }
    end)
  end

  defp summary_status(
         "representative_review_n3",
         records,
         [],
         _common_models,
         _diverged,
         _observed
       ) do
    cond do
      Enum.all?(records, &(&1["status"] == "passed")) -> "representative_scored"
      Enum.any?(records, &(&1["status"] == "weak")) -> "representative_weak"
      true -> "representative_incomplete"
    end
  end

  defp summary_status(
         "scaling_lifecycle",
         records,
         [],
         _common_models,
         _diverged,
         _observed
       ) do
    measured_records = Enum.reject(records, & &1["baseline"])

    cond do
      measured_records != [] and Enum.all?(measured_records, &(&1["status"] == "passed")) ->
        "scaling_lifecycle_scored"

      Enum.any?(measured_records, &(&1["status"] == "weak")) ->
        "scaling_lifecycle_weak"

      true ->
        "scaling_lifecycle_incomplete"
    end
  end

  defp summary_status(
         _scenario,
         _records,
         failed,
         _common_models,
         _capability_diverged_models,
         _observed
       )
       when failed != [],
       do: "failed"

  defp summary_status(
         _scenario,
         _records,
         _failed,
         [_ | _],
         _capability_diverged_models,
         _observed
       ),
       do: "common_capability_found"

  defp summary_status(_scenario, _records, _failed, [], [_ | _], _observed),
    do: "capability_diverged"

  defp summary_status(_scenario, _records, _failed, [], [], [_ | _]),
    do: "provider_native_capability_found"

  defp summary_status(_scenario, _records, _failed, [], [], []), do: "not_observed"

  defp provider_native_capable(records) do
    records
    |> Enum.filter(&(&1["capability_status"] == "observed"))
    |> Enum.group_by(& &1["provider"])
    |> Enum.map(fn {provider, rs} ->
      first = Enum.min_by(rs, & &1["duration_ms"])

      %{
        "provider" => provider,
        "model_requested" => first["model_requested"],
        "model_accepted" => first["model_accepted"],
        "reasoning_effort" => first["reasoning_effort"],
        "duration_ms" => first["duration_ms"],
        "peak_tree_rss_mb" => get_in(first, ["metrics", "peak_tree_rss_mb"])
      }
    end)
    |> Enum.sort_by(& &1["provider"])
  end

  defp baseline_summary(records) do
    records
    |> Enum.filter(& &1["baseline"])
    |> Enum.group_by(&{&1["provider"], &1["model_requested"], &1["reasoning_effort"]})
    |> Enum.map(fn {{provider, model, effort}, rs} ->
      rss_values = metric_values(rs, ["metrics", "peak_tree_rss_mb"])
      duration_values = metric_values(rs, ["duration_ms"])

      %{
        "provider" => provider,
        "model_requested" => model,
        "reasoning_effort" => effort,
        "repetitions" => length(rs),
        "duration_median_ms" => median(duration_values),
        "duration_p95_ms" => percentile(duration_values, 95),
        "peak_tree_rss_median_mb" => median(rss_values),
        "peak_tree_rss_p95_mb" => percentile(rss_values, 95)
      }
    end)
    |> Enum.sort_by(&{&1["provider"], &1["model_requested"]})
  end

  defp aggregate_summary(records, all_records) do
    baseline_by_provider_model =
      all_records
      |> baseline_summary()
      |> Map.new(fn b ->
        {{b["provider"], b["model_requested"], b["reasoning_effort"]}, b}
      end)

    records
    |> Enum.group_by(&{&1["provider"], &1["model_requested"], &1["reasoning_effort"], &1["n"]})
    |> Enum.map(fn {{provider, model, effort, n}, rs} ->
      rss_values = metric_values(rs, ["metrics", "peak_tree_rss_mb"])
      duration_values = metric_values(rs, ["duration_ms"])
      spawn_values = metric_values(rs, ["lifecycle", "spawn_visible_count"])
      wait_values = metric_values(rs, ["lifecycle", "wait_visible_count"])
      baseline = Map.get(baseline_by_provider_model, {provider, model, effort})
      baseline_rss = baseline && baseline["peak_tree_rss_median_mb"]
      rss_median = median(rss_values)

      %{
        "provider" => provider,
        "model_requested" => model,
        "reasoning_effort" => effort,
        "n" => n,
        "repetitions" => length(rs),
        "passed_count" => Enum.count(rs, &(&1["status"] == "passed")),
        "observed_count" => Enum.count(rs, &(&1["capability_status"] == "observed")),
        "duration_median_ms" => median(duration_values),
        "duration_p95_ms" => percentile(duration_values, 95),
        "peak_tree_rss_median_mb" => rss_median,
        "peak_tree_rss_p95_mb" => percentile(rss_values, 95),
        "baseline_peak_tree_rss_median_mb" => baseline_rss,
        "baseline_adjusted_peak_tree_rss_median_mb" =>
          subtract_if_numbers(rss_median, baseline_rss),
        "spawn_visible_median" => median(spawn_values),
        "wait_visible_median" => median(wait_values)
      }
    end)
    |> Enum.sort_by(&{&1["n"], &1["provider"], &1["model_requested"]})
  end

  defp metric_values(records, path) do
    records
    |> Enum.map(&get_in(&1, path))
    |> Enum.filter(&is_number/1)
  end

  defp median([]), do: nil

  defp median(values) do
    sorted = Enum.sort(values)
    count = length(sorted)
    middle = div(count, 2)

    value =
      if rem(count, 2) == 1 do
        Enum.at(sorted, middle)
      else
        (Enum.at(sorted, middle - 1) + Enum.at(sorted, middle)) / 2
      end

    round_metric(value)
  end

  defp percentile([], _pct), do: nil

  defp percentile(values, pct) do
    sorted = Enum.sort(values)
    index = min(length(sorted) - 1, max(0, ceil(pct / 100 * length(sorted)) - 1))
    sorted |> Enum.at(index) |> round_metric()
  end

  defp subtract_if_numbers(a, b) when is_number(a) and is_number(b), do: round_metric(a - b)
  defp subtract_if_numbers(_a, _b), do: nil

  defp round_metric(value) when is_float(value), do: Float.round(value, 2)
  defp round_metric(value), do: value

  defp render_report(summary, records) do
    rows =
      records
      |> Enum.map_join("\n", fn r ->
        lifecycle = r["lifecycle"] || %{}
        peak_rss_mb = get_in(r, ["metrics", "peak_tree_rss_mb"]) || ""

        "| #{r["provider"]} | #{r["model_requested"]} | #{r["n"]} | #{r["repetition"]} | #{r["baseline"]} | #{r["model_accepted"] || ""} | #{r["reasoning_effort"] || ""} | #{r["status"]} | #{r["capability_status"]} | #{r["duration_ms"]} | #{peak_rss_mb} | #{lifecycle["spawn_visible_count"]} | #{lifecycle["wait_visible_count"]} | #{Path.relative_to_cwd(get_in(r, ["evidence", "raw_result_path"]))} |"
      end)

    aggregate_section = json_section("Aggregate Summary", summary["aggregate_summary"])
    baseline_section = json_section("Baseline Summary", summary["baseline_summary"])
    gate_section = json_section("Common Model Gate", summary["common_model_gate"])
    validation_section = json_section("Schema Validation", summary["schema_validation"])
    completion_section = json_section("Completion Audit", summary["completion_audit"])

    score_section =
      case summary["score_summary"] do
        [] ->
          ""

        scores ->
          """

          ## Score Summary

          ```json
          #{Jason.encode!(scores, pretty: true)}
          ```
          """
      end

    """
    # Real-Network Subagents #{report_kind(summary["scenario"])}

    Run id: `#{summary["run_id"]}`

    Status: **#{summary["status"]}**

    Output directory: `#{summary["output_dir"]}`

    ## Matrix

    | Provider | Requested model | N | Rep | Baseline | Accepted model | Reasoning | Status | Capability | Duration ms | Peak tree RSS MB | Spawn visible | Wait visible | Raw result |
    |---|---|---:|---:|---|---|---|---|---|---:|---:|---:|---:|---|
    #{rows}

    ## Summary

    - Common capable models: #{inspect(summary["common_capable_models"])}
    - Capability-diverged models: #{inspect(summary["capability_diverged_models"])}
    - Provider-native capable: #{Jason.encode!(summary["provider_native_capable"])}
    #{gate_section}
    #{aggregate_section}
    #{baseline_section}
    #{score_section}
    #{validation_section}
    #{completion_section}

    ## Requirements

    ```json
    #{Jason.encode!(summary["requirements"], pretty: true)}
    ```

    Raw records: `runs.jsonl`

    Summary: `summary.json`
    """
  end

  defp json_section(_title, []), do: ""
  defp json_section(_title, nil), do: ""

  defp json_section(title, data) do
    """

    ## #{title}

    ```json
    #{Jason.encode!(data, pretty: true)}
    ```
    """
  end

  defp report_kind("representative_review_n3"), do: "Representative Review"
  defp report_kind("scaling_lifecycle"), do: "Scaling Lifecycle"
  defp report_kind("common_model_gate"), do: "Common Model Gate"
  defp report_kind("smoke_real_n2"), do: "Smoke Real N=2"
  defp report_kind("probe"), do: "Provider Probe"
  defp report_kind(_scenario), do: "Capability Matrix"

  defp print_help(json?) do
    payload = %{
      "ok" => true,
      "command" => "mix pixir.bench.real_subagents",
      "description" => "Run real-network T3/Pixir/Codex Subagents benchmarks.",
      "options" => [
        "--scenario capability_matrix|probe|smoke_real_n2|common_model_gate|representative_review_n3|scaling_lifecycle",
        "--providers pixir,codex",
        "--models gpt-5.5",
        "--reasoning-effort low",
        "--n 1",
        "--n-values 1,3,5",
        "--repetitions 3",
        "--include-baseline",
        "--dry-run",
        "--json",
        "--output PATH",
        "--t3-code-path PATH"
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
      Run real-network T3/Pixir/Codex Subagents benchmarks.

      Usage:
        mix pixir.bench.real_subagents [options]

      Common:
        mix pixir.bench.real_subagents --dry-run
        mix pixir.bench.real_subagents --scenario common_model_gate --dry-run --json
        mix pixir.bench.real_subagents --scenario common_model_gate --models gpt-5.5 --reasoning-effort low
        mix pixir.bench.real_subagents --scenario scaling_lifecycle --models gpt-5.5 --reasoning-effort low --n 10
        mix pixir.bench.real_subagents --models gpt-5.5 --reasoning-effort low --n-values 1,3,5 --repetitions 3 --include-baseline

      Agent-facing:
        --json       emit machine-readable dry-run/result/error JSON
        --dry-run    print planned commands and artifacts without network calls
      """)
    end
  end

  defp print_dry_run(output_dir, combos, json?) do
    payload = %{
      "ok" => true,
      "mode" => "dry_run",
      "would_write" => [
        Path.join(output_dir, "runs.jsonl"),
        Path.join(output_dir, "summary.json"),
        Path.join(output_dir, "report.md"),
        Path.join(output_dir, "completion_audit.json"),
        Path.join(output_dir, "provider-artifacts")
      ],
      "would_run" => Enum.map(combos, &combo_plan/1),
      "estimated_real_network_runs" => Enum.count(combos, &(not &1.baseline)),
      "requires" => [
        "Node 24 via nvm",
        "paired T3 Code checkout",
        "local Pixir escript at ./pixir for Pixir provider runs",
        "provider authentication for real-network runs"
      ]
    }

    if json? do
      IO.puts(Jason.encode!(payload, pretty: true))
    else
      Mix.shell().info("Dry run. Would write: #{output_dir}")

      Enum.each(combos, fn combo ->
        Mix.shell().info("""
        provider=#{combo.provider} model=#{combo.model_requested} reasoning=#{combo.reasoning_effort} n=#{combo.n} rep=#{combo.repetition} baseline=#{combo.baseline}
          cd #{combo.t3_code_path}
          bun #{shell_join(combo.args)}
          raw_result=#{combo.raw_result_path}
        """)
      end)
    end
  end

  defp print_common_model_gate_dry_run(output_dir, plan, json?) do
    payload = %{
      "ok" => true,
      "mode" => "dry_run",
      "scenario" => "common_model_gate",
      "would_write" => [
        Path.join(output_dir, "runs.jsonl"),
        Path.join(output_dir, "summary.json"),
        Path.join(output_dir, "report.md"),
        Path.join(output_dir, "completion_audit.json"),
        Path.join(output_dir, "provider-artifacts")
      ],
      "candidate_models" => plan.candidates,
      "providers" => plan.providers,
      "would_run_probe" => Enum.map(plan.probe_combos, &combo_plan/1),
      "would_run_smoke_if_common_model" => Enum.map(plan.smoke_combos, &combo_plan/1),
      "estimated_real_network_runs" => length(plan.probe_combos) + length(plan.providers),
      "completion_semantics" => %{
        "success" => "common_model_smoke_ready",
        "non_comparable_abort" => ["model_diverged", "capability_diverged"],
        "representative_review_n3_deferred" => true
      },
      "requires" => [
        "Node 24 via nvm",
        "paired T3 Code checkout",
        "local Pixir escript at ./pixir for Pixir provider runs",
        "provider authentication for real-network runs"
      ]
    }

    if json? do
      IO.puts(Jason.encode!(payload, pretty: true))
    else
      Mix.shell().info("Dry run. Common-model gate would write: #{output_dir}")
      Mix.shell().info("Probe candidates: #{Enum.join(plan.candidates, ", ")}")

      Enum.each(plan.probe_combos, fn combo ->
        Mix.shell().info("""
        probe provider=#{combo.provider} model=#{combo.model_requested} reasoning=#{combo.reasoning_effort}
          cd #{combo.t3_code_path}
          bun #{shell_join(combo.args)}
          raw_result=#{combo.raw_result_path}
        """)
      end)

      Mix.shell().info("Smoke runs are deferred until a common probe model is selected.")
    end
  end

  defp combo_plan(combo) do
    %{
      "scenario" => combo.scenario,
      "provider" => combo.provider,
      "model_requested" => combo.model_requested,
      "reasoning_effort" => combo.reasoning_effort,
      "n" => combo.n,
      "repetition" => combo.repetition,
      "baseline" => combo.baseline,
      "cwd" => combo.t3_code_path,
      "command" => ["bun" | combo.args],
      "raw_result" => combo.raw_result_path,
      "memory_samples" => combo.memory_samples_path
    }
  end

  defp preflight!(t3_code_path, combos, json?) do
    cond do
      not File.dir?(t3_code_path) ->
        fail!(
          :missing_t3_checkout,
          "Paired T3 Code checkout was not found.",
          %{t3_code_path: t3_code_path},
          json?
        )

      missing = Enum.find(combos, &(not File.exists?(Path.join(t3_code_path, hd(&1.args))))) ->
        fail!(
          :missing_t3_harness,
          "Required T3 benchmark harness was not found.",
          %{t3_code_path: t3_code_path, script: hd(missing.args)},
          json?
        )

      true ->
        :ok
    end
  end

  defp default_t3_code_path do
    System.get_env("T3_CODE_PATH") || Path.expand("../t3code", File.cwd!())
  end

  defp fail!(kind, message, details, json?) do
    payload = %{
      "ok" => false,
      "error" => %{
        "kind" => Atom.to_string(kind),
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

  defp root_agent_hint(:missing_t3_checkout),
    do: "Verify --t3-code-path points to the local T3 checkout before rerunning."

  defp root_agent_hint(:missing_t3_harness),
    do: "Install or create the local-only T3 harness scripts before rerunning."

  defp root_agent_hint(:invalid_options),
    do: "Run with --help or --json --help to inspect the supported adapter contract."

  defp root_agent_hint(:invalid_n),
    do: "Use --n with a valid child count for the selected scenario."

  defp root_agent_hint(:invalid_n_values),
    do: "Use --n-values as a comma-separated list valid for the selected scenario."

  defp root_agent_hint(:invalid_repetitions),
    do: "Use --repetitions with a positive integer."

  defp root_agent_hint(:invalid_scenario), do: "Pick an advertised scenario."
  defp root_agent_hint(:invalid_providers), do: "Use --providers pixir,codex or a subset."

  defp root_agent_hint(_kind),
    do: "Inspect the structured details and retry after fixing local state."

  defp parse_csv(nil, default), do: default

  defp parse_csv(raw, default) when is_binary(raw) do
    raw
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> case do
      [] -> default
      values -> values
    end
  end

  defp parse_int_csv(nil, default, _min, _max), do: {:ok, default}

  defp parse_int_csv(raw, default, min, max) when is_binary(raw) do
    tokens =
      raw
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    parsed =
      Enum.map(tokens, fn value ->
        case Integer.parse(value) do
          {int, ""} when int >= min -> {:ok, int}
          _ -> {:error, value}
        end
      end)

    invalid =
      parsed
      |> Enum.flat_map(fn
        {:error, value} -> [value]
        {:ok, int} -> if(exceeds_max_n?(int, max), do: [Integer.to_string(int)], else: [])
      end)

    values =
      parsed
      |> Enum.flat_map(fn
        {:ok, int} -> [int]
        {:error, _value} -> []
      end)

    cond do
      invalid != [] ->
        {:error,
         %{values: tokens, invalid: invalid, expected_minimum: min, expected_maximum: max}}

      values == [] ->
        {:ok, default}

      true ->
        {:ok, Enum.uniq(values)}
    end
  end

  defp model_args("default"), do: []
  defp model_args(model), do: ["--model", model]

  defp reasoning_effort_args(nil), do: []
  defp reasoning_effort_args(""), do: []
  defp reasoning_effort_args(effort), do: ["--reasoning-effort", effort]

  defp baseline_args(true), do: ["--baseline"]
  defp baseline_args(false), do: []

  defp raw_result_path("pixir", artifact_dir),
    do: Path.join(artifact_dir, "t3-pixir-subagents-result.json")

  defp raw_result_path("codex", artifact_dir),
    do: Path.join(artifact_dir, "codex-subagents-observability.json")

  defp provider_path("pixir"), do: "t3code-pixir-acp"
  defp provider_path("codex"), do: "t3code-codex-app-server"

  defp slug(value) do
    value
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9_.-]+/, "-")
    |> String.trim("-")
  end

  defp shell_join(args), do: Enum.map_join(args, " ", &shell_escape/1)

  defp shell_escape(arg) when is_binary(arg) do
    "'" <> String.replace(arg, "'", "'\"'\"'") <> "'"
  end

  defp write_jsonl!(path, records) do
    contents = Enum.map_join(records, "\n", &Jason.encode!/1) <> "\n"
    File.write!(path, contents)
  end

  defp timestamp do
    DateTime.utc_now()
    |> DateTime.to_iso8601(:basic)
    |> String.replace(~r/[^0-9TZ]/, "")
    |> String.replace("Z", "")
  end
end
