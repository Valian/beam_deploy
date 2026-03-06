defmodule BeamDeploy.Integration.HotUpgradeTest do
  use ExUnit.Case, async: false

  alias BeamDeploy.Test.ReleaseBuilder
  alias BeamDeploy.Test.ReleaseRunner

  @moduletag :integration
  @moduletag timeout: 300_000

  setup_all do
    port = find_free_port()

    {root_v1, _tarball_v1, work_dir_v1} =
      ReleaseBuilder.build("0.1.0", "v1",
        fixture: "hot_release_app",
        env: [
          {"FIXTURE_STATE_LABEL", "v1"},
          {"FIXTURE_ENABLE_NEW_MODULE", "false"}
        ]
      )

    {_root_v2, tarball_v2, work_dir_v2} =
      ReleaseBuilder.build("0.2.0", "v2",
        fixture: "hot_release_app",
        env: [
          {"FIXTURE_STATE_LABEL", "v2"},
          {"FIXTURE_ENABLE_NEW_MODULE", "true"}
        ]
      )

    on_exit(fn ->
      ReleaseBuilder.cleanup(work_dir_v1)
      ReleaseBuilder.cleanup(work_dir_v2)
    end)

    %{port: port, root_v1: root_v1, tarball_v2: tarball_v2}
  end

  test "hot_upgrade keeps the same process alive and migrates state", ctx do
    runner =
      ReleaseRunner.start(ctx.root_v1,
        port: ctx.port,
        beam_deploy: false,
        release_name: "hot_release_app"
      )

    on_exit(fn ->
      try do
        ReleaseRunner.stop(runner)
      rescue
        _ -> :ok
      end
    end)

    ReleaseRunner.wait_for_http(runner)

    assert {:ok, "v1"} = ReleaseRunner.http_get(runner, "/version")
    assert {:ok, "#PID" <> _ = original_pid} = ReleaseRunner.http_get(runner, "/pid")
    assert {:ok, "missing"} = ReleaseRunner.http_get(runner, "/new-module")

    {:ok, initial_state} = ReleaseRunner.http_get(runner, "/state")
    assert initial_state =~ "label: \"v1\""
    assert initial_state =~ "migrations: 0"

    {:ok, rpc_result} =
      ReleaseRunner.rpc(
        runner,
        ~s|BeamDeploy.hot_upgrade("#{ctx.tarball_v2}", otp_app: :hot_release_app)|
      )

    assert rpc_result =~ ":ok"

    wait_until(
      fn ->
        match?({:ok, "v2"}, ReleaseRunner.http_get(runner, "/version")) and
          match?({:ok, "new-module-loaded"}, ReleaseRunner.http_get(runner, "/new-module"))
      end,
      timeout: 30_000
    )

    assert {:ok, "v2"} = ReleaseRunner.http_get(runner, "/version")
    assert {:ok, ^original_pid} = ReleaseRunner.http_get(runner, "/pid")
    assert {:ok, "new-module-loaded"} = ReleaseRunner.http_get(runner, "/new-module")

    {:ok, upgraded_state} = ReleaseRunner.http_get(runner, "/state")
    assert upgraded_state =~ "label: \"v2\""
    assert upgraded_state =~ "previous_label: \"v1\""
    assert upgraded_state =~ "migrations: 1"
    assert upgraded_state =~ "version: \"v2\""
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
end
