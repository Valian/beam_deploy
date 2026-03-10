defmodule HotReleaseApp.Application do
  @moduledoc false
  use Application

  def start(_type, _args) do
    port = "PORT" |> System.get_env("4000") |> String.to_integer()

    children = [
      HotReleaseApp.StateServer,
      {Bandit, plug: HotReleaseApp.Router, port: port}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: HotReleaseApp.Supervisor)
  end
end
