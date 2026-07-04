defmodule Pixir.Delegate.OwnerSupervisorTest do
  use ExUnit.Case, async: false

  import Pixir.Test.RawLogHelpers

  alias Pixir.{Delegate.Async, Delegate.Handle, Delegate.Owner, Delegate.OwnerSupervisor}

  defmodule FakeRunner do
    def start(request, spec, _spec_meta, _opts) do
      parent_session_id = spec["parent_session_id"]
      {:ok, handle} = Handle.build(parent_session_id)

      runtime = %{
        workspace: request.workspace,
        planned_child_count: 1,
        timeout_ms: 1_000,
        max_threads: 1,
        max_depth: 1,
        mode: "read_only",
        workspace_mode: "shared"
      }

      agents = [
        %{
          "id" => "sub_done",
          "child_session_id" => "child-done",
          "status" => "completed",
          "agent" => "explorer",
          "summary" => "done"
        }
      ]

      {:ok,
       %{
         handle: handle,
         parent_session_id: parent_session_id,
         runtime: runtime,
         agents: agents,
         payload: %{
           "ok" => true,
           "status" => "running",
           "kind" => "delegate_start",
           "delegate_id" => handle["delegate_id"],
           "parent_session_id" => parent_session_id,
           "handle" => handle,
           "owner" => %{"state" => "live_delegate_owner"},
           "service_state" => "live_delegate_owner"
         }
       }}
    end
  end

  setup do
    ws =
      Path.join(
        System.tmp_dir!(),
        "pixir-delegate-owner-" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
      )

    File.mkdir_p!(ws)
    sid = "delegate-owner-parent-" <> Base.encode16(:crypto.strong_rand_bytes(3), case: :lower)

    write_raw_log(ws, sid, [
      raw_event(sid, 0, "subagent_event", %{
        "subagent_id" => "sub_done",
        "child_session_id" => "child-done",
        "event" => "finished",
        "status" => "completed",
        "agent" => "explorer",
        "task" => "inspect",
        "workspace" => ws
      })
    ])

    on_exit(fn -> File.rm_rf!(ws) end)

    %{ws: ws, sid: sid}
  end

  test "current-runtime owner enriches status and cancel by delegate id", %{ws: ws, sid: sid} do
    request = %{workspace: ws, timeout_ms: nil}
    spec = %{"parent_session_id" => sid}
    spec_meta = %{"strategy" => "subagents", "planned_child_count" => 1}

    assert {:ok, %{"delegate_id" => delegate_id, "service_state" => "live_delegate_owner"}} =
             OwnerSupervisor.start_delegate(request, spec, spec_meta, runner: FakeRunner)

    assert {:ok, handle} = Handle.resolve(delegate_id)

    on_exit(fn ->
      case OwnerSupervisor.lookup(handle) do
        {:ok, pid} -> Process.exit(pid, :normal)
        {:error, :not_found} -> :ok
      end
    end)

    assert {:ok,
            %{
              "status" => "completed",
              "service_state" => "live_delegate_owner",
              "owner" => %{
                "state" => "live_delegate_owner",
                "delegate_owner" => true,
                "runtime_residency" => %{"model" => "current_beam_runtime"}
              }
            }} = Async.status(delegate_id, workspace: ws)

    assert {:ok,
            %{
              "status" => "completed",
              "service_state" => "live_delegate_owner",
              "cancelled_child_count" => 0,
              "owner" => %{"state" => "live_delegate_owner"}
            }} = Async.cancel(delegate_id, workspace: ws)
  end

  test "owner state validates handle shape" do
    assert {:error, %{"kind" => "invalid_delegate_handle"}} =
             Owner.live_owner_state("not-a-handle")
  end

  test "duplicate owner registration returns structured error instead of crashing", %{
    ws: ws,
    sid: sid
  } do
    request = %{workspace: ws, timeout_ms: nil}
    spec = %{"parent_session_id" => sid}
    spec_meta = %{"strategy" => "subagents", "planned_child_count" => 1}

    assert {:ok, %{"delegate_id" => delegate_id}} =
             OwnerSupervisor.start_delegate(request, spec, spec_meta, runner: FakeRunner)

    assert {:ok, handle} = Handle.resolve(delegate_id)

    on_exit(fn ->
      case OwnerSupervisor.lookup(handle) do
        {:ok, pid} -> Process.exit(pid, :normal)
        {:error, :not_found} -> :ok
      end
    end)

    assert {:error,
            %{
              "kind" => "delegate_owner_registration_failed",
              "details" => %{"delegate_id" => ^delegate_id, "parent_session_id" => ^sid}
            }} = OwnerSupervisor.start_delegate(request, spec, spec_meta, runner: FakeRunner)
  end
end
