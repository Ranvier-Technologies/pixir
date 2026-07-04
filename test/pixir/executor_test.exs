defmodule Pixir.Tools.ExecutorTest do
  use ExUnit.Case, async: false

  alias Pixir.{Events, Log, SessionSupervisor}
  alias Pixir.Permissions.WritePolicy
  alias Pixir.Test.WorkspaceFixtures
  alias Pixir.Tools.Executor

  setup do
    ws =
      Path.join(
        System.tmp_dir!(),
        "pixir-exec-" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
      )

    File.mkdir_p!(ws)
    {:ok, sid, pid} = SessionSupervisor.start_session(workspace: ws, role: :build)

    on_exit(fn ->
      if Process.alive?(pid), do: DynamicSupervisor.terminate_child(SessionSupervisor, pid)
      File.rm_rf!(ws)
    end)

    %{ws: ws, sid: sid, ctx: %{session_id: sid, workspace: ws, call_id: "call_1"}}
  end

  describe "execute_call/2 (no events)" do
    test "runs a known tool", %{ctx: ctx, ws: ws} do
      File.write!(Path.join(ws, "a.txt"), "data")

      assert {:ok, %{"output" => "data"}} =
               Executor.execute_call(%{name: "read", args: %{"path" => "a.txt"}}, ctx)
    end

    test "unknown tool is structured", %{ctx: ctx} do
      assert {:error, %{error: %{kind: :unknown_tool}}} =
               Executor.execute_call(%{name: "frobnicate", args: %{}}, ctx)
    end

    test "missing required args is structured", %{ctx: ctx} do
      assert {:error, %{error: %{kind: :invalid_args, details: %{missing: ["path"]}}}} =
               Executor.execute_call(%{name: "read", args: %{}}, ctx)
    end

    test "type mismatch is structured", %{ctx: ctx} do
      assert {:error, %{error: %{kind: :invalid_args, details: %{invalid: ["path"]}}}} =
               Executor.execute_call(%{name: "read", args: %{"path" => 123}}, ctx)
    end

    test "dry_run dispatches to the tool's plan", %{ctx: ctx} do
      ctx = Map.put(ctx, :dry_run, true)

      assert {:ok, %{"dry_run" => true, "would" => "run"}} =
               Executor.execute_call(%{name: "bash", args: %{"command" => "ls"}}, ctx)
    end
  end

  describe "run/2 (records canonical events)" do
    test "records tool_call then tool_result and persists them", %{ctx: ctx, sid: sid, ws: ws} do
      :ok = Events.subscribe(sid)
      File.write!(Path.join(ws, "a.txt"), "contents")

      assert {:ok, %{"output" => "contents"}} =
               Executor.run(%{call_id: "call_1", name: "read", args: %{"path" => "a.txt"}}, ctx)

      assert_receive {:pixir_event, %{type: :tool_call, data: %{"name" => "read"}}}

      assert_receive {:pixir_event,
                      %{type: :tool_result, data: %{"ok" => true, "output" => "contents"}}}

      assert {:ok, [call, result]} = Log.fold(sid, workspace: ws)
      assert call.type == :tool_call
      assert call.data["call_id"] == "call_1"
      assert result.type == :tool_result
      assert result.data["ok"] == true
    end

    test "records a structured tool_result on failure", %{ctx: ctx, sid: sid, ws: ws} do
      assert {:error, _} =
               Executor.run(
                 %{call_id: "call_2", name: "read", args: %{"path" => "missing.txt"}},
                 ctx
               )

      assert {:ok, [_call, result]} = Log.fold(sid, workspace: ws)
      assert result.data["ok"] == false
      assert result.data["error"]["kind"] == "not_found"
    end

    test "bash output truncated at a multibyte boundary still records a tool_result", %{
      ctx: ctx,
      sid: sid,
      ws: ws
    } do
      command =
        "printf '%*s' 15999 '' | tr ' ' a; printf '\\360\\237\\233\\241\\357\\270\\217'"

      assert {:ok, %{"output" => output, "ok" => true}} =
               Executor.run(
                 %{call_id: "call_utf8", name: "bash", args: %{"command" => command}},
                 ctx
               )

      assert String.valid?(output)
      assert output =~ "[truncated"

      assert {:ok, [call, result]} = Log.fold(sid, workspace: ws)
      assert call.type == :tool_call
      assert call.data["call_id"] == "call_utf8"
      assert result.type == :tool_result
      assert result.data["call_id"] == "call_utf8"
      assert result.data["ok"] == true
      assert String.valid?(result.data["output"])
    end
  end

  describe "run/2 evidence protection (.pixir state dir)" do
    test "bash rm -rf .pixir is denied even in :auto and records the denial", %{
      ctx: ctx,
      sid: sid,
      ws: ws
    } do
      assert {:error, %{error: %{kind: :protected_path, details: details}}} =
               Executor.run(
                 %{call_id: "c", name: "bash", args: %{"command" => "rm -rf .pixir"}},
                 ctx
               )

      assert details.tool == "bash"
      assert Enum.any?(details.next_actions, &(&1 =~ "diagnose session"))
      assert File.dir?(Path.join(ws, ".pixir"))

      assert {:ok, [_call, decision, result]} = Log.fold(sid, workspace: ws)
      assert decision.type == :permission_decision
      assert decision.data["gate"] == "evidence_protection"
      assert decision.data["error_kind"] == "protected_path"
      assert decision.data["tool"] == "bash"
      assert result.data["ok"] == false
      assert result.data["error"]["kind"] == "protected_path"
    end

    test "non-safe bash that references the state dir is denied before execution", %{ctx: ctx} do
      for command <- [
            "python -c \"import shutil; shutil.rmtree('.pixir')\"",
            "perl -e \"unlink '.pixir/sessions/log.ndjson'\"",
            "env rm -rf .pixir"
          ] do
        assert {:error, %{error: %{kind: :protected_path}}} =
                 Executor.run(
                   %{call_id: "non_safe", name: "bash", args: %{"command" => command}},
                   ctx
                 )
      end
    end

    test "bash redirection into the state dir is denied", %{ctx: ctx} do
      for command <- [
            "echo x > .pixir/sessions/evil.ndjson",
            "echo x >> ./.pixir/sessions/evil.ndjson",
            "echo x >.pixir/sessions/evil.ndjson"
          ] do
        assert {:error, %{error: %{kind: :protected_path}}} =
                 Executor.run(%{call_id: "c", name: "bash", args: %{"command" => command}}, ctx)
      end
    end

    test "mutating find that can reach the state dir is denied", %{ctx: ctx, sid: sid, ws: ws} do
      for command <- [
            "find .pixir -delete",
            "env find .pixir -delete",
            "find . -name '*.ndjson' -delete",
            "find . -exec rm {} +",
            "find / -delete",
            "find -H / -delete"
          ] do
        assert {:error, %{error: %{kind: :protected_path}}} =
                 Executor.run(
                   %{call_id: "find", name: "bash", args: %{"command" => command}},
                   ctx
                 )
      end

      assert File.dir?(Path.join(ws, ".pixir"))
      assert {:ok, history} = Log.fold(sid, workspace: ws)
      assert Enum.any?(history, &(&1.type == :permission_decision))

      assert Enum.all?(history, fn event ->
               event.type != :tool_result or event.data["ok"] == false
             end)
    end

    test "find global options preserve following roots for evidence reachability", %{ctx: ctx} do
      ctx = Map.put(ctx, :dry_run, true)
      outside = Path.join(System.tmp_dir!(), "pixir-find-outside")

      assert {:ok, %{"dry_run" => true, "command" => command}} =
               Executor.run(
                 %{
                   call_id: "find_global",
                   name: "bash",
                   args: %{"command" => "find -H #{outside} -delete"}
                 },
                 ctx
               )

      assert command == "find -H #{outside} -delete"
    end

    test "write and edit into the state dir are denied", %{ctx: ctx, ws: ws} do
      assert {:error, %{error: %{kind: :protected_path}}} =
               Executor.run(
                 %{
                   call_id: "c",
                   name: "write",
                   args: %{"path" => ".pixir/sessions/evil.ndjson", "content" => "x"}
                 },
                 ctx
               )

      refute File.exists?(Path.join(ws, ".pixir/sessions/evil.ndjson"))

      assert {:error, %{error: %{kind: :protected_path}}} =
               Executor.run(
                 %{
                   call_id: "c",
                   name: "edit",
                   args: %{
                     "path" => ".pixir/sessions/log.ndjson",
                     "old_string" => "a",
                     "new_string" => "b"
                   }
                 },
                 ctx
               )
    end

    test "write into the state dir through a workspace symlink is denied", %{
      ctx: ctx,
      sid: sid,
      ws: ws
    } do
      File.ln_s!(".pixir", Path.join(ws, "evidence-link"))

      assert {:error, %{error: %{kind: :protected_path, details: details}}} =
               Executor.run(
                 %{
                   call_id: "c",
                   name: "write",
                   args: %{"path" => "evidence-link/sessions/evil.ndjson", "content" => "x"}
                 },
                 ctx
               )

      assert details.normalized_target =~ "/.pixir/sessions/evil.ndjson"
      refute File.exists?(Path.join(ws, ".pixir/sessions/evil.ndjson"))

      assert {:ok, [_call, decision, result]} = Log.fold(sid, workspace: ws)
      assert decision.data["gate"] == "evidence_protection"
      assert decision.data["normalized_target"] =~ "/.pixir/sessions/evil.ndjson"
      assert result.data["error"]["kind"] == "protected_path"
    end

    test "deep symlink chains fail closed as protected evidence paths", %{
      ctx: ctx,
      ws: ws
    } do
      File.ln_s!(".pixir", Path.join(ws, "evidence-link-1"))

      for index <- 2..22 do
        File.ln_s!("evidence-link-#{index - 1}", Path.join(ws, "evidence-link-#{index}"))
      end

      assert {:error, %{error: %{kind: :protected_path}}} =
               Executor.run(
                 %{
                   call_id: "c",
                   name: "write",
                   args: %{"path" => "evidence-link-22/sessions/evil.ndjson", "content" => "x"}
                 },
                 ctx
               )

      refute File.exists?(Path.join(ws, ".pixir/sessions/evil.ndjson"))
    end

    test "git clean ignored-file mode is denied because it can remove the state dir", %{
      ctx: ctx,
      sid: sid,
      ws: ws
    } do
      assert {:error, %{error: %{kind: :protected_path, details: details}}} =
               Executor.run(
                 %{call_id: "c", name: "bash", args: %{"command" => "git clean -fdx"}},
                 ctx
               )

      assert details.tool == "bash"
      assert File.dir?(Path.join(ws, ".pixir"))

      assert {:ok, [_call, decision, result]} = Log.fold(sid, workspace: ws)
      assert decision.data["gate"] == "evidence_protection"
      assert result.data["error"]["kind"] == "protected_path"
    end

    test "bash evidence guard strips shell punctuation and preserves git clean dry-run", %{
      ctx: ctx
    } do
      for command <- [
            "(rm -rf .pixir)",
            "rm -rf .pixir;",
            "(git clean -fdx)",
            "git -C . clean -fdx"
          ] do
        assert {:error, %{error: %{kind: :protected_path}}} =
                 Executor.run(
                   %{call_id: "c", name: "bash", args: %{"command" => command}},
                   ctx
                 )
      end

      assert {:ok, %{"ok" => false, "exit_code" => 128}} =
               Executor.run(
                 %{call_id: "dry", name: "bash", args: %{"command" => "git clean -ndx"}},
                 ctx
               )
    end

    test "reading evidence and non-state-dir lookalikes stay allowed", %{ctx: ctx, ws: ws} do
      # Reads of the state dir are fine (nonzero exit is a result, not an error).
      assert {:ok, _} =
               Executor.run(
                 %{call_id: "c", name: "bash", args: %{"command" => "ls .pixir/sessions"}},
                 ctx
               )

      assert {:ok, _} =
               Executor.run(
                 %{
                   call_id: "find_read",
                   name: "bash",
                   args: %{"command" => "find .pixir -print"}
                 },
                 ctx
               )

      assert {:ok, _} =
               Executor.run(
                 %{
                   call_id: "env_find_read",
                   name: "bash",
                   args: %{"command" => "env find .pixir -print"}
                 },
                 ctx
               )

      # Non-safe shell forms that mention the state dir are refused; use the read tool
      # or diagnostics instead of piping/redirecting session evidence through bash.
      assert {:error, %{error: %{kind: :protected_path}}} =
               Executor.run(
                 %{
                   call_id: "redirect",
                   name: "bash",
                   args: %{"command" => "cat .pixir/sessions/x.ndjson > evidence-backup.txt"}
                 },
                 ctx
               )

      # Redirecting a state-dir lookalike is not evidence mutation.
      assert {:ok, _} =
               Executor.run(
                 %{
                   call_id: "lookalike_redirect",
                   name: "bash",
                   args: %{"command" => "cat .pixir-notes/scratch.md > evidence-backup.txt"}
                 },
                 ctx
               )

      # A `.pixir`-prefixed sibling is not the state dir.
      assert {:ok, _} =
               Executor.run(
                 %{
                   call_id: "c",
                   name: "write",
                   args: %{"path" => ".pixir-notes/scratch.md", "content" => "x"}
                 },
                 ctx
               )

      assert File.exists?(Path.join(ws, ".pixir-notes/scratch.md"))
    end

    test "bash parent-directory scans are denied and recorded", %{ctx: ctx, sid: sid} do
      assert {:error, %{error: %{kind: :outside_workspace}}} =
               Executor.run(
                 %{call_id: "c", name: "bash", args: %{"command" => "find .. -name AGENTS.md"}},
                 ctx
               )

      assert {:ok, [_call, result]} = Log.fold(sid, workspace: ctx.workspace)
      assert result.data["ok"] == false
      assert result.data["error"]["kind"] == "outside_workspace"
    end
  end

  describe "run/2 permissions (ADR 0006)" do
    test "default context (:auto) runs writes without asking", %{ctx: ctx, ws: ws} do
      assert {:ok, _} =
               Executor.run(
                 %{call_id: "c", name: "write", args: %{"path" => "a.txt", "content" => "x"}},
                 ctx
               )

      assert File.exists?(Path.join(ws, "a.txt"))
    end

    test ":read_only denies a write and records the decision", %{ctx: ctx, sid: sid, ws: ws} do
      ctx = Map.put(ctx, :permission, %{mode: :read_only, asker: fn _ -> :deny end})

      assert {:error, %{error: %{kind: :permission_denied}}} =
               Executor.run(
                 %{call_id: "c", name: "write", args: %{"path" => "x.txt", "content" => "y"}},
                 ctx
               )

      refute File.exists?(Path.join(ws, "x.txt"))
      assert {:ok, history} = Log.fold(sid, workspace: ws)
      assert Enum.map(history, & &1.type) == [:tool_call, :permission_decision, :tool_result]
      assert List.last(history).data["ok"] == false
    end

    test ":ask invokes the asker for a write and runs on approval", %{ctx: ctx, ws: ws} do
      parent = self()

      asker = fn request ->
        send(parent, {:asked, request})
        :allow
      end

      ctx = Map.put(ctx, :permission, %{mode: :ask, asker: asker})

      assert {:ok, _} =
               Executor.run(
                 %{call_id: "c", name: "write", args: %{"path" => "a.txt", "content" => "x"}},
                 ctx
               )

      assert_received {:asked, %{tool: "write", reason: _}}
      assert File.exists?(Path.join(ws, "a.txt"))
    end

    test ":ask denies when the asker says no", %{ctx: ctx, ws: ws} do
      ctx = Map.put(ctx, :permission, %{mode: :ask, asker: fn _ -> :deny end})

      assert {:error, %{error: %{kind: :permission_denied}}} =
               Executor.run(
                 %{call_id: "c", name: "write", args: %{"path" => "x.txt", "content" => "y"}},
                 ctx
               )

      refute File.exists?(Path.join(ws, "x.txt"))
    end

    test ":ask auto-allows a safe command without invoking the asker", %{ctx: ctx} do
      parent = self()

      ctx =
        Map.put(ctx, :permission, %{
          mode: :ask,
          asker: fn _ ->
            send(parent, :asked)
            :allow
          end
        })

      assert {:ok, %{"ok" => true}} =
               Executor.run(%{call_id: "c", name: "bash", args: %{"command" => "ls"}}, ctx)

      refute_received :asked
    end

    test "bounded write policy allows listed writes and records policy metadata", %{
      ctx: ctx,
      sid: sid,
      ws: ws
    } do
      {:ok, policy} = write_policy(["allowed/**"])
      ctx = Map.put(ctx, :permission, %{mode: :auto, policy: policy})

      assert {:ok, _} =
               Executor.run(
                 %{
                   call_id: "c",
                   name: "write",
                   args: %{"path" => "allowed/out.txt", "content" => "ok"}
                 },
                 ctx
               )

      assert File.read!(Path.join(ws, "allowed/out.txt")) == "ok"
      assert {:ok, history} = Log.fold(sid, workspace: ws)
      decision = Enum.find(history, &(&1.type == :permission_decision))
      assert decision.data["gate"] == "write_policy"
      assert decision.data["policy"]["id"] == "executor-test"
    end

    test "bounded write policy denies out-of-scope writes before mutation", %{
      ctx: ctx,
      sid: sid,
      ws: ws
    } do
      {:ok, policy} = write_policy(["allowed/**"])
      ctx = Map.put(ctx, :permission, %{mode: :auto, policy: policy})

      assert {:error, %{error: %{kind: :write_policy_denied, details: details}}} =
               Executor.run(
                 %{
                   call_id: "c",
                   name: "write",
                   args: %{"path" => "blocked/out.txt", "content" => "no"}
                 },
                 ctx
               )

      assert details["matched_rule"] == "no_allow_match"
      refute File.exists?(Path.join(ws, "blocked/out.txt"))

      assert {:ok, history} = Log.fold(sid, workspace: ws)
      assert [:tool_call, :permission_decision, :tool_result] = Enum.map(history, & &1.type)
      assert Enum.at(history, 1).data["normalized_path"] == "blocked/out.txt"
      assert List.last(history).data["error"]["kind"] == "write_policy_denied"
    end

    test "bounded write policy keeps unsafe bash disabled", %{ctx: ctx, ws: ws} do
      {:ok, policy} = write_policy(["allowed/**"])
      ctx = Map.put(ctx, :permission, %{mode: :auto, policy: policy})

      assert {:error, %{error: %{kind: :write_policy_denied, details: details}}} =
               Executor.run(
                 %{call_id: "c", name: "bash", args: %{"command" => "touch allowed/out.txt"}},
                 ctx
               )

      assert details["matched_rule"] == "bash_disabled"
      refute File.exists?(Path.join(ws, "allowed/out.txt"))

      assert {:ok, %{"ok" => true}} =
               Executor.run(%{call_id: "safe", name: "bash", args: %{"command" => "ls"}}, ctx)
    end

    test "bounded write policy preserves outside_workspace for bash read escapes", %{
      ctx: ctx,
      sid: sid,
      ws: ws
    } do
      fixture = WorkspaceFixtures.outside_workspace_fixture(ws)
      on_exit(fn -> File.rm_rf!(fixture.outside) end)

      {:ok, policy} = write_policy(["allowed/**"])
      ctx = Map.put(ctx, :permission, %{mode: :auto, policy: policy})

      assert {:error, %{error: %{kind: :outside_workspace, details: details}}} =
               Executor.run(
                 %{
                   call_id: "outside",
                   name: "bash",
                   args: %{"command" => "cat #{fixture.outside_file}"}
                 },
                 ctx
               )

      assert details["tool"] == "bash"
      assert details["token"] == fixture.outside_file
      assert details["matched_rule"] == "outside_workspace"

      File.write!(Path.join(ws, "README.md"), "inside")

      assert {:ok, %{"ok" => true, "output" => "inside"}} =
               Executor.run(
                 %{call_id: "inside", name: "bash", args: %{"command" => "cat README.md"}},
                 ctx
               )

      assert {:ok, history} = Log.fold(sid, workspace: ws)
      [decision] = Enum.filter(history, &(&1.type == :permission_decision))
      assert decision.data["gate"] == "write_policy"
      assert decision.data["tool"] == "bash"
      assert decision.data["matched_rule"] == "outside_workspace"
      assert decision.data["token"] == fixture.outside_file
      assert decision.data["requested_command"] == "cat #{fixture.outside_file}"

      outside_result =
        Enum.find(history, fn event ->
          event.type == :tool_result and event.data["call_id"] == "outside"
        end)

      assert outside_result.data["error"]["kind"] == "outside_workspace"
    end
  end

  defp write_policy(allow_writes) do
    WritePolicy.normalize(%{
      "version" => 1,
      "metadata" => %{"id" => "executor-test"},
      "allow_writes" => allow_writes
    })
  end
end
