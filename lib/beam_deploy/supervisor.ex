defmodule BeamDeploy.Supervisor do
  @moduledoc false

  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    otp_app = Keyword.fetch!(opts, :otp_app)
    parent_children = Keyword.get(opts, :children, [])

    children =
      parent_children ++
        [
          {Task.Supervisor, name: BeamDeploy.TaskSupervisor},
          {BeamDeploy.PeerManager,
           otp_app: otp_app,
           endpoint: Keyword.get(opts, :endpoint),
           shutdown_timeout: Keyword.get(opts, :shutdown_timeout),
           before_cutover: Keyword.get(opts, :before_cutover),
           after_cutover: Keyword.get(opts, :after_cutover)}
        ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
