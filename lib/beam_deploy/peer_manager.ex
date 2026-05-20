defmodule BeamDeploy.PeerManager do
  @moduledoc false

  use GenServer

  require Logger

  @handoff_table :beam_deploy_handoff
  @state_table :beam_deploy_state
  @keep_dirs 3

  defstruct [
    :otp_app,
    :endpoint,
    :shutdown_timeout,
    :before_cutover,
    :after_cutover,
    :active_peer,
    :active_node,
    :active_ref
  ]

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      shutdown: :infinity
    }
  end

  def upgrade(tarball_path) when is_binary(tarball_path) do
    if Process.whereis(__MODULE__) == nil do
      {:error, :not_running}
    else
      case begin_upgrade() do
        :ok ->
          try do
            GenServer.call(__MODULE__, {:upgrade, tarball_path}, :infinity)
          catch
            :exit, _ -> {:error, :not_running}
          after
            finish_upgrade()
          end

        :busy ->
          {:error, :upgrade_in_progress}

        :not_running ->
          {:error, :not_running}
      end
    end
  end

  def upgrading? do
    case :ets.lookup(@state_table, :upgrading) do
      [{:upgrading, true}] -> true
      _ -> false
    end
  catch
    :error, :badarg -> false
  end

  def peer_node do
    GenServer.call(__MODULE__, :peer_node)
  catch
    :exit, _ -> nil
  end

  def get_info do
    GenServer.call(__MODULE__, :get_info, 5_000)
  catch
    :exit, _ -> %{active_node: nil, upgrading: false}
  end

  @doc false
  def put_handoff(key, value) do
    :ets.insert(@handoff_table, {key, value})
    :ok
  end

  @doc false
  def get_handoff(key) do
    case :ets.lookup(@handoff_table, key) do
      [{^key, value}] -> value
      [] -> nil
    end
  end

  @doc false
  def get_all_handoff do
    @handoff_table |> :ets.tab2list() |> Map.new()
  end

  @doc false
  def clear_handoff do
    :ets.delete_all_objects(@handoff_table)
    :ok
  end

  @impl true
  def init(opts) do
    :ets.new(@handoff_table, [:named_table, :public, :set, write_concurrency: true])
    :ets.new(@state_table, [:named_table, :public, :set, read_concurrency: true, write_concurrency: true])

    state = %__MODULE__{
      otp_app: Keyword.fetch!(opts, :otp_app),
      endpoint: Keyword.get(opts, :endpoint) || detect_endpoint(Keyword.fetch!(opts, :otp_app)),
      shutdown_timeout: Keyword.get(opts, :shutdown_timeout),
      before_cutover: Keyword.get(opts, :before_cutover),
      after_cutover: Keyword.get(opts, :after_cutover)
    }

    {peer_pid, peer_node} =
      start_peer(
        state.otp_app,
        current_code_paths(),
        release_dir: find_current_release_dir(),
        endpoint: state.endpoint
      )

    ref = Process.monitor(peer_pid)
    cleanup_old_extract_dirs()
    {:ok, %{state | active_peer: peer_pid, active_node: peer_node, active_ref: ref}}
  end

  @impl true
  def handle_call(:peer_node, _from, state) do
    {:reply, state.active_node, state}
  end

  def handle_call(:get_info, _from, state) do
    {:reply, %{active_node: state.active_node, upgrading: upgrading?()}, state}
  end

  def handle_call({:upgrade, tarball_path}, _from, state) do
    case do_upgrade(tarball_path, state) do
      {:ok, new_state} -> {:reply, :ok, new_state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{active_ref: ref} = state) do
    Logger.error("[BeamDeploy.PeerManager] Active peer #{state.active_node} died: #{inspect(reason)}")

    {:stop, {:peer_died, reason}, state}
  end

  @impl true
  def terminate(reason, state) do
    if state.active_peer do
      Logger.info("[BeamDeploy.PeerManager] Stopping active peer because parent is terminating: #{inspect(reason)}")

      graceful_stop_peer(state.active_peer, state.active_node, state.shutdown_timeout)
    end

    :ok
  end

  defp do_upgrade(tarball_path, state) do
    Logger.info("[BeamDeploy.PeerManager] Starting upgrade from #{tarball_path}")
    clear_handoff()
    do_upgrade_inner(tarball_path, state)
  end

  defp do_upgrade_inner(tarball_path, state) do
    with {:ok, code_paths, release_dir} <- extract_release(tarball_path),
         {:ok, peer_pid, peer_node} <-
           start_new_peer(
             state.otp_app,
             code_paths,
             release_dir,
             state.endpoint,
             state.active_node
           ) do
      Process.demonitor(state.active_ref, [:flush])
      new_ref = Process.monitor(peer_pid)

      set_incoming_peer(state.active_node, peer_node)
      arm_sentinel(state.before_cutover, state.active_node, peer_node)

      graceful_stop_peer(state.active_peer, state.active_node, state.shutdown_timeout)

      handoff_state = get_handoff(:__before_cutover_result__)
      release_root = release_dir |> Path.dirname() |> Path.dirname()
      cleanup_old_extract_dirs([release_root])
      invoke_after_cutover(state.after_cutover, peer_node, handoff_state)

      Logger.info("[BeamDeploy.PeerManager] Upgrade complete. Active peer: #{peer_node}")

      {:ok, %{state | active_peer: peer_pid, active_node: peer_node, active_ref: new_ref}}
    end
  end

  defp extract_release(tarball_path) do
    if File.regular?(tarball_path) do
      tmp_dir =
        Path.join(System.tmp_dir!(), "beam_deploy_bg_#{System.unique_integer([:positive, :monotonic])}")

      File.mkdir_p!(tmp_dir)

      try do
        :ok =
          :erl_tar.extract(String.to_charlist(tarball_path), [:compressed, {:cwd, ~c"#{tmp_dir}"}])

        with {:ok, release_root, release_dir} <- find_extracted_release(tmp_dir),
             code_paths when code_paths != [] <-
               Path.wildcard(Path.join([release_root, "lib", "*", "ebin"])) do
          ensure_nif_files(release_root)
          {:ok, code_paths, release_dir}
        else
          [] -> {:error, :invalid_release}
          error -> error
        end
      rescue
        error ->
          File.rm_rf(tmp_dir)
          {:error, {:extract_failed, Exception.message(error)}}
      end
    else
      {:error, :release_not_found}
    end
  end

  defp find_extracted_release(tmp_dir) do
    case Path.wildcard(Path.join([tmp_dir, "**", "releases", "*", "sys.config"])) do
      [sys_config | _] ->
        release_dir = Path.dirname(sys_config)
        release_root = release_dir |> Path.dirname() |> Path.dirname()

        if File.dir?(Path.join(release_root, "lib")) do
          {:ok, release_root, release_dir}
        else
          {:error, :invalid_release}
        end

      [] ->
        {:error, :invalid_release}
    end
  end

  defp start_new_peer(otp_app, code_paths, release_dir, endpoint, active_node) do
    opts =
      Enum.reject([release_dir: release_dir, endpoint: endpoint, active_node: active_node], fn {_key, value} ->
        is_nil(value)
      end)

    try do
      {peer_pid, peer_node} = start_peer(otp_app, code_paths, opts)
      {:ok, peer_pid, peer_node}
    rescue
      error -> {:error, {:peer_start_failed, Exception.message(error)}}
    end
  end

  defp start_peer(otp_app, code_paths, opts) do
    cookie = Node.get_cookie()
    gen = System.unique_integer([:positive])
    peer_host = peer_host()
    longnames = longnames?()

    peer_opts = %{
      name: :"#{otp_app}_peer_#{gen}",
      host: String.to_charlist(peer_host),
      longnames: longnames,
      exec: {find_erl(), build_exec_args(Keyword.get(opts, :release_dir))},
      args: [~c"-setcookie", ~c"#{cookie}"] ++ code_path_args(code_paths)
    }

    {:ok, pid, node} = :peer.start(peer_opts)

    {:ok, _} = :erpc.call(node, :application, :ensure_all_started, [:elixir])
    {:ok, _} = :erpc.call(node, :application, :ensure_all_started, [:logger])

    if release_dir = Keyword.get(opts, :release_dir) do
      load_release_config(node, release_dir)
    end

    :erpc.call(node, Application, :put_env, [:beam_deploy, :__role__, :peer, [persistent: true]])

    :erpc.call(node, Application, :put_env, [
      :beam_deploy,
      :__parent_node__,
      node(),
      [persistent: true]
    ])

    if endpoint = Keyword.get(opts, :endpoint) do
      inject_reuseport(node, otp_app, endpoint)
    end

    if active_node = Keyword.get(opts, :active_node) do
      :erpc.call(node, Node, :connect, [active_node], 5_000)

      :erpc.call(node, Application, :put_env, [
        :beam_deploy,
        :__outgoing_peer__,
        active_node,
        [persistent: true]
      ])
    end

    case :erpc.call(node, :application, :ensure_all_started, [otp_app], 120_000) do
      {:ok, _started} ->
        {pid, node}

      {:error, {failed_app, reason}} ->
        stop_peer(pid, node)
        raise "failed to start #{failed_app}: #{inspect(reason)}"
    end
  rescue
    error ->
      if binding()[:pid] do
        stop_peer(binding()[:pid], binding()[:node])
      end

      reraise error, __STACKTRACE__
  end

  defp code_path_args(code_paths) do
    Enum.flat_map(code_paths, fn path -> [~c"-pa", String.to_charlist(path)] end)
  end

  defp graceful_stop_peer(peer_pid, peer_node, shutdown_timeout) do
    Logger.info("[BeamDeploy.PeerManager] Sending :init.stop() to #{peer_node}")
    ref = Process.monitor(peer_pid)

    try do
      :erpc.call(peer_node, :init, :stop, [], 5_000)
    catch
      :exit, _ -> :ok
    end

    receive do
      {:DOWN, ^ref, :process, ^peer_pid, _reason} ->
        :ok
    after
      shutdown_timeout || :infinity ->
        Logger.warning("[BeamDeploy.PeerManager] Forcing peer shutdown for #{peer_node}")
        stop_peer(peer_pid, peer_node)
    end

    Process.demonitor(ref, [:flush])
  end

  defp stop_peer(peer_pid, _peer_node) do
    :peer.stop(peer_pid)
  catch
    :exit, _ -> :ok
  end

  defp set_incoming_peer(outgoing_node, incoming_node) do
    :erpc.call(
      outgoing_node,
      Application,
      :put_env,
      [:beam_deploy, :__incoming_peer__, incoming_node, [persistent: true]],
      5_000
    )
  catch
    _, _ -> :ok
  end

  defp arm_sentinel(nil, _outgoing_node, _incoming_node), do: :ok

  defp arm_sentinel(mfa, outgoing_node, incoming_node) do
    :erpc.call(outgoing_node, BeamDeploy.Sentinel, :arm, [mfa, incoming_node], 5_000)
  catch
    _, _ -> :ok
  end

  defp invoke_after_cutover(nil, _peer_node, _handoff_state), do: :ok

  defp invoke_after_cutover({mod, fun, args}, peer_node, handoff_state) do
    Task.Supervisor.start_child(BeamDeploy.TaskSupervisor, fn ->
      :erpc.call(peer_node, mod, fun, [handoff_state | args])
    end)
  end

  defp current_code_paths do
    :code.get_path()
    |> Enum.map(&List.to_string/1)
    |> Enum.filter(&String.contains?(&1, "/ebin"))
  end

  @doc false
  def cleanup_extract_dirs(root_dir \\ System.tmp_dir!(), keep_paths \\ []) do
    keep_paths = Enum.map(keep_paths, &Path.expand/1)

    dirs =
      root_dir
      |> extract_dirs_to_cleanup()
      |> Enum.reject(&(Path.expand(&1) in keep_paths))

    Enum.each(dirs, &File.rm_rf!/1)
    dirs
  end

  defp cleanup_old_extract_dirs(keep_paths \\ []) do
    cleanup_extract_dirs(System.tmp_dir!(), keep_paths)
  end

  @doc false
  def extract_dirs_to_cleanup(root_dir \\ System.tmp_dir!()) do
    root_dir
    |> Path.join("beam_deploy_bg_*")
    |> Path.wildcard()
    |> Enum.filter(&File.dir?/1)
    |> Enum.sort_by(&extract_dir_sort_key/1, :desc)
    |> Enum.drop(@keep_dirs)
  end

  defp begin_upgrade do
    if :ets.insert_new(@state_table, {:upgrading, true}) do
      :ok
    else
      :busy
    end
  catch
    :error, :badarg -> :not_running
  end

  defp finish_upgrade do
    :ets.delete(@state_table, :upgrading)
    :ok
  catch
    :error, :badarg -> :ok
  end

  defp extract_dir_sort_key(path) do
    basename = Path.basename(path)

    case Integer.parse(String.replace_prefix(basename, "beam_deploy_bg_", "")) do
      {suffix, ""} -> {1, suffix}
      _ -> {0, path}
    end
  end

  defp ensure_nif_files(release_root) do
    parent_lib = :code.root_dir() |> to_string() |> Path.join("lib")
    extracted_lib = Path.join(release_root, "lib")

    for app_dir <- Path.wildcard(Path.join(extracted_lib, "*")), File.dir?(app_dir) do
      parent_app = Path.join(parent_lib, Path.basename(app_dir))

      if File.dir?(parent_app) do
        parent_nifs =
          [parent_app, "priv", "**", "*.{so,so.*,dylib}"]
          |> Path.join()
          |> Path.wildcard()
          |> Enum.filter(&File.regular?/1)

        for nif_file <- parent_nifs do
          relative = Path.relative_to(nif_file, parent_app)
          dest = Path.join(app_dir, relative)

          if !File.exists?(dest) do
            File.mkdir_p!(Path.dirname(dest))
            File.cp!(nif_file, dest)
          end
        end
      end
    end
  end

  @doc false
  def do_inject_reuseport(otp_app, endpoint) do
    config = Application.get_env(otp_app, endpoint, [])
    http_config = Keyword.get(config, :http, [])
    ti_opts = Keyword.get(http_config, :thousand_island_options, [])
    transport_opts = Keyword.get(ti_opts, :transport_options, [])

    transport_opts = Keyword.merge(transport_opts, reuseport: true, reuseaddr: true)
    ti_opts = Keyword.put(ti_opts, :transport_options, transport_opts)
    http_config = Keyword.put(http_config, :thousand_island_options, ti_opts)
    config = Keyword.put(config, :http, http_config)

    Application.put_env(otp_app, endpoint, config, persistent: true)
  end

  defp inject_reuseport(node, otp_app, endpoint) do
    :erpc.call(node, __MODULE__, :do_inject_reuseport, [otp_app, endpoint])
  catch
    _, _ -> :ok
  end

  @doc false
  def do_load_release_config(release_dir) do
    sys_config_path = Path.join(release_dir, "sys.config")
    config_env = load_compile_time_config(sys_config_path)

    runtime_path = Path.join(release_dir, "runtime.exs")

    if File.exists?(runtime_path) do
      deep_merge = fn deep_merge, left, right ->
        if Keyword.keyword?(left) and Keyword.keyword?(right) do
          Keyword.merge(left, right, fn _key, old, new -> deep_merge.(deep_merge, old, new) end)
        else
          right
        end
      end

      for {app, kvs} <- Config.Reader.read!(runtime_path, env: config_env) do
        for {key, value} <- kvs do
          case Application.fetch_env(app, key) do
            {:ok, existing} when is_list(existing) and is_list(value) ->
              Application.put_env(app, key, deep_merge.(deep_merge, existing, value), persistent: true)

            _ ->
              Application.put_env(app, key, value, persistent: true)
          end
        end
      end
    end
  end

  defp load_compile_time_config(sys_config_path) do
    if File.exists?(sys_config_path) do
      case :file.consult(String.to_charlist(sys_config_path)) do
        {:ok, [configs]} when is_list(configs) ->
          for {app, kvs} <- configs, is_atom(app), is_list(kvs) do
            for {key, value} <- kvs,
                key not in [:config_providers, :config_provider_init] do
              Application.put_env(app, key, value, persistent: true)
            end
          end

          extract_config_env(configs) || :prod

        _ ->
          :prod
      end
    else
      :prod
    end
  end

  defp load_release_config(node, release_dir) do
    :erpc.call(node, __MODULE__, :do_load_release_config, [release_dir])
  catch
    _, _ -> :ok
  end

  defp extract_config_env(configs) do
    with {:ok, elixir_kvs} <- Keyword.fetch(configs, :elixir),
         {:ok, %{providers: [_ | _] = providers}} <-
           Keyword.fetch(elixir_kvs, :config_provider_init),
         {Config.Reader, {_path, provider_opts}} <- List.first(providers),
         {:ok, env} <- Keyword.fetch(provider_opts, :env) do
      env
    else
      _ -> nil
    end
  end

  defp build_exec_args(nil) do
    root = to_string(:code.root_dir())

    [
      ~c"-boot",
      find_start_clean_boot(nil),
      ~c"-boot_var",
      ~c"RELEASE_LIB",
      String.to_charlist(Path.join(root, "lib"))
    ]
  end

  defp build_exec_args(release_dir) do
    args = build_exec_args(nil)
    args |> maybe_add_config(release_dir) |> maybe_add_vm_args(release_dir)
  end

  defp maybe_add_config(args, release_dir) do
    sys_config = Path.join(release_dir, "sys.config")

    if File.exists?(sys_config) do
      stripped = strip_config_providers(sys_config)

      args ++
        [~c"-config", stripped |> String.replace_trailing(".config", "") |> String.to_charlist()]
    else
      args
    end
  end

  defp maybe_add_vm_args(args, release_dir) do
    vm_args = Path.join(release_dir, "vm.args")

    if File.exists?(vm_args) do
      args ++ [~c"-args_file", String.to_charlist(vm_args)]
    else
      args
    end
  end

  defp strip_config_providers(sys_config_path) do
    case :file.consult(String.to_charlist(sys_config_path)) do
      {:ok, [configs]} when is_list(configs) ->
        stripped =
          Enum.map(configs, fn
            {app, kvs} when is_atom(app) and is_list(kvs) ->
              {app, kvs |> Keyword.delete(:config_providers) |> Keyword.delete(:config_provider_init)}

            other ->
              other
          end)

        tmp_path =
          Path.join(
            System.tmp_dir!(),
            "beam_deploy_peer_#{System.unique_integer([:positive])}.config"
          )

        content = ~c"~p.~n" |> :io_lib.format([stripped]) |> IO.iodata_to_binary()
        File.write!(tmp_path, content)
        tmp_path

      _ ->
        sys_config_path
    end
  end

  defp find_current_release_dir do
    root = to_string(:code.root_dir())

    case Path.wildcard(Path.join([root, "releases", "*", "sys.config"])) do
      [sys_config | _] -> Path.dirname(sys_config)
      [] -> nil
    end
  end

  defp find_erl do
    erts_vsn = :version |> :erlang.system_info() |> to_string()
    root = to_string(:code.root_dir())
    [root, "erts-#{erts_vsn}", "bin", "erl"] |> Path.join() |> String.to_charlist()
  end

  defp find_start_clean_boot(nil) do
    root = to_string(:code.root_dir())

    case Path.wildcard(Path.join([root, "releases", "*", "start_clean.boot"])) do
      [path | _] -> path |> String.replace_trailing(".boot", "") |> String.to_charlist()
      [] -> ~c"start_clean"
    end
  end

  defp find_start_clean_boot(release_dir) do
    path = Path.join(release_dir, "start_clean.boot")

    if File.exists?(path) do
      path |> String.replace_trailing(".boot", "") |> String.to_charlist()
    else
      find_start_clean_boot(nil)
    end
  end

  defp detect_endpoint(otp_app) do
    app_name = otp_app |> Atom.to_string() |> Macro.camelize()
    endpoint_module = Module.concat([:"#{app_name}Web", :Endpoint])

    if Code.ensure_loaded?(endpoint_module) do
      endpoint_module
    end
  end

  defp peer_host do
    Application.get_env(:beam_deploy, :peer_host) ||
      System.get_env("BEAM_DEPLOY_PEER_HOST") ||
      parent_node_host() ||
      "127.0.0.1"
  end

  defp longnames? do
    case :net_kernel.longnames() do
      true -> true
      false -> false
      :ignored -> String.contains?(peer_host(), ".")
    end
  end

  defp parent_node_host do
    case Node.self() |> Atom.to_string() |> String.split("@", parts: 2) do
      [_name, host] when host != "nohost" -> host
      _ -> nil
    end
  end
end
