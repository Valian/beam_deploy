defmodule BeamDeploy.MixProject do
  use Mix.Project

  def project do
    [
      app: :beam_deploy,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      test_ignore_filters: [~r/test\/fixtures/],
      description: "Blue-green release swaps for a single Elixir node via :peer",
      package: package()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:ex_doc, "~> 0.38", only: :dev, runtime: false},
      {:styler, "~> 1.11", only: [:dev, :test], runtime: false},
      {:bandit, "~> 1.0", only: :test, runtime: false},
      {:plug, "~> 1.0", only: :test, runtime: false}
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      files: ~w(lib mix.exs README.md .formatter.exs)
    ]
  end
end
