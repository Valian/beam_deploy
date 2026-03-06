defmodule ReleaseApp.State do
  @moduledoc false
  use Agent

  def start_link(_opts) do
    Agent.start_link(fn -> %{handoff: nil} end, name: __MODULE__)
  end

  def get_handoff do
    Agent.get(__MODULE__, & &1.handoff)
  end

  def set_handoff(data) do
    Agent.update(__MODULE__, &Map.put(&1, :handoff, data))
  end
end
