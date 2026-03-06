defmodule BeamDeploy.HotUpgrader do
  @moduledoc """
  In-process hot upgrades from local `mix release` tarballs.

  This path reloads code inside the currently running node instead of starting
  a replacement peer. It is intended for compatible code changes only.

  Hot upgrades are appropriate when:

  - processes can survive `code_change/3`
  - the supervision tree shape is unchanged
  - the running node and tarball use the same Erlang/OTP version

  Hot upgrades are not supported for:

  - supervision tree topology changes
  - Erlang/OTP upgrades
  - NIF upgrades
  - major runtime config topology changes
  """

  require Logger

  @default_suspend_timeout 3_000

  @type upgrade_stats :: %{
          copied_modules: non_neg_integer(),
          copied_new_modules: non_neg_integer(),
          copied_consolidated_protocols: non_neg_integer(),
          module_names: [String.t()],
          modules_reloaded: non_neg_integer(),
          process_failures: [map()],
          process_names: [String.t()],
          processes_failed: non_neg_integer(),
          processes_skipped: non_neg_integer(),
          processes_succeeded: non_neg_integer(),
          skipped_nif_modules: [module()],
          suspend_duration_ms: non_neg_integer()
        }

  @doc """
  Applies a hot upgrade from a local release tarball.

  ## Options

  - `:suspend_timeout` - timeout in milliseconds for suspending each process
    before code change, defaults to `#{@default_suspend_timeout}`
  """
  @spec hot_upgrade(Path.t(), atom(), keyword()) :: {:ok, upgrade_stats()} | {:error, term()}
  def hot_upgrade(tarball_path, otp_app, opts \\ [])
      when is_binary(tarball_path) and is_atom(otp_app) and is_list(opts) do
    if File.regular?(tarball_path) do
      do_hot_upgrade(tarball_path, otp_app, opts)
    else
      {:error, :release_not_found}
    end
  rescue
    error ->
      Logger.error("""
      [#{inspect(__MODULE__)}] Hot upgrade failed
        App: #{inspect(otp_app)}
        Tarball: #{tarball_path}
        Error: #{Exception.message(error)}
      """)

      {:error, {:hot_upgrade_failed, Exception.message(error)}}
  end

  @doc false
  @spec safe_upgrade(keyword()) :: {:ok, map()} | {:error, term()}
  def safe_upgrade(opts \\ []) when is_list(opts) do
    all_changed = :code.modified_modules()
    {nif_modules, changed_modules} = Enum.split_with(all_changed, &has_nif?/1)

    safe_upgrade_modules(
      changed_modules,
      Keyword.update(opts, :skipped_nif_modules, nif_modules, &Enum.uniq(&1 ++ nif_modules))
    )
  end

  @doc false
  @spec safe_upgrade_modules([module()], keyword()) :: {:ok, map()} | {:error, term()}
  def safe_upgrade_modules(changed_modules, opts \\ []) when is_list(changed_modules) and is_list(opts) do
    suspend_timeout = Keyword.get(opts, :suspend_timeout, @default_suspend_timeout)
    consolidated_paths = Keyword.get(opts, :consolidated_paths, [])

    {nif_modules, changed_modules} =
      Enum.split_with(Enum.uniq(changed_modules), &has_nif?/1)

    skipped_nif_modules =
      opts
      |> Keyword.get(:skipped_nif_modules, [])
      |> Kernel.++(nif_modules)
      |> Enum.uniq()

    if skipped_nif_modules != [] do
      Logger.info(
        "[#{inspect(__MODULE__)}] Skipping #{length(skipped_nif_modules)} NIF modules: #{inspect(skipped_nif_modules)}"
      )
    end

    processes = find_processes_to_upgrade(changed_modules)
    suspend_start = System.monotonic_time(:millisecond)

    suspended_processes =
      processes
      |> Task.async_stream(
        fn {pid, module} -> suspend_process(pid, module, suspend_timeout) end,
        max_concurrency: 100,
        timeout: suspend_timeout + 1_000,
        on_timeout: :kill_task
      )
      |> Enum.map(fn
        {:ok, result} -> result
        {:exit, reason} -> {:error, nil, nil, reason}
      end)

    successfully_suspended =
      Enum.filter(suspended_processes, fn
        {:ok, _pid, _module} -> true
        _ -> false
      end)

    processes_skipped = length(suspended_processes) - length(successfully_suspended)

    outcome =
      try do
        with :ok <- reload_modules(changed_modules),
             :ok <- reload_consolidated_protocols(consolidated_paths) do
          change_code_results = change_code(successfully_suspended)
          {:ok, change_code_results}
        end
      after
        successfully_suspended
        |> Task.async_stream(
          fn {:ok, pid, module} -> resume_process(pid, module) end,
          max_concurrency: 100,
          timeout: 8_000,
          on_timeout: :kill_task
        )
        |> Stream.run()
      end

    suspend_duration_ms = System.monotonic_time(:millisecond) - suspend_start

    build_safe_upgrade_result(
      outcome,
      changed_modules,
      skipped_nif_modules,
      processes_skipped,
      suspend_duration_ms
    )
  end

  @doc false
  @spec find_processes_to_upgrade([module()]) :: [{pid(), module()}]
  def find_processes_to_upgrade(changed_modules) when is_list(changed_modules) do
    changed_modules = MapSet.new(changed_modules)

    Process.list()
    |> Enum.reduce([], fn pid, acc ->
      case Process.info(pid, [:dictionary]) do
        [dictionary: dictionary] ->
          case Keyword.get(dictionary, :"$initial_call") do
            {module, _function, _arity} ->
              if MapSet.member?(changed_modules, module) do
                [{pid, module} | acc]
              else
                acc
              end

            _ ->
              acc
          end

        _ ->
          acc
      end
    end)
    |> Enum.uniq()
  end

  @doc false
  @spec has_nif?(module()) :: boolean()
  def has_nif?(module) when is_atom(module) do
    case module.module_info(:nifs) do
      [] -> false
      [_ | _] -> true
    end
  rescue
    _ -> false
  catch
    _, _ -> false
  end

  @doc false
  @spec beam_file_changed?(Path.t(), module()) :: boolean()
  def beam_file_changed?(tarball_beam_path, module_name) when is_binary(tarball_beam_path) and is_atom(module_name) do
    case :beam_lib.md5(String.to_charlist(tarball_beam_path)) do
      {:ok, {_module, tarball_md5}} ->
        case :code.get_object_code(module_name) do
          {^module_name, binary, _filename} ->
            case :beam_lib.md5(binary) do
              {:ok, {^module_name, loaded_md5}} -> tarball_md5 != loaded_md5
              _ -> true
            end

          _ ->
            true
        end

      _ ->
        true
    end
  end

  defp do_hot_upgrade(tarball_path, otp_app, opts) do
    ensure_loaded_application!(otp_app)

    tmp_dir = unique_tmp_dir("beam_deploy_hot")
    File.mkdir_p!(tmp_dir)

    try do
      :ok =
        :erl_tar.extract(String.to_charlist(tarball_path), [
          :compressed,
          {:cwd, String.to_charlist(tmp_dir)}
        ])

      with {:ok, release_root, _release_dir} <- find_extracted_release(tmp_dir),
           {:ok, copy_result} <- copy_release_beams(release_root, otp_app),
           :ok <- load_new_modules(copy_result.new_modules),
           {:ok, consolidated_paths} <- copy_consolidated_protocols(release_root) do
        safe_opts = Keyword.put(opts, :consolidated_paths, consolidated_paths)

        safe_opts =
          Keyword.update(
            safe_opts,
            :skipped_nif_modules,
            copy_result.skipped_nif_modules,
            &Enum.uniq(&1 ++ copy_result.skipped_nif_modules)
          )

        safe_result = safe_upgrade(safe_opts)
        merge_copy_result(safe_result, copy_result, consolidated_paths)
      end
    after
      File.rm_rf(tmp_dir)
    end
  end

  defp ensure_loaded_application!(otp_app) do
    case Application.spec(otp_app) do
      nil -> raise ArgumentError, "application #{inspect(otp_app)} is not loaded"
      _ -> :ok
    end
  end

  defp unique_tmp_dir(prefix) do
    Path.join(System.tmp_dir!(), "#{prefix}_#{System.unique_integer([:positive])}")
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

  defp copy_release_beams(release_root, otp_app) do
    beam_files = Path.wildcard(Path.join([release_root, "lib", "*", "ebin", "*.beam"]))

    result =
      Enum.reduce(beam_files, empty_copy_result(), fn tarball_beam_path, acc ->
        module_name =
          tarball_beam_path
          |> Path.basename(".beam")
          |> String.to_atom()

        if has_nif?(module_name) and beam_file_changed?(tarball_beam_path, module_name) do
          Logger.info("[#{inspect(__MODULE__)}] Skipping NIF module upgrade for #{inspect(module_name)}")

          %{acc | skipped_nif_modules: [module_name | acc.skipped_nif_modules]}
        else
          maybe_copy_beam(acc, tarball_beam_path, module_name, otp_app)
        end
      end)

    {:ok,
     %{
       result
       | skipped_nif_modules: Enum.uniq(result.skipped_nif_modules),
         new_modules: Enum.reverse(result.new_modules)
     }}
  end

  defp empty_copy_result do
    %{
      copied_modules: 0,
      new_modules: [],
      skipped_nif_modules: []
    }
  end

  defp maybe_copy_beam(acc, tarball_beam_path, module_name, otp_app) do
    case resolve_loaded_beam_path(module_name) do
      {:existing, loaded_path} ->
        if beam_file_changed?(tarball_beam_path, module_name) do
          File.cp!(tarball_beam_path, loaded_path)
          %{acc | copied_modules: acc.copied_modules + 1}
        else
          acc
        end

      :new ->
        dest_path = target_path_for_new_module(tarball_beam_path, otp_app)
        File.mkdir_p!(Path.dirname(dest_path))
        File.cp!(tarball_beam_path, dest_path)

        %{
          acc
          | copied_modules: acc.copied_modules + 1,
            new_modules: [{module_name, dest_path} | acc.new_modules]
        }
    end
  end

  defp resolve_loaded_beam_path(module_name) do
    case :code.which(module_name) do
      path when is_list(path) and path != [] ->
        loaded_path = List.to_string(path)

        if loaded_path != "" and File.dir?(Path.dirname(loaded_path)) do
          {:existing, loaded_path}
        else
          :new
        end

      _ ->
        :new
    end
  end

  defp target_path_for_new_module(tarball_beam_path, otp_app) do
    app =
      tarball_beam_path
      |> Path.dirname()
      |> Path.dirname()
      |> Path.basename()
      |> String.split("-", parts: 2)
      |> hd()
      |> String.to_atom()

    target_dir =
      try do
        Application.app_dir(app, "ebin")
      rescue
        ArgumentError -> Application.app_dir(otp_app, "ebin")
      end

    Path.join(target_dir, Path.basename(tarball_beam_path))
  end

  defp load_new_modules(new_modules) do
    Enum.reduce_while(new_modules, :ok, fn {module_name, beam_path}, :ok ->
      case File.read(beam_path) do
        {:ok, beam_binary} ->
          case :code.load_binary(module_name, String.to_charlist(beam_path), beam_binary) do
            {:module, ^module_name} ->
              Logger.info("[#{inspect(__MODULE__)}] Loaded new module #{inspect(module_name)}")
              {:cont, :ok}

            {:error, reason} ->
              {:halt, {:error, {:load_binary_failed, module_name, reason}}}
          end

        {:error, reason} ->
          {:halt, {:error, {:beam_read_failed, module_name, beam_path, reason}}}
      end
    end)
  end

  defp copy_consolidated_protocols(release_root) do
    releases_dir = Path.join(to_string(:code.root_dir()), "releases")

    copied_paths =
      [release_root, "releases", "*", "consolidated", "*.beam"]
      |> Path.join()
      |> Path.wildcard()
      |> Enum.map(fn tarball_beam_path ->
        relative_path = Path.relative_to(tarball_beam_path, release_root)
        target_path = Path.join(releases_dir, String.replace_prefix(relative_path, "releases/", ""))

        File.mkdir_p!(Path.dirname(target_path))
        File.cp!(tarball_beam_path, target_path)
        target_path
      end)

    {:ok, copied_paths}
  end

  defp reload_modules(changed_modules) do
    Enum.reduce_while(changed_modules, :ok, fn module, :ok ->
      :code.purge(module)

      with {:ok, path, beam_binary} <- load_binary_from_disk(module),
           {:module, ^module} <- :code.load_binary(module, path, beam_binary) do
        {:cont, :ok}
      else
        {:error, reason} ->
          {:halt, {:error, reason}}

        {:error, reason, _loaded} ->
          {:halt, {:error, {:load_binary_failed, module, reason}}}
      end
    end)
  end

  defp load_binary_from_disk(module) do
    case :code.which(module) do
      path when is_list(path) and path != [] ->
        beam_path = List.to_string(path)

        case File.read(beam_path) do
          {:ok, beam_binary} -> {:ok, path, beam_binary}
          {:error, reason} -> {:error, {:beam_read_failed, module, beam_path, reason}}
        end

      other ->
        {:error, {:module_path_not_found, module, other}}
    end
  end

  defp reload_consolidated_protocols(paths) do
    Enum.reduce_while(paths, :ok, fn beam_path, :ok ->
      module_name =
        beam_path
        |> Path.basename(".beam")
        |> String.to_atom()

      case File.read(beam_path) do
        {:ok, beam_binary} ->
          :code.purge(module_name)

          case :code.load_binary(module_name, String.to_charlist(beam_path), beam_binary) do
            {:module, ^module_name} ->
              {:cont, :ok}

            {:error, reason} ->
              {:halt, {:error, {:load_binary_failed, module_name, reason}}}

            {:error, reason, _loaded} ->
              {:halt, {:error, {:load_binary_failed, module_name, reason}}}
          end

        {:error, reason} ->
          {:halt, {:error, {:beam_read_failed, module_name, beam_path, reason}}}
      end
    end)
  end

  defp change_code(successfully_suspended) do
    Enum.map(successfully_suspended, fn {:ok, pid, module} ->
      try do
        case :sys.change_code(pid, module, :undefined, []) do
          :ok ->
            {:ok, pid, module}

          {:ok, _state} ->
            {:ok, pid, module}

          {:error, reason} ->
            {:error, pid, module, reason}
        end
      rescue
        error ->
          {:error, pid, module, error}
      catch
        :exit, reason ->
          {:error, pid, module, reason}
      end
    end)
  end

  defp suspend_process(pid, module, suspend_timeout) do
    :sys.suspend(pid, suspend_timeout)
    {:ok, pid, module}
  catch
    :exit, reason ->
      log_stuck_process(pid, module, :suspend, reason)
      {:error, pid, module, reason}
  end

  defp resume_process(pid, module) do
    case :sys.get_status(pid, 1_000) do
      {:status, ^pid, _, [_, :suspended | _]} ->
        :sys.resume(pid, 3_000)

      {:status, ^pid, _, _} ->
        :ok
    end
  catch
    :exit, {:noproc, _} ->
      :ok

    :exit, reason ->
      log_stuck_process(pid, module, :resume, reason)
  end

  defp build_safe_upgrade_result(outcome, changed_modules, skipped_nif_modules, processes_skipped, suspend_duration_ms) do
    module_names = Enum.map(changed_modules, &inspect/1)

    case outcome do
      {:ok, change_code_results} ->
        successful_processes =
          change_code_results
          |> Enum.filter(&match?({:ok, _pid, _module}, &1))
          |> Enum.map(fn {:ok, _pid, module} -> inspect(module) end)
          |> Enum.uniq()

        successful_count =
          Enum.count(change_code_results, fn
            {:ok, _pid, _module} -> true
            _ -> false
          end)

        process_failures =
          Enum.flat_map(change_code_results, fn
            {:error, pid, module, reason} ->
              [%{pid: pid, module: module, reason: format_process_reason(reason)}]

            _ ->
              []
          end)

        stats = %{
          module_names: module_names,
          modules_reloaded: length(changed_modules),
          process_failures: process_failures,
          process_names: successful_processes,
          processes_failed: length(process_failures),
          processes_skipped: processes_skipped,
          processes_succeeded: successful_count,
          skipped_nif_modules: skipped_nif_modules,
          suspend_duration_ms: suspend_duration_ms
        }

        if process_failures == [] do
          {:ok, stats}
        else
          {:error, {:upgrade_failed, stats}}
        end

      {:error, reason} ->
        stats = %{
          module_names: module_names,
          modules_reloaded: 0,
          process_failures: [],
          process_names: [],
          processes_failed: 0,
          processes_skipped: processes_skipped,
          processes_succeeded: 0,
          skipped_nif_modules: skipped_nif_modules,
          suspend_duration_ms: suspend_duration_ms
        }

        {:error, {:upgrade_failed, Map.put(stats, :reload_failure, reason)}}
    end
  end

  defp merge_copy_result({:ok, safe_stats}, copy_result, consolidated_paths) do
    {:ok,
     Map.merge(safe_stats, %{
       copied_consolidated_protocols: length(consolidated_paths),
       copied_modules: copy_result.copied_modules,
       copied_new_modules: length(copy_result.new_modules)
     })}
  end

  defp merge_copy_result({:error, {:upgrade_failed, safe_stats}}, copy_result, consolidated_paths) do
    {:error,
     {:upgrade_failed,
      Map.merge(safe_stats, %{
        copied_consolidated_protocols: length(consolidated_paths),
        copied_modules: copy_result.copied_modules,
        copied_new_modules: length(copy_result.new_modules)
      })}}
  end

  defp format_process_reason(%_{} = exception), do: Exception.message(exception)
  defp format_process_reason(reason), do: inspect(reason)

  defp log_stuck_process(pid, module, operation, reason) do
    process_info =
      case Process.info(pid, [:current_function, :current_stacktrace, :message_queue_len, :status]) do
        nil ->
          "process dead"

        info ->
          current_fn = Keyword.get(info, :current_function)
          stack = Keyword.get(info, :current_stacktrace, [])
          queue_len = Keyword.get(info, :message_queue_len, 0)
          status = Keyword.get(info, :status)

          stack_str =
            stack
            |> Enum.take(5)
            |> Enum.map_join("\n        ", fn {mod, fun, arity, location} ->
              file = Keyword.get(location, :file, ~c"?")
              line = Keyword.get(location, :line, 0)
              "#{mod}.#{fun}/#{arity} (#{file}:#{line})"
            end)

          "status=#{status}, queue_len=#{queue_len}, current_function=#{inspect(current_fn)}\n      stacktrace:\n        #{stack_str}"
      end

    Logger.warning(
      "[#{inspect(__MODULE__)}] Failed to #{operation} #{inspect(pid)} (#{inspect(module)}): #{inspect(reason)} - #{process_info}"
    )
  end
end
