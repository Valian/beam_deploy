defmodule BeamDeploy.Sentinel do
  @moduledoc false

  use GenServer

  require Logger

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  def arm(before_cutover_mfa, incoming_node) do
    GenServer.call(__MODULE__, {:arm, before_cutover_mfa, incoming_node})
  end

  @impl true
  def init(nil) do
    Process.flag(:trap_exit, true)
    {:ok, %{before_cutover: nil, incoming_node: nil}}
  end

  @impl true
  def handle_call({:arm, mfa, incoming_node}, _from, state) do
    {:reply, :ok, %{state | before_cutover: mfa, incoming_node: incoming_node}}
  end

  @impl true
  def terminate(_reason, %{before_cutover: {mod, fun, args}, incoming_node: incoming_node}) do
    result =
      try do
        apply(mod, fun, [incoming_node | args])
      catch
        kind, reason ->
          Logger.error("[BeamDeploy.Sentinel] before_cutover failed: #{kind}: #{inspect(reason)}")
          nil
      end

    BeamDeploy.put_handoff(:__before_cutover_result__, result)
  end

  def terminate(_reason, _state), do: :ok
end
