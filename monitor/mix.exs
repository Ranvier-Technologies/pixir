defmodule PixirMonitor.MixProject do
  use Mix.Project

  def project do
    [
      app: :pixir_monitor,
      version: "0.1.0",
      elixir: "~> 1.20",
      escript: [main_module: PixirMonitor.CLI, name: "pixir-monitor", app: nil],
      start_permanent: Mix.env() == :prod,
      test_ignore_filters: [~r"^test/support/"],
      deps: deps()
    ]
  end

  def application do
    [mod: {PixirMonitor.Application, []}, extra_applications: [:logger, :crypto, :inets]]
  end

  defp deps do
    [
      {:pixir, path: ".."},
      {:phoenix, "== 1.8.9"},
      {:bandit, "== 1.12.0"},
      {:jason, "== 1.4.5"},
      {:jsv, "== 0.20.0"}
    ]
  end
end
