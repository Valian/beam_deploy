defmodule BeamDeploy.Integration.ReleaseSwapTest do
  use ExUnit.Case, async: false

  alias BeamDeploy.Test.ReleaseBuilder
  alias BeamDeploy.Test.ReleaseRunner

  @moduletag :integration
  @moduletag timeout: 300_000

  setup_all do
    port = find_free_port()

    IO.puts("\n[Integration] Building release v1...")
    {root_v1, tarball_v1, work_dir_v1} = ReleaseBuilder.build("0.1.0", "v1")

    IO.puts("[Integration] Building release v2...")
    {_root_v2, tarball_v2, work_dir_v2} = ReleaseBuilder.build("0.2.0", "v2")

    on_exit(fn ->
      ReleaseBuilder.cleanup(work_dir_v1)
      ReleaseBuilder.cleanup(work_dir_v2)
    end)

    %{
      root_v1: root_v1,
      tarball_v1: tarball_v1,
      tarball_v2: tarball_v2,
      port: port
    }
  end

  test "upgrade swaps the active peer with zero downtime", ctx do
    runner = ReleaseRunner.start(ctx.root_v1, port: ctx.port)

    on_exit(fn ->
      try do
        ReleaseRunner.stop(runner)
      rescue
        _ -> :ok
      end
    end)

    # Wait for the release to boot
    IO.puts("[Integration] Waiting for v1 to boot...")
    ReleaseRunner.wait_for_http(runner)

    # Confirm v1 is serving
    assert {:ok, "v1"} = ReleaseRunner.http_get(runner, "/version")

    # Start burst requester during upgrade
    burst_ref = start_burst_requester(runner)

    # Trigger upgrade via RPC
    IO.puts("[Integration] Triggering upgrade to v2...")
    {:ok, rpc_result} = ReleaseRunner.rpc(runner, ~s|BeamDeploy.upgrade("#{ctx.tarball_v2}")|)

    assert rpc_result =~ ":ok" or rpc_result == ":ok",
           "Expected :ok from upgrade, got: #{rpc_result}"

    # Wait for v2 to be serving
    IO.puts("[Integration] Waiting for v2 to become active...")

    wait_until(
      fn ->
        case ReleaseRunner.http_get(runner, "/version") do
          {:ok, "v2"} -> true
          _ -> false
        end
      end,
      timeout: 30_000
    )

    assert {:ok, "v2"} = ReleaseRunner.http_get(runner, "/version")

    # Stop burst requester and check results
    results = stop_burst_requester(burst_ref)
    errors = Enum.filter(results, &match?({:error, _}, &1))

    IO.puts("[Integration] Burst results: #{length(results)} total, #{length(errors)} errors")

    assert errors == [],
           "Expected zero connection errors during upgrade, got: #{inspect(errors)}"

    versions = results |> Enum.filter(&match?({:ok, _}, &1)) |> Enum.map(fn {:ok, v} -> v end)
    assert "v1" in versions, "Expected to see v1 in burst responses"
    assert "v2" in versions, "Expected to see v2 in burst responses"

    # Check handoff data
    IO.puts("[Integration] Checking handoff data...")

    wait_until(
      fn ->
        case ReleaseRunner.http_get(runner, "/handoff") do
          {:ok, "none"} -> false
          {:ok, _body} -> true
          _ -> false
        end
      end,
      timeout: 10_000
    )

    {:ok, handoff_body} = ReleaseRunner.http_get(runner, "/handoff")
    assert handoff_body =~ "v1", "Handoff data should contain v1 version, got: #{handoff_body}"

    # Check status settled
    {:ok, status_output} = ReleaseRunner.rpc(runner, "BeamDeploy.status()")

    assert status_output =~ "upgrading: false",
           "Expected upgrading: false in status, got: #{status_output}"

    IO.puts("[Integration] Test passed!")
  end

  defp find_free_port do
    {:ok, socket} = :gen_tcp.listen(0, reuseaddr: true)
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end

  defp wait_until(fun, opts) do
    timeout = Keyword.get(opts, :timeout, 10_000)
    interval = Keyword.get(opts, :interval, 200)
    deadline = System.monotonic_time(:millisecond) + timeout

    do_wait_until(fun, deadline, interval)
  end

  defp do_wait_until(fun, deadline, interval) do
    if fun.() do
      :ok
    else
      if System.monotonic_time(:millisecond) > deadline do
        flunk("wait_until timed out")
      end

      Process.sleep(interval)
      do_wait_until(fun, deadline, interval)
    end
  end

  defp start_burst_requester(runner) do
    parent = self()
    ref = make_ref()

    pid =
      spawn_link(fn ->
        burst_loop(runner, parent, ref, [])
      end)

    {pid, ref}
  end

  defp burst_loop(runner, parent, ref, acc) do
    receive do
      {:stop, ^ref} ->
        send(parent, {:burst_results, ref, Enum.reverse(acc)})
    after
      1 ->
        result = ReleaseRunner.http_get(runner, "/version")
        burst_loop(runner, parent, ref, [result | acc])
    end
  end

  defp stop_burst_requester({pid, ref}) do
    send(pid, {:stop, ref})

    receive do
      {:burst_results, ^ref, results} -> results
    after
      5_000 -> flunk("burst requester did not respond")
    end
  end
end
