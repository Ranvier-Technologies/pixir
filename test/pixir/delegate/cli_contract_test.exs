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

  test "workflow rehearsal rejects cyclic dry-run plans" do
    spec =
      Jason.encode!(%{
        "contract_version" => 1,
        "strategy" => "workflow",
        "mode" => "read_only",
        "steps" => [
          %{"id" => "s1", "task" => "one", "depends_on" => ["s2"]},
          %{"id" => "s2", "task" => "two", "depends_on" => ["s1"]}
        ]
      })

    assert {:error,
            %{
              exit_code: 2,
              payload:
                %{
                  "ok" => false,
                  "status" => "rejected",
                  "kind" => "invalid_spec",
                  "message" => message,
                  "details" => %{"next_actions" => next_actions} = payload_details
                } = payload
            }} =
             CLIContract.run(["--spec", "-", "--dry-run", "--json"],
               read_stdin: fn -> spec end
             )

    assert message =~ "contains a cycle"
    assert "fix_workflow_dependency_graph" in next_actions
    assert Map.get(payload, "children", []) == []
    assert is_map(payload_details)
  end

  test "workflow rehearsal rejects cyclic attached requests before runtime" do
    spec =
      Jason.encode!(%{
        "contract_version" => 1,
        "strategy" => "workflow",
        "mode" => "read_only",
        "steps" => [
          %{"id" => "s1", "task" => "one", "depends_on" => ["s2"]},
          %{"id" => "s2", "task" => "two", "depends_on" => ["s1"]}
        ]
      })

    assert {:error,
            %{
              exit_code: 2,
              payload: %{
                "kind" => "invalid_spec",
                "message" => message,
                "details" => %{"next_actions" => next_actions}
              }
            }} =
             CLIContract.run(["--spec", "-", "--json"], read_stdin: fn -> spec end)

    assert message =~ "contains a cycle"
    assert "fix_workflow_dependency_graph" in next_actions
  end

  test "workflow rehearsal preserves unknown dependency details" do
    spec =
      Jason.encode!(%{
        "contract_version" => 1,
        "strategy" => "workflow",
        "mode" => "read_only",
        "steps" => [
          %{"id" => "s1", "task" => "one"},
          %{"id" => "s2", "task" => "two", "depends_on" => ["missing"]}
        ]
      })

    assert {:error,
            %{
              payload: %{
                "kind" => "invalid_spec",
                "message" => message,
                "details" => %{"missing" => missing, "next_actions" => next_actions}
              }
            }} =
             CLIContract.run(["--spec", "-", "--dry-run", "--json"],
               read_stdin: fn -> spec end
             )

    assert message =~ "unknown dependencies"
    assert missing != []
    assert "fix_workflow_dependency_graph" in next_actions
  end

  test "workflow rehearsal rejects duplicate step ids" do
    spec =
      Jason.encode!(%{
        "contract_version" => 1,
        "strategy" => "workflow",
        "mode" => "read_only",
        "steps" => [
          %{"id" => "dup", "task" => "one"},
          %{"id" => "dup", "task" => "two"}
        ]
      })

    assert {:error,
            %{
              payload: %{
                "kind" => "invalid_spec",
                "message" => message,
                "details" => %{"next_actions" => next_actions} = details
              }
            }} =
             CLIContract.run(["--spec", "-", "--dry-run", "--json"],
               read_stdin: fn -> spec end
             )

    assert message =~ "step ids must be unique"
    assert "fix_workflow_dependency_graph" in next_actions
    assert details["duplicates"] == ["dup"]
  end

  test "workflow rehearsal accepts valid diamond dry-run without payload changes" do
    spec =
      Jason.encode!(%{
        "contract_version" => 1,
        "strategy" => "workflow",
        "mode" => "read_only",
        "steps" => [
          %{"id" => "a", "task" => "a"},
          %{"id" => "b", "task" => "b", "depends_on" => ["a"]},
          %{"id" => "c", "task" => "c", "depends_on" => ["a"]},
          %{"id" => "d", "task" => "d", "depends_on" => ["b", "c"]}
        ]
      })

    assert {:ok,
            %{
              exit_code: 0,
              payload:
                %{
                  "ok" => true,
                  "status" => "planned",
                  "strategy" => "workflow",
                  "next_actions" => next_actions
                } = payload
            }} =
             CLIContract.run(["--spec", "-", "--dry-run", "--json"],
               read_stdin: fn -> spec end
             )

    # Workflow-strategy plans never carried children[]; steps identify children
    # at runtime by step id, and planned_child_count is the plan-side evidence.
    refute Map.has_key?(payload, "children")
    assert payload["beam_coordination"]["planned_child_count"] == 4
    assert "run_without_--dry-run_for_attached_workflow" in next_actions
  end

  test "workflow rehearsal rejects nested cyclic workflow specs" do
    spec =
      Jason.encode!(%{
        "contract_version" => 1,
        "strategy" => "workflow",
        "mode" => "read_only",
        "workflow" => %{
          "steps" => [
            %{"id" => "s1", "task" => "one", "depends_on" => ["s2"]},
            %{"id" => "s2", "task" => "two", "depends_on" => ["s1"]}
          ]
        }
      })

    assert {:error, %{payload: %{"kind" => "invalid_spec", "message" => message}}} =
             CLIContract.run(["--spec", "-", "--dry-run", "--json"],
               read_stdin: fn -> spec end
             )

    assert message =~ "contains a cycle"
  end

  test "workflow rehearsal rejects bounded_write cyclic workflow specs" do
    spec =
      Jason.encode!(%{
        "contract_version" => 1,
        "strategy" => "workflow",
        "mode" => "bounded_write",
        "write_policy" => %{"version" => 1, "allow_writes" => ["notes/**"]},
        "steps" => [
          %{
            "id" => "s1",
            "task" => "one",
            "permission_mode" => "read_only",
            "depends_on" => ["s2"]
          },
          %{
            "id" => "s2",
            "task" => "two",
            "permission_mode" => "read_only",
            "depends_on" => ["s1"]
          }
        ]
      })

    assert {:error,
            %{
              payload: %{
                "kind" => "invalid_spec",
                "message" => message,
                "details" => %{"next_actions" => next_actions}
              }
            }} =
             CLIContract.run(["--spec", "-", "--dry-run", "--json"],
               read_stdin: fn -> spec end
             )

    assert message =~ "contains a cycle"
    assert "fix_workflow_dependency_graph" in next_actions
  end

  test "subagents dry-run exposes runtime task indexes and attachment counts" do
    spec =
      Jason.encode!(%{
        "contract_version" => 1,
        "strategy" => "subagents",
        "tasks" => [
          "first task",
          %{
            "task" => "second task",
            "attachments" => ["notes.txt", "file:///tmp/pixir-evidence.txt"]
          },
          "third task"
        ]
      })

    assert {:ok,
            %{
              exit_code: 0,
              payload:
                %{
                  "status" => "planned",
                  "strategy" => "subagents",
                  "children" => children,
                  "children_order" => order_note
                } = payload
            }} =
             CLIContract.run(["--spec", "-", "--dry-run", "--json"],
               read_stdin: fn -> spec end
             )

    assert Enum.map(children, & &1["task"]) == ["first task", "second task", "third task"]
    assert Enum.map(children, & &1["index"]) == [0, 1, 2]
    assert Enum.map(children, & &1["attachment_count"]) == [0, 2, 0]
    # Additive envelope key -> schema revision 3 (family v1 unchanged).
    assert payload["schema_version"] == 3
    assert order_note =~ "unspecified"
    assert order_note =~ "children[].index"
  end

  test "unknown top-level delegate spec keys fail closed" do
    spec =
      Jason.encode!(%{
        "contract_version" => 1,
        "strategy" => "subagents",
        "task" => "inspect docs",
        "modle" => "gpt-5.5"
      })

    assert {:error,
            %{
              exit_code: 2,
              payload: %{
                "kind" => "invalid_spec",
                "details" => %{
                  "json_pointer" => "/modle",
                  "path" => ["modle"],
                  "field" => "modle"
                }
              }
            }} =
             CLIContract.run(["--spec", "-", "--dry-run", "--json"],
               read_stdin: fn -> spec end
             )
  end

  test "unknown subagents keys fail closed" do
    spec =
      Jason.encode!(%{
        "contract_version" => 1,
        "strategy" => "subagents",
        "task" => "inspect docs",
        "subagents" => %{"max_thread" => 2}
      })

    assert {:error,
            %{
              exit_code: 2,
              payload: %{
                "kind" => "invalid_spec",
                "details" => %{
                  "json_pointer" => "/subagents/max_thread",
                  "path" => ["subagents", "max_thread"],
                  "field" => "subagents.max_thread"
                }
              }
            }} =
             CLIContract.run(["--spec", "-", "--dry-run", "--json"],
               read_stdin: fn -> spec end
             )
  end

  test "subagents provider knobs validate with ACP reasoning effort values" do
    valid =
      Jason.encode!(%{
        "contract_version" => 1,
        "strategy" => "subagents",
        "task" => "inspect docs",
        "subagents" => %{"model" => "gpt-5.5", "reasoning_effort" => "xhigh"}
      })

    assert {:ok, %{payload: %{"status" => "planned"}}} =
             CLIContract.run(["--spec", "-", "--dry-run", "--json"],
               read_stdin: fn -> valid end
             )

    invalid =
      Jason.encode!(%{
        "contract_version" => 1,
        "strategy" => "subagents",
        "task" => "inspect docs",
        "subagents" => %{"reasoning_effort" => "ultra"}
      })

    assert {:error,
            %{
              payload: %{
                "kind" => "invalid_spec",
                "details" => %{
                  "json_pointer" => "/subagents/reasoning_effort",
                  "accepted_values" => ["low", "medium", "high", "xhigh"]
                }
              }
            }} =
             CLIContract.run(["--spec", "-", "--dry-run", "--json"],
               read_stdin: fn -> invalid end
             )
  end

  test "subagents web_search accepts true and hosted tool config object" do
    for web_search <- [true, %{"enabled" => true, "search_context_size" => "low"}] do
      spec =
        Jason.encode!(%{
          "contract_version" => 1,
          "strategy" => "subagents",
          "task" => "inspect docs",
          "subagents" => %{"web_search" => web_search}
        })

      assert {:ok, %{payload: %{"status" => "planned"}}} =
               CLIContract.run(["--spec", "-", "--dry-run", "--json"],
                 read_stdin: fn -> spec end
               )
    end
  end

  test "subagents web_search rejects invalid keys and types" do
    invalid_key =
      Jason.encode!(%{
        "contract_version" => 1,
        "strategy" => "subagents",
        "task" => "inspect docs",
        "subagents" => %{"web_search" => %{"surprise" => true}}
      })

    assert {:error,
            %{
              payload: %{
                "kind" => "invalid_spec",
                "details" => %{
                  "json_pointer" => "/subagents/web_search/surprise",
                  "accepted_values" => [true, "object"]
                }
              }
            }} =
             CLIContract.run(["--spec", "-", "--dry-run", "--json"],
               read_stdin: fn -> invalid_key end
             )

    invalid_type =
      Jason.encode!(%{
        "contract_version" => 1,
        "strategy" => "subagents",
        "task" => "inspect docs",
        "subagents" => %{"web_search" => "yes"}
      })

    assert {:error,
            %{
              payload: %{
                "kind" => "invalid_spec",
                "details" => %{"json_pointer" => "/subagents/web_search"}
              }
            }} =
             CLIContract.run(["--spec", "-", "--dry-run", "--json"],
               read_stdin: fn -> invalid_type end
             )
  end

  test "non-object subagents values fail closed instead of crashing" do
    spec =
      Jason.encode!(%{
        "contract_version" => 1,
        "strategy" => "subagents",
        "task" => "inspect docs",
        "subagents" => "explorer"
      })

    assert {:error,
            %{
              exit_code: 2,
              payload: %{
                "kind" => "invalid_spec",
                "details" => %{
                  "json_pointer" => "/subagents",
                  "observed_type" => "string"
                }
              }
            }} =
             CLIContract.run(["--spec", "-", "--dry-run", "--json"],
               read_stdin: fn -> spec end
             )
  end

  test "legacy single-task dry-run plans children without task-array indexes" do
    spec =
      Jason.encode!(%{
        "contract_version" => 1,
        "strategy" => "subagents",
        "task" => "same prompt",
        "subagents" => %{"count" => 2}
      })

    assert {:ok, %{payload: %{"children" => children}}} =
             CLIContract.run(["--spec", "-", "--dry-run", "--json"],
               read_stdin: fn -> spec end
             )

    assert Enum.map(children, & &1["task"]) == ["same prompt", "same prompt"]
    assert Enum.map(children, & &1["attachment_count"]) == [0, 0]
    refute Enum.any?(children, &Map.has_key?(&1, "index"))
  end

  test "subagents dry-run rejects malformed tasks entries like the real runner" do
    # Task objects with unknown keys get the specific fail-closed hint; other
    # malformed shapes keep the generic entries hint. Both mirror the runner.
    expected_hints = %{
      "   " => "fix_subagents_tasks_entries",
      42 => "fix_subagents_tasks_entries",
      %{"other" => "shape"} => "remove_unknown_field"
    }

    for {bad_entry, expected_hint} <- expected_hints do
      spec =
        Jason.encode!(%{
          "contract_version" => 1,
          "strategy" => "subagents",
          "tasks" => ["valid task", bad_entry]
        })

      assert {:error,
              %{
                exit_code: 2,
                payload: %{
                  "ok" => false,
                  "status" => "rejected",
                  "kind" => "invalid_spec",
                  "details" => %{"next_actions" => next_actions} = details
                }
              }} =
               CLIContract.run(["--spec", "-", "--dry-run", "--json"],
                 read_stdin: fn -> spec end
               )

      assert expected_hint in next_actions
      assert details["task_index"] == 1
      assert details["json_pointer"] == "/tasks/1"
      assert details["path"] == ["tasks", 1]
      assert details["field"] == "tasks[2]"
    end
  end

  test "task object attachments validate fail closed in dry-run" do
    cases = [
      {%{"task" => "valid", "anything" => true}, "/tasks/0"},
      {%{"task" => 123, "extra" => true}, "/tasks/0"},
      {%{"task" => "valid", "attachments" => nil}, "/tasks/0/attachments"},
      {%{"task" => "valid", "attachments" => "note.txt"}, "/tasks/0/attachments"},
      {%{"task" => "valid", "attachments" => [""]}, "/tasks/0/attachments/0"},
      {%{"task" => "valid", "attachments" => [123]}, "/tasks/0/attachments/0"},
      {%{"task" => "valid", "attachments" => ["file://evidence.txt"]}, "/tasks/0/attachments/0"}
    ]

    for {entry, pointer} <- cases do
      spec =
        Jason.encode!(%{
          "contract_version" => 1,
          "strategy" => "subagents",
          "tasks" => [entry]
        })

      assert {:error,
              %{
                exit_code: 2,
                payload: %{
                  "kind" => "invalid_spec",
                  "details" => %{"json_pointer" => ^pointer}
                }
              }} =
               CLIContract.run(["--spec", "-", "--dry-run", "--json"],
                 read_stdin: fn -> spec end
               )
    end
  end

  test "subagents dry-run mirrors runner precedence: a tasks list owns validation" do
    empty_tasks_with_fallback =
      Jason.encode!(%{
        "contract_version" => 1,
        "strategy" => "subagents",
        "task" => "fallback task",
        "tasks" => []
      })

    assert {:error,
            %{
              exit_code: 2,
              payload: %{
                "kind" => "invalid_spec",
                "details" => %{"next_actions" => next_actions}
              }
            }} =
             CLIContract.run(["--spec", "-", "--dry-run", "--json"],
               read_stdin: fn -> empty_tasks_with_fallback end
             )

    assert "add_tasks_for_fanout" in next_actions

    both_present =
      Jason.encode!(%{
        "contract_version" => 1,
        "strategy" => "subagents",
        "task" => "legacy task",
        "tasks" => ["a", "b", "c"],
        "subagents" => %{"count" => 5}
      })

    assert {:ok, %{payload: %{"children" => children} = payload}} =
             CLIContract.run(["--spec", "-", "--dry-run", "--json"],
               read_stdin: fn -> both_present end
             )

    assert Enum.map(children, & &1["task"]) == ["a", "b", "c"]
    assert payload["beam_coordination"]["planned_child_count"] == 3
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
