defmodule Pixir.Tools.RunVirtualCommandsTest do
  use ExUnit.Case, async: false

  alias Pixir.SessionSupervisor
  alias Pixir.Support.ToolContract
  alias Pixir.Tools.{Executor, RunVirtualCommands}

  setup do
    workspace =
      Path.join(
        System.tmp_dir!(),
        "pixir-run-virtual-commands-" <>
          Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
      )

    File.mkdir_p!(workspace)
    File.write!(Path.join(workspace, "src.txt"), "virtual source\n")

    {:ok, session_id, session_pid} =
      SessionSupervisor.start_session(workspace: workspace, role: :build)

    on_exit(fn ->
      try do
        if Process.alive?(session_pid) do
          DynamicSupervisor.terminate_child(SessionSupervisor, session_pid)
        end
      catch
        :exit, _reason -> :ok
      end

      File.rm_rf!(workspace)
    end)

    context = %{
      session_id: session_id,
      workspace: workspace,
      call_id: "virtual_call",
      virtual_overlay: %{read_set: ["src.txt"], limits: nil}
    }

    %{context: context, workspace: workspace}
  end

  test "registered tool satisfies the ADR 0005 contract", %{context: context} do
    assert :ok =
             ToolContract.verify_registered!(
               RunVirtualCommands,
               %{"commands" => ["mkdir -p contract-should-not-run"], "deliverable" => true},
               context
             )
  end

  test "Executor fails closed without operator virtual overlay context", %{context: context} do
    context = Map.delete(context, :virtual_overlay)

    assert {:error, %{error: %{kind: :invalid_args}}} =
             run(context, "missing_context", %{"commands" => ["cp src.txt copy.txt"]})
  end

  test "Executor returns an unapplied virtual_diff without mutating the parent workspace", %{
    context: context,
    workspace: workspace
  } do
    context = Map.put(context, :permission, %{mode: :read_only})

    assert {:ok, %{"output" => output, "virtual_diff" => artifact}} =
             run(context, "happy_path", %{
               "commands" => ["mkdir -p out", "cp src.txt out/dst.txt"]
             })

    assert is_binary(output)
    assert artifact["kind"] == "virtual_diff"
    assert artifact["workspace_strategy"] == "virtual_overlay"

    assert artifact["apply"] == %{
             "status" => "not_applied",
             "requires_explicit_apply" => true
           }

    assert artifact["parent_workspace"]["mutation"] == "none"
    assert artifact["import"]["read_set"] == ["src.txt"]
    assert artifact["summary"]["diff_bytes"] > 0

    assert [%{"operation" => "add", "path" => "out/dst.txt"}] = artifact["changes"]
    assert Enum.all?(Map.keys(artifact), &is_binary/1)
    refute File.exists?(Path.join(workspace, "out/dst.txt"))
  end

  test "model-facing output carries command output and diff feedback", %{context: context} do
    context = Map.put(context, :permission, %{mode: :read_only})

    assert {:ok, %{"output" => output}} =
             run(context, "output_feedback", %{
               "commands" => ["cat src.txt", "cp src.txt copy.txt"]
             })

    # The full artifact never reaches the model channel (the provider folds
    # only "output"), so stdout and the unified diff must ride this string.
    assert output =~ "$ cat src.txt (exit 0)"
    assert output =~ "virtual source"
    assert output =~ "+virtual source"
    assert byte_size(output) <= 16_000 + byte_size("…[truncated]")
  end

  test "virtual context confines real reads to the imported read set", %{
    context: context,
    workspace: workspace
  } do
    File.write!(Path.join(workspace, "secret.txt"), "outside the overlay\n")

    assert {:error,
            %{
              error: %{
                kind: :permission_denied,
                details: %{"matched_rule" => "virtual_overlay_read_set"}
              }
            }} =
             Executor.run(
               %{
                 call_id: "virtual_read_out",
                 name: "read",
                 args: %{"path" => "secret.txt", "offset" => 2, "limit" => 1}
               },
               %{context | call_id: "virtual_read_out"}
             )

    assert {:ok, %{"output" => output}} =
             Executor.run(
               %{call_id: "virtual_read_in", name: "read", args: %{"path" => "src.txt"}},
               %{context | call_id: "virtual_read_in"}
             )

    assert output =~ "virtual source"

    # The denial must also land as durable audit evidence (ADR 0006), not
    # only as the returned error.
    assert {:ok, history} = Pixir.Log.fold(context.session_id, workspace: workspace)

    assert Enum.any?(history, fn event ->
             event.type == :permission_decision and
               event.data["decision"] == "deny" and
               event.data["gate"] == "virtual_overlay" and
               event.data["matched_rule"] == "virtual_overlay_read_set"
           end)
  end

  test "virtual context denies host bash with the adaptable kind", %{context: context} do
    assert {:error,
            %{
              error: %{
                kind: :bash_disabled,
                details: %{"matched_rule" => "virtual_overlay_host_boundary"}
              }
            }} =
             Executor.run(
               %{call_id: "virtual_bash", name: "bash", args: %{"command" => "ls"}},
               %{context | call_id: "virtual_bash"}
             )
  end

  test "command feedback strips terminal-control sequences", %{
    context: context,
    workspace: workspace
  } do
    File.write!(Path.join(workspace, "ansi.txt"), "\e[31mred\e[0m plain\n")
    context = Map.put(context, :virtual_overlay, %{read_set: ["ansi.txt"], limits: nil})

    # The second command embeds controls in its own text: the echoed
    # "$ <display>" line is model-channel output too and gets the same
    # sanitizer as stdout/stderr.
    assert {:ok, %{"output" => output}} =
             run(context, "ansi_feedback", %{
               "commands" => ["cat ansi.txt", "echo \e[32mgreen\e[0m"]
             })

    assert output =~ "red plain"
    assert output =~ "green"
    refute output =~ "\e["
  end

  test "Executor rejects model-authored read_set as an unknown argument", %{context: context} do
    assert {:error, %{error: %{kind: :invalid_args, details: %{"unknown" => ["read_set"]}}}} =
             run(context, "unknown_read_set", %{
               "commands" => ["cp src.txt copy.txt"],
               "read_set" => ["src.txt"]
             })
  end

  test "read_only permission allows virtual command execution", %{context: context} do
    context = Map.put(context, :permission, %{mode: :read_only})

    assert {:ok, %{"virtual_diff" => %{"apply" => %{"status" => "not_applied"}}}} =
             run(context, "read_only", %{"commands" => []})
  end

  test "Tool boundary rechecks operator-owned read_set with shared classification", %{
    context: context
  } do
    context =
      Map.put(context, :virtual_overlay, %{
        read_set: ["src.txt", "lib/../**/*"],
        limits: nil
      })

    for checked_context <- [context, Map.put(context, :dry_run, true)] do
      assert {:error,
              %{
                error: %{
                  kind: :invalid_args,
                  details: %{
                    "field" => "virtual_overlay.read_set",
                    "index" => 1,
                    "reason" => "parent_component"
                  }
                }
              }} = run(checked_context, "unsafe_context", %{"commands" => []})
    end
  end

  test "Executor dry-run is effect-free and echoes the operator plan", %{
    context: context,
    workspace: workspace
  } do
    context =
      Map.merge(context, %{
        dry_run: true,
        virtual_overlay: %{
          read_set: ["missing.txt"],
          limits: %{"max_virtual_commands" => 0}
        }
      })

    assert {:ok,
            %{
              "dry_run" => true,
              "command_count" => 1,
              "effective_read_set_size" => 1,
              "limits" => %{"max_virtual_commands" => 0}
            }} = run(context, "dry_run", %{"commands" => ["mkdir -p should_not_run"]})

    refute File.exists?(Path.join(workspace, "should_not_run"))
  end

  test "deliverable metadata survives the canonical Log outside the v1 artifact", %{
    context: context
  } do
    for flag <- [true, false] do
      assert {:ok, result} =
               run(context, "deliverable_#{flag}", %{
                 "commands" => ["cp src.txt scratch.txt", "cat scratch.txt"],
                 "deliverable" => flag
               })

      assert result["deliverable"] == flag
      assert result["virtual_diff"]["version"] == 1
      refute Map.has_key?(result["virtual_diff"], "deliverable")
      assert Enum.at(result["virtual_diff"]["commands"], 1)["stdout"] == "virtual source\n"
      assert {:ok, history} = Pixir.Log.fold(context.session_id, workspace: context.workspace)

      event =
        Enum.find(
          history,
          &(&1.type == :tool_result and &1.data["call_id"] == "deliverable_#{flag}")
        )

      assert event.data["deliverable"] == flag
      assert event.data["virtual_diff"] == result["virtual_diff"]
    end
  end

  test "scratch shares edits within one invocation but the next invocation reimports host files",
       %{context: context, workspace: workspace} do
    assert {:ok, first} =
             run(context, "scratch_write", %{
               "commands" => [
                 "sed -i 's/source/changed/' src.txt",
                 "cp src.txt scratch.txt",
                 "cat scratch.txt"
               ]
             })

    assert List.last(first["virtual_diff"]["commands"])["stdout"] == "virtual changed\n"

    assert {:ok, next} =
             run(context, "scratch_reset", %{"commands" => ["cat scratch.txt", "cat src.txt"]})

    assert hd(next["virtual_diff"]["commands"])["exit_code"] != 0
    assert List.last(next["virtual_diff"]["commands"])["stdout"] == "virtual source\n"
    assert next["virtual_diff"]["changes"] == []
    assert next["output"] =~ "next call reimports host files"
    assert next["output"] =~ "Logs/artifacts persist on disk"
    assert File.read!(Path.join(workspace, "src.txt")) == "virtual source\n"
    refute File.exists?(Path.join(workspace, "scratch.txt"))
  end

  test "malformed deliverable flags and model limits are denied in execution and dry run", %{
    context: context
  } do
    for flag <- [nil, "true", 1, [], %{}], dry_run <- [false, true] do
      assert {:error, %{error: %{kind: :invalid_args}}} =
               run(Map.put(context, :dry_run, dry_run), "invalid_flag", %{
                 "commands" => [],
                 "deliverable" => flag
               })
    end

    assert {:error, %{error: %{kind: :invalid_args}}} =
             run(context, "model_limits", %{"commands" => [], "limits" => %{}})
  end

  test "large first stdout and display cannot hide later command outcomes", %{
    context: context,
    workspace: workspace
  } do
    File.write!(Path.join(workspace, "src.txt"), String.duplicate("huge output\n", 3_000))

    assert {:ok, result} =
             run(context, "large_feedback", %{
               "commands" => [
                 "cat src.txt # " <> String.duplicate("long", 5_000),
                 "cat missing.txt",
                 "cp src.txt copy.txt"
               ]
             })

    output = result["output"]
    assert byte_size(output) <= 16_000
    assert output =~ "cmd_1"
    assert output =~ "cmd_2"
    assert output =~ "$ cat missing.txt (exit 1)"
    assert output =~ "cmd_3"
    assert output =~ "truncated"
    assert output =~ "…[truncated, showing up to "
    {status_pos, _} = :binary.match(output, "cmd_3")
    {stdout_pos, _} = :binary.match(output, "huge output")
    assert status_pos < stdout_pos
    assert byte_size(hd(result["virtual_diff"]["commands"])["display"]) > 16_000
  end

  test "oversized status lists report omitted command and excerpt counts", %{context: context} do
    context = put_in(context, [:virtual_overlay, :limits], %{"max_virtual_commands" => 300})

    assert {:ok, result} =
             run(context, "many_statuses", %{"commands" => List.duplicate("echo ok", 300)})

    assert byte_size(result["output"]) <= 16_000
    assert result["output"] =~ "omitted_commands="
    assert result["output"] =~ "omitted_excerpts="
    assert result["output"] =~ "truncated_displays="
    [_, omitted] = Regex.run(~r/omitted_commands=(\d+)/, result["output"])
    omitted = String.to_integer(omitted)
    assert omitted > 0
    assert length(Regex.scan(~r/^cmd_\d+ \$/m, result["output"])) + omitted == 300
    [_, omitted_excerpts] = Regex.run(~r/omitted_excerpts=(\d+)/, result["output"])
    assert String.to_integer(omitted_excerpts) > 0
    assert length(result["virtual_diff"]["commands"]) == 300
  end

  defp run(context, call_id, args) do
    Executor.run(
      %{call_id: call_id, name: "run_virtual_commands", args: args},
      %{context | call_id: call_id}
    )
  end
end
