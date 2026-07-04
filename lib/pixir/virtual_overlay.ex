defmodule Pixir.VirtualOverlay do
  @moduledoc """
  BEAM-native virtual workspace runner for future `virtual_overlay` Subagent work.

  The runner imports an explicit, bounded read set from a real Pixir Workspace into a
  Bashex in-memory filesystem, executes virtual shell commands there, and returns an
  ADR 0029 `virtual_diff` artifact. It is deliberately not a model-visible Tool and it
  does not apply virtual writes back to the parent Workspace.
  """

  alias Pixir.{Tool, Tools.Workspace}
  alias JustBash.Fs.InMemoryFs

  @version 1
  @workspace_root "/workspace"
  @default_limits %{
    max_import_files: 100,
    max_import_bytes: 1_000_000,
    max_file_bytes: 256_000,
    max_virtual_commands: 20,
    max_diff_bytes: 50_000,
    max_output_bytes: 20_000
  }

  @doc """
  Run virtual shell commands over a bounded import from `workspace`.

  Parameters are string-keyed for parity with Tool and Workflow inputs:

  - `"read_set"`: explicit files or bounded glob patterns to import.
  - `"commands"`: virtual shell commands to execute in order.
  - `"limits"`: optional numeric overrides for the built-in default limits.
  """
  @spec run(String.t(), map(), keyword()) :: {:ok, map()} | {:error, map()}
  def run(workspace, params, opts \\ [])

  def run(workspace, params, opts) when is_binary(workspace) and is_map(params) do
    with {:ok, limits} <- limits(Map.get(params, "limits", Keyword.get(opts, :limits, %{}))),
         {:ok, read_set} <- string_list(params, "read_set"),
         {:ok, commands} <- string_list(params, "commands"),
         :ok <- enforce_command_limit(commands, limits),
         {:ok, imported, import_meta, caveats} <- import_read_set(workspace, read_set, limits) do
      run_import(imported, import_meta, commands, limits, caveats, opts)
    end
  end

  def run(_workspace, _params, _opts),
    do: {:error, Tool.error(:invalid_args, "virtual_overlay requires workspace and params", %{})}

  defp run_import(imported, import_meta, commands, limits, caveats, opts) do
    before_files = Map.new(imported)

    bash =
      JustBash.new(
        files: virtual_files(before_files),
        cwd: @workspace_root,
        commands: %{},
        network: %{enabled: false, allow_list: [], allow_insecure: false},
        limits: Keyword.get(opts, :bashex_limits, :default)
      )

    started_at = monotonic_ms()
    {command_results, bash} = run_commands(bash, commands, limits)
    after_files = exported_files(bash.fs)
    changes = changes(before_files, after_files, limits)

    {:ok,
     %{
       "kind" => "virtual_diff",
       "version" => @version,
       "workspace_strategy" => "virtual_overlay",
       "workspace_fidelity" => "virtual_shell_no_host_binaries",
       "parent_workspace" => %{
         "mutation" => "none",
         "evidence" => "virtual writes only; no parent apply was attempted"
       },
       "import" => import_meta,
       "commands" => command_results,
       "summary" => summary(changes),
       "changes" => changes,
       "limits" => public_limits(limits),
       "caveats" => caveats,
       "apply" => %{"status" => "not_applied", "requires_explicit_apply" => true},
       "elapsed_ms" => monotonic_ms() - started_at
     }}
  end

  defp string_list(params, key) do
    case Map.get(params, key, []) do
      values when is_list(values) ->
        if Enum.all?(values, &is_binary/1) do
          {:ok, Enum.reject(values, &(String.trim(&1) == ""))}
        else
          invalid_string_list(key, values)
        end

      value ->
        invalid_string_list(key, value)
    end
  end

  defp invalid_string_list(key, value) do
    {:error,
     Tool.error(:invalid_args, "virtual_overlay #{key} must be a list of strings", %{
       "field" => key,
       "value" => inspect(value)
     })}
  end

  defp limits(raw) do
    with {:ok, overrides} <- normalize_limit_map(raw) do
      Enum.reduce_while(overrides, {:ok, default_limits()}, fn {key, value}, {:ok, acc} ->
        cond do
          not Map.has_key?(default_limits(), key) ->
            {:halt,
             {:error,
              Tool.error(:invalid_args, "unknown virtual_overlay limit", %{
                "field" => to_string(key)
              })}}

          is_integer(value) and value >= 0 ->
            {:cont, {:ok, Map.put(acc, key, value)}}

          true ->
            {:halt,
             {:error,
              Tool.error(:invalid_args, "virtual_overlay limit must be a non-negative integer", %{
                "field" => to_string(key),
                "value" => inspect(value)
              })}}
        end
      end)
    end
  end

  defp default_limits, do: @default_limits

  defp normalize_limit_map(nil), do: {:ok, %{}}
  defp normalize_limit_map(raw) when is_map(raw), do: {:ok, Map.new(raw, &normalize_limit/1)}

  defp normalize_limit_map(raw) when is_list(raw) do
    if Enum.all?(raw, &kv_pair?/1) do
      raw |> Map.new() |> normalize_limit_map()
    else
      limits_shape_error(raw)
    end
  end

  defp normalize_limit_map(raw), do: limits_shape_error(raw)

  defp limits_shape_error(raw) do
    {:error,
     Tool.error(:invalid_args, "virtual_overlay limits must be a map", %{
       "field" => "limits",
       "value" => inspect(raw)
     })}
  end

  defp normalize_limit({key, value}) when is_atom(key), do: {key, value}

  defp normalize_limit({key, value}) when is_binary(key) do
    atom_key =
      default_limits()
      |> Map.keys()
      |> Enum.find(&(Atom.to_string(&1) == key))

    {atom_key || key, value}
  end

  defp kv_pair?({_key, _value}), do: true
  defp kv_pair?(_value), do: false

  defp enforce_command_limit(commands, limits) do
    if length(commands) <= limits.max_virtual_commands do
      :ok
    else
      {:error,
       Tool.error(:invalid_args, "virtual_overlay command limit exceeded", %{
         "max_virtual_commands" => limits.max_virtual_commands,
         "command_count" => length(commands)
       })}
    end
  end

  defp import_read_set(workspace, read_set, limits) do
    root = Path.expand(workspace)

    with {:ok, paths, caveats} <- expand_read_set(root, read_set),
         :ok <- enforce_import_count(paths, limits) do
      paths
      |> Enum.reduce_while({:ok, [], 0}, fn {rel, abs}, {:ok, acc, total_bytes} ->
        case import_file(rel, abs, total_bytes, limits) do
          {:ok, entry, next_total} -> {:cont, {:ok, [entry | acc], next_total}}
          {:error, error} -> {:halt, {:error, error}}
        end
      end)
      |> case do
        {:ok, imported, byte_count} ->
          imported = Enum.reverse(imported)

          {:ok, imported,
           %{
             "read_set" => read_set,
             "file_count" => length(imported),
             "byte_count" => byte_count,
             "truncated" => false
           }, caveats}

        {:error, error} ->
          {:error, error}
      end
    end
  end

  defp expand_read_set(root, read_set) do
    read_set
    |> Enum.reduce_while({:ok, [], []}, fn entry, {:ok, acc, caveats} ->
      case expand_entry(root, entry) do
        {:ok, [], [caveat]} -> {:cont, {:ok, acc, [caveat | caveats]}}
        {:ok, paths, []} -> {:cont, {:ok, acc ++ paths, caveats}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, paths, caveats} ->
        paths =
          paths
          |> Enum.uniq_by(fn {rel, _abs} -> rel end)
          |> Enum.sort_by(fn {rel, _abs} -> rel end)

        {:ok, paths, Enum.reverse(caveats)}

      {:error, error} ->
        {:error, error}
    end
  end

  defp expand_entry(root, entry) do
    if glob?(entry) do
      pattern = Path.expand(entry, root)

      with :ok <- ensure_under_root(pattern, root, entry) do
        confined =
          pattern
          |> Path.wildcard()
          |> Enum.filter(&File.regular?/1)
          |> Enum.map(&confine_existing_file(root, &1, relative!(&1, root)))
          |> collect_results()

        if confined == {:ok, []} do
          {:ok, [], [%{"kind" => "read_set_no_matches", "path" => entry}]}
        else
          with {:ok, matches} <- confined do
            {:ok, matches, []}
          end
        end
      end
    else
      with {:ok, match} <- confine_existing_file(root, entry, entry) do
        {:ok, [match], []}
      end
    end
  end

  defp collect_results(results) do
    Enum.reduce_while(results, {:ok, []}, fn
      {:ok, value}, {:ok, acc} -> {:cont, {:ok, [value | acc]}}
      {:error, error}, {:ok, _acc} -> {:halt, {:error, error}}
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      {:error, error} -> {:error, error}
    end
  end

  defp confine_existing_file(root, path, original) do
    with {:ok, abs} <- Workspace.confine(root, path),
         :ok <- reject_symlinked_path(root, abs, original),
         true <- File.regular?(abs) || {:error, file_not_found(original)},
         :ok <- ensure_under_root(abs, root, original) do
      {:ok, {relative!(abs, root), abs}}
    else
      {:error, %{error: _} = error} ->
        {:error, stringify_error_details(error)}

      {:error, reason} ->
        {:error,
         Tool.error(:read_failed, "could not resolve read_set file", %{
           "path" => original,
           "filesystem_reason" => inspect(reason)
         })}
    end
  end

  defp reject_symlinked_path(root, abs, original) do
    root = Path.expand(root)
    abs = Path.expand(abs)

    abs
    |> Path.relative_to(root)
    |> Path.split()
    |> Enum.scan(root, &Path.join(&2, &1))
    |> Enum.reduce_while(:ok, fn candidate, :ok ->
      case File.lstat(candidate) do
        {:ok, %{type: :symlink}} ->
          {:halt,
           {:error,
            Tool.error(:outside_workspace, "read_set symlinks are not importable", %{
              "path" => original
            })}}

        {:ok, _stat} ->
          {:cont, :ok}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp glob?(entry), do: String.contains?(entry, ["*", "?", "["])

  defp ensure_under_root(abs_pattern, root, original) do
    if under_path?(abs_pattern, root) do
      :ok
    else
      {:error,
       Tool.error(:outside_workspace, "path escapes the workspace", %{"path" => original})}
    end
  end

  defp file_not_found(path) do
    Tool.error(:read_failed, "read_set entry is not a regular file", %{"path" => path})
  end

  defp enforce_import_count(paths, limits) do
    if length(paths) <= limits.max_import_files do
      :ok
    else
      {:error,
       Tool.error(:invalid_args, "virtual_overlay import file limit exceeded", %{
         "max_import_files" => limits.max_import_files,
         "file_count" => length(paths)
       })}
    end
  end

  defp stringify_error_details(%{error: %{details: details}} = error) when is_map(details) do
    update_in(error, [:error, :details], &stringify_keys/1)
  end

  defp stringify_error_details(error), do: error

  defp import_file(rel, abs, total_bytes, limits) do
    with {:ok, content} <- File.read(abs),
         size = byte_size(content),
         :ok <- enforce_file_size(rel, size, limits),
         :ok <- enforce_total_size(rel, total_bytes + size, limits) do
      {:ok, {rel, content}, total_bytes + byte_size(content)}
    else
      {:error, %{error: _} = error} ->
        {:error, error}

      {:error, reason} ->
        {:error,
         Tool.error(:read_failed, "could not import read_set file", %{
           "path" => rel,
           "filesystem_reason" => inspect(reason)
         })}
    end
  end

  defp enforce_file_size(_rel, size, limits) when size <= limits.max_file_bytes, do: :ok

  defp enforce_file_size(rel, size, limits) do
    {:error,
     Tool.error(:invalid_args, "virtual_overlay file limit exceeded", %{
       "path" => rel,
       "max_file_bytes" => limits.max_file_bytes,
       "byte_count" => size
     })}
  end

  defp enforce_total_size(_rel, size, limits) when size <= limits.max_import_bytes, do: :ok

  defp enforce_total_size(rel, size, limits) do
    {:error,
     Tool.error(:invalid_args, "virtual_overlay import byte limit exceeded", %{
       "path" => rel,
       "max_import_bytes" => limits.max_import_bytes,
       "byte_count" => size
     })}
  end

  defp virtual_files(files) do
    Map.new(files, fn {rel, content} -> {virtual_path(rel), content} end)
  end

  defp run_commands(bash, commands, limits) do
    commands
    |> Enum.with_index(1)
    |> Enum.map_reduce(bash, fn {command, index}, current ->
      started_at = monotonic_ms()
      {result, next} = JustBash.exec(current, command)

      command_result = %{
        "id" => "cmd_#{index}",
        "display" => command,
        "status" => if(result.exit_code == 0, do: "ok", else: "exit"),
        "exit_code" => result.exit_code,
        "stdout" => truncate(result.stdout, limits.max_output_bytes),
        "stderr" => truncate(result.stderr, limits.max_output_bytes),
        "elapsed_ms" => monotonic_ms() - started_at,
        "stats" => stringify_keys(JustBash.stats(next))
      }

      {command_result, next}
    end)
  end

  defp exported_files(fs) do
    fs
    |> InMemoryFs.get_all_paths()
    |> Enum.filter(&under_path?(&1, @workspace_root))
    |> Enum.reduce(%{}, fn path, acc ->
      case InMemoryFs.read_file(fs, path) do
        {:ok, content} -> Map.put(acc, virtual_relative!(path), content)
        {:error, _reason} -> acc
      end
    end)
  end

  defp changes(before_files, after_files, limits) do
    before_paths = before_files |> Map.keys() |> MapSet.new()
    after_paths = after_files |> Map.keys() |> MapSet.new()

    before_paths
    |> MapSet.union(after_paths)
    |> MapSet.to_list()
    |> Enum.sort()
    |> Enum.flat_map(fn path ->
      before = Map.get(before_files, path)
      after_content = Map.get(after_files, path)

      if before == after_content do
        []
      else
        [change(path, before, after_content, limits)]
      end
    end)
  end

  defp change(path, before, after_content, limits) do
    operation = operation(before, after_content)
    base = %{"path" => path, "operation" => operation}
    base = maybe_put(base, "before", content_meta(before))
    base = maybe_put(base, "after", content_meta(after_content))

    cond do
      not text_content?(before) or not text_content?(after_content) ->
        Map.put(base, "caveats", ["binary_or_non_text_change_unsupported"])

      true ->
        {diff_text, truncated} = diff(path, before || "", after_content || "", operation, limits)

        Map.put(base, "diff", %{
          "format" => "unified",
          "text" => diff_text,
          "truncated" => truncated
        })
    end
  end

  defp operation(nil, _after), do: "add"
  defp operation(_before, nil), do: "delete"
  defp operation(_before, _after), do: "modify"

  defp content_meta(nil), do: nil

  defp content_meta(content) do
    %{
      "sha256" => sha256(content),
      "byte_count" => byte_size(content)
    }
  end

  defp text_content?(nil), do: true
  defp text_content?(content), do: String.valid?(content)

  defp diff(path, before, after_content, operation, limits) do
    header =
      case operation do
        "add" -> "--- /dev/null\n+++ b/#{path}\n"
        "delete" -> "--- a/#{path}\n+++ /dev/null\n"
        _ -> "--- a/#{path}\n+++ b/#{path}\n"
      end

    before_lines = line_list(before)
    after_lines = line_list(after_content)

    body =
      [
        "@@ -1,#{length(before_lines)} +1,#{length(after_lines)} @@\n",
        Enum.map_join(before_lines, "", &("-" <> &1)),
        Enum.map_join(after_lines, "", &("+" <> &1))
      ]
      |> IO.iodata_to_binary()

    truncate_with_flag(header <> body, limits.max_diff_bytes)
  end

  defp line_list(""), do: []

  defp line_list(content) do
    lines = String.split(content, "\n", trim: false)
    final_index = length(lines) - 1

    lines
    |> Enum.with_index()
    |> Enum.flat_map(fn
      {"", ^final_index} -> []
      {line, ^final_index} -> [line]
      {line, _index} -> [line <> "\n"]
    end)
  end

  defp summary(changes) do
    %{
      "files_added" => Enum.count(changes, &(&1["operation"] == "add")),
      "files_modified" => Enum.count(changes, &(&1["operation"] == "modify")),
      "files_deleted" => Enum.count(changes, &(&1["operation"] == "delete")),
      "files_unsupported" => Enum.count(changes, &Map.has_key?(&1, "caveats")),
      "diff_bytes" => Enum.reduce(changes, 0, &(&2 + diff_bytes(&1))),
      "truncated" => Enum.any?(changes, &(get_in(&1, ["diff", "truncated"]) == true))
    }
  end

  defp diff_bytes(%{"diff" => %{"text" => text}}), do: byte_size(text)
  defp diff_bytes(_change), do: 0

  defp public_limits(limits), do: Map.put(stringify_keys(limits), "profile", "default")

  defp stringify_keys(map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp virtual_path(rel), do: Path.join(@workspace_root, rel)

  defp virtual_relative!(path) do
    path
    |> String.replace_prefix(@workspace_root <> "/", "")
    |> String.replace_prefix(@workspace_root, "")
  end

  defp relative!(path, root), do: Path.relative_to(Path.expand(path), root)

  defp under_path?(path, root) do
    expanded_path = Path.expand(path)
    expanded_root = Path.expand(root)
    expanded_path == expanded_root or String.starts_with?(expanded_path, expanded_root <> "/")
  end

  defp sha256(content), do: :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)

  defp truncate(text, max_bytes), do: elem(truncate_with_flag(text, max_bytes), 0)

  defp truncate_with_flag(text, max_bytes) do
    text = String.replace_invalid(text)

    if byte_size(text) > max_bytes do
      {take_utf8_prefix(text, max_bytes), true}
    else
      {text, false}
    end
  end

  defp take_utf8_prefix(_text, 0), do: ""

  defp take_utf8_prefix(text, max_bytes) do
    text
    |> String.graphemes()
    |> Enum.reduce_while("", fn grapheme, acc ->
      next = acc <> grapheme

      if byte_size(next) > max_bytes do
        {:halt, acc}
      else
        {:cont, next}
      end
    end)
  end

  defp monotonic_ms, do: System.monotonic_time(:millisecond)
end
