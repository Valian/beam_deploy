defmodule BeamDeploy.Test.ReleaseBuilder do
  @moduledoc false

  @fixture_path Path.expand("../../fixtures/release_app", __DIR__)
  @beam_deploy_root Path.expand("../../..", __DIR__)

  @doc """
  Builds a release of the fixture app with the given version strings.

  Returns `{release_root, tarball_path}` on success.
  """
  def build(app_version, response_version) do
    work_dir = Path.join(System.tmp_dir!(), "beam_deploy_test_build_#{System.unique_integer([:positive])}")
    File.mkdir_p!(work_dir)

    copy_fixture(work_dir)
    fix_beam_deploy_path(work_dir)

    env = [
      {"FIXTURE_APP_VERSION", app_version},
      {"FIXTURE_RESPONSE_VERSION", response_version},
      {"MIX_ENV", "prod"},
      {"MIX_BUILD_ROOT", Path.join(work_dir, "_build")},
      {"MIX_DEPS_PATH", Path.join(work_dir, "deps")}
    ]

    run_cmd("mix", ["deps.get", "--only", "prod"], work_dir, env)
    run_cmd("mix", ["release", "--overwrite"], work_dir, env)

    release_root = Path.join([work_dir, "_build", "prod", "rel", "release_app"])

    tarball_glob = Path.join([work_dir, "_build", "prod", "release_app-#{app_version}.tar.gz"])

    tarball_path =
      case Path.wildcard(tarball_glob) do
        [path | _] ->
          path

        [] ->
          # Try alternative location
          alt = Path.join([release_root, "releases", app_version, "release_app.tar.gz"])
          if File.regular?(alt), do: alt, else: raise("tarball not found at #{tarball_glob} or #{alt}")
      end

    {release_root, tarball_path, work_dir}
  end

  def cleanup(work_dir) do
    File.rm_rf!(work_dir)
  end

  defp copy_fixture(dest) do
    File.cp_r!(@fixture_path, dest, on_conflict: fn _source, _dest -> true end)
  end

  defp fix_beam_deploy_path(work_dir) do
    mix_exs = Path.join(work_dir, "mix.exs")
    content = File.read!(mix_exs)
    updated = String.replace(content, ~s|path: "../../.."|, ~s|path: "#{@beam_deploy_root}"|)
    File.write!(mix_exs, updated)
  end

  defp run_cmd(cmd, args, cd, env) do
    case System.cmd(cmd, args, cd: cd, env: env, stderr_to_stdout: true) do
      {_output, 0} ->
        :ok

      {output, code} ->
        raise """
        Command failed (exit #{code}): #{cmd} #{Enum.join(args, " ")}
        Working directory: #{cd}
        Output:
        #{output}
        """
    end
  end
end
