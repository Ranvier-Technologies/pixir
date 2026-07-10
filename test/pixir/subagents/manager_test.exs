defmodule Pixir.Subagents.ManagerTest do
  use ExUnit.Case, async: false

  alias Pixir.{Event, Log, SessionSupervisor, Subagents}
  alias Pixir.Subagents.Manager

  defmodule VirtualCommandProvider do
    def stream(%{history: history}, _opts) do
      case Enum.find(history, &(&1.type == :tool_result)) do
        nil ->
          {:ok,
           %{
             text: "",
             reasoning: "",
             reasoning_items: [],
             function_calls: [
               %{
                 call_id: "virtual_child_command",
                 name: "run_virtual_commands",
                 args: %{
                   "commands" => [
                     "mkdir -p out",
                     "cp source.txt out/from-child.txt"
                   ]
                 }
               }
             ],
             finish_reason: :tool_calls
           }}

        tool_result ->
          if pid = Process.whereis(:pixir_virtual_overlay_manager_capture) do
            send(pid, {:virtual_child_tool_result, tool_result.data})
          end

          {:ok,
           %{
             text: "virtual artifact ready",
             reasoning: "",
             reasoning_items: [],
             function_calls: [],
             finish_reason: :stop
           }}
      end
    end
  end

  defmodule NoVirtualCommandProvider do
    def stream(_request, _opts) do
      {:ok,
       %{
         text: "finished without artifact",
         reasoning: "",
         reasoning_items: [],
         function_calls: [],
         finish_reason: :stop
       }}
    end
  end

  defmodule OversizeVirtualCommandProvider do
    def stream(%{history: history}, _opts) do
      if Enum.any?(history, &(&1.type == :tool_result)) do
        {:ok,
         %{
           text: "oversize artifact produced",
           reasoning: "",
           reasoning_items: [],
           function_calls: [],
           finish_reason: :stop
         }}
      else
        {:ok,
         %{
           text: "",
           reasoning: "",
           reasoning_items: [],
           function_calls: [
             %{
               call_id: "oversize_virtual_child_command",
               name: "run_virtual_commands",
               args: %{"commands" => ["cp large.txt large-copy.txt"]}
             }
           ],
           finish_reason: :tool_calls
         }}
      end
    end
  end

  defmodule VirtualRetryProvider do
    @state __MODULE__.State

    def start do
      if pid = Process.whereis(@state), do: Agent.stop(pid)
      Agent.start_link(fn -> :fail_first_request end, name: @state)
    end

    def stop do
      if pid = Process.whereis(@state) do
        try do
          Agent.stop(pid)
        catch
          :exit, _ -> :ok
        end
      end

      :ok
    end

    def stream(%{history: history}, _opts) do
      fail? =
        Agent.get_and_update(@state, fn
          :fail_first_request -> {true, :continue}
          :continue -> {false, :continue}
        end)

      cond do
        fail? ->
          websocket_failure()

        Enum.any?(history, &(&1.type == :tool_result)) ->
          {:ok,
           %{
             text: "retry artifact ready",
             reasoning: "",
             function_calls: [],
             finish_reason: :stop
           }}

        true ->
          {:ok,
           %{
             text: "",
             reasoning: "",
             function_calls: [
               %{
                 call_id: "virtual_retry_command",
                 name: "run_virtual_commands",
                 args: %{"commands" => ["cp source.txt retry.txt"]}
               }
             ],
             finish_reason: :tool_calls
           }}
      end
    end

    def websocket_failure do
      {:error,
       %{
         ok: false,
         error: %{
           kind: :websocket_read_failed,
           message: "scripted virtual provider failure",
           details: %{reason: :scripted}
         }
       }}
    end
  end

  defmodule VirtualArtifactThenFailureProvider do
    def stream(%{history: history}, _opts) do
      if Enum.any?(history, &(&1.type == :tool_result)) do
        Pixir.Subagents.ManagerTest.VirtualRetryProvider.websocket_failure()
      else
        {:ok,
         %{
           text: "",
           reasoning: "",
           function_calls: [
             %{
               call_id: "virtual_before_failure",
               name: "run_virtual_commands",
               args: %{"commands" => ["cp source.txt preserved.txt"]}
             }
           ],
           finish_reason: :tool_calls
         }}
      end
    end
  end

  defmodule BlockingProvider do
    def stream(_request, _opts) do
      Process.sleep(10_000)
      {:ok, %{text: "late", reasoning: "", function_calls: [], finish_reason: :stop}}
    end
  end

  setup do
    workspace =
      Path.join(
        System.tmp_dir!(),
        "pixir-subagent-virtual-overlay-" <>
          Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
      )

    File.mkdir_p!(workspace)
    File.write!(Path.join(workspace, "source.txt"), "parent source\n")

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

    %{session_id: session_id, workspace: workspace}
  end

  describe "virtual_overlay retry evidence gate" do
    test "retries a transport failure before durable model or virtual tool evidence", %{
      session_id: session_id,
      workspace: workspace
    } do
      assert {:ok, _pid} = VirtualRetryProvider.start()
      on_exit(&VirtualRetryProvider.stop/0)

      assert {:ok, agent} =
               Subagents.spawn_agent(
                 session_id,
                 %{
                   "task" => "retry before virtual evidence",
                   "workspace_mode" => "virtual_overlay",
                   "retry_attempts" => 1,
                   "retry_jitter_ms" => 0,
                   "timeout_ms" => 5_000
                 },
                 workspace: workspace,
                 provider: VirtualRetryProvider,
                 permission_mode: :read_only,
                 virtual_overlay: %{read_set: ["source.txt"], limits: %{}}
               )

      failed_child_session_id = agent["child_session_id"]

      assert {:ok, [completed]} =
               Subagents.wait(session_id, [agent["id"]], 10_000, workspace: workspace)

      assert completed["status"] == "completed"
      assert completed["child_session_id"] != failed_child_session_id
      assert completed["retry_attempts"] == 1
      assert completed["retry_max_attempts"] == 1
      assert completed["current_attempt_index"] == 1

      assert [
               %{
                 "attempt_index" => 0,
                 "failed_child_session_id" => ^failed_child_session_id,
                 "error_kind" => error_kind
               }
             ] = completed["retry_history"]

      assert error_kind in [:websocket_read_failed, "websocket_read_failed"]
      assert completed["virtual_diff"]["kind"] == "virtual_diff"
    end

    test "does not retry after a virtual command result and preserves the failed artifact", %{
      session_id: session_id,
      workspace: workspace
    } do
      assert {:ok, agent} =
               Subagents.spawn_agent(
                 session_id,
                 %{
                   "task" => "preserve virtual evidence after transport failure",
                   "workspace_mode" => "virtual_overlay",
                   "retry_attempts" => 1,
                   "retry_jitter_ms" => 0,
                   "timeout_ms" => 5_000
                 },
                 workspace: workspace,
                 provider: VirtualArtifactThenFailureProvider,
                 permission_mode: :read_only,
                 virtual_overlay: %{read_set: ["source.txt"], limits: %{}}
               )

      assert {:ok, [failed]} =
               Subagents.wait(session_id, [agent["id"]], 10_000, workspace: workspace)

      assert failed["status"] == "failed"
      assert failed["child_session_id"] == agent["child_session_id"]
      refute Map.has_key?(failed, "retry_history")
      assert failed["virtual_diff"]["kind"] == "virtual_diff"
      assert failed["virtual_diff_ref"]["source_seq"] > 0
      assert get_in(failed, ["virtual_diff", "apply", "status"]) == "not_applied"
    end
  end

  describe "virtual_overlay retry blockers (ADR 0036, fail-closed pins)" do
    defp blocker_agent(child_sid, child_workspace) do
      %{child_session_id: child_sid, child_workspace: child_workspace}
    end

    defp fresh_child_log(workspace, event_builders) do
      child_sid = "blocker-#{System.unique_integer([:positive])}"

      Enum.with_index(event_builders)
      |> Enum.each(fn {build, seq} ->
        assert {:ok, _} =
                 Log.append(Event.with_seq(build.(child_sid), seq), workspace: workspace)
      end)

      child_sid
    end

    test "each durable-evidence blocker denies retry", %{workspace: workspace} do
      blockers = [
        {"assistant_message", [&Event.assistant_message(&1, "partial answer")]},
        {"provider_usage", [&Event.provider_usage(&1, %{"input_tokens" => 1})]},
        {"permission_decision",
         [&Event.permission_decision(&1, "call_1", :deny, details: %{"gate" => "x"})]},
        {"run_virtual_commands call without result",
         [&Event.tool_call(&1, "call_1", "run_virtual_commands", %{"commands" => ["true"]})]},
        {"run_virtual_commands call with result",
         [
           &Event.tool_call(&1, "call_1", "run_virtual_commands", %{"commands" => ["true"]}),
           &Event.tool_result(&1, "call_1", %{"ok" => true, "virtual_diff" => %{}})
         ]}
      ]

      for {label, builders} <- blockers do
        child_sid = fresh_child_log(workspace, builders)

        refute Manager.virtual_retry_log_safe?(blocker_agent(child_sid, workspace)),
               "expected #{label} to block the retry"
      end
    end

    test "benign evidence alone stays retry-eligible", %{workspace: workspace} do
      child_sid = fresh_child_log(workspace, [&Event.user_message(&1, "task text")])
      assert Manager.virtual_retry_log_safe?(blocker_agent(child_sid, workspace))
    end

    test "a missing child Log fails closed", %{workspace: workspace} do
      refute Manager.virtual_retry_log_safe?(blocker_agent("never-existed", workspace))
      refute Manager.virtual_retry_log_safe?(blocker_agent(nil, workspace))
      refute Manager.virtual_retry_log_safe?(blocker_agent("x", nil))
    end

    test "a malformed raw NDJSON child Log fails closed", %{workspace: workspace} do
      child_sid = "malformed-#{System.unique_integer([:positive])}"
      path = Log.path(child_sid, workspace: workspace)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "{this is not json\n")

      refute Manager.virtual_retry_log_safe?(blocker_agent(child_sid, workspace))
    end
  end

  describe "virtual_overlay runtime core" do
    test "passes operator context to Turn without creating a physical snapshot", %{
      session_id: session_id,
      workspace: workspace
    } do
      Process.register(self(), :pixir_virtual_overlay_manager_capture)

      assert {:ok, agent} =
               Subagents.spawn_agent(
                 session_id,
                 %{
                   "task" => "produce a virtual diff",
                   "workspace_mode" => "virtual_overlay",
                   "timeout_ms" => 5_000
                 },
                 workspace: workspace,
                 provider: VirtualCommandProvider,
                 permission_mode: :read_only,
                 virtual_overlay: %{
                   read_set: ["source.txt"],
                   limits: %{"max_virtual_commands" => 5}
                 }
               )

      assert agent["workspace_mode"] == "virtual_overlay"
      assert agent["workspace"] == workspace
      refute Map.has_key?(agent, "workspace_snapshot")

      snapshot_root = Path.join([workspace, ".pixir", "subagents", agent["id"]])
      refute File.exists?(snapshot_root)

      assert {:ok, [completed]} =
               Subagents.wait(session_id, [agent["id"]], 10_000, workspace: workspace)

      assert completed["status"] == "completed"
      assert completed["virtual_diff"]["kind"] == "virtual_diff"
      assert completed["virtual_diff_ref"]["kind"] == "virtual_diff"
      assert completed["virtual_diff_ref"]["encoded_bytes"] > 0

      assert_receive {:virtual_child_tool_result,
                      %{
                        "ok" => true,
                        "virtual_diff" => %{
                          "apply" => %{"status" => "not_applied"},
                          "changes" => changes
                        }
                      }},
                     1_000

      assert [%{"operation" => "add", "path" => "out/from-child.txt"}] = changes
      refute File.exists?(Path.join(workspace, "out/from-child.txt"))
      refute File.exists?(snapshot_root)

      assert {:ok, history} = Log.fold(session_id, workspace: workspace)

      assert [started] =
               Enum.filter(
                 history,
                 &(&1.type == :subagent_event and &1.data["subagent_id"] == agent["id"] and
                     &1.data["event"] == "started")
               )

      assert started.data["workspace_mode"] == "virtual_overlay"

      assert get_in(started.data, ["delegation_context", "workspace_fidelity"]) ==
               "virtual_shell_no_host_binaries"

      assert get_in(started.data, ["delegation_context", "read_boundary"]) ==
               "imported_read_set_only"

      assert [finished] =
               Enum.filter(history, fn event ->
                 event.type == :subagent_event and
                   event.data["subagent_id"] == agent["id"] and
                   event.data["event"] == "finished"
               end)

      assert finished.data["virtual_diff_ref"]["sha256"] ==
               completed["virtual_diff_ref"]["sha256"]

      assert finished.data["virtual_diff_ref"]["source_seq"] > 0
      refute Map.has_key?(finished.data, "virtual_diff")
    end

    test "virtual child done without an artifact fails honestly", %{
      session_id: session_id,
      workspace: workspace
    } do
      assert {:ok, agent} =
               Subagents.spawn_agent(
                 session_id,
                 %{
                   "task" => "finish without a virtual command",
                   "workspace_mode" => "virtual_overlay",
                   "timeout_ms" => 5_000
                 },
                 workspace: workspace,
                 provider: NoVirtualCommandProvider,
                 permission_mode: :read_only,
                 virtual_overlay: %{read_set: ["source.txt"], limits: %{}}
               )

      assert {:ok, [failed]} =
               Subagents.wait(session_id, [agent["id"]], 10_000, workspace: workspace)

      assert failed["status"] == "failed"
      assert failed["reason"] == "virtual_diff_missing"
      refute Map.has_key?(failed, "virtual_diff")
      refute Map.has_key?(failed, "virtual_diff_ref")
    end

    test "oversize virtual artifact fails with a bounded reference", %{
      session_id: session_id,
      workspace: workspace
    } do
      File.write!(Path.join(workspace, "large.txt"), String.duplicate("a", 263_000) <> "\n")

      assert {:ok, agent} =
               Subagents.spawn_agent(
                 session_id,
                 %{
                   "task" => "produce an oversize virtual diff",
                   "workspace_mode" => "virtual_overlay",
                   "timeout_ms" => 10_000
                 },
                 workspace: workspace,
                 provider: OversizeVirtualCommandProvider,
                 permission_mode: :read_only,
                 virtual_overlay: %{
                   read_set: ["large.txt"],
                   limits: %{
                     "max_import_bytes" => 400_000,
                     "max_file_bytes" => 400_000,
                     "max_diff_bytes" => 400_000
                   }
                 }
               )

      assert {:ok, [failed]} =
               Subagents.wait(session_id, [agent["id"]], 15_000, workspace: workspace)

      assert failed["status"] == "failed"
      assert failed["reason"] == "virtual_diff_oversize"
      assert failed["virtual_diff_ref"]["encoded_bytes"] > 262_144
      refute Map.has_key?(failed, "virtual_diff")

      assert {:ok, history} = Log.fold(session_id, workspace: workspace)

      assert terminal =
               Enum.find(history, fn event ->
                 event.type == :subagent_event and
                   event.data["subagent_id"] == agent["id"] and
                   event.data["event"] == "failed"
               end)

      assert terminal.data["reason"] == "virtual_diff_oversize"
      assert terminal.data["virtual_diff_ref"]["encoded_bytes"] > 262_144
      refute Map.has_key?(terminal.data, "virtual_diff")
    end

    test "rejects virtual mode without operator config", %{
      session_id: session_id,
      workspace: workspace
    } do
      assert {:error, %{error: %{kind: :invalid_args, details: details}}} =
               Subagents.spawn_agent(
                 session_id,
                 %{"task" => "missing config", "workspace_mode" => "virtual_overlay"},
                 workspace: workspace,
                 provider: BlockingProvider,
                 permission_mode: :read_only
               )

      assert details["workspace_mode"] == "virtual_overlay"
      assert details["supported_modes"] == ["shared", "isolated"]
      refute File.exists?(Path.join([workspace, ".pixir", "subagents"]))
    end

    test "rejects a write-capable virtual child before workspace preparation", %{
      session_id: session_id,
      workspace: workspace
    } do
      assert {:error, %{error: %{kind: :permission_denied}}} =
               Subagents.spawn_agent(
                 session_id,
                 %{"task" => "write-capable", "workspace_mode" => "virtual_overlay"},
                 workspace: workspace,
                 provider: BlockingProvider,
                 permission_mode: :auto,
                 virtual_overlay: %{read_set: ["source.txt"], limits: nil}
               )

      refute File.exists?(Path.join([workspace, ".pixir", "subagents"]))
    end
  end
end
