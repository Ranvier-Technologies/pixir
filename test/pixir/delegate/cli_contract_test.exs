defmodule Pixir.Delegate.CLIContractTest do
  use ExUnit.Case, async: true

  alias Pixir.Delegate.CLIContract

  defmodule OutputWarningRunner do
    def run(_request, _spec, _spec_meta, opts) do
      {:ok, Keyword.fetch!(opts, :fixture_payload)}
    end
  end

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

  defp apply_workflow_spec(mode, write_policy) do
    spec = %{
      "contract_version" => 1,
      "strategy" => "workflow",
      "mode" => mode,
      "steps" => [
        %{
          "id" => "inspect",
          "task" => "inspect input",
          "permission_mode" => "read_only",
          "workspace_mode" => "shared"
        },
        %{
          "id" => "producer",
          "task" => "produce a virtual diff",
          "permission_mode" => "read_only",
          "workspace_mode" => "virtual_overlay",
          "read_set" => ["input.txt"],
          "virtual_commands" => ["true"],
          "depends_on" => ["inspect"]
        },
        %{
          "id" => "apply",
          "apply_from" => "producer",
          "workspace_mode" => "shared",
          "depends_on" => ["producer"],
          "write_set" => ["notes/output.txt"]
        }
      ]
    }

    if is_nil(write_policy) do
      spec
    else
      Map.put(spec, "write_policy", write_policy)
    end
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

  test "workflow rehearsal accepts bounded_write apply_from with spec write_policy" do
    workspace = tmp_workspace("pixir-delegate-apply-rehearsal")
    File.write!(Path.join(workspace, "input.txt"), "source\n")

    spec =
      "bounded_write"
      |> apply_workflow_spec(%{"version" => 1, "allow_writes" => ["notes/**"]})
      |> Jason.encode!()

    assert {:ok,
            %{
              exit_code: 0,
              payload: %{
                "ok" => true,
                "status" => "planned",
                "strategy" => "workflow",
                "beam_coordination" => %{"planned_child_count" => 3}
              }
            }} =
             CLIContract.run(["--spec", "-", "--dry-run", "--json"],
               workspace: workspace,
               read_stdin: fn -> spec end
             )
  end

  test "workflow rehearsal rejects apply_from without write_policy" do
    workspace = tmp_workspace("pixir-delegate-apply-rehearsal-fail-closed")
    File.write!(Path.join(workspace, "input.txt"), "source\n")

    spec =
      "read_only"
      |> apply_workflow_spec(nil)
      |> Jason.encode!()

    assert {:error,
            %{
              exit_code: 2,
              payload: %{
                "ok" => false,
                "status" => "rejected",
                "kind" => "invalid_spec",
                "details" => details
              }
            }} =
             CLIContract.run(["--spec", "-", "--dry-run", "--json"],
               workspace: workspace,
               read_stdin: fn -> spec end
             )

    assert details["field"] == "apply_from"
    assert "run_with_bounded_write_policy" in details["next_actions"]
  end

  test "workflow bounded_write ignores spec-level read-only subagents role" do
    spec =
      Jason.encode!(%{
        "contract_version" => 1,
        "strategy" => "workflow",
        "mode" => "bounded_write",
        "subagents" => %{"role" => "explorer"},
        "write_policy" => %{"version" => 1, "allow_writes" => ["notes/**"]},
        "steps" => [
          %{
            "id" => "write",
            "task" => "write notes",
            "agent" => "worker",
            "workspace_mode" => "shared",
            "write_set" => ["notes/out.txt"]
          }
        ]
      })

    assert {:ok, %{payload: %{"status" => "planned", "strategy" => "workflow"}}} =
             CLIContract.run(["--spec", "-", "--dry-run", "--json"],
               read_stdin: fn -> spec end
             )
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
    # Additive Provider-output evidence -> schema revision 5 (family v1 unchanged).
    assert payload["schema_version"] == 5
    assert order_note =~ "unspecified"
    assert order_note =~ "children[].index"
  end

  test "Delegate schema 5 bounds distinct child/output warnings at 255/256/257" do
    spec =
      Jason.encode!(%{
        "contract_version" => 1,
        "strategy" => "subagents",
        "task" => "fixture"
      })

    for count <- [255, 256, 257] do
      children =
        for index <- 0..(count - 1) do
          child_session_id = "child_#{index}"

          %{
            "index" => index,
            "child_session_id" => child_session_id,
            "status" => "completed",
            "summary" => "exact summary #{index}",
            "output_warning_count" => 1,
            "output_warnings_truncated" => false,
            "output_warnings" => [
              %{
                "kind" => "provider_output_truncated",
                "severity" => "warning",
                "child_session_id" => child_session_id,
                "provider_usage_event_id" => "evt_shared",
                "provider_usage_seq" => index + 1,
                "reason" => "provider_output_limit",
                "provider_reason" => "max_tokens",
                "call_role" => "final_answer"
              }
            ]
          }
        end

      fixture = %{
        "ok" => true,
        "status" => "completed",
        "kind" => "delegate_result",
        "children" => children,
        "summary" => "done"
      }

      assert {:ok, %{payload: payload}} =
               CLIContract.run(["--spec", "-", "--json"],
                 read_stdin: fn -> spec end,
                 runner: OutputWarningRunner,
                 runtime_opts: [fixture_payload: fixture]
               )

      assert payload["schema_version"] == 5
      assert payload["warning_count"] == count
      assert length(payload["warnings"]) == min(count, 256)
      assert payload["warnings_truncated"] == (count == 257)
      assert payload["truncated_child_count"] == count
      assert length(payload["truncated_children"]) == min(count, 256)
      assert payload["truncated_children_truncated"] == (count == 257)

      # Same Event id in distinct child Sessions remains distinct.
      assert Enum.uniq_by(
               payload["warnings"],
               &{
                 &1["child_session_id"],
                 &1["provider_usage_event_id"]
               }
             ) == payload["warnings"]

      assert Enum.map(payload["children"], & &1["summary"]) ==
               Enum.map(children, & &1["summary"])
    end
  end

  test "Delegate warning totals deduplicate the authoritative child-session/Event identity" do
    spec =
      Jason.encode!(%{"contract_version" => 1, "strategy" => "subagents", "task" => "fixture"})

    warning = %{
      "kind" => "provider_output_truncated",
      "severity" => "warning",
      "child_session_id" => "child_duplicate",
      "provider_usage_event_id" => "evt_duplicate",
      "provider_usage_seq" => 7,
      "reason" => "provider_output_limit",
      "provider_reason" => "max_tokens",
      "call_role" => "final_answer"
    }

    children =
      for index <- 0..1 do
        %{
          "index" => index,
          "child_session_id" => "child_duplicate",
          "status" => "completed",
          "summary" => "duplicate #{index}",
          "output_warning_count" => 1,
          "output_warnings" => [warning],
          "output_warnings_truncated" => false
        }
      end

    fixture = %{
      "ok" => true,
      "status" => "completed",
      "kind" => "delegate_result",
      "children" => children
    }

    assert {:ok, %{payload: payload}} =
             CLIContract.run(["--spec", "-", "--json"],
               read_stdin: fn -> spec end,
               runner: OutputWarningRunner,
               runtime_opts: [fixture_payload: fixture]
             )

    assert payload["warning_count"] == 1
    assert length(payload["warnings"]) == 1
    refute payload["warnings_truncated"]
    assert payload["truncated_child_count"] == 1
  end

  test "Delegate ingress bounds oversized child warning arrays before aggregation" do
    spec =
      Jason.encode!(%{"contract_version" => 1, "strategy" => "subagents", "task" => "fixture"})

    child_sid = "child_oversized"

    warnings =
      for seq <- 1..1_000 do
        %{
          "kind" => "provider_output_truncated",
          "severity" => "warning",
          "child_session_id" => child_sid,
          "provider_usage_event_id" => "evt_oversized_#{seq}",
          "provider_usage_seq" => seq,
          "reason" => "provider_output_limit",
          "provider_reason" => "max_tokens",
          "call_role" => "intermediate"
        }
      end

    fixture = %{
      "ok" => true,
      "status" => "completed",
      "kind" => "delegate_result",
      "children" => [
        %{
          "index" => 0,
          "child_session_id" => child_sid,
          "status" => "completed",
          "summary" => "oversized",
          "output_warning_count" => 1_000,
          "output_warnings" => warnings,
          "output_warning_reasons" => [
            "provider_output_limit",
            "provider_content_filter",
            "unsafe"
          ],
          "output_warnings_truncated" => true
        }
      ]
    }

    assert {:ok, %{payload: payload}} =
             CLIContract.run(["--spec", "-", "--json"],
               read_stdin: fn -> spec end,
               runner: OutputWarningRunner,
               runtime_opts: [fixture_payload: fixture]
             )

    assert [child] = payload["children"]
    assert child["output_warning_count"] == 1_000
    assert length(child["output_warnings"]) == 64

    assert child["output_warning_reasons"] == [
             "provider_content_filter",
             "provider_output_limit"
           ]

    assert payload["warning_count"] == 1_000
    assert length(payload["warnings"]) == 64
    assert payload["warnings_truncated"]

    assert payload["warnings_truncated"] ==
             payload["warning_count"] > length(payload["warnings"])
  end

  test "one-shot keeps the validated reason introduced by a suppressed 65th warning" do
    spec =
      Jason.encode!(%{"contract_version" => 1, "strategy" => "subagents", "task" => "fixture"})

    child_sid = "child_reason_65"

    warnings =
      for seq <- 1..64 do
        %{
          "child_session_id" => child_sid,
          "provider_usage_event_id" => "evt_reason_#{seq}",
          "provider_usage_seq" => seq,
          "reason" => "provider_output_limit",
          "provider_reason" => "max_tokens",
          "call_role" => "intermediate"
        }
      end

    fixture = %{
      "ok" => true,
      "status" => "completed",
      "kind" => "delegate_result",
      "children" => [
        %{
          "child_session_id" => child_sid,
          "status" => "completed",
          "output_warning_count" => 65,
          "output_warnings" => warnings,
          "output_warning_reasons" => [
            "provider_output_limit",
            "provider_content_filter"
          ],
          "output_warnings_truncated" => true
        }
      ]
    }

    assert {:ok, %{payload: %{"children" => [child]}}} =
             CLIContract.run(["--spec", "-", "--json"],
               read_stdin: fn -> spec end,
               runner: OutputWarningRunner,
               runtime_opts: [fixture_payload: fixture]
             )

    assert child["output_warning_count"] == 65
    assert length(child["output_warnings"]) == 64

    assert child["output_warning_reasons"] == [
             "provider_content_filter",
             "provider_output_limit"
           ]
  end

  test "Delegate rejects embedded warning child Session mismatches before counting" do
    spec =
      Jason.encode!(%{"contract_version" => 1, "strategy" => "subagents", "task" => "fixture"})

    fixture = %{
      "ok" => true,
      "status" => "completed",
      "kind" => "delegate_result",
      "children" => [
        %{
          "index" => 0,
          "child_session_id" => "child_outer",
          "status" => "completed",
          "summary" => "mismatch",
          "output_warning_count" => 1,
          "output_warnings_truncated" => false,
          "output_warnings" => [
            %{
              "kind" => "provider_output_truncated",
              "severity" => "warning",
              "child_session_id" => "child_other",
              "provider_usage_event_id" => "evt_mismatch",
              "provider_usage_seq" => 1,
              "reason" => "provider_output_limit",
              "provider_reason" => "max_tokens",
              "call_role" => "final_answer"
            }
          ]
        }
      ]
    }

    assert {:ok, %{payload: payload}} =
             CLIContract.run(["--spec", "-", "--json"],
               read_stdin: fn -> spec end,
               runner: OutputWarningRunner,
               runtime_opts: [fixture_payload: fixture]
             )

    assert [child] = payload["children"]
    assert child["output_warning_count"] == 0
    assert child["output_warnings"] == []
    assert payload["warning_count"] == 0
    assert payload["warnings"] == []
    refute payload["warnings_truncated"]
    refute inspect(payload) =~ "child_other"
  end

  test "Delegate children and warning projections share validated mixed-index ordering" do
    spec =
      Jason.encode!(%{"contract_version" => 1, "strategy" => "subagents", "task" => "fixture"})

    rows = [
      {"child_invalid_first", -2},
      {"child_b", 2},
      {"child_missing", nil},
      {"child_one", 1},
      {"child_a", 2},
      {"child_invalid_last", -1}
    ]

    children =
      rows
      |> Enum.with_index()
      |> Enum.map(fn {{child_sid, index}, position} ->
        child = %{
          "child_session_id" => child_sid,
          "status" => "completed",
          "summary" => child_sid,
          "output_warning_count" => 1,
          "output_warnings_truncated" => false,
          "output_warnings" => [
            %{
              "kind" => "provider_output_truncated",
              "severity" => "warning",
              "child_session_id" => child_sid,
              "provider_usage_event_id" => "evt_#{position}",
              "provider_usage_seq" => position + 1,
              "reason" => "provider_output_limit",
              "provider_reason" => "max_tokens",
              "call_role" => "final_answer"
            }
          ]
        }

        if is_nil(index), do: child, else: Map.put(child, "index", index)
      end)

    fixture = %{
      "ok" => true,
      "status" => "completed",
      "kind" => "delegate_result",
      "children" => children
    }

    assert {:ok, %{payload: payload}} =
             CLIContract.run(["--spec", "-", "--json"],
               read_stdin: fn -> spec end,
               runner: OutputWarningRunner,
               runtime_opts: [fixture_payload: fixture]
             )

    expected = [
      "child_one",
      "child_a",
      "child_b",
      "child_invalid_first",
      "child_missing",
      "child_invalid_last"
    ]

    assert Enum.map(payload["children"], & &1["child_session_id"]) == expected
    assert payload["truncated_children"] == expected
    assert Enum.map(payload["warnings"], & &1["child_session_id"]) == expected
    assert Enum.map(Enum.take(payload["children"], -3), & &1["index"]) == [-2, nil, -1]
  end

  test "bounded_write dry-run exposes verify command count without echoing commands" do
    spec =
      Jason.encode!(%{
        "contract_version" => 1,
        "strategy" => "subagents",
        "mode" => "bounded_write",
        "task" => "format only",
        "write_policy" => %{
          "version" => 1,
          "allow_writes" => ["notes/**"],
          "bash" => %{
            "verify" => ["mix format --check-formatted", "mix compile --warnings-as-errors"]
          }
        }
      })

    assert {:ok,
            %{
              payload: %{
                "status" => "planned",
                "verify_command_count" => 2,
                "children" => [%{"verify_command_count" => 2}]
              }
            }} =
             CLIContract.run(["--spec", "-", "--dry-run", "--json"],
               read_stdin: fn -> spec end
             )
  end

  test "virtual_overlay dry-run accepts bounded operator context and projects it" do
    spec =
      Jason.encode!(%{
        "contract_version" => 1,
        "strategy" => "subagents",
        "mode" => "read_only",
        "task" => "produce a virtual diff",
        "subagents" => %{
          "workspace_mode" => "virtual_overlay",
          "read_set" => ["lib/pixir/delegate/*.ex", "mix.exs"],
          "limits" => %{"max_import_files" => 8, "max_diff_bytes" => 4_096}
        }
      })

    assert {:ok,
            %{
              payload: %{
                "status" => "planned",
                "schema_version" => 5,
                "children" => [
                  %{
                    "workspace_mode" => "virtual_overlay",
                    "read_set_count" => 2,
                    "limits" => %{
                      "max_import_files" => 8,
                      "max_diff_bytes" => 4_096
                    }
                  }
                ]
              }
            }} =
             CLIContract.run(["--spec", "-", "--dry-run", "--json"],
               read_stdin: fn -> spec end
             )
  end

  test "virtual_overlay dry-run omits limits when absent" do
    spec =
      Jason.encode!(%{
        "contract_version" => 1,
        "strategy" => "subagents",
        "task" => "produce a virtual diff",
        "subagents" => %{
          "workspace_mode" => "virtual_overlay",
          "read_set" => ["mix.exs"]
        }
      })

    assert {:ok, %{payload: %{"children" => [child]}}} =
             CLIContract.run(["--spec", "-", "--dry-run", "--json"],
               read_stdin: fn -> spec end
             )

    refute Map.has_key?(child, "limits")
  end

  test "virtual_overlay dry-run rejects missing read_set" do
    spec =
      Jason.encode!(%{
        "contract_version" => 1,
        "strategy" => "subagents",
        "task" => "produce a virtual diff",
        "subagents" => %{"workspace_mode" => "virtual_overlay"}
      })

    assert {:error,
            %{
              payload: %{
                "kind" => "invalid_spec",
                "details" => %{
                  "json_pointer" => "/subagents/read_set",
                  "path" => ["subagents", "read_set"]
                }
              }
            }} =
             CLIContract.run(["--spec", "-", "--dry-run", "--json"],
               read_stdin: fn -> spec end
             )
  end

  test "virtual_overlay dry-run rejects unbounded read_set" do
    spec =
      Jason.encode!(%{
        "contract_version" => 1,
        "strategy" => "subagents",
        "task" => "produce a virtual diff",
        "subagents" => %{
          "workspace_mode" => "virtual_overlay",
          "read_set" => ["**/*"]
        }
      })

    assert {:error,
            %{
              payload: %{
                "kind" => "invalid_spec",
                "details" => %{
                  "matched_rule" => "root_recursive_catch_all",
                  "reason" => "root_recursive_catch_all",
                  "field" => "subagents.read_set[1]",
                  "json_pointer" => "/subagents/read_set/0"
                }
              }
            }} =
             CLIContract.run(["--spec", "-", "--dry-run", "--json"],
               read_stdin: fn -> spec end
             )
  end

  test "virtual_overlay read_set element labels are one-based while machine locations are zero-based" do
    spec =
      Jason.encode!(%{
        "contract_version" => 1,
        "strategy" => "subagents",
        "task" => "produce a virtual diff",
        "subagents" => %{
          "workspace_mode" => "virtual_overlay",
          "read_set" => ["mix.exs", ""]
        }
      })

    assert {:error,
            %{
              payload: %{
                "kind" => "invalid_spec",
                "details" => %{
                  "field" => "subagents.read_set[2]",
                  "json_pointer" => "/subagents/read_set/1",
                  "path" => ["subagents", "read_set", 1],
                  "reason" => "empty"
                }
              }
            }} =
             CLIContract.run(["--spec", "-", "--dry-run", "--json"],
               read_stdin: fn -> spec end
             )
  end

  test "virtual_overlay Delegate envelope preserves shared alias reason and index" do
    spec =
      Jason.encode!(%{
        "contract_version" => 1,
        "strategy" => "subagents",
        "task" => "produce a virtual diff",
        "subagents" => %{
          "workspace_mode" => "virtual_overlay",
          "read_set" => ["mix.exs", "lib/../**/*"]
        }
      })

    assert {:error,
            %{
              payload: %{
                "kind" => "invalid_spec",
                "details" => %{
                  "field" => "subagents.read_set[2]",
                  "json_pointer" => "/subagents/read_set/1",
                  "path" => ["subagents", "read_set", 1],
                  "reason" => "parent_component",
                  "matched_rule" => "parent_component"
                }
              }
            }} =
             CLIContract.run(["--spec", "-", "--dry-run", "--json"],
               read_stdin: fn -> spec end
             )
  end

  test "virtual_overlay attachment rejection uses task attachment location details" do
    spec =
      Jason.encode!(%{
        "contract_version" => 1,
        "strategy" => "subagents",
        "tasks" => [
          %{"task" => "first"},
          %{"task" => "second", "attachments" => ["notes.txt"]}
        ],
        "subagents" => %{
          "workspace_mode" => "virtual_overlay",
          "read_set" => ["mix.exs"]
        }
      })

    assert {:error,
            %{
              payload: %{
                "kind" => "invalid_spec",
                "details" => %{
                  "field" => "tasks[2].attachments",
                  "json_pointer" => "/tasks/1/attachments",
                  "path" => ["tasks", 1, "attachments"],
                  "task_index" => 1
                }
              }
            }} =
             CLIContract.run(["--spec", "-", "--dry-run", "--json"],
               read_stdin: fn -> spec end
             )
  end

  test "virtual_overlay dry-run rejects bounded_write mode" do
    spec =
      Jason.encode!(%{
        "contract_version" => 1,
        "strategy" => "subagents",
        "mode" => "bounded_write",
        "write_policy" => %{"version" => 1, "allow_writes" => ["notes/**"]},
        "task" => "produce a virtual diff",
        "subagents" => %{
          "workspace_mode" => "virtual_overlay",
          "read_set" => ["mix.exs"]
        }
      })

    assert {:error,
            %{
              payload: %{
                "kind" => "invalid_spec",
                "details" => %{"json_pointer" => "/write_policy"}
              }
            }} =
             CLIContract.run(["--spec", "-", "--dry-run", "--json"],
               read_stdin: fn -> spec end
             )
  end

  test "virtual_overlay dry-run rejects unknown limits" do
    spec =
      Jason.encode!(%{
        "contract_version" => 1,
        "strategy" => "subagents",
        "task" => "produce a virtual diff",
        "subagents" => %{
          "workspace_mode" => "virtual_overlay",
          "read_set" => ["mix.exs"],
          "limits" => %{"max_magic_bytes" => 1}
        }
      })

    assert {:error,
            %{
              payload: %{
                "kind" => "invalid_spec",
                "details" => %{
                  "unknown_key" => "max_magic_bytes",
                  "json_pointer" => "/subagents/limits/max_magic_bytes"
                }
              }
            }} =
             CLIContract.run(["--spec", "-", "--dry-run", "--json"],
               read_stdin: fn -> spec end
             )
  end

  test "virtual_overlay dry-run rejects negative limits" do
    spec =
      Jason.encode!(%{
        "contract_version" => 1,
        "strategy" => "subagents",
        "task" => "produce a virtual diff",
        "subagents" => %{
          "workspace_mode" => "virtual_overlay",
          "read_set" => ["mix.exs"],
          "limits" => %{"max_diff_bytes" => -1}
        }
      })

    assert {:error,
            %{
              payload: %{
                "kind" => "invalid_spec",
                "details" => %{
                  "observed" => -1,
                  "json_pointer" => "/subagents/limits/max_diff_bytes"
                }
              }
            }} =
             CLIContract.run(["--spec", "-", "--dry-run", "--json"],
               read_stdin: fn -> spec end
             )
  end

  test "shared mode rejects virtual-only read_set" do
    spec =
      Jason.encode!(%{
        "contract_version" => 1,
        "strategy" => "subagents",
        "task" => "inspect docs",
        "subagents" => %{"workspace_mode" => "shared", "read_set" => ["mix.exs"]}
      })

    assert {:error,
            %{
              payload: %{
                "kind" => "invalid_spec",
                "details" => %{"json_pointer" => "/subagents/read_set"}
              }
            }} =
             CLIContract.run(["--spec", "-", "--dry-run", "--json"],
               read_stdin: fn -> spec end
             )
  end

  test "workflow step keys fail closed with zero-based locations for dry-run and attached requests" do
    spec =
      Jason.encode!(%{
        "contract_version" => 1,
        "strategy" => "workflow",
        "mode" => "read_only",
        "steps" => [
          %{"id" => "inspect", "task" => "inspect"},
          %{"id" => "summarize", "task" => "summarize", "probe" => true}
        ]
      })

    for argv <- [
          ["--spec", "-", "--dry-run", "--json"],
          ["--spec", "-", "--json"]
        ] do
      assert {:error,
              %{
                exit_code: 2,
                payload: %{
                  "kind" => "invalid_spec",
                  "details" => details
                }
              }} =
               CLIContract.run(argv, read_stdin: fn -> spec end)

      assert details["unknown_key"] == "probe"
      assert details["json_pointer"] == "/steps/1/probe"
      assert details["path"] == ["steps", 1, "probe"]
      assert details["field"] == "steps[2].probe"
      assert details["step_index"] == 1
    end
  end

  test "workflow depend_on typo fails closed with a depends_on hint" do
    spec =
      Jason.encode!(%{
        "contract_version" => 1,
        "strategy" => "workflow",
        "mode" => "read_only",
        "steps" => [
          %{"id" => "inspect", "task" => "inspect"},
          %{"id" => "summarize", "task" => "summarize", "depend_on" => ["inspect"]}
        ]
      })

    assert {:error, %{payload: %{"kind" => "invalid_spec", "details" => details}}} =
             CLIContract.run(["--spec", "-", "--dry-run", "--json"],
               read_stdin: fn -> spec end
             )

    assert details["json_pointer"] == "/steps/1/depend_on"
    assert details["step_index"] == 1
    assert details["did_you_mean"] == "depends_on"
    assert "rename_field_to_depends_on" in details["next_actions"]
  end

  test "workflow strict-key validation accepts every parser-consumed step key" do
    workspace = tmp_workspace("pixir-delegate-workflow-step-keys")
    File.write!(Path.join(workspace, "evidence.txt"), "evidence\n")

    spec =
      Jason.encode!(%{
        "contract_version" => 1,
        "strategy" => "workflow",
        "mode" => "bounded_write",
        "write_policy" => %{"version" => 1, "allow_writes" => ["notes/**"]},
        "steps" => [
          %{
            "id" => "inspect",
            "task" => "inspect evidence",
            "agent" => "explorer",
            "workspace_mode" => "shared",
            "read_set" => ["evidence.txt"],
            "write_set" => ["notes/ignored.txt"],
            "model" => "gpt-test",
            "reasoning_effort" => "high",
            "attachments" => ["evidence.txt"],
            "depends_on" => [],
            "timeout_ms" => 1_000,
            "permission_mode" => "read_only",
            "sandbox_mode" => "read-only"
          },
          %{
            "id" => "producer",
            "task" => "produce a virtual diff",
            "workspace_mode" => "virtual_overlay",
            "read_set" => ["evidence.txt"],
            "virtual_commands" => ["true"],
            "limits" => %{"max_import_files" => 1},
            "depends_on" => ["inspect"],
            "permission_mode" => "read_only"
          },
          %{
            "id" => "apply",
            "task" => "apply the diff",
            "apply_from" => "producer",
            "workspace_mode" => "shared",
            "write_set" => ["notes/out.txt"],
            "depends_on" => ["producer"],
            "timeout_ms" => 1_000
          }
        ]
      })

    assert {:ok, %{payload: %{"status" => "planned", "strategy" => "workflow"}}} =
             CLIContract.run(["--spec", "-", "--dry-run", "--json"],
               workspace: workspace,
               read_stdin: fn -> spec end
             )
  end

  test "workflow step key accessor is pinned to normalization reads" do
    assert Pixir.Workflows.workflow_step_keys() ==
             ~w(
               id task agent apply_from workspace_mode read_set virtual_commands limits write_set model
               reasoning_effort attachments depends_on timeout_ms permission_mode sandbox_mode
             )
  end

  test "the accessor matches the step keys the normalizer source actually reads" do
    source = File.read!(Path.expand("../../../lib/pixir/workflows.ex", __DIR__))

    # Honest-regression pin, source-scrape grade: every step-map read in the
    # normalizer goes through field/has_field? on a raw step, so scraping those
    # call sites recovers the true accepted vocabulary. Convention-bound to the
    # parameter names raw/step; renaming them in workflows.ex must update this
    # regex or the second subset assert fails loudly on the dropped reads. Adding a read without
    # updating workflow_step_keys/0 (or vice versa) fails here first.
    scraped =
      ~r/(?:field|has_field\?)\(\s*(?:raw|step)\s*,\s*"([a-z_]+)"/
      |> Regex.scan(source, capture: :all_but_first)
      |> List.flatten()
      |> MapSet.new()

    accessor = MapSet.new(Pixir.Workflows.workflow_step_keys())

    assert MapSet.subset?(accessor, scraped),
           "accessor lists keys the normalizer never reads: #{inspect(MapSet.difference(accessor, scraped) |> Enum.sort())}"

    assert MapSet.subset?(scraped, accessor),
           "normalizer reads keys missing from workflow_step_keys/0: #{inspect(MapSet.difference(scraped, accessor) |> Enum.sort())}"
  end

  test "nested workflow.steps entries reject unknown keys with nested pointers" do
    spec =
      Jason.encode!(%{
        "contract_version" => 1,
        "strategy" => "workflow",
        "workflow" => %{
          "steps" => [
            %{"id" => "a", "task" => "t", "permission_mode" => "read_only", "probe" => true}
          ]
        }
      })

    assert {:error, %{payload: %{"kind" => "invalid_spec", "details" => details}}} =
             CLIContract.run(["--spec", "-", "--dry-run", "--json"], read_stdin: fn -> spec end)

    assert details["json_pointer"] == "/workflow/steps/0/probe"
    assert details["step_index"] == 0
    assert details["unknown_key"] == "probe"
    assert details["field"] == "workflow.steps[1].probe"
  end

  test "root steps and nested workflow.steps are mutually exclusive by key presence" do
    for root_steps <- [
          [%{"id" => "root", "task" => "root", "permission_mode" => "read_only"}],
          nil,
          []
        ] do
      spec =
        Jason.encode!(%{
          "contract_version" => 1,
          "strategy" => "workflow",
          "mode" => "read_only",
          "steps" => root_steps,
          "workflow" => %{
            "steps" => [%{"id" => "nested", "task" => "nested"}]
          }
        })

      for argv <- [
            ["--spec", "-", "--dry-run", "--json"],
            ["--spec", "-", "--json"]
          ] do
        assert {:error,
                %{
                  exit_code: 2,
                  payload: %{
                    "kind" => "invalid_spec",
                    "message" => "root steps and workflow.steps are mutually exclusive",
                    "details" => details
                  }
                }} = CLIContract.run(argv, read_stdin: fn -> spec end)

        assert details["json_pointer"] == "/workflow/steps"
        assert details["path"] == ["workflow", "steps"]
        assert details["next_actions"] == ["remove_root_steps", "remove_workflow_steps"]
      end
    end
  end

  test "workflow.steps rejects non-list values at shared spec admission" do
    for value <- [nil, %{}, "steps"] do
      spec =
        Jason.encode!(%{
          "contract_version" => 1,
          "strategy" => "workflow",
          "mode" => "read_only",
          "workflow" => %{"steps" => value}
        })

      for argv <- [
            ["--spec", "-", "--dry-run", "--json"],
            ["--spec", "-", "--json"]
          ] do
        assert {:error,
                %{
                  exit_code: 2,
                  payload: %{
                    "kind" => "invalid_spec",
                    "message" => "workflow.steps must be a list",
                    "details" => details
                  }
                }} = CLIContract.run(argv, read_stdin: fn -> spec end)

        assert details["observed"] == value
        assert details["json_pointer"] == "/workflow/steps"
        assert details["path"] == ["workflow", "steps"]
        assert details["next_actions"] == ["set_workflow_steps_to_a_list"]
      end
    end
  end

  test "non-workflow strategy rejects root steps at shared spec admission" do
    spec =
      ~s({"contract_version":1,"strategy":"subagents","mode":"read_only","tasks":[{"task":"say hi"}],"steps":[{"id":"stray","task":"this should not be here"}]})

    for argv <- [
          ["--spec", "-", "--dry-run", "--json"],
          ["--spec", "-", "--json"]
        ] do
      assert {:error,
              %{
                exit_code: 2,
                payload: %{
                  "kind" => "invalid_spec",
                  "details" => details
                }
              }} = CLIContract.run(argv, read_stdin: fn -> spec end)

      assert details["json_pointer"] == "/steps"
      assert details["path"] == ["steps"]
      assert details["observed_strategy"] == "subagents"
      assert details["accepted_values"] == ["workflow"]
      assert details["next_actions"] == ["use_workflow_strategy", "remove_steps"]
    end
  end

  test "non-workflow strategy rejects a nested workflow object at shared spec admission" do
    spec =
      Jason.encode!(%{
        "contract_version" => 1,
        "strategy" => "subagents",
        "mode" => "read_only",
        "tasks" => [%{"task" => "say hi"}],
        "workflow" => %{
          "steps" => [%{"id" => "stray", "task" => "this should not be here"}]
        }
      })

    for argv <- [
          ["--spec", "-", "--dry-run", "--json"],
          ["--spec", "-", "--json"]
        ] do
      assert {:error,
              %{
                exit_code: 2,
                payload: %{
                  "kind" => "invalid_spec",
                  "details" => details
                }
              }} = CLIContract.run(argv, read_stdin: fn -> spec end)

      assert details["json_pointer"] == "/workflow"
      assert details["path"] == ["workflow"]
      assert details["observed_strategy"] == "subagents"
      assert details["accepted_values"] == ["workflow"]
      assert details["next_actions"] == ["use_workflow_strategy", "remove_workflow"]
    end
  end

  test "workflow shell rejects non-object values at shared spec admission" do
    spec =
      Jason.encode!(%{
        "contract_version" => 1,
        "strategy" => "workflow",
        "mode" => "read_only",
        "steps" => [%{"id" => "s1", "task" => "noop"}],
        "workflow" => 5
      })

    for argv <- [
          ["--spec", "-", "--dry-run", "--json"],
          ["--spec", "-", "--json"]
        ] do
      assert {:error,
              %{
                exit_code: 2,
                payload: %{
                  "kind" => "invalid_spec",
                  "details" => details
                }
              }} = CLIContract.run(argv, read_stdin: fn -> spec end)

      assert details["json_pointer"] == "/workflow"
      assert details["path"] == ["workflow"]
      assert details["observed"] == 5
      assert details["next_actions"] == ["set_workflow_to_an_object_or_remove_it"]
    end
  end

  test "valid workflow strategy accepts the nested workflow.steps shape" do
    spec =
      Jason.encode!(%{
        "contract_version" => 1,
        "strategy" => "workflow",
        "mode" => "read_only",
        "workflow" => %{
          "steps" => [%{"id" => "s1", "task" => "noop"}]
        }
      })

    assert {:ok, %{payload: %{"status" => "planned", "strategy" => "workflow"}}} =
             CLIContract.run(["--spec", "-", "--dry-run", "--json"],
               read_stdin: fn -> spec end
             )
  end

  test "subagents spec without root steps remains valid" do
    spec =
      Jason.encode!(%{
        "contract_version" => 1,
        "strategy" => "subagents",
        "mode" => "read_only",
        "tasks" => [%{"task" => "say hi"}]
      })

    assert {:ok, %{payload: %{"status" => "planned", "strategy" => "subagents"}}} =
             CLIContract.run(["--spec", "-", "--dry-run", "--json"],
               read_stdin: fn -> spec end
             )
  end

  test "root limits rejects unknown timeout knobs on dry-run and attached paths" do
    spec =
      Jason.encode!(%{
        "contract_version" => 1,
        "strategy" => "subagents",
        "mode" => "read_only",
        "task" => "inspect timeout configuration",
        "limits" => %{"bogus" => 1}
      })

    for argv <- [
          ["--spec", "-", "--dry-run", "--json"],
          ["--spec", "-", "--json"]
        ] do
      assert {:error,
              %{
                exit_code: 2,
                payload: %{
                  "kind" => "invalid_spec",
                  "message" => "delegate spec limits contains an unknown key",
                  "details" => details
                }
              }} = CLIContract.run(argv, read_stdin: fn -> spec end)

      assert details["unknown_key"] == "bogus"

      assert details["accepted_keys"] ==
               ~w(child_timeout_ms delegate_timeout_ms timeout_ms wait_horizon_ms)

      assert details["json_pointer"] == "/limits/bogus"
      assert details["path"] == ["limits", "bogus"]
      assert details["field"] == "limits.bogus"
      assert details["next_actions"] == ["remove_unknown_limit", "check_delegate_timeout_knobs"]
    end
  end

  test "root limits rejects non-object values on dry-run and attached paths" do
    for value <- [nil, 1, [], true, "60000"] do
      spec =
        Jason.encode!(%{
          "contract_version" => 1,
          "strategy" => "subagents",
          "task" => "inspect timeout configuration",
          "limits" => value
        })

      for argv <- [
            ["--spec", "-", "--dry-run", "--json"],
            ["--spec", "-", "--json"]
          ] do
        assert {:error,
                %{
                  exit_code: 2,
                  payload: %{
                    "kind" => "invalid_spec",
                    "message" => "delegate spec limits must be an object",
                    "details" => details
                  }
                }} = CLIContract.run(argv, read_stdin: fn -> spec end)

        assert details["observed"] == value
        assert details["json_pointer"] == "/limits"
        assert details["path"] == ["limits"]
        assert details["field"] == "limits"
        assert details["next_actions"] == ["set_limits_to_an_object_or_remove_it"]
      end
    end
  end

  test "root limits accepts every timeout knob and leaves loose legacy timeout_ms valid" do
    accepted_keys = ~w(child_timeout_ms delegate_timeout_ms timeout_ms wait_horizon_ms)

    all_knobs_spec =
      Jason.encode!(%{
        "contract_version" => 1,
        "strategy" => "subagents",
        "task" => "inspect timeout configuration",
        "limits" => Map.new(accepted_keys, &{&1, 1_000})
      })

    legacy_spec =
      Jason.encode!(%{
        "contract_version" => 1,
        "strategy" => "subagents",
        "task" => "inspect timeout configuration",
        "timeout_ms" => 1_000
      })

    for spec <- [all_knobs_spec, legacy_spec] do
      assert {:ok, %{payload: %{"status" => "planned", "strategy" => "subagents"}}} =
               CLIContract.run(["--spec", "-", "--dry-run", "--json"],
                 read_stdin: fn -> spec end
               )
    end
  end

  test "root limit accessor is pinned to timeout normalization consumption" do
    assert Pixir.Delegate.Runner.root_limit_keys() ==
             ~w(child_timeout_ms delegate_timeout_ms timeout_ms wait_horizon_ms)

    source = File.read!(Path.expand("../../../lib/pixir/delegate/runner.ex", __DIR__))

    [normalizer] =
      ~r/defp normalize_timeouts\(request, spec\) do.*?(?=\n  defp request_timeout_candidate)/s
      |> Regex.run(source)

    assert normalizer =~ "Map.new(root_limit_keys()"
    assert normalizer =~ ~s|timeout_candidate(spec, ["limits", key])|

    consumed =
      ~r/Map\.fetch!\(root_limit_candidates, "([a-z_]+)"\)/
      |> Regex.scan(normalizer, capture: :all_but_first)
      |> List.flatten()
      |> Enum.sort()

    assert consumed == Pixir.Delegate.Runner.root_limit_keys()

    # A fifth knob consumed via a raw literal read (bypassing the accessor
    # loop) must fail here, not slip past the fetch-set equality above.
    raw_limit_reads =
      ~r/timeout_candidate\(spec, \["limits", "/
      |> Regex.scan(normalizer)

    assert raw_limit_reads == [],
           "normalize_timeouts reads a limits key outside the root_limit_keys loop: #{inspect(raw_limit_reads)}"

    assert Regex.scan(~r/get_in\(spec, \["limits"/, normalizer) == []
  end

  test "root workflow step rejects unknown virtual_overlay limit keys" do
    spec =
      ~s({"contract_version":1,"strategy":"workflow","mode":"read_only","steps":[{"id":"s1","task":"noop","depends_on":[],"workspace_mode":"virtual_overlay","read_set":["README.md"],"virtual_commands":["mix format --check-formatted"],"limits":{"bogus_limit":3,"max_output_bytes":-5}}]})

    for argv <- [
          ["--spec", "-", "--dry-run", "--json"],
          ["--spec", "-", "--json"]
        ] do
      assert {:error, %{exit_code: 2, payload: %{"kind" => "invalid_spec", "details" => details}}} =
               CLIContract.run(argv, read_stdin: fn -> spec end)

      assert details["unknown_key"] == "bogus_limit"

      assert details["accepted_keys"] ==
               ~w(max_diff_bytes max_file_bytes max_import_bytes max_import_files max_output_bytes max_virtual_commands)

      assert details["json_pointer"] == "/steps/0/limits/bogus_limit"
      assert details["path"] == ["steps", 0, "limits", "bogus_limit"]
      assert details["step_index"] == 0
      assert details["next_actions"] == ["remove_unknown_limit", "check_virtual_overlay_limits"]
    end
  end

  test "nested workflow step rejects negative virtual_overlay limit values" do
    spec =
      Jason.encode!(%{
        "contract_version" => 1,
        "strategy" => "workflow",
        "mode" => "read_only",
        "workflow" => %{
          "steps" => [
            %{
              "id" => "s1",
              "task" => "noop",
              "workspace_mode" => "virtual_overlay",
              "read_set" => ["README.md"],
              "virtual_commands" => ["true"],
              "limits" => %{"max_output_bytes" => -5}
            }
          ]
        }
      })

    for argv <- [
          ["--spec", "-", "--dry-run", "--json"],
          ["--spec", "-", "--json"]
        ] do
      assert {:error, %{payload: %{"kind" => "invalid_spec", "details" => details}}} =
               CLIContract.run(argv, read_stdin: fn -> spec end)

      assert details["observed"] == -5
      assert details["json_pointer"] == "/workflow/steps/0/limits/max_output_bytes"
      assert details["field"] == "workflow.steps[1].limits.max_output_bytes"
      assert details["next_actions"] == ["set_limit_to_a_non_negative_integer"]
    end
  end

  test "workflow step limits reject non-overlay steps and non-object overlay values" do
    cases = [
      {%{
         "id" => "shared",
         "task" => "noop",
         "workspace_mode" => "shared",
         "limits" => %{"max_output_bytes" => 1}
       }, ["set_step_workspace_mode_to_virtual_overlay", "remove_step_limits"]},
      {%{
         "id" => "overlay",
         "task" => "noop",
         "workspace_mode" => "virtual_overlay",
         "read_set" => ["README.md"],
         "virtual_commands" => ["true"],
         "limits" => 1
       }, ["set_limits_to_an_object_or_remove_it"]}
    ]

    for {step, expected_actions} <- cases do
      spec =
        Jason.encode!(%{
          "contract_version" => 1,
          "strategy" => "workflow",
          "mode" => "read_only",
          "steps" => [step]
        })

      assert {:error, %{payload: %{"kind" => "invalid_spec", "details" => details}}} =
               CLIContract.run(["--spec", "-", "--dry-run", "--json"],
                 read_stdin: fn -> spec end
               )

      assert details["json_pointer"] == "/steps/0/limits"
      assert details["next_actions"] == expected_actions
    end
  end

  test "valid workflow virtual_overlay limits remain accepted" do
    spec =
      Jason.encode!(%{
        "contract_version" => 1,
        "strategy" => "workflow",
        "mode" => "read_only",
        "steps" => [
          %{
            "id" => "s1",
            "task" => "noop",
            "workspace_mode" => "virtual_overlay",
            "read_set" => ["README.md"],
            "virtual_commands" => ["true"],
            "limits" => %{"max_output_bytes" => 4_096, "max_virtual_commands" => 1}
          }
        ]
      })

    assert {:ok, %{payload: %{"status" => "planned", "strategy" => "workflow"}}} =
             CLIContract.run(["--spec", "-", "--dry-run", "--json"],
               read_stdin: fn -> spec end
             )
  end

  test "workflow object shell rejects unknown keys" do
    spec =
      Jason.encode!(%{
        "contract_version" => 1,
        "strategy" => "workflow",
        "mode" => "read_only",
        "workflow" => %{
          "steps" => [%{"id" => "s1", "task" => "noop"}],
          "probe" => true
        }
      })

    for argv <- [
          ["--spec", "-", "--dry-run", "--json"],
          ["--spec", "-", "--json"]
        ] do
      assert {:error, %{payload: %{"kind" => "invalid_spec", "details" => details}}} =
               CLIContract.run(argv, read_stdin: fn -> spec end)

      assert details["unknown_key"] == "probe"
      assert details["accepted_keys"] == ["steps"]
      assert details["json_pointer"] == "/workflow/probe"
      assert details["path"] == ["workflow", "probe"]
      assert details["next_actions"] == ["remove_unknown_field", "check_delegate_spec_contract"]
    end
  end

  test "workflow shell key accessor is pinned to workflow and delegate consumers" do
    assert Pixir.Workflows.workflow_shell_keys() == ["steps"]

    workflows_source = File.read!(Path.expand("../../../lib/pixir/workflows.ex", __DIR__))

    normalized_shell_reads =
      ~r/^\s*([a-z_]+) = field\(spec, "([a-z_]+)", \[\]\)$/m
      |> Regex.scan(workflows_source, capture: :all_but_first)
      |> Enum.filter(fn [binding, key] -> binding == key end)
      |> Enum.map(fn [_binding, key] -> key end)
      |> MapSet.new()

    runner_source = File.read!(Path.expand("../../../lib/pixir/delegate/runner.ex", __DIR__))

    [runner_normalizer] =
      ~r/defp normalize_workflow_spec\(spec, mode\) do.*?(?=\n  defp force_read_only_step)/s
      |> Regex.run(runner_source)

    assert runner_normalizer =~
             "Map.take(nested, Pixir.Workflows.workflow_shell_keys())"

    assert Regex.scan(~r/Map\.([a-z_?]+)\(\s*nested/, runner_normalizer, capture: :all_but_first) ==
             [["take"]]

    assert length(Regex.scan(~r/\bnested\b/, runner_normalizer)) == 2
    refute Regex.match?(~r/nested\s*\[/, runner_normalizer)

    delegate_source =
      File.read!(Path.expand("../../../lib/pixir/delegate/cli_contract.ex", __DIR__))

    assert Regex.match?(
             ~r/reject_unknown_keys\(\s*workflow,\s*Pixir\.Workflows\.workflow_shell_keys\(\)/s,
             delegate_source
           )

    accessor = MapSet.new(Pixir.Workflows.workflow_shell_keys())
    assert accessor == normalized_shell_reads
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

  test "bounded_write rejects read-only subagent role during dry-run and attached validation" do
    spec =
      Jason.encode!(%{
        "contract_version" => 1,
        "strategy" => "subagents",
        "mode" => "bounded_write",
        "write_policy" => %{"version" => 1, "allow_writes" => ["notes/**"]},
        "task" => "inspect docs",
        "subagents" => %{"role" => "explorer"}
      })

    for argv <- [["--spec", "-", "--dry-run", "--json"], ["--spec", "-", "--json"]] do
      assert {:error,
              %{
                exit_code: 2,
                payload: %{
                  "ok" => false,
                  "status" => "rejected",
                  "kind" => "invalid_spec",
                  "message" => "bounded_write conflicts with the read-only role explorer",
                  "details" => details
                }
              }} =
               CLIContract.run(argv,
                 read_stdin: fn -> spec end
               )

      assert details["field"] == "subagents.role"
      assert details["json_pointer"] == "/subagents/role"
      assert details["path"] == ["subagents", "role"]
      assert details["role"] == "explorer"
      assert details["role_sandbox_mode"] == "read-only"
      assert details["mode"] == "bounded_write"

      assert details["next_actions"] == [
               "use_a_write_capable_role",
               "set_mode_to_read_only"
             ]
    end
  end

  test "bounded_write accepts a write-capable worker role during validation" do
    spec =
      Jason.encode!(%{
        "contract_version" => 1,
        "strategy" => "subagents",
        "mode" => "bounded_write",
        "write_policy" => %{"version" => 1, "allow_writes" => ["notes/**"]},
        "task" => "inspect docs",
        "subagents" => %{"role" => "worker"}
      })

    assert {:ok, %{payload: %{"status" => "planned"}}} =
             CLIContract.run(["--spec", "-", "--dry-run", "--json"],
               read_stdin: fn -> spec end
             )
  end

  test "read_only accepts a read-only explorer role during validation" do
    spec =
      Jason.encode!(%{
        "contract_version" => 1,
        "strategy" => "subagents",
        "mode" => "read_only",
        "task" => "inspect docs",
        "subagents" => %{"role" => "explorer"}
      })

    assert {:ok, %{payload: %{"status" => "planned"}}} =
             CLIContract.run(["--spec", "-", "--dry-run", "--json"],
               read_stdin: fn -> spec end
             )
  end

  test "bounded_write without an explicit role validates the delegate default role" do
    # Subagents.Manager defaults missing spawn-agent args to the built-in "default" role;
    # that role has no read-only sandbox mode, so bounded_write stays valid here.
    spec =
      Jason.encode!(%{
        "contract_version" => 1,
        "strategy" => "subagents",
        "mode" => "bounded_write",
        "write_policy" => %{"version" => 1, "allow_writes" => ["notes/**"]},
        "task" => "inspect docs"
      })

    assert {:ok, %{payload: %{"status" => "planned"}}} =
             CLIContract.run(["--spec", "-", "--dry-run", "--json"],
               read_stdin: fn -> spec end
             )
  end

  test "bounded_write rejects a custom role spelled sandbox_mode read_only" do
    ws =
      Path.join(
        System.tmp_dir!(),
        "pixir-239-raw-spelling-" <> Base.encode16(:crypto.strong_rand_bytes(5), case: :lower)
      )

    agents_dir = Path.join(ws, ".pixir/agents")
    File.mkdir_p!(agents_dir)

    File.write!(Path.join(agents_dir, "raw_reader.toml"), """
    name = "raw_reader"
    description = "Reader with the raw sandbox spelling"
    developer_instructions = "Read only."
    sandbox_mode = "read_only"
    """)

    on_exit(fn -> File.rm_rf!(ws) end)

    spec =
      Jason.encode!(%{
        "contract_version" => 1,
        "strategy" => "subagents",
        "mode" => "bounded_write",
        "write_policy" => %{"version" => 1, "allow_writes" => ["notes/**"]},
        "task" => "inspect docs",
        "subagents" => %{"role" => "raw_reader"}
      })

    assert {:error, %{exit_code: 2, payload: %{"kind" => "invalid_spec", "details" => details}}} =
             CLIContract.run(["--spec", "-", "--dry-run", "--json"],
               workspace: ws,
               read_stdin: fn -> spec end
             )

    assert details["role"] == "raw_reader"
    assert details["role_sandbox_mode"] == "read_only"
  end

  test "agent lookup for the conflict gate never escapes the caller workspace" do
    base =
      Path.join(
        System.tmp_dir!(),
        "pixir-239-confine-" <> Base.encode16(:crypto.strong_rand_bytes(5), case: :lower)
      )

    caller_ws = Path.join(base, "caller")
    outside = Path.join(base, "outside")
    File.mkdir_p!(caller_ws)

    # A write-capable "explorer" override planted OUTSIDE the caller workspace:
    # an unconfined lookup would find it and let the conflicting spec pass.
    outside_agents = Path.join(outside, ".pixir/agents")
    File.mkdir_p!(outside_agents)

    File.write!(Path.join(outside_agents, "explorer.toml"), """
    name = "explorer"
    description = "Write-capable impostor outside the workspace"
    developer_instructions = "Write freely."
    sandbox_mode = "workspace-write"
    """)

    on_exit(fn -> File.rm_rf!(base) end)

    spec =
      Jason.encode!(%{
        "contract_version" => 1,
        "strategy" => "subagents",
        "mode" => "bounded_write",
        "workspace" => "../outside",
        "write_policy" => %{"version" => 1, "allow_writes" => ["notes/**"]},
        "task" => "inspect docs",
        "subagents" => %{"role" => "explorer"}
      })

    # The lookup stays confined to the caller workspace, so the built-in
    # read-only explorer wins and the conflict is still rejected.
    assert {:error, %{exit_code: 2, payload: %{"kind" => "invalid_spec", "details" => details}}} =
             CLIContract.run(["--spec", "-", "--dry-run", "--json"],
               workspace: caller_ws,
               read_stdin: fn -> spec end
             )

    assert details["role"] == "explorer"
    assert details["role_sandbox_mode"] == "read-only"
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
