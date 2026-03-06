defmodule HotReleaseApp.MixProject do
  use Mix.Project

  @version System.get_env("FIXTURE_APP_VERSION", "0.1.0")

  def project do
    [
      app: :hot_release_app,
      version: @version,
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      releases: releases()
    ]
  end

  def application do
    [
      mod: {HotReleaseApp.Application, []},
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:beam_deploy, path: "../../.."},
      {:bandit, "~> 1.0"},
      {:plug, "~> 1.0"}
    ]
  end

  defp releases do
    [
      hot_release_app: [
        include_executables_for: [:unix],
        steps: [:assemble, :tar]
      ]
    ]
  end
end
