defmodule Pixir.VirtualDiffApply do
  @moduledoc """
  Planner and staged applier for ADR 0029 `virtual_diff` artifacts.

  The module performs workspace-confined BEAM file I/O only. `plan/3` is effect-free;
  `apply/3` mutates only when every selected file is applicable and authorized. Apply
  is all-or-nothing through precondition checks and staging; rename/delete commit
  failures have a narrow residual window, and the result reports recovery.
  """

  alias Pixir.Permissions.WritePolicy
  alias Pixir.Tool

  @version 1
  @applicable_status "applicable"
  @max_output_bytes 16_000

  @doc "Build an effect-free apply plan for a `virtual_diff` artifact."
  @spec plan(map(), String.t(), keyword()) :: {:ok, map()} | {:error, map()}
  def plan(artifact, workspace, opts \\ [])

  def plan(artifact, workspace, opts) when is_map(artifact) and is_binary(workspace) do
    started_at = monotonic_ms()
    dry_run = Keyword.get(opts, :dry_run, true)

    with {:ok, root, files} <- compute_plan(artifact, workspace, opts) do
      {:ok,
       result(artifact, root, dry_run, plan_status(files), files, started_at, %{
         "output" => bounded_output(files)
       })}
    end
  end

  def plan(_artifact, _workspace, _opts) do
    {:error,
     Tool.error(:invalid_args, "virtual_diff apply requires an artifact map and workspace", %{})}
  end

  # The internal plan keeps after_content so apply can write; result/7 strips
  # it so durable evidence never carries full file contents.
  defp compute_plan(artifact, workspace, opts) do
    with :ok <- validate_artifact(artifact),
         {:ok, root} <- canonical_path(workspace),
         {:ok, changes} <- changes(artifact) do
      {:ok, root, Enum.map(changes, &plan_change(&1, workspace, root, opts))}
    end
  end

  @doc "Apply a `virtual_diff` artifact after complete planning and staging."
  @spec apply(map(), String.t(), keyword()) :: {:ok, map()} | {:error, map()}
  def apply(artifact, workspace, opts \\ [])

  def apply(artifact, workspace, opts) when is_map(artifact) and is_binary(workspace) do
    started_at = monotonic_ms()

    with {:ok, root, files} <-
           compute_plan(artifact, workspace, Keyword.put(opts, :dry_run, false)) do
      if Enum.all?(files, &(&1["status"] == @applicable_status)) do
        case apply_files(files, opts) do
          :ok ->
            applied = Enum.map(files, &Map.put(&1, "status", "applied"))

            {:ok,
             result(artifact, root, false, "applied", applied, started_at, %{
               "output" => bounded_output(applied)
             })}

          {:error, reason, recovery} ->
            failed =
              Enum.map(files, fn file ->
                file
                |> Map.put("status", "failed")
                |> Map.put("error", inspect(reason))
              end)

            {:ok,
             result(artifact, root, false, "failed", failed, started_at, %{
               "output" => bounded_output(failed),
               "recovery" => recovery
             })}
        end
      else
        {:ok,
         result(artifact, root, false, "not_applied", files, started_at, %{
           "output" => bounded_output(files)
         })
         |> put_in(["counts", "applied"], 0)}
      end
    end
  end

  def apply(_artifact, _workspace, _opts) do
    {:error,
     Tool.error(:invalid_args, "virtual_diff apply requires an artifact map and workspace", %{})}
  end

  defp validate_artifact(%{"kind" => "virtual_diff", "version" => 1}), do: :ok

  defp validate_artifact(_artifact) do
    {:error,
     Tool.error(:invalid_args, "artifact must be a version 1 virtual_diff", %{
       "expected" => %{"kind" => "virtual_diff", "version" => 1}
     })}
  end

  defp changes(%{"changes" => changes}) when is_list(changes), do: {:ok, changes}

  defp changes(_artifact) do
    {:error,
     Tool.error(:invalid_args, "virtual_diff artifact changes must be a list", %{
       "field" => "changes"
     })}
  end

  defp plan_change(change, workspace, root, opts) do
    path = Map.get(change, "path")
    operation = Map.get(change, "operation")

    base = %{
      "path" => path,
      "operation" => operation,
      "precondition" => %{},
      "applicability" => %{}
    }

    with {:ok, target} <- confined_target(workspace, root, path),
         base <- Map.merge(base, target),
         :ok <- supported_operation(operation),
         :ok <- no_unsafe_caveats(change),
         :ok <- diff_not_truncated(change, operation),
         {:ok, after_content} <- reconstruct_after(change, operation),
         :ok <- verify_required_hashes(change, operation, after_content),
         {:ok, precondition} <- precondition(change, operation, target["absolute_path"]),
         :ok <- authorize_policy(opts, path, workspace) do
      base
      |> Map.put("status", @applicable_status)
      |> Map.put("precondition", precondition)
      |> maybe_put_content(after_content)
    else
      {:conflict, precondition} ->
        base
        |> Map.put("status", "conflicted")
        |> Map.put("precondition", precondition)
        |> Map.put("safe_next_action", "refresh the virtual_diff from the current workspace")

      {:denied_by_policy, details} ->
        base
        |> Map.put("status", "denied_by_policy")
        |> Map.put("policy", details)
        |> Map.put("safe_next_action", "request_policy_expansion or apply a narrower artifact")

      {:outside_workspace, details} ->
        base
        |> Map.put("status", "outside_workspace")
        |> Map.put("applicability", details)
        |> Map.put("safe_next_action", "remove escaping paths from the artifact")

      {:unsupported, details} ->
        base
        |> Map.put("status", "unsupported")
        |> Map.put("applicability", details)
        |> Map.put("safe_next_action", "review manually or regenerate an applicable text diff")
    end
  end

  defp supported_operation(operation) when operation in ["add", "modify", "delete"], do: :ok

  defp supported_operation(operation),
    do: {:unsupported, %{"reason" => "unsupported_operation", "operation" => operation}}

  defp no_unsafe_caveats(change) do
    caveats = Map.get(change, "caveats", [])

    if caveats == [] do
      :ok
    else
      {:unsupported, %{"reason" => "unsafe_caveat", "caveats" => caveats}}
    end
  end

  defp diff_not_truncated(_change, "delete"), do: :ok

  defp diff_not_truncated(change, _operation) do
    case get_in(change, ["diff", "truncated"]) do
      false -> :ok
      true -> {:unsupported, %{"reason" => "diff_truncated"}}
      _other -> {:unsupported, %{"reason" => "diff_missing_truncation_evidence"}}
    end
  end

  defp reconstruct_after(_change, "delete"), do: {:ok, nil}

  defp reconstruct_after(change, operation) when operation in ["add", "modify"] do
    cond do
      is_binary(get_in(change, ["after", "content"])) ->
        {:ok, get_in(change, ["after", "content"])}

      is_binary(get_in(change, ["diff", "text"])) ->
        {:ok, plus_lines(get_in(change, ["diff", "text"]))}

      true ->
        {:unsupported, %{"reason" => "after_content_unreconstructable"}}
    end
  end

  defp plus_lines(diff_text) do
    parts = String.split(diff_text, "\n", trim: false)
    last = length(parts) - 1

    parts
    |> Enum.with_index()
    |> Enum.flat_map(fn {line, index} ->
      if String.starts_with?(line, "+") and not String.starts_with?(line, "+++") do
        content = String.replace_prefix(line, "+", "")
        suffix = if index < last, do: "\n", else: ""
        [content <> suffix]
      else
        []
      end
    end)
    |> IO.iodata_to_binary()
  end

  defp verify_required_hashes(change, "add", after_content) do
    with :ok <- require_hash(change, ["after", "sha256"], "after.sha256") do
      verify_after_hash(change, after_content)
    end
  end

  defp verify_required_hashes(change, "modify", after_content) do
    with :ok <- require_hash(change, ["before", "sha256"], "before.sha256"),
         :ok <- require_hash(change, ["after", "sha256"], "after.sha256") do
      verify_after_hash(change, after_content)
    end
  end

  defp verify_required_hashes(change, "delete", _after_content) do
    require_hash(change, ["before", "sha256"], "before.sha256")
  end

  defp require_hash(change, path, label) do
    if is_binary(get_in(change, path)) do
      :ok
    else
      {:unsupported, %{"reason" => "required_hash_missing", "hash" => label}}
    end
  end

  defp verify_after_hash(change, after_content) do
    expected = get_in(change, ["after", "sha256"])
    observed = sha256(after_content)

    if expected == observed do
      :ok
    else
      {:unsupported,
       %{
         "reason" => "after_content_hash_mismatch",
         "expected" => expected,
         "observed" => observed
       }}
    end
  end

  defp precondition(_change, "add", abs) do
    if File.exists?(abs) do
      {:conflict,
       %{
         "expected" => "absent",
         "observed" => "exists",
         "target_sha256" => existing_sha(abs)
       }}
    else
      {:ok, %{"expected" => "absent", "observed" => "absent"}}
    end
  end

  defp precondition(change, operation, abs) when operation in ["modify", "delete"] do
    expected = get_in(change, ["before", "sha256"])

    cond do
      not File.exists?(abs) ->
        {:conflict,
         %{"expected" => "exists", "observed" => "missing", "expected_sha256" => expected}}

      not File.regular?(abs) ->
        {:conflict, %{"expected" => "regular_file", "observed" => "not_regular"}}

      true ->
        observed = existing_sha(abs)

        if observed == expected do
          {:ok, %{"expected_sha256" => expected, "observed_sha256" => observed}}
        else
          {:conflict, %{"expected_sha256" => expected, "observed_sha256" => observed}}
        end
    end
  end

  defp existing_sha(abs) do
    case File.read(abs) do
      {:ok, content} -> sha256(content)
      {:error, reason} -> "read_error:#{inspect(reason)}"
    end
  end

  defp authorize_policy(opts, path, workspace) do
    case Keyword.get(opts, :write_policy) do
      nil ->
        :ok

      policy ->
        case WritePolicy.authorize_tool(policy, "write", %{"path" => path}, workspace) do
          :allow -> :ok
          {:deny, %{error: %{details: details}}} -> {:denied_by_policy, details}
          {:error, %{error: %{details: details}}} -> {:denied_by_policy, details}
          {:error, error} -> {:denied_by_policy, %{"error" => inspect(error)}}
        end
    end
  end

  defp confined_target(workspace, root, path) when is_binary(path) and path != "" do
    abs = Path.expand(path, workspace)

    with {:ok, canonical} <- canonical_path_allow_missing(abs),
         true <- under_path?(canonical, root) do
      {:ok,
       %{
         "absolute_path" => canonical,
         "normalized_path" => Path.relative_to(canonical, root)
       }}
    else
      false -> {:outside_workspace, %{"reason" => "path_escapes_workspace", "path" => path}}
      {:error, reason} -> {:outside_workspace, %{"reason" => inspect(reason), "path" => path}}
    end
  end

  defp confined_target(_workspace, _root, path),
    do: {:unsupported, %{"reason" => "invalid_path", "path" => inspect(path)}}

  defp canonical_path(path), do: canonical_path_allow_missing(path)

  defp canonical_path_allow_missing(path) do
    path
    |> Path.expand()
    |> Path.split()
    |> resolve_segments(0)
  end

  defp resolve_segments(_segments, depth) when depth > 40, do: {:error, :too_many_symlinks}
  defp resolve_segments([], _depth), do: {:ok, "/"}
  defp resolve_segments([root | rest], depth), do: resolve_segments(root, rest, depth)

  defp resolve_segments(current, [], _depth), do: {:ok, normalize_path(current)}

  defp resolve_segments(current, [segment | rest], depth) do
    candidate = Path.join(current, segment)

    case File.lstat(candidate) do
      {:ok, %File.Stat{type: :symlink}} ->
        with {:ok, link} <- File.read_link(candidate) do
          target =
            case Path.type(link) do
              :absolute -> Path.expand(link)
              _relative -> Path.expand(link, Path.dirname(candidate))
            end

          [target | rest]
          |> Path.join()
          |> canonical_path_allow_missing(depth + 1)
        end

      {:ok, _stat} ->
        resolve_segments(candidate, rest, depth)

      {:error, :enoent} ->
        {:ok, Path.join([candidate | rest]) |> Path.expand() |> normalize_path()}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp canonical_path_allow_missing(path, depth) do
    path
    |> Path.expand()
    |> Path.split()
    |> resolve_segments(depth)
  end

  defp normalize_path("/"), do: "/"
  defp normalize_path(path), do: String.trim_trailing(Path.expand(path), "/")

  defp under_path?(path, root) do
    path = normalize_path(path)
    root = normalize_path(root)
    path == root or root == "/" or String.starts_with?(path, root <> "/")
  end

  defp maybe_put_content(file, nil), do: file

  defp maybe_put_content(file, content) do
    file
    |> Map.put("after", %{"sha256" => sha256(content), "byte_count" => byte_size(content)})
    |> Map.put("after_content", content)
  end

  defp apply_files(files, opts) do
    case stage_files(files) do
      {:ok, staged} ->
        continue_staged_apply(staged, opts)

      {:error, reason, cleanup_failures} ->
        {:error, reason, recovery(cleanup_failures)}
    end
  end

  defp continue_staged_apply(staged, opts) do
    case run_apply_hook(opts, :staged) do
      :ok ->
        Enum.map(staged, fn entry -> Map.put(entry, :backup, backup(entry)) end)
        |> commit_staged(opts)

      {:error, reason} ->
        {:error, reason, recovery(cleanup_staged(staged))}
    end
  end

  defp stage_files(files) do
    Enum.reduce_while(files, {:ok, []}, fn file, {:ok, staged} ->
      case stage_file(file) do
        {:ok, entry} ->
          {:cont, {:ok, [entry | staged]}}

        {:error, reason, failures} ->
          cleanup_failures = failures ++ cleanup_staged(staged)
          {:halt, {:error, reason, cleanup_failures}}
      end
    end)
    |> case do
      {:ok, staged} -> {:ok, Enum.reverse(staged)}
      {:error, _reason, _failures} = error -> error
    end
  end

  defp stage_file(%{"operation" => operation} = file) when operation in ["add", "modify"] do
    abs = file["absolute_path"]
    content = file["after_content"]
    stage_dir = existing_stage_directory(Path.dirname(abs))
    tmp = unique_apply_tmp_path(stage_dir, abs)

    case File.write(tmp, content, [:exclusive]) do
      :ok ->
        {:ok, %{file: file, tmp: tmp}}

      {:error, reason} ->
        failures = cleanup_temp(tmp, file["path"])
        {:error, {:stage_failed, file["path"], reason}, failures}
    end
  end

  defp stage_file(file), do: {:ok, %{file: file, tmp: nil}}

  defp existing_stage_directory(path) do
    if File.dir?(path) do
      path
    else
      existing_stage_directory(Path.dirname(path))
    end
  end

  defp unique_apply_tmp_path(stage_dir, abs) do
    suffix = Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)
    Path.join(stage_dir, ".#{Path.basename(abs)}.pixir-apply-#{suffix}.tmp")
  end

  defp commit_staged(staged, opts) do
    case run_apply_hook(opts, :backed_up) do
      :ok -> commit_entries(staged, opts)
      {:error, reason} -> {:error, reason, recovery(cleanup_staged(staged))}
    end
  end

  defp commit_entries(staged, opts) do
    initial = %{mutated: [], created_dirs: []}

    staged
    |> Enum.reduce_while({:ok, initial}, fn entry, {:ok, state} ->
      case commit_entry(entry) do
        {:ok, created_dirs} ->
          state = %{
            state
            | mutated: [entry | state.mutated],
              created_dirs: created_dirs ++ state.created_dirs
          }

          case run_apply_hook(opts, {:committed, entry.file["path"]}) do
            :ok -> {:cont, {:ok, state}}
            {:error, reason} -> {:halt, {:error, reason, state}}
          end

        {:error, reason, created_dirs} ->
          state = %{state | created_dirs: created_dirs ++ state.created_dirs}
          {:halt, {:error, reason, state}}
      end
    end)
    |> case do
      {:ok, _state} ->
        :ok

      {:error, reason, state} ->
        _ = run_apply_hook(opts, :before_rollback)

        failures =
          rollback(state.mutated) ++
            cleanup_staged(staged) ++ cleanup_created_dirs(state.created_dirs)

        {:error, reason, recovery(failures)}
    end
  end

  defp commit_entry(%{file: %{"operation" => "delete"} = file}) do
    case File.rm(file["absolute_path"]) do
      :ok -> {:ok, []}
      {:error, reason} -> {:error, {:commit_failed, file["path"], reason}, []}
    end
  end

  defp commit_entry(%{file: file, tmp: tmp}) do
    abs = file["absolute_path"]
    missing_dirs = missing_directories(Path.dirname(abs), [])

    case File.mkdir_p(Path.dirname(abs)) do
      :ok ->
        case File.rename(tmp, abs) do
          :ok -> {:ok, missing_dirs}
          {:error, reason} -> {:error, {:commit_failed, file["path"], reason}, missing_dirs}
        end

      {:error, reason} ->
        {:error, {:commit_failed, file["path"], reason}, []}
    end
  end

  defp missing_directories(path, acc) do
    cond do
      File.exists?(path) -> acc
      Path.dirname(path) == path -> acc
      true -> missing_directories(Path.dirname(path), [path | acc])
    end
  end

  defp backup(%{file: %{"operation" => operation, "absolute_path" => abs}}) do
    case File.read(abs) do
      {:ok, content} -> {:content, content}
      {:error, :enoent} when operation == "add" -> :absent
      {:error, reason} -> {:error, reason}
    end
  end

  defp rollback(mutated) do
    Enum.flat_map(mutated, &restore_entry/1)
  end

  defp restore_entry(%{file: file, backup: {:content, content}}) do
    abs = file["absolute_path"]

    case File.mkdir_p(Path.dirname(abs)) do
      :ok ->
        case File.write(abs, content) do
          :ok -> []
          {:error, reason} -> [restore_failure(file["path"], {:write_failed, reason})]
        end

      {:error, reason} ->
        [restore_failure(file["path"], {:mkdir_failed, reason})]
    end
  end

  defp restore_entry(%{file: file, backup: :absent}) do
    case File.rm(file["absolute_path"]) do
      :ok -> []
      {:error, :enoent} -> []
      {:error, reason} -> [restore_failure(file["path"], {:remove_failed, reason})]
    end
  end

  defp restore_entry(%{file: file, backup: {:error, reason}}) do
    [restore_failure(file["path"], {:backup_read_failed, reason})]
  end

  defp cleanup_staged(staged) do
    Enum.flat_map(staged, fn
      %{tmp: nil} -> []
      %{tmp: tmp, file: file} -> cleanup_temp(tmp, file["path"])
    end)
  end

  defp cleanup_temp(tmp, path) do
    case File.rm(tmp) do
      :ok -> []
      {:error, :enoent} -> []
      {:error, reason} -> [restore_failure(path, {:temporary_cleanup_failed, reason})]
    end
  end

  defp cleanup_created_dirs(dirs) do
    dirs
    |> Enum.uniq()
    |> Enum.sort_by(&path_depth/1, :desc)
    |> Enum.flat_map(fn dir ->
      case File.rmdir(dir) do
        :ok -> []
        {:error, :enoent} -> []
        {:error, reason} -> [restore_failure(dir, {:directory_cleanup_failed, reason})]
      end
    end)
  end

  defp path_depth(path), do: path |> Path.split() |> length()

  defp restore_failure(path, reason) do
    %{"path" => path}
    |> Map.merge(restore_failure_reason(reason))
  end

  # Structured kinds per ADR 0005: callers match on "kind", never on prose.
  defp restore_failure_reason({kind, detail}) when is_atom(kind) do
    %{"kind" => Atom.to_string(kind), "detail" => inspect(detail)}
  end

  defp restore_failure_reason(reason) when is_atom(reason) do
    %{"kind" => Atom.to_string(reason), "detail" => nil}
  end

  defp restore_failure_reason(reason) do
    %{"kind" => "restore_failed", "detail" => inspect(reason)}
  end

  defp recovery(restore_failures) do
    %{
      "rolled_back" => restore_failures == [],
      "restore_failures" => restore_failures
    }
  end

  # Deterministic filesystem-failure seam for apply atomicity tests. Production
  # callers omit it; hook failures are handled like ordinary apply failures.
  defp run_apply_hook(opts, event) do
    case Keyword.get(opts, :apply_hook) do
      nil ->
        :ok

      hook when is_function(hook, 1) ->
        try do
          case hook.(event) do
            :ok -> :ok
            other -> {:error, {:apply_hook_failed, event, other}}
          end
        rescue
          error -> {:error, {:apply_hook_raised, event, Exception.message(error)}}
        catch
          kind, reason -> {:error, {:apply_hook_caught, event, kind, reason}}
        end

      other ->
        {:error, {:invalid_apply_hook, inspect(other)}}
    end
  end

  defp plan_status(files) do
    cond do
      Enum.any?(files, &(&1["status"] == "denied_by_policy")) -> "denied"
      Enum.any?(files, &(&1["status"] == "conflicted")) -> "conflicted"
      Enum.any?(files, &(&1["status"] in ["unsupported", "outside_workspace"])) -> "not_applied"
      true -> "planned"
    end
  end

  defp result(artifact, root, dry_run, status, files, started_at, extra) do
    files_for_output = Enum.map(files, &Map.delete(&1, "after_content"))

    %{
      "kind" => "virtual_diff_apply",
      "version" => @version,
      "dry_run" => dry_run,
      "status" => status,
      "artifact" => artifact_identity(artifact),
      "workspace" => %{"root" => root},
      "counts" => counts(files_for_output),
      "files" => files_for_output,
      "elapsed_ms" => monotonic_ms() - started_at,
      "output_metadata" => %{
        "file_count" => length(files_for_output),
        "bounded" => true,
        "max_output_bytes" => @max_output_bytes
      }
    }
    |> Map.merge(extra)
  end

  defp artifact_identity(artifact) do
    encoded = Jason.encode!(artifact)

    %{
      "kind" => Map.get(artifact, "kind"),
      "version" => Map.get(artifact, "version"),
      "sha256" => sha256(encoded)
    }
  end

  defp counts(files) do
    %{
      "selected" => length(files),
      "applicable" => Enum.count(files, &(&1["status"] in [@applicable_status, "applied"])),
      "applied" => Enum.count(files, &(&1["status"] == "applied")),
      "conflicted" => Enum.count(files, &(&1["status"] == "conflicted")),
      "unsupported" => Enum.count(files, &(&1["status"] in ["unsupported", "outside_workspace"])),
      "skipped" => Enum.count(files, &(&1["status"] not in [@applicable_status, "applied"]))
    }
  end

  defp bounded_output(files) do
    files
    |> Enum.map_join("\n", fn file -> "#{file["status"]}: #{file["path"]}" end)
    |> Tool.truncate(@max_output_bytes)
  end

  defp sha256(content) when is_binary(content) do
    :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
  end

  defp monotonic_ms, do: System.monotonic_time(:millisecond)
end
