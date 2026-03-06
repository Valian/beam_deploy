defmodule ReleaseApp.Application do
  @moduledoc false
  use Application

  def start(type, args) do
    BeamDeploy.start_link(
      otp_app: :release_app,
      start: {__MODULE__, :start_app, [type, args]},
      before_cutover: {ReleaseApp.Handoff, :before_cutover, []},
      after_cutover: {ReleaseApp.Handoff, :after_cutover, []},
      endpoint: nil
    )
  end

  def start_app(_type, _args) do
    port = "PORT" |> System.get_env("4000") |> String.to_integer()

    children = [
      ReleaseApp.State,
      {Bandit,
       plug: ReleaseApp.Router,
       port: port,
       thousand_island_options: [
         transport_options: [reuseport: true, reuseaddr: true]
       ]}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: ReleaseApp.Supervisor)
  end
end
