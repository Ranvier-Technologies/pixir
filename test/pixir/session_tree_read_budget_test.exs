defmodule Pixir.SessionTreeReadBudgetTest do
  use ExUnit.Case, async: false

  alias Pixir.{Event, Log, SessionTree}

  setup do
    workspace =
      Path.join(System.tmp_dir!(), "pixir-tree-budget-#{System.unique_integer([:positive])}")

    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf!(workspace) end)
    %{ws: workspace}
  end

  test "a fork fanout folds each candidate Log only once per projection", %{ws: ws} do
    write_log(ws, "root", [Event.user_message("root", "start", seq: 0)])

    for i <- 1..12 do
      id = "child-#{i}"
      write_log(ws, id, [fork_event(id, "root", ws, i), Event.user_message(id, "child", seq: 1)])
    end

    {{:ok, tree}, calls} = capture_folds(fn -> SessionTree.project("root", workspace: ws) end)

    assert Enum.map(tree["forks"], & &1["child_session_id"]) == Enum.map(1..12, &"child-#{&1}")
    assert Enum.all?(tree["forks"], &(&1["session"]["event_count"] == 2))
    assert map_size(calls) == 13
    assert Enum.all?(calls, fn {_identity, count} -> count == 1 end), inspect(calls)
  end

  test "shared children are reused without becoming cycles and identities include Workspace", %{
    ws: ws
  } do
    other = Path.join(ws, "other")

    write_log(ws, "root", [
      child_event("root", "a", "same", ws, 0),
      child_event("root", "b", "same", other, 1),
      child_event("root", "c", "same", ws, 2)
    ])

    write_log(ws, "same", [Event.user_message("same", "one", seq: 0)])

    write_log(other, "same", [
      Event.user_message("same", "one", seq: 0),
      Event.assistant_message("same", "two", seq: 1)
    ])

    {{:ok, tree}, calls} = capture_folds(fn -> SessionTree.project("root", workspace: ws) end)
    assert [a, b, c] = tree["subagents"]
    assert a["session"] == c["session"]
    assert a["session"]["event_count"] == 1
    assert b["session"]["event_count"] == 2
    refute Map.has_key?(c["session"], "cycle")
    assert calls == %{{"root", ws} => 1, {"same", ws} => 1, {"same", other} => 1}
  end

  test "a new projection observes appended events and newly discovered forks", %{ws: ws} do
    write_log(ws, "root", [Event.user_message("root", "start", seq: 0)])
    assert {:ok, first} = SessionTree.project("root", workspace: ws)
    assert first["forks"] == []

    assert {:ok, _} = Log.append(Event.assistant_message("root", "fresh", seq: 1), workspace: ws)
    write_log(ws, "child", [fork_event("child", "root", ws, 1)])
    assert {:ok, second} = SessionTree.project("root", workspace: ws)
    assert second["event_count"] == 2
    assert [%{"child_session_id" => "child"}] = second["forks"]
  end

  test "small projection facts do not retain large discarded conversation buffers", %{ws: ws} do
    timestamp = "2026-09-04T12:00:00.000000Z"
    task = String.duplicate("task", 32)

    child =
      child_event("root", "missing", "missing", ws, 1)
      |> Map.update!(:data, &Map.put(&1, "task", task))

    write_log(ws, "root", [
      Event.user_message("root", String.duplicate("x", 256_000), seq: 0, ts: timestamp),
      child
    ])

    assert {:ok, tree} = SessionTree.project("root", workspace: ws)
    assert tree["first_event_ts"] == timestamp
    projected_task = hd(tree["subagents"])["task"]
    assert projected_task == task
    assert :binary.referenced_byte_size(projected_task) == byte_size(task)
  end

  test "unrelated lifecycle data is not interpreted while indexing fork candidates", %{ws: ws} do
    write_log(ws, "root", [Event.user_message("root", "start", seq: 0)])
    malformed = Event.subagent_event("unrelated", %{}, seq: 0) |> Map.put(:data, "not-a-map")
    write_log(ws, "unrelated", [malformed])

    assert {:ok, %{"forks" => [], "subagents" => []}} = SessionTree.project("root", workspace: ws)
  end

  test "unrelated corrupt candidates are ignored but a referenced corrupt Log returns its error",
       %{ws: ws} do
    write_log(ws, "root", [Event.user_message("root", "start", seq: 0)])
    bad = Log.path("bad", workspace: ws)
    File.write!(bad, "not-json\n")
    assert {:ok, %{"forks" => []}} = SessionTree.project("root", workspace: ws)

    assert {:ok, _} = Log.append(child_event("root", "bad-child", "bad", ws, 1), workspace: ws)

    assert {:error, %{error: %{kind: :corrupt_log_line}}} =
             SessionTree.project("root", workspace: ws)

    write_log(ws, "bad", [Event.user_message("bad", "repaired", seq: 0)])
    assert {:ok, tree} = SessionTree.project("root", workspace: ws)
    assert hd(tree["subagents"])["session"]["event_count"] == 1
  end

  test "cycles stay path-local and depth bounds avoid reading a truncated external Workspace", %{
    ws: ws
  } do
    other = Path.join(ws, "other")
    write_log(ws, "root", [child_event("root", "child", "child", other, 0)])
    write_log(other, "child", [child_event("child", "back", "root", ws, 0)])

    assert {:ok, tree} = SessionTree.project("root", workspace: ws)

    cycle =
      tree["subagents"]
      |> hd()
      |> get_in(["session", "subagents"])
      |> hd()
      |> Map.fetch!("session")

    assert cycle["cycle"] == true
    assert cycle["truncated_reason"] == "cycle"

    {{:ok, bounded}, calls} =
      capture_folds(fn -> SessionTree.project("root", workspace: ws, max_depth: 0) end)

    child = hd(bounded["subagents"])["session"]
    assert child["truncated_reason"] == "max_depth"
    assert child["log_exists"] == true
    assert calls == %{{"root", ws} => 1}
  end

  test "self forks remain excluded and the first seq-zero lineage and branch summary win", %{
    ws: ws
  } do
    write_log(ws, "root", [fork_event("root", "root", ws, 0)])

    write_log(ws, "child", [
      fork_event("child", "root", ws, 2),
      fork_event("child", "ignored", ws, 1),
      Event.branch_summary("child", %{"strategy" => "first", "limitations" => []}, seq: 1),
      Event.branch_summary("child", %{"strategy" => "later"}, seq: 2)
    ])

    assert {:ok, tree} = SessionTree.project("root", workspace: ws)
    assert [fork] = tree["forks"]
    assert fork["child_session_id"] == "child"
    assert fork["forked_to_seq"] == 2

    assert fork["branch_summary"] == %{
             "present" => true,
             "strategy" => "first",
             "limitations" => []
           }
  end

  test "cached candidates do not bypass symlink rejection for referenced Logs", %{ws: ws} do
    write_log(ws, "root", [Event.user_message("root", "start", seq: 0)])
    write_log(ws, "target", [Event.user_message("target", "safe", seq: 0)])
    assert :ok = File.ln_s(Log.path("target", workspace: ws), Log.path("link", workspace: ws))
    assert {:ok, _} = SessionTree.project("root", workspace: ws)
    assert {:ok, _} = Log.append(child_event("root", "link", "link", ws, 1), workspace: ws)
    assert {:error, error} = SessionTree.project("root", workspace: ws)
    assert {:error, ^error} = Log.exists("link", workspace: ws)
  end

  defp write_log(workspace, id, events) do
    file = Log.path(id, workspace: workspace)
    File.mkdir_p!(Path.dirname(file))
    File.write!(file, Enum.map(events, &[Jason.encode!(&1), "\n"]))
  end

  defp fork_event(id, parent, workspace, to_seq) do
    Event.new(
      id,
      :session_fork,
      %{"parent_session_id" => parent, "child_workspace" => workspace, "forked_to_seq" => to_seq},
      seq: 0
    )
  end

  defp child_event(id, subagent, child, workspace, seq) do
    Event.subagent_event(
      id,
      %{
        "subagent_id" => subagent,
        "child_session_id" => child,
        "workspace" => workspace,
        "event" => "started"
      },
      seq: seq
    )
  end

  defp capture_folds(fun) do
    Code.ensure_loaded!(Log)
    traced = self()
    tracer = spawn(fn -> collect_folds(%{}) end)
    :erlang.trace_pattern({Log, :fold, 2}, true, [])
    :erlang.trace(traced, true, [:call, {:tracer, tracer}])

    try do
      result = fun.()
      delivered = :erlang.trace_delivered(traced)
      assert_receive {:trace_delivered, ^traced, ^delivered}, 1_000
      send(tracer, {:counts, self()})
      assert_receive {:fold_counts, counts}, 1_000
      {result, counts}
    after
      :erlang.trace(traced, false, [:call])
      :erlang.trace_pattern({Log, :fold, 2}, false, [])
      Process.exit(tracer, :kill)
    end
  end

  defp collect_folds(counts) do
    receive do
      {:trace, _pid, :call, {Log, :fold, [id, opts]}} ->
        key = {id, Keyword.fetch!(opts, :workspace)}
        collect_folds(Map.update(counts, key, 1, &(&1 + 1)))

      {:counts, caller} ->
        send(caller, {:fold_counts, counts})
        collect_folds(counts)
    end
  end
end
