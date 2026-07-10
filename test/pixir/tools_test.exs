defmodule Pixir.ToolsTest do
  use ExUnit.Case, async: true

  alias Pixir.{Log, Permissions.WritePolicy, SessionSupervisor}
  alias Pixir.Support.ToolContract
  alias Pixir.Test.WorkspaceFixtures

  alias Pixir.Tools.{
    ApplyVirtualDiff,
    Bash,
    CloseAgent,
    CommandBoundary,
    Edit,
    ListAgents,
    Read,
    Registry,
    RunWorkflow,
    SendInput,
    SkillView,
    SkillsList,
    SpawnAgent,
    UpdatePlan,
    WaitAgent,
    Write
  }

  defmodule PartialWorkflowProvider do
    def stream(%{history: history}, _opts) do
      prompt =
        history
        |> Enum.find(&(&1.type == :user_message))
        |> then(&((&1 && &1.data["text"]) || ""))

      if String.contains?(prompt, "Step: fail") do
        {:error, Pixir.Tool.error(:command_failed, "planned failure", %{})}
      else
        {:ok,
         %{
           text: "checkpoint ready",
           reasoning: "",
           reasoning_items: [],
           function_calls: [],
           finish_reason: :stop
         }}
      end
    end
  end

  setup do
    ws =
      Path.join(
        System.tmp_dir!(),
        "pixir-tools-" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
      )

    File.mkdir_p!(ws)
    on_exit(fn -> File.rm_rf!(ws) end)
    %{ctx: %{session_id: "s", workspace: ws, call_id: "c1"}, ws: ws}
  end

  describe "ADR 0005 contract" do
    test "read/write/edit/bash satisfy the ergonomics contract", %{ctx: ctx, ws: ws} do
      File.write!(Path.join(ws, "a.txt"), "hello")
      assert :ok = ToolContract.verify!(Read, %{"path" => "a.txt"}, ctx)
      assert :ok = ToolContract.verify!(Write, %{"path" => "a.txt", "content" => "x"}, ctx)

      assert :ok =
               ToolContract.verify!(
                 Edit,
                 %{"path" => "a.txt", "old_string" => "hello", "new_string" => "hi"},
                 ctx
               )

      assert :ok = ToolContract.verify!(Bash, %{"command" => "echo hi"}, ctx)

      assert :ok =
               ToolContract.verify!(
                 ApplyVirtualDiff,
                 %{
                   "artifact" => %{
                     "kind" => "virtual_diff",
                     "version" => 1,
                     "changes" => []
                   }
                 },
                 ctx
               )

      write_skill(Path.join(ws, ".agents/skills/sample"), "sample", "Sample skill", "body")

      assert :ok =
               ToolContract.verify!(
                 UpdatePlan,
                 %{"entries" => [%{"content" => "do x"}]},
                 ctx
               )

      assert :ok = ToolContract.verify!(SkillsList, %{}, ctx)
      assert :ok = ToolContract.verify!(SkillView, %{"name" => "sample"}, ctx)
      assert :ok = ToolContract.verify!(SpawnAgent, %{"task" => "inspect auth"}, ctx)
      assert :ok = ToolContract.verify!(WaitAgent, %{}, ctx)

      assert :ok =
               ToolContract.verify!(SendInput, %{"id" => "sub_1", "prompt" => "continue"}, ctx)

      assert :ok = ToolContract.verify!(CloseAgent, %{"id" => "sub_1"}, ctx)
      assert :ok = ToolContract.verify!(ListAgents, %{}, ctx)

      assert :ok =
               ToolContract.verify!(
                 RunWorkflow,
                 %{
                   "steps" => [
                     %{"id" => "inspect", "task" => "inspect repository", "agent" => "explorer"}
                   ]
                 },
                 ctx
               )
    end

    test "spawn_agent dry_run previews inherited write policy", %{ctx: ctx} do
      {:ok, policy} =
        WritePolicy.normalize(%{
          "version" => 1,
          "metadata" => %{"id" => "spawn-preview"},
          "allow_writes" => ["allowed/**"]
        })

      ctx = Map.put(ctx, :permission, %{policy: policy})

      assert {:ok, plan} = SpawnAgent.dry_run(%{"task" => "inspect auth"}, ctx)
      # dry_run now returns the same normalized plan as validate_only (#204
      # gap 4); the inherited policy rides the plan projection.
      assert get_in(plan, ["plan", "write_policy", "id"]) == "spawn-preview"
    end
  end

  describe "edit" do
    test "replaces a unique occurrence", %{ctx: ctx, ws: ws} do
      File.write!(Path.join(ws, "f.txt"), "alpha beta gamma")

      assert {:ok, %{"replacements" => 1}} =
               Edit.execute(
                 %{"path" => "f.txt", "old_string" => "beta", "new_string" => "BETA"},
                 ctx
               )

      assert File.read!(Path.join(ws, "f.txt")) == "alpha BETA gamma"
    end

    test "errors when old_string is absent", %{ctx: ctx, ws: ws} do
      File.write!(Path.join(ws, "f.txt"), "abc")

      assert {:error, %{error: %{kind: :no_match}}} =
               Edit.execute(%{"path" => "f.txt", "old_string" => "xyz", "new_string" => "q"}, ctx)
    end

    test "errors when old_string is not unique (unless replace_all)", %{ctx: ctx, ws: ws} do
      File.write!(Path.join(ws, "f.txt"), "x x x")

      assert {:error, %{error: %{kind: :not_unique, details: %{occurrences: 3}}}} =
               Edit.execute(%{"path" => "f.txt", "old_string" => "x", "new_string" => "y"}, ctx)

      assert {:ok, %{"replacements" => 3}} =
               Edit.execute(
                 %{
                   "path" => "f.txt",
                   "old_string" => "x",
                   "new_string" => "y",
                   "replace_all" => true
                 },
                 ctx
               )

      assert File.read!(Path.join(ws, "f.txt")) == "y y y"
    end

    test "dry_run reports replacements without writing", %{ctx: ctx, ws: ws} do
      File.write!(Path.join(ws, "f.txt"), "keep me")

      assert {:ok, %{"dry_run" => true, "replacements" => 1}} =
               Edit.dry_run(
                 %{"path" => "f.txt", "old_string" => "keep", "new_string" => "drop"},
                 ctx
               )

      assert File.read!(Path.join(ws, "f.txt")) == "keep me"
    end

    test "refuses to edit outside the workspace", %{ctx: ctx} do
      assert {:error, %{error: %{kind: :outside_workspace}}} =
               Edit.execute(
                 %{"path" => "../escape.txt", "old_string" => "a", "new_string" => "b"},
                 ctx
               )
    end
  end

  describe "read" do
    test "reads a file in the workspace", %{ctx: ctx, ws: ws} do
      File.write!(Path.join(ws, "a.txt"), "hello")
      assert {:ok, %{"output" => "hello"}} = Read.execute(%{"path" => "a.txt"}, ctx)
    end

    test "missing file is a structured not_found error", %{ctx: ctx} do
      assert {:error, %{error: %{kind: :not_found}}} = Read.execute(%{"path" => "nope.txt"}, ctx)
    end

    test "refuses to read outside the workspace", %{ctx: ctx} do
      assert {:error, %{error: %{kind: :outside_workspace}}} =
               Read.execute(%{"path" => "../../etc/passwd"}, ctx)
    end

    test "dry_run reports intent without reading", %{ctx: ctx} do
      assert {:ok, %{"dry_run" => true, "would" => "read", "exists" => false}} =
               Read.dry_run(%{"path" => "a.txt"}, ctx)
    end
  end

  describe "write" do
    test "writes a file atomically and reports bytes", %{ctx: ctx, ws: ws} do
      assert {:ok, %{"bytes" => 5}} =
               Write.execute(%{"path" => "out/a.txt", "content" => "hello"}, ctx)

      assert File.read!(Path.join(ws, "out/a.txt")) == "hello"
    end

    test "dry_run does not create the file", %{ctx: ctx, ws: ws} do
      assert {:ok, %{"dry_run" => true, "would" => "write", "bytes" => 3}} =
               Write.dry_run(%{"path" => "b.txt", "content" => "abc"}, ctx)

      refute File.exists?(Path.join(ws, "b.txt"))
    end

    test "refuses to write outside the workspace", %{ctx: ctx} do
      assert {:error, %{error: %{kind: :outside_workspace}}} =
               Write.execute(%{"path" => "/tmp/escape.txt", "content" => "x"}, ctx)
    end
  end

  describe "bash" do
    test "runs a command in the workspace and captures output", %{ctx: ctx, ws: ws} do
      File.write!(Path.join(ws, "marker"), "")
      boundary = start_boundary()

      ctx =
        ctx
        |> Map.put(:host_command_boundary, boundary)
        |> Map.put(:host_command_limits, host_command_limits())

      assert {:ok,
              %{
                "output" => out,
                "exit_code" => 0,
                "ok" => true,
                "timeout" => timeout,
                "host_command" => host_command
              }} =
               Bash.execute(%{"command" => "ls"}, ctx)

      assert out =~ "marker"
      assert timeout["requested_ms"] == nil
      assert timeout["effective_ms"] == 120_000
      assert timeout["source"] == "config"
      assert timeout["capped"] == false
      assert host_command["boundary"] == "host_command"
      assert host_command["tool"] == "bash"
    end

    test "reports a non-zero exit code", %{ctx: ctx} do
      boundary = start_boundary()

      ctx =
        ctx
        |> Map.put(:host_command_boundary, boundary)
        |> Map.put(:host_command_limits, host_command_limits())

      assert {:ok, %{"exit_code" => code, "ok" => false, "host_command" => host_command}} =
               Bash.execute(%{"command" => "exit 3"}, ctx)

      assert code == 3
      assert host_command["boundary"] == "host_command"
      assert {:ok, %{"active_count" => 0, "queue_depth" => 0}} = boundary_snapshot(boundary)
    end

    test "reports requested and effective context timeout metadata", %{ctx: ctx} do
      boundary = start_boundary()

      ctx =
        ctx
        |> Map.put(:bash_timeout_ms, 250)
        |> Map.put(:bash_timeout_source, "cli")
        |> Map.put(:host_command_boundary, boundary)
        |> Map.put(:host_command_limits, host_command_limits())

      assert {:ok,
              %{
                "timeout" => %{
                  "requested_ms" => 250,
                  "configured_ms" => 250,
                  "effective_ms" => 250,
                  "max_ms" => max_ms,
                  "source" => "cli",
                  "capped" => false
                }
              }} = Bash.execute(%{"command" => "echo ok"}, ctx)

      assert max_ms >= 250
    end

    test "ignores invalid context timeout values and falls back to config", %{ctx: ctx} do
      boundary = start_boundary()

      ctx =
        ctx
        |> Map.put(:bash_timeout_ms, 0)
        |> Map.put(:bash_timeout_source, "cli")
        |> Map.put(:host_command_boundary, boundary)
        |> Map.put(:host_command_limits, host_command_limits())

      assert {:ok,
              %{
                "timeout" => %{
                  "requested_ms" => nil,
                  "configured_ms" => 120_000,
                  "effective_ms" => 120_000,
                  "source" => "config",
                  "capped" => false
                }
              }} = Bash.execute(%{"command" => "echo ok"}, ctx)
    end

    test "dry_run does not execute", %{ctx: ctx, ws: ws} do
      boundary = start_boundary()

      assert {:ok, %{"dry_run" => true, "would" => "run"}} =
               Bash.dry_run(
                 %{"command" => "touch should_not_exist"},
                 Map.put(ctx, :host_command_boundary, boundary)
               )

      refute File.exists?(Path.join(ws, "should_not_exist"))
      assert {:ok, %{"active_count" => 0, "queue_depth" => 0}} = boundary_snapshot(boundary)
    end

    test "rejects parent-directory path references before host execution", %{ctx: ctx} do
      boundary = start_boundary()

      ctx =
        ctx
        |> Map.put(:host_command_boundary, boundary)
        |> Map.put(:host_command_limits, host_command_limits())

      assert {:error,
              %{
                error: %{
                  kind: :outside_workspace,
                  details: %{"tool" => "bash", "token" => ".."}
                }
              }} =
               Bash.execute(%{"command" => "find .. -name AGENTS.md"}, ctx)

      assert {:ok, %{"active_count" => 0, "queue_depth" => 0}} = boundary_snapshot(boundary)
    end

    test "rejects operator-adjacent parent-directory references", %{ctx: ctx} do
      boundary = start_boundary()

      ctx =
        ctx
        |> Map.put(:host_command_boundary, boundary)
        |> Map.put(:host_command_limits, host_command_limits())

      for {command, token} <- [
            {"cat <../outside.txt", "../outside.txt"},
            {"echo x >../out", "../out"},
            {"cat '..'/outside.txt", "'..'/outside.txt"}
          ] do
        assert {:error,
                %{
                  error: %{
                    kind: :outside_workspace,
                    details: %{"tool" => "bash", "token" => ^token}
                  }
                }} = Bash.execute(%{"command" => command}, ctx)

        assert {:ok, %{"active_count" => 0, "queue_depth" => 0}} = boundary_snapshot(boundary)
      end
    end

    test "rejects absolute, home, and symlink workspace escapes before host execution", %{
      ctx: ctx,
      ws: ws
    } do
      boundary = start_boundary()
      fixture = WorkspaceFixtures.outside_workspace_fixture(ws)
      on_exit(fn -> File.rm_rf!(fixture.outside) end)

      ctx =
        ctx
        |> Map.put(:host_command_boundary, boundary)
        |> Map.put(:host_command_limits, host_command_limits())

      for {command, token} <- [
            {"cat #{fixture.outside_file}", fixture.outside_file},
            {"cat $HOME", "$HOME"},
            {"cat ${HOME}", "${HOME}"},
            {"cat $HOME/neighbor-notes.txt", "$HOME/neighbor-notes.txt"},
            {"cat ~/neighbor-notes.txt", "~/neighbor-notes.txt"},
            {"cat #{fixture.symlink_token}", fixture.symlink_token},
            {"cat outside-link/missing.txt", "outside-link/missing.txt"},
            {"cat outside-link/*.txt", "outside-link/*.txt"}
          ] do
        assert {:error,
                %{
                  error: %{
                    kind: :outside_workspace,
                    details: %{
                      "tool" => "bash",
                      "token" => ^token,
                      "requested_command" => ^command,
                      "matched_rule" => "outside_workspace"
                    }
                  }
                }} = Bash.execute(%{"command" => command}, ctx)

        assert {:ok, %{"active_count" => 0, "queue_depth" => 0}} = boundary_snapshot(boundary)
      end
    end

    test "allows workspace-relative reads after escape checks", %{ctx: ctx, ws: ws} do
      File.write!(Path.join(ws, "README.md"), "inside workspace")
      boundary = start_boundary()

      ctx =
        ctx
        |> Map.put(:host_command_boundary, boundary)
        |> Map.put(:host_command_limits, host_command_limits())

      assert {:ok, %{"ok" => true, "output" => output}} =
               Bash.execute(%{"command" => "cat README.md"}, ctx)

      assert output == "inside workspace"
      assert {:ok, %{"active_count" => 0, "queue_depth" => 0}} = boundary_snapshot(boundary)
    end

    test "kills a command that exceeds the timeout", %{ctx: ctx} do
      boundary = start_boundary()

      ctx =
        ctx
        |> Map.put(:bash_timeout_ms, 150)
        |> Map.put(:host_command_boundary, boundary)
        |> Map.put(:host_command_limits, host_command_limits())

      assert {:error,
              %{
                error: %{
                  kind: :timeout,
                  details: %{
                    "host_command" => %{"boundary" => "host_command"},
                    "seconds" => 0,
                    "timeout" => %{
                      "requested_ms" => 150,
                      "effective_ms" => 150,
                      "source" => "context"
                    }
                  }
                }
              }} =
               Bash.execute(%{"command" => "sleep 5"}, ctx)

      assert {:ok, %{"active_count" => 0, "queue_depth" => 0}} = boundary_snapshot(boundary)
    end

    test "reports structured backpressure without running or logging raw command", %{ctx: ctx} do
      parent = self()
      limits = host_command_limits(queue_limit: 0)
      boundary = start_boundary()

      holder =
        Task.async(fn ->
          CommandBoundary.with_slot("bash", [boundary: boundary, limits: limits], fn _lease ->
            send(parent, :holder_acquired)

            receive do
              :release_holder -> :released
            end
          end)
        end)

      assert_receive :holder_acquired, 1_000

      ctx =
        ctx
        |> Map.put(:host_command_boundary, boundary)
        |> Map.put(:host_command_limits, limits)

      assert {:error, %{error: %{kind: :backpressure, details: details}}} =
               Bash.execute(%{"command" => "echo secret-token"}, ctx)

      assert details["boundary"] == "host_command"
      assert details["tool"] == "bash"
      assert details["active_count"] == 1
      assert details["max_concurrent"] == 1
      assert details["queue_depth"] == 0
      assert details["queue_limit"] == 0
      assert details["reason"] == "queue_full"
      refute inspect(details) =~ "secret-token"

      send(holder.pid, :release_holder)
      assert :released = Task.await(holder)
    end
  end

  describe "command boundary" do
    test "queues a host command and exposes runtime pressure state" do
      parent = self()
      limits = host_command_limits(queue_limit: 1, queue_timeout_ms: 1_000)
      boundary = start_boundary()

      holder =
        Task.async(fn ->
          CommandBoundary.with_slot("bash", [boundary: boundary, limits: limits], fn lease ->
            send(parent, {:holder_acquired, lease.host_command})

            receive do
              :release_holder -> :holder_done
            end
          end)
        end)

      assert_receive {:holder_acquired, %{"active_count_at_start" => 1}}, 1_000

      queued =
        Task.async(fn ->
          CommandBoundary.with_slot("bash", [boundary: boundary, limits: limits], fn lease ->
            send(parent, {:queued_acquired, lease.host_command})
            :queued_done
          end)
        end)

      assert :ok =
               wait_until(
                 fn -> match?({:ok, %{"queue_depth" => 1}}, boundary_snapshot(boundary)) end,
                 1_000
               )

      assert {:ok,
              %{
                "active_count" => 1,
                "max_concurrent" => 1,
                "queue_depth" => 1,
                "queue_limit" => 1,
                "pressure_state" => "saturated"
              }} = boundary_snapshot(boundary)

      refute_receive {:queued_acquired, _}, 50

      send(holder.pid, :release_holder)
      assert_receive {:queued_acquired, %{"queued_ms" => queued_ms}}, 1_000
      assert queued_ms >= 0
      assert :holder_done = Task.await(holder)
      assert :queued_done = Task.await(queued)

      assert {:ok, %{"active_count" => 0, "queue_depth" => 0, "pressure_state" => "available"}} =
               boundary_snapshot(boundary)
    end

    test "times out a queued host command with backpressure details" do
      parent = self()
      limits = host_command_limits(queue_limit: 1, queue_timeout_ms: 20)
      boundary = start_boundary()

      holder =
        Task.async(fn ->
          CommandBoundary.with_slot("bash", [boundary: boundary, limits: limits], fn _lease ->
            send(parent, :holder_acquired)

            receive do
              :release_holder -> :holder_done
            end
          end)
        end)

      assert_receive :holder_acquired, 1_000

      assert {:error, %{error: %{kind: :backpressure, details: details}}} =
               CommandBoundary.with_slot(
                 "bash",
                 [boundary: boundary, limits: limits],
                 fn _lease ->
                   :should_not_run
                 end
               )

      assert details["boundary"] == "host_command"
      assert details["reason"] == "queue_timeout"
      assert details["queued_ms"] >= 0

      send(holder.pid, :release_holder)
      assert :holder_done = Task.await(holder)
    end

    test "releases a host command lease when the caller raises" do
      limits = host_command_limits()
      boundary = start_boundary()

      assert_raise RuntimeError, "boom", fn ->
        CommandBoundary.with_slot("bash", [boundary: boundary, limits: limits], fn _lease ->
          raise "boom"
        end)
      end

      assert {:ok, %{"active_count" => 0, "queue_depth" => 0}} = boundary_snapshot(boundary)
    end
  end

  describe "registry" do
    test "resolves known tools and rejects unknown", %{} do
      assert {:ok, Read} = Registry.fetch("read")
      assert {:ok, ApplyVirtualDiff} = Registry.fetch("apply_virtual_diff")
      assert {:error, %{error: %{kind: :unknown_tool}}} = Registry.fetch("nope")
    end

    test "responses_specs builds function specs for every tool" do
      specs = Registry.responses_specs()
      assert length(specs) == length(Registry.names())
      assert Enum.map(specs, & &1["name"]) == Registry.names()

      assert Enum.any?(specs, &(&1["name"] == "apply_virtual_diff"))

      assert Enum.all?(
               specs,
               &match?(%{"type" => "function", "name" => _, "parameters" => _}, &1)
             )
    end

    test "anthropic_specs builds input schemas for every tool" do
      specs = Registry.anthropic_specs()
      assert length(specs) == length(Registry.names())
      assert Enum.map(specs, & &1["name"]) == Registry.names()
      assert Enum.any?(specs, &(&1["name"] == "apply_virtual_diff"))

      assert Enum.all?(
               specs,
               &match?(%{"name" => _, "description" => _, "input_schema" => _}, &1)
             )
    end
  end

  describe "skills tools" do
    test "skills_list returns bounded metadata and duplicate warnings", %{ctx: ctx, ws: ws} do
      skill_dir =
        write_skill(Path.join(ws, ".agents/skills/collision"), "collision", "Repo skill", "repo")

      write_workflow_template(skill_dir, "hidden", %{
        "id" => "hidden",
        "workflow" => %{"steps" => [%{"id" => "inspect", "task" => "inspect"}]}
      })

      user_root = Path.join(ws, "outside-user")
      write_skill(Path.join(user_root, "collision"), "collision", "User skill", "user")

      ctx =
        Map.put(ctx, :skills_opts,
          roots: [
            %{scope: "repo", path: Path.join(ws, ".agents/skills")},
            %{scope: "user", path: user_root}
          ]
        )

      assert {:ok, %{"skills" => [skill], "warnings" => [warning], "output" => output}} =
               SkillsList.execute(%{}, ctx)

      assert skill["name"] == "collision"
      assert skill["scope"] == "repo"
      assert warning["name"] == "collision"
      assert output =~ "\"skills\""
      refute Map.has_key?(skill, "workflow_templates")
      refute output =~ "workflow_templates"
      refute output =~ "hidden"
    end

    test "skill_view records activation for SKILL.md but not supporting files", %{ws: ws} do
      write_skill(Path.join(ws, ".agents/skills/sample"), "sample", "Sample skill", "main body")
      {:ok, sid, pid} = SessionSupervisor.start_session(workspace: ws, role: :build)

      on_exit(fn ->
        if Process.alive?(pid), do: DynamicSupervisor.terminate_child(SessionSupervisor, pid)
      end)

      ctx = %{session_id: sid, workspace: ws, call_id: "c1"}

      assert {:ok, %{"activated" => true, "content_hash" => hash, "output" => output}} =
               SkillView.execute(%{"name" => "sample"}, ctx)

      assert is_binary(hash)
      assert output =~ "Sample skill"

      assert {:ok, %{"activated" => false, "content_hash" => nil}} =
               SkillView.execute(%{"name" => "sample", "path" => "references/note.md"}, ctx)

      assert {:ok, history} = Log.fold(sid, workspace: ws)
      assert [%{type: :skill_activation, data: data}] = history
      assert data["name"] == "sample"
      assert data["content"] =~ "main body"
      assert data["activated_by"] == "model"
    end

    test "skill_view rejects malformed optional path instead of crashing", %{ctx: ctx, ws: ws} do
      write_skill(Path.join(ws, ".agents/skills/sample"), "sample", "Sample skill", "body")

      assert {:error, %{error: %{kind: :invalid_args, message: "path must be a string"}}} =
               SkillView.execute(%{"name" => "sample", "path" => %{}}, ctx)
    end
  end

  describe "run_workflow" do
    test "__tool__ schema stays provider-compatible while documenting valid input shapes" do
      schema = RunWorkflow.__tool__().parameters

      assert schema["required"] == []
      refute Map.has_key?(schema, "oneOf")
      refute Map.has_key?(schema, "anyOf")
      refute Map.has_key?(schema, "allOf")
      refute Map.has_key?(schema, "not")
      refute Map.has_key?(schema, "enum")

      assert schema["properties"]["steps"]["description"] =~ "Workflow steps"
      step_schema = schema["properties"]["steps"]["items"]["properties"]
      assert step_schema["workspace_mode"]["enum"] == ["shared", "isolated", "virtual_overlay"]
      assert step_schema["virtual_commands"]["description"] =~ "inside BEAM"
      assert step_schema["limits"]["description"] =~ "max_virtual_commands"

      assert schema["properties"]["template_id"]["description"] =~
               "Skill-backed Workflow Template"

      assert schema["properties"]["skill"]["description"] =~ "separate template field"
      assert schema["properties"]["template"]["description"] =~ "paired with skill"
    end

    test "dry_run expands a Skill-backed Workflow Template", %{ctx: ctx, ws: ws} do
      skill_dir =
        write_skill(Path.join(ws, ".agents/skills/planner"), "planner", "Planner skill", "body")

      write_workflow_template(skill_dir, "single", %{
        "id" => "single",
        "parameters" => %{"topic" => %{"type" => "string", "required" => true}},
        "workflow" => %{
          "id" => "single_{{topic}}",
          "steps" => [
            %{"id" => "inspect", "task" => "Inspect {{topic}}", "agent" => "explorer"}
          ]
        }
      })

      assert {:ok, %{"workflow" => workflow, "output" => output}} =
               RunWorkflow.dry_run(
                 %{"template_id" => "planner/single", "template_args" => %{"topic" => "repo"}},
                 ctx
               )

      assert workflow["template"]["template_id"] == "planner/single"
      assert workflow["workflow_id"] == "single_repo"
      assert output =~ "from template planner/single"
    end

    test "strips model, reasoning_effort, and attachments from model-authored steps", %{
      ctx: ctx
    } do
      args = %{
        "steps" => [
          %{
            "id" => "smuggle",
            "task" => "go",
            "agent" => "explorer",
            "model" => "gpt-expensive",
            "reasoning_effort" => "xhigh",
            "attachments" => ["/etc/passwd"]
          }
        ]
      }

      assert {:ok, %{"workflow" => workflow}} = RunWorkflow.dry_run(args, ctx)

      assert [plan] = workflow["would_run"]
      refute Map.has_key?(plan, "model")
      refute Map.has_key?(plan, "reasoning_effort")
      refute Map.has_key?(plan, "attachment_count")
    end

    test "execute returns honest partial workflow output instead of tool error", %{ws: ws} do
      {:ok, sid, pid} = SessionSupervisor.start_session(workspace: ws, role: :build)

      on_exit(fn ->
        if Process.alive?(pid), do: DynamicSupervisor.terminate_child(SessionSupervisor, pid)
      end)

      ctx = %{
        session_id: sid,
        workspace: ws,
        call_id: "c1",
        provider: PartialWorkflowProvider
      }

      args = %{
        "steps" => [
          %{"id" => "ready", "task" => "ready", "agent" => "explorer"},
          %{"id" => "fail", "task" => "fail", "agent" => "explorer"},
          %{
            "id" => "held",
            "task" => "held",
            "agent" => "explorer",
            "depends_on" => ["fail"]
          }
        ]
      }

      assert {:ok, %{"workflow" => workflow, "output" => output}} =
               RunWorkflow.execute(args, ctx)

      assert workflow["status"] == "partial"
      assert [%{"id" => "fail"}] = workflow["failed_steps"]
      assert [%{"id" => "held"}] = workflow["held_steps"]
      assert output =~ "partial"
      refute output =~ "completed"
    end

    test "execute returns not-applied virtual_diff for virtual_overlay steps", %{ctx: ctx, ws: ws} do
      path = Path.join(ws, "source.txt")
      File.write!(path, "workflow source\n")
      original = File.read!(path)

      args = %{
        "id" => "virtual_tool",
        "steps" => [
          %{
            "id" => "scratch",
            "task" => "scratch edit",
            "workspace_mode" => "virtual_overlay",
            "read_set" => ["source.txt"],
            "virtual_commands" => ["sed -i 's/workflow/virtual/' source.txt"]
          }
        ]
      }

      assert {:ok, %{"workflow" => workflow, "output" => output}} =
               RunWorkflow.execute(args, ctx)

      assert output =~ "Workflow virtual_tool completed"
      assert [%{"virtual_diff" => artifact}] = workflow["steps"]
      assert artifact["kind"] == "virtual_diff"
      assert artifact["apply"]["status"] == "not_applied"
      assert artifact["parent_workspace"]["mutation"] == "none"
      assert File.read!(path) == original
    end
  end

  describe "subagent tool schemas" do
    test "spawn_agent and wait_agent describe depth and timeout semantics" do
      spawn_schema = SpawnAgent.__tool__().parameters
      wait_schema = WaitAgent.__tool__().parameters

      assert spawn_schema["properties"]["max_depth"]["description"] =~
               "root children run at depth 1"

      assert spawn_schema["properties"]["max_depth"]["minimum"] == 0

      assert spawn_schema["properties"]["timeout_ms"]["description"] =~
               "interrupts the child Session"

      assert spawn_schema["properties"]["timeout_ms"]["minimum"] == 1

      assert spawn_schema["properties"]["workspace_mode"]["enum"] == ["isolated", "shared"]

      assert wait_schema["properties"]["timeout_ms"]["description"] =~
               "never cancels the child"

      assert wait_schema["properties"]["timeout_ms"]["minimum"] == 0

      assert WaitAgent.__tool__().description =~ "cheap child Log pointers"
    end
  end

  describe "update_plan" do
    test "rejects non-object entries instead of crashing", %{ctx: ctx} do
      args = %{"entries" => [%{"content" => "ok"}, "not-a-map"]}

      assert {:error,
              %{error: %{kind: :invalid_args, message: "entries must be a list of objects"}}} =
               UpdatePlan.execute(args, ctx)

      assert {:error,
              %{error: %{kind: :invalid_args, message: "entries must be a list of objects"}}} =
               UpdatePlan.dry_run(args, ctx)
    end
  end

  defp write_skill(dir, name, description, body) do
    File.mkdir_p!(Path.join(dir, "references"))

    File.write!(Path.join(dir, "SKILL.md"), """
    ---
    name: #{name}
    description: #{description}
    ---

    # #{description}

    #{body}
    """)

    File.write!(Path.join(dir, "references/note.md"), "note for #{name}\n")
    dir
  end

  defp write_workflow_template(skill_dir, name, payload) do
    dir = Path.join(skill_dir, "workflows")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "#{name}.json"), Jason.encode!(payload, pretty: true))
  end

  defp start_boundary do
    start_supervised!({CommandBoundary, name: nil})
  end

  defp boundary_snapshot(boundary, limits \\ host_command_limits()) do
    CommandBoundary.snapshot(boundary: boundary, limits: limits)
  end

  defp host_command_limits(overrides \\ []) do
    %{
      "max_concurrent" => Keyword.get(overrides, :max_concurrent, 1),
      "queue_limit" => Keyword.get(overrides, :queue_limit, 1),
      "queue_timeout_ms" => Keyword.get(overrides, :queue_timeout_ms, 500)
    }
  end

  defp wait_until(fun, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_until(fun, deadline)
  end

  defp do_wait_until(fun, deadline) do
    cond do
      fun.() ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        {:error, :timeout}

      true ->
        Process.sleep(10)
        do_wait_until(fun, deadline)
    end
  end
end
