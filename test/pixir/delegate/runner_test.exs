defmodule Pixir.Delegate.RunnerTest do
  use ExUnit.Case, async: false

  alias Pixir.Delegate.Runner

  defp tmp_workspace(prefix) do
    path =
      Path.join(
        System.tmp_dir!(),
        "#{prefix}-#{Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)}"
      )

    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end

  defp with_pixir_home(prefix, fun) do
    home = Path.join(System.tmp_dir!(), "#{prefix}-#{System.unique_integer([:positive])}")
    previous_home = System.get_env("PIXIR_HOME")

    File.mkdir_p!(home)
    System.put_env("PIXIR_HOME", home)

    on_exit(fn ->
      if previous_home,
        do: System.put_env("PIXIR_HOME", previous_home),
        else: System.delete_env("PIXIR_HOME")

      File.rm_rf!(home)
    end)

    fun.()
  end

  defp write_raw_session_log(workspace, session_id, events) do
    sessions_dir = Path.join([workspace, ".pixir", "sessions"])
    File.mkdir_p!(sessions_dir)

    body = Enum.map_join(events, "", fn event -> Jason.encode!(event) <> "\n" end)
    File.write!(Path.join(sessions_dir, "#{session_id}.ndjson"), body)
  end

  defp write_corrupt_session_log(workspace, session_id, valid_events) do
    sessions_dir = Path.join([workspace, ".pixir", "sessions"])
    File.mkdir_p!(sessions_dir)

    body =
      Enum.map_join(valid_events, "", fn event -> Jason.encode!(event) <> "\n" end) <>
        ~s({"id":"truncated")

    File.write!(Path.join(sessions_dir, "#{session_id}.ndjson"), body)
  end

  defp raw_event(session_id, seq, type, data) do
    %{
      "id" => "event-#{seq}",
      "session_id" => session_id,
      "seq" => seq,
      "ts" => "2026-07-03T00:00:00Z",
      "type" => type,
      "data" => data
    }
  end

  defp run_child_projection(workspace, child, mode) do
    spec = projection_spec(mode)
    terminal_status = child["status"]
    completed = if terminal_status == "completed", do: 1, else: 0
    failed = if terminal_status == "failed", do: 1, else: 0
    outcome_status = if completed == 1, do: "completed", else: "partial"

    spawn_agent = fn _parent_session_id, _args, _opts -> {:ok, child} end

    wait_outcome = fn _parent_session_id, _ids, _timeout_ms, _opts ->
      {:ok,
       %{
         "status" => outcome_status,
         "complete" => true,
         "counts" => %{
           "completed" => completed,
           "failed" => failed,
           "timed_out" => 0,
           "cancelled" => 0,
           "detached" => 0,
           "incomplete" => 0
         },
         "subagents" => [child],
         "summary" => outcome_status
       }}
    end

    assert {:ok, %{"children" => [projected]}} =
             Runner.run(
               %{workspace: workspace},
               spec,
               %{"strategy" => "subagents", "planned_child_count" => 1},
               spawn_agent: spawn_agent,
               wait_outcome: wait_outcome
             )

    projected
  end

  defp projection_spec("read_only") do
    %{
      "contract_version" => 1,
      "strategy" => "subagents",
      "mode" => "read_only",
      "task" => "project one child"
    }
  end

  defp projection_spec("bounded_write") do
    %{
      "contract_version" => 1,
      "strategy" => "subagents",
      "mode" => "bounded_write",
      "task" => "project one writer",
      "write_policy" => %{
        "version" => 1,
        "metadata" => %{"id" => "guided-resume-test"},
        "allow_writes" => ["notes/out.md"]
      }
    }
  end

  test "transport-dead writer projects guided resume with write-safe notes" do
    with_pixir_home("pixir-delegate-writer-resume-home", fn ->
      ws = tmp_workspace("pixir-delegate-writer-resume")
      child_session_id = "20260710T000001-writer"

      write_raw_session_log(ws, child_session_id, [
        raw_event(child_session_id, 1, "turn_failed", %{
          "terminal_status" => "provider_error",
          "error_kind" => "provider_http_error",
          "error_message" => "provider transport failed",
          "details" => %{
            "retryable" => true,
            "type" => "service_unavailable_error"
          }
        })
      ])

      child = %{
        "id" => "subagent_writer",
        "child_session_id" => child_session_id,
        "agent" => "worker",
        "status" => "failed",
        "summary" => "provider transport failed",
        "task" => "write notes",
        "workspace_mode" => "shared",
        "workspace" => ws,
        "permission_mode" => "auto",
        "write_policy" => %{"allow_writes" => ["notes/out.md"]},
        "reason" => "provider_error",
        "child_log_path" => Path.join(ws, "writer.ndjson"),
        "next_actions" => []
      }

      projected = run_child_projection(ws, child, "bounded_write")

      assert projected["recovery"]["kind"] == "resume_suggested"

      assert projected["recovery"]["reason"] ==
               "terminal transport error: service_unavailable_error"

      assert projected["resume_command"] =~ "pixir resume #{child_session_id}"
      assert projected["diagnose_command"] =~ "pixir diagnose session #{child_session_id}"

      notes = projected["recovery"]["notes"]

      assert "The child Log is the source of truth; the resumed turn continues with context intact." in notes

      assert "Inspect the child Log for already-applied writes before resuming so work is not duplicated." in notes

      assert "A stale writer lease fails closed on purpose; inspect with pixir diagnose and never force-release it as a default." in notes
    end)
  end

  test "transport-dead read-only worker without capability signal omits writer guidance" do
    with_pixir_home("pixir-delegate-reader-resume-home", fn ->
      ws = tmp_workspace("pixir-delegate-reader-resume")
      child_session_id = "20260710T000002-reader"

      write_raw_session_log(ws, child_session_id, [
        raw_event(child_session_id, 1, "turn_failed", %{
          "terminal_status" => "provider_error",
          "error_kind" => "websocket_closed",
          "error_message" => "websocket closed"
        })
      ])

      child = %{
        "id" => "subagent_reader",
        "child_session_id" => child_session_id,
        "agent" => "worker",
        "status" => "failed",
        "summary" => "websocket closed",
        "task" => "inspect notes",
        "workspace_mode" => "shared",
        "workspace" => ws,
        "reason" => "provider_error",
        "retry_attempts" => 2,
        "retry_max_attempts" => 2,
        "current_attempt_index" => 2,
        "retry_history" => [
          %{"attempt_index" => 0, "error_kind" => "websocket_closed"},
          %{"attempt_index" => 1, "error_kind" => "websocket_closed"}
        ],
        "child_log_path" => Path.join(ws, "reader.ndjson"),
        "next_actions" => []
      }

      projected = run_child_projection(ws, child, "read_only")

      assert projected["recovery"] == %{
               "kind" => "resume_suggested",
               "reason" => "terminal transport error: websocket_closed"
             }

      assert projected["resume_command"] =~ "pixir resume #{child_session_id}"
      assert projected["retry_attempts"] == 2
      assert length(projected["retry_history"]) == 2
    end)
  end

  test "detached child with transport evidence projects guided resume" do
    with_pixir_home("pixir-delegate-detached-resume-home", fn ->
      ws = tmp_workspace("pixir-delegate-detached-resume")
      child_session_id = "20260710T000003-detached"

      write_raw_session_log(ws, child_session_id, [
        raw_event(child_session_id, 1, "turn_failed", %{
          "terminal_status" => "provider_error",
          "error_kind" => "websocket_read_failed",
          "error_message" => "Could not read WebSocket frame.",
          "details" => %{"reason" => ":closed"}
        })
      ])

      child = %{
        "id" => "subagent_detached",
        "child_session_id" => child_session_id,
        "agent" => "worker",
        "status" => "detached",
        "summary" => "child from a previous Pixir runtime",
        "task" => "write notes",
        "workspace_mode" => "shared",
        "workspace" => ws,
        "permission_mode" => "auto",
        "write_policy" => %{"allow_writes" => ["notes/out.md"]},
        "reason" => "detached",
        "child_log_path" => Path.join(ws, "detached.ndjson"),
        "next_actions" => []
      }

      # The most common real-world shape: the runtime that owned the child
      # died, the child shows detached after restart, and its Log carries the
      # transport death — guided resume must reach it too.
      projected = run_child_projection(ws, child, "bounded_write")

      assert projected["recovery"]["kind"] == "resume_suggested"
      assert projected["recovery"]["reason"] =~ "websocket_read_failed"
      assert is_binary(projected["resume_command"])
      assert projected["diagnose_command"] =~ "pixir diagnose session #{child_session_id}"
      assert Enum.any?(projected["recovery"]["notes"], &(&1 =~ "lease"))
    end)
  end

  test "non-transport child failure keeps the existing recovery shape" do
    with_pixir_home("pixir-delegate-nontransport-home", fn ->
      ws = tmp_workspace("pixir-delegate-nontransport")
      child_session_id = "20260710T000003-nontransport"

      write_raw_session_log(ws, child_session_id, [
        raw_event(child_session_id, 1, "turn_failed", %{
          "terminal_status" => "tool_error",
          "error_kind" => "invalid_args",
          "error_message" => "invalid task"
        })
      ])

      child = %{
        "id" => "subagent_nontransport",
        "child_session_id" => child_session_id,
        "agent" => "explorer",
        "status" => "failed",
        "summary" => "invalid task",
        "task" => "inspect notes",
        "workspace_mode" => "shared",
        "workspace" => ws,
        "permission_mode" => "read_only",
        "reason" => "tool_error",
        "child_log_path" => Path.join(ws, "nontransport.ndjson"),
        "next_actions" => []
      }

      projected = run_child_projection(ws, child, "read_only")

      refute Map.has_key?(projected, "recovery")
      assert projected["resume_command"] =~ "pixir resume #{child_session_id}"
      assert projected["diagnose_command"] =~ "pixir diagnose session #{child_session_id}"
    end)
  end

  test "completed child stays untouched even with stale transport evidence" do
    with_pixir_home("pixir-delegate-completed-home", fn ->
      ws = tmp_workspace("pixir-delegate-completed")
      child_session_id = "20260710T000004-completed"

      # The stale evidence rides the child Log — the source the projection
      # actually reads when results collapse the reason — not an inline field.
      write_raw_session_log(ws, child_session_id, [
        raw_event(child_session_id, 1, "turn_failed", %{
          "terminal_status" => "provider_error",
          "error_kind" => "websocket_read_failed",
          "error_message" => "stale transport event from an earlier attempt",
          "details" => %{"reason" => ":closed"}
        })
      ])

      child = %{
        "id" => "subagent_completed",
        "child_session_id" => child_session_id,
        "agent" => "explorer",
        "status" => "completed",
        "summary" => "done",
        "task" => "inspect notes",
        "workspace_mode" => "shared",
        "permission_mode" => "read_only",
        "child_log_path" => Path.join(ws, "completed.ndjson"),
        "next_actions" => []
      }

      projected = run_child_projection(ws, child, "read_only")

      refute Map.has_key?(projected, "recovery")
      refute Map.has_key?(projected, "resume_command")
      refute Map.has_key?(projected, "diagnose_command")
    end)
  end

  test "bounded_write workflow runtime pairs auto permission mode with the write policy" do
    with_pixir_home("pixir-delegate-runner-home", fn ->
      ws = tmp_workspace("pixir-delegate-runner-workflow-write")
      test_pid = self()

      spec = %{
        "contract_version" => 1,
        "strategy" => "workflow",
        "mode" => "bounded_write",
        "write_policy" => %{
          "version" => 1,
          "metadata" => %{"id" => "runner-policy"},
          "allow_writes" => ["notes/out.md"]
        },
        "steps" => [
          %{
            "id" => "write",
            "task" => "write notes",
            "agent" => "worker",
            "workspace_mode" => "shared",
            "write_set" => ["notes/out.md"]
          }
        ]
      }

      spec_meta = %{
        "strategy" => "workflow",
        "mode" => "bounded_write",
        "write_policy" => %{
          "version" => 1,
          "id" => "runner-policy",
          "allow_writes" => ["notes/out.md"],
          "deny_writes" => [".pixir/**", ".git/**", "**/.env*", "**/secrets/**"],
          "bash" => "disabled"
        },
        "planned_child_count" => 1
      }

      workflow_runner = fn parent_session_id, workflow_spec, opts ->
        send(test_pid, {:workflow_runner_called, parent_session_id, workflow_spec, opts})

        {:ok,
         %{
           "ok" => true,
           "status" => "completed",
           "workflow_id" => "wf_runner_test",
           "steps" => [],
           "summary" => %{"steps" => 0}
         }}
      end

      assert {:ok, %{"status" => "completed", "mode" => "bounded_write"}} =
               Runner.run(%{workspace: ws}, spec, spec_meta, workflow_runner: workflow_runner)

      assert_received {:workflow_runner_called, _parent_session_id, workflow_spec, opts}

      assert Keyword.fetch!(opts, :permission_mode) == :auto
      assert Keyword.fetch!(opts, :write_policy)["id"] == "runner-policy"
      assert Keyword.fetch!(opts, :write_policy)["allow_writes"] == ["notes/out.md"]
      assert get_in(workflow_spec, ["steps", Access.at(0), "write_set"]) == ["notes/out.md"]
    end)
  end

  test "bounded_write workflow failed writer does not report repo mutation success" do
    with_pixir_home("pixir-delegate-runner-home", fn ->
      ws = tmp_workspace("pixir-delegate-runner-workflow-failed-write")
      test_pid = self()

      spec = %{
        "contract_version" => 1,
        "strategy" => "workflow",
        "mode" => "bounded_write",
        "write_policy" => %{
          "version" => 1,
          "metadata" => %{"id" => "runner-policy"},
          "allow_writes" => ["notes/out.md"]
        },
        "steps" => [
          %{
            "id" => "write",
            "task" => "write notes",
            "agent" => "worker",
            "workspace_mode" => "shared",
            "write_set" => ["notes/out.md"]
          }
        ]
      }

      spec_meta = %{
        "strategy" => "workflow",
        "mode" => "bounded_write",
        "write_policy" => %{
          "version" => 1,
          "id" => "runner-policy",
          "allow_writes" => ["notes/out.md"],
          "deny_writes" => [".pixir/**", ".git/**", "**/.env*", "**/secrets/**"],
          "bash" => "disabled"
        },
        "planned_child_count" => 1
      }

      workflow_runner = fn parent_session_id, workflow_spec, opts ->
        send(test_pid, {:workflow_runner_called, parent_session_id, workflow_spec, opts})

        {:ok,
         %{
           "ok" => false,
           "status" => "partial",
           "workflow_id" => "wf_runner_failed_write",
           "steps" => [
             %{
               "step_id" => "write",
               "status" => "failed",
               "subagent_status" => "failed",
               "checkpoint_status" => "failed",
               "workspace_mode" => "shared",
               "write_set" => ["notes/out.md"]
             }
           ],
           "summary" => %{"steps" => 1, "failed_steps" => 1},
           "failed_steps" => [
             %{
               "step_id" => "write",
               "status" => "failed",
               "checkpoint_status" => "failed"
             }
           ],
           "safe_next_actions" => ["retry_failed_steps"]
         }}
      end

      assert {:ok, payload} =
               Runner.run(%{workspace: ws}, spec, spec_meta, workflow_runner: workflow_runner)

      assert %{
               "ok" => false,
               "status" => "partial",
               "write_destination" => %{
                 "writes_applied_to" => "indeterminate",
                 "contract_status" => "unverified_partial_writes"
               },
               "children" => [
                 %{
                   "step_id" => "write",
                   "writes_applied_to" => "indeterminate"
                 }
               ]
             } = payload

      refute Map.has_key?(payload["write_destination"], "observed_applied_writes")

      assert_received {:workflow_runner_called, _parent_session_id, workflow_spec, opts}

      assert Keyword.fetch!(opts, :permission_mode) == :auto
      assert Keyword.fetch!(opts, :write_policy)["id"] == "runner-policy"
      assert Keyword.fetch!(opts, :write_policy)["allow_writes"] == ["notes/out.md"]
      assert get_in(workflow_spec, ["steps", Access.at(0), "write_set"]) == ["notes/out.md"]
    end)
  end

  test "bounded_write workflow reports observed partial writes from child log" do
    with_pixir_home("pixir-delegate-runner-home", fn ->
      ws = tmp_workspace("pixir-delegate-runner-observed-write")
      child_session_id = "20260703T000001-child"

      spec = %{
        "contract_version" => 1,
        "strategy" => "workflow",
        "mode" => "bounded_write",
        "write_policy" => %{
          "version" => 1,
          "metadata" => %{"id" => "runner-policy"},
          "allow_writes" => ["notes/out.md"]
        },
        "steps" => [
          %{
            "id" => "write",
            "task" => "write notes then try forbidden write",
            "agent" => "worker",
            "workspace_mode" => "shared",
            "write_set" => ["notes/out.md"]
          }
        ]
      }

      spec_meta = %{
        "strategy" => "workflow",
        "mode" => "bounded_write",
        "write_policy" => %{
          "version" => 1,
          "id" => "runner-policy",
          "allow_writes" => ["notes/out.md"],
          "deny_writes" => [".pixir/**", ".git/**", "**/.env*", "**/secrets/**"],
          "bash" => "disabled"
        },
        "planned_child_count" => 1
      }

      workflow_runner = fn _parent_session_id, _workflow_spec, _opts ->
        write_raw_session_log(ws, child_session_id, [
          raw_event(child_session_id, 1, "tool_call", %{
            "call_id" => "write-ok",
            "name" => "write",
            "args" => %{"path" => "notes/out.md", "content" => "ok"}
          }),
          raw_event(child_session_id, 2, "tool_result", %{
            "call_id" => "write-ok",
            "ok" => true,
            "output" => "wrote 2 bytes to notes/out.md"
          }),
          raw_event(child_session_id, 3, "tool_call", %{
            "call_id" => "write-denied",
            "name" => "write",
            "args" => %{"path" => "secrets/out.md", "content" => "nope"}
          }),
          raw_event(child_session_id, 4, "tool_result", %{
            "call_id" => "write-denied",
            "ok" => false,
            "error" => %{"kind" => "write_policy_denied"}
          })
        ])

        {:ok,
         %{
           "ok" => false,
           "status" => "partial",
           "workflow_id" => "wf_observed_partial_write",
           "steps" => [
             %{
               "step_id" => "write",
               "child_session_id" => child_session_id,
               "status" => "failed",
               "subagent_status" => "failed",
               "checkpoint_status" => "failed",
               "workspace_mode" => "shared",
               "write_set" => ["notes/out.md"]
             }
           ],
           "summary" => %{"steps" => 1, "failed_steps" => 1},
           "safe_next_actions" => ["retry_failed_steps"]
         }}
      end

      assert {:ok, payload} =
               Runner.run(%{workspace: ws}, spec, spec_meta, workflow_runner: workflow_runner)

      assert %{
               "writes_applied_to" => "indeterminate",
               "contract_status" => "unverified_partial_writes",
               "observed_applied_writes" => ["notes/out.md"],
               "observed_writes_source" => "child_log",
               "observed_writes_semantics" => "at_least"
             } = payload["write_destination"]

      assert [
               %{
                 "writes_applied_to" => "indeterminate",
                 "observed_applied_writes" => ["notes/out.md"],
                 "observed_writes_source" => "child_log",
                 "observed_writes_semantics" => "at_least"
               }
             ] = payload["children"]
    end)
  end

  test "subagents transport is accepted and surfaced in runtime limits" do
    with_pixir_home("pixir-delegate-runner-home", fn ->
      ws = tmp_workspace("pixir-delegate-runner-transport")
      test_pid = self()

      spec = %{
        "contract_version" => 1,
        "strategy" => "subagents",
        "task" => "inspect transport",
        "subagents" => %{"transport" => "websocket"}
      }

      spec_meta = %{"strategy" => "subagents", "planned_child_count" => 1}

      spawn_agent = fn parent_session_id, args, opts ->
        send(test_pid, {:spawn_agent_called, parent_session_id, args, opts})

        {:ok,
         %{
           "id" => "subagent_1",
           "agent" => args["agent"] || args[:agent],
           "status" => "queued",
           "summary" => "queued"
         }}
      end

      assert {:ok, payload} =
               Runner.start(%{workspace: ws}, spec, spec_meta, spawn_agent: spawn_agent)

      assert payload.runtime.provider_transport == "websocket"
      assert get_in(payload.payload, ["limits", "transport"]) == "websocket"
      assert_received {:spawn_agent_called, _parent_session_id, _args, opts}
      assert Keyword.fetch!(opts, :provider_transport) == "websocket"
    end)
  end

  test "virtual_overlay spec context threads to child spawn opts" do
    with_pixir_home("pixir-delegate-runner-home", fn ->
      ws = tmp_workspace("pixir-delegate-runner-virtual-overlay")
      test_pid = self()

      spec = %{
        "contract_version" => 1,
        "strategy" => "subagents",
        "task" => "produce a virtual diff",
        "mode" => "read_only",
        "subagents" => %{
          "workspace_mode" => "virtual_overlay",
          "read_set" => ["mix.exs"],
          "limits" => %{"max_virtual_commands" => 2}
        }
      }

      spec_meta = %{"strategy" => "subagents", "planned_child_count" => 1}

      spawn_agent = fn parent_session_id, args, opts ->
        send(test_pid, {:virtual_spawn_called, parent_session_id, args, opts})

        {:ok,
         %{
           "id" => "subagent_virtual",
           "agent" => "explorer",
           "status" => "queued",
           "summary" => "queued",
           "workspace_mode" => "virtual_overlay"
         }}
      end

      assert {:ok, _payload} =
               Runner.start(%{workspace: ws}, spec, spec_meta, spawn_agent: spawn_agent)

      assert_received {:virtual_spawn_called, _parent_session_id, args, opts}
      assert args["workspace_mode"] == "virtual_overlay"

      assert Keyword.fetch!(opts, :virtual_overlay) == %{
               read_set: ["mix.exs"],
               limits: %{"max_virtual_commands" => 2}
             }

      assert Keyword.fetch!(opts, :permission_mode) == :read_only
      assert Keyword.fetch!(opts, :write_policy) == nil
    end)
  end

  test "virtual child result projects artifact and explicit apply affordance" do
    with_pixir_home("pixir-delegate-runner-home", fn ->
      ws = tmp_workspace("pixir-delegate-runner-virtual-envelope")

      artifact = %{
        "kind" => "virtual_diff",
        "version" => 1,
        "changes" => [],
        "summary" => %{"diff_bytes" => 0},
        "apply" => %{"status" => "not_applied", "requires_explicit_apply" => true}
      }

      child = %{
        "id" => "subagent_virtual",
        "child_session_id" => "child-session",
        "agent" => "explorer",
        "status" => "completed",
        "summary" => "done",
        "task" => "produce a virtual diff",
        "workspace_mode" => "virtual_overlay",
        "child_log_path" => Path.join(ws, "child.ndjson"),
        "next_actions" => [],
        "virtual_diff" => artifact,
        "virtual_diff_ref" => %{"kind" => "virtual_diff", "encoded_bytes" => 100}
      }

      spec = %{
        "contract_version" => 1,
        "strategy" => "subagents",
        "task" => "produce a virtual diff",
        "subagents" => %{
          "workspace_mode" => "virtual_overlay",
          "read_set" => ["mix.exs"]
        }
      }

      spawn_agent = fn _parent_session_id, _args, _opts -> {:ok, child} end

      wait_outcome = fn _parent_session_id, _ids, _timeout_ms, _opts ->
        {:ok,
         %{
           "status" => "completed",
           "complete" => true,
           "counts" => %{
             "completed" => 1,
             "failed" => 0,
             "timed_out" => 0,
             "cancelled" => 0,
             "detached" => 0,
             "incomplete" => 0
           },
           "subagents" => [child],
           "summary" => "completed"
         }}
      end

      assert {:ok, %{"children" => [projected]}} =
               Runner.run(
                 %{workspace: ws},
                 spec,
                 %{"strategy" => "subagents", "planned_child_count" => 1},
                 spawn_agent: spawn_agent,
                 wait_outcome: wait_outcome
               )

      assert projected["virtual_diff"] == artifact

      assert projected["apply"] == %{
               "status" => "not_applied",
               "requires_explicit_apply" => true,
               "tool" => "apply_virtual_diff",
               "dry_run_default" => true,
               "workflow_apply_from_compatible" => false
             }
    end)
  end

  test "failed virtual child projects preserved artifact and strategy-aware recovery" do
    with_pixir_home("pixir-delegate-runner-home", fn ->
      ws = tmp_workspace("pixir-delegate-runner-failed-virtual-envelope")

      artifact = %{
        "kind" => "virtual_diff",
        "version" => 1,
        "changes" => [],
        "summary" => %{"diff_bytes" => 0},
        "apply" => %{"status" => "not_applied", "requires_explicit_apply" => true}
      }

      ref = %{"kind" => "virtual_diff", "encoded_bytes" => 100, "source_seq" => 4}

      child = %{
        "id" => "subagent_virtual_failed",
        "child_session_id" => "failed-child-session",
        "agent" => "explorer",
        "status" => "failed",
        "summary" => "provider transport failed after artifact export",
        "task" => "produce then fail",
        "workspace_mode" => "virtual_overlay",
        "child_log_path" => Path.join(ws, "failed-child.ndjson"),
        "next_actions" => ["inspect_child_session_log"],
        "virtual_diff" => artifact,
        "virtual_diff_ref" => ref
      }

      spec = %{
        "contract_version" => 1,
        "strategy" => "subagents",
        "task" => "produce then fail",
        "subagents" => %{
          "workspace_mode" => "virtual_overlay",
          "read_set" => ["mix.exs"]
        }
      }

      spawn_agent = fn _parent_session_id, _args, _opts -> {:ok, child} end

      wait_outcome = fn _parent_session_id, _ids, _timeout_ms, _opts ->
        {:ok,
         %{
           "status" => "partial",
           "complete" => false,
           "counts" => %{"completed" => 0, "failed" => 1},
           "subagents" => [child],
           "summary" => "failed"
         }}
      end

      assert {:ok, %{"children" => [projected]}} =
               Runner.run(
                 %{workspace: ws},
                 spec,
                 %{"strategy" => "subagents", "planned_child_count" => 1},
                 spawn_agent: spawn_agent,
                 wait_outcome: wait_outcome
               )

      assert projected["status"] == "failed"
      assert projected["virtual_diff"] == artifact
      assert projected["virtual_diff_ref"] == ref
      assert projected["apply"]["tool"] == "apply_virtual_diff"
      assert projected["recovery"]["virtual_diff_preserved"] == true
      assert projected["recovery"]["virtual_diff_ref"] == ref
      assert projected["recovery"]["apply_is_separate_explicit_decision"] == true

      assert Enum.any?(projected["recovery"]["notes"], &String.contains?(&1, "no longer exists"))

      assert Enum.any?(
               projected["recovery"]["notes"],
               &String.contains?(&1, "Inspect the child Log")
             )
    end)
  end

  test "non-virtual child result does not gain virtual artifact keys" do
    with_pixir_home("pixir-delegate-runner-home", fn ->
      ws = tmp_workspace("pixir-delegate-runner-shared-envelope")

      child = %{
        "id" => "subagent_shared",
        "child_session_id" => "child-session",
        "agent" => "explorer",
        "status" => "completed",
        "summary" => "done",
        "task" => "inspect",
        "workspace_mode" => "shared",
        "child_log_path" => Path.join(ws, "child.ndjson"),
        "next_actions" => []
      }

      spawn_agent = fn _parent_session_id, _args, _opts -> {:ok, child} end

      wait_outcome = fn _parent_session_id, _ids, _timeout_ms, _opts ->
        {:ok,
         %{
           "status" => "completed",
           "counts" => %{"completed" => 1},
           "subagents" => [child],
           "summary" => "completed"
         }}
      end

      assert {:ok, %{"children" => [projected]}} =
               Runner.run(
                 %{workspace: ws},
                 %{"strategy" => "subagents", "task" => "inspect"},
                 %{"strategy" => "subagents", "planned_child_count" => 1},
                 spawn_agent: spawn_agent,
                 wait_outcome: wait_outcome
               )

      refute Map.has_key?(projected, "virtual_diff")
      refute Map.has_key?(projected, "virtual_diff_ref")
      refute Map.has_key?(projected, "apply")
    end)
  end

  test "subagent provider knobs are threaded to child spawn args and opts" do
    with_pixir_home("pixir-delegate-runner-home", fn ->
      ws = tmp_workspace("pixir-delegate-runner-provider-knobs")
      test_pid = self()

      spec = %{
        "contract_version" => 1,
        "strategy" => "subagents",
        "task" => "inspect model knobs",
        "subagents" => %{"model" => "gpt-5.5", "reasoning_effort" => "high"}
      }

      spec_meta = %{"strategy" => "subagents", "planned_child_count" => 1}

      spawn_agent = fn parent_session_id, args, opts ->
        send(test_pid, {:spawn_agent_called, parent_session_id, args, opts})

        {:ok,
         %{
           "id" => "subagent_1",
           "agent" => args["agent"] || args[:agent],
           "status" => "queued",
           "summary" => "queued"
         }}
      end

      assert {:ok, _payload} =
               Runner.start(%{workspace: ws}, spec, spec_meta, spawn_agent: spawn_agent)

      assert_received {:spawn_agent_called, _parent_session_id, args, _opts}
      assert args["model"] == "gpt-5.5"
      assert args["reasoning_effort"] == "high"
    end)
  end

  test "subagents web_search threads from spec to child spawn args" do
    with_pixir_home("pixir-delegate-runner-home", fn ->
      ws = tmp_workspace("pixir-delegate-runner-web-search")
      test_pid = self()

      spec = %{
        "contract_version" => 1,
        "strategy" => "subagents",
        "task" => "inspect web_search knob",
        "subagents" => %{"web_search" => true}
      }

      spec_meta = %{"strategy" => "subagents", "planned_child_count" => 1}

      spawn_agent = fn parent_session_id, args, opts ->
        send(test_pid, {:spawn_agent_called, parent_session_id, args, opts})

        {:ok,
         %{
           "id" => "subagent_1",
           "agent" => args["agent"] || args[:agent],
           "status" => "queued",
           "summary" => "queued"
         }}
      end

      assert {:ok, _payload} =
               Runner.start(%{workspace: ws}, spec, spec_meta, spawn_agent: spawn_agent)

      assert_received {:spawn_agent_called, _parent_session_id, args, _opts}
      assert args["web_search"] == true

      # Absent knob stays absent: no implicit enablement in the spawn args.
      spec_off = Map.delete(spec, "subagents")

      assert {:ok, _payload} =
               Runner.start(%{workspace: ws}, spec_off, spec_meta, spawn_agent: spawn_agent)

      assert_received {:spawn_agent_called, _parent_session_id, args_off, _opts}
      refute Map.has_key?(args_off, "web_search")
    end)
  end

  test "subagent task object attachments are normalized into child spawn args" do
    with_pixir_home("pixir-delegate-runner-home", fn ->
      ws = tmp_workspace("pixir-delegate-runner-attachments")
      File.write!(Path.join(ws, "note.txt"), "evidence")
      test_pid = self()

      spec = %{
        "contract_version" => 1,
        "strategy" => "subagents",
        "tasks" => [%{"task" => "inspect note", "attachments" => ["note.txt"]}]
      }

      spec_meta = %{"strategy" => "subagents", "planned_child_count" => 1}

      spawn_agent = fn parent_session_id, args, opts ->
        send(test_pid, {:spawn_agent_called, parent_session_id, args, opts})

        {:ok,
         %{
           "id" => "subagent_1",
           "agent" => args["agent"] || args[:agent],
           "status" => "queued",
           "summary" => "queued"
         }}
      end

      assert {:ok, payload} =
               Runner.start(%{workspace: ws}, spec, spec_meta, spawn_agent: spawn_agent)

      refute Map.has_key?(payload.payload, "attachments")

      refute Enum.any?(Map.get(payload.payload, "children", []), fn child ->
               Map.has_key?(child, "attachments") or Map.has_key?(child, "uris") or
                 Map.has_key?(child, "uri")
             end)

      assert_received {:spawn_agent_called, _parent_session_id, args, _opts}

      assert [%{"type" => "resource_link", "uri" => uri, "name" => "note.txt"}] =
               args["attachments"]

      # Plain path: the encoded URI must equal the literal file:// form.
      assert uri == "file://" <> Path.join(ws, "note.txt")
    end)
  end

  test "attachments outside the workspace are accepted as operator-supplied (ADR 0021)" do
    with_pixir_home("pixir-delegate-runner-home", fn ->
      ws = tmp_workspace("pixir-delegate-runner-outside")
      outside = tmp_workspace("pixir-delegate-runner-outside-src")
      File.write!(Path.join(outside, "external.txt"), "outside evidence")
      test_pid = self()

      spec = %{
        "contract_version" => 1,
        "strategy" => "subagents",
        "tasks" => [
          %{"task" => "read external", "attachments" => [Path.join(outside, "external.txt")]}
        ]
      }

      spec_meta = %{"strategy" => "subagents", "planned_child_count" => 1}

      spawn_agent = fn parent_session_id, args, opts ->
        send(test_pid, {:spawn_agent_called, parent_session_id, args, opts})

        {:ok,
         %{
           "id" => "subagent_1",
           "agent" => args["agent"] || args[:agent],
           "status" => "queued",
           "summary" => "queued"
         }}
      end

      # ADR 0021: operator-supplied file:// links are deliberately exempt from
      # workspace read confinement (the spec author is the operator; the
      # model-authored channel is closed by the spawn_agent strip). This test
      # pins that decision so it cannot be re-read as an oversight.
      assert {:ok, _payload} =
               Runner.start(%{workspace: ws}, spec, spec_meta, spawn_agent: spawn_agent)

      assert_received {:spawn_agent_called, _parent_session_id, args, _opts}

      assert [%{"type" => "resource_link", "uri" => uri}] = args["attachments"]
      assert uri == "file://" <> Path.join(outside, "external.txt")
    end)
  end

  test "subagent task object attachments reject invalid shapes" do
    ws = tmp_workspace("pixir-delegate-runner-bad-attachments")
    spec_meta = %{"strategy" => "subagents", "planned_child_count" => 1}

    cases = [
      {%{"task" => "valid", "unexpected" => true}, "/tasks/0"},
      {%{"task" => 123, "extra" => true}, "/tasks/0"},
      {%{"task" => "valid", "attachments" => nil}, "/tasks/0/attachments"},
      {%{"task" => "valid", "attachments" => "note.txt"}, "/tasks/0/attachments"},
      {%{"task" => "valid", "attachments" => [""]}, "/tasks/0/attachments/0"},
      {%{"task" => "valid", "attachments" => [123]}, "/tasks/0/attachments/0"},
      {%{"task" => "valid", "attachments" => ["file://evidence.txt"]}, "/tasks/0/attachments/0"}
    ]

    for {entry, pointer} <- cases do
      spec = %{
        "contract_version" => 1,
        "strategy" => "subagents",
        "tasks" => [entry]
      }

      assert {:error, error} = Runner.start(%{workspace: ws}, spec, spec_meta)
      assert error["kind"] == "invalid_spec"
      assert error["details"]["json_pointer"] == pointer
    end
  end

  test "subagents transport rejects unsupported values" do
    ws = tmp_workspace("pixir-delegate-runner-bad-transport")

    spec = %{
      "contract_version" => 1,
      "strategy" => "subagents",
      "task" => "inspect transport",
      "subagents" => %{"transport" => "stdio"}
    }

    spec_meta = %{"strategy" => "subagents", "planned_child_count" => 1}

    assert {:error, error} = Runner.start(%{workspace: ws}, spec, spec_meta)
    assert error["kind"] == "invalid_spec"
    assert error["details"]["field"] == "subagents.transport"
    assert error["details"]["accepted_values"] == ["auto", "websocket", "http_sse"]
  end

  test "subagents model rejects non-string values" do
    ws = tmp_workspace("pixir-delegate-runner-bad-model")

    spec = %{
      "contract_version" => 1,
      "strategy" => "subagents",
      "task" => "inspect model",
      "subagents" => %{"model" => 123}
    }

    spec_meta = %{"strategy" => "subagents", "planned_child_count" => 1}

    assert {:error, error} = Runner.start(%{workspace: ws}, spec, spec_meta)
    assert error["kind"] == "invalid_spec"
    assert error["details"]["field"] == "subagents.model"
  end

  test "subagents reasoning_effort rejects unsupported values" do
    ws = tmp_workspace("pixir-delegate-runner-bad-effort")

    spec = %{
      "contract_version" => 1,
      "strategy" => "subagents",
      "task" => "inspect effort",
      "subagents" => %{"reasoning_effort" => "ultra"}
    }

    spec_meta = %{"strategy" => "subagents", "planned_child_count" => 1}

    assert {:error, error} = Runner.start(%{workspace: ws}, spec, spec_meta)
    assert error["kind"] == "invalid_spec"
    assert error["details"]["field"] == "subagents.reasoning_effort"
    assert error["details"]["accepted_values"] == ["low", "medium", "high", "xhigh"]
  end

  test "bounded_write workflow does not infer observed writes from corrupt child log" do
    with_pixir_home("pixir-delegate-runner-home", fn ->
      ws = tmp_workspace("pixir-delegate-runner-corrupt-child-log")
      child_session_id = "20260703T000002-child"

      spec = %{
        "contract_version" => 1,
        "strategy" => "workflow",
        "mode" => "bounded_write",
        "write_policy" => %{
          "version" => 1,
          "metadata" => %{"id" => "runner-policy"},
          "allow_writes" => ["notes/out.md"]
        },
        "steps" => [
          %{
            "id" => "write",
            "task" => "write notes then produce corrupt evidence",
            "agent" => "worker",
            "workspace_mode" => "shared",
            "write_set" => ["notes/out.md"]
          }
        ]
      }

      spec_meta = %{
        "strategy" => "workflow",
        "mode" => "bounded_write",
        "write_policy" => %{
          "version" => 1,
          "id" => "runner-policy",
          "allow_writes" => ["notes/out.md"],
          "deny_writes" => [".pixir/**", ".git/**", "**/.env*", "**/secrets/**"],
          "bash" => "disabled"
        },
        "planned_child_count" => 1
      }

      workflow_runner = fn _parent_session_id, _workflow_spec, _opts ->
        write_corrupt_session_log(ws, child_session_id, [
          raw_event(child_session_id, 1, "tool_call", %{
            "call_id" => "write-ok",
            "name" => "write",
            "args" => %{"path" => "notes/out.md", "content" => "ok"}
          }),
          raw_event(child_session_id, 2, "tool_result", %{
            "call_id" => "write-ok",
            "ok" => true,
            "output" => "wrote 2 bytes to notes/out.md"
          })
        ])

        {:ok,
         %{
           "ok" => false,
           "status" => "partial",
           "workflow_id" => "wf_corrupt_child_log",
           "steps" => [
             %{
               "step_id" => "write",
               "child_session_id" => child_session_id,
               "status" => "failed",
               "subagent_status" => "failed",
               "checkpoint_status" => "failed",
               "workspace_mode" => "shared",
               "write_set" => ["notes/out.md"]
             }
           ],
           "summary" => %{"steps" => 1, "failed_steps" => 1},
           "safe_next_actions" => ["inspect_delegate_diagnostics"]
         }}
      end

      assert {:ok, payload} =
               Runner.run(%{workspace: ws}, spec, spec_meta, workflow_runner: workflow_runner)

      assert %{
               "writes_applied_to" => "indeterminate",
               "contract_status" => "unverified_partial_writes"
             } = payload["write_destination"]

      refute Map.has_key?(payload["write_destination"], "observed_applied_writes")
      refute Map.has_key?(hd(payload["children"]), "observed_applied_writes")
    end)
  end

  test "subagent runtime assigns task indexes to spawned children and envelopes" do
    with_pixir_home("pixir-delegate-runner-home", fn ->
      ws = tmp_workspace("pixir-delegate-runner-indexes")
      test_pid = self()

      spec = %{
        "contract_version" => 1,
        "strategy" => "subagents",
        "tasks" => ["alpha", "beta"]
      }

      spec_meta = %{"strategy" => "subagents", "planned_child_count" => 2}

      spawn_agent = fn _parent_session_id, args, opts ->
        index = Keyword.get(opts, :index)
        send(test_pid, {:spawn_args, args, index})

        {:ok,
         %{
           "id" => "subagent_#{index}",
           "index" => index,
           "agent" => args["agent"],
           "task" => args["task"],
           "status" => "completed",
           "summary" => "done",
           "child_session_id" => "child-#{index}"
         }}
      end

      wait_outcome = fn _parent_session_id, _ids, _timeout_ms, _opts ->
        {:ok,
         %{
           "status" => "completed",
           "summary" => "done",
           "counts" => %{"completed" => 2},
           "subagents" => [
             %{
               "id" => "subagent_0",
               "index" => 0,
               "agent" => "default",
               "task" => "alpha",
               "status" => "completed",
               "summary" => "done",
               "child_session_id" => "child-0"
             },
             %{
               "id" => "subagent_1",
               "index" => 1,
               "agent" => "default",
               "task" => "beta",
               "status" => "completed",
               "summary" => "done",
               "child_session_id" => "child-1"
             }
           ]
         }}
      end

      assert {:ok, payload} =
               Runner.run(%{workspace: ws}, spec, spec_meta,
                 spawn_agent: spawn_agent,
                 wait_outcome: wait_outcome
               )

      assert_received {:spawn_args, %{"task" => "alpha"} = alpha_args, 0}
      assert_received {:spawn_args, %{"task" => "beta"} = beta_args, 1}
      refute Map.has_key?(alpha_args, "index")
      refute Map.has_key?(beta_args, "index")
      assert Enum.map(payload["children"], & &1["index"]) == [0, 1]
    end)
  end

  test "partial spawn preserves indexes for children already spawned" do
    with_pixir_home("pixir-delegate-runner-home", fn ->
      ws = tmp_workspace("pixir-delegate-runner-partial-indexes")

      spec = %{
        "contract_version" => 1,
        "strategy" => "subagents",
        "tasks" => ["first", "second"]
      }

      spec_meta = %{"strategy" => "subagents", "planned_child_count" => 2}

      spawn_agent = fn
        _parent_session_id, %{"task" => "first"} = args, opts ->
          assert Keyword.get(opts, :index) == 0

          {:ok,
           %{
             "id" => "subagent_0",
             "index" => Keyword.get(opts, :index),
             "agent" => args["agent"],
             "task" => args["task"],
             "status" => "running",
             "summary" => "running",
             "child_session_id" => "child-0"
           }}

        _parent_session_id, %{"task" => "second"}, opts when is_list(opts) ->
          assert Keyword.get(opts, :index) == 1

          # contract-shaped error: normalize_error/1 passes %{"ok" => false}
          # maps through untouched; a bare map would be wrapped as
          # runtime_error and hide the original kind
          {:error,
           %{
             "ok" => false,
             "status" => "rejected",
             "kind" => "spawn_failed",
             "message" => "boom",
             "details" => %{}
           }}
      end

      wait_outcome = fn _parent_session_id, _ids, _timeout_ms, _opts ->
        {:ok,
         %{
           "status" => "incomplete",
           "summary" => "one running",
           "counts" => %{"incomplete" => 1},
           "subagents" => [
             %{
               "id" => "subagent_0",
               "index" => 0,
               "agent" => "default",
               "task" => "first",
               "status" => "running",
               "summary" => "running",
               "child_session_id" => "child-0"
             }
           ]
         }}
      end

      assert {:ok, payload} =
               Runner.run(%{workspace: ws}, spec, spec_meta,
                 spawn_agent: spawn_agent,
                 wait_outcome: wait_outcome
               )

      assert payload["status"] == "partial"
      assert [%{"index" => 0, "task" => "first"}] = payload["children"]
      assert payload["spawn_failure"]["kind"] == "spawn_failed"
    end)
  end

  test "running-at-horizon children keep their task index" do
    with_pixir_home("pixir-delegate-runner-home", fn ->
      ws = tmp_workspace("pixir-delegate-runner-horizon-indexes")

      spec = %{
        "contract_version" => 1,
        "strategy" => "subagents",
        "tasks" => ["keeps running"]
      }

      spec_meta = %{"strategy" => "subagents", "planned_child_count" => 1}

      running = %{
        "id" => "subagent_0",
        "index" => 0,
        "agent" => "worker",
        "task" => "keeps running",
        "status" => "running",
        "summary" => "still running",
        "child_session_id" => "child-running"
      }

      spawn_agent = fn _parent_session_id, _args, _opts -> {:ok, running} end

      wait_outcome = fn _parent_session_id, _ids, _timeout_ms, _opts ->
        {:ok,
         %{
           "status" => "incomplete",
           "summary" => "horizon reached",
           "counts" => %{"incomplete" => 1},
           "subagents" => [running]
         }}
      end

      assert {:ok, payload} =
               Runner.run(%{workspace: ws}, spec, spec_meta,
                 spawn_agent: spawn_agent,
                 wait_outcome: wait_outcome
               )

      assert payload["status"] == "timed_out"
      assert [%{"index" => 0, "status" => "running"}] = payload["children"]
    end)
  end

  test "subagent children without retries keep retry lineage keys omitted" do
    with_pixir_home("pixir-delegate-runner-home", fn ->
      ws = tmp_workspace("pixir-delegate-runner-no-retry-lineage")

      spec = %{
        "contract_version" => 1,
        "strategy" => "subagents",
        "task" => "no retry child"
      }

      spec_meta = %{"strategy" => "subagents", "planned_child_count" => 1}

      agent = %{
        "id" => "subagent_1",
        "agent" => "worker",
        "status" => "completed",
        "summary" => "done",
        "child_session_id" => "20260706T000000-child"
      }

      spawn_agent = fn _parent_session_id, _args, _opts -> {:ok, agent} end

      assert {:ok, payload} =
               Runner.start(%{workspace: ws}, spec, spec_meta, spawn_agent: spawn_agent)

      assert [child] = payload.payload["children"]
      refute Map.has_key?(child, "retry_attempts")
      refute Map.has_key?(child, "retry_max_attempts")
      refute Map.has_key?(child, "current_attempt_index")
      refute Map.has_key?(child, "retry_history")
      refute Map.has_key?(child, "resume_command")
      refute Map.has_key?(child, "diagnose_command")
    end)
  end

  test "non-completed terminal children carry ready-made recovery commands" do
    with_pixir_home("pixir-delegate-runner-home", fn ->
      ws = tmp_workspace("pixir-delegate-runner-child-recovery")

      spec = %{
        "contract_version" => 1,
        "strategy" => "subagents",
        "tasks" => ["times out", "fails", "completes", "still running"]
      }

      spec_meta = %{"strategy" => "subagents", "planned_child_count" => 4}

      agents = %{
        "times out" => %{
          "id" => "subagent_1",
          "agent" => "worker",
          "status" => "timed_out",
          "summary" => "",
          "child_session_id" => "20260706T000000-timeout"
        },
        "fails" => %{
          "id" => "subagent_2",
          "agent" => "worker",
          "status" => "failed",
          "summary" => "",
          "child_session_id" => "20260706T000000-failed"
        },
        "completes" => %{
          "id" => "subagent_3",
          "agent" => "worker",
          "status" => "completed",
          "summary" => "done",
          "child_session_id" => "20260706T000000-done"
        },
        "still running" => %{
          "id" => "subagent_4",
          "agent" => "worker",
          "status" => "running",
          "summary" => "",
          "child_session_id" => "20260706T000000-running"
        }
      }

      spawn_agent = fn _parent_session_id, args, _opts ->
        {:ok, Map.fetch!(agents, args["task"])}
      end

      assert {:ok, payload} =
               Runner.start(%{workspace: ws}, spec, spec_meta, spawn_agent: spawn_agent)

      children = payload.payload["children"]
      by_sid = Map.new(children, &{&1["child_session_id"], &1})

      timed_out = by_sid["20260706T000000-timeout"]

      assert timed_out["resume_command"] ==
               ~s(pixir resume 20260706T000000-timeout ) <>
                 ~s("Continue from the latest incomplete turn. Inspect the Log first, ) <>
                 ~s(avoid duplicating completed writes, and report what you resumed.")

      assert timed_out["diagnose_command"] ==
               "pixir diagnose session 20260706T000000-timeout --json"

      failed = by_sid["20260706T000000-failed"]

      assert failed["resume_command"] ==
               ~s(pixir resume 20260706T000000-failed ) <>
                 ~s("Continue from the latest incomplete turn. Inspect the Log first, ) <>
                 ~s(avoid duplicating completed writes, and report what you resumed.")

      assert failed["diagnose_command"] ==
               "pixir diagnose session 20260706T000000-failed --json"

      # This is a start snapshot (kind delegate_start): a running child here is
      # alive and owned, so it must NOT carry recovery commands. The final
      # delegate_result envelope is where running-at-collection-horizon children
      # gain them (functional coverage: the forced-partial dogfood run).
      running = by_sid["20260706T000000-running"]
      refute Map.has_key?(running, "resume_command")
      refute Map.has_key?(running, "diagnose_command")

      completed = by_sid["20260706T000000-done"]
      refute Map.has_key?(completed, "resume_command")
      refute Map.has_key?(completed, "diagnose_command")
    end)
  end

  @safe_resume_prompt "Continue from the latest incomplete turn. Inspect the Log first, " <>
                        "avoid duplicating completed writes, and report what you resumed."

  test "final delegate_result gives recovery commands to children cut off at the horizon" do
    with_pixir_home("pixir-delegate-runner-home", fn ->
      ws = tmp_workspace("pixir-delegate-runner-horizon-recovery")

      spec = %{
        "contract_version" => 1,
        "strategy" => "subagents",
        "tasks" => ["keeps running", "gets cancelled", "completes"]
      }

      spec_meta = %{"strategy" => "subagents", "planned_child_count" => 3}

      running_with_retry = %{
        "id" => "subagent_1",
        "agent" => "worker",
        "status" => "running",
        "summary" => "",
        "child_session_id" => "20260706T000001-running",
        "retry_attempts" => 1,
        "retry_max_attempts" => 1,
        "current_attempt_index" => 1,
        "retry_history" => [
          %{"attempt_index" => 0, "error_kind" => "websocket_read_failed"}
        ]
      }

      cancelled = %{
        "id" => "subagent_2",
        "agent" => "worker",
        "status" => "cancelled",
        "summary" => "",
        "child_session_id" => "20260706T000001-cancelled"
      }

      completed = %{
        "id" => "subagent_3",
        "agent" => "worker",
        "status" => "completed",
        "summary" => "done",
        "child_session_id" => "20260706T000001-done"
      }

      agents = %{
        "keeps running" => running_with_retry,
        "gets cancelled" => cancelled,
        "completes" => completed
      }

      spawn_agent = fn _parent_session_id, args, _opts ->
        {:ok, Map.fetch!(agents, args["task"])}
      end

      wait_outcome = fn _parent_session_id, _ids, _timeout_ms, _opts ->
        {:ok,
         %{
           "status" => "incomplete",
           "summary" => "horizon reached",
           "counts" => %{"completed" => 1, "cancelled" => 1},
           "subagents" => [running_with_retry, cancelled, completed]
         }}
      end

      assert {:ok, payload} =
               Runner.run(%{workspace: ws}, spec, spec_meta,
                 spawn_agent: spawn_agent,
                 wait_outcome: wait_outcome
               )

      # work_complete is stamped later by CLIContract; at Runner level the
      # incomplete outcome shows as status timed_out with ok false.
      assert payload["kind"] == "delegate_result"
      assert payload["ok"] == false
      assert payload["status"] == "timed_out"

      by_sid = Map.new(payload["children"], &{&1["child_session_id"], &1})

      running = by_sid["20260706T000001-running"]

      assert running["resume_command"] ==
               ~s(pixir resume 20260706T000001-running "#{@safe_resume_prompt}")

      assert running["diagnose_command"] ==
               "pixir diagnose session 20260706T000001-running --json"

      # Retry lineage and recovery commands coexist on the same child.
      assert running["retry_attempts"] == 1
      assert [%{"error_kind" => "websocket_read_failed"}] = running["retry_history"]

      cancelled_child = by_sid["20260706T000001-cancelled"]

      assert cancelled_child["resume_command"] ==
               ~s(pixir resume 20260706T000001-cancelled "#{@safe_resume_prompt}")

      assert cancelled_child["diagnose_command"] ==
               "pixir diagnose session 20260706T000001-cancelled --json"

      completed_child = by_sid["20260706T000001-done"]
      refute Map.has_key?(completed_child, "resume_command")
      refute Map.has_key?(completed_child, "diagnose_command")
    end)
  end

  test "subagents transport is nil when absent" do
    with_pixir_home("pixir-delegate-runner-home", fn ->
      ws = tmp_workspace("pixir-delegate-runner-no-transport")
      test_pid = self()

      spec = %{
        "contract_version" => 1,
        "strategy" => "subagents",
        "task" => "inspect default transport"
      }

      spec_meta = %{"strategy" => "subagents", "planned_child_count" => 1}

      spawn_agent = fn parent_session_id, args, opts ->
        send(test_pid, {:spawn_agent_called, parent_session_id, args, opts})

        {:ok,
         %{
           "id" => "subagent_1",
           "agent" => args["agent"] || args[:agent],
           "status" => "queued",
           "summary" => "queued"
         }}
      end

      assert {:ok, payload} =
               Runner.start(%{workspace: ws}, spec, spec_meta, spawn_agent: spawn_agent)

      assert get_in(payload, ["limits", "transport"]) == nil
      assert_received {:spawn_agent_called, _parent_session_id, _args, opts}
      refute Keyword.has_key?(opts, :provider_transport)
    end)
  end
end
