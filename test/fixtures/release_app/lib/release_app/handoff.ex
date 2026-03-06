defmodule ReleaseApp.Handoff do
  @moduledoc false
  def before_cutover(_incoming_node) do
    %{version: ReleaseApp.version(), timestamp: System.monotonic_time()}
  end

  def after_cutover(handoff_state) do
    ReleaseApp.State.set_handoff(handoff_state)
  end
end
