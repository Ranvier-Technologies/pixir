defmodule Pixir.Subagents.GC do
  @moduledoc """
  Plans and applies fail-closed reclamation of isolated Subagent workspaces.

  Parent Session Logs are the only lifecycle evidence. Reclamation never deletes or
  moves an NDJSON file below a `.pixir/sessions` directory, including child Logs
  embedded inside an isolated workspace snapshot.
  """

  alias Pixir.{Log, Paths, Subagents}

  @active_statuses ~w(running queued)

  @doc "Build an effect-free reclamation plan for the current Workspace."
  @spec plan(keyword()) :: {:ok, map()} | {:error, map()}
  def plan(opts \\ []) do
    workspace = opts |> Keyword.get(:workspace, File.cwd!()) |> Path.expand()

    with {:ok, references} <- discover_references(workspace),
         {:ok, entries} <- plan_entries(workspace, references) do
      {:ok, plan_envelope(workspace, entries)}
    end
  end

  @doc "Build and apply one reclamation plan, continuing after per-directory errors."
  @spec apply(keyword()) :: {:ok, map()} | {:error, map()}
  def apply(opts \\ []) do
    with {:ok, plan} <- plan(opts) do
      result = apply_plan(plan)
      if result["ok"], do: {:ok, result}, else: {:error, result}
    end
  end

  defp discover_references(workspace) do
    workspace
    |> Paths.sessions_dir()
    |> Path.join("*.ndjson")
    |> Path.wildcard()
    |> Enum.sort()
    |> Enum.reduce_while({:ok, []}, fn path, {:ok, references} ->
      session_id = path |> Path.basename() |> String.replace_suffix(".ndjson", "")

      case Log.fold(session_id, workspace: workspace) do
        {:ok, history} ->
          reconstructed =
            history
            |> Subagents.reconstruct()
            |> Map.values()
            |> Enum.map(&reference(&1, path, workspace))
            |> Enum.reject(&is_nil/1)

          {:cont, {:ok, references ++ reconstructed}}

        {:error, error} ->
          {:halt,
           {:error,
            error_envelope(
              "subagent_gc_evidence_error",
              "blocked",
              [
                "repair_or_remove_the_corrupt_parent_log",
                "rerun_pixir_gc"
              ],
              %{
                "parent_log_path" => path,
                "cause" => json_safe(error)
              }
            )}}
      end
    end)
  end

  defp reference(agent, parent_log_path, workspace) do
    case agent["workspace"] do
      path when is_binary(path) and path != "" ->
        %{
          "workspace" => Path.expand(path, workspace),
          "status" => agent["status"],
          "subagent_id" => agent["subagent_id"] || agent["id"],
          "parent_log_path" => parent_log_path
        }

      _other ->
        nil
    end
  end

  defp plan_entries(workspace, references) do
    root = Path.join(Paths.project_root(workspace), "subagents")

    case File.ls(root) do
      {:error, :enoent} ->
        {:ok, []}

      {:error, reason} ->
        {:error,
         error_envelope(
           "subagent_gc_scan_error",
           "blocked",
           [
             "check_subagent_directory_permissions",
             "rerun_pixir_gc"
           ],
           %{"dir" => root, "reason" => inspect(reason)}
         )}

      {:ok, names} ->
        names
        |> Enum.sort()
        |> Enum.reduce_while({:ok, []}, fn name, {:ok, entries} ->
          dir = Path.join(root, name)

          if File.dir?(dir) do
            case directory_entry(dir, references) do
              {:ok, entry} -> {:cont, {:ok, entries ++ [entry]}}
              {:error, error} -> {:halt, {:error, error}}
            end
          else
            {:cont, {:ok, entries}}
          end
        end)
    end
  end

  defp directory_entry(dir, references) do
    matching = Enum.filter(references, &reference_matches_dir?(&1, dir))

    with {:ok, usage} <- directory_usage(dir) do
      {:ok,
       %{
         "dir" => dir,
         "bytes" => usage.bytes,
         "preserved_log_count" => usage.preserved_log_count,
         "preserved_logs_bytes" => usage.preserved_logs_bytes,
         "classification" => classify(matching),
         "references" => matching
       }}
    else
      {:error, details} ->
        {:error,
         error_envelope(
           "subagent_gc_scan_error",
           "blocked",
           [
             "check_subagent_directory_permissions",
             "rerun_pixir_gc"
           ],
           Map.put(details, "dir", dir)
         )}
    end
  end

  # Join evidence to directories by the `.pixir/subagents/<id>` suffix rather
  # than absolute equality: evidence paths and File.cwd!-derived dirs can
  # disagree on symlinked prefixes (macOS /var -> /private/var) while naming
  # the same snapshot.
  defp reference_matches_dir?(%{"workspace" => workspace}, dir) do
    workspace == Path.expand(dir) or workspace == Path.expand(Path.join(dir, "workspace")) or
      subagents_suffix(workspace) == subagents_suffix(Path.join(dir, "workspace"))
  end

  defp subagents_suffix(path) do
    parts = path |> Path.expand() |> Path.split()

    case Enum.split_while(parts, &(&1 != ".pixir")) do
      {_prefix, [".pixir", "subagents" | rest]} when rest != [] -> [".pixir", "subagents" | rest]
      _no_marker -> nil
    end
  end

  defp classify([]), do: "skipped_unreferenced"

  defp classify(references) do
    statuses = Enum.map(references, & &1["status"])

    cond do
      Enum.any?(statuses, &(&1 == "detached")) -> "skipped_detached"
      Enum.all?(statuses, &Subagents.terminal?/1) -> "reclaimable"
      Enum.any?(statuses, &(&1 in @active_statuses)) -> "skipped_running"
      true -> "skipped_running"
    end
  end

  defp directory_usage(root) do
    walk_usage(root, %{bytes: 0, preserved_log_count: 0, preserved_logs_bytes: 0})
  end

  defp walk_usage(path, acc) do
    case File.lstat(path) do
      {:ok, %{type: :directory}} ->
        case File.ls(path) do
          {:ok, names} ->
            Enum.reduce_while(names, {:ok, acc}, fn name, {:ok, current} ->
              case walk_usage(Path.join(path, name), current) do
                {:ok, updated} -> {:cont, {:ok, updated}}
                {:error, details} -> {:halt, {:error, details}}
              end
            end)

          {:error, reason} ->
            {:error, %{"path" => path, "reason" => inspect(reason)}}
        end

      {:ok, stat} ->
        bytes = stat.size || 0

        if preserved_log?(path) do
          {:ok,
           %{
             acc
             | bytes: acc.bytes + bytes,
               preserved_log_count: acc.preserved_log_count + 1,
               preserved_logs_bytes: acc.preserved_logs_bytes + bytes
           }}
        else
          {:ok, %{acc | bytes: acc.bytes + bytes}}
        end

      {:error, reason} ->
        {:error, %{"path" => path, "reason" => inspect(reason)}}
    end
  end

  defp preserved_log?(path) do
    parts = Path.split(Path.expand(path))

    String.ends_with?(Path.basename(path), ".ndjson") and
      sessions_ancestor?(parts)
  end

  defp sessions_ancestor?([".pixir", "sessions" | _rest]), do: true
  defp sessions_ancestor?([_part | rest]), do: sessions_ancestor?(rest)
  defp sessions_ancestor?([]), do: false

  defp plan_envelope(workspace, entries) do
    reclaimable = Enum.filter(entries, &(&1["classification"] == "reclaimable"))

    %{
      "ok" => true,
      "status" => "planned",
      "kind" => "subagent_gc_plan",
      "workspace" => workspace,
      "apply" => false,
      "entries" => entries,
      "totals" => totals(reclaimable),
      "next_actions" => plan_next_actions(reclaimable)
    }
  end

  defp totals(entries) do
    reclaimable =
      entries
      |> Enum.filter(&(&1["classification"] == "reclaimable"))
      |> Enum.map(&(&1["bytes"] - &1["preserved_logs_bytes"]))
      |> Enum.sum()

    %{
      "reclaimable_bytes" => reclaimable,
      "preserved_logs_bytes" => Enum.sum(Enum.map(entries, & &1["preserved_logs_bytes"]))
    }
  end

  defp plan_next_actions([]), do: []
  defp plan_next_actions(_entries), do: ["run_pixir_gc_--apply_--json"]

  defp apply_plan(plan) do
    outcomes = Enum.map(plan["entries"], &apply_entry/1)
    failed = Enum.filter(outcomes, &(&1["outcome"] == "failed"))
    reclaimed = Enum.filter(outcomes, &(&1["outcome"] == "reclaimed"))

    %{
      "ok" => failed == [],
      "status" => if(failed == [], do: "applied", else: "partial"),
      "kind" => "subagent_gc_apply",
      "workspace" => plan["workspace"],
      "apply" => true,
      "entries" => outcomes,
      "totals" => totals(reclaimed),
      "next_actions" => apply_next_actions(failed)
    }
  end

  defp apply_entry(%{"classification" => "reclaimable"} = entry) do
    case reclaim(entry["dir"]) do
      :ok -> Map.put(entry, "outcome", "reclaimed")
      {:error, details} -> entry |> Map.put("outcome", "failed") |> Map.put("error", details)
    end
  end

  defp apply_entry(entry), do: Map.put(entry, "outcome", "skipped")

  defp reclaim(dir) do
    case delete_tree_preserving_logs(dir, true) do
      {:ok, _preserved?} -> :ok
      {:error, details} -> {:error, details}
    end
  end

  defp delete_tree_preserving_logs(path, root?) do
    cond do
      preserved_log?(path) ->
        {:ok, true}

      true ->
        delete_non_preserved(path, root?)
    end
  end

  defp delete_non_preserved(path, root?) do
    case File.lstat(path) do
      {:ok, %{type: :directory}} -> delete_directory(path, root?)
      {:ok, _stat} -> remove_file(path)
      {:error, :enoent} -> {:ok, false}
      {:error, reason} -> {:error, filesystem_error("lstat_failed", path, reason)}
    end
  end

  defp delete_directory(path, root?) do
    case File.ls(path) do
      {:ok, names} ->
        case delete_children(path, names, false) do
          {:ok, true} -> {:ok, true}
          {:ok, false} -> remove_directory(path, root?)
          {:error, details} -> {:error, details}
        end

      {:error, reason} ->
        {:error, filesystem_error("list_failed", path, reason)}
    end
  end

  defp delete_children(_path, [], preserved?), do: {:ok, preserved?}

  defp delete_children(path, [name | rest], preserved?) do
    case delete_tree_preserving_logs(Path.join(path, name), false) do
      {:ok, child_preserved?} ->
        delete_children(path, rest, preserved? or child_preserved?)

      {:error, details} ->
        {:error, details}
    end
  end

  defp remove_file(path) do
    case File.rm(path) do
      :ok -> {:ok, false}
      {:error, :enoent} -> {:ok, false}
      {:error, reason} -> {:error, filesystem_error("remove_failed", path, reason)}
    end
  end

  defp remove_directory(path, _root?) do
    case File.rmdir(path) do
      :ok -> {:ok, false}
      {:error, :enoent} -> {:ok, false}
      {:error, reason} -> {:error, filesystem_error("remove_directory_failed", path, reason)}
    end
  end

  defp filesystem_error(kind, path, reason) do
    %{"kind" => kind, "path" => path, "reason" => inspect(reason)}
  end

  defp apply_next_actions([]), do: []

  defp apply_next_actions(_failed) do
    ["inspect_failed_gc_entries", "fix_filesystem_permissions", "rerun_pixir_gc_--apply_--json"]
  end

  defp error_envelope(kind, status, next_actions, details) do
    %{
      "ok" => false,
      "status" => status,
      "kind" => kind,
      "details" => details,
      "next_actions" => next_actions
    }
  end

  defp json_safe(value) when is_map(value) do
    Map.new(value, fn {key, nested} -> {to_string(key), json_safe(nested)} end)
  end

  defp json_safe(value) when is_list(value), do: Enum.map(value, &json_safe/1)
  defp json_safe(value) when is_atom(value), do: Atom.to_string(value)
  defp json_safe(value) when is_tuple(value), do: value |> Tuple.to_list() |> json_safe()
  defp json_safe(value), do: value
end
