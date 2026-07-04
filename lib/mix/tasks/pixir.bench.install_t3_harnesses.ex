defmodule Mix.Tasks.Pixir.Bench.InstallT3Harnesses do
  @shortdoc "Install local-only T3 benchmark harness templates"

  @moduledoc """
  Installs Pixir-owned copies of the local-only T3 benchmark harnesses into the paired
  T3 Code checkout.

  The harnesses are templates for local benchmarking only. This task does not create,
  commit, push, or upstream T3 Code changes.

  Usage:

      mix pixir.bench.install_t3_harnesses --dry-run --json
      mix pixir.bench.install_t3_harnesses
      mix pixir.bench.install_t3_harnesses --force
      mix pixir.bench.install_t3_harnesses --t3-code-path /path/to/t3code

  Options:

    * `--t3-code-path` - paired T3 Code checkout. Default: `T3_CODE_PATH`, or
      `../t3code` relative to the Pixir repo.
    * `--force` - overwrite existing harness files when their contents differ.
    * `--dry-run` - describe planned writes without touching the T3 checkout.
    * `--json` - emit machine-readable output or errors.
    * `--help` - print command help.
  """

  use Mix.Task

  @template_dir Path.expand(
                  Path.join([
                    __DIR__,
                    "..",
                    "..",
                    "..",
                    "docs",
                    "benchmarks",
                    "t3-harnesses"
                  ])
                )

  @templates [
    %{
      source: "pixir-subagents-benchmark.ts",
      target: "scripts/pixir-subagents-benchmark.ts",
      provider_path: "t3code-pixir-acp"
    },
    %{
      source: "codex-subagents-observability-probe.ts",
      target: "scripts/codex-subagents-observability-probe.ts",
      provider_path: "t3code-codex-app-server"
    }
  ]

  @switches [
    t3_code_path: :string,
    force: :boolean,
    dry_run: :boolean,
    json: :boolean,
    help: :boolean
  ]

  @aliases [h: :help]

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

    t3_code_path = Keyword.get(opts, :t3_code_path, default_t3_code_path()) |> Path.expand()
    dry_run? = Keyword.get(opts, :dry_run, false)
    force? = Keyword.get(opts, :force, false)

    preflight!(t3_code_path, json?)

    actions = Enum.map(@templates, &plan_action(&1, t3_code_path, force?))

    conflicts =
      Enum.filter(actions, fn action ->
        action["action"] == "conflict"
      end)

    if conflicts != [] and not dry_run? do
      fail!(
        :target_exists,
        "One or more T3 harness files already exist with different contents. Use --force to overwrite.",
        %{conflicts: conflicts},
        json?
      )
    end

    unless dry_run? do
      Enum.each(actions, &apply_action!/1)
    end

    payload = %{
      "ok" => true,
      "mode" => if(dry_run?, do: "dry_run", else: "install"),
      "t3_code_path" => t3_code_path,
      "template_dir" => @template_dir,
      "force" => force?,
      "actions" => actions,
      "would_write" =>
        actions
        |> Enum.reject(&(&1["action"] == "up_to_date"))
        |> Enum.map(& &1["target_path"]),
      "note" =>
        "Harnesses are local-only T3 benchmark adapters. Do not upstream them unless explicitly requested."
    }

    if json? do
      IO.puts(Jason.encode!(payload, pretty: true))
    else
      Mix.shell().info("""

      T3 benchmark harness install #{if(dry_run?, do: "dry-run", else: "complete")}.
        T3 checkout: #{t3_code_path}
      """)

      Enum.each(actions, fn action ->
        Mix.shell().info("  #{action["action"]}: #{action["target_path"]}")
      end)
    end
  end

  defp preflight!(t3_code_path, json?) do
    cond do
      not File.dir?(@template_dir) ->
        fail!(
          :missing_templates,
          "Pixir T3 harness templates were not found.",
          %{template_dir: @template_dir},
          json?
        )

      missing_template = Enum.find(@templates, &(not File.exists?(template_path(&1)))) ->
        fail!(
          :missing_template,
          "A Pixir T3 harness template was not found.",
          %{template: missing_template.source, template_dir: @template_dir},
          json?
        )

      not File.dir?(t3_code_path) ->
        fail!(
          :missing_t3_checkout,
          "Paired T3 Code checkout was not found.",
          %{t3_code_path: t3_code_path},
          json?
        )

      true ->
        :ok
    end
  end

  defp default_t3_code_path do
    System.get_env("T3_CODE_PATH") || Path.expand("../t3code", File.cwd!())
  end

  defp plan_action(template, t3_code_path, force?) do
    source_path = template_path(template)
    target_path = Path.join(t3_code_path, template.target)
    source_hash = file_hash(source_path)
    target_hash = if File.exists?(target_path), do: file_hash(target_path)

    action =
      cond do
        target_hash == source_hash ->
          "up_to_date"

        target_hash && force? ->
          "overwrite"

        target_hash ->
          "conflict"

        true ->
          "install"
      end

    %{
      "action" => action,
      "source_path" => source_path,
      "target_path" => target_path,
      "provider_path" => template.provider_path,
      "source_sha256" => source_hash,
      "target_sha256" => target_hash
    }
  end

  defp apply_action!(%{"action" => "up_to_date"}), do: :ok
  defp apply_action!(%{"action" => "conflict"}), do: :ok

  defp apply_action!(%{"source_path" => source_path, "target_path" => target_path}) do
    File.mkdir_p!(Path.dirname(target_path))
    File.cp!(source_path, target_path)
  end

  defp template_path(template), do: Path.join(@template_dir, template.source)

  defp file_hash(path) do
    path
    |> File.read!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp print_help(json?) do
    payload = %{
      "ok" => true,
      "command" => "mix pixir.bench.install_t3_harnesses",
      "description" => "Install local-only T3 benchmark harness templates.",
      "options" => [
        "--t3-code-path PATH",
        "--force",
        "--dry-run",
        "--json",
        "--help"
      ],
      "templates" => Enum.map(@templates, &Map.take(&1, [:source, :target, :provider_path]))
    }

    if json? do
      IO.puts(Jason.encode!(payload, pretty: true))
    else
      Mix.shell().info("""
      Install local-only T3 benchmark harness templates.

      Usage:
        mix pixir.bench.install_t3_harnesses [options]

      Common:
        mix pixir.bench.install_t3_harnesses --dry-run --json
        mix pixir.bench.install_t3_harnesses --force
      """)
    end
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

  defp root_agent_hint(:target_exists),
    do:
      "Inspect the local T3 scripts. Use --force only if overwriting local harness edits is intended."

  defp root_agent_hint(:missing_t3_checkout),
    do: "Pass --t3-code-path pointing at the local T3 Code checkout."

  defp root_agent_hint(:missing_templates),
    do: "Verify the Pixir repo includes docs/benchmarks/t3-harnesses."

  defp root_agent_hint(:missing_template),
    do: "Restore the missing template file from the Pixir repo."

  defp root_agent_hint(:invalid_options),
    do: "Run with --help or --json --help to inspect the supported installer contract."

  defp root_agent_hint(_kind), do: "Inspect the structured details and retry."
end
