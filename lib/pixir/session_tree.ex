defmodule Pixir.SessionTree do
  @moduledoc """
  Read-only Session tree projection over Pixir Logs.

  This module does not create a second message store. It folds each Session's Log,
  reads durable `subagent_event` and `session_fork` facts, and projects parent/child
  relationships for presenters and diagnostics.
  """

  alias Pixir.{Log, Paths, SessionId, Tool}

  @default_max_depth 4

  @doc """
  Project one root Session into a JSON-serializable tree.

  The root Session must have a Log in `opts[:workspace]`. Child Sessions referenced by
  Subagent lifecycle events or fork lineage may be missing; those are represented
  honestly with `"log_exists" => false`. Fork children are discovered by scanning
  workspace Logs for `session_fork.parent_session_id` (ADR 0024).
  """
  @spec project(String.t(), keyword()) :: {:ok, map()} | {:error, map()}
  def project(session_id, opts \\ [])

  def project(session_id, opts) when is_binary(session_id) do
    workspace = opts |> Keyword.get(:workspace, File.cwd!()) |> Path.expand()
    max_depth = Keyword.get(opts, :max_depth, @default_max_depth)

    with :ok <- SessionId.validate(session_id) do
      case Log.exists(session_id, workspace: workspace) do
        {:ok, true} ->
          build_node(session_id, workspace, 0, max_depth, MapSet.new())

        {:ok, false} ->
          {:error,
           Tool.error(:not_found, "session log was not found", %{
             session_id: session_id,
             workspace: workspace,
             log_path: Log.path(session_id, workspace: workspace),
             next_actions: [
               "check the session id",
               "run pixir tree from the workspace that owns the session log"
             ]
           })}

        {:error, _error} = error ->
          error
      end
    end
  end

  def project(_session_id, _opts),
    do: {:error, Tool.error(:invalid_args, "session id must be a string", %{})}

  @doc "Render a compact human-readable tree."
  @spec render(map()) :: String.t()
  def render(tree) when is_map(tree) do
    tree
    |> render_session([], true)
    |> Enum.reverse()
    |> Enum.join("\n")
    |> Kernel.<>("\n")
  end

  defp build_node(session_id, workspace, depth, max_depth, seen) do
    with :ok <- SessionId.validate(session_id),
         {:ok, log_exists?} <- Log.exists(session_id, workspace: workspace) do
      do_build_node(session_id, workspace, depth, max_depth, seen, log_exists?)
    end
  end

  defp do_build_node(session_id, workspace, depth, max_depth, seen, log_exists?) do
    key = {session_id, workspace}
    log_path = Log.path(session_id, workspace: workspace)

    cond do
      MapSet.member?(seen, key) ->
        {:ok,
         base_node(session_id, workspace, log_path, false)
         |> Map.put("cycle", true)
         |> Map.put("truncated_reason", "cycle")}

      depth > max_depth ->
        {:ok,
         base_node(session_id, workspace, log_path, log_exists?)
         |> Map.put("truncated", true)
         |> Map.put("truncated_reason", "max_depth")}

      not log_exists? ->
        {:ok, base_node(session_id, workspace, log_path, false)}

      true ->
        with {:ok, history} <- Log.fold(session_id, workspace: workspace) do
          subagents = subagent_records(history)
          forks = fork_records(session_id, workspace)
          seen = MapSet.put(seen, key)

          with {:ok, subagents} <- attach_child_sessions(subagents, depth, max_depth, seen),
               {:ok, forks} <- attach_fork_sessions(forks, depth, max_depth, seen) do
            {:ok,
             base_node(session_id, workspace, log_path, true)
             |> Map.merge(%{
               "event_count" => length(history),
               "event_counts" => event_counts(history),
               "first_event_ts" => first_event_ts(history),
               "last_event_ts" => last_event_ts(history),
               "subagents" => subagents,
               "forks" => forks
             })}
          end
        end
    end
  end

  defp attach_fork_sessions(records, depth, max_depth, seen) do
    Enum.reduce_while(records, {:ok, []}, fn record, {:ok, acc} ->
      child_sid = record["child_session_id"]
      child_workspace = record["workspace"]

      child_result =
        if present?(child_sid) and present?(child_workspace) do
          build_node(child_sid, Path.expand(child_workspace), depth + 1, max_depth, seen)
        else
          {:ok, nil}
        end

      case child_result do
        {:ok, child} -> {:cont, {:ok, [Map.put(record, "session", child) | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, records} -> {:ok, Enum.reverse(records)}
      {:error, _} = error -> error
    end
  end

  defp attach_child_sessions(records, depth, max_depth, seen) do
    Enum.reduce_while(records, {:ok, []}, fn record, {:ok, acc} ->
      child_sid = record["child_session_id"]
      child_workspace = record["workspace"]

      child_result =
        if present?(child_sid) and present?(child_workspace) do
          build_node(child_sid, Path.expand(child_workspace), depth + 1, max_depth, seen)
        else
          {:ok, nil}
        end

      case child_result do
        {:ok, child} -> {:cont, {:ok, [Map.put(record, "session", child) | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, records} -> {:ok, Enum.reverse(records)}
      {:error, _} = error -> error
    end
  end

  defp fork_records(parent_session_id, workspace) do
    workspace
    |> Paths.sessions_dir()
    |> list_session_ids()
    |> Enum.flat_map(&fork_child_record(parent_session_id, &1, workspace))
    |> Enum.sort_by(&{seq_sort_key(&1["forked_to_seq"]), &1["child_session_id"]})
  end

  defp list_session_ids(dir) do
    case File.ls(dir) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.ends_with?(&1, ".ndjson"))
        |> Enum.map(&String.trim_trailing(&1, ".ndjson"))

      {:error, _} ->
        []
    end
  end

  defp fork_child_record(parent_session_id, child_session_id, workspace) do
    with true <- child_session_id != parent_session_id,
         {:ok, history} <- Log.fold(child_session_id, workspace: workspace),
         %{data: data} when is_map(data) <-
           Enum.find(history, &(&1.type == :session_fork and &1.seq == 0)),
         true <- data["parent_session_id"] == parent_session_id do
      [
        %{
          "child_session_id" => child_session_id,
          "parent_session_id" => data["parent_session_id"],
          "fork_root_session_id" => data["fork_root_session_id"],
          "forked_to_seq" => data["forked_to_seq"],
          "replay_event_count" => data["replay_event_count"],
          "from_seq" => data["from_seq"],
          "strategy" => data["strategy"],
          "workspace" => data["child_workspace"] || workspace,
          "branch_summary" => branch_summary_fact(history)
        }
      ]
    else
      _ -> []
    end
  end

  defp branch_summary_fact(history) do
    case Enum.find(history, &(&1.type == :branch_summary)) do
      %{data: data} when is_map(data) ->
        %{
          "present" => true,
          "strategy" => data["strategy"],
          "limitations" => data["limitations"]
        }

      _ ->
        %{"present" => false}
    end
  end

  defp subagent_records(history) do
    history
    |> Enum.filter(&(&1.type == :subagent_event))
    |> Enum.reduce(%{}, fn event, acc ->
      data = event.data
      id = data["subagent_id"]

      if present?(id) do
        current =
          Map.get(acc, id, %{
            "subagent_id" => id,
            "events" => [],
            "first_seq" => event.seq,
            "last_seq" => event.seq
          })

        updated =
          current
          |> Map.merge(Map.take(data, subagent_fields()))
          |> alias_subagent_session_id()
          |> Map.put("events", append_event(current["events"], data["event"]))
          |> Map.put("first_seq", min_seq(current["first_seq"], event.seq))
          |> Map.put("last_seq", max_seq(current["last_seq"], event.seq))

        Map.put(acc, id, updated)
      else
        acc
      end
    end)
    |> Map.values()
    |> Enum.sort_by(&{seq_sort_key(&1["first_seq"]), &1["subagent_id"]})
  end

  defp alias_subagent_session_id(%{"child_session_id" => child_session_id} = record)
       when not is_nil(child_session_id) do
    if is_nil(Map.get(record, "session_id")) do
      Map.put(record, "session_id", child_session_id)
    else
      record
    end
  end

  defp alias_subagent_session_id(record), do: record

  defp base_node(session_id, workspace, log_path, log_exists?) do
    %{
      "session_id" => session_id,
      "workspace" => workspace,
      "log_path" => log_path,
      "log_exists" => log_exists?,
      "event_count" => 0,
      "event_counts" => %{},
      "first_event_ts" => nil,
      "last_event_ts" => nil,
      "subagents" => [],
      "forks" => []
    }
  end

  defp event_counts(history) do
    history
    |> Enum.frequencies_by(&Atom.to_string(&1.type))
    |> Enum.into(%{})
  end

  defp first_event_ts([]), do: nil
  defp first_event_ts([event | _]), do: event.ts

  defp last_event_ts([]), do: nil
  defp last_event_ts(history), do: history |> List.last() |> Map.get(:ts)

  defp render_session(node, acc, root?) do
    label =
      if root? do
        "session #{node["session_id"]}"
      else
        "child session #{node["session_id"]}"
      end

    status =
      if node["log_exists"] do
        "events=#{node["event_count"]}"
      else
        "log=missing"
      end

    acc = ["#{label} (#{status})" | acc]
    acc = ["  workspace: #{node["workspace"]}" | acc]

    acc =
      node["subagents"]
      |> Enum.with_index()
      |> Enum.reduce(acc, fn {subagent, index}, lines ->
        last? = index == length(node["subagents"]) - 1 and node["forks"] == []
        render_subagent(subagent, lines, if(last?, do: "`--", else: "|--"))
      end)

    node["forks"]
    |> Enum.with_index()
    |> Enum.reduce(acc, fn {fork, index}, lines ->
      last? = index == length(node["forks"]) - 1
      render_fork(fork, lines, if(last?, do: "`--", else: "|--"))
    end)
  end

  defp render_fork(fork, acc, branch) do
    header =
      "#{branch} fork #{fork["child_session_id"]} (forked_to_seq=#{fork["forked_to_seq"]})"

    acc = [header | acc]
    acc = maybe_line(acc, "    fork_root: ", fork["fork_root_session_id"])
    acc = maybe_line(acc, "    replay_events: ", fork["replay_event_count"])
    acc = maybe_line(acc, "    strategy: ", fork["strategy"])

    acc =
      if fork["branch_summary"]["present"] do
        ["    branch_summary: present" | acc]
      else
        ["    branch_summary: none" | acc]
      end

    case fork["session"] do
      nil -> acc
      child -> render_nested_child(child, acc)
    end
  end

  defp render_subagent(subagent, acc, branch) do
    header =
      [
        "#{branch} subagent #{subagent["subagent_id"]}",
        maybe_paren(subagent["agent"]),
        maybe_status(subagent["status"])
      ]
      |> Enum.reject(&(&1 == ""))
      |> Enum.join(" ")

    acc = [header | acc]
    acc = maybe_line(acc, "    index: ", subagent["index"])
    acc = maybe_line(acc, "    child_session: ", subagent["child_session_id"])
    acc = maybe_line(acc, "    child_log: ", subagent["child_log_path"])
    acc = maybe_line(acc, "    task: ", subagent["task"])
    acc = maybe_line(acc, "    summary: ", subagent["summary"])
    acc = maybe_line(acc, "    reason: ", subagent["reason"])
    acc = maybe_line(acc, "    elapsed_ms: ", subagent["elapsed_ms"])
    acc = maybe_line(acc, "    timeout_ms: ", subagent["timeout_ms"])
    acc = maybe_line(acc, "    deadline_at: ", subagent["deadline_at"])
    acc = ["    events: #{Enum.join(subagent["events"], " -> ")}" | acc]

    case subagent["session"] do
      nil -> acc
      child -> render_nested_child(child, acc)
    end
  end

  defp render_nested_child(child, acc) do
    child_lines =
      child
      |> render_session([], false)
      |> Enum.reverse()
      |> Enum.map(&("    " <> &1))

    Enum.reduce(child_lines, acc, fn line, lines -> [line | lines] end)
  end

  defp maybe_line(acc, _prefix, nil), do: acc
  defp maybe_line(acc, _prefix, ""), do: acc
  defp maybe_line(acc, prefix, value), do: [prefix <> to_string(value) | acc]

  defp maybe_paren(nil), do: ""
  defp maybe_paren(""), do: ""
  defp maybe_paren(value), do: "(#{value})"

  defp maybe_status(nil), do: ""
  defp maybe_status(""), do: ""
  defp maybe_status(value), do: "status=#{value}"

  defp append_event(events, nil), do: events
  defp append_event(events, event), do: events ++ [event]

  defp subagent_fields do
    [
      "child_session_id",
      "agent",
      "status",
      "task",
      "depth",
      "max_depth",
      "workspace",
      "index",
      "parent_log_path",
      "child_log_path",
      "summary",
      "event",
      "timeout_ms",
      "deadline_at",
      "elapsed_ms",
      "reason",
      "next_actions"
    ]
  end

  defp present?(value), do: is_binary(value) and String.trim(value) != ""

  defp min_seq(nil, seq), do: seq
  defp min_seq(seq, nil), do: seq
  defp min_seq(left, right), do: min(left, right)

  defp max_seq(nil, seq), do: seq
  defp max_seq(seq, nil), do: seq
  defp max_seq(left, right), do: max(left, right)

  defp seq_sort_key(nil), do: 9_999_999_999
  defp seq_sort_key(seq), do: seq
end
