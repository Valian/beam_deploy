defmodule BeamDeploy.TestSupport do
  @moduledoc false
  def start_user_supervisor do
    Supervisor.start_link(
      [
        {Agent, fn -> :ok end}
      ],
      strategy: :one_for_one
    )
  end
end

defmodule BeamDeployTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  setup do
    :persistent_term.erase({BeamDeploy, :parent_node})
    :persistent_term.erase({BeamDeploy.PeerManager, :upgrading})

    Application.delete_env(:beam_deploy, :enabled)
    Application.delete_env(:beam_deploy, :peer_host)
    Application.delete_env(:beam_deploy, :__role__)
    Application.delete_env(:beam_deploy, :__parent_node__)
    Application.delete_env(:beam_deploy, :__incoming_peer__)
    Application.delete_env(:beam_deploy, :__outgoing_peer__)

    System.delete_env("BEAM_DEPLOY")
    System.delete_env("BEAM_DEPLOY_PEER_HOST")

    on_exit(fn ->
      if pid = Process.whereis(BeamDeploy.PeerManager) do
        if Process.alive?(pid) do
          capture_log(fn ->
            try do
              GenServer.stop(pid, :normal, 15_000)
            catch
              :exit, _ -> :ok
            end
          end)
        end
      else
        :ok
      end

      :persistent_term.erase({BeamDeploy, :parent_node})
      :persistent_term.erase({BeamDeploy.PeerManager, :upgrading})
      Application.delete_env(:beam_deploy, :enabled)
      Application.delete_env(:beam_deploy, :peer_host)
      Application.delete_env(:beam_deploy, :__role__)
      Application.delete_env(:beam_deploy, :__parent_node__)
      Application.delete_env(:beam_deploy, :__incoming_peer__)
      Application.delete_env(:beam_deploy, :__outgoing_peer__)
      System.delete_env("BEAM_DEPLOY")
      System.delete_env("BEAM_DEPLOY_PEER_HOST")
    end)

    :ok
  end

  test "start_link falls back to the user start callback when disabled" do
    {:ok, pid} =
      BeamDeploy.start_link(
        otp_app: :beam_deploy,
        start: {BeamDeploy.TestSupport, :start_user_supervisor, []}
      )

    on_exit(fn ->
      if Process.alive?(pid) do
        try do
          Supervisor.stop(pid)
        catch
          :exit, _ -> :ok
        end
      end
    end)

    assert [{Agent, _child, :worker, [Agent]}] = Supervisor.which_children(pid)
    assert BeamDeploy.status() == %{active_node: nil, upgrading: false}
  end

  test "start_link wraps the user supervisor with the sentinel on peer nodes" do
    Application.put_env(:beam_deploy, :__role__, :peer)
    Application.put_env(:beam_deploy, :__parent_node__, :parent@localhost)

    {:ok, pid} =
      BeamDeploy.start_link(
        otp_app: :beam_deploy,
        start: {BeamDeploy.TestSupport, :start_user_supervisor, []}
      )

    on_exit(fn ->
      if Process.alive?(pid) do
        try do
          Supervisor.stop(pid)
        catch
          :exit, _ -> :ok
        end
      end
    end)

    children = Supervisor.which_children(pid)
    ids = Enum.map(children, fn {id, _child, _type, _modules} -> id end)

    assert BeamDeploy.Sentinel in ids
    assert :user_app in ids
  end

  test "enabled? reads both env and app config" do
    refute BeamDeploy.enabled?()

    System.put_env("BEAM_DEPLOY", "true")
    assert BeamDeploy.enabled?()

    System.delete_env("BEAM_DEPLOY")
    Application.put_env(:beam_deploy, :enabled, true)
    assert BeamDeploy.enabled?()
  end

  test "public helpers work against a running peer manager" do
    capture_log(fn ->
      assert {:ok, _pid} =
               BeamDeploy.PeerManager.start_link(otp_app: :logger, shutdown_timeout: 1_000)
    end)

    status = BeamDeploy.status()

    assert is_atom(status.active_node)
    assert status.active_node == BeamDeploy.peer_node()
    refute BeamDeploy.upgrading?()

    assert :ok = BeamDeploy.put_handoff(:sample, 123)
    assert 123 == BeamDeploy.get_handoff(:sample)
    assert %{sample: 123} = BeamDeploy.get_all_handoff()
  end

  test "upgrade reports a missing tarball without leaving the manager stuck" do
    capture_log(fn ->
      assert {:ok, _pid} =
               BeamDeploy.PeerManager.start_link(otp_app: :logger, shutdown_timeout: 1_000)
    end)

    assert {:error, :release_not_found} = BeamDeploy.upgrade("/tmp/does-not-exist.tar.gz")
    refute BeamDeploy.upgrading?()
  end

  test "concurrent upgrades reject queued callers while one request is waiting on the manager" do
    capture_log(fn ->
      assert {:ok, _pid} =
               BeamDeploy.PeerManager.start_link(otp_app: :logger, shutdown_timeout: 1_000)
    end)

    :sys.suspend(BeamDeploy.PeerManager)

    task =
      Task.async(fn ->
        BeamDeploy.upgrade("/tmp/does-not-exist.tar.gz")
      end)

    wait_until(&BeamDeploy.upgrading?/0)

    assert {:error, :upgrade_in_progress} = BeamDeploy.upgrade("/tmp/does-not-exist.tar.gz")

    :sys.resume(BeamDeploy.PeerManager)

    assert {:error, :release_not_found} = Task.await(task)
    refute BeamDeploy.upgrading?()
  end

  test "cleanup_extract_dirs keeps the newest numbered release extracts" do
    root_dir = Path.join(System.tmp_dir!(), "beam_deploy_cleanup_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root_dir)

    on_exit(fn -> File.rm_rf(root_dir) end)

    oldest = Path.join(root_dir, "beam_deploy_bg_9")
    keep_a = Path.join(root_dir, "beam_deploy_bg_10")
    keep_b = Path.join(root_dir, "beam_deploy_bg_11")
    keep_c = Path.join(root_dir, "beam_deploy_bg_12")

    Enum.each([oldest, keep_a, keep_b, keep_c], &File.mkdir_p!/1)

    assert [^oldest] = BeamDeploy.PeerManager.cleanup_extract_dirs(root_dir)
    refute File.exists?(oldest)
    assert File.dir?(keep_a)
    assert File.dir?(keep_b)
    assert File.dir?(keep_c)
  end

  test "incoming_peer and outgoing_peer expose runtime wiring" do
    Application.put_env(:beam_deploy, :__incoming_peer__, :next@localhost)
    Application.put_env(:beam_deploy, :__outgoing_peer__, :prev@localhost)

    assert BeamDeploy.incoming_peer() == :next@localhost
    assert BeamDeploy.outgoing_peer() == :prev@localhost
  end

  defp wait_until(fun, timeout_ms \\ 1_000)

  defp wait_until(fun, timeout_ms) when timeout_ms <= 0 do
    assert fun.()
  end

  defp wait_until(fun, timeout_ms) do
    if fun.() do
      :ok
    else
      Process.sleep(10)
      wait_until(fun, timeout_ms - 10)
    end
  end
end
