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

      spawn_agent = fn _parent_session_id, args, _opts ->
        send(test_pid, {:spawn_args, args})

        {:ok,
         %{
           "id" => "subagent_#{args["index"]}",
           "index" => args["index"],
           "agent" => args["agent"],
           "task" => args["task"],
           "status" => "completed",
           "summary" => "done",
           "child_session_id" => "child-#{args["index"]}"
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

      assert_received {:spawn_args, %{"task" => "alpha", "index" => 0}}
      assert_received {:spawn_args, %{"task" => "beta", "index" => 1}}
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
        _parent_session_id, %{"task" => "first", "index" => 0} = args, _opts ->
          {:ok,
           %{
             "id" => "subagent_0",
             "index" => args["index"],
             "agent" => args["agent"],
             "task" => args["task"],
             "status" => "running",
             "summary" => "running",
             "child_session_id" => "child-0"
           }}

        _parent_session_id, %{"task" => "second", "index" => 1}, _opts ->
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
