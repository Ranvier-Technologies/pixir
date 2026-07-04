defmodule Pixir.Delegate.CLIContractTest do
  use ExUnit.Case, async: true

  alias Pixir.Delegate.CLIContract

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

  defp assert_step_location(details, field, step_index \\ 0) do
    assert details["field"] == "steps[#{step_index + 1}].#{field}"
    assert details["json_pointer"] == "/steps/#{step_index}/#{field}"
    assert details["path"] == ["steps", step_index, field]
    assert details["step_index"] == step_index
  end

  defp assert_policy_step_location(details, field, step_index \\ 0) do
    assert details["step_field"] == "steps[#{step_index + 1}].#{field}"
    assert details["step_json_pointer"] == "/steps/#{step_index}/#{field}"
    assert details["step_path"] == ["steps", step_index, field]
    assert details["step_index"] == step_index
  end

  test "dry-run rejects an unknown subagent role before runtime starts" do
    ws = tmp_workspace("pixir-delegate-contract-role")

    spec =
      Jason.encode!(%{
        "contract_version" => 1,
        "strategy" => "subagents",
        "task" => "inspect docs",
        "subagents" => %{"role" => "editor"}
      })

    assert {:error,
            %{
              exit_code: 2,
              payload: %{
                "ok" => false,
                "status" => "rejected",
                "kind" => "not_found",
                "message" => "agent not found",
                "command_ok" => false,
                "work_complete" => false,
                "reason_code" => "not_found",
                "details" => %{
                  "field" => "subagents.role",
                  "role" => "editor",
                  "known" => known,
                  "next_actions" => next_actions
                }
              }
            }} =
             CLIContract.run(["--spec", "-", "--dry-run", "--json"],
               workspace: ws,
               read_stdin: fn -> spec end
             )

    assert "explorer" in known
    assert "default" in known
    assert "worker" in known
    assert "choose_known_subagent_role" in next_actions
  end

  test "dry-run role validation honors injected agent discovery options" do
    ws = tmp_workspace("pixir-delegate-contract-custom-role")
    agents_root = Path.join(ws, "agents")
    File.mkdir_p!(agents_root)

    File.write!(
      Path.join(agents_root, "editor.toml"),
      """
      name = "editor"
      description = "Scoped editing role for delegate dry-run validation."
      developer_instructions = \"\"\"
      Edit only within the delegated scope and report evidence.
      \"\"\"
      """
    )

    spec =
      Jason.encode!(%{
        "contract_version" => 1,
        "strategy" => "subagents",
        "task" => "inspect docs",
        "subagents" => %{"role" => "editor"}
      })

    assert {:ok,
            %{
              exit_code: 0,
              payload: %{
                "status" => "planned",
                "strategy" => "subagents",
                "beam_coordination" => %{"subagent_role" => "editor"},
                "role_validation" => %{"status" => "known", "known" => known}
              }
            }} =
             CLIContract.run(["--spec", "-", "--dry-run", "--json"],
               workspace: ws,
               read_stdin: fn -> spec end,
               runtime_opts: [agents_opts: [roots: [{"test", agents_root, 0}]]]
             )

    assert "editor" in known
  end

  test "attached delegate rejects progress mode until it can emit real frames" do
    assert {:error,
            %{
              exit_code: 2,
              payload: %{
                "ok" => false,
                "status" => "rejected",
                "kind" => "invalid_args",
                "command_ok" => false,
                "work_complete" => false,
                "reason_code" => "invalid_args",
                "details" => %{
                  "mode" => "stderr-jsonl",
                  "scope" => "attached_delegate",
                  "supported_progress_now" => [
                    "pixir delegate attach <handle> --progress=stderr-jsonl"
                  ],
                  "next_actions" => next_actions
                }
              }
            }} =
             CLIContract.run(["--spec", "-", "--progress=stderr-jsonl", "--json"],
               read_stdin: fn -> flunk("attached progress rejection should not read the spec") end
             )

    assert "remove_--progress_for_attached_delegate" in next_actions
  end

  test "workflow dry-run rejects ambiguous steps without a read-only proof" do
    spec =
      Jason.encode!(%{
        "contract_version" => 1,
        "strategy" => "workflow",
        "steps" => [
          %{"id" => "inspect", "task" => "inspect docs", "agent" => "explorer"}
        ]
      })

    assert {:error,
            %{
              exit_code: 2,
              payload: %{
                "ok" => false,
                "status" => "rejected",
                "kind" => "invalid_spec",
                "details" =>
                  %{
                    "field" => "steps[1].permission_mode",
                    "reason" => "missing_permission_mode_is_writer_capable_by_default",
                    "next_actions" => next_actions
                  } = details
              }
            }} =
             CLIContract.run(["--spec", "-", "--dry-run", "--json"],
               read_stdin: fn -> spec end
             )

    assert_step_location(details, "permission_mode")
    assert "set_mode_to_read_only_to_apply_read_only_to_all_steps" in next_actions
  end

  test "workflow dry-run reports step locations for non-first steps" do
    spec =
      Jason.encode!(%{
        "contract_version" => 1,
        "strategy" => "workflow",
        "steps" => [
          %{
            "id" => "first",
            "task" => "inspect docs",
            "agent" => "explorer",
            "permission_mode" => "read_only"
          },
          %{"id" => "second", "task" => "inspect more docs", "agent" => "explorer"}
        ]
      })

    assert {:error,
            %{
              exit_code: 2,
              payload: %{
                "kind" => "invalid_spec",
                "details" =>
                  %{
                    "id" => "second",
                    "field" => "steps[2].permission_mode",
                    "reason" => "missing_permission_mode_is_writer_capable_by_default"
                  } = details
              }
            }} =
             CLIContract.run(["--spec", "-", "--dry-run", "--json"],
               read_stdin: fn -> spec end
             )

    assert_step_location(details, "permission_mode", 1)
  end

  test "workflow bounded_write requires write_policy before planning" do
    spec =
      Jason.encode!(%{
        "contract_version" => 1,
        "strategy" => "workflow",
        "mode" => "bounded_write",
        "steps" => [
          %{
            "id" => "write",
            "task" => "write a file",
            "agent" => "worker",
            "permission_mode" => "auto"
          }
        ]
      })

    assert {:error,
            %{
              exit_code: 2,
              payload: %{
                "ok" => false,
                "status" => "rejected",
                "kind" => "invalid_spec",
                "details" => %{
                  "missing" => ["write_policy"],
                  "next_actions" => next_actions
                }
              }
            }} =
             CLIContract.run(["--spec", "-", "--dry-run", "--json"],
               read_stdin: fn -> spec end
             )

    assert "add_write_policy_or_use_read_only_mode" in next_actions
  end

  test "workflow bounded_write dry-run rejects writer steps without write_set" do
    spec =
      Jason.encode!(%{
        "contract_version" => 1,
        "strategy" => "workflow",
        "mode" => "bounded_write",
        "write_policy" => %{
          "version" => 1,
          "metadata" => %{"id" => "delegate-workflow"},
          "allow_writes" => ["notes/**"]
        },
        "steps" => [
          %{
            "id" => "write",
            "task" => "write notes",
            "agent" => "worker",
            "workspace_mode" => "shared"
          }
        ]
      })

    assert {:error,
            %{
              exit_code: 2,
              payload: %{
                "ok" => false,
                "status" => "rejected",
                "kind" => "invalid_spec",
                "details" =>
                  %{
                    "id" => "write",
                    "field" => "steps[1].write_set",
                    "next_actions" => next_actions
                  } = details
              }
            }} =
             CLIContract.run(["--spec", "-", "--dry-run", "--json"],
               read_stdin: fn -> spec end
             )

    assert_step_location(details, "write_set")
    assert "add_explicit_write_set" in next_actions
  end

  test "workflow bounded_write dry-run rejects write_set outside delegate allowlist" do
    spec =
      Jason.encode!(%{
        "contract_version" => 1,
        "strategy" => "workflow",
        "mode" => "bounded_write",
        "write_policy" => %{
          "version" => 1,
          "metadata" => %{"id" => "delegate-workflow"},
          "allow_writes" => ["notes/**"]
        },
        "steps" => [
          %{
            "id" => "write",
            "task" => "write blocked file",
            "agent" => "worker",
            "workspace_mode" => "shared",
            "write_set" => ["blocked.txt"]
          }
        ]
      })

    assert {:error,
            %{
              exit_code: 3,
              payload: %{
                "ok" => false,
                "status" => "rejected",
                "kind" => "write_policy_denied",
                "details" =>
                  %{
                    "id" => "write",
                    "matched_rule" => "not_within_parent_allow",
                    "next_actions" => next_actions
                  } = details
              }
            }} =
             CLIContract.run(["--spec", "-", "--dry-run", "--json"],
               read_stdin: fn -> spec end
             )

    refute Map.has_key?(details, "field")
    refute Map.has_key?(details, "json_pointer")
    refute Map.has_key?(details, "path")
    assert_policy_step_location(details, "write_set")
    assert "narrow_child_write_set" in next_actions
  end

  test "workflow bounded_write dry-run rejects isolated writer snapshots" do
    spec =
      Jason.encode!(%{
        "contract_version" => 1,
        "strategy" => "workflow",
        "mode" => "bounded_write",
        "write_policy" => %{
          "version" => 1,
          "metadata" => %{"id" => "delegate-workflow"},
          "allow_writes" => ["notes/**"]
        },
        "steps" => [
          %{
            "id" => "write",
            "task" => "write notes",
            "agent" => "worker",
            "workspace_mode" => "isolated",
            "write_set" => ["notes/out.md"]
          }
        ]
      })

    assert {:error,
            %{
              exit_code: 2,
              payload: %{
                "ok" => false,
                "status" => "rejected",
                "kind" => "invalid_spec",
                "details" =>
                  %{
                    "id" => "write",
                    "field" => "steps[1].workspace_mode",
                    "observed" => "isolated",
                    "reason" => "isolated_writes_do_not_mutate_parent_workspace",
                    "next_actions" => next_actions
                  } = details
              }
            }} =
             CLIContract.run(["--spec", "-", "--dry-run", "--json"],
               read_stdin: fn -> spec end
             )

    assert_step_location(details, "workspace_mode")
    assert "set_writer_step_workspace_mode_to_shared" in next_actions
  end

  test "workflow dry-run reports non-string permission modes without crashing" do
    spec =
      Jason.encode!(%{
        "contract_version" => 1,
        "strategy" => "workflow",
        "mode" => "read_only",
        "steps" => [
          %{
            "id" => "weird",
            "task" => "inspect docs",
            "agent" => "explorer",
            "permission_mode" => %{"not" => "stringable"}
          }
        ]
      })

    assert {:error,
            %{
              exit_code: 2,
              payload: %{
                "ok" => false,
                "status" => "rejected",
                "kind" => "invalid_spec",
                "details" =>
                  %{
                    "field" => "steps[1].permission_mode",
                    "observed" => "%{\"not\" => \"stringable\"}",
                    "next_actions" => next_actions
                  } = details
              }
            }} =
             CLIContract.run(["--spec", "-", "--dry-run", "--json"],
               read_stdin: fn -> spec end
             )

    assert_step_location(details, "permission_mode")
    assert "set_step_permission_mode_to_read_only" in next_actions
  end
end
