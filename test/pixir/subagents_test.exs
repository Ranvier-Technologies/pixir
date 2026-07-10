defmodule Pixir.SubagentsTest do
  use ExUnit.Case, async: false

  alias Pixir.{Auth, Event, Log, Session, SessionSupervisor, Subagents}
  alias Pixir.Permissions.WritePolicy
  alias Pixir.Subagents.DelegationContext
  alias Pixir.Subagents.WorkspaceSnapshot
  alias Pixir.Tools.{SpawnAgent, WaitAgent}

  defmodule NoOAuth do
    def refresh_skew_ms, do: 60_000
  end

  defmodule WritingProvider do
    def stream(%{history: history}, opts) do
      on_delta = Keyword.get(opts, :on_delta, fn _ -> :ok end)

      if Enum.any?(history, &(&1.type == :tool_result)) do
        on_delta.({:text_delta, "done"})

        {:ok,
         %{
           text: "wrote isolated result",
           reasoning: "",
           function_calls: [],
           finish_reason: :stop
         }}
      else
        prompt =
          history
          |> Enum.find(&(&1.type == :user_message))
          |> then(&((&1 && &1.data["text"]) || ""))

        {:ok,
         %{
           text: "",
           reasoning: "",
           reasoning_items: [],
           function_calls: [
             %{
               call_id: "write_once",
               name: "write",
               args: %{"path" => "result.txt", "content" => prompt}
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

  defmodule FailingAfterToolProvider do
    def stream(%{history: history}, _opts) do
      if Enum.any?(history, &(&1.type == :tool_result)) do
        {:error,
         %{
           ok: false,
           error: %{
             kind: :network,
             message: "provider stream exited during subagent",
             details: %{transport: "test"}
           }
         }}
      else
        {:ok,
         %{
           text: "",
           reasoning: "",
           reasoning_items: [],
           function_calls: [
             %{
               call_id: "write_before_failure",
               name: "write",
               args: %{"path" => "before-failure.txt", "content" => "started"}
             }
           ],
           finish_reason: :tool_calls
         }}
      end
    end
  end

  defmodule PartialThenErrorProvider do
    def stream(_request, opts) do
      on_delta = Keyword.get(opts, :on_delta, fn _ -> :ok end)
      on_delta.({:text_delta, "useful partial evidence"})

      {:error,
       %{
         ok: false,
         error: %{
           kind: :network,
           message: "provider stream exited after partial text",
           details: %{transport: "test"}
         }
       }}
    end
  end

  defmodule KnobCaptureProvider do
    def stream(request, opts) do
      if pid = Process.whereis(:pixir_knob_capture) do
        send(
          pid,
          {:provider_knobs, request[:model] || Keyword.get(opts, :model),
           request[:reasoning_effort] || Keyword.get(opts, :reasoning_effort),
           request[:web_search] || Keyword.get(opts, :web_search)}
        )
      end

      {:ok, %{text: "done", reasoning: "", function_calls: [], finish_reason: :stop}}
    end
  end

  defmodule ScriptedRetryProvider do
    def stream(_request, _opts) do
      outcome =
        Agent.get_and_update(:pixir_subagent_retry_script, fn [next | rest] -> {next, rest} end)

      case outcome do
        :retryable_true ->
          {:error,
           %{
             ok: false,
             error: %{
               kind: :provider_http_error,
               message: "overloaded",
               details: %{retryable: true, type: "service_unavailable_error"}
             }
           }}

        :legacy_server_error ->
          {:error,
           %{
             ok: false,
             error: %{
               kind: :provider_http_error,
               message: "server error",
               details: %{type: "server_error"}
             }
           }}

        :non_retryable ->
          {:error,
           %{
             ok: false,
             error: %{
               kind: :provider_http_error,
               message: "not retryable",
               details: %{type: "service_unavailable_error"}
             }
           }}

        :ok ->
          {:ok, %{text: "retried", reasoning: "", function_calls: [], finish_reason: :stop}}
      end
    end
  end

  setup do
    ws =
      Path.join(
        System.tmp_dir!(),
        "pixir-subagents-" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
      )

    File.mkdir_p!(ws)
    File.write!(Path.join(ws, "source.txt"), "parent source")
    {:ok, sid, pid} = SessionSupervisor.start_session(workspace: ws, role: :build)

    on_exit(fn ->
      if script_pid = Process.whereis(:pixir_subagent_retry_script) do
        Agent.stop(script_pid)
      end

      try do
        if Process.alive?(pid), do: DynamicSupervisor.terminate_child(SessionSupervisor, pid)
      catch
        :exit, _ -> :ok
      end

      File.rm_rf(ws)
    end)

    %{ws: ws, sid: sid}
  end

  test "delegate auto-retry accepts provider_http_error retryable details flag", %{
    sid: sid,
    ws: ws
  } do
    {:ok, _script} =
      Agent.start_link(fn -> [:retryable_true, :ok] end, name: :pixir_subagent_retry_script)

    {:ok, agent} =
      Subagents.spawn_agent(
        sid,
        %{
          "task" => "retry flagged provider error",
          "retry_attempts" => 1,
          "retry_jitter_ms" => 0
        },
        workspace: ws,
        provider: ScriptedRetryProvider,
        permission_mode: :read_only
      )

    assert {:ok, [completed]} = Subagents.wait(sid, [agent["id"]], 10_000, workspace: ws)
    assert completed["status"] == "completed"
    assert Agent.get(:pixir_subagent_retry_script, & &1) == []
  end

  test "delegate auto-retry keeps legacy server_error eligibility", %{sid: sid, ws: ws} do
    {:ok, _script} =
      Agent.start_link(fn -> [:legacy_server_error, :ok] end, name: :pixir_subagent_retry_script)

    {:ok, agent} =
      Subagents.spawn_agent(
        sid,
        %{"task" => "retry legacy provider error", "retry_attempts" => 1, "retry_jitter_ms" => 0},
        workspace: ws,
        provider: ScriptedRetryProvider,
        permission_mode: :read_only
      )

    assert {:ok, [completed]} = Subagents.wait(sid, [agent["id"]], 10_000, workspace: ws)
    assert completed["status"] == "completed"
    assert Agent.get(:pixir_subagent_retry_script, & &1) == []
  end

  test "delegate auto-retry rejects provider_http_error without retryable or legacy type", %{
    sid: sid,
    ws: ws
  } do
    {:ok, _script} =
      Agent.start_link(fn -> [:non_retryable, :ok] end, name: :pixir_subagent_retry_script)

    {:ok, agent} =
      Subagents.spawn_agent(
        sid,
        %{"task" => "do not retry provider error", "retry_attempts" => 1, "retry_jitter_ms" => 0},
        workspace: ws,
        provider: ScriptedRetryProvider,
        permission_mode: :read_only
      )

    assert {:ok, [failed]} = Subagents.wait(sid, [agent["id"]], 10_000, workspace: ws)
    assert failed["status"] == "failed"
    assert Agent.get(:pixir_subagent_retry_script, & &1) == [:ok]
  end

  test "spawned Subagents expose and durably record task indexes", %{sid: sid, ws: ws} do
    {:ok, agent} =
      Subagents.spawn_agent(
        sid,
        %{"task" => "indexed task", "agent" => "worker", "timeout_ms" => 5_000},
        workspace: ws,
        provider: WritingProvider,
        permission_mode: :auto,
        index: 3
      )

    assert agent["index"] == 3
    assert {:ok, [completed]} = Subagents.wait(sid, [agent["id"]], 10_000, workspace: ws)
    assert completed["index"] == 3

    assert {:ok, history} = Log.fold(sid, workspace: ws)

    events =
      Enum.filter(
        history,
        &(&1.type == :subagent_event and &1.data["subagent_id"] == agent["id"])
      )

    assert events != []
    assert Enum.all?(events, &(&1.data["index"] == 3))
    assert Subagents.reconstruct(history)[agent["id"]]["index"] == 3
  end

  test "spawn_agent validates opts indexes and ignores caller-authored indexes", %{
    sid: sid,
    ws: ws
  } do
    assert {:error, %{error: %{kind: :invalid_args, details: details}}} =
             Subagents.spawn_agent(
               sid,
               %{"task" => "bad opts index"},
               workspace: ws,
               provider: BlockingProvider,
               permission_mode: :read_only,
               index: -1
             )

    assert details["field"] == "index"

    assert {:ok, forged} =
             Subagents.spawn_agent(
               sid,
               %{"task" => "forged index ignored", "index" => 9},
               workspace: ws,
               provider: WritingProvider,
               permission_mode: :auto
             )

    refute Map.has_key?(forged, "index")
    assert {:ok, [completed]} = Subagents.wait(sid, [forged["id"]], 10_000, workspace: ws)
    refute Map.has_key?(completed, "index")

    assert {:ok, history} = Log.fold(sid, workspace: ws)

    forged_events =
      Enum.filter(
        history,
        &(&1.type == :subagent_event and &1.data["subagent_id"] == forged["id"])
      )

    assert forged_events != []
    refute Enum.any?(forged_events, &Map.has_key?(&1.data, "index"))

    assert {:ok, with_opts} =
             Subagents.spawn_agent(
               sid,
               %{"task" => "opts index wins", "index" => 9},
               workspace: ws,
               provider: WritingProvider,
               permission_mode: :auto,
               index: 4
             )

    assert with_opts["index"] == 4

    assert {:ok, [_completed_with_opts]} =
             Subagents.wait(sid, [with_opts["id"]], 10_000, workspace: ws)
  end

  test "spawn_agent rejects non-string model knobs", %{sid: sid, ws: ws} do
    assert {:error, %{error: %{kind: :invalid_args, details: details}}} =
             Subagents.spawn_agent(
               sid,
               %{"task" => "bad model", "model" => 123},
               workspace: ws,
               provider: BlockingProvider,
               permission_mode: :read_only
             )

    assert details["field"] == "model"
  end

  test "spawn_agent rejects unsupported reasoning_effort knobs", %{sid: sid, ws: ws} do
    assert {:error, %{error: %{kind: :invalid_args, details: details}}} =
             Subagents.spawn_agent(
               sid,
               %{"task" => "bad effort", "reasoning_effort" => "ultra"},
               workspace: ws,
               provider: BlockingProvider,
               permission_mode: :read_only
             )

    assert details["field"] == "reasoning_effort"
    assert details["accepted_values"] == ["low", "medium", "high", "xhigh"]
  end

  test "spawn_agent tool strips caller-authored index before spawning", %{sid: sid, ws: ws} do
    context = %{
      session_id: sid,
      workspace: ws,
      provider: WritingProvider,
      permission: %{mode: :auto}
    }

    assert {:ok, %{"subagent" => agent}} =
             SpawnAgent.execute(%{"task" => "smuggled index", "index" => 9}, context)

    refute Map.has_key?(agent, "index")

    assert {:ok, [completed]} = Subagents.wait(sid, [agent["id"]], 10_000, workspace: ws)
    refute Map.has_key?(completed, "index")

    assert {:ok, history} = Log.fold(sid, workspace: ws)

    events =
      Enum.filter(
        history,
        &(&1.type == :subagent_event and &1.data["subagent_id"] == agent["id"])
      )

    assert events != []
    refute Enum.any?(events, &Map.has_key?(&1.data, "index"))
  end

  test "spawn_agent ignores caller-authored ids in args and durable evidence", %{sid: sid, ws: ws} do
    forged_id = "subagent_forged_identity"

    assert {:ok, agent} =
             Subagents.spawn_agent(
               sid,
               %{"task" => "forged id ignored", "id" => forged_id, "timeout_ms" => 5_000},
               workspace: ws,
               provider: WritingProvider,
               permission_mode: :auto
             )

    refute agent["id"] == forged_id
    assert agent["id"] =~ ~r/\Asub_[0-9a-f]{10}\z/
    assert {:ok, [_completed]} = Subagents.wait(sid, [agent["id"]], 10_000, workspace: ws)

    assert {:ok, history} = Log.fold(sid, workspace: ws)

    events = Enum.filter(history, &(&1.type == :subagent_event))
    assert events != []
    refute Enum.any?(events, &(&1.data["subagent_id"] == forged_id))
  end

  test "spawn_agent tool strips caller-authored id before spawning", %{sid: sid, ws: ws} do
    context = %{
      session_id: sid,
      workspace: ws,
      provider: WritingProvider,
      permission: %{mode: :auto}
    }

    forged_id = "subagent_tool_forgery"

    assert {:ok, %{"subagent" => agent}} =
             SpawnAgent.execute(%{"task" => "smuggled id", "id" => forged_id}, context)

    refute agent["id"] == forged_id
    assert agent["id"] =~ ~r/\Asub_[0-9a-f]{10}\z/
    assert {:ok, [_completed]} = Subagents.wait(sid, [agent["id"]], 10_000, workspace: ws)
  end

  test "spawn args thread model and reasoning_effort to the child provider", %{sid: sid, ws: ws} do
    Process.register(self(), :pixir_knob_capture)

    {:ok, agent} =
      Subagents.spawn_agent(
        sid,
        %{
          "task" => "capture knobs",
          "model" => "gpt-5.5-test",
          "reasoning_effort" => "xhigh",
          "timeout_ms" => 5_000
        },
        workspace: ws,
        provider: KnobCaptureProvider,
        permission_mode: :auto
      )

    assert {:ok, [_completed]} = Subagents.wait(sid, [agent["id"]], 10_000, workspace: ws)
    assert_received {:provider_knobs, "gpt-5.5-test", "xhigh", _web_search}

    assert {:ok, history} = Log.fold(sid, workspace: ws)

    events =
      Enum.filter(
        history,
        &(&1.type == :subagent_event and &1.data["subagent_id"] == agent["id"])
      )

    assert events != []
    assert Enum.all?(events, &(&1.data["model"] == "gpt-5.5-test"))
    assert Enum.all?(events, &(&1.data["reasoning_effort"] == "xhigh"))

    # Evidence, not echo: the knobs live in the durable Log for replay, but
    # public reconstruction does not surface them as envelope fields.
    reconstructed = Subagents.reconstruct(history)[agent["id"]]
    refute Map.has_key?(reconstructed, "model")
    refute Map.has_key?(reconstructed, "reasoning_effort")
  end

  test "spawn args thread web_search to the child provider", %{sid: sid, ws: ws} do
    Process.register(self(), :pixir_knob_capture)

    {:ok, agent} =
      Subagents.spawn_agent(
        sid,
        %{
          "task" => "capture web search",
          "web_search" => true,
          "timeout_ms" => 5_000
        },
        workspace: ws,
        provider: KnobCaptureProvider,
        permission_mode: :auto
      )

    assert {:ok, [_completed]} = Subagents.wait(sid, [agent["id"]], 10_000, workspace: ws)
    assert_received {:provider_knobs, _model, _effort, %{"enabled" => true}}
  end

  test "explicit web_search false in args beats an inherited opts default", %{sid: sid, ws: ws} do
    Process.register(self(), :pixir_knob_capture)

    {:ok, agent} =
      Subagents.spawn_agent(
        sid,
        %{
          "task" => "opt this child out",
          "web_search" => false,
          "timeout_ms" => 5_000
        },
        workspace: ws,
        provider: KnobCaptureProvider,
        web_search: %{"enabled" => true},
        permission_mode: :auto
      )

    assert {:ok, [_completed]} = Subagents.wait(sid, [agent["id"]], 10_000, workspace: ws)
    assert_received {:provider_knobs, _model, _effort, web_search}
    assert web_search == nil
  end

  test "spawn_agent tool strips caller-authored provider knobs", %{sid: sid, ws: ws} do
    Process.register(self(), :pixir_knob_capture)

    context = %{
      session_id: sid,
      workspace: ws,
      provider: KnobCaptureProvider,
      permission: %{mode: :auto}
    }

    assert {:ok, %{"subagent" => agent}} =
             SpawnAgent.execute(
               %{
                 "task" => "smuggled knobs",
                 "model" => "gpt-omega",
                 "reasoning_effort" => "xhigh"
               },
               context
             )

    assert {:ok, [_completed]} = Subagents.wait(sid, [agent["id"]], 10_000, workspace: ws)
    assert_received {:provider_knobs, model, effort, _web_search}
    refute model == "gpt-omega"
    refute effort == "xhigh"
  end

  test "spawn_agent operator attachments ingest into the child log", %{sid: sid, ws: ws} do
    path = Path.join(ws, "attached.txt")
    File.write!(path, "operator evidence")
    uri = "file://" <> URI.encode(path, &(&1 == ?/ or URI.char_unreserved?(&1)))

    {:ok, agent} =
      Subagents.spawn_agent(
        sid,
        %{
          "task" => "read attached evidence",
          "workspace_mode" => "shared",
          "attachments" => [%{"type" => "resource_link", "uri" => uri, "name" => "attached.txt"}],
          "timeout_ms" => 5_000
        },
        workspace: ws,
        provider: WritingProvider,
        permission_mode: :auto
      )

    assert {:ok, [_completed]} = Subagents.wait(sid, [agent["id"]], 10_000, workspace: ws)
    assert {:ok, history} = Log.fold(agent["child_session_id"], workspace: ws)

    assert Enum.any?(history, fn
             %{type: :user_message, data: %{"resources" => [%{"name" => "attached.txt"} | _]}} ->
               true

             _event ->
               false
           end)
  end

  test "send_input restarts do not re-ingest operator attachments", %{sid: sid, ws: ws} do
    path = Path.join(ws, "once.txt")
    File.write!(path, "ingest once")
    uri = "file://" <> URI.encode(path, &(&1 == ?/ or URI.char_unreserved?(&1)))

    {:ok, agent} =
      Subagents.spawn_agent(
        sid,
        %{
          "task" => "first turn",
          "workspace_mode" => "shared",
          "attachments" => [%{"type" => "resource_link", "uri" => uri, "name" => "once.txt"}],
          "timeout_ms" => 5_000
        },
        workspace: ws,
        provider: WritingProvider,
        permission_mode: :auto
      )

    assert {:ok, [_completed]} = Subagents.wait(sid, [agent["id"]], 10_000, workspace: ws)

    assert {:ok, _restarted} =
             Subagents.send_input(sid, agent["id"], "steered turn", workspace: ws)

    assert {:ok, [_completed_again]} = Subagents.wait(sid, [agent["id"]], 10_000, workspace: ws)
    assert {:ok, history} = Log.fold(agent["child_session_id"], workspace: ws)

    with_resources =
      Enum.filter(history, &(&1.type == :user_message and Map.has_key?(&1.data, "resources")))

    # Only the first Turn ingests; the steered turn must not duplicate payloads.
    assert length(with_resources) == 1
    assert hd(with_resources).data["text"] == "first turn"
  end

  test "spawn_agent tool strips caller-authored attachments", %{sid: sid, ws: ws} do
    context = %{
      session_id: sid,
      workspace: ws,
      provider: WritingProvider,
      permission: %{mode: :auto}
    }

    assert {:ok, %{"subagent" => agent}} =
             SpawnAgent.execute(
               %{
                 "task" => "smuggled attachments",
                 # Shared workspace so the child Log is foldable from `ws` below.
                 "workspace_mode" => "shared",
                 "attachments" => [
                   %{"type" => "resource_link", "uri" => "file:///tmp/not-operator-approved.txt"}
                 ]
               },
               context
             )

    assert {:ok, [_completed]} = Subagents.wait(sid, [agent["id"]], 10_000, workspace: ws)
    assert {:ok, history} = Log.fold(agent["child_session_id"], workspace: ws)

    user_messages = Enum.filter(history, &(&1.type == :user_message))
    assert user_messages != []
    refute Enum.any?(user_messages, &Map.has_key?(&1.data, "resources"))
  end

  test "documents the Subagent lifecycle transition contract" do
    assert Subagents.statuses() ==
             ~w(queued running completed failed timed_out cancelled detached closed)

    assert Subagents.terminal_statuses() ==
             ~w(completed failed cancelled timed_out closed detached)

    assert Subagents.transition_allowed?("queued", "running")
    assert Subagents.transition_allowed?("queued", "failed")
    assert Subagents.transition_allowed?("running", "completed")
    assert Subagents.transition_allowed?("running", "failed")
    assert Subagents.transition_allowed?("running", "timed_out")
    assert Subagents.transition_allowed?("running", "cancelled")
    assert Subagents.transition_allowed?("running", "detached")
    refute Subagents.transition_allowed?("running", "closed")

    for restartable <- ~w(completed failed timed_out cancelled) do
      assert Subagents.transition_allowed?(restartable, "running")
      assert Subagents.transition_allowed?(restartable, "closed")
    end

    refute Subagents.transition_allowed?("queued", "completed")
    refute Subagents.transition_allowed?("detached", "running")
    refute Subagents.transition_allowed?("closed", "running")
    refute Subagents.transition_allowed?("unknown", "running")
    refute Subagents.transition_allowed?(nil, "running")
  end

  test "diagnostics returns a structured error when the manager is unavailable", %{sid: sid} do
    if Process.whereis(Pixir.Subagents.Manager) do
      :ok = Supervisor.terminate_child(Pixir.Supervisor, Pixir.Subagents.Manager)
    end

    try do
      assert {:error, %{error: %{kind: :read_failed, details: details}}} =
               Subagents.diagnostics(sid)

      assert details["parent_session_id"] == sid
      assert "start_or_restart_pixir" in details["next_actions"]
    after
      ensure_subagents_manager_started()
    end
  end

  test "Delegation Context keeps base fields authoritative" do
    merged =
      DelegationContext.merge_metadata(
        %{
          "subagent_id" => "base_subagent",
          "child_session_id" => "base_child",
          "deadline_at" => "base_deadline",
          "permission_mode" => "read_only"
        },
        %{
          subagent_id: "metadata_subagent",
          child_session_id: "metadata_child",
          deadline_at: nil,
          permission_mode: "auto",
          workflow_id: "wf_1"
        }
      )

    assert merged["subagent_id"] == "base_subagent"
    assert merged["child_session_id"] == "base_child"
    assert merged["deadline_at"] == "base_deadline"
    assert merged["permission_mode"] == "read_only"
    assert merged["workflow_id"] == "wf_1"
  end

  test "Delegation Context describes shared workspace fidelity" do
    context =
      DelegationContext.from_agent(%{
        id: "shared_agent",
        permission_mode: :read_only,
        workspace_mode: "shared",
        delegation_context: %{
          workspace_fidelity: "metadata_must_not_override_generated_context"
        }
      })

    assert context["workspace_mode"] == "shared"
    assert context["workspace_fidelity"] == "real_parent_workspace"
    assert context["read_boundary"] == "parent_workspace"
    assert context["write_semantics"] == "parent_workspace_subject_to_permission_mode"
    assert context["parent_workspace_mutation"] == "possible_with_write_permissions"
    assert context["host_boundary_rule"] =~ "OS-boundary fanout carefully bounded"
  end

  test "Delegation Context describes isolated workspace fidelity" do
    context =
      DelegationContext.from_agent(%{
        id: "isolated_agent",
        permission_mode: :auto,
        workspace_mode: "isolated"
      })

    assert context["workspace_mode"] == "isolated"
    assert context["workspace_fidelity"] == "bounded_physical_snapshot"
    assert context["read_boundary"] == "snapshot_copy"
    assert context["write_semantics"] == "snapshot_only_parent_workspace_not_mutated"
    assert context["parent_workspace_mutation"] == "none"
  end

  test "Delegation Context can model future virtual_overlay fidelity without runtime exposure" do
    context =
      DelegationContext.from_agent(%{
        id: "virtual_agent",
        permission_mode: :read_only,
        workspace_mode: "virtual_overlay",
        delegation_context: %{
          read_set: ["lib/pixir/example.ex"],
          write_set: ["virtual.patch"],
          workspace_fidelity: "metadata_must_not_override_generated_context"
        }
      })

    assert context["workspace_mode"] == "virtual_overlay"
    assert context["workspace_fidelity"] == "virtual_shell_no_host_binaries"
    assert context["read_boundary"] == "imported_read_set_only"
    assert context["write_semantics"] == "virtual_only_parent_workspace_not_mutated"
    assert context["parent_workspace_mutation"] == "none"
    assert context["output_artifact"] == "virtual_diff"
    assert context["apply_status"] == "not_applied"
    assert context["requires_explicit_apply"] == true
    assert context["virtual_command_boundary"] == "beam_native_virtual_shell_only"
    assert context["read_set"] == ["lib/pixir/example.ex"]

    assert Enum.any?(
             context["fidelity_caveats"],
             &String.contains?(&1, "mix, git, node")
           )
  end

  test "spawns many child Sessions, collects summaries, and isolates writes", %{sid: sid, ws: ws} do
    agents =
      for i <- 1..50 do
        {:ok, agent} =
          Subagents.spawn_agent(
            sid,
            %{
              "task" => "task-#{i}",
              "agent" => "worker",
              "max_threads" => 8,
              "timeout_ms" => 5_000
            },
            workspace: ws,
            provider: WritingProvider,
            permission_mode: :auto
          )

        agent
      end

    assert length(agents) == 50
    assert {:ok, completed} = Subagents.wait(sid, Enum.map(agents, & &1["id"]), 10_000)
    assert Enum.all?(completed, &(&1["status"] == "completed"))
    refute File.exists?(Path.join(ws, "result.txt"))

    for agent <- completed do
      assert File.read!(Path.join(agent["workspace"], "result.txt")) =~ "task-"
    end

    assert {:ok, history} = Log.fold(sid, workspace: ws)

    assert Enum.count(history, &(&1.type == :subagent_event and &1.data["event"] == "finished")) ==
             50

    assert map_size(Subagents.reconstruct(history)) == 50

    restart_subagents_manager()

    assert {:ok, listed} = Subagents.list(sid, workspace: ws)
    assert length(listed) == 50
    assert Enum.all?(listed, &(&1["status"] == "completed"))

    assert {:ok, polled} = Subagents.wait(sid, Enum.map(agents, & &1["id"]), 0, workspace: ws)
    assert Enum.all?(polled, &(&1["status"] == "completed"))
  end

  test "a late timeout for an already-dead child does not crash the Manager", %{
    sid: sid,
    ws: ws
  } do
    {:ok, agent} =
      Subagents.spawn_agent(
        sid,
        %{"task" => "block", "timeout_ms" => 600_000},
        workspace: ws,
        provider: BlockingProvider,
        permission_mode: :auto
      )

    manager = Process.whereis(Pixir.Subagents.Manager)
    assert is_pid(manager)

    # Kill the child Session out from under the Manager, simulating a child
    # whose test/app tore down before its timeout fired (the CI race).
    [{child_pid, _}] = Registry.lookup(Pixir.Sessions.Registry, agent["child_session_id"])
    ref = Process.monitor(child_pid)
    Process.exit(child_pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^child_pid, :killed}

    # Fire the timeout by hand; before the guard this crashed the Manager with
    # a :noproc exit from Session.interrupt/1.
    send(manager, {:subagent_timeout, sid, agent["id"]})

    # The Manager must survive and record honest timeout evidence.
    assert {:ok, [outcome]} = Subagents.wait(sid, [agent["id"]], 0, workspace: ws)
    assert outcome["status"] == "timed_out"
    assert Process.alive?(manager)
    assert Process.whereis(Pixir.Subagents.Manager) == manager
  end

  test "isolated snapshots skip generated directories recursively and expose metadata", %{
    sid: sid,
    ws: ws
  } do
    File.mkdir_p!(Path.join([ws, "site", "node_modules", "pkg"]))
    File.write!(Path.join([ws, "site", "node_modules", "pkg", "ignored.js"]), "ignored")
    File.mkdir_p!(Path.join([ws, "site", "dist"]))
    File.write!(Path.join([ws, "site", "dist", "bundle.js"]), "bundle")
    File.mkdir_p!(Path.join([ws, "site", "src"]))
    File.write!(Path.join([ws, "site", "src", "app.js"]), "source")
    File.mkdir_p!(Path.join([ws, "app", ".cache"]))
    File.write!(Path.join([ws, "app", ".cache", "tmp"]), "cache")

    outside = Path.join(System.tmp_dir!(), "pixir-subagent-outside-#{System.unique_integer()}")
    File.write!(outside, "outside")
    on_exit(fn -> File.rm_rf(outside) end)

    link = Path.join(ws, "outside-link")
    symlink_created? = File.ln_s(outside, link) == :ok

    {:ok, agent} =
      Subagents.spawn_agent(
        sid,
        %{"task" => "block", "timeout_ms" => 5_000},
        workspace: ws,
        provider: BlockingProvider,
        permission_mode: :auto
      )

    child_ws = agent["workspace"]

    assert File.read!(Path.join([child_ws, "site", "src", "app.js"])) == "source"
    refute File.exists?(Path.join([child_ws, "site", "node_modules"]))
    refute File.exists?(Path.join([child_ws, "site", "dist"]))
    refute File.exists?(Path.join([child_ws, "app", ".cache"]))

    if symlink_created? do
      refute File.exists?(Path.join(child_ws, "outside-link"))
    end

    snapshot = agent["workspace_snapshot"]
    assert snapshot["snapshot_policy"] == "recursive_denylist_v1"
    assert snapshot["files_copied"] >= 2
    assert snapshot["dirs_skipped"] >= 4
    assert snapshot["bytes_copied"] >= byte_size("parent source") + byte_size("source")
    assert is_integer(snapshot["elapsed_ms"])
    assert snapshot["limits"]["max_files"] == 20_000
    assert snapshot["limits"]["max_bytes"] == 256 * 1024 * 1024
    assert snapshot["limits"]["max_file_bytes"] == 64 * 1024 * 1024
    assert snapshot["skipped_dirs_by_name"][".pixir"] >= 1
    assert snapshot["skipped_dirs_by_name"]["node_modules"] == 1
    assert snapshot["skipped_dirs_by_name"]["dist"] == 1
    assert snapshot["skipped_dirs_by_name"][".cache"] == 1

    if symlink_created? do
      assert snapshot["symlinks_skipped"] == 1
    end

    assert {:ok, history} = Log.fold(sid, workspace: ws)

    assert [started] =
             Enum.filter(
               history,
               &(&1.type == :subagent_event and &1.data["subagent_id"] == agent["id"] and
                   &1.data["event"] == "started")
             )

    assert started.data["workspace_snapshot"] == snapshot

    assert {:ok, cancelled} = Subagents.close(sid, agent["id"], workspace: ws)
    assert cancelled["status"] == "cancelled"
  end

  test "isolated snapshot limit violations return structured write errors", %{
    sid: sid,
    ws: ws
  } do
    assert {:error,
            %{
              error: %{
                kind: :write_failed,
                details: details
              }
            }} =
             Subagents.spawn_agent(
               sid,
               %{"task" => "too large", "timeout_ms" => 5_000},
               workspace: ws,
               provider: BlockingProvider,
               permission_mode: :auto,
               workspace_snapshot_opts: [limits: [max_file_bytes: 1]]
             )

    assert details["reason"] == "snapshot_max_file_bytes_exceeded"
    assert details["limit_name"] == "max_file_bytes"
    assert details["limit"] == 1
    assert details["observed"] > 1
    assert details["path"] == "source.txt"
    assert details["snapshot_policy"] == "recursive_denylist_v1"
    assert details["limits"]["max_file_bytes"] == 1
    assert details["files_copied"] == 0
    assert details["bytes_copied"] == 0
    assert is_integer(details["elapsed_ms"])
    assert "increase_subagent_snapshot_limits_if_intentional" in details["next_actions"]

    assert {:ok, [failed]} = Subagents.list(sid, workspace: ws)
    assert failed["status"] == "failed"
    refute Map.has_key?(failed, "workspace_snapshot")
  end

  # Before the opts channel, a caller-authored id reached workspace paths and
  # only format validation stopped "../outside". Now the id never comes from
  # args at all: path-unsafe input cannot reach path construction.
  test "path-unsafe caller-authored ids never reach workspace preparation", %{sid: sid, ws: ws} do
    assert {:ok, agent} =
             Subagents.spawn_agent(
               sid,
               %{"task" => "unsafe id ignored", "id" => "../outside", "timeout_ms" => 5_000},
               workspace: ws,
               provider: WritingProvider,
               permission_mode: :auto
             )

    assert agent["id"] =~ ~r/\Asub_[0-9a-f]{10}\z/
    refute agent["id"] =~ ".."
    refute agent["child_log_path"] =~ "outside"
    assert {:ok, [_completed]} = Subagents.wait(sid, [agent["id"]], 10_000, workspace: ws)
  end

  test "malformed snapshot options return structured write errors", %{sid: sid, ws: ws} do
    assert {:error, %{error: %{kind: :write_failed, details: details}}} =
             Subagents.spawn_agent(
               sid,
               %{"task" => "bad snapshot opts", "timeout_ms" => 5_000},
               workspace: ws,
               provider: BlockingProvider,
               permission_mode: :auto,
               workspace_snapshot_opts: %{limits: [max_files: 1]}
             )

    assert details["reason"] == "snapshot_invalid_options"
    assert "pass_workspace_snapshot_opts_as_a_keyword_list" in details["next_actions"]
  end

  test "workspace snapshot skips a nested destination instead of self-copying", %{ws: ws} do
    dest = Path.join(ws, "nested-destination")
    File.mkdir_p!(dest)
    File.write!(Path.join(dest, "old.txt"), "old")
    File.write!(Path.join(ws, "keep.txt"), "keep")

    assert {:ok, snapshot} = WorkspaceSnapshot.copy(ws, dest)

    assert File.read!(Path.join(dest, "keep.txt")) == "keep"
    refute File.exists?(Path.join([dest, "nested-destination", "old.txt"]))
    assert snapshot["skipped_dirs_by_name"]["nested-destination"] == 1
  end

  test "shared workspace mode stays cheap and does not emit snapshot metadata", %{
    sid: sid,
    ws: ws
  } do
    {:ok, agent} =
      Subagents.spawn_agent(
        sid,
        %{"task" => "shared block", "workspace_mode" => "shared", "timeout_ms" => 5_000},
        workspace: ws,
        provider: BlockingProvider,
        permission_mode: :auto
      )

    assert agent["workspace"] == ws
    refute Map.has_key?(agent, "workspace_snapshot")

    assert {:ok, history} = Log.fold(sid, workspace: ws)

    assert [started] =
             Enum.filter(
               history,
               &(&1.type == :subagent_event and &1.data["subagent_id"] == agent["id"] and
                   &1.data["event"] == "started")
             )

    assert started.data["workspace_mode"] == "shared"
    refute Map.has_key?(started.data, "workspace_snapshot")

    assert get_in(started.data, ["delegation_context", "workspace_fidelity"]) ==
             "real_parent_workspace"

    assert get_in(Subagents.reconstruct(history), [agent["id"], "workspace_mode"]) == "shared"

    assert {:ok, cancelled} = Subagents.close(sid, agent["id"], workspace: ws)
    assert cancelled["status"] == "cancelled"
  end

  test "rejects unsupported Subagent workspace modes instead of snapshot fallback", %{
    sid: sid,
    ws: ws
  } do
    assert {:error, %{error: %{kind: :invalid_args, details: details}}} =
             Subagents.spawn_agent(
               sid,
               %{"task" => "virtual scratch", "workspace_mode" => "virtual_overlay"},
               workspace: ws,
               provider: BlockingProvider,
               permission_mode: :auto
             )

    assert details["workspace_mode"] == "virtual_overlay"
    assert details["supported_modes"] == ["shared", "isolated"]
    assert details["future_modes"] == ["virtual_overlay"]
    assert details["future_mode_status"] =~ "not runtime-enabled yet"

    assert {:ok, history} = Log.fold(sid, workspace: ws)
    refute Enum.any?(history, &(&1.type == :subagent_event))
  end

  test "child turns receive late Subagent Delegation Context", %{sid: sid, ws: ws} do
    auth = start_test_auth(ws)

    {:ok, policy} =
      WritePolicy.normalize(%{
        "version" => 1,
        "metadata" => %{"id" => "subagent-test"},
        "allow_writes" => ["allowed/**"]
      })

    {:ok, agent} =
      Subagents.spawn_agent(
        sid,
        %{
          "task" => "inspect delegated context",
          "agent" => "explorer",
          "timeout_ms" => 5_000
        },
        workspace: ws,
        provider_opts: [auth: auth, transport: capturing_transport(self())],
        permission_mode: :auto,
        write_policy: policy
      )

    assert {:ok, [completed]} = Subagents.wait(sid, [agent["id"]], 2_000, workspace: ws)
    assert completed["status"] == "completed"

    assert_receive {:subagent_provider_http_request, http_request}, 1_000
    body = Jason.decode!(http_request.body)
    developer_context = developer_context_from_body(body)

    refute body["instructions"] =~ agent["id"]
    refute body["instructions"] =~ agent["child_session_id"]
    assert developer_context =~ "Subagent delegation context"
    assert developer_context =~ ~s("subagent_id": "#{agent["id"]}")
    assert developer_context =~ ~s("parent_session_id": "#{sid}")
    assert developer_context =~ ~s("child_session_id": "#{agent["child_session_id"]}")
    assert developer_context =~ ~s("agent": "explorer")
    assert developer_context =~ ~s("task": "inspect delegated context")
    assert developer_context =~ ~s("depth": 1)
    assert developer_context =~ ~s("max_depth": 1)
    assert developer_context =~ ~s("timeout_ms": 5000)
    assert developer_context =~ ~s("permission_mode": "read_only")
    assert developer_context =~ ~s("write_policy":)
    assert developer_context =~ "subagent-test"
    assert developer_context =~ ~s("workspace_mode": "isolated")
    assert developer_context =~ ~s("workspace_fidelity": "bounded_physical_snapshot")
    assert developer_context =~ ~s("read_boundary": "snapshot_copy")

    assert developer_context =~
             ~s("write_semantics": "snapshot_only_parent_workspace_not_mutated")

    assert developer_context =~ ~s("parent_workspace_mutation": "none")
    assert developer_context =~ ~s("deadline_at":)
    assert developer_context =~ "OS-boundary fanout carefully bounded"

    assert {:ok, history} = Log.fold(sid, workspace: ws)

    started_event =
      Enum.find(
        history,
        &(&1.type == :subagent_event and &1.data["subagent_id"] == agent["id"] and
            &1.data["event"] == "started")
      )

    assert started_event.data["delegation_context"]["subagent_id"] == agent["id"]

    assert started_event.data["delegation_context"]["child_session_id"] ==
             agent["child_session_id"]

    assert started_event.data["delegation_context"]["permission_mode"] == "read_only"
    assert started_event.data["delegation_context"]["write_policy"]["id"] == "subagent-test"
    assert started_event.data["write_policy"]["id"] == "subagent-test"
    assert started_event.data["delegation_context"]["workspace_mode"] == "isolated"

    assert started_event.data["delegation_context"]["workspace_fidelity"] ==
             "bounded_physical_snapshot"

    assert started_event.data["delegation_context"]["parent_workspace_mutation"] == "none"
  end

  test "enforces max_threads with queueing", %{sid: sid, ws: ws} do
    ids =
      for i <- 1..3 do
        {:ok, agent} =
          Subagents.spawn_agent(
            sid,
            %{"task" => "block-#{i}", "max_threads" => 1, "timeout_ms" => 500},
            workspace: ws,
            provider: BlockingProvider,
            permission_mode: :auto
          )

        agent["id"]
      end

    {:ok, listed} = Subagents.list(sid)
    assert Enum.count(listed, &(&1["status"] == "running")) == 1
    assert Enum.count(listed, &(&1["status"] == "queued")) == 2

    assert {:ok, waited} = Subagents.wait(sid, ids, 3_000)
    assert Enum.all?(waited, &(&1["status"] in ["timed_out", "completed"]))
  end

  test "diagnostics exposes manager counters, waiters, and child index health", %{
    sid: sid,
    ws: ws
  } do
    {:ok, running} =
      Subagents.spawn_agent(
        sid,
        %{"task" => "running", "max_threads" => 1, "timeout_ms" => 5_000},
        workspace: ws,
        provider: BlockingProvider,
        permission_mode: :auto
      )

    {:ok, queued} =
      Subagents.spawn_agent(
        sid,
        %{"task" => "queued", "max_threads" => 1, "timeout_ms" => 5_000},
        workspace: ws,
        provider: BlockingProvider,
        permission_mode: :auto
      )

    running_id = running["id"]
    queued_id = queued["id"]
    running_child_sid = running["child_session_id"]

    on_exit(fn ->
      _ = Subagents.close(sid, queued_id, workspace: ws)
      _ = Subagents.close(sid, running_id, workspace: ws)
      cleanup_session(running_child_sid)
    end)

    waiter_task =
      Task.async(fn -> Subagents.wait(sid, [running_id], 5_000, workspace: ws) end)

    wait_until(fn ->
      case Subagents.diagnostics(sid) do
        {:ok, diagnostics} -> diagnostics["active_waiter_count"] == 1
        _ -> false
      end
    end)

    assert {:ok, diagnostics} = Subagents.diagnostics(sid)
    assert diagnostics["parent_session_id"] == sid
    assert is_binary(diagnostics["observed_at"])
    assert is_integer(diagnostics["message_queue_len"])
    assert diagnostics["known_subagent_count"] == 2
    assert diagnostics["running_count"] == 1
    assert diagnostics["queued_count"] == 1
    assert diagnostics["terminal_count"] == 0
    assert diagnostics["status_counts"] == %{"queued" => 1, "running" => 1}
    assert diagnostics["child_index_count"] == 1
    assert diagnostics["active_waiter_count"] == 1
    assert diagnostics["runtime_gaps"] == []
    assert diagnostics["next_actions"] == []

    assert [%{"ids" => [^running_id], "mode" => "agents", "timeout_ms" => 5_000}] =
             diagnostics["active_waiters"]

    running_runtime = Enum.find(diagnostics["subagents"], &(&1["id"] == running_id))
    queued_runtime = Enum.find(diagnostics["subagents"], &(&1["id"] == queued_id))

    assert running_runtime["child_session_id"] == running["child_session_id"]
    assert running_runtime["child_indexed"] == true
    assert running_runtime["child_pid_alive"] == true
    assert queued_runtime["status"] == "queued"
    refute queued_runtime["child_indexed"]
    refute queued_runtime["child_pid_alive"]

    assert {:ok, _cancelled_running} = Subagents.close(sid, running_id, workspace: ws)

    assert {:ok, [%{"id" => ^running_id, "status" => "cancelled"}]} =
             Task.await(waiter_task, 1_000)

    assert {:ok, _cancelled_queued} = Subagents.close(sid, queued_id, workspace: ws)
  end

  test "rejects malformed limits before queueing", %{sid: sid, ws: ws} do
    assert {:error, %{error: %{kind: :invalid_args, details: details}}} =
             Subagents.spawn_agent(
               sid,
               %{"task" => "bad limit", "max_threads" => "one"},
               workspace: ws,
               provider: WritingProvider,
               permission_mode: :auto
             )

    assert details["field"] == "max_threads"

    assert {:error, %{error: %{kind: :invalid_args, details: details}}} =
             Subagents.spawn_agent(
               sid,
               %{"task" => "bad depth", "max_depth" => "one"},
               workspace: ws,
               provider: WritingProvider,
               permission_mode: :auto
             )

    assert details["field"] == "max_depth"

    assert {:error, %{error: %{kind: :invalid_args, details: details}}} =
             Subagents.spawn_agent(
               sid,
               %{"task" => "bad timeout", "timeout_ms" => 0},
               workspace: ws,
               provider: WritingProvider,
               permission_mode: :auto
             )

    assert details["field"] == "timeout_ms"

    assert {:ok, []} = Subagents.list(sid, workspace: ws)
  end

  test "wait_agent reports mixed fanout as a structured partial outcome", %{sid: sid, ws: ws} do
    {:ok, completed_agent} =
      Subagents.spawn_agent(
        sid,
        %{"task" => "quick", "timeout_ms" => 5_000},
        workspace: ws,
        provider: WritingProvider,
        permission_mode: :auto
      )

    {:ok, timeout_agent} =
      Subagents.spawn_agent(
        sid,
        %{"task" => "block", "timeout_ms" => 50},
        workspace: ws,
        provider: BlockingProvider,
        permission_mode: :auto
      )

    ids = [completed_agent["id"], timeout_agent["id"]]
    ctx = %{session_id: sid, workspace: ws}

    assert {:ok, result} = WaitAgent.execute(%{"ids" => ids, "timeout_ms" => 1_000}, ctx)
    assert result["output"] =~ "wait_agent partial"

    outcome = result["outcome"]
    assert outcome["status"] == "partial"
    assert outcome["complete"] == false
    assert outcome["partial"] == true
    assert outcome["counts"]["completed"] == 1
    assert outcome["counts"]["timed_out"] == 1
    timeout_id = timeout_agent["id"]
    assert [%{"id" => ^timeout_id, "reason" => "timeout"}] = outcome["timed_out"]
    assert "retry_subagent_with_larger_timeout" in outcome["next_actions"]
    assert Enum.sort(Enum.map(result["subagents"], & &1["id"])) == Enum.sort(ids)
  end

  test "wait_agent polling reports incomplete children without failing the tool call", %{
    sid: sid,
    ws: ws
  } do
    {:ok, agent} =
      Subagents.spawn_agent(
        sid,
        %{"task" => "block", "timeout_ms" => 5_000},
        workspace: ws,
        provider: BlockingProvider,
        permission_mode: :auto
      )

    ctx = %{session_id: sid, workspace: ws}

    assert {:ok, result} =
             WaitAgent.execute(%{"ids" => [agent["id"]], "timeout_ms" => 0}, ctx)

    assert result["output"] =~ "wait_agent incomplete"
    assert result["outcome"]["status"] == "incomplete"
    assert result["outcome"]["observed_at"]
    assert result["outcome"]["counts"]["incomplete"] == 1
    agent_id = agent["id"]

    assert [%{"id" => ^agent_id, "status" => "running"} = running] =
             result["outcome"]["incomplete"]

    assert running["max_depth"] == 1
    assert running["parent_log_path"] =~ ".pixir/sessions/#{sid}.ndjson"
    assert running["child_log_path"] =~ ".pixir/sessions/#{running["child_session_id"]}.ndjson"
    refute Map.has_key?(running, "child_log_exists")
    refute Map.has_key?(running, "child_event_count")
    assert "wait_again" in result["outcome"]["next_actions"]
    assert "inspect_child_log_if_stale" in result["outcome"]["next_actions"]
  end

  test "timeout records actionable evidence in public state and parent log", %{
    sid: sid,
    ws: ws
  } do
    {:ok, policy} =
      WritePolicy.normalize(%{
        "version" => 1,
        "metadata" => %{"id" => "restore-policy"},
        "allow_writes" => ["allowed/**"]
      })

    {:ok, agent} =
      Subagents.spawn_agent(
        sid,
        %{"task" => "block", "timeout_ms" => 50},
        workspace: ws,
        provider: BlockingProvider,
        permission_mode: :auto,
        write_policy: policy
      )

    assert {:ok, [timed_out]} = Subagents.wait(sid, [agent["id"]], 1_000)
    assert timed_out["id"] == agent["id"]
    assert timed_out["child_session_id"] == agent["child_session_id"]
    assert timed_out["status"] == "timed_out"
    assert timed_out["max_depth"] == 1
    assert timed_out["timeout_ms"] == 50
    assert is_binary(timed_out["deadline_at"])
    assert timed_out["parent_log_path"] =~ ".pixir/sessions/#{sid}.ndjson"
    assert timed_out["child_log_path"] =~ ".pixir/sessions/#{agent["child_session_id"]}.ndjson"
    assert is_integer(timed_out["elapsed_ms"])
    assert timed_out["elapsed_ms"] >= 0
    assert timed_out["reason"] == "timeout"
    assert "inspect_child_session_log" in timed_out["next_actions"]
    assert timed_out["summary"] =~ "configured timeout 50ms"

    assert {:ok, history} = Log.fold(sid, workspace: ws)

    assert [event] =
             Enum.filter(
               history,
               &(&1.type == :subagent_event and &1.data["event"] == "timed_out")
             )

    assert event.data["subagent_id"] == agent["id"]
    assert event.data["child_session_id"] == agent["child_session_id"]
    assert event.data["agent"] == "default"
    assert event.data["status"] == "timed_out"
    assert event.data["max_depth"] == 1
    assert event.data["timeout_ms"] == 50
    assert is_binary(event.data["deadline_at"])
    assert event.data["parent_log_path"] =~ ".pixir/sessions/#{sid}.ndjson"
    assert event.data["child_log_path"] =~ ".pixir/sessions/#{agent["child_session_id"]}.ndjson"
    assert is_integer(event.data["elapsed_ms"])
    assert event.data["reason"] == "timeout"
    assert "retry_subagent_with_larger_timeout" in event.data["next_actions"]

    assert [started] =
             Enum.filter(
               history,
               &(&1.type == :subagent_event and &1.data["event"] == "started")
             )

    assert started.data["timeout_ms"] == 50
    assert is_binary(started.data["deadline_at"])
    assert started.data["parent_log_path"] =~ ".pixir/sessions/#{sid}.ndjson"
    assert started.data["child_log_path"] =~ ".pixir/sessions/#{agent["child_session_id"]}.ndjson"

    restart_subagents_manager()

    assert {:ok, [restored]} = Subagents.list(sid, workspace: ws)
    assert restored["id"] == agent["id"]
    assert restored["status"] == "timed_out"
    assert restored["max_depth"] == 1
    assert restored["timeout_ms"] == 50
    assert is_binary(restored["deadline_at"])
    assert restored["parent_log_path"] =~ ".pixir/sessions/#{sid}.ndjson"
    assert restored["child_log_path"] =~ ".pixir/sessions/#{agent["child_session_id"]}.ndjson"
    assert is_integer(restored["elapsed_ms"])
    assert restored["reason"] == "timeout"
    assert restored["write_policy"]["id"] == "restore-policy"
    assert restored["write_policy"]["hash"] == policy["hash"]
    assert "inspect_child_session_log" in restored["next_actions"]
  end

  test "provider failure after child tool activity records durable failed state", %{
    sid: sid,
    ws: ws
  } do
    {:ok, agent} =
      Subagents.spawn_agent(
        sid,
        %{"task" => "write then fail", "timeout_ms" => 5_000},
        workspace: ws,
        provider: FailingAfterToolProvider,
        permission_mode: :auto
      )

    assert {:ok, [failed]} = Subagents.wait(sid, [agent["id"]], 2_000)
    assert failed["status"] == "failed"
    assert failed["reason"] == "provider_error"
    assert is_integer(failed["elapsed_ms"])
    assert "inspect_child_session_log" in failed["next_actions"]
    assert failed["summary"] =~ "provider stream exited"

    assert File.read!(Path.join(failed["workspace"], "before-failure.txt")) == "started"

    assert {:ok, history} = Log.fold(sid, workspace: ws)

    assert [event] =
             Enum.filter(
               history,
               &(&1.type == :subagent_event and &1.data["event"] == "failed")
             )

    assert event.data["subagent_id"] == agent["id"]
    assert event.data["status"] == "failed"
    assert event.data["reason"] == "provider_error"
    assert is_integer(event.data["elapsed_ms"])
    assert "reduce_task_scope" in event.data["next_actions"]

    restart_subagents_manager()

    assert {:ok, [restored]} = Subagents.list(sid, workspace: ws)
    assert restored["id"] == agent["id"]
    assert restored["status"] == "failed"
    assert restored["reason"] == "provider_error"
    assert "inspect_child_session_log" in restored["next_actions"]
  end

  test "partial child assistant evidence does not rehydrate as completed", %{
    sid: sid,
    ws: ws
  } do
    {:ok, agent} =
      Subagents.spawn_agent(
        sid,
        %{"task" => "partial then fail", "timeout_ms" => 5_000},
        workspace: ws,
        provider: PartialThenErrorProvider,
        permission_mode: :auto
      )

    assert {:ok, [failed]} = Subagents.wait(sid, [agent["id"]], 2_000)
    assert failed["status"] == "failed"
    assert failed["reason"] == "partial_provider_error"
    assert failed["summary"] =~ "partial assistant evidence"

    assert {:ok, child_history} =
             Log.fold(failed["child_session_id"], workspace: failed["workspace"])

    assert Enum.any?(child_history, &(&1.type == :assistant_message))
    assert Enum.any?(child_history, &(&1.type == :turn_failed))

    restart_subagents_manager()

    assert {:ok, [restored]} = Subagents.list(sid, workspace: ws)
    assert restored["id"] == agent["id"]
    assert restored["status"] == "failed"
    assert restored["reason"] == "partial_provider_error"
    assert restored["summary"] =~ "partial assistant evidence"
  end

  test "cold restore treats non-live running child logs as detached", %{sid: sid, ws: ws} do
    id = unique_subagent_id("cold-running")
    child_sid = unique_session_id("child-running")
    child_ws = Path.join(ws, "cold-running-workspace")

    File.mkdir_p!(child_ws)

    write_subagent_event!(sid, ws, %{
      "event" => "started",
      "subagent_id" => id,
      "child_session_id" => child_sid,
      "agent" => "default",
      "task" => "cold child",
      "depth" => 1,
      "max_depth" => 1,
      "timeout_ms" => 5_000,
      "status" => "running",
      "workspace_mode" => "shared",
      "workspace" => child_ws,
      "summary" => nil,
      "deadline_at" => DateTime.utc_now() |> DateTime.add(60, :second) |> DateTime.to_iso8601(),
      "parent_log_path" => Log.path(sid, workspace: ws),
      "child_log_path" => Log.path(child_sid, workspace: child_ws)
    })

    assert {:ok, _} =
             Log.append(Event.with_seq(Event.assistant_message(child_sid, "misleading done"), 0),
               workspace: child_ws
             )

    restart_subagents_manager()

    assert {:ok, [listed]} = Subagents.list(sid, workspace: ws)
    assert listed["id"] == id
    assert listed["child_session_id"] == child_sid
    assert listed["status"] == "detached"
    assert listed["workspace_mode"] == "shared"
    assert listed["summary"] =~ "previous Pixir runtime"
    refute listed["summary"] =~ "misleading done"

    assert {:ok, [polled]} = Subagents.wait(sid, [id], 0, workspace: ws)
    assert polled["status"] == "detached"

    assert {:ok, outcome} = Subagents.wait_outcome(sid, [id], 0, workspace: ws)
    assert outcome["status"] == "partial"
    assert outcome["counts"]["detached"] == 1
    assert [%{"id" => ^id, "status" => "detached"}] = outcome["detached"]

    assert {:error, %{error: %{kind: :detached}}} =
             Subagents.send_input(sid, id, "resume", workspace: ws)

    assert {:error, %{error: %{kind: :detached}}} = Subagents.close(sid, id, workspace: ws)
  end

  test "cold restore treats queued children as detached", %{sid: sid, ws: ws} do
    id = unique_subagent_id("cold-queued")

    write_subagent_event!(sid, ws, %{
      "event" => "queued",
      "subagent_id" => id,
      "child_session_id" => nil,
      "agent" => "default",
      "task" => "queued child",
      "depth" => 1,
      "max_depth" => 1,
      "timeout_ms" => 5_000,
      "status" => "queued",
      "workspace" => ws,
      "summary" => nil,
      "parent_log_path" => Log.path(sid, workspace: ws)
    })

    restart_subagents_manager()

    assert {:ok, [listed]} = Subagents.list(sid, workspace: ws)
    assert listed["id"] == id
    assert listed["status"] == "detached"
    assert listed["summary"] =~ "previous Pixir runtime"

    assert {:ok, [polled]} = Subagents.wait(sid, [id], 0, workspace: ws)
    assert polled["status"] == "detached"

    assert {:error, %{error: %{kind: :detached}}} =
             Subagents.send_input(sid, id, "resume", workspace: ws)

    assert {:error, %{error: %{kind: :detached}}} = Subagents.close(sid, id, workspace: ws)
  end

  test "cold restore preserves virtual_diff_ref through reconstruct and restored agents", %{
    sid: sid,
    ws: ws
  } do
    id = unique_subagent_id("cold-virtual")
    child_sid = unique_session_id("child-virtual")

    ref = %{
      "kind" => "virtual_diff",
      "version" => 1,
      "sha256" => String.duplicate("ab", 32),
      "encoded_bytes" => 1651,
      "changed_files" => 1,
      "diff_bytes" => 129,
      "apply_status" => "not_applied",
      "source_seq" => 10
    }

    write_subagent_event!(sid, ws, %{
      "event" => "finished",
      "subagent_id" => id,
      "child_session_id" => child_sid,
      "agent" => "default",
      "task" => "cold virtual child",
      "depth" => 1,
      "max_depth" => 1,
      "timeout_ms" => 5_000,
      "status" => "completed",
      "workspace_mode" => "virtual_overlay",
      "workspace" => ws,
      "summary" => "{\"done\":true}",
      "virtual_diff_ref" => ref,
      "parent_log_path" => Log.path(sid, workspace: ws),
      "child_log_path" => Log.path(child_sid, workspace: ws)
    })

    assert {:ok, history} = Log.fold(sid, workspace: ws)

    # The pure fold projection carries the bounded ref with string keys intact.
    assert Subagents.reconstruct(history)[id]["virtual_diff_ref"] == ref

    # And the restored (cold) Manager agent exposes the same ref on the
    # public surface — the resume/fold path, no live spawn involved.
    restart_subagents_manager()

    assert {:ok, [listed]} = Subagents.list(sid, workspace: ws)
    assert listed["id"] == id
    assert listed["workspace_mode"] == "virtual_overlay"
    assert listed["virtual_diff_ref"] == ref
  end

  test "reattaches started-only live subagents after manager restart", %{sid: sid, ws: ws} do
    {:ok, agent} =
      Subagents.spawn_agent(
        sid,
        %{"task" => "block", "timeout_ms" => 10_000},
        workspace: ws,
        provider: BlockingProvider,
        permission_mode: :auto
      )

    child_sid = agent["child_session_id"]
    on_exit(fn -> cleanup_session(child_sid) end)

    wait_until_started(sid, ws, agent)
    restart_subagents_manager()

    assert {:ok, [listed]} = Subagents.list(sid, workspace: ws)
    assert listed["id"] == agent["id"]
    assert listed["child_session_id"] == child_sid
    assert listed["status"] == "running"
    assert listed["summary"] =~ "reattached"
    assert is_binary(listed["deadline_at"])

    assert {:ok, [polled]} = Subagents.wait(sid, [agent["id"]], 0, workspace: ws)
    assert polled["status"] == "running"

    assert {:error, %{error: %{kind: :permission_denied}}} =
             Subagents.send_input(sid, agent["id"], "resume", workspace: ws)

    assert {:ok, cancelled} = Subagents.close(sid, agent["id"], workspace: ws)
    assert cancelled["status"] == "cancelled"
    assert cancelled["reason"] == "cancelled_by_parent"

    assert {:ok, history} = Log.fold(sid, workspace: ws)

    assert Enum.any?(
             history,
             &(&1.type == :subagent_event and &1.data["subagent_id"] == agent["id"] and
                 &1.data["event"] == "cancelled")
           )
  end

  test "manager restart rearms running subagent timeouts from durable deadline", %{
    sid: sid,
    ws: ws
  } do
    {:ok, agent} =
      Subagents.spawn_agent(
        sid,
        %{"task" => "block", "timeout_ms" => 120},
        workspace: ws,
        provider: BlockingProvider,
        permission_mode: :auto
      )

    child_sid = agent["child_session_id"]
    on_exit(fn -> cleanup_session(child_sid) end)

    wait_until_started(sid, ws, agent)
    restart_subagents_manager()

    assert {:ok, [timed_out]} = Subagents.wait(sid, [agent["id"]], 1_000, workspace: ws)
    assert timed_out["status"] == "timed_out"
    assert timed_out["reason"] == "timeout"
    assert timed_out["timeout_ms"] == 120
    assert is_binary(timed_out["deadline_at"])

    assert {:ok, history} = Log.fold(sid, workspace: ws)

    assert Enum.any?(
             history,
             &(&1.type == :subagent_event and &1.data["subagent_id"] == agent["id"] and
                 &1.data["event"] == "timed_out" and is_binary(&1.data["deadline_at"]))
           )
  end

  test "close cancels a running subagent with durable lifecycle evidence", %{sid: sid, ws: ws} do
    {:ok, agent} =
      Subagents.spawn_agent(
        sid,
        %{"task" => "block", "timeout_ms" => 5_000},
        workspace: ws,
        provider: BlockingProvider,
        permission_mode: :auto
      )

    wait_until(fn ->
      {:ok, agents} = Subagents.list(sid, workspace: ws)
      Enum.any?(agents, &(&1["id"] == agent["id"] and &1["status"] == "running"))
    end)

    assert {:ok, cancelled} = Subagents.close(sid, agent["id"])
    assert cancelled["status"] == "cancelled"
    assert cancelled["reason"] == "cancelled_by_parent"
    assert is_integer(cancelled["elapsed_ms"])
    assert "inspect_child_session_log" in cancelled["next_actions"]
    assert "rerun_subagent_if_still_needed" in cancelled["next_actions"]

    assert {:ok, history} = Log.fold(sid, workspace: ws)

    assert [event] =
             Enum.filter(
               history,
               &(&1.type == :subagent_event and &1.data["event"] == "cancelled")
             )

    assert event.data["subagent_id"] == agent["id"]
    assert event.data["status"] == "cancelled"
    assert event.data["reason"] == "cancelled_by_parent"
    assert is_integer(event.data["elapsed_ms"])
    assert "rerun_subagent_if_still_needed" in event.data["next_actions"]

    assert {:ok, outcome} = Subagents.wait_outcome(sid, [agent["id"]], 0, workspace: ws)
    assert outcome["status"] == "partial"
    assert outcome["counts"]["cancelled"] == 1
    assert [%{"id" => id, "status" => "cancelled"}] = outcome["cancelled"]
    assert id == agent["id"]
    assert "rerun_subagent_if_still_needed" in outcome["next_actions"]
  end

  test "close cleans up a queued subagent before runtime start", %{sid: sid, ws: ws} do
    {:ok, running} =
      Subagents.spawn_agent(
        sid,
        %{"task" => "running", "max_threads" => 1, "timeout_ms" => 5_000},
        workspace: ws,
        provider: BlockingProvider,
        permission_mode: :auto
      )

    {:ok, queued} =
      Subagents.spawn_agent(
        sid,
        %{"task" => "queued", "max_threads" => 1, "timeout_ms" => 5_000},
        workspace: ws,
        provider: BlockingProvider,
        permission_mode: :auto
      )

    assert queued["status"] == "queued"

    assert {:ok, closed} = Subagents.close(sid, queued["id"], workspace: ws)
    assert closed["status"] == "closed"
    assert closed["reason"] == "closed_before_start"
    assert closed["summary"] =~ "before it started"
    assert "inspect_parent_session_log" in closed["next_actions"]

    assert {:ok, history} = Log.fold(sid, workspace: ws)

    assert [event] =
             Enum.filter(
               history,
               &(&1.type == :subagent_event and &1.data["subagent_id"] == queued["id"] and
                   &1.data["event"] == "closed")
             )

    assert event.data["status"] == "closed"
    assert event.data["reason"] == "closed_before_start"
    assert "spawn_agent_again_if_needed" in event.data["next_actions"]

    assert {:ok, outcome} = Subagents.wait_outcome(sid, [queued["id"]], 0, workspace: ws)
    assert outcome["status"] == "partial"
    assert outcome["counts"]["cancelled"] == 1
    assert [%{"id" => id, "status" => "closed"}] = outcome["cancelled"]
    assert id == queued["id"]

    assert {:ok, _cancelled_running} = Subagents.close(sid, running["id"], workspace: ws)
  end

  test "max_depth rejects recursive fan-out beyond the configured cap", %{sid: sid, ws: ws} do
    assert {:error, %{error: %{kind: :permission_denied, details: details}}} =
             Subagents.spawn_agent(
               sid,
               %{"task" => "too deep", "max_depth" => 1},
               workspace: ws,
               provider: WritingProvider,
               depth: 1
             )

    assert details["current_depth"] == 1
    assert details["requested_child_depth"] == 2
    assert details["max_depth"] == 1
    assert details["meaning"] =~ "root children run at depth 1"
    assert "increase_max_depth_to_2" in details["next_actions"]
  end

  defp restart_subagents_manager do
    old = Process.whereis(Pixir.Subagents.Manager)

    if is_pid(old) do
      :ok = Supervisor.terminate_child(Pixir.Supervisor, Pixir.Subagents.Manager)
      {:ok, _pid} = Supervisor.restart_child(Pixir.Supervisor, Pixir.Subagents.Manager)
    end

    wait_until(fn ->
      current = Process.whereis(Pixir.Subagents.Manager)
      is_pid(current) and current != old and Process.alive?(current)
    end)
  end

  defp ensure_subagents_manager_started do
    case Process.whereis(Pixir.Subagents.Manager) do
      pid when is_pid(pid) ->
        :ok

      _ ->
        case Supervisor.restart_child(Pixir.Supervisor, Pixir.Subagents.Manager) do
          {:ok, _pid} -> :ok
          {:ok, _pid, _info} -> :ok
          {:error, :running} -> :ok
          {:error, {:already_started, _pid}} -> :ok
        end

        wait_until(fn ->
          current = Process.whereis(Pixir.Subagents.Manager)
          is_pid(current) and Process.alive?(current)
        end)
    end
  end

  defp wait_until(fun, attempts \\ 50)

  defp wait_until(fun, attempts) when attempts > 0 do
    if fun.() do
      :ok
    else
      Process.sleep(20)
      wait_until(fun, attempts - 1)
    end
  end

  defp wait_until(_fun, 0), do: flunk("condition was not met before timeout")

  defp wait_until_started(sid, ws, agent) do
    wait_until(fn ->
      case Log.fold(sid, workspace: ws) do
        {:ok, history} ->
          Enum.any?(
            history,
            &(&1.type == :subagent_event and &1.data["subagent_id"] == agent["id"] and
                &1.data["child_session_id"] == agent["child_session_id"] and
                &1.data["event"] == "started" and is_binary(&1.data["deadline_at"]))
          )

        _ ->
          false
      end
    end)
  end

  defp write_subagent_event!(sid, ws, data) do
    assert {:ok, _event} = Session.record(sid, Event.subagent_event(sid, data))
    assert {:ok, _history} = Log.fold(sid, workspace: ws)
  end

  defp start_test_auth(ws) do
    path = Path.join(ws, "auth-#{System.unique_integer([:positive])}.json")

    {:ok, pid} =
      Auth.start_link(name: nil, store_path: path, env_api_key: "sk-test", oauth: NoOAuth)

    pid
  end

  defp capturing_transport(test_pid) do
    fn http_request, acc, fun ->
      send(test_pid, {:subagent_provider_http_request, http_request})

      acc = fun.({:status, 200}, acc)
      acc = fun.({:data, sse(%{type: "response.output_text.delta", delta: "captured"})}, acc)
      acc = fun.({:data, sse(%{type: "response.completed"})}, acc)

      {:ok, acc}
    end
  end

  defp developer_context_from_body(body) do
    body["input"]
    |> Enum.find(&(&1["role"] == "developer"))
    |> get_in(["content", Access.at(0), "text"])
  end

  defp sse(map), do: "data: " <> Jason.encode!(map) <> "\n\n"

  defp unique_subagent_id(label) do
    "sub_#{label}_#{System.unique_integer([:positive])}"
  end

  defp unique_session_id(label) do
    "sess_#{label}_#{System.unique_integer([:positive])}"
  end

  defp cleanup_session(nil), do: :ok

  defp cleanup_session(session_id) do
    _ =
      try do
        Session.interrupt(session_id)
      catch
        :exit, _reason -> :ok
      end

    case Registry.lookup(Pixir.Sessions.Registry, session_id) do
      [{pid, _}] -> DynamicSupervisor.terminate_child(SessionSupervisor, pid)
      [] -> :ok
    end
  end
end
