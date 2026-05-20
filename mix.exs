defmodule BeamDeploy.MixProject do
  use Mix.Project

  @version "0.1.0"
  @repo_url "https://github.com/Valian/beam_deploy"

  def project do
    [
      app: :beam_deploy,
      version: @version,
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      aliases: aliases(),
      deps: deps(),
      test_ignore_filters: [~r/test\/fixtures/],
      description: "Single-host blue-green release swaps and hot upgrades for Elixir",
      package: package(),
      name: "BeamDeploy",
      docs: [
        main: "readme",
        source_ref: "v#{@version}",
        source_url: @repo_url,
        homepage_url: @repo_url,
        extras: [
          "README.md": [title: "BeamDeploy"],
          "CHANGELOG.md": [title: "Changelog"]
        ],
        links: %{
          "GitHub" => @repo_url
        }
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:ex_doc, "~> 0.38", only: :dev, runtime: false},
      {:easy_publish, "~> 0.1", only: :dev, runtime: false},
      {:styler, "~> 1.11", only: [:dev, :test], runtime: false},
      {:bandit, "~> 1.0", only: :test, runtime: false},
      {:plug, "~> 1.0", only: :test, runtime: false}
    ]
  end

  defp package do
    [
      maintainers: ["Jakub Skalecki"],
      licenses: ["MIT"],
      links: %{
        Changelog: @repo_url <> "/blob/main/CHANGELOG.md",
        GitHub: @repo_url
      },
      files: ~w(lib mix.exs README.md CHANGELOG.md LICENSE.md .formatter.exs)
    ]
  end

  defp aliases do
    [
      "release.patch": ["easy_publish.release patch --branch=main"],
      "release.minor": ["easy_publish.release minor --branch=main"],
      "release.major": ["easy_publish.release major --branch=main"]
    ]
  end
end
