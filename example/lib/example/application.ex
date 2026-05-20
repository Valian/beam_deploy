defmodule Example.Application do
  @moduledoc false

  use Application

  @impl true
  def start(type, args) do
    BeamDeploy.start_link([Example.Deployer],
      otp_app: :example,
      start: {__MODULE__, :start_app, [type, args]},
      endpoint: ExampleWeb.Endpoint
    )
  end

  def start_app(_type, _args) do
    children = [
      ExampleWeb.Telemetry,
      {DNSCluster, query: Application.get_env(:example, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Example.PubSub},
      ExampleWeb.Endpoint
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Example.Supervisor)
  end

  @impl true
  def config_change(changed, _new, removed) do
    ExampleWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
