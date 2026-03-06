defmodule HotReleaseApp.StateServer do
  @moduledoc false

  use GenServer

  @state_label System.get_env("FIXTURE_STATE_LABEL", "v0")
  @code_change_mode System.get_env("FIXTURE_CODE_CHANGE_MODE", "migrate")

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  def snapshot do
    GenServer.call(__MODULE__, :snapshot)
  end

  @impl true
  def init(nil) do
    {:ok,
     %{
       label: @state_label,
       migrations: 0,
       previous_label: nil,
       version: HotReleaseApp.version()
     }}
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    {:reply, Map.put(state, :pid, self()), state}
  end

  @impl true
  def code_change(_old_vsn, state, _extra) do
    case @code_change_mode do
      "fail" ->
        {:error, :forced_code_change_failure}

      _ ->
        {:ok,
         %{
           state
           | label: @state_label,
             migrations: state.migrations + 1,
             previous_label: state.label,
             version: HotReleaseApp.version()
         }}
    end
  end
end
