defmodule BeamDeploy.TestSupport.HotServer do
  @moduledoc false

  use GenServer

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, opts)
  end

  def ping(pid) do
    GenServer.call(pid, :ping)
  end

  def snapshot(pid) do
    GenServer.call(pid, :snapshot)
  end

  @impl true
  def init(opts) do
    {:ok, %{mode: Keyword.get(opts, :mode, :ok), value: Keyword.get(opts, :value, :ok)}}
  end

  @impl true
  def handle_call(:ping, _from, state) do
    {:reply, :pong, state}
  end

  def handle_call(:snapshot, _from, state) do
    {:reply, state, state}
  end

  @impl true
  def code_change(_old_vsn, %{mode: :fail} = state, _extra) do
    {:error, {:forced_failure, state.value}}
  end

  def code_change(_old_vsn, state, _extra) do
    {:ok, Map.update(state, :value, 1, &increment/1)}
  end

  defp increment(value) when is_integer(value), do: value + 1
  defp increment(value), do: value
end
