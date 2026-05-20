defmodule Example.Deployer do
  use GenServer

  @name __MODULE__
  @version Mix.Project.config()[:version]

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :idle, name: @name)
  end

  def deploy(label) do
    call({:deploy, label}, {:error, :not_running})
  end

  def status do
    call(:status, %{state: :idle, label: nil, log: []})
  end

  @impl true
  def init(:idle) do
    {:ok, %{state: :idle, label: nil, log: []}}
  end

  @impl true
  def handle_call({:deploy, _label}, _from, %{state: state_name} = state)
      when state_name in [:running, :upgrading] do
    {:reply, {:error, :busy}, state}
  end

  def handle_call({:deploy, label}, _from, state) do
    parent = self()

    Task.start(fn ->
      try do
        run(parent, label)
      rescue
        exception -> send(parent, {:failed, Exception.message(exception)})
      end
    end)

    next_state = %{
      state
      | state: :running,
        label: label,
        log: ["Starting build for #{inspect(label)}"]
    }

    {:reply, :ok, next_state}
  end

  def handle_call(:status, _from, state) do
    {:reply, state, state}
  end

  @impl true
  def handle_info({:log, line}, state) do
    {:noreply, %{state | log: keep_log([line | state.log])}}
  end

  def handle_info(:upgrading, state) do
    {:noreply,
     %{state | state: :upgrading, log: keep_log(["Handing tarball to BeamDeploy" | state.log])}}
  end

  def handle_info(:complete, state) do
    {:noreply, %{state | state: :idle, log: keep_log(["Release swap complete" | state.log])}}
  end

  def handle_info({:failed, reason}, state) do
    {:noreply, %{state | state: :failed, log: keep_log([reason | state.log])}}
  end

  defp run(parent, label) do
    with {:ok, source_dir} <- source_dir(),
         :ok <- build_release(parent, source_dir, label),
         :ok <- upgrade(parent, source_dir) do
      send(parent, :complete)
    else
      {:error, reason} -> send(parent, {:failed, inspect(reason)})
    end
  end

  defp source_dir do
    source_dir = System.get_env("DEMO_SOURCE_DIR") || File.cwd!()

    if File.exists?(Path.join(source_dir, "mix.exs")) do
      {:ok, source_dir}
    else
      {:error,
       "Set DEMO_SOURCE_DIR to the example app source directory before starting the release"}
    end
  end

  defp build_release(parent, source_dir, label) do
    env = [
      {"MIX_ENV", "prod"},
      {"DEMO_BUTTON_LABEL", label},
      {"PHX_SERVER", "true"}
    ]

    with :ok <- run_command(parent, source_dir, env, "mix", ["deps.get", "--only", "prod"]),
         :ok <- run_command(parent, source_dir, env, "mix", ["compile", "--force"]),
         :ok <- run_command(parent, source_dir, env, "mix", ["release", "--overwrite"]) do
      :ok
    end
  end

  defp upgrade(parent, source_dir) do
    send(parent, :upgrading)

    tarball_path = Path.join([source_dir, "_build", "prod", "example-#{@version}.tar.gz"])

    BeamDeploy.upgrade(tarball_path)
  end

  defp run_command(parent, cwd, env, command, args) do
    executable = System.find_executable(command)

    port =
      Port.open({:spawn_executable, executable}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        {:args, args},
        {:cd, String.to_charlist(cwd)},
        {:env, port_env(env)}
      ])

    collect_port(parent, port)
  end

  defp port_env(env) do
    cleared_release_env =
      System.get_env()
      |> Map.keys()
      |> Enum.filter(&release_env?/1)
      |> Enum.map(&{String.to_charlist(&1), false})

    build_env =
      [{"PATH", clean_path()} | env]
      |> Enum.map(fn {key, value} -> {String.to_charlist(key), String.to_charlist(value)} end)

    cleared_release_env ++ build_env
  end

  defp release_env?(key) do
    String.starts_with?(key, "RELEASE_") or key in ["BINDIR", "EMU", "PROGNAME", "ROOTDIR"]
  end

  defp clean_path do
    release_root = System.get_env("RELEASE_ROOT")

    System.get_env("PATH", "")
    |> String.split(":", trim: true)
    |> Enum.reject(&(release_root && String.starts_with?(&1, release_root)))
    |> Enum.join(":")
  end

  defp collect_port(parent, port) do
    receive do
      {^port, {:data, data}} ->
        data
        |> String.split("\n", trim: true)
        |> Enum.each(&send(parent, {:log, &1}))

        collect_port(parent, port)

      {^port, {:exit_status, 0}} ->
        :ok

      {^port, {:exit_status, status}} ->
        {:error, "Build command exited with status #{status}"}
    end
  end

  defp call(message, fallback) do
    case parent_node() do
      nil -> GenServer.call(@name, message, :infinity)
      parent when parent == node() -> GenServer.call(@name, message, :infinity)
      parent -> :erpc.call(parent, GenServer, :call, [@name, message, :infinity], :infinity)
    end
  catch
    :exit, _ -> fallback
  end

  defp parent_node do
    :persistent_term.get({BeamDeploy, :parent_node}, nil) ||
      Application.get_env(:beam_deploy, :__parent_node__)
  end

  defp keep_log(lines), do: Enum.take(lines, 80)
end
