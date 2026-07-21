defmodule Pixir.MixProject do
  use Mix.Project

  @version "0.1.12"
  @source_url "https://github.com/Ranvier-Technologies/pixir"

  def project do
    [
      app: :pixir,
      version: @version,
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      escript: escript(),
      deps: deps(),
      aliases: aliases(),
      description: description(),
      package: package(),
      docs: docs()
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger, :crypto, :public_key],
      mod: {Pixir.Application, []}
    ]
  end

  defp escript do
    # +Bi ignores the BEAM break handler so a companion shell trap can forward
    # SIGINT as SIGUSR1 during CLI Turn execution (issue #24).
    [main_module: Pixir.CLI, name: "pixir", emu_args: "-Bi"]
  end

  defp description do
    "Elixir/OTP runtime for supervised coding-agent sessions with ACP, Subagents, Workflows, and replayable evidence."
  end

  defp docs do
    adr_extras = public_adr_extras()
    example_paths = public_example_extras()
    example_extras = Enum.map(example_paths, &{&1, [filename: doc_extra_filename(&1)]})
    quickstart = "docs/open-beta-quickstart.md"
    release_notes = "docs/release-notes/open-beta-developer-preview.md"

    [
      main: "readme",
      source_url: @source_url,
      source_ref: "main",
      assets: %{"assets/brand" => "assets/brand"},
      extras:
        [
          {"README.md", [filename: "readme", title: "Pixir"]},
          "CONTEXT.md",
          quickstart,
          release_notes
        ] ++
          adr_extras ++ example_extras,
      groups_for_extras: [
        "Public Contract": ["CONTEXT.md", quickstart, release_notes] ++ adr_extras,
        Examples: example_paths
      ],
      groups_for_modules: [
        "Runtime Core": [
          Pixir,
          Pixir.Application,
          Pixir.Event,
          Pixir.Events,
          Pixir.Log,
          Pixir.Session,
          Pixir.SessionSupervisor,
          Pixir.Turn,
          Pixir.Conversation
        ],
        "Provider And Auth": ~r/^Pixir\.(Provider|Auth)/,
        "Agent Practices": [Pixir.Agents, Pixir.Skills, Pixir.Subagents, Pixir.Workflows],
        Tools: ~r/^Pixir\.Tools?/,
        ACP: ~r/^Pixir\.ACP/
      ]
    ]
  end

  defp doc_extra_filename(path) do
    path
    |> Path.rootname()
    |> String.replace("/", "-")
    |> String.downcase()
  end

  defp public_adr_extras do
    [
      "docs/adr/0016-open-beta-scope.md",
      "docs/adr/0017-minimal-harness-core-and-interactive-boundary.md",
      "docs/adr/0018-durable-history-compaction-and-replay-repair.md",
      "docs/adr/0019-provider-usage-and-prompt-cache.md",
      "docs/adr/0021-session-resources-and-image-attachments.md",
      "docs/adr/0022-provider-hosted-web-search.md",
      "docs/adr/0025-hex-package-scope.md",
      "docs/adr/0026-runtime-terminal-state-and-replay-contract.md"
    ]
  end

  defp public_example_extras do
    [
      "docs/examples/delegate-cli-live/README.md",
      "docs/examples/skill-workflow-template/README.md",
      "docs/examples/skill-workflow-template/SKILL.md"
    ]
  end

  defp public_example_files do
    [
      "docs/examples/delegate-cli-live/README.md",
      "docs/examples/delegate-cli-live/attached-subagents.json",
      "docs/examples/delegate-cli-live/async-subagents.json",
      "docs/examples/skill-workflow-template/README.md",
      "docs/examples/skill-workflow-template/SKILL.md"
    ]
  end

  defp deps do
    [
      {:ex_doc, "~> 0.40.3", only: :dev, runtime: false},
      {:finch, "0.23.0"},
      {:just_bash, "~> 0.3.0"},
      {:jason, "1.4.5"}
    ]
  end

  defp package do
    [
      files: package_files(),
      licenses: ["MIT"],
      links: %{
        "GitHub" => @source_url,
        "Changelog" => "#{@source_url}/blob/main/CHANGELOG.md"
      }
    ]
  end

  defp package_files do
    [
      ".formatter.exs",
      "assets/brand/pixir-logo.svg",
      "assets/brand/pixir-logo-card.svg",
      "assets/readme/runtime-boundary.svg",
      "CHANGELOG.md",
      "CONTEXT.md",
      "LICENSE",
      "README.md",
      "mix.exs",
      "docs/open-beta-quickstart.md",
      "docs/release-notes/open-beta-developer-preview.md"
    ] ++
      public_runtime_files() ++
      public_adr_extras() ++
      public_example_files()
  end

  defp public_runtime_files do
    Path.wildcard("lib/**/*.ex") -- Path.wildcard("lib/mix/tasks/**/*.ex")
  end

  # Run the test suite in MIX_ENV=test as a fresh subprocess. We shell out with
  # MIX_ENV exported as an environment variable rather than the older
  # `cmd env MIX_ENV=test mix ...` form: that nested a second `mix` under the
  # `env` binary, and on teardown the child BEAM node did not exit cleanly, so
  # `mix check` hung after "N tests, 0 failures" instead of returning.
  defp run_test_suite(_args) do
    {_output, status} =
      System.cmd(
        "mix",
        ["do", "compile", "--warnings-as-errors", "+", "test", "--warnings-as-errors"],
        env: [{"MIX_ENV", "test"}],
        into: IO.stream(:stdio, :line)
      )

    if status != 0, do: Mix.raise("test suite failed with exit status #{status}")
  end

  defp aliases do
    [
      check: [
        "format --check-formatted",
        "compile --warnings-as-errors",
        &run_test_suite/1,
        "escript.build",
        "cmd ./pixir doctor --json",
        "pixir.smoke.workflows --dry-run --json",
        "pixir.smoke.prompt_cache --dry-run --json",
        "pixir.smoke.websocket --dry-run --json",
        "docs --warnings-as-errors"
      ]
    ]
  end
end
