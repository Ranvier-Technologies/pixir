defmodule Pixir.SessionIdSurfacesTest do
  use ExUnit.Case, async: false

  alias Pixir.{
    Compaction,
    Conversation,
    Event,
    Fork,
    Log,
    Paths,
    ReplayInspector,
    SessionDiagnostics,
    SessionLease,
    SessionResources,
    Session,
    SessionSupervisor,
    SessionTree,
    Subagents,
    Workflows
  }

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "pixir-session-id-surfaces-" <>
          Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
      )

    workspace = Path.join(root, "workspace")
    File.mkdir_p!(workspace)

    on_exit(fn ->
      _ = SessionSupervisor.stop_all_sessions()
      File.rm_rf!(root)
    end)

    %{root: root, workspace: workspace}
  end

  test "Log, lease, Resource, and Registry boundaries reject traversal before mutation", %{
    root: root,
    workspace: ws
  } do
    hostile = "../../../outside/victim"

    assert_invalid_no_echo(Log.fold(hostile, workspace: ws), hostile)
    assert_invalid_no_echo(Log.create_session(hostile, [], workspace: ws), hostile)
    assert_invalid_no_echo(SessionLease.acquire(hostile, workspace: ws), hostile)

    assert_invalid_no_echo(
      SessionResources.ingest_attachments(hostile, [], workspace: ws),
      hostile
    )

    assert_invalid_no_echo(
      SessionResources.resource_path(
        hostile,
        %{
          "resource_id" => "res_safe",
          "content_sha256" => String.duplicate("a", 64),
          "extension" => "bin"
        },
        ws
      ),
      hostile
    )

    assert_invalid_no_echo(SessionSupervisor.start_session(id: hostile, workspace: ws), hostile)

    for result <- [
          Session.info(hostile),
          Session.history(hostile),
          Session.emit(hostile, Event.status(hostile, "thinking"))
        ] do
      assert_invalid_no_echo(result, hostile)
    end

    assert Registry.lookup(Pixir.Sessions.Registry, hostile) == []
    refute File.exists?(Path.join(root, "outside"))
    refute File.exists?(Path.join(ws, ".pixir"))
  end

  test "read-only inspectors reject hostile ids before building Log paths", %{workspace: ws} do
    hostile = "../../../outside/inspect;PWN"

    for result <- [
          SessionDiagnostics.run(hostile, workspace: ws),
          SessionTree.project(hostile, workspace: ws),
          ReplayInspector.inspect(hostile, workspace: ws),
          Compaction.plan(hostile, workspace: ws),
          Fork.dry_run(hostile, workspace: ws)
        ] do
      assert_invalid_no_echo(result, hostile)
    end

    refute File.exists?(Path.join(ws, ".pixir"))
  end

  test "Fork rejects a caller-selected hostile child id before child path or Resource work", %{
    root: root,
    workspace: ws
  } do
    parent = "parent-safe"
    event = Event.user_message(parent, "hello") |> Event.with_seq(0)
    assert {:ok, [_]} = Log.create_session(parent, [event], workspace: ws)

    hostile_child = "../../../outside/fork-child"

    assert_invalid_no_echo(
      Fork.dry_run(parent, workspace: ws, child_session_id: hostile_child),
      hostile_child
    )

    refute File.exists?(Path.join(root, "outside"))
  end

  test "Fork validates a hostile child before reading a corrupt parent Log", %{workspace: ws} do
    parent = "corrupt-parent"
    Paths.ensure_sessions_dir(ws)
    File.write!(Paths.session_log(parent, ws), "{not-json}\n")
    hostile_child = "../hostile-child"

    assert_invalid_no_echo(
      Fork.dry_run(parent, workspace: ws, child_session_id: hostile_child),
      hostile_child
    )
  end

  test "a corrupt Log after lease acquisition releases the failed-init lease", %{workspace: ws} do
    session_id = "corrupt-init"
    Paths.ensure_sessions_dir(ws)
    File.write!(Paths.session_log(session_id, ws), "{not-json}\n")

    assert {:error, %{error: %{kind: :corrupt_log_line}}} =
             Conversation.start(id: session_id, workspace: ws)

    refute File.exists?(Paths.session_lease(session_id, ws))

    File.write!(Paths.session_log(session_id, ws), "")
    assert {:ok, ^session_id} = Conversation.start(id: session_id, workspace: ws)
    assert {:ok, :stopped} = SessionSupervisor.stop_session(session_id)
    refute File.exists?(Paths.session_lease(session_id, ws))
  end

  test "direct Session start preflights the Log branch before creating a lease", %{
    root: root,
    workspace: ws
  } do
    outside = Path.join(root, "outside-sessions")
    File.mkdir_p!(outside)
    sentinel = Path.join(outside, "sentinel")
    File.write!(sentinel, "unchanged")
    File.mkdir_p!(Paths.project_root(ws))
    File.ln_s!(outside, Paths.sessions_dir(ws))

    assert {:error, reason} = SessionSupervisor.start_session(id: "safe-session", workspace: ws)
    assert inspect(reason) =~ "unsafe_state_path"
    refute File.exists?(Paths.session_leases_dir(ws))
    assert File.read!(sentinel) == "unchanged"
  end

  test "Workflow and Subagent process boundaries reject invalid parent ids before work", %{
    workspace: ws
  } do
    hostile = "../process-parent;PWN"
    manager_before = :sys.get_state(Pixir.Subagents.Manager)

    workflow = %{
      "id" => "invalid-parent-proof",
      "steps" => [
        %{
          "id" => "scratch",
          "task" => "do nothing",
          "workspace_mode" => "virtual_overlay",
          "read_set" => ["missing.txt"],
          "virtual_commands" => []
        }
      ]
    }

    for result <- [
          Workflows.run(hostile, workflow, workspace: ws),
          Subagents.list(hostile, workspace: ws),
          Subagents.diagnostics(hostile, workspace: ws)
        ] do
      assert_invalid_no_echo(result, hostile)
    end

    assert :sys.get_state(Pixir.Subagents.Manager) == manager_before
    refute File.exists?(Path.join(ws, ".pixir"))
  end

  test "a valid 235-byte id fits real durable and temporary Log operations", %{workspace: ws} do
    session_id = "a" <> String.duplicate("b", 234)
    event = Event.user_message(session_id, "fits") |> Event.with_seq(0)

    assert {:ok, [_]} = Log.create_session(session_id, [event], workspace: ws)
    assert byte_size(Path.basename(Paths.session_log(session_id, ws))) == 242
    assert {:ok, [_]} = Log.fold(session_id, workspace: ws)
    assert Path.wildcard(Paths.session_log(session_id, ws) <> ".tmp-*") == []
  end

  defp assert_invalid_no_echo({:error, %{error: %{kind: :invalid_args}} = error}, hostile) do
    refute inspect(error) =~ hostile
    :ok
  end
end
