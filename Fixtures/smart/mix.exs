defmodule GreeceRelay.MixProject do
  use Mix.Project

  @version "0.4.0"

  def project do
    [
      app: :greece_relay,
      version: @version,
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      description: "Relays live-reload events from Macs to the Greece web viewer.",
      package: [licenses: ["Apache-2.0"]],
      deps: deps(),
      aliases: aliases()
    ]
  end

  def application do
    [extra_applications: [:logger], mod: {GreeceRelay.Application, []}]
  end

  defp deps do
    [
      {:phoenix, "~> 1.7.14"},
      {:phoenix_pubsub, "~> 2.1"},
      {:jason, "~> 1.4"},
      {:bandit, "~> 1.5"},
      {:telemetry_metrics, "~> 1.0"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:greece_proto, github: "example/greece-proto"}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get", "assets.setup"],
      "assets.setup": ["esbuild.install --if-missing"],
      test: ["format --check-formatted", "test"]
    ]
  end
end
