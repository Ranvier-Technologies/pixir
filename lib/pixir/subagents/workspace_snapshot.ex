defmodule Pixir.Subagents.WorkspaceSnapshot do
  @moduledoc """
  BEAM-local physical workspace snapshots for isolated Subagents.

  This module is the snapshot half of ADR 0011's isolated child workspace contract. It
  deliberately walks and copies with Elixir filesystem APIs instead of shelling out to
  `git`, `find`, or another host process. That keeps Subagent fanout aligned with ADR
  0027: BEAM coordination can scale broadly, while host-boundary crossings stay scarce
  and explicit.

  The first policy is intentionally conservative. It skips common dependency, build,
  cache, and Pixir runtime-state directories by basename at any depth, enforces copy
  limits, and returns string-keyed metadata/errors suitable for Tool results and Events.
  """

  @policy "recursive_denylist_v1"
  @excluded_dir_names ~w(.git .pixir _build deps node_modules dist .astro .vercel .next .turbo coverage .cache)
  @copy_chunk_bytes 64 * 1024
  @default_limits %{
    max_files: 20_000,
    max_bytes: 256 * 1024 * 1024,
    max_file_bytes: 64 * 1024 * 1024
  }
  @next_actions [
    "reduce_parent_workspace_size",
    "remove_generated_or_dependency_directories",
    "use_shared_workspace_for_read_only_delegation",
    "increase_subagent_snapshot_limits_if_intentional"
  ]

  @doc """
  Copy a bounded, policy-filtered snapshot from `src` into existing directory `dest`.

  Returns `{:ok, metadata}` when copying succeeds, or `{:error, details}` where
  `details` is a string-keyed map ready to embed inside a structured Tool error.
  """
  def copy(src, dest, opts \\ [])

  def copy(src, dest, opts) when is_binary(src) and is_binary(dest) do
    started_at = monotonic_ms()

    with {:ok, limits} <- limits(opts) do
      state = new_state(src, dest, limits)

      with :ok <- ensure_directory(src, "source"),
           :ok <- ensure_directory(dest, "destination"),
           {:ok, state} <- copy_dir(Path.expand(src), Path.expand(dest), state) do
        {:ok, metadata(state, elapsed_ms(started_at))}
      else
        {:error, details} when is_map(details) ->
          {:error, finalize_error(details, state, started_at)}

        {:error, reason} ->
          {:error,
           finalize_error(
             %{"reason" => "snapshot_copy_failed", "filesystem_reason" => inspect(reason)},
             state,
             started_at
           )}
      end
    else
      {:error, details} when is_map(details) ->
        state = new_state(src, dest, @default_limits)
        {:error, finalize_error(details, state, started_at)}
    end
  end

  def copy(_src, _dest, _opts) do
    {:error,
     %{
       "reason" => "snapshot_invalid_args",
       "message" => "workspace snapshot source and destination must be strings",
       "snapshot_policy" => @policy,
       "next_actions" => @next_actions
     }}
  end

  defp new_state(src, dest, limits) do
    %{
      root: Path.expand(src),
      dest_root: Path.expand(dest),
      files_copied: 0,
      dirs_skipped: 0,
      symlinks_skipped: 0,
      special_entries_skipped: 0,
      bytes_copied: 0,
      skipped_dirs_by_name: %{},
      limits: limits
    }
  end

  defp copy_dir(src_dir, dest_dir, state) do
    case File.ls(src_dir) do
      {:ok, entries} ->
        entries
        |> Enum.sort()
        |> Enum.reduce_while({:ok, state}, fn entry, {:ok, acc} ->
          src_path = Path.join(src_dir, entry)
          dest_path = Path.join(dest_dir, entry)

          case copy_entry(entry, src_path, dest_path, acc) do
            {:ok, next} -> {:cont, {:ok, next}}
            {:error, details} -> {:halt, {:error, details}}
          end
        end)

      {:error, reason} ->
        {:error,
         %{
           "reason" => "snapshot_read_failed",
           "path" => relative(src_dir, state.root),
           "filesystem_reason" => inspect(reason)
         }}
    end
  end

  defp copy_entry(entry, src_path, dest_path, state) do
    expanded_src_path = Path.expand(src_path)

    cond do
      expanded_src_path == state.dest_root ->
        {:ok, skip_directory(state, entry)}

      true ->
        copy_entry_stat(entry, src_path, dest_path, state)
    end
  end

  defp copy_entry_stat(entry, src_path, dest_path, state) do
    case File.lstat(src_path) do
      {:ok, %{type: :directory}} ->
        copy_directory(entry, src_path, dest_path, state)

      {:ok, %{type: :regular} = stat} ->
        copy_regular_file(src_path, dest_path, stat, state)

      {:ok, %{type: :symlink}} ->
        {:ok, %{state | symlinks_skipped: state.symlinks_skipped + 1}}

      {:ok, _stat} ->
        {:ok, %{state | special_entries_skipped: state.special_entries_skipped + 1}}

      {:error, reason} ->
        {:error,
         %{
           "reason" => "snapshot_lstat_failed",
           "path" => relative(src_path, state.root),
           "filesystem_reason" => inspect(reason)
         }}
    end
  end

  defp copy_directory(entry, _src_path, _dest_path, state) when entry in @excluded_dir_names do
    {:ok, skip_directory(state, entry)}
  end

  defp copy_directory(_entry, src_path, dest_path, state) do
    case File.mkdir_p(dest_path) do
      :ok ->
        copy_dir(src_path, dest_path, state)

      {:error, reason} ->
        {:error,
         %{
           "reason" => "snapshot_mkdir_failed",
           "path" => relative(dest_path, state.root),
           "filesystem_reason" => inspect(reason)
         }}
    end
  end

  defp skip_directory(state, entry) do
    %{
      state
      | dirs_skipped: state.dirs_skipped + 1,
        skipped_dirs_by_name: Map.update(state.skipped_dirs_by_name, entry, 1, &(&1 + 1))
    }
  end

  defp copy_regular_file(src_path, dest_path, %{size: size} = stat, state) do
    with :ok <- enforce_file_size(size, src_path, state),
         :ok <- enforce_file_count(src_path, state),
         :ok <- enforce_total_size(size, src_path, state),
         {:ok, bytes} <- copy_file_bounded(src_path, dest_path, stat.mode, state) do
      {:ok,
       %{
         state
         | files_copied: state.files_copied + 1,
           bytes_copied: state.bytes_copied + bytes
       }}
    else
      {:error, details} -> {:error, details}
    end
  end

  defp copy_file_bounded(src_path, dest_path, mode, state) do
    case File.open(src_path, [:read, :binary]) do
      {:ok, input} ->
        try do
          copy_file_bounded_with_input(input, src_path, dest_path, mode, state)
        after
          File.close(input)
        end

      {:error, reason} ->
        {:error, file_error("snapshot_file_open_failed", src_path, reason, state)}
    end
  end

  defp copy_file_bounded_with_input(input, src_path, dest_path, mode, state) do
    case File.open(dest_path, [:write, :binary]) do
      {:ok, output} ->
        result =
          try do
            copy_chunks(input, output, src_path, state, 0)
          after
            File.close(output)
          end

        case result do
          {:ok, bytes} ->
            with :ok <- preserve_mode(dest_path, mode) do
              {:ok, bytes}
            else
              {:error, reason} ->
                _ = File.rm(dest_path)
                {:error, file_error("snapshot_file_chmod_failed", src_path, reason, state)}
            end

          {:error, details} ->
            _ = File.rm(dest_path)
            {:error, details}
        end

      {:error, reason} ->
        {:error, file_error("snapshot_file_create_failed", src_path, reason, state)}
    end
  end

  defp copy_chunks(input, output, src_path, state, copied_bytes) do
    case IO.binread(input, @copy_chunk_bytes) do
      :eof ->
        {:ok, copied_bytes}

      {:error, reason} ->
        {:error, file_error("snapshot_file_read_failed", src_path, reason, state)}

      chunk when is_binary(chunk) ->
        next_file_bytes = copied_bytes + byte_size(chunk)
        next_total_bytes = state.bytes_copied + next_file_bytes

        cond do
          next_file_bytes > state.limits.max_file_bytes ->
            {:error,
             exceeded_error(
               "snapshot_max_file_bytes_exceeded",
               "max_file_bytes",
               state.limits.max_file_bytes,
               next_file_bytes,
               src_path,
               state
             )}

          next_total_bytes > state.limits.max_bytes ->
            {:error,
             exceeded_error(
               "snapshot_max_bytes_exceeded",
               "max_bytes",
               state.limits.max_bytes,
               next_total_bytes,
               src_path,
               state
             )}

          true ->
            case write_chunk(output, chunk, src_path, state) do
              :ok -> copy_chunks(input, output, src_path, state, next_file_bytes)
              {:error, details} -> {:error, details}
            end
        end
    end
  end

  defp write_chunk(output, chunk, src_path, state) do
    try do
      :ok = IO.binwrite(output, chunk)
    rescue
      exception ->
        {:error,
         file_error("snapshot_file_write_failed", src_path, Exception.message(exception), state)}
    catch
      kind, reason ->
        {:error, file_error("snapshot_file_write_failed", src_path, {kind, reason}, state)}
    end
  end

  defp file_error(reason_name, src_path, reason, state) do
    %{
      "reason" => reason_name,
      "path" => relative(src_path, state.root),
      "filesystem_reason" => inspect(reason)
    }
  end

  defp preserve_mode(path, mode) when is_integer(mode),
    do: File.chmod(path, Bitwise.band(mode, 0o777))

  defp preserve_mode(_path, _mode), do: :ok

  defp enforce_file_size(size, src_path, state) when size > state.limits.max_file_bytes do
    {:error,
     exceeded_error(
       "snapshot_max_file_bytes_exceeded",
       "max_file_bytes",
       state.limits.max_file_bytes,
       size,
       src_path,
       state
     )}
  end

  defp enforce_file_size(_size, _src_path, _state), do: :ok

  defp enforce_file_count(src_path, state)
       when state.files_copied + 1 > state.limits.max_files do
    {:error,
     exceeded_error(
       "snapshot_max_files_exceeded",
       "max_files",
       state.limits.max_files,
       state.files_copied + 1,
       src_path,
       state
     )}
  end

  defp enforce_file_count(_src_path, _state), do: :ok

  defp enforce_total_size(size, src_path, state)
       when state.bytes_copied + size > state.limits.max_bytes do
    {:error,
     exceeded_error(
       "snapshot_max_bytes_exceeded",
       "max_bytes",
       state.limits.max_bytes,
       state.bytes_copied + size,
       src_path,
       state
     )}
  end

  defp enforce_total_size(_size, _src_path, _state), do: :ok

  defp exceeded_error(reason, limit_name, limit, observed, src_path, state) do
    %{
      "reason" => reason,
      "limit" => limit,
      "limit_name" => limit_name,
      "observed" => observed,
      "path" => relative(src_path, state.root)
    }
  end

  defp ensure_directory(path, label) do
    if File.dir?(path) do
      :ok
    else
      {:error,
       %{
         "reason" => "snapshot_#{label}_not_directory",
         "path" => path
       }}
    end
  end

  defp limits(opts) when is_list(opts) do
    app_limits =
      :pixir
      |> Application.get_env(:subagents, [])
      |> Keyword.get(:snapshot_limits, [])

    with {:ok, app_limits} <- normalize_limits(app_limits),
         {:ok, opts_limits} <- opts |> Keyword.get(:limits, []) |> normalize_limits() do
      {:ok,
       @default_limits
       |> Map.merge(app_limits)
       |> Map.merge(opts_limits)}
    end
  end

  defp limits(_opts) do
    {:error,
     %{
       "reason" => "snapshot_invalid_options",
       "message" => "workspace snapshot options must be a keyword list",
       "next_actions" => ["pass_workspace_snapshot_opts_as_a_keyword_list"]
     }}
  end

  defp normalize_limits(limits) when is_map(limits) do
    limits
    |> Enum.reduce_while({:ok, %{}}, fn {key, value}, {:ok, acc} ->
      case normalize_limit(key, value) do
        {:ok, nil} ->
          {:cont, {:ok, acc}}

        {:ok, {normalized_key, normalized_value}} ->
          {:cont, {:ok, Map.put(acc, normalized_key, normalized_value)}}

        {:error, details} ->
          {:halt, {:error, details}}
      end
    end)
  end

  defp normalize_limits(limits) when is_list(limits) do
    if Keyword.keyword?(limits) do
      limits
      |> Map.new()
      |> normalize_limits()
    else
      {:error,
       %{
         "reason" => "snapshot_invalid_limits",
         "message" => "workspace snapshot limits must be a map or keyword list",
         "next_actions" => ["use_positive_integer_snapshot_limits"]
       }}
    end
  end

  defp normalize_limits(_limits) do
    {:error,
     %{
       "reason" => "snapshot_invalid_limits",
       "message" => "workspace snapshot limits must be a map or keyword list",
       "next_actions" => ["use_positive_integer_snapshot_limits"]
     }}
  end

  defp normalize_limit(key, value) when key in [:max_files, :max_bytes, :max_file_bytes],
    do: normalize_known_limit(key, value)

  defp normalize_limit("max_files", value), do: normalize_known_limit(:max_files, value)
  defp normalize_limit("max_bytes", value), do: normalize_known_limit(:max_bytes, value)
  defp normalize_limit("max_file_bytes", value), do: normalize_known_limit(:max_file_bytes, value)
  defp normalize_limit(_key, _value), do: {:ok, nil}

  defp normalize_known_limit(key, value) when is_integer(value) and value > 0,
    do: {:ok, {key, value}}

  defp normalize_known_limit(key, value) do
    {:error,
     %{
       "reason" => "snapshot_invalid_limit",
       "message" => "workspace snapshot limits must be positive integers",
       "field" => Atom.to_string(key),
       "value" => inspect(value),
       "next_actions" => ["use_positive_integer_snapshot_limits"]
     }}
  end

  defp finalize_error(details, state, started_at) do
    details
    |> Map.put_new("message", "subagent workspace snapshot failed")
    |> Map.put("snapshot_policy", @policy)
    |> Map.put("limits", public_limits(state.limits))
    |> Map.put("files_copied", state.files_copied)
    |> Map.put("dirs_skipped", state.dirs_skipped)
    |> Map.put("bytes_copied", state.bytes_copied)
    |> Map.put("elapsed_ms", elapsed_ms(started_at))
    |> Map.put_new("next_actions", @next_actions)
  end

  defp metadata(state, elapsed_ms) do
    %{
      "snapshot_policy" => @policy,
      "files_copied" => state.files_copied,
      "dirs_skipped" => state.dirs_skipped,
      "bytes_copied" => state.bytes_copied,
      "elapsed_ms" => elapsed_ms,
      "limits" => public_limits(state.limits),
      "skipped_dirs_by_name" => state.skipped_dirs_by_name,
      "symlinks_skipped" => state.symlinks_skipped,
      "special_entries_skipped" => state.special_entries_skipped
    }
  end

  defp public_limits(limits) do
    %{
      "max_files" => limits.max_files,
      "max_bytes" => limits.max_bytes,
      "max_file_bytes" => limits.max_file_bytes
    }
  end

  defp relative(path, root) do
    path
    |> Path.expand()
    |> Path.relative_to(root)
  end

  defp elapsed_ms(started_at), do: max(monotonic_ms() - started_at, 0)

  defp monotonic_ms, do: System.monotonic_time(:millisecond)
end
