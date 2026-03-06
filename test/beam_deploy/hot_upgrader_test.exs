defmodule BeamDeploy.HotUpgraderTest do
  use ExUnit.Case, async: false

  alias BeamDeploy.HotUpgrader
  alias BeamDeploy.TestSupport.HotServer

  test "BeamDeploy.hot_upgrade/2 returns a clean error for a missing tarball" do
    assert {:error, :release_not_found} =
             BeamDeploy.hot_upgrade("/tmp/does-not-exist.tar.gz", otp_app: :beam_deploy)
  end

  test "find_processes_to_upgrade/1 finds GenServer processes by module" do
    {:ok, pid} = start_supervised({HotServer, [value: 1]})

    assert [{^pid, HotServer}] = HotUpgrader.find_processes_to_upgrade([HotServer])
  end

  test "has_nif?/1 detects NIF-backed modules" do
    assert HotUpgrader.has_nif?(:crypto)
    refute HotUpgrader.has_nif?(HotServer)
  end

  test "safe_upgrade_modules/2 always resumes processes when code_change fails" do
    {:ok, pid} = start_supervised({HotServer, [mode: :fail, value: 7]})

    assert {:error, {:upgrade_failed, stats}} =
             HotUpgrader.safe_upgrade_modules([HotServer], suspend_timeout: 500)

    assert stats.processes_failed == 1
    assert HotServer.ping(pid) == :pong
    assert HotServer.snapshot(pid) == %{mode: :fail, value: 7}
  end

  test "safe_upgrade_modules/2 always resumes processes when module reload fails" do
    {:ok, pid} = start_supervised({HotServer, [value: 9]})

    beam_path = HotServer |> :code.which() |> List.to_string()
    backup_path = beam_path <> ".bak"

    File.rename!(beam_path, backup_path)

    on_exit(fn ->
      if File.exists?(backup_path) do
        File.rename!(backup_path, beam_path)
      end
    end)

    assert {:error, {:upgrade_failed, stats}} =
             HotUpgrader.safe_upgrade_modules([HotServer], suspend_timeout: 500)

    assert match?({:beam_read_failed, HotServer, ^beam_path, :enoent}, stats.reload_failure)
    assert HotServer.ping(pid) == :pong
  end
end
