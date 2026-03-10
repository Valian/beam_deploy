defmodule BeamDeploy do
  @moduledoc """
  Blue-green release swaps and in-process hot upgrades for a single Elixir node.

  `BeamDeploy` keeps a long-lived parent node running locally and serves traffic
  from a child peer node started with OTP's `:peer` module. When you hand the
  parent a new `mix release` tarball, it boots a new peer with the new release,
  lets both peers overlap on the same socket via `SO_REUSEPORT`, then gracefully
  shuts down the old one.

  The package is intentionally small:

  - no storage, polling, or orchestration layer
  - no Docker or platform coupling
  - local tarball input only

  You copy a release tarball onto the host and call either:

  - `BeamDeploy.upgrade/1` for a blue-green peer swap
  - `BeamDeploy.hot_upgrade/2` for an in-process hot code reload

  ## Integration

      defmodule MyApp.Application do
        use Application

        def start(type, args) do
          BeamDeploy.start_link(
            otp_app: :my_app,
            start: {__MODULE__, :start_app, [type, args]},
            endpoint: MyAppWeb.Endpoint
          )
        end

        def start_app(_type, _args) do
          children = [MyApp.Repo, MyAppWeb.Endpoint]
          Supervisor.start_link(children, strategy: :one_for_one, name: MyApp.Supervisor)
        end
      end

  Enable parent/peer mode in production with either:

      config :beam_deploy, enabled: true

  or:

      BEAM_DEPLOY=true

  In environments where BeamDeploy is not enabled, `start_link/1` and
  `start_link/2` just call your `start_app` MFA directly.

  ## Upgrades

      BeamDeploy.upgrade("/tmp/my_app-0.2.0.tar.gz")
      # => :ok

      BeamDeploy.hot_upgrade("/tmp/my_app-0.2.0.tar.gz", otp_app: :my_app)
      # => :ok

  The tarball must be a standard `mix release` archive built with the same OTP
  version as the running node.

  Hot upgrades are only safe for compatible code changes. Use a cold deploy or
  the blue-green path instead when changing supervision tree shape, upgrading
  Erlang/OTP, changing major runtime topology, or touching NIFs.
  """

  require Logger

  @doc """
  Starts BeamDeploy with optional parent-level children.

  Parent children run on the long-lived parent node before the peer manager.
  This is useful for services that should not restart on every cutover.
  """
  @spec start_link([Supervisor.child_spec()], keyword()) :: Supervisor.on_start()
  def start_link(children, opts) when is_list(children) and is_list(opts) do
    do_start_link(children, opts)
  end

  @doc """
  Starts BeamDeploy without parent-level children.
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) when is_list(opts) do
    do_start_link([], opts)
  end

  @doc """
  Returns `true` when BeamDeploy parent/peer mode is enabled for this runtime.
  """
  @spec enabled?() :: boolean()
  def enabled? do
    truthy?(System.get_env("BEAM_DEPLOY")) || Application.get_env(:beam_deploy, :enabled, false)
  end

  @doc """
  Performs a blue-green upgrade from a local release tarball path.

  The call can be made from either the parent or active peer node.
  """
  @spec upgrade(Path.t()) :: :ok | {:error, term()}
  def upgrade(tarball_path) when is_binary(tarball_path) do
    call_peer_manager(:upgrade, [tarball_path], {:error, :not_running})
  end

  @doc """
  Performs an in-process hot upgrade from a local release tarball path.

  This path does not depend on the parent/peer runtime. It reloads code inside
  the current node, suspends affected processes, runs `code_change/3`, and
  resumes them.

  Supported changes are limited to compatible hot-code updates built with the
  same Erlang/OTP version. NIF upgrades are skipped.
  """
  @spec hot_upgrade(Path.t(), keyword()) :: :ok | {:error, term()}
  def hot_upgrade(tarball_path, opts) when is_binary(tarball_path) and is_list(opts) do
    otp_app = Keyword.fetch!(opts, :otp_app)

    case BeamDeploy.HotUpgrader.hot_upgrade(tarball_path, otp_app, opts) do
      {:ok, _stats} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Returns the current blue-green status map.
  """
  @spec status() :: %{active_node: node() | nil, upgrading: boolean()}
  def status do
    case call_peer_manager(:get_info, [], nil) do
      nil -> %{active_node: nil, upgrading: false}
      info -> info
    end
  end

  @doc """
  Returns `true` if a release swap is currently running.
  """
  @spec upgrading?() :: boolean()
  def upgrading? do
    case call_peer_manager(:upgrading?, [], false) do
      value when is_boolean(value) -> value
      _ -> false
    end
  end

  @doc """
  Returns the active peer node, or `nil` when BeamDeploy is not running.
  """
  @spec peer_node() :: node() | nil
  def peer_node do
    call_peer_manager(:peer_node, [], nil)
  end

  @doc """
  Stores handoff data that survives peer transitions.
  """
  @spec put_handoff(term(), term()) :: :ok
  def put_handoff(key, value) do
    call_peer_manager(:put_handoff, [key, value], :ok)
  end

  @doc """
  Reads handoff data from the parent node.
  """
  @spec get_handoff(term()) :: term() | nil
  def get_handoff(key) do
    call_peer_manager(:get_handoff, [key], nil)
  end

  @doc """
  Returns all handoff data as a map.
  """
  @spec get_all_handoff() :: map()
  def get_all_handoff do
    call_peer_manager(:get_all_handoff, [], %{})
  end

  @doc """
  Returns the incoming replacement peer for the current peer, if one exists.
  """
  @spec incoming_peer() :: node() | nil
  def incoming_peer do
    Application.get_env(:beam_deploy, :__incoming_peer__)
  end

  @doc """
  Returns the outgoing peer being replaced by the current peer, if one exists.
  """
  @spec outgoing_peer() :: node() | nil
  def outgoing_peer do
    Application.get_env(:beam_deploy, :__outgoing_peer__)
  end

  defp do_start_link(children, opts) do
    {mod, fun, args} = Keyword.fetch!(opts, :start)
    otp_app = Keyword.fetch!(opts, :otp_app)

    cond do
      Application.get_env(:beam_deploy, :__role__) == :peer ->
        start_as_peer(mod, fun, args)

      enabled?() ->
        start_as_parent(otp_app, children, opts)

      true ->
        apply(mod, fun, args)
    end
  end

  defp start_as_peer(mod, fun, args) do
    if parent = Application.get_env(:beam_deploy, :__parent_node__) do
      :persistent_term.put({__MODULE__, :parent_node}, parent)
    end

    Supervisor.start_link(
      [
        BeamDeploy.Sentinel,
        %{id: :user_app, start: {mod, fun, args}, type: :supervisor, shutdown: :infinity}
      ],
      strategy: :one_for_one,
      name: BeamDeploy.PeerSupervisor
    )
  end

  defp start_as_parent(otp_app, children, opts) do
    if !Node.alive?() do
      raise ArgumentError,
            "BeamDeploy requires a distributed node. Start the release with name/sname distribution enabled."
    end

    Logger.info("[BeamDeploy] Starting parent node for #{otp_app}")

    BeamDeploy.Supervisor.start_link(
      otp_app: otp_app,
      children: children,
      endpoint: Keyword.get(opts, :endpoint),
      shutdown_timeout: Keyword.get(opts, :shutdown_timeout),
      before_cutover: Keyword.get(opts, :before_cutover),
      after_cutover: Keyword.get(opts, :after_cutover)
    )
  end

  defp call_peer_manager(function, args, fallback) do
    parent = parent_node()

    cond do
      is_atom(parent) and parent != node() ->
        case remote_peer_manager_call(parent, function, args) do
          {:ok, result} -> result
          :error -> local_peer_manager_call(function, args, fallback)
        end

      Process.whereis(BeamDeploy.PeerManager) ->
        apply(BeamDeploy.PeerManager, function, args)

      true ->
        fallback
    end
  catch
    :exit, _ -> fallback
    _, _ -> fallback
  end

  defp remote_peer_manager_call(parent, function, args) do
    {:ok, :erpc.call(parent, BeamDeploy.PeerManager, function, args)}
  catch
    :exit, _ -> :error
    _, _ -> :error
  end

  defp local_peer_manager_call(function, args, fallback) do
    if Process.whereis(BeamDeploy.PeerManager) do
      apply(BeamDeploy.PeerManager, function, args)
    else
      fallback
    end
  end

  defp parent_node do
    case :persistent_term.get({__MODULE__, :parent_node}, nil) do
      node when is_atom(node) and node != nil -> node
      _ -> Application.get_env(:beam_deploy, :__parent_node__)
    end
  end

  defp truthy?(value) when value in [nil, "", "0"], do: false

  defp truthy?(value) when is_binary(value) do
    value
    |> String.downcase()
    |> Kernel.in(["1", "true", "yes", "on"])
  end

  defp truthy?(value), do: value not in [false, nil]
end
