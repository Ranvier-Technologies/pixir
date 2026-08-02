defmodule PixirMonitor.ProjectionMutationChildEvidenceTest do
  @moduledoc """
  Child-log evidence folded into unit and run mutation: derived applied writes,
  write-policy denials, and the derived `basis` provenance label.
  """
  use ExUnit.Case, async: true

  alias PixirMonitor.Projection.Builder
  alias PixirMonitor.Projection.Validator

  describe "child-derived applied writes" do
    test "a successful child write with no envelope evidence yields a lower-bound partial mutation" do
      assert {:ok, projection} =
               Builder.build(
                 input(
                   child_logs: %{
                     "child-writer" => [
                       tool_call(1, "call-a", "write", %{"path" => "lib/pixir/example.ex"}),
                       tool_result(2, "call-a", true)
                     ]
                   }
                 )
               )

      [unit] = projection["units"]

      assert unit["mutation"]["status"] == "partial"
      assert unit["mutation"]["observed_semantics"] == "at_least"
      assert unit["mutation"]["observed_paths"] == ["lib/pixir/example.ex"]

      assert projection["mutation"]["status"] == "partial"
      assert projection["mutation"]["observed_semantics"] == "at_least"
      assert projection["mutation"]["observed_paths"] == ["lib/pixir/example.ex"]
      assert :ok = Validator.validate(projection)
    end

    test "child-derived paths are workspace-relative, deduplicated in first-observation order" do
      assert {:ok, projection} =
               Builder.build(
                 input(
                   child_logs: %{
                     "child-writer" => [
                       tool_call(1, "call-b", "write", %{"path" => "./lib/b.ex"}),
                       tool_result(2, "call-b", true),
                       tool_call(3, "call-a", "edit", %{"path" => "lib/a.ex"}),
                       tool_result(4, "call-a", true),
                       tool_call(5, "call-b2", "write", %{"path" => "lib/b.ex"}),
                       tool_result(6, "call-b2", true)
                     ]
                   }
                 )
               )

      [unit] = projection["units"]
      assert unit["mutation"]["observed_paths"] == ["lib/b.ex", "lib/a.ex"]
    end

    test "a child write escaping the workspace is not reported as an observed path" do
      assert {:ok, projection} =
               Builder.build(
                 input(
                   child_logs: %{
                     "child-writer" => [
                       tool_call(1, "call-out", "write", %{"path" => "../outside/secret.ex"}),
                       tool_result(2, "call-out", true),
                       tool_call(3, "call-abs", "write", %{"path" => "/etc/passwd"}),
                       tool_result(4, "call-abs", true),
                       tool_call(5, "call-in", "write", %{"path" => "lib/inside.ex"}),
                       tool_result(6, "call-in", true)
                     ]
                   }
                 )
               )

      [unit] = projection["units"]
      assert unit["mutation"]["observed_paths"] == ["lib/inside.ex"]
    end

    test "an uncorrelated or failed write tool call contributes no observed path" do
      assert {:ok, projection} =
               Builder.build(
                 input(
                   child_logs: %{
                     "child-writer" => [
                       tool_call(1, "call-orphan", "write", %{"path" => "lib/orphan.ex"}),
                       tool_call(2, "call-failed", "write", %{"path" => "lib/failed.ex"}),
                       tool_result(3, "call-failed", false)
                     ]
                   }
                 )
               )

      [unit] = projection["units"]
      assert unit["mutation"]["observed_paths"] == []
      assert unit["mutation"]["status"] == "none"
      assert unit["mutation"]["basis"] == "no_write_evidence"
    end

    test "envelope-supplied writes take precedence and are never double-counted" do
      assert {:ok, projection} =
               Builder.build(
                 input(
                   child: %{"observed_applied_writes" => ["lib/pixir/example.ex"]},
                   child_logs: %{
                     "child-writer" => [
                       tool_call(1, "call-a", "write", %{"path" => "lib/pixir/example.ex"}),
                       tool_result(2, "call-a", true)
                     ]
                   }
                 )
               )

      [unit] = projection["units"]
      assert unit["mutation"]["observed_paths"] == ["lib/pixir/example.ex"]
      assert unit["mutation"]["basis"] == "envelope_observed_writes"
      assert projection["mutation"]["observed_paths"] == ["lib/pixir/example.ex"]
    end

    test "child-derived write evidence never claims exact semantics or workspace_applied" do
      assert {:ok, projection} =
               Builder.build(
                 input(
                   child_logs: %{
                     "child-writer" => [
                       tool_call(1, "call-a", "write", %{"path" => "lib/a.ex"}),
                       tool_result(2, "call-a", true)
                     ]
                   }
                 )
               )

      [unit] = projection["units"]
      refute unit["mutation"]["observed_semantics"] == "exact"
      refute unit["mutation"]["status"] == "workspace_applied"
      refute projection["mutation"]["observed_semantics"] == "exact"
      refute projection["mutation"]["status"] == "workspace_applied"
    end
  end

  describe "write-policy denials" do
    test "a write_policy deny is projected on the unit and folded to the run" do
      assert {:ok, projection} =
               Builder.build(
                 input(
                   child_logs: %{
                     "child-writer" => [
                       deny(1, "call-deny", %{
                         "requested_path" => "docs/notes.md",
                         "normalized_path" => "docs/notes.md",
                         "matched_rule" => "no_allow_match",
                         "rule" => "no_allow_match",
                         "policy_id" => "policy-writer",
                         "policy_hash" => "sha256:abcdef",
                         "tool" => "write"
                       })
                     ]
                   }
                 )
               )

      [unit] = projection["units"]

      assert [denial] = unit["mutation"]["write_denials"]
      assert denial["normalized_path"] == "docs/notes.md"
      assert denial["matched_rule"] == "no_allow_match"
      assert denial["policy_id"] == "policy-writer"
      assert denial["policy_hash"] == "sha256:abcdef"
      assert denial["evidence_refs"] != []

      assert projection["mutation"]["write_denials"] == unit["mutation"]["write_denials"]
      assert :ok = Validator.validate(projection)
    end

    test "denies deduplicate by path, rule, and policy identity in first-observation order" do
      assert {:ok, projection} =
               Builder.build(
                 input(
                   child_logs: %{
                     "child-writer" => [
                       deny(1, "c1", %{
                         "normalized_path" => "docs/b.md",
                         "matched_rule" => "no_allow_match",
                         "policy_id" => "p1"
                       }),
                       deny(2, "c2", %{
                         "normalized_path" => "docs/a.md",
                         "matched_rule" => "deny_match",
                         "policy_id" => "p1"
                       }),
                       deny(3, "c3", %{
                         "normalized_path" => "docs/b.md",
                         "matched_rule" => "no_allow_match",
                         "policy_id" => "p1"
                       })
                     ]
                   }
                 )
               )

      [unit] = projection["units"]

      assert Enum.map(unit["mutation"]["write_denials"], & &1["normalized_path"]) ==
               ["docs/b.md", "docs/a.md"]
    end

    test "distinct out-of-lane denies stay distinct even though both normalize to nil" do
      assert {:ok, projection} =
               Builder.build(
                 input(
                   child_logs: %{
                     "child-writer" => [
                       deny(1, "c1", %{
                         "requested_path" => "/etc/passwd",
                         "matched_rule" => "no_allow_match",
                         "policy_id" => "p1"
                       }),
                       deny(2, "c2", %{
                         "requested_path" => "/etc/shadow",
                         "matched_rule" => "no_allow_match",
                         "policy_id" => "p1"
                       })
                     ]
                   }
                 )
               )

      [unit] = projection["units"]
      denials = unit["mutation"]["write_denials"]

      assert Enum.map(denials, & &1["normalized_path"]) == [nil, nil]
      assert Enum.map(denials, & &1["requested_path"]) == ["/etc/passwd", "/etc/shadow"]

      assert Enum.map(projection["mutation"]["write_denials"], & &1["requested_path"]) ==
               ["/etc/passwd", "/etc/shadow"]
    end

    test "the same denied path in two units keeps both units' evidence at run scope" do
      assert {:ok, projection} =
               Builder.build(
                 two_unit_input(%{
                   "child-a" => [
                     deny(1, "c1", %{
                       "normalized_path" => "docs/shared.md",
                       "matched_rule" => "no_allow_match",
                       "policy_id" => "p1"
                     })
                   ],
                   "child-b" => [
                     deny(1, "c2", %{
                       "normalized_path" => "docs/shared.md",
                       "matched_rule" => "no_allow_match",
                       "policy_id" => "p1"
                     })
                   ]
                 })
               )

      denials = projection["mutation"]["write_denials"]

      assert Enum.map(denials, & &1["normalized_path"]) == ["docs/shared.md", "docs/shared.md"]

      assert denials |> Enum.flat_map(& &1["evidence_refs"]) |> Enum.uniq() |> length() == 2
      assert :ok = Validator.validate(projection)
    end

    test "an observed deny reaches the unit evidence drill-down even when nothing was written" do
      assert {:ok, projection} =
               Builder.build(
                 input(
                   child_logs: %{
                     "child-writer" => [
                       deny(1, "c1", %{
                         "normalized_path" => "docs/a.md",
                         "matched_rule" => "no_allow_match",
                         "policy_id" => "p1"
                       })
                     ]
                   }
                 )
               )

      [unit] = projection["units"]
      assert unit["mutation"]["status"] == "none"

      denial_refs = unit["mutation"]["write_denials"] |> Enum.flat_map(& &1["evidence_refs"])
      assert denial_refs != []

      for ref <- denial_refs do
        assert ref in unit["evidence_refs"]
      end
    end

    test "denies from different units stay attributable to their unit" do
      assert {:ok, projection} =
               Builder.build(
                 two_unit_input(%{
                   "child-a" => [
                     deny(1, "c1", %{
                       "normalized_path" => "docs/a.md",
                       "matched_rule" => "no_allow_match",
                       "policy_id" => "p1"
                     })
                   ],
                   "child-b" => [
                     deny(1, "c2", %{
                       "normalized_path" => "docs/b.md",
                       "matched_rule" => "deny_match",
                       "policy_id" => "p2"
                     })
                   ]
                 })
               )

      by_unit =
        Map.new(projection["units"], fn unit ->
          {unit["logical_id"], Enum.map(unit["mutation"]["write_denials"], & &1["normalized_path"])}
        end)

      assert Map.values(by_unit) |> Enum.sort() == [["docs/a.md"], ["docs/b.md"]]

      assert Enum.map(projection["mutation"]["write_denials"], & &1["normalized_path"]) ==
               ["docs/a.md", "docs/b.md"]
    end

    test "a deny alone is not a mutation" do
      assert {:ok, projection} =
               Builder.build(
                 input(
                   child_logs: %{
                     "child-writer" => [
                       deny(1, "c1", %{
                         "normalized_path" => "docs/a.md",
                         "matched_rule" => "no_allow_match",
                         "policy_id" => "p1"
                       })
                     ]
                   }
                 )
               )

      [unit] = projection["units"]
      assert unit["mutation"]["status"] == "none"
      assert unit["mutation"]["observed_semantics"] == "none"
      assert unit["mutation"]["write_denials"] != []
      assert projection["mutation"]["status"] == "none"
    end
  end

  describe "basis labelling" do
    test "basis distinguishes envelope, child-derived, mixed, and absent write evidence" do
      envelope_only =
        input(
          child: %{"observed_applied_writes" => ["lib/a.ex"]},
          child_logs: %{"child-writer" => []}
        )

      child_only =
        input(
          child_logs: %{
            "child-writer" => [
              tool_call(1, "c1", "write", %{"path" => "lib/a.ex"}),
              tool_result(2, "c1", true)
            ]
          }
        )

      mixed =
        input(
          child: %{"observed_applied_writes" => ["lib/a.ex"]},
          child_logs: %{
            "child-writer" => [
              tool_call(1, "c1", "write", %{"path" => "lib/b.ex"}),
              tool_result(2, "c1", true)
            ]
          }
        )

      none = input(child_logs: %{"child-writer" => [assistant(1)]})

      assert {:ok, p1} = Builder.build(envelope_only)
      assert {:ok, p2} = Builder.build(child_only)
      assert {:ok, p3} = Builder.build(mixed)
      assert {:ok, p4} = Builder.build(none)

      assert hd(p1["units"])["mutation"]["basis"] == "envelope_observed_writes"
      assert hd(p2["units"])["mutation"]["basis"] == "child_log_derived"
      assert hd(p3["units"])["mutation"]["basis"] == "envelope_and_child_log"
      assert hd(p4["units"])["mutation"]["basis"] == "no_write_evidence"

      assert p1["mutation"]["basis"] == "envelope_observed_writes"
      assert p2["mutation"]["basis"] == "child_log_derived"
      assert p3["mutation"]["basis"] == "envelope_and_child_log"
      assert p4["mutation"]["basis"] == "no_write_evidence"
    end

    test "apply-engine checkpoint evidence carries its own basis and keeps exact semantics" do
      assert {:ok, projection} = Builder.build(virtual_apply_input())

      apply_unit = Enum.find(projection["units"], &(&1["execution_kind"] == "virtual_diff_apply"))
      assert apply_unit["mutation"]["basis"] == "apply_checkpoint"
      assert apply_unit["mutation"]["status"] == "workspace_applied"
      assert apply_unit["mutation"]["observed_semantics"] == "exact"
      assert projection["mutation"]["basis"] == "apply_checkpoint"
    end

    test "the run basis is a deterministic fold of unit bases" do
      assert {:ok, projection} =
               Builder.build(
                 two_unit_input(%{
                   "child-a" => [
                     tool_call(1, "c1", "write", %{"path" => "lib/a.ex"}),
                     tool_result(2, "c1", true)
                   ],
                   "child-b" => []
                 })
               )

      bases = projection["units"] |> Enum.map(& &1["mutation"]["basis"]) |> Enum.sort()
      assert bases == ["child_log_derived", "no_write_evidence"]
      assert projection["mutation"]["basis"] == "child_log_derived"
    end

    test "the run basis fold follows the documented precedence for every mixed pair" do
      documented = ~w(envelope_observed_writes child_log_derived envelope_and_child_log apply_checkpoint no_child_evidence_available no_write_evidence)

      schema =
        "priv/presenter/schema/pixir.presenter.run.v1.schema.json"
        |> File.read!()
        |> Jason.decode!()
        |> get_in(["$defs", "mutation", "properties", "basis", "enum"])

      assert schema == documented

      fold = fn bases ->
        Enum.find(documented, "no_write_evidence", &(&1 in bases))
      end

      # An envelope-observed write outranks an apply checkpoint, not the reverse.
      assert fold.(["apply_checkpoint", "envelope_observed_writes"]) == "envelope_observed_writes"
      assert fold.(["no_write_evidence", "apply_checkpoint"]) == "apply_checkpoint"

      assert fold.(["no_write_evidence", "no_child_evidence_available"]) ==
               "no_child_evidence_available"

      builder_order =
        "lib/pixir_monitor/projection/builder.ex"
        |> File.read!()
        |> then(&Regex.run(~r/@basis_precedence\s+~w\(([^)]+)\)/, &1))
        |> List.last()
        |> String.split()

      assert builder_order == documented
    end
  end

  describe "honest absence" do
    test "missing child logs keep mutation honest and say no child evidence was available" do
      assert {:ok, projection} =
               Builder.build(
                 input(
                   child_logs: %{"child-writer" => nil},
                   completeness: %{"parent_log" => "complete", "child_logs" => "explicitly_missing"}
                 )
               )

      [unit] = projection["units"]

      assert unit["mutation"]["basis"] == "no_child_evidence_available"
      assert "child_log_missing" in unit["mutation"]["limitations"]
      assert "mutation_evidence_incomplete" in unit["mutation"]["limitations"]
      refute unit["mutation"]["status"] == "none"

      assert projection["mutation"]["basis"] == "no_child_evidence_available"
      assert "child_log_missing" in projection["mutation"]["limitations"]
      assert :ok = Validator.validate(projection)
    end

    test "minimized child logs also report that no child evidence was available" do
      assert {:ok, projection} =
               Builder.build(
                 input(
                   child_logs: %{"child-writer" => []},
                   completeness: %{"parent_log" => "complete", "child_logs" => "minimized"}
                 )
               )

      [unit] = projection["units"]
      assert unit["mutation"]["basis"] == "no_child_evidence_available"
      assert "mutation_evidence_incomplete" in unit["mutation"]["limitations"]
    end
  end

  describe "evidence drill-down and determinism" do
    test "every derived path and denial contributes a resolvable child evidence ref" do
      assert {:ok, projection} =
               Builder.build(
                 input(
                   child_logs: %{
                     "child-writer" => [
                       tool_call(1, "c1", "write", %{"path" => "lib/a.ex"}),
                       tool_result(2, "c1", true),
                       deny(3, "c2", %{
                         "normalized_path" => "docs/a.md",
                         "matched_rule" => "no_allow_match",
                         "policy_id" => "p1"
                       })
                     ]
                   }
                 )
               )

      [unit] = projection["units"]
      refs = unit["mutation"]["evidence_refs"]

      assert "e-child-1" in refs
      assert "e-child-2" in refs
      assert "e-child-3" in refs

      [denial] = unit["mutation"]["write_denials"]
      assert Enum.all?(denial["evidence_refs"], &(&1 in refs))

      known = MapSet.new(projection["evidence"], & &1["id"])
      assert Enum.all?(refs, &MapSet.member?(known, &1))
    end

    test "the run-scope mutation fold is order-stable across two projections" do
      fixture =
        two_unit_input(%{
          "child-a" => [
            tool_call(1, "c1", "write", %{"path" => "lib/a.ex"}),
            tool_result(2, "c1", true),
            deny(3, "c2", %{
              "normalized_path" => "docs/a.md",
              "matched_rule" => "no_allow_match",
              "policy_id" => "p1"
            })
          ],
          "child-b" => [
            tool_call(1, "c3", "edit", %{"path" => "lib/b.ex"}),
            tool_result(2, "c3", true)
          ]
        })

      assert {:ok, first} = Builder.build(fixture)
      assert {:ok, second} = Builder.build(fixture)

      assert first["mutation"] == second["mutation"]
      assert Map.keys(first["mutation"]) == Map.keys(second["mutation"])
      assert first["mutation"]["observed_paths"] == ["lib/a.ex", "lib/b.ex"]
    end
  end

  describe "presenter run card" do
    @app Path.expand("../../priv/static/app.js", __DIR__)

    test "the mutation panel renders basis and write denies without opening child logs" do
      source = File.read!(@app)

      assert source =~ ~s{section.append(marker(mutation && mutation.status, "mutation", mutation && mutation.basis));}
      assert source =~ ~s{"Evidence basis: " + titleCase(mutation && mutation.basis)}
      assert source =~ "section.append(writeDenials(mutation));"

      assert source =~ ~s{const denials = array(mutation && mutation.write_denials);}
      assert source =~ ~s{projected(item, "code", denial.normalized_path || denial.requested_path);}
      assert source =~ ~s{titleCase(denial.matched_rule)}
      assert source =~ "denial.policy_id"
      assert source =~ "denial.policy_hash"

      # Denials stay inert observation: no control plane leaks into the card.
      refute source =~ ~r/write_denials[\s\S]{0,600}?\bbutton\b/
    end

    test "the denial list stays inside the frozen evidence budget" do
      source = File.read!(@app)

      assert source =~ "denials.slice(0, LIMITS.evidence)"
      assert source =~ ~s{if (denials.length > LIMITS.evidence) region.append(text("p", "Showing " + LIMITS.evidence + " of " + denials.length + " observed denials.", "truncation"));}
    end
  end

  # ── fixtures ────────────────────────────────────────────────────────────

  defp input(opts) do
    child_logs = Keyword.get(opts, :child_logs, %{})
    child_extra = Keyword.get(opts, :child, %{})

    completeness =
      Keyword.get(opts, :completeness, %{"parent_log" => "complete", "child_logs" => "complete"})

    %{
      "projected_at" => "2026-07-31T00:00:00Z",
      "inputs" => %{
        "terminal_envelope" => %{
          "kind" => "delegate_result",
          "delegate_id" => "dlg-child-evidence",
          "parent_session_id" => "parent",
          "strategy" => "subagents",
          "mode" => "bounded_write",
          "status" => "completed",
          "children" => [
            Map.merge(
              %{
                "subagent_id" => "sub-writer",
                "child_session_id" => "child-writer",
                "agent" => "worker",
                "status" => "completed",
                "workspace_mode" => "shared"
              },
              child_extra
            )
          ]
        },
        "delegate_snapshot" => nil,
        "parent_log" => [
          subagent_event(0, "sub-writer", "child-writer", "started", "running"),
          subagent_event(1, "sub-writer", "child-writer", "finished", "completed")
        ],
        "parent_log_origin" => "fixture",
        "child_logs" => child_logs,
        "runtime_diagnostics" => nil,
        "owner_state" => %{"state" => "snapshot_only", "reachable" => false},
        "evidence_mirror" => nil
      },
      "completeness" => completeness
    }
  end

  defp two_unit_input(child_logs) do
    %{
      "projected_at" => "2026-07-31T00:00:00Z",
      "inputs" => %{
        "terminal_envelope" => %{
          "kind" => "delegate_result",
          "delegate_id" => "dlg-two",
          "parent_session_id" => "parent",
          "strategy" => "subagents",
          "mode" => "bounded_write",
          "status" => "completed",
          "children" => [
            %{
              "subagent_id" => "sub-a",
              "child_session_id" => "child-a",
              "agent" => "worker",
              "status" => "completed",
              "workspace_mode" => "shared"
            },
            %{
              "subagent_id" => "sub-b",
              "child_session_id" => "child-b",
              "agent" => "worker",
              "status" => "completed",
              "workspace_mode" => "shared"
            }
          ]
        },
        "delegate_snapshot" => nil,
        "parent_log" => [
          subagent_event(0, "sub-a", "child-a", "started", "running"),
          subagent_event(1, "sub-b", "child-b", "started", "running"),
          subagent_event(2, "sub-a", "child-a", "finished", "completed"),
          subagent_event(3, "sub-b", "child-b", "finished", "completed")
        ],
        "parent_log_origin" => "fixture",
        "child_logs" => child_logs,
        "runtime_diagnostics" => nil,
        "owner_state" => %{"state" => "snapshot_only", "reachable" => false},
        "evidence_mirror" => nil
      },
      "completeness" => %{"parent_log" => "complete", "child_logs" => "complete"}
    }
  end

  defp virtual_apply_input do
    steps = [
      %{"id" => "produce", "execution_kind" => "virtual_overlay", "depends_on" => []},
      %{"id" => "apply", "execution_kind" => "virtual_diff_apply", "depends_on" => ["produce"]}
    ]

    %{
      "projected_at" => "2026-07-31T00:00:00Z",
      "inputs" => %{
        "terminal_envelope" => %{
          "kind" => "delegate_result",
          "delegate_id" => "dlg-apply",
          "parent_session_id" => "parent",
          "strategy" => "workflow",
          "workflow_id" => "wf-apply",
          "mode" => "bounded_write",
          "status" => "completed",
          "steps" => [
            %{
              "step_id" => "apply",
              "checkpoint" => %{
                "virtual_diff_apply" => %{
                  "status" => "applied",
                  "files" => [%{"path" => "lib/applied.ex", "status" => "applied"}]
                }
              }
            }
          ]
        },
        "delegate_snapshot" => nil,
        "parent_log" => [
          %{
            "seq" => 0,
            "ts" => "2026-07-31T00:00:00Z",
            "type" => "workflow_event",
            "session_id" => "parent",
            "data" => %{
              "kind" => "workflow_started",
              "workflow_id" => "wf-apply",
              "graph" => %{"steps" => steps}
            }
          }
        ],
        "parent_log_origin" => "fixture",
        "child_logs" => %{},
        "runtime_diagnostics" => nil,
        "owner_state" => %{"state" => "snapshot_only", "reachable" => false},
        "evidence_mirror" => nil
      },
      "completeness" => %{"parent_log" => "complete", "child_logs" => "complete"}
    }
  end

  defp subagent_event(seq, subagent_id, child_id, event, status) do
    %{
      "seq" => seq,
      "ts" => "2026-07-31T00:00:0#{seq}Z",
      "type" => "subagent_event",
      "session_id" => "parent",
      "data" => %{
        "event" => event,
        "status" => status,
        "subagent_id" => subagent_id,
        "child_session_id" => child_id,
        "agent" => "worker",
        "workspace_mode" => "shared"
      }
    }
  end

  defp tool_call(seq, call_id, name, args) do
    %{
      "seq" => seq,
      "ts" => "2026-07-31T00:01:0#{seq}Z",
      "type" => "tool_call",
      "data" => %{"call_id" => call_id, "name" => name, "args" => args}
    }
  end

  defp tool_result(seq, call_id, ok) do
    %{
      "seq" => seq,
      "ts" => "2026-07-31T00:01:0#{seq}Z",
      "type" => "tool_result",
      "data" => %{"call_id" => call_id, "ok" => ok}
    }
  end

  defp deny(seq, call_id, details) do
    %{
      "seq" => seq,
      "ts" => "2026-07-31T00:01:0#{seq}Z",
      "type" => "permission_decision",
      "data" => Map.merge(%{"call_id" => call_id, "decision" => "deny", "gate" => "write_policy"}, details)
    }
  end

  defp assistant(seq) do
    %{
      "seq" => seq,
      "ts" => "2026-07-31T00:01:0#{seq}Z",
      "type" => "assistant_message",
      "data" => %{"text" => "no writes here"}
    }
  end
end
