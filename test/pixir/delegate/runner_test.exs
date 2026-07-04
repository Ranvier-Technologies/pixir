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
end
