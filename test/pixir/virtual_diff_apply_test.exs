defmodule Pixir.VirtualDiffApplyTest do
  use ExUnit.Case, async: false

  alias Pixir.Permissions.WritePolicy
  alias Pixir.SessionSupervisor
  alias Pixir.Tools.{ApplyVirtualDiff, Executor}
  alias Pixir.VirtualDiffApply
  alias Pixir.VirtualOverlay

  setup do
    ws = Path.join(System.tmp_dir!(), "pixir-virtual-diff-apply-#{System.unique_integer()}")
    File.rm_rf!(ws)
    File.mkdir_p!(Path.join(ws, "lib"))
    File.mkdir_p!(Path.join(ws, "tmp"))

    on_exit(fn -> File.rm_rf!(ws) end)

    %{ws: ws}
  end

  test "plans and applies add modify delete from a real virtual_overlay artifact", %{ws: ws} do
    File.write!(Path.join(ws, "lib/modify.txt"), "old\n")
    File.write!(Path.join(ws, "lib/delete.txt"), "bye\n")

    assert {:ok, artifact} =
             VirtualOverlay.run(ws, %{
               "read_set" => ["lib/modify.txt", "lib/delete.txt"],
               "commands" => [
                 "sed -i 's/old/new/' lib/modify.txt",
                 "rm lib/delete.txt",
                 "echo added > lib/add.txt"
               ]
             })

    assert {:ok, plan} = VirtualDiffApply.plan(artifact, ws)
    assert plan["kind"] == "virtual_diff_apply"
    assert plan["dry_run"] == true
    assert plan["status"] == "planned"
    assert plan["counts"]["selected"] == 3
    assert plan["counts"]["applicable"] == 3
    assert File.read!(Path.join(ws, "lib/modify.txt")) == "old\n"

    assert {:ok, applied} = VirtualDiffApply.apply(artifact, ws)
    assert applied["status"] == "applied"
    assert applied["counts"]["applied"] == 3
    assert File.read!(Path.join(ws, "lib/modify.txt")) == "new\n"
    refute File.exists?(Path.join(ws, "lib/delete.txt"))
    assert File.read!(Path.join(ws, "lib/add.txt")) == "added\n"
  end

  test "hash drift conflicts and applies nothing", %{ws: ws} do
    File.write!(Path.join(ws, "lib/good.txt"), "good\n")
    File.write!(Path.join(ws, "lib/drift.txt"), "before\n")

    assert {:ok, artifact} =
             VirtualOverlay.run(ws, %{
               "read_set" => ["lib/good.txt", "lib/drift.txt"],
               "commands" => [
                 "sed -i 's/good/better/' lib/good.txt",
                 "sed -i 's/before/after/' lib/drift.txt"
               ]
             })

    File.write!(Path.join(ws, "lib/drift.txt"), "changed outside\n")

    assert {:ok, result} = VirtualDiffApply.apply(artifact, ws)
    assert result["status"] == "not_applied"
    assert result["counts"]["conflicted"] == 1
    assert File.read!(Path.join(ws, "lib/good.txt")) == "good\n"
    assert File.read!(Path.join(ws, "lib/drift.txt")) == "changed outside\n"
  end

  test "add over existing and delete missing conflict", %{ws: ws} do
    File.write!(Path.join(ws, "lib/delete.txt"), "bye\n")

    assert {:ok, add_artifact} =
             VirtualOverlay.run(ws, %{
               "read_set" => [],
               "commands" => ["echo added > lib/add.txt"]
             })

    File.write!(Path.join(ws, "lib/add.txt"), "already\n")
    assert {:ok, add_result} = VirtualDiffApply.apply(add_artifact, ws)
    assert add_result["status"] == "not_applied"
    assert hd(add_result["files"])["status"] == "conflicted"

    assert {:ok, delete_artifact} =
             VirtualOverlay.run(ws, %{
               "read_set" => ["lib/delete.txt"],
               "commands" => ["rm lib/delete.txt"]
             })

    File.rm!(Path.join(ws, "lib/delete.txt"))
    assert {:ok, delete_result} = VirtualDiffApply.apply(delete_artifact, ws)
    assert delete_result["status"] == "not_applied"
    assert hd(delete_result["files"])["status"] == "conflicted"
  end

  test "symlink escape in artifact path is refused during plan", %{ws: ws} do
    outside = Path.join(System.tmp_dir!(), "pixir-vdiff-outside-#{System.unique_integer()}")
    File.rm_rf!(outside)
    File.mkdir_p!(outside)
    File.ln_s!(outside, Path.join(ws, "tmp/outside"))

    on_exit(fn -> File.rm_rf!(outside) end)

    artifact = artifact([add_change("tmp/outside/escape.txt", "secret\n")])

    assert {:ok, plan} = VirtualDiffApply.plan(artifact, ws)
    assert plan["status"] == "not_applied"
    assert hd(plan["files"])["status"] == "outside_workspace"
  end

  test "final symlink artifact paths resolve without raising", %{ws: ws} do
    target = Path.join(ws, "lib/target.txt")
    File.write!(target, "target\n")
    File.ln_s!("lib/target.txt", Path.join(ws, "link.txt"))

    assert {:ok, plan} =
             VirtualDiffApply.plan(artifact([delete_change("link.txt", "target\n")]), ws)

    assert plan["status"] == "planned"
    assert [%{"status" => "applicable", "normalized_path" => "lib/target.txt"}] = plan["files"]
  end

  test "final symlink artifact paths escaping the workspace return structured evidence", %{ws: ws} do
    outside =
      Path.join(System.tmp_dir!(), "pixir-vdiff-final-outside-#{System.unique_integer()}.txt")

    File.write!(outside, "outside\n")
    File.ln_s!(outside, Path.join(ws, "outside-link.txt"))
    on_exit(fn -> File.rm(outside) end)

    assert {:ok, plan} =
             VirtualDiffApply.plan(
               artifact([delete_change("outside-link.txt", "outside\n")]),
               ws
             )

    assert plan["status"] == "not_applied"
    assert [%{"status" => "outside_workspace", "applicability" => details}] = plan["files"]
    assert details["reason"] == "path_escapes_workspace"
  end

  test "truncated or unsupported changes are not applicable", %{ws: ws} do
    truncated = put_in(add_change("lib/truncated.txt", "x\n"), ["diff", "truncated"], true)
    unsupported = %{"path" => "lib/blob.bin", "operation" => "unsupported"}

    assert {:ok, result} = VirtualDiffApply.apply(artifact([truncated, unsupported]), ws)
    assert result["status"] == "not_applied"
    assert result["counts"]["unsupported"] == 2
    refute File.exists?(Path.join(ws, "lib/truncated.txt"))
  end

  test "tool dry_run defaults true and read_only denies mutating apply", %{ws: ws} do
    artifact = artifact([add_change("lib/tool.txt", "tool\n")])
    ctx = %{workspace: ws, permission: %{mode: :read_only}}

    assert {:ok, plan} = ApplyVirtualDiff.execute(%{"artifact" => artifact}, ctx)
    assert plan["dry_run"] == true
    refute File.exists?(Path.join(ws, "lib/tool.txt"))

    assert {:ok, denied} =
             ApplyVirtualDiff.execute(%{"artifact" => artifact, "dry_run" => false}, ctx)

    assert denied["status"] == "denied"
    refute File.exists?(Path.join(ws, "lib/tool.txt"))
  end

  test "bounded write policy denial prevents all mutations", %{ws: ws} do
    File.write!(Path.join(ws, "lib/ok.txt"), "ok\n")

    {:ok, policy} = WritePolicy.normalize(%{"version" => 1, "allow_writes" => ["lib/ok.txt"]})

    assert {:ok, artifact} =
             VirtualOverlay.run(ws, %{
               "read_set" => ["lib/ok.txt"],
               "commands" => ["sed -i 's/ok/changed/' lib/ok.txt", "echo no > lib/denied.txt"]
             })

    assert {:ok, result} = VirtualDiffApply.apply(artifact, ws, write_policy: policy)
    assert result["status"] == "not_applied"
    assert Enum.any?(result["files"], &(&1["status"] == "denied_by_policy"))
    assert File.read!(Path.join(ws, "lib/ok.txt")) == "ok\n"
    refute File.exists?(Path.join(ws, "lib/denied.txt"))
  end

  test "applying the same artifact twice conflicts the second time", %{ws: ws} do
    artifact = artifact([add_change("lib/once.txt", "once\n")])

    assert {:ok, first} = VirtualDiffApply.apply(artifact, ws)
    assert first["status"] == "applied"

    assert {:ok, second} = VirtualDiffApply.apply(artifact, ws)
    assert second["status"] == "not_applied"
    assert second["counts"]["conflicted"] == 1
    assert File.read!(Path.join(ws, "lib/once.txt")) == "once\n"
  end

  test "phase-A staging failure leaves every target byte-identical", %{ws: ws} do
    first = Path.join(ws, "lib/first.txt")
    locked_dir = Path.join(ws, "locked")
    second = Path.join(locked_dir, "second.txt")
    File.mkdir_p!(locked_dir)
    File.write!(first, "first-before\r\n")
    File.write!(second, "second-before\n")

    changes = [
      modify_change("lib/first.txt", "first-before\r\n", "first-after\n"),
      modify_change("locked/second.txt", "second-before\n", "second-after\n")
    ]

    result =
      try do
        File.chmod!(locked_dir, 0o555)
        VirtualDiffApply.apply(artifact(changes), ws)
      after
        File.chmod!(locked_dir, 0o755)
      end

    assert {:ok, %{"status" => "failed"} = failed} = result
    assert failed["recovery"] == %{"rolled_back" => true, "restore_failures" => []}
    assert File.read!(first) == "first-before\r\n"
    assert File.read!(second) == "second-before\n"
  end

  test "Executor.run reports phase-A recovery without mutating its target", %{ws: ws} do
    locked_dir = Path.join(ws, "executor-locked")
    target = Path.join(locked_dir, "target.txt")
    File.mkdir_p!(locked_dir)
    File.write!(target, "executor-before\n")

    session_id = "vdiff-executor-#{System.unique_integer([:positive])}"

    assert {:ok, ^session_id, session_pid} =
             SessionSupervisor.start_session(id: session_id, workspace: ws)

    on_exit(fn ->
      if Process.alive?(session_pid) do
        DynamicSupervisor.terminate_child(SessionSupervisor, session_pid)
      end
    end)

    call = %{
      call_id: "apply-phase-a",
      name: "apply_virtual_diff",
      args: %{
        "artifact" =>
          artifact([
            modify_change(
              "executor-locked/target.txt",
              "executor-before\n",
              "executor-after\n"
            )
          ]),
        "dry_run" => false
      }
    }

    context = %{
      session_id: session_id,
      workspace: ws,
      permission: %{mode: :auto, asker: nil}
    }

    result =
      try do
        File.chmod!(locked_dir, 0o555)
        Executor.run(call, context)
      after
        File.chmod!(locked_dir, 0o755)
      end

    assert {:ok, %{"status" => "failed"} = failed} = result
    assert failed["recovery"] == %{"rolled_back" => true, "restore_failures" => []}
    assert File.read!(target) == "executor-before\n"
  end

  test "phase-B failure rolls prior content back byte-exact", %{ws: ws} do
    target = Path.join(ws, "lib/rollback.txt")
    locked_dir = Path.join(ws, "delete-locked")
    doomed = Path.join(locked_dir, "doomed.txt")
    before = "before\r\nwith-final-byte" <> <<0>>
    File.mkdir_p!(locked_dir)
    File.write!(target, before)
    File.write!(doomed, "delete me\n")

    changes = [
      modify_change("lib/rollback.txt", before, "after\n"),
      delete_change("delete-locked/doomed.txt", "delete me\n")
    ]

    result =
      try do
        File.chmod!(locked_dir, 0o555)
        VirtualDiffApply.apply(artifact(changes), ws)
      after
        File.chmod!(locked_dir, 0o755)
      end

    assert {:ok, %{"status" => "failed"} = failed} = result
    assert failed["recovery"] == %{"rolled_back" => true, "restore_failures" => []}
    assert File.read!(target) == before
    assert File.read!(doomed) == "delete me\n"
  end

  test "rollback restore failure is reported instead of raised", %{ws: ws} do
    target = Path.join(ws, "lib/restore-failure.txt")
    locked_dir = Path.join(ws, "restore-trigger-locked")
    doomed = Path.join(locked_dir, "doomed.txt")
    File.mkdir_p!(locked_dir)
    File.write!(target, "before\n")
    File.write!(doomed, "delete me\n")

    hook = fn
      {:committed, "lib/restore-failure.txt"} -> File.chmod(target, 0o444)
      _event -> :ok
    end

    result =
      try do
        File.chmod!(locked_dir, 0o555)

        VirtualDiffApply.apply(
          artifact([
            modify_change("lib/restore-failure.txt", "before\n", "after\n"),
            delete_change("restore-trigger-locked/doomed.txt", "delete me\n")
          ]),
          ws,
          apply_hook: hook
        )
      after
        File.chmod!(target, 0o644)
        File.chmod!(locked_dir, 0o755)
      end

    assert {:ok, %{"status" => "failed"} = failed} = result
    assert failed["recovery"]["rolled_back"] == false

    assert [%{"path" => "lib/restore-failure.txt", "kind" => "write_failed"}] =
             failed["recovery"]["restore_failures"]

    assert File.read!(target) == "after\n"
  end

  test "unreadable backup is reported when its mutated file cannot be restored", %{ws: ws} do
    target = Path.join(ws, "lib/unreadable-backup.txt")
    locked_dir = Path.join(ws, "backup-trigger-locked")
    doomed = Path.join(locked_dir, "doomed.txt")
    File.mkdir_p!(locked_dir)
    File.write!(target, "before\n")
    File.write!(doomed, "delete me\n")

    hook = fn
      :staged -> File.chmod(target, 0o000)
      _event -> :ok
    end

    result =
      try do
        File.chmod!(locked_dir, 0o555)

        VirtualDiffApply.apply(
          artifact([
            modify_change("lib/unreadable-backup.txt", "before\n", "after\n"),
            delete_change("backup-trigger-locked/doomed.txt", "delete me\n")
          ]),
          ws,
          apply_hook: hook
        )
      after
        File.chmod!(target, 0o644)
        File.chmod!(locked_dir, 0o755)
      end

    assert {:ok, %{"status" => "failed"} = failed} = result
    assert failed["recovery"]["rolled_back"] == false

    assert [%{"path" => "lib/unreadable-backup.txt", "kind" => "backup_read_failed"}] =
             failed["recovery"]["restore_failures"]

    assert File.read!(target) == "after\n"
  end

  test "does not introduce host-boundary calls in the apply source" do
    source = File.read!("lib/pixir/virtual_diff_apply.ex")

    refute source =~ "System.cmd"
    refute source =~ "Port.open"
    refute source =~ ":os.cmd"
    refute source =~ "System.find_executable"
    refute source =~ "CommandBoundary"
    refute source =~ "/bin/bash"
    refute source =~ "/bin/sh"
    refute source =~ ~r/\bgit\b/
    refute source =~ ~r/\bnode\b/
  end

  defp artifact(changes) do
    %{
      "kind" => "virtual_diff",
      "version" => 1,
      "workspace_strategy" => "virtual_overlay",
      "workspace_fidelity" => "virtual_shell_no_host_binaries",
      "parent_workspace" => %{"mutation" => "none"},
      "import" => %{"read_set" => [], "file_count" => 0, "byte_count" => 0, "truncated" => false},
      "commands" => [],
      "summary" => %{},
      "changes" => changes,
      "limits" => %{},
      "caveats" => [],
      "apply" => %{"status" => "not_applied", "requires_explicit_apply" => true}
    }
  end

  defp add_change(path, content) do
    %{
      "path" => path,
      "operation" => "add",
      "after" => %{
        "sha256" => sha256(content),
        "byte_count" => byte_size(content),
        "content" => content
      },
      "diff" => %{"format" => "unified", "text" => "+#{content}", "truncated" => false}
    }
  end

  defp modify_change(path, before, after_content) do
    %{
      "path" => path,
      "operation" => "modify",
      "before" => %{"sha256" => sha256(before), "byte_count" => byte_size(before)},
      "after" => %{
        "sha256" => sha256(after_content),
        "byte_count" => byte_size(after_content),
        "content" => after_content
      },
      "diff" => %{"format" => "unified", "text" => "+#{after_content}", "truncated" => false}
    }
  end

  defp delete_change(path, before) do
    %{
      "path" => path,
      "operation" => "delete",
      "before" => %{"sha256" => sha256(before), "byte_count" => byte_size(before)},
      "diff" => %{"format" => "unified", "text" => "-#{before}", "truncated" => false}
    }
  end

  defp sha256(content), do: :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
end
