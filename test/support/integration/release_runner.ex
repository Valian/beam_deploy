defmodule BeamDeploy.Test.ReleaseRunner do
  @moduledoc false

  defstruct [:env, :http_port, :node_name, :cookie, :release_name, :release_root]

  @doc """
  Starts a built release as a daemon.

  Options:
    - `:port` — HTTP port (required)
    - `:id` — unique suffix for node name (default: random)
    - `:release_name` — release script name, defaults to the release root basename
    - `:beam_deploy` — set BeamDeploy env wiring, defaults to `true`
    - `:env` — extra environment variables
  """
  def start(release_root, opts) do
    http_port = Keyword.fetch!(opts, :port)
    id = Keyword.get(opts, :id, System.unique_integer([:positive]))
    release_name = Keyword.get(opts, :release_name, Path.basename(release_root))
    cookie = "beam_deploy_test_#{id}"
    node_name = "#{release_name}_#{id}@127.0.0.1"
    bin = Path.join(release_root, "bin/#{release_name}")
    beam_deploy? = Keyword.get(opts, :beam_deploy, true)

    env =
      [
        {"PORT", "#{http_port}"},
        {"RELEASE_NODE", node_name},
        {"RELEASE_COOKIE", cookie},
        {"RELEASE_DISTRIBUTION", "name"}
      ] ++
        if beam_deploy? do
          [
            {"BEAM_DEPLOY", "true"},
            {"BEAM_DEPLOY_PEER_HOST", "127.0.0.1"}
          ]
        else
          []
        end ++ Keyword.get(opts, :env, [])

    # Use Port.open instead of System.cmd because daemon inherits stdout fd
    # and System.cmd blocks waiting for it to close
    port =
      Port.open({:spawn_executable, String.to_charlist(bin)}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: [~c"daemon"],
        env: Enum.map(env, fn {k, v} -> {~c"#{k}", ~c"#{v}"} end)
      ])

    # Wait for the daemon launcher to exit
    receive do
      {^port, {:exit_status, 0}} -> :ok
      {^port, {:exit_status, code}} -> raise "Failed to start release (exit #{code})"
    after
      10_000 ->
        Port.close(port)
        :ok
    end

    %__MODULE__{
      http_port: http_port,
      node_name: node_name,
      cookie: cookie,
      release_name: release_name,
      release_root: release_root,
      env: env
    }
  end

  @doc """
  Waits until the release responds to HTTP on the given port.
  """
  def wait_for_http(runner, timeout \\ 30_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_for_http(runner, deadline)
  end

  defp do_wait_for_http(runner, deadline) do
    if System.monotonic_time(:millisecond) > deadline do
      raise "Release did not become reachable within timeout"
    end

    case http_get(runner, "/health") do
      {:ok, _} ->
        :ok

      _ ->
        Process.sleep(200)
        do_wait_for_http(runner, deadline)
    end
  end

  @doc """
  Executes an RPC expression on the running release node.
  Wraps the expression in IO.inspect so stdout captures the result.
  """
  def rpc(runner, expression) do
    bin = Path.join(runner.release_root, "bin/#{runner.release_name}")

    case System.cmd(bin, ["rpc", "IO.inspect(#{expression})"],
           env: runner.env,
           stderr_to_stdout: true
         ) do
      {output, 0} -> {:ok, String.trim(output)}
      {output, code} -> {:error, {code, String.trim(output)}}
    end
  end

  @doc """
  Stops the running release.
  """
  def stop(runner) do
    bin = Path.join(runner.release_root, "bin/#{runner.release_name}")
    System.cmd(bin, ["stop"], env: runner.env, stderr_to_stdout: true)

    # Wait for the node to actually go down
    wait_until_dead(runner, 10_000)
  end

  defp wait_until_dead(runner, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout

    do_wait_until_dead(runner, deadline)
  end

  defp do_wait_until_dead(runner, deadline) do
    if System.monotonic_time(:millisecond) > deadline do
      # Force kill via pid command
      bin = Path.join(runner.release_root, "bin/#{runner.release_name}")

      case System.cmd(bin, ["pid"], env: runner.env, stderr_to_stdout: true) do
        {pid_str, 0} ->
          pid = String.trim(pid_str)
          System.cmd("kill", ["-9", pid])

        _ ->
          :ok
      end
    else
      bin = Path.join(runner.release_root, "bin/#{runner.release_name}")

      case System.cmd(bin, ["pid"], env: runner.env, stderr_to_stdout: true) do
        {_, 0} ->
          Process.sleep(200)
          do_wait_until_dead(runner, deadline)

        _ ->
          :ok
      end
    end
  end

  @doc """
  Makes an HTTP GET request using raw TCP. Returns `{:ok, body}` or `{:error, reason}`.
  """
  def http_get(runner, path) do
    http_get_raw("127.0.0.1", runner.http_port, path)
  end

  def http_get_raw(host, port, path) do
    with {:ok, socket} <- :gen_tcp.connect(~c"#{host}", port, [:binary, active: false], 2_000),
         :ok <- :gen_tcp.send(socket, "GET #{path} HTTP/1.0\r\nHost: #{host}\r\n\r\n"),
         {:ok, response} <- recv_all(socket) do
      :gen_tcp.close(socket)
      parse_http_response(response)
    end
  end

  defp recv_all(socket, acc \\ "") do
    case :gen_tcp.recv(socket, 0, 5_000) do
      {:ok, data} -> recv_all(socket, acc <> data)
      {:error, :closed} -> {:ok, acc}
      {:error, reason} -> {:error, reason}
    end
  end

  defp parse_http_response(response) do
    case String.split(response, "\r\n\r\n", parts: 2) do
      [headers, body] ->
        case Regex.run(~r/HTTP\/[\d.]+ (\d+)/, headers) do
          [_, "200"] -> {:ok, body}
          [_, code] -> {:error, {:http, String.to_integer(code), body}}
          nil -> {:error, :bad_response}
        end

      _ ->
        {:error, :bad_response}
    end
  end
end
